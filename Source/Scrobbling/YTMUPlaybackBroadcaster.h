#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Singleton. Polls MPNowPlayingInfoCenter every ~1 second once
// `start` has been called and emits the two notifications declared
// in YTMUScrobbleTypes.h:
//
//   YTMUPlaybackTrackChangedNotification  - on track switch
//   YTMUPlaybackStateChangedNotification  - on play/pause transition
//
// Decoupled from SyncedLyrics.x's hook chain by design: callers
// observing these notifications don't need to know how the metadata
// got captured, and we don't add new edits to SyncedLyrics.x.
@interface YTMUPlaybackBroadcaster : NSObject

+ (instancetype)sharedBroadcaster;

// Idempotent. Safe to call from `+load` of YTMUScrobbleManager.
- (void)start;

// Only exposed for tests / manual debugging.
- (void)stop;

@end

NS_ASSUME_NONNULL_END
