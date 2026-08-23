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
#import "Providers/YTMUDescriptionProvider.h"
#import "../Utils/NSBundle+YTMU.h"
#import "YTMURomanizationService.h"
#import <NaturalLanguage/NaturalLanguage.h>

static NSString *YTMULyricsManagerLocalized(NSString *key, NSString *fallback) {
    return [NSBundle.ytmu_defaultBundle localizedStringForKey:key value:fallback table:nil] ?: (fallback ?: key);
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
// How long one provider may hold up a pass before it is skipped. Every
// provider bounds its own requests (≈8 s each), but NetEase's
// candidate-by-candidate lyric fetch and Genius's two legs can stack
// several of those; this keeps the chain moving regardless. A late answer
// is still cached and still updates the availability chip.
@property (nonatomic) NSTimeInterval providerBudgetSeconds;
@end

// Result of a single provider pass. provider/result are set together
// — if result is nil the pass exhausted every provider with no match.
typedef void (^YTMULyricsTryProvidersCompletion)(YTMULyricsResult *_Nullable result,
                                                 id<YTMULyricsProvider> _Nullable provider,
                                                 NSArray<NSString *> *_Nonnull errors);

// One walk over an ordered provider list for one search. Carries the
// cursor and the running fallback so the recursion below does not have to
// thread nine parameters through every step.
@interface YTMULyricsProviderPass : NSObject
@property (nonatomic, copy) NSArray<id<YTMULyricsProvider>> *providers;
@property (nonatomic) NSUInteger index;
@property (nonatomic, copy) YTMULyricsSearchInfo *info;
@property (nonatomic) NSUInteger generation;
@property (nonatomic, strong) NSMutableArray<NSString *> *errors;
@property (nonatomic, strong, nullable) YTMULyricsResult *fallbackResult;     // best imperfect-but-similar so far
@property (nonatomic, strong, nullable) id<YTMULyricsProvider> fallbackProvider;
@property (nonatomic) BOOL updateAvailability;                                  // raw pass drives the status chips; re-pass is silent
@property (nonatomic, copy) YTMULyricsTryProvidersCompletion completion;
@end
@implementation YTMULyricsProviderPass
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
        model = YTMULyricsSettingsString(@"translationModel_anthropic", YTMUTranslationDefaultModelForProvider(provider));
    } else if ([provider isEqualToString:YTMUTranslationProviderGemini]) {
        name = YTMULyricsManagerLocalized(@"PROVIDER_GEMINI", @"Gemini");
        model = YTMULyricsSettingsString(@"translationModel_gemini", YTMUTranslationDefaultModelForProvider(provider));
    } else if ([provider isEqualToString:YTMUTranslationProviderOpenAI]) {
        name = YTMULyricsManagerLocalized(@"PROVIDER_OPENAI", @"OpenAI-compatible");
        model = YTMULyricsSettingsString(@"translationModel_openai-compatible", YTMUTranslationDefaultModelForProvider(provider));
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
        // Order matters here:
        //   YTMusic / NetEase / MusixMatch / Genius — fast, cheap, run first.
        //   Description — runs AFTER the cheap DBs but BEFORE LRCLib.
        //     Description has two short-circuit guards: (a) if the
        //     description string isn't in the search info yet, it
        //     returns an instant miss; (b) if there's no LLM provider
        //     configured, same. So in raw pass (description still
        //     fetching from InnerTube) it costs ~0ms. In re-refresh
        //     (after InnerTube completes), it usually hits and saves
        //     us LRCLib's 6-8s timeout.
        //   LRCLib — last because its fallback path can take up to its
        //     8s deadline before giving up; placing it after Description
        //     means a successful Description hit returns the result
        //     without waiting on LRCLib.
        _providers = @[
            [[YTMUYTMusicProvider alloc] init],
            [[YTMUNetEaseProvider alloc] init],
            [[YTMUMusixMatchProvider alloc] init],
            [[YTMUGeniusProvider alloc] init],
            [[YTMUDescriptionProvider alloc] init],
            [[YTMULRCLibProvider alloc] init],
        ];
        _state = YTMULyricsFetchStateIdle;
        _activeVideoId = @"";
        _translatedLines = @[];
        _translationAttribution = @"";
        _lastErrorMessage = @"";
        _sourceAvailability = @{};
        _providerBudgetSeconds = 20.0;
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
    NSMutableArray<id<YTMULyricsProvider>> *ordered = [NSMutableArray array];
    // When the user pins a preferred source we put it first so the
    // pipeline asks it before everything else — but we still keep the
    // other providers as fallback. A pinned source that returns a
    // wrong-song match (e.g. NetEase confidently serving THE MUSMUS for
    // a Qeiru video) is still wrong; the quality gate further down will
    // discard it and the rest of the chain (incl. Description) gets a
    // shot. "Preferred" means "preferred", not "exclusive".
    if (![preferred isEqualToString:@"auto"]) {
        id<YTMULyricsProvider> pinned = byName[preferred];
        if (pinned) [ordered addObject:pinned];
    }
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
    [[YTMURomanizationService sharedService] clearMemoryCache];
}

- (NSArray<NSString *> *)displayLineTexts {
    return [self.currentResult lineTexts] ?: @[];
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

- (void)applyRomanizedLines:(NSArray<NSString *> *)romanized generation:(NSUInteger)generation info:(YTMULyricsSearchInfo *)info cacheKey:(NSString *)cacheKey {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (generation != self.requestGeneration || ![info.videoId isEqualToString:self.activeVideoId]) return;
        YTMULyricsResult *current = [self.currentResult copy];
        if (!current) return;   // nothing to decorate (and never write nil back)
        NSArray<NSString *> *sourceLines = [current lineTexts] ?: @[];
        NSString *sourceLanguage = [[YTMURomanizationService sharedService] sourceLanguageForLines:current.lineTexts];

        // Render whatever we got — DON'T gate on every line being filled.
        // Google's per-segment transliteration endpoint occasionally
        // returns empty for an individual line (rate-limit, weird kanji,
        // empty/punctuation-only line, etc.) and the old behavior was to
        // wipe ALL lines if even one came back blank, which is why users
        // saw zero romanization on long lyrics. Now: hit lines render,
        // miss lines stay empty, the user sees the partial result.
        NSUInteger filled = 0;
        NSUInteger needed = 0;
        NSMutableArray<NSString *> *lineTexts = [NSMutableArray arrayWithCapacity:sourceLines.count];
        for (NSUInteger idx = 0; idx < sourceLines.count; idx++) {
            NSString *text = [sourceLines[idx] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            BOOL needsRomanization = [YTMULyricsTextProcessor needsRomanizationForText:text preferredLanguage:sourceLanguage];
            NSString *value = idx < romanized.count ? romanized[idx] : @"";
            value = [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].length ? value : @"";
            if (needsRomanization) {
                needed++;
                if (value.length) filled++;
            }
            [lineTexts addObject:value];
        }
        current.romanizedLineTexts = lineTexts;

        NSMutableArray<YTMULyricLine *> *lines = [NSMutableArray arrayWithCapacity:current.lines.count];
        for (NSUInteger idx = 0; idx < current.lines.count; idx++) {
            YTMULyricLine *line = [current.lines[idx] copy];
            NSString *value = idx < romanized.count ? romanized[idx] : @"";
            value = [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].length ? value : @"";
            line.romanizedText = value;
            [lines addObject:line];
        }
        current.lines = lines;
        self.currentResult = current;

        // Cache the partial result too — re-running 28 HTTP roundtrips
        // every replay just to recover the same partial set is what made
        // the old "complete=NO ⇒ delete cache" behavior so painful.
        // Empty arrays still don't get cached (nothing to remember).
        BOOL anyFilled = filled > 0;
        [[YTMURomanizationService sharedService] storeLines:anyFilled ? lineTexts : nil forKey:cacheKey];
        if (current.sourceName.length && anyFilled) {
            NSString *lyricsCacheKey = [YTMULyricsCache cacheKeyForInfo:info source:current.sourceName];
            [[YTMULyricsCache sharedCache] storeResult:current forKey:lyricsCacheKey];
        }
        YTMULyricsLog(@"google romanization applied videoId=%@ filled=%lu/%lu lines=%lu",
                      info.videoId,
                      (unsigned long)filled,
                      (unsigned long)needed,
                      (unsigned long)romanized.count);
        [self notify];
    });
}

- (void)fetchRomanizationIfNeededForInfo:(YTMULyricsSearchInfo *)info generation:(NSUInteger)generation {
    if (!YTMULyricsSettingsBool(@"lyricsRomanization", YES)) return;
    YTMULyricsResult *result = self.currentResult;
    NSArray<NSString *> *source = [result lineTexts] ?: @[];
    if (!source.count) return;

    YTMURomanizationService *service = [YTMURomanizationService sharedService];
    NSString *sourceLanguage = [service sourceLanguageForLines:source];
    NSArray<NSDictionary *> *items = [service romanizableItemsForLines:source existing:result.romanizedLineTexts sourceLanguage:sourceLanguage];
    if (!items.count) return;

    NSString *cacheKey = [service cacheKeyForVideoId:info.videoId source:result.sourceName lines:source];
    NSArray<NSString *> *cached = [service cachedLinesForKey:cacheKey];
    if (cached.count == source.count) {
        [self applyRomanizedLines:cached generation:generation info:info cacheKey:cacheKey];
        return;
    }

    NSMutableArray<NSString *> *romanized = [NSMutableArray arrayWithCapacity:source.count];
    for (NSUInteger idx = 0; idx < source.count; idx++) {
        NSString *existing = idx < result.romanizedLineTexts.count ? result.romanizedLineTexts[idx] : @"";
        [romanized addObject:existing ?: @""];
    }

    // Stop issuing requests once the song has changed; applyRomanizedLines'
    // generation check then drops whatever partial result comes back.
    __weak typeof(self) weakSelf = self;
    NSUInteger limit = MIN(items.count, (NSUInteger)80);
    [service romanizeItems:items limit:limit sourceLanguage:sourceLanguage into:romanized
            shouldContinue:^BOOL{ typeof(self) strongSelf = weakSelf; return strongSelf != nil && generation == strongSelf.requestGeneration; }
                completion:^(NSArray<NSString *> *values) {
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
    // Snapshot what the translation request was issued FOR. The
    // generation counter only ticks on song-change refreshWithInfo:
    // calls, but within a single song the source can still flip out
    // from under us — e.g. Description fallback (lines=46) → AI
    // normalize re-pass discovers NetEase (lines=42). If the slow AI
    // translation we kicked off for the Description rows lands AFTER
    // the NetEase source took over, the old completion would overwrite
    // NetEase's official tlyric and we'd render 42 lyric rows against
    // 46 translation rows misaligned. The completion bails when either
    // sourceName or line count has drifted.
    NSString *requestedForSource = self.currentResult.sourceName ?: @"";
    NSUInteger requestedLineCount = sourceLines.count;
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
        NSString *currentSource = self.currentResult.sourceName ?: @"";
        NSUInteger currentLineCount = self.currentResult.lineTexts.count;
        if (![currentSource isEqualToString:requestedForSource] || currentLineCount != requestedLineCount) {
            YTMULyricsLog(@"translation discarded: source changed during request videoId=%@ requested=%@/%lu current=%@/%lu",
                          info.videoId,
                          requestedForSource,
                          (unsigned long)requestedLineCount,
                          currentSource,
                          (unsigned long)currentLineCount);
            return;
        }
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



// True if the matched track's title and artist look reasonably close to
// what the caller searched for. Provider-reported `inexact` is unreliable
// — NetEase returns inexact=NO for any track sharing a title even if the
// artist is completely different (THE MUSMUS / タイムカプセル returned
// for a Qeiru search). We do our own check based on string similarity so
// the same logic applies whether the provider claims exact or inexact.
//
// Note on the duration escape hatch: a previous iteration accepted
// artist-mismatched results when title sim was high and duration was
// within ~5s. That assumption was wrong — Japanese vocaloid cover
// culture means a same-title-same-length cover by a different artist
// is often genuinely a different track with completely different lyrics
// (e.g. 冥河's cover of sato noco's 「以上、n番観測地から…」). Better
// to reject and let the AI normalize re-pass try again than show
// confidently-wrong lyrics.
- (BOOL)result:(YTMULyricsResult *)result similarToInfo:(YTMULyricsSearchInfo *)info {
    if (!result.hasText) return NO;
    // Build the candidate (title, artist) pairs to test against. Start
    // with the raw info, then fold in any normalize-cache candidates
    // for this videoId. On second-or-later replays of a song where the
    // player's channel-name artist (e.g. "Nao") doesn't match the
    // actual track artist (e.g. "夏央"), a NetEase cache hit looks
    // like a wrong-song match by raw info alone — and we re-discover
    // the same NetEase hit via normalize re-pass anyway, paying the
    // full LRCLib-timeout penalty in between. Including normalized
    // candidates here short-circuits that round trip.
    NSMutableArray<NSString *> *titles = [NSMutableArray array];
    NSMutableArray<NSString *> *artists = [NSMutableArray array];
    if (info.title.length) [titles addObject:info.title];
    if (info.artist.length) [artists addObject:info.artist];
    if (info.videoId.length) {
        YTMULyricsTitleNormalization *normalized = [[YTMULyricsTitleNormalizer sharedNormalizer] cachedNormalizationForInfo:info];
        for (NSString *t in normalized.titleCandidates) {
            if (t.length && ![titles containsObject:t]) [titles addObject:t];
        }
        for (NSString *a in normalized.artistCandidates) {
            if (a.length && ![artists containsObject:a]) [artists addObject:a];
        }
    }
    if (!titles.count) [titles addObject:@""];
    if (!artists.count) [artists addObject:@""];
    for (NSString *title in titles) {
        BOOL titleOK = !title.length || !result.title.length ||
                       YTMULyricsSimilarity(result.title, title) >= 0.5;
        if (!titleOK) continue;
        for (NSString *artist in artists) {
            BOOL artistOK = !artist.length || !result.artists.count ||
                            YTMULMBestArtistSimilarity(result.artists, artist) >= 0.3;
            if (artistOK) return YES;
        }
    }
    return NO;
}

// Pick the better of two candidate fallbacks by quality score against
// the search info. Prefers `incoming` on ties so we get the most-recent
// provider's view (which has its own data freshness benefits).
- (void)pickBetterFallback:(YTMULyricsResult **)bestResultPtr
                  provider:(id<YTMULyricsProvider> *)bestProviderPtr
                  incoming:(YTMULyricsResult *)incoming
          incomingProvider:(id<YTMULyricsProvider>)incomingProvider
                      info:(YTMULyricsSearchInfo *)info {
    if (!incoming.hasText) return;
    if (!*bestResultPtr) {
        *bestResultPtr = incoming;
        *bestProviderPtr = incomingProvider;
        return;
    }
    double currentScore = [self qualityScoreForResult:*bestResultPtr forInfo:info];
    double incomingScore = [self qualityScoreForResult:incoming forInfo:info];
    if (incomingScore >= currentScore) {
        *bestResultPtr = incoming;
        *bestProviderPtr = incomingProvider;
    }
}

- (void)runProviderPass:(YTMULyricsProviderPass *)pass {
    YTMULyricsSearchInfo *info = pass.info;
    if (pass.generation != self.requestGeneration || ![info.videoId isEqualToString:self.activeVideoId]) return;
    if (pass.index >= pass.providers.count) {
        if (pass.fallbackResult.hasText) {
            pass.completion(pass.fallbackResult, pass.fallbackProvider, pass.errors);
            return;
        }
        pass.completion(nil, nil, pass.errors);
        return;
    }

    id<YTMULyricsProvider> provider = pass.providers[pass.index];
    BOOL updateAvailability = pass.updateAvailability;
    if (updateAvailability) [self setAvailability:@"checking" forProvider:provider notify:YES];
    BOOL syncedRequested = YTMULyricsSettingsBool(@"syncedLyricsEnabled", NO) ||
                           YTMULyricsSettingsBool(@"bilingualLyrics", NO) ||
                           YTMULyricsSettingsBool(@"lyricsTranslationEnabled", NO);

    // Is the current provider the source the user explicitly pinned?
    // When the user picks "YTMusic" / "Genius" / "LRCLib" / etc. in
    // the Lyrics source sheet, we put that provider first in
    // `orderedProviders` and want to respect their choice for the
    // gate logic below. "auto" means "no explicit preference, do
    // whatever's best", which is the historical default.
    NSString *preferred = YTMULyricsSettingsString(@"lyricsPreferredSource", @"auto");
    BOOL providerIsPinned = ![preferred isEqualToString:@"auto"] &&
                            [[provider providerName] isEqualToString:preferred];

    // Common acceptance check shared by cache-hit and live-response paths.
    // Similarity (right-song-ness) is always enforced — a wrong-song
    // match is wrong in any mode. The synced-only check, however, is
    // skipped for the user's pinned source: if they explicitly asked
    // for YTMusic / Genius / LRCLib and that source returned a
    // matching plain-text result, the picker UI labelled it
    // "Matched" and the user expects clicking it to actually surface
    // that source's lyrics — not silently fall through to NetEase
    // because synced lyrics are also requested in the settings.
    // "Preferred" means "preferred", not "best-effort if synced".
    void (^acceptOrContinue)(YTMULyricsResult *, BOOL) = ^(YTMULyricsResult *result, BOOL fromCache) {
        BOOL similar = [self result:result similarToInfo:info];
        BOOL syncedOK = !syncedRequested || result.isSynced || providerIsPinned;
        BOOL isPerfect = similar && syncedOK;
        BOOL hasMore = (pass.index + 1 < pass.providers.count);

        if (isPerfect) {
            pass.completion(result, provider, pass.errors);
            return;
        }

        // Imperfect — only consider as fallback when the title and artist
        // actually match what the caller searched for. A wrong-artist
        // result (NetEase returning THE MUSMUS for a Qeiru search) just
        // misleads the user if we surface it; drop it so the rest of the
        // chain (other providers, AI normalizer re-pass) can try. If no
        // provider produces a similar match, we return nil from this pass
        // and the UI shows "no lyrics found" rather than the wrong song.
        YTMULyricsResult *bestFallback = pass.fallbackResult;
        id<YTMULyricsProvider> bestProvider = pass.fallbackProvider;
        if (similar) {
            [self pickBetterFallback:&bestFallback provider:&bestProvider
                            incoming:result incomingProvider:provider info:info];
        } else {
            // The cache-hit and live-response paths above optimistically
            // set availability=hit before we knew if the result was for
            // the right song. Now that we've decided to discard, flip it
            // back to "miss" so the UI status indicator doesn't lie about
            // a NetEase response that we threw away.
            if (updateAvailability) [self setAvailability:@"miss" forProvider:provider notify:YES];
        }

        YTMULyricsLog(@"lyrics low-confidence candidate videoId=%@ source=%@ similar=%@ synced=%@ %@; %@",
                      info.videoId,
                      [provider providerName],
                      similar ? @"YES" : @"NO",
                      result.isSynced ? @"YES" : @"NO",
                      fromCache ? @"(cache)" : @"(net)",
                      similar ? @"kept as fallback, continuing" : @"discarded (wrong song), continuing");

        if (!hasMore) {
            // Exhausted — return whatever fallback won (may be nil if every
            // provider's match was a wrong-song hit, which is the desired
            // behavior: better to say "not found" than show wrong lyrics).
            pass.completion(bestFallback, bestProvider, pass.errors);
            return;
        }
        pass.fallbackResult = bestFallback;
        pass.fallbackProvider = bestProvider;
        pass.index += 1;
        [self runProviderPass:pass];
    };

    NSString *cacheKey = [YTMULyricsCache cacheKeyForInfo:info source:[provider providerName]];
    YTMULyricsResult *cached = [[YTMULyricsCache sharedCache] resultForKey:cacheKey];
    if (cached.hasText) {
        if (updateAvailability) [self setAvailability:@"hit" forProvider:provider notify:NO];
        YTMULyricsLog(@"lyrics cache hit videoId=%@ source=%@", info.videoId, [provider providerName]);
        acceptOrContinue(cached, YES);
        return;
    }

    YTMULyricsLog(@"lyrics source request videoId=%@ source=%@ title=%@ artist=%@ duration=%.1f",
                  info.videoId,
                  [provider providerName],
                  info.title,
                  info.artist,
                  info.duration);
    NSUInteger generation = pass.generation;
    // `settled` (main-thread only) makes sure exactly one of {answer, budget
    // timeout} advances the pass; the other just records what it learned.
    __block BOOL settled = NO;
    NSTimeInterval budget = self.providerBudgetSeconds;
    if (budget > 0) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(budget * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (settled) return;
            if (generation != self.requestGeneration || ![info.videoId isEqualToString:self.activeVideoId]) return;
            settled = YES;
            YTMULyricsLog(@"lyrics source budget exceeded videoId=%@ source=%@ after %.0fs — moving on", info.videoId, [provider providerName], budget);
            [pass.errors addObject:[NSString stringWithFormat:@"%@: %@", [provider providerName],
                                    YTMULyricsManagerLocalized(@"LYRICS_PROVIDER_TIMEOUT", @"timed out")]];
            pass.index += 1;
            [self runProviderPass:pass];
        });
    }
    [provider searchWithInfo:info completion:^(YTMULyricsResult *result, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self.requestGeneration || ![info.videoId isEqualToString:self.activeVideoId]) return;
            if (result.hasText) {
                if (updateAvailability) [self setAvailability:@"hit" forProvider:provider notify:NO];
                [[YTMULyricsCache sharedCache] storeResult:result forKey:cacheKey];
                if (settled) return;          // answered after the budget: cached for next time
                settled = YES;
                acceptOrContinue(result, NO);
                return;
            }
            if (settled) return;
            settled = YES;
            NSString *message = error.localizedDescription ?: YTMULyricsManagerLocalized(@"LYRICS_PROVIDER_NO_MATCH", @"no match");
            if (updateAvailability) [self setAvailability:@"miss" forProvider:provider notify:YES];
            [pass.errors addObject:[NSString stringWithFormat:@"%@: %@", [provider providerName], message]];
            YTMULyricsLog(@"lyrics source miss videoId=%@ source=%@ reason=%@", info.videoId, [provider providerName], message);
            pass.index += 1;
            [self runProviderPass:pass];
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
    YTMULyricsProviderPass *rawPass = [[YTMULyricsProviderPass alloc] init];
    rawPass.providers = providers;
    rawPass.info = infoCopy;
    rawPass.generation = generation;
    rawPass.errors = [NSMutableArray array];
    rawPass.updateAvailability = YES;
    rawPass.completion = ^(YTMULyricsResult *rawResult, id<YTMULyricsProvider> rawProvider, NSArray<NSString *> *errors) {
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
    };
    [self runProviderPass:rawPass];
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
    YTMULyricsProviderPass *repass = [[YTMULyricsProviderPass alloc] init];
    repass.providers = providers;
    repass.info = candidate;
    repass.generation = generation;
    repass.errors = [NSMutableArray array];
    repass.updateAvailability = NO;
    repass.completion = ^(YTMULyricsResult *normalizedResult, id<YTMULyricsProvider> normalizedProvider, NSArray<NSString *> *errors) {
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
    };
    [self runProviderPass:repass];
}

@end
