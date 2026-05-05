#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "Headers/YTPlayerViewController.h"
#import "Headers/YTIFormattedString.h"
#import "Lyrics/YTMULyricsManager.h"
#import "Lyrics/YTMULyricsPlaybackState.h"
#import "Lyrics/YTMUSyncedLyricsView.h"
#import "Lyrics/YTMULyricsTextProcessor.h"
#import "Translation/YTMUTranslationContext.h"
#import "Translation/YTMUTranslationTypes.h"

static NSDictionary *YTMULyricsPageSettings(void) {
    return [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"YTMUltimate"] ?: @{};
}

static BOOL YTMULyricsPageBool(NSString *key) {
    return [YTMULyricsPageSettings()[key] boolValue];
}

static NSString *YTMULyricsPageString(NSString *key, NSString *fallback) {
    id value = YTMULyricsPageSettings()[key];
    if ([value isKindOfClass:[NSString class]] && [(NSString *)value length]) return value;
    return fallback ?: @"";
}

static BOOL YTMULyricsPageCustomSourceEnabled(void);

static BOOL YTMULyricsPageReplacementEnabled(void) {
    return YTMULyricsPageCustomSourceEnabled();
}

static BOOL YTMULyricsPageCustomSourceEnabled(void) {
    NSDictionary *settings = YTMULyricsPageSettings();
    return [settings[@"YTMUltimateIsEnabled"] boolValue] &&
           ([settings[@"syncedLyricsEnabled"] boolValue] ||
            [settings[@"lyricsTranslationEnabled"] boolValue] ||
            [settings[@"bilingualLyrics"] boolValue]);
}

static void YTMULyricsPageSetSetting(NSString *key, id value) {
    if (!key.length) return;
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSMutableDictionary *settings = [NSMutableDictionary dictionaryWithDictionary:[defaults dictionaryForKey:@"YTMUltimate"] ?: @{}];
    settings[key] = value ?: @"";
    [defaults setObject:settings forKey:@"YTMUltimate"];
    [defaults synchronize];
    [[NSNotificationCenter defaultCenter] postNotificationName:YTMULyricsSettingsDidChangeNotification
                                                        object:nil
                                                      userInfo:@{YTMULyricsSettingChangedKey: key}];
}

static NSArray<NSDictionary *> *YTMULyricsPageSourceOptions(void) {
    static NSArray<NSDictionary *> *options;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        options = @[
            @{@"key": @"auto", @"title": @"Auto"},
            @{@"key": YTMULyricsSourceYTMusic, @"title": @"YTMusic"},
            @{@"key": YTMULyricsSourceLRCLib, @"title": @"LRCLib"},
            @{@"key": YTMULyricsSourceNetEase, @"title": @"NetEase"},
            @{@"key": YTMULyricsSourceMusixMatch, @"title": @"MusixMatch"},
            @{@"key": YTMULyricsSourceGenius, @"title": @"Genius"},
        ];
    });
    return options;
}

static NSString *YTMULyricsPageSourceTitle(NSString *key) {
    for (NSDictionary *option in YTMULyricsPageSourceOptions()) {
        if ([option[@"key"] isEqualToString:key]) return option[@"title"];
    }
    return key.length ? key : @"Auto";
}

static NSUInteger YTMULyricsPageSourceIndex(NSString *key) {
    NSArray *options = YTMULyricsPageSourceOptions();
    for (NSUInteger idx = 0; idx < options.count; idx++) {
        if ([options[idx][@"key"] isEqualToString:key]) return idx;
    }
    return 0;
}

static NSString *YTMULyricsPageTranslationProviderTitle(void) {
    NSString *provider = YTMULyricsPageString(@"translationProvider", YTMUTranslationProviderGoogle);
    if ([provider isEqualToString:YTMUTranslationProviderGoogle]) return @"Google Translate";
    if ([provider isEqualToString:YTMUTranslationProviderAnthropic]) return @"Anthropic";
    if ([provider isEqualToString:YTMUTranslationProviderGemini]) return @"Gemini";
    if ([provider isEqualToString:YTMUTranslationProviderOpenAI]) return @"OpenAI-compatible";
    return provider.length ? provider : @"translator";
}

static CGFloat YTMULyricsPageClampFontSize(CGFloat size) {
    return MIN(38.0, MAX(16.0, size));
}

static CGFloat YTMULyricsPageBaseFontSize(void) {
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

static void YTMULyricsPageSetBaseFontSize(CGFloat size) {
    YTMULyricsPageSetSetting(@"lyricsFontPointSize", @(llround(YTMULyricsPageClampFontSize(size))));
}

static BOOL YTMULyricsPageResultHasCompleteRomanization(YTMULyricsResult *result) {
    NSArray<NSString *> *sourceLines = result.lineTexts ?: @[];
    if (!sourceLines.count) return NO;

    BOOL needsRomanization = NO;
    for (NSUInteger idx = 0; idx < sourceLines.count; idx++) {
        NSString *text = [sourceLines[idx] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (![YTMULyricsTextProcessor hasRomanizableText:text]) continue;
        needsRomanization = YES;
        NSString *roman = idx < result.romanizedLineTexts.count ? result.romanizedLineTexts[idx] : @"";
        if (![roman stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].length) {
            return NO;
        }
    }
    return needsRomanization;
}

static NSString *YTMULyricsPageRomanizedLineAtIndex(YTMULyricsResult *result, NSUInteger idx) {
    if (idx < result.romanizedLineTexts.count) return result.romanizedLineTexts[idx] ?: @"";
    if (idx < result.lines.count) return result.lines[idx].romanizedText ?: @"";
    return @"";
}

static NSString *YTMULyricsPageLineText(NSString *text) {
    NSString *value = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (value.length) return value;
    NSString *mode = YTMULyricsPageString(@"lyricsDefaultText", @"♪");
    if ([mode isEqualToString:@"dots"]) return @"...";
    if ([mode isEqualToString:@"bullets"]) return @"•••";
    if ([mode isEqualToString:@"dash"]) return @"---";
    if ([mode isEqualToString:@"space"]) return @" ";
    return @"♪";
}

static UIColor *YTMULyricsPageSecondaryTextColor(void) {
    if (@available(iOS 13.0, *)) return [UIColor secondaryLabelColor];
    return [[UIColor whiteColor] colorWithAlphaComponent:0.58];
}

static NSAttributedString *YTMULyricsPageAttributedText(UITextView *textView, NSString *fallbackText) {
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

    if (manager.state == YTMULyricsFetchStateFetching) {
        appendLine(@"Searching lyrics...", statusFont, secondary, mainParagraph);
        return output;
    }
    if (manager.state == YTMULyricsFetchStateError) {
        appendLine(manager.lastErrorMessage.length ? manager.lastErrorMessage : @"No lyrics found", statusFont, secondary, mainParagraph);
        return output;
    }

    YTMULyricsResult *result = manager.currentResult;
    NSArray<NSString *> *sourceLines = result.lineTexts ?: @[];
    if (!sourceLines.count && fallbackText.length) {
        sourceLines = [fallbackText componentsSeparatedByString:@"\n"];
    }
    if (!sourceLines.count) {
        appendLine(@"Open a song to load lyrics.", statusFont, secondary, mainParagraph);
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

static NSString *YTMULyricsPagePlainDisplayText(NSString *fallbackText) {
    YTMULyricsManager *manager = [YTMULyricsManager sharedManager];
    if (manager.state == YTMULyricsFetchStateFetching) return @"Searching lyrics...";
    if (manager.state == YTMULyricsFetchStateError) {
        return manager.lastErrorMessage.length ? manager.lastErrorMessage : (fallbackText.length ? fallbackText : @"No lyrics found");
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

static NSString *YTMULyricsPageAttributionText(void) {
    YTMULyricsManager *manager = [YTMULyricsManager sharedManager];
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    if (manager.currentResult.sourceName.length) {
        [parts addObject:[NSString stringWithFormat:@"Lyrics via %@", manager.currentResult.sourceName]];
    }
    if (manager.translatedLines.count) {
        NSString *provider = manager.translationAttribution.length ? manager.translationAttribution : YTMULyricsPageTranslationProviderTitle();
        [parts addObject:[NSString stringWithFormat:@"Translated via %@", provider]];
    }
    return [parts componentsJoinedByString:@" · "];
}

static id YTMULyricsPageFormattedString(NSString *text, id fallback) {
    if (!text.length) return fallback;
    Class formattedStringClass = NSClassFromString(@"YTIFormattedString");
    if ([formattedStringClass respondsToSelector:@selector(formattedStringWithString:)]) {
        id formatted = [formattedStringClass formattedStringWithString:text];
        if (formatted) return formatted;
    }
    return fallback;
}

static void YTMULyricsPageLogRendererOverride(NSString *event, NSString *source, NSUInteger translatedCount) {
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

static NSString *YTMULyricsPageViewText(UIView *view) {
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

static id YTMULyricsPageSafeValueForKey(id object, NSString *key) {
    if (!object || !key.length) return nil;
    @try {
        return [object valueForKey:key];
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static UIView *YTMULyricsPageActionTargetForView(UIView *view) {
    UIView *candidate = view;
    for (NSUInteger depth = 0; candidate && depth < 4; depth++) {
        if ([candidate isKindOfClass:[UIControl class]]) return candidate;
        candidate = candidate.superview;
    }
    return view;
}

static YTPlayerViewController *YTMULyricsPagePlayerFromCandidate(id candidate) {
    Class playerClass = NSClassFromString(@"YTPlayerViewController");
    if (playerClass && [candidate isKindOfClass:playerClass]) return candidate;

    id player = YTMULyricsPageSafeValueForKey(candidate, @"playerViewController");
    if (playerClass && [player isKindOfClass:playerClass]) return player;

    id parent = YTMULyricsPageSafeValueForKey(candidate, @"parentViewController");
    if (parent && parent != candidate) return YTMULyricsPagePlayerFromCandidate(parent);
    return nil;
}

static void YTMULyricsPageHideOfficialActionsInView(UIView *view, UIView *replacementRoot) {
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

static NSString *YTMULyricsPageAccessibilityText(UIView *view) {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    NSString *label = view.accessibilityLabel;
    NSString *value = view.accessibilityValue;
    NSString *hint = view.accessibilityHint;
    if ([label isKindOfClass:[NSString class]] && label.length) [parts addObject:label];
    if ([value isKindOfClass:[NSString class]] && value.length) [parts addObject:value];
    if ([hint isKindOfClass:[NSString class]] && hint.length) [parts addObject:hint];
    NSString *viewText = YTMULyricsPageViewText(view);
    if (viewText.length) [parts addObject:viewText];
    return [[parts componentsJoinedByString:@" "] lowercaseString];
}

static NSString *YTMULyricsPageRecursiveAccessibilityText(UIView *view, NSUInteger depth) {
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

static BOOL YTMULyricsPageTextHasLyricsToken(NSString *text) {
    NSString *value = [[text ?: @"" stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
    return [value containsString:@"lyrics"] ||
           [value containsString:@"歌词"] ||
           [value containsString:@"歌詞"];
}

static BOOL YTMULyricsPageTextHasOtherPlayerTabToken(NSString *text) {
    NSString *value = [text ?: @"" lowercaseString];
    return [value containsString:@"queue"] ||
           [value containsString:@"up next"] ||
           [value containsString:@"related"] ||
           [value containsString:@"next up"] ||
           [value containsString:@"播放队列"] ||
           [value containsString:@"播放佇列"] ||
           [value containsString:@"関連"];
}

static BOOL YTMULyricsPageViewIsSelected(UIView *view) {
    if ((view.accessibilityTraits & UIAccessibilityTraitSelected) == UIAccessibilityTraitSelected) return YES;
    NSString *text = YTMULyricsPageAccessibilityText(view);
    return [text containsString:@"selected"] ||
           [text containsString:@"已选择"] ||
           [text containsString:@"已選取"] ||
           [text containsString:@"選択中"];
}

static void YTMULyricsPageCollectTabSelection(UIView *view,
                                              UIView *root,
                                              BOOL *lyricsSelected,
                                              BOOL *otherSelected,
                                              CGFloat *tabBarTop,
                                              NSUInteger depth) {
    if (!view || view.hidden || view.alpha <= 0.03 || depth > 18) return;

    NSString *text = YTMULyricsPageRecursiveAccessibilityText(view, 0);
    BOOL hasLyrics = YTMULyricsPageTextHasLyricsToken(text);
    BOOL hasOther = YTMULyricsPageTextHasOtherPlayerTabToken(text);
    BOOL selected = YTMULyricsPageViewIsSelected(view);
    CGRect frame = [view convertRect:view.bounds toView:root];
    BOOL tabSized = frame.size.width >= 40.0 &&
                    frame.size.width <= root.bounds.size.width &&
                    frame.size.height >= 20.0 &&
                    frame.size.height <= 72.0 &&
                    CGRectGetMidY(frame) >= root.bounds.size.height * 0.45;

    if (tabSized && (hasLyrics || hasOther)) {
        *tabBarTop = MIN(*tabBarTop, CGRectGetMinY(frame));
        if (selected && hasLyrics) *lyricsSelected = YES;
        if (selected && hasOther) *otherSelected = YES;
    }

    for (UIView *subview in view.subviews) {
        YTMULyricsPageCollectTabSelection(subview, root, lyricsSelected, otherSelected, tabBarTop, depth + 1);
    }
}

static CGFloat YTMULyricsPageTabContentBottom(UIView *root) {
    BOOL lyricsSelected = NO;
    BOOL otherSelected = NO;
    CGFloat tabTop = CGFLOAT_MAX;
    YTMULyricsPageCollectTabSelection(root, root, &lyricsSelected, &otherSelected, &tabTop, 0);
    if (tabTop == CGFLOAT_MAX) return MAX(0.0, root.bounds.size.height - 72.0);
    return MAX(0.0, tabTop - 6.0);
}

static BOOL YTMULyricsPageOfficialLyricsTabSelected(UIView *root) {
    BOOL lyricsSelected = NO;
    BOOL otherSelected = NO;
    CGFloat tabTop = CGFLOAT_MAX;
    YTMULyricsPageCollectTabSelection(root, root, &lyricsSelected, &otherSelected, &tabTop, 0);
    return lyricsSelected && !otherSelected;
}

@interface YTMULyricsTabOverlayView : UIView
@property (retain, nonatomic) UIScrollView *sourceScrollView;
@property (retain, nonatomic) NSArray *sourceButtons;
@property (retain, nonatomic) UITextView *lyricsTextView;
@property (retain, nonatomic) YTMUSyncedLyricsView *syncedLyricsView;
@property (retain, nonatomic) UILabel *attributionLabel;
@property (retain, nonatomic) UIButton *fontDecreaseButton;
@property (retain, nonatomic) UIButton *fontIncreaseButton;
@property (retain, nonatomic) UILabel *fontSizeLabel;
@property (copy, nonatomic) NSString *lastRenderSignature;
@property (assign, nonatomic) YTPlayerViewController *playerViewController;
- (void)ytmu_renderTabOverlay;
- (void)ytmu_layoutSourceButtons;
- (void)ytmu_updateSourceButtons;
- (void)ytmu_updateFontControls;
- (void)ytmu_scrollSourceButtonIntoView:(UIButton *)button animated:(BOOL)animated;
- (void)ytmu_selectLyricsSource:(UIButton *)sender;
- (void)ytmu_cycleLyricsSource:(UISwipeGestureRecognizer *)gesture;
- (void)ytmu_adjustLyricsFontSize:(UIButton *)sender;
@end

@implementation YTMULyricsTabOverlayView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.clipsToBounds = YES;
        self.userInteractionEnabled = YES;
        self.backgroundColor = [UIColor colorWithRed:0.035 green:0.095 blue:0.135 alpha:0.99];

        self.sourceScrollView = [[UIScrollView alloc] initWithFrame:CGRectZero];
        self.sourceScrollView.backgroundColor = [UIColor clearColor];
        self.sourceScrollView.showsHorizontalScrollIndicator = NO;
        self.sourceScrollView.alwaysBounceHorizontal = YES;
        [self addSubview:self.sourceScrollView];

        NSMutableArray<UIButton *> *buttons = [NSMutableArray array];
        NSArray *options = YTMULyricsPageSourceOptions();
        for (NSUInteger idx = 0; idx < options.count; idx++) {
            UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
            button.tag = idx;
            [button setTitle:options[idx][@"title"] forState:UIControlStateNormal];
            button.titleLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightSemibold];
            button.contentEdgeInsets = UIEdgeInsetsMake(6, 13, 6, 13);
            button.layer.cornerRadius = 15.0;
            button.clipsToBounds = YES;
            [button addTarget:self action:@selector(ytmu_selectLyricsSource:) forControlEvents:UIControlEventTouchUpInside];
            [self.sourceScrollView addSubview:button];
            [buttons addObject:button];
        }
        self.sourceButtons = buttons;

        self.fontDecreaseButton = [UIButton buttonWithType:UIButtonTypeSystem];
        self.fontDecreaseButton.tag = -1;
        [self.fontDecreaseButton setTitle:@"A-" forState:UIControlStateNormal];
        [self.fontDecreaseButton addTarget:self action:@selector(ytmu_adjustLyricsFontSize:) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:self.fontDecreaseButton];

        self.fontSizeLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        self.fontSizeLabel.textAlignment = NSTextAlignmentCenter;
        self.fontSizeLabel.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightSemibold];
        self.fontSizeLabel.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.72];
        [self addSubview:self.fontSizeLabel];

        self.fontIncreaseButton = [UIButton buttonWithType:UIButtonTypeSystem];
        self.fontIncreaseButton.tag = 1;
        [self.fontIncreaseButton setTitle:@"A+" forState:UIControlStateNormal];
        [self.fontIncreaseButton addTarget:self action:@selector(ytmu_adjustLyricsFontSize:) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:self.fontIncreaseButton];

        for (UIButton *button in @[self.fontDecreaseButton, self.fontIncreaseButton]) {
            button.titleLabel.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightBold];
            [button setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
            button.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.12];
            button.layer.cornerRadius = 15.0;
            button.clipsToBounds = YES;
        }

        self.lyricsTextView = [[UITextView alloc] initWithFrame:CGRectZero];
        self.lyricsTextView.backgroundColor = [UIColor clearColor];
        self.lyricsTextView.editable = NO;
        self.lyricsTextView.selectable = YES;
        self.lyricsTextView.scrollEnabled = YES;
        self.lyricsTextView.showsVerticalScrollIndicator = NO;
        self.lyricsTextView.textContainerInset = UIEdgeInsetsZero;
        self.lyricsTextView.textContainer.lineFragmentPadding = 0;
        self.lyricsTextView.textColor = [UIColor whiteColor];
        [self addSubview:self.lyricsTextView];

        self.syncedLyricsView = [[YTMUSyncedLyricsView alloc] initWithFrame:CGRectZero];
        self.syncedLyricsView.backgroundColor = [UIColor clearColor];
        self.syncedLyricsView.hidden = YES;
        [self addSubview:self.syncedLyricsView];

        UISwipeGestureRecognizer *left = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(ytmu_cycleLyricsSource:)];
        left.direction = UISwipeGestureRecognizerDirectionLeft;
        [self.lyricsTextView addGestureRecognizer:left];
        UISwipeGestureRecognizer *right = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(ytmu_cycleLyricsSource:)];
        right.direction = UISwipeGestureRecognizerDirectionRight;
        [self.lyricsTextView addGestureRecognizer:right];

        self.attributionLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        self.attributionLabel.backgroundColor = [UIColor clearColor];
        self.attributionLabel.font = [UIFont systemFontOfSize:10.5 weight:UIFontWeightMedium];
        self.attributionLabel.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.58];
        self.attributionLabel.numberOfLines = 2;
        self.attributionLabel.adjustsFontSizeToFitWidth = YES;
        self.attributionLabel.minimumScaleFactor = 0.82;
        [self addSubview:self.attributionLabel];

        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(ytmu_renderTabOverlay)
                                                     name:YTMULyricsDidUpdateNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(ytmu_renderTabOverlay)
                                                     name:YTMULyricsSettingsDidChangeNotification
                                                   object:nil];
        [self ytmu_updateSourceButtons];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat sideInset = MAX(20.0, MIN(34.0, self.bounds.size.width * 0.065));
    CGFloat topInset = 14.0;
    CGFloat bottomInset = 12.0;
    if (@available(iOS 11.0, *)) bottomInset += self.safeAreaInsets.bottom;
    CGFloat attributionHeight = self.attributionLabel.text.length ? 30.0 : 0.0;
    CGFloat controlWidth = 110.0;
    CGFloat controlX = MAX(sideInset, self.bounds.size.width - sideInset - controlWidth);
    self.fontDecreaseButton.frame = CGRectMake(controlX, topInset + 2.0, 30.0, 30.0);
    self.fontSizeLabel.frame = CGRectMake(CGRectGetMaxX(self.fontDecreaseButton.frame) + 4.0, topInset + 2.0, 38.0, 30.0);
    self.fontIncreaseButton.frame = CGRectMake(CGRectGetMaxX(self.fontSizeLabel.frame) + 4.0, topInset + 2.0, 30.0, 30.0);
    CGFloat sourceWidth = MAX(96.0, controlX - sideInset - 10.0);
    self.sourceScrollView.frame = CGRectMake(sideInset, topInset, sourceWidth, 34.0);
    CGFloat textY = CGRectGetMaxY(self.sourceScrollView.frame) + 12.0;
    CGFloat attributionY = self.bounds.size.height - bottomInset - attributionHeight;
    self.lyricsTextView.frame = CGRectMake(sideInset,
                                           textY,
                                           self.bounds.size.width - sideInset * 2.0,
                                           MAX(80.0, attributionY - textY - 10.0));
    self.syncedLyricsView.frame = self.lyricsTextView.frame;
    self.attributionLabel.frame = CGRectMake(sideInset, attributionY, self.bounds.size.width - sideInset * 2.0, attributionHeight);
    [self ytmu_layoutSourceButtons];
}

- (void)ytmu_renderTabOverlay {
    if (!YTMULyricsPageReplacementEnabled()) {
        self.hidden = YES;
        return;
    }

    YTMULyricsManager *manager = [YTMULyricsManager sharedManager];
    BOOL useSynced = manager.currentResult.isSynced && manager.state == YTMULyricsFetchStateDone;
    self.lyricsTextView.hidden = useSynced;
    self.syncedLyricsView.hidden = !useSynced;
    self.syncedLyricsView.playerViewController = self.playerViewController;
    if (!self.syncedLyricsView.playerViewController) {
        self.syncedLyricsView.playerViewController = [YTMULyricsPlaybackState sharedState].playerViewController;
    }
    if (useSynced) {
        [self.syncedLyricsView reloadFromManager];
    } else {
        self.lyricsTextView.attributedText = YTMULyricsPageAttributedText(self.lyricsTextView, @"");
    }
    self.attributionLabel.text = YTMULyricsPageAttributionText();
    [self ytmu_updateSourceButtons];
    [self ytmu_updateFontControls];
    [self setNeedsLayout];

    NSString *signature = [NSString stringWithFormat:@"%ld|%@|%lu|%lu|%@|%.0f",
                           (long)manager.state,
                           manager.currentResult.sourceName ?: @"<none>",
                           (unsigned long)manager.displayLineTexts.count,
                           (unsigned long)manager.translatedLines.count,
                           YTMULyricsPageString(@"lyricsPreferredSource", @"auto"),
                           YTMULyricsPageBaseFontSize()];
    if (![signature isEqualToString:self.lastRenderSignature]) {
        self.lastRenderSignature = signature;
        YTMULyricsLog(@"lyrics tab overlay rendered state=%ld source=%@ lines=%lu translated=%lu",
                      (long)manager.state,
                      manager.currentResult.sourceName ?: @"<none>",
                      (unsigned long)manager.displayLineTexts.count,
                      (unsigned long)manager.translatedLines.count);
    }
}

- (void)ytmu_updateFontControls {
    CGFloat size = YTMULyricsPageBaseFontSize();
    self.fontSizeLabel.text = [NSString stringWithFormat:@"%.0f", size];
    self.fontDecreaseButton.enabled = size > 16.0;
    self.fontIncreaseButton.enabled = size < 38.0;
    self.fontDecreaseButton.alpha = self.fontDecreaseButton.enabled ? 1.0 : 0.38;
    self.fontIncreaseButton.alpha = self.fontIncreaseButton.enabled ? 1.0 : 0.38;
}

- (void)ytmu_layoutSourceButtons {
    CGFloat x = 0.0;
    for (UIButton *button in self.sourceButtons) {
        [button sizeToFit];
        CGFloat width = MAX(64.0, button.bounds.size.width + 22.0);
        button.frame = CGRectMake(x, 2.0, width, 30.0);
        x += width + 8.0;
    }
    self.sourceScrollView.contentSize = CGSizeMake(MAX(x, self.sourceScrollView.bounds.size.width + 1.0), self.sourceScrollView.bounds.size.height);
}

- (void)ytmu_updateSourceButtons {
    NSString *selected = YTMULyricsPageString(@"lyricsPreferredSource", @"auto");
    NSArray *options = YTMULyricsPageSourceOptions();
    for (UIButton *button in self.sourceButtons) {
        NSString *key = button.tag < options.count ? options[button.tag][@"key"] : @"";
        BOOL active = [key isEqualToString:selected];
        UIColor *titleColor = active ? [UIColor whiteColor] : [[UIColor whiteColor] colorWithAlphaComponent:0.66];
        UIColor *background = active ? [[UIColor whiteColor] colorWithAlphaComponent:0.22] : [[UIColor whiteColor] colorWithAlphaComponent:0.10];
        [button setTitleColor:titleColor forState:UIControlStateNormal];
        button.backgroundColor = background;
    }
}

- (void)ytmu_scrollSourceButtonIntoView:(UIButton *)button animated:(BOOL)animated {
    if (!button || !self.sourceScrollView) return;
    [self.sourceScrollView scrollRectToVisible:CGRectInset(button.frame, -18.0, 0.0) animated:animated];
}

- (void)ytmu_selectLyricsSource:(UIButton *)sender {
    NSArray *options = YTMULyricsPageSourceOptions();
    if (sender.tag >= options.count) return;
    NSString *key = options[sender.tag][@"key"];
    YTMULyricsPageSetSetting(@"lyricsPreferredSource", key);
    [self ytmu_updateSourceButtons];
    [self ytmu_scrollSourceButtonIntoView:sender animated:YES];
    YTMULyricsLog(@"lyrics tab source selected=%@", YTMULyricsPageSourceTitle(key));
}

- (void)ytmu_cycleLyricsSource:(UISwipeGestureRecognizer *)gesture {
    NSArray *options = YTMULyricsPageSourceOptions();
    if (!options.count) return;
    NSString *selected = YTMULyricsPageString(@"lyricsPreferredSource", @"auto");
    NSInteger index = (NSInteger)YTMULyricsPageSourceIndex(selected);
    if (gesture.direction == UISwipeGestureRecognizerDirectionLeft) {
        index = (index + 1) % (NSInteger)options.count;
    } else if (gesture.direction == UISwipeGestureRecognizerDirectionRight) {
        index = (index - 1 + (NSInteger)options.count) % (NSInteger)options.count;
    }
    NSString *key = options[(NSUInteger)index][@"key"];
    YTMULyricsPageSetSetting(@"lyricsPreferredSource", key);
    [self ytmu_updateSourceButtons];
    [self ytmu_layoutSourceButtons];
    if ((NSUInteger)index < self.sourceButtons.count) {
        [self ytmu_scrollSourceButtonIntoView:self.sourceButtons[(NSUInteger)index] animated:YES];
    }
    YTMULyricsLog(@"lyrics tab source swiped=%@", YTMULyricsPageSourceTitle(key));
}

- (void)ytmu_adjustLyricsFontSize:(UIButton *)sender {
    CGFloat next = YTMULyricsPageBaseFontSize() + (sender.tag < 0 ? -2.0 : 2.0);
    YTMULyricsPageSetBaseFontSize(next);
    [self ytmu_updateFontControls];
    [self ytmu_renderTabOverlay];
    YTMULyricsLog(@"lyrics page font size=%.0f", YTMULyricsPageBaseFontSize());
}

@end

@interface YTMULyricsPanelViewController : UIViewController
@property (retain, nonatomic) YTMULyricsTabOverlayView *lyricsOverlayView;
@property (retain, nonatomic) UIButton *closeButton;
@property (assign, nonatomic) YTPlayerViewController *playerViewController;
@end

@implementation YTMULyricsPanelViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithRed:0.035 green:0.095 blue:0.135 alpha:1.0];

    self.closeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.closeButton setTitle:@"Close" forState:UIControlStateNormal];
    self.closeButton.titleLabel.font = [UIFont systemFontOfSize:17.0 weight:UIFontWeightSemibold];
    [self.closeButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [self.closeButton addTarget:self action:@selector(ytmu_closeLyricsPanel:) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.closeButton];

    self.lyricsOverlayView = [[YTMULyricsTabOverlayView alloc] initWithFrame:CGRectZero];
    self.lyricsOverlayView.playerViewController = self.playerViewController;
    [self.view addSubview:self.lyricsOverlayView];
    [self.lyricsOverlayView ytmu_renderTabOverlay];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    UIEdgeInsets safe = UIEdgeInsetsZero;
    if (@available(iOS 11.0, *)) safe = self.view.safeAreaInsets;
    CGFloat top = safe.top + 10.0;
    CGFloat closeWidth = 86.0;
    self.closeButton.frame = CGRectMake(self.view.bounds.size.width - safe.right - closeWidth - 14.0,
                                        top,
                                        closeWidth,
                                        38.0);
    self.lyricsOverlayView.frame = CGRectMake(0.0,
                                              CGRectGetMaxY(self.closeButton.frame) + 2.0,
                                              self.view.bounds.size.width,
                                              MAX(120.0, self.view.bounds.size.height - CGRectGetMaxY(self.closeButton.frame) - 2.0));
}

- (void)ytmu_closeLyricsPanel:(id)sender {
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end

static UIViewController *YTMULyricsPageTopPresenter(UIViewController *controller) {
    UIViewController *presenter = controller;
    while (presenter.presentedViewController) {
        if ([presenter.presentedViewController isKindOfClass:[YTMULyricsPanelViewController class]]) return presenter.presentedViewController;
        presenter = presenter.presentedViewController;
    }
    return presenter;
}

@interface YTMPlayerTabViewController : UIViewController
@property (retain, nonatomic) YTMULyricsTabOverlayView *ytmuLyricsTabOverlayView;
- (void)ytmu_updateLyricsTabOverlay;
@end

%hook YTMPlayerTabViewController

%property (retain, nonatomic) YTMULyricsTabOverlayView *ytmuLyricsTabOverlayView;

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    [self ytmu_updateLyricsTabOverlay];
}

- (void)viewDidLayoutSubviews {
    %orig;
    [self ytmu_updateLyricsTabOverlay];
}

%new
- (void)ytmu_updateLyricsTabOverlay {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self ytmu_updateLyricsTabOverlay];
        });
        return;
    }

    BOOL selected = YTMULyricsPageReplacementEnabled() && YTMULyricsPageOfficialLyricsTabSelected(self.view);
    if (!selected) {
        self.ytmuLyricsTabOverlayView.hidden = YES;
        return;
    }

    if (!self.ytmuLyricsTabOverlayView) {
        self.ytmuLyricsTabOverlayView = [[YTMULyricsTabOverlayView alloc] initWithFrame:CGRectZero];
        [self.view addSubview:self.ytmuLyricsTabOverlayView];
        YTMULyricsLog(@"lyrics tab overlay attached controller=%@", NSStringFromClass([self class]));
    }

    CGFloat bottom = YTMULyricsPageTabContentBottom(self.view);
    self.ytmuLyricsTabOverlayView.hidden = NO;
    self.ytmuLyricsTabOverlayView.playerViewController = YTMULyricsPagePlayerFromCandidate(self) ?: [YTMULyricsPlaybackState sharedState].playerViewController;
    self.ytmuLyricsTabOverlayView.frame = CGRectMake(0.0, 0.0, self.view.bounds.size.width, bottom);
    self.ytmuLyricsTabOverlayView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleBottomMargin;
    [self.view bringSubviewToFront:self.ytmuLyricsTabOverlayView];
    [self.ytmuLyricsTabOverlayView ytmu_renderTabOverlay];
    YTMULyricsPageHideOfficialActionsInView(self.view, self.ytmuLyricsTabOverlayView);
}

%end

@interface YTIMusicLyricsRenderer : NSObject
- (id)lyricsText;
- (id)lyricsAccessibilityText;
- (id)lyricsSourceMessage;
@end

%hook YTIMusicLyricsRenderer

- (id)lyricsText {
    id original = %orig;
    if (!YTMULyricsPageCustomSourceEnabled()) return original;

    YTMULyricsManager *manager = [YTMULyricsManager sharedManager];
    if (manager.state != YTMULyricsFetchStateDone || !manager.currentResult.hasText) return original;

    NSString *text = YTMULyricsPagePlainDisplayText(@"");
    if (!text.length) return original;
    YTMULyricsPageLogRendererOverride(@"lyricsText",
                                      manager.currentResult.sourceName ?: @"<none>",
                                      manager.translatedLines.count);
    return YTMULyricsPageFormattedString(text, original);
}

- (id)lyricsAccessibilityText {
    id original = %orig;
    if (!YTMULyricsPageCustomSourceEnabled()) return original;

    YTMULyricsManager *manager = [YTMULyricsManager sharedManager];
    if (manager.state != YTMULyricsFetchStateDone || !manager.currentResult.hasText) return original;

    NSString *text = YTMULyricsPagePlainDisplayText(@"");
    return text.length ? YTMULyricsPageFormattedString(text, original) : original;
}

- (id)lyricsSourceMessage {
    id original = %orig;
    if (!YTMULyricsPageCustomSourceEnabled()) return original;

    NSString *attribution = YTMULyricsPageAttributionText();
    return attribution.length ? YTMULyricsPageFormattedString(attribution, original) : original;
}

%end

@interface YTMNowPlayingViewController : UIViewController
@property (retain, nonatomic) UIButton *ytmuLyricsEntryButton;
- (void)ytmu_updateLyricsEntryButton;
- (void)ytmu_openLyricsPanel:(id)sender;
@end

@interface UIView (YTMULyricsPageAncestor)
- (UIViewController *)_viewControllerForAncestor;
@end

static UIView *YTMULyricsPageFindOfficialLyricsEntry(UIView *view, UIView *root, NSUInteger depth) {
    if (!view || view.hidden || view.alpha <= 0.03 || depth > 18) return nil;
    NSString *identifier = view.accessibilityIdentifier;
    if ([identifier isKindOfClass:[NSString class]] && [identifier isEqualToString:@"ytmu.lyrics.entry"]) return nil;

    NSString *text = YTMULyricsPageAccessibilityText(view);
    CGRect frame = [view convertRect:view.bounds toView:root];
    BOOL buttonSized = frame.size.width >= 48.0 &&
                       frame.size.width <= 160.0 &&
                       frame.size.height >= 24.0 &&
                       frame.size.height <= 64.0;
    BOOL insideRoot = CGRectIntersectsRect(root.bounds, frame);
    if (buttonSized && insideRoot && YTMULyricsPageTextHasLyricsToken(text) && ![text containsString:@"close"]) {
        return view;
    }

    for (UIView *subview in view.subviews) {
        UIView *found = YTMULyricsPageFindOfficialLyricsEntry(subview, root, depth + 1);
        if (found) return found;
    }
    return nil;
}

static UIView *YTMULyricsPageFindChipAnchor(UIView *view, UIView *root, NSUInteger depth) {
    if (!view || view.hidden || view.alpha <= 0.03 || depth > 18) return nil;
    NSString *identifier = view.accessibilityIdentifier;
    if ([identifier isKindOfClass:[NSString class]] && [identifier isEqualToString:@"ytmu.lyrics.entry"]) return nil;

    UIView *best = nil;
    NSString *text = YTMULyricsPageAccessibilityText(view);
    CGRect frame = [view convertRect:view.bounds toView:root];
    BOOL chipSized = frame.size.width >= 52.0 &&
                     frame.size.width <= 230.0 &&
                     frame.size.height >= 26.0 &&
                     frame.size.height <= 58.0 &&
                     CGRectGetMidY(frame) >= root.bounds.size.height * 0.32 &&
                     CGRectGetMidY(frame) <= root.bounds.size.height * 0.82 &&
                     CGRectIntersectsRect(root.bounds, frame);
    BOOL chipText = [text containsString:@"mix"] ||
                    [text containsString:@"live chat"] ||
                    [text containsString:@"replay"] ||
                    [text containsString:@"comment"] ||
                    [text containsString:@"混音"] ||
                    [text containsString:@"聊天"];
    if (chipSized && chipText) best = view;

    for (UIView *subview in view.subviews) {
        UIView *candidate = YTMULyricsPageFindChipAnchor(subview, root, depth + 1);
        if (!candidate) continue;
        if (!best) {
            best = candidate;
            continue;
        }
        CGRect bestFrame = [best convertRect:best.bounds toView:root];
        CGRect candidateFrame = [candidate convertRect:candidate.bounds toView:root];
        if (CGRectGetMaxX(candidateFrame) > CGRectGetMaxX(bestFrame)) best = candidate;
    }
    return best;
}

%hook YTMNowPlayingViewController

%property (retain, nonatomic) UIButton *ytmuLyricsEntryButton;

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    [self ytmu_updateLyricsEntryButton];
}

- (void)viewDidLayoutSubviews {
    %orig;
    [self ytmu_updateLyricsEntryButton];
}

%new
- (void)ytmu_updateLyricsEntryButton {
    if (!YTMULyricsPageCustomSourceEnabled()) {
        self.ytmuLyricsEntryButton.hidden = YES;
        return;
    }

    if (!self.ytmuLyricsEntryButton) {
        self.ytmuLyricsEntryButton = [UIButton buttonWithType:UIButtonTypeSystem];
        self.ytmuLyricsEntryButton.accessibilityIdentifier = @"ytmu.lyrics.entry";
        self.ytmuLyricsEntryButton.accessibilityLabel = @"Lyrics";
        [self.ytmuLyricsEntryButton setTitle:@"Lyrics" forState:UIControlStateNormal];
        self.ytmuLyricsEntryButton.titleLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightBold];
        [self.ytmuLyricsEntryButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        self.ytmuLyricsEntryButton.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.16];
        self.ytmuLyricsEntryButton.layer.cornerRadius = 17.0;
        self.ytmuLyricsEntryButton.layer.borderWidth = 0.0;
        self.ytmuLyricsEntryButton.clipsToBounds = YES;
        [self.ytmuLyricsEntryButton addTarget:self action:@selector(ytmu_openLyricsPanel:) forControlEvents:UIControlEventTouchUpInside];
        [self.view addSubview:self.ytmuLyricsEntryButton];
        YTMULyricsLog(@"lyrics entry button attached controller=%@", NSStringFromClass([self class]));
    }

    UIEdgeInsets safe = UIEdgeInsetsZero;
    if (@available(iOS 11.0, *)) safe = self.view.safeAreaInsets;
    CGFloat width = 86.0;
    CGFloat height = 34.0;
    UIView *official = YTMULyricsPageFindOfficialLyricsEntry(self.view, self.view, 0);
    CGRect frame = CGRectZero;
    if (official) {
        UIView *target = YTMULyricsPageActionTargetForView(official);
        CGRect officialFrame = [target convertRect:target.bounds toView:self.view];
        frame = officialFrame;
        if (frame.size.width < 72.0 || frame.size.width > 180.0) {
            frame = CGRectMake(CGRectGetMinX(officialFrame),
                               CGRectGetMidY(officialFrame) - height / 2.0,
                               width,
                               height);
        }
    } else {
        UIView *anchor = YTMULyricsPageFindChipAnchor(self.view, self.view, 0);
        if (anchor) {
            CGRect anchorFrame = [YTMULyricsPageActionTargetForView(anchor) convertRect:YTMULyricsPageActionTargetForView(anchor).bounds toView:self.view];
            CGFloat x = CGRectGetMaxX(anchorFrame) + 8.0;
            if (x + width > self.view.bounds.size.width - safe.right - 12.0) {
                x = self.view.bounds.size.width - safe.right - width - 12.0;
            }
            frame = CGRectMake(MAX(safe.left + 12.0, x),
                               CGRectGetMidY(anchorFrame) - height / 2.0,
                               width,
                               height);
        } else {
            CGFloat y = self.view.bounds.size.height * 0.64;
            frame = CGRectMake(self.view.bounds.size.width - safe.right - width - 16.0,
                               y,
                               width,
                               height);
        }
    }

    self.ytmuLyricsEntryButton.hidden = self.view.bounds.size.height < 360.0;
    self.ytmuLyricsEntryButton.frame = frame;
    self.ytmuLyricsEntryButton.layer.cornerRadius = MIN(18.0, frame.size.height / 2.0);
    [self.view bringSubviewToFront:self.ytmuLyricsEntryButton];
}

%new
- (void)ytmu_openLyricsPanel:(id)sender {
    if (!YTMULyricsPageCustomSourceEnabled()) return;
    UIViewController *presenter = YTMULyricsPageTopPresenter(self);
    if ([presenter isKindOfClass:[YTMULyricsPanelViewController class]]) return;

    YTMULyricsPanelViewController *controller = [[YTMULyricsPanelViewController alloc] init];
    controller.playerViewController = YTMULyricsPagePlayerFromCandidate(self) ?: [YTMULyricsPlaybackState sharedState].playerViewController;
    controller.modalPresentationStyle = UIModalPresentationPageSheet;
    [presenter presentViewController:controller animated:YES completion:nil];
    YTMULyricsLog(@"lyrics panel presented from=%@", NSStringFromClass([presenter class]));
}

%end

@interface ELMNodeController : NSObject
@property (nonatomic, assign, readonly) NSString *key;
@end

@interface ELMTouchCommandPropertiesHandler : NSObject
@end

static BOOL YTMULyricsPageTapLooksLikeOfficialLyrics(id handler, YTMNowPlayingViewController **nowPlayingOut) {
    if (!YTMULyricsPageCustomSourceEnabled()) return NO;
    if (class_getInstanceVariable([handler class], "_controller") == NULL ||
        class_getInstanceVariable([handler class], "_tapRecognizer") == NULL) {
        return NO;
    }

    ELMNodeController *node = YTMULyricsPageSafeValueForKey(handler, @"_controller");
    UIGestureRecognizer *tapRecognizer = YTMULyricsPageSafeValueForKey(handler, @"_tapRecognizer");
    UIView *tapView = tapRecognizer.view;
    UIViewController *ancestor = [tapView respondsToSelector:@selector(_viewControllerForAncestor)] ? [tapView _viewControllerForAncestor] : nil;
    Class nowPlayingClass = NSClassFromString(@"YTMNowPlayingViewController");
    if (!nowPlayingClass || ![ancestor isKindOfClass:nowPlayingClass]) return NO;

    NSString *nodeKey = @"";
    @try {
        nodeKey = node.key ?: @"";
    } @catch (__unused NSException *exception) {
        nodeKey = @"";
    }

    NSString *text = YTMULyricsPageRecursiveAccessibilityText(tapView, 0);
    BOOL keyLooksLikeLyrics = [[nodeKey lowercaseString] containsString:@"lyrics"];
    BOOL textLooksLikeLyrics = YTMULyricsPageTextHasLyricsToken(text);
    if (!keyLooksLikeLyrics && !textLooksLikeLyrics) return NO;

    if (nowPlayingOut) *nowPlayingOut = (YTMNowPlayingViewController *)ancestor;
    YTMULyricsLog(@"official lyrics tap intercepted node=%@ text=%@",
                  nodeKey.length ? nodeKey : @"<empty>",
                  text.length ? text : @"<empty>");
    return YES;
}

%hook ELMTouchCommandPropertiesHandler

- (void)handleTap {
    YTMNowPlayingViewController *nowPlaying = nil;
    if (YTMULyricsPageTapLooksLikeOfficialLyrics(self, &nowPlaying)) {
        [nowPlaying ytmu_openLyricsPanel:self];
        return;
    }
    %orig;
}

%end

@interface YTFormattedStringLabel : UILabel
@end

@interface YTMLightweightMusicDescriptionShelfCell : UIView
@property (retain, nonatomic) UITextView *lyrics;
@property (retain, nonatomic) UIScrollView *ytmuSourceScrollView;
@property (retain, nonatomic) NSArray *ytmuSourceButtons;
@property (retain, nonatomic) UILabel *ytmuAttributionLabel;
@property (copy, nonatomic) NSString *ytmuFallbackLyricsText;
- (void)ytmu_ensureLyricsReplacementViews;
- (void)ytmu_renderLyricsPage;
- (void)ytmu_layoutSourceButtons;
- (void)ytmu_updateSourceButtons;
- (void)ytmu_scrollSourceButtonIntoView:(UIButton *)button animated:(BOOL)animated;
- (void)ytmu_selectLyricsSource:(UIButton *)sender;
- (void)ytmu_cycleLyricsSource:(UISwipeGestureRecognizer *)gesture;
- (void)ytmu_hideOfficialLyricsActions;
@end

%hook YTMLightweightMusicDescriptionShelfCell

%property (retain, nonatomic) UITextView *lyrics;
%property (retain, nonatomic) UIScrollView *ytmuSourceScrollView;
%property (retain, nonatomic) NSArray *ytmuSourceButtons;
%property (retain, nonatomic) UILabel *ytmuAttributionLabel;
%property (copy, nonatomic) NSString *ytmuFallbackLyricsText;

- (id)initWithFrame:(CGRect)frame {
    self = %orig;
    if (self) {
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(ytmu_renderLyricsPage)
                                                     name:YTMULyricsDidUpdateNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(ytmu_renderLyricsPage)
                                                     name:YTMULyricsSettingsDidChangeNotification
                                                   object:nil];
        [self ytmu_ensureLyricsReplacementViews];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    %orig;
}

- (void)setRenderer:(id)renderer {
    %orig;
    [self ytmu_ensureLyricsReplacementViews];

    YTFormattedStringLabel *officialLyrics = nil;
    @try {
        officialLyrics = [self valueForKey:@"_descriptionLabel"];
    } @catch (__unused NSException *exception) {
        officialLyrics = nil;
    }
    self.ytmuFallbackLyricsText = officialLyrics.attributedText.string ?: officialLyrics.text ?: @"";

    if (!YTMULyricsPageReplacementEnabled()) {
        officialLyrics.hidden = NO;
        self.lyrics.hidden = YES;
        self.ytmuSourceScrollView.hidden = YES;
        self.ytmuAttributionLabel.hidden = YES;
        return;
    }

    officialLyrics.hidden = YES;
    self.lyrics.hidden = NO;
    self.ytmuSourceScrollView.hidden = NO;
    self.ytmuAttributionLabel.hidden = NO;
    [self ytmu_renderLyricsPage];
    [self ytmu_hideOfficialLyricsActions];
}

- (void)layoutSubviews {
    %orig;
    if (!YTMULyricsPageReplacementEnabled()) return;
    [self ytmu_ensureLyricsReplacementViews];

    YTFormattedStringLabel *officialLyrics = nil;
    @try {
        officialLyrics = [self valueForKey:@"_descriptionLabel"];
    } @catch (__unused NSException *exception) {
        officialLyrics = nil;
    }

    CGRect baseFrame = officialLyrics ? officialLyrics.frame : UIEdgeInsetsInsetRect(self.bounds, UIEdgeInsetsMake(12, 32, 24, 32));
    CGFloat sourceHeight = 34.0;
    CGFloat attributionHeight = self.ytmuAttributionLabel.text.length ? 30.0 : 0.0;
    self.ytmuSourceScrollView.frame = CGRectMake(baseFrame.origin.x,
                                                baseFrame.origin.y,
                                                baseFrame.size.width,
                                                sourceHeight);

    CGFloat textY = CGRectGetMaxY(self.ytmuSourceScrollView.frame) + 12.0;
    CGFloat textHeight = MAX(180.0, baseFrame.size.height - sourceHeight - attributionHeight - 24.0);
    self.lyrics.frame = CGRectMake(baseFrame.origin.x, textY, baseFrame.size.width, textHeight);

    self.ytmuAttributionLabel.frame = CGRectMake(baseFrame.origin.x,
                                                CGRectGetMaxY(self.lyrics.frame) + 8.0,
                                                baseFrame.size.width,
                                                attributionHeight);
    [self ytmu_layoutSourceButtons];
    [self ytmu_hideOfficialLyricsActions];
}

%new
- (void)ytmu_ensureLyricsReplacementViews {
    UIView *container = nil;
    @try {
        container = [self valueForKey:@"_descriptionContainer"];
    } @catch (__unused NSException *exception) {
        container = nil;
    }
    if (!container) container = self;

    if (!self.ytmuSourceScrollView) {
        self.ytmuSourceScrollView = [[UIScrollView alloc] initWithFrame:CGRectZero];
        self.ytmuSourceScrollView.backgroundColor = [UIColor clearColor];
        self.ytmuSourceScrollView.showsHorizontalScrollIndicator = NO;
        self.ytmuSourceScrollView.alwaysBounceHorizontal = YES;
        [container addSubview:self.ytmuSourceScrollView];

        NSMutableArray<UIButton *> *buttons = [NSMutableArray array];
        NSArray *options = YTMULyricsPageSourceOptions();
        for (NSUInteger idx = 0; idx < options.count; idx++) {
            UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
            button.tag = idx;
            [button setTitle:options[idx][@"title"] forState:UIControlStateNormal];
            button.titleLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightSemibold];
            button.contentEdgeInsets = UIEdgeInsetsMake(6, 13, 6, 13);
            button.layer.cornerRadius = 15.0;
            button.clipsToBounds = YES;
            [button addTarget:self action:@selector(ytmu_selectLyricsSource:) forControlEvents:UIControlEventTouchUpInside];
            [self.ytmuSourceScrollView addSubview:button];
            [buttons addObject:button];
        }
        self.ytmuSourceButtons = buttons;
    }

    if (!self.lyrics) {
        self.lyrics = [[UITextView alloc] initWithFrame:CGRectZero];
        self.lyrics.backgroundColor = [UIColor clearColor];
        self.lyrics.editable = NO;
        self.lyrics.selectable = YES;
        self.lyrics.scrollEnabled = YES;
        self.lyrics.showsVerticalScrollIndicator = NO;
        self.lyrics.textContainerInset = UIEdgeInsetsZero;
        self.lyrics.textContainer.lineFragmentPadding = 0;
        if (@available(iOS 13.0, *)) self.lyrics.textColor = [UIColor labelColor];
        [container addSubview:self.lyrics];

        UISwipeGestureRecognizer *left = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(ytmu_cycleLyricsSource:)];
        left.direction = UISwipeGestureRecognizerDirectionLeft;
        [self.lyrics addGestureRecognizer:left];
        UISwipeGestureRecognizer *right = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(ytmu_cycleLyricsSource:)];
        right.direction = UISwipeGestureRecognizerDirectionRight;
        [self.lyrics addGestureRecognizer:right];
    }

    if (!self.ytmuAttributionLabel) {
        self.ytmuAttributionLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        self.ytmuAttributionLabel.backgroundColor = [UIColor clearColor];
        self.ytmuAttributionLabel.font = [UIFont systemFontOfSize:10.5 weight:UIFontWeightMedium];
        self.ytmuAttributionLabel.textColor = YTMULyricsPageSecondaryTextColor();
        self.ytmuAttributionLabel.numberOfLines = 2;
        self.ytmuAttributionLabel.adjustsFontSizeToFitWidth = YES;
        self.ytmuAttributionLabel.minimumScaleFactor = 0.82;
        [container addSubview:self.ytmuAttributionLabel];
    }

    [self ytmu_updateSourceButtons];
}

%new
- (void)ytmu_renderLyricsPage {
    if (!YTMULyricsPageReplacementEnabled()) return;
    [self ytmu_ensureLyricsReplacementViews];
    self.lyrics.attributedText = YTMULyricsPageAttributedText(self.lyrics, self.ytmuFallbackLyricsText ?: @"");
    self.ytmuAttributionLabel.text = YTMULyricsPageAttributionText();
    [self ytmu_updateSourceButtons];
    [self setNeedsLayout];

    id delegate = nil;
    @try {
        delegate = [self valueForKey:@"_delegate"] ?: [self valueForKey:@"delegate"];
    } @catch (__unused NSException *exception) {
        delegate = nil;
    }
    if ([delegate respondsToSelector:@selector(lightweightMusicDescriptionShelfCellNeedsResize:)]) {
        SEL selector = @selector(lightweightMusicDescriptionShelfCellNeedsResize:);
        void (*resize)(id, SEL, id) = (void (*)(id, SEL, id))[delegate methodForSelector:selector];
        resize(delegate, selector, self);
    }

    YTMULyricsManager *manager = [YTMULyricsManager sharedManager];
    YTMULyricsLog(@"lyrics page rendered state=%ld source=%@ lines=%lu translated=%lu",
                  (long)manager.state,
                  manager.currentResult.sourceName ?: @"<none>",
                  (unsigned long)manager.displayLineTexts.count,
                  (unsigned long)manager.translatedLines.count);
}

%new
- (void)ytmu_layoutSourceButtons {
    CGFloat x = 0.0;
    for (UIButton *button in self.ytmuSourceButtons) {
        [button sizeToFit];
        CGFloat width = MAX(64.0, button.bounds.size.width + 22.0);
        button.frame = CGRectMake(x, 2.0, width, 30.0);
        x += width + 8.0;
    }
    self.ytmuSourceScrollView.contentSize = CGSizeMake(MAX(x, self.ytmuSourceScrollView.bounds.size.width + 1), self.ytmuSourceScrollView.bounds.size.height);
}

%new
- (void)ytmu_scrollSourceButtonIntoView:(UIButton *)button animated:(BOOL)animated {
    if (!button || !self.ytmuSourceScrollView) return;
    [self.ytmuSourceScrollView scrollRectToVisible:CGRectInset(button.frame, -18.0, 0.0) animated:animated];
}

%new
- (void)ytmu_updateSourceButtons {
    NSString *selected = YTMULyricsPageString(@"lyricsPreferredSource", @"auto");
    for (UIButton *button in self.ytmuSourceButtons) {
        NSString *key = YTMULyricsPageSourceOptions()[button.tag][@"key"];
        BOOL active = [key isEqualToString:selected];
        UIColor *titleColor = active ? [UIColor whiteColor] : YTMULyricsPageSecondaryTextColor();
        UIColor *background = active ? [[UIColor whiteColor] colorWithAlphaComponent:0.22] : [[UIColor whiteColor] colorWithAlphaComponent:0.10];
        [button setTitleColor:titleColor forState:UIControlStateNormal];
        button.backgroundColor = background;
    }
}

%new
- (void)ytmu_selectLyricsSource:(UIButton *)sender {
    NSArray *options = YTMULyricsPageSourceOptions();
    if (sender.tag >= options.count) return;
    NSString *key = options[sender.tag][@"key"];
    YTMULyricsPageSetSetting(@"lyricsPreferredSource", key);
    [self ytmu_updateSourceButtons];
    [self ytmu_scrollSourceButtonIntoView:sender animated:YES];
    YTMULyricsLog(@"lyrics page source selected=%@", YTMULyricsPageSourceTitle(key));
}

%new
- (void)ytmu_cycleLyricsSource:(UISwipeGestureRecognizer *)gesture {
    NSArray *options = YTMULyricsPageSourceOptions();
    if (!options.count) return;
    NSString *selected = YTMULyricsPageString(@"lyricsPreferredSource", @"auto");
    NSInteger index = (NSInteger)YTMULyricsPageSourceIndex(selected);
    if (gesture.direction == UISwipeGestureRecognizerDirectionLeft) {
        index = (index + 1) % (NSInteger)options.count;
    } else if (gesture.direction == UISwipeGestureRecognizerDirectionRight) {
        index = (index - 1 + (NSInteger)options.count) % (NSInteger)options.count;
    }
    NSString *key = options[(NSUInteger)index][@"key"];
    YTMULyricsPageSetSetting(@"lyricsPreferredSource", key);
    [self ytmu_updateSourceButtons];
    [self ytmu_layoutSourceButtons];
    if ((NSUInteger)index < self.ytmuSourceButtons.count) {
        [self ytmu_scrollSourceButtonIntoView:self.ytmuSourceButtons[(NSUInteger)index] animated:YES];
    }
    YTMULyricsLog(@"lyrics page source swiped=%@", YTMULyricsPageSourceTitle(key));
}

%new
- (void)ytmu_hideOfficialLyricsActions {
    UIView *root = self;
    for (NSUInteger depth = 0; depth < 8 && root.superview && ![root.superview isKindOfClass:[UIWindow class]]; depth++) {
        root = root.superview;
    }
    YTMULyricsPageHideOfficialActionsInView(root, self);
}

%end

%hook YTPlayerViewController

- (void)playbackController:(id)arg1 didActivateVideo:(id)arg2 withPlaybackData:(id)arg3 {
    %orig;

    NSString *videoId = self.currentVideoID ?: self.contentVideoID ?: @"";
    YTIVideoDetails *details = self.playerResponse.playerData.videoDetails;
    [[YTMUTranslationContext sharedContext] updateWithVideoId:videoId
                                                        title:details.title
                                                       artist:details.author];
}

%end

%ctor {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithDictionary:[defaults dictionaryForKey:@"YTMUltimate"] ?: @{}];
    YTMULyricsSetDefault(dict, @"bilingualLyrics", @(NO));
    YTMULyricsSetDefault(dict, @"lyricsTranslationEnabled", dict[@"bilingualLyrics"] ?: @(NO));
    YTMULyricsSetDefault(dict, @"lyricsPreferredSource", @"auto");
    YTMULyricsSetDefault(dict, @"translationProvider", YTMUTranslationProviderGoogle);
    YTMULyricsSetDefault(dict, @"translationTargetLang", @"auto");
    YTMULyricsSetDefault(dict, @"translationBaseUrl", @"https://api.openai.com/v1");
    YTMULyricsSetDefault(dict, @"translationDebugLogs", @(YES));
    [defaults setObject:dict forKey:@"YTMUltimate"];
}
