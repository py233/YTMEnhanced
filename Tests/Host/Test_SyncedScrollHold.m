// Manual-scroll hold: while the user reads elsewhere the view must not
// yank back on line changes; it resumes following followResumeDelay after
// the interaction ends, every new interaction resets the wait, tapping a
// line resumes immediately, and a rebuilt song forgets the hold.
#import <UIKit/UIKit.h>
#import "YTMUTestKit.h"
#import "YTMUTestSettings.h"
#import "YTMUTestFakeLyricsProvider.h"
#import "Lyrics/YTMUSyncedLyricsView.h"
#import "Lyrics/YTMULyricsManager.h"
#import "Lyrics/YTMULyricsPlaybackState.h"

@class YTMULyricLineView;
@interface YTMUSyncedLyricsView (YTMUScrollHoldTesting) <UIScrollViewDelegate>
- (CGPoint)followOffsetForLineAtIndex:(NSInteger)index;
- (void)lineTapped:(id)sender;
@end

@interface YTMUFakeSeekPlayer : NSObject
@property (nonatomic) CGFloat lastSeekSeconds;
@property (nonatomic) NSUInteger seekCount;
@end
@implementation YTMUFakeSeekPlayer
- (void)seekToTime:(CGFloat)time { self.lastSeekSeconds = time; self.seekCount++; }
@end

static void HoldSpin(NSTimeInterval s) {
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:s];
    while ([until timeIntervalSinceNow] > 0) [[NSRunLoop mainRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
}

static void HoldInstallResult(NSUInteger lines) {
    YTMULyricsManager *m = [YTMULyricsManager sharedManager];
    [m setValue:YTMUTestSyncedResult(@"Hold", @"Hold Song", @"Artist", lines) forKey:@"currentResult"];
    [m setValue:@(YTMULyricsFetchStateDone) forKey:@"state"];
    [m setValue:@"hold-video" forKey:@"activeVideoId"];
}

static void PlayAtMs(NSTimeInterval ms) {
    [[YTMULyricsPlaybackState sharedState] notePlaybackTimeMs:ms];
}

static NSInteger ActiveIndex(YTMUSyncedLyricsView *view) {
    return [[view valueForKey:@"activeIndex"] integerValue];
}

static UIScrollView *Scroller(YTMUSyncedLyricsView *view) {
    return [view valueForKey:@"scrollView"];
}

// A window-mounted view following a 30-line song, delay shrunk for tests.
static YTMUSyncedLyricsView *HoldSetUp(UIWindow **windowOut) {
    YTMUTestSetSettings(@{@"YTMUltimateIsEnabled": @YES, @"syncedLyricsEnabled": @YES,
                          @"lyricsRomanization": @NO, @"lyricsTranslationEnabled": @NO});
    HoldInstallResult(30);
    PlayAtMs(500);   // line 0
    UIWindow *window = [[UIWindow alloc] initWithFrame:CGRectMake(0, 0, 390, 844)];
    window.hidden = NO;
    YTMUSyncedLyricsView *view = [[YTMUSyncedLyricsView alloc] initWithFrame:CGRectMake(0, 0, 390, 600)];
    view.followResumeDelay = 0.6;
    [window addSubview:view];
    view.hidden = NO;   // the panel owner does this in the app
    HoldSpin(0.4);
    *windowOut = window;
    return view;
}

static void HoldTearDown(YTMUSyncedLyricsView *view, UIWindow *window) {
    [view removeFromSuperview];
    window.hidden = YES;
}

YTMU_TEST(ScrollHold_baseline_followsLineChanges) {
    UIWindow *window = nil;
    YTMUSyncedLyricsView *view = HoldSetUp(&window);
    CGFloat atStart = Scroller(view).contentOffset.y;
    PlayAtMs(20500);   // line 20
    YTMU_ASSERT(YTMUTestWaitUntil(3, ^BOOL{ return ActiveIndex(view) == 20; }), "active line never advanced");
    CGFloat expected = [view followOffsetForLineAtIndex:20].y;
    YTMU_ASSERT(YTMUTestWaitUntil(3, ^BOOL{ return fabs(Scroller(view).contentOffset.y - expected) < 2; }),
                "did not follow to line 20 (offset %.1f, expected %.1f)", Scroller(view).contentOffset.y, expected);
    YTMU_ASSERT(expected > atStart + 50, "line 20 should sit well below the start");
    HoldTearDown(view, window);
}

YTMU_TEST(ScrollHold_userScrollParks_highlightMoves_resumesAfterGrace) {
    UIWindow *window = nil;
    YTMUSyncedLyricsView *view = HoldSetUp(&window);
    UIScrollView *scroller = Scroller(view);

    // User grabs the view mid-line-3 and drags to the top to re-read the intro.
    PlayAtMs(3500);
    YTMU_ASSERT(YTMUTestWaitUntil(3, ^BOOL{ return ActiveIndex(view) == 3; }), "setup: line 3 never active");
    [view scrollViewWillBeginDragging:scroller];
    scroller.contentOffset = CGPointMake(0, 0);
    [view scrollViewDidEndDragging:scroller willDecelerate:NO];

    // Playback rolls on to line 9: highlight follows, position does not.
    PlayAtMs(9500);
    YTMU_ASSERT(YTMUTestWaitUntil(3, ^BOOL{ return ActiveIndex(view) == 9; }), "highlight must keep tracking during the hold");
    HoldSpin(0.25);   // inside the 0.6 s grace
    YTMU_ASSERT(fabs(scroller.contentOffset.y - 0) < 2, "view moved during the hold (offset %.1f)", scroller.contentOffset.y);

    // Grace over → drifts back to the active line without a line change.
    CGFloat expected = [view followOffsetForLineAtIndex:9].y;
    YTMU_ASSERT(YTMUTestWaitUntil(3, ^BOOL{ return fabs(Scroller(view).contentOffset.y - expected) < 2; }),
                "did not resume following after the grace (offset %.1f, expected %.1f)", scroller.contentOffset.y, expected);
    HoldTearDown(view, window);
}

YTMU_TEST(ScrollHold_everyNewInteractionResetsTheGrace) {
    UIWindow *window = nil;
    YTMUSyncedLyricsView *view = HoldSetUp(&window);
    UIScrollView *scroller = Scroller(view);
    PlayAtMs(12500);
    YTMU_ASSERT(YTMUTestWaitUntil(3, ^BOOL{ return ActiveIndex(view) == 12; }), "setup: line 12 never active");

    [view scrollViewWillBeginDragging:scroller];
    scroller.contentOffset = CGPointMake(0, 10);
    [view scrollViewDidEndDragging:scroller willDecelerate:NO];
    HoldSpin(0.35);                                  // ~0.35 into the first grace
    // Second flick, this time with a deceleration tail.
    [view scrollViewWillBeginDragging:scroller];
    scroller.contentOffset = CGPointMake(0, 30);
    [view scrollViewDidEndDragging:scroller willDecelerate:YES];
    [view scrollViewDidEndDecelerating:scroller];

    HoldSpin(0.4);                                    // first deadline long gone, second still running
    YTMU_ASSERT(fabs(scroller.contentOffset.y - 30) < 2, "first (stale) deadline restored the view (offset %.1f)", scroller.contentOffset.y);
    CGFloat expected = [view followOffsetForLineAtIndex:ActiveIndex(view)].y;
    YTMU_ASSERT(YTMUTestWaitUntil(3, ^BOOL{ return fabs(Scroller(view).contentOffset.y - expected) < 2; }),
                "second deadline never restored (offset %.1f, expected %.1f)", scroller.contentOffset.y, expected);
    HoldTearDown(view, window);
}

YTMU_TEST(ScrollHold_neverRestoresWhileFingerIsDown) {
    UIWindow *window = nil;
    YTMUSyncedLyricsView *view = HoldSetUp(&window);
    UIScrollView *scroller = Scroller(view);
    PlayAtMs(5500);
    YTMU_ASSERT(YTMUTestWaitUntil(3, ^BOOL{ return ActiveIndex(view) == 5; }), "setup: line 5 never active");

    [view scrollViewWillBeginDragging:scroller];
    scroller.contentOffset = CGPointMake(0, 0);
    PlayAtMs(10500);
    HoldSpin(1.0);                                    // far past the delay, finger still down
    YTMU_ASSERT_EQ_INT(ActiveIndex(view), 10);
    YTMU_ASSERT(fabs(scroller.contentOffset.y - 0) < 2, "restored while dragging (offset %.1f)", scroller.contentOffset.y);

    [view scrollViewDidEndDragging:scroller willDecelerate:NO];
    CGFloat expected = [view followOffsetForLineAtIndex:10].y;
    YTMU_ASSERT(YTMUTestWaitUntil(3, ^BOOL{ return fabs(Scroller(view).contentOffset.y - expected) < 2; }),
                "did not restore after the finger lifted");
    HoldTearDown(view, window);
}

YTMU_TEST(ScrollHold_tapToSeek_liftsTheHoldImmediately) {
    UIWindow *window = nil;
    YTMUSyncedLyricsView *view = HoldSetUp(&window);
    UIScrollView *scroller = Scroller(view);
    YTMUFakeSeekPlayer *player = [[YTMUFakeSeekPlayer alloc] init];
    view.playerViewController = (id)player;

    [view scrollViewWillBeginDragging:scroller];
    scroller.contentOffset = CGPointMake(0, 400);
    [view scrollViewDidEndDragging:scroller willDecelerate:NO];

    NSArray *lineViews = [view valueForKey:@"lineViews"];
    [view lineTapped:lineViews[14]];                 // user picks line 14 (t = 14 s)
    YTMU_ASSERT_EQ_INT(player.seekCount, 1);
    YTMU_ASSERT(fabs(player.lastSeekSeconds - 14.01) < 0.05, "unexpected seek target %.2f", player.lastSeekSeconds);
    PlayAtMs(14500);                                  // the seek lands
    CGFloat expected = [view followOffsetForLineAtIndex:14].y;
    // Must follow well before the 0.6 s grace would have allowed it.
    YTMU_ASSERT(YTMUTestWaitUntil(0.45, ^BOOL{ return fabs(Scroller(view).contentOffset.y - expected) < 2; }),
                "tap did not lift the hold (offset %.1f, expected %.1f)", scroller.contentOffset.y, expected);
    HoldTearDown(view, window);
}

YTMU_TEST(ScrollHold_songRebuildForgetsTheHold) {
    UIWindow *window = nil;
    YTMUSyncedLyricsView *view = HoldSetUp(&window);
    UIScrollView *scroller = Scroller(view);
    [view scrollViewWillBeginDragging:scroller];
    scroller.contentOffset = CGPointMake(0, 300);
    [view scrollViewDidEndDragging:scroller willDecelerate:NO];

    // Next song arrives (different line count → full rebuild).
    YTMULyricsManager *m = [YTMULyricsManager sharedManager];
    [m setValue:YTMUTestSyncedResult(@"Hold", @"Next Song", @"Artist", 12) forKey:@"currentResult"];
    PlayAtMs(500);
    [[NSNotificationCenter defaultCenter] postNotificationName:YTMULyricsDidUpdateNotification object:nil];
    YTMU_ASSERT(YTMUTestWaitUntil(3, ^BOOL{ return [[view valueForKey:@"lineViews"] count] == 12; }), "rebuild never happened");
    CGFloat expected = [view followOffsetForLineAtIndex:0].y;
    YTMU_ASSERT(YTMUTestWaitUntil(0.45, ^BOOL{ return fabs(Scroller(view).contentOffset.y - expected) < 2; }),
                "new song should follow immediately, hold must not survive the rebuild (offset %.1f)", scroller.contentOffset.y);
    HoldTearDown(view, window);
}
