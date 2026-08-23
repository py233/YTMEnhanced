#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Collapses concurrent requests for the same key into one piece of work:
// the first caller starts it, later callers for the same key just queue
// their completion, and whoever finishes hands every queued completion the
// same result. Thread-safe. Replaces three hand-rolled copies of the same
// @synchronized dictionary.
@interface YTMUInflightCoalescer<__covariant Completion> : NSObject

// Returns YES if `completion` is the first for `key` (the caller must do
// the work and later call -takeCompletionsForKey:), NO if it was queued
// behind an in-flight request.
- (BOOL)beginOrJoinKey:(NSString *)key completion:(Completion)completion;

// Removes and returns every completion queued for `key` (possibly empty).
- (NSArray<Completion> *)takeCompletionsForKey:(NSString *)key;

@end

NS_ASSUME_NONNULL_END
