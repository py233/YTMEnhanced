// L4: one playback-time unit heuristic, pinned.
#import "YTMUTestKit.h"
#import "Lyrics/YTMULyricsPlaybackState.h"

YTMU_TEST(PlaybackTime_unitHeuristic_table) {
    YTMULyricsPlaybackState *s = [YTMULyricsPlaybackState sharedState];
    // seconds in, seconds duration → ms out
    YTMU_ASSERT_EQ_INT((long long)[s normalizedPlaybackTimeMsForRawTime:65.25 duration:197], 65250);
    // player already in ms for time, seconds for duration → passthrough
    YTMU_ASSERT_EQ_INT((long long)[s normalizedPlaybackTimeMsForRawTime:65250 duration:197], 65250);
    // both in ms (observed on device, commit afd7a9e) → passthrough
    YTMU_ASSERT_EQ_INT((long long)[s normalizedPlaybackTimeMsForRawTime:65250 duration:197000], 65250);
    // seconds time with ms duration → ms out
    YTMU_ASSERT_EQ_INT((long long)[s normalizedPlaybackTimeMsForRawTime:65.25 duration:197000], 65250);
    // unusable
    YTMU_ASSERT_EQ_INT((long long)[s normalizedPlaybackTimeMsForRawTime:-1 duration:197], -1);
    YTMU_ASSERT_EQ_INT((long long)[s normalizedPlaybackTimeMsForRawTime:NAN duration:197], -1);
    // no duration → assume seconds
    YTMU_ASSERT_EQ_INT((long long)[s normalizedPlaybackTimeMsForRawTime:12.5 duration:0], 12500);
}
