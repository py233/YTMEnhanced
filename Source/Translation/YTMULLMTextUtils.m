#import "YTMULLMTextUtils.h"

static NSCharacterSet *YTMULLMWhitespace(void) {
    return [NSCharacterSet whitespaceAndNewlineCharacterSet];
}

static BOOL YTMULLMIsFenceTagCharacter(unichar c) {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') ||
           c == '+' || c == '-' || c == '#' || c == '_' || c == '.';
}

NSString *YTMULLMStripMarkdownFences(NSString *text) {
    NSString *trimmed = [text ?: @"" stringByTrimmingCharactersInSet:YTMULLMWhitespace()];
    if ([trimmed hasPrefix:@"```"]) {
        // Optional language tag (json / javascript / …) right after the
        // fence, then whatever whitespace separates it from the payload.
        // Walking characters — rather than "find the first newline" —
        // handles ```{...}``` with no newline after the fence, and the tag
        // is limited to identifier characters so a payload glued to the
        // fence is not eaten as a tag.
        NSUInteger i = 3;
        while (i < trimmed.length && YTMULLMIsFenceTagCharacter([trimmed characterAtIndex:i])) i++;
        while (i < trimmed.length) {
            unichar c = [trimmed characterAtIndex:i];
            if (c != '\n' && c != '\r' && c != ' ' && c != '\t') break;
            i++;
        }
        trimmed = [trimmed substringFromIndex:i];
    }
    if ([trimmed hasSuffix:@"```"]) trimmed = [trimmed substringToIndex:trimmed.length - 3];
    return [trimmed stringByTrimmingCharactersInSet:YTMULLMWhitespace()];
}

NSString *YTMULLMBalancedObjectSubstring(NSString *text, NSUInteger openIndex) {
    NSUInteger length = text.length;
    if (openIndex >= length || [text characterAtIndex:openIndex] != '{') return nil;
    NSUInteger depth = 0;
    BOOL inString = NO;
    BOOL escape = NO;
    for (NSUInteger i = openIndex; i < length; i++) {
        unichar c = [text characterAtIndex:i];
        if (inString) {
            if (escape) { escape = NO; continue; }
            if (c == '\\') { escape = YES; continue; }
            if (c == '"') inString = NO;
            continue;
        }
        if (c == '"') { inString = YES; continue; }
        if (c == '{') {
            depth++;
        } else if (c == '}') {
            if (depth > 0) depth--;
            if (depth == 0) return [text substringWithRange:NSMakeRange(openIndex, i - openIndex + 1)];
        }
    }
    return nil;
}

static NSDictionary *YTMULLMDictionaryFromJSONString(NSString *string) {
    NSData *data = [string dataUsingEncoding:NSUTF8StringEncoding];
    id object = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    return [object isKindOfClass:[NSDictionary class]] ? object : nil;
}

NSDictionary *YTMULLMFirstJSONObject(NSString *text) {
    if (!text.length) return nil;
    NSString *clean = YTMULLMStripMarkdownFences(text);
    NSDictionary *object = YTMULLMDictionaryFromJSONString(clean);
    if (object) return object;

    NSRange open = [clean rangeOfString:@"{"];
    if (open.location == NSNotFound) return nil;
    // Greedy first { … last }: handles "Here's the JSON:" + trailing notes.
    NSRange close = [clean rangeOfString:@"}" options:NSBackwardsSearch];
    if (close.location != NSNotFound && close.location > open.location) {
        object = YTMULLMDictionaryFromJSONString([clean substringWithRange:NSMakeRange(open.location, close.location - open.location + 1)]);
        if (object) return object;
    }
    // Brace-balanced: trailing prose that itself contains a brace, or
    // fence remnants after the real closing brace.
    NSString *balanced = YTMULLMBalancedObjectSubstring(clean, open.location);
    return balanced ? YTMULLMDictionaryFromJSONString(balanced) : nil;
}

void YTMULLMPostJSON(NSString *url,
                     NSDictionary<NSString *, NSString *> *headers,
                     id body,
                     NSTimeInterval timeout,
                     void (^completion)(NSData *data, NSInteger status, NSError *error)) {
    NSURL *requestURL = [NSURL URLWithString:url ?: @""];
    if (!requestURL) {
        completion(nil, 0, [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorBadURL
                                            userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Invalid URL: %@", url ?: @""]}]);
        return;
    }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:requestURL];
    request.HTTPMethod = @"POST";
    request.timeoutInterval = timeout;
    request.HTTPBody = body ? [NSJSONSerialization dataWithJSONObject:body options:0 error:nil] : nil;
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [headers enumerateKeysAndObjectsUsingBlock:^(NSString *field, NSString *value, BOOL *stop) {
        if (value.length) [request setValue:value forHTTPHeaderField:field];
    }];
    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]] ? [(NSHTTPURLResponse *)response statusCode] : 0;
        completion(data, error ? 0 : status, error);
    }] resume];
}

void YTMUSSEEnumerateJSONEvents(NSData *data, void (NS_NOESCAPE ^block)(NSDictionary *json)) {
    if (!data.length || !block) return;
    NSString *body = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!body.length) return;
    if ([body rangeOfString:@"\r\n"].location != NSNotFound) {
        body = [body stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"];
    }
    for (NSString *event in [body componentsSeparatedByString:@"\n\n"]) {
        NSString *payload = nil;
        for (NSString *line in [event componentsSeparatedByString:@"\n"]) {
            if ([line hasPrefix:@"data:"]) {
                payload = [[line substringFromIndex:5] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                break;   // the providers put one JSON document per event
            }
        }
        if (!payload.length || [payload isEqualToString:@"[DONE]"]) continue;
        NSDictionary *json = YTMULLMDictionaryFromJSONString(payload);
        if (json) block(json);
    }
}
