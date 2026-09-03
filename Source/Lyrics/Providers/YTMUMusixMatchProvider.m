#import "YTMUMusixMatchProvider.h"
#import "../YTMULRCParser.h"
#import "../../Utils/NSBundle+YTMU.h"
#import "../../Utils/YTMUSettings.h"

// Musixmatch answers unmatched lookups with this fixed placeholder track
// ("no result") instead of an error; it must never be shown as lyrics.
static const NSInteger YTMUMusixMatchPlaceholderTrackId = 115264642;

// Musixmatch retired the desktop API in 2026: apic-desktop.musixmatch.com now
// resolves to 127.0.0.1 from every resolver worldwide, so every request to it
// fails at the TLS handshake ("An SSL error has occurred"). apic.musixmatch.com
// is still served, and the host sits behind a WAF that scores clients on
// request patterns (see spotDL/spotify-downloader#2741).
static NSString *const YTMUMusixMatchDefaultBaseURL = @"https://apic.musixmatch.com";

// Which credential the WAF still mints tokens for varies by exit IP and time
// of day: measured within one hour from two different exits,
// `android-player-v1.0` answered on one and 401 captcha on the other, with
// `mxm-com-v1.0` doing the reverse. Pinning any single one guarantees periodic
// silent failure, so they are tried in order and the one that worked is
// remembered (and persisted, so the next launch starts there instead of
// sweeping again). `web-desktop-app-v1.0` is retired — it answers 401 upgrade
// everywhere — and is not worth a request.
static NSArray<NSString *> *YTMUMusixMatchAppIds(void) {
    return @[@"mxm-com-v1.0", @"android-player-v1.0", @"mxm-pro-web-v1.0"];
}

// A real user token stays valid for hours. The old 55-second cache put a
// token.get on the wire about once a minute for as long as music was playing,
// which is precisely the automated cadence the WAF scores on — asking rarely
// matters more here than which host or credential is used.
static const NSTimeInterval YTMUMusixMatchTokenTTL = 6 * 60 * 60;

// When a whole sweep fails (normally 401 captcha), stop asking for a while.
// Re-minting once per song is a steady beacon for the same WAF and is what
// gets an IP flagged in the first place.
static const NSTimeInterval YTMUMusixMatchFailureCooldown = 30 * 60;

static NSString *const YTMUMusixMatchTokenKey = @"musixmatch_userToken";
static NSString *const YTMUMusixMatchTokenExpiryKey = @"musixmatch_userTokenExpiresAt";
static NSString *const YTMUMusixMatchAppIdKey = @"musixmatch_appId";

@interface YTMUMusixMatchProvider ()
// atomic: written from NSURLSession's completion queue, read from whichever
// thread starts the next search.
@property (atomic, copy) NSString *cookie;
@property (atomic, copy) NSString *token;
@property (atomic) NSTimeInterval tokenExpiresAt;
// The credential that last produced a token, tried first next time.
@property (atomic, copy) NSString *appId;
// Set after a failed sweep; no token request goes out before it passes.
@property (atomic) NSTimeInterval retryTokenAfter;
@end

@implementation YTMUMusixMatchProvider

- (instancetype)init {
    self = [super init];
    if (self) {
        _cookie = @"x-mxm-user-id=";
        // Reuse the token from the previous launch while it is still valid, so
        // starting the app is not itself a token.get.
        NSString *stored = YTMUSettingsString(YTMUMusixMatchTokenKey, @"");
        NSTimeInterval expires = YTMUSettingsDouble(YTMUMusixMatchTokenExpiryKey, 0);
        if (stored.length && expires > [[NSDate date] timeIntervalSince1970]) {
            _token = stored;
            _tokenExpiresAt = expires;
        } else {
            _token = @"";
        }
        _appId = YTMUSettingsString(YTMUMusixMatchAppIdKey, YTMUMusixMatchAppIds().firstObject);
        _endpointBaseURL = YTMUMusixMatchDefaultBaseURL;
    }
    return self;
}

// The credentials to try this time, best guess first.
- (NSArray<NSString *> *)orderedAppIds {
    NSMutableArray<NSString *> *ids = [YTMUMusixMatchAppIds() mutableCopy];
    NSString *remembered = self.appId;
    if (remembered.length) {
        [ids removeObject:remembered];
        [ids insertObject:remembered atIndex:0];
    }
    return ids;
}

- (NSString *)providerName {
    return YTMULyricsSourceMusixMatch;
}

// Set-Cookie carries attributes (`Path=/; Expires=Wed, 09 Jun …`) that must
// never be echoed back. Sending the raw header as `Cookie:` produces a
// malformed request that no browser would make — a non-browser signal in its
// own right — so it is parsed and only the name=value pairs are kept.
- (void)captureCookie:(NSHTTPURLResponse *)response {
    NSDictionary *fields = response.allHeaderFields;
    if (!fields.count) return;
    NSURL *url = response.URL ?: [NSURL URLWithString:self.endpointBaseURL];
    NSMutableArray<NSString *> *pairs = [NSMutableArray array];
    for (NSHTTPCookie *cookie in [NSHTTPCookie cookiesWithResponseHeaderFields:fields forURL:url]) {
        if (cookie.name.length) [pairs addObject:[NSString stringWithFormat:@"%@=%@", cookie.name, cookie.value ?: @""]];
    }
    if (pairs.count) self.cookie = [pairs componentsJoinedByString:@"; "];
}

- (void)getToken:(void(^)(NSString *token, NSError *error))completion {
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (self.token.length && self.tokenExpiresAt > now) {
        completion(self.token, nil);
        return;
    }
    if (self.retryTokenAfter > now) {
        // Still cooling down from a failed sweep; fail without touching the
        // network so this provider stops being a per-song beacon.
        completion(@"", [NSError errorWithDomain:@"YTMUMusixMatch" code:3 userInfo:@{
            NSLocalizedDescriptionKey: YTMULocalized(@"LYRICS_ERROR_MUSIXMATCH_NO_TOKEN", @"Musixmatch token not initialized")
        }]);
        return;
    }
    [self mintTokenWithAppIds:[self orderedAppIds] index:0 lastHint:@"" completion:completion];
}

// Tries one credential per request, stopping at the first that mints a token.
- (void)mintTokenWithAppIds:(NSArray<NSString *> *)appIds
                      index:(NSUInteger)index
                   lastHint:(NSString *)lastHint
                 completion:(void(^)(NSString *token, NSError *error))completion {
    if (index >= appIds.count) {
        self.retryTokenAfter = [[NSDate date] timeIntervalSince1970] + YTMUMusixMatchFailureCooldown;
        NSString *message = YTMULocalized(@"LYRICS_ERROR_MUSIXMATCH_NO_TOKEN", @"Musixmatch token not initialized");
        if (lastHint.length) message = [NSString stringWithFormat:@"%@ (%@)", message, lastHint];
        completion(@"", [NSError errorWithDomain:@"YTMUMusixMatch" code:1 userInfo:@{NSLocalizedDescriptionKey: message}]);
        return;
    }

    NSString *appId = appIds[index];
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@/ws/1.1/token.get?app_id=%@", self.endpointBaseURL, appId]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.timeoutInterval = 8.0; // bound a stuck token-fetch call
    [request setValue:self.cookie forHTTPHeaderField:@"Cookie"];
    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            completion(@"", error);
            return;
        }
        if ([response isKindOfClass:[NSHTTPURLResponse class]]) [self captureCookie:(NSHTTPURLResponse *)response];
        id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSString *token = YTMULyricsJSONStringAtPath(json, @[@"message", @"body", @"user_token"]);
        if (!token.length) {
            // The header says why: "upgrade" = this credential is retired,
            // "captcha" = this exit is being scored as automation. Either way
            // the next credential is worth one try.
            NSString *hint = YTMULyricsJSONStringAtPath(json, @[@"message", @"header", @"hint"]) ?: @"";
            YTMULyricsLog(@"musixmatch token.get app_id=%@ rejected hint=%@", appId, hint.length ? hint : @"<none>");
            [self mintTokenWithAppIds:appIds index:index + 1 lastHint:hint completion:completion];
            return;
        }
        NSTimeInterval expiresAt = [[NSDate date] timeIntervalSince1970] + YTMUMusixMatchTokenTTL;
        self.token = token;
        self.tokenExpiresAt = expiresAt;
        self.appId = appId;
        self.retryTokenAfter = 0;
        YTMUSettingsUpdate(^(NSMutableDictionary<NSString *, id> *settings) {
            settings[YTMUMusixMatchTokenKey] = token;
            settings[YTMUMusixMatchTokenExpiryKey] = @(expiresAt);
            settings[YTMUMusixMatchAppIdKey] = appId;
        }, @[YTMUMusixMatchTokenKey, YTMUMusixMatchTokenExpiryKey, YTMUMusixMatchAppIdKey]);
        YTMULyricsLog(@"musixmatch token minted app_id=%@ valid for %.0f h", appId, YTMUMusixMatchTokenTTL / 3600.0);
        completion(token, nil);
    }] resume];
}

- (void)queryMacroWithInfo:(YTMULyricsSearchInfo *)info token:(NSString *)token completion:(void(^)(NSDictionary *json, NSError *error))completion {
    NSMutableDictionary *params = [@{
        @"app_id": self.appId.length ? self.appId : YTMUMusixMatchAppIds().firstObject,
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
    NSString *url = [NSString stringWithFormat:@"%@/ws/1.1/macro.subtitles.get?%@", self.endpointBaseURL, [parts componentsJoinedByString:@"&"]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    request.timeoutInterval = 8.0; // bound a stuck subtitles call
    [request setValue:self.cookie forHTTPHeaderField:@"Cookie"];
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
    if ([YTMULyricsJSONNumberAtPath(track, @[@"track_id"]) integerValue] == YTMUMusixMatchPlaceholderTrackId) return nil;

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
