// Regression tests for the audit fixes in the lyrics module: romanization
// drift (A3), the normalizer's raw-metadata check (A13), description-
// extraction TTLs (B13), the playback-time fallback (B14), the YTMusic
// provider's localized "no lyrics" message (A9), the re-pass cache key and
// copy-on-store in the lyrics cache (B9 / B10).
#import <UIKit/UIKit.h>
#import <MediaPlayer/MediaPlayer.h>
#import "YTMUTestKit.h"
#import "YTMUTestSettings.h"
#import "YTMUTestHTTPServer.h"
#import "YTMUTestFakeLLM.h"
#import "YTMUTestFakeLyricsProvider.h"
#import "Lyrics/YTMULyricsManager.h"
#import "Lyrics/YTMULyricsCache.h"
#import "Lyrics/YTMURomanizationService.h"
#import "Lyrics/YTMULyricsTitleNormalizer.h"
#import "Lyrics/YTMULyricsDescriptionExtractor.h"
#import "Lyrics/YTMULyricsPlaybackState.h"
#import "Lyrics/Providers/YTMUYTMusicProvider.h"
#import "Translation/YTMUTranslator.h"

@interface YTMULyricsDescriptionExtractor (YTMUFixTesting)
- (NSString *)filePathForVideoId:(NSString *)videoId;
@end
@interface YTMUYTMusicProvider (YTMUFixTesting)
- (YTMULyricsResult *)resultFromBrowse:(NSDictionary *)json info:(YTMULyricsSearchInfo *)info;
- (NSDictionary *)context;
- (NSDictionary *)timedLyricsContext;
@end
@interface YTMULyricsCache (YTMUFixTesting)
- (void)clearMemoryCache;
@end

static YTMULyricsResult *FixJapaneseResult(NSString *source, NSUInteger lines) {
    YTMULyricsResult *r = [[YTMULyricsResult alloc] init];
    r.sourceName = source; r.title = @"夜に駆ける"; r.artists = @[@"YOASOBI"];
    NSArray *texts = @[@"沈むように溶けてゆくように", @"二人だけの空が広がる夜に", @"さよならだけだった", @"その一言で全てが分かった"];
    NSMutableArray *arr = [NSMutableArray array];
    for (NSUInteger i = 0; i < lines; i++) {
        [arr addObject:[YTMULyricLine lineWithTime:@"" timeInMs:(NSTimeInterval)(i * 1000) durationMs:1000 text:texts[i % texts.count]]];
    }
    r.lines = arr;
    return r;
}

// A3: a romanization batch started for one source must not be applied to
// the lines of another source that replaced it mid-flight, and must not be
// persisted under the new source's cache key.
YTMU_TEST(Romanization_sourceSwapMidBatch_isDiscarded_notCached) {
    YTMUTestHTTPServer *server = [YTMUTestHTTPServer start];
    server.responseDelay = 0.3;
    server.responder = ^NSData *(YTMUTestHTTPRequest *req, NSInteger *status, NSMutableDictionary *headers) {
        headers[@"Content-Type"] = @"application/json";
        return [NSJSONSerialization dataWithJSONObject:@{@"sentences": @[@{@"src_translit": @"romaji-drift"}]} options:0 error:nil];
    };
    YTMURomanizationService *service = [YTMURomanizationService sharedService];
    NSString *savedEndpoint = service.endpointBaseURL;
    service.endpointBaseURL = server.baseURL;
    [service clearMemoryCache];

    YTMUTestFakeLyricsProvider *p = [[YTMUTestFakeLyricsProvider alloc] initWithName:@"Desc"];
    p.result = FixJapaneseResult(@"Desc", 6);
    YTMUTestSetSettings(@{@"YTMUltimateIsEnabled": @YES, @"syncedLyricsEnabled": @YES, @"lyricsTranslationEnabled": @NO,
                          @"lyricsRomanization": @YES, @"lyricsPreferredSource": @"auto", @"translationProvider": @"google-translate"});
    YTMULyricsManager *m = [YTMULyricsManager sharedManager];
    [m clearCurrent]; [[YTMULyricsCache sharedCache] clearAll];
    [m setValue:@[p] forKey:@"providers"];

    YTMULyricsSearchInfo *info = YTMUTestInfo(@"v-drift", @"夜に駆ける", @"YOASOBI");
    [m refreshWithInfo:info];
    YTMU_ASSERT(YTMUTestWaitUntil(5, ^BOOL{ return server.requests.count >= 1; }), "batch never started");

    // The AI re-pass swaps the source under the running batch: different
    // provider, different line count.
    YTMULyricsResult *replacement = FixJapaneseResult(@"NE", 4);
    [m setValue:replacement forKey:@"currentResult"];
    YTMUTestWaitUntil(2.5, ^BOOL{ return NO; });   // let the whole batch land

    YTMU_ASSERT_EQ_STR(m.currentResult.sourceName, @"NE");
    YTMU_ASSERT_EQ_INT(m.currentResult.romanizedLineTexts.count, 0);
    for (YTMULyricLine *line in m.currentResult.lines) {
        YTMU_ASSERT(line.romanizedText.length == 0, "drifted romanization leaked onto line %@", line.text);
    }
    NSString *poisonedKey = [YTMULyricsCache cacheKeyForInfo:info source:@"NE"];
    [[YTMULyricsCache sharedCache] clearMemoryCache];
    YTMU_ASSERT([[YTMULyricsCache sharedCache] resultForKey:poisonedKey] == nil, "the replacement source must not have been cached with foreign romanization");

    service.endpointBaseURL = savedEndpoint;
    [server stop];
}

// A13: a normalization computed for the wrong (flickered) title is not
// served for the corrected title, and the corrected call overwrites it.
YTMU_TEST(Normalizer_cacheIgnoresEntryForDifferentRawMetadata_whenStrict) {
    YTMUTestFakeLLM *llm = [[YTMUTestFakeLLM alloc] init];
    llm.responseText = @"{\"title_primary\":\"Wrong\",\"title_alts\":[],\"artist_primary\":\"Nobody\",\"artist_alts\":[],\"language\":\"en\",\"confidence\":0.9}";
    YTMULyricsTitleNormalizer *n = [YTMULyricsTitleNormalizer sharedNormalizer];
    [n clearCache];
    YTMULyricsSearchInfo *flickered = YTMUTestInfo(@"v-raw", @"Previous Song Title", @"Channel");
    YTMULyricsSearchInfo *correct = YTMUTestInfo(@"v-raw", @"Real Song Title", @"Channel");

    __block BOOL done = NO;
    [n normalizeForInfo:flickered provider:llm providerName:@"fake" requireRawMetadataMatch:YES
             completion:^(YTMULyricsTitleNormalization *r, NSError *e) { done = YES; }];
    YTMU_ASSERT(YTMUTestWaitUntil(5, ^BOOL{ return done; }), "first normalize never completed");
    YTMU_ASSERT(YTMUTestWaitUntil(3, ^BOOL{ return [n cachedNormalizationForInfo:flickered] != nil; }), "entry never reached disk");
    YTMU_ASSERT_EQ_INT(llm.callCount, 1);

    YTMU_ASSERT([n cachedNormalizationForInfo:correct requireRawMetadataMatch:YES] == nil, "strict lookup must reject the entry made for another title");
    YTMU_ASSERT([n cachedNormalizationForInfo:correct requireRawMetadataMatch:NO] != nil, "lenient lookup (scrobble path) still sees it");
    YTMU_ASSERT([n cachedNormalizationForInfo:flickered requireRawMetadataMatch:YES] != nil, "strict lookup with the matching title hits");

    llm.responseText = @"{\"title_primary\":\"Real\",\"title_alts\":[],\"artist_primary\":\"Artist\",\"artist_alts\":[],\"language\":\"en\",\"confidence\":0.9}";
    done = NO;
    __block YTMULyricsTitleNormalization *got = nil;
    [n normalizeForInfo:correct provider:llm providerName:@"fake" requireRawMetadataMatch:YES
             completion:^(YTMULyricsTitleNormalization *r, NSError *e) { got = r; done = YES; }];
    YTMU_ASSERT(YTMUTestWaitUntil(5, ^BOOL{ return done; }), "second normalize never completed");
    YTMU_ASSERT_EQ_INT(llm.callCount, 2);                       // asked again for the real title
    YTMU_ASSERT_EQ_STR(got.titleCandidates.firstObject, @"Real");
    YTMU_ASSERT(YTMUTestWaitUntil(3, ^BOOL{ return [n cachedNormalizationForInfo:correct requireRawMetadataMatch:YES] != nil; }), "corrected entry not persisted");
    YTMU_ASSERT([n cachedNormalizationForInfo:flickered requireRawMetadataMatch:YES] == nil, "the stale entry was replaced");
}

// B13: negative and positive extraction verdicts expire; legacy entries
// without a timestamp do not.
YTMU_TEST(Extractor_verdictsExpire_legacyEntriesDoNot) {
    YTMULyricsDescriptionExtractor *x = [YTMULyricsDescriptionExtractor sharedExtractor];
    NSMutableString *desc = [NSMutableString string];
    while (desc.length < 260) [desc appendString:@"filler text for the minimum description length threshold "];
    YTMULyricsSearchInfo *info = YTMUTestInfo(@"v-ttl", @"T", @"A");
    info.shortDescription = desc;
    YTMUTestFakeLLM *llm = [[YTMUTestFakeLLM alloc] init];
    llm.responseText = @"{\"has_lyrics\":false,\"source_lyrics\":\"\",\"confidence\":0.9}";
    __block BOOL done = NO;
    [x extractForInfo:info provider:llm providerName:@"fake" completion:^(YTMULyricsDescriptionExtraction *e, NSError *err) { done = YES; }];
    YTMU_ASSERT(YTMUTestWaitUntil(5, ^BOOL{ return done; }), "extract never completed");
    NSString *path = [x filePathForVideoId:info.videoId];
    YTMU_ASSERT(YTMUTestWaitUntil(3, ^BOOL{ return [[NSFileManager defaultManager] fileExistsAtPath:path]; }), "verdict not persisted");
    YTMU_ASSERT([x cachedExtractionForInfo:info] != nil, "fresh negative is served");

    NSMutableDictionary *plist = [[NSDictionary dictionaryWithContentsOfFile:path] mutableCopy];
    YTMU_ASSERT([plist[@"ts"] isKindOfClass:[NSNumber class]], "new entries carry a timestamp");
    plist[@"ts"] = @([[NSDate date] timeIntervalSince1970] - 8 * 24 * 3600);
    [plist writeToFile:path atomically:YES];
    YTMU_ASSERT([x cachedExtractionForInfo:info] == nil, "an 8-day-old negative must expire");

    // A positive verdict lasts longer than a week but not a month.
    plist[@"src_lines"] = @[@"a line", @"another line"];
    plist[@"ts"] = @([[NSDate date] timeIntervalSince1970] - 8 * 24 * 3600);
    [plist writeToFile:path atomically:YES];
    YTMU_ASSERT([x cachedExtractionForInfo:info].sourceLines.count == 2, "an 8-day-old positive is still served");
    plist[@"ts"] = @([[NSDate date] timeIntervalSince1970] - 31 * 24 * 3600);
    [plist writeToFile:path atomically:YES];
    YTMU_ASSERT([x cachedExtractionForInfo:info] == nil, "a 31-day-old positive expires");

    // Legacy entry (no ts) is served regardless of age.
    [plist removeObjectForKey:@"ts"];
    [plist writeToFile:path atomically:YES];
    YTMU_ASSERT([x cachedExtractionForInfo:info].sourceLines.count == 2, "legacy entries without ts must keep working");

    // And an expired negative makes the LLM get asked again.
    plist[@"src_lines"] = @[];
    plist[@"ts"] = @([[NSDate date] timeIntervalSince1970] - 8 * 24 * 3600);
    [plist writeToFile:path atomically:YES];
    done = NO;
    [x extractForInfo:info provider:llm providerName:@"fake" completion:^(YTMULyricsDescriptionExtraction *e, NSError *err) { done = YES; }];
    YTMU_ASSERT(YTMUTestWaitUntil(5, ^BOOL{ return done; }), "re-extract never completed");
    YTMU_ASSERT_EQ_INT(llm.callCount, 2);
}

// B14: with no player, the MPNowPlayingInfoCenter fallback keeps advancing
// between the app's (static) elapsed-time updates.
YTMU_TEST(PlaybackTime_nowPlayingFallback_extrapolatesWhilePlaying) {
    YTMULyricsPlaybackState *s = [YTMULyricsPlaybackState sharedState];
    s.playerViewController = nil;
    MPNowPlayingInfoCenter *center = [MPNowPlayingInfoCenter defaultCenter];
    center.nowPlayingInfo = @{MPNowPlayingInfoPropertyElapsedPlaybackTime: @10.0, MPNowPlayingInfoPropertyPlaybackRate: @1.0};
    NSTimeInterval first = [s currentPlaybackTimeMs];
    YTMU_ASSERT(fabs(first - 10000) < 50, "first read should be the reported elapsed time, got %.0f", first);
    YTMUTestWaitUntil(0.2, ^BOOL{ return NO; });
    NSTimeInterval second = [s currentPlaybackTimeMs];
    YTMU_ASSERT(second - first >= 150 && second - first < 600, "time must advance between reads (delta %.0f ms)", second - first);

    center.nowPlayingInfo = @{MPNowPlayingInfoPropertyElapsedPlaybackTime: @30.0, MPNowPlayingInfoPropertyPlaybackRate: @0.0};
    NSTimeInterval paused = [s currentPlaybackTimeMs];
    YTMUTestWaitUntil(0.15, ^BOOL{ return NO; });
    YTMU_ASSERT(fabs(paused - 30000) < 50 && fabs([s currentPlaybackTimeMs] - paused) < 50, "a new elapsed value resets the base and rate 0 must not advance");
    center.nowPlayingInfo = nil;
}

// A9: a single short line from the official lyrics endpoint is a status
// message, not lyrics — whatever language it arrives in — and the request
// context pins the language so the English sentinel keeps matching.
YTMU_TEST(YTMusicProvider_rejectsSingleLineStatusMessages_andPinsLanguage) {
    YTMUYTMusicProvider *p = [[YTMUYTMusicProvider alloc] init];
    YTMULyricsSearchInfo *info = YTMUTestInfo(@"v-ytm", @"Song", @"Artist");
    NSDictionary *(^message)(NSString *) = ^NSDictionary *(NSString *text) {
        return @{@"contents": @{@"messageRenderer": @{@"text": @{@"runs": @[@{@"text": text}]}}}};
    };
    YTMU_ASSERT([p resultFromBrowse:message(@"Lyrics not available") info:info] == nil, "English sentinel");
    YTMU_ASSERT([p resultFromBrowse:message(@"歌詞はありません") info:info] == nil, "localized status message must not become lyrics");
    YTMU_ASSERT([p resultFromBrowse:message(@"暂无歌词") info:info] == nil, "localized status message must not become lyrics");
    NSDictionary *real = @{@"contents": @{@"musicDescriptionShelfRenderer": @{@"description": @{@"runs": @[@{@"text": @"first line\nsecond line\nthird line"}]}}}};
    YTMULyricsResult *r = [p resultFromBrowse:real info:info];
    YTMU_ASSERT(r != nil && r.lineTexts.count == 3, "multi-line plain lyrics still come through, got %@", r);
    YTMU_ASSERT_EQ_STR([p context][@"client"][@"hl"], @"en");
    YTMU_ASSERT_EQ_STR([p timedLyricsContext][@"client"][@"hl"], @"en");
}

// B10: the cache archives a snapshot; mutating the stored object afterwards
// does not change what comes back.
YTMU_TEST(LyricsCache_storeIsCopyOnWrite) {
    YTMULyricsCache *cache = [YTMULyricsCache sharedCache];
    [cache clearAll];
    YTMULyricsResult *r = YTMUTestSyncedResult(@"S", @"Original Title", @"Artist", 3);
    NSString *key = [YTMULyricsCache cacheKeyForInfo:YTMUTestInfo(@"v-cow", @"Original Title", @"Artist") source:@"S"];
    [cache storeResult:r forKey:key];
    r.title = @"Mutated After Store";
    YTMU_ASSERT_EQ_STR([cache resultForKey:key].title, @"Original Title");          // memory entry
    YTMU_ASSERT(YTMUTestWaitUntil(3, ^BOOL{
        [cache clearMemoryCache];
        return [cache resultForKey:key] != nil;
    }), "archive never landed");
    YTMU_ASSERT_EQ_STR([cache resultForKey:key].title, @"Original Title");          // disk entry
}

// B9: after the AI re-pass replaces the raw hit, the replacement is also
// cached under the ORIGINAL metadata's key so the next replay's raw pass
// finds it without re-running the chain.
YTMU_TEST(Pipeline_repassHit_isCachedUnderOriginalKey) {
    YTMUTestFakeLyricsProvider *p1 = [[YTMUTestFakeLyricsProvider alloc] initWithName:@"P1"];
    YTMUTestFakeLyricsProvider *p2 = [[YTMUTestFakeLyricsProvider alloc] initWithName:@"P2"];
    p1.result = YTMUTestPlainResult(@"P1", @"【MV】ハテ (Official)", @"Uploader Channel", 10);
    p2.result = nil;
    YTMUTestFakeLLM *llm = [[YTMUTestFakeLLM alloc] init];
    llm.responseText = @"{\"title_primary\":\"ハテ\",\"title_alts\":[],\"artist_primary\":\"Qeiru\",\"artist_alts\":[],\"language\":\"ja\",\"confidence\":0.9}";
    [[YTMUTranslator sharedTranslator] setValue:@{@"fake": llm} forKey:@"providers"];
    [[YTMULyricsTitleNormalizer sharedNormalizer] clearCache];
    YTMUTestSetSettings(@{@"YTMUltimateIsEnabled": @YES, @"syncedLyricsEnabled": @YES, @"lyricsTranslationEnabled": @NO,
                          @"lyricsRomanization": @NO, @"lyricsPreferredSource": @"auto", @"lyricsShowInexact": @YES,
                          @"translationProvider": @"fake", @"translationDebugLogs": @NO});
    YTMULyricsManager *m = [YTMULyricsManager sharedManager];
    [m clearCurrent]; [[YTMULyricsCache sharedCache] clearAll];
    [m setValue:@[p1, p2] forKey:@"providers"];

    YTMULyricsSearchInfo *original = YTMUTestInfo(@"v-repass-key", @"【MV】ハテ (Official)", @"Uploader Channel");
    [m refreshWithInfo:original];
    YTMU_ASSERT(YTMUTestWaitUntil(5, ^BOOL{ return m.state == YTMULyricsFetchStateDone; }), "raw pass never finished");
    p2.result = YTMUTestSyncedResult(@"P2", @"ハテ", @"Qeiru", 20);
    YTMU_ASSERT(YTMUTestWaitUntil(6, ^BOOL{ return [m.currentResult.sourceName isEqualToString:@"P2"]; }), "re-pass did not replace P1");

    NSString *originalKey = [YTMULyricsCache cacheKeyForInfo:original source:@"P2"];
    YTMU_ASSERT(YTMUTestWaitUntil(3, ^BOOL{
        [[YTMULyricsCache sharedCache] clearMemoryCache];
        return [[YTMULyricsCache sharedCache] resultForKey:originalKey].lines.count == 20;
    }), "re-pass hit must be cached under the original metadata's key");
}
