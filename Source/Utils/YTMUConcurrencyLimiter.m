#import "YTMUConcurrencyLimiter.h"

@interface YTMUConcurrencyLimiter ()
@property (nonatomic) NSUInteger count;
@property (nonatomic) NSUInteger nextIndex;
@property (nonatomic) NSUInteger finished;
@property (nonatomic, copy, nullable) BOOL (^shouldStart)(void);
@property (nonatomic, copy) void (^work)(NSUInteger index, dispatch_block_t done);
@property (nonatomic, copy) dispatch_block_t completion;
@property (nonatomic, strong) NSLock *lock;
@end

@implementation YTMUConcurrencyLimiter

+ (void)runItems:(NSUInteger)count
     concurrency:(NSUInteger)concurrency
     shouldStart:(BOOL (^)(void))shouldStart
            work:(void (^)(NSUInteger, dispatch_block_t))work
      completion:(dispatch_block_t)completion {
    if (count == 0) { if (completion) completion(); return; }
    YTMUConcurrencyLimiter *limiter = [[self alloc] init];
    limiter.count = count;
    limiter.shouldStart = shouldStart;
    limiter.work = work;
    limiter.completion = completion;
    limiter.lock = [[NSLock alloc] init];
    // The in-flight `done` blocks retain the limiter; it lives exactly as
    // long as the batch.
    for (NSUInteger i = 0; i < MIN(MAX(concurrency, (NSUInteger)1), count); i++) [limiter startNext];
}

- (void)startNext {
    [self.lock lock];
    if (self.nextIndex >= self.count) { [self.lock unlock]; return; }
    NSUInteger index = self.nextIndex++;
    [self.lock unlock];

    if (self.shouldStart && !self.shouldStart()) {
        [self itemFinished];
        return;
    }
    __block BOOL called = NO;
    __weak typeof(self) weakSelf = self;
    void (^done)(void) = ^{
        // Tolerate a sloppy worker calling done twice; count it once.
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf.lock lock];
        BOOL first = !called; called = YES;
        [strongSelf.lock unlock];
        if (first) [strongSelf itemFinished];
    };
    // Keep self alive for the duration of the work via the done block's
    // strong reference below.
    typeof(self) strongForWork = self;
    self.work(index, ^{ (void)strongForWork; done(); });
}

- (void)itemFinished {
    [self.lock lock];
    self.finished++;
    BOOL all = self.finished >= self.count;
    [self.lock unlock];
    if (all) {
        dispatch_block_t completion = self.completion;
        self.completion = nil;
        if (completion) completion();
    } else {
        [self startNext];
    }
}

@end
