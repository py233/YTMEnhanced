#import "YTMULRCLibProvider.h"
#import "../YTMULRCParser.h"

@implementation YTMULRCLibProvider

- (NSString *)providerName {
    return YTMULyricsSourceLRCLib;
}

- (NSURLRequest *)requestForQuery:(NSDictionary<NSString *, NSString *> *)query {
    NSMutableArray *parts = [NSMutableArray array];
    [query enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *obj, BOOL *stop) {
        if (!obj.length) return;
        [parts addObject:[NSString stringWithFormat:@"%@=%@", key, YTMULyricsEncodeQuery(obj)]];
    }];
    NSString *url = [NSString stringWithFormat:@"https://lrclib.net/api/search?%@", [parts componentsJoinedByString:@"&"]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    [request setValue:@"YTMusicUltimate-Bilingual/1.0 (https://github.com/py233/YTMusicUltimate-Bilingual)" forHTTPHeaderField:@"User-Agent"];
    return request;
}

- (void)fetchQuery:(NSDictionary<NSString *, NSString *> *)query completion:(void(^)(NSArray<NSDictionary *> *items, NSError *error))completion {
    NSURLRequest *request = [self requestForQuery:query];
    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            completion(nil, error);
            return;
        }
        NSInteger status = [(NSHTTPURLResponse *)response statusCode];
        if (status < 200 || status >= 300) {
            completion(nil, [NSError errorWithDomain:@"YTMULRCLib" code:status userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"LRCLib HTTP %ld", (long)status]}]);
            return;
        }
        id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:&error] : nil;
        if (![json isKindOfClass:[NSArray class]]) {
            completion(nil, error ?: [NSError errorWithDomain:@"YTMULRCLib" code:1 userInfo:@{NSLocalizedDescriptionKey: @"LRCLib returned invalid JSON"}]);
            return;
        }
        completion(json, nil);
    }] resume];
}

- (BOOL)artist:(NSString *)artist matchesItemArtist:(NSString *)itemArtist tags:(NSArray<NSString *> *)tags {
    NSArray<NSString *> *artists = YTMULyricsSplitArtists(artist, tags);
    NSArray<NSString *> *itemArtists = YTMULyricsSplitArtists(itemArtist, nil);
    if (!artists.count || !itemArtists.count) return YES;

    CGFloat best = 0;
    for (NSString *a in artists) {
        for (NSString *b in itemArtists) {
            best = MAX(best, YTMULyricsSimilarity(a, b));
        }
    }
    return best > 0.82;
}

- (YTMULyricsResult *)bestResultFromItems:(NSArray<NSDictionary *> *)items info:(YTMULyricsSearchInfo *)info {
    NSDictionary *bestItem = nil;
    CGFloat bestScore = -CGFLOAT_MAX;
    BOOL hasDuration = isfinite(info.duration) && info.duration > 0;

    for (NSDictionary *item in items) {
        if (![item isKindOfClass:[NSDictionary class]]) continue;
        if ([item[@"instrumental"] boolValue]) continue;

        NSString *trackName = [item[@"trackName"] isKindOfClass:[NSString class]] ? item[@"trackName"] : @"";
        NSString *artistName = [item[@"artistName"] isKindOfClass:[NSString class]] ? item[@"artistName"] : @"";
        NSString *synced = [item[@"syncedLyrics"] isKindOfClass:[NSString class]] ? item[@"syncedLyrics"] : @"";
        NSString *plain = [item[@"plainLyrics"] isKindOfClass:[NSString class]] ? item[@"plainLyrics"] : @"";
        if (!synced.length && !plain.length) continue;
        if (![self artist:info.artist matchesItemArtist:artistName tags:info.tags]) continue;

        CGFloat titleScore = MAX(YTMULyricsSimilarity(info.title, trackName), YTMULyricsSimilarity(info.alternativeTitle, trackName));
        NSTimeInterval duration = [item[@"duration"] doubleValue];
        CGFloat durationScore = 0.2;
        if (hasDuration && duration > 0) {
            NSTimeInterval delta = fabs(duration - info.duration);
            if (delta > 15 && titleScore < 0.92) continue;
            durationScore = MAX(0, 1 - delta / 25.0);
        }

        CGFloat score = titleScore * 1.7 + durationScore * 0.45 + (synced.length ? 0.2 : 0);
        if (score > bestScore) {
            bestScore = score;
            bestItem = item;
        }
    }

    if (!bestItem) return nil;

    NSString *synced = [bestItem[@"syncedLyrics"] isKindOfClass:[NSString class]] ? bestItem[@"syncedLyrics"] : @"";
    NSString *plain = [bestItem[@"plainLyrics"] isKindOfClass:[NSString class]] ? bestItem[@"plainLyrics"] : @"";
    YTMULyricsResult *result = [[YTMULyricsResult alloc] init];
    result.sourceName = [self providerName];
    result.title = [bestItem[@"trackName"] isKindOfClass:[NSString class]] ? bestItem[@"trackName"] : info.title;
    NSString *artistName = [bestItem[@"artistName"] isKindOfClass:[NSString class]] ? bestItem[@"artistName"] : info.artist;
    result.artists = YTMULyricsSplitArtists(artistName, nil);
    result.plainLyrics = plain ?: @"";
    result.lines = synced.length ? [YTMULRCParser parseLRC:synced] : @[];
    result.duration = [bestItem[@"duration"] doubleValue];
    return result.hasText ? result : nil;
}

- (void)searchWithInfo:(YTMULyricsSearchInfo *)info completion:(void (^)(YTMULyricsResult *, NSError *))completion {
    NSDictionary *primary = @{
        @"artist_name": info.artist ?: @"",
        @"track_name": info.title ?: @"",
        @"album_name": info.album ?: @"",
    };
    [self fetchQuery:primary completion:^(NSArray<NSDictionary *> *items, NSError *error) {
        YTMULyricsResult *best = error ? nil : [self bestResultFromItems:items info:info];
        if (best) {
            YTMULyricsLog(@"LRCLib match title=%@ lines=%lu plain=%d",
                          best.title,
                          (unsigned long)best.lines.count,
                          best.plainLyrics.length > 0);
            completion(best, nil);
            return;
        }

        if (!YTMULyricsSettingsBool(@"lyricsShowInexact", YES)) {
            completion(nil, error);
            return;
        }

        NSString *fallbackTitle = info.alternativeTitle.length ? info.alternativeTitle : info.title;
        [self fetchQuery:@{@"q": fallbackTitle ?: @""} completion:^(NSArray<NSDictionary *> *fallbackItems, NSError *fallbackError) {
            YTMULyricsResult *fallback = fallbackError ? nil : [self bestResultFromItems:fallbackItems info:info];
            if (fallback) fallback.inexact = YES;
            completion(fallback, fallback ? nil : (fallbackError ?: error));
        }];
    }];
}

@end
