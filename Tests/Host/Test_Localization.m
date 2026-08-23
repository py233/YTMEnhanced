#import "YTMUTestKit.h"
#import "Utils/NSBundle+YTMU.h"

YTMU_TEST(Localization_bundleIsFound_andFallbacksHold) {
    YTMU_ASSERT(NSBundle.ytmu_defaultBundle != nil, "YTMusicUltimate.bundle should ship inside the test app");
    NSString *real = YTMULocalized(@"LYRICS_ERROR_LRCLIB_TIMEOUT", @"__fallback__");
    YTMU_ASSERT(real.length && ![real isEqualToString:@"__fallback__"], "known key should resolve from the bundle, got %@", real);
    YTMU_ASSERT_EQ_STR(YTMULocalized(@"NO_SUCH_KEY_XYZ", @"inline"), @"inline");
    // every locale must carry the same key set (the AGENTS.md invariant)
    NSArray<NSString *> *lprojs = [NSBundle.ytmu_defaultBundle pathsForResourcesOfType:@"lproj" inDirectory:nil];
    YTMU_ASSERT_EQ_INT(lprojs.count, 14);
    NSCountedSet *keyCounts = [NSCountedSet set];
    for (NSString *lproj in lprojs) {
        NSDictionary *table = [NSDictionary dictionaryWithContentsOfFile:[lproj stringByAppendingPathComponent:@"Localizable.strings"]];
        YTMU_ASSERT(table.count > 0, "empty strings table in %@", lproj.lastPathComponent);
        [keyCounts addObject:@(table.count)];
    }
    YTMU_ASSERT_EQ_INT(keyCounts.count, 1);   // one distinct key count across all locales
}
