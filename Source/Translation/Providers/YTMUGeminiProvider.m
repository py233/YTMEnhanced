#import "YTMUGeminiProvider.h"
#import "../YTMUPromptBuilder.h"
#import "../YTMULLMTextUtils.h"
#import "../../Utils/YTMUSettings.h"

static NSString *const YTMUGeminiDefaultBaseURL = @"https://generativelanguage.googleapis.com";

// The streamGenerateContent endpoint from the user-configured base. Empty
// / missing → official generativelanguage.googleapis.com. We accept either
// a bare host (https://gemini.my-gateway.com) or one already pointing at
// the v1beta root. The API key travels in the x-goog-api-key header,
// never in the URL, so it cannot end up in logs, proxy access logs or
// crash reports. Streaming (`alt=sse`) keeps NSURLSession's per-chunk
// timeout reset alive through long generations, like the other two
// providers; a gateway that answers with a plain JSON body instead of
// events is still understood (see YTMUGeminiCollect).
static NSString *YTMUGeminiStreamURL(NSString *model) {
    NSString *raw = YTMUSettingsString(@"translationBaseUrl_gemini", YTMUGeminiDefaultBaseURL);
    NSString *trimmed = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    while ([trimmed hasSuffix:@"/"]) trimmed = [trimmed substringToIndex:trimmed.length - 1];
    if (!trimmed.length) trimmed = YTMUGeminiDefaultBaseURL;
    NSString *root = [trimmed hasSuffix:@"/v1beta"] ? [trimmed substringToIndex:trimmed.length - 7] : trimmed;
    NSString *encodedModel = [model stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLPathAllowedCharacterSet]] ?: model;
    return [NSString stringWithFormat:@"%@/v1beta/models/%@:streamGenerateContent?alt=sse", root, encodedModel];
}

static NSError *YTMUGeminiError(YTMUTranslationErrorCode code, NSString *message) {
    return YTMUTranslationMakeError(code, message ?: @"Gemini translation failed");
}

// Folds one generateContent response object (a whole non-streamed body,
// or one SSE chunk) into `text`, and records a refusal (prompt blocked,
// candidate stopped for SAFETY & co.) or a truncation (MAX_TOKENS) in
// `error`. Those used to surface as "could not parse JSON", which the
// translator then retried and remembered for the wrong reasons.
static void YTMUGeminiCollect(NSDictionary *json, NSMutableString *text, NSError **error) {
    NSDictionary *feedback = json[@"promptFeedback"];
    id blockReason = [feedback isKindOfClass:[NSDictionary class]] ? feedback[@"blockReason"] : nil;
    if ([blockReason isKindOfClass:[NSString class]] && [blockReason length] && error && !*error) {
        *error = YTMUGeminiError(YTMUTranslationErrorContentBlocked, [NSString stringWithFormat:@"Gemini blocked the prompt (%@)", blockReason]);
    }

    NSArray *candidates = json[@"candidates"];
    NSDictionary *candidate = [candidates isKindOfClass:[NSArray class]] && candidates.count ? candidates.firstObject : nil;
    if (![candidate isKindOfClass:[NSDictionary class]]) return;

    NSDictionary *content = candidate[@"content"];
    NSArray *parts = [content isKindOfClass:[NSDictionary class]] ? content[@"parts"] : nil;
    if ([parts isKindOfClass:[NSArray class]]) {
        for (id part in parts) {
            if (![part isKindOfClass:[NSDictionary class]]) continue;
            NSString *partText = ((NSDictionary *)part)[@"text"];
            if ([partText isKindOfClass:[NSString class]]) [text appendString:partText];
        }
    }

    id finishValue = candidate[@"finishReason"];
    NSString *finish = [finishValue isKindOfClass:[NSString class]] ? finishValue : @"";
    if (!error || *error) return;
    if ([finish isEqualToString:@"MAX_TOKENS"]) {
        *error = YTMUGeminiError(YTMUTranslationErrorTruncated, @"Gemini stopped at its output token limit before finishing");
        return;
    }
    static NSSet<NSString *> *blockedFinishReasons;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        blockedFinishReasons = [NSSet setWithArray:@[@"SAFETY", @"RECITATION", @"BLOCKLIST", @"PROHIBITED_CONTENT", @"SPII", @"IMAGE_SAFETY"]];
    });
    if ([blockedFinishReasons containsObject:finish]) {
        *error = YTMUGeminiError(YTMUTranslationErrorContentBlocked, [NSString stringWithFormat:@"Gemini refused to answer (%@)", finish]);
    }
}

// The streamed answer as one string: every SSE chunk folded in order; a
// body that is a single JSON object (a gateway ignoring alt=sse) is
// folded the same way.
static NSString *YTMUGeminiTextFromResponse(NSData *data, NSError **outError) {
    NSMutableString *text = [NSMutableString string];
    __block NSError *error = nil;
    __block NSUInteger events = 0;
    YTMUSSEEnumerateJSONEvents(data, ^(NSDictionary *json) {
        events++;
        YTMUGeminiCollect(json, text, &error);
    });
    if (!events) {
        NSDictionary *json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if (![json isKindOfClass:[NSDictionary class]]) {
            if (outError) *outError = YTMUGeminiError(YTMUTranslationErrorParse, @"Gemini returned invalid JSON");
            return nil;
        }
        YTMUGeminiCollect(json, text, &error);
    }
    if (outError) *outError = error;
    return error ? nil : [text copy];
}

@implementation YTMUGeminiProvider

- (NSString *)providerName {
    return YTMUTranslationProviderGemini;
}

- (NSString *)modelIdentifier {
    return YTMUSettingsString(@"translationModel_gemini", YTMUTranslationDefaultModelForProvider(YTMUTranslationProviderGemini));
}

- (NSDictionary *)bodyForSystem:(NSString *)system user:(NSString *)user generationConfig:(NSDictionary *)generationConfig {
    return @{
        @"systemInstruction": @{
            @"role": @"system",
            @"parts": @[@{@"text": system ?: @""}],
        },
        @"contents": @[
            @{
                @"role": @"user",
                @"parts": @[@{@"text": user ?: @""}],
            },
        ],
        @"generationConfig": generationConfig,
    };
}

- (void)postBody:(NSDictionary *)body
          apiKey:(NSString *)apiKey
           model:(NSString *)model
         timeout:(NSTimeInterval)timeout
      completion:(void (^)(NSString *_Nullable text, NSError *_Nullable error))completion {
    NSDictionary *headers = @{@"x-goog-api-key": apiKey, @"Accept": @"text/event-stream"};
    YTMULLMPostJSON(YTMUGeminiStreamURL(model), headers, body, timeout, ^(NSData *data, NSInteger status, NSError *error) {
        if (error) {
            completion(nil, error);
            return;
        }
        if (status < 200 || status >= 300) {
            YTMUTranslationLog(@"gemini failed status=%ld", (long)status);
            completion(nil, YTMUTranslationHTTPError(@"Gemini API", status, data, 300));
            return;
        }
        NSError *collectError = nil;
        NSString *text = YTMUGeminiTextFromResponse(data, &collectError);
        if (collectError) {
            YTMUTranslationLog(@"gemini refused: %@", collectError.localizedDescription);
            completion(nil, collectError);
            return;
        }
        completion(text ?: @"", nil);
    });
}

- (void)translateRequest:(YTMUTranslationRequest *)request
              completion:(void (^)(NSArray<NSString *> * _Nullable, NSError * _Nullable))completion {
    NSString *apiKey = YTMUSettingsString(@"translationApiKey_gemini", @"");
    NSString *model = [self modelIdentifier];
    if (!apiKey.length) {
        YTMUTranslationLog(@"gemini skipped: missing API key model=%@", model.length ? model : @"<empty>");
        completion(nil, YTMUGeminiError(YTMUTranslationErrorMissingAPIKey, @"Gemini API key is empty"));
        return;
    }
    YTMUTranslationLog(@"gemini start model=%@ lines=%lu", model, (unsigned long)request.lines.count);

    NSDictionary *body = [self bodyForSystem:[YTMUPromptBuilder systemPromptForRequest:request]
                                        user:[YTMUPromptBuilder userPromptForRequest:request]
                            generationConfig:@{@"temperature": @0.3, @"responseMimeType": @"application/json"}];
    NSUInteger expected = request.lines.count;
    [self postBody:body apiKey:apiKey model:model timeout:120.0 completion:^(NSString *text, NSError *error) {
        if (error) {
            completion(nil, error);
            return;
        }
        NSArray *parsed = [YTMUPromptBuilder parseLinesFromJSON:text expected:expected];
        if (!parsed) {
            YTMUTranslationLog(@"gemini parse failed lines=%lu", (unsigned long)expected);
            completion(nil, YTMUGeminiError(YTMUTranslationErrorParse, @"Could not parse JSON from Gemini response"));
            return;
        }
        YTMUTranslationLog(@"gemini success translatedLines=%lu", (unsigned long)parsed.count);
        completion(parsed, nil);
    }];
}

#pragma mark - YTMULLMCompletionProvider

- (void)completeWithSystemPrompt:(NSString *)systemPrompt
                      userPrompt:(NSString *)userPrompt
                  expectJSONMode:(BOOL)expectJSONMode
                      completion:(void(^)(NSString *_Nullable text, NSError *_Nullable error))completion {
    NSString *apiKey = YTMUSettingsString(@"translationApiKey_gemini", @"");
    NSString *model = [self modelIdentifier];
    if (!apiKey.length) {
        completion(nil, YTMUGeminiError(YTMUTranslationErrorMissingAPIKey, @"Gemini API key is empty"));
        return;
    }

    NSMutableDictionary *generationConfig = [@{@"temperature": @0.2} mutableCopy];
    if (expectJSONMode) generationConfig[@"responseMimeType"] = @"application/json";
    NSDictionary *body = [self bodyForSystem:systemPrompt user:userPrompt generationConfig:generationConfig];
    [self postBody:body apiKey:apiKey model:model timeout:60.0 completion:^(NSString *text, NSError *error) {
        if (error) {
            completion(nil, error);
            return;
        }
        if (!text.length) {
            completion(nil, YTMUGeminiError(YTMUTranslationErrorEmptyResponse, @"Gemini returned empty completion"));
            return;
        }
        completion(text, nil);
    }];
}

@end
