#import "YTMUAnthropicProvider.h"
#import "../YTMUPromptBuilder.h"
#import "../YTMULLMTextUtils.h"
#import "../../Utils/YTMUSettings.h"

// Construct the messages endpoint URL from the user-configured base.
// Empty / missing → official api.anthropic.com. We accept whatever
// shape the user pastes (host root, host with /v1, full /v1/messages
// path) so a custom proxy like https://anthropic.my-gateway.com or
// https://my-gateway/anthropic/v1 both work without surprise.
static NSString *YTMUAnthropicMessagesURL(void) {
    NSString *raw = YTMUSettingsString(@"translationBaseUrl_anthropic",
                                                @"https://api.anthropic.com");
    NSString *trimmed = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    while ([trimmed hasSuffix:@"/"]) trimmed = [trimmed substringToIndex:trimmed.length - 1];
    if (!trimmed.length) trimmed = @"https://api.anthropic.com";
    if ([trimmed hasSuffix:@"/v1/messages"]) return trimmed;
    if ([trimmed hasSuffix:@"/messages"]) return trimmed;
    if ([trimmed hasSuffix:@"/v1"]) return [trimmed stringByAppendingString:@"/messages"];
    return [trimmed stringByAppendingString:@"/v1/messages"];
}

static NSError *YTMUAnthropicError(YTMUTranslationErrorCode code, NSString *message) {
    return YTMUTranslationMakeError(code, message ?: @"Anthropic translation failed");
}

// Parse Anthropic's Server-Sent Events response and accumulate the
// model's text output. With `"stream": true` the Messages endpoint sends
// a sequence of JSON events:
//
//   event: content_block_delta
//   data: {"type":"content_block_delta","index":0,
//          "delta":{"type":"text_delta","text":"Hello"}}
//
// Every text_delta is concatenated. message_start / message_stop / usage
// events are ignored; message_delta is read for the stop reason, so an
// answer cut off at max_tokens (or refused) is reported as such instead
// of as unparseable JSON. `outError` is also set for an explicit
// `event: error` payload, so the caller can surface it the same way a
// non-2xx HTTP status is surfaced.
static NSString *YTMUAnthropicAccumulateSSE(NSData *data, NSError **outError) {
    NSMutableString *accumulated = [NSMutableString string];
    __block NSError *error = nil;
    YTMUSSEEnumerateJSONEvents(data, ^(NSDictionary *json) {
        // Every field below comes off the wire (possibly via a user-configured
        // proxy), so JSON null / wrong-typed values are real inputs. NSNull
        // does not respond to isEqualToString: / length — type-check before
        // touching anything.
        id typeValue = json[@"type"];
        NSString *type = [typeValue isKindOfClass:[NSString class]] ? typeValue : @"";
        if ([type isEqualToString:@"content_block_delta"]) {
            NSDictionary *delta = json[@"delta"];
            if ([delta isKindOfClass:[NSDictionary class]]) {
                id deltaTypeValue = delta[@"type"];
                NSString *deltaType = [deltaTypeValue isKindOfClass:[NSString class]] ? deltaTypeValue : @"";
                NSString *text = delta[@"text"];
                if ([deltaType isEqualToString:@"text_delta"] && [text isKindOfClass:[NSString class]]) {
                    [accumulated appendString:text];
                }
            }
        } else if ([type isEqualToString:@"message_delta"]) {
            // {"type":"message_delta","delta":{"stop_reason":"end_turn"|"max_tokens"|"refusal"},…}
            NSDictionary *delta = json[@"delta"];
            id stopValue = [delta isKindOfClass:[NSDictionary class]] ? delta[@"stop_reason"] : nil;
            NSString *stop = [stopValue isKindOfClass:[NSString class]] ? stopValue : @"";
            if (error) return;
            if ([stop isEqualToString:@"max_tokens"]) {
                error = YTMUAnthropicError(YTMUTranslationErrorTruncated, @"Claude stopped at its output token limit before finishing");
            } else if ([stop isEqualToString:@"refusal"]) {
                error = YTMUAnthropicError(YTMUTranslationErrorContentBlocked, @"Claude declined to answer this request");
            }
        } else if ([type isEqualToString:@"error"]) {
            NSDictionary *err = json[@"error"];
            // `?:` is not enough here: JSON null arrives as NSNull, which is
            // non-nil, and an NSNull inside NSError's userInfo surfaces as a
            // non-string localizedDescription downstream.
            id rawMessage = [err isKindOfClass:[NSDictionary class]] ? err[@"message"] : nil;
            NSString *msg = ([rawMessage isKindOfClass:[NSString class]] && [rawMessage length]) ? rawMessage : @"Anthropic stream error";
            error = YTMUAnthropicError(YTMUTranslationErrorHTTPStatus, msg);
        }
    });
    if (outError) *outError = error;
    return [accumulated copy];
}

@implementation YTMUAnthropicProvider

- (NSString *)providerName {
    return YTMUTranslationProviderAnthropic;
}

- (NSString *)modelIdentifier {
    return YTMUSettingsString(@"translationModel_anthropic", YTMUTranslationDefaultModelForProvider(YTMUTranslationProviderAnthropic));
}

// The one request path. Newer Claude models reject the assistant-prefill
// trick that used to seed `{` (HTTP 400 "This model does not support
// assistant message prefill") and `temperature` (HTTP 400 "temperature is
// deprecated for this model"), so neither is sent: the system prompt's
// "JSON only" rule plus the parsers' substring fallbacks carry the format.
// `max_tokens` is a ceiling, not a target — billing is per generated
// token; 8192 covers whole-song translations (~3k tokens worst observed)
// and bounds a runaway loop. Streaming keeps NSURLSession's per-chunk
// timeout reset alive through long generations (the old 60 s
// non-streaming budget was cut close on long songs).
- (void)sendSystem:(NSString *)system
              user:(NSString *)user
        completion:(void (^)(NSString *_Nullable text, NSError *_Nullable error))completion {
    NSString *apiKey = YTMUSettingsString(@"translationApiKey_anthropic", @"");
    NSDictionary *body = @{
        @"model": [self modelIdentifier],
        @"max_tokens": @8192,
        @"system": system ?: @"",
        @"messages": @[@{@"role": @"user", @"content": user ?: @""}],
        @"stream": @YES,
    };
    NSDictionary *headers = @{
        @"x-api-key": apiKey,
        @"anthropic-version": @"2023-06-01",
        @"Accept": @"text/event-stream",
    };
    YTMULLMPostJSON(YTMUAnthropicMessagesURL(), headers, body, 120.0, ^(NSData *data, NSInteger status, NSError *error) {
        if (error) {
            completion(nil, error);
            return;
        }
        if (status < 200 || status >= 300) {
            YTMUTranslationLog(@"anthropic failed status=%ld", (long)status);
            completion(nil, YTMUTranslationHTTPError(@"Anthropic API", status, data, 300));
            return;
        }
        NSError *streamError = nil;
        NSString *text = YTMUAnthropicAccumulateSSE(data, &streamError);
        if (streamError) {
            YTMUTranslationLog(@"anthropic stream error: %@", streamError.localizedDescription);
            completion(nil, streamError);
            return;
        }
        completion(text ?: @"", nil);
    });
}

- (void)translateRequest:(YTMUTranslationRequest *)request
              completion:(void (^)(NSArray<NSString *> * _Nullable, NSError * _Nullable))completion {
    NSString *apiKey = YTMUSettingsString(@"translationApiKey_anthropic", @"");
    NSString *model = [self modelIdentifier];
    if (!apiKey.length) {
        YTMUTranslationLog(@"anthropic skipped: missing API key model=%@", model.length ? model : @"<empty>");
        completion(nil, YTMUAnthropicError(YTMUTranslationErrorMissingAPIKey, @"Anthropic API key is empty"));
        return;
    }
    YTMUTranslationLog(@"anthropic start model=%@ lines=%lu", model, (unsigned long)request.lines.count);
    NSUInteger expected = request.lines.count;

    [self sendSystem:[YTMUPromptBuilder systemPromptForRequest:request]
                user:[YTMUPromptBuilder userPromptForRequest:request]
          completion:^(NSString *text, NSError *error) {
        if (error) {
            completion(nil, error);
            return;
        }
        // parseLinesFromJSON tolerates markdown fences and prefatory prose.
        NSArray *parsed = [YTMUPromptBuilder parseLinesFromJSON:text expected:expected];
        if (!parsed) {
            NSUInteger headLen = MIN((NSUInteger)80, text.length);
            NSString *head = headLen ? [text substringToIndex:headLen] : @"";
            NSString *tail = text.length > 80 ? [text substringFromIndex:text.length - 80] : @"";
            YTMUTranslationLog(@"anthropic parse failed lines=%lu textLen=%lu head=%@ tail=%@",
                               (unsigned long)expected, (unsigned long)text.length, head, tail);
            completion(nil, YTMUAnthropicError(YTMUTranslationErrorParse, @"Could not parse JSON from Anthropic response"));
            return;
        }
        YTMUTranslationLog(@"anthropic success translatedLines=%lu", (unsigned long)parsed.count);
        completion(parsed, nil);
    }];
}

#pragma mark - YTMULLMCompletionProvider

- (void)completeWithSystemPrompt:(NSString *)systemPrompt
                      userPrompt:(NSString *)userPrompt
                  expectJSONMode:(BOOL)expectJSONMode
                      completion:(void(^)(NSString *_Nullable text, NSError *_Nullable error))completion {
    NSString *apiKey = YTMUSettingsString(@"translationApiKey_anthropic", @"");
    if (!apiKey.length) {
        completion(nil, YTMUAnthropicError(YTMUTranslationErrorMissingAPIKey, @"Anthropic API key is empty"));
        return;
    }
    // Callers parse the JSON themselves; `expectJSONMode` has no wire
    // equivalent on this API.
    [self sendSystem:systemPrompt user:userPrompt completion:^(NSString *text, NSError *error) {
        if (error) {
            completion(nil, error);
            return;
        }
        if (!text.length) {
            completion(nil, YTMUAnthropicError(YTMUTranslationErrorEmptyResponse, @"Anthropic returned empty completion"));
            return;
        }
        completion(text, nil);
    }];
}

@end
