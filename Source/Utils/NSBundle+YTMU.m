#import "NSBundle+YTMU.h"

@implementation NSBundle (YTMusicUltimate)

+ (NSBundle *)ytmu_defaultBundle {
    static NSBundle *bundle = nil;
    static dispatch_once_t onceToken;

    dispatch_once(&onceToken, ^{
        NSString *tweakBundlePath = [[NSBundle mainBundle] pathForResource:@"YTMusicUltimate" ofType:@"bundle"];
        NSString *rootlessBundlePath = ROOT_PATH_NS(@"/Library/Application Support/YTMusicUltimate.bundle");

        bundle = [NSBundle bundleWithPath:tweakBundlePath ?: rootlessBundlePath];
    });

    return bundle;
}

@end

NSString *YTMULocalized(NSString *key, NSString *fallback) {
    // A missing bundle (packaging slip, or the host test binary) must still
    // yield the inline fallback rather than nil — callers put the result
    // straight into dictionary literals and labels.
    return [NSBundle.ytmu_defaultBundle localizedStringForKey:key value:fallback table:nil] ?: (fallback ?: key);
}