#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Forwards every message to a weakly-held target. Use it as the `target` of
// CADisplayLink / NSTimer so the run loop does not keep the real object
// alive: without this, run loop → link → target is a cycle the target's
// -dealloc can never break because -dealloc never runs.
@interface YTMUWeakProxy : NSProxy
+ (instancetype)proxyWithTarget:(id)target;
@end

NS_ASSUME_NONNULL_END
