// H2 / H3: a provider error event whose "message" is JSON null must never
// put NSNull into an NSError, and the translator's per-line-fallback check
// must survive a non-string localizedDescription. Exercises the real
// NSURLSession → SSE parser → NSError → YTMUTranslator path against an
// in-process HTTP server.
#import "YTMUTestKit.h"
#import "YTMUTestSettings.h"
#import "YTMUTestHTTPServer.h"
#import "Translation/YTMUTranslator.h"
#import "Translation/YTMUTranslationTypes.h"
#import "Translation/Providers/YTMUAnthropicProvider.h"
#import "Translation/Providers/YTMUOpenAIProvider.h"

static NSString *const kNullMessageSSE =
    @"event: error\n"
    @"data: {\"type\":\"error\",\"error\":{\"message\":null}}\n\n";

static NSString *const kOpenAINullMessageSSE =
    @"event: response.failed\n"
    @"data: {\"type\":\"response.failed\",\"response\":{\"id\":\"r1\",\"error\":null},\"error\":{\"message\":null}}\n\n"
    @"data: [DONE]\n\n";

static void ConfigureAnthropic(YTMUTestHTTPServer *server) {
    YTMUTestSetSettings(@{
        @"YTMUltimateIsEnabled": @YES,
        @"translationProvider": YTMUTranslationProviderAnthropic,
        @"translationApiKey_anthropic": @"test-key",
        @"translationBaseUrl_anthropic": server.baseURL,
        @"translationTargetLang": @"en",
        @"translationDebugLogs": @NO,
    });
}

static void ConfigureOpenAI(YTMUTestHTTPServer *server) {
    YTMUTestSetSettings(@{
        @"YTMUltimateIsEnabled": @YES,
        @"translationProvider": YTMUTranslationProviderOpenAI,
        @"translationApiKey_openai-compatible": @"test-key",
        @"translationBaseUrl": server.baseURL,
        @"translationTargetLang": @"en",
        @"translationDebugLogs": @NO,
    });
}

// --- Provider level: the NSError must carry a real NSString description. ---

YTMU_TEST(Anthropic_completion_nullErrorMessage_yieldsStringDescription) {
    YTMUTestHTTPServer *server = [YTMUTestHTTPServer start];
    [server setTextResponse:kNullMessageSSE contentType:@"text/event-stream" status:200];
    ConfigureAnthropic(server);

    __block NSError *got = nil; __block BOOL done = NO;
    [[[YTMUAnthropicProvider alloc] init] completeWithSystemPrompt:@"sys" userPrompt:@"user" expectJSONMode:YES
        completion:^(NSString *text, NSError *error) { got = error; done = YES; }];
    YTMU_ASSERT(YTMUTestWaitUntil(5, ^BOOL{ return done; }), "completion never fired");
    YTMU_ASSERT(got != nil, "expected an error for the error event");
    YTMU_ASSERT([got.localizedDescription isKindOfClass:[NSString class]],
                "localizedDescription is %@, not NSString", NSStringFromClass([got.localizedDescription class]));
    YTMU_ASSERT_EQ_INT(server.requests.count, 1);
    [server stop];
}

YTMU_TEST(OpenAI_completion_nullErrorMessage_yieldsStringDescription) {
    YTMUTestHTTPServer *server = [YTMUTestHTTPServer start];
    [server setTextResponse:kOpenAINullMessageSSE contentType:@"text/event-stream" status:200];
    ConfigureOpenAI(server);

    __block NSError *got = nil; __block BOOL done = NO;
    [[[YTMUOpenAIProvider alloc] init] completeWithSystemPrompt:@"sys" userPrompt:@"user" expectJSONMode:YES
        completion:^(NSString *text, NSError *error) { got = error; done = YES; }];
    YTMU_ASSERT(YTMUTestWaitUntil(5, ^BOOL{ return done; }), "completion never fired");
    YTMU_ASSERT(got != nil, "expected an error for the error event");
    YTMU_ASSERT([got.localizedDescription isKindOfClass:[NSString class]],
                "localizedDescription is %@, not NSString", NSStringFromClass([got.localizedDescription class]));
    [server stop];
}

// --- End to end: translateLines with ≤8 lines routes the error through
// shouldFallbackPerLineForError:, which used to call rangeOfString: on the
// NSNull. This test must complete with an error and without any exception. ---

YTMU_TEST(Translator_shortLyrics_nullErrorMessage_doesNotThrow) {
    YTMUTestHTTPServer *server = [YTMUTestHTTPServer start];
    [server setTextResponse:kNullMessageSSE contentType:@"text/event-stream" status:200];
    ConfigureAnthropic(server);

    __block NSError *got = nil; __block NSArray *lines = nil; __block BOOL done = NO;
    [[YTMUTranslator sharedTranslator] translateLines:@[@"one", @"two", @"three"]
                                              videoId:@"test-null-msg"
                                                title:@"t" artist:@"a"
                                           completion:^(NSArray<NSString *> *translated, NSError *error) {
        lines = translated; got = error; done = YES;
    }];
    YTMU_ASSERT(YTMUTestWaitUntil(10, ^BOOL{ return done; }), "translation completion never fired");
    YTMU_ASSERT(lines == nil, "expected no translation");
    YTMU_ASSERT(got != nil, "expected an error");
    YTMU_ASSERT([got.localizedDescription isKindOfClass:[NSString class]], "error description must be a string");
    [server stop];
}

// --- H3: SSE events with non-string "type" / "delta" must be ignored, not
// crash isEqualToString:. ---

YTMU_TEST(Anthropic_sse_nonStringTypeFields_areIgnored) {
    YTMUTestHTTPServer *server = [YTMUTestHTTPServer start];
    NSString *sse =
        @"data: {\"type\":null}\n\n"
        @"data: {\"type\":42}\n\n"
        @"data: {\"type\":\"content_block_delta\",\"delta\":{\"type\":null,\"text\":\"x\"}}\n\n"
        @"data: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"{\\\"ok\\\":true}\"}}\n\n";
    [server setTextResponse:sse contentType:@"text/event-stream" status:200];
    ConfigureAnthropic(server);

    __block NSString *text = nil; __block NSError *err = nil; __block BOOL done = NO;
    [[[YTMUAnthropicProvider alloc] init] completeWithSystemPrompt:@"s" userPrompt:@"u" expectJSONMode:YES
        completion:^(NSString *t, NSError *e) { text = t; err = e; done = YES; }];
    YTMU_ASSERT(YTMUTestWaitUntil(5, ^BOOL{ return done; }), "completion never fired");
    YTMU_ASSERT(err == nil, "unexpected error %@", err);
    YTMU_ASSERT_EQ_STR(text, @"{\"ok\":true}");
    [server stop];
}

YTMU_TEST(OpenAI_sse_nonStringTypeFields_areIgnored) {
    YTMUTestHTTPServer *server = [YTMUTestHTTPServer start];
    NSString *sse =
        @"data: {\"type\":null}\n\n"
        @"data: {\"type\":7,\"delta\":\"nope\"}\n\n"
        @"data: {\"type\":\"response.output_text.delta\",\"delta\":null}\n\n"
        @"data: {\"type\":\"response.output_text.delta\",\"delta\":\"{\\\"ok\\\":1}\"}\n\n"
        @"data: [DONE]\n\n";
    [server setTextResponse:sse contentType:@"text/event-stream" status:200];
    ConfigureOpenAI(server);

    __block NSString *text = nil; __block NSError *err = nil; __block BOOL done = NO;
    [[[YTMUOpenAIProvider alloc] init] completeWithSystemPrompt:@"s" userPrompt:@"u" expectJSONMode:NO
        completion:^(NSString *t, NSError *e) { text = t; err = e; done = YES; }];
    YTMU_ASSERT(YTMUTestWaitUntil(5, ^BOOL{ return done; }), "completion never fired");
    YTMU_ASSERT(err == nil, "unexpected error %@", err);
    YTMU_ASSERT_EQ_STR(text, @"{\"ok\":1}");
    [server stop];
}
