#import "YTMULRCLibProvider.h"
#import "../YTMULRCParser.h"

static BOOL YTMULRCLibRegexTest(NSString *value, NSString *pattern) {
    return [value rangeOfString:pattern options:NSRegularExpressionSearch | NSCaseInsensitiveSearch].location != NSNotFound;
}

static BOOL YTMULRCLibHasJapaneseOrCJK(NSString *value) {
    return [value rangeOfString:@"[\\u3040-\\u30ff\\u3400-\\u9fff]" options:NSRegularExpressionSearch].location != NSNotFound;
}

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

- (NSString *)cleanTitleFragment:(NSString *)fragment {
    NSString *clean = YTMULyricsStripSearchNoise(fragment ?: @"");
    NSRegularExpression *spaces = [NSRegularExpression regularExpressionWithPattern:@"\\s+" options:0 error:nil];
    clean = [spaces stringByReplacingMatchesInString:clean options:0 range:NSMakeRange(0, clean.length) withTemplate:@" "];
    return [clean stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

- (NSArray<NSString *> *)splitTitleCandidatesForInfo:(YTMULyricsSearchInfo *)info {
    NSMutableArray<NSString *> *titles = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    void (^addTitle)(NSString *) = ^(NSString *title) {
        NSString *clean = [self cleanTitleFragment:title];
        NSString *key = YTMULyricsCompactString(clean);
        if (key.length <= 1 || [seen containsObject:key]) return;
        if (YTMULRCLibRegexTest(clean, @"\\b(?:official|music\\s*video|mv|pv|lyric|audio)\\b")) return;
        [seen addObject:key];
        [titles addObject:clean];
    };

    for (NSString *source in @[info.title ?: @"", info.alternativeTitle ?: @""]) {
        if (!source.length) continue;
        addTitle(source);

        NSRegularExpression *quoted = [NSRegularExpression regularExpressionWithPattern:@"[「『](.+?)[」』]"
                                                                                options:0
                                                                                  error:nil];
        for (NSTextCheckingResult *match in [quoted matchesInString:source options:0 range:NSMakeRange(0, source.length)]) {
            if (match.numberOfRanges >= 2) addTitle([source substringWithRange:[match rangeAtIndex:1]]);
        }

        NSRegularExpression *delimiter = [NSRegularExpression regularExpressionWithPattern:@"\\s+[-–—]\\s+|\\s+[/|]\\s+|[／｜│]|\\s+:\\s+|[：]"
                                                                                  options:0
                                                                                    error:nil];
        NSString *split = [delimiter stringByReplacingMatchesInString:source options:0 range:NSMakeRange(0, source.length) withTemplate:@"\n"];
        for (NSString *part in [split componentsSeparatedByString:@"\n"]) addTitle(part);
    }
    return titles;
}

- (CGFloat)bestTitleScoreForTrackName:(NSString *)trackName info:(YTMULyricsSearchInfo *)info {
    CGFloat best = MAX(YTMULyricsSimilarity(info.title, trackName), YTMULyricsSimilarity(info.alternativeTitle, trackName));
    for (NSString *candidate in [self splitTitleCandidatesForInfo:info]) {
        CGFloat weight = YTMULRCLibHasJapaneseOrCJK(candidate) ? 1.08 : 1.0;
        best = MAX(best, MIN((CGFloat)1.0, YTMULyricsSimilarity(candidate, trackName) * weight));
    }
    return best;
}

- (CGFloat)artistScore:(NSString *)artist itemArtist:(NSString *)itemArtist tags:(NSArray<NSString *> *)tags {
    NSArray<NSString *> *artists = YTMULyricsSplitArtists(artist, tags);
    NSArray<NSString *> *itemArtists = YTMULyricsSplitArtists(itemArtist, nil);
    if (!artists.count || !itemArtists.count) return 0.5;

    CGFloat best = 0;
    for (NSString *a in artists) {
        for (NSString *b in itemArtists) {
            best = MAX(best, YTMULyricsSimilarity(a, b));
        }
    }
    return best;
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

        CGFloat titleScore = [self bestTitleScoreForTrackName:trackName info:info];
        NSTimeInterval duration = [item[@"duration"] doubleValue];
        NSTimeInterval delta = 0;
        CGFloat durationScore = 0.2;
        if (hasDuration && duration > 0) {
            delta = fabs(duration - info.duration);
            if (delta > 15 && titleScore < 0.92) continue;
            durationScore = MAX(0, 1 - delta / 25.0);
        }
        CGFloat artistScore = [self artistScore:info.artist itemArtist:artistName tags:info.tags];
        BOOL artistAcceptedByTitleAndDuration = titleScore >= 0.92 && (!hasDuration || delta <= 15);
        if (artistScore <= 0.82 && !artistAcceptedByTitleAndDuration) continue;

        CGFloat score = titleScore * 1.7 + artistScore * 0.5 + durationScore * 0.45 + (synced.length ? 0.2 : 0);
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

        NSMutableArray<NSString *> *queries = [NSMutableArray array];
        NSMutableSet<NSString *> *seen = [NSMutableSet set];
        for (NSString *candidate in [self splitTitleCandidatesForInfo:info]) {
            NSString *key = YTMULyricsCompactString(candidate);
            if (!key.length || [seen containsObject:key]) continue;
            [seen addObject:key];
            [queries addObject:candidate];
            if (queries.count >= 6) break;
        }
        if (!queries.count && info.title.length) [queries addObject:info.title];
        [self fetchFallbackQueries:queries index:0 originalError:error info:info completion:completion];
    }];
}

- (void)fetchFallbackQueries:(NSArray<NSString *> *)queries
                       index:(NSUInteger)index
               originalError:(NSError *)originalError
                        info:(YTMULyricsSearchInfo *)info
                  completion:(void (^)(YTMULyricsResult *, NSError *))completion {
    if (index >= queries.count) {
        completion(nil, originalError);
        return;
    }
    NSString *query = queries[index];
    [self fetchQuery:@{@"q": query ?: @""} completion:^(NSArray<NSDictionary *> *fallbackItems, NSError *fallbackError) {
        YTMULyricsResult *fallback = fallbackError ? nil : [self bestResultFromItems:fallbackItems info:info];
        if (fallback) {
            fallback.inexact = YES;
            completion(fallback, nil);
            return;
        }
        [self fetchFallbackQueries:queries index:index + 1 originalError:(fallbackError ?: originalError) info:info completion:completion];
    }];
}

@end
