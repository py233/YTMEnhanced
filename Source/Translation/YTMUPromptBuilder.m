#import "YTMUPromptBuilder.h"

@implementation YTMUPromptBuilder

+ (NSString *)systemPromptForRequest:(YTMUTranslationRequest *)req {
    NSString *lang = req.resolvedTargetLanguage;
    NSArray *lines = @[
        [NSString stringWithFormat:@"You are a careful song-lyrics translator. Translate the complete song into %@.", lang],
        @"Read the title, artists, and the full lyrics as one complete lyric/poem before choosing any wording.",
        @"Rules:",
        @"- Output ONLY a raw JSON object: {\"lines\": [\"...\", \"...\"]}.",
        @"- Your reply MUST start with `{` and end with `}`. Do NOT wrap the JSON in markdown code fences (no ```json, no ```), no preface (\"Here is the translation:\"), no commentary, no trailing notes.",
        @"- Every value in \"lines\" is a JSON string. Any literal \" character inside a value MUST be escaped as \\\".",
        [NSString stringWithFormat:@"- The \"lines\" array MUST have exactly %lu entries — the same count as the input, no exceptions.",
            (unsigned long)req.lines.count],
        @"- Do NOT add any extra entries: no leading blank, no trailing blank, no inserted \"intro\" / \"outro\" / \"chorus\" placeholder. Do NOT merge two source lines into one entry. Do NOT split a long source line across two entries.",
        @"- The array is only for display alignment: entry i corresponds to source line i+1 after full-song translation.",
        @"- Do not translate lines as isolated fragments. Use the full song context, speaker/listener relationship, repeated motifs, and neighboring lines.",
        @"- Use natural, emotionally coherent wording. It is okay for a translated line to be slightly longer when needed to preserve meaning.",
        @"- Keep repeated refrains and recurring images consistent unless the original clearly shifts them.",
        @"- For Japanese lyrics, resolve omitted subjects, particles, ruby text, and line-break enjambment from context.",
        @"- When translating into Chinese, avoid stiff word-for-word Japanese syntax; preserve ambiguity and imagery while making the line read like natural Chinese lyrics.",
        @"- Keep proper nouns, brand names, and untranslatable interjections as-is when natural.",
        @"- For lines that contain only punctuation, symbols, or musical marks (e.g. ♪), copy them unchanged.",
        @"- Do NOT include any explanation, notes, or the [N] index prefix in the output.",
    ];
    return [lines componentsJoinedByString:@"\n"];
}

+ (NSString *)userPromptForRequest:(YTMUTranslationRequest *)req {
    NSString *title = req.title.length ? req.title : @"(unknown)";
    NSString *artists = req.artists.count ? [req.artists componentsJoinedByString:@", "] : @"(unknown)";
    NSArray *headerLines = @[
        [NSString stringWithFormat:@"Song title: %@", title],
        [NSString stringWithFormat:@"Artist(s): %@", artists],
        [NSString stringWithFormat:@"Target language: %@", req.resolvedTargetLanguage],
        [NSString stringWithFormat:@"Display alignment line count: %lu", (unsigned long)req.lines.count],
        @"Translate the entire song below as one coherent lyric. The numbers exist only so your JSON array can stay aligned with the original lines.",
        @"Return valid json only: {\"lines\":[\"...\"]}.",
        @"",
        @"Full lyrics:",
    ];
    NSMutableArray *bodyLines = [NSMutableArray arrayWithCapacity:req.lines.count];
    [req.lines enumerateObjectsUsingBlock:^(NSString *line, NSUInteger i, BOOL *stop) {
        [bodyLines addObject:[NSString stringWithFormat:@"%lu. %@", (unsigned long)(i + 1), line]];
    }];
    NSString *header = [headerLines componentsJoinedByString:@"\n"];
    NSString *body = [bodyLines componentsJoinedByString:@"\n"];
    return [NSString stringWithFormat:@"%@\n%@", header, body];
}

+ (nullable NSArray<NSString *> *)tryParse:(NSString *)input {
    NSData *data = [input dataUsingEncoding:NSUTF8StringEncoding];
    if (!data) return nil;
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    if (!obj) return nil;

    NSArray *src = nil;
    if ([obj isKindOfClass:[NSArray class]]) {
        src = obj;
    } else if ([obj isKindOfClass:[NSDictionary class]]) {
        id maybe = obj[@"lines"];
        if ([maybe isKindOfClass:[NSArray class]]) src = maybe;
    }
    if (!src) return nil;

    NSMutableArray *out = [NSMutableArray arrayWithCapacity:src.count];
    for (id x in src) {
        if ([x isKindOfClass:[NSString class]]) [out addObject:x];
    }
    return out;
}

// Tolerant `{"lines":[...]}` parser that recovers from unescaped
// internal double quotes — a real failure mode we hit on claude-opus
// translating an English lyric line containing a quoted phrase. The
// model emits e.g. `"呃，"她在海边卖贝壳""` (the inner quotes from the
// English original survive untouched into the JSON value), and
// NSJSONSerialization rejects it because the first inner `"` looks
// like a string terminator.
//
// Recovery strategy: walk the string with a depth/quote state machine
// and treat any `"` whose lookahead is NOT a JSON-syntactic follower
// (`,` or `]` or whitespace+`,`/`]`) as a literal quote inside the
// current value. This is purely additive — well-formed JSON parses
// the same way it would in NSJSONSerialization.
+ (nullable NSArray<NSString *> *)tolerantLinesFromJSON:(NSString *)text {
    if (!text.length) return nil;
    NSUInteger len = text.length;
    NSUInteger i = 0;
    NSCharacterSet *ws = [NSCharacterSet whitespaceAndNewlineCharacterSet];

    // Inline whitespace skip (a block-based helper would need __block
    // qualifiers on `i` and complicates the function for no gain).
    #define YTMU_SKIPWS() do { \
        while (i < len && [ws characterIsMember:[text characterAtIndex:i]]) i++; \
    } while (0)

    YTMU_SKIPWS();
    if (i >= len || [text characterAtIndex:i] != '{') { return nil; }
    i++;
    YTMU_SKIPWS();
    // Find a "lines" key. Bail if the very first key isn't it — the
    // production prompt only ever emits {"lines":...}.
    NSString *linesKey = @"\"lines\"";
    if (i + linesKey.length > len ||
        ![[text substringWithRange:NSMakeRange(i, linesKey.length)] isEqualToString:linesKey]) {
        return nil;
    }
    i += linesKey.length;
    YTMU_SKIPWS();
    if (i >= len || [text characterAtIndex:i] != ':') return nil;
    i++;
    YTMU_SKIPWS();
    if (i >= len || [text characterAtIndex:i] != '[') return nil;
    i++;

    NSMutableArray<NSString *> *out = [NSMutableArray array];
    while (i < len) {
        YTMU_SKIPWS();
        if (i >= len) return nil;
        unichar c = [text characterAtIndex:i];
        if (c == ']') { i++; break; }
        if (c != '"') return nil;
        i++; // opening quote

        NSMutableString *value = [NSMutableString string];
        BOOL closed = NO;
        while (i < len) {
            unichar ch = [text characterAtIndex:i];
            if (ch == '\\') {
                if (i + 1 < len) {
                    unichar nx = [text characterAtIndex:i + 1];
                    switch (nx) {
                        case '"':  [value appendString:@"\""]; i += 2; continue;
                        case '\\': [value appendString:@"\\"]; i += 2; continue;
                        case '/':  [value appendString:@"/"];  i += 2; continue;
                        case 'n':  [value appendString:@"\n"]; i += 2; continue;
                        case 't':  [value appendString:@"\t"]; i += 2; continue;
                        case 'r':  [value appendString:@"\r"]; i += 2; continue;
                        case 'b':  [value appendFormat:@"%c", 0x08]; i += 2; continue;
                        case 'f':  [value appendFormat:@"%c", 0x0c]; i += 2; continue;
                        case 'u': {
                            if (i + 5 < len) {
                                NSString *hex = [text substringWithRange:NSMakeRange(i + 2, 4)];
                                NSScanner *sc = [NSScanner scannerWithString:hex];
                                unsigned int code = 0;
                                if ([sc scanHexInt:&code]) {
                                    [value appendFormat:@"%C", (unichar)code];
                                    i += 6;
                                    continue;
                                }
                            }
                            break;
                        }
                        default: break;
                    }
                    // Unknown escape — keep the following char literally.
                    [value appendFormat:@"%C", nx];
                    i += 2;
                    continue;
                }
                [value appendFormat:@"%C", ch];
                i++;
                continue;
            }
            if (ch == '"') {
                // Closing quote vs unescaped inner quote? Look at the
                // next non-whitespace char. If it's `,` or `]`, we're
                // at the value terminator. Otherwise the model emitted
                // a literal `"` and we keep it.
                NSUInteger j = i + 1;
                while (j < len && [ws characterIsMember:[text characterAtIndex:j]]) j++;
                if (j < len) {
                    unichar nx = [text characterAtIndex:j];
                    if (nx == ',' || nx == ']') {
                        i++;
                        closed = YES;
                        break;
                    }
                }
                [value appendString:@"\""];
                i++;
                continue;
            }
            [value appendFormat:@"%C", ch];
            i++;
        }
        if (!closed) return nil;
        [out addObject:[value copy]];

        YTMU_SKIPWS();
        if (i >= len) return nil;
        unichar sep = [text characterAtIndex:i];
        if (sep == ',') { i++; continue; }
        if (sep == ']') { i++; break; }
        return nil;
    }

    #undef YTMU_SKIPWS
    return [out copy];
}

+ (nullable NSArray<NSString *> *)parseLinesFromJSON:(NSString *)raw expected:(NSUInteger)expected {
    if (!raw.length) return nil;
    NSString *text = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

    NSArray *parsed = [self tryParse:text];
    if (parsed) return parsed;

    // Strip markdown code fences. Some providers/models wrap the
    // JSON in ```json … ``` even when the system prompt tells them
    // not to. Previous regex-based stripping (`^```(?:json)?`)
    // occasionally failed in practice — we now walk characters
    // explicitly so there's no ICU-regex / Unicode-class surprise.
    NSString *fenced = text;
    if ([fenced hasPrefix:@"```"]) {
        NSUInteger start = 3;
        // Optional language tag (json / javascript / js / ts / etc.) —
        // skip until newline or whitespace.
        while (start < fenced.length) {
            unichar c = [fenced characterAtIndex:start];
            if (c == '\n' || c == '\r' || c == ' ' || c == '\t') break;
            start++;
        }
        // Skip the separating newline/whitespace itself.
        while (start < fenced.length) {
            unichar c = [fenced characterAtIndex:start];
            if (c != '\n' && c != '\r' && c != ' ' && c != '\t') break;
            start++;
        }
        fenced = [fenced substringFromIndex:start];
    }
    if ([fenced hasSuffix:@"```"]) {
        fenced = [fenced substringToIndex:fenced.length - 3];
    }
    fenced = [fenced stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    parsed = [self tryParse:fenced];
    if (parsed) return parsed;

    // Greedy first {...} (last `}` after first `{`). Works when
    // models prepend "Here is the translation:" prose.
    NSRange objStart = [text rangeOfString:@"{"];
    NSRange objEnd = [text rangeOfString:@"}" options:NSBackwardsSearch];
    if (objStart.location != NSNotFound && objEnd.location != NSNotFound && objEnd.location > objStart.location) {
        NSString *sub = [text substringWithRange:NSMakeRange(objStart.location, objEnd.location - objStart.location + 1)];
        parsed = [self tryParse:sub];
        if (parsed) return parsed;
    }

    // First [...]
    NSRange arrStart = [text rangeOfString:@"["];
    NSRange arrEnd = [text rangeOfString:@"]" options:NSBackwardsSearch];
    if (arrStart.location != NSNotFound && arrEnd.location != NSNotFound && arrEnd.location > arrStart.location) {
        NSString *sub = [text substringWithRange:NSMakeRange(arrStart.location, arrEnd.location - arrStart.location + 1)];
        parsed = [self tryParse:sub];
        if (parsed) return parsed;
    }

    // Last-ditch: brace-balanced extraction. Walks the string with
    // a depth counter that respects JSON string literals (so braces
    // inside `"..."` don't confuse the count). Catches cases where
    // the response is truncated mid-output but the leading {…} is
    // still self-contained, or where there's trailing prose after
    // the JSON object.
    if (objStart.location != NSNotFound) {
        NSUInteger len = text.length;
        NSUInteger depth = 0;
        BOOL inString = NO;
        BOOL escape = NO;
        NSUInteger endIdx = NSNotFound;
        for (NSUInteger i = objStart.location; i < len; i++) {
            unichar c = [text characterAtIndex:i];
            if (inString) {
                if (escape) { escape = NO; continue; }
                if (c == '\\') { escape = YES; continue; }
                if (c == '"') { inString = NO; }
                continue;
            }
            if (c == '"') { inString = YES; continue; }
            if (c == '{') { depth++; }
            else if (c == '}') {
                if (depth > 0) depth--;
                if (depth == 0) { endIdx = i; break; }
            }
        }
        if (endIdx != NSNotFound) {
            NSString *sub = [text substringWithRange:NSMakeRange(objStart.location, endIdx - objStart.location + 1)];
            parsed = [self tryParse:sub];
            if (parsed) return parsed;
        }
    }

    // Last-resort: tolerant `{"lines":[...]}` parser that survives
    // unescaped internal quotes (claude-opus sometimes leaves the
    // ASCII " from "she sells seashells" verbatim inside a JSON
    // value, which strict parsers reject). Try the fenced text first
    // (cheapest), fall back to the raw text if needed.
    parsed = [self tolerantLinesFromJSON:fenced];
    if (parsed) return parsed;
    parsed = [self tolerantLinesFromJSON:text];
    if (parsed) return parsed;

    return nil;
}

+ (BOOL)isSkippableLine:(NSString *)line {
    if (!line.length) return YES;
    NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!trimmed.length) return YES;
    static NSRegularExpression *re;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        re = [NSRegularExpression regularExpressionWithPattern:@"^[\\s♪•·.…\\-—_~()【】\\[\\]{}「」『』<>/\\\\|\"'`*+=#@$%^&!?，。！？、；：…—]+$"
                                                       options:0
                                                         error:NULL];
    });
    NSUInteger matches = [re numberOfMatchesInString:trimmed options:0 range:NSMakeRange(0, trimmed.length)];
    return matches > 0;
}

+ (NSString *)resolveLanguageName:(NSString *)code {
    static NSDictionary *map;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        map = @{
            @"auto"   : @"the user's preferred language",
            @"zh"     : @"Simplified Chinese",
            @"zh-Hans": @"Simplified Chinese",
            @"zh-CN"  : @"Simplified Chinese",
            @"zh-Hant": @"Traditional Chinese",
            @"zh-TW"  : @"Traditional Chinese",
            @"en"     : @"English",
            @"ja"     : @"Japanese",
            @"ko"     : @"Korean",
            @"es"     : @"Spanish",
            @"fr"     : @"French",
            @"de"     : @"German",
            @"it"     : @"Italian",
            @"pt"     : @"Portuguese",
            @"pt-BR"  : @"Brazilian Portuguese",
            @"ru"     : @"Russian",
            @"ar"     : @"Arabic",
            @"hi"     : @"Hindi",
            @"tr"     : @"Turkish",
            @"vi"     : @"Vietnamese",
            @"th"     : @"Thai",
            @"id"     : @"Indonesian",
            @"pl"     : @"Polish",
            @"nl"     : @"Dutch",
            @"sv"     : @"Swedish",
            @"uk"     : @"Ukrainian",
            @"el"     : @"Greek",
            @"he"     : @"Hebrew",
            @"cs"     : @"Czech",
            @"da"     : @"Danish",
            @"fi"     : @"Finnish",
            @"no"     : @"Norwegian",
            @"hu"     : @"Hungarian",
            @"ro"     : @"Romanian",
            @"sk"     : @"Slovak",
            @"bg"     : @"Bulgarian",
            @"hr"     : @"Croatian",
            @"lt"     : @"Lithuanian",
            @"lv"     : @"Latvian",
            @"sr"     : @"Serbian",
            @"ms"     : @"Malay",
            @"fa"     : @"Persian",
        };
    });
    NSString *name = map[code];
    if (name) return name;
    NSLocale *en = [NSLocale localeWithLocaleIdentifier:@"en"];
    NSString *display = [en displayNameForKey:NSLocaleLanguageCode value:code];
    return display.length ? display : code;
}

+ (NSString *)effectiveTargetCode:(NSString *)code {
    if (![code isEqualToString:@"auto"]) return code ?: @"en";
    NSLocale *cur = [NSLocale currentLocale];
    NSString *lang = [cur objectForKey:NSLocaleLanguageCode] ?: @"en";
    if ([lang isEqualToString:@"zh"]) {
        NSString *ident = cur.localeIdentifier ?: @"";
        if ([ident containsString:@"Hant"] || [ident containsString:@"TW"] ||
            [ident containsString:@"HK"]   || [ident containsString:@"MO"]) {
            return @"zh-Hant";
        }
        return @"zh-Hans";
    }
    if ([lang isEqualToString:@"pt"]) {
        NSString *region = [cur objectForKey:NSLocaleCountryCode] ?: @"";
        if ([region isEqualToString:@"BR"]) return @"pt-BR";
        return @"pt";
    }
    return lang;
}

@end
