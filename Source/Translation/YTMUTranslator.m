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
