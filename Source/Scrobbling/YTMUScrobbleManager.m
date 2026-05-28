#import "YTMUScrobbleManager.h"
#import "YTMUPlaybackBroadcaster.h"
#import "Providers/YTMULastFMScrobbler.h"
#import "Providers/YTMUListenBrainzScrobbler.h"
#import <UIKit/UIKit.h>

// Hold off on submitting now-playing this long after a track change.
// Filters out the "user fast-skipped through three songs in two
// seconds" case where every transient track would otherwise post a
// spurious now-playing to last.fm/ListenBrainz that immediately gets
// overwritten by the next one. 4 s is short enough that real users
// don't notice the latency on a track they actually listen to.
static const NSTimeInterval kNowPlayingDelaySeconds = 4.0;

@interface YTMUScrobbleManager ()
@property (nonatomic, strong) YTMULastFMScrobbler *lastfm;
@property (nonatomic, strong) YTMUListenBrainzScrobbler *listenbrainz;

// All providers in a single array so the broadcast handlers can just
// loop. Keep the concrete-property variants above for the settings
// UI which needs to call provider-specific auth/validate methods.
@property (nonatomic, strong) NSArray<id<YTMUScrobbler>> *providers;

// The listen most recently emitted by the broadcaster — kept here
// for two reasons: (1) decide what to scrobble on the next track-
// change event, (2) re-fire now-playing if user resumes from pause.
@property (nonatomic, strong, nullable) YTMUListen *currentListen;

// Latch so we only fire scrobble once per track even if the
// broadcaster keeps the same listen around (e.g. user pauses well
// past the threshold, comes back, then track ends).
@property (nonatomic) BOOL currentScrobbled;

// Defensive guard against double-registration. dispatch_once on the
// singleton should be sufficient, but the duplicate-handler symptom
// observed during testing (every notification firing twice from
// 14:05 onward) is consistent with `start` running twice. With this
// flag, even if it does, observers register exactly once.
@property (nonatomic) BOOL started;

// Token that increments on every track change. The deferred
// now-playing block captures the token at schedule time and only
// fires if it still matches when the timer elapses — so a faster
// track change cancels the pending now-playing implicitly.
@property (nonatomic) NSInteger nowPlayingScheduleToken;

// Wall-clock time of the most recent successful now-playing submit.
// Used to gate the state-change-resume code path so it only refreshes
// the API's display when the user is truly resuming from a long pause
// (rather than each fresh-track state=YES, which would defeat the
// track-change deferred throttle).
@property (nonatomic) NSTimeInterval lastNowPlayingSubmitTime;
@end

// Minimum wall-clock seconds since the last now-playing submit before
// we'll re-fire from the state-change-resume path. last.fm and
// ListenBrainz typically time out their "now playing" display around
// 5 min of silence; 60 s is well under that and avoids re-firing on
// any normal play-pause-play within the same listening session.
static const NSTimeInterval kNowPlayingResumeMinGapSeconds = 60.0;

// And: don't even consider state-change-resume firing until the
// current track has actually been heard for this long. Tracks just
// jumped to via skip will have elapsedPlayedSeconds near 0 and the
// track-change deferred is the right path for those.
static const NSTimeInterval kNowPlayingResumeMinElapsedSeconds = 4.0;

@implementation YTMUScrobbleManager

+ (instancetype)sharedManager {
    static YTMUScrobbleManager *manager;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        manager = [[self alloc] init];
        [manager start];
    });
    return manager;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _lastfm = [[YTMULastFMScrobbler alloc] init];
        _listenbrainz = [[YTMUListenBrainzScrobbler alloc] init];
        _providers = @[_lastfm, _listenbrainz];
    }
    return self;
}

- (void)start {
    if (self.started) {
        YTMUScrobbleLog(@"manager start ignored: already started");
        return;
    }
    self.started = YES;
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    // Belt-and-suspenders: remove any prior registrations under our
    // names before adding. NSNotificationCenter de-duplicates by
    // (observer, selector, name, object) tuple, but a removeObserver
    // first guarantees no leftover from an earlier dylib lifecycle.
    [nc removeObserver:self name:YTMUPlaybackTrackChangedNotification object:nil];
    [nc removeObserver:self name:YTMUPlaybackStateChangedNotification object:nil];
    [nc removeObserver:self name:UIApplicationDidBecomeActiveNotification object:nil];
    [nc addObserver:self selector:@selector(handleTrackChanged:)
               name:YTMUPlaybackTrackChangedNotification object:nil];
    [nc addObserver:self selector:@selector(handleStateChanged:)
               name:YTMUPlaybackStateChangedNotification object:nil];
    // Foreground transition = good moment to retry anything that
    // failed while the device was offline. iOS may resume the app
    // after a network gap without giving us a "reachability is back"
    // signal directly.
    [nc addObserver:self selector:@selector(handleAppDidBecomeActive:)
               name:UIApplicationDidBecomeActiveNotification object:nil];
    [[YTMUPlaybackBroadcaster sharedBroadcaster] start];
    YTMUScrobbleLog(@"manager start providers=%lu master=%@",
                    (unsigned long)self.providers.count,
                    self.isMasterEnabled ? @"ON" : @"OFF");
    // Flush any leftover queue from a previous app lifetime / network
    // outage. flushQueueIfPossible bails early when empty or when the
    // master switch is off, so this is cheap if there's nothing to do.
    [self flushQueueIfPossible];
}

- (void)handleAppDidBecomeActive:(NSNotification *)note {
    YTMUScrobbleLog(@"app foreground; attempting queue flush");
    [self flushQueueIfPossible];
}

- (BOOL)isMasterEnabled {
    return YTMUScrobbleDefaultsBool(@"scrobblingEnabled", NO);
}

#pragma mark - Notification handlers

- (void)handleTrackChanged:(NSNotification *)note {
    YTMUListen *previous = note.userInfo[kYTMUPlaybackUserInfoPreviousListen];
    YTMUListen *next = note.userInfo[kYTMUPlaybackUserInfoListen];

    // First: evaluate the previous track against the scrobble
    // threshold. If it's eligible and we haven't already scrobbled
    // it on this run, submit it.
    if (previous && !self.currentScrobbled && [previous hasReachedScrobbleThreshold]) {
        YTMUScrobbleLog(@"prev track reached threshold; scrobbling track=\"%@\" elapsed=%.1fs",
                        previous.trackName, previous.elapsedPlayedSeconds);
        [self submitScrobbleForListen:previous];
    } else if (previous) {
        YTMUScrobbleLog(@"prev track skipped (elapsed=%.1fs threshold not met)", previous.elapsedPlayedSeconds);
    }

    // Then advance to the new track and defer the now-playing
    // submission so a rapid skip-skip-skip pattern doesn't spam each
    // transient title to the API.
    self.currentListen = next;
    self.currentScrobbled = NO;
    self.nowPlayingScheduleToken += 1;
    NSInteger token = self.nowPlayingScheduleToken;
    if (!next || ![next hasMinimumMetadata]) return;

    __weak typeof(self) weakSelf = self;
    YTMUListen *captured = next;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kNowPlayingDelaySeconds * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (token != strongSelf.nowPlayingScheduleToken) {
            YTMUScrobbleLog(@"now-playing canceled (newer track took over) track=\"%@\"", captured.trackName);
            return;
        }
        if (strongSelf.currentListen != captured) {
            // Identity check: same object means the broadcaster has
            // not produced a newer track since we scheduled this.
            return;
        }
        [strongSelf submitNowPlayingForListen:captured];
    });
}

- (void)handleStateChanged:(NSNotification *)note {
    BOOL isPlaying = [note.userInfo[kYTMUPlaybackUserInfoIsPlaying] boolValue];
    if (isPlaying && self.currentListen && [self.currentListen hasMinimumMetadata]) {
        // Re-fire now-playing only when this looks like a real
        // resume-from-pause: enough wall-clock time since the last
        // submit (so the API's display has likely timed out), AND
        // the track has actually been played long enough to be more
        // than a transient skip. Fresh track starts hit this branch
        // too (broadcaster emits state=YES on the first tick after a
        // track change) but the elapsed-played check filters those
        // out — the track-change deferred is the right path for them.
        NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
        NSTimeInterval sinceLast = now - self.lastNowPlayingSubmitTime;
        if (sinceLast > kNowPlayingResumeMinGapSeconds
            && self.currentListen.elapsedPlayedSeconds > kNowPlayingResumeMinElapsedSeconds) {
            YTMUScrobbleLog(@"state resume now-playing refresh track=\"%@\" sinceLast=%.0fs elapsed=%.1fs",
                            self.currentListen.trackName, sinceLast, self.currentListen.elapsedPlayedSeconds);
            [self submitNowPlayingForListen:self.currentListen];
        }
    }
    if (!isPlaying && self.currentListen && !self.currentScrobbled
        && [self.currentListen hasReachedScrobbleThreshold]) {
        // User stopped playback after passing the threshold. Most
        // services treat this as a completed listen — fire it now
        // rather than waiting for a track-change that may never come.
        YTMUScrobbleLog(@"paused past threshold; scrobbling current");
        [self submitScrobbleForListen:self.currentListen];
        self.currentScrobbled = YES;
    }
}

#pragma mark - Submissions

- (void)submitNowPlayingForListen:(YTMUListen *)listen {
    if (![self isMasterEnabled]) return;
    // Record submit time before dispatching the requests — they are
    // fire-and-forget at the provider layer, so we can't gate on a
    // server response. The wall-clock stamp is "we attempted to send
    // a now-playing for this track at time X", which is what the
    // resume-detection logic in handleStateChanged actually needs.
    self.lastNowPlayingSubmitTime = [NSDate timeIntervalSinceReferenceDate];
    for (id<YTMUScrobbler> provider in self.providers) {
        [provider submitNowPlaying:listen];
    }
}

- (void)submitScrobbleForListen:(YTMUListen *)listen {
    if (![self isMasterEnabled]) return;
    YTMUListen *snapshot = [listen copy];
    self.currentScrobbled = YES;
    __weak typeof(self) weakSelf = self;
    for (id<YTMUScrobbler> provider in self.providers) {
        if (![provider isEnabled] || ![provider isConfigured]) continue;
        NSString *pid = [provider identifier];
        [provider submitScrobble:snapshot completion:^(BOOL ok, NSError *err) {
            if (ok) {
                YTMUScrobbleLog(@"scrobble ok provider=%@ track=\"%@\"", pid, snapshot.trackName);
                // A successful submission proves the network is back
                // up. Hop onto main to drain anything that piled up
                // while it was down.
                dispatch_async(dispatch_get_main_queue(), ^{
                    [weakSelf flushQueueIfPossible];
                });
            } else {
                YTMUScrobbleLog(@"scrobble failed provider=%@ err=%@ → queue", pid, err.localizedDescription);
                [weakSelf enqueuePending:snapshot forProvider:pid];
            }
        }];
    }
}

#pragma mark - Offline queue

- (NSString *)pendingQueueKey {
    return @"scrobble_pendingQueue";
}

- (NSArray<NSDictionary *> *)readPendingQueue {
    NSDictionary *dict = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"YTMUltimate"] ?: @{};
    id queue = dict[[self pendingQueueKey]];
    return [queue isKindOfClass:[NSArray class]] ? queue : @[];
}

- (void)writePendingQueue:(NSArray<NSDictionary *> *)queue {
    YTMUScrobbleSetDefaults([self pendingQueueKey], queue ?: @[]);
}

- (void)enqueuePending:(YTMUListen *)listen forProvider:(NSString *)providerId {
    NSMutableArray *queue = [[self readPendingQueue] mutableCopy] ?: [NSMutableArray array];
    [queue addObject:@{@"provider": providerId, @"listen": [listen serialize]}];
    // Cap queue size to avoid runaway defaults growth in pathological
    // offline scenarios. Oldest entries get dropped first.
    static const NSUInteger kQueueMax = 500;
    if (queue.count > kQueueMax) {
        [queue removeObjectsInRange:NSMakeRange(0, queue.count - kQueueMax)];
    }
    [self writePendingQueue:queue];
}

- (void)flushQueueIfPossible {
    NSArray<NSDictionary *> *queue = [self readPendingQueue];
    if (queue.count == 0) return;
    if (![self isMasterEnabled]) return;

    // Split by provider, batch-submit each, remove on success.
    NSMutableDictionary<NSString *, NSMutableArray<YTMUListen *> *> *byProvider = [NSMutableDictionary dictionary];
    NSMutableArray<NSDictionary *> *invalid = [NSMutableArray array];
    for (NSDictionary *entry in queue) {
        NSString *pid = entry[@"provider"];
        YTMUListen *listen = [YTMUListen deserialize:entry[@"listen"]];
        if (!pid || !listen) {
            [invalid addObject:entry];
            continue;
        }
        if (!byProvider[pid]) byProvider[pid] = [NSMutableArray array];
        [byProvider[pid] addObject:listen];
    }
    YTMUScrobbleLog(@"queue flush start total=%lu", (unsigned long)queue.count);

    __block NSMutableArray<NSDictionary *> *remaining = [queue mutableCopy];
    // Strip invalid up front so they never recycle.
    [remaining removeObjectsInArray:invalid];

    dispatch_group_t group = dispatch_group_create();
    for (NSString *pid in byProvider) {
        id<YTMUScrobbler> provider = [self providerWithIdentifier:pid];
        if (!provider || ![provider isEnabled] || ![provider isConfigured]) continue;
        NSArray<YTMUListen *> *listens = byProvider[pid];
        dispatch_group_enter(group);
        [provider submitBatch:listens completion:^(BOOL ok, NSError *err) {
            if (ok) {
                YTMUScrobbleLog(@"queue flush ok provider=%@ count=%lu", pid, (unsigned long)listens.count);
                [remaining filterUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *entry, NSDictionary *_) {
                    return ![entry[@"provider"] isEqualToString:pid];
                }]];
            } else {
                YTMUScrobbleLog(@"queue flush fail provider=%@ err=%@", pid, err.localizedDescription);
            }
            dispatch_group_leave(group);
        }];
    }
    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        [self writePendingQueue:remaining];
    });
}

- (nullable id<YTMUScrobbler>)providerWithIdentifier:(NSString *)identifier {
    for (id<YTMUScrobbler> provider in self.providers) {
        if ([[provider identifier] isEqualToString:identifier]) return provider;
    }
    return nil;
}

#pragma mark - Auto-init

+ (void)load {
    // Defer to next runloop iteration so UIKit / MediaPlayer have
    // finished initializing inside the host app before we start
    // polling. Avoids racing nowPlayingInfoCenter at tweak load.
    dispatch_async(dispatch_get_main_queue(), ^{
        [YTMUScrobbleManager sharedManager];
    });
}

@end
