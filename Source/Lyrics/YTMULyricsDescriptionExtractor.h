#import <Foundation/Foundation.h>
#import "YTMULyricsTypes.h"
#import "../Translation/YTMUTranslationTypes.h"

NS_ASSUME_NONNULL_BEGIN

// Result of pulling lyrics out of a YouTube video description block.
//
// `sourceLines` is the verbatim lyrics in the video's original language,
// already split into per-line strings (empty trailing/leading items
// stripped). Empty if the description didn't contain real lyrics.
//
// `translatedLines` is populated only when the uploader bundled an
// existing translation in the same description (e.g. doujin uploaders
// pasting 日中 or 日英 side-by-side). We never machine-translate here —
// that's the manager's translation pipeline's job. Either matches
// `sourceLines.count` or is empty.
@interface YTMULyricsDescriptionExtraction : NSObject
@property (nonatomic, copy) NSArray<NSString *> *sourceLines;
@property (nonatomic, copy) NSString *language;
@property (nonatomic, copy) NSArray<NSString *> *translatedLines;
@property (nonatomic, copy) NSString *translationLanguage;
@property (nonatomic) double confidence;
@end

typedef void(^YTMULyricsDescriptionExtractorCompletion)(YTMULyricsDescriptionExtraction *_Nullable extraction, NSError *_Nullable error);

@interface YTMULyricsDescriptionExtractor : NSObject

+ (instancetype)sharedExtractor;

- (void)extractForInfo:(YTMULyricsSearchInfo *)info
              provider:(id<YTMULLMCompletionProvider>)provider
          providerName:(NSString *)providerName
            completion:(YTMULyricsDescriptionExtractorCompletion)completion;

// Cache lookup without firing an AI call. Returns nil if not cached.
- (nullable YTMULyricsDescriptionExtraction *)cachedExtractionForInfo:(YTMULyricsSearchInfo *)info;

- (void)clearCache;

@end

NS_ASSUME_NONNULL_END
