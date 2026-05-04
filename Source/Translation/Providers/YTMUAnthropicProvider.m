#import "YTMUAnthropicProvider.h"
#import "../YTMUPromptBuilder.h"

static NSString *YTMUAnthropicDefaultsString(NSString *key, NSString *fallback) {
    NSDictionary *dict = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"YTMUltimate"] ?: @{};
    id value = dict[key];
    if ([value isKindOfClass:[NSString class]] && [(NSString *)value length]) return value;
    return fallback ?: @"";
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

    NSDictionary *body = @{
        @"model": model,
        @"max_tokens": @4096,
        @"system": [YTMUPromptBuilder systemPromptForRequest:request],
        @"messages": @[
            @{@"role": @"user", @"content": [YTMUPromptBuilder userPromptForRequest:request]},
            @{@"role": @"assistant", @"content": @"{"},
        ],
        @"temperature": @0.3,
    };
    NSData *bodyData = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];

    NSMutableURLRequest *urlRequest = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://api.anthropic.com/v1/messages"]];
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

        NSArray *parsed = [YTMUPromptBuilder parseLinesFromJSON:[@"{" stringByAppendingString:(text ?: @"")]
                                                       expected:request.lines.count];
        if (!parsed) {
            parsed = [YTMUPromptBuilder parseLinesFromJSON:text expected:request.lines.count];
        }
        if (!parsed) {
            YTMUTranslationLog(@"anthropic parse failed lines=%lu", (unsigned long)request.lines.count);
            completion(nil, YTMUAnthropicError(YTMUTranslationErrorParse, @"Could not parse JSON from Anthropic response"));
            return;
        }

        YTMUTranslationLog(@"anthropic success translatedLines=%lu", (unsigned long)parsed.count);
        completion(parsed, nil);
    }] resume];
}

@end
