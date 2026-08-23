#import "YTMUDescriptionProvider.h"
#import "../YTMULyricsDescriptionExtractor.h"
#import "../../Translation/YTMUTranslator.h"
#import "../../Utils/NSBundle+YTMU.h"

@implementation YTMUDescriptionProvider

- (NSString *)providerName {
    return YTMULyricsSourceDescription;
}

- (void)searchWithInfo:(YTMULyricsSearchInfo *)info completion:(void (^)(YTMULyricsResult *, NSError *))completion {
    if (!info.shortDescription.length) {
        completion(nil, [NSError errorWithDomain:@"YTMUDescription"
                                            code:1
                                        userInfo:@{NSLocalizedDescriptionKey: YTMULocalized(@"LYRICS_ERROR_NO_DESCRIPTION", @"no description available")}]);
        return;
    }

    id<YTMULLMCompletionProvider> llm = [[YTMUTranslator sharedTranslator] currentLLMCompletionProvider];
    if (!llm) {
        // No LLM configured — silently miss. The user either has Google
        // Translate selected (no chat completion) or hasn't set up a key.
        completion(nil, [NSError errorWithDomain:@"YTMUDescription"
                                            code:2
                                        userInfo:@{NSLocalizedDescriptionKey: YTMULocalized(@"LYRICS_ERROR_NO_LLM", @"no LLM provider configured")}]);
        return;
    }

    NSString *providerName = [[YTMUTranslator sharedTranslator] currentProviderName];
    [[YTMULyricsDescriptionExtractor sharedExtractor]
        extractForInfo:info
              provider:llm
          providerName:providerName
            completion:^(YTMULyricsDescriptionExtraction * _Nullable extraction, NSError * _Nullable error) {
        if (error) {
            completion(nil, error);
            return;
        }
        if (!extraction.sourceLines.count) {
            // Cached negative or short-description: legitimate miss.
            completion(nil, [NSError errorWithDomain:@"YTMUDescription"
                                                code:3
                                            userInfo:@{NSLocalizedDescriptionKey: YTMULocalized(@"LYRICS_ERROR_DESCRIPTION_NO_LYRICS", @"description has no lyrics")}]);
            return;
        }

        // Build a plain-only result. lines=@[] keeps isSynced=NO so the
        // UI takes the plain-text rendering path; plainLyrics carries
        // the actual content, lineTexts splits it back out per line.
        NSMutableString *plain = [NSMutableString string];
        for (NSUInteger i = 0; i < extraction.sourceLines.count; i++) {
            if (i > 0) [plain appendString:@"\n"];
            [plain appendString:extraction.sourceLines[i]];
        }

        YTMULyricsResult *result = [[YTMULyricsResult alloc] init];
        result.sourceName = [self providerName];
        result.title = info.title.length ? info.title : @"";
        result.artists = info.artist.length ? @[info.artist] : @[];
        result.plainLyrics = plain;
        result.lines = @[];
        result.duration = info.duration;
        // Not inexact: `inexact` means "title/artist matched fuzzily", and
        // this text came from the video's own description and was verified
        // against it line by line — the song identity is certain even if
        // the extraction is partial. (An earlier comment here said the
        // opposite of what the code does; the code was right.)
        result.inexact = NO;

        // If the uploader provided a side-by-side translation in the
        // same description, hand it through as an "official" translation
        // — the manager's translation pipeline will pick it up just like
        // it does for NetEase's tlyric.
        if (extraction.translatedLines.count == extraction.sourceLines.count &&
            extraction.translatedLines.count > 0) {
            result.officialTranslatedLines = extraction.translatedLines;
            result.officialTranslationLanguage = extraction.translationLanguage ?: @"";
            result.officialTranslationProvider = @"uploader";
        }

        completion(result, nil);
    }];
}

@end
