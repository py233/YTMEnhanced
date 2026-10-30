#import <Foundation/Foundation.h>
#import "YTMULyricsTypes.h"

NS_ASSUME_NONNULL_BEGIN

NSArray<YTMULyricLine *> *_Nullable YTMUWordLyricsParseTTML(NSString *ttml);
YTMULyricsResult *_Nullable YTMUWordLyricsResultFromSpicyJSON(NSDictionary *json,
                                                               YTMULyricsSearchInfo *info,
                                                               NSString *sourceName);

NS_ASSUME_NONNULL_END
