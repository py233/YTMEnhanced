#import "YTMULyricsTextProcessor.h"
#import "YTMULyricsTypes.h"

@implementation YTMULyricsTextProcessor

+ (NSString *)canonicalize:(NSString *)text {
    if (!text.length) return @"";
    NSString *out = text;
    NSRegularExpression *spaces = YTMULyricsCachedRegex(@"\\s+", 0);
    out = [spaces stringByReplacingMatchesInString:out options:0 range:NSMakeRange(0, out.length) withTemplate:@" "];

    NSArray<NSArray<NSString *> *> *replacements = @[
        @[@"([\\(\\[]) ([^ ])", @"$1$2"],
        @[@"([^ ]) ([\\)\\]])", @"$1$2"],
        @[@"([^ ]) ([\\.,!?])", @"$1$2"],
        @[@"([^ ]) (-) ([^ ])", @"$1$2$3"],
    ];
    for (NSArray<NSString *> *pair in replacements) {
        NSRegularExpression *re = YTMULyricsCachedRegex(pair[0], 0);
        out = [re stringByReplacingMatchesInString:out options:0 range:NSMakeRange(0, out.length) withTemplate:pair[1]];
    }
    return [out stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

+ (NSString *)simplifyUnicode:(NSString *)text {
    if (!text.length) return @"";
    NSString *folded = [text stringByReplacingOccurrencesOfString:@"\u00a0" withString:@" "];
    NSRegularExpression *spaces = YTMULyricsCachedRegex(@"\\s+", 0);
    folded = [spaces stringByReplacingMatchesInString:folded options:0 range:NSMakeRange(0, folded.length) withTemplate:@" "];
    return [[folded.precomposedStringWithCanonicalMapping lowercaseString] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

+ (BOOL)hasChinese:(NSString *)text {
    return YTMULyricsRegexMatches(text, @"[\\u4E00-\\u9FFF]", 0);
}

+ (BOOL)hasJapaneseKana:(NSString *)text {
    return YTMULyricsRegexMatches(text, @"[\\u3040-\\u30ff]", 0);
}

+ (BOOL)hasCJKIdeograph:(NSString *)text {
    return YTMULyricsRegexMatches(text, @"[\\u3400-\\u9fff]", 0);
}

+ (BOOL)hasRomanizableText:(NSString *)text {
    return YTMULyricsRegexMatches(text, @"[\\u3040-\\u30ff\\u3400-\\u9fff\\uac00-\\ud7af\\u0e00-\\u0e7f\\u0900-\\u097f\\u0980-\\u09ff]", 0);
}

+ (BOOL)looksLikeLyricsHeader:(NSString *)text {
    NSString *trimmed = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!trimmed.length) return YES;
    if (YTMULyricsRegexMatches(trimmed, @"^\\[[^\\]]+\\]$", 0)) return YES;
    if (YTMULyricsRegexMatches(trimmed, @"^\\([^\\)]+\\)$", 0)) return YES;
    return NO;
}

+ (BOOL)needsRomanizationForText:(NSString *)text preferredLanguage:(NSString *)language {
    NSString *trimmed = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (![self hasRomanizableText:trimmed] || [self looksLikeLyricsHeader:trimmed]) return NO;

    NSString *lang = language.lowercaseString ?: @"";
    if ([lang hasPrefix:@"ja"]) {
        return [self hasJapaneseKana:trimmed] || [self hasCJKIdeograph:trimmed];
    }

    if ([self hasJapaneseKana:trimmed]) return YES;
    if (YTMULyricsRegexMatches(trimmed, @"[\\uac00-\\ud7af\\u0e00-\\u0e7f\\u0900-\\u097f\\u0980-\\u09ff]", 0)) {
        return YES;
    }
    return NO;
}

+ (NSString *)convertChineseText:(NSString *)text mode:(NSString *)mode {
    if (!text.length || ![self hasChinese:text]) return text ?: @"";
    if (![mode isEqualToString:@"simplifiedToTraditional"] && ![mode isEqualToString:@"traditionalToSimplified"]) return text;

    NSMutableString *mutable = [text mutableCopy];
    CFStringRef transform = [mode isEqualToString:@"simplifiedToTraditional"]
        ? CFSTR("Simplified-Traditional")
        : CFSTR("Traditional-Simplified");
    CFStringTransform((__bridge CFMutableStringRef)mutable, NULL, transform, NO);
    return mutable;
}

+ (NSString *)googleTransliterationFromJSON:(id)json {
    NSMutableString *text = [NSMutableString string];

    if ([json isKindOfClass:[NSDictionary class]]) {
        NSArray *sentences = ((NSDictionary *)json)[@"sentences"];
        if ([sentences isKindOfClass:[NSArray class]]) {
            for (id sentence in sentences) {
                if (![sentence isKindOfClass:[NSDictionary class]]) continue;
                NSString *part = ((NSDictionary *)sentence)[@"src_translit"];
                if ([part isKindOfClass:[NSString class]]) [text appendString:part];
            }
        }
    }

    NSString *out = [self canonicalize:text];
    return [[out lowercaseString] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

@end
