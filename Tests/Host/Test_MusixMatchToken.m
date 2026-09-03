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
