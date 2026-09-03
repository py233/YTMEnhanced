#include "GSVolBar.h"
#import "../Utils/YTMUSettings.h"

// Read at call time. Upstream evaluated this once when the dylib loaded, so
// toggling the setting did nothing until the app was restarted.
static BOOL volumeBarEnabled(void) {
    return YTMUEnabled(@"volBar");
}

@interface YTMWatchView: UIView
@property (readonly, nonatomic) BOOL isExpanded;
@property (nonatomic, strong) UIView *tabView;
@property (nonatomic) long long currentLayout;
@property (nonatomic, strong) GSVolBar *volumeBar;

- (void)updateVolBarVisibility;
- (void)ytmu_syncVolumeBar;
@end

%hook YTMWatchView
%property (nonatomic, strong) GSVolBar *volumeBar;

- (instancetype)initWithColorScheme:(id)scheme {
    self = %orig;

    if (self) [self ytmu_syncVolumeBar];

    return self;
}

- (void)layoutSubviews {
    %orig;

    // Create or tear the bar down here as well as at init: the watch view is
    // built once per session, so a bar only created at init never appeared
    // until the app was restarted (and one created then stayed on screen
    // after the setting was switched off).
    [self ytmu_syncVolumeBar];

    if (self.volumeBar) {
        self.volumeBar.frame = CGRectMake(self.frame.size.width / 2 - (self.frame.size.width / 2) / 2, CGRectGetMinY(self.tabView.frame) - 25, self.frame.size.width / 2, 25);
    }
}

%new
- (void)ytmu_syncVolumeBar {
    BOOL wanted = volumeBarEnabled();
    if (wanted && !self.volumeBar) {
        self.volumeBar = [[GSVolBar alloc] initWithFrame:CGRectMake(self.frame.size.width / 2 - (self.frame.size.width / 2) / 2, 0, self.frame.size.width / 2, 25)];
        [self addSubview:self.volumeBar];
        [self updateVolBarVisibility];
    } else if (!wanted && self.volumeBar) {
        [self.volumeBar removeFromSuperview];
        self.volumeBar = nil;
    }
}

- (void)updateColorsAfterLayoutChangeTo:(long long)arg1 {
    %orig;

    if (volumeBarEnabled()) {
        [self updateVolBarVisibility];
    }
}

- (void)updateColorsBeforeLayoutChangeTo:(long long)arg1 {
    %orig;

    self.volumeBar.hidden = YES;
}

%new
- (void)updateVolBarVisibility {
    if (!self.volumeBar) return;
    dispatch_async(dispatch_get_main_queue(), ^(void){
        self.volumeBar.hidden = !(self.isExpanded && self.currentLayout == 2);
    });
}

%end