// H4: the offline scrobble queue must never lose an entry that was enqueued
// while a flush was in flight, and a flush must only remove what it
// actually submitted successfully.
#import "YTMUTestKit.h"
#import "YTMUTestSettings.h"
#import "Scrobbling/YTMUScrobbleManager.h"
#import "Scrobbling/YTMUScrobbleTypes.h"

// Private on the manager; the runtime resolves it, this just lets us call it.
@interface YTMUScrobbleManager (YTMUTesting)
- (void)enqueuePending:(YTMUListen *)listen forProvider:(NSString *)providerId;
@end

// A scrobbler whose batch completions are released by the test.
@interface YTMUTestHeldScrobbler : NSObject <YTMUScrobbler>
@property (nonatomic, copy) NSString *ident;
@property (nonatomic, strong) NSMutableArray<YTMUScrobblerCompletion> *heldBatchCompletions;
@property (nonatomic, strong) NSMutableArray<NSArray<YTMUListen *> *> *submittedBatches;
@end
@implementation YTMUTestHeldScrobbler
- (instancetype)initWithIdentifier:(NSString *)ident {
    self = [super init];
    _ident = [ident copy];
    _heldBatchCompletions = [NSMutableArray array];
    _submittedBatches = [NSMutableArray array];
    return self;
}
- (NSString *)identifier { return self.ident; }
- (BOOL)isEnabled { return YES; }
- (BOOL)isConfigured { return YES; }
- (void)submitNowPlaying:(YTMUListen *)listen {}
- (void)submitScrobble:(YTMUListen *)listen completion:(YTMUScrobblerCompletion)completion { completion(NO, nil); }
- (void)submitBatch:(NSArray<YTMUListen *> *)listens completion:(YTMUScrobblerCompletion)completion {
    [self.submittedBatches addObject:listens];
    [self.heldBatchCompletions addObject:[completion copy]];
}
// Complete the oldest held batch from a background queue, like a real
// NSURLSession completion would.
- (void)releaseOldestBatchWithSuccess:(BOOL)ok {
    YTMUScrobblerCompletion c = self.heldBatchCompletions.firstObject;
    [self.heldBatchCompletions removeObjectAtIndex:0];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{ c(ok, nil); });
}
@end

static YTMUListen *Listen(NSString *track) {
    YTMUListen *l = [[YTMUListen alloc] init];
    l.trackName = track; l.artist = @"Artist"; l.durationSeconds = 200;
    l.startedAtUnix = 1700000000 + track.hash % 1000; l.elapsedPlayedSeconds = 150;
    return l;
}

static NSArray<NSString *> *QueuedTracks(void) {
    NSArray *queue = YTMUTestSettings()[@"scrobble_pendingQueue"];
    NSMutableArray *tracks = [NSMutableArray array];
    for (NSDictionary *entry in queue) [tracks addObject:entry[@"listen"][@"track"] ?: @"?"];
    return tracks;
}

static YTMUScrobbleManager *FreshManager(NSArray *providers) {
    YTMUTestSetSettings(@{@"YTMUltimateIsEnabled": @YES, @"scrobblingEnabled": @YES, @"scrobbleDebugLogs": @NO});
    YTMUScrobbleManager *m = [[YTMUScrobbleManager alloc] init];   // not -start: no observers, no timer
    [m setValue:providers forKey:@"providers"];
    return m;
}

YTMU_TEST(ScrobbleQueue_entryEnqueuedDuringFlush_survivesTheFlush) {
    YTMUTestHeldScrobbler *fake = [[YTMUTestHeldScrobbler alloc] initWithIdentifier:@"fake"];
    YTMUScrobbleManager *m = FreshManager(@[fake]);

    [m enqueuePending:Listen(@"A") forProvider:@"fake"];
    [m flushQueueIfPossible];                              // reads [A], batch in flight
    YTMU_ASSERT_EQ_INT(fake.submittedBatches.count, 1);
    [m enqueuePending:Listen(@"B") forProvider:@"fake"];   // B arrives mid-flush
    [fake releaseOldestBatchWithSuccess:YES];               // A submitted OK
    YTMU_ASSERT(YTMUTestWaitUntil(3, ^BOOL{ return ![QueuedTracks() containsObject:@"A"]; }), "A was never removed");
    YTMUTestWaitUntil(0.2, ^BOOL{ return NO; });            // let any trailing write land
    NSArray *tracks = QueuedTracks();
    YTMU_ASSERT([tracks isEqualToArray:@[@"B"]], "expected [B] left in queue, got %@", tracks);
}

YTMU_TEST(ScrobbleQueue_failedFlush_keepsEntries_successfulFlush_removesOnlyItsProvider) {
    YTMUTestHeldScrobbler *p1 = [[YTMUTestHeldScrobbler alloc] initWithIdentifier:@"p1"];
    YTMUTestHeldScrobbler *p2 = [[YTMUTestHeldScrobbler alloc] initWithIdentifier:@"p2"];
    YTMUScrobbleManager *m = FreshManager(@[p1, p2]);

    [m enqueuePending:Listen(@"X") forProvider:@"p1"];
    [m enqueuePending:Listen(@"Y") forProvider:@"p2"];
    [m flushQueueIfPossible];
    YTMU_ASSERT_EQ_INT(p1.submittedBatches.count, 1);
    YTMU_ASSERT_EQ_INT(p2.submittedBatches.count, 1);
    [p1 releaseOldestBatchWithSuccess:NO];   // p1 offline
    [p2 releaseOldestBatchWithSuccess:YES];  // p2 fine
    YTMU_ASSERT(YTMUTestWaitUntil(3, ^BOOL{ return ![QueuedTracks() containsObject:@"Y"]; }), "Y was never removed");
    YTMUTestWaitUntil(0.2, ^BOOL{ return NO; });
    NSArray *tracks = QueuedTracks();
    YTMU_ASSERT([tracks isEqualToArray:@[@"X"]], "expected [X] (p1 failed) left, got %@", tracks);
}

YTMU_TEST(ScrobbleQueue_invalidEntries_arePrunedOnFlush) {
    YTMUTestHeldScrobbler *fake = [[YTMUTestHeldScrobbler alloc] initWithIdentifier:@"fake"];
    YTMUScrobbleManager *m = FreshManager(@[fake]);
    NSMutableDictionary *settings = [YTMUTestSettings() mutableCopy];
    settings[@"scrobble_pendingQueue"] = @[ @{@"provider": @"fake", @"listen": @{@"garbage": @1}},
                                            @{@"provider": @"fake", @"listen": [Listen(@"Good") serialize]} ];
    YTMUTestSetSettings(settings);
    [m flushQueueIfPossible];
    YTMU_ASSERT_EQ_INT(fake.submittedBatches.count, 1);
    YTMU_ASSERT_EQ_INT(fake.submittedBatches.firstObject.count, 1);
    [fake releaseOldestBatchWithSuccess:YES];
    YTMU_ASSERT(YTMUTestWaitUntil(3, ^BOOL{ return QueuedTracks().count == 0; }), "queue not emptied, left %@", QueuedTracks());
}
