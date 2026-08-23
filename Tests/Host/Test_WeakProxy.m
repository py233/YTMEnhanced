#import <UIKit/UIKit.h>
#import "YTMUTestKit.h"
#import "Utils/YTMUWeakProxy.h"

@interface YTMUProxyTickTarget : NSObject
@property (nonatomic) NSUInteger ticks;
- (void)tick:(id)sender;
@end
@implementation YTMUProxyTickTarget
- (void)tick:(id)sender { self.ticks++; }
@end

static void Spin(NSTimeInterval s) {
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:s];
    while ([until timeIntervalSinceNow] > 0) [[NSRunLoop mainRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
}

YTMU_TEST(WeakProxy_forwardsWhileTargetAlive_andIsInertAfterwards) {
    __weak YTMUProxyTickTarget *weakTarget = nil;
    CADisplayLink *link = nil;
    @autoreleasepool {
        YTMUProxyTickTarget *target = [[YTMUProxyTickTarget alloc] init];
        weakTarget = target;
        link = [CADisplayLink displayLinkWithTarget:[YTMUWeakProxy proxyWithTarget:target] selector:@selector(tick:)];
        [link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
        Spin(0.3);
        YTMU_ASSERT(target.ticks > 0, "display link never reached the target through the proxy");
        target = nil;
    }
    YTMU_ASSERT(weakTarget == nil, "proxy must not retain its target");
    // Link still scheduled, target gone: must keep firing harmlessly.
    YTMU_ASSERT_NO_THROW(Spin(0.2));
    [link invalidate];
}

YTMU_TEST(WeakProxy_respondsToSelector_tracksTarget) {
    YTMUProxyTickTarget *target = [[YTMUProxyTickTarget alloc] init];
    id proxy = [YTMUWeakProxy proxyWithTarget:target];
    YTMU_ASSERT([proxy respondsToSelector:@selector(tick:)], "should forward respondsToSelector:");
    YTMU_ASSERT(![proxy respondsToSelector:@selector(removeFromSuperview)], "should not claim selectors the target lacks");
}
