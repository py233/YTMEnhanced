#import "YTMUTranslator.h"
#import "YTMUTranslationCache.h"
#import "YTMUPromptBuilder.h"
#import "Providers/YTMUGoogleTranslateProvider.h"
#import "Providers/YTMUAnthropicProvider.h"
#import "Providers/YTMUGeminiProvider.h"
#import "Providers/YTMUOpenAIProvider.h"

@interface YTMUTranslator ()
@property (nonatomic, strong) NSDictionary<NSString *, id<YTMUTranslationProvider>> *providers;
@end

static NSError *YTMUTranslatorError(YTMUTranslationErrorCode code, NSString *message) {
    return [NSError errorWithDomain:YTMUTranslationErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: message ?: @"Translation failed"}];
}

static NSDictionary *YTMUSettingsDictionary(void) {
    return [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"YTMUltimate"] ?: @{};
}

static NSString *YTMUSettingsString(NSString *key, NSString *fallback) {
    id value = YTMUSettingsDictionary()[key];
    if ([value isKindOfClass:[NSString class]] && [(NSString *)value length]) return value;
    return fallback ?: @"";
}

static void YTMUCompleteOnMain(void (^block)(void)) {
    if ([NSThread isMainThread]) {
        block();
    } else {
        dispatch_async(dispatch_get_main_queue(), block);
    }
}

@implementation YTMUTranslator

+ (instancetype)sharedTranslator {
    static YTMUTranslator *translator;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        translator = [[self alloc] init];
    });
    return translator;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        id<YTMUTranslationProvider> google = [[YTMUGoogleTranslateProvider alloc] init];
        id<YTMUTranslationProvider> anthropic = [[YTMUAnthropicProvider alloc] init];
        id<YTMUTranslationProvider> gemini = [[YTMUGeminiProvider alloc] init];
        id<YTMUTranslationProvider> openai = [[YTMUOpenAIProvider alloc] init];
        _providers = @{
            [google providerName]: google,
            [anthropic providerName]: anthropic,
            [gemini providerName]: gemini,
            [openai providerName]: openai,
        };
    }
    return self;
}

- (NSString *)currentProviderName {
    return YTMUSettingsString(@"translationProvider", YTMUTranslationProviderGoogle);
}

- (id<YTMULLMCompletionProvider>)currentLLMCompletionProvider {
    NSString *name = [self currentProviderName];
    if ([name isEqualToString:YTMUTranslationProviderGoogle]) return nil; // Google Translate has no chat completion
    id<YTMUTranslationProvider> provider = self.providers[name];
    if (![provider conformsToProtocol:@protocol(YTMULLMCompletionProvider)]) return nil;
    // Make sure the provider has the credentials it needs. We can only
    // know that by reading the same UserDefaults keys each provider
    // checks; rather than duplicate that knowledge here, a missing key
    // surfaces as YTMUTranslationErrorMissingAPIKey from the actual
    // call, and the normalizer treats that as a network failure (silent
    // fallback to raw, no blacklist).
    return (id<YTMULLMCompletionProvider>)provider;
}

- (YTMUTranslationRequest *)requestWithLines:(NSArray<NSString *> *)lines
                                      title:(NSString *)title
                                     artist:(NSString *)artist
                                targetCode:(NSString *)targetCode {
    YTMUTranslationRequest *request = [[YTMUTranslationRequest alloc] init];
    request.title = title ?: @"";
    request.artists = artist.length ? @[artist] : @[];
    request.targetLanguageCode = targetCode ?: @"en";
    request.resolvedTargetLanguage = [YTMUPromptBuilder resolveLanguageName:request.targetLanguageCode];
    request.lines = lines ?: @[];
    return request;
}

- (BOOL)shouldFallbackPerLineForError:(NSError *)error lineCount:(NSUInteger)lineCount {
    if (lineCount > 8) return NO;
    NSString *message = error.localizedDescription ?: @"";
    NSRange range = [message rangeOfString:@"parse|json|line|length|number of lines"
                                   options:NSRegularExpressionSearch | NSCaseInsensitiveSearch];
    return range.location != NSNotFound ||
           error.code == YTMUTranslationErrorParse ||
           error.code == YTMUTranslationErrorLineCount;
}

- (NSError *)lineCountErrorForTranslated:(NSArray<NSString *> *)translated expected:(NSUInteger)expected {
    return YTMUTranslatorError(YTMUTranslationErrorLineCount,
                               [NSString stringWithFormat:@"Translation returned %lu lines; expected %lu",
                                (unsigned long)translated.count,
                                (unsigned long)expected]);
}

- (void)storeTranslatedLines:(NSArray<NSString *> *)translated
                    cacheKey:(NSString *)cacheKey
                     videoId:(NSString *)videoId
                    language:(NSString *)language
                    provider:(id<YTMUTranslationProvider>)provider
                       lines:(NSArray<NSString *> *)lines {
    YTMUTranslationCacheEntry *entry = [[YTMUTranslationCacheEntry alloc] init];
    entry.cacheKey = cacheKey;
    entry.strategyVersion = YTMUTranslationStrategyVersion;
    entry.videoId = videoId ?: @"";
    entry.targetLanguage = language ?: @"";
    entry.provider = [provider providerName] ?: @"";
    entry.model = [provider modelIdentifier] ?: @"";
    entry.sourceHash = [YTMUTranslationCache sourceHashForLines:lines];
    entry.lineCount = lines.count;
    entry.sourceLines = lines ?: @[];
    entry.translatedLines = translated ?: @[];
    entry.createdAt = [[NSDate date] timeIntervalSince1970];
    [[YTMUTranslationCache sharedCache] storeEntry:entry];
}

- (void)fallbackPerLineWithProvider:(id<YTMUTranslationProvider>)provider
                            request:(YTMUTranslationRequest *)request
                           cacheKey:(NSString *)cacheKey
                            videoId:(NSString *)videoId
                           language:(NSString *)language
                         firstError:(NSError *)firstError
                         completion:(void(^)(NSArray<NSString *> *_Nullable translatedLines, NSError *_Nullable error))completion {
    NSMutableArray *results = [NSMutableArray arrayWithCapacity:request.lines.count];
    for (NSUInteger i = 0; i < request.lines.count; i++) {
        [results addObject:@""];
    }

    __block NSError *lineError = nil;
    dispatch_group_t group = dispatch_group_create();
    [request.lines enumerateObjectsUsingBlock:^(NSString *line, NSUInteger idx, BOOL *stop) {
        dispatch_group_enter(group);
        YTMUTranslationRequest *lineRequest = [self requestWithLines:@[line]
                                                               title:request.title
                                                              artist:request.artists.firstObject
                                                          targetCode:request.targetLanguageCode];
        [provider translateRequest:lineRequest completion:^(NSArray<NSString *> *translated, NSError *error) {
            @synchronized (results) {
                if (error && !lineError) lineError = error;
                results[idx] = translated.firstObject ?: @"";
            }
            dispatch_group_leave(group);
        }];
    }];

    dispatch_group_notify(group, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        if (lineError) {
            YTMUTranslationLog(@"per-line fallback failed videoId=%@ provider=%@ error=%@",
                               videoId.length ? videoId : @"<empty>",
                               [provider providerName],
                               lineError.localizedDescription ?: @"<unknown>");
            YTMUCompleteOnMain(^{
                completion(nil, firstError ?: lineError);
            });
            return;
        }

        NSArray *translated = [results copy];
        YTMUTranslationLog(@"per-line fallback success videoId=%@ provider=%@ lines=%lu",
                           videoId.length ? videoId : @"<empty>",
                           [provider providerName],
                           (unsigned long)translated.count);
        [self storeTranslatedLines:translated
                          cacheKey:cacheKey
                           videoId:videoId
                          language:language
                          provider:provider
                             lines:request.lines];
        YTMUCompleteOnMain(^{
            completion(translated, nil);
        });
    });
}

// Threshold above which we split the song into fixed-size translation
// batches. The provider asks the model to return EXACTLY N translated
// lines as JSON; that contract holds reliably for ~40-line slices but
// breaks above ~50–80 lines on every provider tested. Long songs come
// back with merged refrains / dropped interjections / truncated output
// (Anthropic's max_tokens=4096 ceiling especially) and the strict
// line-count check then fails, with no per-line fallback because
// shouldFallbackPerLineForError requires lineCount <= 8.
//
// Chunking lets each batch operate under the conditions where the
// model is reliable, and caches each chunk independently so a partial
// retry doesn't re-translate the whole song.
static const NSUInteger YTMUTranslationBatchThreshold = 50;
static const NSUInteger YTMUTranslationBatchSize = 40;

- (void)translateChunkWithProvider:(id<YTMUTranslationProvider>)provider
                           request:(YTMUTranslationRequest *)chunkRequest
                          cacheKey:(NSString *)chunkCacheKey
                           videoId:(NSString *)videoId
                          language:(NSString *)language
                        attemptsLeft:(NSUInteger)attemptsLeft
                        completion:(void (^)(NSArray<NSString *> *_Nullable, NSError *_Nullable))completion {
    [provider translateRequest:chunkRequest completion:^(NSArray<NSString *> *translated, NSError *error) {
        if (!error && translated.count == chunkRequest.lines.count) {
            [self storeTranslatedLines:translated
                              cacheKey:chunkCacheKey
                               videoId:videoId
                              language:language
                              provider:provider
                                 lines:chunkRequest.lines];
            completion(translated, nil);
            return;
        }
        NSError *thisError = error ?: [self lineCountErrorForTranslated:translated ?: @[]
                                                                expected:chunkRequest.lines.count];
        if (attemptsLeft > 1) {
            [self translateChunkWithProvider:provider
                                     request:chunkRequest
                                    cacheKey:chunkCacheKey
                                     videoId:videoId
                                    language:language
                                attemptsLeft:attemptsLeft - 1
                                  completion:completion];
            return;
        }
        completion(nil, thisError);
    }];
}

- (void)translateInBatchesWithProvider:(id<YTMUTranslationProvider>)provider
                                 lines:(NSArray<NSString *> *)lines
                                 title:(NSString *)title
                                artist:(NSString *)artist
                               videoId:(NSString *)videoId
                              language:(NSString *)language
                            completion:(void (^)(NSArray<NSString *> *_Nullable, NSError *_Nullable))completion {
    NSUInteger total = lines.count;
    NSUInteger batchCount = (total + YTMUTranslationBatchSize - 1) / YTMUTranslationBatchSize;
    NSString *model = [provider modelIdentifier] ?: @"";
    NSString *providerNameStr = [provider providerName] ?: @"";

    YTMUTranslationLog(@"batched translate start videoId=%@ provider=%@ totalLines=%lu batchSize=%lu batches=%lu",
                       videoId.length ? videoId : @"<empty>",
                       providerNameStr,
                       (unsigned long)total,
                       (unsigned long)YTMUTranslationBatchSize,
                       (unsigned long)batchCount);

    NSMutableArray<NSArray<NSString *> *> *batchedResults = [NSMutableArray arrayWithCapacity:batchCount];
    for (NSUInteger i = 0; i < batchCount; i++) [batchedResults addObject:@[]];

    __block NSError *firstError = nil;
    dispatch_group_t group = dispatch_group_create();

    for (NSUInteger i = 0; i < batchCount; i++) {
        NSUInteger start = i * YTMUTranslationBatchSize;
        NSUInteger len = MIN(YTMUTranslationBatchSize, total - start);
        NSArray<NSString *> *chunk = [lines subarrayWithRange:NSMakeRange(start, len)];
        NSString *chunkCacheKey = [YTMUTranslationCache keyForVideoId:videoId
                                                            language:language
                                                            provider:providerNameStr
                                                               model:model
                                                               lines:chunk];

        YTMUTranslationCacheEntry *cached = [[YTMUTranslationCache sharedCache] entryForKey:chunkCacheKey];
        if (cached.translatedLines.count == chunk.count) {
            batchedResults[i] = cached.translatedLines;
            continue;
        }

        dispatch_group_enter(group);
        YTMUTranslationRequest *chunkRequest = [self requestWithLines:chunk
                                                                title:title
                                                               artist:artist
                                                          targetCode:language];
        [self translateChunkWithProvider:provider
                                 request:chunkRequest
                                cacheKey:chunkCacheKey
                                 videoId:videoId
                                language:language
                            attemptsLeft:2
                              completion:^(NSArray<NSString *> *translated, NSError *error) {
            @synchronized (batchedResults) {
                if (translated.count == chunk.count) {
                    batchedResults[i] = translated;
                } else if (!firstError) {
                    firstError = error ?: [self lineCountErrorForTranslated:translated ?: @[] expected:chunk.count];
                }
            }
            dispatch_group_leave(group);
        }];
    }

    dispatch_group_notify(group, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        if (firstError) {
            YTMUTranslationLog(@"batched translate failed videoId=%@ provider=%@ error=%@",
                               videoId.length ? videoId : @"<empty>",
                               providerNameStr,
                               firstError.localizedDescription ?: @"<unknown>");
            YTMUCompleteOnMain(^{ completion(nil, firstError); });
            return;
        }
        NSMutableArray<NSString *> *all = [NSMutableArray arrayWithCapacity:total];
        for (NSArray *batch in batchedResults) [all addObjectsFromArray:batch];
        if (all.count != total) {
            YTMUCompleteOnMain(^{
                completion(nil, [self lineCountErrorForTranslated:all expected:total]);
            });
            return;
        }
        YTMUTranslationLog(@"batched translate success videoId=%@ provider=%@ lines=%lu",
                           videoId.length ? videoId : @"<empty>",
                           providerNameStr,
                           (unsigned long)all.count);
        YTMUCompleteOnMain(^{ completion([all copy], nil); });
    });
}

- (void)translateLines:(NSArray<NSString *> *)lines
               videoId:(NSString *)videoId
                 title:(NSString *)title
                artist:(NSString *)artist
            completion:(void (^)(NSArray<NSString *> * _Nullable, NSError * _Nullable))completion {
    if (!lines.count) {
        YTMUCompleteOnMain(^{ completion(@[], nil); });
        return;
    }

    NSString *providerName = YTMUSettingsString(@"translationProvider", YTMUTranslationProviderGoogle);
    id<YTMUTranslationProvider> provider = self.providers[providerName] ?: self.providers[YTMUTranslationProviderGoogle];
    if (!provider) {
        YTMUCompleteOnMain(^{
            completion(nil, YTMUTranslatorError(YTMUTranslationErrorUnknown, [NSString stringWithFormat:@"Unknown provider: %@", providerName]));
        });
        return;
    }

    NSString *configuredTarget = YTMUSettingsString(@"translationTargetLang", @"auto");
    NSString *language = [YTMUPromptBuilder effectiveTargetCode:configuredTarget];
    NSString *model = [provider modelIdentifier] ?: @"";
    YTMUTranslationLog(@"request videoId=%@ provider=%@ model=%@ target=%@ lines=%lu",
                       videoId.length ? videoId : @"<empty>",
                       [provider providerName],
                       model.length ? model : @"<empty>",
                       language,
                       (unsigned long)lines.count);
    NSString *cacheKey = [YTMUTranslationCache keyForVideoId:videoId
                                                    language:language
                                                    provider:[provider providerName]
                                                       model:model
                                                       lines:lines];

    YTMUTranslationCacheEntry *cached = [[YTMUTranslationCache sharedCache] entryForKey:cacheKey];
    if (cached.translatedLines.count == lines.count) {
        YTMUTranslationLog(@"cache hit videoId=%@ provider=%@ target=%@ lines=%lu",
                           videoId.length ? videoId : @"<empty>",
                           [provider providerName],
                           language,
                           (unsigned long)lines.count);
        YTMUCompleteOnMain(^{
            completion(cached.translatedLines, nil);
        });
        return;
    }
    YTMUTranslationLog(@"cache miss videoId=%@ provider=%@ target=%@",
                       videoId.length ? videoId : @"<empty>",
                       [provider providerName],
                       language);

    // Long songs (>50 lines) — model reliability for "return EXACTLY N
    // lines as JSON" degrades sharply past ~80 lines. Fan out into
    // smaller chunks and cache each independently so the strict
    // line-count contract holds per batch.
    if (lines.count > YTMUTranslationBatchThreshold) {
        [self translateInBatchesWithProvider:provider
                                       lines:lines
                                       title:title
                                      artist:artist
                                     videoId:videoId
                                    language:language
                                  completion:completion];
        return;
    }

    YTMUTranslationRequest *request = [self requestWithLines:lines title:title artist:artist targetCode:language];

    void (^handleFailure)(NSError *) = ^(NSError *error) {
        if ([self shouldFallbackPerLineForError:error lineCount:lines.count]) {
            [self fallbackPerLineWithProvider:provider
                                      request:request
                                     cacheKey:cacheKey
                                      videoId:videoId
                                     language:language
                                   firstError:error
                                   completion:completion];
            return;
        }

        YTMUCompleteOnMain(^{
            completion(nil, error);
        });
    };

    [provider translateRequest:request completion:^(NSArray<NSString *> *translated, NSError *error) {
        if (!error && translated.count == lines.count) {
            YTMUTranslationLog(@"provider success videoId=%@ provider=%@ lines=%lu",
                               videoId.length ? videoId : @"<empty>",
                               [provider providerName],
                               (unsigned long)translated.count);
            [self storeTranslatedLines:translated cacheKey:cacheKey videoId:videoId language:language provider:provider lines:lines];
            YTMUCompleteOnMain(^{ completion(translated, nil); });
            return;
        }

        NSError *firstError = error ?: [self lineCountErrorForTranslated:translated ?: @[] expected:lines.count];
        YTMUTranslationLog(@"provider first attempt failed videoId=%@ provider=%@ error=%@",
                           videoId.length ? videoId : @"<empty>",
                           [provider providerName],
                           firstError.localizedDescription ?: @"<unknown>");
        [provider translateRequest:request completion:^(NSArray<NSString *> *retryTranslated, NSError *retryError) {
            if (!retryError && retryTranslated.count == lines.count) {
                YTMUTranslationLog(@"provider retry success videoId=%@ provider=%@ lines=%lu",
                                   videoId.length ? videoId : @"<empty>",
                                   [provider providerName],
                                   (unsigned long)retryTranslated.count);
                [self storeTranslatedLines:retryTranslated cacheKey:cacheKey videoId:videoId language:language provider:provider lines:lines];
                YTMUCompleteOnMain(^{ completion(retryTranslated, nil); });
                return;
            }

            NSError *finalError = retryError ?: [self lineCountErrorForTranslated:retryTranslated ?: @[] expected:lines.count];
            YTMUTranslationLog(@"provider retry failed videoId=%@ provider=%@ error=%@",
                               videoId.length ? videoId : @"<empty>",
                               [provider providerName],
                               finalError.localizedDescription ?: @"<unknown>");
            handleFailure(finalError ?: firstError);
        }];
    }];
}

@end
