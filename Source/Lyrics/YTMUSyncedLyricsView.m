#import "YTMUSyncedLyricsView.h"
#import "YTMULyricsManager.h"
#import "YTMULyricsPlaybackState.h"
#import "YTMULyricsTextProcessor.h"
#import "../Headers/YTPlayerViewController.h"
#import <MediaPlayer/MediaPlayer.h>

@interface YTMULyricLineView : UIControl
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
        _mainLabel = [[UILabel alloc] init];
        _romanLabel = [[UILabel alloc] init];
        _translationLabel = [[UILabel alloc] init];
        for (UILabel *label in @[_mainLabel, _romanLabel, _translationLabel]) {
            label.numberOfLines = 0;
            label.translatesAutoresizingMaskIntoConstraints = NO;
            [self addSubview:label];
        }
        _romanLabel.textColor = [UIColor secondaryLabelColor];
        _romanLabel.font = [UIFont italicSystemFontOfSize:16];
        _translationLabel.textColor = [UIColor labelColor];
        _translationLabel.alpha = 0.82;

        [NSLayoutConstraint activateConstraints:@[
            [_mainLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:18],
            [_mainLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-18],
            [_mainLabel.topAnchor constraintEqualToAnchor:self.topAnchor constant:9],
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

- (void)setActive:(BOOL)active effect:(NSString *)effect {
    CGFloat activeAlpha = 1.0;
    CGFloat inactiveAlpha = [effect isEqualToString:@"focus"] ? 0.22 : 0.36;
    self.alpha = active ? activeAlpha : inactiveAlpha;
    self.mainLabel.font = active ? [UIFont boldSystemFontOfSize:self.mainLabel.font.pointSize] : [UIFont systemFontOfSize:self.mainLabel.font.pointSize weight:UIFontWeightRegular];
    if ([effect isEqualToString:@"scale"]) {
        self.transform = active ? CGAffineTransformMakeScale(1.08, 1.08) : CGAffineTransformIdentity;
    } else if ([effect isEqualToString:@"offset"]) {
        self.transform = active ? CGAffineTransformMakeTranslation(18, 0) : CGAffineTransformIdentity;
    } else {
        self.transform = CGAffineTransformIdentity;
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
    NSUInteger split = active ? MIN(text.length, (NSUInteger)ceil((CGFloat)text.length * clamped)) : 0;
    NSMutableAttributedString *out = [[NSMutableAttributedString alloc] initWithString:text attributes:@{
        NSFontAttributeName: font,
        NSForegroundColorAttributeName: active ? inactiveColor : activeColor,
    }];
    if (active && split > 0) {
        [out addAttribute:NSForegroundColorAttributeName value:activeColor range:NSMakeRange(0, split)];
    }
    return out;
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
                                                       progress:progress
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
@end

@implementation YTMUSyncedLyricsView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.hidden = YES;
        self.clipsToBounds = YES;
        self.layer.cornerRadius = 16;
        self.layer.cornerCurve = kCACornerCurveContinuous;

        UIBlurEffect *blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterialDark];
        _blurView = [[UIVisualEffectView alloc] initWithEffect:blur];
        _blurView.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:_blurView];

        _titleLabel = [[UILabel alloc] init];
        _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
        _titleLabel.textColor = [UIColor secondaryLabelColor];
        _titleLabel.numberOfLines = 1;
        [_blurView.contentView addSubview:_titleLabel];

        _stateLabel = [[UILabel alloc] init];
        _stateLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _stateLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightMedium];
        _stateLabel.textColor = [UIColor labelColor];
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
            [_scrollView.topAnchor constraintEqualToAnchor:_titleLabel.bottomAnchor constant:6],
            [_scrollView.bottomAnchor constraintEqualToAnchor:_blurView.contentView.bottomAnchor constant:-8],

            [_stackView.leadingAnchor constraintEqualToAnchor:_scrollView.contentLayoutGuide.leadingAnchor],
            [_stackView.trailingAnchor constraintEqualToAnchor:_scrollView.contentLayoutGuide.trailingAnchor],
            [_stackView.topAnchor constraintEqualToAnchor:_scrollView.contentLayoutGuide.topAnchor],
            [_stackView.bottomAnchor constraintEqualToAnchor:_scrollView.contentLayoutGuide.bottomAnchor],
            [_stackView.widthAnchor constraintEqualToAnchor:_scrollView.frameLayoutGuide.widthAnchor],
        ]];

        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(reloadFromManager) name:YTMULyricsDidUpdateNotification object:nil];

        _displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(displayLinkTick:)];
        _displayLink.preferredFramesPerSecond = 10;
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
    [super setHidden:hidden];
    [self updateDisplayLinkState];
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    [self updateDisplayLinkState];
}

- (void)updateDisplayLinkState {
    self.displayLink.paused = self.hidden || self.window == nil;
}

- (void)displayLinkTick:(CADisplayLink *)displayLink {
    [self updatePlaybackTimeMs:[self currentPlaybackTimeMs]];
}

- (CGFloat)baseFontSize {
    CGFloat pointSize = (CGFloat)YTMULyricsSettingsInteger(@"lyricsFontPointSize", 0);
    if (pointSize > 0.0) return MIN(38.0, MAX(16.0, pointSize));
    NSString *size = YTMULyricsSettingsString(@"lyricsFontSize", @"small");
    if ([size isEqualToString:@"large"]) return 33;
    if ([size isEqualToString:@"medium"]) return 27;
    return 22;
}

- (NSTimeInterval)currentPlaybackTimeMs {
    if (self.playerViewController) {
        [[YTMULyricsPlaybackState sharedState] notePlayerViewController:self.playerViewController];
        @try {
            NSTimeInterval playerTime = self.playerViewController.currentVideoMediaTime;
            if (isfinite(playerTime) && playerTime >= 0) {
                NSTimeInterval timeMs = playerTime * 1000.0;
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
    for (YTMULyricLine *line in lines) {
        NSString *text = [line.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (![YTMULyricsTextProcessor hasRomanizableText:text]) continue;
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

- (NSString *)romanizedLineForResult:(YTMULyricsResult *)result index:(NSUInteger)index fallbackLine:(YTMULyricLine *)line {
    if (index < result.romanizedLineTexts.count) return result.romanizedLineTexts[index] ?: @"";
    return line.romanizedText ?: @"";
}

- (NSString *)lineEffect {
    return YTMULyricsSettingsString(@"lyricsLineEffect", @"fancy");
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

- (void)clearLineViews {
    for (UIView *view in self.stackView.arrangedSubviews) {
        [self.stackView removeArrangedSubview:view];
        [view removeFromSuperview];
    }
    self.lineViews = @[];
    self.activeIndex = -1;
}

- (void)reloadFromManager {
    [self updateDisplayLinkState];

    YTMULyricsManager *manager = [YTMULyricsManager sharedManager];
    self.titleLabel.text = manager.currentResult.sourceName.length
        ? [NSString stringWithFormat:@"%@ · %@", manager.currentResult.sourceName, manager.currentResult.title.length ? manager.currentResult.title : manager.activeVideoId]
        : @"Synced lyrics";

    [self clearLineViews];
    self.scrollView.hidden = YES;
    self.stateLabel.hidden = NO;

    if (manager.state == YTMULyricsFetchStateFetching) {
        self.stateLabel.text = @"Searching lyrics...";
        return;
    }
    if (manager.state == YTMULyricsFetchStateError) {
        self.stateLabel.text = manager.lastErrorMessage.length ? manager.lastErrorMessage : @"No lyrics found";
        return;
    }
    YTMULyricsResult *result = manager.currentResult;
    if (!result.hasText) {
        self.stateLabel.text = @"No lyrics found";
        return;
    }

    self.scrollView.hidden = NO;
    self.stateLabel.hidden = YES;
    CGFloat base = [self baseFontSize];
    NSString *convertMode = YTMULyricsSettingsString(@"lyricsConvertChinese", @"disabled");
    BOOL romanizationEnabled = YTMULyricsSettingsBool(@"lyricsRomanization", YES);
    BOOL showTimeCodes = YTMULyricsSettingsBool(@"lyricsShowTimeCodes", NO);
    NSArray<NSString *> *translations = manager.translatedLines ?: @[];
    BOOL showRomanization = romanizationEnabled && [self hasCompleteRomanizationForResult:result];

    NSMutableArray<YTMULyricLineView *> *lineViews = [NSMutableArray array];
    NSArray<YTMULyricLine *> *synced = result.lines;
    NSArray<NSString *> *plain = result.isSynced ? @[] : result.lineTexts;
    NSUInteger count = result.isSynced ? synced.count : plain.count;
    for (NSUInteger i = 0; i < count; i++) {
        YTMULyricLine *line = result.isSynced ? synced[i] : [YTMULyricLine lineWithTime:@"" timeInMs:0 durationMs:0 text:plain[i]];
        NSString *text = line.text ?: @"";
        text = [YTMULyricsTextProcessor convertChineseText:text mode:convertMode];
        if (showTimeCodes && line.time.length) text = [NSString stringWithFormat:@"[%@] %@", line.time, text];

        YTMULyricLineView *lineView = [[YTMULyricLineView alloc] init];
        lineView.index = i;
        lineView.timeInMs = line.timeInMs;
        lineView.durationMs = line.durationMs;
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
        [lineView setActive:NO effect:[self lineEffect]];
        [self.stackView addArrangedSubview:lineView];
        [lineViews addObject:lineView];
    }

    if (manager.translationAttribution.length) {
        UILabel *label = [[UILabel alloc] init];
        label.numberOfLines = 0;
        label.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
        label.textColor = [UIColor secondaryLabelColor];
        label.text = manager.translationAttribution;
        label.textAlignment = NSTextAlignmentLeft;
        UIView *wrap = [[UIView alloc] init];
        label.translatesAutoresizingMaskIntoConstraints = NO;
        [wrap addSubview:label];
        [NSLayoutConstraint activateConstraints:@[
            [label.leadingAnchor constraintEqualToAnchor:wrap.leadingAnchor constant:18],
            [label.trailingAnchor constraintEqualToAnchor:wrap.trailingAnchor constant:-18],
            [label.topAnchor constraintEqualToAnchor:wrap.topAnchor constant:14],
            [label.bottomAnchor constraintEqualToAnchor:wrap.bottomAnchor constant:-18],
        ]];
        [self.stackView addArrangedSubview:wrap];
    }

    self.lineViews = lineViews;
    [self updatePlaybackTimeMs:[self currentPlaybackTimeMs]];
}

- (void)lineTapped:(YTMULyricLineView *)sender {
    if (!self.playerViewController || sender.timeInMs <= 0) return;
    [self.playerViewController seekToTime:(sender.timeInMs + 10) / 1000.0];
}

- (void)updatePlaybackTimeMs:(NSTimeInterval)timeMs {
    if (self.hidden || !self.lineViews.count) return;
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
    NSString *effect = [self lineEffect];
    [UIView animateWithDuration:0.25 animations:^{
        for (NSUInteger i = 0; i < self.lineViews.count; i++) {
            [self.lineViews[i] setActive:(NSInteger)i == current effect:effect];
        }
    }];

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
    [self.scrollView setContentOffset:CGPointMake(0, MIN(offsetY, maxOffset)) animated:YES];
}

@end
