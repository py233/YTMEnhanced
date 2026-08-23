#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString *const YTMULyricsSourceYTMusic;
extern NSString *const YTMULyricsSourceLRCLib;
extern NSString *const YTMULyricsSourceNetEase;
extern NSString *const YTMULyricsSourceMusixMatch;
extern NSString *const YTMULyricsSourceGenius;
// Synthetic provider that uses the user's LLM to extract lyrics that the
// uploader pasted into the YouTube video description. No timestamps —
// surfaces as plain (non-karaoke) lyrics. Always last in the chain.
extern NSString *const YTMULyricsSourceDescription;

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
@property (nonatomic, copy) NSString *romanizedText;
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
@property (nonatomic, copy) NSArray<NSString *> *romanizedLineTexts;
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
// Truncated YouTube video shortDescription. Many doujin/cover/individual
// uploads on YouTube Music carry the real staff list (曲: ... / 唄: ...
// / 作詞: ...) here even when the title/author look misleading. We only
// feed it to the AI title normalizer; the lyrics providers themselves
// don't read this field.
@property (nonatomic, copy) NSString *shortDescription;
@end

@protocol YTMULyricsProvider <NSObject>
- (NSString *)providerName;
- (void)searchWithInfo:(YTMULyricsSearchInfo *)info
            completion:(void(^)(YTMULyricsResult *_Nullable result, NSError *_Nullable error))completion;
@end

BOOL YTMULyricsDebugLoggingEnabled(void);
void YTMULyricsLogImpl(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
// Macro, not a function, so the argument expressions are only evaluated
// when logging is actually on — several call sites pass things like
// `manager.displayLineTexts.count`, which re-splits the whole lyric.
#define YTMULyricsLog(...) do { if (YTMULyricsDebugLoggingEnabled()) YTMULyricsLogImpl(__VA_ARGS__); } while (0)

NSString *YTMULyricsSettingsString(NSString *key, NSString *fallback);
BOOL YTMULyricsSettingsBool(NSString *key, BOOL fallback);
NSInteger YTMULyricsSettingsInteger(NSString *key, NSInteger fallback);
void YTMULyricsSetDefault(NSMutableDictionary *dict, NSString *key, id value);
NSInteger YTMULyricsClampTimingOffsetMs(NSInteger value);
NSString *YTMULyricsTimingOffsetKeyForInfo(YTMULyricsSearchInfo *info);
NSInteger YTMULyricsTimingOffsetForKey(NSString *key);
NSInteger YTMULyricsCurrentTimingOffsetForKey(NSString *key);
void YTMULyricsActivateTimingOffsetForInfo(YTMULyricsSearchInfo *info, BOOL notify);
void YTMULyricsSetTimingOffsetForKey(NSString *key, NSInteger value, BOOL notify);

// Process-wide cache of compiled regexes keyed by (pattern, options).
// NSRegularExpression compilation costs tens of microseconds and the
// matching helpers below run inside O(candidates × titles) scoring loops,
// so every pattern literal in the lyrics code goes through this instead
// of +regularExpressionWithPattern:. Thread-safe; returns nil only for an
// invalid pattern (all callers pass literals).
NSRegularExpression *_Nullable YTMULyricsCachedRegex(NSString *pattern, NSRegularExpressionOptions options);
// `value` matches `pattern` anywhere (regex search). Same truth table as
// [value rangeOfString:pattern options:NSRegularExpressionSearch|…].location != NSNotFound.
BOOL YTMULyricsRegexMatches(NSString *_Nullable value, NSString *pattern, NSRegularExpressionOptions options);

NSString *YTMULyricsNormalizeLoose(NSString *value);
NSString *YTMULyricsCompactString(NSString *value);
CGFloat YTMULyricsSimilarity(NSString *left, NSString *right);
NSArray<NSString *> *YTMULyricsSplitArtists(NSString *artist, NSArray<NSString *> *_Nullable tags);
NSString *YTMULyricsStripSearchNoise(NSString *value);
NSString *YTMULyricsEncodeQuery(NSString *value);
NSString *YTMULyricsJSONStringFromObject(id object);
id _Nullable YTMULyricsJSONValueAtPath(id _Nullable object, NSArray *path);
NSDictionary *_Nullable YTMULyricsJSONDictionaryAtPath(id _Nullable object, NSArray *path);
NSArray *_Nullable YTMULyricsJSONArrayAtPath(id _Nullable object, NSArray *path);
NSString *_Nullable YTMULyricsJSONStringAtPath(id _Nullable object, NSArray *path);
NSNumber *_Nullable YTMULyricsJSONNumberAtPath(id _Nullable object, NSArray *path);

NS_ASSUME_NONNULL_END
