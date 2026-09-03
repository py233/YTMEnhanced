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

// Idempotent. The scrobble manager starts the poll only while
// scrobbling is switched on and stops it when the user switches it off.
- (void)start;

// Stops the poll and forgets the observed track, so a later start does
// not report the song that was playing at the time as a "previous"
// track.
- (void)stop;

- (BOOL)isRunning;

@end

NS_ASSUME_NONNULL_END
