#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Runs `count` asynchronous work items with at most `concurrency` in flight,
// without parking a thread: each item is started from the completion of a
// previous one. `shouldStart` (optional) is consulted before every start;
// once it returns NO the remaining items are skipped (counted as done) so
// a batch can be abandoned cheaply when its result is no longer wanted.
// `completion` runs exactly once, on an arbitrary queue, after every item
// has either called its `done` block or been skipped.
@interface YTMUConcurrencyLimiter : NSObject

+ (void)runItems:(NSUInteger)count
     concurrency:(NSUInteger)concurrency
     shouldStart:(nullable BOOL (^)(void))shouldStart
            work:(void (^)(NSUInteger index, dispatch_block_t done))work
      completion:(dispatch_block_t)completion;

@end

NS_ASSUME_NONNULL_END
