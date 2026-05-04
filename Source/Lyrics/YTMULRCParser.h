#import <Foundation/Foundation.h>
#import "YTMULyricsTypes.h"

NS_ASSUME_NONNULL_BEGIN

@interface YTMULRCParser : NSObject
+ (NSArray<YTMULyricLine *> *)parseLRC:(NSString *)text;
+ (NSArray<NSString *> *)plainLinesFromLyrics:(NSString *)lyrics;
+ (NSString *)stripNetEaseMetadata:(NSString *)lyrics;
@end

NS_ASSUME_NONNULL_END
