#import "YTMUSyncedLyricsView.h"
#import "../Utils/YTMUWeakProxy.h"
#import "YTMULyricsManager.h"
#import "YTMULyricsPlaybackState.h"
#import "YTMULyricsTextProcessor.h"
#import "../Headers/Localization.h"
#import "../Headers/YTPlayerViewController.h"
#import <MediaPlayer/MediaPlayer.h>

static NSString *YTMUSyncedLyricsLocalized(NSString *key, NSString *fallback) {
    return [NSBundle.ytmu_defaultBundle localizedStringForKey:key value:fallback table:nil] ?: (fallback ?: key);
}

static id YTMUSyncedLyricsBlurFilter(CGFloat radius) {
    static dispatch_once_t onceToken;
    static Class filterClass;
    static SEL filterSel;
    dispatch_once(&onceToken, ^{
        filterClass = NSClassFromString(@"CAFilter");
        filterSel = NSSelectorFromString(@"filterWithType:");
    });
    if (!filterClass || ![filterClass respondsToSelector:filterSel]) return nil;
    id (*makeFilter)(id, SEL, NSString *) = (id (*)(id, SEL, NSString *))[filterClass methodForSelector:filterSel];
    id filter = makeFilter(filterClass, filterSel, @"gaussianBlur");
    if (!filter) return nil;
    @try {
        [filter setValue:@(radius) forKey:@"inputRadius"];
    } @catch (__unused NSException *exception) {
        return nil;
    }
    return filter;
}

@interface YTMULyricLineView : UIControl
@property (nonatomic, strong) UILabel *timeLabel;
@property (nonatomic, strong) UILabel *mainLabel;
@property (nonatomic, strong) UILabel *romanLabel;
@property (nonatomic, strong) UILabel *translationLabel;
@property (nonatomic, copy) NSString *mainText;
@property (nonatomic, copy) NSString *romanText;
@property (nonatomic, copy) NSString *translationText;
@property (nonatomic) NSUInteger index;
@property (nonatomic) NSTimeInterval timeInMs;
@property (nonatomic) NSTimeInterval durationMs;
@end

@implementation YTMULyricLineView

- (instancetype)init {
    self = [super initWithFrame:CGRectZero];
    if (self) {
        _timeLabel = [[UILabel alloc] init];
        _mainLabel = [[UILabel alloc] init];
        _romanLabel = [[UILabel alloc] init];
        _translationLabel = [[UILabel alloc] init];
        for (UILabel *label in @[_timeLabel, _mainLabel, _romanLabel, _translationLabel]) {
            label.numberOfLines = 0;
            label.translatesAutoresizingMaskIntoConstraints = NO;
            [self addSubview:label];
        }
        _timeLabel.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.42];
        _timeLabel.font = [UIFont monospacedDigitSystemFontOfSize:11 weight:UIFontWeightMedium];
        _romanLabel.textColor = [UIColor secondaryLabelColor];
        _romanLabel.font = [UIFont italicSystemFontOfSize:16];
        _translationLabel.textColor = [UIColor labelColor];
        _translationLabel.alpha = 0.82;

        [NSLayoutConstraint activateConstraints:@[
            [_timeLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
            [_timeLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
            [_timeLabel.topAnchor constraintEqualToAnchor:self.topAnchor constant:9],
            [_mainLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
            [_mainLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
            [_mainLabel.topAnchor constraintEqualToAnchor:_timeLabel.bottomAnchor constant:2],
            [_romanLabel.leadingAnchor constraintEqualToAnchor:_mainLabel.leadingAnchor],
            [_romanLabel.trailingAnchor constraintEqualToAnchor:_mainLabel.trailingAnchor],
            [_romanLabel.topAnchor constraintEqualToAnchor:_mainLabel.bottomAnchor constant:3],
            [_translationLabel.leadingAnchor constraintEqualToAnchor:_mainLabel.leadingAnchor],
            [_translationLabel.trailingAnchor constraintEqualToAnchor:_mainLabel.trailingAnchor],
            [_translationLabel.topAnchor constraintEqualToAnchor:_romanLabel.bottomAnchor constant:3],
            [_translationLabel.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-9],
        ]];
    }
    return self;
}

- (void)setActive:(BOOL)active distance:(NSInteger)distance focusBlur:(BOOL)focusBlur {
    CGFloat alpha = 1.0;
    CGFloat blurRadius = 0.0;

    if (!active) {
        if (focusBlur) {
            NSInteger absDistance = labs(distance);
            if (absDistance == 1) {
                alpha = (distance > 0) ? 0.65 : 0.52;
                blurRadius = 1.6;
            } else if (absDistance == 2) {
                alpha = 0.40;
                blurRadius = 3.0;
            } else {
                alpha = 0.24;
                blurRadius = 5.5;
            }
        } else {
            alpha = 0.36;
        }
    }

    self.alpha = alpha;
    self.transform = CGAffineTransformIdentity;
    self.mainLabel.font = active ? [UIFont boldSystemFontOfSize:self.mainLabel.font.pointSize] : [UIFont systemFontOfSize:self.mainLabel.font.pointSize weight:UIFontWeightRegular];
    self.layer.filters = nil;

    for (UILabel *label in @[self.timeLabel, self.mainLabel, self.romanLabel, self.translationLabel]) {
        if (label.layer.shouldRasterize) label.layer.shouldRasterize = NO;
        if (blurRadius > 0.01) {
            id filter = YTMUSyncedLyricsBlurFilter(blurRadius);
            label.layer.filters = filter ? @[filter] : nil;
        } else {
            label.layer.filters = nil;
        }
    }
}

- (NSAttributedString *)attributedText:(NSString *)text
                                  font:(UIFont *)font
                                active:(BOOL)active
                              progress:(CGFloat)progress
                          activeColor:(UIColor *)activeColor
                        inactiveColor:(UIColor *)inactiveColor {
    if (!text.length) return [[NSAttributedString alloc] initWithString:@""];
    CGFloat clamped = MIN(1.0, MAX(0.0, progress));
    CGFloat exactSplit = active ? (CGFloat)text.length * clamped : 0.0;
    NSUInteger split = MIN(text.length, (NSUInteger)floor(exactSplit));
    CGFloat fractional = exactSplit - floor(exactSplit);
    NSMutableAttributedString *out = [[NSMutableAttributedString alloc] initWithString:text attributes:@{
        NSFontAttributeName: font,
        NSForegroundColorAttributeName: active ? inactiveColor : activeColor,
    }];
    if (active && split > 0) {
        [out addAttribute:NSForegroundColorAttributeName value:activeColor range:NSMakeRange(0, split)];
    }
    if (active && fractional > 0.01 && split < text.length) {
        UIColor *blend = [self colorByBlendingFromColor:inactiveColor toColor:activeColor progress:fractional];
        [out addAttribute:NSForegroundColorAttributeName value:blend range:NSMakeRange(split, 1)];
    }
    return out;
}

- (UIColor *)colorByBlendingFromColor:(UIColor *)fromColor toColor:(UIColor *)toColor progress:(CGFloat)progress {
    CGFloat fr = 0, fg = 0, fb = 0, fa = 0;
    CGFloat tr = 0, tg = 0, tb = 0, ta = 0;
    if (![fromColor getRed:&fr green:&fg blue:&fb alpha:&fa]) {
        fr = fg = fb = 1.0;
        fa = 0.32;
    }
    if (![toColor getRed:&tr green:&tg blue:&tb alpha:&ta]) {
        tr = tg = tb = 1.0;
        ta = 1.0;
    }
    CGFloat t = MIN(1.0, MAX(0.0, progress));
    return [UIColor colorWithRed:fr + (tr - fr) * t
                           green:fg + (tg - fg) * t
                            blue:fb + (tb - fb) * t
                           alpha:fa + (ta - fa) * t];
}

- (void)updateKaraokeProgress:(CGFloat)progress active:(BOOL)active {
    UIColor *primary = [UIColor whiteColor];
    UIColor *secondary = [[UIColor whiteColor] colorWithAlphaComponent:0.58];
    UIColor *translation = [[UIColor whiteColor] colorWithAlphaComponent:0.78];
    UIColor *dim = [[UIColor whiteColor] colorWithAlphaComponent:0.32];

    self.mainLabel.attributedText = [self attributedText:self.mainText ?: @""
                                                    font:self.mainLabel.font
                                                  active:active
                                                progress:progress
                                             activeColor:primary
                                           inactiveColor:dim];
    self.romanLabel.attributedText = [self attributedText:self.romanText ?: @""
                                                     font:self.romanLabel.font
                                                   active:active
                                                 progress:progress
                                              activeColor:secondary
                                            inactiveColor:dim];
    self.translationLabel.attributedText = [self attributedText:self.translationText ?: @""
                                                           font:self.translationLabel.font
                                                         active:active
                                                       progress:active ? 1.0 : 0.0
                                                    activeColor:translation
                                                  inactiveColor:dim];
}

@end

@interface YTMUSyncedLyricsView ()
@property (nonatomic, strong) UIVisualEffectView *blurView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *stateLabel;
@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) UIStackView *stackView;
@property (nonatomic, copy) NSArray<YTMULyricLineView *> *lineViews;
@property (nonatomic) NSInteger activeIndex;
@property (nonatomic, strong) CADisplayLink *displayLink;
@property (nonatomic, copy) NSString *lastReloadSignature;
@property (nonatomic, copy) NSString *lastReloadContentSignature;
- (void)updatePlaybackTimeMs:(NSTimeInterval)timeMs animated:(BOOL)animated;
@end

@implementation YTMUSyncedLyricsView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.hidden = YES;
        self.clipsToBounds = NO;
        self.backgroundColor = [UIColor clearColor];
        self.layer.cornerRadius = 0;
        self.layer.cornerCurve = kCACornerCurveContinuous;

        _blurView = [[UIVisualEffectView alloc] initWithEffect:nil];
        _blurView.backgroundColor = [UIColor clearColor];
        _blurView.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:_blurView];

        _titleLabel = [[UILabel alloc] init];
        _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
        _titleLabel.textColor = [UIColor secondaryLabelColor];
        _titleLabel.numberOfLines = 1;
        _titleLabel.hidden = YES;
        [_blurView.contentView addSubview:_titleLabel];

        _stateLabel = [[UILabel alloc] init];
        _stateLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _stateLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightMedium];
        _stateLabel.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.72];
        _stateLabel.numberOfLines = 0;
        _stateLabel.textAlignment = NSTextAlignmentCenter;
        [_blurView.contentView addSubview:_stateLabel];

        _scrollView = [[UIScrollView alloc] init];
        _scrollView.translatesAutoresizingMaskIntoConstraints = NO;
        _scrollView.showsVerticalScrollIndicator = NO;
        [_blurView.contentView addSubview:_scrollView];

        _stackView = [[UIStackView alloc] init];
        _stackView.axis = UILayoutConstraintAxisVertical;
        _stackView.spacing = 2;
        _stackView.translatesAutoresizingMaskIntoConstraints = NO;
        [_scrollView addSubview:_stackView];

        [NSLayoutConstraint activateConstraints:@[
            [_blurView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
            [_blurView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
            [_blurView.topAnchor constraintEqualToAnchor:self.topAnchor],
            [_blurView.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],

            [_titleLabel.leadingAnchor constraintEqualToAnchor:_blurView.contentView.leadingAnchor constant:18],
            [_titleLabel.trailingAnchor constraintEqualToAnchor:_blurView.contentView.trailingAnchor constant:-18],
            [_titleLabel.topAnchor constraintEqualToAnchor:_blurView.contentView.topAnchor constant:12],

            [_stateLabel.leadingAnchor constraintEqualToAnchor:_blurView.contentView.leadingAnchor constant:24],
            [_stateLabel.trailingAnchor constraintEqualToAnchor:_blurView.contentView.trailingAnchor constant:-24],
            [_stateLabel.centerYAnchor constraintEqualToAnchor:_blurView.contentView.centerYAnchor],

            [_scrollView.leadingAnchor constraintEqualToAnchor:_blurView.contentView.leadingAnchor],
            [_scrollView.trailingAnchor constraintEqualToAnchor:_blurView.contentView.trailingAnchor],
            [_scrollView.topAnchor constraintEqualToAnchor:_blurView.contentView.topAnchor],
            [_scrollView.bottomAnchor constraintEqualToAnchor:_blurView.contentView.bottomAnchor],

            [_stackView.leadingAnchor constraintEqualToAnchor:_scrollView.contentLayoutGuide.leadingAnchor],
            [_stackView.trailingAnchor constraintEqualToAnchor:_scrollView.contentLayoutGuide.trailingAnchor],
            [_stackView.topAnchor constraintEqualToAnchor:_scrollView.contentLayoutGuide.topAnchor],
            [_stackView.bottomAnchor constraintEqualToAnchor:_scrollView.contentLayoutGuide.bottomAnchor],
            [_stackView.widthAnchor constraintEqualToAnchor:_scrollView.frameLayoutGuide.widthAnchor],
        ]];

        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(reloadFromManager) name:YTMULyricsDidUpdateNotification object:nil];

        // Weak-proxy target: a CADisplayLink retains its target, the run loop
        // retains the link, so a direct `self` here is a cycle that kept every
        // instance alive forever (one leak per lyrics-panel open), each one
        // still rebuilding its line stack on every lyrics update.
        _displayLink = [CADisplayLink displayLinkWithTarget:[YTMUWeakProxy proxyWithTarget:self]
                                                   selector:@selector(displayLinkTick:)];
        _displayLink.preferredFramesPerSecond = 30;
        _displayLink.paused = YES;
        [_displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self.displayLink invalidate];
}

- (void)setHidden:(BOOL)hidden {
    BOOL wasHidden = self.hidden;
    [super setHidden:hidden];
    [self updateDisplayLinkState];
    if (wasHidden && !hidden) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self reloadFromManager];
        });
    }
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    [self updateDisplayLinkState];
    if (self.window) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self reloadFromManager];
        });
    }
}

- (BOOL)ytmu_isEffectivelyVisible {
    if (self.hidden || self.window == nil || self.alpha <= 0.01) return NO;
    UIView *view = self.superview;
    while (view) {
        if (view.hidden || view.alpha <= 0.01) return NO;
        view = view.superview;
    }
    return YES;
}

- (void)updateDisplayLinkState {
    self.displayLink.paused = ![self ytmu_isEffectivelyVisible];
}

- (void)displayLinkTick:(CADisplayLink *)displayLink {
    if (![self ytmu_isEffectivelyVisible]) {
        displayLink.paused = YES;
        return;
    }
    [self updatePlaybackTimeMs:[self currentPlaybackTimeMs]];
}

- (CGFloat)baseFontSize {
    CGFloat pointSize = (CGFloat)YTMULyricsSettingsInteger(@"lyricsFontPointSize", 0);
    if (pointSize > 0.0) return MIN(38.0, MAX(12.0, pointSize));
    NSString *size = YTMULyricsSettingsString(@"lyricsFontSize", @"small");
    if ([size isEqualToString:@"large"]) return 33;
    if ([size isEqualToString:@"medium"]) return 27;
    return 22;
}

- (NSTimeInterval)timelineEndMs {
    NSTimeInterval end = 0;
    for (YTMULyricLineView *line in self.lineViews ?: @[]) {
        NSTimeInterval duration = isfinite(line.durationMs) && line.durationMs > 0 ? line.durationMs : 0;
        end = MAX(end, line.timeInMs + duration);
    }
    YTMULyricsResult *result = [YTMULyricsManager sharedManager].currentResult;
    for (YTMULyricLine *line in result.lines ?: @[]) {
        NSTimeInterval duration = isfinite(line.durationMs) && line.durationMs > 0 ? line.durationMs : 0;
        end = MAX(end, line.timeInMs + duration);
    }
    return end;
}

- (NSTimeInterval)normalizedPlaybackTimeMsForRawTime:(NSTimeInterval)rawTime
                                           duration:(NSTimeInterval)duration
                                      timelineEndMs:(NSTimeInterval)timelineEndMs {
    if (!isfinite(rawTime) || rawTime < 0) return -1;
    if (timelineEndMs > 1000.0) {
        NSTimeInterval timelineSeconds = timelineEndMs / 1000.0;
        if (rawTime <= timelineSeconds * 1.5 && rawTime * 1000.0 <= timelineEndMs * 1.5) return rawTime * 1000.0;
        if (rawTime <= timelineEndMs * 1.5) return rawTime;
    }
    if (isfinite(duration) && duration > 0) {
        if (duration > 10000.0) {
            NSTimeInterval durationSeconds = duration / 1000.0;
            if (rawTime <= durationSeconds * 1.5) return rawTime * 1000.0;
            if (rawTime <= duration * 1.5) return rawTime;
        }
        if (rawTime > duration * 1.5 && rawTime <= duration * 1500.0) return rawTime;
    }
    return rawTime * 1000.0;
}

- (NSTimeInterval)currentPlaybackTimeMs {
    if (self.playerViewController) {
        [[YTMULyricsPlaybackState sharedState] notePlayerViewController:self.playerViewController];
        @try {
            NSTimeInterval playerTime = self.playerViewController.currentVideoMediaTime;
            NSTimeInterval duration = self.playerViewController.currentVideoTotalMediaTime;
            YTMULyricsResult *result = [YTMULyricsManager sharedManager].currentResult;
            if ((!isfinite(duration) || duration <= 0) && result.duration > 0) duration = result.duration;
            NSTimeInterval timeMs = [self normalizedPlaybackTimeMsForRawTime:playerTime
                                                                    duration:duration
                                                               timelineEndMs:[self timelineEndMs]];
            if (timeMs >= 0) {
                [[YTMULyricsPlaybackState sharedState] notePlaybackTimeMs:timeMs];
                return timeMs;
            }
        } @catch (__unused NSException *exception) {
        }
    }

    return [[YTMULyricsPlaybackState sharedState] currentPlaybackTimeMs];
}

- (BOOL)hasCompleteRomanizationForLines:(NSArray<YTMULyricLine *> *)lines {
    BOOL needsRomanization = NO;
    NSString *sourceLanguage = @"auto";
    for (YTMULyricLine *line in lines) {
        if ([YTMULyricsTextProcessor hasJapaneseKana:line.text ?: @""]) {
            sourceLanguage = @"ja";
            break;
        }
    }
    for (YTMULyricLine *line in lines) {
        NSString *text = [line.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (![YTMULyricsTextProcessor needsRomanizationForText:text preferredLanguage:sourceLanguage]) continue;
        needsRomanization = YES;
        if (![line.romanizedText stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].length) {
            return NO;
        }
    }
    return needsRomanization;
}

- (BOOL)hasCompleteRomanizationForResult:(YTMULyricsResult *)result {
    NSArray<NSString *> *sourceLines = result.lineTexts ?: @[];
    BOOL needsRomanization = NO;
    NSString *sourceLanguage = @"auto";
    for (NSString *line in sourceLines) {
        if ([YTMULyricsTextProcessor hasJapaneseKana:line ?: @""]) {
            sourceLanguage = @"ja";
            break;
        }
    }
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

- (NSString *)romanizedLineForResult:(YTMULyricsResult *)result index:(NSUInteger)index fallbackLine:(YTMULyricLine *)line {
    if (index < result.romanizedLineTexts.count) return result.romanizedLineTexts[index] ?: @"";
    return line.romanizedText ?: @"";
}

- (NSArray<NSString *> *)emptyLineStates {
    NSString *mode = YTMULyricsSettingsString(@"lyricsDefaultText", @"♪");
    if ([mode isEqualToString:@"dots"]) return @[@".", @"..", @"..."];
    if ([mode isEqualToString:@"bullets"]) return @[@"•", @"••", @"•••"];
    if ([mode isEqualToString:@"dash"]) return @[@"———"];
    if ([mode isEqualToString:@"space"]) return @[@" "];
    return @[@"♪"];
}

- (NSString *)textForEmptyLineAtTime:(NSTimeInterval)timeMs line:(YTMULyricLine *)line {
    NSArray *states = [self emptyLineStates];
    if (states.count <= 1 || !isfinite(line.durationMs) || line.durationMs <= 0) return states.firstObject ?: @"";
    CGFloat progress = MIN(1, MAX(0, (timeMs - line.timeInMs) / line.durationMs));
    NSUInteger idx = MIN(states.count - 1, (NSUInteger)floor((states.count - 1) * progress));
    return states[idx];
}

- (NSString *)nowPlayingTitleForManager:(YTMULyricsManager *)manager {
    YTMULyricsSearchInfo *info = manager.lastSearchInfo;
    NSString *title = [info.title stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *artist = [info.artist stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (artist.length && title.length) return [NSString stringWithFormat:@"%@ · %@", artist, title];
    if (title.length) return title;
    if (artist.length) return artist;
    return manager.activeVideoId.length ? manager.activeVideoId : YTMUSyncedLyricsLocalized(@"SYNCED_LYRICS", @"Synced lyrics");
}

- (void)clearLineViews {
    for (UIView *view in self.stackView.arrangedSubviews) {
        [self.stackView removeArrangedSubview:view];
        [view removeFromSuperview];
    }
    self.lineViews = @[];
    self.activeIndex = -1;
}

- (void)applyBaseFontSizeToExistingLines:(CGFloat)base {
    if (!self.lineViews.count) return;

    [UIView performWithoutAnimation:^{
        NSInteger activeIndex = self.activeIndex;
        for (YTMULyricLineView *lineView in self.lineViews) {
            BOOL active = (NSInteger)lineView.index == activeIndex;
            lineView.mainLabel.font = active ? [UIFont boldSystemFontOfSize:base] : [UIFont systemFontOfSize:base weight:UIFontWeightRegular];
            lineView.romanLabel.font = [UIFont italicSystemFontOfSize:base * 0.78];
            lineView.translationLabel.font = [UIFont systemFontOfSize:base * 0.88 weight:UIFontWeightRegular];
            [lineView updateKaraokeProgress:active ? 1.0 : 0.0 active:active];
        }
        [self setNeedsLayout];
        [self layoutIfNeeded];
        [self.scrollView layoutIfNeeded];
        [self.stackView layoutIfNeeded];
    }];
    [self updatePlaybackTimeMs:[self currentPlaybackTimeMs] animated:NO];
}

- (void)reloadFromManager {
    [self updateDisplayLinkState];
    // Nothing to show when we are not in a window; -didMoveToWindow reloads
    // the moment we are. Skipping here is what keeps a hidden-but-retained
    // instance from rebuilding its whole line stack on every lyrics update.
    if (!self.window) return;

    YTMULyricsManager *manager = [YTMULyricsManager sharedManager];
    self.titleLabel.text = [self nowPlayingTitleForManager:manager];
    CGFloat base = [self baseFontSize];
    NSString *contentSignature = [NSString stringWithFormat:@"%ld|%p|%p|%@|%@|%@|%@|%@|%@|%@",
                           (long)manager.state,
                           (void *)manager.currentResult,
                           (void *)manager.translatedLines,
                           YTMULyricsSettingsString(@"lyricsConvertChinese", @"disabled"),
                           YTMULyricsSettingsString(@"lyricsLineEffect", @"fancy"),
                           YTMULyricsSettingsString(@"lyricsDefaultText", @"♪"),
                           YTMULyricsSettingsBool(@"lyricsRomanization", YES) ? @"1" : @"0",
                           YTMULyricsSettingsBool(@"lyricsShowTimeCodes", NO) ? @"1" : @"0",
                           YTMULyricsSettingsBool(@"lyricsFocusBlur", YES) ? @"1" : @"0",
                           manager.lastErrorMessage ?: @""];
    NSString *signature = [NSString stringWithFormat:@"%@|%.0f", contentSignature, base];
    if ([signature isEqualToString:self.lastReloadSignature]) {
        [self updatePlaybackTimeMs:[self currentPlaybackTimeMs] animated:NO];
        return;
    }
    if ([contentSignature isEqualToString:self.lastReloadContentSignature] &&
        self.lineViews.count &&
        manager.currentResult.hasText) {
        self.lastReloadSignature = signature;
        [self applyBaseFontSizeToExistingLines:base];
        return;
    }
    self.lastReloadSignature = signature;
    self.lastReloadContentSignature = contentSignature;

    [self clearLineViews];
    self.scrollView.hidden = YES;
    self.stateLabel.hidden = NO;

    if (manager.state == YTMULyricsFetchStateFetching && !manager.currentResult.hasText) {
        self.stateLabel.text = YTMUSyncedLyricsLocalized(@"LYRICS_STATE_SEARCHING", @"Searching lyrics...");
        return;
    }
    if (manager.state == YTMULyricsFetchStateError) {
        self.stateLabel.text = manager.lastErrorMessage.length ? manager.lastErrorMessage : YTMUSyncedLyricsLocalized(@"LYRICS_STATE_NO_LYRICS", @"No lyrics found");
        return;
    }
    YTMULyricsResult *result = manager.currentResult;
    if (!result.hasText) {
        self.stateLabel.text = YTMUSyncedLyricsLocalized(@"LYRICS_STATE_NO_LYRICS", @"No lyrics found");
        return;
    }

    self.scrollView.hidden = NO;
    self.stateLabel.hidden = YES;
    NSString *convertMode = YTMULyricsSettingsString(@"lyricsConvertChinese", @"disabled");
    BOOL romanizationEnabled = YTMULyricsSettingsBool(@"lyricsRomanization", YES);
    BOOL showTimeCodes = YTMULyricsSettingsBool(@"lyricsShowTimeCodes", NO);
    NSArray<NSString *> *translations = manager.translatedLines ?: @[];
    BOOL showRomanization = romanizationEnabled && [self hasCompleteRomanizationForResult:result];

    NSMutableArray<YTMULyricLineView *> *lineViews = [NSMutableArray array];
    NSArray<YTMULyricLine *> *synced = result.lines;
    NSArray<NSString *> *plain = result.isSynced ? @[] : result.lineTexts;
    NSUInteger count = result.isSynced ? synced.count : plain.count;
    // Each line is a UIControl with four labels and a dozen constraints,
    // built synchronously. Providers reject absurd line counts already;
    // this is the last line of defence for the main thread.
    static const NSUInteger kMaxRenderedLines = 600;
    if (count > kMaxRenderedLines) {
        YTMULyricsLog(@"synced view truncating %lu lines to %lu", (unsigned long)count, (unsigned long)kMaxRenderedLines);
        count = kMaxRenderedLines;
    }
    for (NSUInteger i = 0; i < count; i++) {
        YTMULyricLine *line = result.isSynced ? synced[i] : [YTMULyricLine lineWithTime:@"" timeInMs:0 durationMs:0 text:plain[i]];
        NSString *text = line.text ?: @"";
        text = [YTMULyricsTextProcessor convertChineseText:text mode:convertMode];

        YTMULyricLineView *lineView = [[YTMULyricLineView alloc] init];
        lineView.index = i;
        lineView.timeInMs = line.timeInMs;
        lineView.durationMs = line.durationMs;
        lineView.timeLabel.hidden = !(showTimeCodes && line.time.length);
        lineView.timeLabel.text = showTimeCodes && line.time.length ? [NSString stringWithFormat:@"[%@]", line.time] : @"";
        lineView.mainLabel.font = [UIFont systemFontOfSize:base weight:UIFontWeightRegular];
        lineView.mainLabel.textColor = [UIColor whiteColor];
        lineView.mainText = text.length ? text : [self emptyLineStates].firstObject;
        lineView.mainLabel.text = lineView.mainText;
        lineView.romanLabel.font = [UIFont italicSystemFontOfSize:base * 0.78];
        NSString *roman = showRomanization ? [self romanizedLineForResult:result index:i fallbackLine:line] : @"";
        lineView.romanText = [[YTMULyricsTextProcessor simplifyUnicode:roman] isEqualToString:[YTMULyricsTextProcessor simplifyUnicode:text]] ? @"" : roman;
        lineView.romanLabel.text = lineView.romanText;
        lineView.translationLabel.font = [UIFont systemFontOfSize:base * 0.88 weight:UIFontWeightRegular];
        NSString *translation = i < translations.count ? translations[i] : @"";
        translation = [YTMULyricsTextProcessor convertChineseText:translation mode:convertMode];
        lineView.translationText = [[YTMULyricsTextProcessor simplifyUnicode:translation] isEqualToString:[YTMULyricsTextProcessor simplifyUnicode:text]] ? @"" : translation;
        lineView.translationLabel.text = lineView.translationText;
        [lineView addTarget:self action:@selector(lineTapped:) forControlEvents:UIControlEventTouchUpInside];
        [lineView setActive:NO distance:NSIntegerMax focusBlur:NO];
        [self.stackView addArrangedSubview:lineView];
        [lineViews addObject:lineView];
    }

    self.lineViews = lineViews;
    [self setNeedsLayout];
    [self layoutIfNeeded];
    [self.scrollView layoutIfNeeded];
    [self.stackView layoutIfNeeded];
    [self updatePlaybackTimeMs:[self currentPlaybackTimeMs] animated:NO];
}

- (void)lineTapped:(YTMULyricLineView *)sender {
    if (!self.playerViewController || sender.timeInMs <= 0) return;
    // Display highlights a line when currentTime + offset >= line.timeInMs (see
    // updatePlaybackTimeMs:animated:, which does timeMs += lyricsTimingOffsetMs).
    // To land on the tapped line, seek to the moment it becomes current, i.e.
    // line.timeInMs - offset. Read the offset the same way so they stay in sync.
    NSTimeInterval offsetMs = (NSTimeInterval)YTMULyricsSettingsInteger(@"lyricsTimingOffsetMs", 0);
    NSTimeInterval seekMs = sender.timeInMs - offsetMs + 10;
    if (seekMs < 0) seekMs = 0;
    [self.playerViewController seekToTime:seekMs / 1000.0];
}

- (void)updatePlaybackTimeMs:(NSTimeInterval)timeMs {
    [self updatePlaybackTimeMs:timeMs animated:YES];
}

- (void)updatePlaybackTimeMs:(NSTimeInterval)timeMs animated:(BOOL)animated {
    if (![self ytmu_isEffectivelyVisible] || !self.lineViews.count) {
        [self updateDisplayLinkState];
        return;
    }
    timeMs += (NSTimeInterval)YTMULyricsSettingsInteger(@"lyricsTimingOffsetMs", 0);
    if (timeMs < 0) timeMs = 0;
    NSTimeInterval timelineEnd = [self timelineEndMs];
    if (timelineEnd > 1000.0 && timeMs > timelineEnd * 1.5 && timeMs / 1000.0 <= timelineEnd * 1.5) {
        timeMs /= 1000.0;
    }
    NSInteger current = -1;
    for (NSUInteger i = 0; i < self.lineViews.count; i++) {
        YTMULyricLineView *line = self.lineViews[i];
        if (line.timeInMs <= timeMs && timeMs < line.timeInMs + MAX(line.durationMs, 800)) {
            current = (NSInteger)i;
            break;
        }
        if (line.timeInMs <= timeMs) current = (NSInteger)i;
    }
    if (current < 0) current = 0;
    if (current == self.activeIndex) {
        YTMULyricLineView *line = self.lineViews[current];
        if (!line.mainLabel.text.length || [line.mainLabel.text isEqualToString:[self emptyLineStates].firstObject]) {
            YTMULyricsResult *result = [YTMULyricsManager sharedManager].currentResult;
            if (current < (NSInteger)result.lines.count && !result.lines[current].text.length) {
                line.mainText = [self textForEmptyLineAtTime:timeMs line:result.lines[current]];
            }
        }
        CGFloat progress = line.durationMs > 0 ? (CGFloat)((timeMs - line.timeInMs) / line.durationMs) : 1.0;
        [line updateKaraokeProgress:progress active:YES];
        return;
    }

    self.activeIndex = current;
    BOOL focusBlur = YTMULyricsSettingsBool(@"lyricsFocusBlur", YES);
    void (^stateUpdates)(void) = ^{
        for (NSUInteger i = 0; i < self.lineViews.count; i++) {
            BOOL isActive = (NSInteger)i == current;
            NSInteger distance = (NSInteger)i - current;
            [self.lineViews[i] setActive:isActive distance:distance focusBlur:focusBlur];
        }
    };
    if (animated) {
        [UIView animateWithDuration:0.25 animations:stateUpdates];
    } else {
        [UIView performWithoutAnimation:stateUpdates];
    }

    for (NSUInteger i = 0; i < self.lineViews.count; i++) {
        YTMULyricLineView *line = self.lineViews[i];
        CGFloat progress = 0.0;
        if ((NSInteger)i == current && line.durationMs > 0) {
            progress = (CGFloat)((timeMs - line.timeInMs) / line.durationMs);
        }
        [line updateKaraokeProgress:progress active:(NSInteger)i == current];
    }

    CGRect target = [self.scrollView convertRect:self.lineViews[current].bounds fromView:self.lineViews[current]];
    CGFloat offsetY = MAX(0, CGRectGetMidY(target) - self.scrollView.bounds.size.height * 0.48);
    CGFloat maxOffset = MAX(0, self.scrollView.contentSize.height - self.scrollView.bounds.size.height);
    CGPoint contentOffset = CGPointMake(0, MIN(offsetY, maxOffset));
    if (!animated) {
        [UIView performWithoutAnimation:^{
            self.scrollView.contentOffset = contentOffset;
        }];
        return;
    }
    [UIView animateWithDuration:0.45
                          delay:0
                        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveEaseInOut
                     animations:^{
        self.scrollView.contentOffset = contentOffset;
    } completion:nil];
}

@end
