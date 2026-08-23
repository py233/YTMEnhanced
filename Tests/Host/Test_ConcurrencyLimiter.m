#import "YTMUTestKit.h"
#import "Utils/YTMUConcurrencyLimiter.h"
#import <stdatomic.h>

YTMU_TEST(ConcurrencyLimiter_capsInFlight_runsAll_completesOnce) {
    static _Atomic int inflight = 0, maxInflight = 0, done = 0, completions = 0;
    atomic_store(&inflight, 0); atomic_store(&maxInflight, 0); atomic_store(&done, 0); atomic_store(&completions, 0);
    __block BOOL finished = NO;
    [YTMUConcurrencyLimiter runItems:25 concurrency:6 shouldStart:nil
        work:^(NSUInteger index, dispatch_block_t itemDone) {
            int now = atomic_fetch_add(&inflight, 1) + 1;
            int m; do { m = atomic_load(&maxInflight); } while (now > m && !atomic_compare_exchange_weak(&maxInflight, &m, now));
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((5 + arc4random_uniform(20)) * NSEC_PER_MSEC)),
                           dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
                atomic_fetch_sub(&inflight, 1);
                atomic_fetch_add(&done, 1);
                itemDone();
            });
        } completion:^{ atomic_fetch_add(&completions, 1); finished = YES; }];
    YTMU_ASSERT(YTMUTestWaitUntil(5, ^BOOL{ return finished; }), "batch never completed");
    YTMU_ASSERT_EQ_INT(atomic_load(&done), 25);
    YTMU_ASSERT(atomic_load(&maxInflight) <= 6, "more than 6 in flight: %d", atomic_load(&maxInflight));
    YTMU_ASSERT(atomic_load(&maxInflight) >= 2, "concurrency never exceeded 1: %d", atomic_load(&maxInflight));
    YTMUTestWaitUntil(0.2, ^BOOL{ return NO; });
    YTMU_ASSERT_EQ_INT(atomic_load(&completions), 1);
}

YTMU_TEST(ConcurrencyLimiter_shouldStartNo_skipsRemaining_stillCompletes) {
    __block NSUInteger started = 0; __block BOOL finished = NO; __block BOOL allow = YES;
    [YTMUConcurrencyLimiter runItems:30 concurrency:3 shouldStart:^BOOL{ return allow; }
        work:^(NSUInteger index, dispatch_block_t itemDone) {
            started++;
            if (started == 4) allow = NO;   // "user skipped the song"
            dispatch_async(dispatch_get_main_queue(), itemDone);
        } completion:^{ finished = YES; }];
    YTMU_ASSERT(YTMUTestWaitUntil(3, ^BOOL{ return finished; }), "batch never completed after cancel");
    YTMU_ASSERT(started <= 4 + 3, "too many items started after cancel: %lu", (unsigned long)started);
}

YTMU_TEST(ConcurrencyLimiter_zeroItems_completesImmediately) {
    __block BOOL finished = NO;
    [YTMUConcurrencyLimiter runItems:0 concurrency:4 shouldStart:nil work:^(NSUInteger i, dispatch_block_t d) { d(); } completion:^{ finished = YES; }];
    YTMU_ASSERT(finished, "zero items must complete synchronously");
}
