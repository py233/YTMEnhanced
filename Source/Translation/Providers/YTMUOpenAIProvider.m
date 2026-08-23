#import "YTMUOpenAIProvider.h"
#import "../YTMUPromptBuilder.h"

static NSString *YTMUOpenAIDefaultsString(NSString *key, NSString *fallback) {
    NSDictionary *dict = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"YTMUltimate"] ?: @{};
    id value = dict[key];
    if ([value isKindOfClass:[NSString class]] && [(NSString *)value length]) return value;
    return fallback ?: @"";
}

static NSError *YTMUOpenAIError(YTMUTranslationErrorCode code, NSString *message) {
    return [NSError errorWithDomain:YTMUTranslationErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: message ?: @"OpenAI-compatible translation failed"}];
}

static NSString *YTMUOpenAIResponsesURL(NSString *baseURL) {
    NSString *trimmed = [baseURL stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    while ([trimmed hasSuffix:@"/"]) {
        trimmed = [trimmed substringToIndex:trimmed.length - 1];
    }
    if (!trimmed.length) trimmed = @"https://api.openai.com/v1";
    if ([trimmed.lowercaseString hasSuffix:@"/responses"]) return trimmed;
    return [trimmed stringByAppendingString:@"/responses"];
}



@implementation YTMUOpenAIProvider

- (NSString *)providerName {
    return YTMUTranslationProviderOpenAI;
}

- (NSString *)modelIdentifier {
    return YTMUOpenAIDefaultsString(@"translationModel_openai-compatible", YTMUTranslationDefaultModelForProvider(YTMUTranslationProviderOpenAI));
}

- (NSDictionary *)requestBodyForRequest:(YTMUTranslationRequest *)request includeJSONMode:(BOOL)includeJSONMode {
    NSMutableDictionary *body = [@{
        @"model": [self modelIdentifier],
        @"instructions": [YTMUPromptBuilder systemPromptForRequest:request],
        @"input": [YTMUPromptBuilder userPromptForRequest:request],
        // Stream the response so NSURLSession's per-chunk timeout
        // reset keeps the connection alive through long generations
        // (a 50-line CJK translation can sit on the wire for 50–60 s;
        // streaming guarantees bytes arrive incrementally and never
        // trip the timeoutInterval).
        @"stream": @YES,
        // max_output_tokens is a ceiling, not a target — billing
        // is always for actual tokens generated. 8192 = sensible
        // cap for whole-song translations: real-world bill shows
        // worst-case ~3035 visible output tokens, and reasoning-
        // tier models (gpt-5.x, o3, o4-mini) add ~2500 reasoning
        // tokens internally. 8192 gives ~170% headroom over the
        // worst observed and leaves room for the verbose end of
        // reasoning models, while still bounding any pathological
        // model loop well before runaway cost.
        @"max_output_tokens": @8192,
    } mutableCopy];

    if (includeJSONMode) {
        body[@"text"] = @{@"format": @{@"type": @"json_object"}};
    }
    return body;
}

// OpenAI Responses streams the model output as a sequence of
// Server-Sent Events. We only care about `response.output_text.delta`
// events; their `delta` field carries the incremental text we
// concatenate to reconstruct the final JSON payload. Other event
// types (response.created / response.output_item.added /
// response.completed / etc.) are metadata we ignore.
static NSString *YTMUOpenAIAccumulateSSE(NSData *data, NSError **outError) {
    if (!data.length) return @"";
    NSString *body = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!body.length) return @"";
    NSMutableString *accumulated = [NSMutableString string];
    NSArray<NSString *> *events = [body componentsSeparatedByString:@"\n\n"];
    for (NSString *event in events) {
        NSString *dataPayload = nil;
        for (NSString *line in [event componentsSeparatedByString:@"\n"]) {
            if ([line hasPrefix:@"data: "]) {
                dataPayload = [line substringFromIndex:6];
                break;
            }
        }
        if (!dataPayload.length) continue;
        // The end-of-stream marker `data: [DONE]` is not valid JSON;
        // skip it.
        if ([dataPayload isEqualToString:@"[DONE]"]) continue;
        NSData *jsonData = [dataPayload dataUsingEncoding:NSUTF8StringEncoding];
        NSDictionary *json = jsonData
            ? [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:nil]
            : nil;
        if (![json isKindOfClass:[NSDictionary class]]) continue;
        // Wire data (possibly via a user-configured gateway): JSON null and
        // wrong-typed values are real inputs, and NSNull does not respond to
        // isEqualToString: / length. Type-check before touching anything.
        id typeValue = json[@"type"];
        NSString *type = [typeValue isKindOfClass:[NSString class]] ? typeValue : @"";
        if ([type isEqualToString:@"response.output_text.delta"]) {
            NSString *delta = json[@"delta"];
            if ([delta isKindOfClass:[NSString class]]) {
                [accumulated appendString:delta];
            }
        } else if ([type isEqualToString:@"error"] ||
                   [type isEqualToString:@"response.failed"]) {
            // Prefer a dictionary-shaped `error`; fall back to `response`
            // (response.failed nests the error there). `?:` alone would
            // happily pick an NSNull `error`.
            NSDictionary *err = [json[@"error"] isKindOfClass:[NSDictionary class]] ? json[@"error"] : json[@"response"];
            id rawMessage = [err isKindOfClass:[NSDictionary class]] ? err[@"message"] : nil;
            if (![rawMessage isKindOfClass:[NSString class]] && [err isKindOfClass:[NSDictionary class]]) {
                // response.failed: {"response":{"error":{"message":...}}}
                NSDictionary *nested = err[@"error"];
                if ([nested isKindOfClass:[NSDictionary class]]) rawMessage = nested[@"message"];
            }
            NSString *msg = ([rawMessage isKindOfClass:[NSString class]] && [rawMessage length])
                ? rawMessage
                : @"OpenAI stream error";
            if (outError) {
                *outError = [NSError errorWithDomain:YTMUTranslationErrorDomain
                                                code:YTMUTranslationErrorHTTPStatus
                                            userInfo:@{NSLocalizedDescriptionKey: msg}];
            }
        }
    }
    return [accumulated copy];
}

- (void)postRequest:(YTMUTranslationRequest *)request
    includeJSONMode:(BOOL)includeJSONMode
         completion:(void(^)(NSData *data, NSURLResponse *response, NSError *error))completion {
    NSString *baseURL = YTMUOpenAIDefaultsString(@"translationBaseUrl", @"https://api.openai.com/v1");
    NSString *apiKey = YTMUOpenAIDefaultsString(@"translationApiKey_openai-compatible", @"");

    NSMutableURLRequest *urlRequest = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:YTMUOpenAIResponsesURL(baseURL)]];
    urlRequest.HTTPMethod = @"POST";
    // 120 s: streaming resets the timer per chunk, so even a 60+ s
    // long-song generation has zero risk of tripping the timeout
    // while bytes keep arriving.
    urlRequest.timeoutInterval = 120.0;
    urlRequest.HTTPBody = [NSJSONSerialization dataWithJSONObject:[self requestBodyForRequest:request includeJSONMode:includeJSONMode]
                                                          options:0
                                                            error:nil];
    [urlRequest setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [urlRequest setValue:@"text/event-stream" forHTTPHeaderField:@"Accept"];
    if (apiKey.length) {
        [urlRequest setValue:[@"Bearer " stringByAppendingString:apiKey] forHTTPHeaderField:@"Authorization"];
    }

    [[[NSURLSession sharedSession] dataTaskWithRequest:urlRequest completionHandler:completion] resume];
}


- (BOOL)shouldRetryWithoutJSONModeForStatus:(NSInteger)status body:(NSString *)body {
    if (status != 400) return NO;
    NSRange range = [body rangeOfString:@"response_format|json_object|text\\.format|json"
                                options:NSRegularExpressionSearch | NSCaseInsensitiveSearch];
    return range.location != NSNotFound;
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

- (void)handleData:(NSData *)data
          response:(NSURLResponse *)response
             error:(NSError *)error
           request:(YTMUTranslationRequest *)request
     canRetryNoJSON:(BOOL)canRetryNoJSON
        completion:(void (^)(NSArray<NSString *> * _Nullable, NSError * _Nullable))completion {
    if (error) {
        completion(nil, error);
        return;
    }

    NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]] ? [(NSHTTPURLResponse *)response statusCode] : 0;
    if (status < 200 || status >= 300) {
        NSString *bodyText = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"";
        if (canRetryNoJSON && [self shouldRetryWithoutJSONModeForStatus:status body:bodyText ?: @""]) {
            YTMUTranslationLog(@"openai-compatible retrying without JSON mode status=%ld", (long)status);
            [self postRequest:request includeJSONMode:NO completion:^(NSData *retryData, NSURLResponse *retryResponse, NSError *retryError) {
                [self handleData:retryData response:retryResponse error:retryError request:request canRetryNoJSON:NO completion:completion];
            }];
            return;
        }

        NSString *message = [NSString stringWithFormat:@"OpenAI-compatible API %ld: %@", (long)status, [bodyText substringToIndex:MIN((NSUInteger)300, bodyText.length)] ?: @""];
        YTMUTranslationLog(@"openai-compatible failed status=%ld", (long)status);
        completion(nil, YTMUOpenAIError(YTMUTranslationErrorHTTPStatus, message));
        return;
    }

    NSError *streamError = nil;
    NSString *content = YTMUOpenAIAccumulateSSE(data, &streamError);
    if (streamError) {
        completion(nil, streamError);
        return;
    }
    NSString *safeContent = content ?: @"";
    NSArray *parsed = [YTMUPromptBuilder parseLinesFromJSON:safeContent expected:request.lines.count];
    if (!parsed) {
        // Proxy-side safety filter: short refusal text under JSON mode.
        // Try dropping JSON mode — some proxies gate only `text.format`
        // and the filter is flaky enough that the no-JSON retry slips
        // through on most attempts. Don't auto-fall back to
        // /chat/completions: that path returns truncated output on
        // explicit-lyrics tracks (model stops mid-stream around
        // sensitive content) and the partial JSON we get back is
        // worse to show than a clean error, plus the gateway admin
        // prefers the modern Responses path.
        if (canRetryNoJSON && [self responseLooksLikeSafetyRefusal:safeContent]) {
            YTMUTranslationLog(@"openai-compatible response looks like safety refusal under JSON mode — retrying without JSON mode");
            [self postRequest:request includeJSONMode:NO completion:^(NSData *retryData, NSURLResponse *retryResponse, NSError *retryError) {
                [self handleData:retryData response:retryResponse error:retryError request:request canRetryNoJSON:NO completion:completion];
            }];
            return;
        }
        NSUInteger headLen = MIN((NSUInteger)80, safeContent.length);
        NSString *head = headLen ? [safeContent substringToIndex:headLen] : @"";
        NSString *tail = safeContent.length > 80
            ? [safeContent substringFromIndex:safeContent.length - 80]
            : @"";
        YTMUTranslationLog(@"openai-compatible responses parse failed lines=%lu textLen=%lu head=%@ tail=%@",
                          (unsigned long)request.lines.count,
                          (unsigned long)safeContent.length,
                          head,
                          tail);
        completion(nil, YTMUOpenAIError(YTMUTranslationErrorParse, @"Could not parse JSON from Responses API response"));
        return;
    }
    YTMUTranslationLog(@"openai-compatible responses success translatedLines=%lu", (unsigned long)parsed.count);
    completion(parsed, nil);
}

- (void)translateRequest:(YTMUTranslationRequest *)request
              completion:(void (^)(NSArray<NSString *> * _Nullable, NSError * _Nullable))completion {
    YTMUTranslationLog(@"openai-compatible responses start model=%@ lines=%lu baseUrl=%@",
                       [self modelIdentifier],
                       (unsigned long)request.lines.count,
                       YTMUOpenAIDefaultsString(@"translationBaseUrl", @"https://api.openai.com/v1"));
    [self postRequest:request includeJSONMode:YES completion:^(NSData *data, NSURLResponse *response, NSError *error) {
        [self handleData:data response:response error:error request:request canRetryNoJSON:YES completion:completion];
    }];
}

#pragma mark - YTMULLMCompletionProvider

- (NSDictionary *)completionBodyForSystem:(NSString *)systemPrompt
                                     user:(NSString *)userPrompt
                                 jsonMode:(BOOL)jsonMode {
    // Chat-completion path is used by title-normalize and
    // description-extract, both of which output short structured
    // JSON (typically 500–1500 tokens). 4096 is plenty headroom
    // without risking runaway output if a model misbehaves.
    NSMutableDictionary *body = [@{
        @"model": [self modelIdentifier],
        @"instructions": systemPrompt ?: @"",
        @"input": userPrompt ?: @"",
        @"stream": @YES,
        @"max_output_tokens": @4096,
    } mutableCopy];
    if (jsonMode) body[@"text"] = @{@"format": @{@"type": @"json_object"}};
    return body;
}

- (void)postCompletionWithSystem:(NSString *)systemPrompt
                            user:(NSString *)userPrompt
                        jsonMode:(BOOL)jsonMode
                      completion:(void(^)(NSData *data, NSURLResponse *response, NSError *error))completion {
    NSString *baseURL = YTMUOpenAIDefaultsString(@"translationBaseUrl", @"https://api.openai.com/v1");
    NSString *apiKey = YTMUOpenAIDefaultsString(@"translationApiKey_openai-compatible", @"");
    NSMutableURLRequest *urlRequest = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:YTMUOpenAIResponsesURL(baseURL)]];
    urlRequest.HTTPMethod = @"POST";
    urlRequest.timeoutInterval = 120.0;
    urlRequest.HTTPBody = [NSJSONSerialization dataWithJSONObject:[self completionBodyForSystem:systemPrompt user:userPrompt jsonMode:jsonMode]
                                                          options:0
                                                            error:nil];
    [urlRequest setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [urlRequest setValue:@"text/event-stream" forHTTPHeaderField:@"Accept"];
    if (apiKey.length) [urlRequest setValue:[@"Bearer " stringByAppendingString:apiKey] forHTTPHeaderField:@"Authorization"];
    [[[NSURLSession sharedSession] dataTaskWithRequest:urlRequest completionHandler:completion] resume];
}

- (void)completeWithSystemPrompt:(NSString *)systemPrompt
                      userPrompt:(NSString *)userPrompt
                  expectJSONMode:(BOOL)expectJSONMode
                      completion:(void(^)(NSString *_Nullable text, NSError *_Nullable error))completion {
    NSString *apiKey = YTMUOpenAIDefaultsString(@"translationApiKey_openai-compatible", @"");
    if (!apiKey.length) {
        completion(nil, YTMUOpenAIError(YTMUTranslationErrorMissingAPIKey, @"OpenAI-compatible API key is empty"));
        return;
    }

    __weak typeof(self) weakSelf = self;
    void (^handle)(NSData *, NSURLResponse *, NSError *, BOOL) = ^(NSData *data, NSURLResponse *response, NSError *error, BOOL canRetry) {
        if (error) { completion(nil, error); return; }
        NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]] ? [(NSHTTPURLResponse *)response statusCode] : 0;
        if (status < 200 || status >= 300) {
            NSString *bodyText = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"";
            if (canRetry && [weakSelf shouldRetryWithoutJSONModeForStatus:status body:bodyText ?: @""]) {
                YTMUTranslationLog(@"openai-compatible normalize retrying without JSON mode status=%ld", (long)status);
                [weakSelf postCompletionWithSystem:systemPrompt user:userPrompt jsonMode:NO completion:^(NSData *retryData, NSURLResponse *retryResponse, NSError *retryError) {
                    if (retryError) { completion(nil, retryError); return; }
                    NSInteger retryStatus = [retryResponse isKindOfClass:[NSHTTPURLResponse class]] ? [(NSHTTPURLResponse *)retryResponse statusCode] : 0;
                    if (retryStatus < 200 || retryStatus >= 300) {
                        NSString *retryBody = retryData ? [[NSString alloc] initWithData:retryData encoding:NSUTF8StringEncoding] : @"";
                        completion(nil, YTMUOpenAIError(YTMUTranslationErrorHTTPStatus, [NSString stringWithFormat:@"OpenAI %ld: %@", (long)retryStatus, [retryBody substringToIndex:MIN((NSUInteger)200, retryBody.length)] ?: @""]));
                        return;
                    }
                    NSError *retryStreamErr = nil;
                    NSString *text = YTMUOpenAIAccumulateSSE(retryData, &retryStreamErr);
                    if (retryStreamErr) { completion(nil, retryStreamErr); return; }
                    if (!text.length) { completion(nil, YTMUOpenAIError(YTMUTranslationErrorEmptyResponse, @"OpenAI returned empty completion")); return; }
                    completion(text, nil);
                }];
                return;
            }
            completion(nil, YTMUOpenAIError(YTMUTranslationErrorHTTPStatus, [NSString stringWithFormat:@"OpenAI %ld: %@", (long)status, [bodyText substringToIndex:MIN((NSUInteger)200, bodyText.length)] ?: @""]));
            return;
        }
        NSError *streamErr = nil;
        NSString *text = YTMUOpenAIAccumulateSSE(data, &streamErr);
        if (streamErr) { completion(nil, streamErr); return; }
        if (!text.length) { completion(nil, YTMUOpenAIError(YTMUTranslationErrorEmptyResponse, @"OpenAI returned empty completion")); return; }
        completion(text, nil);
    };

    [self postCompletionWithSystem:systemPrompt user:userPrompt jsonMode:expectJSONMode completion:^(NSData *data, NSURLResponse *response, NSError *error) {
        handle(data, response, error, expectJSONMode);
    }];
}

@end
