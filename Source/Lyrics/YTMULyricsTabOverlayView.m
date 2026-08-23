#import "YTMULyricsTabOverlayView.h"
#import "YTMULyricsPanelSupport.h"
#import <MediaPlayer/MediaPlayer.h>
#import <objc/runtime.h>
#import "YTMULyricsManager.h"
#import "YTMULyricsPlaybackState.h"
#import "YTMULyricsTextProcessor.h"
#import "../Translation/YTMUTranslationTypes.h"

@implementation YTMULyricsTabOverlayView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.clipsToBounds = YES;
        self.userInteractionEnabled = YES;
        self.backgroundColor = [UIColor colorWithRed:0.035 green:0.095 blue:0.135 alpha:0.99];

        self.artworkImageView = [[UIImageView alloc] initWithFrame:CGRectZero];
        self.artworkImageView.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.10];
        self.artworkImageView.contentMode = UIViewContentModeScaleAspectFill;
        self.artworkImageView.clipsToBounds = YES;
        self.artworkImageView.layer.cornerRadius = 8.0;
        self.artworkImageView.layer.cornerCurve = kCACornerCurveContinuous;
        [self addSubview:self.artworkImageView];

        self.nowPlayingTitleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        self.nowPlayingTitleLabel.backgroundColor = [UIColor clearColor];
        self.nowPlayingTitleLabel.font = [UIFont systemFontOfSize:18.0 weight:UIFontWeightBold];
        self.nowPlayingTitleLabel.textColor = [UIColor whiteColor];
        self.nowPlayingTitleLabel.numberOfLines = 1;
        self.nowPlayingTitleLabel.adjustsFontSizeToFitWidth = YES;
        self.nowPlayingTitleLabel.minimumScaleFactor = 0.72;
        [self addSubview:self.nowPlayingTitleLabel];

        self.nowPlayingArtistLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        self.nowPlayingArtistLabel.backgroundColor = [UIColor clearColor];
        self.nowPlayingArtistLabel.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightSemibold];
        self.nowPlayingArtistLabel.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.66];
        self.nowPlayingArtistLabel.numberOfLines = 1;
        self.nowPlayingArtistLabel.adjustsFontSizeToFitWidth = YES;
        self.nowPlayingArtistLabel.minimumScaleFactor = 0.76;
        [self addSubview:self.nowPlayingArtistLabel];

        self.menuButton = [UIButton buttonWithType:UIButtonTypeSystem];
        UIImage *menuImage = nil;
        if (@available(iOS 13.0, *)) menuImage = [UIImage systemImageNamed:@"ellipsis"];
        if (menuImage) {
            [self.menuButton setImage:menuImage forState:UIControlStateNormal];
        } else {
            [self.menuButton setTitle:@"..." forState:UIControlStateNormal];
            self.menuButton.titleLabel.font = [UIFont systemFontOfSize:18.0 weight:UIFontWeightBold];
        }
        self.menuButton.tintColor = [UIColor whiteColor];
        self.menuButton.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.12];
        self.menuButton.layer.cornerRadius = 17.0;
        self.menuButton.clipsToBounds = YES;
        [self.menuButton addTarget:self action:@selector(ytmu_presentLyricsMenu:) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:self.menuButton];

        self.headerSeparatorView = [[UIView alloc] initWithFrame:CGRectZero];
        self.headerSeparatorView.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.13];
        [self addSubview:self.headerSeparatorView];

        self.sourceScrollView = [[UIScrollView alloc] initWithFrame:CGRectZero];
        self.sourceScrollView.backgroundColor = [UIColor clearColor];
        self.sourceScrollView.showsHorizontalScrollIndicator = NO;
        self.sourceScrollView.alwaysBounceHorizontal = YES;
        self.sourceScrollView.hidden = YES;
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

        self.offsetDecreaseButton = [UIButton buttonWithType:UIButtonTypeSystem];
        self.offsetDecreaseButton.tag = -100;
        [self.offsetDecreaseButton setTitle:@"-0.1s" forState:UIControlStateNormal];
        [self.offsetDecreaseButton addTarget:self action:@selector(ytmu_adjustLyricsTiming:) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:self.offsetDecreaseButton];

        self.offsetLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        self.offsetLabel.textAlignment = NSTextAlignmentCenter;
        self.offsetLabel.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightSemibold];
        self.offsetLabel.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.72];
        self.offsetLabel.userInteractionEnabled = YES;
        UITapGestureRecognizer *resetOffset = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(ytmu_resetLyricsTiming:)];
        [self.offsetLabel addGestureRecognizer:resetOffset];
        [self addSubview:self.offsetLabel];

        self.offsetIncreaseButton = [UIButton buttonWithType:UIButtonTypeSystem];
        self.offsetIncreaseButton.tag = 100;
        [self.offsetIncreaseButton setTitle:@"+0.1s" forState:UIControlStateNormal];
        [self.offsetIncreaseButton addTarget:self action:@selector(ytmu_adjustLyricsTiming:) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:self.offsetIncreaseButton];

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

        for (UIButton *button in @[self.offsetDecreaseButton, self.offsetIncreaseButton, self.fontDecreaseButton, self.fontIncreaseButton]) {
            button.titleLabel.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightBold];
            [button setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
            button.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.12];
            button.layer.cornerRadius = 15.0;
            button.clipsToBounds = YES;
            button.hidden = YES;
        }
        self.offsetLabel.hidden = YES;
        self.fontSizeLabel.hidden = YES;

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

        UISwipeGestureRecognizer *syncedLeft = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(ytmu_cycleLyricsSource:)];
        syncedLeft.direction = UISwipeGestureRecognizerDirectionLeft;
        [self.syncedLyricsView addGestureRecognizer:syncedLeft];
        UISwipeGestureRecognizer *syncedRight = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(ytmu_cycleLyricsSource:)];
        syncedRight.direction = UISwipeGestureRecognizerDirectionRight;
        [self.syncedLyricsView addGestureRecognizer:syncedRight];

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
                                                 selector:@selector(ytmu_handleLyricsSettingsDidChange:)
                                                     name:YTMULyricsSettingsDidChangeNotification
                                                   object:nil];
        [self ytmu_updateSourceButtons];
        [self ytmu_updateNowPlayingHeader];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat sideInset = MAX(24.0, MIN(34.0, self.bounds.size.width * 0.07));
    CGFloat bottomInset = 12.0;
    CGFloat safeTop = 0.0;
    CGFloat safeRight = 0.0;
    if (@available(iOS 11.0, *)) {
        bottomInset += self.safeAreaInsets.bottom;
        safeTop = self.safeAreaInsets.top;
        safeRight = self.safeAreaInsets.right;
    }
    CGFloat attributionHeight = self.attributionLabel.text.length ? 30.0 : 0.0;
    CGFloat headerTop = safeTop + 8.0;
    CGFloat artworkSize = 48.0;
    CGFloat closeReserve = 46.0;
    CGFloat menuSize = 34.0;
    CGFloat menuX = self.bounds.size.width - safeRight - sideInset - closeReserve - menuSize;
    if (menuX < sideInset + artworkSize + 16.0) menuX = self.bounds.size.width - safeRight - sideInset - menuSize;
    self.artworkImageView.frame = CGRectMake(sideInset, headerTop, artworkSize, artworkSize);
    self.menuButton.frame = CGRectMake(menuX, headerTop + 7.0, menuSize, menuSize);

    CGFloat labelX = CGRectGetMaxX(self.artworkImageView.frame) + 14.0;
    CGFloat labelRight = MIN(menuX - 12.0, self.bounds.size.width - safeRight - sideInset);
    CGFloat labelWidth = MAX(80.0, labelRight - labelX);
    self.nowPlayingTitleLabel.frame = CGRectMake(labelX, headerTop + 4.0, labelWidth, 22.0);
    self.nowPlayingArtistLabel.frame = CGRectMake(labelX, CGRectGetMaxY(self.nowPlayingTitleLabel.frame) + 1.0, labelWidth, 19.0);
    self.headerSeparatorView.frame = CGRectMake(sideInset,
                                                CGRectGetMaxY(self.artworkImageView.frame) + 18.0,
                                                self.bounds.size.width - sideInset * 2.0 - safeRight,
                                                1.0 / MAX(1.0, UIScreen.mainScreen.scale));

    self.sourceScrollView.frame = CGRectMake(sideInset, CGRectGetMaxY(self.headerSeparatorView.frame), self.bounds.size.width - sideInset * 2.0, 1.0);
    self.offsetDecreaseButton.frame = CGRectZero;
    self.offsetLabel.frame = CGRectZero;
    self.offsetIncreaseButton.frame = CGRectZero;
    self.fontDecreaseButton.frame = CGRectZero;
    self.fontSizeLabel.frame = CGRectZero;
    self.fontIncreaseButton.frame = CGRectZero;

    CGFloat textY = CGRectGetMaxY(self.headerSeparatorView.frame) + 12.0;
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
    [self ytmu_updateNowPlayingHeader];
    BOOL canDisplayResult = manager.currentResult.hasText &&
                            (manager.state == YTMULyricsFetchStateDone || manager.state == YTMULyricsFetchStateFetching);
    BOOL useSynced = manager.currentResult.isSynced && canDisplayResult;
    self.lyricsTextView.hidden = useSynced;
    self.syncedLyricsView.hidden = !useSynced;
    self.syncedLyricsView.playerViewController = self.playerViewController;
    if (!self.syncedLyricsView.playerViewController) {
        self.syncedLyricsView.playerViewController = [YTMULyricsPlaybackState sharedState].playerViewController;
    }

    NSString *signature = [NSString stringWithFormat:@"%ld|%p|%p|%@|%.0f|%ld|%@|%@|%@|%@|%@|%@",
                           (long)manager.state,
                           (void *)manager.currentResult,
                           (void *)manager.translatedLines,
                           YTMULyricsPageString(@"lyricsPreferredSource", @"auto"),
                           YTMULyricsPageBaseFontSize(),
                           (long)YTMULyricsPageTimingOffsetMs(),
                           YTMULyricsPageString(@"lyricsConvertChinese", @"disabled"),
                           YTMULyricsPageString(@"lyricsLineEffect", @"fancy"),
                           YTMULyricsPageString(@"lyricsDefaultText", @"♪"),
                           YTMULyricsPageBool(@"lyricsRomanization") ? @"1" : @"0",
                           YTMULyricsPageBool(@"lyricsShowTimeCodes") ? @"1" : @"0",
                           manager.translationAttribution ?: @""];
    if ([signature isEqualToString:self.lastRenderSignature]) {
        if (useSynced) [self.syncedLyricsView reloadFromManager];
        return;
    }
    self.lastRenderSignature = signature;

    if (useSynced) {
        [self.syncedLyricsView reloadFromManager];
    } else {
        self.lyricsTextView.attributedText = YTMULyricsPageAttributedText(self.lyricsTextView, @"");
    }
    self.attributionLabel.text = YTMULyricsPageAttributionText();
    [self ytmu_updateSourceButtons];
    [self ytmu_updateFontControls];
    [self ytmu_updateTimingControls];
    [self setNeedsLayout];

    YTMULyricsLog(@"lyrics tab overlay rendered state=%ld source=%@ lines=%lu translated=%lu",
                  (long)manager.state,
                  manager.currentResult.sourceName ?: @"<none>",
                  (unsigned long)manager.displayLineTexts.count,
                  (unsigned long)manager.translatedLines.count);
}

- (void)ytmu_updateFontControls {
    CGFloat size = YTMULyricsPageBaseFontSize();
    self.fontSizeLabel.text = [NSString stringWithFormat:@"%.0f", size];
    self.fontDecreaseButton.enabled = size > 16.0;
    self.fontIncreaseButton.enabled = size < 38.0;
    self.fontDecreaseButton.alpha = self.fontDecreaseButton.enabled ? 1.0 : 0.38;
    self.fontIncreaseButton.alpha = self.fontIncreaseButton.enabled ? 1.0 : 0.38;
}

- (void)ytmu_updateTimingControls {
    NSInteger offset = YTMULyricsPageTimingOffsetMs();
    self.offsetLabel.text = [NSString stringWithFormat:@"%+.1fs", offset / 1000.0];
    self.offsetDecreaseButton.enabled = offset > -10000;
    self.offsetIncreaseButton.enabled = offset < 10000;
    self.offsetDecreaseButton.alpha = self.offsetDecreaseButton.enabled ? 1.0 : 0.38;
    self.offsetIncreaseButton.alpha = self.offsetIncreaseButton.enabled ? 1.0 : 0.38;
}

- (void)ytmu_updateNowPlayingHeader {
    self.nowPlayingTitleLabel.text = YTMULyricsPageNowPlayingTitle();
    self.nowPlayingArtistLabel.text = YTMULyricsPageNowPlayingArtist();
    UIImage *artwork = YTMULyricsPageNowPlayingArtwork(CGSizeMake(96.0, 96.0));
    self.artworkImageView.image = artwork;
    self.artworkImageView.backgroundColor = artwork ? [UIColor clearColor] : [[UIColor whiteColor] colorWithAlphaComponent:0.10];
}

- (UIViewController *)ytmu_presentingViewController {
    UIResponder *responder = self;
    while (responder) {
        if ([responder isKindOfClass:[UIViewController class]]) return (UIViewController *)responder;
        responder = responder.nextResponder;
    }
    UIViewController *controller = UIApplication.sharedApplication.keyWindow.rootViewController;
    while (controller.presentedViewController) controller = controller.presentedViewController;
    return controller;
}

- (UIView *)ytmu_sheetHostView {
    UIViewController *controller = [self ytmu_presentingViewController];
    return controller.view ?: self;
}

- (UIColor *)ytmu_sheetBackgroundColor {
    return [UIColor colorWithRed:0.095 green:0.105 blue:0.120 alpha:0.98];
}

- (UIColor *)ytmu_sheetSeparatorColor {
    return [[UIColor whiteColor] colorWithAlphaComponent:0.075];
}

- (void)ytmu_prepareSheetWithHeight:(CGFloat)height title:(NSString *)title {
    [self ytmu_dismissSheet];
    UIView *host = [self ytmu_sheetHostView];
    UIEdgeInsets safe = UIEdgeInsetsZero;
    if (@available(iOS 11.0, *)) safe = host.safeAreaInsets;
    // 0.5 host-height cap was too tight for the source menu after we
    // grew to 7 rows (7 × 48 + 54 title + safe.bottom ≈ 424pt, which
    // hits the 50% cap on common ~844pt screens and clips the home-
    // indicator area). Allow up to 0.62 so the last row stays
    // tappable, while still preventing absurd sheets on big lists.
    CGFloat sheetHeight = MIN(host.bounds.size.height * 0.62, height + safe.bottom);

    UIView *backdrop = [[UIView alloc] initWithFrame:host.bounds];
    backdrop.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.32];
    backdrop.alpha = 0.0;
    backdrop.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(ytmu_dismissSheet)];
    [backdrop addGestureRecognizer:tap];
    [host addSubview:backdrop];
    self.sheetBackdropView = backdrop;

    UIView *sheet = [[UIView alloc] initWithFrame:CGRectMake(0.0,
                                                            host.bounds.size.height,
                                                            host.bounds.size.width,
                                                            sheetHeight)];
    sheet.backgroundColor = [self ytmu_sheetBackgroundColor];
    sheet.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
    sheet.layer.cornerRadius = 22.0;
    sheet.layer.cornerCurve = kCACornerCurveContinuous;
    if (@available(iOS 11.0, *)) {
        sheet.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner;
    }
    [host addSubview:sheet];
    self.sheetContentView = sheet;

    UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(22.0, 12.0, sheet.bounds.size.width - 44.0, 22.0)];
    titleLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    titleLabel.text = title;
    titleLabel.font = [UIFont systemFontOfSize:16.0 weight:UIFontWeightSemibold];
    titleLabel.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.72];
    titleLabel.textAlignment = NSTextAlignmentCenter;
    [sheet addSubview:titleLabel];

    UIView *separator = [[UIView alloc] initWithFrame:CGRectMake(0.0, 44.0, sheet.bounds.size.width, 1.0 / MAX(1.0, UIScreen.mainScreen.scale))];
    separator.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    separator.backgroundColor = [self ytmu_sheetSeparatorColor];
    [sheet addSubview:separator];

    CGRect finalFrame = sheet.frame;
    finalFrame.origin.y = host.bounds.size.height - sheetHeight;
    [UIView animateWithDuration:0.24
                          delay:0.0
         usingSpringWithDamping:0.92
          initialSpringVelocity:0.0
                        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveEaseOut
                     animations:^{
        backdrop.alpha = 1.0;
        sheet.frame = finalFrame;
    } completion:nil];
}

- (UILabel *)ytmu_sheetLabelWithFrame:(CGRect)frame font:(UIFont *)font color:(UIColor *)color {
    UILabel *label = [[UILabel alloc] initWithFrame:frame];
    label.font = font;
    label.textColor = color;
    label.numberOfLines = 1;
    label.adjustsFontSizeToFitWidth = YES;
    label.minimumScaleFactor = 0.72;
    return label;
}

- (UIButton *)ytmu_addSheetRowAtY:(CGFloat)y
                           symbol:(NSString *)symbol
                            title:(NSString *)title
                            value:(NSString *)value
                          enabled:(BOOL)enabled
                           target:(id)target
                           action:(SEL)action {
    UIView *sheet = self.sheetContentView;
    CGFloat width = sheet.bounds.size.width;
    UIButton *row = [UIButton buttonWithType:UIButtonTypeCustom];
    row.frame = CGRectMake(0.0, y, width, 48.0);
    row.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    row.enabled = enabled;
    row.backgroundColor = [UIColor clearColor];
    if (target && action) [row addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
    [sheet addSubview:row];

    UIImage *image = nil;
    if (@available(iOS 13.0, *)) image = [UIImage systemImageNamed:symbol];
    if (image) {
        UIImageView *icon = [[UIImageView alloc] initWithImage:image];
        icon.frame = CGRectMake(22.0, 14.0, 20.0, 20.0);
        icon.contentMode = UIViewContentModeScaleAspectFit;
        icon.tintColor = [[UIColor whiteColor] colorWithAlphaComponent:enabled ? 0.74 : 0.32];
        icon.userInteractionEnabled = NO;
        [row addSubview:icon];
    }

    UILabel *titleLabel = [self ytmu_sheetLabelWithFrame:CGRectMake(58.0, 0.0, width * 0.50, 48.0)
                                                    font:[UIFont systemFontOfSize:15.0 weight:UIFontWeightMedium]
                                                   color:[[UIColor whiteColor] colorWithAlphaComponent:enabled ? 0.92 : 0.38]];
    titleLabel.text = title;
    titleLabel.userInteractionEnabled = NO;
    [row addSubview:titleLabel];

    CGFloat valueWidth = width - CGRectGetMaxX(titleLabel.frame) - 66.0;
    UILabel *valueLabel = [self ytmu_sheetLabelWithFrame:CGRectMake(width - valueWidth - 46.0, 0.0, valueWidth, 48.0)
                                                    font:[UIFont systemFontOfSize:14.0 weight:UIFontWeightSemibold]
                                                   color:[[UIColor whiteColor] colorWithAlphaComponent:enabled ? 0.50 : 0.25]];
    valueLabel.text = value;
    valueLabel.textAlignment = NSTextAlignmentRight;
    valueLabel.userInteractionEnabled = NO;
    valueLabel.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [row addSubview:valueLabel];

    if (action) {
        UILabel *chevron = [self ytmu_sheetLabelWithFrame:CGRectMake(width - 34.0, 0.0, 14.0, 48.0)
                                                     font:[UIFont systemFontOfSize:21.0 weight:UIFontWeightRegular]
                                                    color:[[UIColor whiteColor] colorWithAlphaComponent:0.30]];
        chevron.text = @">";
        chevron.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
        chevron.userInteractionEnabled = NO;
        [row addSubview:chevron];
    }

    UIView *separator = [[UIView alloc] initWithFrame:CGRectMake(58.0, 47.5, width - 58.0, 0.5)];
    separator.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    separator.backgroundColor = [self ytmu_sheetSeparatorColor];
    separator.userInteractionEnabled = NO;
    [row addSubview:separator];
    return row;
}

- (void)ytmu_addSwitchRowAtY:(CGFloat)y
                      symbol:(NSString *)symbol
                       title:(NSString *)title
                          on:(BOOL)on
                         tag:(NSInteger)tag {
    UIButton *row = [self ytmu_addSheetRowAtY:y symbol:symbol title:title value:@"" enabled:YES target:nil action:nil];
    UISwitch *toggle = [[UISwitch alloc] initWithFrame:CGRectZero];
    toggle.on = on;
    toggle.tag = tag;
    toggle.onTintColor = [UIColor colorWithRed:0.92 green:0.16 blue:0.20 alpha:1.0];
    toggle.center = CGPointMake(row.bounds.size.width - 52.0, row.bounds.size.height * 0.5);
    toggle.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [toggle addTarget:self action:@selector(ytmu_sheetSwitchChanged:) forControlEvents:UIControlEventValueChanged];
    [row addSubview:toggle];
}

- (void)ytmu_presentLyricsMenu:(UIButton *)sender {
    [self ytmu_prepareSheetWithHeight:340.0 title:YTMULyricsPageLocalized(@"LYRICS_PANEL_TITLE", @"Lyrics")];
    CGFloat y = 46.0;
    NSString *source = YTMULyricsPageString(@"lyricsPreferredSource", @"auto");
    [self ytmu_addSheetRowAtY:y symbol:@"text.bubble" title:YTMULyricsPageLocalized(@"LYRICS_SOURCE", @"Lyrics source") value:YTMULyricsPageSourceTitle(source) enabled:YES target:self action:@selector(ytmu_presentSourceMenuFromCurrentSheet)];
    y += 48.0;
    [self ytmu_addSheetRowAtY:y symbol:@"textformat.size" title:YTMULyricsPageLocalized(@"LYRICS_TEXT_SIZE", @"Text size") value:[NSString stringWithFormat:@"%.0f", YTMULyricsPageBaseFontSize()] enabled:YES target:self action:@selector(ytmu_presentFontSheet)];
    y += 48.0;
    [self ytmu_addSheetRowAtY:y symbol:@"arrow.up.arrow.down" title:YTMULyricsPageLocalized(@"LYRICS_TIMING_OFFSET", @"Timing offset") value:[NSString stringWithFormat:@"%+.1fs", YTMULyricsPageTimingOffsetMs() / 1000.0] enabled:YES target:self action:@selector(ytmu_presentTimingSheet)];
    y += 48.0;
    [self ytmu_addSwitchRowAtY:y symbol:@"eye" title:YTMULyricsPageLocalized(@"LYRICS_FOCUS_BLUR", @"Focus blur") on:YTMULyricsPageBoolDefault(@"lyricsFocusBlur", YES) tag:3];
    y += 48.0;
    [self ytmu_addSwitchRowAtY:y symbol:@"textformat.abc" title:YTMULyricsPageLocalized(@"LYRICS_ROMANIZATION", @"Romanization") on:YTMULyricsPageBoolDefault(@"lyricsRomanization", YES) tag:1];
    y += 48.0;
    [self ytmu_addSwitchRowAtY:y symbol:@"clock" title:YTMULyricsPageLocalized(@"LYRICS_TIMECODES", @"Timecodes") on:YTMULyricsPageBoolDefault(@"lyricsShowTimeCodes", NO) tag:2];
}

- (void)ytmu_presentSourceMenuFromCurrentSheet {
    [self ytmu_presentSourceMenuFromView:self.menuButton];
}

- (void)ytmu_presentSourceMenuFromView:(UIView *)sourceView {
    NSArray *options = YTMULyricsPageSourceOptions();
    // Height must reflect the actual number of rows we draw. A
    // previous MIN(..., 6.0) cap silently truncated when a new
    // provider (Description) was added — the 7th row got painted
    // into the sheet but the container only sized for 6 rows, so
    // the new row sat on top of (or under) the home indicator.
    CGFloat height = 54.0 + (CGFloat)options.count * 48.0;
    [self ytmu_prepareSheetWithHeight:height title:YTMULyricsPageLocalized(@"LYRICS_SOURCE", @"Lyrics source")];
    NSString *selected = YTMULyricsPageString(@"lyricsPreferredSource", @"auto");
    NSDictionary *availability = [YTMULyricsManager sharedManager].sourceAvailability ?: @{};
    CGFloat y = 46.0;
    for (NSUInteger idx = 0; idx < options.count; idx++) {
        NSDictionary *option = options[idx];
        NSString *key = option[@"key"];
        NSString *status = [key isEqualToString:@"auto"] ? @"" : availability[key];
        BOOL selectedSource = [key isEqualToString:selected];
        BOOL missed = [status isEqualToString:@"miss"];
        BOOL enabled = !missed;
        NSString *value = selectedSource ? YTMULyricsPageLocalized(@"LYRICS_SELECTED", @"Selected") : @"";
        if (!value.length && [status isEqualToString:@"hit"]) value = YTMULyricsPageLocalized(@"LYRICS_MATCHED", @"Matched");
        if (!value.length && [status isEqualToString:@"checking"]) value = YTMULyricsPageLocalized(@"LYRICS_CHECKING", @"Checking");
        if (missed) value = YTMULyricsPageLocalized(@"LYRICS_NO_MATCH", @"No match");
        UIButton *row = [self ytmu_addSheetRowAtY:y
                                           symbol:@"music.note.list"
                                            title:option[@"title"]
                                            value:value
                                          enabled:enabled
                                           target:enabled ? self : nil
                                           action:enabled ? @selector(ytmu_sheetSourceSelected:) : nil];
        row.tag = idx;
        y += 48.0;
    }
}

- (void)ytmu_presentFontSheet {
    [self ytmu_prepareSheetWithHeight:214.0 title:YTMULyricsPageLocalized(@"LYRICS_TEXT_SIZE", @"Text size")];
    UIView *sheet = self.sheetContentView;
    CGFloat width = sheet.bounds.size.width;

    UILabel *value = [self ytmu_sheetLabelWithFrame:CGRectMake(22.0, 58.0, width - 44.0, 32.0)
                                               font:[UIFont systemFontOfSize:24.0 weight:UIFontWeightSemibold]
                                              color:[UIColor whiteColor]];
    value.textAlignment = NSTextAlignmentCenter;
    value.text = [NSString stringWithFormat:@"%.0f", YTMULyricsPageBaseFontSize()];
    value.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [sheet addSubview:value];
    self.sheetValueLabel = value;

    UISlider *slider = [[UISlider alloc] initWithFrame:CGRectMake(34.0, 108.0, width - 68.0, 34.0)];
    slider.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    slider.minimumValue = 12.0;
    slider.maximumValue = 38.0;
    slider.value = YTMULyricsPageBaseFontSize();
    slider.minimumTrackTintColor = [UIColor colorWithRed:0.92 green:0.16 blue:0.20 alpha:1.0];
    slider.maximumTrackTintColor = [[UIColor whiteColor] colorWithAlphaComponent:0.22];
    [slider addTarget:self action:@selector(ytmu_fontSliderChanged:) forControlEvents:UIControlEventValueChanged];
    [slider addTarget:self action:@selector(ytmu_fontSliderTouchEnded:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
    [sheet addSubview:slider];

    UILabel *small = [self ytmu_sheetLabelWithFrame:CGRectMake(34.0, 140.0, 90.0, 22.0)
                                               font:[UIFont systemFontOfSize:13.0 weight:UIFontWeightSemibold]
                                              color:[[UIColor whiteColor] colorWithAlphaComponent:0.52]];
    small.text = @"12";
    [sheet addSubview:small];
    UILabel *large = [self ytmu_sheetLabelWithFrame:CGRectMake(width - 124.0, 140.0, 90.0, 22.0)
                                               font:[UIFont systemFontOfSize:13.0 weight:UIFontWeightSemibold]
                                              color:[[UIColor whiteColor] colorWithAlphaComponent:0.52]];
    large.textAlignment = NSTextAlignmentRight;
    large.text = @"38";
    large.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [sheet addSubview:large];

    UIButton *done = [self ytmu_sheetDoneButtonAtY:166.0 title:YTMULyricsPageLocalized(@"DONE", @"Done")];
    [sheet addSubview:done];
}

- (void)ytmu_presentTimingSheet {
    [self ytmu_prepareSheetWithHeight:226.0 title:YTMULyricsPageLocalized(@"LYRICS_TIMING_OFFSET", @"Timing offset")];
    UIView *sheet = self.sheetContentView;
    CGFloat width = sheet.bounds.size.width;

    UILabel *value = [self ytmu_sheetLabelWithFrame:CGRectMake(22.0, 58.0, width - 44.0, 32.0)
                                               font:[UIFont systemFontOfSize:24.0 weight:UIFontWeightSemibold]
                                              color:[UIColor whiteColor]];
    value.textAlignment = NSTextAlignmentCenter;
    value.text = [NSString stringWithFormat:@"%+.1fs", YTMULyricsPageTimingOffsetMs() / 1000.0];
    value.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [sheet addSubview:value];
    self.sheetValueLabel = value;

    NSArray<NSString *> *titles = @[@"-0.1s", YTMULyricsPageLocalized(@"LYRICS_RESET", @"Reset"), @"+0.1s"];
    NSArray<NSNumber *> *tags = @[@(-100), @(0), @(100)];
    CGFloat gap = 10.0;
    CGFloat buttonWidth = (width - 44.0 - gap * 2.0) / 3.0;
    for (NSUInteger idx = 0; idx < titles.count; idx++) {
        UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
        button.frame = CGRectMake(22.0 + (buttonWidth + gap) * idx, 112.0, buttonWidth, 42.0);
        button.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        button.tag = tags[idx].integerValue;
        [button setTitle:titles[idx] forState:UIControlStateNormal];
        button.titleLabel.font = [UIFont systemFontOfSize:16.0 weight:UIFontWeightSemibold];
        [button setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        button.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.12];
        button.layer.cornerRadius = 14.0;
        button.clipsToBounds = YES;
        [button addTarget:self action:@selector(ytmu_timingButtonTapped:) forControlEvents:UIControlEventTouchUpInside];
        [sheet addSubview:button];
    }

    UIButton *done = [self ytmu_sheetDoneButtonAtY:174.0 title:YTMULyricsPageLocalized(@"DONE", @"Done")];
    [sheet addSubview:done];
}

- (UIButton *)ytmu_sheetDoneButtonAtY:(CGFloat)y title:(NSString *)title {
    UIView *sheet = self.sheetContentView;
    UIButton *done = [UIButton buttonWithType:UIButtonTypeSystem];
    done.frame = CGRectMake(22.0, y, sheet.bounds.size.width - 44.0, 42.0);
    done.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [done setTitle:title forState:UIControlStateNormal];
    done.titleLabel.font = [UIFont systemFontOfSize:17.0 weight:UIFontWeightSemibold];
    [done setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    done.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.13];
    done.layer.cornerRadius = 14.0;
    done.clipsToBounds = YES;
    [done addTarget:self action:@selector(ytmu_dismissSheet) forControlEvents:UIControlEventTouchUpInside];
    return done;
}

- (void)ytmu_sheetSwitchChanged:(UISwitch *)sender {
    if (sender.tag == 1) {
        YTMULyricsPageSetSetting(@"lyricsRomanization", @(sender.on));
    } else if (sender.tag == 2) {
        YTMULyricsPageSetSetting(@"lyricsShowTimeCodes", @(sender.on));
    } else if (sender.tag == 3) {
        YTMULyricsPageSetSetting(@"lyricsFocusBlur", @(sender.on));
    }
}

- (void)ytmu_sheetSourceSelected:(UIButton *)sender {
    NSArray *options = YTMULyricsPageSourceOptions();
    if (sender.tag >= (NSInteger)options.count) return;
    NSString *key = options[(NSUInteger)sender.tag][@"key"];
    YTMULyricsPageSetSetting(@"lyricsPreferredSource", key);
    [self ytmu_updateSourceButtons];
    [self ytmu_dismissSheet];
}

- (void)ytmu_fontSliderChanged:(UISlider *)sender {
    CGFloat next = round(sender.value);
    self.sheetValueLabel.text = [NSString stringWithFormat:@"%.0f", next];
    if (fabs(next - YTMULyricsPageBaseFontSize()) < 0.5) return;
    self.pendingFontSlider = sender;
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (now - self.lastFontCommitTime >= 0.13) {
        [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(ytmu_commitFontSlider) object:nil];
        [self ytmu_commitFontSlider];
    } else {
        [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(ytmu_commitFontSlider) object:nil];
        [self performSelector:@selector(ytmu_commitFontSlider) withObject:nil afterDelay:0.13];
    }
}

- (void)ytmu_fontSliderTouchEnded:(UISlider *)sender {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(ytmu_commitFontSlider) object:nil];
    self.pendingFontSlider = sender;
    [self ytmu_commitFontSlider];
}

- (void)ytmu_commitFontSlider {
    UISlider *slider = self.pendingFontSlider;
    if (!slider) return;
    CGFloat next = round(slider.value);
    if (fabs(next - YTMULyricsPageBaseFontSize()) < 0.5) return;
    YTMULyricsPageSetBaseFontSize(next);
    self.lastFontCommitTime = [NSDate timeIntervalSinceReferenceDate];
    [self ytmu_updateFontControls];
}

- (void)ytmu_timingButtonTapped:(UIButton *)sender {
    NSInteger next = sender.tag == 0 ? 0 : YTMULyricsPageTimingOffsetMs() + sender.tag;
    YTMULyricsPageSetTimingOffsetMs(next);
    [self ytmu_applyTimingOffsetChange];
    self.sheetValueLabel.text = [NSString stringWithFormat:@"%+.1fs", YTMULyricsPageTimingOffsetMs() / 1000.0];
}

- (void)ytmu_dismissSheet {
    UIView *backdrop = self.sheetBackdropView;
    UIView *sheet = self.sheetContentView;
    self.sheetBackdropView = nil;
    self.sheetContentView = nil;
    self.sheetValueLabel = nil;
    if (!backdrop && !sheet) return;
    CGRect finalFrame = sheet.frame;
    finalFrame.origin.y = sheet.superview.bounds.size.height;
    [UIView animateWithDuration:0.18
                          delay:0.0
                        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveEaseIn
                     animations:^{
        backdrop.alpha = 0.0;
        sheet.frame = finalFrame;
    } completion:^(__unused BOOL finished) {
        [backdrop removeFromSuperview];
        [sheet removeFromSuperview];
    }];
}

- (void)ytmu_handleLyricsSettingsDidChange:(NSNotification *)notification {
    NSString *key = notification.userInfo[YTMULyricsSettingChangedKey];
    if ([key isEqualToString:@"lyricsTimingOffsetMs"]) {
        [self ytmu_applyTimingOffsetChange];
        return;
    }
    [self ytmu_renderTabOverlay];
}

- (void)ytmu_applyTimingOffsetChange {
    [self ytmu_updateTimingControls];
    if (!self.syncedLyricsView.hidden) {
        [self.syncedLyricsView updatePlaybackTimeMs:[[YTMULyricsPlaybackState sharedState] currentPlaybackTimeMs]];
    }
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
    YTMULyricsLog(@"lyrics page font size=%.0f", YTMULyricsPageBaseFontSize());
}

- (void)ytmu_adjustLyricsTiming:(UIButton *)sender {
    NSInteger next = YTMULyricsPageTimingOffsetMs() + sender.tag;
    YTMULyricsPageSetTimingOffsetMs(next);
    [self ytmu_applyTimingOffsetChange];
    YTMULyricsLog(@"lyrics page timing offset=%ldms", (long)YTMULyricsPageTimingOffsetMs());
}

- (void)ytmu_resetLyricsTiming:(UITapGestureRecognizer *)gesture {
    YTMULyricsPageSetTimingOffsetMs(0);
    [self ytmu_applyTimingOffsetChange];
    YTMULyricsLog(@"lyrics page timing offset reset");
}

@end
