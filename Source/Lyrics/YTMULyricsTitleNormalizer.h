#import <Foundation/Foundation.h>
#import "YTMULyricsTypes.h"
#import "../Translation/YTMUTranslationTypes.h"

NS_ASSUME_NONNULL_BEGIN

// Result returned by the normalizer. titleCandidates / artistCandidates are
// always non-empty if the call succeeded — the primary candidate is at
// index 0, alternates follow. The manager cross-products them when retrying
// the lyrics providers.
@interface YTMULyricsTitleNormalization : NSObject
@property (nonatomic, copy) NSArray<NSString *> *titleCandidates;
@property (nonatomic, copy) NSArray<NSString *> *artistCandidates;
@property (nonatomic, copy) NSString *language;     // ISO 639-1 code or "" if unknown
@property (nonatomic) double confidence;            // 0.0–1.0 from the model
@end

typedef void (^YTMULyricsTitleNormalizerCompletion)(YTMULyricsTitleNormalization *_Nullable result, NSError *_Nullable error);

@interface YTMULyricsTitleNormalizer : NSObject

+ (instancetype)sharedNormalizer;

// Returns the cached normalization synchronously if there is one; otherwise
// nil. Manager uses this to decide whether to wait on AI before kicking off
// the AI re-pass.
- (nullable YTMULyricsTitleNormalization *)cachedNormalizationForInfo:(YTMULyricsSearchInfo *)info;

// Same, but a cached entry only counts when it was produced for the same
// raw title/artist the caller has now. The lyrics path uses this: YouTube
// Music's metadata flickers for a moment after a song change (new videoId,
// previous song's title), and a normalization computed from the wrong
// title must not be served for that videoId forever. The scrobble
// resolver asks with already-cleaned metadata and keeps the lenient form.
- (nullable YTMULyricsTitleNormalization *)cachedNormalizationForInfo:(YTMULyricsSearchInfo *)info
                                              requireRawMetadataMatch:(BOOL)requireRawMetadataMatch;

// Hits the LLM and persists the result on success. provider must conform to
// YTMULLMCompletionProvider; providerName is used purely for logging. The
// completion runs on the main queue. On any failure (network, HTTP, parse)
// the error is non-nil and result is nil — the caller should fall back to
// raw title/artist.
- (void)normalizeForInfo:(YTMULyricsSearchInfo *)info
                provider:(id<YTMULLMCompletionProvider>)provider
            providerName:(NSString *)providerName
              completion:(YTMULyricsTitleNormalizerCompletion)completion;

// As above; `requireRawMetadataMatch` selects which cached entries are
// accepted before the LLM is asked (see -cachedNormalizationForInfo:…).
- (void)normalizeForInfo:(YTMULyricsSearchInfo *)info
                provider:(id<YTMULLMCompletionProvider>)provider
            providerName:(NSString *)providerName
 requireRawMetadataMatch:(BOOL)requireRawMetadataMatch
              completion:(YTMULyricsTitleNormalizerCompletion)completion;

// Wipe the persisted normalizations. Hooked into the existing "Clear
// lyrics and translation cache" button.
- (void)clearCache;

@end

NS_ASSUME_NONNULL_END
