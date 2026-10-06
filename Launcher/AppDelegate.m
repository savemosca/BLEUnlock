#import "AppDelegate.h"

@interface AppDelegate ()
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
    NSString *id = [[NSBundle mainBundle] bundleIdentifier];
    NSString *mainId = [id stringByReplacingOccurrencesOfString:@".Launcher" withString:@""];
    if ([NSRunningApplication runningApplicationsWithBundleIdentifier:mainId].count > 0) {
        [NSApp terminate:self];
    }

    NSString *path = [[NSBundle mainBundle] bundlePath];
    NSMutableArray *components = [NSMutableArray arrayWithArray:[path pathComponents]];
    [components removeLastObject];
    [components removeLastObject];
    [components removeLastObject];
    [components removeLastObject];
    NSURL *mainURL = [NSURL fileURLWithPath:[NSString pathWithComponents:components]];
    [[NSWorkspace sharedWorkspace] openApplicationAtURL:mainURL
                                          configuration:[NSWorkspaceOpenConfiguration configuration]
                                      completionHandler:^(NSRunningApplication *app, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [NSApp terminate:self];
        });
    }];
}

- (void)applicationWillTerminate:(NSNotification *)aNotification {
}

@end
