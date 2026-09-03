#import "YTMULastFMScrobbler.h"
#import <CommonCrypto/CommonDigest.h>

static NSString *const kLastFMBaseURL = @"https://ws.audioscrobbler.com/2.0/";

// last.fm batch limit per scrobble call.
static const NSUInteger kLastFMBatchMax = 50;

@implementation YTMULastFMSearchResult

- (instancetype)initWithTrack:(NSString *)track
                       artist:(NSString *)artist
                         mbid:(NSString *)mbid
                    listeners:(NSInteger)listeners {
    self = [super init];
    if (self) {
        _track = [track copy];
        _artist = [artist copy];
        _mbid = [mbid copy];
        _listeners = listeners;
    }
    return self;
}

@end

#pragma mark - Helpers

static NSString *YTMULastFMMD5(NSString *input) {
    const char *cstr = [input UTF8String];
    if (!cstr) return @"";
    unsigned char digest[CC_MD5_DIGEST_LENGTH];
    CC_MD5(cstr, (CC_LONG)strlen(cstr), digest);
    NSMutableString *out = [NSMutableString stringWithCapacity:CC_MD5_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_MD5_DIGEST_LENGTH; i++) {
        [out appendFormat:@"%02x", digest[i]];
    }
    return out;
}

// last.fm signs every authenticated call with:
//   md5( concat(sortedKeys, sortedValues) + secret )
// where sorted means UTF-8 byte-sorted keys, "format" field excluded.
// See https://www.last.fm/api/desktopauth and the desktop fork's
// `scrobbler/services/lastfm.ts` :: createApiSig (verified shape match).
NSString *YTMULastFMSignParams(NSDictionary<NSString *, NSString *> *params, NSString *secret) {
    NSMutableArray<NSString *> *keys = [[params allKeys] mutableCopy];
    [keys removeObject:@"format"];
    [keys sortUsingSelector:@selector(compare:)];
    NSMutableString *concat = [NSMutableString string];
    for (NSString *key in keys) {
        [concat appendString:key];
        [concat appendString:params[key] ?: @""];
    }
    [concat appendString:secret ?: @""];
    return YTMULastFMMD5(concat);
}

static NSString *YTMULastFMURLEncode(NSString *value) {
    NSMutableCharacterSet *allowed = [NSCharacterSet.URLQueryAllowedCharacterSet mutableCopy];
    [allowed removeCharactersInString:@"&=+?#"];
    return [value stringByAddingPercentEncodingWithAllowedCharacters:allowed] ?: @"";
}

static NSData *YTMULastFMFormBody(NSDictionary<NSString *, NSString *> *params) {
    NSMutableArray<NSString *> *pairs = [NSMutableArray arrayWithCapacity:params.count];
    for (NSString *key in params) {
        [pairs addObject:[NSString stringWithFormat:@"%@=%@", YTMULastFMURLEncode(key), YTMULastFMURLEncode(params[key])]];
    }
    return [[pairs componentsJoinedByString:@"&"] dataUsingEncoding:NSUTF8StringEncoding];
}

static NSError *YTMULastFMError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"YTMULastFM"
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: message ?: @"last.fm error"}];
}

#pragma mark - YTMULastFMScrobbler

@implementation YTMULastFMScrobbler

- (NSString *)identifier {
    return @"lastfm";
}

#pragma mark Settings accessors

- (NSString *)apiKey {
    return YTMUScrobbleDefaultsString(@"lastfm_apiKey", @"");
}

- (NSString *)apiSecret {
    return YTMUScrobbleDefaultsString(@"lastfm_apiSecret", @"");
}

- (NSString *)sessionKey {
    return YTMUScrobbleDefaultsString(@"lastfm_sessionKey", @"");
}

- (nullable NSString *)authenticatedUsername {
    NSString *name = YTMUScrobbleDefaultsString(@"lastfm_username", @"");
    return name.length ? name : nil;
}

- (BOOL)isEnabled {
    return YTMUScrobbleDefaultsBool(@"lastfm_enabled", NO);
}

- (BOOL)isConfigured {
    return self.apiKey.length > 0 && self.apiSecret.length > 0 && self.sessionKey.length > 0;
}

#pragma mark - Auth flow

- (void)fetchAuthTokenWithCompletion:(void (^)(NSString *_Nullable, NSError *_Nullable))completion {
    NSString *apiKey = self.apiKey;
    NSString *apiSecret = self.apiSecret;
    if (!apiKey.length || !apiSecret.length) {
        completion(nil, YTMULastFMError(1001, @"API key/secret missing"));
        return;
    }
    NSDictionary<NSString *, NSString *> *params = @{
        @"method": @"auth.getToken",
        @"api_key": apiKey,
    };
    NSString *sig = YTMULastFMSignParams(params, apiSecret);
    NSString *url = [NSString stringWithFormat:@"%@?method=auth.getToken&api_key=%@&api_sig=%@&format=json",
                     kLastFMBaseURL, YTMULastFMURLEncode(apiKey), YTMULastFMURLEncode(sig)];
    [self performJSONRequest:[NSURL URLWithString:url]
                      method:@"GET"
                        body:nil
                  completion:^(NSDictionary *json, NSError *error) {
        if (error) { completion(nil, error); return; }
        NSString *token = [json[@"token"] isKindOfClass:[NSString class]] ? json[@"token"] : nil;
        if (!token.length) { completion(nil, YTMULastFMError(1002, @"No token in response")); return; }
        completion(token, nil);
    }];
}

- (void)fetchSessionWithToken:(NSString *)token
                   completion:(void (^)(NSString *_Nullable, NSError *_Nullable))completion {
    NSString *apiKey = self.apiKey;
    NSString *apiSecret = self.apiSecret;
    if (!apiKey.length || !apiSecret.length) {
        completion(nil, YTMULastFMError(1001, @"API key/secret missing"));
        return;
    }
    NSDictionary<NSString *, NSString *> *params = @{
        @"method": @"auth.getSession",
        @"api_key": apiKey,
        @"token": token ?: @"",
    };
    NSString *sig = YTMULastFMSignParams(params, apiSecret);
    NSString *url = [NSString stringWithFormat:@"%@?method=auth.getSession&api_key=%@&token=%@&api_sig=%@&format=json",
                     kLastFMBaseURL,
                     YTMULastFMURLEncode(apiKey),
                     YTMULastFMURLEncode(token),
                     YTMULastFMURLEncode(sig)];
    [self performJSONRequest:[NSURL URLWithString:url]
                      method:@"GET"
                        body:nil
                  completion:^(NSDictionary *json, NSError *error) {
        if (error) { completion(nil, error); return; }
        NSDictionary *session = [json[@"session"] isKindOfClass:[NSDictionary class]] ? json[@"session"] : nil;
        NSString *sk = [session[@"key"] isKindOfClass:[NSString class]] ? session[@"key"] : nil;
        NSString *name = [session[@"name"] isKindOfClass:[NSString class]] ? session[@"name"] : nil;
        if (!sk.length || !name.length) {
            completion(nil, YTMULastFMError(1003, @"No session in response"));
            return;
        }
        YTMUScrobbleSetDefaults(@"lastfm_sessionKey", sk);
        YTMUScrobbleSetDefaults(@"lastfm_username", name);
        completion(name, nil);
    }];
}

- (void)signOut {
    YTMUScrobbleSetDefaults(@"lastfm_sessionKey", nil);
    YTMUScrobbleSetDefaults(@"lastfm_username", nil);
}

#pragma mark - Search

- (void)searchTrack:(NSString *)track
             artist:(NSString *)artist
              limit:(NSUInteger)limit
         completion:(void (^)(NSArray<YTMULastFMSearchResult *> *_Nullable, NSError *_Nullable))completion {
    NSString *apiKey = self.apiKey;
    if (!apiKey.length) {
        completion(nil, YTMULastFMError(1010, @"API key missing — search skipped"));
        return;
    }
    if (!track.length) {
        completion(nil, YTMULastFMError(1011, @"track required"));
        return;
    }
    NSUInteger effectiveLimit = limit == 0 ? 5 : MIN(limit, (NSUInteger)10);
    // track.search supports filtering by artist; we pass it when we
    // have one to improve recall on common track titles.
    // https://www.last.fm/api/show/track.search
    NSMutableString *url = [NSMutableString stringWithFormat:
                            @"%@?method=track.search&api_key=%@&format=json&limit=%lu&track=%@",
                            kLastFMBaseURL,
                            YTMULastFMURLEncode(apiKey),
                            (unsigned long)effectiveLimit,
                            YTMULastFMURLEncode(track)];
    if (artist.length) {
        [url appendFormat:@"&artist=%@", YTMULastFMURLEncode(artist)];
    }
    [self performJSONRequest:[NSURL URLWithString:url]
                      method:@"GET"
                        body:nil
                  completion:^(NSDictionary *json, NSError *error) {
        if (error) {
            completion(nil, error);
            return;
        }
        // Response shape:
        //   { "results": { "trackmatches": { "track": [...] } } }
        // BUT "track" can be:
        //   - an array (multiple matches)
        //   - a single dict (one match)
        //   - missing / empty string (no matches)
        id results = json[@"results"];
        if (![results isKindOfClass:[NSDictionary class]]) {
            completion(@[], nil);
            return;
        }
        id matches = ((NSDictionary *)results)[@"trackmatches"];
        if (![matches isKindOfClass:[NSDictionary class]]) {
            completion(@[], nil);
            return;
        }
        id tracksRaw = ((NSDictionary *)matches)[@"track"];
        NSArray *tracks = nil;
        if ([tracksRaw isKindOfClass:[NSArray class]]) {
            tracks = tracksRaw;
        } else if ([tracksRaw isKindOfClass:[NSDictionary class]]) {
            tracks = @[tracksRaw];
        } else {
            completion(@[], nil);
            return;
        }
        NSMutableArray<YTMULastFMSearchResult *> *parsed = [NSMutableArray array];
        for (id t in tracks) {
            if (![t isKindOfClass:[NSDictionary class]]) continue;
            NSString *name = [t[@"name"] isKindOfClass:[NSString class]] ? t[@"name"] : nil;
            NSString *resultArtist = [t[@"artist"] isKindOfClass:[NSString class]] ? t[@"artist"] : nil;
            NSString *mbid = [t[@"mbid"] isKindOfClass:[NSString class]] ? t[@"mbid"] : nil;
            if (mbid.length == 0) mbid = nil;
            // `listeners` arrives as a string like "350"; coerce.
            NSInteger listeners = 0;
            id listenersRaw = t[@"listeners"];
            if ([listenersRaw isKindOfClass:[NSString class]]) {
                listeners = [(NSString *)listenersRaw integerValue];
            } else if ([listenersRaw isKindOfClass:[NSNumber class]]) {
                listeners = [(NSNumber *)listenersRaw integerValue];
            }
            if (!name.length || !resultArtist.length) continue;
            [parsed addObject:[[YTMULastFMSearchResult alloc] initWithTrack:name
                                                                     artist:resultArtist
                                                                       mbid:mbid
                                                                  listeners:listeners]];
        }
        completion(parsed, nil);
    }];
}

#pragma mark - Submission

- (void)submitNowPlaying:(YTMUListen *)listen {
    if (![self isEnabled] || ![self isConfigured]) return;
    if (![listen hasMinimumMetadata]) return;
    // Snapshot the values actually being submitted so the log can
    // show the canonical name even though the YTMUListen mutates
    // (resolver may write later corrections that this submission
    // doesn't see, and we want the log to match what we sent).
    NSString *submittedTrack = [listen bestTrack];
    NSString *submittedArtist = [listen bestArtist];
    NSDictionary<NSString *, NSString *> *params = [self baseParamsForListen:listen method:@"track.updateNowPlaying"];
    [self submitSignedParams:params completion:^(BOOL ok, NSError *err) {
        if (!ok) {
            YTMUScrobbleLog(@"lastfm now-playing failed track=\"%@\" / \"%@\": %@",
                            submittedTrack, submittedArtist, err.localizedDescription);
        } else {
            YTMUScrobbleLog(@"lastfm now-playing ok track=\"%@\" / \"%@\"",
                            submittedTrack, submittedArtist);
        }
    }];
}

- (void)submitScrobble:(YTMUListen *)listen completion:(YTMUScrobblerCompletion)completion {
    if (![self isEnabled] || ![self isConfigured] || ![listen hasMinimumMetadata]) {
        completion(NO, YTMULastFMError(1004, @"Not configured or missing metadata"));
        return;
    }
    NSMutableDictionary<NSString *, NSString *> *params = [[self baseParamsForListen:listen method:@"track.scrobble"] mutableCopy];
    params[@"timestamp"] = [NSString stringWithFormat:@"%lld", (long long)listen.startedAtUnix];
    [self submitSignedParams:params completion:completion];
}

- (NSUInteger)maxBatchSize {
    return kLastFMBatchMax;
}

- (void)submitBatch:(NSArray<YTMUListen *> *)listens completion:(YTMUScrobblerCompletion)completion {
    if (![self isEnabled] || ![self isConfigured] || listens.count == 0) {
        completion(NO, YTMULastFMError(1004, @"Not configured or empty batch"));
        return;
    }
    NSArray<YTMUListen *> *slice = listens.count > kLastFMBatchMax
        ? [listens subarrayWithRange:NSMakeRange(0, kLastFMBatchMax)]
        : listens;
    NSMutableDictionary<NSString *, NSString *> *params = [NSMutableDictionary dictionary];
    params[@"method"] = @"track.scrobble";
    params[@"api_key"] = self.apiKey;
    params[@"sk"] = self.sessionKey;
    [slice enumerateObjectsUsingBlock:^(YTMUListen *listen, NSUInteger i, BOOL *stop) {
        // Submit the best resolved values (corrected > cleaned > raw).
        params[[NSString stringWithFormat:@"track[%lu]", (unsigned long)i]] = [listen bestTrack];
        params[[NSString stringWithFormat:@"artist[%lu]", (unsigned long)i]] = [listen bestArtist];
        NSString *album = [listen bestAlbum];
        if (album.length) params[[NSString stringWithFormat:@"album[%lu]", (unsigned long)i]] = album;
        params[[NSString stringWithFormat:@"timestamp[%lu]", (unsigned long)i]] = [NSString stringWithFormat:@"%lld", (long long)listen.startedAtUnix];
        if (listen.durationSeconds > 0) {
            params[[NSString stringWithFormat:@"duration[%lu]", (unsigned long)i]] = [NSString stringWithFormat:@"%ld", (long)round(listen.durationSeconds)];
        }
    }];
    [self submitSignedParams:params completion:completion];
}

#pragma mark - Internal

- (NSDictionary<NSString *, NSString *> *)baseParamsForListen:(YTMUListen *)listen method:(NSString *)method {
    NSMutableDictionary *params = [NSMutableDictionary dictionary];
    params[@"method"] = method;
    params[@"api_key"] = self.apiKey;
    params[@"sk"] = self.sessionKey;
    // Best resolved values (corrected if last.fm/LLM returned a
    // canonical, otherwise cleaned via regex, otherwise the raw
    // MPNowPlayingInfoCenter strings).
    params[@"track"] = [listen bestTrack];
    params[@"artist"] = [listen bestArtist];
    NSString *album = [listen bestAlbum];
    if (album.length) params[@"album"] = album;
    if (listen.durationSeconds > 0) params[@"duration"] = [NSString stringWithFormat:@"%ld", (long)round(listen.durationSeconds)];
    return params;
}

- (void)submitSignedParams:(NSDictionary<NSString *, NSString *> *)params completion:(YTMUScrobblerCompletion)completion {
    NSMutableDictionary<NSString *, NSString *> *signed_ = [params mutableCopy];
    signed_[@"api_sig"] = YTMULastFMSignParams(signed_, self.apiSecret);
    signed_[@"format"] = @"json";

    NSURL *url = [NSURL URLWithString:kLastFMBaseURL];
    [self performJSONRequest:url
                      method:@"POST"
                        body:YTMULastFMFormBody(signed_)
                  completion:^(NSDictionary *json, NSError *error) {
        if (error) {
            completion(NO, error);
            return;
        }
        if ([json[@"error"] respondsToSelector:@selector(integerValue)]) {
            NSInteger errCode = [json[@"error"] integerValue];
            NSString *msg = [json[@"message"] isKindOfClass:[NSString class]] ? json[@"message"] : @"last.fm rejected";
            completion(NO, YTMULastFMError(errCode, msg));
            return;
        }
        completion(YES, nil);
    }];
}

- (void)performJSONRequest:(NSURL *)url
                    method:(NSString *)method
                      body:(nullable NSData *)body
                completion:(void (^)(NSDictionary *_Nullable json, NSError *_Nullable error))completion {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = method;
    request.timeoutInterval = 30.0;
    if (body) {
        request.HTTPBody = body;
        [request setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
    }
    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            completion(nil, error);
            return;
        }
        NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]] ? [(NSHTTPURLResponse *)response statusCode] : 0;
        NSError *jsonError = nil;
        id parsed = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError] : nil;
        if (status < 200 || status >= 300) {
            NSString *body = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"";
            completion(nil, YTMULastFMError(status, [NSString stringWithFormat:@"HTTP %ld: %@", (long)status, [body substringToIndex:MIN((NSUInteger)200, body.length)] ?: @""]));
            return;
        }
        if (![parsed isKindOfClass:[NSDictionary class]]) {
            completion(nil, jsonError ?: YTMULastFMError(1005, @"Invalid JSON"));
            return;
        }
        completion(parsed, nil);
    }] resume];
}

@end
