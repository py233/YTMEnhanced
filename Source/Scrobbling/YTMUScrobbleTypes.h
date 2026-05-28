#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - Notifications

// Posted by YTMUPlaybackBroadcaster when the currently-playing track
// changes. userInfo carries the YTMUListen for the new track (key
// kYTMUPlaybackUserInfoListen), and the previously-playing listen if
// any (key kYTMUPlaybackUserInfoPreviousListen) — that previous one
// is what the scrobble manager evaluates against the threshold.
extern NSNotificationName const YTMUPlaybackTrackChangedNotification;

// Posted on play/pause transitions. userInfo[@"isPlaying"] = @(BOOL).
extern NSNotificationName const YTMUPlaybackStateChangedNotification;

extern NSString *const kYTMUPlaybackUserInfoListen;
extern NSString *const kYTMUPlaybackUserInfoPreviousListen;
extern NSString *const kYTMUPlaybackUserInfoElapsedSeconds;
extern NSString *const kYTMUPlaybackUserInfoIsPlaying;

#pragma mark - Listen value type

// Snapshot of one track's metadata at the moment we observed it. The
// scrobble manager creates one of these when a track starts playing,
// then later mutates `elapsedPlayedSeconds` as accumulation goes on
// and reads `listenedAt` (unix seconds) when actually submitting.
@interface YTMUListen : NSObject <NSCopying>

@property (nonatomic, copy, nullable) NSString *trackName;
@property (nonatomic, copy, nullable) NSString *artist;
@property (nonatomic, copy, nullable) NSString *albumName;

// Duration in seconds. 0 means unknown.
@property (nonatomic) NSTimeInterval durationSeconds;

// Unix timestamp (seconds) at which playback started. Filled in when
// a YTMUListen is constructed from the broadcaster — used as the
// `timestamp` for last.fm scrobble and `listened_at` for ListenBrainz.
@property (nonatomic) NSTimeInterval startedAtUnix;

// Total real-time seconds the user has actually heard so far (does
// not advance while paused). Used against the scrobble threshold.
@property (nonatomic) NSTimeInterval elapsedPlayedSeconds;

// Optional. YT Music's video id; included in ListenBrainz
// additional_info.origin_url ("https://music.youtube.com/watch?v=…").
@property (nonatomic, copy, nullable) NSString *videoId;

// Returns YES if elapsedPlayedSeconds has reached the scrobble
// threshold, defined as min(duration/2, 240s) when duration > 30s.
// Tracks shorter than 30s are never scrobble-eligible (last.fm rule).
- (BOOL)hasReachedScrobbleThreshold;

// Returns YES when track + artist are both non-empty — required by
// both last.fm and ListenBrainz APIs.
- (BOOL)hasMinimumMetadata;

- (NSDictionary<NSString *, id> *)serialize;
+ (nullable instancetype)deserialize:(NSDictionary<NSString *, id> *)dict;

@end

#pragma mark - Scrobbler provider protocol

typedef void (^YTMUScrobblerCompletion)(BOOL success, NSError *_Nullable error);

@protocol YTMUScrobbler <NSObject>

// Stable identifier (e.g. @"lastfm", @"listenbrainz") used in logs
// and offline-queue serialization.
- (NSString *)identifier;

// Master enable toggle for this provider (read from NSUserDefaults).
- (BOOL)isEnabled;

// Returns YES when credentials are valid enough to attempt a submit.
// Used to skip silently when the user hasn't set the provider up.
- (BOOL)isConfigured;

// Fire "now playing" for the current track. No-op if !isEnabled or
// !isConfigured. Errors are logged but never block the caller.
- (void)submitNowPlaying:(YTMUListen *)listen;

// Submit a single completed scrobble. completion runs on an
// arbitrary queue; pass success=NO with error to indicate failure
// — the manager retries via offline queue.
- (void)submitScrobble:(YTMUListen *)listen
            completion:(YTMUScrobblerCompletion)completion;

// Submit a batch of pending scrobbles in one request (used to flush
// the offline queue). Order matters — older first.
- (void)submitBatch:(NSArray<YTMUListen *> *)listens
         completion:(YTMUScrobblerCompletion)completion;

@end

#pragma mark - Defaults helpers

// Read a string out of NSUserDefaults["YTMUltimate"][key]. Returns
// fallback if absent or wrong type. Trims whitespace.
NSString *YTMUScrobbleDefaultsString(NSString *key, NSString *fallback);

// Same shape as above for BOOL keys.
BOOL YTMUScrobbleDefaultsBool(NSString *key, BOOL fallback);

// Write a value back into NSUserDefaults["YTMUltimate"][key]. nil
// value removes the key.
void YTMUScrobbleSetDefaults(NSString *key, id _Nullable value);

#pragma mark - Logging

// Same shape as YTMULyricsLog / YTMUTranslationLog. Gated on the
// `scrobbleDebugLogs` defaults key (default YES — flip to NO once
// shipping). Format string is required.
void YTMUScrobbleLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);

NS_ASSUME_NONNULL_END
