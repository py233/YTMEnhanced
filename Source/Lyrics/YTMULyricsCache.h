#import <Foundation/Foundation.h>
#import "YTMULyricsTypes.h"

NS_ASSUME_NONNULL_BEGIN

@interface YTMULyricsCache : NSObject
+ (instancetype)sharedCache;
+ (NSString *)cacheKeyForInfo:(YTMULyricsSearchInfo *)info source:(NSString *)source;
- (nullable YTMULyricsResult *)resultForKey:(NSString *)key;
- (void)storeResult:(YTMULyricsResult *)result forKey:(NSString *)key;
- (NSUInteger)clearAll;
@end

NS_ASSUME_NONNULL_END
