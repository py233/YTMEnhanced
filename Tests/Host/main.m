#import "YTMUTestKit.h"
#import "YTMUTestSettings.h"
int main(void) {
    @autoreleasepool {
        YTMUTestResetDefaultsDomain();
        NSUInteger failed = YTMUTestRunAll();
        YTMUTestResetDefaultsDomain();
        return failed ? 1 : 0;
    }
}
