// Translation providers against a real local HTTP server: the OpenAI
// Responses → Chat Completions fallback (A15), truncation / safety
// verdicts and the Gemini key header (B12), the translator's retry policy
// (A14) and the shared LLM text helpers (C2).
#import "YTMUTestKit.h"
#import "YTMUTestSettings.h"
#import "YTMUTestHTTPServer.h"
#import "Translation/YTMUTranslator.h"
#import "Translation/YTMUTranslationTypes.h"
#import "Translation/YTMULLMTextUtils.h"
#import "Translation/Providers/YTMUOpenAIProvider.h"
#import "Translation/Providers/YTMUAnthropicProvider.h"
#import "Translation/Providers/YTMUGeminiProvider.h"

static NSString *JSONString(id object) {
    return [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:object options:0 error:nil] encoding:NSUTF8StringEncoding];
}

static NSString *ChatSSE(NSString *content, NSString *finishReason) {
    NSDictionary *chunk = @{@"choices": @[@{@"delta": @{@"content": content}, @"finish_reason": [NSNull null]}]};
    NSDictionary *last = @{@"choices": @[@{@"delta": @{}, @"finish_reason": finishReason}]};
    return [NSString stringWithFormat:@"data: %@\n\ndata: %@\n\ndata: [DONE]\n\n", JSONString(chunk), JSONString(last)];
}

static NSString *HeaderValue(YTMUTestHTTPRequest *request, NSString *name) {
    for (NSString *key in request.headers) {
        if ([key caseInsensitiveCompare:name] == NSOrderedSame) return request.headers[key];
    }
    return nil;
}

static NSArray<NSString *> *Lines(NSUInteger count) {
    NSMutableArray *lines = [NSMutableArray array];
    for (NSUInteger i = 0; i < count; i++) [lines addObject:[NSString stringWithFormat:@"source line %lu", (unsigned long)i + 1]];
    return lines;
}

static YTMUTranslationRequest *Request(NSUInteger lineCount) {
    YTMUTranslationRequest *r = [[YTMUTranslationRequest alloc] init];
    r.title = @"Song"; r.artists = @[@"Artist"];
    r.targetLanguageCode = @"en"; r.resolvedTargetLanguage = @"English";
    r.lines = Lines(lineCount);
    return r;
}

// Other test files swap the translator's providers for fakes; put the real
// ones back so translateLines: reaches the HTTP server.
static void InstallRealProviders(void) {
    [[YTMUTranslator sharedTranslator] setValue:@{
        YTMUTranslationProviderOpenAI: [[YTMUOpenAIProvider alloc] init],
        YTMUTranslationProviderAnthropic: [[YTMUAnthropicProvider alloc] init],
        YTMUTranslationProviderGemini: [[YTMUGeminiProvider alloc] init],
    } forKey:@"providers"];
}

static void Configure(NSString *provider, NSString *keySetting, NSString *baseSetting, YTMUTestHTTPServer *server) {
    YTMUTestSetSettings(@{
        @"YTMUltimateIsEnabled": @YES,
        @"translationProvider": provider,
        keySetting: @"test-key",
        baseSetting: server.baseURL,
        @"translationTargetLang": @"en",
        @"translationDebugLogs": @NO,
    });
    InstallRealProviders();
}

static NSError *TranslateSync(NSArray *lines, NSString *videoId, NSArray **outLines) {
    __block NSError *got = nil; __block NSArray *translated = nil; __block BOOL done = NO;
    [[YTMUTranslator sharedTranslator] translateLines:lines videoId:videoId title:@"t" artist:@"a"
                                           completion:^(NSArray<NSString *> *result, NSError *error) {
        translated = result; got = error; done = YES;
    }];
    YTMUTestWaitUntil(15, ^BOOL{ return done; });
    if (outLines) *outLines = translated;
    return done ? got : [NSError errorWithDomain:@"test" code:-1 userInfo:@{NSLocalizedDescriptionKey: @"timed out"}];
}

// A15: a gateway that only speaks /chat/completions.
YTMU_TEST(OpenAI_responses404_fallsBackToChatCompletions_andRemembersIt) {
    YTMUTestHTTPServer *server = [YTMUTestHTTPServer start];
    server.responder = ^NSData *(YTMUTestHTTPRequest *req, NSInteger *status, NSMutableDictionary *headers) {
        if ([req.path hasSuffix:@"/responses"]) {
            *status = 404;
            return [@"{\"error\":\"unknown endpoint\"}" dataUsingEncoding:NSUTF8StringEncoding];
        }
        *status = 200;
        headers[@"Content-Type"] = @"text/event-stream";
        return [ChatSSE(@"{\"lines\":[\"one\",\"two\"]}", @"stop") dataUsingEncoding:NSUTF8StringEncoding];
    };
    Configure(YTMUTranslationProviderOpenAI, @"translationApiKey_openai-compatible", @"translationBaseUrl", server);

    YTMUOpenAIProvider *provider = [[YTMUOpenAIProvider alloc] init];
    __block NSArray *lines = nil; __block NSError *error = nil; __block BOOL done = NO;
    [provider translateRequest:Request(2) completion:^(NSArray *l, NSError *e) { lines = l; error = e; done = YES; }];
    YTMU_ASSERT(YTMUTestWaitUntil(5, ^BOOL{ return done; }), "never completed");
    YTMU_ASSERT(error == nil, "unexpected error %@", error);
    YTMU_ASSERT(([lines isEqualToArray:@[@"one", @"two"]]), "chat-completions answer must be parsed, got %@", lines);
    YTMU_ASSERT_EQ_INT(server.requests.count, 2);
    YTMU_ASSERT([server.requests[0].path hasSuffix:@"/responses"] && [server.requests[1].path hasSuffix:@"/chat/completions"],
                "expected /responses then /chat/completions, got %@ / %@", server.requests[0].path, server.requests[1].path);
    NSDictionary *chatBody = [NSJSONSerialization JSONObjectWithData:server.requests[1].body options:0 error:nil];
    YTMU_ASSERT([chatBody[@"messages"] count] == 2 && [chatBody[@"response_format"][@"type"] isEqualToString:@"json_object"] && [chatBody[@"stream"] boolValue],
                "chat body shape: %@", chatBody);

    // Remembered for this base URL: the next call skips /responses.
    done = NO;
    [provider translateRequest:Request(2) completion:^(NSArray *l, NSError *e) { lines = l; error = e; done = YES; }];
    YTMU_ASSERT(YTMUTestWaitUntil(5, ^BOOL{ return done; }), "second call never completed");
    YTMU_ASSERT(error == nil && lines.count == 2, "second call failed: %@", error);
    YTMU_ASSERT_EQ_INT(server.requests.count, 3);
    YTMU_ASSERT([server.requests[2].path hasSuffix:@"/chat/completions"], "second call must go straight to /chat/completions");

    // The LLM completion path shares the memory.
    done = NO;
    __block NSString *text = nil;
    [provider completeWithSystemPrompt:@"s" userPrompt:@"u" expectJSONMode:YES completion:^(NSString *t, NSError *e) { text = t; error = e; done = YES; }];
    YTMU_ASSERT(YTMUTestWaitUntil(5, ^BOOL{ return done; }), "completion never completed");
    YTMU_ASSERT(error == nil && [text isEqualToString:@"{\"lines\":[\"one\",\"two\"]}"], "completion via chat failed: %@ / %@", text, error);
    YTMU_ASSERT_EQ_INT(server.requests.count, 4);
    YTMU_ASSERT([server.requests[3].path hasSuffix:@"/chat/completions"], "completion must reuse the remembered endpoint");
    [server stop];
}

// A14 / B12: an answer cut off at the token limit is reported as such,
// not retried (the second answer would be cut off too) and not
// remembered (a bigger model would succeed).
YTMU_TEST(Translator_truncatedAnswer_isNotRetried_andNotRemembered) {
    YTMUTestHTTPServer *server = [YTMUTestHTTPServer start];
    NSString *sse =
        @"data: {\"type\":\"response.output_text.delta\",\"delta\":\"{\\\"lines\\\":[\\\"a\\\"\"}\n\n"
        @"data: {\"type\":\"response.incomplete\",\"response\":{\"status\":\"incomplete\",\"incomplete_details\":{\"reason\":\"max_output_tokens\"}}}\n\n";
    [server setTextResponse:sse contentType:@"text/event-stream" status:200];
    Configure(YTMUTranslationProviderOpenAI, @"translationApiKey_openai-compatible", @"translationBaseUrl", server);

    NSError *error = TranslateSync(Lines(12), @"v-truncated", NULL);
    YTMU_ASSERT(error.code == YTMUTranslationErrorTruncated && [error.domain isEqualToString:YTMUTranslationErrorDomain], "expected Truncated, got %@", error);
    YTMU_ASSERT_EQ_INT(server.requests.count, 1);

    error = TranslateSync(Lines(12), @"v-truncated", NULL);
    YTMU_ASSERT_EQ_INT(server.requests.count, 2);                  // asked again: not remembered as a failure
    YTMU_ASSERT(error.code == YTMUTranslationErrorTruncated, "second attempt should report the same verdict, got %@", error);
    [server stop];
}

// A14: one automatic retry only when a second answer could differ.
YTMU_TEST(Translator_retriesOnlyWhenASecondAnswerCouldDiffer) {
    YTMUTestHTTPServer *server = [YTMUTestHTTPServer start];
    __block NSInteger replyStatus = 401;
    server.responder = ^NSData *(YTMUTestHTTPRequest *req, NSInteger *status, NSMutableDictionary *headers) {
        *status = replyStatus;
        if (replyStatus == 200) {
            headers[@"Content-Type"] = @"text/event-stream";
            return [@"data: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"not json at all\"}}\n\n" dataUsingEncoding:NSUTF8StringEncoding];
        }
        headers[@"Content-Type"] = @"application/json";
        return [@"{\"error\":{\"message\":\"nope\"}}" dataUsingEncoding:NSUTF8StringEncoding];
    };
    Configure(YTMUTranslationProviderAnthropic, @"translationApiKey_anthropic", @"translationBaseUrl_anthropic", server);

    NSError *error = TranslateSync(Lines(12), @"v-401", NULL);
    YTMU_ASSERT(error.code == YTMUTranslationErrorHTTPStatus && [error.userInfo[YTMUTranslationErrorHTTPStatusKey] integerValue] == 401, "expected HTTP 401 error, got %@", error);
    YTMU_ASSERT_EQ_INT(server.requests.count, 1);                  // 401: no retry

    replyStatus = 429;
    error = TranslateSync(Lines(12), @"v-429", NULL);
    YTMU_ASSERT_EQ_INT(server.requests.count, 2);                  // rate limited: no retry

    replyStatus = 503;
    error = TranslateSync(Lines(12), @"v-503", NULL);
    YTMU_ASSERT_EQ_INT(server.requests.count, 4);                  // 5xx: one retry
    YTMU_ASSERT(error.code == YTMUTranslationErrorHTTPStatus, "expected HTTP error, got %@", error);

    replyStatus = 200;
    error = TranslateSync(Lines(12), @"v-garbage", NULL);
    YTMU_ASSERT_EQ_INT(server.requests.count, 6);                  // unparseable model output: one retry
    YTMU_ASSERT(error.code == YTMUTranslationErrorParse, "expected Parse error, got %@", error);

    // …and a 401 must not be remembered: the next play asks again.
    replyStatus = 401;
    error = TranslateSync(Lines(12), @"v-401", NULL);
    YTMU_ASSERT_EQ_INT(server.requests.count, 7);
    [server stop];
}

// B12: Claude's max_tokens stop is a truncation, not a parse failure.
YTMU_TEST(Anthropic_maxTokensStop_isReportedAsTruncated) {
    YTMUTestHTTPServer *server = [YTMUTestHTTPServer start];
    NSString *sse =
        @"event: content_block_delta\n"
        @"data: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"{\\\"title_primary\\\":\\\"x\"}}\n\n"
        @"event: message_delta\n"
        @"data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"max_tokens\"},\"usage\":{\"output_tokens\":8192}}\n\n";
    [server setTextResponse:sse contentType:@"text/event-stream" status:200];
    Configure(YTMUTranslationProviderAnthropic, @"translationApiKey_anthropic", @"translationBaseUrl_anthropic", server);

    __block NSError *error = nil; __block NSString *text = nil; __block BOOL done = NO;
    [[[YTMUAnthropicProvider alloc] init] completeWithSystemPrompt:@"s" userPrompt:@"u" expectJSONMode:YES
        completion:^(NSString *t, NSError *e) { text = t; error = e; done = YES; }];
    YTMU_ASSERT(YTMUTestWaitUntil(5, ^BOOL{ return done; }), "completion never fired");
    YTMU_ASSERT(text == nil && error.code == YTMUTranslationErrorTruncated, "expected Truncated, got text=%@ error=%@", text, error);
    [server stop];
}

// B12: the Gemini key rides in a header, a safety block is remembered for
// the song, MAX_TOKENS is a truncation.
YTMU_TEST(Gemini_keyInHeader_safetyBlockRemembered_maxTokensTruncated) {
    YTMUTestHTTPServer *server = [YTMUTestHTTPServer start];
    __block NSDictionary *reply = @{@"promptFeedback": @{@"blockReason": @"SAFETY"}, @"candidates": @[]};
    server.responder = ^NSData *(YTMUTestHTTPRequest *req, NSInteger *status, NSMutableDictionary *headers) {
        *status = 200;
        headers[@"Content-Type"] = @"application/json";
        return [JSONString(reply) dataUsingEncoding:NSUTF8StringEncoding];
    };
    Configure(YTMUTranslationProviderGemini, @"translationApiKey_gemini", @"translationBaseUrl_gemini", server);

    NSError *error = TranslateSync(Lines(12), @"v-gemini-blocked", NULL);
    YTMU_ASSERT(error.code == YTMUTranslationErrorContentBlocked, "expected ContentBlocked, got %@", error);
    YTMU_ASSERT_EQ_INT(server.requests.count, 1);                  // no retry for a refusal
    YTMUTestHTTPRequest *request = server.requests.firstObject;
    YTMU_ASSERT_EQ_STR(HeaderValue(request, @"x-goog-api-key"), @"test-key");
    YTMU_ASSERT([request.path containsString:@"/v1beta/models/"] && ![request.path containsString:@"key="], "key must not be in the URL: %@", request.path);

    error = TranslateSync(Lines(12), @"v-gemini-blocked", NULL);
    YTMU_ASSERT_EQ_INT(server.requests.count, 1);                  // remembered: not asked again this session
    YTMU_ASSERT(error != nil, "a remembered refusal still reports an error");

    reply = @{@"candidates": @[@{@"content": @{@"parts": @[@{@"text": @"{\"lines\":[\"x\""}]}, @"finishReason": @"MAX_TOKENS"}]};
    error = TranslateSync(Lines(12), @"v-gemini-truncated", NULL);
    YTMU_ASSERT(error.code == YTMUTranslationErrorTruncated, "expected Truncated, got %@", error);
    YTMU_ASSERT_EQ_INT(server.requests.count, 2);

    reply = @{@"candidates": @[@{@"content": @{@"parts": @[@{@"text": @"```json\n{\"lines\":[\"1\",\"2\",\"3\",\"4\",\"5\",\"6\",\"7\",\"8\",\"9\",\"10\",\"11\",\"12\"]}\n```"}]}, @"finishReason": @"STOP"}]};
    NSArray *lines = nil;
    error = TranslateSync(Lines(12), @"v-gemini-ok", &lines);
    YTMU_ASSERT(error == nil && lines.count == 12, "a plain JSON body (gateway ignoring alt=sse) must still parse: %@ / %@", error, lines);
    YTMU_ASSERT([server.requests.lastObject.path containsString:@":streamGenerateContent?alt=sse"], "Gemini must be asked for a stream: %@", server.requests.lastObject.path);

    // The real API streams: the answer arrives split over several chunks,
    // the finish reason on the last one.
    server.responder = ^NSData *(YTMUTestHTTPRequest *req, NSInteger *status, NSMutableDictionary *headers) {
        *status = 200;
        headers[@"Content-Type"] = @"text/event-stream";
        NSString *sse = [NSString stringWithFormat:@"data: %@\n\ndata: %@\n\ndata: %@\n\n",
                         JSONString(@{@"candidates": @[@{@"content": @{@"parts": @[@{@"text": @"{\"lines\":[\"1\",\"2\",\"3\",\"4\",\"5\",\"6\","}]}}]}),
                         JSONString(@{@"candidates": @[@{@"content": @{@"parts": @[@{@"text": @"\"7\",\"8\",\"9\",\"10\",\"11\",\"12\"]}"}]}}]}),
                         JSONString(@{@"candidates": @[@{@"content": @{@"parts": @[]}, @"finishReason": @"STOP"}]})];
        return [sse dataUsingEncoding:NSUTF8StringEncoding];
    };
    error = TranslateSync(Lines(12), @"v-gemini-stream", &lines);
    YTMU_ASSERT(error == nil && lines.count == 12 && [lines.lastObject isEqualToString:@"12"], "streamed chunks must be joined: %@ / %@", error, lines);
    [server stop];
}

// C2: the shared fence / JSON-object / SSE helpers.
YTMU_TEST(LLMTextUtils_fences_prose_balancedObjects_andSSE) {
    YTMU_ASSERT_EQ_STR(YTMULLMStripMarkdownFences(@"```json\n{\"a\":1}\n```"), @"{\"a\":1}");
    YTMU_ASSERT_EQ_STR(YTMULLMStripMarkdownFences(@"```{\"a\": 1}```"), @"{\"a\": 1}");
    YTMU_ASSERT_EQ_STR(YTMULLMStripMarkdownFences(@"``` \n[1]\n```"), @"[1]");
    YTMU_ASSERT_EQ_STR(YTMULLMStripMarkdownFences(@"  plain  "), @"plain");
    YTMU_ASSERT_EQ_STR(YTMULLMStripMarkdownFences(nil), @"");

    NSDictionary *object = YTMULLMFirstJSONObject(@"Sure! Here it is:\n{\"title\":\"a } b\",\"n\":{\"x\":1}}\nHope this helps }");
    YTMU_ASSERT([object[@"title"] isEqualToString:@"a } b"] && [object[@"n"][@"x"] integerValue] == 1,
                "brace-balanced extraction with braces in strings and prose: %@", object);
    YTMU_ASSERT([YTMULLMFirstJSONObject(@"```json\n{\"k\":\"v\"}\n```")[@"k"] isEqualToString:@"v"], "fenced object");
    YTMU_ASSERT(YTMULLMFirstJSONObject(@"{\"unterminated\": \"x") == nil, "a truncated object must not parse");
    YTMU_ASSERT(YTMULLMFirstJSONObject(nil) == nil && YTMULLMFirstJSONObject(@"no json here") == nil, "nil / no object");
    YTMU_ASSERT(YTMULLMBalancedObjectSubstring(@"x{y}", 0) == nil, "must point at a brace");

    NSMutableArray *types = [NSMutableArray array];
    NSData *sse = [@"event: a\r\ndata: {\"type\":\"one\"}\r\n\r\ndata: [DONE]\r\n\r\ndata:{\"type\":\"two\"}\n\ndata: not json\n\n" dataUsingEncoding:NSUTF8StringEncoding];
    YTMUSSEEnumerateJSONEvents(sse, ^(NSDictionary *json) { [types addObject:json[@"type"]]; });
    YTMU_ASSERT(([types isEqualToArray:@[@"one", @"two"]]), "SSE events (CRLF, [DONE], no-space data:): %@", types);
    YTMUSSEEnumerateJSONEvents(nil, ^(NSDictionary *json) { [types addObject:@"never"]; });
    YTMU_ASSERT_EQ_INT(types.count, 2);
}
