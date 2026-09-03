#import "YTMUOpenAIProvider.h"
#import "../YTMUPromptBuilder.h"
#import "../YTMULLMTextUtils.h"
#import "../../Utils/YTMUSettings.h"

// Two wire formats behind one provider:
//   • the Responses API (`/responses`; `instructions` + `input`;
//     `response.output_text.delta` stream events) — OpenAI's current
//     surface and what most gateways expose;
//   • Chat Completions (`/chat/completions`; `messages`;
//     `choices[0].delta.content` stream chunks) — what older or
//     self-hosted OpenAI-compatible servers (Ollama, LM Studio, one-api,
//     …) still speak.
// Responses is tried first; a base URL that answers 404/405 there is
// switched to Chat Completions for the rest of the process.
typedef NS_ENUM(NSInteger, YTMUOpenAIEndpoint) {
    YTMUOpenAIEndpointResponses = 0,
    YTMUOpenAIEndpointChatCompletions = 1,
};

static NSString *const YTMUOpenAIDefaultBaseURL = @"https://api.openai.com/v1";

static NSError *YTMUOpenAIError(YTMUTranslationErrorCode code, NSString *message) {
    return YTMUTranslationMakeError(code, message ?: @"OpenAI-compatible translation failed");
}

// The user's base URL normalised to the API root: trailing slashes and a
// pasted `/responses` or `/chat/completions` suffix are dropped so both
// endpoints can be derived from it.
static NSString *YTMUOpenAIBaseURL(void) {
    NSString *raw = YTMUSettingsString(@"translationBaseUrl", YTMUOpenAIDefaultBaseURL);
    NSString *trimmed = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    while ([trimmed hasSuffix:@"/"]) trimmed = [trimmed substringToIndex:trimmed.length - 1];
    NSString *lower = trimmed.lowercaseString;
    if ([lower hasSuffix:@"/responses"]) {
        trimmed = [trimmed substringToIndex:trimmed.length - @"/responses".length];
    } else if ([lower hasSuffix:@"/chat/completions"]) {
        trimmed = [trimmed substringToIndex:trimmed.length - @"/chat/completions".length];
    }
    while ([trimmed hasSuffix:@"/"]) trimmed = [trimmed substringToIndex:trimmed.length - 1];
    return trimmed.length ? trimmed : YTMUOpenAIDefaultBaseURL;
}

static NSString *YTMUOpenAIEndpointURL(NSString *base, YTMUOpenAIEndpoint endpoint) {
    return [base stringByAppendingString:endpoint == YTMUOpenAIEndpointResponses ? @"/responses" : @"/chat/completions"];
}

// Base URLs whose /responses answered 404/405 in this process.
static NSMutableSet<NSString *> *YTMUOpenAIChatOnlyBases(void) {
    static NSMutableSet *bases;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ bases = [NSMutableSet set]; });
    return bases;
}

static YTMUOpenAIEndpoint YTMUOpenAIPreferredEndpoint(NSString *base) {
    NSMutableSet *bases = YTMUOpenAIChatOnlyBases();
    @synchronized (bases) {
        return [bases containsObject:base] ? YTMUOpenAIEndpointChatCompletions : YTMUOpenAIEndpointResponses;
    }
}

static void YTMUOpenAIRememberChatOnlyBase(NSString *base) {
    NSMutableSet *bases = YTMUOpenAIChatOnlyBases();
    @synchronized (bases) {
        [bases addObject:base];
    }
}

static NSString *YTMUOpenAIStringOrFallback(id value, NSString *fallback) {
    return ([value isKindOfClass:[NSString class]] && [value length]) ? value : fallback;
}

// Accumulates the streamed text. `outError` reports an explicit error
// event, a safety stop, or an answer cut off at the output token limit —
// partial JSON is worse to show than a clear error, and the translator
// must not retry or remember those as if the model had misbehaved.
static NSString *YTMUOpenAIAccumulateStream(NSData *data, YTMUOpenAIEndpoint endpoint, NSError **outError) {
    NSMutableString *accumulated = [NSMutableString string];
    __block NSError *error = nil;
    YTMUSSEEnumerateJSONEvents(data, ^(NSDictionary *json) {
        if (endpoint == YTMUOpenAIEndpointChatCompletions) {
            // {"error":{"message":…}} | {"choices":[{"delta":{"content":…},"finish_reason":null|"stop"|"length"|"content_filter"}]}
            NSDictionary *err = json[@"error"];
            if ([err isKindOfClass:[NSDictionary class]]) {
                error = YTMUOpenAIError(YTMUTranslationErrorHTTPStatus, YTMUOpenAIStringOrFallback(err[@"message"], @"OpenAI stream error"));
                return;
            }
            NSArray *choices = json[@"choices"];
            NSDictionary *choice = [choices isKindOfClass:[NSArray class]] && choices.count ? choices.firstObject : nil;
            if (![choice isKindOfClass:[NSDictionary class]]) return;
            NSDictionary *delta = choice[@"delta"];
            id content = [delta isKindOfClass:[NSDictionary class]] ? delta[@"content"] : nil;
            if ([content isKindOfClass:[NSString class]]) [accumulated appendString:content];
            NSString *finish = YTMUOpenAIStringOrFallback(choice[@"finish_reason"], @"");
            if ([finish isEqualToString:@"length"] && !error) {
                error = YTMUOpenAIError(YTMUTranslationErrorTruncated, @"The model stopped at its output token limit before finishing");
            } else if ([finish isEqualToString:@"content_filter"] && !error) {
                error = YTMUOpenAIError(YTMUTranslationErrorContentBlocked, @"The model's content filter stopped this answer");
            }
            return;
        }

        NSString *type = YTMUOpenAIStringOrFallback(json[@"type"], @"");
        if ([type isEqualToString:@"response.output_text.delta"]) {
            NSString *delta = json[@"delta"];
            if ([delta isKindOfClass:[NSString class]]) [accumulated appendString:delta];
        } else if ([type isEqualToString:@"response.incomplete"]) {
            // {"response":{"status":"incomplete","incomplete_details":{"reason":"max_output_tokens"|"content_filter"}}}
            NSDictionary *response = json[@"response"];
            NSDictionary *details = [response isKindOfClass:[NSDictionary class]] ? response[@"incomplete_details"] : nil;
            NSString *reason = YTMUOpenAIStringOrFallback([details isKindOfClass:[NSDictionary class]] ? details[@"reason"] : nil, @"unknown reason");
            if (error) return;
            if ([reason isEqualToString:@"content_filter"]) {
                error = YTMUOpenAIError(YTMUTranslationErrorContentBlocked, @"The model's content filter stopped this answer");
            } else {
                error = YTMUOpenAIError(YTMUTranslationErrorTruncated, [NSString stringWithFormat:@"The model did not finish its answer (%@)", reason]);
            }
        } else if ([type isEqualToString:@"error"] || [type isEqualToString:@"response.failed"]) {
            // Prefer a dictionary-shaped `error`; fall back to `response`
            // (response.failed nests the error there). `?:` alone would
            // happily pick an NSNull `error`.
            NSDictionary *err = [json[@"error"] isKindOfClass:[NSDictionary class]] ? json[@"error"] : json[@"response"];
            id rawMessage = [err isKindOfClass:[NSDictionary class]] ? err[@"message"] : nil;
            if (![rawMessage isKindOfClass:[NSString class]] && [err isKindOfClass:[NSDictionary class]]) {
                NSDictionary *nested = err[@"error"];
                if ([nested isKindOfClass:[NSDictionary class]]) rawMessage = nested[@"message"];
            }
            error = YTMUOpenAIError(YTMUTranslationErrorHTTPStatus, YTMUOpenAIStringOrFallback(rawMessage, @"OpenAI stream error"));
        }
    });
    if (outError) *outError = error;
    return [accumulated copy];
}

typedef void (^YTMUOpenAITextCompletion)(NSString *_Nullable text, NSError *_Nullable error, BOOL jsonModeUsed);

@implementation YTMUOpenAIProvider

- (NSString *)providerName {
    return YTMUTranslationProviderOpenAI;
}

- (NSString *)modelIdentifier {
    return YTMUSettingsString(@"translationModel_openai-compatible", YTMUTranslationDefaultModelForProvider(YTMUTranslationProviderOpenAI));
}

- (NSDictionary *)bodyForSystem:(NSString *)system
                           user:(NSString *)user
                       jsonMode:(BOOL)jsonMode
                      maxTokens:(NSInteger)maxTokens
                       endpoint:(YTMUOpenAIEndpoint)endpoint {
    // Streaming on both endpoints so NSURLSession's per-chunk timeout reset
    // keeps the connection alive through long generations (a 50-line CJK
    // translation can sit on the wire for a minute).
    //
    // The token ceiling is a cap, not a target — billing is for the tokens
    // actually generated. 8192 covers whole-song translations (worst
    // observed ~3k visible tokens, plus reasoning-tier models' hidden
    // tokens); 4096 covers the short structured answers of
    // title-normalize / description-extract.
    if (endpoint == YTMUOpenAIEndpointChatCompletions) {
        NSMutableDictionary *body = [@{
            @"model": [self modelIdentifier],
            @"messages": @[
                @{@"role": @"system", @"content": system ?: @""},
                @{@"role": @"user", @"content": user ?: @""},
            ],
            @"stream": @YES,
            @"max_tokens": @(maxTokens),
        } mutableCopy];
        if (jsonMode) body[@"response_format"] = @{@"type": @"json_object"};
        return body;
    }
    NSMutableDictionary *body = [@{
        @"model": [self modelIdentifier],
        @"instructions": system ?: @"",
        @"input": user ?: @"",
        @"stream": @YES,
        @"max_output_tokens": @(maxTokens),
    } mutableCopy];
    if (jsonMode) body[@"text"] = @{@"format": @{@"type": @"json_object"}};
    return body;
}

- (void)postBody:(NSDictionary *)body
           toURL:(NSString *)url
      completion:(void (^)(NSData *data, NSInteger status, NSError *error))completion {
    NSString *apiKey = YTMUSettingsString(@"translationApiKey_openai-compatible", @"");
    NSMutableDictionary *headers = [@{@"Accept": @"text/event-stream"} mutableCopy];
    if (apiKey.length) headers[@"Authorization"] = [@"Bearer " stringByAppendingString:apiKey];
    // 120 s idle timeout; streaming resets it per chunk, so a long
    // generation never trips it while bytes keep arriving.
    YTMULLMPostJSON(url, headers, body, 120.0, completion);
}

- (BOOL)shouldRetryWithoutJSONModeForStatus:(NSInteger)status body:(NSString *)body {
    if (status != 400) return NO;
    NSRange range = [body rangeOfString:@"response_format|json_object|text\\.format|json"
                                options:NSRegularExpressionSearch | NSCaseInsensitiveSearch];
    return range.location != NSNotFound;
}

// One logical request: talks to `endpoint`, falls back from Responses to
// Chat Completions on 404/405 (remembered per base URL), retries once
// without JSON mode when the server rejects it, and hands back the
// accumulated text.
- (void)sendSystem:(NSString *)system
              user:(NSString *)user
          jsonMode:(BOOL)jsonMode
         maxTokens:(NSInteger)maxTokens
          endpoint:(YTMUOpenAIEndpoint)endpoint
        completion:(YTMUOpenAITextCompletion)completion {
    NSString *base = YTMUOpenAIBaseURL();
    NSDictionary *body = [self bodyForSystem:system user:user jsonMode:jsonMode maxTokens:maxTokens endpoint:endpoint];
    [self postBody:body toURL:YTMUOpenAIEndpointURL(base, endpoint) completion:^(NSData *data, NSInteger status, NSError *error) {
        if (error) {
            completion(nil, error, jsonMode);
            return;
        }
        if (status >= 200 && status < 300) {
            NSError *streamError = nil;
            NSString *text = YTMUOpenAIAccumulateStream(data, endpoint, &streamError);
            if (streamError) {
                completion(nil, streamError, jsonMode);
                return;
            }
            completion(text ?: @"", nil, jsonMode);
            return;
        }
        if ((status == 404 || status == 405) && endpoint == YTMUOpenAIEndpointResponses) {
            YTMUTranslationLog(@"openai-compatible /responses answered %ld at %@ — using /chat/completions for this base URL from now on", (long)status, base);
            YTMUOpenAIRememberChatOnlyBase(base);
            [self sendSystem:system user:user jsonMode:jsonMode maxTokens:maxTokens endpoint:YTMUOpenAIEndpointChatCompletions completion:completion];
            return;
        }
        NSString *bodyText = data.length ? ([[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"") : @"";
        if (jsonMode && [self shouldRetryWithoutJSONModeForStatus:status body:bodyText]) {
            YTMUTranslationLog(@"openai-compatible retrying without JSON mode status=%ld", (long)status);
            [self sendSystem:system user:user jsonMode:NO maxTokens:maxTokens endpoint:endpoint completion:completion];
            return;
        }
        YTMUTranslationLog(@"openai-compatible failed status=%ld", (long)status);
        completion(nil, YTMUTranslationHTTPError(@"OpenAI-compatible API", status, data, 300), jsonMode);
    }];
}

// Some proxies have a safety filter on the Responses endpoint that
// triggers only when JSON mode is requested. The filter returns a
// canned refusal text inside a 200 OK response (usage shows zero
// input/output tokens — the proxy never forwards to the underlying
// model). Detecting refusal at parse-time lets us retry without
// JSON mode, which usually slips past the filter on the same model.
- (BOOL)responseLooksLikeSafetyRefusal:(NSString *)text {
    if (!text.length || text.length > 500) return NO;
    NSString *lower = [text lowercaseString];
    NSArray *needles = @[
        @"i'm sorry",
        @"i am sorry",
        @"i cannot assist",
        @"i can't assist",
        @"i cannot help",
        @"i can't help",
        @"i cannot comply",
        @"i can't comply",
        @"i'm unable to",
        @"i am unable to",
        @"i'm not able to",
    ];
    for (NSString *n in needles) {
        if ([lower rangeOfString:n].location != NSNotFound) return YES;
    }
    return NO;
}

- (NSError *)parseFailureForText:(NSString *)text lineCount:(NSUInteger)lineCount {
    // Enough of the actual response to diagnose parse failures (fence
    // shape / truncation point) without dumping the whole body.
    NSString *safe = text ?: @"";
    NSUInteger headLen = MIN((NSUInteger)80, safe.length);
    NSString *head = headLen ? [safe substringToIndex:headLen] : @"";
    NSString *tail = safe.length > 80 ? [safe substringFromIndex:safe.length - 80] : @"";
    YTMUTranslationLog(@"openai-compatible parse failed lines=%lu textLen=%lu head=%@ tail=%@",
                       (unsigned long)lineCount,
                       (unsigned long)safe.length,
                       head,
                       tail);
    return YTMUOpenAIError(YTMUTranslationErrorParse, @"Could not parse JSON from the OpenAI-compatible response");
}

- (void)translateRequest:(YTMUTranslationRequest *)request
              completion:(void (^)(NSArray<NSString *> * _Nullable, NSError * _Nullable))completion {
    NSString *base = YTMUOpenAIBaseURL();
    YTMUTranslationLog(@"openai-compatible start model=%@ lines=%lu baseUrl=%@",
                       [self modelIdentifier],
                       (unsigned long)request.lines.count,
                       base);
    NSString *system = [YTMUPromptBuilder systemPromptForRequest:request];
    NSString *user = [YTMUPromptBuilder userPromptForRequest:request];
    NSUInteger expected = request.lines.count;

    [self sendSystem:system user:user jsonMode:YES maxTokens:8192 endpoint:YTMUOpenAIPreferredEndpoint(base)
          completion:^(NSString *text, NSError *error, BOOL jsonModeUsed) {
        if (error) {
            completion(nil, error);
            return;
        }
        NSArray *parsed = [YTMUPromptBuilder parseLinesFromJSON:text expected:expected];
        if (parsed) {
            YTMUTranslationLog(@"openai-compatible success translatedLines=%lu", (unsigned long)parsed.count);
            completion(parsed, nil);
            return;
        }
        if (!jsonModeUsed || ![self responseLooksLikeSafetyRefusal:text]) {
            completion(nil, [self parseFailureForText:text lineCount:expected]);
            return;
        }
        YTMUTranslationLog(@"openai-compatible response looks like a safety refusal under JSON mode — retrying without JSON mode");
        [self sendSystem:system user:user jsonMode:NO maxTokens:8192 endpoint:YTMUOpenAIPreferredEndpoint(base)
              completion:^(NSString *retryText, NSError *retryError, BOOL unused) {
            if (retryError) {
                completion(nil, retryError);
                return;
            }
            NSArray *retryParsed = [YTMUPromptBuilder parseLinesFromJSON:retryText expected:expected];
            if (retryParsed) {
                YTMUTranslationLog(@"openai-compatible success translatedLines=%lu", (unsigned long)retryParsed.count);
                completion(retryParsed, nil);
                return;
            }
            completion(nil, [self parseFailureForText:retryText lineCount:expected]);
        }];
    }];
}

#pragma mark - YTMULLMCompletionProvider

- (void)completeWithSystemPrompt:(NSString *)systemPrompt
                      userPrompt:(NSString *)userPrompt
                  expectJSONMode:(BOOL)expectJSONMode
                      completion:(void(^)(NSString *_Nullable text, NSError *_Nullable error))completion {
    NSString *apiKey = YTMUSettingsString(@"translationApiKey_openai-compatible", @"");
    if (!apiKey.length) {
        completion(nil, YTMUOpenAIError(YTMUTranslationErrorMissingAPIKey, @"OpenAI-compatible API key is empty"));
        return;
    }
    [self sendSystem:systemPrompt user:userPrompt jsonMode:expectJSONMode maxTokens:4096
            endpoint:YTMUOpenAIPreferredEndpoint(YTMUOpenAIBaseURL())
          completion:^(NSString *text, NSError *error, BOOL jsonModeUsed) {
        if (error) {
            completion(nil, error);
            return;
        }
        if (!text.length) {
            completion(nil, YTMUOpenAIError(YTMUTranslationErrorEmptyResponse, @"OpenAI returned empty completion"));
            return;
        }
        completion(text, nil);
    }];
}

@end
