#import "YTMUTestKit.h"
#import "Lyrics/YTMUWordLyricsParser.h"
#include <math.h>

YTMU_TEST(WordLyricsParser_parsesTTMLWordSpans) {
    NSString *ttml = @"<tt><body><p begin=\"0s\" end=\"2s\"><span begin=\"0s\" end=\"0.5s\">One</span> <span begin=\"0.5s\" end=\"1s\">two</span></p></body></tt>";
    NSArray<YTMULyricLine *> *lines = YTMUWordLyricsParseTTML(ttml);
    YTMU_ASSERT_EQ_INT(lines.count, 1);
    YTMU_ASSERT_EQ_INT(lines.firstObject.wordTimings.count, 2);
    YTMU_ASSERT_EQ_STR(lines.firstObject.text, @"One two");
    YTMU_ASSERT(fabs([lines.firstObject.wordTimings[1][@"start"] doubleValue] - 500.0) < 0.1, "second word start should be 500ms");
}

YTMU_TEST(WordLyricsParser_parsesSpicySyllableContent) {
    NSDictionary *json = @{
        @"Type": @"Syllable",
        @"Content": @[@{
            @"Lead": @{
                @"Syllables": @[
                    @{@"Text": @"Hello", @"StartTime": @0.0, @"EndTime": @0.4},
                    @{@"Text": @"world", @"StartTime": @0.4, @"EndTime": @0.8},
                ],
            },
        }],
    };
    YTMULyricsSearchInfo *info = [[YTMULyricsSearchInfo alloc] init];
    info.title = @"Song";
    YTMULyricsResult *result = YTMUWordLyricsResultFromSpicyJSON(json, info, @"SpicyLyrics.org");
    YTMU_ASSERT_EQ_INT(result.lines.count, 1);
    YTMU_ASSERT_EQ_INT(result.lines.firstObject.wordTimings.count, 2);
    YTMU_ASSERT_EQ_STR(result.lines.firstObject.text, @"Hello world");
}
