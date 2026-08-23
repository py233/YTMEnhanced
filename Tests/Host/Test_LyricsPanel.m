// The in-app lyrics panel, now compiled outside the hook file: it must
// render both lyric shapes without crashing and be released with its host.
#import <UIKit/UIKit.h>
#import "YTMUTestKit.h"
#import "YTMUTestSettings.h"
#import "YTMUTestFakeLyricsProvider.h"
#import "Lyrics/YTMULyricsTabOverlayView.h"
#import "Lyrics/YTMULyricsPanelViewController.h"
#import "Lyrics/YTMULyricsManager.h"
#import "Lyrics/YTMULyricsTypes.h"

static void Spin(NSTimeInterval s) {
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:s];
    while ([until timeIntervalSinceNow] > 0) [[NSRunLoop mainRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
}

static void Install(YTMULyricsResult *result) {
    YTMULyricsManager *m = [YTMULyricsManager sharedManager];
    [m setValue:result forKey:@"currentResult"];
    [m setValue:@(YTMULyricsFetchStateDone) forKey:@"state"];
    [m setValue:@"panel-video" forKey:@"activeVideoId"];
}

YTMU_TEST(LyricsPanel_overlay_rendersPlainAndSynced_andIsReleased) {
    YTMUTestSetSettings(@{@"YTMUltimateIsEnabled": @YES, @"syncedLyricsEnabled": @YES,
                          @"lyricsReplacementEnabled": @YES, @"lyricsTranslationEnabled": @NO, @"lyricsRomanization": @NO});
    __weak YTMULyricsTabOverlayView *weakOverlay = nil;
    __weak YTMUSyncedLyricsView *weakSynced = nil;
    @autoreleasepool {
        UIWindow *window = [[UIWindow alloc] initWithFrame:CGRectMake(0, 0, 390, 844)];
        window.hidden = NO;
        YTMULyricsTabOverlayView *overlay = [[YTMULyricsTabOverlayView alloc] initWithFrame:CGRectMake(0, 0, 390, 700)];
        [window addSubview:overlay];

        Install(YTMUTestPlainResult(@"P", @"Plain Song", @"Artist", 6));
        [overlay ytmu_renderTabOverlay];
        Spin(0.2);
        YTMU_ASSERT(!overlay.hidden, "overlay should be visible");
        YTMU_ASSERT(!overlay.lyricsTextView.hidden, "plain result should show the text view");
        YTMU_ASSERT(overlay.syncedLyricsView.hidden, "plain result should hide the synced view");
        YTMU_ASSERT(overlay.lyricsTextView.attributedText.length > 0, "text view should carry the lyrics");

        Install(YTMUTestSyncedResult(@"S", @"Synced Song", @"Artist", 8));
        [overlay ytmu_renderTabOverlay];
        Spin(0.3);
        YTMU_ASSERT(overlay.lyricsTextView.hidden, "synced result should hide the text view");
        YTMU_ASSERT(!overlay.syncedLyricsView.hidden, "synced result should show the synced view");
        YTMU_ASSERT_EQ_INT([[overlay.syncedLyricsView valueForKey:@"lineViews"] count], 8);

        weakOverlay = overlay; weakSynced = overlay.syncedLyricsView;
        [overlay removeFromSuperview];
        overlay = nil; window.hidden = YES; window = nil;
    }
    Spin(0.3);
    YTMU_ASSERT(weakOverlay == nil, "overlay view leaked");
    YTMU_ASSERT(weakSynced == nil, "embedded synced view leaked");
}

YTMU_TEST(LyricsPanel_panelViewController_loadsAndIsReleased) {
    YTMUTestSetSettings(@{@"YTMUltimateIsEnabled": @YES, @"syncedLyricsEnabled": @YES, @"lyricsReplacementEnabled": @YES});
    Install(YTMUTestPlainResult(@"P", @"Plain Song", @"Artist", 4));
    __weak YTMULyricsPanelViewController *weakVC = nil;
    @autoreleasepool {
        UIWindow *window = [[UIWindow alloc] initWithFrame:CGRectMake(0, 0, 390, 844)];
        YTMULyricsPanelViewController *vc = [[YTMULyricsPanelViewController alloc] init];
        window.rootViewController = vc;
        window.hidden = NO;
        Spin(0.2);
        YTMU_ASSERT(vc.lyricsOverlayView != nil, "panel should build its overlay on load");
        YTMU_ASSERT(vc.closeButton.superview == vc.view, "close button should be on the panel");
        weakVC = vc;
        window.rootViewController = nil; window.hidden = YES; window = nil; vc = nil;
    }
    Spin(0.3);
    YTMU_ASSERT(weakVC == nil, "panel view controller leaked");
}
