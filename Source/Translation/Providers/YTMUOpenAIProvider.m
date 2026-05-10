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
    return YTMUOpenAIDefaultsString(@"translationModel_openai-compatible", @"gpt-4o-mini");
}

- (NSDictionary *)requestBodyForRequest:(YTMUTranslationRequest *)request includeJSONMode:(BOOL)includeJSONMode {
    NSMutableDictionary *body = [@{
        @"model": [self modelIdentifier],
        @"instructions": [YTMUPromptBuilder systemPromptForRequest:request],
        @"input": [YTMUPromptBuilder userPromptForRequest:request],
    } mutableCopy];

    if (includeJSONMode) {
        body[@"text"] = @{@"format": @{@"type": @"json_object"}};
    }
    return body;
}

- (void)postRequest:(YTMUTranslationRequest *)request
    includeJSONMode:(BOOL)includeJSONMode
         completion:(void(^)(NSData *data, NSURLResponse *response, NSError *error))completion {
    NSString *baseURL = YTMUOpenAIDefaultsString(@"translationBaseUrl", @"https://api.openai.com/v1");
    NSString *apiKey = YTMUOpenAIDefaultsString(@"translationApiKey_openai-compatible", @"");

    NSMutableURLRequest *urlRequest = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:YTMUOpenAIResponsesURL(baseURL)]];
    urlRequest.HTTPMethod = @"POST";
    urlRequest.timeoutInterval = 60.0;
    urlRequest.HTTPBody = [NSJSONSerialization dataWithJSONObject:[self requestBodyForRequest:request includeJSONMode:includeJSONMode]
                                                          options:0
                                                            error:nil];
    [urlRequest setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
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

- (NSString *)responseTextFromJSON:(NSDictionary *)json {
    NSString *outputText = [json[@"output_text"] isKindOfClass:[NSString class]] ? json[@"output_text"] : @"";
    if (outputText.length) return outputText;

    NSArray *output = [json[@"output"] isKindOfClass:[NSArray class]] ? json[@"output"] : @[];
    NSMutableString *combined = [NSMutableString string];
    for (id item in output) {
        NSDictionary *itemDict = [item isKindOfClass:[NSDictionary class]] ? item : nil;
        NSArray *content = [itemDict[@"content"] isKindOfClass:[NSArray class]] ? itemDict[@"content"] : @[];
        for (id part in content) {
            NSDictionary *partDict = [part isKindOfClass:[NSDictionary class]] ? part : nil;
            NSString *text = [partDict[@"text"] isKindOfClass:[NSString class]] ? partDict[@"text"] : @"";
            if (!text.length) text = [partDict[@"output_text"] isKindOfClass:[NSString class]] ? partDict[@"output_text"] : @"";
            if (text.length) [combined appendString:text];
        }
    }
    return combined;
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

    NSError *jsonError = nil;
    NSDictionary *json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError] : nil;
    if (![json isKindOfClass:[NSDictionary class]]) {
        completion(nil, jsonError ?: YTMUOpenAIError(YTMUTranslationErrorParse, @"OpenAI-compatible endpoint returned invalid JSON"));
        return;
    }

    NSString *content = [self responseTextFromJSON:json];
    NSArray *parsed = [YTMUPromptBuilder parseLinesFromJSON:content ?: @"" expected:request.lines.count];
    if (!parsed) {
        YTMUTranslationLog(@"openai-compatible responses parse failed lines=%lu", (unsigned long)request.lines.count);
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
    NSMutableDictionary *body = [@{
        @"model": [self modelIdentifier],
        @"instructions": systemPrompt ?: @"",
        @"input": userPrompt ?: @"",
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
    urlRequest.timeoutInterval = 45.0;
    urlRequest.HTTPBody = [NSJSONSerialization dataWithJSONObject:[self completionBodyForSystem:systemPrompt user:userPrompt jsonMode:jsonMode]
                                                          options:0
                                                            error:nil];
    [urlRequest setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
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
                    NSDictionary *retryJson = retryData ? [NSJSONSerialization JSONObjectWithData:retryData options:0 error:nil] : nil;
                    NSString *text = [retryJson isKindOfClass:[NSDictionary class]] ? [weakSelf responseTextFromJSON:retryJson] : @"";
                    if (!text.length) { completion(nil, YTMUOpenAIError(YTMUTranslationErrorEmptyResponse, @"OpenAI returned empty completion")); return; }
                    completion(text, nil);
                }];
                return;
            }
            completion(nil, YTMUOpenAIError(YTMUTranslationErrorHTTPStatus, [NSString stringWithFormat:@"OpenAI %ld: %@", (long)status, [bodyText substringToIndex:MIN((NSUInteger)200, bodyText.length)] ?: @""]));
            return;
        }
        NSDictionary *json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if (![json isKindOfClass:[NSDictionary class]]) {
            completion(nil, YTMUOpenAIError(YTMUTranslationErrorParse, @"OpenAI returned invalid JSON"));
            return;
        }
        NSString *text = [weakSelf responseTextFromJSON:json];
        if (!text.length) { completion(nil, YTMUOpenAIError(YTMUTranslationErrorEmptyResponse, @"OpenAI returned empty completion")); return; }
        completion(text, nil);
    };

    [self postCompletionWithSystem:systemPrompt user:userPrompt jsonMode:expectJSONMode completion:^(NSData *data, NSURLResponse *response, NSError *error) {
        handle(data, response, error, expectJSONMode);
    }];
}

@end
