#import "YTMUGoogleTranslateProvider.h"
#import "../YTMUPromptBuilder.h"

static const NSUInteger YTMUGoogleMaxChunkLines = 40;
static const NSUInteger YTMUGoogleMaxChunkChars = 4500;

static NSError *YTMUGoogleError(YTMUTranslationErrorCode code, NSString *message) {
    return [NSError errorWithDomain:YTMUTranslationErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: message ?: @"Google Translate failed"}];
}

static NSString *YTMUGoogleFormEncode(NSString *value) {
    static NSCharacterSet *allowed;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSMutableCharacterSet *set = [[NSCharacterSet URLQueryAllowedCharacterSet] mutableCopy];
        [set removeCharactersInString:@"!*'();:@&=+$,/?%#[]"];
        allowed = [set copy];
    });

    NSString *encoded = [value stringByAddingPercentEncodingWithAllowedCharacters:allowed] ?: @"";
    return [encoded stringByReplacingOccurrencesOfString:@"%20" withString:@"+"];
}

static NSString *YTMUGoogleTargetLanguage(NSString *language) {
    NSString *lower = language.lowercaseString;
    if ([lower isEqualToString:@"fil"]) return @"tl";
    if ([lower isEqualToString:@"zh-hans"]) return @"zh-CN";
    if ([lower isEqualToString:@"zh-hant"]) return @"zh-TW";
    if ([lower isEqualToString:@"pt-pt"]) return @"pt";
    return language.length ? language : @"en";
}

static NSString *YTMUGoogleMarker(NSUInteger index) {
    return [NSString stringWithFormat:@"<<<YTMD_LYRICS_LINE_%04lu>>>", (unsigned long)index];
}

static NSString *YTMUGoogleTranslatedTextFromJSON(id json) {
    NSMutableString *text = [NSMutableString string];

    if ([json isKindOfClass:[NSDictionary class]]) {
        NSArray *sentences = ((NSDictionary *)json)[@"sentences"];
        if ([sentences isKindOfClass:[NSArray class]]) {
            for (id sentence in sentences) {
                if (![sentence isKindOfClass:[NSDictionary class]]) continue;
                NSString *part = ((NSDictionary *)sentence)[@"trans"];
                if ([part isKindOfClass:[NSString class]]) [text appendString:part];
            }
        }
        return text;
    }

    if ([json isKindOfClass:[NSArray class]] && [(NSArray *)json count] > 0) {
        id sentences = ((NSArray *)json)[0];
        if ([sentences isKindOfClass:[NSArray class]]) {
            for (id sentence in (NSArray *)sentences) {
                if (![sentence isKindOfClass:[NSArray class]] || [(NSArray *)sentence count] == 0) continue;
                NSString *part = ((NSArray *)sentence)[0];
                if ([part isKindOfClass:[NSString class]]) [text appendString:part];
            }
        }
    }

    return text;
}

@implementation YTMUGoogleTranslateProvider

- (NSString *)providerName {
    return YTMUTranslationProviderGoogle;
}

- (NSString *)modelIdentifier {
    return @"google-translate:translate.google.com";
}

- (NSArray<NSDictionary *> *)translatableLines:(NSArray<NSString *> *)lines {
    NSMutableArray *indexed = [NSMutableArray array];
    [lines enumerateObjectsUsingBlock:^(NSString *line, NSUInteger idx, BOOL *stop) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (trimmed.length && ![YTMUPromptBuilder isSkippableLine:line]) {
            [indexed addObject:@{@"index": @(idx), @"text": line}];
        }
    }];
    return indexed;
}

- (NSArray<NSString *> *)mergeSourceLines:(NSArray<NSString *> *)sourceLines
                                  indexed:(NSArray<NSDictionary *> *)indexed
                               translated:(NSArray<NSString *> *)translated {
    NSMutableArray *output = [NSMutableArray arrayWithCapacity:sourceLines.count];
    for (NSString *line in sourceLines) {
        [output addObject:[YTMUPromptBuilder isSkippableLine:line] ? line : @""];
    }

    [indexed enumerateObjectsUsingBlock:^(NSDictionary *item, NSUInteger idx, BOOL *stop) {
        NSUInteger sourceIndex = [item[@"index"] unsignedIntegerValue];
        if (sourceIndex < output.count) {
            output[sourceIndex] = idx < translated.count ? translated[idx] : @"";
        }
    }];
    return output;
}

- (NSArray<NSArray<NSDictionary *> *> *)chunksForIndexedLines:(NSArray<NSDictionary *> *)indexed {
    NSMutableArray *chunks = [NSMutableArray array];
    NSMutableArray *chunk = [NSMutableArray array];
    NSUInteger chars = 0;

    for (NSDictionary *line in indexed) {
        NSString *text = line[@"text"] ?: @"";
        NSUInteger markerLength = chunk.count == 0 ? 0 : YTMUGoogleMarker(chunk.count).length;
        NSUInteger nextChars = text.length + markerLength + 2;
        if (chunk.count > 0 &&
            (chunk.count >= YTMUGoogleMaxChunkLines || chars + nextChars > YTMUGoogleMaxChunkChars)) {
            [chunks addObject:[chunk copy]];
            [chunk removeAllObjects];
            chars = 0;
        }

        [chunk addObject:line];
        chars += nextChars;
    }

    if (chunk.count) [chunks addObject:[chunk copy]];
    return chunks;
}

- (NSArray<NSString *> *)splitTranslatedText:(NSString *)text expected:(NSUInteger)expected {
    NSArray *raw = [text componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    NSMutableArray *lines = [NSMutableArray arrayWithCapacity:raw.count];
    for (NSString *line in raw) {
        [lines addObject:[line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]];
    }
    return lines.count == expected ? lines : nil;
}

- (NSArray<NSString *> *)splitByMarkers:(NSString *)text expected:(NSUInteger)expected {
    if (expected == 0) return @[];

    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"<{2,}\\s*YTMD\\s*[_-]\\s*LYRICS\\s*[_-]\\s*LINE\\s*[_-]\\s*(\\d{4})\\s*>{2,}"
                                                                           options:NSRegularExpressionCaseInsensitive
                                                                             error:nil];
    NSArray<NSTextCheckingResult *> *matches = [regex matchesInString:text options:0 range:NSMakeRange(0, text.length)];
    if (matches.count != expected - 1) return nil;

    NSMutableArray *output = [NSMutableArray arrayWithCapacity:expected];
    NSUInteger cursor = 0;
    for (NSTextCheckingResult *match in matches) {
        if (match.range.location < cursor) return nil;
        NSString *part = [text substringWithRange:NSMakeRange(cursor, match.range.location - cursor)];
        [output addObject:[part stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]];
        cursor = NSMaxRange(match.range);
    }

    NSString *tail = [text substringFromIndex:cursor];
    [output addObject:[tail stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]];
    return output.count == expected ? output : nil;
}

- (NSArray<NSString *> *)splitByHTMLBreaks:(NSString *)text expected:(NSUInteger)expected {
    NSRegularExpression *escaped = [NSRegularExpression regularExpressionWithPattern:@"&lt;\\s*br\\s*/?\\s*&gt;"
                                                                            options:NSRegularExpressionCaseInsensitive
                                                                              error:nil];
    NSString *normalized = [escaped stringByReplacingMatchesInString:text
                                                             options:0
                                                               range:NSMakeRange(0, text.length)
                                                        withTemplate:@"<br>"];
    NSRegularExpression *br = [NSRegularExpression regularExpressionWithPattern:@"<\\s*br\\s*/?\\s*>"
                                                                        options:NSRegularExpressionCaseInsensitive
                                                                          error:nil];
    normalized = [br stringByReplacingMatchesInString:normalized
                                              options:0
                                                range:NSMakeRange(0, normalized.length)
                                         withTemplate:@"\n"];
    return [self splitTranslatedText:normalized expected:expected];
}

- (void)translateText:(NSString *)text
               target:(NSString *)target
           completion:(void(^)(NSString *translatedText, NSError *error))completion {
    NSURL *url = [NSURL URLWithString:@"https://translate.google.com/translate_a/single?client=at&dt=t&dt=rm&dj=1"];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    request.timeoutInterval = 20.0;
    [request setValue:@"application/x-www-form-urlencoded;charset=utf-8" forHTTPHeaderField:@"Content-Type"];

    NSString *body = [NSString stringWithFormat:@"sl=auto&tl=%@&q=%@",
                      YTMUGoogleFormEncode(target),
                      YTMUGoogleFormEncode(text ?: @"")];
    request.HTTPBody = [body dataUsingEncoding:NSUTF8StringEncoding];

    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            completion(nil, error);
            return;
        }

        NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]] ? [(NSHTTPURLResponse *)response statusCode] : 0;
        if ([response isKindOfClass:[NSHTTPURLResponse class]] && (status < 200 || status >= 300)) {
            completion(nil, YTMUGoogleError(YTMUTranslationErrorHTTPStatus, [NSString stringWithFormat:@"Google Translate HTTP %ld", (long)status]));
            return;
        }

        NSError *jsonError = nil;
        id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError] : nil;
        if (!json) {
            completion(nil, jsonError ?: YTMUGoogleError(YTMUTranslationErrorParse, @"Google Translate returned invalid JSON"));
            return;
        }

        NSString *translated = YTMUGoogleTranslatedTextFromJSON(json);
        if (!translated.length && text.length) {
            completion(nil, YTMUGoogleError(YTMUTranslationErrorEmptyResponse, @"Google Translate returned an empty response"));
            return;
        }
        completion(translated ?: @"", nil);
    }] resume];
}

- (void)translateChunk:(NSArray<NSDictionary *> *)chunk
                target:(NSString *)target
            completion:(void(^)(NSArray<NSString *> *lines, NSError *error))completion {
    if (chunk.count == 0) {
        completion(@[], nil);
        return;
    }

    if (chunk.count == 1) {
        [self translateText:chunk.firstObject[@"text"] target:target completion:^(NSString *translatedText, NSError *error) {
            completion(error ? nil : @[translatedText ?: @""], error);
        }];
        return;
    }

    NSMutableArray *markedLines = [NSMutableArray arrayWithCapacity:chunk.count];
    [chunk enumerateObjectsUsingBlock:^(NSDictionary *line, NSUInteger idx, BOOL *stop) {
        NSString *text = line[@"text"] ?: @"";
        [markedLines addObject:idx == 0 ? text : [NSString stringWithFormat:@"%@\n%@", YTMUGoogleMarker(idx), text]];
    }];

    NSString *marked = [markedLines componentsJoinedByString:@"\n"];
    [self translateText:marked target:target completion:^(NSString *markedText, NSError *markedError) {
        if (!markedError) {
            NSArray *split = [self splitByMarkers:markedText expected:chunk.count];
            if (split) {
                completion(split, nil);
                return;
            }
        }

        NSMutableArray *plainLines = [NSMutableArray arrayWithCapacity:chunk.count];
        for (NSDictionary *line in chunk) {
            [plainLines addObject:line[@"text"] ?: @""];
        }

        NSString *htmlJoined = [plainLines componentsJoinedByString:@"<br>"];
        [self translateText:htmlJoined target:target completion:^(NSString *htmlText, NSError *htmlError) {
            if (htmlError) {
                completion(nil, markedError ?: htmlError);
                return;
            }

            NSArray *htmlLines = [self splitByHTMLBreaks:htmlText expected:chunk.count];
            if (htmlLines) {
                completion(htmlLines, nil);
                return;
            }

            NSArray *newlineLines = [self splitTranslatedText:htmlText expected:chunk.count];
            if (newlineLines) {
                completion(newlineLines, nil);
                return;
            }

            completion(nil, YTMUGoogleError(YTMUTranslationErrorLineCount, @"Google Translate did not preserve lyric line boundaries"));
        }];
    }];
}

- (void)translateChunks:(NSArray<NSArray<NSDictionary *> *> *)chunks
                 target:(NSString *)target
                  index:(NSUInteger)index
                results:(NSMutableArray<NSString *> *)results
             completion:(void(^)(NSArray<NSString *> *lines, NSError *error))completion {
    if (index >= chunks.count) {
        completion([results copy], nil);
        return;
    }

    [self translateChunk:chunks[index] target:target completion:^(NSArray<NSString *> *lines, NSError *error) {
        if (error) {
            completion(nil, error);
            return;
        }

        [results addObjectsFromArray:lines ?: @[]];
        [self translateChunks:chunks target:target index:index + 1 results:results completion:completion];
    }];
}

- (void)translateRequest:(YTMUTranslationRequest *)request
              completion:(void (^)(NSArray<NSString *> * _Nullable, NSError * _Nullable))completion {
    NSString *target = YTMUGoogleTargetLanguage(request.targetLanguageCode);
    NSArray *indexed = [self translatableLines:request.lines];
    if (indexed.count == 0) {
        completion([self mergeSourceLines:request.lines indexed:@[] translated:@[]], nil);
        return;
    }

    NSArray *chunks = [self chunksForIndexedLines:indexed];
    YTMUTranslationLog(@"google translate start target=%@ translatableLines=%lu chunks=%lu",
                       target,
                       (unsigned long)indexed.count,
                       (unsigned long)chunks.count);
    [self translateChunks:chunks target:target index:0 results:[NSMutableArray array] completion:^(NSArray<NSString *> *lines, NSError *error) {
        if (error) {
            YTMUTranslationLog(@"google translate failed error=%@", error.localizedDescription ?: @"<unknown>");
            completion(nil, error);
            return;
        }
        YTMUTranslationLog(@"google translate success translatedLines=%lu", (unsigned long)lines.count);
        completion([self mergeSourceLines:request.lines indexed:indexed translated:lines], nil);
    }];
}

@end
