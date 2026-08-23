#import "YTMUGeminiProvider.h"
#import "../YTMUPromptBuilder.h"

static NSString *YTMUGeminiDefaultsString(NSString *key, NSString *fallback) {
    NSDictionary *dict = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"YTMUltimate"] ?: @{};
    id value = dict[key];
    if ([value isKindOfClass:[NSString class]] && [(NSString *)value length]) return value;
    return fallback ?: @"";
}

// Construct the generateContent endpoint from the user-configured
// base. Empty / missing → official generativelanguage.googleapis.com.
// We accept either a bare host (https://gemini.my-gateway.com) or one
// already pointing at the v1beta root (https://gemini.my-gateway.com/
// v1beta), and tack on /v1beta/models/<model>:generateContent?key=<k>
// from whichever stripped form we land on.
static NSString *YTMUGeminiGenerateContentURL(NSString *model, NSString *apiKey) {
    NSString *raw = YTMUGeminiDefaultsString(@"translationBaseUrl_gemini",
                                             @"https://generativelanguage.googleapis.com");
    NSString *trimmed = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    while ([trimmed hasSuffix:@"/"]) trimmed = [trimmed substringToIndex:trimmed.length - 1];
    if (!trimmed.length) trimmed = @"https://generativelanguage.googleapis.com";
    NSString *root = [trimmed hasSuffix:@"/v1beta"] ? [trimmed substringToIndex:trimmed.length - 7] : trimmed;
    NSString *encodedModel = [model stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLPathAllowedCharacterSet]] ?: model;
    NSString *encodedKey = [apiKey stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]] ?: apiKey;
    return [NSString stringWithFormat:@"%@/v1beta/models/%@:generateContent?key=%@",
            root, encodedModel, encodedKey];
}

static NSError *YTMUGeminiError(YTMUTranslationErrorCode code, NSString *message) {
    return [NSError errorWithDomain:YTMUTranslationErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: message ?: @"Gemini translation failed"}];
}

@implementation YTMUGeminiProvider

- (NSString *)providerName {
    return YTMUTranslationProviderGemini;
}

- (NSString *)modelIdentifier {
    return YTMUGeminiDefaultsString(@"translationModel_gemini", YTMUTranslationDefaultModelForProvider(YTMUTranslationProviderGemini));
}

- (void)translateRequest:(YTMUTranslationRequest *)request
              completion:(void (^)(NSArray<NSString *> * _Nullable, NSError * _Nullable))completion {
    NSString *apiKey = YTMUGeminiDefaultsString(@"translationApiKey_gemini", @"");
    NSString *model = [self modelIdentifier];
    if (!apiKey.length) {
        YTMUTranslationLog(@"gemini skipped: missing API key model=%@", model.length ? model : @"<empty>");
        completion(nil, YTMUGeminiError(YTMUTranslationErrorMissingAPIKey, @"Gemini API key is empty"));
        return;
    }
    YTMUTranslationLog(@"gemini start model=%@ lines=%lu", model, (unsigned long)request.lines.count);

    NSString *urlString = YTMUGeminiGenerateContentURL(model, apiKey);

    NSDictionary *body = @{
        @"systemInstruction": @{
            @"role": @"system",
            @"parts": @[@{@"text": [YTMUPromptBuilder systemPromptForRequest:request]}],
        },
        @"contents": @[
            @{
                @"role": @"user",
                @"parts": @[@{@"text": [YTMUPromptBuilder userPromptForRequest:request]}],
            },
        ],
        @"generationConfig": @{
            @"temperature": @0.3,
            @"responseMimeType": @"application/json",
        },
    };

    NSMutableURLRequest *urlRequest = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlString]];
    urlRequest.HTTPMethod = @"POST";
    urlRequest.timeoutInterval = 60.0;
    urlRequest.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    [urlRequest setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];

    [[[NSURLSession sharedSession] dataTaskWithRequest:urlRequest completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            completion(nil, error);
            return;
        }

        NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]] ? [(NSHTTPURLResponse *)response statusCode] : 0;
        if (status < 200 || status >= 300) {
            NSString *bodyText = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"";
            NSString *message = [NSString stringWithFormat:@"Gemini API %ld: %@", (long)status, [bodyText substringToIndex:MIN((NSUInteger)300, bodyText.length)] ?: @""];
            YTMUTranslationLog(@"gemini failed status=%ld", (long)status);
            completion(nil, YTMUGeminiError(YTMUTranslationErrorHTTPStatus, message));
            return;
        }

        NSError *jsonError = nil;
        NSDictionary *json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError] : nil;
        if (![json isKindOfClass:[NSDictionary class]]) {
            completion(nil, jsonError ?: YTMUGeminiError(YTMUTranslationErrorParse, @"Gemini returned invalid JSON"));
            return;
        }

        NSMutableString *text = [NSMutableString string];
        NSArray *candidates = json[@"candidates"];
        NSDictionary *candidate = [candidates isKindOfClass:[NSArray class]] && candidates.count ? candidates.firstObject : nil;
        NSDictionary *content = [candidate isKindOfClass:[NSDictionary class]] ? candidate[@"content"] : nil;
        NSArray *parts = [content isKindOfClass:[NSDictionary class]] ? content[@"parts"] : nil;
        if ([parts isKindOfClass:[NSArray class]]) {
            for (id part in parts) {
                if (![part isKindOfClass:[NSDictionary class]]) continue;
                NSString *partText = ((NSDictionary *)part)[@"text"];
                if ([partText isKindOfClass:[NSString class]]) [text appendString:partText];
            }
        }

        NSArray *parsed = [YTMUPromptBuilder parseLinesFromJSON:text expected:request.lines.count];
        if (!parsed) {
            YTMUTranslationLog(@"gemini parse failed lines=%lu", (unsigned long)request.lines.count);
            completion(nil, YTMUGeminiError(YTMUTranslationErrorParse, @"Could not parse JSON from Gemini response"));
            return;
        }
        YTMUTranslationLog(@"gemini success translatedLines=%lu", (unsigned long)parsed.count);
        completion(parsed, nil);
    }] resume];
}

#pragma mark - YTMULLMCompletionProvider

- (void)completeWithSystemPrompt:(NSString *)systemPrompt
                      userPrompt:(NSString *)userPrompt
                  expectJSONMode:(BOOL)expectJSONMode
                      completion:(void(^)(NSString *_Nullable text, NSError *_Nullable error))completion {
    NSString *apiKey = YTMUGeminiDefaultsString(@"translationApiKey_gemini", @"");
    NSString *model = [self modelIdentifier];
    if (!apiKey.length) {
        completion(nil, YTMUGeminiError(YTMUTranslationErrorMissingAPIKey, @"Gemini API key is empty"));
        return;
    }

    NSString *urlString = YTMUGeminiGenerateContentURL(model, apiKey);

    NSMutableDictionary *generationConfig = [@{@"temperature": @0.2} mutableCopy];
    if (expectJSONMode) generationConfig[@"responseMimeType"] = @"application/json";

    NSDictionary *body = @{
        @"systemInstruction": @{
            @"role": @"system",
            @"parts": @[@{@"text": systemPrompt ?: @""}],
        },
        @"contents": @[
            @{
                @"role": @"user",
                @"parts": @[@{@"text": userPrompt ?: @""}],
            },
        ],
        @"generationConfig": generationConfig,
    };

    NSMutableURLRequest *urlRequest = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlString]];
    urlRequest.HTTPMethod = @"POST";
    urlRequest.timeoutInterval = 45.0;
    urlRequest.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    [urlRequest setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];

    [[[NSURLSession sharedSession] dataTaskWithRequest:urlRequest completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) { completion(nil, error); return; }
        NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]] ? [(NSHTTPURLResponse *)response statusCode] : 0;
        if (status < 200 || status >= 300) {
            NSString *bodyText = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"";
            completion(nil, YTMUGeminiError(YTMUTranslationErrorHTTPStatus, [NSString stringWithFormat:@"Gemini %ld: %@", (long)status, [bodyText substringToIndex:MIN((NSUInteger)200, bodyText.length)] ?: @""]));
            return;
        }
        NSDictionary *json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if (![json isKindOfClass:[NSDictionary class]]) {
            completion(nil, YTMUGeminiError(YTMUTranslationErrorParse, @"Gemini returned invalid JSON"));
            return;
        }
        NSMutableString *text = [NSMutableString string];
        NSArray *candidates = json[@"candidates"];
        NSDictionary *candidate = [candidates isKindOfClass:[NSArray class]] && candidates.count ? candidates.firstObject : nil;
        NSDictionary *content = [candidate isKindOfClass:[NSDictionary class]] ? candidate[@"content"] : nil;
        NSArray *parts = [content isKindOfClass:[NSDictionary class]] ? content[@"parts"] : nil;
        if ([parts isKindOfClass:[NSArray class]]) {
            for (id part in parts) {
                if (![part isKindOfClass:[NSDictionary class]]) continue;
                NSString *partText = ((NSDictionary *)part)[@"text"];
                if ([partText isKindOfClass:[NSString class]]) [text appendString:partText];
            }
        }
        if (!text.length) {
            completion(nil, YTMUGeminiError(YTMUTranslationErrorEmptyResponse, @"Gemini returned empty completion"));
            return;
        }
        completion(text, nil);
    }] resume];
}

@end
