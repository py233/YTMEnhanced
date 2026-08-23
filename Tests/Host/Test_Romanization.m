// Romanization end to end: a Japanese result from a scripted provider, the
// real manager pipeline, the real service, and an in-process stand-in for
// Google's transliteration endpoint.
#import "YTMUTestKit.h"
#import "YTMUTestSettings.h"
#import "YTMUTestHTTPServer.h"
#import "YTMUTestFakeLyricsProvider.h"
#import "Lyrics/YTMULyricsManager.h"
#import "Lyrics/YTMULyricsCache.h"
#import "Lyrics/YTMURomanizationService.h"

static YTMULyricsResult *JapaneseResult(NSString *source, NSUInteger lines) {
    YTMULyricsResult *r = [[YTMULyricsResult alloc] init];
    r.sourceName = source; r.title = @"夜に駆ける"; r.artists = @[@"YOASOBI"];
    NSMutableArray *arr = [NSMutableArray array];
    NSArray *texts = @[@"沈むように溶けてゆくように", @"二人だけの空が広がる夜に", @"さよならだけだった", @"その一言で全てが分かった"];
    for (NSUInteger i = 0; i < lines; i++) {
        [arr addObject:[YTMULyricLine lineWithTime:@"" timeInMs:(NSTimeInterval)(i * 1000) durationMs:1000 text:texts[i % texts.count]]];
    }
    r.lines = arr;
    return r;
}

static YTMUTestHTTPServer *StartGoogleStandIn(void) {
    YTMUTestHTTPServer *server = [YTMUTestHTTPServer start];
    server.responder = ^NSData *(YTMUTestHTTPRequest *req, NSInteger *status, NSMutableDictionary *headers) {
        // echo a deterministic transliteration derived from the query so each
        // line gets a distinct value we can check against
        NSURLComponents *c = [NSURLComponents componentsWithString:[@"http://x" stringByAppendingString:req.path]];
        NSString *q = @"";
        for (NSURLQueryItem *item in c.queryItems) if ([item.name isEqualToString:@"q"]) q = item.value;
        NSString *translit = [NSString stringWithFormat:@"romaji-%lu", (unsigned long)q.length];
        headers[@"Content-Type"] = @"application/json";
        return [NSJSONSerialization dataWithJSONObject:@{@"sentences": @[@{@"src_translit": translit}]} options:0 error:nil];
    };
    return server;
}

YTMU_TEST(Romanization_japaneseLyrics_getRomanizedThroughThePipeline) {
    YTMUTestHTTPServer *server = StartGoogleStandIn();
    YTMURomanizationService *service = [YTMURomanizationService sharedService];
    NSString *savedEndpoint = service.endpointBaseURL;
    service.endpointBaseURL = server.baseURL;
    [service clearMemoryCache];

    YTMUTestFakeLyricsProvider *p = [[YTMUTestFakeLyricsProvider alloc] initWithName:@"JP"];
    p.result = JapaneseResult(@"JP", 6);
    YTMUTestSetSettings(@{@"YTMUltimateIsEnabled": @YES, @"syncedLyricsEnabled": @YES, @"lyricsTranslationEnabled": @NO,
                          @"lyricsRomanization": @YES, @"lyricsPreferredSource": @"auto", @"translationProvider": @"google-translate"});
    YTMULyricsManager *m = [YTMULyricsManager sharedManager];
    [m clearCurrent]; [[YTMULyricsCache sharedCache] clearAll];
    [m setValue:@[p] forKey:@"providers"];

    [m refreshWithInfo:YTMUTestInfo(@"v-ja", @"夜に駆ける", @"YOASOBI")];
    YTMU_ASSERT(YTMUTestWaitUntil(8, ^BOOL{
        NSArray *r = m.currentResult.romanizedLineTexts;
        return r.count == 6 && [r[0] length] > 0 && [r[5] length] > 0;
    }), "romanized lines never applied (have %@)", m.currentResult.romanizedLineTexts);
    YTMU_ASSERT([m.currentResult.romanizedLineTexts[0] hasPrefix:@"romaji-"], "unexpected romanization %@", m.currentResult.romanizedLineTexts[0]);
    YTMU_ASSERT_EQ_INT(server.requests.count, 6);                     // one request per line, none repeated
    for (YTMUTestHTTPRequest *r in server.requests) {
        YTMU_ASSERT([r.path containsString:@"client=gtx"] && [r.path containsString:@"sl=ja"], "unexpected request %@", r.path);
    }
    // the per-line view copy carries it too
    YTMU_ASSERT([[m.currentResult.lines[1] romanizedText] hasPrefix:@"romaji-"], "line view copy lacks romanization");

    service.endpointBaseURL = savedEndpoint;
    [server stop];
}

YTMU_TEST(Romanization_songChangeMidBatch_stopsRequests) {
    YTMUTestHTTPServer *server = StartGoogleStandIn();
    server.responseDelay = 0.15;                          // 40 lines / 6 in flight ≈ 1 s batch
    YTMURomanizationService *service = [YTMURomanizationService sharedService];
    NSString *savedEndpoint = service.endpointBaseURL;
    service.endpointBaseURL = server.baseURL;
    [service clearMemoryCache];

    YTMUTestFakeLyricsProvider *p = [[YTMUTestFakeLyricsProvider alloc] initWithName:@"JP2"];
    p.result = JapaneseResult(@"JP2", 40);               // 40 lines → 6 in flight, 34 queued
    YTMUTestSetSettings(@{@"YTMUltimateIsEnabled": @YES, @"syncedLyricsEnabled": @YES, @"lyricsTranslationEnabled": @NO,
                          @"lyricsRomanization": @YES, @"lyricsPreferredSource": @"auto", @"translationProvider": @"google-translate"});
    YTMULyricsManager *m = [YTMULyricsManager sharedManager];
    [m clearCurrent]; [[YTMULyricsCache sharedCache] clearAll];
    [m setValue:@[p] forKey:@"providers"];

    [m refreshWithInfo:YTMUTestInfo(@"v-ja-long", @"夜に駆ける", @"YOASOBI")];
    YTMU_ASSERT(YTMUTestWaitUntil(5, ^BOOL{ return server.requests.count >= 1; }), "batch never started");
    [m clearCurrent];                                    // user skips the song
    NSUInteger soon = server.requests.count;
    YTMUTestWaitUntil(1.5, ^BOOL{ return NO; });
    // at most the in-flight window was issued after the skip — nowhere near 40
    YTMU_ASSERT(server.requests.count <= soon + 6, "requests kept flowing after song change: %lu → %lu", (unsigned long)soon, (unsigned long)server.requests.count);
    YTMU_ASSERT(server.requests.count < 40, "the whole batch was issued despite the song change");

    service.endpointBaseURL = savedEndpoint;
    [server stop];
}
