#import <UIKit/UIKit.h>
#import <MediaPlayer/MediaPlayer.h>
#import <objc/runtime.h>
#import "Headers/Localization.h"
#import "Headers/YTPlayerViewController.h"
#import "Headers/YTIFormattedString.h"
#import "Lyrics/YTMULyricsManager.h"
#import "Lyrics/YTMULyricsPlaybackState.h"
#import "Lyrics/YTMUSyncedLyricsView.h"
#import "Lyrics/YTMULyricsTextProcessor.h"
#import "Translation/YTMUTranslationContext.h"
#import "Translation/YTMUTranslationTypes.h"
#import "Lyrics/YTMULyricsPanelSupport.h"
#import "Lyrics/YTMULyricsTabOverlayView.h"
#import "Lyrics/YTMULyricsPanelViewController.h"

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

    BOOL tabSelected = NO;
    CGFloat bottom = 0.0;
    if (YTMULyricsPageReplacementEnabled()) {
        YTMULyricsPageTabState(self.view, &tabSelected, &bottom);
    }
    BOOL selected = YTMULyricsPageReplacementEnabled() && tabSelected;
    if (!selected) {
        self.ytmuLyricsTabOverlayView.hidden = YES;
        return;
    }

    if (!self.ytmuLyricsTabOverlayView) {
        self.ytmuLyricsTabOverlayView = [[YTMULyricsTabOverlayView alloc] initWithFrame:CGRectZero];
        [self.view addSubview:self.ytmuLyricsTabOverlayView];
        YTMULyricsLog(@"lyrics tab overlay attached controller=%@", NSStringFromClass([self class]));
    }

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
    YTMULyricsMarkOfficialAvailableForCurrentSong(@"lyricsText");
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
    YTMULyricsMarkOfficialAvailableForCurrentSong(@"lyricsAccessibilityText");
    id original = %orig;
    if (!YTMULyricsPageCustomSourceEnabled()) return original;

    YTMULyricsManager *manager = [YTMULyricsManager sharedManager];
    if (manager.state != YTMULyricsFetchStateDone || !manager.currentResult.hasText) return original;

    NSString *text = YTMULyricsPagePlainDisplayText(@"");
    return text.length ? YTMULyricsPageFormattedString(text, original) : original;
}

- (id)lyricsSourceMessage {
    YTMULyricsMarkOfficialAvailableForCurrentSong(@"lyricsSourceMessage");
    id original = %orig;
    if (!YTMULyricsPageCustomSourceEnabled()) return original;

    NSString *attribution = YTMULyricsPageAttributionText();
    return attribution.length ? YTMULyricsPageFormattedString(attribution, original) : original;
}

%end

@interface YTMNowPlayingViewController : UIViewController
@property (retain, nonatomic) UIButton *ytmuLyricsEntryButton;
@property (retain, nonatomic) NSNumber *ytmuLyricsEntryRefreshToken;
- (void)ytmu_updateLyricsEntryButton;
- (void)ytmu_scheduleLyricsEntryButtonRefresh;
- (void)ytmu_handleLyricsEntryRefreshNotification:(NSNotification *)notification;
- (void)ytmu_openLyricsPanel:(id)sender;
@end

@interface UIView (YTMULyricsPageAncestor)
- (UIViewController *)_viewControllerForAncestor;
@end

static const void *YTMULyricsActionBarOriginalInsetKey = &YTMULyricsActionBarOriginalInsetKey;

static NSString *YTMULyricsPageNodeAttributedText(id node, NSUInteger depth) {
    if (!node || depth > 8) return @"";
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    NSArray<NSString *> *attrKeys = @[@"attributedText", @"_attributedText", @"attributedString", @"_attributedString"];
    NSString *own = nil;
    for (NSString *key in attrKeys) {
        @try {
            id value = [node valueForKey:key];
            if ([value isKindOfClass:[NSAttributedString class]]) {
                own = [(NSAttributedString *)value string];
            } else if ([value isKindOfClass:[NSString class]]) {
                own = (NSString *)value;
            }
        } @catch (__unused NSException *e) {}
        if (own.length) break;
    }
    if (own.length) [parts addObject:own];

    NSArray *children = nil;
    NSArray<NSString *> *childKeys = @[@"subnodes", @"_subnodes"];
    for (NSString *key in childKeys) {
        @try {
            id value = [node valueForKey:key];
            if ([value isKindOfClass:[NSArray class]]) {
                children = value;
            }
        } @catch (__unused NSException *e) {}
        if (children) break;
    }
    for (id sub in children ?: @[]) {
        NSString *t = YTMULyricsPageNodeAttributedText(sub, depth + 1);
        if (t.length) [parts addObject:t];
    }
    return [parts componentsJoinedByString:@" "];
}

static NSString *YTMULyricsPageCellNodeKey(UIView *cell) {
    NSArray<NSString *> *paths = @[
        @"_node._controller.key",
        @"node._controller.key",
        @"_node.controller.key",
        @"node.controller.key",
        @"_controller.key",
    ];
    for (NSString *path in paths) {
        @try {
            id value = [cell valueForKeyPath:path];
            if ([value isKindOfClass:[NSString class]] && [(NSString *)value length]) return (NSString *)value;
        } @catch (__unused NSException *e) {}
    }
    return @"";
}

static NSString *YTMULyricsPageCellNodeText(UIView *cell) {
    NSArray<NSString *> *keys = @[@"_node", @"node"];
    for (NSString *key in keys) {
        @try {
            id node = [cell valueForKey:key];
            NSString *text = YTMULyricsPageNodeAttributedText(node, 0);
            if (text.length) return text;
        } @catch (__unused NSException *e) {}
    }
    return @"";
}

static BOOL YTMULyricsPageStringHasLyricsToken(NSString *value) {
    if (!value.length) return NO;
    return YTMULyricsPageHasLyricsTokenInLowercased([value lowercaseString]);
}

static NSString *YTMULyricsPageNodeControllerKey(id node);

// (Previously a `YTMULyricsForceBindAllCells` helper called
// `[cv.dataSource collectionView:cv cellForItemAtIndexPath:ip]` to coerce
// off-screen cells into binding their text. This had a catastrophic side
// effect: ASCollectionView's dataSource implementation isn't purely
// functional — every call dequeues a real UICollectionViewCell into the
// view hierarchy, and ours never get reclaimed because we don't drive a
// layout pass. Each update tick added N orphan cells; after 30 seconds
// we'd accumulated 70+ ghost cells, the collection view's internal
// indexing got corrupted, and tapping anything inside (a comment, a
// chip, even Save) would crash. Don't try to force-bind from outside
// UIKit's layout pipeline.)

// Returns YES if any prefetched ASCellNode in the dataSource still has
// neither attributedText nor a controller key — i.e. binding hasn't
// completed for that cell. While this is true, our chipPresent verdict
// is unreliable: there might be a Lyrics cell hiding in an unbound slot.
static BOOL YTMULyricsCollectionViewHasUnboundNodes(UIScrollView *bar) {
    if (![bar isKindOfClass:[UICollectionView class]]) return NO;
    UICollectionView *cv = (UICollectionView *)bar;
    NSInteger sections = 0;
    @try { sections = cv.numberOfSections; } @catch (__unused NSException *e) { return NO; }
    SEL nodeSel = @selector(nodeForItemAtIndexPath:);
    if (![cv respondsToSelector:nodeSel]) return NO;
    for (NSInteger s = 0; s < sections; s++) {
        NSInteger items = 0;
        @try { items = [cv numberOfItemsInSection:s]; } @catch (__unused NSException *e) { continue; }
        for (NSInteger i = 0; i < items; i++) {
            NSIndexPath *ip = [NSIndexPath indexPathForItem:i inSection:s];
            id node = nil;
            @try {
                #pragma clang diagnostic push
                #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                node = [cv performSelector:nodeSel withObject:ip];
                #pragma clang diagnostic pop
            } @catch (__unused NSException *e) {}
            if (!node) continue;
            NSString *text = YTMULyricsPageNodeAttributedText(node, 0);
            if (text.length) continue;
            NSString *key = YTMULyricsPageNodeControllerKey(node);
            if (key.length) continue;
            return YES;
        }
    }
    return NO;
}

// ELMCellNode (used by the YTMusic action row) wraps an ELMNodeController
// whose `key` carries the binding identity (e.g. "Element|...|Lyrics|...")
// even before the cell renders. We rely on this because for off-screen
// cells the node exists but `attributedText` is still empty — only after
// layout/measurement does the text get filled in. The controller key, by
// contrast, is set at element-binding time and is stable.
static NSString *YTMULyricsPageNodeControllerKey(id node) {
    if (!node) return @"";
    NSArray<NSString *> *paths = @[
        @"_controller.key",
        @"controller.key",
        @"_controller.elementKey",
        @"controller.elementKey",
        @"_element.identifier",
        @"element.identifier",
        @"_element.elementIdentifier",
        @"element.elementIdentifier",
    ];
    for (NSString *path in paths) {
        @try {
            id v = [node valueForKeyPath:path];
            if ([v isKindOfClass:[NSString class]] && [(NSString *)v length]) return (NSString *)v;
        } @catch (__unused NSException *e) {}
    }
    return @"";
}

// ASCollectionView keeps prefetched ASCellNodes alive even when the cell
// isn't in the visible window — the action bar is horizontally scrollable
// (contentSize.width often exceeds bounds.width), so the native "Lyrics"
// cell can be off-screen at the right edge and never appear in subviews.
// We need to iterate the dataSource's cells directly and ask each cell's
// node for its text. -[ASCollectionView nodeForItemAtIndexPath:] is the
// public AsyncDisplayKit accessor for that. For nodes that exist but
// haven't been laid out yet (attributedText still nil), we fall back to
// the controller key which is set up at binding time.
static BOOL YTMULyricsCollectionViewHasLyricsCell(UIScrollView *bar) {
    if (![bar isKindOfClass:[UICollectionView class]]) return NO;
    UICollectionView *cv = (UICollectionView *)bar;
    NSInteger sections = 0;
    @try { sections = cv.numberOfSections; } @catch (__unused NSException *e) { return NO; }
    SEL nodeSel = @selector(nodeForItemAtIndexPath:);
    BOOL hasNodeAccessor = [cv respondsToSelector:nodeSel];
    for (NSInteger s = 0; s < sections; s++) {
        NSInteger items = 0;
        @try { items = [cv numberOfItemsInSection:s]; } @catch (__unused NSException *e) { continue; }
        for (NSInteger i = 0; i < items; i++) {
            NSIndexPath *ip = [NSIndexPath indexPathForItem:i inSection:s];
            if (hasNodeAccessor) {
                id node = nil;
                @try {
                    #pragma clang diagnostic push
                    #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                    node = [cv performSelector:nodeSel withObject:ip];
                    #pragma clang diagnostic pop
                } @catch (__unused NSException *e) {}
                if (node) {
                    NSString *text = YTMULyricsPageNodeAttributedText(node, 0);
                    if (text.length &&
                        YTMULyricsPageStringHasLyricsToken(text) &&
                        ![[text lowercaseString] containsString:@"close"]) {
                        return YES;
                    }
                    // Fallback for off-screen cells whose text isn't laid
                    // out yet: read the controller key, which is set at
                    // binding time and reliably contains the action
                    // identifier (e.g. "...|Lyrics|...").
                    NSString *ctrlKey = YTMULyricsPageNodeControllerKey(node);
                    if (ctrlKey.length &&
                        YTMULyricsPageStringHasLyricsToken(ctrlKey) &&
                        ![[ctrlKey lowercaseString] containsString:@"close"]) {
                        return YES;
                    }
                }
            }
            UICollectionViewCell *cell = nil;
            @try {
                cell = [cv cellForItemAtIndexPath:ip];
            } @catch (__unused NSException *e) {}
            if (cell) {
                NSString *cellKey = YTMULyricsPageCellNodeKey(cell);
                if (YTMULyricsPageStringHasLyricsToken(cellKey)) return YES;
                NSString *nodeText = YTMULyricsPageCellNodeText(cell);
                if (nodeText.length &&
                    YTMULyricsPageStringHasLyricsToken(nodeText) &&
                    ![[nodeText lowercaseString] containsString:@"close"]) return YES;
            }
        }
    }
    return NO;
}

static BOOL YTMULyricsPageContainsOfficialLyricsEntry(UIView *view, NSUInteger depth) {
    if (!view || view.hidden || view.alpha <= 0.03 || depth > 18) return NO;
    NSString *identifier = view.accessibilityIdentifier;
    if ([identifier isKindOfClass:[NSString class]] && [identifier isEqualToString:@"ytmu.lyrics.entry"]) return NO;

    NSString *text = YTMULyricsPageAccessibilityText(view);
    CGRect bounds = view.bounds;
    BOOL buttonSized = bounds.size.width >= 48.0 &&
                       bounds.size.width <= 180.0 &&
                       bounds.size.height >= 24.0 &&
                       bounds.size.height <= 72.0;
    if ((buttonSized || depth > 0) && YTMULyricsPageTextHasLyricsToken(text) && ![text containsString:@"close"]) {
        return YES;
    }

    NSString *nodeKey = YTMULyricsPageCellNodeKey(view);
    if (YTMULyricsPageStringHasLyricsToken(nodeKey)) return YES;

    NSString *nodeText = YTMULyricsPageCellNodeText(view);
    if (YTMULyricsPageStringHasLyricsToken(nodeText) && ![[nodeText lowercaseString] containsString:@"close"]) return YES;

    for (UIView *subview in view.subviews) {
        if (YTMULyricsPageContainsOfficialLyricsEntry(subview, depth + 1)) return YES;
    }
    return NO;
}

static UIScrollView *YTMULyricsPageFindActionBarScrollView(UIView *view, NSUInteger depth) {
    if (!view || depth > 12) return nil;
    NSString *identifier = view.accessibilityIdentifier;
    if ([view isKindOfClass:[UIScrollView class]] &&
        [identifier isKindOfClass:[NSString class]] &&
        [identifier isEqualToString:@"id.video.scrollable_action_bar"]) {
        return (UIScrollView *)view;
    }
    for (UIView *subview in view.subviews) {
        UIScrollView *found = YTMULyricsPageFindActionBarScrollView(subview, depth + 1);
        if (found) return found;
    }
    return nil;
}

static CGFloat YTMULyricsPageActionBarContentWidth(UIScrollView *scrollView, UIView *button) {
    // Collection-view layout publishes the full native content width via
    // contentSize, including cells that have been recycled out of subviews.
    // Subview maxX alone misses those, which is what made our chip overlap
    // with cells that loaded in later (e.g. Download appearing on top of
    // our button after the first layout pass).
    CGFloat contentSizeWidth = scrollView.contentSize.width;
    if (contentSizeWidth >= 1.0) return contentSizeWidth;

    CGFloat maxX = 0.0;
    for (UIView *subview in scrollView.subviews) {
        if (subview == button) continue;
        if (subview.hidden || subview.alpha <= 0.03) continue;
        if ([NSStringFromClass([subview class]) containsString:@"ScrollIndicator"]) continue;
        CGRect frame = subview.frame;
        if (frame.size.width < 8.0 || frame.size.height < 8.0) continue;
        maxX = MAX(maxX, CGRectGetMaxX(frame));
    }
    return maxX;
}

static UIImage *YTMULyricsPageLyricsIcon(void) {
    NSArray<NSString *> *names = @[@"quote.bubble", @"text.quote", @"quote.opening"];
    for (NSString *name in names) {
        UIImage *image = [UIImage systemImageNamed:name];
        if (image) return image;
    }
    return nil;
}

static void YTMULyricsPageApplyActionBarInset(UIScrollView *scrollView, CGFloat requiredRightInset) {
    if (!scrollView) return;
    NSValue *originalValue = objc_getAssociatedObject(scrollView, YTMULyricsActionBarOriginalInsetKey);
    if (!originalValue) {
        originalValue = [NSValue valueWithUIEdgeInsets:scrollView.contentInset];
        objc_setAssociatedObject(scrollView, YTMULyricsActionBarOriginalInsetKey, originalValue, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    UIEdgeInsets originalInset = originalValue.UIEdgeInsetsValue;
    UIEdgeInsets inset = scrollView.contentInset;
    CGFloat desiredRight = MAX(originalInset.right, requiredRightInset);
    // Short-circuit when the inset already matches. Writing -setContentInset:
    // unconditionally is what made rapid swipes feel jerky: UIKit invalidates
    // layout and re-clamps contentOffset on every assignment, even when the
    // value is identical, which competes with the user's in-flight pan
    // gesture. ytmu_updateLyricsEntryButton runs once per viewDidLayoutSubviews
    // tick (~150–200 ms during interaction) and the desired inset stays
    // stable as long as the chip width / origin doesn't shift.
    if (fabs(inset.right - desiredRight) < 0.5) return;
    inset.right = desiredRight;
    scrollView.contentInset = inset;
    scrollView.scrollIndicatorInsets = inset;
}

static void YTMULyricsPageRestoreActionBarInset(UIScrollView *scrollView) {
    if (!scrollView) return;
    NSValue *originalValue = objc_getAssociatedObject(scrollView, YTMULyricsActionBarOriginalInsetKey);
    if (!originalValue) return;
    UIEdgeInsets originalInset = originalValue.UIEdgeInsetsValue;
    scrollView.contentInset = originalInset;
    scrollView.scrollIndicatorInsets = originalInset;
    objc_setAssociatedObject(scrollView, YTMULyricsActionBarOriginalInsetKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// Associated-object key on YTMNowPlayingViewController for the action-bar
// scroll offset captured at lyrics-panel open. The panel modal dismiss
// resets the bar's contentOffset to zero, so for music videos that lack
// a native "Lyrics" cell — where our chip sits at the far right and the
// user must scroll to reach it — re-opening the player snaps the bar
// back to the left and the chip disappears off-screen again. Saving the
// scroll position at open-time and restoring it on viewDidAppear after
// dismiss is a pure UX restore: no layout or hierarchy changes.
static char YTMULyricsActionBarSavedOffsetKey;

%hook YTMNowPlayingViewController

%property (retain, nonatomic) UIButton *ytmuLyricsEntryButton;
%property (retain, nonatomic) NSNumber *ytmuLyricsEntryRefreshToken;

- (void)viewDidLoad {
    %orig;
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(ytmu_handleLyricsEntryRefreshNotification:)
                                                 name:YTMULyricsDidUpdateNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(ytmu_handleLyricsEntryRefreshNotification:)
                                                 name:YTMULyricsSettingsDidChangeNotification
                                               object:nil];
    [self ytmu_updateLyricsEntryButton];
    [self ytmu_scheduleLyricsEntryButtonRefresh];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    %orig;
}

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    [self ytmu_updateLyricsEntryButton];
    [self ytmu_scheduleLyricsEntryButtonRefresh];
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    [self ytmu_updateLyricsEntryButton];
    [self ytmu_scheduleLyricsEntryButtonRefresh];

    // After modal dismiss, restore the action-bar scroll offset the user
    // had scrolled to before opening the lyrics panel. Without this,
    // music videos that don't carry a native "Lyrics" cell — where the
    // chip lives at the far right of the bar — reset to leftmost on
    // dismiss and the user has to scroll right again every time.
    NSDictionary *snapshot = objc_getAssociatedObject(self, &YTMULyricsActionBarSavedOffsetKey);
    if (!snapshot) return;
    objc_setAssociatedObject(self, &YTMULyricsActionBarSavedOffsetKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSString *savedVideoId = snapshot[@"videoId"];
    NSString *currentVideoId = [YTMULyricsManager sharedManager].activeVideoId ?: @"";
    if (savedVideoId.length && currentVideoId.length && ![savedVideoId isEqualToString:currentVideoId]) {
        // Auto-advance happened while the panel was open. The saved
        // offset belongs to a different bar layout — restoring it onto
        // the new song's bar would scroll us to an arbitrary position.
        // Drop the snapshot and let the user scroll fresh.
        YTMULyricsLog(@"actionRow: dropping stale offset (saved videoId=%@ now=%@)",
                      savedVideoId, currentVideoId);
        return;
    }
    CGPoint target = [snapshot[@"offset"] CGPointValue];
    YTMULyricsLog(@"actionRow: restoring offset target=%@ after panel dismiss", NSStringFromCGPoint(target));
    // Single delayed restore is enough now that the notification handler
    // no longer pre-emptively retracts the chip and clamps offset on
    // every same-song lyrics update. 0.3s gives the dismiss animation
    // and YT Music's own layout work time to settle; restoring earlier
    // races those layouts and gets clamped.
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        YTMNowPlayingViewController *strongSelf = weakSelf;
        if (!strongSelf || !strongSelf.isViewLoaded) return;
        UIScrollView *actionBar = YTMULyricsPageFindActionBarScrollView(strongSelf.view, 0);
        if (!actionBar) return;
        CGPoint current = actionBar.contentOffset;
        if (fabs(current.x - target.x) < 0.5 && fabs(current.y - target.y) < 0.5) return;
        CGSize contentSize = actionBar.contentSize;
        UIEdgeInsets inset = actionBar.contentInset;
        CGFloat maxX = MAX(0.0, contentSize.width + inset.right - actionBar.bounds.size.width);
        CGPoint clamped = CGPointMake(MIN(target.x, maxX), target.y);
        [actionBar setContentOffset:clamped animated:NO];
        YTMULyricsLog(@"actionRow: restored offset current=%@ → set %@ (maxX=%.1f inset.r=%.1f)",
                      NSStringFromCGPoint(current), NSStringFromCGPoint(clamped), maxX, inset.right);
    });
}

- (void)viewDidLayoutSubviews {
    %orig;
    [self ytmu_updateLyricsEntryButton];
}

%new
- (void)ytmu_updateLyricsEntryButton {
    if (!YTMULyricsPageCustomSourceEnabled()) {
        if ([self.ytmuLyricsEntryButton.superview isKindOfClass:[UIScrollView class]]) {
            YTMULyricsPageRestoreActionBarInset((UIScrollView *)self.ytmuLyricsEntryButton.superview);
        }
        self.ytmuLyricsEntryButton.hidden = YES;
        [self.ytmuLyricsEntryButton removeFromSuperview];
        return;
    }

    NSString *currentVideoId = [YTMULyricsManager sharedManager].activeVideoId;
    UIScrollView *actionBar = YTMULyricsPageFindActionBarScrollView(self.view, 0);

    static NSString *gLastEntryButtonVideoId = nil;
    static __weak UIScrollView *gStaleActionBarFromPrevVideo = nil;
    static CFAbsoluteTime gStaleActionBarTimestamp = 0;
    if (gLastEntryButtonVideoId && currentVideoId.length &&
        ![gLastEntryButtonVideoId isEqualToString:currentVideoId]) {
        // Song changed since the last update. Two things to do:
        //   1. Retract any chip we left attached to the old action bar so
        //      we never co-render with the new song's native Lyrics chip
        //      during the transition window.
        //   2. Remember the current bar as "stale". manager.activeVideoId
        //      flips to the new song *before* YTMNowPlayingViewController
        //      tears down the old action bar, so for a few frames the old
        //      bar's Lyrics cell is still in the hierarchy even though it
        //      belongs to the previous song. If we mark chipPresent
        //      against the new videoId during that window we permanently
        //      cache the wrong "this song has official lyrics" verdict
        //      (and then hide our chip every time the user comes back).
        if (actionBar) {
            gStaleActionBarFromPrevVideo = actionBar;
            gStaleActionBarTimestamp = CFAbsoluteTimeGetCurrent();
        }
        if ([self.ytmuLyricsEntryButton.superview isKindOfClass:[UIScrollView class]]) {
            YTMULyricsPageRestoreActionBarInset((UIScrollView *)self.ytmuLyricsEntryButton.superview);
        }
        self.ytmuLyricsEntryButton.hidden = YES;
        [self.ytmuLyricsEntryButton removeFromSuperview];
        YTMULyricsLog(@"actionRow: videoId changed %@ -> %@; retracting chip; staleBar=%p",
                      gLastEntryButtonVideoId, currentVideoId, (__bridge void *)actionBar);
    }
    if (currentVideoId.length) {
        gLastEntryButtonVideoId = [currentVideoId copy];
    }

    if (!actionBar) {
        YTMULyricsLog(@"actionRow: no action bar yet");
        // Make sure the chip isn't lingering inside an action bar that's about
        // to disappear from the hierarchy (otherwise it stays visible during
        // the song-change animation).
        if ([self.ytmuLyricsEntryButton.superview isKindOfClass:[UIScrollView class]]) {
            YTMULyricsPageRestoreActionBarInset((UIScrollView *)self.ytmuLyricsEntryButton.superview);
        }
        self.ytmuLyricsEntryButton.hidden = YES;
        [self.ytmuLyricsEntryButton removeFromSuperview];
        return;
    }

    // Note: we used to force-bind every dataSource entry here so off-screen
    // cells revealed their attributedText. That route is poison — see the
    // comment near the (deleted) YTMULyricsForceBindAllCells helper. We
    // now accept that off-screen cells stay unbound and rely on the
    // unbound-guard below to keep our chip retracted while the verdict is
    // ambiguous; subsequent retries will catch up once natural binding
    // completes.

    if (actionBar == gStaleActionBarFromPrevVideo) {
        // Same bar instance we recorded at the videoId switch — its cells
        // most likely still belong to the previous song. Skip this tick:
        // don't mark, don't render, don't take any chipPresent verdict.
        // Time-bound the suppression at 3.0s so that if YTMusic reuses
        // the same ASCollectionView for the new song we don't deadlock
        // ourselves into permanent silence. (Previously 1.5s, but real
        // device logs showed the manager-vs-actionBar lag can stretch
        // past 2s, after which we'd start hiding/showing for the wrong
        // song.)
        CFAbsoluteTime age = CFAbsoluteTimeGetCurrent() - gStaleActionBarTimestamp;
        if (age < 3.0) {
            YTMULyricsLog(@"actionRow: skip — actionBar=%p still stale (age=%.2fs); current=%@",
                          (__bridge void *)actionBar, age,
                          currentVideoId.length ? currentVideoId : @"<none>");
            return;
        }
        YTMULyricsLog(@"actionRow: stale bar=%p timed out (age=%.2fs) — releasing",
                      (__bridge void *)actionBar, age);
        gStaleActionBarFromPrevVideo = nil;
        gStaleActionBarTimestamp = 0;
    }

    // Fresh detection every frame — no cross-frame cache writes from this
    // UI path. Earlier versions cached "this song has official lyrics"
    // into a per-videoId set whenever we saw a Lyrics cell, plus a bridge
    // map keyed by action-bar instance for the videoId-not-yet-known
    // window. Both were a footgun: when YTMNowPlayingViewController flips
    // manager.activeVideoId before tearing down the previous song's
    // action bar (a window that can stretch past a couple of seconds),
    // the stale Lyrics cell got attributed to the new videoId and cached
    // permanently. The user then sees us hide the chip on songs that
    // genuinely have no lyrics. The renderer hook still writes the set
    // when it fires (rare, but more authoritative), so we read it but
    // never write from here.
    BOOL rendererSawLyrics = YTMULyricsHasOfficialForCurrentSong();
    BOOL chipPresent = NO;
    if (!rendererSawLyrics) {
        chipPresent = YTMULyricsCollectionViewHasLyricsCell(actionBar)
            || YTMULyricsPageContainsOfficialLyricsEntry(actionBar, 0);
    }

    if (rendererSawLyrics || chipPresent) {
        if ([self.ytmuLyricsEntryButton.superview isKindOfClass:[UIScrollView class]]) {
            YTMULyricsPageRestoreActionBarInset((UIScrollView *)self.ytmuLyricsEntryButton.superview);
        }
        self.ytmuLyricsEntryButton.hidden = YES;
        [self.ytmuLyricsEntryButton removeFromSuperview];
        YTMULyricsLog(@"actionRow: hide rendererSeen=%d chipPresent=%d videoId=%@",
                      rendererSawLyrics, chipPresent,
                      currentVideoId.length ? currentVideoId : @"<none>");
        return;
    }

    if (YTMULyricsCollectionViewHasUnboundNodes(actionBar)) {
        // Some cells in the action bar's dataSource haven't bound yet —
        // their text/key are both empty so we can't tell whether one of
        // them is the native Lyrics chip. Stay retracted and wait for
        // the next refresh to retry; surfacing the chip now would risk
        // double-rendering once the unbound cell finally lays out.
        if ([self.ytmuLyricsEntryButton.superview isKindOfClass:[UIScrollView class]]) {
            YTMULyricsPageRestoreActionBarInset((UIScrollView *)self.ytmuLyricsEntryButton.superview);
        }
        self.ytmuLyricsEntryButton.hidden = YES;
        [self.ytmuLyricsEntryButton removeFromSuperview];
        YTMULyricsLog(@"actionRow: skip — dataSource has unbound nodes; current=%@",
                      currentVideoId.length ? currentVideoId : @"<none>");
        return;
    }

    if (!self.ytmuLyricsEntryButton) {
        self.ytmuLyricsEntryButton = [UIButton buttonWithType:UIButtonTypeSystem];
        self.ytmuLyricsEntryButton.accessibilityIdentifier = @"ytmu.lyrics.entry";
        self.ytmuLyricsEntryButton.accessibilityLabel = YTMULyricsPageLocalized(@"LYRICS_PANEL_TITLE", @"Lyrics");
        [self.ytmuLyricsEntryButton setTitle:YTMULyricsPageLocalized(@"LYRICS_PANEL_TITLE", @"Lyrics") forState:UIControlStateNormal];
        UIImage *icon = YTMULyricsPageLyricsIcon();
        if (icon) [self.ytmuLyricsEntryButton setImage:icon forState:UIControlStateNormal];
        self.ytmuLyricsEntryButton.titleLabel.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightMedium];
        [self.ytmuLyricsEntryButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        self.ytmuLyricsEntryButton.tintColor = [UIColor whiteColor];
        self.ytmuLyricsEntryButton.imageView.contentMode = UIViewContentModeScaleAspectFit;
        self.ytmuLyricsEntryButton.contentEdgeInsets = UIEdgeInsetsMake(0.0, 14.0, 0.0, 14.0);
        self.ytmuLyricsEntryButton.imageEdgeInsets = UIEdgeInsetsMake(0.0, -4.0, 0.0, 6.0);
        self.ytmuLyricsEntryButton.titleEdgeInsets = UIEdgeInsetsMake(0.0, 6.0, 0.0, -4.0);
        self.ytmuLyricsEntryButton.clipsToBounds = YES;
        [self.ytmuLyricsEntryButton addTarget:self action:@selector(ytmu_openLyricsPanel:) forControlEvents:UIControlEventTouchUpInside];
    }

    if (self.ytmuLyricsEntryButton.superview != actionBar) {
        [self.ytmuLyricsEntryButton removeFromSuperview];
        [actionBar addSubview:self.ytmuLyricsEntryButton];
    }

    // The action-bar cell is 48pt tall but YT's chip pill inside it is ~36pt
    // (logs of native cells: cell.frame.size = {W, 48}, but the visible chip
    // sits centered with ~6pt padding top/bottom). Pin our chip to that pill
    // height instead of the cell height so we don't render too tall.
    CGFloat actionBarHeight = actionBar.bounds.size.height;
    CGFloat height = MIN(36.0, MAX(28.0, actionBarHeight - 12.0));

    self.ytmuLyricsEntryButton.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.10];
    self.ytmuLyricsEntryButton.layer.cornerRadius = height / 2.0;

    // Native "Lyrics" chip measures 108-120pt across logs; sizeThatFits with
    // our font + edge insets returns ~91pt which truncates the title into
    // "L...cs". Floor the width at 112pt so the full label fits with the
    // icon and matches the native chip's footprint.
    CGSize fitSize = [self.ytmuLyricsEntryButton sizeThatFits:CGSizeMake(CGFLOAT_MAX, height)];
    CGFloat width = MAX(112.0, ceil(fitSize.width));

    CGFloat contentWidth = YTMULyricsPageActionBarContentWidth(actionBar, self.ytmuLyricsEntryButton);
    if (actionBar.bounds.size.width < 1.0) {
        self.ytmuLyricsEntryButton.hidden = YES;
        return;
    }

    CGFloat gap = 6.0;
    CGFloat x = contentWidth > 0.0 ? contentWidth + gap : 0.0;
    CGFloat y = MAX(0.0, (actionBarHeight - height) / 2.0);
    CGRect desiredFrame = CGRectMake(x, y, width, height);
    CGRect currentFrame = self.ytmuLyricsEntryButton.frame;
    BOOL frameUnchanged = !self.ytmuLyricsEntryButton.hidden &&
        fabs(currentFrame.origin.x - desiredFrame.origin.x) < 0.5 &&
        fabs(currentFrame.origin.y - desiredFrame.origin.y) < 0.5 &&
        fabs(currentFrame.size.width - desiredFrame.size.width) < 0.5 &&
        fabs(currentFrame.size.height - desiredFrame.size.height) < 0.5;
    if (!frameUnchanged) {
        self.ytmuLyricsEntryButton.frame = desiredFrame;
        self.ytmuLyricsEntryButton.hidden = NO;
    }
    // ApplyActionBarInset short-circuits when the inset already matches, so
    // calling it every tick is cheap when the chip width hasn't moved.
    YTMULyricsPageApplyActionBarInset(actionBar, width + gap + 16.0);
    if (!frameUnchanged) {
        [actionBar bringSubviewToFront:self.ytmuLyricsEntryButton];
        YTMULyricsLog(@"actionRow: show frame=%@ contentWidth=%.1f barH=%.1f videoId=%@",
                      NSStringFromCGRect(self.ytmuLyricsEntryButton.frame),
                      contentWidth, actionBarHeight,
                      currentVideoId.length ? currentVideoId : @"<none>");
    }
}

%new
- (void)ytmu_scheduleLyricsEntryButtonRefresh {
    NSUInteger token = self.ytmuLyricsEntryRefreshToken.unsignedIntegerValue + 1;
    self.ytmuLyricsEntryRefreshToken = @(token);
    NSArray<NSNumber *> *delays = @[@0.15, @0.3, @0.6, @1.0, @1.5, @2.5, @4.0, @6.0, @9.0, @13.0];
    __weak typeof(self) weakSelf = self;
    for (NSNumber *delayNumber in delays) {
        NSTimeInterval delay = delayNumber.doubleValue;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            YTMNowPlayingViewController *strongSelf = weakSelf;
            if (!strongSelf || !strongSelf.isViewLoaded) return;
            if (strongSelf.ytmuLyricsEntryRefreshToken.unsignedIntegerValue != token) return;
            [strongSelf ytmu_updateLyricsEntryButton];
        });
    }
}

%new
- (void)ytmu_handleLyricsEntryRefreshNotification:(NSNotification *)notification {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self ytmu_handleLyricsEntryRefreshNotification:notification];
        });
        return;
    }
    // Manager state changed — could be song change OR a same-song lyrics
    // update (translation applied, lyrics ready, etc.). Just hand off to
    // updateLyricsEntryButton which has its own song-change retraction
    // path (gLastEntryButtonVideoId).
    //
    // We used to proactively retract the chip + restore inset here on
    // *every* notification. For same-song notifications (which fire
    // multiple times per song as lyrics/translation arrive) that was
    // wasted work and, worse, races our viewDidAppear scroll-position
    // restore — the inset reset triggers UIKit to clamp contentOffset
    // back to the smaller (chipless) maxX, undoing whatever the user
    // had scrolled to before opening the panel.
    [self ytmu_updateLyricsEntryButton];
    [self ytmu_scheduleLyricsEntryButtonRefresh];
}

%new
- (void)ytmu_openLyricsPanel:(id)sender {
    if (!YTMULyricsPageCustomSourceEnabled()) return;
    UIViewController *presenter = YTMULyricsPageTopPresenter(self);
    if ([presenter isKindOfClass:[YTMULyricsPanelViewController class]]) return;

    // Snapshot the action-bar scroll position before presenting so we
    // can restore it on dismiss. Tag the snapshot with the active
    // videoId so a save from song A doesn't get applied to song B's
    // bar after an auto-advance during the panel session.
    UIScrollView *actionBar = YTMULyricsPageFindActionBarScrollView(self.view, 0);
    if (actionBar) {
        CGPoint offset = actionBar.contentOffset;
        NSString *videoId = [YTMULyricsManager sharedManager].activeVideoId ?: @"";
        NSDictionary *snapshot = @{
            @"videoId": videoId,
            @"offset": [NSValue valueWithCGPoint:offset],
        };
        objc_setAssociatedObject(self, &YTMULyricsActionBarSavedOffsetKey,
                                 snapshot,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        YTMULyricsLog(@"actionRow: saved offset=%@ videoId=%@ before panel present (contentSize=%@ inset.r=%.1f bar=%.1f)",
                      NSStringFromCGPoint(offset), videoId,
                      NSStringFromCGSize(actionBar.contentSize),
                      actionBar.contentInset.right,
                      actionBar.bounds.size.width);
    }

    YTMULyricsPanelViewController *controller = [[YTMULyricsPanelViewController alloc] init];
    controller.playerViewController = YTMULyricsPagePlayerFromCandidate(self) ?: [YTMULyricsPlaybackState sharedState].playerViewController;
    controller.modalPresentationStyle = UIModalPresentationFullScreen;
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
@property (copy, nonatomic) NSString *ytmuRenderSignature;
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
%property (copy, nonatomic) NSString *ytmuRenderSignature;

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
    YTMULyricsManager *manager = [YTMULyricsManager sharedManager];
    NSString *signature = [NSString stringWithFormat:@"%ld|%p|%p|%lu|%@|%.0f|%@|%@|%@|%@|%@|%@",
                           (long)manager.state,
                           (void *)manager.currentResult,
                           (void *)manager.translatedLines,
                           (unsigned long)(self.ytmuFallbackLyricsText ?: @"").hash,
                           YTMULyricsPageString(@"lyricsPreferredSource", @"auto"),
                           YTMULyricsPageBaseFontSize(),
                           YTMULyricsPageString(@"lyricsConvertChinese", @"disabled"),
                           YTMULyricsPageString(@"lyricsDefaultText", @"♪"),
                           YTMULyricsPageBool(@"lyricsRomanization") ? @"1" : @"0",
                           YTMULyricsPageBool(@"lyricsShowTimeCodes") ? @"1" : @"0",
                           manager.translationAttribution ?: @"",
                           self.lyrics.textColor.description ?: @""];
    if ([signature isEqualToString:self.ytmuRenderSignature]) return;
    self.ytmuRenderSignature = signature;

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
    static const void *kLastHideTimeKey = &kLastHideTimeKey;
    NSNumber *last = objc_getAssociatedObject(self, kLastHideTimeKey);
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (last && now - last.doubleValue < 0.5) return;
    objc_setAssociatedObject(self, kLastHideTimeKey, @(now), OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    UIView *root = self;
    for (NSUInteger depth = 0; depth < 8 && root.superview && ![root.superview isKindOfClass:[UIWindow class]]; depth++) {
        root = root.superview;
    }
    YTMULyricsPageHideOfficialActionsInView(root, self);
}

%end

%ctor {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithDictionary:[defaults dictionaryForKey:@"YTMUltimate"] ?: @{}];
    YTMULyricsSetDefault(dict, @"bilingualLyrics", @(NO));
    YTMULyricsSetDefault(dict, @"lyricsTranslationEnabled", dict[@"bilingualLyrics"] ?: @(NO));
    YTMULyricsSetDefault(dict, @"lyricsPreferredSource", @"auto");
    YTMULyricsSetDefault(dict, @"lyricsTimingOffsetMs", @(0));
    YTMULyricsSetDefault(dict, @"lyricsTimingOffsetActiveKey", @"");
    YTMULyricsSetDefault(dict, @"lyricsTimingOffsets", @{});
    YTMULyricsSetDefault(dict, @"translationProvider", YTMUTranslationProviderGoogle);
    YTMULyricsSetDefault(dict, @"translationTargetLang", @"auto");
    YTMULyricsSetDefault(dict, @"translationBaseUrl", @"https://api.openai.com/v1");
    YTMULyricsSetDefault(dict, @"translationDebugLogs", @(NO));
    YTMULyricsSetDefault(dict, @"lyricsFocusBlur", @(YES));
    [defaults setObject:dict forKey:@"YTMUltimate"];
}
