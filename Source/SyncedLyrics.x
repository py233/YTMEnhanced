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
#import "Lyrics/YTMUInnerTubeDescriptionFetcher.h"
#import "Translation/YTMUTranslationContext.h"

static BOOL YTMUSyncedLyricsEnabled(void) {
    NSDictionary *dict = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"YTMUltimate"] ?: @{};
    return [dict[@"YTMUltimateIsEnabled"] boolValue] && [dict[@"syncedLyricsEnabled"] boolValue];
}

static BOOL YTMUArtworkLyricsOverlayEnabled(void) {
    NSDictionary *dict = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"YTMUltimate"] ?: @{};
    return [dict[@"lyricsArtworkOverlayEnabled"] boolValue];
}

static NSTimeInterval YTMUNormalizedPlaybackTimeMs(YTPlayerViewController *player) {
    if (!player) return 0;
    @try {
        NSTimeInterval rawTime = player.currentVideoMediaTime;
        NSTimeInterval duration = player.currentVideoTotalMediaTime;
        if (!isfinite(rawTime) || rawTime < 0) return 0;
        if (isfinite(duration) && duration > 0 && rawTime > duration * 1.5 && rawTime <= duration * 1500.0) {
            return rawTime;
        }
        return rawTime * 1000.0;
    } @catch (__unused NSException *exception) {
        return 0;
    }
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

// NSObject's default `-description` returns something like
// "<ClassName: 0xADDR>". KVC accessing the `description` key on any
// Obj-C object falls through to this method, which is how we ended up
// with a 31-char "description" that's actually just a debug pointer
// string. Filter it out — anything matching this shape is NOT the YT
// video description we want.
static BOOL YTMUIsObjectDebugString(NSString *str) {
    if (!str.length || str.length > 200) return NO;
    if (![str hasPrefix:@"<"] || ![str hasSuffix:@">"]) return NO;
    return [str rangeOfString:@"0x"].location != NSNotFound;
}

// Strict string-only KVC reader. Returns @"" when the value is missing,
// not a string, or matches the NSObject -description debug format.
static NSString *YTMUSafeStringForKey(id object, NSString *key) {
    if (!object || !key.length) return @"";
    id value = nil;
    if ([object isKindOfClass:[NSDictionary class]]) {
        value = ((NSDictionary *)object)[key];
    } else {
        value = YTMUSafeValueForKey(object, key);
    }
    if (![value isKindOfClass:[NSString class]]) return @"";
    NSString *str = (NSString *)value;
    return YTMUIsObjectDebugString(str) ? @"" : str;
}

// Pull the long-form video description out of the player response. YT
// Music's client does NOT consistently populate `videoDetails.shortDescription`
// — for music-video uploads it's frequently empty even though the same
// video on www.youtube.com has a multi-KB description with full lyrics.
// We probe every known path and pick the longest real string.
//
// `lengthsLog` (out, optional) is filled with a human-readable breakdown
// of every path's length so the caller can log which one won.
static NSString *YTMUDescriptionFromPlayerResponse(id playerResponse, id details, id microformat,
                                                   NSString *_Nullable *lengthsLog) {
    NSString *fromDetails = YTMUSafeStringForKey(details, @"shortDescription");

    NSString *fromMicroformatSimple = @"";
    NSString *fromMicroformatRuns = @"";
    // We use YTMUObjectForKey to descend into `description` here only
    // when the parent is an NSDictionary — that avoids hitting NSObject's
    // -description method as a side effect.
    id microformatDescription = nil;
    if ([microformat isKindOfClass:[NSDictionary class]]) {
        microformatDescription = ((NSDictionary *)microformat)[@"description"];
    }
    if ([microformatDescription isKindOfClass:[NSDictionary class]]) {
        fromMicroformatSimple = YTMUSafeStringForKey(microformatDescription, @"simpleText");
        NSArray *runs = YTMUArrayFromObject(((NSDictionary *)microformatDescription)[@"runs"]);
        if (runs.count) {
            NSMutableString *joined = [NSMutableString string];
            for (id run in runs) {
                NSString *text = YTMUSafeStringForKey(run, @"text");
                if (text.length) [joined appendString:text];
            }
            fromMicroformatRuns = joined;
        }
    }

    NSString *best = @"";
    NSString *bestSource = @"<none>";
    if (fromDetails.length > best.length)           { best = fromDetails;           bestSource = @"details.shortDescription"; }
    if (fromMicroformatSimple.length > best.length) { best = fromMicroformatSimple; bestSource = @"microformat.description.simpleText"; }
    if (fromMicroformatRuns.length > best.length)   { best = fromMicroformatRuns;   bestSource = @"microformat.description.runs"; }

    if (lengthsLog) {
        *lengthsLog = [NSString stringWithFormat:@"details=%lu microformat.simple=%lu microformat.runs=%lu chosen=%@",
                       (unsigned long)fromDetails.length,
                       (unsigned long)fromMicroformatSimple.length,
                       (unsigned long)fromMicroformatRuns.length,
                       bestSource];
    }
    return best;
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

    // YTPlayerViewController exposes the player response under the
    // selector `contentPlayerResponse`, NOT `playerResponse` (we missed
    // this in earlier passes — the runtime-selector dump at startup
    // shows it). Try both, falling back to whichever responds.
    id playerResponse = YTMUSafeValueForKey(player, @"contentPlayerResponse");
    if (!playerResponse) playerResponse = YTMUSafeValueForKey(player, @"playerResponse");
    id playerData = YTMUSafeValueForKey(playerResponse, @"playerData");
    id details = YTMUSafeValueForKey(playerData, @"videoDetails");
    NSString *title = YTMUStringFromObject(YTMUSafeValueForKey(details, @"title"));
    NSString *artist = YTMUStringFromObject(YTMUSafeValueForKey(details, @"author"));
    NSString *album = YTMUStringFromObject(YTMUSafeValueForKey(details, @"album"));
    id microformat = YTMUMicroformatRendererFromPlayerResponse(playerResponse);
    NSString *descriptionLengths = nil;
    NSString *shortDescription = YTMUDescriptionFromPlayerResponse(playerResponse, details, microformat, &descriptionLengths);
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
                if (YTMULyricsDebugLoggingEnabled()) {
                    YTMULyricsLog(@"player metadata unavailable source=%@ player=%@", source, YTMUClassAndPointer(player));
                }
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

    if (YTMULyricsDebugLoggingEnabled()) {
        NSDictionary *flags = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"YTMUltimate"] ?: @{};
        YTMULyricsLog(@"player metadata source=%@ player=%@ videoId=%@ title=%@ alt=%@ artist=%@ duration=%.1f tags=%lu master=%@ synced=%@ bilingual=%@",
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
        // YT Music's client strips the description out of its player
        // response — `videoDetails.shortDescription` is empty for almost
        // every music video and the microformat block is never present
        // (verified via reflection dumps). We log which (if any) of the
        // local paths produced the description; the InnerTube fetcher
        // wired in below picks up when none did.
        YTMULyricsLog(@"player metadata description %@", descriptionLengths ?: @"<no probe>");
    }

    YTMULyricsSearchInfo *info = [[YTMULyricsSearchInfo alloc] init];
    info.videoId = videoId;
    info.title = title;
    info.alternativeTitle = alternativeTitle.length ? alternativeTitle : title;
    info.artist = artist;
    info.album = album;
    info.duration = duration;
    info.tags = tags ?: @[];
    // YouTube descriptions cap at 5000 characters server-side. We allow up
    // to 32KB defensively (in case a client is bundling extra metadata)
    // and pass the full block downstream. Trimming aggressively here
    // would defeat the description-lyrics extractor — uploaders frequently
    // open with credits/links/CC notice and only paste lyrics deep into
    // the description.
    if (shortDescription.length > 32 * 1024) shortDescription = [shortDescription substringToIndex:32 * 1024];
    info.shortDescription = shortDescription ?: @"";

    // YT Music's player response strips out the description (verified via
    // reflection — `videoDetails.shortDescription` is empty and the
    // microformat block is absent). If we got nothing locally, look up
    // an InnerTube cache entry (synchronous, no network) and inject it
    // before the lyrics pipeline kicks off.
    if (!info.shortDescription.length && videoId.length) {
        NSString *cachedDescription = [[YTMUInnerTubeDescriptionFetcher sharedFetcher]
                                          cachedDescriptionForVideoId:videoId];
        if (cachedDescription.length) {
            NSString *capped = cachedDescription.length > 32 * 1024
                ? [cachedDescription substringToIndex:32 * 1024]
                : cachedDescription;
            info.shortDescription = capped;
            YTMULyricsLog(@"innertube cache hit (sync) videoId=%@ len=%lu",
                          videoId, (unsigned long)capped.length);
        }
    }

    [[YTMULyricsManager sharedManager] refreshWithInfo:info];

    // Cache miss + we still have no description: kick off an async
    // InnerTube fetch. On success we re-run refreshWithInfo with the
    // populated description; from then on the synchronous cache-hit
    // path above takes over for this videoId.
    if (!info.shortDescription.length && videoId.length) {
        NSString *capturedVideoId = [videoId copy];
        YTMULyricsSearchInfo *infoSnapshot = [info copy];
        [[YTMUInnerTubeDescriptionFetcher sharedFetcher]
            fetchDescriptionForVideoId:capturedVideoId
                            completion:^(NSString *_Nullable description, NSError *_Nullable error) {
            if (!description.length) return; // empty = video has no description, or fetch failed

            // Dedup re-refreshes: the same videoId can have multiple
            // metadata-refresh calls all queue a callback during a
            // single in-flight fetch. We only want one re-refresh per
            // videoId per process lifetime. The fetcher's disk cache
            // takes over for subsequent plays.
            static NSMutableSet<NSString *> *injectedVideoIds;
            static dispatch_once_t injectOnce;
            dispatch_once(&injectOnce, ^{ injectedVideoIds = [NSMutableSet set]; });
            @synchronized (injectedVideoIds) {
                if ([injectedVideoIds containsObject:capturedVideoId]) return;
                [injectedVideoIds addObject:capturedVideoId];
            }

            NSString *capped = description.length > 32 * 1024
                ? [description substringToIndex:32 * 1024]
                : description;
            YTMULyricsSearchInfo *updated = [infoSnapshot copy];
            updated.shortDescription = capped;
            YTMULyricsLog(@"innertube description injected videoId=%@ len=%lu — re-running refresh",
                          capturedVideoId, (unsigned long)capped.length);
            [[YTMULyricsManager sharedManager] refreshWithInfo:updated];
        }];
    }

    return YES;
}

static char YTMUPlayerRefreshRetryTokenKey;

static void YTMUSchedulePlayerRefreshRetries(YTPlayerViewController *player, NSString *source) {
    if (!player) return;
    NSUInteger token = [objc_getAssociatedObject(player, &YTMUPlayerRefreshRetryTokenKey) unsignedIntegerValue] + 1;
    objc_setAssociatedObject(player, &YTMUPlayerRefreshRetryTokenKey, @(token), OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    NSArray<NSNumber *> *delays = @[@0.25, @0.75, @1.5, @2.5];
    __weak YTPlayerViewController *weakPlayer = player;
    for (NSUInteger idx = 0; idx < delays.count; idx++) {
        NSTimeInterval delay = delays[idx].doubleValue;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            YTPlayerViewController *strongPlayer = weakPlayer;
            if (!strongPlayer) return;
            if ([objc_getAssociatedObject(strongPlayer, &YTMUPlayerRefreshRetryTokenKey) unsignedIntegerValue] != token) return;
            NSString *retrySource = [NSString stringWithFormat:@"%@.retry%lu", source ?: @"player", (unsigned long)(idx + 1)];
            YTMURefreshLyricsFromPlayer(strongPlayer, retrySource, NO);
        });
    }
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
                if (YTMULyricsDebugLoggingEnabled()) {
                    YTMULyricsLog(@"no player candidate source=%@ object=%@", source, YTMUClassAndPointer(candidate));
                }
            }
        }
        return;
    }

    if ([player respondsToSelector:@selector(ytmu_attachSyncedLyricsViewIfNeeded)]) {
        [player ytmu_attachSyncedLyricsViewIfNeeded];
    }
    [[YTMULyricsPlaybackState sharedState] notePlayerViewController:player];
    YTMURefreshLyricsFromPlayer(player, source, force);
    if (force) YTMUSchedulePlayerRefreshRetries(player, source);
}

static NSString *YTMUHasSelector(Class cls, SEL selector) {
    return (cls && [cls instancesRespondToSelector:selector]) ? @"YES" : @"NO";
}

static void YTMULogInterestingSelectors(Class cls) {
    if (!YTMULyricsDebugLoggingEnabled()) return;
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

    YTMULyricsLog(@"runtime selectors class=%@ count=%u interesting=%@",
                  NSStringFromClass(cls),
                  count,
                  names.count ? [names componentsJoinedByString:@", "] : @"<none>");
}

static void YTMULogRuntimeDiagnostics(void) {
    if (!YTMULyricsDebugLoggingEnabled()) return;
    YTMULyricsLog(@"build stamp %s %s", __DATE__, __TIME__);

    NSArray<NSString *> *classes = @[
        @"YTPlayerViewController",
        @"YTMWatchViewController",
        @"YTMNowPlayingViewController",
        @"YTMPlayerViewController",
        @"YTMPlayerTabViewController"
    ];
    for (NSString *name in classes) {
        Class cls = NSClassFromString(name);
        YTMULyricsLog(@"runtime class %@ present=%@ viewDidAppear=%@ viewDidLayout=%@ playerVC=%@ didActivate3=%@ pvDidActivate=%@ timeSingle=%@ timePotential=%@",
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
    if (YTMULyricsDebugLoggingEnabled()) YTMULyricsLog(@"dynamic callback %@ class=%@", NSStringFromSelector(_cmd), NSStringFromClass([self class]));
    YTMUHandlePlayerCandidate(self, NSStringFromSelector(_cmd), YES);
}

static void (*YTMUOrigYTPlayerPlaybackControllerDidActivateVideo)(id, SEL, id);
static void YTMUHookYTPlayerPlaybackControllerDidActivateVideo(id self, SEL _cmd, id arg1) {
    if (YTMUOrigYTPlayerPlaybackControllerDidActivateVideo) {
        YTMUOrigYTPlayerPlaybackControllerDidActivateVideo(self, _cmd, arg1);
    }
    if (YTMULyricsDebugLoggingEnabled()) YTMULyricsLog(@"dynamic callback %@ class=%@", NSStringFromSelector(_cmd), NSStringFromClass([self class]));
    YTMUHandlePlayerCandidate(self, NSStringFromSelector(_cmd), YES);
}

static void (*YTMUOrigWatchPlayerDidActivate)(id, SEL, id, id);
static void YTMUHookWatchPlayerDidActivate(id self, SEL _cmd, id player, id video) {
    if (YTMUOrigWatchPlayerDidActivate) {
        YTMUOrigWatchPlayerDidActivate(self, _cmd, player, video);
    }
    if (YTMULyricsDebugLoggingEnabled()) YTMULyricsLog(@"dynamic callback %@ class=%@ player=%@", NSStringFromSelector(_cmd), NSStringFromClass([self class]), YTMUClassAndPointer(player));
    YTMUHandlePlayerCandidate(player ?: self, NSStringFromSelector(_cmd), YES);
}

static void (*YTMUOrigWatchPlayerActivatedWithVideo)(id, SEL, id, id);
static void YTMUHookWatchPlayerActivatedWithVideo(id self, SEL _cmd, id player, id video) {
    if (YTMUOrigWatchPlayerActivatedWithVideo) {
        YTMUOrigWatchPlayerActivatedWithVideo(self, _cmd, player, video);
    }
    if (YTMULyricsDebugLoggingEnabled()) YTMULyricsLog(@"dynamic callback %@ class=%@ player=%@", NSStringFromSelector(_cmd), NSStringFromClass([self class]), YTMUClassAndPointer(player));
    YTMUHandlePlayerCandidate(player ?: self, NSStringFromSelector(_cmd), YES);
}

static void (*YTMUOrigWatchPlayerDidActivateNewPlayback)(id, SEL, id, id);
static void YTMUHookWatchPlayerDidActivateNewPlayback(id self, SEL _cmd, id player, id video) {
    if (YTMUOrigWatchPlayerDidActivateNewPlayback) {
        YTMUOrigWatchPlayerDidActivateNewPlayback(self, _cmd, player, video);
    }
    if (YTMULyricsDebugLoggingEnabled()) YTMULyricsLog(@"dynamic callback %@ class=%@ player=%@", NSStringFromSelector(_cmd), NSStringFromClass([self class]), YTMUClassAndPointer(player));
    YTMUHandlePlayerCandidate(player ?: self, NSStringFromSelector(_cmd), YES);
}

static void (*YTMUOrigWatchPlayerWillActivate)(id, SEL, id, id);
static void YTMUHookWatchPlayerWillActivate(id self, SEL _cmd, id player, id video) {
    if (YTMUOrigWatchPlayerWillActivate) {
        YTMUOrigWatchPlayerWillActivate(self, _cmd, player, video);
    }
    if (YTMULyricsDebugLoggingEnabled()) YTMULyricsLog(@"dynamic callback %@ class=%@ player=%@", NSStringFromSelector(_cmd), NSStringFromClass([self class]), YTMUClassAndPointer(player));
    YTMUHandlePlayerCandidate(player ?: self, NSStringFromSelector(_cmd), NO);
}

static void YTMUInstallMessageHook(Class cls, SEL selector, IMP replacement, IMP *original, NSString *label) {
    BOOL hasMethod = cls && class_getInstanceMethod(cls, selector) != NULL;
    YTMULyricsLog(@"dynamic hook candidate %@ %@ installed=%@",
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
        YTMULyricsLog(@"hook YTPlayerViewController.viewDidAppear fired (class=%@)", NSStringFromClass([self class]));
    });
    [self ytmu_attachSyncedLyricsViewIfNeeded];
}

- (void)viewDidLayoutSubviews {
    %orig;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        YTMULyricsLog(@"hook YTPlayerViewController.viewDidLayoutSubviews fired");
    });
    [self ytmu_layoutSyncedLyricsView];
}

- (void)playbackController:(id)arg1 didActivateVideo:(id)arg2 withPlaybackData:(id)arg3 {
    %orig;
    YTMULyricsLog(@"hook didActivateVideo class=%@", NSStringFromClass([self class]));
    YTMUHandlePlayerCandidate(self, @"YTPlayerViewController.didActivateVideo", YES);
}

- (void)singleVideo:(id)video currentVideoTimeDidChange:(id)time {
    %orig;
    NSTimeInterval timeMs = YTMUNormalizedPlaybackTimeMs(self);
    [[YTMULyricsPlaybackState sharedState] notePlayerViewController:self];
    [[YTMULyricsPlaybackState sharedState] notePlaybackTimeMs:timeMs];
    [self.ytmuSyncedLyricsView updatePlaybackTimeMs:timeMs];
}

- (void)potentiallyMutatedSingleVideo:(id)video currentVideoTimeDidChange:(id)time {
    %orig;
    NSTimeInterval timeMs = YTMUNormalizedPlaybackTimeMs(self);
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
        YTMULyricsLog(@"synced lyrics view attached player=%@ container=%@", YTMUClassAndPointer(self), YTMUClassAndPointer(self.view));
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
        YTMULyricsLog(@"hook YTMWatchViewController.viewDidAppear fired class=%@", NSStringFromClass([self class]));
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
        YTMULyricsLog(@"hook YTMWatchViewController.viewDidLayoutSubviews fired class=%@", NSStringFromClass([self class]));
    });
    YTMUHandlePlayerCandidate(self, @"YTMWatchViewController.viewDidLayoutSubviews", NO);
}

- (void)playbackControllerStateDidChange {
    %orig;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        YTMULyricsLog(@"hook YTMWatchViewController.playbackControllerStateDidChange fired class=%@", NSStringFromClass([self class]));
    });
    YTMUHandlePlayerCandidate(self, @"YTMWatchViewController.playbackControllerStateDidChange", NO);
}

%end

%hook YTMNowPlayingViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        YTMULyricsLog(@"hook YTMNowPlayingViewController.viewDidAppear fired class=%@", NSStringFromClass([self class]));
    });
    YTMUHandlePlayerCandidate(self, @"YTMNowPlayingViewController.viewDidAppear", NO);
}

- (void)viewDidLayoutSubviews {
    %orig;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        YTMULyricsLog(@"hook YTMNowPlayingViewController.viewDidLayoutSubviews fired class=%@", NSStringFromClass([self class]));
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
    YTMULyricsSetDefault(dict, @"lyricsTimingOffsetMs", @(0));
    YTMULyricsSetDefault(dict, @"lyricsTimingOffsetActiveKey", @"");
    YTMULyricsSetDefault(dict, @"lyricsTimingOffsets", @{});
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
