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

// View-tree probes over YouTube Music's private views (action row,
// official lyrics chip, tab bar). Declared in YTMULyricsPanelSupport.h.

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
