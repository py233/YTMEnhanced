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
    // localizedDescription is whatever the provider put into userInfo. The
    // providers now guarantee a string, but keep this boundary defensive: a
    // non-string here used to reach rangeOfString: and abort the process.
    id description = error.localizedDescription;
    NSString *message = [description isKindOfClass:[NSString class]] ? description : @"";
    NSRange range = [message rangeOfString:@"parse|json|line|length|number of lines"
                                   options:NSRegularExpressionSearch | NSCaseInsensitiveSearch];
    return range.location != NSNotFound ||
           error.code == YTMUTranslationErrorParse ||
           error.code == YTMUTranslationErrorLineCount;
}

// Reconcile a model-returned line count that's off by ≤1 with the
// expected source line count by scoring each candidate alignment
// against the source's blank pattern.
//
// Naïve "look at the edges" rules don't work when the song's source
// has a blank at BOTH ends (e.g. Hi Ren on LRCLib: leading and
// trailing silent intro/outro). In that case both candidates have
// blank edges and edge-only inspection guesses wrong half the time.
//
// Instead we build the two N-entry candidates (drop-leading,
// drop-trailing) and score each by: how many positions have the
// SAME blank-or-not status as the source at the same index. The
// candidate with the higher score wins; ties go to drop-trailing
// (models statistically drift toward appending an extra closing
// entry more often than prepending one). Deterministic and
// content-aware, so the song that worked yesterday works the same
// today.
//
// off-by-−1: pad an empty entry at the end. The most common cause
// is the model truncating its final entry; padding at the tail at
// worst leaves the last source line un-translated, never misaligned.
//
// Larger drift: bail.
- (nullable NSArray<NSString *> *)alignedTranslation:(NSArray<NSString *> *)translated
                                       toSourceLines:(NSArray<NSString *> *)source {
    if (translated.count == source.count) return translated;
    NSCharacterSet *ws = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    BOOL (^isBlank)(id) = ^BOOL(id obj) {
        if (![obj isKindOfClass:[NSString class]]) return YES;
        return ![[(NSString *)obj stringByTrimmingCharactersInSet:ws] length];
    };

    if (translated.count == source.count + 1) {
        NSArray *dropLeading =
            [translated subarrayWithRange:NSMakeRange(1, translated.count - 1)];
        NSArray *dropTrailing =
            [translated subarrayWithRange:NSMakeRange(0, translated.count - 1)];

        NSUInteger scoreLeading = 0;
        NSUInteger scoreTrailing = 0;
        for (NSUInteger i = 0; i < source.count; i++) {
            BOOL srcBlank = isBlank(source[i]);
            if (srcBlank == isBlank(dropLeading[i])) scoreLeading++;
            if (srcBlank == isBlank(dropTrailing[i])) scoreTrailing++;
        }

        // Ties go to drop-trailing (see above).
        return scoreLeading > scoreTrailing ? dropLeading : dropTrailing;
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

// Only deterministic-looking failures are remembered: an unparseable or
// misaligned model output for this exact source usually repeats, whereas
// network / HTTP / missing-key errors should be retried on the next play.
- (BOOL)shouldRememberFailure:(NSError *)error {
    if (![error.domain isEqualToString:YTMUTranslationErrorDomain]) return NO;
    return error.code == YTMUTranslationErrorParse || error.code == YTMUTranslationErrorLineCount;
}

- (void)rememberFailure:(NSError *)error
               cacheKey:(NSString *)cacheKey
                videoId:(NSString *)videoId
               language:(NSString *)language
               provider:(id<YTMUTranslationProvider>)provider
                  lines:(NSArray<NSString *> *)lines {
    if (![self shouldRememberFailure:error]) return;
    YTMUTranslationCacheEntry *entry = [[YTMUTranslationCacheEntry alloc] init];
    entry.cacheKey = cacheKey;
    entry.strategyVersion = YTMUTranslationStrategyVersion;
    entry.videoId = videoId ?: @"";
    entry.targetLanguage = language ?: @"";
    entry.provider = [provider providerName] ?: @"";
    entry.model = [provider modelIdentifier] ?: @"";
    entry.sourceHash = [YTMUTranslationCache sourceHashForLines:lines];
    entry.lineCount = lines.count;
    entry.sourceLines = @[];
    entry.translatedLines = @[];
    entry.createdAt = [[NSDate date] timeIntervalSince1970];
    entry.failedAt = entry.createdAt;
    [[YTMUTranslationCache sharedCache] storeEntry:entry];
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
            NSError *finalError = firstError ?: lineError;
            [self rememberFailure:finalError cacheKey:cacheKey videoId:videoId language:language provider:provider lines:request.lines];
            YTMUCompleteOnMain(^{
                completion(nil, finalError);
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
    if (cached.translatedLines.count == lines.count && lines.count) {
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
    if ([cached isRememberedFailure]) {
        YTMUTranslationLog(@"cache holds a recent failure videoId=%@ provider=%@ target=%@ — not retrying yet",
                           videoId.length ? videoId : @"<empty>",
                           [provider providerName],
                           language);
        YTMUCompleteOnMain(^{
            completion(nil, YTMUTranslatorError(YTMUTranslationErrorParse, @"Translation failed recently for this song; will retry later"));
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
            // (the per-line path records the failure itself if it also fails)
            [self fallbackPerLineWithProvider:provider
                                      request:request
                                     cacheKey:cacheKey
                                      videoId:videoId
                                     language:language
                                   firstError:error
                                   completion:completion];
            return;
        }

        [self rememberFailure:error cacheKey:cacheKey videoId:videoId language:language provider:provider lines:lines];
        YTMUCompleteOnMain(^{
            completion(nil, error);
        });
    };

    // One attempt = ask the provider, accept an exact or ±1-aligned result.
    // Returns the aligned lines or nil (with `errorOut` filled).
    NSArray *(^alignedOrNil)(NSArray *, NSError *, NSError **, NSString *) = ^NSArray *(NSArray *translated, NSError *error, NSError **errorOut, NSString *attempt) {
        if (!error) {
            if (translated.count == lines.count) return translated;
            NSArray *candidate = [self alignedTranslation:translated toSourceLines:lines];
            if (candidate.count == lines.count) {
                YTMUTranslationLog(@"aligned line-count drift%@ videoId=%@ provider=%@ raw=%lu → %lu",
                                   attempt,
                                   videoId.length ? videoId : @"<empty>",
                                   [provider providerName],
                                   (unsigned long)translated.count,
                                   (unsigned long)candidate.count);
                return candidate;
            }
        }
        if (errorOut) *errorOut = error ?: [self lineCountErrorForTranslated:translated ?: @[] expected:lines.count];
        return nil;
    };
    void (^succeed)(NSArray *, NSString *) = ^(NSArray *aligned, NSString *attempt) {
        YTMUTranslationLog(@"provider%@ success videoId=%@ provider=%@ lines=%lu",
                           attempt,
                           videoId.length ? videoId : @"<empty>",
                           [provider providerName],
                           (unsigned long)aligned.count);
        [self storeTranslatedLines:aligned cacheKey:cacheKey videoId:videoId language:language provider:provider lines:lines];
        YTMUCompleteOnMain(^{ completion(aligned, nil); });
    };

    [provider translateRequest:request completion:^(NSArray<NSString *> *translated, NSError *error) {
        NSError *firstError = nil;
        NSArray *aligned = alignedOrNil(translated, error, &firstError, @"");
        if (aligned) { succeed(aligned, @""); return; }

        YTMUTranslationLog(@"provider first attempt failed videoId=%@ provider=%@ error=%@",
                           videoId.length ? videoId : @"<empty>",
                           [provider providerName],
                           firstError.localizedDescription ?: @"<unknown>");
        [provider translateRequest:request completion:^(NSArray<NSString *> *retryTranslated, NSError *retryError) {
            NSError *finalError = nil;
            NSArray *retryAligned = alignedOrNil(retryTranslated, retryError, &finalError, @" on retry");
            if (retryAligned) { succeed(retryAligned, @" retry"); return; }

            YTMUTranslationLog(@"provider retry failed videoId=%@ provider=%@ error=%@",
                               videoId.length ? videoId : @"<empty>",
                               [provider providerName],
                               finalError.localizedDescription ?: @"<unknown>");
            handleFailure(finalError ?: firstError);
        }];
    }];
}

@end
