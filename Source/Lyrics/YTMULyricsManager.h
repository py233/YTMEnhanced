#import <Foundation/Foundation.h>
#import "YTMULyricsTypes.h"

NS_ASSUME_NONNULL_BEGIN

@interface YTMULyricsManager : NSObject

@property (nonatomic, readonly) YTMULyricsFetchState state;
@property (nonatomic, copy, readonly) NSString *activeVideoId;
@property (nonatomic, strong, readonly, nullable) YTMULyricsSearchInfo *lastSearchInfo;
@property (nonatomic, strong, readonly, nullable) YTMULyricsResult *currentResult;
@property (nonatomic, copy, readonly) NSArray<NSString *> *translatedLines;
@property (nonatomic, copy, readonly) NSString *translationAttribution;
@property (nonatomic, copy, readonly) NSString *lastErrorMessage;
@property (nonatomic, copy, readonly) NSDictionary<NSString *, NSString *> *sourceAvailability;

+ (instancetype)sharedManager;
- (void)refreshWithInfo:(YTMULyricsSearchInfo *)info;
- (void)clearCurrent;
- (void)clearRomanizationCache;
- (NSArray<NSString *> *)displayLineTexts;

// One line per provider: when it last returned lyrics and when it last
// failed (error or timeout). For the debug log and the settings screen.
- (NSString *)providerHealthSummary;

@end

NS_ASSUME_NONNULL_END
