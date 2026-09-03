#import "Headers/YTPivotBarItemView.h"
#import "Headers/YTIPivotBarRenderer.h"
#import "Headers/YTMWatchViewController.h"
#import "Headers/YTPivotBarViewController.h"
#import "Headers/YTPlayabilityResolutionUserActionUIController.h"
#import "Utils/YTMUSettings.h"
#import "Utils/YTMUKVC.h"

@interface YTPlayabilityResolutionUserActionUIControllerImpl : NSObject
- (void)confirmAlertDidPressConfirm;
@end

// Headers stuff
%hook YTLightweightCollectionController
- (void)setUseStickyHeaders:(BOOL)arg1 {
	YTMU(@"YTMUltimateIsEnabled") && YTMU(@"noStickyHeaders") ? %orig(NO) : %orig;
}
%end

%hook YTMSearchTabViewController
- (BOOL)shouldUseStickyHeaders {
	return YTMU(@"YTMUltimateIsEnabled") && YTMU(@"noStickyHeaders") ? NO : %orig;
}
%end

%hook YTMTabViewController
- (BOOL)shouldUseStickyHeaders {
	return YTMU(@"YTMUltimateIsEnabled") && YTMU(@"noStickyHeaders") ? NO : %orig;
}
%end

// Make chip clouds (aka headers) background transparent
%hook YTMChipCloudView
- (void)setBackgroundColor:(UIColor *)backgroundColor {
    YTMU(@"YTMUltimateIsEnabled") && YTMU(@"noStickyHeaders") ? %orig([UIColor clearColor]) : %orig;
}
%end

// Tab bar stuff
%hook YTPivotBarItemView
- (void)setRenderer:(YTIPivotBarRenderer *)renderer {
    %orig;
    if (YTMU(@"YTMUltimateIsEnabled") && YTMU(@"noTabBarLabels")) {
        [self.navigationButton setTitle:@"" forState:UIControlStateNormal];
        [self.navigationButton setSizeWithPaddingAndInsets:NO];
    }
}
%end

// Hidden tabs are removed in Source/YTMTab.x (the one YTPivotBarView
// setRenderer: hook).

// Startup bar
static BOOL isTabSelected = NO;

%hook YTPivotBarViewController
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    if (!isTabSelected) {
        // Index 4 is the tweak's own Downloads tab; its pivot identifier is
        // the one YTMTab.x injects (it used to name a tab that never existed).
        NSArray *pivotIdentifiers = @[@"FEmusic_home", @"FEmusic_immersive", @"FEmusic_explore", @"FEmusic_library_landing", @"FEytmu_downloads"];
        NSInteger index = YTMUSettingsInteger(@"startupPage", 0);
        if (index < 0 || index >= (NSInteger)pivotIdentifiers.count) index = 0;
        [self selectItemWithPivotIdentifier:pivotIdentifiers[index]];
        isTabSelected = YES;
    }
}
%end

%hook YTPlayabilityResolutionUserActionUIController
- (void)showConfirmAlert {
    YTMU(@"YTMUltimateIsEnabled") && YTMU(@"skipWarning") ? [self confirmAlertDidPressConfirm] : %orig;
}
%end

%hook YTPlayabilityResolutionUserActionUIControllerImpl
- (void)showConfirmAlert {
    YTMU(@"YTMUltimateIsEnabled") && YTMU(@"skipWarning") ? [self confirmAlertDidPressConfirm] : %orig;
}
%end

%hook YTMWatchViewController
- (void)playbackControllerStateDidChange {
    %orig;
    if (!YTMU(@"YTMUltimateIsEnabled")) return;
    // Reset all miniplayer restrictions
    if ([self respondsToSelector:@selector(resetMiniplayerRestrictions)]) {
        [self resetMiniplayerRestrictions];
    }
    // Disable auto-pause when player minimized to miniplayer. Written by
    // ivar name, so it is checked first: a renamed ivar in a newer app
    // build must not turn into NSUnknownKeyException here.
    YTMUSafeSetValueForKey(self, @"_pauseOnMinimize", @NO);
}
%end

%hook YTColdConfig
- (BOOL)cxClientEnableIosLocalNetworkPermissionWifiFixes { return YES; }
- (BOOL)cxClientEnableIosLocalNetworkPermissionUsingSockets { return NO; }
- (BOOL)cxClientEnableIosLocalNetworkPermissionReliabilityFixes { return YES; }
- (BOOL)cxClientEnableIosLocalNetworkPermissionPageDelayFix { return YES; }
%end

%hook YTHotConfig
- (BOOL)isPromptForLocalNetworkPermissionsEnabled { return NO; }
%end

// Stub for server-side request (Search results)
%hook YTMLightweightOfflineTrackingSectionController
%new
- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {
    return 1;
}
%end