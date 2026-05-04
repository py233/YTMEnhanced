#import "YTMUGeniusProvider.h"

@implementation YTMUGeniusProvider

- (NSString *)providerName {
    return YTMULyricsSourceGenius;
}

- (NSString *)stringByDecodingHTML:(NSString *)text {
    if (!text.length) return @"";
    NSMutableString *out = [text mutableCopy];
    NSDictionary *entities = @{@"&amp;": @"&", @"&quot;": @"\"", @"&#x27;": @"'", @"&#39;": @"'", @"&lt;": @"<", @"&gt;": @">", @"<br/>": @"\n", @"<br />": @"\n", @"<br>": @"\n"};
    [entities enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *obj, BOOL *stop) {
        [out replaceOccurrencesOfString:key withString:obj options:0 range:NSMakeRange(0, out.length)];
    }];
    return out;
}

- (NSString *)stripHTML:(NSString *)html {
    NSString *withBreaks = [html stringByReplacingOccurrencesOfString:@"<br/>" withString:@"\n"];
    withBreaks = [withBreaks stringByReplacingOccurrencesOfString:@"<br />" withString:@"\n"];
    withBreaks = [withBreaks stringByReplacingOccurrencesOfString:@"</p>" withString:@"\n"];
    NSRegularExpression *tags = [NSRegularExpression regularExpressionWithPattern:@"<[^>]+>" options:0 error:nil];
    NSString *stripped = [tags stringByReplacingMatchesInString:withBreaks options:0 range:NSMakeRange(0, withBreaks.length) withTemplate:@""];
    return [[self stringByDecodingHTML:stripped] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

- (NSString *)extractLyricsFromHTML:(NSString *)html {
    NSRegularExpression *dataLyrics = [NSRegularExpression regularExpressionWithPattern:@"<div[^>]+data-lyrics-container=\"true\"[^>]*>(.*?)</div>"
                                                                                options:NSRegularExpressionDotMatchesLineSeparators | NSRegularExpressionCaseInsensitive
                                                                                  error:nil];
    NSArray<NSTextCheckingResult *> *matches = [dataLyrics matchesInString:html options:0 range:NSMakeRange(0, html.length)];
    NSMutableArray *parts = [NSMutableArray array];
    for (NSTextCheckingResult *match in matches) {
        NSString *fragment = [html substringWithRange:[match rangeAtIndex:1]];
        NSString *plain = [self stripHTML:fragment];
        if (plain.length) [parts addObject:plain];
    }
    if (parts.count) return [parts componentsJoinedByString:@"\n"];

    NSRegularExpression *preload = [NSRegularExpression regularExpressionWithPattern:@"body\"\\s*:\\s*\\{\\s*\"html\"\\s*:\\s*\"(.*?)\"\\s*,\\s*\"children\""
                                                                             options:NSRegularExpressionDotMatchesLineSeparators
                                                                               error:nil];
    NSTextCheckingResult *match = [preload firstMatchInString:html options:0 range:NSMakeRange(0, html.length)];
    if (match.numberOfRanges >= 2) {
        NSString *encoded = [html substringWithRange:[match rangeAtIndex:1]];
        encoded = [encoded stringByReplacingOccurrencesOfString:@"\\\\n" withString:@"\n"];
        encoded = [encoded stringByReplacingOccurrencesOfString:@"\\\"" withString:@"\""];
        encoded = [encoded stringByReplacingOccurrencesOfString:@"\\\\/" withString:@"/"];
        return [self stripHTML:encoded];
    }
    return @"";
}

- (void)searchWithInfo:(YTMULyricsSearchInfo *)info completion:(void (^)(YTMULyricsResult *, NSError *))completion {
    NSString *query = YTMULyricsEncodeQuery([NSString stringWithFormat:@"%@ %@", info.artist ?: @"", info.title ?: @""]);
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"https://genius.com/api/search/song?q=%@&page=1&per_page=10", query]];
    [[[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            completion(nil, error);
            return;
        }
        NSDictionary *json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSArray *hits = json[@"response"][@"sections"][0][@"hits"];
        if (![hits isKindOfClass:[NSArray class]]) {
            completion(nil, nil);
            return;
        }
        NSDictionary *best = nil;
        CGFloat bestScore = 0;
        for (NSDictionary *hit in hits) {
            NSDictionary *result = hit[@"result"];
            NSString *title = result[@"title"];
            NSString *artist = result[@"primary_artist"][@"name"];
            NSString *path = result[@"path"];
            if (![path isKindOfClass:[NSString class]]) continue;
            CGFloat score = YTMULyricsSimilarity(info.title, title) * 1.4 + YTMULyricsSimilarity(info.artist, artist) * 0.8;
            if (score > bestScore) {
                bestScore = score;
                best = result;
            }
        }
        NSString *path = best[@"path"];
        if (!path.length || bestScore < 0.75) {
            completion(nil, nil);
            return;
        }
        NSURL *pageURL = [NSURL URLWithString:[@"https://genius.com" stringByAppendingString:path]];
        [[[NSURLSession sharedSession] dataTaskWithURL:pageURL completionHandler:^(NSData *htmlData, NSURLResponse *htmlResponse, NSError *htmlError) {
            NSString *html = htmlData ? [[NSString alloc] initWithData:htmlData encoding:NSUTF8StringEncoding] : @"";
            NSString *lyrics = [self extractLyricsFromHTML:html];
            if (!lyrics.length || [[lyrics.lowercaseString stringByReplacingOccurrencesOfString:@"[" withString:@""] containsString:@"instrumental"]) {
                completion(nil, htmlError);
                return;
            }
            YTMULyricsResult *result = [[YTMULyricsResult alloc] init];
            result.sourceName = [self providerName];
            result.title = [best[@"title"] isKindOfClass:[NSString class]] ? best[@"title"] : info.title;
            NSString *artist = best[@"primary_artist"][@"name"];
            result.artists = artist.length ? @[artist] : (info.artist.length ? @[info.artist] : @[]);
            result.plainLyrics = lyrics;
            result.duration = info.duration;
            completion(result, nil);
        }] resume];
    }] resume];
}

@end
