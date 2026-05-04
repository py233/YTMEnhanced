#import "YTMUPromptBuilder.h"

@implementation YTMUPromptBuilder

+ (NSString *)systemPromptForRequest:(YTMUTranslationRequest *)req {
    NSString *lang = req.resolvedTargetLanguage;
    NSArray *lines = @[
        [NSString stringWithFormat:@"You are a careful song-lyrics translator. Translate the complete song into %@.", lang],
        @"Read the title, artists, and the full lyrics as one complete lyric/poem before choosing any wording.",
        @"Rules:",
        @"- Output ONLY a JSON object: {\"lines\": [\"...\", \"...\"]}.",
        [NSString stringWithFormat:@"- The \"lines\" array MUST have exactly %lu entries, in the same order as the input.",
            (unsigned long)req.lines.count],
        @"- The array is only for display alignment: each entry corresponds to the same-numbered original line after full-song translation.",
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

+ (nullable NSArray<NSString *> *)parseLinesFromJSON:(NSString *)raw expected:(NSUInteger)expected {
    if (!raw.length) return nil;
    NSString *text = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

    NSArray *parsed = [self tryParse:text];
    if (parsed) return parsed;

    // Strip ``` fences.
    NSString *fenced = text;
    NSRegularExpression *openFence = [NSRegularExpression regularExpressionWithPattern:@"^```(?:json)?"
                                                                                options:NSRegularExpressionCaseInsensitive
                                                                                  error:NULL];
    fenced = [openFence stringByReplacingMatchesInString:fenced
                                                 options:0
                                                   range:NSMakeRange(0, fenced.length)
                                            withTemplate:@""];
    if ([fenced hasSuffix:@"```"]) {
        fenced = [fenced substringToIndex:fenced.length - 3];
    }
    fenced = [fenced stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    parsed = [self tryParse:fenced];
    if (parsed) return parsed;

    // First {...}
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

+ (NSString *)simplifyUnicode:(NSString *)s {
    if (!s) return @"";
    NSString *folded = [s.precomposedStringWithCanonicalMapping lowercaseString];
    NSCharacterSet *ws = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    NSArray *parts = [folded componentsSeparatedByCharactersInSet:ws];
    NSMutableArray *nonEmpty = [NSMutableArray array];
    for (NSString *p in parts) if (p.length) [nonEmpty addObject:p];
    return [nonEmpty componentsJoinedByString:@" "];
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
