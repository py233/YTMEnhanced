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
    return YTMUAnthropicDefaultsString(@"translationModel_anthropic", @"claude-haiku-4-5-20251001");
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
    NSDictionary *body = @{
        @"model": model,
        @"max_tokens": @4096,
        @"system": [YTMUPromptBuilder systemPromptForRequest:request],
        @"messages": @[
            @{@"role": @"user", @"content": [YTMUPromptBuilder userPromptForRequest:request]},
        ],
        @"temperature": @0.3,
    };
    NSData *bodyData = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];

    NSMutableURLRequest *urlRequest = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:YTMUAnthropicMessagesURL()]];
    urlRequest.HTTPMethod = @"POST";
    urlRequest.timeoutInterval = 60.0;
    urlRequest.HTTPBody = bodyData;
    [urlRequest setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [urlRequest setValue:apiKey forHTTPHeaderField:@"x-api-key"];
    [urlRequest setValue:@"2023-06-01" forHTTPHeaderField:@"anthropic-version"];

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

        NSError *jsonError = nil;
        NSDictionary *json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError] : nil;
        if (![json isKindOfClass:[NSDictionary class]]) {
            completion(nil, jsonError ?: YTMUAnthropicError(YTMUTranslationErrorParse, @"Anthropic returned invalid JSON"));
            return;
        }

        NSMutableString *text = [NSMutableString string];
        NSArray *content = json[@"content"];
        if ([content isKindOfClass:[NSArray class]]) {
            for (id item in content) {
                if (![item isKindOfClass:[NSDictionary class]]) continue;
                NSString *part = ((NSDictionary *)item)[@"text"];
                if ([part isKindOfClass:[NSString class]]) [text appendString:part];
            }
        }

        // No prefill anymore — parse the raw response. parseLinesFromJSON
        // already has a "find the outermost {...} substring" fallback
        // so it tolerates models that wrap their JSON in prose.
        NSArray *parsed = [YTMUPromptBuilder parseLinesFromJSON:text
                                                       expected:request.lines.count];
        if (!parsed) {
            YTMUTranslationLog(@"anthropic parse failed lines=%lu", (unsigned long)request.lines.count);
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

    NSDictionary *body = @{
        @"model": model,
        @"max_tokens": @1024,
        @"system": systemPrompt ?: @"",
        @"messages": messages,
        @"temperature": @0.2,
    };

    NSMutableURLRequest *urlRequest = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:YTMUAnthropicMessagesURL()]];
    urlRequest.HTTPMethod = @"POST";
    urlRequest.timeoutInterval = 45.0;
    urlRequest.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    [urlRequest setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [urlRequest setValue:apiKey forHTTPHeaderField:@"x-api-key"];
    [urlRequest setValue:@"2023-06-01" forHTTPHeaderField:@"anthropic-version"];

    [[[NSURLSession sharedSession] dataTaskWithRequest:urlRequest completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) { completion(nil, error); return; }
        NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]] ? [(NSHTTPURLResponse *)response statusCode] : 0;
        if (status < 200 || status >= 300) {
            NSString *bodyText = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"";
            completion(nil, YTMUAnthropicError(YTMUTranslationErrorHTTPStatus, [NSString stringWithFormat:@"Anthropic %ld: %@", (long)status, [bodyText substringToIndex:MIN((NSUInteger)200, bodyText.length)] ?: @""]));
            return;
        }
        NSDictionary *json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if (![json isKindOfClass:[NSDictionary class]]) {
            completion(nil, YTMUAnthropicError(YTMUTranslationErrorParse, @"Anthropic returned invalid JSON"));
            return;
        }
        NSMutableString *text = [NSMutableString string];
        NSArray *content = json[@"content"];
        if ([content isKindOfClass:[NSArray class]]) {
            for (id item in content) {
                if (![item isKindOfClass:[NSDictionary class]]) continue;
                NSString *part = ((NSDictionary *)item)[@"text"];
                if ([part isKindOfClass:[NSString class]]) [text appendString:part];
            }
        }
        if (text.length == 0) {
            completion(nil, YTMUAnthropicError(YTMUTranslationErrorEmptyResponse, @"Anthropic returned empty completion"));
            return;
        }
        completion(text, nil);
    }] resume];
}

@end
