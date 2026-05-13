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

// Reconcile a model-returned line count that's off by ≤1 with the
// expected source line count. claude-opus consistently drifts by one
// on long whole-song translations — typically by emitting an extra
// blank entry at the start or end that represents an intro / outro
// marker the model "saw" but the source didn't have. Without this
// reconciliation the manager rejects an entire 150-line translation
// (and another retry call) over a single misplaced blank.
//
// Strategy:
//   off-by-+1: prefer dropping the edge whose blankness DOESN'T match
//              the source's edge (i.e. the model added the blank).
//              If both edges are blank in the model output, drop the
//              leading one (most common drift). If neither edge is
//              blank, bail — that's not a safe alignment.
//   off-by--1: pad an empty entry at the end. Worst case is the last
//              source line is shown un-translated; better than no
//              translation at all.
//   larger drift: bail (caller retries / errors).
- (nullable NSArray<NSString *> *)alignedTranslation:(NSArray<NSString *> *)translated
                                       toSourceLines:(NSArray<NSString *> *)source {
    if (translated.count == source.count) return translated;
    NSCharacterSet *ws = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    BOOL (^isBlank)(id) = ^BOOL(id obj) {
        if (![obj isKindOfClass:[NSString class]]) return YES;
        return ![[(NSString *)obj stringByTrimmingCharactersInSet:ws] length];
    };

    if (translated.count == source.count + 1) {
        BOOL srcFirstBlank = source.count ? isBlank(source.firstObject) : YES;
        BOOL srcLastBlank = source.count ? isBlank(source.lastObject) : YES;
        BOOL outFirstBlank = isBlank(translated.firstObject);
        BOOL outLastBlank = isBlank(translated.lastObject);

        if (outFirstBlank && !srcFirstBlank) {
            return [translated subarrayWithRange:NSMakeRange(1, translated.count - 1)];
        }
        if (outLastBlank && !srcLastBlank) {
            return [translated subarrayWithRange:NSMakeRange(0, translated.count - 1)];
        }
        if (outFirstBlank) {
            return [translated subarrayWithRange:NSMakeRange(1, translated.count - 1)];
        }
        if (outLastBlank) {
            return [translated subarrayWithRange:NSMakeRange(0, translated.count - 1)];
        }
        return nil;
    }
    if (translated.count + 1 == source.count) {
        NSMutableArray *padded = [translated mutableCopy];
        [padded addObject:@""];
        return padded;
    }
    return nil;
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
        NSArray *aligned = nil;
        if (!error) {
            if (translated.count == lines.count) {
                aligned = translated;
            } else {
                NSArray *candidate = [self alignedTranslation:translated toSourceLines:lines];
                if (candidate.count == lines.count) {
                    YTMUTranslationLog(@"aligned line-count drift videoId=%@ provider=%@ raw=%lu → %lu",
                                       videoId.length ? videoId : @"<empty>",
                                       [provider providerName],
                                       (unsigned long)translated.count,
                                       (unsigned long)candidate.count);
                    aligned = candidate;
                }
            }
        }

        if (aligned) {
            YTMUTranslationLog(@"provider success videoId=%@ provider=%@ lines=%lu",
                               videoId.length ? videoId : @"<empty>",
                               [provider providerName],
                               (unsigned long)aligned.count);
            [self storeTranslatedLines:aligned cacheKey:cacheKey videoId:videoId language:language provider:provider lines:lines];
            YTMUCompleteOnMain(^{ completion(aligned, nil); });
            return;
        }

        NSError *firstError = error ?: [self lineCountErrorForTranslated:translated ?: @[] expected:lines.count];
        YTMUTranslationLog(@"provider first attempt failed videoId=%@ provider=%@ error=%@",
                           videoId.length ? videoId : @"<empty>",
                           [provider providerName],
                           firstError.localizedDescription ?: @"<unknown>");
        [provider translateRequest:request completion:^(NSArray<NSString *> *retryTranslated, NSError *retryError) {
            NSArray *retryAligned = nil;
            if (!retryError) {
                if (retryTranslated.count == lines.count) {
                    retryAligned = retryTranslated;
                } else {
                    NSArray *candidate = [self alignedTranslation:retryTranslated toSourceLines:lines];
                    if (candidate.count == lines.count) {
                        YTMUTranslationLog(@"aligned line-count drift on retry videoId=%@ provider=%@ raw=%lu → %lu",
                                           videoId.length ? videoId : @"<empty>",
                                           [provider providerName],
                                           (unsigned long)retryTranslated.count,
                                           (unsigned long)candidate.count);
                        retryAligned = candidate;
                    }
                }
            }

            if (retryAligned) {
                YTMUTranslationLog(@"provider retry success videoId=%@ provider=%@ lines=%lu",
                                   videoId.length ? videoId : @"<empty>",
                                   [provider providerName],
                                   (unsigned long)retryAligned.count);
                [self storeTranslatedLines:retryAligned cacheKey:cacheKey videoId:videoId language:language provider:provider lines:lines];
                YTMUCompleteOnMain(^{ completion(retryAligned, nil); });
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
