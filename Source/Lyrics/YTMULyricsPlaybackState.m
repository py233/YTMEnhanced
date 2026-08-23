#import "YTMULyricsPlaybackState.h"
#import "../Headers/YTPlayerViewController.h"
#import <MediaPlayer/MediaPlayer.h>
#import <QuartzCore/QuartzCore.h>

@implementation YTMULyricsPlaybackState

+ (instancetype)sharedState {
    static YTMULyricsPlaybackState *state;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        state = [[self alloc] init];
    });
    return state;
}

- (void)notePlayerViewController:(YTPlayerViewController *)playerViewController {
    if (playerViewController) self.playerViewController = playerViewController;
}

- (void)notePlaybackTimeMs:(NSTimeInterval)timeMs {
    if (!isfinite(timeMs) || timeMs < 0) return;
    self.lastPlaybackTimeMs = timeMs;
    self.lastPlaybackWallClock = CACurrentMediaTime() * 1000.0;
}

// YTPlayerViewController reports currentVideoMediaTime /
// currentVideoTotalMediaTime as seconds, but real devices have also been
// seen handing back millisecond-scale values for the duration (see commit
// afd7a9e), so this guesses the unit from magnitude:
//   - duration > 10000 is taken to be milliseconds; a rawTime that fits
//     the seconds-scale duration is seconds, one that fits the ms-scale
//     duration is already ms;
//   - otherwise a rawTime far above the duration (but not absurdly so) is
//     already ms; anything else is seconds.
// Returns -1 for an unusable rawTime. The single implementation for both
// the hook path (SyncedLyrics.x) and the display-link path.
- (NSTimeInterval)normalizedPlaybackTimeMsForRawTime:(NSTimeInterval)rawTime duration:(NSTimeInterval)duration {
    if (!isfinite(rawTime) || rawTime < 0) return -1;
    if (isfinite(duration) && duration > 0) {
        if (duration > 10000.0) {
            NSTimeInterval durationSeconds = duration / 1000.0;
            if (rawTime <= durationSeconds * 1.5) return rawTime * 1000.0;
            if (rawTime <= duration * 1.5) return rawTime;
        }
        if (rawTime > duration * 1.5 && rawTime <= duration * 1500.0) return rawTime;
    }
    return rawTime * 1000.0;
}

- (NSTimeInterval)currentPlaybackTimeMs {
    YTPlayerViewController *player = self.playerViewController;
    if (player) {
        @try {
            NSTimeInterval playerTime = player.currentVideoMediaTime;
            NSTimeInterval duration = player.currentVideoTotalMediaTime;
            NSTimeInterval timeMs = [self normalizedPlaybackTimeMsForRawTime:playerTime duration:duration];
            if (timeMs >= 0) {
                [self notePlaybackTimeMs:timeMs];
                return timeMs;
            }
        } @catch (__unused NSException *exception) {
        }
    }

    NSDictionary *nowPlaying = [MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo ?: @{};
    id elapsed = nowPlaying[MPNowPlayingInfoPropertyElapsedPlaybackTime];
    if ([elapsed respondsToSelector:@selector(doubleValue)]) {
        NSTimeInterval value = [elapsed doubleValue];
        if (isfinite(value) && value >= 0) {
            NSTimeInterval timeMs = value * 1000.0;
            [self notePlaybackTimeMs:timeMs];
            return timeMs;
        }
    }

    if (self.lastPlaybackWallClock > 0 && self.lastPlaybackTimeMs >= 0) {
        id rateValue = nowPlaying[MPNowPlayingInfoPropertyPlaybackRate];
        CGFloat rate = [rateValue respondsToSelector:@selector(doubleValue)] ? [rateValue doubleValue] : 0.0;
        if (rate > 0) {
            NSTimeInterval elapsedMs = CACurrentMediaTime() * 1000.0 - self.lastPlaybackWallClock;
            return self.lastPlaybackTimeMs + MAX(0, elapsedMs) * rate;
        }
        return self.lastPlaybackTimeMs;
    }

    return 0;
}

@end
