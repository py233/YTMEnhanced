#import "YTMUAnthropicProvider.h"
#import "../YTMUPromptBuilder.h"

static NSString *YTMUAnthropicDefaultsString(NSString *key, NSString *fallback) {
    NSDictionary *dict = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"YTMUltimate"] ?: @{};
    id value = dict[key];
    if ([value isKindOfClass:[NSString class]] && [(NSString *)value length]) return value;
    return fallback ?: @"";
}

// Construct the messages endpoint URL from the user-configured base.
// Empty / missing → official api.anthropic.com. We accept whatever
// shape the user pastes (host root, host with /v1, full /v1/messages
// path) so a custom proxy like https://anthropic.my-gateway.com or
// https://my-gateway/anthropic/v1 both work without surprise.
static NSString *YTMUAnthropicMessagesURL(void) {
    NSString *raw = YTMUAnthropicDefaultsString(@"translationBaseUrl_anthropic",
                                                @"https://api.anthropic.com");
    NSString *trimmed = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    while ([trimmed hasSuffix:@"/"]) trimmed = [trimmed substringToIndex:trimmed.length - 1];
    if (!trimmed.length) trimmed = @"https://api.anthropic.com";
    if ([trimmed hasSuffix:@"/v1/messages"]) return trimmed;
    if ([trimmed hasSuffix:@"/messages"]) return trimmed;
    if ([trimmed hasSuffix:@"/v1"]) return [trimmed stringByAppendingString:@"/messages"];
    return [trimmed stringByAppendingString:@"/v1/messages"];
}

// Parse Anthropic's Server-Sent Events response and accumulate the
// model's text output. The Messages endpoint streams a sequence of
// JSON events when `"stream": true` is set on the request body:
//
//   event: content_block_delta
//   data: {"type":"content_block_delta","index":0,
//          "delta":{"type":"text_delta","text":"Hello"}}
//
//   event: content_block_delta
//   data: {"type":"content_block_delta","index":0,
//          "delta":{"type":"text_delta","text":" world"}}
//
// We split by blank lines, extract the `data: …` payload of each
// event, and concatenate every text_delta. Non-stream-event payloads
// (message_start / message_stop / message_delta / usage) are
// silently ignored — only text_delta carries content we care about.
// `outError` is set to a synthetic API error if the stream contains
// an explicit `event: error` payload, so the caller can surface it
// the same way a non-2xx HTTP status is surfaced.
static NSString *YTMUAnthropicAccumulateSSE(NSData *data, NSError **outError) {
    if (!data.length) return @"";
    NSString *body = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!body.length) return @"";
    NSMutableString *accumulated = [NSMutableString string];
    // Events are separated by a blank line (\n\n on Anthropic).
    NSArray<NSString *> *events = [body componentsSeparatedByString:@"\n\n"];
    for (NSString *event in events) {
        NSString *dataPayload = nil;
        // An event may span multiple lines; we want the first `data: ` line.
        for (NSString *line in [event componentsSeparatedByString:@"\n"]) {
            if ([line hasPrefix:@"data: "]) {
                dataPayload = [line substringFromIndex:6];
                break;
            }
        }
        if (!dataPayload.length) continue;
        NSData *jsonData = [dataPayload dataUsingEncoding:NSUTF8StringEncoding];
        NSDictionary *json = jsonData
            ? [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:nil]
            : nil;
        if (![json isKindOfClass:[NSDictionary class]]) continue;
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
                if ([deltaType isEqualToString:@"text_delta"] &&
                    [text isKindOfClass:[NSString class]]) {
                    [accumulated appendString:text];
                }
            }
        } else if ([type isEqualToString:@"error"]) {
            NSDictionary *err = json[@"error"];
            // `?:` is not enough here: JSON null arrives as NSNull, which is
            // non-nil, and an NSNull inside NSError's userInfo surfaces as a
            // non-string localizedDescription downstream.
            id rawMessage = [err isKindOfClass:[NSDictionary class]] ? err[@"message"] : nil;
            NSString *msg = ([rawMessage isKindOfClass:[NSString class]] && [rawMessage length])
                ? rawMessage
                : @"Anthropic stream error";
            if (outError) {
                *outError = [NSError errorWithDomain:YTMUTranslationErrorDomain
                                                code:YTMUTranslationErrorHTTPStatus
                                            userInfo:@{NSLocalizedDescriptionKey: msg}];
            }
        }
    }
    return [accumulated copy];
}

static NSError *YTMUAnthropicError(YTMUTranslationErrorCode code, NSString *message) {
    return [NSError errorWithDomain:YTMUTranslationErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: message ?: @"Anthropic translation failed"}];
}

@implementation YTMUAnthropicProvider

- (NSString *)providerName {
    return YTMUTranslationProviderAnthropic;
}

- (NSString *)modelIdentifier {
    return YTMUAnthropicDefaultsString(@"translationModel_anthropic", YTMUTranslationDefaultModelForProvider(YTMUTranslationProviderAnthropic));
}

- (void)translateRequest:(YTMUTranslationRequest *)request
              completion:(void (^)(NSArray<NSString *> * _Nullable, NSError * _Nullable))completion {
    NSString *apiKey = YTMUAnthropicDefaultsString(@"translationApiKey_anthropic", @"");
    NSString *model = [self modelIdentifier];
    if (!apiKey.length) {
        YTMUTranslationLog(@"anthropic skipped: missing API key model=%@", model.length ? model : @"<empty>");
        completion(nil, YTMUAnthropicError(YTMUTranslationErrorMissingAPIKey, @"Anthropic API key is empty"));
        return;
    }
    YTMUTranslationLog(@"anthropic start model=%@ lines=%lu", model, (unsigned long)request.lines.count);

    // Newer Claude models (claude-haiku-4-5+ and others) reject the
    // assistant-prefill trick we used to seed `{` for reliable JSON
    // output, returning HTTP 400 "This model does not support
    // assistant message prefill. The conversation must end with a
    // user message." Drop the prefill entirely and trust the system
    // prompt's "JSON only" rule plus the parser's first-`{...}`
    // substring fallback in parseLinesFromJSON.
    // max_tokens = 8192: real-world bill shows worst-case ~3035
    // output tokens for long whole-song translations (Hi Ren, ~150
    // lines). 8192 gives ~170% headroom for the occasional verbose
    // model run while still bounding any pathological loop well
    // before it could double user spending. Billing is per actual
    // generated tokens, so this ceiling never inflates ordinary
    // cost — it only protects against runaway. We translate the
    // whole song in one call to preserve cross-line context
    // (refrains, callbacks, character voices) the prompt depends on.
    // `temperature` is intentionally omitted. Newer Claude models
    // reject it with HTTP 400 "temperature is deprecated for this
    // model"; omitting it uses the model default and works across
    // both old and new models. Output stays reliable because the
    // system prompt enforces JSON-only and the parser tolerates
    // surrounding prose.
    NSDictionary *body = @{
        @"model": model,
        @"max_tokens": @8192,
        @"system": [YTMUPromptBuilder systemPromptForRequest:request],
        @"messages": @[
            @{@"role": @"user", @"content": [YTMUPromptBuilder userPromptForRequest:request]},
        ],
        @"stream": @YES,
    };
    NSData *bodyData = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];

    NSMutableURLRequest *urlRequest = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:YTMUAnthropicMessagesURL()]];
    urlRequest.HTTPMethod = @"POST";
    // 120 s is plenty for streaming — NSURLSession resets the timer
    // on every chunk that arrives, so as long as the model is
    // actively emitting tokens (which streaming guarantees) the call
    // can run as long as needed without tripping the timeout. The
    // old 60 s non-streaming budget got cut close on long songs
    // (Hi Ren billed at 49–53 s per attempt).
    urlRequest.timeoutInterval = 120.0;
    urlRequest.HTTPBody = bodyData;
    [urlRequest setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [urlRequest setValue:apiKey forHTTPHeaderField:@"x-api-key"];
    [urlRequest setValue:@"2023-06-01" forHTTPHeaderField:@"anthropic-version"];
    [urlRequest setValue:@"text/event-stream" forHTTPHeaderField:@"Accept"];

    [[[NSURLSession sharedSession] dataTaskWithRequest:urlRequest completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            completion(nil, error);
            return;
        }

        NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]] ? [(NSHTTPURLResponse *)response statusCode] : 0;
        if (status < 200 || status >= 300) {
            NSString *bodyText = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"";
            NSString *message = [NSString stringWithFormat:@"Anthropic API %ld: %@", (long)status, [bodyText substringToIndex:MIN((NSUInteger)300, bodyText.length)] ?: @""];
            YTMUTranslationLog(@"anthropic failed status=%ld", (long)status);
            completion(nil, YTMUAnthropicError(YTMUTranslationErrorHTTPStatus, message));
            return;
        }

        // Parse the SSE stream. Even though we're using completionHandler
        // (so all bytes are buffered before this block fires), the
        // streaming response shape (a) lets NSURLSession's per-chunk
        // timeout reset keep the connection alive while the model
        // generates, and (b) is the same wire format Anthropic itself
        // is moving toward as the preferred surface.
        NSError *streamError = nil;
        NSString *text = YTMUAnthropicAccumulateSSE(data, &streamError);
        if (streamError) {
            YTMUTranslationLog(@"anthropic stream error: %@", streamError.localizedDescription);
            completion(nil, streamError);
            return;
        }

        // parseLinesFromJSON already has fence-stripping, prose-
        // substring, and brace-balanced extraction fallbacks so it
        // tolerates models that wrap their JSON in markdown fences
        // or prefatory commentary.
        NSArray *parsed = [YTMUPromptBuilder parseLinesFromJSON:text
                                                       expected:request.lines.count];
        if (!parsed) {
            // Surface enough of the actual response to diagnose
            // future parse failures without dumping the whole body.
            // 80 chars on each end is plenty to see fence shape /
            // truncation point.
            NSUInteger headLen = MIN((NSUInteger)80, text.length);
            NSString *head = headLen ? [text substringToIndex:headLen] : @"";
            NSString *tail = text.length > 80
                ? [text substringFromIndex:text.length - 80]
                : @"";
            YTMUTranslationLog(@"anthropic parse failed lines=%lu textLen=%lu head=%@ tail=%@",
                              (unsigned long)request.lines.count,
                              (unsigned long)text.length,
                              head,
                              tail);
            completion(nil, YTMUAnthropicError(YTMUTranslationErrorParse, @"Could not parse JSON from Anthropic response"));
            return;
        }

        YTMUTranslationLog(@"anthropic success translatedLines=%lu", (unsigned long)parsed.count);
        completion(parsed, nil);
    }] resume];
}

#pragma mark - YTMULLMCompletionProvider

- (void)completeWithSystemPrompt:(NSString *)systemPrompt
                      userPrompt:(NSString *)userPrompt
                  expectJSONMode:(BOOL)expectJSONMode
                      completion:(void(^)(NSString *_Nullable text, NSError *_Nullable error))completion {
    NSString *apiKey = YTMUAnthropicDefaultsString(@"translationApiKey_anthropic", @"");
    NSString *model = [self modelIdentifier];
    if (!apiKey.length) {
        completion(nil, YTMUAnthropicError(YTMUTranslationErrorMissingAPIKey, @"Anthropic API key is empty"));
        return;
    }

    NSMutableArray *messages = [NSMutableArray array];
    [messages addObject:@{@"role": @"user", @"content": userPrompt ?: @""}];
    // Newer Claude models reject the assistant-prefill trick with
    // HTTP 400 ("This model does not support assistant message
    // prefill. The conversation must end with a user message."), so
    // we send only the user turn. Callers expecting JSON parse the
    // raw response themselves and rely on their parsers' substring
    // extraction (parseJsonObject / parseLinesFromJSON) to tolerate
    // surrounding prose.

    // `temperature` omitted — newer Claude models reject it with
    // HTTP 400 "temperature is deprecated for this model". Default
    // temperature is fine; callers parse JSON defensively.
    NSDictionary *body = @{
        @"model": model,
        @"max_tokens": @8192,
        @"system": systemPrompt ?: @"",
        @"messages": messages,
        @"stream": @YES,
    };

    NSMutableURLRequest *urlRequest = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:YTMUAnthropicMessagesURL()]];
    urlRequest.HTTPMethod = @"POST";
    urlRequest.timeoutInterval = 120.0;
    urlRequest.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    [urlRequest setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [urlRequest setValue:apiKey forHTTPHeaderField:@"x-api-key"];
    [urlRequest setValue:@"2023-06-01" forHTTPHeaderField:@"anthropic-version"];
    [urlRequest setValue:@"text/event-stream" forHTTPHeaderField:@"Accept"];

    [[[NSURLSession sharedSession] dataTaskWithRequest:urlRequest completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) { completion(nil, error); return; }
        NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]] ? [(NSHTTPURLResponse *)response statusCode] : 0;
        if (status < 200 || status >= 300) {
            NSString *bodyText = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"";
            completion(nil, YTMUAnthropicError(YTMUTranslationErrorHTTPStatus, [NSString stringWithFormat:@"Anthropic %ld: %@", (long)status, [bodyText substringToIndex:MIN((NSUInteger)200, bodyText.length)] ?: @""]));
            return;
        }
        NSError *streamError = nil;
        NSString *text = YTMUAnthropicAccumulateSSE(data, &streamError);
        if (streamError) {
            completion(nil, streamError);
            return;
        }
        if (text.length == 0) {
            completion(nil, YTMUAnthropicError(YTMUTranslationErrorEmptyResponse, @"Anthropic returned empty completion"));
            return;
        }
        completion(text, nil);
    }] resume];
}

@end
