#import <UIKit/UIKit.h>
#import <MediaPlayer/MediaPlayer.h>
#import <objc/runtime.h>
#import <substrate.h>
#import "Headers/YTPlayerViewController.h"
#import "Headers/YTMWatchViewController.h"
#import "Headers/YTMNowPlayingViewController.h"
#import "Lyrics/YTMULyricsManager.h"
#import "Lyrics/YTMULyricsPlaybackState.h"
#import "Lyrics/YTMUSyncedLyricsView.h"
#import "Translation/YTMUTranslationContext.h"

static BOOL YTMUSyncedLyricsEnabled(void) {
    NSDictionary *dict = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"YTMUltimate"] ?: @{};
    return [dict[@"YTMUltimateIsEnabled"] boolValue] && [dict[@"syncedLyricsEnabled"] boolValue];
}

static BOOL YTMUArtworkLyricsOverlayEnabled(void) {
    NSDictionary *dict = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"YTMUltimate"] ?: @{};
    return [dict[@"lyricsArtworkOverlayEnabled"] boolValue];
}

static void YTMULogOfficialLyricsProbe(id object, NSString *event, NSString *source, NSData *data, NSString *entityKey) {
    if (!YTMULyricsDebugLoggingEnabled()) return;
    static NSMutableSet<NSString *> *seen;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        seen = [NSMutableSet set];
    });

    NSString *signature = [NSString stringWithFormat:@"%@::%@::%@::%lu::%@",
                           NSStringFromClass([object class]),
                           event ?: @"",
                           source ?: @"",
                           (unsigned long)data.length,
                           entityKey ?: @""];
    @synchronized (seen) {
        if ([seen containsObject:signature]) return;
        [seen addObject:signature];
    }
    YTMULyricsLog(@"official lyrics probe event=%@ class=%@ source=%@ dataBytes=%lu entityKey=%@",
                  event ?: @"<unknown>",
                  NSStringFromClass([object class]),
                  source.length ? source : @"<empty>",
                  (unsigned long)data.length,
                  entityKey.length ? entityKey : @"<empty>");
}

@interface YTPlayerViewController ()
@property (nonatomic, retain) YTMUSyncedLyricsView *ytmuSyncedLyricsView;
- (void)ytmu_attachSyncedLyricsViewIfNeeded;
- (void)ytmu_layoutSyncedLyricsView;
@end

static id YTMUSafeValueForKey(id object, NSString *key) {
    if (!object || !key.length) return nil;
    @try {
        return [object valueForKey:key];
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static NSString *YTMUStringFromObject(id object) {
    if ([object isKindOfClass:[NSString class]]) return object;
    if ([object respondsToSelector:@selector(stringValue)]) return [object stringValue];
    return @"";
}

static id YTMUObjectForKey(id object, NSString *key) {
    if (!object || !key.length) return nil;
    if ([object isKindOfClass:[NSDictionary class]]) return ((NSDictionary *)object)[key];
    return YTMUSafeValueForKey(object, key);
}

static NSArray *YTMUArrayFromObject(id object) {
    if ([object isKindOfClass:[NSArray class]]) return object;
    if ([object isKindOfClass:[NSSet class]]) return [(NSSet *)object allObjects];
    return nil;
}

static id YTMUFirstObjectAtKeys(id root, NSArray<NSString *> *keys) {
    id current = root;
    for (NSString *key in keys) {
        current = YTMUObjectForKey(current, key);
        if (!current) return nil;
    }
    return current;
}

static id YTMUMicroformatRendererFromPlayerResponse(id playerResponse) {
    id playerData = YTMUObjectForKey(playerResponse, @"playerData");
    id microformat = YTMUFirstObjectAtKeys(playerData, @[@"microformat", @"microformatDataRenderer"]) ?:
                     YTMUFirstObjectAtKeys(playerResponse, @[@"microformat", @"microformatDataRenderer"]) ?:
                     YTMUObjectForKey(playerData, @"microformat") ?:
                     YTMUObjectForKey(playerResponse, @"microformat");
    return microformat;
}

static NSString *YTMUAlternativeTitleFromMicroformat(id microformat, NSString *currentTitle) {
    NSArray *linkAlternates = YTMUArrayFromObject(YTMUObjectForKey(microformat, @"linkAlternates"));
    for (id link in linkAlternates ?: @[]) {
        NSString *title = YTMUStringFromObject(YTMUObjectForKey(link, @"title"));
        if (!title.length) continue;
        if (currentTitle.length && [YTMULyricsCompactString(title) isEqualToString:YTMULyricsCompactString(currentTitle)]) continue;
        return title;
    }
    return @"";
}

static NSArray<NSString *> *YTMUTagsFromMicroformat(id microformat) {
    NSArray *rawTags = YTMUArrayFromObject(YTMUObjectForKey(microformat, @"tags"));
    NSMutableArray<NSString *> *tags = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (id raw in rawTags ?: @[]) {
        NSString *tag = YTMUStringFromObject(raw);
        NSString *key = YTMULyricsCompactString(tag);
        if (!tag.length || !key.length || [seen containsObject:key]) continue;
        [seen addObject:key];
        [tags addObject:tag];
        if (tags.count >= 12) break;
    }
    return tags;
}

static YTPlayerViewController *YTMUPlayerFromCandidate(id candidate) {
    Class playerClass = NSClassFromString(@"YTPlayerViewController");
    if (playerClass && [candidate isKindOfClass:playerClass]) {
        return candidate;
    }

    id player = YTMUSafeValueForKey(candidate, @"playerViewController");
    if (playerClass && [player isKindOfClass:playerClass]) {
        return player;
    }

    id parent = YTMUSafeValueForKey(candidate, @"parentViewController");
    if (parent && parent != candidate) {
        return YTMUPlayerFromCandidate(parent);
    }

    return nil;
}

static NSString *YTMUClassAndPointer(id object) {
    return object ? [NSString stringWithFormat:@"%@<%p>", NSStringFromClass([object class]), object] : @"<nil>";
}

static BOOL YTMURefreshLyricsFromPlayer(YTPlayerViewController *player, NSString *source, BOOL force) {
    if (!player) return NO;
    [[YTMULyricsPlaybackState sharedState] notePlayerViewController:player];

    NSString *videoId = @"";
    NSTimeInterval duration = 0;
    @try {
        videoId = player.currentVideoID ?: player.contentVideoID ?: @"";
        duration = player.currentVideoTotalMediaTime;
    } @catch (__unused NSException *exception) {
        videoId = @"";
        duration = 0;
    }
    if (!videoId.length) {
        videoId = YTMUStringFromObject(YTMUSafeValueForKey(player, @"currentVideoID"));
        if (!videoId.length) videoId = YTMUStringFromObject(YTMUSafeValueForKey(player, @"contentVideoID"));
    }
    if (duration <= 0) {
        duration = [YTMUSafeValueForKey(player, @"currentVideoTotalMediaTime") doubleValue];
    }

    id playerResponse = YTMUSafeValueForKey(player, @"playerResponse");
    id playerData = YTMUSafeValueForKey(playerResponse, @"playerData");
    id details = YTMUSafeValueForKey(playerData, @"videoDetails");
    NSString *title = YTMUStringFromObject(YTMUSafeValueForKey(details, @"title"));
    NSString *artist = YTMUStringFromObject(YTMUSafeValueForKey(details, @"author"));
    NSString *album = YTMUStringFromObject(YTMUSafeValueForKey(details, @"album"));
    id microformat = YTMUMicroformatRendererFromPlayerResponse(playerResponse);
    NSString *alternativeTitle = YTMUAlternativeTitleFromMicroformat(microformat, title);
    NSArray<NSString *> *tags = YTMUTagsFromMicroformat(microformat);
    NSDictionary *nowPlaying = [MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo ?: @{};
    if (!title.length) title = YTMUStringFromObject(nowPlaying[MPMediaItemPropertyTitle]);
    if (!artist.length) artist = YTMUStringFromObject(nowPlaying[MPMediaItemPropertyArtist]);
    if (!album.length) album = YTMUStringFromObject(nowPlaying[MPMediaItemPropertyAlbumTitle]);
    if (!alternativeTitle.length) alternativeTitle = YTMUAlternativeTitleFromMicroformat(microformat, title);
    if (duration <= 0) duration = [nowPlaying[MPMediaItemPropertyPlaybackDuration] doubleValue];

    if (!videoId.length && !title.length) {
        static NSMutableSet<NSString *> *missingSources;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            missingSources = [NSMutableSet set];
        });
        @synchronized (missingSources) {
            if (![missingSources containsObject:source ?: @"<unknown>"]) {
                [missingSources addObject:source ?: @"<unknown>"];
                NSLog(@"[YTMULyrics] player metadata unavailable source=%@ player=%@", source, YTMUClassAndPointer(player));
            }
        }
        return NO;
    }

    NSString *signature = [NSString stringWithFormat:@"%@|%@|%@", videoId ?: @"", title ?: @"", artist ?: @""];
    static NSString *lastSignature;
    BOOL shouldRefresh = force;
    @synchronized ([YTMULyricsManager class]) {
        if (![signature isEqualToString:lastSignature]) {
            shouldRefresh = YES;
            lastSignature = [signature copy];
        }
    }
    if (!shouldRefresh) return NO;

    [[YTMUTranslationContext sharedContext] updateWithVideoId:videoId title:title artist:artist];

    NSDictionary *flags = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"YTMUltimate"] ?: @{};
    NSLog(@"[YTMULyrics] player metadata source=%@ player=%@ videoId=%@ title=%@ alt=%@ artist=%@ duration=%.1f tags=%lu master=%@ synced=%@ bilingual=%@",
          source ?: @"<unknown>",
          YTMUClassAndPointer(player),
          videoId.length ? videoId : @"<empty>",
          title.length ? title : @"<empty>",
          alternativeTitle.length ? alternativeTitle : @"<empty>",
          artist.length ? artist : @"<empty>",
          duration,
          (unsigned long)tags.count,
          [flags[@"YTMUltimateIsEnabled"] boolValue] ? @"YES" : @"NO",
          [flags[@"syncedLyricsEnabled"] boolValue] ? @"YES" : @"NO",
          ([flags[@"lyricsTranslationEnabled"] boolValue] || [flags[@"bilingualLyrics"] boolValue]) ? @"YES" : @"NO");

    YTMULyricsSearchInfo *info = [[YTMULyricsSearchInfo alloc] init];
    info.videoId = videoId;
    info.title = title;
    info.alternativeTitle = alternativeTitle.length ? alternativeTitle : title;
    info.artist = artist;
    info.album = album;
    info.duration = duration;
    info.tags = tags ?: @[];
    [[YTMULyricsManager sharedManager] refreshWithInfo:info];
    return YES;
}

static void YTMUHandlePlayerCandidate(id candidate, NSString *source, BOOL force) {
    YTPlayerViewController *player = YTMUPlayerFromCandidate(candidate);
    if (!player) {
        static NSMutableSet<NSString *> *missingSources;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            missingSources = [NSMutableSet set];
        });
        @synchronized (missingSources) {
            if (![missingSources containsObject:source ?: @"<unknown>"]) {
                [missingSources addObject:source ?: @"<unknown>"];
                NSLog(@"[YTMULyrics] no player candidate source=%@ object=%@", source, YTMUClassAndPointer(candidate));
            }
        }
        return;
    }

    if ([player respondsToSelector:@selector(ytmu_attachSyncedLyricsViewIfNeeded)]) {
        [player ytmu_attachSyncedLyricsViewIfNeeded];
    }
    [[YTMULyricsPlaybackState sharedState] notePlayerViewController:player];
    YTMURefreshLyricsFromPlayer(player, source, force);
}

static NSString *YTMUHasSelector(Class cls, SEL selector) {
    return (cls && [cls instancesRespondToSelector:selector]) ? @"YES" : @"NO";
}

static void YTMULogInterestingSelectors(Class cls) {
    if (!cls) return;

    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    NSArray<NSString *> *needles = @[@"Activate", @"VideoTime", @"playbackController", @"playerViewController", @"currentVideo", @"playerResponse"];
    for (unsigned int i = 0; i < count; i++) {
        NSString *name = NSStringFromSelector(method_getName(methods[i]));
        for (NSString *needle in needles) {
            if ([name rangeOfString:needle options:NSCaseInsensitiveSearch].location != NSNotFound) {
                [names addObject:name];
                break;
            }
        }
        if (names.count >= 70) break;
    }
    free(methods);

    NSLog(@"[YTMULyrics] runtime selectors class=%@ count=%u interesting=%@",
          NSStringFromClass(cls),
          count,
          names.count ? [names componentsJoinedByString:@", "] : @"<none>");
}

static void YTMULogRuntimeDiagnostics(void) {
    NSLog(@"[YTMULyrics] build stamp %s %s", __DATE__, __TIME__);

    NSArray<NSString *> *classes = @[
        @"YTPlayerViewController",
        @"YTMWatchViewController",
        @"YTMNowPlayingViewController",
        @"YTMPlayerViewController",
        @"YTMPlayerTabViewController"
    ];
    for (NSString *name in classes) {
        Class cls = NSClassFromString(name);
        NSLog(@"[YTMULyrics] runtime class %@ present=%@ viewDidAppear=%@ viewDidLayout=%@ playerVC=%@ didActivate3=%@ pvDidActivate=%@ timeSingle=%@ timePotential=%@",
              name,
              cls ? @"YES" : @"NO",
              YTMUHasSelector(cls, @selector(viewDidAppear:)),
              YTMUHasSelector(cls, @selector(viewDidLayoutSubviews)),
              YTMUHasSelector(cls, @selector(playerViewController)),
              YTMUHasSelector(cls, @selector(playbackController:didActivateVideo:withPlaybackData:)),
              YTMUHasSelector(cls, @selector(playerViewController:didActivateVideo:)),
              YTMUHasSelector(cls, @selector(singleVideo:currentVideoTimeDidChange:)),
              YTMUHasSelector(cls, @selector(potentiallyMutatedSingleVideo:currentVideoTimeDidChange:)));
        YTMULogInterestingSelectors(cls);
    }
}

static void (*YTMUOrigYTPlayerPlaybackControllerDidActivateVideoWithPlayerResponse)(id, SEL, id, id);
static void YTMUHookYTPlayerPlaybackControllerDidActivateVideoWithPlayerResponse(id self, SEL _cmd, id arg1, id arg2) {
    if (YTMUOrigYTPlayerPlaybackControllerDidActivateVideoWithPlayerResponse) {
        YTMUOrigYTPlayerPlaybackControllerDidActivateVideoWithPlayerResponse(self, _cmd, arg1, arg2);
    }
    NSLog(@"[YTMULyrics] dynamic callback %@ class=%@", NSStringFromSelector(_cmd), NSStringFromClass([self class]));
    YTMUHandlePlayerCandidate(self, NSStringFromSelector(_cmd), YES);
}

static void (*YTMUOrigYTPlayerPlaybackControllerDidActivateVideo)(id, SEL, id);
static void YTMUHookYTPlayerPlaybackControllerDidActivateVideo(id self, SEL _cmd, id arg1) {
    if (YTMUOrigYTPlayerPlaybackControllerDidActivateVideo) {
        YTMUOrigYTPlayerPlaybackControllerDidActivateVideo(self, _cmd, arg1);
    }
    NSLog(@"[YTMULyrics] dynamic callback %@ class=%@", NSStringFromSelector(_cmd), NSStringFromClass([self class]));
    YTMUHandlePlayerCandidate(self, NSStringFromSelector(_cmd), YES);
}

static void (*YTMUOrigWatchPlayerDidActivate)(id, SEL, id, id);
static void YTMUHookWatchPlayerDidActivate(id self, SEL _cmd, id player, id video) {
    if (YTMUOrigWatchPlayerDidActivate) {
        YTMUOrigWatchPlayerDidActivate(self, _cmd, player, video);
    }
    NSLog(@"[YTMULyrics] dynamic callback %@ class=%@ player=%@", NSStringFromSelector(_cmd), NSStringFromClass([self class]), YTMUClassAndPointer(player));
    YTMUHandlePlayerCandidate(player ?: self, NSStringFromSelector(_cmd), YES);
}

static void (*YTMUOrigWatchPlayerActivatedWithVideo)(id, SEL, id, id);
static void YTMUHookWatchPlayerActivatedWithVideo(id self, SEL _cmd, id player, id video) {
    if (YTMUOrigWatchPlayerActivatedWithVideo) {
        YTMUOrigWatchPlayerActivatedWithVideo(self, _cmd, player, video);
    }
    NSLog(@"[YTMULyrics] dynamic callback %@ class=%@ player=%@", NSStringFromSelector(_cmd), NSStringFromClass([self class]), YTMUClassAndPointer(player));
    YTMUHandlePlayerCandidate(player ?: self, NSStringFromSelector(_cmd), YES);
}

static void (*YTMUOrigWatchPlayerDidActivateNewPlayback)(id, SEL, id, id);
static void YTMUHookWatchPlayerDidActivateNewPlayback(id self, SEL _cmd, id player, id video) {
    if (YTMUOrigWatchPlayerDidActivateNewPlayback) {
        YTMUOrigWatchPlayerDidActivateNewPlayback(self, _cmd, player, video);
    }
    NSLog(@"[YTMULyrics] dynamic callback %@ class=%@ player=%@", NSStringFromSelector(_cmd), NSStringFromClass([self class]), YTMUClassAndPointer(player));
    YTMUHandlePlayerCandidate(player ?: self, NSStringFromSelector(_cmd), YES);
}

static void (*YTMUOrigWatchPlayerWillActivate)(id, SEL, id, id);
static void YTMUHookWatchPlayerWillActivate(id self, SEL _cmd, id player, id video) {
    if (YTMUOrigWatchPlayerWillActivate) {
        YTMUOrigWatchPlayerWillActivate(self, _cmd, player, video);
    }
    NSLog(@"[YTMULyrics] dynamic callback %@ class=%@ player=%@", NSStringFromSelector(_cmd), NSStringFromClass([self class]), YTMUClassAndPointer(player));
    YTMUHandlePlayerCandidate(player ?: self, NSStringFromSelector(_cmd), NO);
}

static void YTMUInstallMessageHook(Class cls, SEL selector, IMP replacement, IMP *original, NSString *label) {
    BOOL hasMethod = cls && class_getInstanceMethod(cls, selector) != NULL;
    NSLog(@"[YTMULyrics] dynamic hook candidate %@ %@ installed=%@",
          label ?: NSStringFromClass(cls),
          NSStringFromSelector(selector),
          hasMethod ? @"YES" : @"NO");
    if (hasMethod) {
        MSHookMessageEx(cls, selector, replacement, original);
    }
}

static void YTMUInstallDynamicHooks(void) {
    Class playerClass = NSClassFromString(@"YTPlayerViewController");
    YTMUInstallMessageHook(playerClass,
                           @selector(playbackControllerDidActivateVideo:withPlayerResponse:),
                           (IMP)YTMUHookYTPlayerPlaybackControllerDidActivateVideoWithPlayerResponse,
                           (IMP *)&YTMUOrigYTPlayerPlaybackControllerDidActivateVideoWithPlayerResponse,
                           @"YTPlayerViewController");
    YTMUInstallMessageHook(playerClass,
                           @selector(playbackControllerDidActivateVideo:),
                           (IMP)YTMUHookYTPlayerPlaybackControllerDidActivateVideo,
                           (IMP *)&YTMUOrigYTPlayerPlaybackControllerDidActivateVideo,
                           @"YTPlayerViewController");

    Class watchClass = NSClassFromString(@"YTMWatchViewController");
    YTMUInstallMessageHook(watchClass,
                           @selector(playerViewController:didActivateVideo:),
                           (IMP)YTMUHookWatchPlayerDidActivate,
                           (IMP *)&YTMUOrigWatchPlayerDidActivate,
                           @"YTMWatchViewController");
    YTMUInstallMessageHook(watchClass,
                           @selector(playerViewController:activatedWithVideo:),
                           (IMP)YTMUHookWatchPlayerActivatedWithVideo,
                           (IMP *)&YTMUOrigWatchPlayerActivatedWithVideo,
                           @"YTMWatchViewController");
    YTMUInstallMessageHook(watchClass,
                           @selector(playerViewController:didActivateNewPlaybackWithContentVideo:),
                           (IMP)YTMUHookWatchPlayerDidActivateNewPlayback,
                           (IMP *)&YTMUOrigWatchPlayerDidActivateNewPlayback,
                           @"YTMWatchViewController");
    YTMUInstallMessageHook(watchClass,
                           @selector(playerViewController:willActivateVideo:),
                           (IMP)YTMUHookWatchPlayerWillActivate,
                           (IMP *)&YTMUOrigWatchPlayerWillActivate,
                           @"YTMWatchViewController");
}

@interface YTClientLyricsDataModel : NSObject
- (NSString *)lyricsSource;
- (NSData *)data;
@end

@interface YTMusicLyricsEntityModel : NSObject
- (id)clientLyricsData;
- (NSData *)data;
- (NSString *)entityKey;
@end

%hook YTPlayerViewController

%property (nonatomic, retain) YTMUSyncedLyricsView *ytmuSyncedLyricsView;

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSLog(@"[YTMULyrics] hook YTPlayerViewController.viewDidAppear fired (class=%@)", NSStringFromClass([self class]));
    });
    [self ytmu_attachSyncedLyricsViewIfNeeded];
}

- (void)viewDidLayoutSubviews {
    %orig;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSLog(@"[YTMULyrics] hook YTPlayerViewController.viewDidLayoutSubviews fired");
    });
    [self ytmu_layoutSyncedLyricsView];
}

- (void)playbackController:(id)arg1 didActivateVideo:(id)arg2 withPlaybackData:(id)arg3 {
    %orig;
    NSLog(@"[YTMULyrics] hook didActivateVideo class=%@", NSStringFromClass([self class]));
    YTMUHandlePlayerCandidate(self, @"YTPlayerViewController.didActivateVideo", YES);
}

- (void)singleVideo:(id)video currentVideoTimeDidChange:(id)time {
    %orig;
    NSTimeInterval timeMs = self.currentVideoMediaTime * 1000.0;
    [[YTMULyricsPlaybackState sharedState] notePlayerViewController:self];
    [[YTMULyricsPlaybackState sharedState] notePlaybackTimeMs:timeMs];
    [self.ytmuSyncedLyricsView updatePlaybackTimeMs:timeMs];
}

- (void)potentiallyMutatedSingleVideo:(id)video currentVideoTimeDidChange:(id)time {
    %orig;
    NSTimeInterval timeMs = self.currentVideoMediaTime * 1000.0;
    [[YTMULyricsPlaybackState sharedState] notePlayerViewController:self];
    [[YTMULyricsPlaybackState sharedState] notePlaybackTimeMs:timeMs];
    [self.ytmuSyncedLyricsView updatePlaybackTimeMs:timeMs];
}

%new
- (void)ytmu_attachSyncedLyricsViewIfNeeded {
    if (!YTMUArtworkLyricsOverlayEnabled()) {
        if (self.ytmuSyncedLyricsView) {
            self.ytmuSyncedLyricsView.hidden = YES;
            [self.ytmuSyncedLyricsView removeFromSuperview];
            self.ytmuSyncedLyricsView = nil;
        }
        return;
    }
    if (!YTMUSyncedLyricsEnabled()) {
        self.ytmuSyncedLyricsView.hidden = YES;
        return;
    }
    if (!self.ytmuSyncedLyricsView) {
        self.ytmuSyncedLyricsView = [[YTMUSyncedLyricsView alloc] initWithFrame:CGRectZero];
        self.ytmuSyncedLyricsView.playerViewController = self;
        self.ytmuSyncedLyricsView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
        [self.view addSubview:self.ytmuSyncedLyricsView];
        NSLog(@"[YTMULyrics] synced lyrics view attached player=%@ container=%@", YTMUClassAndPointer(self), YTMUClassAndPointer(self.view));
        [self ytmu_layoutSyncedLyricsView];
        [self.ytmuSyncedLyricsView reloadFromManager];
    }
}

%new
- (void)ytmu_layoutSyncedLyricsView {
    if (!self.ytmuSyncedLyricsView) return;
    UIEdgeInsets safe = self.view.safeAreaInsets;
    CGFloat width = self.view.bounds.size.width - 20;
    CGFloat height = MIN(MAX(self.view.bounds.size.height * 0.38, 210), 360);
    CGFloat y = self.view.bounds.size.height - height - safe.bottom - 14;
    self.ytmuSyncedLyricsView.frame = CGRectMake(10, MAX(safe.top + 12, y), width, height);
}

%end

%hook YTMWatchViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSLog(@"[YTMULyrics] hook YTMWatchViewController.viewDidAppear fired class=%@", NSStringFromClass([self class]));
    });
    YTMUHandlePlayerCandidate(self, @"YTMWatchViewController.viewDidAppear", YES);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        YTMUHandlePlayerCandidate(self, @"YTMWatchViewController.viewDidAppear.delayed", NO);
    });
}

- (void)viewDidLayoutSubviews {
    %orig;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSLog(@"[YTMULyrics] hook YTMWatchViewController.viewDidLayoutSubviews fired class=%@", NSStringFromClass([self class]));
    });
    YTMUHandlePlayerCandidate(self, @"YTMWatchViewController.viewDidLayoutSubviews", NO);
}

- (void)playbackControllerStateDidChange {
    %orig;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSLog(@"[YTMULyrics] hook YTMWatchViewController.playbackControllerStateDidChange fired class=%@", NSStringFromClass([self class]));
    });
    YTMUHandlePlayerCandidate(self, @"YTMWatchViewController.playbackControllerStateDidChange", NO);
}

%end

%hook YTMNowPlayingViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSLog(@"[YTMULyrics] hook YTMNowPlayingViewController.viewDidAppear fired class=%@", NSStringFromClass([self class]));
    });
    YTMUHandlePlayerCandidate(self, @"YTMNowPlayingViewController.viewDidAppear", NO);
}

- (void)viewDidLayoutSubviews {
    %orig;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSLog(@"[YTMULyrics] hook YTMNowPlayingViewController.viewDidLayoutSubviews fired class=%@", NSStringFromClass([self class]));
    });
    YTMUHandlePlayerCandidate(self, @"YTMNowPlayingViewController.viewDidLayoutSubviews", NO);
}

%end

%group YTMUOfficialLyricsProbe

%hook YTClientLyricsDataModel

- (NSString *)lyricsSource {
    NSString *source = %orig;
    NSData *data = nil;
    @try {
        data = [self data];
    } @catch (__unused NSException *exception) {
        data = nil;
    }
    YTMULogOfficialLyricsProbe(self, @"clientLyricsData.lyricsSource", source, data, @"");
    return source;
}

%end

%hook YTMusicLyricsEntityModel

- (id)clientLyricsData {
    id clientData = %orig;
    NSString *source = @"";
    if ([clientData respondsToSelector:@selector(lyricsSource)]) {
        source = [clientData lyricsSource];
    }
    NSData *data = nil;
    NSString *entityKey = @"";
    @try {
        data = [self data];
        entityKey = [self entityKey];
    } @catch (__unused NSException *exception) {
        data = nil;
        entityKey = @"";
    }
    YTMULogOfficialLyricsProbe(self, @"musicLyricsEntity.clientLyricsData", source, data, entityKey);
    return clientData;
}

%end

%end

%ctor {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithDictionary:[defaults dictionaryForKey:@"YTMUltimate"] ?: @{}];
    YTMULyricsSetDefault(dict, @"syncedLyricsEnabled", @(NO));
    YTMULyricsSetDefault(dict, @"lyricsPreferredSource", @"auto");
    YTMULyricsSetDefault(dict, @"lyricsShowInexact", @(YES));
    YTMULyricsSetDefault(dict, @"lyricsRomanization", @(YES));
    YTMULyricsSetDefault(dict, @"lyricsConvertChinese", @"disabled");
    YTMULyricsSetDefault(dict, @"lyricsShowTimeCodes", @(NO));
    YTMULyricsSetDefault(dict, @"lyricsLineEffect", @"fancy");
    YTMULyricsSetDefault(dict, @"lyricsFontSize", @"small");
    YTMULyricsSetDefault(dict, @"lyricsDefaultText", @"♪");
    YTMULyricsSetDefault(dict, @"lyricsTranslationEnabled", @(NO));
    dict[@"lyricsArtworkOverlayEnabled"] = @(NO);
    [defaults setObject:dict forKey:@"YTMUltimate"];
    %init;
    YTMULogRuntimeDiagnostics();
    YTMUInstallDynamicHooks();
    YTMULyricsLog(@"synced lyrics module loaded");
    if (NSClassFromString(@"YTClientLyricsDataModel") || NSClassFromString(@"YTMusicLyricsEntityModel")) {
        %init(YTMUOfficialLyricsProbe);
        YTMULyricsLog(@"official lyrics probe installed");
    }
}
