#import "YTMULyricsPanelSupport.h"
#import "../Utils/YTMUKVC.h"
#import "../Utils/YTMUSettings.h"
#import <MediaPlayer/MediaPlayer.h>
#import <objc/runtime.h>
#import "../Headers/Localization.h"
#import "../Headers/YTIFormattedString.h"
#import "YTMULyricsManager.h"
#import "YTMULyricsPlaybackState.h"
#import "YTMUSyncedLyricsView.h"
#import "YTMULyricsTextProcessor.h"
#import "../Translation/YTMUTranslationTypes.h"

// Text rendering for the lyrics panel: romanization rows, line text,
// attributed lyrics, attribution. Declared in YTMULyricsPanelSupport.h.

NSString *YTMULyricsPageRomanizationLanguageForResult(YTMULyricsResult *result) {
    for (NSString *line in result.lineTexts ?: @[]) {
        if ([YTMULyricsTextProcessor hasJapaneseKana:line ?: @""]) return @"ja";
    }
    return @"auto";
}

// YES when at least one line that needs romanization has it. Lines the
// transliteration endpoint skipped simply render without a romaji row —
// the manager caches partial batches on purpose (a single empty answer
// used to hide the romanization of the whole song).
BOOL YTMULyricsPageResultHasAnyRomanization(YTMULyricsResult *result) {
    NSArray<NSString *> *sourceLines = result.lineTexts ?: @[];
    if (!sourceLines.count) return NO;

    NSString *sourceLanguage = YTMULyricsPageRomanizationLanguageForResult(result);
    for (NSUInteger idx = 0; idx < sourceLines.count; idx++) {
        NSString *text = [sourceLines[idx] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (![YTMULyricsTextProcessor needsRomanizationForText:text preferredLanguage:sourceLanguage]) continue;
        NSString *roman = YTMULyricsPageRomanizedLineAtIndex(result, idx);
        if ([roman stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].length) return YES;
    }
    return NO;
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
    BOOL showRomanization = romanization && YTMULyricsPageResultHasAnyRomanization(result);
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
    BOOL showRomanization = romanization && YTMULyricsPageResultHasAnyRomanization(result);
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
