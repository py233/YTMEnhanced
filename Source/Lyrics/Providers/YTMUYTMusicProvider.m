#import "YTMUYTMusicProvider.h"
#import "../YTMULRCParser.h"

@implementation YTMUYTMusicProvider

- (NSString *)providerName {
    return YTMULyricsSourceYTMusic;
}

- (NSDictionary *)context {
    return @{@"client": @{@"clientName": @"WEB_REMIX", @"clientVersion": @"1.20240501.01.00"}};
}

- (void)postPath:(NSString *)path body:(NSDictionary *)body completion:(void(^)(NSDictionary *json, NSError *error))completion {
    NSString *url = [NSString stringWithFormat:@"https://music.youtube.com/youtubei/v1/%@?prettyPrint=false", path];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    request.HTTPMethod = @"POST";
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:@"https://music.youtube.com" forHTTPHeaderField:@"Origin"];
    [request setValue:@"https://music.youtube.com/" forHTTPHeaderField:@"Referer"];
    NSMutableDictionary *full = [body mutableCopy];
    full[@"context"] = [self context];
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:full options:0 error:nil];

    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            completion(nil, error);
            return;
        }
        NSInteger status = [(NSHTTPURLResponse *)response statusCode];
        if (status < 200 || status >= 300) {
            completion(nil, [NSError errorWithDomain:@"YTMUYTMusic" code:status userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"YTMusic HTTP %ld", (long)status]}]);
            return;
        }
        id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:&error] : nil;
        completion([json isKindOfClass:[NSDictionary class]] ? json : nil, error);
    }] resume];
}

- (NSString *)lyricsBrowseIdFromNext:(NSDictionary *)json {
    NSArray *tabs = YTMULyricsJSONArrayAtPath(json, @[@"contents", @"singleColumnMusicWatchNextResultsRenderer", @"tabbedRenderer", @"watchNextTabbedResultsRenderer", @"tabs"]);
    if (![tabs isKindOfClass:[NSArray class]]) return @"";
    for (id tab in tabs) {
        NSDictionary *browse = YTMULyricsJSONDictionaryAtPath(tab, @[@"tabRenderer", @"endpoint", @"browseEndpoint"]);
        NSString *pageType = YTMULyricsJSONStringAtPath(browse, @[@"browseEndpointContextSupportedConfigs", @"browseEndpointContextMusicConfig", @"pageType"]);
        if ([pageType isEqualToString:@"MUSIC_PAGE_TYPE_TRACK_LYRICS"]) {
            NSString *browseId = YTMULyricsJSONStringAtPath(browse, @[@"browseId"]);
            return [browseId isKindOfClass:[NSString class]] ? browseId : @"";
        }
    }
    return @"";
}

- (void)collectTimedLyricsFromNode:(id)node into:(NSMutableArray<NSDictionary *> *)found {
    if ([node isKindOfClass:[NSArray class]]) {
        NSArray *array = node;
        BOOL looksLikeTimed = NO;
        for (id item in array) {
            if ([item isKindOfClass:[NSDictionary class]] && [item[@"lyricLine"] isKindOfClass:[NSString class]]) {
                looksLikeTimed = YES;
                break;
            }
        }
        if (looksLikeTimed) [found addObject:@{@"items": array}];
        for (id item in array) [self collectTimedLyricsFromNode:item into:found];
    } else if ([node isKindOfClass:[NSDictionary class]]) {
        for (id value in [(NSDictionary *)node allValues]) [self collectTimedLyricsFromNode:value into:found];
    }
}

- (NSArray<NSDictionary *> *)findTimedLyricsArrays:(id)obj {
    NSMutableArray<NSDictionary *> *found = [NSMutableArray array];
    [self collectTimedLyricsFromNode:obj into:found];
    return found;
}

- (void)collectPlainLyricsFromNode:(id)node into:(NSMutableArray<NSString *> *)plainParts {
    if ([node isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = node;
        NSArray *runs = YTMULyricsJSONArrayAtPath(dict, @[@"musicDescriptionShelfRenderer", @"description", @"runs"]) ?:
                        YTMULyricsJSONArrayAtPath(dict, @[@"messageRenderer", @"text", @"runs"]);
        if ([runs isKindOfClass:[NSArray class]]) {
            for (id run in runs) {
                NSString *text = YTMULyricsJSONStringAtPath(run, @[@"text"]);
                if ([text isKindOfClass:[NSString class]]) [plainParts addObject:text];
            }
        }
        for (id value in dict.allValues) [self collectPlainLyricsFromNode:value into:plainParts];
    } else if ([node isKindOfClass:[NSArray class]]) {
        for (id value in (NSArray *)node) [self collectPlainLyricsFromNode:value into:plainParts];
    }
}

- (YTMULyricsResult *)resultFromBrowse:(NSDictionary *)json info:(YTMULyricsSearchInfo *)info {
    NSArray<NSDictionary *> *arrays = [self findTimedLyricsArrays:json];
    for (NSDictionary *wrapper in arrays) {
        NSArray *items = wrapper[@"items"];
        NSMutableArray<YTMULyricLine *> *lines = [NSMutableArray array];
        for (id item in items) {
            NSString *text = YTMULyricsJSONStringAtPath(item, @[@"lyricLine"]) ?: @"";
            NSDictionary *cue = YTMULyricsJSONDictionaryAtPath(item, @[@"cueRange"]);
            if (![cue isKindOfClass:[NSDictionary class]]) continue;
            NSTimeInterval start = [YTMULyricsJSONNumberAtPath(cue, @[@"startTimeMilliseconds"]) doubleValue];
            NSTimeInterval end = [YTMULyricsJSONNumberAtPath(cue, @[@"endTimeMilliseconds"]) doubleValue];
            if (end <= start) end = start + 2500;
            if ([text isEqualToString:@"♪"]) text = @"";
            NSInteger totalMs = (NSInteger)llround(start);
            NSString *time = [NSString stringWithFormat:@"%02ld:%02ld.%02ld",
                              (long)(totalMs / 60000),
                              (long)((totalMs % 60000) / 1000),
                              (long)((totalMs % 1000) / 10)];
            [lines addObject:[YTMULyricLine lineWithTime:time timeInMs:start durationMs:end - start text:[text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]]];
        }
        if (lines.count) {
            YTMULyricsResult *result = [[YTMULyricsResult alloc] init];
            result.sourceName = [self providerName];
            result.title = info.title;
            result.artists = info.artist.length ? @[info.artist] : @[];
            result.lines = lines;
            result.duration = info.duration;
            return result;
        }
    }

    NSMutableArray<NSString *> *plainParts = [NSMutableArray array];
    [self collectPlainLyricsFromNode:json into:plainParts];
    NSString *plain = [[plainParts componentsJoinedByString:@""] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([plain isEqualToString:@"Lyrics not available"] || !plain.length) return nil;

    YTMULyricsResult *result = [[YTMULyricsResult alloc] init];
    result.sourceName = [self providerName];
    result.title = info.title;
    result.artists = info.artist.length ? @[info.artist] : @[];
    result.plainLyrics = plain;
    result.duration = info.duration;
    return result.hasText ? result : nil;
}

- (void)searchWithInfo:(YTMULyricsSearchInfo *)info completion:(void (^)(YTMULyricsResult *, NSError *))completion {
    if (!info.videoId.length) {
        completion(nil, nil);
        return;
    }

    [self postPath:@"next" body:@{@"videoId": info.videoId} completion:^(NSDictionary *nextJSON, NSError *error) {
        NSString *browseId = error ? @"" : [self lyricsBrowseIdFromNext:nextJSON];
        if (!browseId.length) {
            completion(nil, error);
            return;
        }
        [self postPath:@"browse" body:@{@"browseId": browseId} completion:^(NSDictionary *browseJSON, NSError *browseError) {
            YTMULyricsResult *result = browseError ? nil : [self resultFromBrowse:browseJSON info:info];
            if (result) {
                YTMULyricsLog(@"YTMusic lyrics match videoId=%@ synced=%d lines=%lu",
                              info.videoId,
                              result.isSynced,
                              (unsigned long)result.lineTexts.count);
            }
            completion(result, browseError);
        }];
    }];
}

@end
