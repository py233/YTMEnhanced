#import "YTMUWeakProxy.h"

@implementation YTMUWeakProxy {
    __weak id _target;
}

+ (instancetype)proxyWithTarget:(id)target {
    YTMUWeakProxy *proxy = [self alloc]; // NSProxy has no -init
    proxy->_target = target;
    return proxy;
}

- (id)forwardingTargetForSelector:(SEL)selector {
    return _target;
}

- (NSMethodSignature *)methodSignatureForSelector:(SEL)selector {
    // Only reached once the target is gone (the fast path above handles the
    // live case). Hand back any valid signature so the runtime can build an
    // invocation we then drop in -forwardInvocation:.
    return [_target methodSignatureForSelector:selector] ?: [NSMethodSignature signatureWithObjCTypes:"v@:"];
}

- (void)forwardInvocation:(NSInvocation *)invocation {
    id target = _target;
    if (target) [invocation invokeWithTarget:target];
}

- (BOOL)respondsToSelector:(SEL)selector {
    return [_target respondsToSelector:selector];
}

@end
