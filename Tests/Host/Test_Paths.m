// Guards the test-suite invariant that no test can write into the real
// ~/Library/Caches: YTMU_CACHES_ROOT must be honoured by every cache owner.
#import "YTMUTestKit.h"
#import "Utils/YTMUPaths.h"

YTMU_TEST(Paths_cachesRoot_honoursEnvironmentOverride) {
    NSString *override = [[NSProcessInfo processInfo] environment][@"YTMU_CACHES_ROOT"];
    YTMU_ASSERT(override.length > 0, "run the suite via Tests/Host/run.sh, which sets YTMU_CACHES_ROOT");
    NSString *root = YTMUCachesDirectory();
    YTMU_ASSERT([root hasPrefix:override], "cache root %@ does not live under override %@", root, override);
    YTMU_ASSERT([root hasSuffix:@"/YTMUltimate"], "cache root should end in /YTMUltimate, got %@", root);
    NSString *real = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    YTMU_ASSERT(![root hasPrefix:real], "cache root must not point at the real Caches dir (%@)", real);
    YTMU_ASSERT_EQ_STR(YTMUCachesSubdirectory(@"Lyrics"), [root stringByAppendingPathComponent:@"Lyrics"]);
}
