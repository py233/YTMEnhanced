// C1: YTMUSyncedLyricsView must be released when its owner lets go of it.
// It used to be kept alive forever by its own CADisplayLink (run loop →
// link → target), so every lyrics-panel open leaked one instance that kept
// rebuilding its line stack on every lyrics update.
#import <UIKit/UIKit.h>
#import "YTMUTestKit.h"
#import "YTMUTestSettings.h"
#import "Lyrics/YTMUSyncedLyricsView.h"
#import "Lyrics/YTMULyricsManager.h"
#import "Lyrics/YTMULyricsTypes.h"

static void SpinRunLoop(NSTimeInterval seconds) {
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while ([until timeIntervalSinceNow] > 0) {
        [[NSRunLoop mainRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
    }
}

static YTMULyricsResult *ThreeLineResult(void) {
    YTMULyricsResult *r = [[YTMULyricsResult alloc] init];
    r.sourceName = @"Test";
    r.title = @"t"; r.artists = @[@"a"];
    r.lines = @[
        [YTMULyricLine lineWithTime:@"00:00.00" timeInMs:0 durationMs:1000 text:@"alpha"],
        [YTMULyricLine lineWithTime:@"00:01.00" timeInMs:1000 durationMs:1000 text:@"beta"],
        [YTMULyricLine lineWithTime:@"00:02.00" timeInMs:2000 durationMs:1000 text:@"gamma"],
    ];
    return r;
}

static void InstallResultInManager(YTMULyricsResult *result) {
    // The manager's setters are private; KVC reaches the class-extension
    // readwrite properties exactly like the manager's own code does.
    YTMULyricsManager *m = [YTMULyricsManager sharedManager];
    [m setValue:result forKey:@"currentResult"];
    [m setValue:@(YTMULyricsFetchStateDone) forKey:@"state"];
    [m setValue:@"test-video" forKey:@"activeVideoId"];
}

static NSUInteger LineViewCount(YTMUSyncedLyricsView *view) {
    return [[view valueForKey:@"lineViews"] count];
}

YTMU_TEST(SyncedLyricsView_isReleasedAfterRemovalFromWindow) {
    YTMUTestSetSettings(@{@"YTMUltimateIsEnabled": @YES, @"syncedLyricsEnabled": @YES});
    InstallResultInManager(ThreeLineResult());

    __weak YTMUSyncedLyricsView *weakView = nil;
    @autoreleasepool {
        UIWindow *window = [[UIWindow alloc] initWithFrame:CGRectMake(0, 0, 390, 844)];
        YTMUSyncedLyricsView *view = [[YTMUSyncedLyricsView alloc] initWithFrame:CGRectMake(0, 0, 390, 600)];
        [window addSubview:view];
        window.hidden = NO;
        [view reloadFromManager];
        SpinRunLoop(0.3);                         // let the display link tick a few times
        YTMU_ASSERT_EQ_INT(LineViewCount(view), 3); // it really rendered while on screen
        weakView = view;
        [view removeFromSuperview];
        window.hidden = YES;
        view = nil; window = nil;
    }
    SpinRunLoop(0.3);
    YTMU_ASSERT(weakView == nil, "YTMUSyncedLyricsView leaked: still alive after its owner released it");
}

YTMU_TEST(SyncedLyricsView_offWindow_doesNotRebuildOnLyricsUpdate) {
    YTMUTestSetSettings(@{@"YTMUltimateIsEnabled": @YES, @"syncedLyricsEnabled": @YES});
    InstallResultInManager(ThreeLineResult());

    YTMUSyncedLyricsView *view = [[YTMUSyncedLyricsView alloc] initWithFrame:CGRectMake(0, 0, 390, 600)];
    // Never added to a window. A lyrics update must not make it build line views.
    [[NSNotificationCenter defaultCenter] postNotificationName:YTMULyricsDidUpdateNotification object:nil];
    SpinRunLoop(0.2);
    YTMU_ASSERT_EQ_INT(LineViewCount(view), 0);

    // Once it is on screen it must catch up.
    UIWindow *window = [[UIWindow alloc] initWithFrame:CGRectMake(0, 0, 390, 844)];
    [window addSubview:view];
    window.hidden = NO;
    SpinRunLoop(0.3);
    YTMU_ASSERT_EQ_INT(LineViewCount(view), 3);
    [view removeFromSuperview];
    window.hidden = YES;
}

YTMU_TEST(SyncedLyricsView_onWindow_rebuildsWhenResultChanges) {
    YTMUTestSetSettings(@{@"YTMUltimateIsEnabled": @YES, @"syncedLyricsEnabled": @YES});
    InstallResultInManager(ThreeLineResult());

    UIWindow *window = [[UIWindow alloc] initWithFrame:CGRectMake(0, 0, 390, 844)];
    YTMUSyncedLyricsView *view = [[YTMUSyncedLyricsView alloc] initWithFrame:CGRectMake(0, 0, 390, 600)];
    [window addSubview:view];
    window.hidden = NO;
    SpinRunLoop(0.2);
    YTMU_ASSERT_EQ_INT(LineViewCount(view), 3);

    YTMULyricsResult *five = ThreeLineResult();
    five.lines = [five.lines arrayByAddingObjectsFromArray:@[
        [YTMULyricLine lineWithTime:@"00:03.00" timeInMs:3000 durationMs:1000 text:@"delta"],
        [YTMULyricLine lineWithTime:@"00:04.00" timeInMs:4000 durationMs:1000 text:@"epsilon"],
    ]];
    InstallResultInManager(five);
    [[NSNotificationCenter defaultCenter] postNotificationName:YTMULyricsDidUpdateNotification object:nil];
    SpinRunLoop(0.2);
    YTMU_ASSERT_EQ_INT(LineViewCount(view), 5);
    [view removeFromSuperview];
    window.hidden = YES;
}

// Simulates the user opening and closing the lyrics panel many times.
YTMU_TEST(SyncedLyricsView_twentyOpenClose_leaveNoInstancesBehind) {
    YTMUTestSetSettings(@{@"YTMUltimateIsEnabled": @YES, @"syncedLyricsEnabled": @YES});
    InstallResultInManager(ThreeLineResult());
    NSPointerArray *weakRefs = [NSPointerArray weakObjectsPointerArray];
    UIWindow *window = [[UIWindow alloc] initWithFrame:CGRectMake(0, 0, 390, 844)];
    window.hidden = NO;
    for (NSUInteger i = 0; i < 20; i++) {
        @autoreleasepool {
            YTMUSyncedLyricsView *view = [[YTMUSyncedLyricsView alloc] initWithFrame:CGRectMake(0, 0, 390, 600)];
            [window addSubview:view];
            [view reloadFromManager];
            SpinRunLoop(0.05);
            [weakRefs addPointer:(__bridge void *)view];
            [view removeFromSuperview];
        }
    }
    SpinRunLoop(0.3);
    // NSPointerArray.count still counts zeroed slots; allObjects does not.
    YTMU_ASSERT_EQ_INT(weakRefs.allObjects.count, 0);
    // Ghost-free means a lyrics update costs exactly zero hidden rebuilds.
    YTMU_ASSERT_NO_THROW([[NSNotificationCenter defaultCenter] postNotificationName:YTMULyricsDidUpdateNotification object:nil]);
    SpinRunLoop(0.1);
    window.hidden = YES;
}
