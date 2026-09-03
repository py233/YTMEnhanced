// Musixmatch sits behind a WAF that scores clients on request patterns, so the
// provider's token handling is the part that decides whether this source keeps
// working: which credential mints a token varies by exit IP and time, a real
// token lasts hours (the old 55 s cache re-minted one per minute of playback),
// a failed sweep must back off instead of re-asking every song, and the raw
// Set-Cookie header must never be echoed back as Cookie.
#import "YTMUTestKit.h"
#import "YTMUTestSettings.h"
#import "YTMUTestHTTPServer.h"
#import "Lyrics/Providers/YTMUMusixMatchProvider.h"
#import "YTMUTestFakeLyricsProvider.h"

@interface YTMUMusixMatchProvider (YTMUTokenTesting)
- (void)getToken:(void(^)(NSString *token, NSError *error))completion;
- (NSString *)appId;
@end

static YTMUMusixMatchProvider *ProviderOn(YTMUTestHTTPServer *server) {
    YTMUTestSetSettings(@{@"YTMUltimateIsEnabled": @YES});   // no persisted token
    YTMUMusixMatchProvider *p = [[YTMUMusixMatchProvider alloc] init];
    p.endpointBaseURL = server.baseURL;
    return p;
}

static NSString *TokenSync(YTMUMusixMatchProvider *provider, NSError **outError) {
    __block NSString *token = nil; __block NSError *error = nil; __block BOOL done = NO;
    [provider getToken:^(NSString *t, NSError *e) { token = t; error = e; done = YES; }];
    YTMUTestWaitUntil(6, ^BOOL{ return done; });
    if (outError) *outError = error;
    return token;
}

static NSString *AppIdOfRequest(YTMUTestHTTPRequest *request) {
    NSRange r = [request.path rangeOfString:@"app_id="];
    return r.location == NSNotFound ? @"" : [request.path substringFromIndex:NSMaxRange(r)];
}

// The credential that works changes with the exit IP: the provider must sweep
// its candidates rather than give up on the first 401, and remember the winner.
YTMU_TEST(MusixMatch_rotatesCredentials_andRemembersTheOneThatWorked) {
    YTMUTestHTTPServer *server = [YTMUTestHTTPServer start];
    __block NSString *working = @"android-player-v1.0";
    server.responder = ^NSData *(YTMUTestHTTPRequest *req, NSInteger *status, NSMutableDictionary *headers) {
        *status = 200;
        headers[@"Content-Type"] = @"application/json";
        NSString *body = [AppIdOfRequest(req) isEqualToString:working]
            ? @"{\"message\":{\"header\":{\"status_code\":200},\"body\":{\"user_token\":\"tok-abcdefghijklmnopqrstuvwxyz\"}}}"
            : @"{\"message\":{\"header\":{\"status_code\":401,\"hint\":\"captcha\"}}}";
        return [body dataUsingEncoding:NSUTF8StringEncoding];
    };
    YTMUMusixMatchProvider *provider = ProviderOn(server);

    NSError *error = nil;
    YTMU_ASSERT_EQ_STR(TokenSync(provider, &error), @"tok-abcdefghijklmnopqrstuvwxyz");
    YTMU_ASSERT(error == nil, "unexpected error %@", error);
    YTMU_ASSERT(server.requests.count >= 2, "the first credential was rejected, so a second had to be tried (got %lu)", (unsigned long)server.requests.count);
    YTMU_ASSERT_EQ_STR(AppIdOfRequest(server.requests.lastObject), working);
    YTMU_ASSERT_EQ_STR([provider appId], working);

    // A fresh provider starts from the persisted winner instead of sweeping.
    YTMUMusixMatchProvider *relaunched = [[YTMUMusixMatchProvider alloc] init];
    relaunched.endpointBaseURL = server.baseURL;
    YTMU_ASSERT_EQ_STR([relaunched appId], working);
    [server stop];
}

// A real token lasts hours; re-minting per song is what gets an IP flagged.
YTMU_TEST(MusixMatch_tokenIsReusedAcrossSongs_andSurvivesRelaunch) {
    YTMUTestHTTPServer *server = [YTMUTestHTTPServer start];
    [server setTextResponse:@"{\"message\":{\"header\":{\"status_code\":200},\"body\":{\"user_token\":\"tok-lives-for-hours\"}}}"
                contentType:@"application/json" status:200];
    YTMUMusixMatchProvider *provider = ProviderOn(server);

    YTMU_ASSERT_EQ_STR(TokenSync(provider, NULL), @"tok-lives-for-hours");
    NSUInteger afterFirst = server.requests.count;
    for (int i = 0; i < 5; i++) YTMU_ASSERT_EQ_STR(TokenSync(provider, NULL), @"tok-lives-for-hours");
    YTMU_ASSERT_EQ_INT(server.requests.count, afterFirst);   // five more songs, zero extra token.get

    // Relaunch: the stored token is still valid, so starting the app is not a request.
    YTMUMusixMatchProvider *relaunched = [[YTMUMusixMatchProvider alloc] init];
    relaunched.endpointBaseURL = server.baseURL;
    YTMU_ASSERT_EQ_STR(TokenSync(relaunched, NULL), @"tok-lives-for-hours");
    YTMU_ASSERT_EQ_INT(server.requests.count, afterFirst);
    [server stop];
}

// When every credential is refused, stop asking — retrying each song is the
// steady beacon that keeps the exit flagged.
YTMU_TEST(MusixMatch_failedSweepCoolsDown_insteadOfAskingEverySong) {
    YTMUTestHTTPServer *server = [YTMUTestHTTPServer start];
    [server setTextResponse:@"{\"message\":{\"header\":{\"status_code\":401,\"hint\":\"captcha\"}}}"
                contentType:@"application/json" status:200];
    YTMUMusixMatchProvider *provider = ProviderOn(server);

    NSError *error = nil;
    YTMU_ASSERT_EQ_INT(TokenSync(provider, &error).length, 0);
    YTMU_ASSERT(error != nil && [error.localizedDescription containsString:@"captcha"],
                "the reason Musixmatch gave should reach the error: %@", error.localizedDescription);
    NSUInteger afterSweep = server.requests.count;
    YTMU_ASSERT(afterSweep >= 3, "every candidate should have been tried once (got %lu)", (unsigned long)afterSweep);

    for (int i = 0; i < 4; i++) (void)TokenSync(provider, NULL);
    YTMU_ASSERT_EQ_INT(server.requests.count, afterSweep);   // four more songs, no new requests
    [server stop];
}

// Set-Cookie carries Path/Expires; echoing the raw header back as Cookie is a
// malformed request no browser would make.
YTMU_TEST(MusixMatch_sendsOnlyCookieNameValuePairsBack) {
    YTMUTestHTTPServer *server = [YTMUTestHTTPServer start];
    server.responder = ^NSData *(YTMUTestHTTPRequest *req, NSInteger *status, NSMutableDictionary *headers) {
        *status = 200;
        headers[@"Content-Type"] = @"application/json";
        headers[@"Set-Cookie"] = @"mxm-user=abc123; Path=/; Expires=Wed, 09 Jun 2027 10:18:14 GMT; HttpOnly";
        return [@"{\"message\":{\"header\":{\"status_code\":401,\"hint\":\"captcha\"}}}" dataUsingEncoding:NSUTF8StringEncoding];
    };
    YTMUMusixMatchProvider *provider = ProviderOn(server);
    (void)TokenSync(provider, NULL);

    YTMU_ASSERT(server.requests.count >= 2, "need a follow-up request to inspect its Cookie header");
    NSString *sent = server.requests.lastObject.headers[@"cookie"] ?: @"";
    YTMU_ASSERT([sent containsString:@"mxm-user=abc123"], "the cookie value should be echoed, got %@", sent);
    YTMU_ASSERT(![sent containsString:@"Path"] && ![sent containsString:@"Expires"] && ![sent containsString:@"HttpOnly"],
                "cookie attributes must not be echoed back, got %@", sent);
}

// This provider used to be the only one reporting "no match" on tracks
// Musixmatch demonstrably has (Ninajirachi's "Delete" among them): it sent the
// microformat video title verbatim and gave up after one attempt, and it sent
// q_duration=0 when the duration was unknown, which makes the matcher match
// nothing.
YTMU_TEST(MusixMatch_cleansTheSearchTitle_triesASecondCandidate_andOmitsZeroDuration) {
    YTMUTestHTTPServer *server = [YTMUTestHTTPServer start];
    NSString *lrc = @"[00:01.00]line one\n[00:05.00]line two\n[00:09.00]line three\n";
    NSString *hit = [NSString stringWithFormat:
        @"{\"message\":{\"header\":{\"status_code\":200},\"body\":{\"macro_calls\":{"
        @"\"matcher.track.get\":{\"message\":{\"header\":{\"status_code\":200},\"body\":{\"track\":{\"track_id\":42,\"track_name\":\"Delete\",\"artist_name\":\"Ninajirachi\"}}}},"
        @"\"track.lyrics.get\":{\"message\":{\"header\":{\"status_code\":200},\"body\":{\"lyrics\":{\"lyrics_body\":\"line one\\nline two\\nline three\"}}}},"
        @"\"track.subtitles.get\":{\"message\":{\"header\":{\"status_code\":200},\"body\":{\"subtitle_list\":[{\"subtitle\":{\"subtitle_body\":\"%@\"}}]}}}"
        @"}}}}", [lrc stringByReplacingOccurrencesOfString:@"\n" withString:@"\\n"]];
    NSString *miss = @"{\"message\":{\"header\":{\"status_code\":200},\"body\":{\"macro_calls\":{"
        @"\"matcher.track.get\":{\"message\":{\"header\":{\"status_code\":200},\"body\":{\"track\":{\"track_id\":115264642,\"track_name\":\"\",\"artist_name\":\"\"}}}}}}}}";

    server.responder = ^NSData *(YTMUTestHTTPRequest *req, NSInteger *status, NSMutableDictionary *headers) {
        *status = 200;
        headers[@"Content-Type"] = @"application/json";
        if ([req.path containsString:@"token.get"]) {
            return [@"{\"message\":{\"header\":{\"status_code\":200},\"body\":{\"user_token\":\"tok-search\"}}}" dataUsingEncoding:NSUTF8StringEncoding];
        }
        // Musixmatch only knows the clean title; the raw video title misses.
        BOOL clean = [req.path containsString:@"q_track=Delete&"] || [req.path hasSuffix:@"q_track=Delete"];
        return [(clean ? hit : miss) dataUsingEncoding:NSUTF8StringEncoding];
    };

    YTMUMusixMatchProvider *provider = ProviderOn(server);
    YTMULyricsSearchInfo *info = YTMUTestInfo(@"v-mxm", @"Delete (Official Audio)", @"Ninajirachi");
    info.alternativeTitle = @"Ninajirachi - Delete (Official Audio)";
    info.duration = 0;   // unknown, as it is before the player reports it

    __block YTMULyricsResult *result = nil; __block NSError *error = nil; __block BOOL done = NO;
    [provider searchWithInfo:info completion:^(YTMULyricsResult *r, NSError *e) { result = r; error = e; done = YES; }];
    YTMU_ASSERT(YTMUTestWaitUntil(8, ^BOOL{ return done; }), "search never completed");
    YTMU_ASSERT(error == nil, "unexpected error %@", error);
    // Four lines, not three: the LRC parser prepends a silent lead-in when the
    // first timestamp is later than 300 ms.
    YTMU_ASSERT(result.lineTexts.count == 4 && result.isSynced,
                "the cleaned title should have matched: %lu lines", (unsigned long)result.lineTexts.count);
    YTMU_ASSERT([result.lineTexts containsObject:@"line one"], "lyrics text: %@", result.lineTexts);
    YTMU_ASSERT_EQ_STR(result.title, @"Delete");

    NSMutableArray<NSString *> *tracks = [NSMutableArray array];
    for (YTMUTestHTTPRequest *r in server.requests) {
        if ([r.path containsString:@"macro.subtitles.get"]) [tracks addObject:r.path];
    }
    YTMU_ASSERT(tracks.count >= 1, "no lyrics query was made");
    YTMU_ASSERT([tracks.firstObject containsString:@"q_track=Delete"],
                "the noise-stripped title must be tried first, got %@", tracks.firstObject);
    for (NSString *path in tracks) {
        YTMU_ASSERT(![path containsString:@"q_duration=0"], "an unknown duration must not be sent as 0: %@", path);
    }
    [server stop];
}
