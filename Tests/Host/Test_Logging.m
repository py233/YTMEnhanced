// M4: log calls must not evaluate their arguments when logging is off, and
// the enabled-check must be cheap enough for per-frame call sites.
#import "YTMUTestKit.h"
#import "YTMUTestSettings.h"
#import "Lyrics/YTMULyricsTypes.h"
#import "Translation/YTMUTranslationTypes.h"
#import "Scrobbling/YTMUScrobbleTypes.h"
#import <QuartzCore/QuartzCore.h>

static NSUInteger gSideEffects = 0;
static NSString *SideEffect(void) { gSideEffects++; return @"evaluated"; }

YTMU_TEST(Logging_argumentsNotEvaluatedWhenDisabled) {
    YTMUTestSetSettings(@{@"translationDebugLogs": @NO, @"scrobbleDebugLogs": @NO});
    gSideEffects = 0;
    YTMULyricsLog(@"lyrics %@", SideEffect());
    YTMUTranslationLog(@"translation %@", SideEffect());
    YTMUScrobbleLog(@"scrobble %@", SideEffect());
    YTMU_ASSERT_EQ_INT(gSideEffects, 0);
}

YTMU_TEST(Logging_argumentsEvaluatedWhenEnabled) {
    YTMUTestSetSettings(@{@"translationDebugLogs": @YES, @"scrobbleDebugLogs": @YES});
    gSideEffects = 0;
    YTMULyricsLog(@"lyrics %@", SideEffect());
    YTMUTranslationLog(@"translation %@", SideEffect());
    YTMUScrobbleLog(@"scrobble %@", SideEffect());
    YTMU_ASSERT_EQ_INT(gSideEffects, 3);
    YTMUTestSetSettings(@{@"translationDebugLogs": @NO, @"scrobbleDebugLogs": @NO});
}

YTMU_TEST(Logging_enabledCheckIsCheap) {
    YTMUTestSetSettings(@{@"translationDebugLogs": @NO});
    (void)YTMULyricsDebugLoggingEnabled();
    CFTimeInterval t0 = CACurrentMediaTime();
    for (int i = 0; i < 20000; i++) (void)YTMULyricsDebugLoggingEnabled();
    double perCall = (CACurrentMediaTime() - t0) / 20000.0 * 1e6;
    printf("        YTMULyricsDebugLoggingEnabled: %.2f µs/call\n", perCall);
    YTMU_ASSERT(perCall < 5.0, "enabled-check too slow for hot paths: %.2f µs", perCall);
}
