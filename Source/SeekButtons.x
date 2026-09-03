#import "Headers/YTMNowPlayingViewController.h"
#import "Headers/YTMNowPlayingView.h"
#import "Headers/YTAssetLoader.h"
#import "Headers/Localization.h"
#import "Utils/YTMUSettings.h"

// Index into the prefs segmented control (Default / 10 / 20 / 30 / 60).
// Bounds-checked: a stale or hand-edited index must not become an
// NSRangeException on the Now Playing screen.
static NSInteger seekTime(void) {
    static const NSInteger seekTimes[] = {0, 10, 20, 30, 60};
    NSInteger index = YTMUSettingsInteger(@"seekTime", 0);
    if (index < 0 || index >= (NSInteger)(sizeof(seekTimes) / sizeof(seekTimes[0]))) return 0;
    return seekTimes[index];
}

%hook YTMNowPlayingViewController
- (void)viewDidLoad {
    %orig;

    if (!YTMU(@"YTMUltimateIsEnabled") || !YTMU(@"seekButtons")) {
        return;
    }

    YTMNowPlayingView *nowPlayingView = [self valueForKey:@"_nowPlayingView"];

    if (nowPlayingView) {
        YTMPlayerControlsView *controlsView = nowPlayingView.playerControlsView;

        [controlsView.prevButton removeTarget:self action:@selector(didTapPrevButton) forControlEvents:UIControlEventTouchUpInside];
        [controlsView.nextButton removeTarget:self action:@selector(didTapNextButton) forControlEvents:UIControlEventTouchUpInside];

        [controlsView.prevButton addTarget:self action:@selector(didTapSeekBackwardButton) forControlEvents:UIControlEventTouchUpInside];
        [controlsView.nextButton addTarget:self action:@selector(didTapSeekForwardButton) forControlEvents:UIControlEventTouchUpInside];

        UILongPressGestureRecognizer *longPressPrev = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(longPressPrev:)];
        [longPressPrev setMinimumPressDuration:0.5];
        [controlsView.prevButton addGestureRecognizer:longPressPrev];

        UILongPressGestureRecognizer *longPressNext = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(longPressNext:)];
        [longPressNext setMinimumPressDuration:0.5];
        [controlsView.nextButton addGestureRecognizer:longPressNext];

        NSInteger configured = seekTime();
        NSInteger backValue = configured == 0 ? 10 : configured;
        NSInteger forwardValue = configured == 0 ? 30 : configured;

        YTAssetLoader *al = [[%c(YTAssetLoader) alloc] initWithBundle:[NSBundle mainBundle]];

        UIImage *backImage = [al imageNamed:[NSString stringWithFormat:@"ic_seek_back_%ld_40", backValue]];
        UIImage *forwardImage = [al imageNamed:[NSString stringWithFormat:@"ic_seek_forward_%ld_40", forwardValue]];

        [controlsView.prevButton setImage:backImage forState:UIControlStateNormal];
        [controlsView.prevButton setImage:backImage forState:UIControlStateSelected];
        [controlsView.nextButton setImage:forwardImage forState:UIControlStateNormal];
        [controlsView.nextButton setImage:forwardImage forState:UIControlStateSelected];
    }
}

// - (void)didTapPrevButton {
//     YTMU(@"YTMUltimateIsEnabled") && YTMU(@"seekButtons") ? [self didTapSeekBackwardButton] : %orig;
// }

// - (void)didTapNextButton {
//     YTMU(@"YTMUltimateIsEnabled") && YTMU(@"seekButtons") ? [self didTapSeekForwardButton] : %orig;
// }

%new
- (void)longPressPrev:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateBegan) {
        [self didTapPrevButton];
    }
}

%new
- (void)longPressNext:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateBegan) {
        [self didTapNextButton];
    }
}
%end

%hook YTColdConfig
- (NSInteger)iosPlayerClientSharedConfigTransportControlsSeekForwardTime {
    return (seekTime() == 0) ? %orig : seekTime();
}

- (NSInteger)iosPlayerClientSharedConfigTransportControlsSeekBackwardTime {
    return (seekTime() == 0) ? %orig : seekTime();
}
%end
