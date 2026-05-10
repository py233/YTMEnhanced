#import "../YTMULyricsTypes.h"

NS_ASSUME_NONNULL_BEGIN

// Synthetic provider that surfaces lyrics pasted by the uploader into
// the YouTube video description block (very common for Japanese doujin
// / Vocaloid producers). Always last in the chain. Plain text only —
// no timestamps, since descriptions don't carry sync info.
@interface YTMUDescriptionProvider : NSObject <YTMULyricsProvider>
@end

NS_ASSUME_NONNULL_END
