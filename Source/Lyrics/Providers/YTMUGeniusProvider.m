#import "YTMUGeniusProvider.h"

static const NSUInteger YTMUGeniusMaxUsableLines = 600;

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
    NSRegularExpression *tags = YTMULyricsCachedRegex(@"<[^>]+>", 0);
    NSString *stripped = [tags stringByReplacingMatchesInString:withBreaks options:0 range:NSMakeRange(0, withBreaks.length) withTemplate:@""];
    return [[self stringByDecodingHTML:stripped] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

- (NSString *)cleanExtractedLyrics:(NSString *)lyrics {
    NSArray<NSString *> *rawLines = [lyrics componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    NSRegularExpression *boilerplate = YTMULyricsCachedRegex(@"^(\\d+\\s*)?(contributors?|translations?|english|romanization|romanized|you might also like|embed|read more|lyrics)$|contributors?.*translations?.*romanization|^see .+ live|get tickets as low as|^\\d+embed$", NSRegularExpressionCaseInsensitive);
    for (NSString *raw in rawLines) {
        NSString *line = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        while ([line hasSuffix:@"\\"]) {
            line = [[line substringToIndex:line.length - 1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        }
        if (!line.length) continue;
        if ([line isEqualToString:@"\\"]) continue;
        if ([boilerplate firstMatchInString:line options:0 range:NSMakeRange(0, line.length)]) continue;
        [lines addObject:line];
    }
    return [lines componentsJoinedByString:@"\n"];
}

- (NSString *)decodeGeniusEscapedHTML:(NSString *)encoded {
    NSString *out = encoded ?: @"";
    out = [out stringByReplacingOccurrencesOfString:@"\\\\/" withString:@"/"];
    out = [out stringByReplacingOccurrencesOfString:@"\\\\n" withString:@"\n"];
    out = [out stringByReplacingOccurrencesOfString:@"\\n" withString:@"\n"];
    out = [out stringByReplacingOccurrencesOfString:@"\\'" withString:@"'"];
    out = [out stringByReplacingOccurrencesOfString:@"\\\"" withString:@"\""];
    out = [out stringByReplacingOccurrencesOfString:@"\\\\" withString:@"\\"];
    return out;
}

- (NSString *)extractLyricsFromPreloadedState:(NSString *)html {
    NSRegularExpression *stateRegex = YTMULyricsCachedRegex(@"__PRELOADED_STATE__\\s*=\\s*JSON\\.parse\\('(.*?)'\\);", NSRegularExpressionDotMatchesLineSeparators);
    NSTextCheckingResult *stateMatch = [stateRegex firstMatchInString:html options:0 range:NSMakeRange(0, html.length)];
    if (!stateMatch || stateMatch.numberOfRanges < 2) return @"";

    NSString *state = [html substringWithRange:[stateMatch rangeAtIndex:1]];
    state = [state stringByReplacingOccurrencesOfString:@"\\\"" withString:@"\""];
    NSRegularExpression *preload = YTMULyricsCachedRegex(@"body\"\\s*:\\s*\\{\\s*\"html\"\\s*:\\s*\"(.*?)\"\\s*,\\s*\"children\"", NSRegularExpressionDotMatchesLineSeparators);
    NSTextCheckingResult *match = [preload firstMatchInString:state options:0 range:NSMakeRange(0, state.length)];
    if (!match || match.numberOfRanges < 2) return @"";

    NSString *encoded = [state substringWithRange:[match rangeAtIndex:1]];
    NSString *plain = [self stripHTML:[self decodeGeniusEscapedHTML:encoded]];
    return [self cleanExtractedLyrics:plain];
}

- (NSString *)extractLyricsFromHTML:(NSString *)html {
    NSString *preloaded = [self extractLyricsFromPreloadedState:html];
    if (preloaded.length) return preloaded;

    NSRegularExpression *dataLyrics = YTMULyricsCachedRegex(@"<div[^>]+data-lyrics-container=\"true\"[^>]*>(.*?)</div>", NSRegularExpressionDotMatchesLineSeparators | NSRegularExpressionCaseInsensitive);
    NSArray<NSTextCheckingResult *> *matches = [dataLyrics matchesInString:html options:0 range:NSMakeRange(0, html.length)];
    NSMutableArray *parts = [NSMutableArray array];
    for (NSTextCheckingResult *match in matches) {
        NSString *fragment = [html substringWithRange:[match rangeAtIndex:1]];
        if ([fragment rangeOfString:@"data-exclude-from-selection" options:NSCaseInsensitiveSearch].location != NSNotFound) continue;
        NSString *plain = [self stripHTML:fragment];
        plain = [self cleanExtractedLyrics:plain];
        if (plain.length) [parts addObject:plain];
    }
    if (parts.count) return [parts componentsJoinedByString:@"\n"];
    return @"";
}

- (BOOL)isTranslationOrRomanizationHit:(NSDictionary *)result {
    NSString *title = YTMULyricsJSONStringAtPath(result, @[@"title"]) ?: @"";
    NSString *fullTitle = YTMULyricsJSONStringAtPath(result, @[@"full_title"]) ?: @"";
    NSString *artist = YTMULyricsJSONStringAtPath(result, @[@"primary_artist", @"name"]) ?: @"";
    NSString *path = YTMULyricsJSONStringAtPath(result, @[@"path"]) ?: @"";
    NSString *haystack = [@[title, fullTitle, artist, path] componentsJoinedByString:@" "].lowercaseString;
    return [haystack rangeOfString:@"romanization"].location != NSNotFound ||
           [haystack rangeOfString:@"romanized"].location != NSNotFound ||
           [haystack rangeOfString:@"translation"].location != NSNotFound ||
           [haystack rangeOfString:@"translations"].location != NSNotFound ||
           [artist.lowercaseString hasPrefix:@"genius "];
}

- (CGFloat)scoreSearchResult:(NSDictionary *)result info:(YTMULyricsSearchInfo *)info {
    NSString *title = YTMULyricsJSONStringAtPath(result, @[@"title"]) ?: @"";
    NSString *titleWithFeatured = YTMULyricsJSONStringAtPath(result, @[@"title_with_featured"]) ?: title;
    NSString *artist = YTMULyricsJSONStringAtPath(result, @[@"primary_artist", @"name"]) ?: @"";
    NSString *artistNames = YTMULyricsJSONStringAtPath(result, @[@"artist_names"]) ?: artist;
    NSString *path = YTMULyricsJSONStringAtPath(result, @[@"path"]) ?: @"";

    CGFloat titleScore = MAX(YTMULyricsSimilarity(info.title, title), YTMULyricsSimilarity(info.alternativeTitle, title));
    titleScore = MAX(titleScore, YTMULyricsSimilarity(info.title, titleWithFeatured));
    CGFloat artistScore = MAX(YTMULyricsSimilarity(info.artist, artist), YTMULyricsSimilarity(info.artist, artistNames));
    for (NSString *tag in info.tags ?: @[]) {
        artistScore = MAX(artistScore, MAX(YTMULyricsSimilarity(tag, artist), YTMULyricsSimilarity(tag, artistNames)));
    }

    CGFloat score = titleScore * 1.5 + artistScore * 0.9;
    if (path.length && ![self isTranslationOrRomanizationHit:result]) score += 0.25;
    if ([self isTranslationOrRomanizationHit:result]) score -= 1.4;
    if ([path hasSuffix:@"-lyrics"] && [path rangeOfString:@"-romanized-lyrics"].location == NSNotFound) score += 0.15;
    return score;
}

- (BOOL)lyricsTextLooksUsable:(NSString *)lyrics info:(YTMULyricsSearchInfo *)info {
    if (!lyrics.length) return NO;
    NSString *lower = lyrics.lowercaseString;
    if ([[lower stringByReplacingOccurrencesOfString:@"[" withString:@""] containsString:@"instrumental"]) return NO;

    NSArray<NSString *> *rawLines = [lyrics componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    for (NSString *raw in rawLines) {
        NSString *line = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (line.length) [lines addObject:line];
    }
    if (lines.count < 4) return NO;
    // A real song page tops out in the low hundreds of lines; thousands
    // means the container regex over-captured (page chrome, comments).
    // Rendering that would mean thousands of label stacks on the main
    // thread, so refuse it here.
    if (lines.count > YTMUGeniusMaxUsableLines) return NO;

    NSUInteger lyricLikeLines = 0;
    NSUInteger boilerplateLines = 0;
    NSRegularExpression *boilerplate = YTMULyricsCachedRegex(@"^(\\d+\\s*)?(contributors?|translations?|you might also like|embed|read more|lyrics)$|contributors?.*lyrics$|^see .+ live|get tickets as low as", NSRegularExpressionCaseInsensitive);
    for (NSUInteger idx = 0; idx < MIN((NSUInteger)8, lines.count); idx++) {
        NSString *line = lines[idx];
        if ([boilerplate firstMatchInString:line options:0 range:NSMakeRange(0, line.length)]) boilerplateLines++;
        if (line.length >= 8 && ![line.lowercaseString hasSuffix:@" lyrics"]) lyricLikeLines++;
    }

    NSString *compactLyrics = YTMULyricsCompactString([lines componentsJoinedByString:@" "]);
    NSString *compactTitle = YTMULyricsCompactString([NSString stringWithFormat:@"%@ lyrics", info.title ?: @""]);
    if (compactTitle.length && [compactLyrics isEqualToString:compactTitle]) return NO;
    if (boilerplateLines >= 2 && lyricLikeLines <= 3) return NO;
    return YES;
}

- (void)searchWithInfo:(YTMULyricsSearchInfo *)info completion:(void (^)(YTMULyricsResult *, NSError *))completion {
    NSString *query = YTMULyricsEncodeQuery([NSString stringWithFormat:@"%@ %@", info.artist ?: @"", info.title ?: @""]);
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"https://genius.com/api/search/song?q=%@&page=1&per_page=10", query]];
    // Genius's web API + page fetches are normally fast (<2s) but
    // genius.com can intermittently take 30s+ when their CDN slows
    // down. 8s timeout on each leg keeps the chain bounded.
    NSMutableURLRequest *searchRequest = [NSMutableURLRequest requestWithURL:url];
    searchRequest.timeoutInterval = 8.0;
    [[[NSURLSession sharedSession] dataTaskWithRequest:searchRequest completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            completion(nil, error);
            return;
        }
        id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSArray *hits = YTMULyricsJSONArrayAtPath(json, @[@"response", @"sections", @0, @"hits"]);
        if (![hits isKindOfClass:[NSArray class]]) {
            completion(nil, nil);
            return;
        }
        NSDictionary *best = nil;
        CGFloat bestScore = -CGFLOAT_MAX;
        for (id hit in hits) {
            NSDictionary *result = YTMULyricsJSONDictionaryAtPath(hit, @[@"result"]);
            NSString *path = YTMULyricsJSONStringAtPath(result, @[@"path"]);
            if (![path isKindOfClass:[NSString class]]) continue;
            CGFloat score = [self scoreSearchResult:result info:info];
            if (score > bestScore) {
                bestScore = score;
                best = result;
            }
        }
        NSString *path = YTMULyricsJSONStringAtPath(best, @[@"path"]);
        if (!path.length || bestScore < 0.75 || [self isTranslationOrRomanizationHit:best]) {
            completion(nil, nil);
            return;
        }
        NSURL *pageURL = [NSURL URLWithString:[@"https://genius.com" stringByAppendingString:path]];
        NSMutableURLRequest *pageRequest = [NSMutableURLRequest requestWithURL:pageURL];
        pageRequest.timeoutInterval = 8.0;
        [[[NSURLSession sharedSession] dataTaskWithRequest:pageRequest completionHandler:^(NSData *htmlData, NSURLResponse *htmlResponse, NSError *htmlError) {
            NSString *html = htmlData ? [[NSString alloc] initWithData:htmlData encoding:NSUTF8StringEncoding] : @"";
            NSString *lyrics = [self extractLyricsFromHTML:html];
            if (![self lyricsTextLooksUsable:lyrics info:info]) {
                YTMULyricsLog(@"Genius rejected non-lyric page title=%@ extracted=%@", info.title, [lyrics substringToIndex:MIN((NSUInteger)80, lyrics.length)] ?: @"");
                completion(nil, htmlError);
                return;
            }
            YTMULyricsResult *result = [[YTMULyricsResult alloc] init];
            result.sourceName = [self providerName];
            result.title = YTMULyricsJSONStringAtPath(best, @[@"title"]) ?: info.title;
            NSString *artist = YTMULyricsJSONStringAtPath(best, @[@"primary_artist", @"name"]);
            result.artists = artist.length ? @[artist] : (info.artist.length ? @[info.artist] : @[]);
            result.plainLyrics = lyrics;
            result.duration = info.duration;
            completion(result, nil);
        }] resume];
    }] resume];
}

@end
