#import "YTMUInflightCoalescer.h"

@implementation YTMUInflightCoalescer {
    NSMutableDictionary<NSString *, NSMutableArray *> *_queues;
}

- (instancetype)init {
    self = [super init];
    if (self) _queues = [NSMutableDictionary dictionary];
    return self;
}

- (BOOL)beginOrJoinKey:(NSString *)key completion:(id)completion {
    id copied = [completion copy];   // blocks must be copied off the stack
    @synchronized (_queues) {
        NSMutableArray *queue = _queues[key];
        if (queue) {
            [queue addObject:copied];
            return NO;
        }
        _queues[key] = [NSMutableArray arrayWithObject:copied];
        return YES;
    }
}

- (NSArray *)takeCompletionsForKey:(NSString *)key {
    @synchronized (_queues) {
        NSArray *completions = [_queues[key] copy] ?: @[];
        [_queues removeObjectForKey:key];
        return completions;
    }
}

@end
