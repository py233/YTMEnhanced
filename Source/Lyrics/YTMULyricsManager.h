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

@end

NS_ASSUME_NONNULL_END
