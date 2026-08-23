// Golden outputs of the string utilities, captured from the code as it was
// before any regex caching / Levenshtein rewrite. These functions sit in the
// O(candidates × titles) scoring loops, so later speed work must reproduce
// every byte here.
#import "YTMUTestKit.h"
#import "Lyrics/YTMULyricsTypes.h"
#import "Lyrics/YTMULyricsTextProcessor.h"
#import <QuartzCore/QuartzCore.h>

typedef struct { NSString *in, *loose, *compact, *stripped, *artists; } YTMUStringRow;
typedef struct { NSString *a, *b; double sim; } YTMUSimRow;
typedef struct { NSString *in; int chinese, kana, cjk, romanizable, needsRoman; } YTMUTPRow;

YTMU_TEST(StringUtils_golden_normalize_compact_strip_splitArtists) {
    static YTMUStringRow rows[] = {
    {@"Qeiru - ハテ (feat. IA) [Official Music Video]", @"qeiru - ﾊﾃ (feat. ia) [official music video]", @"qeiruﾊﾃfeatiaofficialmusicvideo", @"Qeiru - ハテ", @"Qeiru - ハテ (|. IA)"},
    {@"【MV】Terminal / Qeiru feat. IA「初音ミク」(Official)", @"【mv】terminal / qeiru feat. ia｢初音ﾐｸ｣(official)", @"mvterminalqeirufeatia初音ﾐｸofficial", @"Terminal / Qeiru", @"Terminal|Qeiru|. IA「初音ミク」"},
    {@"iPod Touch", @"ipod touch", @"ipodtouch", @"iPod Touch", @"iPod Touch"},
    {@"IPOD  touch ", @"ipod touch", @"ipodtouch", @"IPOD touch", @"IPOD touch"},
    {@"Ｆｕｌｌｗｉｄｔｈ　Ｔｅｘｔ", @"fullwidth text", @"fullwidthtext", @"Ｆｕｌｌｗｉｄｔｈ Ｔｅｘｔ", @"Ｆｕｌｌｗｉｄｔｈ Ｔｅｘｔ"},
    {@"Café Déjà Vu – Remix (Lyric Video)", @"cafe deja vu – remix (lyric video)", @"cafedejavuremixlyricvideo", @"Café Déjà Vu – Remix", @"Café Déjà Vu – Remix"},
    {@"song_title_with_underscores", @"song title with underscores", @"songtitlewithunderscores", @"song_title_with_underscores", @"song_title_with_underscores"},
    {@"A & B feat. C, D and E / F｜G", @"a & b feat. c, d and e / f|g", @"abfeatcdandefg", @"A & B", @"A|B|. C|D|E|F|G"},
    {@"夜に駆ける / YOASOBI", @"夜に駆ける / yoasobi", @"夜に駆けるyoasobi", @"夜に駆ける / YOASOBI", @"夜に駆ける|YOASOBI"},
    {@"Hello, World! 123", @"hello, world! 123", @"helloworld123", @"Hello, World! 123", @"Hello|World! 123"},
    {@"   ", @"", @"", @"", @""},
    {@"", @"", @"", @"", @""},
    {@"ABC", @"abc", @"abc", @"ABC", @"ABC"},
    {@"abc", @"abc", @"abc", @"abc", @"abc"},
    {@"ab", @"ab", @"ab", @"ab", @"ab"},
    {@"a", @"a", @"a", @"a", @"a"},
    {@"THE MUSMUS - タイムカプセル (Official Video)", @"the musmus - ﾀｲﾑｶﾌﾟｾﾙ (official video)", @"themusmusﾀｲﾑｶﾌﾟｾﾙofficialvideo", @"THE MUSMUS - タイムカプセル", @"THE MUSMUS - タイムカプセル"},
    {@"Hi Ren", @"hi ren", @"hiren", @"Hi Ren", @"Hi Ren"},
    {@"hi ren (official audio)", @"hi ren (official audio)", @"hirenofficialaudio", @"hi ren", @"hi ren"},
    {@"Ex Luna Scientia", @"ex luna scientia", @"exlunascientia", @"Ex Luna Scientia", @"Ex Luna Scientia"},
    {@"消えない温度 (feat. 初音ミク)", @"消えない温度 (feat. 初音ﾐｸ)", @"消えない温度feat初音ﾐｸ", @"消えない温度", @"消えない温度 (|. 初音ミク)"},
    {@"公式ミュージックビデオ 歌詞付き", @"公式ﾐｭｰｼﾞｯｸﾋﾞﾃﾞｵ 歌詞付き", @"公式ﾐｭｰｼﾞｯｸﾋﾞﾃﾞｵ歌詞付き", @"", @""},
    };
    for (size_t i = 0; i < sizeof(rows) / sizeof(rows[0]); i++) {
        YTMUStringRow r = rows[i];
        YTMU_ASSERT_EQ_STR(YTMULyricsNormalizeLoose(r.in), r.loose);
        YTMU_ASSERT_EQ_STR(YTMULyricsCompactString(r.in), r.compact);
        YTMU_ASSERT_EQ_STR(YTMULyricsStripSearchNoise(r.in), r.stripped);
        YTMU_ASSERT_EQ_STR([YTMULyricsSplitArtists(r.in, nil) componentsJoinedByString:@"|"], r.artists);
    }
}

YTMU_TEST(StringUtils_golden_similarity) {
    static YTMUSimRow rows[] = {
    {@"iPod Touch", @"iPod Touch (iPod Touch)", 0.940000},
    {@"ハテ", @"ハテ - Terminal", 0.200000},
    {@"Hi Ren", @"Hi Ren (Official Audio)", 0.940000},
    {@"Terminal", @"タイムカプセル", 0.000000},
    {@"abc", @"abd", 0.666667},
    {@"", @"x", 0.000000},
    {@"Ex Luna Scientia", @"Ex Luna Scientia", 1.000000},
    {@"夜に駆ける", @"夜に駆ける / YOASOBI", 0.940000},
    {@"Café", @"Cafe", 1.000000},
    {@"AB", @"ab", 1.000000},
    };
    for (size_t i = 0; i < sizeof(rows) / sizeof(rows[0]); i++) {
        double got = (double)YTMULyricsSimilarity(rows[i].a, rows[i].b);
        YTMU_ASSERT(fabs(got - rows[i].sim) < 1e-5, "similarity(%@, %@) = %.6f, expected %.6f", rows[i].a, rows[i].b, got, rows[i].sim);
    }
}

YTMU_TEST(StringUtils_golden_textProcessorClassifiers) {
    static YTMUTPRow rows[] = {
    {@"こんにちは 世界", 1, 1, 1, 1, 1},
    {@"안녕하세요", 0, 0, 0, 1, 1},
    {@"สวัสดี", 0, 0, 0, 1, 1},
    {@"Hello", 0, 0, 0, 0, 0},
    {@"[Chorus]", 0, 0, 0, 0, 0},
    {@"(intro)", 0, 0, 0, 0, 0},
    {@"漢字だけ", 1, 1, 1, 1, 1},
    {@"ひらがな", 0, 1, 0, 1, 1},
    };
    for (size_t i = 0; i < sizeof(rows) / sizeof(rows[0]); i++) {
        YTMUTPRow r = rows[i];
        YTMU_ASSERT_EQ_INT([YTMULyricsTextProcessor hasChinese:r.in], r.chinese);
        YTMU_ASSERT_EQ_INT([YTMULyricsTextProcessor hasJapaneseKana:r.in], r.kana);
        YTMU_ASSERT_EQ_INT([YTMULyricsTextProcessor hasCJKIdeograph:r.in], r.cjk);
        YTMU_ASSERT_EQ_INT([YTMULyricsTextProcessor hasRomanizableText:r.in], r.romanizable);
        YTMU_ASSERT_EQ_INT([YTMULyricsTextProcessor needsRomanizationForText:r.in preferredLanguage:@"auto"], r.needsRoman);
    }
    YTMU_ASSERT_EQ_STR([YTMULyricsTextProcessor canonicalize:@"  a  ( b ) , c  - d  "], @"a (b), c-d");
}

YTMU_TEST(StringUtils_nilAndEmptyInputs_neverMatch) {
    NSString *nilString = nil;   // typed variable sidesteps the compile-time nonnull check
    YTMU_ASSERT(![YTMULyricsTextProcessor hasChinese:nilString], "nil must not match");
    YTMU_ASSERT(![YTMULyricsTextProcessor hasRomanizableText:@""], "empty must not match");
    YTMU_ASSERT(!YTMULyricsRegexMatches(nilString, @"a", 0), "nil must not match");
    YTMU_ASSERT(!YTMULyricsRegexMatches(@"", @"a", 0), "empty must not match");
    YTMU_ASSERT(YTMULyricsRegexMatches(@"xAx", @"a", NSRegularExpressionCaseInsensitive), "case-insensitive option must apply");
    YTMU_ASSERT(!YTMULyricsRegexMatches(@"xAx", @"a", 0), "case-sensitive by default");
    YTMU_ASSERT(YTMULyricsCachedRegex(@"[", 0) == nil, "invalid pattern must yield nil, not crash");
    YTMU_ASSERT(YTMULyricsCachedRegex(@"\\s+", 0) == YTMULyricsCachedRegex(@"\\s+", 0), "same pattern must be cached");
}

YTMU_TEST(StringUtils_similarityLoop_isFast) {
    // A NetEase-sized scoring workload: 160 candidates × 8 title variants.
    NSMutableArray *candidates = [NSMutableArray array];
    for (int i = 0; i < 160; i++) [candidates addObject:[NSString stringWithFormat:@"候補曲 %d (feat. Artist %d) Official", i, i % 7]];
    NSArray *titles = @[@"候補曲 12", @"Terminal", @"ハテ", @"タイムカプセル", @"夜に駆ける", @"Song", @"Official Video", @"候補曲 150 (feat. Artist 3)"];
    CFTimeInterval t0 = CACurrentMediaTime();
    double acc = 0;
    for (NSString *c in candidates) for (NSString *t in titles) acc += YTMULyricsSimilarity(c, t);
    double ms = (CACurrentMediaTime() - t0) * 1000.0;
    printf("        1280 similarity calls: %.1f ms (acc=%.1f)\n", ms, acc);
    YTMU_ASSERT(ms < 400, "similarity loop too slow: %.1f ms", ms);
}
