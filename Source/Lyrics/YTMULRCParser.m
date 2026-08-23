#import "YTMULRCParser.h"
#import "YTMULyricsTypes.h"

@implementation YTMULRCParser

+ (NSTimeInterval)millisecondsForMinutes:(NSString *)minutes seconds:(NSString *)seconds fraction:(NSString *)fraction {
    NSInteger min = minutes.integerValue;
    NSInteger sec = seconds.integerValue;
    NSString *msText = fraction.length ? fraction : @"0";
    if (msText.length == 1) msText = [msText stringByAppendingString:@"00"];
    else if (msText.length == 2) msText = [msText stringByAppendingString:@"0"];
    else if (msText.length > 3) msText = [msText substringToIndex:3];
    NSInteger ms = msText.integerValue;
    return min * 60 * 1000 + sec * 1000 + ms;
}

+ (NSString *)timeStringForMs:(NSTimeInterval)timeInMs {
    NSInteger totalMs = MAX(0, (NSInteger)llround(timeInMs));
    NSInteger minutes = totalMs / 60000;
    NSInteger seconds = (totalMs % 60000) / 1000;
    NSInteger centiseconds = (totalMs % 1000) / 10;
    return [NSString stringWithFormat:@"%02ld:%02ld.%02ld", (long)minutes, (long)seconds, (long)centiseconds];
}

+ (NSArray<YTMULyricLine *> *)parseLRC:(NSString *)text {
    if (!text.length) return @[];

    NSRegularExpression *timestamp = YTMULyricsCachedRegex(@"\\[(\\d+)[:：](\\d+)(?:[\\.:：](\\d+))?\\]", 0);
    NSRegularExpression *tag = YTMULyricsCachedRegex(@"^\\[(\\w+):\\s*(.+?)\\s*\\]$", 0);
    NSRegularExpression *wordTiming = YTMULyricsCachedRegex(@"<\\d+[:：]\\d+(?:[\\.:：]\\d+)?>\\s*", 0);

    NSMutableArray<YTMULyricLine *> *lines = [NSMutableArray array];
    __block NSInteger offset = 0;

    NSArray<NSString *> *rawLines = [text componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    for (NSString *rawLine in rawLines) {
        NSString *line = [rawLine stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (![line hasPrefix:@"["]) continue;

        NSArray<NSTextCheckingResult *> *matches = [timestamp matchesInString:line options:0 range:NSMakeRange(0, line.length)];
        if (!matches.count) {
            NSTextCheckingResult *tagMatch = [tag firstMatchInString:line options:0 range:NSMakeRange(0, line.length)];
            if (tagMatch.numberOfRanges >= 3) {
                NSString *tagName = [line substringWithRange:[tagMatch rangeAtIndex:1]].lowercaseString;
                NSString *tagValue = [line substringWithRange:[tagMatch rangeAtIndex:2]];
                if ([tagName isEqualToString:@"offset"]) offset = tagValue.integerValue;
            }
            continue;
        }

        NSString *textPart = [timestamp stringByReplacingMatchesInString:line options:0 range:NSMakeRange(0, line.length) withTemplate:@""];
        textPart = [wordTiming stringByReplacingMatchesInString:textPart options:0 range:NSMakeRange(0, textPart.length) withTemplate:@""];
        textPart = [textPart stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

        for (NSTextCheckingResult *match in matches) {
            NSString *minutes = [line substringWithRange:[match rangeAtIndex:1]];
            NSString *seconds = [line substringWithRange:[match rangeAtIndex:2]];
            NSString *fraction = [match rangeAtIndex:3].location == NSNotFound ? @"" : [line substringWithRange:[match rangeAtIndex:3]];
            NSTimeInterval timeInMs = [self millisecondsForMinutes:minutes seconds:seconds fraction:fraction];
            [lines addObject:[YTMULyricLine lineWithTime:[self timeStringForMs:timeInMs]
                                                timeInMs:timeInMs
                                              durationMs:INFINITY
                                                    text:textPart]];
        }
    }

    [lines sortUsingComparator:^NSComparisonResult(YTMULyricLine *a, YTMULyricLine *b) {
        if (a.timeInMs < b.timeInMs) return NSOrderedAscending;
        if (a.timeInMs > b.timeInMs) return NSOrderedDescending;
        return NSOrderedSame;
    }];

    for (NSUInteger i = 0; i < lines.count; i++) {
        YTMULyricLine *current = lines[i];
        current.timeInMs += offset;
        current.time = [self timeStringForMs:current.timeInMs];
        if (i + 1 < lines.count) {
            current.durationMs = MAX(0, lines[i + 1].timeInMs - current.timeInMs);
        } else {
            current.durationMs = 3500;
        }
    }

    if (lines.firstObject && lines.firstObject.timeInMs > 300) {
        YTMULyricLine *empty = [YTMULyricLine lineWithTime:@"00:00.00"
                                                  timeInMs:0
                                                durationMs:lines.firstObject.timeInMs
                                                      text:@""];
        [lines insertObject:empty atIndex:0];
    }

    return lines;
}

+ (NSArray<NSString *> *)plainLinesFromLyrics:(NSString *)lyrics {
    if (!lyrics.length) return @[];
    NSArray *raw = [lyrics componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    NSMutableArray *lines = [NSMutableArray arrayWithCapacity:raw.count];
    NSRegularExpression *lrcPrefix = YTMULyricsCachedRegex(@"^\\[\\d+[:：]\\d+(?:[\\.:：]\\d+)?\\]\\s*", 0);
    for (NSString *line in raw) {
        NSString *clean = [lrcPrefix stringByReplacingMatchesInString:line options:0 range:NSMakeRange(0, line.length) withTemplate:@""];
        clean = [clean stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (clean.length) [lines addObject:clean];
    }
    return lines;
}

+ (NSString *)stripNetEaseMetadata:(NSString *)lyrics {
    if (!lyrics.length) return @"";
    NSMutableArray *kept = [NSMutableArray array];
    for (NSString *line in [lyrics componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        if ([line containsString:@"{"]) {
            NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
            if (data && [NSJSONSerialization JSONObjectWithData:data options:0 error:nil]) {
                continue;
            }
        }
        [kept addObject:line];
    }
    return [kept componentsJoinedByString:@"\n"];
}

@end
