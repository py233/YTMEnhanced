#import <Foundation/Foundation.h>
#import "YTMUScrobbleTypes.h"

NS_ASSUME_NONNULL_BEGIN

@class YTMULastFMScrobbler;
@class YTMUListenBrainzScrobbler;

// Central coordinator. Subscribes to YTMUPlaybackBroadcaster
// notifications, decides when to fire now-playing vs scrobble, and
// routes those calls to all enabled providers. Also owns the
// offline retry queue (one queue, shared across providers — each
// pending entry stores which provider it's for).
@interface YTMUScrobbleManager : NSObject

+ (instancetype)sharedManager;

// Concrete providers exposed for the settings UI to call the
// per-provider auth flows on. The manager itself only ever uses
// them through the YTMUScrobbler protocol.
@property (nonatomic, strong, readonly) YTMULastFMScrobbler *lastfm;
@property (nonatomic, strong, readonly) YTMUListenBrainzScrobbler *listenbrainz;

// Master gate. When NO, no submissions go out regardless of the
// per-provider enable toggles. Default NO.
@property (nonatomic, readonly) BOOL isMasterEnabled;

// Try to flush the offline queue right now (called by settings UI
// after the user changes credentials). Safe to call any time.
- (void)flushQueueIfPossible;

@end

NS_ASSUME_NONNULL_END
