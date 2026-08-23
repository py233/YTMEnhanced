// The suite runs inside a real UIApplication (Mac Catalyst) so UIKit code
// under test — windows, display links, layout — behaves as on device.
#import <UIKit/UIKit.h>
#import "YTMUTestKit.h"
#import "YTMUTestSettings.h"

@interface YTMUTestAppDelegate : UIResponder <UIApplicationDelegate>
@end

@implementation YTMUTestAppDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    // Kick the suite off from a run-loop timer rather than a main-queue
    // block: tests spin the run loop while waiting for completions that
    // arrive via dispatch_async(main), and the main queue is serial — it
    // would not drain those blocks while one of its own blocks (this one)
    // is still executing.
    [self performSelector:@selector(runSuite) withObject:nil afterDelay:0];
    return YES;
}

- (void)runSuite {
    YTMUTestResetDefaultsDomain();
    NSUInteger failed = YTMUTestRunAll();
    YTMUTestResetDefaultsDomain();
    fflush(stdout);
    exit(failed ? 1 : 0);
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([YTMUTestAppDelegate class]));
    }
}
