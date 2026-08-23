#import "YTMULRCLibProvider.h"
#import "../YTMULRCParser.h"
#import "../../Utils/NSBundle+YTMU.h"

static BOOL YTMULRCLibRegexTest(NSString *value, NSString *pattern) {
    return YTMULyricsRegexMatches(value, pattern, NSRegularExpressionCaseInsensitive);
}

static BOOL YTMULRCLibHasJapaneseOrCJK(NSString *value) {
    return YTMULyricsRegexMatches(value, @"[\\u3040-\\u30ff\\u3400-\\u9fff]", 0);
}

@implementation YTMULRCLibProvider

- (NSString *)providerName {
    return YTMULyricsSourceLRCLib;
}

// Per-request timeout cap. The actual timeout used per request is the
// MIN of this and whatever the global deadline still allows — the prior
// hard 5s value let the request occupy 5s even when the chain only had
// 1s of budget left, blowing past the deadline by 4s.
static const NSTimeInterval YTMULRCLibPerRequestTimeoutCap = 5.0;

// Global deadline for the whole searchWithInfo. With dynamic per-request
// timeouts (see fetchQuery:withTimeout:) the overall searchWithInfo now
// finishes within ~deadline + 0.5s for connect-setup overhead, instead
// of the old behavior where the last fallback could happily run for a
// full 5s past deadline.
static const NSTimeInterval YTMULRCLibTotalDeadline = 6.0;

// Cap on fallback-query count. Three is enough to cover the common
// title-fragment splits; more just burns budget without raising hit rate.
// LRCLib's primary structured query (artist/track/album) is what really
// matters — fallbacks only catch corner cases where the title has noise.
static const NSUInteger YTMULRCLibMaxFallbackQueries = 2;

- (NSURLRequest *)requestForQuery:(NSDictionary<NSString *, NSString *> *)query withTimeout:(NSTimeInterval)timeout {
    NSMutableArray *parts = [NSMutableArray array];
    [query enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *obj, BOOL *stop) {
        if (!obj.length) return;
        [parts addObject:[NSString stringWithFormat:@"%@=%@", key, YTMULyricsEncodeQuery(obj)]];
    }];
    NSString *url = [NSString stringWithFormat:@"https://lrclib.net/api/search?%@", [parts componentsJoinedByString:@"&"]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    [request setValue:@"YTMEnhanced/1.0 (https://github.com/py233/YTMEnhanced)" forHTTPHeaderField:@"User-Agent"];
    request.timeoutInterval = timeout;
    return request;
}

- (void)fetchQuery:(NSDictionary<NSString *, NSString *> *)query
        withTimeout:(NSTimeInterval)timeout
         completion:(void(^)(NSArray<NSDictionary *> *items, NSError *error))completion {
    NSURLRequest *request = [self requestForQuery:query withTimeout:timeout];
    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            completion(nil, error);
            return;
        }
        NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]]
                               ? [(NSHTTPURLResponse *)response statusCode] : 0;
        if (status < 200 || status >= 300) {
            completion(nil, [NSError errorWithDomain:@"YTMULRCLib" code:status userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:YTMULocalized(@"LYRICS_ERROR_HTTP_STATUS_FORMAT", @"HTTP %ld"), (long)status]}]);
            return;
        }
        id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:&error] : nil;
        if (![json isKindOfClass:[NSArray class]]) {
            completion(nil, error ?: [NSError errorWithDomain:@"YTMULRCLib" code:1 userInfo:@{NSLocalizedDescriptionKey: YTMULocalized(@"LYRICS_ERROR_LRCLIB_BAD_JSON", @"LRCLIB returned invalid JSON")}]);
            return;
        }
        completion(json, nil);
    }] resume];
}

- (NSString *)cleanTitleFragment:(NSString *)fragment {
    NSString *clean = YTMULyricsStripSearchNoise(fragment ?: @"");
    NSRegularExpression *spaces = YTMULyricsCachedRegex(@"\\s+", 0);
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

        NSRegularExpression *quoted = YTMULyricsCachedRegex(@"[「『](.+?)[」』]", 0);
        for (NSTextCheckingResult *match in [quoted matchesInString:source options:0 range:NSMakeRange(0, source.length)]) {
            if (match.numberOfRanges >= 2) addTitle([source substringWithRange:[match rangeAtIndex:1]]);
        }

        NSRegularExpression *delimiter = YTMULyricsCachedRegex(@"\\s+[-–—]\\s+|\\s+[/|]\\s+|[／｜│]|\\s+:\\s+|[：]", 0);
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
        // LRCLIB emits JSON null for fields user submissions left blank — which is
        // why every string field below is isKindOfClass:-checked. The numeric ones
        // need the same care: NSNull responds to neither boolValue nor doubleValue,
        // so a bare send here aborts the process from the URLSession callback.
        if ([YTMULyricsJSONNumberAtPath(item, @[@"instrumental"]) boolValue]) continue;

        NSString *trackName = [item[@"trackName"] isKindOfClass:[NSString class]] ? item[@"trackName"] : @"";
        NSString *artistName = [item[@"artistName"] isKindOfClass:[NSString class]] ? item[@"artistName"] : @"";
        NSString *synced = [item[@"syncedLyrics"] isKindOfClass:[NSString class]] ? item[@"syncedLyrics"] : @"";
        NSString *plain = [item[@"plainLyrics"] isKindOfClass:[NSString class]] ? item[@"plainLyrics"] : @"";
        if (!synced.length && !plain.length) continue;

        CGFloat titleScore = [self bestTitleScoreForTrackName:trackName info:info];
        NSTimeInterval duration = [YTMULyricsJSONNumberAtPath(item, @[@"duration"]) doubleValue];
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
    result.duration = [YTMULyricsJSONNumberAtPath(bestItem, @[@"duration"]) doubleValue];
    return result.hasText ? result : nil;
}

- (NSTimeInterval)remainingBudgetFromStart:(NSDate *)startedAt {
    NSTimeInterval elapsed = [[NSDate date] timeIntervalSinceDate:startedAt];
    return YTMULRCLibTotalDeadline - elapsed;
}

- (void)searchWithInfo:(YTMULyricsSearchInfo *)info completion:(void (^)(YTMULyricsResult *, NSError *))completion {
    NSDate *startedAt = [NSDate date];
    NSDictionary *primary = @{
        @"artist_name": info.artist ?: @"",
        @"track_name": info.title ?: @"",
        @"album_name": info.album ?: @"",
    };
    NSTimeInterval primaryTimeout = MIN(YTMULRCLibPerRequestTimeoutCap, [self remainingBudgetFromStart:startedAt]);
    [self fetchQuery:primary withTimeout:primaryTimeout completion:^(NSArray<NSDictionary *> *items, NSError *error) {
        YTMULyricsResult *best = error ? nil : [self bestResultFromItems:items info:info];
        if (best) {
            YTMULyricsLog(@"LRCLIB match title=%@ lines=%lu plain=%d",
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
            if (queries.count >= YTMULRCLibMaxFallbackQueries) break;
        }
        if (!queries.count && info.title.length) [queries addObject:info.title];
        [self fetchFallbackQueries:queries
                             index:0
                     originalError:error
                              info:info
                         startedAt:startedAt
                        completion:completion];
    }];
}

- (void)fetchFallbackQueries:(NSArray<NSString *> *)queries
                       index:(NSUInteger)index
               originalError:(NSError *)originalError
                        info:(YTMULyricsSearchInfo *)info
                   startedAt:(NSDate *)startedAt
                  completion:(void (^)(YTMULyricsResult *, NSError *))completion {
    if (index >= queries.count) {
        completion(nil, originalError);
        return;
    }
    // Bail out of the fallback chain if we've already burned the global
    // deadline OR if there's so little time left that the next request
    // wouldn't have a meaningful shot anyway. The caller will treat us
    // as a miss and let the rest of the pipeline (other providers, AI
    // normalizer) do its thing.
    NSTimeInterval remaining = [self remainingBudgetFromStart:startedAt];
    if (remaining < 0.8) {
        NSTimeInterval elapsed = YTMULRCLibTotalDeadline - remaining;
        YTMULyricsLog(@"LRCLIB deadline reached after %.1fs (%lu of %lu fallbacks attempted) — giving up",
                      elapsed,
                      (unsigned long)index,
                      (unsigned long)queries.count);
        completion(nil, originalError ?: [NSError errorWithDomain:@"YTMULRCLib"
                                                              code:NSURLErrorTimedOut
                                                          userInfo:@{NSLocalizedDescriptionKey: YTMULocalized(@"LYRICS_ERROR_LRCLIB_TIMEOUT", @"LRCLIB deadline exceeded")}]);
        return;
    }
    NSString *query = queries[index];
    NSTimeInterval queryTimeout = MIN(YTMULRCLibPerRequestTimeoutCap, remaining);
    [self fetchQuery:@{@"q": query ?: @""} withTimeout:queryTimeout completion:^(NSArray<NSDictionary *> *fallbackItems, NSError *fallbackError) {
        YTMULyricsResult *fallback = fallbackError ? nil : [self bestResultFromItems:fallbackItems info:info];
        if (fallback) {
            fallback.inexact = YES;
            completion(fallback, nil);
            return;
        }
        [self fetchFallbackQueries:queries
                             index:index + 1
                     originalError:(fallbackError ?: originalError)
                              info:info
                         startedAt:startedAt
                        completion:completion];
    }];
}

@end
