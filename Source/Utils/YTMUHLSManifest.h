#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Picks the audio rendition URL out of a YouTube HLS master playlist.
// YouTube labels its audio renditions GROUP-ID "234" (higher quality) and
// "233"; the first 234 entry wins, then 233. Returns nil when neither is
// present. Pure string parsing — no network.
NSString *_Nullable YTMUHLSAudioStreamURLFromManifest(NSString *_Nullable manifest);

NS_ASSUME_NONNULL_END
