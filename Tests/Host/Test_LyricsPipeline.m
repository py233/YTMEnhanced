// Characterisation of YTMULyricsManager's provider pipeline with scripted
// providers: these pin the behaviour every later refactor must preserve.
#import "YTMUTestKit.h"
#import "YTMUTestSettings.h"
#import "YTMUTestFakeLyricsProvider.h"
#import "YTMUTestFakeLLM.h"
#import "Lyrics/YTMULyricsManager.h"
#import "Lyrics/YTMULyricsCache.h"
#import "Lyrics/YTMULyricsTitleNormalizer.h"
#import "Translation/YTMUTranslator.h"

static YTMULyricsManager *ManagerWithProviders(NSArray *providers, NSDictionary *extraSettings) {
    NSMutableDictionary *settings = [@{
        @"YTMUltimateIsEnabled": @YES,
        @"syncedLyricsEnabled": @YES,
        @"lyricsTranslationEnabled": @NO,
        @"lyricsRomanization": @NO,
        @"lyricsPreferredSource": @"auto",
        @"lyricsShowInexact": @YES,
        @"translationProvider": @"google-translate",   // no LLM → no normalize re-pass
        @"translationDebugLogs": @NO,
    } mutableCopy];
    [settings addEntriesFromDictionary:extraSettings ?: @{}];
    YTMUTestSetSettings(settings);
    YTMULyricsManager *m = [YTMULyricsManager sharedManager];
    [m clearCurrent];
    [[YTMULyricsCache sharedCache] clearAll];
    [m setValue:providers forKey:@"providers"];
    return m;
}

static BOOL WaitForState(YTMULyricsManager *m, YTMULyricsFetchState state, NSTimeInterval timeout) {
    return YTMUTestWaitUntil(timeout, ^BOOL{ return m.state == state; });
}

static BOOL WaitForAvailability(YTMULyricsManager *m, NSString *source, NSString *value, NSTimeInterval timeout) {
    return YTMUTestWaitUntil(timeout, ^BOOL{ return [m.sourceAvailability[source] isEqualToString:value]; });
}

YTMU_TEST(Pipeline_firstSyncedSimilarHit_wins_andOthersAreProbed) {
    YTMUTestFakeLyricsProvider *p1 = [[YTMUTestFakeLyricsProvider alloc] initWithName:@"P1"];
    YTMUTestFakeLyricsProvider *p2 = [[YTMUTestFakeLyricsProvider alloc] initWithName:@"P2"];
    YTMUTestFakeLyricsProvider *p3 = [[YTMUTestFakeLyricsProvider alloc] initWithName:@"P3"];
    p1.result = YTMUTestSyncedResult(@"P1", @"Song Title", @"Artist", 12);
    p2.result = YTMUTestSyncedResult(@"P2", @"Song Title", @"Artist", 12);
    p3.result = nil;
    YTMULyricsManager *m = ManagerWithProviders(@[p1, p2, p3], nil);

    [m refreshWithInfo:YTMUTestInfo(@"v1", @"Song Title", @"Artist")];
    YTMU_ASSERT(WaitForState(m, YTMULyricsFetchStateDone, 5), "never reached Done");
    YTMU_ASSERT_EQ_STR(m.currentResult.sourceName, @"P1");
    YTMU_ASSERT_EQ_INT(m.currentResult.lines.count, 12);
    // probe pass settles the others' status indicators
    YTMU_ASSERT(WaitForAvailability(m, @"P2", @"hit", 5), "P2 should be probed as hit, got %@", m.sourceAvailability);
    YTMU_ASSERT(WaitForAvailability(m, @"P3", @"miss", 5), "P3 should be probed as miss, got %@", m.sourceAvailability);
    YTMU_ASSERT_EQ_STR(m.sourceAvailability[@"P1"], @"hit");
    YTMU_ASSERT_EQ_INT(p1.searchCount, 1);
}

YTMU_TEST(Pipeline_secondRefreshSameSong_isServedFromDiskCache) {
    YTMUTestFakeLyricsProvider *p1 = [[YTMUTestFakeLyricsProvider alloc] initWithName:@"P1"];
    p1.result = YTMUTestSyncedResult(@"P1", @"Cached Song", @"Artist", 6);
    YTMULyricsManager *m = ManagerWithProviders(@[p1], nil);
    [m refreshWithInfo:YTMUTestInfo(@"v-cache", @"Cached Song", @"Artist")];
    YTMU_ASSERT(WaitForState(m, YTMULyricsFetchStateDone, 5), "first refresh never completed");
    YTMU_ASSERT_EQ_INT(p1.searchCount, 1);
    // let the async cache write land
    YTMU_ASSERT(YTMUTestWaitUntil(3, ^BOOL{
        NSString *key = [YTMULyricsCache cacheKeyForInfo:YTMUTestInfo(@"v-cache", @"Cached Song", @"Artist") source:@"P1"];
        [[YTMULyricsCache sharedCache] performSelector:@selector(clearMemoryCache)];
        return [[YTMULyricsCache sharedCache] resultForKey:key] != nil;
    }), "result never reached the disk cache");

    [m clearCurrent];
    p1.result = nil;   // provider would now miss — cache must answer instead
    [m refreshWithInfo:YTMUTestInfo(@"v-cache", @"Cached Song", @"Artist")];
    YTMU_ASSERT(WaitForState(m, YTMULyricsFetchStateDone, 5), "cached refresh never completed");
    YTMU_ASSERT_EQ_STR(m.currentResult.sourceName, @"P1");
    YTMU_ASSERT_EQ_INT(p1.searchCount, 1);   // not searched again
}

YTMU_TEST(Pipeline_wrongSongHit_isDiscarded_plainSimilarBecomesFallback_syncedSimilarWins) {
    YTMUTestFakeLyricsProvider *p1 = [[YTMUTestFakeLyricsProvider alloc] initWithName:@"P1"];
    YTMUTestFakeLyricsProvider *p2 = [[YTMUTestFakeLyricsProvider alloc] initWithName:@"P2"];
    YTMUTestFakeLyricsProvider *p3 = [[YTMUTestFakeLyricsProvider alloc] initWithName:@"P3"];
    p1.result = YTMUTestSyncedResult(@"P1", @"Completely Different Track", @"Somebody Else", 10);
    p2.result = YTMUTestPlainResult(@"P2", @"Right Song", @"Artist", 10);
    p3.result = YTMUTestSyncedResult(@"P3", @"Right Song", @"Artist", 10);
    YTMULyricsManager *m = ManagerWithProviders(@[p1, p2, p3], nil);

    [m refreshWithInfo:YTMUTestInfo(@"v2", @"Right Song", @"Artist")];
    YTMU_ASSERT(WaitForState(m, YTMULyricsFetchStateDone, 5), "never reached Done");
    YTMU_ASSERT_EQ_STR(m.currentResult.sourceName, @"P3");
    YTMU_ASSERT(WaitForAvailability(m, @"P1", @"miss", 5), "wrong-song P1 must read as miss, got %@", m.sourceAvailability);
}

YTMU_TEST(Pipeline_onlyPlainSimilar_isUsedAsFallbackWhenSyncedRequested) {
    YTMUTestFakeLyricsProvider *p1 = [[YTMUTestFakeLyricsProvider alloc] initWithName:@"P1"];
    YTMUTestFakeLyricsProvider *p2 = [[YTMUTestFakeLyricsProvider alloc] initWithName:@"P2"];
    p1.result = YTMUTestPlainResult(@"P1", @"Only Plain", @"Artist", 9);
    p2.result = nil;
    YTMULyricsManager *m = ManagerWithProviders(@[p1, p2], nil);
    [m refreshWithInfo:YTMUTestInfo(@"v3", @"Only Plain", @"Artist")];
    YTMU_ASSERT(WaitForState(m, YTMULyricsFetchStateDone, 5), "never reached Done");
    YTMU_ASSERT_EQ_STR(m.currentResult.sourceName, @"P1");
    YTMU_ASSERT(!m.currentResult.isSynced, "expected the plain fallback");
}

YTMU_TEST(Pipeline_pinnedSource_isAskedFirst_andPlainIsAccepted) {
    YTMUTestFakeLyricsProvider *p1 = [[YTMUTestFakeLyricsProvider alloc] initWithName:@"P1"];
    YTMUTestFakeLyricsProvider *p2 = [[YTMUTestFakeLyricsProvider alloc] initWithName:@"P2"];
    p1.result = YTMUTestSyncedResult(@"P1", @"Pinned", @"Artist", 8);
    p2.result = YTMUTestPlainResult(@"P2", @"Pinned", @"Artist", 8);
    YTMULyricsManager *m = ManagerWithProviders(@[p1, p2], @{@"lyricsPreferredSource": @"P2"});
    [m refreshWithInfo:YTMUTestInfo(@"v4", @"Pinned", @"Artist")];
    YTMU_ASSERT(WaitForState(m, YTMULyricsFetchStateDone, 5), "never reached Done");
    YTMU_ASSERT_EQ_STR(m.currentResult.sourceName, @"P2");
    YTMU_ASSERT(!m.currentResult.isSynced, "pinned plain result must be used as-is");
}

YTMU_TEST(Pipeline_allMiss_endsInErrorState) {
    YTMUTestFakeLyricsProvider *p1 = [[YTMUTestFakeLyricsProvider alloc] initWithName:@"P1"];
    YTMUTestFakeLyricsProvider *p2 = [[YTMUTestFakeLyricsProvider alloc] initWithName:@"P2"];
    p2.error = [NSError errorWithDomain:@"t" code:1 userInfo:@{NSLocalizedDescriptionKey: @"boom"}];
    YTMULyricsManager *m = ManagerWithProviders(@[p1, p2], nil);
    [m refreshWithInfo:YTMUTestInfo(@"v5", @"Nothing", @"Nobody")];
    YTMU_ASSERT(WaitForState(m, YTMULyricsFetchStateError, 5), "never reached Error");
    YTMU_ASSERT(m.currentResult == nil, "no result expected");
    YTMU_ASSERT([m.lastErrorMessage containsString:@"boom"], "error message should carry provider error, got %@", m.lastErrorMessage);
}

YTMU_TEST(Pipeline_staleResponse_isDroppedAfterNewerRefresh) {
    YTMUTestFakeLyricsProvider *slow = [[YTMUTestFakeLyricsProvider alloc] initWithName:@"Slow"];
    slow.result = YTMUTestSyncedResult(@"Slow", @"First Song", @"Artist", 5);
    slow.delay = 0.4;
    YTMULyricsManager *m = ManagerWithProviders(@[slow], nil);
    [m refreshWithInfo:YTMUTestInfo(@"old", @"First Song", @"Artist")];
    // Before the slow answer lands, the user skips to another song.
    YTMUTestWaitUntil(0.1, ^BOOL{ return NO; });
    slow.result = YTMUTestSyncedResult(@"Slow", @"Second Song", @"Artist", 7);
    [m refreshWithInfo:YTMUTestInfo(@"new", @"Second Song", @"Artist")];
    YTMU_ASSERT(YTMUTestWaitUntil(5, ^BOOL{ return m.state == YTMULyricsFetchStateDone && m.currentResult.lines.count == 7; }),
                "second song's result never applied (state=%ld lines=%lu)", (long)m.state, (unsigned long)m.currentResult.lines.count);
    YTMUTestWaitUntil(0.6, ^BOOL{ return NO; });   // let the stale answer arrive
    YTMU_ASSERT_EQ_STR(m.activeVideoId, @"new");
    YTMU_ASSERT_EQ_INT(m.currentResult.lines.count, 7);
}

YTMU_TEST(Pipeline_lowQualityRaw_triggersNormalizeRepass_andBetterHitReplacesIt) {
    // P1 hits with a plain result (not high quality when synced requested);
    // P2 only knows the song under its canonical title, which the fake LLM
    // supplies. The re-pass must find P2 and replace P1.
    YTMUTestFakeLyricsProvider *p1 = [[YTMUTestFakeLyricsProvider alloc] initWithName:@"P1"];
    YTMUTestFakeLyricsProvider *p2 = [[YTMUTestFakeLyricsProvider alloc] initWithName:@"P2"];
    p1.result = YTMUTestPlainResult(@"P1", @"【MV】ハテ (Official)", @"Uploader Channel", 10);
    p2.result = nil;
    YTMUTestFakeLLM *llm = [[YTMUTestFakeLLM alloc] init];
    llm.responseText = @"{\"title_primary\":\"ハテ\",\"title_alts\":[],\"artist_primary\":\"Qeiru\",\"artist_alts\":[],\"language\":\"ja\",\"confidence\":0.9}";
    [[YTMUTranslator sharedTranslator] setValue:@{@"fake": llm} forKey:@"providers"];
    [[YTMULyricsTitleNormalizer sharedNormalizer] clearCache];

    YTMULyricsManager *m = ManagerWithProviders(@[p1, p2], @{@"translationProvider": @"fake"});
    // P2 answers only when asked with the normalized title/artist.
    YTMULyricsResult *canonical = YTMUTestSyncedResult(@"P2", @"ハテ", @"Qeiru", 20);
    [m refreshWithInfo:YTMUTestInfo(@"v-repass", @"【MV】ハテ (Official)", @"Uploader Channel")];
    YTMU_ASSERT(WaitForState(m, YTMULyricsFetchStateDone, 5), "raw pass never finished");
    YTMU_ASSERT_EQ_STR(m.currentResult.sourceName, @"P1");
    // arm P2 for the re-pass (it is searched with candidate info after the debounce)
    p2.result = canonical;
    YTMU_ASSERT(YTMUTestWaitUntil(6, ^BOOL{ return [m.currentResult.sourceName isEqualToString:@"P2"]; }),
                "re-pass did not replace P1 with P2 (llm calls=%lu, p2 searches=%lu, last title=%@)",
                (unsigned long)llm.callCount, (unsigned long)p2.searchCount, p2.lastInfo.title);
    YTMU_ASSERT_EQ_STR(p2.lastInfo.title, @"ハテ");
    YTMU_ASSERT_EQ_STR(p2.lastInfo.artist, @"Qeiru");
    YTMU_ASSERT_EQ_INT(m.currentResult.lines.count, 20);
}

// L9: a provider that does not answer within the budget is skipped; its
// late answer is still cached but must not advance the pass a second time.
YTMU_TEST(Pipeline_slowProvider_isSkippedAfterBudget_lateAnswerOnlyCaches) {
    YTMUTestFakeLyricsProvider *slow = [[YTMUTestFakeLyricsProvider alloc] initWithName:@"Slow"];
    YTMUTestFakeLyricsProvider *fast = [[YTMUTestFakeLyricsProvider alloc] initWithName:@"Fast"];
    slow.result = YTMUTestSyncedResult(@"Slow", @"Budget Song", @"Artist", 10);
    slow.delay = 1.2;                                   // answers after the budget
    fast.result = YTMUTestSyncedResult(@"Fast", @"Budget Song", @"Artist", 4);
    YTMULyricsManager *m = ManagerWithProviders(@[slow, fast], nil);
    [m setValue:@0.4 forKey:@"providerBudgetSeconds"];

    [m refreshWithInfo:YTMUTestInfo(@"v-budget", @"Budget Song", @"Artist")];
    YTMU_ASSERT(WaitForState(m, YTMULyricsFetchStateDone, 5), "never reached Done");
    YTMU_ASSERT_EQ_STR(m.currentResult.sourceName, @"Fast");         // chain moved on past Slow
    YTMU_ASSERT([m.sourceAvailability[@"Slow"] isEqualToString:@"checking"], "skipped provider should still read as checking, got %@", m.sourceAvailability[@"Slow"]);

    // Let the slow answer arrive: it caches + flips the chip, nothing else.
    YTMU_ASSERT(WaitForAvailability(m, @"Slow", @"hit", 5), "late answer should mark Slow as hit, got %@", m.sourceAvailability);
    YTMU_ASSERT_EQ_STR(m.currentResult.sourceName, @"Fast");         // result unchanged
    YTMU_ASSERT_EQ_INT(fast.searchCount, 1);                          // pass did not run again
    NSString *key = [YTMULyricsCache cacheKeyForInfo:YTMUTestInfo(@"v-budget", @"Budget Song", @"Artist") source:@"Slow"];
    YTMU_ASSERT(YTMUTestWaitUntil(3, ^BOOL{ return [[YTMULyricsCache sharedCache] resultForKey:key] != nil; }), "late answer should be cached");
    [m setValue:@20.0 forKey:@"providerBudgetSeconds"];
}
