#import "YTMULyricsManager.h"
#import "YTMULyricsCache.h"
#import "YTMULyricsTextProcessor.h"
#import "YTMULyricsTitleNormalizer.h"
#import "../Translation/YTMUTranslator.h"
#import "../Translation/YTMUPromptBuilder.h"
#import "../Translation/YTMUTranslationTypes.h"
#import "Providers/YTMUYTMusicProvider.h"
#import "Providers/YTMULRCLibProvider.h"
#import "Providers/YTMUNetEaseProvider.h"
#import "Providers/YTMUMusixMatchProvider.h"
#import "Providers/YTMUGeniusProvider.h"
#import "../Utils/NSBundle+YTMU.h"
#import <NaturalLanguage/NaturalLanguage.h>

static NSString *YTMULyricsManagerLocalized(NSString *key, NSString *fallback) {
    return [NSBundle.ytmu_defaultBundle localizedStringForKey:key value:fallback table:nil];
}

@interface YTMULyricsManager ()
@property (nonatomic, strong) NSArray<id<YTMULyricsProvider>> *providers;
@property (nonatomic, readonly) NSDictionary<NSString *, id<YTMULyricsProvider>> *providersByName;
@property (nonatomic, readwrite) YTMULyricsFetchState state;
@property (nonatomic, copy, readwrite) NSString *activeVideoId;
@property (nonatomic, strong, readwrite) YTMULyricsResult *currentResult;
@property (nonatomic, copy, readwrite) NSArray<NSString *> *translatedLines;
@property (nonatomic, copy, readwrite) NSString *translationAttribution;
@property (nonatomic, copy, readwrite) NSString *lastErrorMessage;
@property (nonatomic, copy, readwrite) NSDictionary<NSString *, NSString *> *sourceAvailability;
@property (nonatomic) NSUInteger requestGeneration;
@property (nonatomic, strong, readwrite) YTMULyricsSearchInfo *lastSearchInfo;
@property (nonatomic, strong) NSCache<NSString *, NSArray<NSString *> *> *romanizationMemoryCache;
@end

@implementation YTMULyricsManager

- (NSString *)translationProviderDisplayName {
    NSString *provider = YTMULyricsSettingsString(@"translationProvider", YTMUTranslationProviderGoogle);
    NSString *name = nil;
    NSString *model = nil;
    if ([provider isEqualToString:YTMUTranslationProviderGoogle]) {
        name = YTMULyricsManagerLocalized(@"PROVIDER_GOOGLE", @"Google Translate");
        model = @"google-translate";
    } else if ([provider isEqualToString:YTMUTranslationProviderAnthropic]) {
        name = YTMULyricsManagerLocalized(@"PROVIDER_ANTHROPIC", @"Anthropic");
        model = YTMULyricsSettingsString(@"translationModel_anthropic", @"claude-haiku-4-5-20251001");
    } else if ([provider isEqualToString:YTMUTranslationProviderGemini]) {
        name = YTMULyricsManagerLocalized(@"PROVIDER_GEMINI", @"Gemini");
        model = YTMULyricsSettingsString(@"translationModel_gemini", @"gemini-2.0-flash");
    } else if ([provider isEqualToString:YTMUTranslationProviderOpenAI]) {
        name = YTMULyricsManagerLocalized(@"PROVIDER_OPENAI", @"OpenAI-compatible");
        model = YTMULyricsSettingsString(@"translationModel_openai-compatible", @"gpt-4o-mini");
    }

    if (!name.length) name = provider.length ? provider : YTMULyricsManagerLocalized(@"LYRICS_PROVIDER_FALLBACK", @"translator");
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
        // LRCLib is intentionally last: when its primary `search` API
        // misses it falls back to up to six serial HTTP queries (one per
        // title-fragment candidate), which on slow networks routinely
        // pushes a single song's lookup past 30s. The faster providers
        // ahead of it usually answer first; LRCLib remains the deepest
        // lyric DB and still gets its turn if everyone above misses.
        _providers = @[
            [[YTMUYTMusicProvider alloc] init],
            [[YTMUNetEaseProvider alloc] init],
            [[YTMUMusixMatchProvider alloc] init],
            [[YTMUGeniusProvider alloc] init],
            [[YTMULRCLibProvider alloc] init],
        ];
        _state = YTMULyricsFetchStateIdle;
        _activeVideoId = @"";
        _translatedLines = @[];
        _translationAttribution = @"";
        _lastErrorMessage = @"";
        _sourceAvailability = @{};
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

- (void)setAvailability:(NSString *)availability forProvider:(id<YTMULyricsProvider>)provider notify:(BOOL)notify {
    NSString *source = [provider providerName];
    if (!source.length || !availability.length) return;
    NSMutableDictionary *status = [NSMutableDictionary dictionaryWithDictionary:self.sourceAvailability ?: @{}];
    if ([status[source] isEqualToString:availability]) return;
    status[source] = availability;
    self.sourceAvailability = status;
    if (notify) [self notify];
}

- (BOOL)isLyricsEnabled {
    return YTMULyricsSettingsBool(@"YTMUltimateIsEnabled", NO) &&
           (YTMULyricsSettingsBool(@"syncedLyricsEnabled", NO) || YTMULyricsSettingsBool(@"bilingualLyrics", NO));
}

- (void)settingsDidChange:(NSNotification *)notification {
    NSString *key = notification.userInfo[YTMULyricsSettingChangedKey] ?: @"";
    YTMULyricsLog(@"settings notification key=%@", key.length ? key : @"<unknown>");

    if ([key isEqualToString:@"lyricsTimingOffsetMs"]) {
        return;
    }

    NSSet *visualKeys = [NSSet setWithObjects:
                         @"lyricsLineEffect",
                         @"lyricsFontSize",
                         @"lyricsFontPointSize",
                         @"lyricsDefaultText",
                         @"lyricsConvertChinese",
                         @"lyricsShowTimeCodes",
                         @"lyricsFocusBlur",
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
    self.sourceAvailability = @{};
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

- (NSString *)normalizedLanguageFamily:(NSString *)language {
    NSString *normalized = [[language ?: @"" lowercaseString] stringByReplacingOccurrencesOfString:@"_" withString:@"-"];
    if (!normalized.length) return @"";
    NSString *primary = [normalized componentsSeparatedByString:@"-"].firstObject ?: normalized;
    if ([primary isEqualToString:@"cmn"] || [primary isEqualToString:@"yue"] || [primary isEqualToString:@"zh"]) return @"zh";
    if ([primary isEqualToString:@"nb"] || [primary isEqualToString:@"nn"]) return @"no";
    if ([primary isEqualToString:@"tl"]) return @"fil";
    return primary;
}

- (NSDictionary<NSString *, id> *)detectLyricsLanguageForLines:(NSArray<NSString *> *)lines {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSString *line in lines ?: @[]) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (trimmed.length) [parts addObject:trimmed];
    }

    NSString *text = [parts componentsJoinedByString:@"\n"];
    if (text.length < 24) return nil;

    NLLanguageRecognizer *recognizer = [[NLLanguageRecognizer alloc] init];
    [recognizer processString:text];
    NSDictionary<NLLanguage, NSNumber *> *hypotheses = [recognizer languageHypothesesWithMaximum:1];
    NLLanguage bestLanguage = recognizer.dominantLanguage;
    NSNumber *accuracy = bestLanguage.length ? hypotheses[bestLanguage] : nil;
    if (!bestLanguage.length || [bestLanguage isEqualToString:NLLanguageUndetermined]) {
        bestLanguage = hypotheses.allKeys.firstObject;
        accuracy = bestLanguage.length ? hypotheses[bestLanguage] : nil;
    }
    if (!bestLanguage.length || [bestLanguage isEqualToString:NLLanguageUndetermined]) return nil;
    if (accuracy.doubleValue < 0.55) return nil;

    return @{@"language": bestLanguage, @"accuracy": accuracy};
}

- (NSDictionary<NSString *, id> *)sourceLanguageMatchesTargetForLines:(NSArray<NSString *> *)lines targetLanguage:(NSString *)targetLanguage {
    NSDictionary<NSString *, id> *detected = [self detectLyricsLanguageForLines:lines];
    if (!detected) return nil;

    NSString *sourceFamily = [self normalizedLanguageFamily:detected[@"language"]];
    NSString *targetFamily = [self normalizedLanguageFamily:targetLanguage];
    if (!sourceFamily.length || !targetFamily.length || ![sourceFamily isEqualToString:targetFamily]) return nil;

    return detected;
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
            completion(@"");
            return;
        }
        NSError *jsonError = nil;
        id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError] : nil;
        NSString *romanized = json ? [YTMULyricsTextProcessor googleTransliterationFromJSON:json] : @"";
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
        for (NSUInteger idx = 0; idx < sourceLines.count; idx++) {
            NSString *text = [sourceLines[idx] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (![YTMULyricsTextProcessor needsRomanizationForText:text preferredLanguage:sourceLanguage]) continue;
            NSString *value = idx < romanized.count ? romanized[idx] : @"";
            if (![value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].length) {
                complete = NO;
                break;
            }
        }
        NSMutableArray<NSString *> *lineTexts = [NSMutableArray arrayWithCapacity:sourceLines.count];
        for (NSUInteger idx = 0; idx < sourceLines.count; idx++) {
            NSString *value = idx < romanized.count ? romanized[idx] : @"";
            [lineTexts addObject:complete && value.length ? value : @""];
        }
        current.romanizedLineTexts = lineTexts;

        NSMutableArray<YTMULyricLine *> *lines = [NSMutableArray arrayWithCapacity:current.lines.count];
        for (NSUInteger idx = 0; idx < current.lines.count; idx++) {
            YTMULyricLine *line = [current.lines[idx] copy];
            NSString *value = idx < romanized.count ? romanized[idx] : @"";
            line.romanizedText = complete && value.length ? value : @"";
            [lines addObject:line];
        }
        current.lines = lines;
        self.currentResult = current;
        if (cacheKey.length) {
            if (complete) {
                [self.romanizationMemoryCache setObject:lineTexts ?: @[] forKey:cacheKey];
            } else {
                [self.romanizationMemoryCache removeObjectForKey:cacheKey];
            }
        }
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

    NSArray *sourceLines = [self displayLineTexts];
    if (!sourceLines.count) return;

    NSString *targetLanguage = [YTMUPromptBuilder effectiveTargetCode:YTMULyricsSettingsString(@"translationTargetLang", @"auto")];
    NSDictionary<NSString *, id> *sameLanguage = [self sourceLanguageMatchesTargetForLines:sourceLines targetLanguage:targetLanguage];
    if (sameLanguage) {
        self.translatedLines = @[];
        self.translationAttribution = @"";
        YTMULyricsLog(@"translation skipped: source language matches target videoId=%@ source=%@ detected=%@ accuracy=%.2f target=%@",
                      info.videoId,
                      self.currentResult.sourceName,
                      sameLanguage[@"language"],
                      [sameLanguage[@"accuracy"] doubleValue],
                      targetLanguage);
        [self notify];
        return;
    }

    [self applyOfficialTranslationIfAvailableForInfo:info generation:generation];
    if (self.translatedLines.count == sourceLines.count && self.translatedLines.count) return;

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
    [self setAvailability:@"hit" forProvider:provider notify:NO];
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
    [self probeRemainingProvidersForInfo:info generation:generation];
}

- (void)probeRemainingProvidersForInfo:(YTMULyricsSearchInfo *)info generation:(NSUInteger)generation {
    if (generation != self.requestGeneration || ![info.videoId isEqualToString:self.activeVideoId]) return;
    // Fire every unsettled provider in parallel so a slow one (LRCLib's
    // multi-query fallback path can take 30s+ on a poor connection)
    // doesn't block the others' status indicators. Each provider's
    // completion is independent — they only update sourceAvailability
    // for themselves and notify, so racing is safe.
    for (id<YTMULyricsProvider> provider in self.providers) {
        [self probeSingleProvider:provider info:info generation:generation];
    }
}

- (void)probeSingleProvider:(id<YTMULyricsProvider>)provider
                       info:(YTMULyricsSearchInfo *)info
                 generation:(NSUInteger)generation {
    if (generation != self.requestGeneration || ![info.videoId isEqualToString:self.activeVideoId]) return;

    NSString *status = self.sourceAvailability[[provider providerName]];
    if ([status isEqualToString:@"hit"] || [status isEqualToString:@"miss"]) return;

    NSString *cacheKey = [YTMULyricsCache cacheKeyForInfo:info source:[provider providerName]];
    YTMULyricsResult *cached = [[YTMULyricsCache sharedCache] resultForKey:cacheKey];
    if (cached.hasText) {
        [self setAvailability:@"hit" forProvider:provider notify:YES];
        return;
    }

    [self setAvailability:@"checking" forProvider:provider notify:YES];
    YTMULyricsLog(@"lyrics availability probe videoId=%@ source=%@", info.videoId, [provider providerName]);
    [provider searchWithInfo:info completion:^(YTMULyricsResult *result, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self.requestGeneration || ![info.videoId isEqualToString:self.activeVideoId]) return;
            if (result.hasText) {
                [[YTMULyricsCache sharedCache] storeResult:result forKey:cacheKey];
                [self setAvailability:@"hit" forProvider:provider notify:YES];
            } else {
                [self setAvailability:@"miss" forProvider:provider notify:YES];
            }
        });
    }];
}

// Result of a single tryProviders pass. provider/result are set together
// — if result is nil the pass exhausted every provider with no match.
typedef void (^YTMULyricsTryProvidersCompletion)(YTMULyricsResult *_Nullable result,
                                                 id<YTMULyricsProvider> _Nullable provider,
                                                 NSArray<NSString *> *_Nonnull errors);

- (void)tryProviders:(NSArray<id<YTMULyricsProvider>> *)providers
               index:(NSUInteger)index
                info:(YTMULyricsSearchInfo *)info
          generation:(NSUInteger)generation
          lastErrors:(NSMutableArray<NSString *> *)lastErrors
      fallbackResult:(YTMULyricsResult *)fallbackResult
    fallbackProvider:(id<YTMULyricsProvider>)fallbackProvider
       updateAvailability:(BOOL)updateAvailability
          completion:(YTMULyricsTryProvidersCompletion)completion {
    if (generation != self.requestGeneration || ![info.videoId isEqualToString:self.activeVideoId]) return;
    if (index >= providers.count) {
        if (fallbackResult.hasText) {
            completion(fallbackResult, fallbackProvider, lastErrors);
            return;
        }
        completion(nil, nil, lastErrors);
        return;
    }

    id<YTMULyricsProvider> provider = providers[index];
    if (updateAvailability) [self setAvailability:@"checking" forProvider:provider notify:YES];
    NSString *cacheKey = [YTMULyricsCache cacheKeyForInfo:info source:[provider providerName]];
    YTMULyricsResult *cached = [[YTMULyricsCache sharedCache] resultForKey:cacheKey];
    if (cached.hasText) {
        if (updateAvailability) [self setAvailability:@"hit" forProvider:provider notify:NO];
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
               fallbackProvider:fallbackProvider ?: provider
            updateAvailability:updateAvailability
                    completion:completion];
            return;
        }
        completion(cached, provider, lastErrors);
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
                if (updateAvailability) [self setAvailability:@"hit" forProvider:provider notify:NO];
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
                       fallbackProvider:fallbackProvider ?: provider
                    updateAvailability:updateAvailability
                            completion:completion];
                    return;
                }
                completion(result, provider, lastErrors);
                return;
            }
            NSString *message = error.localizedDescription ?: YTMULyricsManagerLocalized(@"LYRICS_PROVIDER_NO_MATCH", @"no match");
            if (updateAvailability) [self setAvailability:@"miss" forProvider:provider notify:YES];
            [lastErrors addObject:[NSString stringWithFormat:@"%@: %@", [provider providerName], message]];
            YTMULyricsLog(@"lyrics source miss videoId=%@ source=%@ reason=%@", info.videoId, [provider providerName], message);
            [self tryProviders:providers
                         index:index + 1
                          info:info
                    generation:generation
                    lastErrors:lastErrors
                fallbackResult:fallbackResult
               fallbackProvider:fallbackProvider
            updateAvailability:updateAvailability
                    completion:completion];
        });
    }];
}

- (void)refreshWithInfo:(YTMULyricsSearchInfo *)info {
    YTMULyricsLog(@"refreshWithInfo videoId=%@ title=%@ enabled=%@",
                  info.videoId ?: @"",
                  info.title ?: @"",
                  [self isLyricsEnabled] ? @"YES" : @"NO");

    if (!info.videoId.length && !info.title.length) {
        [self clearCurrent];
        return;
    }

    NSString *incomingTitle = info.title ?: @"";
    NSString *incomingArtist = info.artist ?: @"";
    NSString *lastTitle = self.lastSearchInfo.title ?: @"";
    NSString *lastArtist = self.lastSearchInfo.artist ?: @"";
    BOOL sameSongIdentity = (info.videoId.length && [info.videoId isEqualToString:self.activeVideoId]) ||
                            (!info.videoId.length &&
                             [incomingTitle isEqualToString:lastTitle] &&
                             [incomingArtist isEqualToString:lastArtist]);
    BOOL sameActiveSong = self.currentResult.hasText && sameSongIdentity;
    self.lastSearchInfo = [info copy];

    if (![self isLyricsEnabled]) {
        YTMULyricsLog(@"feature disabled - enable Synced lyrics or Bilingual lyrics in Translation settings");
        [self clearCurrent];
        return;
    }

    self.requestGeneration++;
    NSUInteger generation = self.requestGeneration;
    self.activeVideoId = info.videoId ?: @"";
    if (!sameSongIdentity) {
        NSMutableDictionary *initial = [NSMutableDictionary dictionary];
        for (id<YTMULyricsProvider> provider in self.providers) {
            initial[[provider providerName]] = @"checking";
        }
        self.sourceAvailability = initial;
    }
    YTMULyricsActivateTimingOffsetForInfo(info, NO);
    if (!sameActiveSong) {
        self.currentResult = nil;
        self.translatedLines = @[];
        self.translationAttribution = @"";
    }
    self.lastErrorMessage = @"";
    [self setStateAndNotify:YTMULyricsFetchStateFetching];

    NSArray *providers = [self orderedProviders];
    YTMULyricsLog(@"lyrics refresh videoId=%@ title=%@ artist=%@ preferred=%@ providers=%lu",
                  info.videoId,
                  info.title,
                  info.artist,
                  YTMULyricsSettingsString(@"lyricsPreferredSource", @"auto"),
                  (unsigned long)providers.count);
    YTMULyricsSearchInfo *infoCopy = [info copy];
    [self tryProviders:providers
                 index:0
                  info:infoCopy
            generation:generation
            lastErrors:[NSMutableArray array]
        fallbackResult:nil
      fallbackProvider:nil
    updateAvailability:YES
            completion:^(YTMULyricsResult *rawResult, id<YTMULyricsProvider> rawProvider, NSArray<NSString *> *errors) {
        if (generation != self.requestGeneration || ![infoCopy.videoId isEqualToString:self.activeVideoId]) return;
        if (rawResult.hasText) {
            if (rawResult == [self currentResult]) {
                // (defensive: shouldn't happen, but a no-op finish is safer than re-running side effects.)
            } else {
                [self finishWithResult:rawResult info:infoCopy provider:rawProvider generation:generation];
            }
        } else {
            self.state = YTMULyricsFetchStateError;
            self.lastErrorMessage = errors.count ? [errors componentsJoinedByString:@" | "] : YTMULyricsManagerLocalized(@"LYRICS_STATE_NO_LYRICS", @"No lyrics found");
            YTMULyricsLog(@"lyrics lookup exhausted videoId=%@ errors=%@", infoCopy.videoId, self.lastErrorMessage);
            [self notify];
            [self probeRemainingProvidersForInfo:infoCopy generation:generation];
        }

        // Quality gate: if raw is already a confident synced+exact match,
        // skip AI. Otherwise (inexact match, plain-only, or all-miss) hand
        // off to the title normalizer for an AI re-pass — see
        // -maybeAttemptAINormalize... for full criteria.
        [self maybeAttemptAINormalizeForInfo:infoCopy
                                  rawResult:rawResult
                                rawProvider:rawProvider
                                 generation:generation];
    }];
}

#pragma mark - AI title normalize re-pass

// Best-of similarity between a candidate string and an array of
// alternates. Returns 0 if either side is empty.
static CGFloat YTMULMBestArtistSimilarity(NSArray<NSString *> *artists, NSString *expected) {
    if (!expected.length || !artists.count) return 0.0;
    CGFloat best = 0.0;
    for (NSString *artist in artists) {
        if (![artist isKindOfClass:[NSString class]] || !artist.length) continue;
        CGFloat sim = YTMULyricsSimilarity(artist, expected);
        if (sim > best) best = sim;
    }
    return best;
}

- (BOOL)isHighQualityResult:(YTMULyricsResult *)result forInfo:(YTMULyricsSearchInfo *)info {
    if (!result.hasText) return NO;
    if (result.inexact) return NO;
    BOOL syncedRequested = YTMULyricsSettingsBool(@"syncedLyricsEnabled", NO) ||
                           YTMULyricsSettingsBool(@"bilingualLyrics", NO);
    if (syncedRequested && !result.isSynced) return NO;

    // Even when the provider reports inexact=NO, the matched track can be
    // a different song that just shares a title (NetEase routinely returns
    // "タイムカプセル" by THE MUSMUS for a YT video that's actually
    // Qeiru's track of the same name; LRCLib has done the same with
    // "Ex Luna Scientia"). Cross-check the matched metadata against the
    // YT input — if either side diverges hard, skip the high-quality
    // shortcut so the AI normalizer gets a chance to re-pass.
    if (info.title.length && result.title.length) {
        CGFloat titleSim = YTMULyricsSimilarity(result.title, info.title);
        if (titleSim < 0.5) {
            YTMULyricsLog(@"quality gate fail: title sim %.2f result=\"%@\" vs info=\"%@\"",
                          (double)titleSim, result.title, info.title);
            return NO;
        }
    }
    if (info.artist.length && result.artists.count) {
        CGFloat best = YTMULMBestArtistSimilarity(result.artists, info.artist);
        if (best < 0.3) {
            YTMULyricsLog(@"quality gate fail: artist sim %.2f result=[%@] vs info=\"%@\"",
                          (double)best,
                          [result.artists componentsJoinedByString:@", "],
                          info.artist);
            return NO;
        }
    }
    return YES;
}

- (double)qualityScoreForResult:(YTMULyricsResult *)result forInfo:(YTMULyricsSearchInfo *)info {
    if (!result.hasText) return 0.0;
    double score = 0.5;                    // baseline for "has any text"
    if (result.isSynced) score += 0.3;     // synced way better than plain
    if (!result.inexact) score += 0.15;    // exact title/artist match
    if (result.lines.count > 8) score += 0.05; // long enough to be a real song

    // Penalty for matched-track metadata that doesn't look like what the
    // caller searched for. Without this a wrong-song-same-title hit can
    // score 1.0 and drown out the AI re-pass's correct match.
    if (info.title.length && result.title.length) {
        CGFloat titleSim = YTMULyricsSimilarity(result.title, info.title);
        if (titleSim < 0.5) score -= 0.4;
        else if (titleSim < 0.8) score -= 0.1;
    }
    if (info.artist.length && result.artists.count) {
        CGFloat best = YTMULMBestArtistSimilarity(result.artists, info.artist);
        if (best < 0.3) score -= 0.3;
        else if (best < 0.6) score -= 0.1;
    }
    return MAX(0.0, MIN(1.0, score));
}

- (void)maybeAttemptAINormalizeForInfo:(YTMULyricsSearchInfo *)info
                             rawResult:(YTMULyricsResult *)rawResult
                           rawProvider:(id<YTMULyricsProvider>)rawProvider
                            generation:(NSUInteger)generation {
    if (generation != self.requestGeneration || ![info.videoId isEqualToString:self.activeVideoId]) return;
    if ([self isHighQualityResult:rawResult forInfo:info]) {
        return; // raw is good, no need to ask AI
    }

    id<YTMULLMCompletionProvider> llm = [[YTMUTranslator sharedTranslator] currentLLMCompletionProvider];
    if (!llm) {
        YTMULyricsLog(@"normalize skipped videoId=%@ reason=no LLM provider configured", info.videoId);
        return;
    }
    if (![info.videoId length]) return;

    NSString *providerName = [[YTMUTranslator sharedTranslator] currentProviderName];
    YTMULyricsTitleNormalizer *normalizer = [YTMULyricsTitleNormalizer sharedNormalizer];
    if ([normalizer isBlacklistedForVideoId:info.videoId]) {
        YTMULyricsLog(@"normalize blacklisted videoId=%@ — skipping", info.videoId);
        return;
    }

    void (^fire)(void) = ^{
        [normalizer normalizeForInfo:info
                            provider:llm
                        providerName:providerName
                          completion:^(YTMULyricsTitleNormalization * _Nullable normalized, NSError * _Nullable error) {
            if (generation != self.requestGeneration || ![info.videoId isEqualToString:self.activeVideoId]) return;
            if (error || !normalized) {
                YTMULyricsLog(@"normalize unavailable videoId=%@ err=%@", info.videoId, error.localizedDescription ?: @"<no result>");
                return;
            }
            [self runNormalizedRepassForOriginalInfo:info
                                       normalization:normalized
                                           rawResult:rawResult
                                         rawProvider:rawProvider
                                          generation:generation];
        }];
    };

    // Cache hit path runs immediately — no need to wait, the result is on
    // disk. Cache miss path debounces 500ms: YouTube Music's player
    // metadata can flicker for 1–2s after a song change (we receive the
    // previous song's title with the new videoId, then the real one).
    // Without the wait we'd burn an AI request on the wrong title and
    // race the correct request after it. If a fresher refresh comes in
    // during the wait, the generation check inside fire() drops the
    // stale call.
    if ([normalizer cachedNormalizationForInfo:info]) {
        fire();
        return;
    }

    NSUInteger savedGeneration = generation;
    NSString *savedVideoId = info.videoId ?: @"";
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (savedGeneration != self.requestGeneration ||
            ![savedVideoId isEqualToString:self.activeVideoId]) {
            YTMULyricsLog(@"normalize debounce dropped videoId=%@ — newer refresh in flight", savedVideoId);
            return;
        }
        fire();
    });
}

- (void)runNormalizedRepassForOriginalInfo:(YTMULyricsSearchInfo *)originalInfo
                             normalization:(YTMULyricsTitleNormalization *)normalized
                                 rawResult:(YTMULyricsResult *)rawResult
                               rawProvider:(id<YTMULyricsProvider>)rawProvider
                                generation:(NSUInteger)generation {
    if (generation != self.requestGeneration || ![originalInfo.videoId isEqualToString:self.activeVideoId]) return;

    YTMULyricsSearchInfo *candidate = [originalInfo copy];
    candidate.title = normalized.titleCandidates.firstObject ?: originalInfo.title;
    candidate.artist = normalized.artistCandidates.firstObject ?: originalInfo.artist;
    candidate.alternativeTitle = normalized.titleCandidates.count > 1
        ? normalized.titleCandidates[1]
        : originalInfo.alternativeTitle;

    YTMULyricsLog(@"normalize re-pass start videoId=%@ title=\"%@\" artist=\"%@\" rawScore=%.2f",
                  originalInfo.videoId, candidate.title, candidate.artist,
                  [self qualityScoreForResult:rawResult forInfo:originalInfo]);

    NSArray *providers = [self orderedProviders];
    [self tryProviders:providers
                 index:0
                  info:candidate
            generation:generation
            lastErrors:[NSMutableArray array]
        fallbackResult:nil
      fallbackProvider:nil
    updateAvailability:NO
            completion:^(YTMULyricsResult *normalizedResult, id<YTMULyricsProvider> normalizedProvider, NSArray<NSString *> *errors) {
        if (generation != self.requestGeneration || ![originalInfo.videoId isEqualToString:self.activeVideoId]) return;
        // Score raw against the original YT metadata, normalized against
        // the AI-cleaned candidate metadata: that way a wrong-song raw
        // hit takes the title/artist mismatch penalty while a correctly
        // re-located normalized hit doesn't.
        double rawScore = [self qualityScoreForResult:rawResult forInfo:originalInfo];
        double newScore = [self qualityScoreForResult:normalizedResult forInfo:candidate];
        if (!normalizedResult.hasText || newScore <= rawScore) {
            YTMULyricsLog(@"normalize re-pass kept raw videoId=%@ rawScore=%.2f newScore=%.2f",
                          originalInfo.videoId, rawScore, newScore);
            return;
        }
        // Replace currentResult with the normalized hit. Mark it under the
        // *original* info so cache keys for downstream translation/probe
        // stay aligned with the player's actual videoId.
        normalizedResult.title = normalizedResult.title.length ? normalizedResult.title : candidate.title;
        YTMULyricsLog(@"normalize re-pass replaced raw videoId=%@ source=%@ newScore=%.2f title=\"%@\"",
                      originalInfo.videoId,
                      [normalizedProvider providerName],
                      newScore,
                      normalizedResult.title);
        [self finishWithResult:normalizedResult info:originalInfo provider:normalizedProvider generation:generation];
    }];
}

@end
