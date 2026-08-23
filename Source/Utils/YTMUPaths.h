#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Root under which every YTMUltimate on-disk cache lives, i.e.
// <Caches>/YTMUltimate. All cache owners (lyrics, translation, InnerTube,
// title-normalize, description-extract) derive their directory from this so
// "clear cache" and the host test-suite only need one knob.
//
// The host tests set YTMU_CACHES_ROOT to a temp dir so they never touch the
// developer's real Caches folder; the variable is never set on device.
NSString *YTMUCachesDirectory(void);

// Convenience: YTMUCachesDirectory() + "/" + name.
NSString *YTMUCachesSubdirectory(NSString *name);

NS_ASSUME_NONNULL_END
