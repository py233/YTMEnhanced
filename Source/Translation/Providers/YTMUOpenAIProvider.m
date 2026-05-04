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

static NSString *YTMUOpenAIChatCompletionsURL(NSString *baseURL) {
    NSString *trimmed = [baseURL stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    while ([trimmed hasSuffix:@"/"]) {
        trimmed = [trimmed substringToIndex:trimmed.length - 1];
    }
    if (!trimmed.length) trimmed = @"https://api.openai.com/v1";
    if ([[trimmed lowercaseString] hasSuffix:@"/chat/completions"]) return trimmed;
    return [trimmed stringByAppendingString:@"/chat/completions"];
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
        @"messages": @[
            @{@"role": @"system", @"content": [YTMUPromptBuilder systemPromptForRequest:request]},
            @{@"role": @"user", @"content": [YTMUPromptBuilder userPromptForRequest:request]},
        ],
        @"temperature": @0.3,
    } mutableCopy];

    if (includeJSONMode) {
        body[@"response_format"] = @{@"type": @"json_object"};
    }
    return body;
}

- (void)postRequest:(YTMUTranslationRequest *)request
    includeJSONMode:(BOOL)includeJSONMode
         completion:(void(^)(NSData *data, NSURLResponse *response, NSError *error))completion {
    NSString *baseURL = YTMUOpenAIDefaultsString(@"translationBaseUrl", @"https://api.openai.com/v1");
    NSString *apiKey = YTMUOpenAIDefaultsString(@"translationApiKey_openai-compatible", @"");

    NSMutableURLRequest *urlRequest = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:YTMUOpenAIChatCompletionsURL(baseURL)]];
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
    NSRange range = [body rangeOfString:@"response_format|json_object|json"
                                options:NSRegularExpressionSearch | NSCaseInsensitiveSearch];
    return range.location != NSNotFound;
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
            [self postRequest:request includeJSONMode:NO completion:^(NSData *retryData, NSURLResponse *retryResponse, NSError *retryError) {
                [self handleData:retryData response:retryResponse error:retryError request:request canRetryNoJSON:NO completion:completion];
            }];
            return;
        }

        NSString *message = [NSString stringWithFormat:@"OpenAI-compatible API %ld: %@", (long)status, [bodyText substringToIndex:MIN((NSUInteger)300, bodyText.length)] ?: @""];
        completion(nil, YTMUOpenAIError(YTMUTranslationErrorHTTPStatus, message));
        return;
    }

    NSError *jsonError = nil;
    NSDictionary *json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError] : nil;
    if (![json isKindOfClass:[NSDictionary class]]) {
        completion(nil, jsonError ?: YTMUOpenAIError(YTMUTranslationErrorParse, @"OpenAI-compatible endpoint returned invalid JSON"));
        return;
    }

    NSArray *choices = json[@"choices"];
    NSDictionary *choice = [choices isKindOfClass:[NSArray class]] && choices.count ? choices.firstObject : nil;
    NSDictionary *message = [choice isKindOfClass:[NSDictionary class]] ? choice[@"message"] : nil;
    NSString *content = [message isKindOfClass:[NSDictionary class]] ? message[@"content"] : nil;
    NSArray *parsed = [YTMUPromptBuilder parseLinesFromJSON:content ?: @"" expected:request.lines.count];
    if (!parsed) {
        completion(nil, YTMUOpenAIError(YTMUTranslationErrorParse, @"Could not parse JSON from OpenAI-compatible response"));
        return;
    }
    completion(parsed, nil);
}

- (void)translateRequest:(YTMUTranslationRequest *)request
              completion:(void (^)(NSArray<NSString *> * _Nullable, NSError * _Nullable))completion {
    [self postRequest:request includeJSONMode:YES completion:^(NSData *data, NSURLResponse *response, NSError *error) {
        [self handleData:data response:response error:error request:request canRetryNoJSON:YES completion:completion];
    }];
}

@end
