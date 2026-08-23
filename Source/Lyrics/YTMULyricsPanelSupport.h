#import <UIKit/UIKit.h>
#import "YTMULyricsTypes.h"
#import "../Headers/YTPlayerViewController.h"


// Settings accessors, text rendering, and view-tree probes shared by the
// in-app lyrics panel (YTMULyricsTabOverlayView / YTMULyricsPanelViewController)
// and the Logos hooks in Source/SelectableLyrics.x. Moved out of the hook
// file verbatim so the panel can be compiled and tested on its own.

NSDictionary *YTMULyricsPageSettings(void);
BOOL YTMULyricsPageBool(NSString *key);
BOOL YTMULyricsPageBoolDefault(NSString *key, BOOL fallback);
NSString *YTMULyricsPageString(NSString *key, NSString *fallback);
NSString *YTMULyricsPageLocalized(NSString *key, NSString *fallback);
NSMutableSet<NSString *> *YTMULyricsOfficialAvailableVideoIds(void);
void YTMULyricsMarkOfficialAvailableForCurrentSong(NSString *trigger);
BOOL YTMULyricsHasOfficialForCurrentSong(void);
BOOL YTMULyricsPageReplacementEnabled(void);
BOOL YTMULyricsPageCustomSourceEnabled(void);
void YTMULyricsPageSetSetting(NSString *key, id value);
NSArray<NSDictionary *> *YTMULyricsPageSourceOptions(void);
NSString *YTMULyricsPageSourceTitle(NSString *key);
NSUInteger YTMULyricsPageSourceIndex(NSString *key);
NSString *YTMULyricsPageNowPlayingTitle(void);
NSString *YTMULyricsPageNowPlayingArtist(void);
UIImage *YTMULyricsPageNowPlayingArtwork(CGSize size);
NSString *YTMULyricsPageTranslationProviderTitle(void);
CGFloat YTMULyricsPageClampFontSize(CGFloat size);
CGFloat YTMULyricsPageBaseFontSize(void);
void YTMULyricsPageSetBaseFontSize(CGFloat size);
NSString *YTMULyricsPageTimingOffsetKey(void);
NSInteger YTMULyricsPageTimingOffsetMs(void);
void YTMULyricsPageSetTimingOffsetMs(NSInteger value);
NSString *YTMULyricsPageRomanizationLanguageForResult(YTMULyricsResult *result);
BOOL YTMULyricsPageResultHasCompleteRomanization(YTMULyricsResult *result);
NSString *YTMULyricsPageRomanizedLineAtIndex(YTMULyricsResult *result, NSUInteger idx);
NSString *YTMULyricsPageLineText(NSString *text);
UIColor *YTMULyricsPageSecondaryTextColor(void);
NSAttributedString *YTMULyricsPageAttributedText(UITextView *textView, NSString *fallbackText);
NSString *YTMULyricsPagePlainDisplayText(NSString *fallbackText);
NSString *YTMULyricsPageAttributionText(void);
id YTMULyricsPageFormattedString(NSString *text, id fallback);
void YTMULyricsPageLogRendererOverride(NSString *event, NSString *source, NSUInteger translatedCount);
NSString *YTMULyricsPageViewText(UIView *view);
id YTMULyricsPageSafeValueForKey(id object, NSString *key);
void YTMULyricsPageAppendStringValue(id value, NSMutableArray<NSString *> *parts);
void YTMULyricsPageAppendObjectText(id object, NSMutableArray<NSString *> *parts, NSUInteger depth);
UIView *YTMULyricsPageActionTargetForView(UIView *view);
YTPlayerViewController *YTMULyricsPagePlayerFromCandidate(id candidate);
void YTMULyricsPageHideOfficialActionsInView(UIView *view, UIView *replacementRoot);
NSString *YTMULyricsPageAccessibilityText(UIView *view);
NSString *YTMULyricsPageRecursiveAccessibilityText(UIView *view, NSUInteger depth);
BOOL YTMULyricsPageHasLyricsTokenInLowercased(NSString *lowered);
BOOL YTMULyricsPageTextHasLyricsToken(NSString *text);
BOOL YTMULyricsPageViewIsSelected(UIView *view);
void YTMULyricsPageCollectTabSelection(UIView *view, UIView *root, BOOL *lyricsSelected, CGFloat *tabBarTop, NSUInteger depth);
void YTMULyricsPageTabState(UIView *root, BOOL *selected, CGFloat *bottom);

