#import "YTMULyricsTextProcessor.h"

@implementation YTMULyricsTextProcessor

+ (NSString *)canonicalize:(NSString *)text {
    if (!text.length) return @"";
    NSString *out = text;
    NSRegularExpression *spaces = [NSRegularExpression regularExpressionWithPattern:@"\\s+" options:0 error:nil];
    out = [spaces stringByReplacingMatchesInString:out options:0 range:NSMakeRange(0, out.length) withTemplate:@" "];

    NSArray<NSArray<NSString *> *> *replacements = @[
        @[@"([\\(\\[]) ([^ ])", @"$1$2"],
        @[@"([^ ]) ([\\)\\]])", @"$1$2"],
        @[@"([^ ]) ([\\.,!?])", @"$1$2"],
        @[@"([^ ]) (-) ([^ ])", @"$1$2$3"],
    ];
    for (NSArray<NSString *> *pair in replacements) {
        NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:pair[0] options:0 error:nil];
        out = [re stringByReplacingMatchesInString:out options:0 range:NSMakeRange(0, out.length) withTemplate:pair[1]];
    }
    return [out stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

+ (NSString *)simplifyUnicode:(NSString *)text {
    if (!text.length) return @"";
    NSString *folded = [text stringByReplacingOccurrencesOfString:@"\u00a0" withString:@" "];
    NSRegularExpression *spaces = [NSRegularExpression regularExpressionWithPattern:@"\\s+" options:0 error:nil];
    folded = [spaces stringByReplacingMatchesInString:folded options:0 range:NSMakeRange(0, folded.length) withTemplate:@" "];
    return [[folded.precomposedStringWithCanonicalMapping lowercaseString] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

+ (BOOL)hasChinese:(NSString *)text {
    return [text rangeOfString:@"[\\u4E00-\\u9FFF]" options:NSRegularExpressionSearch].location != NSNotFound;
}

+ (BOOL)hasJapaneseKana:(NSString *)text {
    return [text rangeOfString:@"[\\u3040-\\u30ff]" options:NSRegularExpressionSearch].location != NSNotFound;
}

+ (BOOL)hasRomanizableText:(NSString *)text {
    return [text rangeOfString:@"[\\u3040-\\u30ff\\u3400-\\u9fff\\uac00-\\ud7af\\u0e00-\\u0e7f\\u0900-\\u097f\\u0980-\\u09ff]"
                      options:NSRegularExpressionSearch].location != NSNotFound;
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

+ (NSString *)romanizeText:(NSString *)text {
    if (!text.length || ![self hasRomanizableText:text]) return @"";
    NSMutableString *mutable = [[self canonicalize:text] mutableCopy];
    if (!mutable.length) return @"";

    if ([self hasChinese:mutable]) {
        return @"";
    }

    CFStringTransform((__bridge CFMutableStringRef)mutable, NULL, kCFStringTransformToLatin, NO);
    CFStringTransform((__bridge CFMutableStringRef)mutable, NULL, kCFStringTransformStripCombiningMarks, NO);

    NSString *out = mutable.lowercaseString;
    NSRegularExpression *spaces = [NSRegularExpression regularExpressionWithPattern:@"\\s+" options:0 error:nil];
    out = [spaces stringByReplacingMatchesInString:out options:0 range:NSMakeRange(0, out.length) withTemplate:@" "];
    return [out stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
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
