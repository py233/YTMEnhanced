// Characterization tests for the areas the audit found untested: the LRC
// parser, title similarity, NetEase cookie capture, the lyrics cache
// archive, last.fm signing, the ListenBrainz body, the scrobble title
// cleaner and resolver rules, Google Translate's line splitting, and the
// LLM providers' base-URL handling. They pin today's behaviour so a later
// refactor cannot drift silently.
#import "YTMUTestKit.h"
#import "YTMUTestSettings.h"
#import "YTMUTestHTTPServer.h"
#import "YTMUTestFakeLyricsProvider.h"
#import "Lyrics/YTMULRCParser.h"
#import "Lyrics/YTMULyricsTypes.h"
#import "Lyrics/YTMULyricsCache.h"
#import "Lyrics/Providers/YTMUNetEaseProvider.h"
#import "Scrobbling/Providers/YTMULastFMScrobbler.h"
#import "Scrobbling/Providers/YTMUListenBrainzScrobbler.h"
#import "Scrobbling/YTMUScrobbleTitleCleaner.h"
#import "Scrobbling/YTMUScrobbleResolver.h"
#import "Scrobbling/YTMUScrobbleTypes.h"
#import "Translation/Providers/YTMUGoogleTranslateProvider.h"
#import "Translation/Providers/YTMUOpenAIProvider.h"
#import "Translation/Providers/YTMUAnthropicProvider.h"
#import "Translation/YTMUTranslationTypes.h"

@interface YTMUNetEaseProvider (YTMUCharTesting)
- (void)captureCookiesFromResponse:(NSHTTPURLResponse *)response;
- (NSString *)cookieHeader;
@end
@interface YTMUListenBrainzScrobbler (YTMUCharTesting)
- (NSDictionary *)bodyForListens:(NSArray<YTMUListen *> *)listens listenType:(NSString *)listenType includeTimestamp:(BOOL)includeTimestamp;
@end
@interface YTMUScrobbleResolver (YTMUCharTesting)
- (BOOL)artist:(NSString *)resultArtist matchesInput:(NSString *)inputArtist;
- (BOOL)track:(NSString *)resultTrack matchesInput:(NSString *)inputTrack;
- (NSString *)normalizeTrackForCompare:(NSString *)s;
@end
@interface YTMUGoogleTranslateProvider (YTMUCharTesting)
- (NSArray<NSString *> *)splitByMarkers:(NSString *)text expected:(NSUInteger)expected;
- (NSArray<NSString *> *)splitByHTMLBreaks:(NSString *)text expected:(NSUInteger)expected;
@end
@interface YTMULyricsCache (YTMUCharTesting)
- (void)clearMemoryCache;
@end


static NSString *HeaderValueCI(YTMUTestHTTPRequest *request, NSString *name) {
    for (NSString *key in request.headers) {
        if ([key caseInsensitiveCompare:name] == NSOrderedSame) return request.headers[key];
    }
    return nil;
}

YTMU_TEST(LRC_offsetShiftsEarlier_multiTimestampLinesExpand_wordTagsStripped) {
    NSString *lrc = @"[ti:Song]\n[offset:+500]\n[00:01.00][00:03.00]chorus\n[00:02.00]verse <00:02.10>word\n";
    NSArray<YTMULyricLine *> *lines = [YTMULRCParser parseLRC:lrc];
    // A song that starts later than 300 ms gets a silent lead-in line at 0.
    YTMU_ASSERT_EQ_INT(lines.count, 4);
    YTMU_ASSERT(lines[0].timeInMs == 0 && lines[0].text.length == 0 && fabs(lines[0].durationMs - 500) < 1, "lead-in line: %@ @%.0f dur %.0f", lines[0].text, lines[0].timeInMs, lines[0].durationMs);
    YTMU_ASSERT(fabs(lines[1].timeInMs - 500) < 1 && [lines[1].text isEqualToString:@"chorus"], "first line: %@ @%.0f", lines[1].text, lines[1].timeInMs);
    YTMU_ASSERT(fabs(lines[2].timeInMs - 1500) < 1 && [lines[2].text isEqualToString:@"verse word"], "word timing tags stripped: %@ @%.0f", lines[2].text, lines[2].timeInMs);
    YTMU_ASSERT(fabs(lines[3].timeInMs - 2500) < 1 && [lines[3].text isEqualToString:@"chorus"], "repeated timestamp expands: %@ @%.0f", lines[3].text, lines[3].timeInMs);
    YTMU_ASSERT(fabs(lines[1].durationMs - 1000) < 1 && fabs(lines[3].durationMs - 3500) < 1, "durations run to the next line (last one 3.5 s), got %.0f / %.0f", lines[1].durationMs, lines[3].durationMs);
    NSArray<YTMULyricLine *> *delayed = [YTMULRCParser parseLRC:@"[offset:-250]\n[00:01.00]a\n"];
    YTMU_ASSERT(fabs(delayed.lastObject.timeInMs - 1250) < 1, "negative offset delays, got %.0f", delayed.lastObject.timeInMs);
    NSArray<YTMULyricLine *> *clamped = [YTMULRCParser parseLRC:@"[offset:5000]\n[00:01.00]a\n"];
    YTMU_ASSERT(clamped.count == 1 && clamped.firstObject.timeInMs == 0, "an offset never produces a negative time, got %lu lines @%.0f", (unsigned long)clamped.count, clamped.firstObject.timeInMs);
}

YTMU_TEST(Similarity_shortTitleInsideLongTitle_isNotNearEqual) {
    YTMU_ASSERT(YTMULyricsSimilarity(@"Sun", @"Sunflower") < 0.6, "got %.2f", YTMULyricsSimilarity(@"Sun", @"Sunflower"));
    YTMU_ASSERT(YTMULyricsSimilarity(@"Terminal", @"ハテ - Terminal") >= 0.9, "comparable-length containment stays near-equal: %.2f", YTMULyricsSimilarity(@"Terminal", @"ハテ - Terminal"));
    YTMU_ASSERT(YTMULyricsSimilarity(@"夜に駆ける", @"夜に駆ける") == 1, "identical");
    YTMU_ASSERT(YTMULyricsSimilarity(@"", @"x") == 0, "empty");
}

YTMU_TEST(NetEase_setCookieWithExpiresComma_isParsedByCookieRules) {
    YTMUNetEaseProvider *provider = [[YTMUNetEaseProvider alloc] init];
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:[NSURL URLWithString:@"https://music.163.com/eapi/x"] statusCode:200 HTTPVersion:@"HTTP/1.1"
        headerFields:@{@"Set-Cookie": @"MUSIC_U=abc; Expires=Wed, 21 Oct 2026 07:28:00 GMT; Path=/; HttpOnly, NMTID=xyz; Max-Age=315360000; Path=/"}];
    [provider captureCookiesFromResponse:response];
    NSString *header = [provider cookieHeader];
    YTMU_ASSERT([header containsString:@"MUSIC_U=abc"] && [header containsString:@"NMTID=xyz"], "both cookies captured: %@", header);
    YTMU_ASSERT(![header containsString:@"Oct"] && ![header containsString:@"GMT"], "the Expires date must not become a cookie: %@", header);
}

YTMU_TEST(LyricsCache_archiveRoundTrip_preservesEverythingTheViewsRead) {
    YTMULyricsCache *cache = [YTMULyricsCache sharedCache];
    YTMULyricsResult *result = YTMUTestSyncedResult(@"S", @"Title", @"Artist", 4);
    result.romanizedLineTexts = @[@"a", @"b", @"c", @"d"];
    result.duration = 123;
    result.inexact = YES;
    NSString *key = [YTMULyricsCache cacheKeyForInfo:YTMUTestInfo(@"v-roundtrip", @"Title", @"Artist") source:@"S"];
    [cache storeResult:result forKey:key];
    YTMU_ASSERT(YTMUTestWaitUntil(3, ^BOOL{ [cache clearMemoryCache]; return [cache resultForKey:key] != nil; }), "archive never landed");
    YTMULyricsResult *back = [cache resultForKey:key];
    YTMU_ASSERT([back.lineTexts isEqualToArray:result.lineTexts] && back.lines.count == 4, "lines survive: %@", back.lineTexts);
    YTMU_ASSERT(fabs(back.lines[2].timeInMs - result.lines[2].timeInMs) < 0.5 && back.isSynced, "timing survives");
    YTMU_ASSERT(([back.romanizedLineTexts isEqualToArray:@[@"a", @"b", @"c", @"d"]]), "romanization survives: %@", back.romanizedLineTexts);
    YTMU_ASSERT(back.inexact && fabs(back.duration - 123) < 0.5 && [back.sourceName isEqualToString:@"S"] && [back.title isEqualToString:@"Title"], "flags survive");
}

YTMU_TEST(LastFM_signature_isMD5OfSortedParamsAndSecret_withoutFormat) {
    NSString *sig = YTMULastFMSignParams(@{@"method": @"auth.getToken", @"api_key": @"k", @"format": @"json"}, @"s");
    YTMU_ASSERT_EQ_STR(sig, @"fcb68e4c03131d77e8851e889687a441");
    YTMU_ASSERT_EQ_STR(YTMULastFMSignParams(@{@"method": @"auth.getToken", @"api_key": @"k"}, @"s"), @"fcb68e4c03131d77e8851e889687a441");   // format never counts
}

YTMU_TEST(ListenBrainz_submissionBody_shape) {
    YTMUListenBrainzScrobbler *lb = [[YTMUListenBrainzScrobbler alloc] init];
    YTMUListen *listen = [[YTMUListen alloc] init];
    listen.trackName = @"T"; listen.artist = @"A"; listen.albumName = @"Al";
    listen.durationSeconds = 200.4; listen.startedAtUnix = 1700000000; listen.videoId = @"vid"; listen.recordingMBID = @"mbid-1";
    NSDictionary *body = [lb bodyForListens:@[listen] listenType:@"import" includeTimestamp:YES];
    NSDictionary *entry = body[@"payload"][0];
    NSDictionary *meta = entry[@"track_metadata"];
    NSDictionary *additional = meta[@"additional_info"];
    YTMU_ASSERT([body[@"listen_type"] isEqualToString:@"import"] && [entry[@"listened_at"] longLongValue] == 1700000000, "envelope: %@", body);
    YTMU_ASSERT([meta[@"track_name"] isEqualToString:@"T"] && [meta[@"artist_name"] isEqualToString:@"A"] && [meta[@"release_name"] isEqualToString:@"Al"], "metadata: %@", meta);
    YTMU_ASSERT([additional[@"origin_url"] isEqualToString:@"https://music.youtube.com/watch?v=vid"] && [additional[@"duration"] integerValue] == 200 && [additional[@"recording_mbid"] isEqualToString:@"mbid-1"], "additional_info: %@", additional);
    YTMU_ASSERT([NSJSONSerialization isValidJSONObject:body], "body must serialise");
    NSDictionary *nowPlaying = [lb bodyForListens:@[listen] listenType:@"playing_now" includeTimestamp:NO];
    YTMU_ASSERT(nowPlaying[@"payload"][0][@"listened_at"] == nil, "playing_now carries no timestamp");
}

YTMU_TEST(TitleCleaner_stripsPlatformNoise_keepsVersionMarkers_dropsArtistSuffix) {
    YTMUScrobbleCleanedMeta *meta = [YTMUScrobbleTitleCleaner cleanTrack:@"Song Name (Official Music Video)" artist:@"Artist - Topic" album:nil];
    YTMU_ASSERT_EQ_STR(meta.track, @"Song Name");
    YTMU_ASSERT_EQ_STR(meta.artist, @"Artist");
    meta = [YTMUScrobbleTitleCleaner cleanTrack:@"Song (Live)" artist:@"Artist" album:@"Album"];
    YTMU_ASSERT([meta.track containsString:@"Live"] && [meta.album isEqualToString:@"Album"], "recording-version markers are kept: %@", meta.track);
    meta = [YTMUScrobbleTitleCleaner cleanTrack:@"ハテ / Qeiru" artist:@"Qeiru" album:nil];
    YTMU_ASSERT_EQ_STR(meta.track, @"ハテ");
    meta = [YTMUScrobbleTitleCleaner cleanTrack:nil artist:nil album:nil];
    YTMU_ASSERT(meta.track != nil && meta.artist != nil && meta.album != nil, "nil inputs yield empty strings, never nil");
}

YTMU_TEST(ScrobbleResolver_artistAndTrackMatchRules) {
    YTMUScrobbleResolver *resolver = [YTMUScrobbleResolver sharedResolver];
    YTMU_ASSERT_EQ_STR(YTMUScrobbleNormalizeArtistForCompare(@" 初音ミク × 鏡音リン "), @"初音ミク&鏡音リン");
    YTMU_ASSERT_EQ_STR(YTMUScrobbleNormalizeArtistForCompare(@"IA, ONE"), @"ia&one");
    YTMU_ASSERT([resolver artist:@"YOASOBI" matchesInput:@"yoasobi"], "case-insensitive equality");
    YTMU_ASSERT([resolver artist:@"Qeiru feat. IA" matchesInput:@"Qeiru"], "containment with ≥3 chars");
    YTMU_ASSERT(![resolver artist:@"IA" matchesInput:@"Diana"], "two-letter names never match by containment");
    YTMU_ASSERT_EQ_STR([resolver normalizeTrackForCompare:@"Fiction (feat. IA)!"], @"fiction");
    YTMU_ASSERT([resolver track:@"海辺の電話ボックス" matchesInput:@"海辺の電話ボックス !"], "punctuation-insensitive track equality");
    YTMU_ASSERT(![resolver track:@"いいじゃない" matchesInput:@"消えない温度"], "different songs by the same artist do not match");
}

YTMU_TEST(GoogleTranslate_markerSplit_toleratesSpacing_andBreakFallback) {
    YTMUGoogleTranslateProvider *google = [[YTMUGoogleTranslateProvider alloc] init];
    NSArray *lines = [google splitByMarkers:@"one <<< YTMD_LYRICS_LINE_0001 >>> two<<<YTMD-LYRICS-LINE-0002>>>three" expected:3];
    YTMU_ASSERT(([lines isEqualToArray:@[@"one", @"two", @"three"]]), "markers: %@", lines);
    YTMU_ASSERT([google splitByMarkers:@"one<<<YTMD_LYRICS_LINE_0001>>>two" expected:3] == nil, "a missing marker is a failure, not a guess");
    NSArray *breaks = [google splitByHTMLBreaks:@"uno&lt;br&gt;dos<br/>tres" expected:3];
    YTMU_ASSERT(([breaks isEqualToArray:@[@"uno", @"dos", @"tres"]]), "breaks: %@", breaks);
}

YTMU_TEST(Providers_baseURLJoins_tolerateUserPastedPaths) {
    YTMUTestHTTPServer *server = [YTMUTestHTTPServer start];
    YTMUTestSetSettings(@{
        @"YTMUltimateIsEnabled": @YES,
        @"translationApiKey_openai-compatible": @"k", @"translationBaseUrl": [server.baseURL stringByAppendingString:@"/v1/responses/"],
        @"translationApiKey_anthropic": @"k", @"translationBaseUrl_anthropic": [server.baseURL stringByAppendingString:@"/v1"],
        @"translationDebugLogs": @NO,
    });
    [server setTextResponse:@"data: {\"type\":\"response.output_text.delta\",\"delta\":\"ok\"}\n\n" contentType:@"text/event-stream" status:200];
    __block BOOL done = NO;
    [[[YTMUOpenAIProvider alloc] init] completeWithSystemPrompt:@"s" userPrompt:@"u" expectJSONMode:NO completion:^(NSString *t, NSError *e) { done = YES; }];
    YTMU_ASSERT(YTMUTestWaitUntil(5, ^BOOL{ return done; }), "openai never completed");
    YTMU_ASSERT_EQ_STR(server.requests.lastObject.path, @"/v1/responses");

    [server setTextResponse:@"data: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"ok\"}}\n\n" contentType:@"text/event-stream" status:200];
    done = NO;
    [[[YTMUAnthropicProvider alloc] init] completeWithSystemPrompt:@"s" userPrompt:@"u" expectJSONMode:NO completion:^(NSString *t, NSError *e) { done = YES; }];
    YTMU_ASSERT(YTMUTestWaitUntil(5, ^BOOL{ return done; }), "anthropic never completed");
    YTMU_ASSERT_EQ_STR(server.requests.lastObject.path, @"/v1/messages");
    YTMU_ASSERT_EQ_STR(HeaderValueCI(server.requests.lastObject, @"anthropic-version"), @"2023-06-01");
    [server stop];
}
