#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "Headers/YTPlayerViewController.h"
#import "Lyrics/YTMULyricsManager.h"
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

static BOOL YTMULyricsPageReplacementEnabled(void) {
    NSDictionary *settings = YTMULyricsPageSettings();
    return [settings[@"YTMUltimateIsEnabled"] boolValue] &&
           ([settings[@"selectableLyrics"] boolValue] ||
            [settings[@"syncedLyricsEnabled"] boolValue] ||
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
    UIFont *mainFont = [UIFont systemFontOfSize:30.0 weight:UIFontWeightHeavy];
    UIFont *romanFont = [UIFont italicSystemFontOfSize:20.0];
    UIFont *translationFont = [UIFont systemFontOfSize:23.0 weight:UIFontWeightSemibold];
    UIFont *statusFont = [UIFont systemFontOfSize:22.0 weight:UIFontWeightSemibold];

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
    BOOL showTimeCodes = YTMULyricsPageBool(@"lyricsShowTimeCodes");

    for (NSUInteger idx = 0; idx < sourceLines.count; idx++) {
        NSString *source = YTMULyricsPageLineText(sourceLines[idx]);
        source = [YTMULyricsTextProcessor convertChineseText:source mode:convertMode];
        if (showTimeCodes && idx < result.lines.count && result.lines[idx].time.length) {
            source = [NSString stringWithFormat:@"[%@] %@", result.lines[idx].time, source];
        }

        appendLine(source, mainFont, primary, mainParagraph);

        if (romanization) {
            NSString *roman = [YTMULyricsTextProcessor romanizeText:source] ?: @"";
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

static UIView *YTMULyricsPageActionTargetForView(UIView *view) {
    UIView *candidate = view;
    for (NSUInteger depth = 0; candidate && depth < 4; depth++) {
        if ([candidate isKindOfClass:[UIControl class]]) return candidate;
        candidate = candidate.superview;
    }
    return view;
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

static const NSInteger YTMULyricsPageOverlayTag = 0x59544D55;
static char YTMULyricsPageOverlayKey;

static BOOL YTMULyricsPageViewIsVisible(UIView *view) {
    return view && !view.hidden && view.alpha > 0.03 && view.window;
}

static BOOL YTMULyricsPageLooksLikeTitleText(NSString *text) {
    NSString *value = [[text ?: @"" stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
    if (!value.length || value.length > 48) return NO;
    return [value containsString:@"lyrics"] ||
           [value containsString:@"歌词"] ||
           [value containsString:@"歌詞"];
}

static BOOL YTMULyricsPageLooksLikeActionText(NSString *text) {
    NSString *value = [text ?: @"" lowercaseString];
    return [value containsString:@"share"] ||
           [value containsString:@"translate"] ||
           [value containsString:@"分享"] ||
           [value containsString:@"翻译"] ||
           [value containsString:@"共有"] ||
           [value containsString:@"翻訳"];
}

static void YTMULyricsPageCollectSheetSignals(UIView *view,
                                              BOOL *hasTitle,
                                              BOOL *hasAction,
                                              NSUInteger *textNodeCount,
                                              NSUInteger depth) {
    if (!YTMULyricsPageViewIsVisible(view) || view.tag == YTMULyricsPageOverlayTag || depth > 16) return;

    NSString *text = YTMULyricsPageViewText(view);
    if (text.length) {
        if (YTMULyricsPageLooksLikeTitleText(text)) *hasTitle = YES;
        if (YTMULyricsPageLooksLikeActionText(text)) *hasAction = YES;
        if ([view isKindOfClass:[UILabel class]] || [view isKindOfClass:[UIButton class]]) {
            (*textNodeCount)++;
        }
    }

    for (UIView *subview in view.subviews) {
        YTMULyricsPageCollectSheetSignals(subview, hasTitle, hasAction, textNodeCount, depth + 1);
    }
}

static UIView *YTMULyricsPageFindLyricsSheetInView(UIView *root, UIWindow *window, CGFloat *bestArea, BOOL requireAction) {
    if (!YTMULyricsPageViewIsVisible(root) || root.tag == YTMULyricsPageOverlayTag) return nil;

    UIView *best = nil;
    CGRect frame = [root convertRect:root.bounds toView:window];
    CGSize windowSize = window.bounds.size;
    BOOL plausibleFrame = frame.size.width >= windowSize.width * 0.72 &&
                          frame.size.height >= windowSize.height * 0.34 &&
                          CGRectGetMaxY(frame) >= windowSize.height * 0.72 &&
                          frame.origin.y >= windowSize.height * 0.06;

    if (plausibleFrame) {
        BOOL hasTitle = NO;
        BOOL hasAction = NO;
        NSUInteger textNodeCount = 0;
        YTMULyricsPageCollectSheetSignals(root, &hasTitle, &hasAction, &textNodeCount, 0);
        BOOL looksLikeLyricsSheet = hasTitle && (requireAction ? hasAction : (hasAction || textNodeCount >= 8));
        if (looksLikeLyricsSheet) {
            CGFloat area = frame.size.width * frame.size.height;
            if (area > 0 && area < *bestArea) {
                *bestArea = area;
                best = root;
            }
        }
    }

    for (UIView *subview in root.subviews) {
        UIView *candidate = YTMULyricsPageFindLyricsSheetInView(subview, window, bestArea, requireAction);
        if (candidate) best = candidate;
    }
    return best;
}

static void YTMULyricsPageFindTitleBottom(UIView *view, UIView *sheet, CGFloat *bottom, NSUInteger depth) {
    if (!YTMULyricsPageViewIsVisible(view) || view.tag == YTMULyricsPageOverlayTag || depth > 16) return;
    NSString *text = YTMULyricsPageViewText(view);
    if (YTMULyricsPageLooksLikeTitleText(text)) {
        CGRect frame = [view convertRect:view.bounds toView:sheet];
        *bottom = MAX(*bottom, CGRectGetMaxY(frame));
    }
    for (UIView *subview in view.subviews) {
        YTMULyricsPageFindTitleBottom(subview, sheet, bottom, depth + 1);
    }
}

static CGFloat YTMULyricsPageOverlayTopForSheet(UIView *sheet) {
    CGFloat titleBottom = 0.0;
    YTMULyricsPageFindTitleBottom(sheet, sheet, &titleBottom, 0);
    CGFloat top = titleBottom > 0.0 ? titleBottom + 28.0 : 108.0;
    CGFloat maxTop = MAX(88.0, MIN(154.0, sheet.bounds.size.height * 0.24));
    return MIN(MAX(top, 88.0), maxTop);
}

static void YTMULyricsPageCollectFallbackLines(UIView *view,
                                               UIView *sheet,
                                               UIView *replacementRoot,
                                               CGFloat overlayTop,
                                               NSMutableArray<NSString *> *lines,
                                               NSUInteger depth) {
    if (!YTMULyricsPageViewIsVisible(view) || view == replacementRoot || [view isDescendantOfView:replacementRoot] || depth > 18) return;
    if ([view isKindOfClass:[UILabel class]]) {
        NSString *text = [(UILabel *)view text] ?: @"";
        NSString *trimmed = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        CGRect frame = [view convertRect:view.bounds toView:sheet];
        if (trimmed.length > 1 &&
            CGRectGetMinY(frame) >= overlayTop - 8.0 &&
            !YTMULyricsPageLooksLikeTitleText(trimmed) &&
            !YTMULyricsPageLooksLikeActionText(trimmed)) {
            [lines addObject:trimmed];
        }
    }
    for (UIView *subview in view.subviews) {
        YTMULyricsPageCollectFallbackLines(subview, sheet, replacementRoot, overlayTop, lines, depth + 1);
    }
}

@interface YTMULyricsPageOverlayView : UIView
@property (retain, nonatomic) UIScrollView *sourceScrollView;
@property (retain, nonatomic) NSArray *sourceButtons;
@property (retain, nonatomic) UITextView *lyricsTextView;
@property (retain, nonatomic) UILabel *attributionLabel;
@property (copy, nonatomic) NSString *fallbackLyricsText;
@property (copy, nonatomic) NSString *lastRenderSignature;
- (void)ytmu_renderSheetOverlay;
@end

@implementation YTMULyricsPageOverlayView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.tag = YTMULyricsPageOverlayTag;
        self.clipsToBounds = YES;
        self.userInteractionEnabled = YES;
        self.backgroundColor = [UIColor colorWithRed:0.035 green:0.095 blue:0.135 alpha:0.985];

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

        UISwipeGestureRecognizer *left = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(ytmu_cycleLyricsSource:)];
        left.direction = UISwipeGestureRecognizerDirectionLeft;
        [self.lyricsTextView addGestureRecognizer:left];
        UISwipeGestureRecognizer *right = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(ytmu_cycleLyricsSource:)];
        right.direction = UISwipeGestureRecognizerDirectionRight;
        [self.lyricsTextView addGestureRecognizer:right];

        self.attributionLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        self.attributionLabel.backgroundColor = [UIColor clearColor];
        self.attributionLabel.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightSemibold];
        self.attributionLabel.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.58];
        self.attributionLabel.numberOfLines = 2;
        [self addSubview:self.attributionLabel];

        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(ytmu_renderSheetOverlay)
                                                     name:YTMULyricsDidUpdateNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(ytmu_renderSheetOverlay)
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
    CGFloat sideInset = MAX(24.0, MIN(34.0, self.bounds.size.width * 0.07));
    CGFloat bottomInset = 16.0 + self.safeAreaInsets.bottom;
    CGFloat attributionHeight = self.attributionLabel.text.length ? 36.0 : 0.0;
    CGFloat sourceHeight = 34.0;
    self.sourceScrollView.frame = CGRectMake(sideInset, 16.0, self.bounds.size.width - sideInset * 2.0, sourceHeight);

    CGFloat textY = CGRectGetMaxY(self.sourceScrollView.frame) + 16.0;
    CGFloat attributionY = self.bounds.size.height - bottomInset - attributionHeight;
    CGFloat textHeight = MAX(120.0, attributionY - textY - 12.0);
    self.lyricsTextView.frame = CGRectMake(sideInset, textY, self.bounds.size.width - sideInset * 2.0, textHeight);
    self.attributionLabel.frame = CGRectMake(sideInset, attributionY, self.bounds.size.width - sideInset * 2.0, attributionHeight);
    [self ytmu_layoutSourceButtons];
}

- (void)ytmu_renderSheetOverlay {
    if (!YTMULyricsPageReplacementEnabled()) {
        self.hidden = YES;
        return;
    }

    self.hidden = NO;
    self.lyricsTextView.attributedText = YTMULyricsPageAttributedText(self.lyricsTextView, self.fallbackLyricsText ?: @"");
    self.attributionLabel.text = YTMULyricsPageAttributionText();
    [self ytmu_updateSourceButtons];
    [self setNeedsLayout];

    YTMULyricsManager *manager = [YTMULyricsManager sharedManager];
    NSString *signature = [NSString stringWithFormat:@"%ld|%@|%lu|%lu|%@",
                           (long)manager.state,
                           manager.currentResult.sourceName ?: @"<none>",
                           (unsigned long)manager.displayLineTexts.count,
                           (unsigned long)manager.translatedLines.count,
                           YTMULyricsPageString(@"lyricsPreferredSource", @"auto")];
    if (![signature isEqualToString:self.lastRenderSignature]) {
        self.lastRenderSignature = signature;
        YTMULyricsLog(@"lyrics sheet overlay rendered state=%ld source=%@ lines=%lu translated=%lu attribution=%@",
                      (long)manager.state,
                      manager.currentResult.sourceName ?: @"<none>",
                      (unsigned long)manager.displayLineTexts.count,
                      (unsigned long)manager.translatedLines.count,
                      self.attributionLabel.text.length ? self.attributionLabel.text : @"<empty>");
    }
}

- (void)ytmu_layoutSourceButtons {
    CGFloat x = 0.0;
    NSString *selected = YTMULyricsPageString(@"lyricsPreferredSource", @"auto");
    NSArray *options = YTMULyricsPageSourceOptions();
    for (UIButton *button in self.sourceButtons) {
        [button sizeToFit];
        CGFloat width = MAX(64.0, button.bounds.size.width + 22.0);
        button.frame = CGRectMake(x, 2.0, width, 30.0);
        x += width + 8.0;
        if (button.tag < options.count) {
            NSString *key = options[button.tag][@"key"];
            if ([key isEqualToString:selected]) {
                [self.sourceScrollView scrollRectToVisible:CGRectInset(button.frame, -18, 0) animated:NO];
            }
        }
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

- (void)ytmu_selectLyricsSource:(UIButton *)sender {
    NSArray *options = YTMULyricsPageSourceOptions();
    if (sender.tag >= options.count) return;
    NSString *key = options[sender.tag][@"key"];
    YTMULyricsPageSetSetting(@"lyricsPreferredSource", key);
    [self ytmu_updateSourceButtons];
    YTMULyricsLog(@"lyrics sheet source selected=%@", YTMULyricsPageSourceTitle(key));
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
    YTMULyricsLog(@"lyrics sheet source swiped=%@", YTMULyricsPageSourceTitle(key));
}

@end

static void YTMULyricsPageSetExistingOverlaysHidden(UIView *view, BOOL hidden) {
    if (!view) return;
    if (view.tag == YTMULyricsPageOverlayTag) view.hidden = hidden;
    for (UIView *subview in view.subviews) {
        YTMULyricsPageSetExistingOverlaysHidden(subview, hidden);
    }
}

static void YTMULyricsPageAttachOverlayToSheet(UIView *sheet, UIWindow *window) {
    if (!sheet || !window) return;
    CGFloat overlayTop = YTMULyricsPageOverlayTopForSheet(sheet);
    CGFloat height = MAX(160.0, sheet.bounds.size.height - overlayTop);

    YTMULyricsPageOverlayView *overlay = objc_getAssociatedObject(sheet, &YTMULyricsPageOverlayKey);
    if (!overlay) {
        overlay = [[YTMULyricsPageOverlayView alloc] initWithFrame:CGRectZero];
        objc_setAssociatedObject(sheet, &YTMULyricsPageOverlayKey, overlay, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [sheet addSubview:overlay];
        CGRect frame = [sheet convertRect:sheet.bounds toView:window];
        YTMULyricsLog(@"lyrics sheet overlay attached sheet=%@ frame={%.1f,%.1f,%.1f,%.1f} top=%.1f",
                      NSStringFromClass([sheet class]),
                      frame.origin.x,
                      frame.origin.y,
                      frame.size.width,
                      frame.size.height,
                      overlayTop);
    }

    NSMutableArray<NSString *> *fallbackLines = [NSMutableArray array];
    YTMULyricsPageCollectFallbackLines(sheet, sheet, overlay, overlayTop, fallbackLines, 0);
    overlay.fallbackLyricsText = [fallbackLines componentsJoinedByString:@"\n"];
    overlay.frame = CGRectMake(0.0, overlayTop, sheet.bounds.size.width, height);
    overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [sheet bringSubviewToFront:overlay];
    [overlay ytmu_renderSheetOverlay];
    YTMULyricsPageHideOfficialActionsInView(sheet, overlay);
}

static void YTMULyricsPageScanVisibleLyricsSheets(BOOL forced) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            YTMULyricsPageScanVisibleLyricsSheets(forced);
        });
        return;
    }

    NSArray<UIWindow *> *windows = [UIApplication sharedApplication].windows ?: @[];
    if (!YTMULyricsPageReplacementEnabled()) {
        for (UIWindow *window in windows) {
            YTMULyricsPageSetExistingOverlaysHidden(window, YES);
        }
        return;
    }

    BOOL attached = NO;
    for (UIWindow *window in windows) {
        if (!YTMULyricsPageViewIsVisible(window)) continue;
        CGFloat bestArea = CGFLOAT_MAX;
        UIView *sheet = YTMULyricsPageFindLyricsSheetInView(window, window, &bestArea, YES);
        if (!sheet) {
            bestArea = CGFLOAT_MAX;
            sheet = YTMULyricsPageFindLyricsSheetInView(window, window, &bestArea, NO);
        }
        if (sheet) {
            attached = YES;
            YTMULyricsPageAttachOverlayToSheet(sheet, window);
        }
    }

    static CFTimeInterval lastMissLogTime = 0;
    if (forced && !attached) {
        CFTimeInterval now = [[NSDate date] timeIntervalSinceReferenceDate];
        if (now - lastMissLogTime > 4.0) {
            lastMissLogTime = now;
            YTMULyricsLog(@"lyrics sheet scan no visible official sheet found");
        }
    }
}

static void YTMULyricsPageStartWindowScanner(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] addObserverForName:YTMULyricsDidUpdateNotification
                                                              object:nil
                                                               queue:[NSOperationQueue mainQueue]
                                                          usingBlock:^(__unused NSNotification *notification) {
                YTMULyricsPageScanVisibleLyricsSheets(YES);
            }];
            [[NSNotificationCenter defaultCenter] addObserverForName:YTMULyricsSettingsDidChangeNotification
                                                              object:nil
                                                               queue:[NSOperationQueue mainQueue]
                                                          usingBlock:^(__unused NSNotification *notification) {
                YTMULyricsPageScanVisibleLyricsSheets(YES);
            }];
            [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                              object:nil
                                                               queue:[NSOperationQueue mainQueue]
                                                          usingBlock:^(__unused NSNotification *notification) {
                YTMULyricsPageScanVisibleLyricsSheets(YES);
            }];

            NSTimer *timer = [NSTimer timerWithTimeInterval:0.75 repeats:YES block:^(__unused NSTimer *timer) {
                YTMULyricsPageScanVisibleLyricsSheets(NO);
            }];
            [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
            YTMULyricsLog(@"lyrics sheet scanner installed");
            YTMULyricsPageScanVisibleLyricsSheets(YES);
        });
    });
}

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
    CGFloat attributionHeight = self.ytmuAttributionLabel.text.length ? 22.0 : 0.0;
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
        self.ytmuAttributionLabel.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightSemibold];
        self.ytmuAttributionLabel.textColor = YTMULyricsPageSecondaryTextColor();
        self.ytmuAttributionLabel.numberOfLines = 1;
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
    NSString *selected = YTMULyricsPageString(@"lyricsPreferredSource", @"auto");
    for (UIButton *button in self.ytmuSourceButtons) {
        [button sizeToFit];
        CGFloat width = MAX(64.0, button.bounds.size.width + 22.0);
        button.frame = CGRectMake(x, 2.0, width, 30.0);
        x += width + 8.0;
        NSString *key = YTMULyricsPageSourceOptions()[button.tag][@"key"];
        if ([key isEqualToString:selected]) {
            [self.ytmuSourceScrollView scrollRectToVisible:CGRectInset(button.frame, -18, 0) animated:NO];
        }
    }
    self.ytmuSourceScrollView.contentSize = CGSizeMake(MAX(x, self.ytmuSourceScrollView.bounds.size.width + 1), self.ytmuSourceScrollView.bounds.size.height);
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
    YTMULyricsPageStartWindowScanner();
}
