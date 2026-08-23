#import "YTMUMusixMatchProvider.h"
#import "../YTMULRCParser.h"
#import "../../Utils/NSBundle+YTMU.h"

@interface YTMUMusixMatchProvider ()
// atomic: written from NSURLSession's completion queue, read from whichever
// thread starts the next search.
@property (atomic, copy) NSString *cookie;
@property (atomic, copy) NSString *token;
@property (atomic) NSTimeInterval tokenExpiresAt;
@end

@implementation YTMUMusixMatchProvider

- (instancetype)init {
    self = [super init];
    if (self) {
        _cookie = @"x-mxm-user-id=";
        _token = @"";
    }
    return self;
}

- (NSString *)providerName {
    return YTMULyricsSourceMusixMatch;
}

- (void)captureCookie:(NSHTTPURLResponse *)response {
    NSString *cookie = response.allHeaderFields[@"Set-Cookie"] ?: response.allHeaderFields[@"set-cookie"];
    if ([cookie isKindOfClass:[NSString class]] && cookie.length) self.cookie = cookie;
}

- (void)getToken:(void(^)(NSString *token, NSError *error))completion {
    if (self.token.length && self.tokenExpiresAt > [[NSDate date] timeIntervalSince1970]) {
        completion(self.token, nil);
        return;
    }

    NSURL *url = [NSURL URLWithString:@"https://apic-desktop.musixmatch.com/ws/1.1/token.get?app_id=web-desktop-app-v1.0"];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.timeoutInterval = 8.0; // bound a stuck token-fetch call
    [request setValue:self.cookie forHTTPHeaderField:@"Cookie"];
    [request setValue:@"apic-desktop.musixmatch.com" forHTTPHeaderField:@"Authority"];
    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            completion(@"", error);
            return;
        }
        if ([response isKindOfClass:[NSHTTPURLResponse class]]) [self captureCookie:(NSHTTPURLResponse *)response];
        id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSString *token = YTMULyricsJSONStringAtPath(json, @[@"message", @"body", @"user_token"]);
        if (!token.length) {
            completion(@"", [NSError errorWithDomain:@"YTMUMusixMatch" code:1 userInfo:@{NSLocalizedDescriptionKey: YTMULocalized(@"LYRICS_ERROR_MUSIXMATCH_NO_TOKEN", @"Musixmatch token not initialized")}]);
            return;
        }
        self.token = token;
        self.tokenExpiresAt = [[NSDate date] timeIntervalSince1970] + 55;
        completion(token, nil);
    }] resume];
}

- (void)queryMacroWithInfo:(YTMULyricsSearchInfo *)info token:(NSString *)token completion:(void(^)(NSDictionary *json, NSError *error))completion {
    NSMutableDictionary *params = [@{
        @"app_id": @"web-desktop-app-v1.0",
        @"format": @"json",
        @"usertoken": token ?: @"",
        @"q_track": info.alternativeTitle.length ? info.alternativeTitle : info.title ?: @"",
        @"q_artist": info.artist ?: @"",
        @"q_duration": [NSString stringWithFormat:@"%ld", (long)llround(info.duration)],
        @"namespace": @"lyrics_richsynched",
        @"subtitle_format": @"lrc",
    } mutableCopy];
    if (info.album.length) params[@"q_album"] = info.album;

    NSMutableArray *parts = [NSMutableArray array];
    [params enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *obj, BOOL *stop) {
        [parts addObject:[NSString stringWithFormat:@"%@=%@", key, YTMULyricsEncodeQuery(obj)]];
    }];
    NSString *url = [NSString stringWithFormat:@"https://apic-desktop.musixmatch.com/ws/1.1/macro.subtitles.get?%@", [parts componentsJoinedByString:@"&"]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    request.timeoutInterval = 8.0; // bound a stuck subtitles call
    [request setValue:self.cookie forHTTPHeaderField:@"Cookie"];
    [request setValue:@"apic-desktop.musixmatch.com" forHTTPHeaderField:@"Authority"];
    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            completion(nil, error);
            return;
        }
        if ([response isKindOfClass:[NSHTTPURLResponse class]]) [self captureCookie:(NSHTTPURLResponse *)response];
        id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:&error] : nil;
        if (json && ![json isKindOfClass:[NSDictionary class]]) {
            completion(nil, [NSError errorWithDomain:@"YTMUMusixMatch" code:2 userInfo:@{NSLocalizedDescriptionKey: YTMULocalized(@"LYRICS_ERROR_MUSIXMATCH_BAD_JSON", @"Musixmatch returned invalid JSON")}]);
            return;
        }
        completion((NSDictionary *)json, error);
    }] resume];
}

- (YTMULyricsResult *)resultFromJSON:(NSDictionary *)json info:(YTMULyricsSearchInfo *)info {
    NSDictionary *macro = YTMULyricsJSONDictionaryAtPath(json, @[@"message", @"body", @"macro_calls"]);
    NSDictionary *track = YTMULyricsJSONDictionaryAtPath(macro, @[@"matcher.track.get", @"message", @"body", @"track"]);
    NSDictionary *lyrics = YTMULyricsJSONDictionaryAtPath(macro, @[@"track.lyrics.get", @"message", @"body", @"lyrics"]);
    NSArray *subs = YTMULyricsJSONArrayAtPath(macro, @[@"track.subtitles.get", @"message", @"body", @"subtitle_list"]);
    if (![track isKindOfClass:[NSDictionary class]]) return nil;
    if ([YTMULyricsJSONNumberAtPath(track, @[@"track_id"]) integerValue] == 115264642) return nil;

    NSString *trackName = YTMULyricsJSONStringAtPath(track, @[@"track_name"]) ?: info.title;
    NSString *artistName = YTMULyricsJSONStringAtPath(track, @[@"artist_name"]) ?: info.artist;
    CGFloat score = YTMULyricsSimilarity(trackName, info.title) * 1.5 + YTMULyricsSimilarity(artistName, info.artist) * 0.7;
    if (score < 0.75) return nil;

    NSString *plain = YTMULyricsJSONStringAtPath(lyrics, @[@"lyrics_body"]) ?: @"";
    NSString *lrc = @"";
    if ([subs isKindOfClass:[NSArray class]] && subs.count) {
        lrc = YTMULyricsJSONStringAtPath(subs, @[@0, @"subtitle", @"subtitle_body"]) ?: @"";
    }
    if (!plain.length && !lrc.length) return nil;

    YTMULyricsResult *result = [[YTMULyricsResult alloc] init];
    result.sourceName = [self providerName];
    result.title = trackName;
    result.artists = artistName.length ? @[artistName] : @[];
    result.plainLyrics = plain;
    result.lines = lrc.length ? [YTMULRCParser parseLRC:lrc] : @[];
    result.duration = info.duration;
    return result.hasText ? result : nil;
}

- (void)searchWithInfo:(YTMULyricsSearchInfo *)info completion:(void (^)(YTMULyricsResult *, NSError *))completion {
    [self getToken:^(NSString *token, NSError *error) {
        if (error) {
            completion(nil, error);
            return;
        }
        [self queryMacroWithInfo:info token:token completion:^(NSDictionary *json, NSError *queryError) {
            YTMULyricsResult *result = queryError ? nil : [self resultFromJSON:json info:info];
            if (result) {
                YTMULyricsLog(@"Musixmatch match title=%@ synced=%d lines=%lu",
                              result.title,
                              result.isSynced,
                              (unsigned long)result.lineTexts.count);
            }
            completion(result, queryError);
        }];
    }];
}

@end
