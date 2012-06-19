/* 
 Boxer is copyright 2011 Alun Bestor and contributors.
 Boxer is released under the GNU General Public License 2.0. A full copy of this license can be
 found in this XCode project at Resources/English.lproj/BoxerHelp/pages/legalese.html, or read
 online at [http://www.gnu.org/licenses/gpl-2.0.txt].
 */


#import "BXImportDropzonePanelController.h"
#import "BXImportWindowController.h"
#import "BXImportDropzone.h"
#import "BXImportSession.h"
#import "BXBlueprintPanel.h"
#import "BXAppController.h"


#pragma mark -
#pragma mark Private method declarations

@interface BXImportDropzonePanelController ()

@end


@implementation BXImportDropzonePanelController
@synthesize dropzone, controller, spinner;

#pragma mark -
#pragma mark Initialization and deallocation

- (void) awakeFromNib
{
	//Set up the dropzone panel to support drag-drop operations
	[[self view] registerForDraggedTypes: [NSArray arrayWithObjects: NSFilenamesPboardType, nil]];
	
	[[self spinner] setUsesThreadedAnimation: YES];
	//Since the spinner is on a separate view that's only added to the window
	//when it's spinnin' time, we can safely start it animating now
	[[self spinner] startAnimation: self];
}

- (void) dealloc
{
	[self setDropzone: nil], [dropzone release];
	[self setSpinner: nil], [spinner release];
	
	[super dealloc];
}


#pragma mark -
#pragma mark UI actions

- (IBAction) showImportPathPicker: (id)sender
{
	NSOpenPanel *openPanel	= [NSOpenPanel openPanel];
	
    openPanel.delegate = self;
    openPanel.canChooseFiles = YES;
    openPanel.canChooseDirectories = YES;
    openPanel.treatsFilePackagesAsDirectories = NO;
    openPanel.message = NSLocalizedString(@"Choose a DOS game folder, CD-ROM or disc image to import:",
                                          @"Help text shown at the top of choose-a-folder-to-import panel.");
    
    openPanel.prompt = NSLocalizedString(@"Import",
                                         @"Label shown on accept button in choose-a-folder-to-import panel.");
	
    openPanel.allowedFileTypes = [BXImportSession acceptedSourceTypes].allObjects;
    
    [openPanel beginSheetModalForWindow: self.view.window
                      completionHandler: ^(NSInteger result) {
                          if (result == NSOKButton)
                          {
                              NSString *path = openPanel.URL.path;
                              
                              //Because an error sheet may be displayed from importFromSourcePath, we close the panel first
                              [openPanel close];
                              
                              [self.controller.document importFromSourcePath: path];
                          }
                      }];
}

- (IBAction) showImportDropzoneHelp: (id)sender
{
	[[NSApp delegate] showHelpAnchor: @"import-drop-game"];
}


#pragma mark -
#pragma mark Drag-drop handlers

- (NSDragOperation) draggingEntered: (id <NSDraggingInfo>)sender
{
	NSPasteboard *pboard = [sender draggingPasteboard];
	if ([[pboard types] containsObject: NSFilenamesPboardType])
	{
		NSArray *filePaths = [pboard propertyListForType: NSFilenamesPboardType];
		BXImportSession *importer = [[self controller] document];
		for (NSString *path in filePaths)
		{
			//If any of the dropped files cannot be imported, reject the drop
			if (![[importer class] canImportFromSourcePath: path]) return NSDragOperationNone;
		}
		
		[[self dropzone] setHighlighted: YES];
		return NSDragOperationCopy;
	}
	else return NSDragOperationNone;
}

- (BOOL) performDragOperation: (id <NSDraggingInfo>)sender
{	
	[[self dropzone] setHighlighted: NO];
	NSPasteboard *pboard = [sender draggingPasteboard];
	
    if ([[pboard types] containsObject: NSFilenamesPboardType])
	{
        NSArray *filePaths = [pboard propertyListForType: NSFilenamesPboardType];
		BXImportSession *importer = [[self controller] document];
		for (NSString *path in filePaths)
		{
			if ([[importer class] canImportFromSourcePath: path])
			{
				//Defer import to give the drag operation and animations time to clean up
				[importer performSelector: @selector(importFromSourcePath:) withObject: path afterDelay: 0.5];
				return YES;
			}
		}
	}
	return NO;
}

- (void)draggingExited: (id <NSDraggingInfo>)sender
{
	[[self dropzone] setHighlighted: NO];
}

@end