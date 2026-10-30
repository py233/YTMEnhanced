#import "YTMUWordLyricsParser.h"
#import "YTMULRCParser.h"
#include <math.h>

static NSTimeInterval YTMUWordLyricsTime(NSString *value) {
    NSString *v = [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!v.length) return NAN;
    NSRegularExpression *shortClock = [NSRegularExpression regularExpressionWithPattern:@"^(\\d+):([0-9]+)(?:\\.([0-9]+))?$" options:0 error:nil];
    NSTextCheckingResult *shortMatch = [shortClock firstMatchInString:v options:0 range:NSMakeRange(0, v.length)];
    if (shortMatch) {
        double minutes = [[v substringWithRange:[shortMatch rangeAtIndex:1]] doubleValue];
        double seconds = [[v substringWithRange:[shortMatch rangeAtIndex:2]] doubleValue];
        NSString *fraction = [shortMatch rangeAtIndex:3].location == NSNotFound ? @"" : [v substringWithRange:[shortMatch rangeAtIndex:3]];
        double f = fraction.length ? [@[@"0", fraction] componentsJoinedByString:@"."].doubleValue : 0;
        return (minutes * 60 + seconds + f) * 1000;
    }
    NSRegularExpression *clock = [NSRegularExpression regularExpressionWithPattern:@"^(\\d+):([0-9]+):([0-9]+)(?:\\.([0-9]+))?$" options:0 error:nil];
    NSTextCheckingResult *match = [clock firstMatchInString:v options:0 range:NSMakeRange(0, v.length)];
    if (match) {
        double h = [[v substringWithRange:[match rangeAtIndex:1]] doubleValue];
        double m = [[v substringWithRange:[match rangeAtIndex:2]] doubleValue];
        double s = [[v substringWithRange:[match rangeAtIndex:3]] doubleValue];
        NSString *fraction = [match rangeAtIndex:4].location == NSNotFound ? @"" : [v substringWithRange:[match rangeAtIndex:4]];
        double f = fraction.length ? [@[@"0", fraction] componentsJoinedByString:@"."].doubleValue : 0;
        return (h * 3600 + m * 60 + s + f) * 1000;
    }
    NSRegularExpression *offset = [NSRegularExpression regularExpressionWithPattern:@"^([0-9]+(?:\\.[0-9]+)?)(ms|s|m|h|t)$" options:NSRegularExpressionCaseInsensitive error:nil];
    match = [offset firstMatchInString:v options:0 range:NSMakeRange(0, v.length)];
    if (!match) return isfinite(v.doubleValue) ? v.doubleValue * 1000 : NAN;
    double amount = [[v substringWithRange:[match rangeAtIndex:1]] doubleValue];
    NSString *unit = [[v substringWithRange:[match rangeAtIndex:2]] lowercaseString];
    if ([unit isEqualToString:@"ms"]) return amount;
    if ([unit isEqualToString:@"m"]) return amount * 60000;
    if ([unit isEqualToString:@"h"]) return amount * 3600000;
    return amount * 1000;
}

NSArray<YTMULyricLine *> *YTMUWordLyricsParseTTML(NSString *ttml) {
    if (!ttml.length) return @[];
    NSMutableArray<YTMULyricLine *> *lines = [NSMutableArray array];
    NSRegularExpression *paragraphRegex = [NSRegularExpression regularExpressionWithPattern:@"<p\\b([^>]*)>([\\s\\S]*?)</p>" options:NSRegularExpressionCaseInsensitive error:nil];
    NSRegularExpression *attributeRegex = [NSRegularExpression regularExpressionWithPattern:@"\\b(begin|end)\\s*=\\s*[\"']([^\"']+)[\"']" options:NSRegularExpressionCaseInsensitive error:nil];
    NSRegularExpression *spanRegex = [NSRegularExpression regularExpressionWithPattern:@"<span\\b([^>]*)>([\\s\\S]*?)</span>" options:NSRegularExpressionCaseInsensitive error:nil];
    NSArray *paragraphs = [paragraphRegex matchesInString:ttml options:0 range:NSMakeRange(0, ttml.length)];
    for (NSTextCheckingResult *paragraph in paragraphs) {
        NSString *attributes = [ttml substringWithRange:[paragraph rangeAtIndex:1]];
        NSString *body = [ttml substringWithRange:[paragraph rangeAtIndex:2]];
        NSTimeInterval start = NAN;
        NSTimeInterval end = NAN;
        for (NSTextCheckingResult *attribute in [attributeRegex matchesInString:attributes options:0 range:NSMakeRange(0, attributes.length)]) {
            NSString *key = [[attributes substringWithRange:[attribute rangeAtIndex:1]] lowercaseString];
            NSTimeInterval value = YTMUWordLyricsTime([attributes substringWithRange:[attribute rangeAtIndex:2]]);
            if ([key isEqualToString:@"begin"]) start = value;
            else end = value;
        }
        if (!isfinite(start)) continue;
        NSMutableArray<NSDictionary *> *words = [NSMutableArray array];
        for (NSTextCheckingResult *span in [spanRegex matchesInString:body options:0 range:NSMakeRange(0, body.length)]) {
            NSString *spanAttributes = [body substringWithRange:[span rangeAtIndex:1]];
            NSString *text = [body substringWithRange:[span rangeAtIndex:2]];
            text = [text stringByReplacingOccurrencesOfString:@"<[^>]+>" withString:@"" options:NSRegularExpressionSearch range:NSMakeRange(0, text.length)];
            text = [text stringByReplacingOccurrencesOfString:@"\\s+" withString:@" " options:NSRegularExpressionSearch range:NSMakeRange(0, text.length)];
            text = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            NSTimeInterval wordStart = NAN;
            NSTimeInterval wordEnd = NAN;
            for (NSTextCheckingResult *attribute in [attributeRegex matchesInString:spanAttributes options:0 range:NSMakeRange(0, spanAttributes.length)]) {
                NSString *key = [[spanAttributes substringWithRange:[attribute rangeAtIndex:1]] lowercaseString];
                NSTimeInterval value = YTMUWordLyricsTime([spanAttributes substringWithRange:[attribute rangeAtIndex:2]]);
                if ([key isEqualToString:@"begin"]) wordStart = value;
                else wordEnd = value;
            }
            if (!text.length || !isfinite(wordStart)) continue;
            if (!isfinite(wordEnd) || wordEnd < wordStart) wordEnd = wordStart;
            [words addObject:@{@"text": text, @"start": @(wordStart), @"end": @(wordEnd)}];
        }
        NSString *text = [body stringByReplacingOccurrencesOfString:@"<[^>]+>" withString:@"" options:NSRegularExpressionSearch range:NSMakeRange(0, body.length)];
        text = [text stringByReplacingOccurrencesOfString:@"\\s+" withString:@" " options:NSRegularExpressionSearch range:NSMakeRange(0, text.length)];
        text = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (!text.length) continue;
        if (!isfinite(end) || end <= start) end = words.lastObject ? [words.lastObject[@"end"] doubleValue] : start + 3500;
        if (end <= start) end = start + 3500;
        YTMULyricLine *line = [YTMULyricLine lineWithTime:[YTMULRCParser timeStringForMs:start]
                                                  timeInMs:start durationMs:end - start text:text];
        line.wordTimings = words;
        [lines addObject:line];
    }
    [lines sortUsingComparator:^NSComparisonResult(YTMULyricLine *a, YTMULyricLine *b) {
        return [@(a.timeInMs) compare:@(b.timeInMs)];
    }];
    return lines;
}

YTMULyricsResult *YTMUWordLyricsResultFromSpicyJSON(NSDictionary *json, YTMULyricsSearchInfo *info, NSString *sourceName) {
    NSString *type = [json[@"Type"] isKindOfClass:[NSString class]] ? json[@"Type"] : @"";
    if (![type.lowercaseString isEqualToString:@"syllable"]) return nil;
    NSArray *content = [json[@"Content"] isKindOfClass:[NSArray class]] ? json[@"Content"] : @[];
    NSMutableArray<YTMULyricLine *> *lines = [NSMutableArray array];
    for (NSDictionary *item in content) {
        NSDictionary *lead = [item[@"Lead"] isKindOfClass:[NSDictionary class]] ? item[@"Lead"] : nil;
        NSArray *raw = [lead[@"Syllables"] isKindOfClass:[NSArray class]] ? lead[@"Syllables"] : @[];
        NSMutableArray<NSDictionary *> *words = [NSMutableArray array];
        NSMutableString *text = [NSMutableString string];
        for (NSDictionary *syllable in raw) {
            NSString *part = [syllable[@"Text"] isKindOfClass:[NSString class]] ? syllable[@"Text"] : @"";
            NSNumber *start = [syllable[@"StartTime"] respondsToSelector:@selector(doubleValue)] ? syllable[@"StartTime"] : nil;
            NSNumber *end = [syllable[@"EndTime"] respondsToSelector:@selector(doubleValue)] ? syllable[@"EndTime"] : nil;
            if (!part.length || !start || !end) continue;
            if (text.length && ![part hasPrefix:@" "]) [text appendString:@" "];
            [text appendString:part];
            [words addObject:@{@"text": part, @"start": @([start doubleValue] * 1000), @"end": @([end doubleValue] * 1000)}];
        }
        if (!text.length) continue;
        NSTimeInterval start = words.firstObject[@"start"] ? [words.firstObject[@"start"] doubleValue] : 0;
        NSTimeInterval end = words.lastObject[@"end"] ? [words.lastObject[@"end"] doubleValue] : start + 3500;
        YTMULyricLine *line = [YTMULyricLine lineWithTime:[YTMULRCParser timeStringForMs:start] timeInMs:start durationMs:MAX(1, end - start) text:text];
        line.wordTimings = words;
        [lines addObject:line];
    }
    if (!lines.count) return nil;
    YTMULyricsResult *result = [[YTMULyricsResult alloc] init];
    result.sourceName = sourceName;
    result.title = info.title;
    result.artists = info.artist.length ? @[info.artist] : @[];
    result.lines = lines;
    result.duration = info.duration;
    return result;
}
