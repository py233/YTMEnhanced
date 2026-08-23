#import "YTMUTestKit.h"
#import "Utils/YTMUHLSManifest.h"
#import "Utils/YTMUKVC.h"

YTMU_TEST(HLSManifest_prefers234_then233_elseNil) {
    NSString *m =
    @"#EXTM3U\n"
    @"#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"233\",NAME=\"Default\",DEFAULT=YES,URI=\"https://r1.example.com/a/233/index.m3u8?x=1\"\n"
    @"#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"234\",NAME=\"Default\",DEFAULT=YES,URI=\"https://r2.example.com/a/234/index.m3u8?y=2\"\n"
    @"#EXT-X-STREAM-INF:BANDWIDTH=1,CODECS=\"avc1\",AUDIO=\"234\"\nhttps://r2.example.com/v/index.m3u8\n";
    YTMU_ASSERT_EQ_STR(YTMUHLSAudioStreamURLFromManifest(m), @"https://r2.example.com/a/234/index.m3u8");
    NSString *only233 = @"#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"233\",URI=\"https://r1.example.com/a/233/index.m3u8\"\n";
    YTMU_ASSERT_EQ_STR(YTMUHLSAudioStreamURLFromManifest(only233), @"https://r1.example.com/a/233/index.m3u8");
    YTMU_ASSERT(YTMUHLSAudioStreamURLFromManifest(@"#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\nhttps://v/index.m3u8\n") == nil, "no audio group → nil");
    YTMU_ASSERT(YTMUHLSAudioStreamURLFromManifest(@"") == nil && YTMUHLSAudioStreamURLFromManifest(nil) == nil, "empty → nil");
    // a line that mentions the group but carries no https:// or no index.m3u8 is skipped, not mis-sliced
    YTMU_ASSERT(YTMUHLSAudioStreamURLFromManifest(@"#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"234\",URI=\"ftp://nope/index.m3u8\"\n") == nil, "non-https skipped");
}

YTMU_TEST(SafeKVC_returnsNilForUnknownKey) {
    NSObject *o = [[NSObject alloc] init];
    YTMU_ASSERT(YTMUSafeValueForKey(o, @"definitelyNotAKey") == nil, "unknown key must yield nil, not throw");
    YTMU_ASSERT(YTMUSafeValueForKey(nil, @"x") == nil && YTMUSafeValueForKey(o, @"") == nil, "nil/empty guards");
    YTMU_ASSERT_EQ_STR(YTMUSafeValueForKey(@{@"k": @"v"}, @"k"), @"v");
}
