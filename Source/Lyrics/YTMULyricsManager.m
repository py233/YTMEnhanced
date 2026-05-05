#import "YTMULyricsManager.h"
#import "YTMULyricsCache.h"
#import "YTMULyricsTextProcessor.h"
#import "../Translation/YTMUTranslator.h"
#import "../Translation/YTMUPromptBuilder.h"
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
@end

@implementation YTMULyricsManager

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
    NSMutableArray *ordered = [NSMutableArray array];
    NSDictionary *byName = self.providersByName;
    if (![preferred isEqualToString:@"auto"] && byName[preferred]) {
        [ordered addObject:byName[preferred]];
    }
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
                         @"lyricsDefaultText",
                         @"lyricsConvertChinese",
                         @"lyricsRomanization",
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
    self.translationAttribution = [NSString stringWithFormat:@"Official %@ translation", self.currentResult.officialTranslationProvider.length ? self.currentResult.officialTranslationProvider : self.currentResult.sourceName];
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
        self.translationAttribution = @"Translated";
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
    [self fetchTranslationForInfo:info generation:generation];
}

- (void)tryProviders:(NSArray<id<YTMULyricsProvider>> *)providers
               index:(NSUInteger)index
                info:(YTMULyricsSearchInfo *)info
          generation:(NSUInteger)generation
          lastErrors:(NSMutableArray<NSString *> *)lastErrors {
    if (generation != self.requestGeneration || ![info.videoId isEqualToString:self.activeVideoId]) return;
    if (index >= providers.count) {
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
                [self finishWithResult:result info:info provider:provider generation:generation];
                return;
            }
            NSString *message = error.localizedDescription ?: @"no match";
            [lastErrors addObject:[NSString stringWithFormat:@"%@: %@", [provider providerName], message]];
            YTMULyricsLog(@"lyrics source miss videoId=%@ source=%@ reason=%@", info.videoId, [provider providerName], message);
            [self tryProviders:providers index:index + 1 info:info generation:generation lastErrors:lastErrors];
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
    [self tryProviders:providers index:0 info:[info copy] generation:generation lastErrors:[NSMutableArray array]];
}

@end
