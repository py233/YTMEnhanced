#import <Foundation/Foundation.h>
#import <rootless.h>

NS_ASSUME_NONNULL_BEGIN

@interface NSBundle (YTMusicUltimate)

@property (class, nonatomic, readonly) NSBundle *ytmu_defaultBundle;

@end

// Shorthand for looking up a localized string from the YTMUltimate bundle
// with a hard-coded English fallback. Use this in places that can't import
// the LOC() macro (e.g. provider .m files that emit NSError descriptions).
FOUNDATION_EXPORT NSString *YTMULocalized(NSString *key, NSString *fallback);

NS_ASSUME_NONNULL_END