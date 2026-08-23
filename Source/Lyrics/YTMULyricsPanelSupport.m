#import "YTMULyricsPanelSupport.h"
#import "../Utils/YTMUKVC.h"
#import <MediaPlayer/MediaPlayer.h>
#import <objc/runtime.h>
#import "../Headers/Localization.h"
#import "../Headers/YTIFormattedString.h"
#import "YTMULyricsManager.h"
#import "YTMULyricsPlaybackState.h"
#import "YTMUSyncedLyricsView.h"
#import "YTMULyricsTextProcessor.h"
#import "../Translation/YTMUTranslationContext.h"
#import "../Translation/YTMUTranslationTypes.h"

NSDictionary *YTMULyricsPageSettings(void) {
    return [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"YTMUltimate"] ?: @{};
}

BOOL YTMULyricsPageBool(NSString *key) {
    return [YTMULyricsPageSettings()[key] boolValue];
}

BOOL YTMULyricsPageBoolDefault(NSString *key, BOOL fallback) {
    id value = YTMULyricsPageSettings()[key];
    return [value respondsToSelector:@selector(boolValue)] ? [value boolValue] : fallback;
}

NSString *YTMULyricsPageString(NSString *key, NSString *fallback) {
    id value = YTMULyricsPageSettings()[key];
    if ([value isKindOfClass:[NSString class]] && [(NSString *)value length]) return value;
    return fallback ?: @"";
}

NSString *YTMULyricsPageLocalized(NSString *key, NSString *fallback) {
    return [NSBundle.ytmu_defaultBundle localizedStringForKey:key value:fallback table:nil] ?: (fallback ?: key);
}

NSMutableSet<NSString *> *YTMULyricsOfficialAvailableVideoIds(void) {
    static NSMutableSet *set;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ set = [NSMutableSet set]; });
    return set;
}

void YTMULyricsMarkOfficialAvailableForCurrentSong(NSString *trigger) {
    NSString *videoId = [YTMULyricsManager sharedManager].activeVideoId;
    if (!videoId.length) return;
    NSMutableSet *set = YTMULyricsOfficialAvailableVideoIds();
    BOOL inserted = NO;
    @synchronized (set) {
        if (![set containsObject:videoId]) {
            [set addObject:videoId];
            inserted = YES;
        }
    }
    if (inserted) YTMULyricsLog(@"actionRow: renderer-fired trigger=%@ videoId=%@", trigger, videoId);
}

BOOL YTMULyricsHasOfficialForCurrentSong(void) {
    NSString *videoId = [YTMULyricsManager sharedManager].activeVideoId;
    if (!videoId.length) return NO;
    NSMutableSet *set = YTMULyricsOfficialAvailableVideoIds();
    @synchronized (set) {
        return [set containsObject:videoId];
    }
}

// (Previously a bridge cache mapping action-bar instances to "saw chip"
// timestamps lived here. It was used to carry over a chipPresent
// observation from the videoId-not-yet-known window into the next frame
// where videoId arrived, then promote it into the per-videoId set.
// Removed because the promotion path was attributing the previous song's
// Lyrics cell to the new song whenever YTMNowPlayingViewController flipped
// activeVideoId before tearing down the previous action bar — a window
// that can stretch past two seconds. Detection now runs fresh every
// frame off the dataSource, with no UI-side cache writes.)


BOOL YTMULyricsPageReplacementEnabled(void) {
    return YTMULyricsPageCustomSourceEnabled();
}

BOOL YTMULyricsPageCustomSourceEnabled(void) {
    NSDictionary *settings = YTMULyricsPageSettings();
    return [settings[@"YTMUltimateIsEnabled"] boolValue] &&
           ([settings[@"syncedLyricsEnabled"] boolValue] ||
            [settings[@"lyricsTranslationEnabled"] boolValue] ||
            [settings[@"bilingualLyrics"] boolValue]);
}

void YTMULyricsPageSetSetting(NSString *key, id value) {
    if (!key.length) return;
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSMutableDictionary *settings = [NSMutableDictionary dictionaryWithDictionary:[defaults dictionaryForKey:@"YTMUltimate"] ?: @{}];
    settings[key] = value ?: @"";
    [defaults setObject:settings forKey:@"YTMUltimate"];
    [[NSNotificationCenter defaultCenter] postNotificationName:YTMULyricsSettingsDidChangeNotification
                                                        object:nil
                                                      userInfo:@{YTMULyricsSettingChangedKey: key}];
}

NSArray<NSDictionary *> *YTMULyricsPageSourceOptions(void) {
    static NSArray<NSDictionary *> *options;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        options = @[
            @{@"key": @"auto", @"title": YTMULyricsPageLocalized(@"LYRICS_SOURCE_AUTO", @"Auto")},
            @{@"key": YTMULyricsSourceYTMusic, @"title": @"YTMusic"},
            @{@"key": YTMULyricsSourceLRCLib, @"title": @"LRCLIB"},
            @{@"key": YTMULyricsSourceNetEase, @"title": @"NetEase"},
            @{@"key": YTMULyricsSourceMusixMatch, @"title": @"Musixmatch"},
            @{@"key": YTMULyricsSourceGenius, @"title": @"Genius"},
            @{@"key": YTMULyricsSourceDescription, @"title": @"Description"},
        ];
    });
    return options;
}

NSString *YTMULyricsPageSourceTitle(NSString *key) {
    for (NSDictionary *option in YTMULyricsPageSourceOptions()) {
        if ([option[@"key"] isEqualToString:key]) return option[@"title"];
    }
    return key.length ? key : YTMULyricsPageLocalized(@"LYRICS_SOURCE_AUTO", @"Auto");
}

NSUInteger YTMULyricsPageSourceIndex(NSString *key) {
    NSArray *options = YTMULyricsPageSourceOptions();
    for (NSUInteger idx = 0; idx < options.count; idx++) {
        if ([options[idx][@"key"] isEqualToString:key]) return idx;
    }
    return 0;
}

NSString *YTMULyricsPageNowPlayingTitle(void) {
    YTMULyricsManager *manager = [YTMULyricsManager sharedManager];
    if (manager.currentResult.title.length) return manager.currentResult.title;
    NSString *title = [MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo[MPMediaItemPropertyTitle];
    return title.length ? title : YTMULyricsPageLocalized(@"LYRICS_PANEL_TITLE", @"Lyrics");
}

NSString *YTMULyricsPageNowPlayingArtist(void) {
    YTMULyricsManager *manager = [YTMULyricsManager sharedManager];
    if (manager.currentResult.artists.count) return [manager.currentResult.artists componentsJoinedByString:@", "];
    NSString *artist = [MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo[MPMediaItemPropertyArtist];
    return artist.length ? artist : @"YouTube Music";
}

UIImage *YTMULyricsPageNowPlayingArtwork(CGSize size) {
    id artwork = [MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo[MPMediaItemPropertyArtwork];
    if ([artwork respondsToSelector:@selector(imageWithSize:)]) {
        return [artwork imageWithSize:size];
    }
    return nil;
}

NSString *YTMULyricsPageTranslationProviderTitle(void) {
    NSString *provider = YTMULyricsPageString(@"translationProvider", YTMUTranslationProviderGoogle);
    if ([provider isEqualToString:YTMUTranslationProviderGoogle]) return YTMULyricsPageLocalized(@"PROVIDER_GOOGLE", @"Google Translate");
    if ([provider isEqualToString:YTMUTranslationProviderAnthropic]) return YTMULyricsPageLocalized(@"PROVIDER_ANTHROPIC", @"Anthropic");
    if ([provider isEqualToString:YTMUTranslationProviderGemini]) return YTMULyricsPageLocalized(@"PROVIDER_GEMINI", @"Gemini");
    if ([provider isEqualToString:YTMUTranslationProviderOpenAI]) return YTMULyricsPageLocalized(@"PROVIDER_OPENAI", @"OpenAI-compatible");
    return provider.length ? provider : YTMULyricsPageLocalized(@"LYRICS_PROVIDER_FALLBACK", @"translator");
}

CGFloat YTMULyricsPageClampFontSize(CGFloat size) {
    return MIN(38.0, MAX(12.0, size));
}

CGFloat YTMULyricsPageBaseFontSize(void) {
    id custom = YTMULyricsPageSettings()[@"lyricsFontPointSize"];
    CGFloat pointSize = 0.0;
    if ([custom respondsToSelector:@selector(doubleValue)]) {
        pointSize = [custom doubleValue];
    }
    if (pointSize > 0.0) return YTMULyricsPageClampFontSize(pointSize);

    NSString *size = YTMULyricsPageString(@"lyricsFontSize", @"small");
    if ([size isEqualToString:@"large"]) return 33.0;
    if ([size isEqualToString:@"medium"]) return 27.0;
    return 22.0;
}

void YTMULyricsPageSetBaseFontSize(CGFloat size) {
    YTMULyricsPageSetSetting(@"lyricsFontPointSize", @(llround(YTMULyricsPageClampFontSize(size))));
}

NSString *YTMULyricsPageTimingOffsetKey(void) {
    YTMULyricsManager *manager = [YTMULyricsManager sharedManager];
    YTMULyricsSearchInfo *info = [[YTMULyricsSearchInfo alloc] init];
    info.videoId = manager.activeVideoId ?: @"";
    info.title = manager.currentResult.title ?: @"";
    info.artist = manager.currentResult.artists.count ? [manager.currentResult.artists componentsJoinedByString:@", "] : @"";
    info.duration = manager.currentResult.duration;
    return YTMULyricsTimingOffsetKeyForInfo(info);
}

NSInteger YTMULyricsPageTimingOffsetMs(void) {
    return YTMULyricsCurrentTimingOffsetForKey(YTMULyricsPageTimingOffsetKey());
}

void YTMULyricsPageSetTimingOffsetMs(NSInteger value) {
    YTMULyricsSetTimingOffsetForKey(YTMULyricsPageTimingOffsetKey(), value, YES);
}

NSString *YTMULyricsPageRomanizationLanguageForResult(YTMULyricsResult *result) {
    for (NSString *line in result.lineTexts ?: @[]) {
        if ([YTMULyricsTextProcessor hasJapaneseKana:line ?: @""]) return @"ja";
    }
    return @"auto";
}

BOOL YTMULyricsPageResultHasCompleteRomanization(YTMULyricsResult *result) {
    NSArray<NSString *> *sourceLines = result.lineTexts ?: @[];
    if (!sourceLines.count) return NO;

    BOOL needsRomanization = NO;
    NSString *sourceLanguage = YTMULyricsPageRomanizationLanguageForResult(result);
    for (NSUInteger idx = 0; idx < sourceLines.count; idx++) {
        NSString *text = [sourceLines[idx] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (![YTMULyricsTextProcessor needsRomanizationForText:text preferredLanguage:sourceLanguage]) continue;
        needsRomanization = YES;
        NSString *roman = idx < result.romanizedLineTexts.count ? result.romanizedLineTexts[idx] : @"";
        if (![roman stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].length) {
            return NO;
        }
    }
    return needsRomanization;
}

NSString *YTMULyricsPageRomanizedLineAtIndex(YTMULyricsResult *result, NSUInteger idx) {
    if (idx < result.romanizedLineTexts.count) return result.romanizedLineTexts[idx] ?: @"";
    if (idx < result.lines.count) return result.lines[idx].romanizedText ?: @"";
    return @"";
}

NSString *YTMULyricsPageLineText(NSString *text) {
    NSString *value = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (value.length) return value;
    NSString *mode = YTMULyricsPageString(@"lyricsDefaultText", @"♪");
    if ([mode isEqualToString:@"dots"]) return @"...";
    if ([mode isEqualToString:@"bullets"]) return @"•••";
    if ([mode isEqualToString:@"dash"]) return @"---";
    if ([mode isEqualToString:@"space"]) return @" ";
    return @"♪";
}

UIColor *YTMULyricsPageSecondaryTextColor(void) {
    if (@available(iOS 13.0, *)) return [UIColor secondaryLabelColor];
    return [[UIColor whiteColor] colorWithAlphaComponent:0.58];
}

NSAttributedString *YTMULyricsPageAttributedText(UITextView *textView, NSString *fallbackText) {
    YTMULyricsManager *manager = [YTMULyricsManager sharedManager];
    UIColor *primary = textView.textColor ?: [UIColor labelColor];
    UIColor *secondary = [primary colorWithAlphaComponent:0.58];
    UIColor *translationColor = [primary colorWithAlphaComponent:0.78];
    CGFloat base = YTMULyricsPageBaseFontSize();
    UIFont *mainFont = [UIFont systemFontOfSize:base weight:UIFontWeightHeavy];
    UIFont *romanFont = [UIFont italicSystemFontOfSize:MAX(13.0, base * 0.78)];
    UIFont *translationFont = [UIFont systemFontOfSize:MAX(14.0, base * 0.88) weight:UIFontWeightSemibold];
    UIFont *statusFont = [UIFont systemFontOfSize:MAX(16.0, base * 0.88) weight:UIFontWeightSemibold];

    NSMutableParagraphStyle *mainParagraph = [[NSMutableParagraphStyle alloc] init];
    mainParagraph.paragraphSpacing = 12.0;
    mainParagraph.lineSpacing = 2.0;

    NSMutableParagraphStyle *secondaryParagraph = [[NSMutableParagraphStyle alloc] init];
    secondaryParagraph.paragraphSpacing = 2.0;
    secondaryParagraph.lineSpacing = 1.0;

    NSMutableParagraphStyle *pairEndParagraph = [[NSMutableParagraphStyle alloc] init];
    pairEndParagraph.paragraphSpacing = 16.0;
    pairEndParagraph.lineSpacing = 2.0;

    NSMutableAttributedString *output = [[NSMutableAttributedString alloc] init];
    void (^appendLine)(NSString *, UIFont *, UIColor *, NSParagraphStyle *) = ^(NSString *line, UIFont *font, UIColor *color, NSParagraphStyle *paragraph) {
        if (output.length) [output appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n"]];
        [output appendAttributedString:[[NSAttributedString alloc] initWithString:line ?: @""
                                                                       attributes:@{
            NSFontAttributeName: font,
            NSForegroundColorAttributeName: color,
            NSParagraphStyleAttributeName: paragraph,
        }]];
    };

    if (manager.state == YTMULyricsFetchStateFetching && !manager.currentResult.hasText) {
        appendLine(YTMULyricsPageLocalized(@"LYRICS_STATE_SEARCHING", @"Searching lyrics..."), statusFont, secondary, mainParagraph);
        return output;
    }
    if (manager.state == YTMULyricsFetchStateError) {
        appendLine(manager.lastErrorMessage.length ? manager.lastErrorMessage : YTMULyricsPageLocalized(@"LYRICS_STATE_NO_LYRICS", @"No lyrics found"), statusFont, secondary, mainParagraph);
        return output;
    }

    YTMULyricsResult *result = manager.currentResult;
    NSArray<NSString *> *sourceLines = result.lineTexts ?: @[];
    if (!sourceLines.count && fallbackText.length) {
        sourceLines = [fallbackText componentsSeparatedByString:@"\n"];
    }
    if (!sourceLines.count) {
        appendLine(YTMULyricsPageLocalized(@"LYRICS_STATE_OPEN_SONG", @"Open a song to load lyrics."), statusFont, secondary, mainParagraph);
        return output;
    }

    NSArray<NSString *> *translations = manager.translatedLines ?: @[];
    NSString *convertMode = YTMULyricsPageString(@"lyricsConvertChinese", @"disabled");
    BOOL romanization = YTMULyricsPageBool(@"lyricsRomanization");
    BOOL showRomanization = romanization && YTMULyricsPageResultHasCompleteRomanization(result);
    BOOL showTimeCodes = YTMULyricsPageBool(@"lyricsShowTimeCodes");

    for (NSUInteger idx = 0; idx < sourceLines.count; idx++) {
        NSString *source = YTMULyricsPageLineText(sourceLines[idx]);
        source = [YTMULyricsTextProcessor convertChineseText:source mode:convertMode];
        if (showTimeCodes && idx < result.lines.count && result.lines[idx].time.length) {
            source = [NSString stringWithFormat:@"[%@] %@", result.lines[idx].time, source];
        }

        appendLine(source, mainFont, primary, mainParagraph);

        if (showRomanization) {
            NSString *roman = YTMULyricsPageRomanizedLineAtIndex(result, idx);
            BOOL same = [[YTMULyricsTextProcessor simplifyUnicode:roman] isEqualToString:[YTMULyricsTextProcessor simplifyUnicode:source]];
            if (roman.length && !same) appendLine(roman, romanFont, secondary, secondaryParagraph);
        }

        NSString *translated = idx < translations.count ? translations[idx] : @"";
        translated = [YTMULyricsTextProcessor convertChineseText:translated mode:convertMode];
        BOOL sameTranslation = [[YTMULyricsTextProcessor simplifyUnicode:translated] isEqualToString:[YTMULyricsTextProcessor simplifyUnicode:source]];
        if (translated.length && !sameTranslation) {
            appendLine(translated, translationFont, translationColor, pairEndParagraph);
        }
    }

    return output;
}

NSString *YTMULyricsPagePlainDisplayText(NSString *fallbackText) {
    YTMULyricsManager *manager = [YTMULyricsManager sharedManager];
    if (manager.state == YTMULyricsFetchStateFetching && !manager.currentResult.hasText) return YTMULyricsPageLocalized(@"LYRICS_STATE_SEARCHING", @"Searching lyrics...");
    if (manager.state == YTMULyricsFetchStateError) {
        return manager.lastErrorMessage.length ? manager.lastErrorMessage : (fallbackText.length ? fallbackText : YTMULyricsPageLocalized(@"LYRICS_STATE_NO_LYRICS", @"No lyrics found"));
    }

    YTMULyricsResult *result = manager.currentResult;
    NSArray<NSString *> *sourceLines = result.lineTexts ?: @[];
    if (!sourceLines.count && fallbackText.length) {
        sourceLines = [fallbackText componentsSeparatedByString:@"\n"];
    }
    if (!sourceLines.count) return fallbackText ?: @"";

    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    NSArray<NSString *> *translations = manager.translatedLines ?: @[];
    NSString *convertMode = YTMULyricsPageString(@"lyricsConvertChinese", @"disabled");
    BOOL romanization = YTMULyricsPageBool(@"lyricsRomanization");
    BOOL showRomanization = romanization && YTMULyricsPageResultHasCompleteRomanization(result);
    BOOL showTimeCodes = YTMULyricsPageBool(@"lyricsShowTimeCodes");

    for (NSUInteger idx = 0; idx < sourceLines.count; idx++) {
        NSString *source = YTMULyricsPageLineText(sourceLines[idx]);
        source = [YTMULyricsTextProcessor convertChineseText:source mode:convertMode];
        if (showTimeCodes && idx < result.lines.count && result.lines[idx].time.length) {
            source = [NSString stringWithFormat:@"[%@] %@", result.lines[idx].time, source];
        }
        if (source.length) [lines addObject:source];

        if (showRomanization) {
            NSString *roman = YTMULyricsPageRomanizedLineAtIndex(result, idx);
            BOOL same = [[YTMULyricsTextProcessor simplifyUnicode:roman] isEqualToString:[YTMULyricsTextProcessor simplifyUnicode:source]];
            if (roman.length && !same) [lines addObject:roman];
        }

        NSString *translated = idx < translations.count ? translations[idx] : @"";
        translated = [YTMULyricsTextProcessor convertChineseText:translated mode:convertMode];
        BOOL sameTranslation = [[YTMULyricsTextProcessor simplifyUnicode:translated] isEqualToString:[YTMULyricsTextProcessor simplifyUnicode:source]];
        if (translated.length && !sameTranslation) [lines addObject:translated];
    }

    return [lines componentsJoinedByString:@"\n"];
}

NSString *YTMULyricsPageAttributionText(void) {
    YTMULyricsManager *manager = [YTMULyricsManager sharedManager];
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    NSString *lyricsProvider = manager.currentResult.sourceName ?: @"";
    NSString *translationProvider = manager.translationAttribution.length ? manager.translationAttribution : YTMULyricsPageTranslationProviderTitle();
    if ([translationProvider hasSuffix:@" official"]) {
        translationProvider = [translationProvider substringToIndex:translationProvider.length - @" official".length];
    }
    BOOL sameProvider = lyricsProvider.length &&
                        translationProvider.length &&
                        [YTMULyricsCompactString(lyricsProvider) isEqualToString:YTMULyricsCompactString(translationProvider)];
    if (lyricsProvider.length && manager.translatedLines.count && sameProvider) {
        [parts addObject:[NSString stringWithFormat:YTMULyricsPageLocalized(@"LYRICS_ATTRIBUTION_BOTH_FORMAT", @"Lyrics and translation via %@"), lyricsProvider]];
        return [parts componentsJoinedByString:@" · "];
    }
    if (lyricsProvider.length) [parts addObject:[NSString stringWithFormat:YTMULyricsPageLocalized(@"LYRICS_ATTRIBUTION_LYRICS_FORMAT", @"Lyrics via %@"), lyricsProvider]];
    if (manager.translatedLines.count) {
        [parts addObject:[NSString stringWithFormat:YTMULyricsPageLocalized(@"LYRICS_ATTRIBUTION_TRANSLATION_FORMAT", @"Translated via %@"), translationProvider]];
    }
    return [parts componentsJoinedByString:@" · "];
}

id YTMULyricsPageFormattedString(NSString *text, id fallback) {
    if (!text.length) return fallback;
    Class formattedStringClass = NSClassFromString(@"YTIFormattedString");
    if ([formattedStringClass respondsToSelector:@selector(formattedStringWithString:)]) {
        id formatted = [formattedStringClass formattedStringWithString:text];
        if (formatted) return formatted;
    }
    return fallback;
}

void YTMULyricsPageLogRendererOverride(NSString *event, NSString *source, NSUInteger translatedCount) {
    if (!YTMULyricsDebugLoggingEnabled()) return;
    static NSString *lastSignature;
    NSString *signature = [NSString stringWithFormat:@"%@|%@|%lu", event ?: @"", source ?: @"", (unsigned long)translatedCount];
    @synchronized ([YTMULyricsManager class]) {
        if ([signature isEqualToString:lastSignature]) return;
        lastSignature = [signature copy];
    }
    YTMULyricsLog(@"official lyrics renderer override event=%@ source=%@ translated=%lu",
                  event ?: @"<unknown>",
                  source.length ? source : @"<none>",
                  (unsigned long)translatedCount);
}

NSString *YTMULyricsPageViewText(UIView *view) {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    NSString *accessibility = view.accessibilityLabel;
    if ([accessibility isKindOfClass:[NSString class]] && accessibility.length) [parts addObject:accessibility];
    if ([view isKindOfClass:[UIButton class]]) {
        NSString *title = [(UIButton *)view currentTitle];
        if (title.length) [parts addObject:title];
    }
    if ([view isKindOfClass:[UILabel class]]) {
        NSString *text = [(UILabel *)view text];
        if (text.length) [parts addObject:text];
    }
    return [[parts componentsJoinedByString:@" "] lowercaseString];
}

id YTMULyricsPageSafeValueForKey(id object, NSString *key) {
    return YTMUSafeValueForKey(object, key);
}


void YTMULyricsPageAppendStringValue(id value, NSMutableArray<NSString *> *parts) {
    if ([value isKindOfClass:[NSString class]] && [(NSString *)value length]) {
        [parts addObject:value];
    } else if ([value isKindOfClass:[NSAttributedString class]] && [(NSAttributedString *)value string].length) {
        [parts addObject:[(NSAttributedString *)value string]];
    }
}

void YTMULyricsPageAppendObjectText(id object, NSMutableArray<NSString *> *parts, NSUInteger depth) {
    if (!object || depth > 2) return;
    YTMULyricsPageAppendStringValue(object, parts);

    NSArray<NSString *> *textKeys = @[
        @"accessibilityLabel",
        @"accessibilityValue",
        @"accessibilityHint",
        @"text",
        @"attributedText",
        @"title",
        @"currentTitle",
        @"key"
    ];
    for (NSString *key in textKeys) {
        YTMULyricsPageAppendStringValue(YTMULyricsPageSafeValueForKey(object, key), parts);
    }

    NSArray<NSString *> *childKeys = @[
        @"_asyncdisplaykit_node",
        @"asyncdisplaykit_node",
        @"_node",
        @"node",
        @"_controller",
        @"controller",
        @"_element",
        @"element",
        @"_renderer",
        @"renderer"
    ];
    for (NSString *key in childKeys) {
        id child = YTMULyricsPageSafeValueForKey(object, key);
        if (child && child != object) YTMULyricsPageAppendObjectText(child, parts, depth + 1);
    }
}

UIView *YTMULyricsPageActionTargetForView(UIView *view) {
    UIView *candidate = view;
    for (NSUInteger depth = 0; candidate && depth < 4; depth++) {
        if ([candidate isKindOfClass:[UIControl class]]) return candidate;
        candidate = candidate.superview;
    }
    return view;
}

YTPlayerViewController *YTMULyricsPagePlayerFromCandidate(id candidate) {
    Class playerClass = NSClassFromString(@"YTPlayerViewController");
    if (playerClass && [candidate isKindOfClass:playerClass]) return candidate;

    id player = YTMULyricsPageSafeValueForKey(candidate, @"playerViewController");
    if (playerClass && [player isKindOfClass:playerClass]) return player;

    id parent = YTMULyricsPageSafeValueForKey(candidate, @"parentViewController");
    if (parent && parent != candidate) return YTMULyricsPagePlayerFromCandidate(parent);
    return nil;
}

void YTMULyricsPageHideOfficialActionsInView(UIView *view, UIView *replacementRoot) {
    if (!view || view == replacementRoot || [view isDescendantOfView:replacementRoot]) return;
    NSString *text = YTMULyricsPageViewText(view);
    BOOL looksLikeAction = [text containsString:@"share"] ||
                           [text containsString:@"translate"] ||
                           [text containsString:@"分享"] ||
                           [text containsString:@"翻译"] ||
                           [text containsString:@"共有"] ||
                           [text containsString:@"翻訳"];
    if (looksLikeAction) {
        UIView *target = YTMULyricsPageActionTargetForView(view);
        target.hidden = YES;
        target.alpha = 0.0;
        target.userInteractionEnabled = NO;
    }
    for (UIView *subview in view.subviews) {
        YTMULyricsPageHideOfficialActionsInView(subview, replacementRoot);
    }
}

NSString *YTMULyricsPageAccessibilityText(UIView *view) {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    NSString *label = view.accessibilityLabel;
    NSString *value = view.accessibilityValue;
    NSString *hint = view.accessibilityHint;
    if ([label isKindOfClass:[NSString class]] && label.length) [parts addObject:label];
    if ([value isKindOfClass:[NSString class]] && value.length) [parts addObject:value];
    if ([hint isKindOfClass:[NSString class]] && hint.length) [parts addObject:hint];
    NSString *viewText = YTMULyricsPageViewText(view);
    if (viewText.length) [parts addObject:viewText];
    YTMULyricsPageAppendObjectText(YTMULyricsPageSafeValueForKey(view, @"_asyncdisplaykit_node"), parts, 0);
    YTMULyricsPageAppendObjectText(YTMULyricsPageSafeValueForKey(view, @"_element"), parts, 0);
    return [[parts componentsJoinedByString:@" "] lowercaseString];
}

NSString *YTMULyricsPageRecursiveAccessibilityText(UIView *view, NSUInteger depth) {
    if (!view || view.hidden || view.alpha <= 0.03 || depth > 3) return @"";
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    NSString *own = YTMULyricsPageAccessibilityText(view);
    if (own.length) [parts addObject:own];
    for (UIView *subview in view.subviews) {
        NSString *text = YTMULyricsPageRecursiveAccessibilityText(subview, depth + 1);
        if (text.length) [parts addObject:text];
    }
    return [parts componentsJoinedByString:@" "];
}

// Returns YES if `value` (lowercase) contains any known native word for
// "lyrics". Two things to know about how this is used:
//
//   1. The text we match against is collected from accessibilityLabel /
//      accessibilityValue / accessibilityHint AND from YT Music's
//      internal `_asyncdisplaykit_node` / `_element` graph. The element
//      graph carries the English internal identifier "Lyrics"
//      regardless of UI language — so for ~all locales the English
//      `lyrics` token below is the one that fires, not the localized
//      tokens.
//   2. The localized tokens are kept only as a defensive fallback for
//      views where the element graph isn't exposed (e.g. some player
//      tab bar items). We list the top ~25 YT Music UI languages here
//      explicitly; anything else is handled by the English token
//      hitting the internal element identifier.
//
// `containsString:` substring matching is intentional — we mostly see
// these tokens inside longer accessibility strings ("Lyrics tab" /
// "showing Lyrics" / "Letra de la canción"). The tabSized geometry
// filter at the call site is what prevents false positives.
BOOL YTMULyricsPageHasLyricsTokenInLowercased(NSString *lowered) {
    if (!lowered.length) return NO;
    static NSArray<NSString *> *tokens = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        tokens = @[
            @"lyrics",          // en + internal element identifier
            @"letra",           // es, pt
            @"paroles",         // fr
            @"songtext",        // de
            @"testo",           // it
            @"songtekst",       // nl
            @"tekst piosenki",  // pl
            @"текст",           // ru, uk, bg, sr (cyrillic)
            @"sözler",          // tr
            @"كلمات",           // ar
            @"מילים",            // he
            @"متن",             // fa
            @"बोल",             // hi
            @"lirik",           // id, ms
            @"lời",             // vi
            @"เนื้อเพลง",         // th
            @"歌词",            // zh-Hans
            @"歌詞",            // zh-Hant, ja
            @"가사",            // ko
            @"sångtext",        // sv
            @"sangtekst",       // no, da
            @"sanat",           // fi
            @"versuri",         // ro
            @"szöveg",          // hu
            @"στίχοι",          // el
        ];
    });
    for (NSString *t in tokens) {
        if ([lowered containsString:t]) return YES;
    }
    return NO;
}

BOOL YTMULyricsPageTextHasLyricsToken(NSString *text) {
    NSString *value = [[text ?: @"" stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
    return YTMULyricsPageHasLyricsTokenInLowercased(value);
}

BOOL YTMULyricsPageViewIsSelected(UIView *view) {
    // YT Music marks the active tab via the standard
    // UIAccessibilityTraitSelected — locale-independent and stable
    // across iOS versions. Previous code also fuzzy-matched visible
    // "selected" / "已选择" / "已選取" / "選択中" strings as a defensive
    // backup, but those only covered four languages out of YT Music's
    // 40+ UI locales; dropped in favor of the standard trait alone.
    return (view.accessibilityTraits & UIAccessibilityTraitSelected) == UIAccessibilityTraitSelected;
}

void YTMULyricsPageCollectTabSelection(UIView *view,
                                              UIView *root,
                                              BOOL *lyricsSelected,
                                              CGFloat *tabBarTop,
                                              NSUInteger depth) {
    if (!view || view.hidden || view.alpha <= 0.03 || depth > 18) return;

    NSString *text = YTMULyricsPageRecursiveAccessibilityText(view, 0);
    BOOL hasLyrics = YTMULyricsPageTextHasLyricsToken(text);
    BOOL selected = YTMULyricsPageViewIsSelected(view);
    CGRect frame = [view convertRect:view.bounds toView:root];
    BOOL tabSized = frame.size.width >= 40.0 &&
                    frame.size.width <= root.bounds.size.width &&
                    frame.size.height >= 20.0 &&
                    frame.size.height <= 72.0 &&
                    CGRectGetMidY(frame) >= root.bounds.size.height * 0.45;

    // Only the Lyrics tab is identified explicitly. The previous code
    // also fuzzy-matched "queue / up next / related / 播放队列 / 関連"
    // to track "an other tab is selected" and gated the overlay on
    // `lyricsSelected && !otherSelected`. That defensive double-check
    // bought nothing — UIAccessibilityTraitSelected only fires on the
    // active tab — and the localized non-lyrics token list was the
    // most brittle piece of the chip detection (covered four
    // languages, broke for the other forty). Dropped.
    if (tabSized && hasLyrics) {
        *tabBarTop = MIN(*tabBarTop, CGRectGetMinY(frame));
        if (selected) *lyricsSelected = YES;
    }

    for (UIView *subview in view.subviews) {
        YTMULyricsPageCollectTabSelection(subview, root, lyricsSelected, tabBarTop, depth + 1);
    }
}

void YTMULyricsPageTabState(UIView *root, BOOL *selected, CGFloat *bottom) {
    BOOL lyricsSelected = NO;
    CGFloat tabTop = CGFLOAT_MAX;
    YTMULyricsPageCollectTabSelection(root, root, &lyricsSelected, &tabTop, 0);
    if (selected) *selected = lyricsSelected;
    if (bottom) {
        *bottom = tabTop == CGFLOAT_MAX ? MAX(0.0, root.bounds.size.height - 72.0) : MAX(0.0, tabTop - 6.0);
    }
}
