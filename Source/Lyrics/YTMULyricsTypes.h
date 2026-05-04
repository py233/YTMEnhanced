#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString *const YTMULyricsSourceYTMusic;
extern NSString *const YTMULyricsSourceLRCLib;
extern NSString *const YTMULyricsSourceNetEase;
extern NSString *const YTMULyricsSourceMusixMatch;
extern NSString *const YTMULyricsSourceGenius;

extern NSString *const YTMULyricsDidUpdateNotification;
extern NSString *const YTMULyricsStateDidChangeNotification;
extern NSString *const YTMULyricsSettingsDidChangeNotification;
extern NSString *const YTMULyricsSettingChangedKey;

typedef NS_ENUM(NSInteger, YTMULyricsFetchState) {
    YTMULyricsFetchStateIdle = 0,
    YTMULyricsFetchStateFetching = 1,
    YTMULyricsFetchStateDone = 2,
    YTMULyricsFetchStateError = 3,
};

@interface YTMULyricLine : NSObject <NSCopying, NSSecureCoding>
@property (nonatomic, copy) NSString *time;
@property (nonatomic) NSTimeInterval timeInMs;
@property (nonatomic) NSTimeInterval durationMs;
@property (nonatomic, copy) NSString *text;
+ (instancetype)lineWithTime:(NSString *)time
                    timeInMs:(NSTimeInterval)timeInMs
                  durationMs:(NSTimeInterval)durationMs
                        text:(NSString *)text;
@end

@interface YTMULyricsResult : NSObject <NSCopying, NSSecureCoding>
@property (nonatomic, copy) NSString *sourceName;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSArray<NSString *> *artists;
@property (nonatomic, copy) NSString *plainLyrics;
@property (nonatomic, copy) NSArray<YTMULyricLine *> *lines;
@property (nonatomic, copy) NSArray<NSString *> *officialTranslatedLines;
@property (nonatomic, copy) NSString *officialTranslationLanguage;
@property (nonatomic, copy) NSString *officialTranslationProvider;
@property (nonatomic) NSTimeInterval duration;
@property (nonatomic) BOOL inexact;
- (NSArray<NSString *> *)lineTexts;
- (BOOL)hasText;
- (BOOL)isSynced;
@end

@interface YTMULyricsSearchInfo : NSObject <NSCopying>
@property (nonatomic, copy) NSString *videoId;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *alternativeTitle;
@property (nonatomic, copy) NSString *artist;
@property (nonatomic, copy) NSString *album;
@property (nonatomic) NSTimeInterval duration;
@property (nonatomic, copy) NSArray<NSString *> *tags;
@end

@protocol YTMULyricsProvider <NSObject>
- (NSString *)providerName;
- (void)searchWithInfo:(YTMULyricsSearchInfo *)info
            completion:(void(^)(YTMULyricsResult *_Nullable result, NSError *_Nullable error))completion;
@end

BOOL YTMULyricsDebugLoggingEnabled(void);
void YTMULyricsLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);

NSString *YTMULyricsSettingsString(NSString *key, NSString *fallback);
BOOL YTMULyricsSettingsBool(NSString *key, BOOL fallback);
NSInteger YTMULyricsSettingsInteger(NSString *key, NSInteger fallback);
void YTMULyricsSetDefault(NSMutableDictionary *dict, NSString *key, id value);

NSString *YTMULyricsNormalizeLoose(NSString *value);
NSString *YTMULyricsCompactString(NSString *value);
CGFloat YTMULyricsSimilarity(NSString *left, NSString *right);
NSArray<NSString *> *YTMULyricsSplitArtists(NSString *artist, NSArray<NSString *> *_Nullable tags);
NSString *YTMULyricsStripSearchNoise(NSString *value);
NSString *YTMULyricsEncodeQuery(NSString *value);
NSString *YTMULyricsJSONStringFromObject(id object);

NS_ASSUME_NONNULL_END
