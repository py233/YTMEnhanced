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

- (NSTimeInterval)currentPlaybackTimeMs {
    YTPlayerViewController *player = self.playerViewController;
    if (player) {
        @try {
            NSTimeInterval playerTime = player.currentVideoMediaTime;
            if (isfinite(playerTime) && playerTime >= 0) {
                NSTimeInterval timeMs = playerTime * 1000.0;
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
