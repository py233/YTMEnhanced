#import "YTMULyricsManager.h"
#import "YTMULyricsCache.h"
#import "YTMULyricsTextProcessor.h"
#import "../Translation/YTMUTranslator.h"
#import "../Translation/YTMUPromptBuilder.h"
#import "../Translation/YTMUTranslationTypes.h"
#import "Providers/YTMUYTMusicProvider.h"
#import "Providers/YTMULRCLibProvider.h"
#import "Providers/YTMUNetEaseProvider.h"
#import "Providers/YTMUMusixMatchProvider.h"
#import "Providers/YTMUGeniusProvider.h"

@interface YTMULyricsManager ()
@property (nonatomic, strong) NSArray<id<YTMULyricsProvider>> *providers;
@property (nonatomic, readonly) NSDictionary<NSString *, id<YTMULyricsProvider>> *providersByName;
@property (nonatomic, readwrite) YTMULyricsFetchState state;
@property (nonatomic, copy, readwrite) NSString *activeVideoId;
@property (nonatomic, strong, readwrite) YTMULyricsResult *currentResult;
@property (nonatomic, copy, readwrite) NSArray<NSString *> *translatedLines;
@property (nonatomic, copy, readwrite) NSString *translationAttribution;
@property (nonatomic, copy, readwrite) NSString *lastErrorMessage;
@property (nonatomic) NSUInteger requestGeneration;
@property (nonatomic, strong) YTMULyricsSearchInfo *lastSearchInfo;
@property (nonatomic, strong) NSCache<NSString *, NSArray<NSString *> *> *romanizationMemoryCache;
@end

@implementation YTMULyricsManager

- (NSString *)translationProviderDisplayName {
    NSString *provider = YTMULyricsSettingsString(@"translationProvider", YTMUTranslationProviderGoogle);
    NSString *name = nil;
    NSString *model = nil;
    if ([provider isEqualToString:YTMUTranslationProviderGoogle]) {
        name = @"Google Translate";
        model = @"google-translate";
    } else if ([provider isEqualToString:YTMUTranslationProviderAnthropic]) {
        name = @"Anthropic";
        model = YTMULyricsSettingsString(@"translationModel_anthropic", @"claude-haiku-4-5-20251001");
    } else if ([provider isEqualToString:YTMUTranslationProviderGemini]) {
        name = @"Gemini";
        model = YTMULyricsSettingsString(@"translationModel_gemini", @"gemini-2.0-flash");
    } else if ([provider isEqualToString:YTMUTranslationProviderOpenAI]) {
        name = @"OpenAI-compatible";
        model = YTMULyricsSettingsString(@"translationModel_openai-compatible", @"gpt-4o-mini");
    }

    if (!name.length) name = provider.length ? provider : @"translator";
    return model.length ? [NSString stringWithFormat:@"%@ (%@)", name, model] : name;
}

+ (instancetype)sharedManager {
    static YTMULyricsManager *manager;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        manager = [[self alloc] init];
    });
    return manager;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _providers = @[
            [[YTMUYTMusicProvider alloc] init],
            [[YTMULRCLibProvider alloc] init],
            [[YTMUNetEaseProvider alloc] init],
            [[YTMUMusixMatchProvider alloc] init],
            [[YTMUGeniusProvider alloc] init],
        ];
        _state = YTMULyricsFetchStateIdle;
        _activeVideoId = @"";
        _translatedLines = @[];
        _translationAttribution = @"";
        _lastErrorMessage = @"";
        _romanizationMemoryCache = [[NSCache alloc] init];
        _romanizationMemoryCache.countLimit = 8;
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(settingsDidChange:)
                                                     name:YTMULyricsSettingsDidChangeNotification
                                                   object:nil];
    }
    return self;
}

- (NSDictionary<NSString *,id<YTMULyricsProvider>> *)providersByName {
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    for (id<YTMULyricsProvider> provider in self.providers) dict[[provider providerName]] = provider;
    return dict;
}

- (void)notify {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:YTMULyricsStateDidChangeNotification object:self];
        [[NSNotificationCenter defaultCenter] postNotificationName:YTMULyricsDidUpdateNotification object:self];
    });
}

- (NSArray<id<YTMULyricsProvider>> *)orderedProviders {
    NSString *preferred = YTMULyricsSettingsString(@"lyricsPreferredSource", @"auto");
    NSDictionary *byName = self.providersByName;
    if (![preferred isEqualToString:@"auto"] && byName[preferred]) {
        return @[byName[preferred]];
    }
    NSMutableArray *ordered = [NSMutableArray array];
    for (id<YTMULyricsProvider> provider in self.providers) {
        if (![ordered containsObject:provider]) [ordered addObject:provider];
    }
    return ordered;
}

- (BOOL)isLyricsEnabled {
    return YTMULyricsSettingsBool(@"YTMUltimateIsEnabled", NO) &&
           (YTMULyricsSettingsBool(@"syncedLyricsEnabled", NO) || YTMULyricsSettingsBool(@"bilingualLyrics", NO));
}

- (void)settingsDidChange:(NSNotification *)notification {
    NSString *key = notification.userInfo[YTMULyricsSettingChangedKey] ?: @"";
    YTMULyricsLog(@"settings notification key=%@", key.length ? key : @"<unknown>");

    NSSet *visualKeys = [NSSet setWithObjects:
                         @"lyricsLineEffect",
                         @"lyricsFontSize",
                         @"lyricsFontPointSize",
                         @"lyricsDefaultText",
                         @"lyricsConvertChinese",
                         @"lyricsShowTimeCodes",
                         @"translationDebugLogs",
                         nil];
    if ([visualKeys containsObject:key]) {
        [self notify];
        return;
    }

    if (![self isLyricsEnabled]) {
        [self clearCurrent];
        return;
    }

    if (self.lastSearchInfo.videoId.length || self.lastSearchInfo.title.length) {
        [self refreshWithInfo:self.lastSearchInfo];
    } else {
        [self notify];
    }
}

- (void)setStateAndNotify:(YTMULyricsFetchState)state {
    self.state = state;
    [self notify];
}

- (void)clearCurrent {
    self.requestGeneration++;
    self.state = YTMULyricsFetchStateIdle;
    self.activeVideoId = @"";
    self.currentResult = nil;
    self.translatedLines = @[];
    self.translationAttribution = @"";
    self.lastErrorMessage = @"";
    [self notify];
}

- (void)clearRomanizationCache {
    [self.romanizationMemoryCache removeAllObjects];
    YTMULyricsLog(@"romanization memory cache cleared");
}

- (NSArray<NSString *> *)displayLineTexts {
    return [self.currentResult lineTexts] ?: @[];
}

- (NSString *)translationForLineAtIndex:(NSUInteger)index {
    if (index >= self.translatedLines.count) return @"";
    return self.translatedLines[index] ?: @"";
}

- (BOOL)isChineseTarget {
    NSString *target = [YTMUPromptBuilder effectiveTargetCode:YTMULyricsSettingsString(@"translationTargetLang", @"auto")];
    return [target.lowercaseString hasPrefix:@"zh"];
}

- (BOOL)translationEnabled {
    return YTMULyricsSettingsBool(@"lyricsTranslationEnabled", YTMULyricsSettingsBool(@"bilingualLyrics", NO));
}

- (NSString *)googleFormEncode:(NSString *)value {
    static NSCharacterSet *allowed;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSMutableCharacterSet *set = [[NSCharacterSet URLQueryAllowedCharacterSet] mutableCopy];
        [set removeCharactersInString:@"!*'();:@&=+$,/?%#[]"];
        allowed = [set copy];
    });
    NSString *encoded = [value stringByAddingPercentEncodingWithAllowedCharacters:allowed] ?: @"";
    return [encoded stringByReplacingOccurrencesOfString:@"%20" withString:@"+"];
}

- (NSString *)romanizationCacheKeyForResult:(YTMULyricsResult *)result info:(YTMULyricsSearchInfo *)info lines:(NSArray<NSString *> *)lines {
    return [NSString stringWithFormat:@"%@::%@::%lu::%@",
            info.videoId ?: @"",
            result.sourceName ?: @"",
            (unsigned long)lines.count,
            YTMULyricsCompactString([lines componentsJoinedByString:@"|"] ?: @"")];
}

- (NSArray<NSDictionary *> *)romanizableLineItemsForResult:(YTMULyricsResult *)result
                                                sourceLines:(NSArray<NSString *> *)sourceLines
                                             sourceLanguage:(NSString *)sourceLanguage {
    NSMutableArray<NSDictionary *> *items = [NSMutableArray array];
    [sourceLines enumerateObjectsUsingBlock:^(NSString *lineText, NSUInteger idx, BOOL *stop) {
        NSString *text = [lineText stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSString *existing = idx < result.romanizedLineTexts.count ? result.romanizedLineTexts[idx] : @"";
        if (!text.length || existing.length) return;
        if (![YTMULyricsTextProcessor needsRomanizationForText:text preferredLanguage:sourceLanguage]) return;
        [items addObject:@{@"index": @(idx), @"text": text}];
    }];
    return items;
}

- (NSString *)romanizationSourceLanguageForResult:(YTMULyricsResult *)result {
    for (NSString *line in result.lineTexts ?: @[]) {
        if ([YTMULyricsTextProcessor hasJapaneseKana:line ?: @""]) return @"ja";
    }
    return @"auto";
}

- (void)fetchGoogleRomanizationForText:(NSString *)text sourceLanguage:(NSString *)sourceLanguage completion:(void(^)(NSString *romanized))completion {
    if (!text.length) {
        completion(@"");
        return;
    }
    NSURL *url = [NSURL URLWithString:@"https://translate.google.com/translate_a/single?client=at&dt=rm&dj=1"];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    request.timeoutInterval = 15.0;
    [request setValue:@"application/x-www-form-urlencoded;charset=utf-8" forHTTPHeaderField:@"Content-Type"];
    NSString *source = sourceLanguage.length ? sourceLanguage : @"auto";
    NSString *body = [NSString stringWithFormat:@"sl=%@&tl=en&q=%@", [self googleFormEncode:source], [self googleFormEncode:text]];
    request.HTTPBody = [body dataUsingEncoding:NSUTF8StringEncoding];

    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            completion([YTMULyricsTextProcessor romanizeText:text]);
            return;
        }
        NSError *jsonError = nil;
        id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError] : nil;
        NSString *romanized = json ? [YTMULyricsTextProcessor googleTransliterationFromJSON:json] : @"";
        if (!romanized.length) romanized = [YTMULyricsTextProcessor romanizeText:text];
        completion(romanized ?: @"");
    }] resume];
}

- (void)fetchGoogleRomanizationItems:(NSArray<NSDictionary *> *)items
                             position:(NSUInteger)position
                                limit:(NSUInteger)limit
                       sourceLanguage:(NSString *)sourceLanguage
                            romanized:(NSMutableArray<NSString *> *)romanized
                           completion:(void(^)(NSArray<NSString *> *romanized))completion {
    if (position >= limit || position >= items.count) {
        completion([romanized copy]);
        return;
    }

    NSDictionary *item = items[position];
    NSUInteger lineIndex = [item[@"index"] unsignedIntegerValue];
    NSString *text = item[@"text"] ?: @"";
    [self fetchGoogleRomanizationForText:text sourceLanguage:sourceLanguage completion:^(NSString *value) {
        if (lineIndex < romanized.count && value.length) romanized[lineIndex] = value;
        [self fetchGoogleRomanizationItems:items
                                  position:position + 1
                                     limit:limit
                            sourceLanguage:sourceLanguage
                                 romanized:romanized
                                completion:completion];
    }];
}

- (void)applyRomanizedLines:(NSArray<NSString *> *)romanized generation:(NSUInteger)generation info:(YTMULyricsSearchInfo *)info cacheKey:(NSString *)cacheKey {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (generation != self.requestGeneration || ![info.videoId isEqualToString:self.activeVideoId]) return;
        YTMULyricsResult *current = [self.currentResult copy];
        NSArray<NSString *> *sourceLines = [current lineTexts] ?: @[];
        BOOL complete = YES;
        NSString *sourceLanguage = [self romanizationSourceLanguageForResult:current];
        NSMutableArray<NSString *> *filledRomanized = [NSMutableArray arrayWithCapacity:sourceLines.count];
        for (NSUInteger idx = 0; idx < sourceLines.count; idx++) {
            NSString *text = [sourceLines[idx] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            NSString *value = idx < romanized.count ? romanized[idx] : @"";
            if (![value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].length &&
                [YTMULyricsTextProcessor needsRomanizationForText:text preferredLanguage:sourceLanguage]) {
                value = [YTMULyricsTextProcessor romanizeText:text];
                if (!value.length) value = text;
            }
            [filledRomanized addObject:value ?: @""];
        }
        for (NSUInteger idx = 0; idx < sourceLines.count; idx++) {
            NSString *text = [sourceLines[idx] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (![YTMULyricsTextProcessor needsRomanizationForText:text preferredLanguage:sourceLanguage]) continue;
            NSString *value = idx < filledRomanized.count ? filledRomanized[idx] : @"";
            if (![value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].length) {
                complete = NO;
                break;
            }
        }
        NSMutableArray<NSString *> *lineTexts = [NSMutableArray arrayWithCapacity:sourceLines.count];
        for (NSUInteger idx = 0; idx < sourceLines.count; idx++) {
            NSString *value = idx < filledRomanized.count ? filledRomanized[idx] : @"";
            [lineTexts addObject:complete && value.length ? value : @""];
        }
        current.romanizedLineTexts = lineTexts;

        NSMutableArray<YTMULyricLine *> *lines = [NSMutableArray arrayWithCapacity:current.lines.count];
        for (NSUInteger idx = 0; idx < current.lines.count; idx++) {
            YTMULyricLine *line = [current.lines[idx] copy];
            NSString *value = idx < filledRomanized.count ? filledRomanized[idx] : @"";
            line.romanizedText = complete && value.length ? value : @"";
            [lines addObject:line];
        }
        current.lines = lines;
        self.currentResult = current;
        if (cacheKey.length) [self.romanizationMemoryCache setObject:filledRomanized ?: @[] forKey:cacheKey];
        if (current.sourceName.length) {
            NSString *lyricsCacheKey = [YTMULyricsCache cacheKeyForInfo:info source:current.sourceName];
            [[YTMULyricsCache sharedCache] storeResult:current forKey:lyricsCacheKey];
        }
        YTMULyricsLog(@"google romanization applied videoId=%@ lines=%lu complete=%@",
                      info.videoId,
                      (unsigned long)romanized.count,
                      complete ? @"YES" : @"NO");
        [self notify];
    });
}

- (void)fetchRomanizationIfNeededForInfo:(YTMULyricsSearchInfo *)info generation:(NSUInteger)generation {
    if (!YTMULyricsSettingsBool(@"lyricsRomanization", YES)) return;
    YTMULyricsResult *result = self.currentResult;
    NSArray<NSString *> *source = [result lineTexts] ?: @[];
    if (!source.count) return;

    NSString *sourceLanguage = [self romanizationSourceLanguageForResult:result];
    NSArray<NSDictionary *> *items = [self romanizableLineItemsForResult:result sourceLines:source sourceLanguage:sourceLanguage];
    if (!items.count) return;

    NSString *cacheKey = [self romanizationCacheKeyForResult:result info:info lines:source];
    NSArray<NSString *> *cached = [self.romanizationMemoryCache objectForKey:cacheKey];
    if (cached.count == source.count) {
        [self applyRomanizedLines:cached generation:generation info:info cacheKey:cacheKey];
        return;
    }

    NSMutableArray<NSString *> *romanized = [NSMutableArray arrayWithCapacity:source.count];
    for (NSUInteger idx = 0; idx < source.count; idx++) {
        NSString *existing = idx < result.romanizedLineTexts.count ? result.romanizedLineTexts[idx] : @"";
        [romanized addObject:existing ?: @""];
    }

    NSUInteger limit = MIN(items.count, (NSUInteger)80);
    [self fetchGoogleRomanizationItems:items position:0 limit:limit sourceLanguage:sourceLanguage romanized:romanized completion:^(NSArray<NSString *> *values) {
        [self applyRomanizedLines:values generation:generation info:info cacheKey:cacheKey];
    }];
}

- (void)applyOfficialTranslationIfAvailableForInfo:(YTMULyricsSearchInfo *)info generation:(NSUInteger)generation {
    if (![self translationEnabled] || ![self isChineseTarget]) return;
    NSArray *source = [self.currentResult lineTexts];
    NSArray *official = self.currentResult.officialTranslatedLines ?: @[];
    if (!official.count || !source.count) return;

    NSMutableArray *aligned = [NSMutableArray arrayWithCapacity:source.count];
    if (official.count == source.count) {
        [aligned addObjectsFromArray:official];
    } else {
        NSArray *nonEmpty = [official filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSString *line, NSDictionary *bindings) {
            return [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].length > 0;
        }]];
        NSMutableArray<NSNumber *> *sourceNonEmptyIndexes = [NSMutableArray array];
        [source enumerateObjectsUsingBlock:^(NSString *line, NSUInteger idx, BOOL *stop) {
            if ([line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].length > 0) {
                [sourceNonEmptyIndexes addObject:@(idx)];
            }
        }];
        if (nonEmpty.count == sourceNonEmptyIndexes.count) {
            for (NSUInteger i = 0; i < source.count; i++) [aligned addObject:@""];
            [sourceNonEmptyIndexes enumerateObjectsUsingBlock:^(NSNumber *idx, NSUInteger i, BOOL *stop) {
                aligned[idx.unsignedIntegerValue] = nonEmpty[i];
            }];
        }
    }
    if (aligned.count != source.count) return;

    self.translatedLines = aligned;
    self.translationAttribution = [NSString stringWithFormat:@"%@ official", self.currentResult.officialTranslationProvider.length ? self.currentResult.officialTranslationProvider : self.currentResult.sourceName];
    YTMULyricsLog(@"official translation applied videoId=%@ source=%@ lines=%lu",
                  info.videoId,
                  self.currentResult.sourceName,
                  (unsigned long)aligned.count);
    [self notify];
}

- (void)fetchTranslationForInfo:(YTMULyricsSearchInfo *)info generation:(NSUInteger)generation {
    if (![self translationEnabled]) {
        self.translatedLines = @[];
        self.translationAttribution = @"";
        [self notify];
        return;
    }

    [self applyOfficialTranslationIfAvailableForInfo:info generation:generation];
    if (self.translatedLines.count == self.displayLineTexts.count && self.translatedLines.count) return;

    NSArray *sourceLines = [self displayLineTexts];
    if (!sourceLines.count) return;
    NSString *title = self.currentResult.title.length ? self.currentResult.title : info.title;
    NSString *artist = self.currentResult.artists.count ? [self.currentResult.artists componentsJoinedByString:@", "] : info.artist;
    YTMULyricsLog(@"translation requested for lyrics source=%@ videoId=%@ lines=%lu",
                  self.currentResult.sourceName,
                  info.videoId,
                  (unsigned long)sourceLines.count);
    [[YTMUTranslator sharedTranslator] translateLines:sourceLines
                                              videoId:info.videoId
                                                title:title
                                               artist:artist
                                           completion:^(NSArray<NSString *> *translatedLines, NSError *error) {
        if (generation != self.requestGeneration || ![info.videoId isEqualToString:self.activeVideoId]) return;
        if (error || translatedLines.count != sourceLines.count) {
            YTMULyricsLog(@"translation failed for lyrics source=%@ videoId=%@ error=%@ returned=%lu expected=%lu",
                          self.currentResult.sourceName,
                          info.videoId,
                          error.localizedDescription ?: @"<line-count>",
                          (unsigned long)translatedLines.count,
                          (unsigned long)sourceLines.count);
            return;
        }
        self.translatedLines = translatedLines;
        self.translationAttribution = [self translationProviderDisplayName];
        [self notify];
    }];
}

- (void)finishWithResult:(YTMULyricsResult *)result info:(YTMULyricsSearchInfo *)info provider:(id<YTMULyricsProvider>)provider generation:(NSUInteger)generation {
    if (generation != self.requestGeneration || ![info.videoId isEqualToString:self.activeVideoId]) return;
    self.currentResult = result;
    self.translatedLines = @[];
    self.translationAttribution = @"";
    self.lastErrorMessage = @"";
    self.state = YTMULyricsFetchStateDone;
    YTMULyricsLog(@"lyrics ready videoId=%@ source=%@ title=%@ synced=%d lines=%lu",
                  info.videoId,
                  result.sourceName,
                  result.title,
                  result.isSynced,
                  (unsigned long)result.lineTexts.count);
    [self notify];
    [self fetchRomanizationIfNeededForInfo:info generation:generation];
    [self fetchTranslationForInfo:info generation:generation];
}

- (void)tryProviders:(NSArray<id<YTMULyricsProvider>> *)providers
               index:(NSUInteger)index
                info:(YTMULyricsSearchInfo *)info
          generation:(NSUInteger)generation
          lastErrors:(NSMutableArray<NSString *> *)lastErrors
      fallbackResult:(YTMULyricsResult *)fallbackResult
     fallbackProvider:(id<YTMULyricsProvider>)fallbackProvider {
    if (generation != self.requestGeneration || ![info.videoId isEqualToString:self.activeVideoId]) return;
    if (index >= providers.count) {
        if (fallbackResult.hasText) {
            YTMULyricsLog(@"lyrics using plain fallback videoId=%@ source=%@", info.videoId, fallbackResult.sourceName);
            [self finishWithResult:fallbackResult info:info provider:fallbackProvider generation:generation];
            return;
        }
        self.state = YTMULyricsFetchStateError;
        self.lastErrorMessage = lastErrors.count ? [lastErrors componentsJoinedByString:@" | "] : @"No lyrics found";
        YTMULyricsLog(@"lyrics lookup exhausted videoId=%@ errors=%@", info.videoId, self.lastErrorMessage);
        [self notify];
        return;
    }

    id<YTMULyricsProvider> provider = providers[index];
    NSString *cacheKey = [YTMULyricsCache cacheKeyForInfo:info source:[provider providerName]];
    YTMULyricsResult *cached = [[YTMULyricsCache sharedCache] resultForKey:cacheKey];
    if (cached.hasText) {
        YTMULyricsLog(@"lyrics cache hit videoId=%@ source=%@", info.videoId, [provider providerName]);
        NSString *preferred = YTMULyricsSettingsString(@"lyricsPreferredSource", @"auto");
        BOOL shouldKeepLookingForSynced = [preferred isEqualToString:@"auto"] &&
                                          (YTMULyricsSettingsBool(@"syncedLyricsEnabled", NO) ||
                                           YTMULyricsSettingsBool(@"bilingualLyrics", NO) ||
                                           YTMULyricsSettingsBool(@"lyricsTranslationEnabled", NO)) &&
                                          !cached.isSynced &&
                                          index + 1 < providers.count;
        if (shouldKeepLookingForSynced) {
            [self tryProviders:providers
                         index:index + 1
                          info:info
                    generation:generation
                    lastErrors:lastErrors
                fallbackResult:fallbackResult ?: cached
               fallbackProvider:fallbackProvider ?: provider];
            return;
        }
        [self finishWithResult:cached info:info provider:provider generation:generation];
        return;
    }

    YTMULyricsLog(@"lyrics source request videoId=%@ source=%@ title=%@ artist=%@ duration=%.1f",
                  info.videoId,
                  [provider providerName],
                  info.title,
                  info.artist,
                  info.duration);
    [provider searchWithInfo:info completion:^(YTMULyricsResult *result, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self.requestGeneration || ![info.videoId isEqualToString:self.activeVideoId]) return;
            if (result.hasText) {
                [[YTMULyricsCache sharedCache] storeResult:result forKey:cacheKey];
                NSString *preferred = YTMULyricsSettingsString(@"lyricsPreferredSource", @"auto");
                BOOL shouldKeepLookingForSynced = [preferred isEqualToString:@"auto"] &&
                                                  (YTMULyricsSettingsBool(@"syncedLyricsEnabled", NO) ||
                                                   YTMULyricsSettingsBool(@"bilingualLyrics", NO) ||
                                                   YTMULyricsSettingsBool(@"lyricsTranslationEnabled", NO)) &&
                                                  !result.isSynced &&
                                                  index + 1 < providers.count;
                if (shouldKeepLookingForSynced) {
                    YTMULyricsLog(@"lyrics plain candidate source=%@; continuing for synced source", [provider providerName]);
                    [self tryProviders:providers
                                 index:index + 1
                                  info:info
                            generation:generation
                            lastErrors:lastErrors
                        fallbackResult:fallbackResult ?: result
                       fallbackProvider:fallbackProvider ?: provider];
                    return;
                }
                [self finishWithResult:result info:info provider:provider generation:generation];
                return;
            }
            NSString *message = error.localizedDescription ?: @"no match";
            [lastErrors addObject:[NSString stringWithFormat:@"%@: %@", [provider providerName], message]];
            YTMULyricsLog(@"lyrics source miss videoId=%@ source=%@ reason=%@", info.videoId, [provider providerName], message);
            [self tryProviders:providers
                         index:index + 1
                          info:info
                    generation:generation
                    lastErrors:lastErrors
                fallbackResult:fallbackResult
               fallbackProvider:fallbackProvider];
        });
    }];
}

- (void)refreshWithInfo:(YTMULyricsSearchInfo *)info {
    NSLog(@"[YTMULyrics] refreshWithInfo videoId=%@ title=%@ enabled=%@",
          info.videoId ?: @"",
          info.title ?: @"",
          [self isLyricsEnabled] ? @"YES" : @"NO");

    if (!info.videoId.length && !info.title.length) {
        [self clearCurrent];
        return;
    }
    self.lastSearchInfo = [info copy];

    if (![self isLyricsEnabled]) {
        NSLog(@"[YTMULyrics] feature disabled - enable Synced lyrics or Bilingual lyrics in Translation settings");
        [self clearCurrent];
        return;
    }

    self.requestGeneration++;
    NSUInteger generation = self.requestGeneration;
    self.activeVideoId = info.videoId ?: @"";
    self.currentResult = nil;
    self.translatedLines = @[];
    self.translationAttribution = @"";
    self.lastErrorMessage = @"";
    [self setStateAndNotify:YTMULyricsFetchStateFetching];

    NSArray *providers = [self orderedProviders];
    YTMULyricsLog(@"lyrics refresh videoId=%@ title=%@ artist=%@ preferred=%@ providers=%lu",
                  info.videoId,
                  info.title,
                  info.artist,
                  YTMULyricsSettingsString(@"lyricsPreferredSource", @"auto"),
                  (unsigned long)providers.count);
    [self tryProviders:providers
                 index:0
                  info:[info copy]
            generation:generation
            lastErrors:[NSMutableArray array]
        fallbackResult:nil
       fallbackProvider:nil];
}

@end
