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

// Settings accessors, source options, now-playing metadata, font size and
// timing offset for the lyrics panel. Declared in YTMULyricsPanelSupport.h.

NSDictionary *YTMULyricsPageSettings(void) {
    return YTMUSettingsSnapshot();
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
    YTMUSettingsSetObject(key, value ?: @"");
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
