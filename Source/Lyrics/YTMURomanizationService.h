#import <Foundation/Foundation.h>
#import "YTMULyricsTypes.h"

NS_ASSUME_NONNULL_BEGIN

// Per-line romanization (Japanese / Korean / Thai / Indic → Latin) through
// Google's public transliteration endpoint, with a small in-memory cache.
// Pure service: it knows nothing about the manager's state — the manager
// asks for romanized lines and decides what to do with them.
@interface YTMURomanizationService : NSObject

+ (instancetype)sharedService;

// Base URL of the transliteration endpoint. Defaults to
// https://translate.googleapis.com; the host tests point it at an
// in-process server.
@property (nonatomic, copy) NSString *endpointBaseURL;

// "ja" when any line carries kana (Google's auto-detect confuses kanji-only
// lines with Chinese), otherwise "auto".
- (NSString *)sourceLanguageForLines:(NSArray<NSString *> *)lines;

// Lines that still need romanization: index + trimmed text for every line
// that is non-empty, not yet romanized (`existing`), and in a script the
// text processor says needs it.
- (NSArray<NSDictionary *> *)romanizableItemsForLines:(NSArray<NSString *> *)lines
                                            existing:(nullable NSArray<NSString *> *)existing
                                      sourceLanguage:(NSString *)sourceLanguage;

// Memory cache keyed by video + source + the lines themselves.
- (NSString *)cacheKeyForVideoId:(NSString *)videoId source:(NSString *)source lines:(NSArray<NSString *> *)lines;
- (nullable NSArray<NSString *> *)cachedLinesForKey:(NSString *)key;
- (void)storeLines:(nullable NSArray<NSString *> *)lines forKey:(NSString *)key;   // nil/empty removes
- (void)clearMemoryCache;

// Romanizes up to `limit` items with bounded concurrency, writing each
// result into `romanized[item.index]` (the array is shared, writes are
// synchronised) and calling `completion` on the main queue with a copy once
// all items are done or skipped. `shouldContinue` is consulted before each
// request so an abandoned batch stops issuing network calls.
- (void)romanizeItems:(NSArray<NSDictionary *> *)items
                limit:(NSUInteger)limit
       sourceLanguage:(NSString *)sourceLanguage
                 into:(NSMutableArray<NSString *> *)romanized
       shouldContinue:(nullable BOOL (^)(void))shouldContinue
           completion:(void (^)(NSArray<NSString *> *romanized))completion;

// One line → its transliteration ("" on any failure). Completion on an
// arbitrary queue.
- (void)romanizeText:(NSString *)text sourceLanguage:(NSString *)sourceLanguage completion:(void (^)(NSString *romanized))completion;

@end

NS_ASSUME_NONNULL_END
