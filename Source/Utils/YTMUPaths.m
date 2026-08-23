#import "YTMUPaths.h"

NSString *YTMUCachesDirectory(void) {
    static NSString *root;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *override = [[NSProcessInfo processInfo] environment][@"YTMU_CACHES_ROOT"];
        NSString *base = override.length
            ? override
            : NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
        root = [base stringByAppendingPathComponent:@"YTMUltimate"];
    });
    return root;
}

NSString *YTMUCachesSubdirectory(NSString *name) {
    return [YTMUCachesDirectory() stringByAppendingPathComponent:name];
}
