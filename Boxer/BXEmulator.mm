/* 
 Boxer is copyright 2009 Alun Bestor and contributors.
 Boxer is released under the GNU General Public License 2.0. A full copy of this license can be
 found in this XCode project at Resources/English.lproj/GNU General Public License.txt, or read
 online at [http://www.gnu.org/licenses/gpl-2.0.txt].
 */

#import "BXEmulator.h"
#import "BXSession+BXEmulatorController.h"

#import "BXEmulator+BXShell.h"
#import "BXEmulator+BXRendering.h"
#import "BXEmulator+BXRecording.h"
#import "BXEmulator+BXDOSFileSystem.h"
#import "BXRenderer.h"

#import "boxer.h"
#import "render.h"
#import "cpu.h"
#import "sdlmain.h"
#import "mixer.h"
#import "control.h"
#import "shell.h"
#import "vga.h"

#import <SDL/boxer_hooks.h>	//for boxer_SDLCaptureInput et. al.
#import <crt_externs.h>		//for _NSGetArgc() and _NSGetArgv()

//Default name that DOSBox uses when there's no process running. Used by processName for string comparisons.
NSString * const shellProcessName = @"DOSBOX";


//String encodings to use when talking to DOSBox
//----------------------------------------------

//Use for strings that should be displayed to the user
NSStringEncoding BXDisplayStringEncoding	= CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingDOSLatin1);
//Use for strings that should be left unmunged (usually filesystem paths)
NSStringEncoding BXDirectStringEncoding		= NSUTF8StringEncoding;


//DOSBox functions and vars we hook into
//--------------------------------------

//defined in gui/sdlmain.cpp
int DOSBox_main(int argc, char* argv[]);

//Defined by us in midi.cpp
void boxer_toggleMIDIOutput(bool enabled);


//defined in dos_execute.cpp
extern const char* RunningProgram;

//defined in dosbox.h
extern Config * control;

//the current shell instance in DOSBox, defined in shell.h
extern Program * first_shell;

//Defined herein
BXCoreMode boxer_CPUMode();

extern DOS_Block dos;

BXEmulator *currentEmulator = nil;


@implementation BXEmulator
@synthesize processName, processPath, processLocalPath;
@synthesize currentRecordingPath;
@synthesize delegate, thread;
@synthesize renderer;
@synthesize minFixedSpeed, maxFixedSpeed, maxFrameskip;
@synthesize suppressOutput;
@synthesize configFiles;
@synthesize aspectCorrected;
@synthesize filterType;
@synthesize commandQueue;


//Introspective class methods
//---------------------------

//Used by processIsInternal, to determine when we're running one of DOSBox's own builtin programs
//TODO: generate this from DOSBox's builtin program manifest instead
+ (NSArray *) internalProcessNames
{
	static NSArray *names = nil;
	if (!names) names = [[NSArray alloc] initWithObjects:
		@"IPXNET",
		@"COMMAND",
		@"KEYB",
		@"IMGMOUNT",
		@"BOOT",
		@"INTRO",
		@"RESCAN",
		@"LOADFIX",
		@"MEM",
		@"MOUNT",
		@"MIXER",
		@"CONFIG",
	nil];
	return names;
}

+ (BOOL) isInternal: (NSString *)process
{
	return [[self internalProcessNames] containsObject: process];
}


//Key-value binding-related class methods
//---------------------------------------

//Every property also depends on whether we're executing or not
+ (NSSet *) keyPathsForValuesAffectingValueForKey: (NSString *)key
{
	NSSet *keyPaths = [super keyPathsForValuesAffectingValueForKey: key];
	if (![key isEqualToString: @"isExecuting"]) keyPaths = [keyPaths setByAddingObject: @"isExecuting"];
	return keyPaths;
}

+ (NSSet *) keyPathsForValuesAffectingMouseLocked		{ return [NSSet setWithObject: @"fullScreen"]; }
+ (NSSet *) keyPathsForValuesAffectingDynamic			{ return [NSSet setWithObject: @"coreMode"]; }

+ (NSSet *) keyPathsForValuesAffectingIsRunningProcess	{ return [NSSet setWithObjects: @"processName", @"processPath", nil]; }
+ (NSSet *) keyPathsForValuesAffectingProcessIsInternal	{ return [NSSet setWithObject: @"processName"]; }


+ (BXEmulator *) currentEmulator
{
	return currentEmulator;
}

- (id) init
{
	if ((self = [super init]))
	{
		//Todo: bind these to hidden preferences instead?
		maxFixedSpeed		= BXMaxSpeedThreshold;
		minFixedSpeed		= BXMinSpeedThreshold;
		maxFrameskip		= 9;
		
		configFiles			= [[NSMutableArray alloc] initWithCapacity: 10];
		commandQueue		= [[NSMutableArray alloc] initWithCapacity: 4];
		driveCache			= [[NSMutableDictionary alloc] initWithCapacity: DOS_DRIVES];
		currentVideoMode	= M_TEXT;
		
		[self setRenderer: [[[BXRenderer alloc] init] autorelease]];
	}
	return self;
}

- (void) dealloc
{
	[self setProcessName: nil],	[processName release];
	[self setCurrentRecordingPath: nil], [currentRecordingPath release];
	[self setRenderer: nil], [renderer release];
	
	[driveCache release], driveCache = nil;
	[configFiles release], configFiles = nil;
	[commandQueue release], commandQueue = nil;
	
	[super dealloc];
}


//Threading and operation control
//-------------------------------

- (void) main
{
	currentEmulator = self;
	
	//Record the thread we are running on for comparisons later
	//We don't retain it since presumably it will always outlive us
	thread = [NSThread currentThread];
	
	//Start DOSBox's main loop
	DOSBox_main(*_NSGetArgc(), *_NSGetArgv());
	
	//Clean up after DOSBox finishes
	[self _shutdownRecording];
	[self _shutdownRenderer];
	[self _shutdownShell];
	
	if (currentEmulator == self) currentEmulator = nil;
}



//Introspecting emulation state
//-----------------------------

- (BOOL) isRunningProcess
{
	//Extra-safe - processPath is set earlier than processName
	return [self isExecuting] && ([self processName] || [self processPath]);
}

- (BOOL) processIsInternal
{
	if (![self isRunningProcess]) return NO;
	return [[self class] isInternal: [self processName]];
}

- (BOOL) isInBatchScript
{
	DOS_Shell *shell = [self _currentShell];
	return (shell && shell->bf);
}

- (BOOL) isAtPrompt
{
	return ![self isRunningProcess] && ![self isInBatchScript];
}



//Managing user input
//-------------------

- (void) setMouseLocked: (BOOL)lock
{
	BOOL wasLocked = [self mouseLocked];
	if ([self isExecuting] && wasLocked != lock)
	{
		GFX_CaptureMouse();
		//Force additional activation messages to SDL
		//this resyncs the mouse position immediately, and fixes the OS X cursor remaining visible until moved
		boxer_SDLGrabInput();
	}
}

- (BOOL) mouseLocked
{
	BOOL isLocked = NO;
	if ([self isExecuting])
	{
		isLocked = (SDL_WM_GrabInput(SDL_GRAB_QUERY) == SDL_GRAB_ON);
	}
	return isLocked;
}



//Controlling emulation state
//---------------------------

- (NSUInteger) frameskip
{
	NSUInteger frameskip = 0;
	if ([self isExecuting])
	{
		frameskip = (NSUInteger)render.frameskip.max;
	}
	return frameskip; 
}

- (void) setFrameskip: (NSUInteger)frameskip
{
	if ([self isExecuting])
	{
		render.frameskip.max = (Bitu)frameskip;
	}
}

- (BOOL) validateFrameskip: (id *)ioValue error: (NSError **)outError
{
	NSInteger theValue = [*ioValue integerValue];
	if		(theValue < 0)						*ioValue = [NSNumber numberWithInteger: 0];
	else if	(theValue > [self maxFrameskip])	*ioValue = [NSNumber numberWithInteger: [self maxFrameskip]];
	return YES;
}



- (NSInteger) fixedSpeed
{
	NSInteger fixedSpeed = 0;
	if ([self isExecuting])
	{
		fixedSpeed = (NSInteger)CPU_CycleMax;
	}
	return fixedSpeed;
}

- (void) setFixedSpeed: (NSInteger)newSpeed
{
	if ([self isExecuting])
	{
		//Turn off automatic speed scaling
		[self setAutoSpeed: NO];
	
		CPU_OldCycleMax = CPU_CycleMax = (Bit32s)newSpeed;
		
		//Wipe out the cycles queue - we do this because DOSBox's CPU functions do whenever they modify the cycles
		CPU_CycleLeft	= 0;
		CPU_Cycles		= 0;
	}
}

- (BOOL) validateFixedSpeed: (id *)ioValue error: (NSError **)outError
{
	NSInteger	min = [self minFixedSpeed],
				max	= [self maxFixedSpeed],
				theValue = [*ioValue integerValue];
	if		(theValue < min) *ioValue = [NSNumber numberWithInteger: min];
	else if	(theValue > max) *ioValue = [NSNumber numberWithInteger: max];
	return YES;
}

- (BOOL) isAutoSpeed
{
	BOOL autoSpeed = NO;
	if ([self isExecuting])
	{
		autoSpeed = (CPU_CycleAutoAdjust == BXSpeedAuto);
	}
	return autoSpeed;
}

- (void) setAutoSpeed: (BOOL)autoSpeed
{
	if ([self isExecuting] && [self isAutoSpeed] != autoSpeed)
	{
		//Be a good boy and record/restore the old cycles setting
		if (autoSpeed)	CPU_OldCycleMax = CPU_CycleMax;
		else			CPU_CycleMax = CPU_OldCycleMax;
		
		//Always force the usage percentage to 100
		CPU_CyclePercUsed = 100;
		
		CPU_CycleAutoAdjust = (autoSpeed) ? BXSpeedAuto : BXSpeedFixed;
	}
}


//CPU emulation
//-------------

//Note: these work but are currently unused. This is because this implementation is just too simple; games may crash when the emulation mode is arbitrarily changed in the middle of program execution, so instead we should queue this up and require an emulation restart for it to take effect.
- (BXCoreMode) coreMode
{
	BXCoreMode coreMode = BXCoreUnknown;
	if ([self isExecuting])
	{
		coreMode = boxer_CPUMode();
	}
	return coreMode;
}
- (void) setCoreMode: (BXCoreMode)coreMode
{
	if ([self isExecuting] && [self coreMode] != coreMode)
	{
		//We change the core by feeding command settings to Config
		NSString *modeName;
		switch(coreMode)
		{
			case BXCoreNormal:	modeName = @"normal";	break;
			case BXCoreDynamic:	modeName = @"dynamic";	break;
			case BXCoreSimple:	modeName = @"simple";	break;
			case BXCoreFull:	modeName = @"full";		break;
		}
		if (modeName)
		{
			NSInteger currentSpeed		= [self fixedSpeed];
			BOOL currentSpeedIsAuto		= [self isAutoSpeed];
			
			[self setConfig: @"core" to: modeName];
			
			//Changing the core mode will revert the speed settings, so we need to reset them manually afterwards
			//Todo: try to avoid the momentary flash of old values this causes
			[self setFixedSpeed: currentSpeed];
			[self setAutoSpeed: currentSpeedIsAuto];
		}
	}
}
- (BOOL) isDynamic	{ return [self coreMode] == BXCoreDynamic; }

//Todo: make this use the previous core mode, instead of just assuming normal
- (void) setDynamic: (BOOL)dynamic
{
	[self setCoreMode: ([self coreMode] == BXCoreDynamic) ? BXCoreNormal : BXCoreDynamic];
}


//Handling changes to application focus
//-------------------------------------

- (void) captureInput
{
	if ([self isExecuting])
	{ 
		boxer_SDLGrabInput();
	}
}

- (void) releaseInput
{
	if ([self isExecuting])
	{
		boxer_SDLReleaseInput();
		[self setMouseLocked: NO];
	}
}

- (void) activate
{
	if ([self isExecuting])
	{
		currentEmulator = self;
		boxer_SDLActivateApp();
	}
}

- (void) deactivate
{
	if ([self isExecuting])
	{
		boxer_SDLDeactivateApp();
	}
}


//These methods are only necessary if we are running in single-threaded mode,
//which currently is indicated by the isConcurrent flag
- (void) willPause
{
	
	if ([self isConcurrent] && [self isExecuting] && !isInterrupted)
	{
		SDL_PauseAudio(YES);
		boxer_toggleMIDIOutput(NO);
		isInterrupted = YES;
	}
}

- (void) didResume
{
	
	if ([self isConcurrent] && [self isExecuting] && isInterrupted)
	{
		SDL_PauseAudio(NO);
		boxer_toggleMIDIOutput(YES);
		isInterrupted = NO;
	}
}

- (void) cancel
{
	DOS_Shell *shell = [self _currentShell];
	if (shell) shell->exit = YES;
	[super cancel];
}
@end


@implementation BXEmulator (BXEmulatorInternals)

- (DOS_Shell *) _currentShell
{
	return (DOS_Shell *)first_shell;
}

- (void) _postNotificationName: (NSString *)name
			  delegateSelector: (SEL)selector
					  userInfo: (id)userInfo
{
	NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
	NSNotification *notification = [NSNotification notificationWithName: name
																 object: self
															   userInfo: userInfo];
	
	BXSession *theSession = [self delegate];
	if (theSession && [theSession respondsToSelector: selector]) [theSession performSelector: selector withObject: notification];
	
	[center postNotification: notification];
}

- (void) _applyConfiguration
{
	[self _postNotificationName: @"BXEmulatorWillLoadConfigurationNotification"
			   delegateSelector: @selector(willLoadConfiguration:)
					   userInfo: nil];
	
	for (NSString *configPath in [self configFiles])
	{
		configPath = [configPath stringByStandardizingPath];
		const char * encodedConfigPath = [configPath cStringUsingEncoding: BXDirectStringEncoding];
		control->ParseConfigFile((const char * const)encodedConfigPath);
	}

	[self _postNotificationName: @"BXEmulatorDidLoadConfigurationNotification"
			   delegateSelector: @selector(didLoadConfiguration:)
					   userInfo: nil];
}


//Synchronising emulation state
//-----------------------------

//Post change notifications on all likely properties to resync KVC bindings
//This is called by coalface functions to notify Boxer that the emulation state may have changed behind its back
- (void) _syncWithEmulationState
{
	if ([self isExecuting])
	{
		//Post event notifications for settings we have no way of detecting changes to,
		//so that all bound objects will update just in case
		[self willChangeValueForKey:	@"mouseLocked"];
		[self didChangeValueForKey:		@"mouseLocked"];
		
		[self willChangeValueForKey:	@"fixedSpeed"];
		[self didChangeValueForKey:		@"fixedSpeed"];
		
		[self willChangeValueForKey:	@"autoSpeed"];
		[self didChangeValueForKey:		@"autoSpeed"];
		
		[self willChangeValueForKey:	@"frameskip"];
		[self didChangeValueForKey:		@"frameskip"];
		
		[self willChangeValueForKey:	@"coreMode"];
		[self didChangeValueForKey:		@"coreMode"];
		
		
		//Now perform fine-grained checking on the process name, and post appropriate notifications
		
		NSString *newProcessName = [NSString stringWithCString: RunningProgram encoding: BXDirectStringEncoding];
		if ([newProcessName isEqualToString: shellProcessName]) newProcessName = nil;
		[self setProcessName: newProcessName];
		
		//Update our max fixed speed if the real speed has gone higher
		//this allows us to gracefully handle extra-high speeds imposed by game settings
		//Disabled for now, since we have implemented the banded CPU slider any adjustments to the max speed will fuck with its shit - will reenable this when I write code to sync changes to this with the highest slider band
		
		//NSInteger newFixedSpeed = [self fixedSpeed];
		//if (newFixedSpeed > [self maxFixedSpeed]) [self setMaxFixedSpeed: newFixedSpeed];
	}
}


//Threading
//---------

- (BOOL) _executingOnDOSBoxThread	{ return ([NSThread currentThread] == thread); }
- (void) _performSelectorOnDOSBoxThread:(SEL)selector withObject:(id)arg waitUntilDone:(BOOL)wait
{
	[self performSelector: selector onThread: thread withObject: arg waitUntilDone: wait];
}

//Event-handling
//--------------

- (BOOL) _handleEventLoop
{
	return NO;
}

- (BOOL) _handleRunLoop
{
	if ([self isCancelled]) return YES;
	if ([[self commandQueue] count] && [self isAtPrompt]) return YES;
	return NO;
}

@end


//Return the current DOSBox core mode
BXCoreMode boxer_CPUMode()
{
	if (cpudecoder == &CPU_Core_Normal_Run ||
		cpudecoder == &CPU_Core_Normal_Trap_Run)	return BXCoreNormal;
	
#if (C_DYNAMIC_X86)
	if (cpudecoder == &CPU_Core_Dyn_X86_Run ||
		cpudecoder == &CPU_Core_Dyn_X86_Trap_Run)	return BXCoreDynamic;
#endif
	
#if (C_DYNREC)
	if (cpudecoder == &CPU_Core_Dynrec_Run ||
		cpudecoder == &CPU_Core_Dynrec_Trap_Run)	return BXCoreDynamic;
#endif
	
	if (cpudecoder == &CPU_Core_Simple_Run)			return BXCoreSimple;
	if (cpudecoder == &CPU_Core_Full_Run)			return BXCoreFull;
	
	return BXCoreUnknown;
}


//Bridge functions
//----------------
//DOSBox uses these to call relevant methods on the current Boxer emulation context

//This is called at the start of GFX_Events in DOSBox's sdlmain.cpp, to allow us to perform initial actions every time the event loop runs. Return YES to skip the event loop.
bool boxer_handleEventLoop()
{
	BXEmulator *emulator = [BXEmulator currentEmulator];
	return [emulator _handleEventLoop];
}

//This is called at the start of DOSBox_NormalLoop, and allows us to short-circuit the current run loop if needed.
bool boxer_handleRunLoop()
{
	BXEmulator *emulator = [BXEmulator currentEmulator];
	return [emulator _handleRunLoop];	
}

//Catch SDL events and process them - return YES if we've handled the event, NO if we want to let it go through
//This is called by GFX_Events in DOSBox's sdlmain.cpp, to allow us to hook into the main event loop
bool boxer_handleSDLEvent(SDL_Event *event)
{
	return NO;
}

//Notifies Boxer of changes to title and speed settings
//This is called by GFX_SetTitle in DOSBox's sdlmain.cpp, instead of trying to set the window title through SDL
bool boxer_handleDOSBoxTitleChange(int newCycles, int newFrameskip, bool newPaused)
{
	BXEmulator *emulator = [BXEmulator currentEmulator];
	[emulator _syncWithEmulationState];
	return YES;
}

void boxer_applyConfigFiles()
{
	BXEmulator *emulator = [BXEmulator currentEmulator];
	[emulator _applyConfiguration];
}

bool boxer_isCancelled()
{
	BXEmulator *emulator = [BXEmulator currentEmulator];
	return [emulator isCancelled];	
}