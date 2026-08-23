// Characterisation of NetEase candidate ranking and keyword generation on a
// fixed fixture. Pure functions of their inputs — no network.
#import "YTMUTestKit.h"
#import "YTMUTestSettings.h"
#import "Lyrics/Providers/YTMUNetEaseProvider.h"

@interface YTMUNetEaseProvider (YTMUTesting)
- (NSArray<NSDictionary *> *)candidateSongsFromSongs:(NSArray<NSDictionary *> *)songs info:(YTMULyricsSearchInfo *)info;
- (NSArray<NSString *> *)keywordsForInfo:(YTMULyricsSearchInfo *)info;
@end

static NSDictionary *Song(NSInteger sid, NSString *name, NSArray<NSString *> *artists, NSTimeInterval seconds) {
    NSMutableArray *ar = [NSMutableArray array];
    for (NSString *a in artists) [ar addObject:@{@"name": a}];
    return @{@"id": @(sid), @"name": name, @"artists": ar, @"duration": @(seconds * 1000)};
}

static YTMULyricsSearchInfo *FixtureInfo(void) {
    YTMULyricsSearchInfo *info = [[YTMULyricsSearchInfo alloc] init];
    info.videoId = @"ne-fixture";
    info.title = @"Qeiru - ハテ (feat. IA) [Official Music Video]";
    info.alternativeTitle = @"ハテ - Terminal";
    info.artist = @"Qeiru";
    info.album = @"";
    info.duration = 197;
    info.tags = @[];   // YT Music never ships microformat tags in practice
    return info;
}

static NSArray<NSDictionary *> *FixtureSongs(void) {
    return @[
        Song(1001, @"ハテ", @[@"Qeiru", @"IA"], 197),
        Song(1002, @"ハテ (Instrumental)", @[@"Qeiru"], 197),
        Song(1003, @"Terminal", @[@"Qeiru", @"IA"], 198),
        Song(1004, @"Terminal", @[@"Some K-pop Group"], 214),
        Song(1005, @"タイムカプセル", @[@"THE MUSMUS"], 197),
        Song(1006, @"ハテ", @[@"Cover Singer"], 230),
        Song(1007, @"Qeiru Mega Mix", @[@"Qeiru"], 1200),
        Song(1008, @"ハテ", @[@"Qeiru", @"IA"], 197),   // duplicate id-different twin of 1001
    ];
}

static NSString *Describe(NSArray<NSDictionary *> *matches) {
    NSMutableArray *parts = [NSMutableArray array];
    for (NSDictionary *m in matches) {
        [parts addObject:[NSString stringWithFormat:@"%@%@", m[@"song"][@"id"], [m[@"strict"] boolValue] ? @"*" : @""]];
    }
    return [parts componentsJoinedByString:@","];
}

YTMU_TEST(NetEase_candidateRanking_golden) {
    YTMUTestSetSettings(@{@"lyricsShowInexact": @YES});
    YTMUNetEaseProvider *p = [[YTMUNetEaseProvider alloc] init];
    NSArray *matches = [p candidateSongsFromSongs:FixtureSongs() info:FixtureInfo()];
    // Captured before the keyword/candidate computation was shared between
    // the two passes: the real "ハテ" twins rank first as strict matches,
    // the Qeiru "Terminal" next, the wrong-artist "Terminal" still strict
    // (title-only gate), instrumental + cover only as inexact fallbacks,
    // THE MUSMUS and the 20-minute mix excluded.
    YTMU_ASSERT_EQ_STR(Describe(matches), @"1001*,1008*,1003*,1004*,1002,1006");
    YTMU_ASSERT_EQ_STR([[p keywordsForInfo:FixtureInfo()] componentsJoinedByString:@" | "],
                       @"ハテ | ハテ Qeiru | ハテ IA | ハテ - Terminal | ハテ - Terminal Qeiru | ハテ - Terminal IA | Terminal | Terminal Qeiru | Terminal IA");
}

YTMU_TEST(NetEase_candidateRanking_respectsShowInexactSetting) {
    YTMUTestSetSettings(@{@"lyricsShowInexact": @NO});
    YTMUNetEaseProvider *p = [[YTMUNetEaseProvider alloc] init];
    NSArray *matches = [p candidateSongsFromSongs:FixtureSongs() info:FixtureInfo()];
    YTMU_ASSERT_EQ_STR(Describe(matches), @"1001*,1008*,1003*,1004*");
    YTMUTestSetSettings(@{@"lyricsShowInexact": @YES});
}
