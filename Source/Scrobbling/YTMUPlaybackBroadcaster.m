#import "YTMUPlaybackBroadcaster.h"
#import "YTMUScrobbleTypes.h"
#import "../Lyrics/YTMULyricsPlaybackState.h"
#import "../Headers/YTPlayerViewController.h"
#import <MediaPlayer/MediaPlayer.h>

// Poll cadence. 1 Hz is enough for scrobbling (we tolerate the
// 0-1s detection lag at track-change boundaries; the inaccuracy in
// "elapsed-played seconds" is bounded by one tick and never matters
// near the min(duration/2, 240s) threshold).
static const NSTimeInterval kPollInterval = 1.0;

// MPNowPlayingInfoCenter momentarily becomes empty between tracks
// (especially on skip). We treat one empty observation as a transient
// gap rather than a real "stopped" event, so a YT Music skip doesn't
// emit "paused" → "playing" spam. Two consecutive empties means
// playback truly stopped.
static const NSInteger kEmptyTicksForStop = 2;

@interface YTMUPlaybackBroadcaster ()
@property (nonatomic, strong, nullable) NSTimer *pollTimer;
@property (nonatomic, copy, nullable) NSString *lastTrackName;
@property (nonatomic, copy, nullable) NSString *lastArtist;
@property (nonatomic, copy, nullable) NSString *lastAlbumName;
@property (nonatomic, strong, nullable) YTMUListen *currentListen;
@property (nonatomic) BOOL lastIsPlaying;
@property (nonatomic) NSInteger emptyTickCount;
@property (nonatomic) NSTimeInterval lastTickWallClock;
@end

@implementation YTMUPlaybackBroadcaster

+ (instancetype)sharedBroadcaster {
    static YTMUPlaybackBroadcaster *broadcaster;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        broadcaster = [[self alloc] init];
    });
    return broadcaster;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _lastIsPlaying = NO;
        _emptyTickCount = kEmptyTicksForStop; // start in "stopped" state
        _lastTickWallClock = 0;
    }
    return self;
}

- (void)start {
    if (self.pollTimer) return;
    YTMUScrobbleLog(@"broadcaster start");
    // Use a scheduled timer on the main run loop common modes so it
    // also fires while UIKit is tracking touches. The work each tick
    // is cheap (a NowPlayingInfoCenter dict read + 3 NSString compares).
    self.pollTimer = [NSTimer timerWithTimeInterval:kPollInterval
                                             target:self
                                           selector:@selector(tick:)
                                           userInfo:nil
                                            repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.pollTimer forMode:NSRunLoopCommonModes];
}

- (void)stop {
    [self.pollTimer invalidate];
    self.pollTimer = nil;
    YTMUScrobbleLog(@"broadcaster stop");
}

#pragma mark - Tick

- (void)tick:(NSTimer *)timer {
    NSDictionary *nowPlaying = [MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo;
    NSTimeInterval wallClock = [[NSDate date] timeIntervalSince1970];
    NSTimeInterval deltaSeconds = self.lastTickWallClock > 0 ? wallClock - self.lastTickWallClock : 0;
    self.lastTickWallClock = wallClock;

    if (![nowPlaying isKindOfClass:[NSDictionary class]] || nowPlaying.count == 0) {
        // No now-playing info. After kEmptyTicksForStop in a row, treat
        // it as a real stop and clear current track state.
        self.emptyTickCount = MIN(self.emptyTickCount + 1, kEmptyTicksForStop + 1);
        if (self.emptyTickCount >= kEmptyTicksForStop && self.lastIsPlaying) {
            [self emitStateChange:NO];
        }
        return;
    }
    self.emptyTickCount = 0;

    NSString *track = [self stringValue:nowPlaying[MPMediaItemPropertyTitle]];
    NSString *artist = [self stringValue:nowPlaying[MPMediaItemPropertyArtist]];
    NSString *album = [self stringValue:nowPlaying[MPMediaItemPropertyAlbumTitle]];
    NSTimeInterval duration = [self doubleValue:nowPlaying[MPMediaItemPropertyPlaybackDuration]];

    id rateValue = nowPlaying[MPNowPlayingInfoPropertyPlaybackRate];
    BOOL isPlaying = [rateValue respondsToSelector:@selector(doubleValue)] && [rateValue doubleValue] > 0.0;

    BOOL trackChanged = ![self isSameTrackName:track artist:artist asLast:self.lastTrackName lastArtist:self.lastArtist];

    // Accumulate elapsed-played time onto the *previous* track if we
    // observed it still playing one tick ago and no track change.
    if (!trackChanged && self.currentListen && self.lastIsPlaying && deltaSeconds > 0 && deltaSeconds < 5.0) {
        self.currentListen.elapsedPlayedSeconds += deltaSeconds;
    }

    if (trackChanged) {
        YTMUListen *previous = self.currentListen;
        YTMUListen *next = nil;
        if (track.length && artist.length) {
            next = [[YTMUListen alloc] init];
            next.trackName = track;
            next.artist = artist;
            next.albumName = album.length ? album : nil;
            next.durationSeconds = duration > 0 ? duration : 0;
            next.startedAtUnix = wallClock;
            next.elapsedPlayedSeconds = 0;
            // Capture the YouTube video id off the lyrics path's
            // playback-state singleton. The lyrics tweak already
            // wires `notePlayerViewController:` on every track
            // change, so this reference is fresh by the time our
            // broadcaster ticks. Used by the resolver as a stable
            // cache key for LLM normalize results, and by the LB
            // submission body for additional_info.origin_url.
            @try {
                YTPlayerViewController *player = [YTMULyricsPlaybackState sharedState].playerViewController;
                NSString *videoId = [player respondsToSelector:@selector(currentVideoID)] ? [player currentVideoID] : nil;
                if ([videoId isKindOfClass:[NSString class]] && videoId.length) {
                    next.videoId = videoId;
                }
            } @catch (__unused NSException *exception) {
                // Defensive: YT internals occasionally throw when
                // queried mid-transition. videoId is optional, so
                // we silently leave it nil.
            }
        }
        self.lastTrackName = track;
        self.lastArtist = artist;
        self.lastAlbumName = album;
        self.currentListen = next;
        if (next || previous) {
            [self emitTrackChange:next previous:previous];
        }
    }

    if (isPlaying != self.lastIsPlaying) {
        [self emitStateChange:isPlaying];
    }
}

#pragma mark - Emit

- (void)emitTrackChange:(nullable YTMUListen *)next previous:(nullable YTMUListen *)previous {
    YTMUScrobbleLog(@"track change next=%@ prev=%@", next.trackName ?: @"(nil)", previous.trackName ?: @"(nil)");
    NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
    if (next) userInfo[kYTMUPlaybackUserInfoListen] = next;
    if (previous) userInfo[kYTMUPlaybackUserInfoPreviousListen] = previous;
    [[NSNotificationCenter defaultCenter] postNotificationName:YTMUPlaybackTrackChangedNotification
                                                        object:self
                                                      userInfo:userInfo];
}

- (void)emitStateChange:(BOOL)isPlaying {
    self.lastIsPlaying = isPlaying;
    YTMUScrobbleLog(@"state change isPlaying=%@", isPlaying ? @"YES" : @"NO");
    [[NSNotificationCenter defaultCenter] postNotificationName:YTMUPlaybackStateChangedNotification
                                                        object:self
                                                      userInfo:@{kYTMUPlaybackUserInfoIsPlaying: @(isPlaying)}];
}

#pragma mark - Helpers

- (BOOL)isSameTrackName:(nullable NSString *)trackA
                 artist:(nullable NSString *)artistA
                 asLast:(nullable NSString *)trackB
             lastArtist:(nullable NSString *)artistB {
    // nil == nil counts as same (no track in either case).
    if (trackA.length == 0 && trackB.length == 0) return YES;
    return [trackA isEqualToString:trackB] && [artistA isEqualToString:artistB];
}

- (nullable NSString *)stringValue:(id)value {
    if ([value isKindOfClass:[NSString class]]) {
        NSString *trimmed = [(NSString *)value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        return trimmed.length ? trimmed : nil;
    }
    return nil;
}

- (NSTimeInterval)doubleValue:(id)value {
    if ([value respondsToSelector:@selector(doubleValue)]) {
        NSTimeInterval v = [value doubleValue];
        if (isfinite(v) && v >= 0) return v;
    }
    return 0;
}

@end
