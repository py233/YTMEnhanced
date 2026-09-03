// Scrobbling audit fixes: the offline queue is flushed in chunks of the
// provider's batch limit and only what a chunk sent is removed (A8); a
// flush is never re-entered; the 1 Hz MPNowPlayingInfoCenter poll follows
// the master switch; repeat-one restarts count as a new play (A16).
#import <MediaPlayer/MediaPlayer.h>
#import "YTMUTestKit.h"
#import "YTMUTestSettings.h"
#import "Scrobbling/YTMUScrobbleManager.h"
#import "Scrobbling/YTMUScrobbleTypes.h"
#import "Scrobbling/YTMUPlaybackBroadcaster.h"
#import "Utils/YTMUSettings.h"

@interface YTMUScrobbleManager (YTMUFixTesting)
- (void)enqueuePending:(YTMUListen *)listen forProvider:(NSString *)providerId;
- (void)start;
@end
@interface YTMUPlaybackBroadcaster (YTMUFixTesting)
- (void)tick:(NSTimer *)timer;
@end

// A scrobbler with a batch limit whose completions the test releases.
@interface YTMUTestChunkScrobbler : NSObject <YTMUScrobbler>
@property (nonatomic, copy) NSString *ident;
@property (nonatomic) NSUInteger limit;
@property (nonatomic, strong) NSMutableArray<YTMUScrobblerCompletion> *held;
@property (nonatomic, strong) NSMutableArray<NSArray<YTMUListen *> *> *batches;
@end
@implementation YTMUTestChunkScrobbler
- (instancetype)initWithIdentifier:(NSString *)ident limit:(NSUInteger)limit {
    self = [super init];
    _ident = [ident copy]; _limit = limit;
    _held = [NSMutableArray array]; _batches = [NSMutableArray array];
    return self;
}
- (NSString *)identifier { return self.ident; }
- (BOOL)isEnabled { return YES; }
- (BOOL)isConfigured { return YES; }
- (NSUInteger)maxBatchSize { return self.limit; }
- (void)submitNowPlaying:(YTMUListen *)listen {}
- (void)submitScrobble:(YTMUListen *)listen completion:(YTMUScrobblerCompletion)completion { completion(NO, nil); }
- (void)submitBatch:(NSArray<YTMUListen *> *)listens completion:(YTMUScrobblerCompletion)completion {
    [self.batches addObject:listens];
    [self.held addObject:[completion copy]];
}
- (void)releaseOldest:(BOOL)ok {
    YTMUScrobblerCompletion c = self.held.firstObject;
    [self.held removeObjectAtIndex:0];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{ c(ok, nil); });
}
- (NSArray<NSString *> *)tracksInBatch:(NSUInteger)index {
    NSMutableArray *tracks = [NSMutableArray array];
    for (YTMUListen *l in self.batches[index]) [tracks addObject:l.trackName];
    return tracks;
}
@end

static YTMUListen *ChunkListen(NSString *track) {
    YTMUListen *l = [[YTMUListen alloc] init];
    l.trackName = track; l.artist = @"Artist"; l.durationSeconds = 200;
    l.startedAtUnix = 1700000000 + track.hash % 1000; l.elapsedPlayedSeconds = 150;
    return l;
}

static NSArray<NSString *> *ChunkQueued(void) {
    NSMutableArray *tracks = [NSMutableArray array];
    for (NSDictionary *entry in YTMUTestSettings()[@"scrobble_pendingQueue"]) [tracks addObject:entry[@"listen"][@"track"] ?: @"?"];
    return tracks;
}

static YTMUScrobbleManager *ChunkManager(NSArray *providers) {
    YTMUTestSetSettings(@{@"YTMUltimateIsEnabled": @YES, @"scrobblingEnabled": @YES, @"scrobbleDebugLogs": @NO});
    YTMUScrobbleManager *m = [[YTMUScrobbleManager alloc] init];   // not -start: no observers, no timer
    [m setValue:providers forKey:@"providers"];
    return m;
}

YTMU_TEST(ScrobbleQueue_flushSendsChunksOfTheProviderLimit_andRemovesOnlyWhatWasSent) {
    YTMUTestChunkScrobbler *fake = [[YTMUTestChunkScrobbler alloc] initWithIdentifier:@"fake" limit:3];
    YTMUScrobbleManager *m = ChunkManager(@[fake]);
    for (NSString *t in @[@"A", @"B", @"C", @"D", @"E", @"F", @"G"]) [m enqueuePending:ChunkListen(t) forProvider:@"fake"];

    [m flushQueueIfPossible];
    YTMU_ASSERT_EQ_INT(fake.batches.count, 1);
    YTMU_ASSERT(([[fake tracksInBatch:0] isEqualToArray:@[@"A", @"B", @"C"]]), "first chunk: %@", [fake tracksInBatch:0]);
    YTMU_ASSERT_EQ_INT(ChunkQueued().count, 7);                    // nothing removed before success

    [fake releaseOldest:YES];
    YTMU_ASSERT(YTMUTestWaitUntil(3, ^BOOL{ return fake.batches.count == 2; }), "second chunk never sent");
    YTMU_ASSERT(([ChunkQueued() isEqualToArray:@[@"D", @"E", @"F", @"G"]]), "only the first chunk removed, queue=%@", ChunkQueued());
    YTMU_ASSERT(([[fake tracksInBatch:1] isEqualToArray:@[@"D", @"E", @"F"]]), "second chunk: %@", [fake tracksInBatch:1]);

    [fake releaseOldest:NO];                                        // this chunk fails: G is never attempted now
    YTMUTestWaitUntil(0.4, ^BOOL{ return NO; });
    YTMU_ASSERT_EQ_INT(fake.batches.count, 2);
    YTMU_ASSERT(([ChunkQueued() isEqualToArray:@[@"D", @"E", @"F", @"G"]]), "a failed chunk removes nothing, queue=%@", ChunkQueued());

    [m flushQueueIfPossible];                                       // next flush picks up where it stopped
    YTMU_ASSERT_EQ_INT(fake.batches.count, 3);
    [fake releaseOldest:YES];
    YTMU_ASSERT(YTMUTestWaitUntil(3, ^BOOL{ return fake.batches.count == 4; }), "tail chunk never sent");
    YTMU_ASSERT(([[fake tracksInBatch:3] isEqualToArray:@[@"G"]]), "tail chunk: %@", [fake tracksInBatch:3]);
    [fake releaseOldest:YES];
    YTMU_ASSERT(YTMUTestWaitUntil(3, ^BOOL{ return ChunkQueued().count == 0; }), "queue not drained: %@", ChunkQueued());
}

YTMU_TEST(ScrobbleQueue_flushIsNotReentrant_andRunsAgainWhenAskedMidFlight) {
    YTMUTestChunkScrobbler *fake = [[YTMUTestChunkScrobbler alloc] initWithIdentifier:@"fake" limit:50];
    YTMUScrobbleManager *m = ChunkManager(@[fake]);
    [m enqueuePending:ChunkListen(@"A") forProvider:@"fake"];
    [m flushQueueIfPossible];
    [m flushQueueIfPossible];
    [m flushQueueIfPossible];
    YTMU_ASSERT_EQ_INT(fake.batches.count, 1);                     // overlapping flushes never double-submit
    [m enqueuePending:ChunkListen(@"B") forProvider:@"fake"];
    [m flushQueueIfPossible];                                       // asked while in flight: deferred, not dropped
    YTMU_ASSERT_EQ_INT(fake.batches.count, 1);
    [fake releaseOldest:YES];
    YTMU_ASSERT(YTMUTestWaitUntil(3, ^BOOL{ return fake.batches.count == 2; }), "deferred flush never ran");
    YTMU_ASSERT(([[fake tracksInBatch:1] isEqualToArray:@[@"B"]]), "deferred flush content: %@", [fake tracksInBatch:1]);
    [fake releaseOldest:YES];
    YTMU_ASSERT(YTMUTestWaitUntil(3, ^BOOL{ return ChunkQueued().count == 0; }), "queue not drained: %@", ChunkQueued());
}

YTMU_TEST(Scrobble_pollerFollowsTheMasterSwitch) {
    YTMUTestSetSettings(@{@"YTMUltimateIsEnabled": @YES, @"scrobblingEnabled": @NO, @"scrobbleDebugLogs": @NO});
    YTMUPlaybackBroadcaster *broadcaster = [YTMUPlaybackBroadcaster sharedBroadcaster];
    [broadcaster stop];
    YTMUScrobbleManager *m = [[YTMUScrobbleManager alloc] init];
    [m start];
    YTMU_ASSERT(!broadcaster.isRunning, "poll must not run while scrobbling is off");
    YTMUSettingsSetObject(@"scrobblingEnabled", @YES);
    YTMU_ASSERT(YTMUTestWaitUntil(2, ^BOOL{ return broadcaster.isRunning; }), "poll did not start when scrobbling was switched on");
    YTMUSettingsSetObject(@"scrobblingEnabled", @NO);
    YTMU_ASSERT(YTMUTestWaitUntil(2, ^BOOL{ return !broadcaster.isRunning; }), "poll did not stop when scrobbling was switched off");
    (void)m;
}

YTMU_TEST(Scrobble_repeatOneRestart_countsAsANewPlay) {
    YTMUTestSetSettings(@{@"YTMUltimateIsEnabled": @YES, @"scrobblingEnabled": @NO, @"scrobbleDebugLogs": @NO});
    YTMUPlaybackBroadcaster *b = [[YTMUPlaybackBroadcaster alloc] init];
    __block NSInteger changes = 0;
    __block YTMUListen *lastPrevious = nil;
    __block YTMUListen *lastNext = nil;
    id token = [[NSNotificationCenter defaultCenter] addObserverForName:YTMUPlaybackTrackChangedNotification object:b queue:nil usingBlock:^(NSNotification *n) {
        changes++;
        lastPrevious = n.userInfo[kYTMUPlaybackUserInfoPreviousListen];
        lastNext = n.userInfo[kYTMUPlaybackUserInfoListen];
    }];
    MPNowPlayingInfoCenter *center = [MPNowPlayingInfoCenter defaultCenter];
    NSDictionary *(^info)(double) = ^NSDictionary *(double elapsed) {
        return @{MPMediaItemPropertyTitle: @"Song", MPMediaItemPropertyArtist: @"Artist", MPMediaItemPropertyPlaybackDuration: @200.0,
                 MPNowPlayingInfoPropertyPlaybackRate: @1.0, MPNowPlayingInfoPropertyElapsedPlaybackTime: @(elapsed)};
    };
    center.nowPlayingInfo = info(100); [b tick:nil];
    YTMU_ASSERT(changes == 1 && lastPrevious == nil && [lastNext.trackName isEqualToString:@"Song"], "first observation is a track change (changes=%ld)", (long)changes);
    YTMUListen *firstPlay = lastNext;
    center.nowPlayingInfo = info(101); [b tick:nil];                 // normal progress
    center.nowPlayingInfo = info(95); [b tick:nil];                  // a seek back into the song is not a new play
    YTMU_ASSERT_EQ_INT(changes, 1);
    center.nowPlayingInfo = info(0.4); [b tick:nil];                 // back at the start after being deep in: repeat-one
    YTMU_ASSERT(changes == 2 && lastPrevious == firstPlay && lastNext != firstPlay && [lastNext.trackName isEqualToString:@"Song"],
                "restart must hand the first play over as previous (changes=%ld)", (long)changes);
    center.nowPlayingInfo = info(1.4); [b tick:nil];                 // progressing from the start: nothing new
    YTMU_ASSERT_EQ_INT(changes, 2);
    [[NSNotificationCenter defaultCenter] removeObserver:token];
    center.nowPlayingInfo = nil;
}
