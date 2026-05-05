#import "YTMUNetEaseProvider.h"
#import "../YTMULRCParser.h"
#import <CommonCrypto/CommonCrypto.h>
#import <CommonCrypto/CommonDigest.h>

static NSString *const YTMUNetEaseAESKey = @"e82ckenh8dichen8";
static NSString *const YTMUNetEaseEncodeKey = @"3go8&$8*3*3h0k(2)2";
static NSString *const YTMUNetEaseCheckToken = @"9ca17ae2e6ffcda170e2e6ee8ad85dba908ca4d74da9ac8ea2d44e938f9eadc66da5a8979af572a5a9b68ac12af0feaec3b92aa69af9b1d372f6b8adccb35e968b9bb6c14f908d0099fb6ff48efdacd361f5b6ee9e";

@interface YTMUNetEaseProvider ()
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *cookies;
@property (nonatomic) BOOL initialized;
@end

@implementation YTMUNetEaseProvider

- (instancetype)init {
    self = [super init];
    if (self) {
        _cookies = [NSMutableDictionary dictionary];
    }
    return self;
}

- (NSString *)providerName {
    return YTMULyricsSourceNetEase;
}

- (NSData *)md5DataForData:(NSData *)data {
    unsigned char digest[CC_MD5_DIGEST_LENGTH];
    CC_MD5(data.bytes, (CC_LONG)data.length, digest);
    return [NSData dataWithBytes:digest length:CC_MD5_DIGEST_LENGTH];
}

- (NSString *)md5Hex:(NSString *)string {
    NSData *digest = [self md5DataForData:[string dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data]];
    const unsigned char *bytes = digest.bytes;
    NSMutableString *out = [NSMutableString stringWithCapacity:CC_MD5_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_MD5_DIGEST_LENGTH; i++) [out appendFormat:@"%02x", bytes[i]];
    return out;
}

- (NSString *)encodeDeviceId:(NSString *)deviceId {
    NSMutableData *xored = [NSMutableData dataWithCapacity:deviceId.length];
    for (NSUInteger i = 0; i < deviceId.length; i++) {
        unichar c = [deviceId characterAtIndex:i];
        unichar k = [YTMUNetEaseEncodeKey characterAtIndex:i % YTMUNetEaseEncodeKey.length];
        unsigned char byte = (unsigned char)(c ^ k);
        [xored appendBytes:&byte length:1];
    }
    NSString *hash = [[self md5DataForData:xored] base64EncodedStringWithOptions:0];
    NSString *combined = [NSString stringWithFormat:@"%@ %@", deviceId, hash];
    return [[combined dataUsingEncoding:NSISOLatin1StringEncoding] base64EncodedStringWithOptions:0];
}

- (NSString *)hexAESForString:(NSString *)string {
    NSData *data = [string dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
    NSData *key = [YTMUNetEaseAESKey dataUsingEncoding:NSUTF8StringEncoding];
    size_t outLength = data.length + kCCBlockSizeAES128;
    NSMutableData *out = [NSMutableData dataWithLength:outLength];
    CCCryptorStatus status = CCCrypt(kCCEncrypt,
                                     kCCAlgorithmAES,
                                     kCCOptionPKCS7Padding | kCCOptionECBMode,
                                     key.bytes,
                                     kCCKeySizeAES128,
                                     NULL,
                                     data.bytes,
                                     data.length,
                                     out.mutableBytes,
                                     out.length,
                                     &outLength);
    if (status != kCCSuccess) return @"";
    out.length = outLength;
    const unsigned char *bytes = out.bytes;
    NSMutableString *hex = [NSMutableString stringWithCapacity:out.length * 2];
    for (NSUInteger i = 0; i < out.length; i++) [hex appendFormat:@"%02X", bytes[i]];
    return hex;
}

- (NSString *)cookieHeader {
    NSMutableArray *parts = [NSMutableArray array];
    [self.cookies enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *obj, BOOL *stop) {
        [parts addObject:[NSString stringWithFormat:@"%@=%@", key, obj]];
    }];
    return [parts componentsJoinedByString:@"; "];
}

- (void)captureCookiesFromResponse:(NSHTTPURLResponse *)response {
    NSString *setCookie = response.allHeaderFields[@"Set-Cookie"] ?: response.allHeaderFields[@"set-cookie"];
    if (![setCookie isKindOfClass:[NSString class]] || !setCookie.length) return;
    NSArray *cookieStrings = [setCookie componentsSeparatedByString:@","];
    for (NSString *cookieString in cookieStrings) {
        NSString *first = [cookieString componentsSeparatedByString:@";"].firstObject;
        NSArray *kv = [first componentsSeparatedByString:@"="];
        if (kv.count < 2) continue;
        NSString *name = [kv[0] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSString *value = [[kv subarrayWithRange:NSMakeRange(1, kv.count - 1)] componentsJoinedByString:@"="];
        if (name.length && value.length) self.cookies[name] = value;
    }
}

- (void)eapiPath:(NSString *)path
            data:(NSDictionary *)data
          params:(NSDictionary<NSString *, NSString *> *)params
      completion:(void(^)(NSDictionary *json, NSError *error))completion {
    NSMutableDictionary *bodyData = [NSMutableDictionary dictionaryWithDictionary:data ?: @{}];
    bodyData[@"header"] = YTMULyricsJSONStringFromObject(@{
        @"os": @"osx",
        @"appver": @"3.0.14",
        @"requestId": @"0",
        @"osver": @"15.6.1",
    });
    NSString *body = YTMULyricsJSONStringFromObject(bodyData);
    NSString *sign = [self md5Hex:[NSString stringWithFormat:@"nobody/api%@use%@md5forencrypt", path, body]];
    NSString *payload = [NSString stringWithFormat:@"/api%@-36cd479b6b5-%@-36cd479b6b5-%@", path, body, sign];
    NSString *encrypted = [self hexAESForString:payload];
    if (!encrypted.length) {
        completion(nil, [NSError errorWithDomain:@"YTMUNetEase" code:1 userInfo:@{NSLocalizedDescriptionKey: @"NetEase encryption failed"}]);
        return;
    }

    NSMutableArray *queryParts = [NSMutableArray array];
    [params enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *obj, BOOL *stop) {
        [queryParts addObject:[NSString stringWithFormat:@"%@=%@", key, YTMULyricsEncodeQuery(obj)]];
    }];
    NSString *url = [NSString stringWithFormat:@"https://interface.music.163.com/eapi%@%@", path, queryParts.count ? [@"?" stringByAppendingString:[queryParts componentsJoinedByString:@"&"]] : @""];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    request.HTTPMethod = @"POST";
    [request setValue:@"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) NeteaseMusicDesktop/3.0.14.2534" forHTTPHeaderField:@"User-Agent"];
    [request setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
    NSString *cookie = [self cookieHeader];
    if (cookie.length) [request setValue:cookie forHTTPHeaderField:@"Cookie"];
    request.HTTPBody = [[NSString stringWithFormat:@"params=%@", YTMULyricsEncodeQuery(encrypted)] dataUsingEncoding:NSUTF8StringEncoding];

    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *responseData, NSURLResponse *response, NSError *error) {
        if (error) {
            completion(nil, error);
            return;
        }
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
        [self captureCookiesFromResponse:http];
        NSInteger status = http.statusCode;
        if (status < 200 || status >= 300) {
            completion(nil, [NSError errorWithDomain:@"YTMUNetEase" code:status userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"NetEase HTTP %ld", (long)status]}]);
            return;
        }
        id json = responseData ? [NSJSONSerialization JSONObjectWithData:responseData options:0 error:&error] : nil;
        if (![json isKindOfClass:[NSDictionary class]]) {
            completion(nil, error ?: [NSError errorWithDomain:@"YTMUNetEase" code:2 userInfo:@{NSLocalizedDescriptionKey: @"NetEase returned invalid JSON"}]);
            return;
        }
        NSNumber *code = YTMULyricsJSONNumberAtPath(json, @[@"code"]);
        if (code && code.integerValue != 200) {
            completion(nil, [NSError errorWithDomain:@"YTMUNetEase" code:code.integerValue userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"NetEase API %ld", (long)code.integerValue]}]);
            return;
        }
        completion(json, nil);
    }] resume];
}

- (void)registerIfNeeded:(void(^)(void))ready failure:(void(^)(NSError *error))failure {
    if (self.initialized) {
        ready();
        return;
    }
    NSString *deviceId = @"7B79802670C7A45DB9091976D71E0AE829E28926C6C34A1B8644";
    [self eapiPath:@"/register/anonimous"
              data:@{@"username": [self encodeDeviceId:deviceId]}
            params:@{@"_nmclfl": @"1"}
        completion:^(NSDictionary *json, NSError *error) {
        if (error) {
            failure(error);
            return;
        }
        self.initialized = YES;
        ready();
    }];
}

- (NSDictionary *)parseSong:(id)raw {
    if (![raw isKindOfClass:[NSDictionary class]]) return nil;
    NSDictionary *dict = raw;
    NSNumber *resourceId = YTMULyricsJSONNumberAtPath(dict, @[@"resourceId"]) ?: YTMULyricsJSONNumberAtPath(dict, @[@"id"]);
    NSDictionary *simple = YTMULyricsJSONDictionaryAtPath(dict, @[@"baseInfo", @"simpleSongData"]) ?: dict;
    NSString *name = YTMULyricsJSONStringAtPath(simple, @[@"name"]);
    NSArray *artists = YTMULyricsJSONArrayAtPath(simple, @[@"ar"]) ?: YTMULyricsJSONArrayAtPath(simple, @[@"artists"]) ?: @[];
    NSNumber *duration = YTMULyricsJSONNumberAtPath(simple, @[@"dt"]) ?: YTMULyricsJSONNumberAtPath(simple, @[@"duration"]);
    if (!resourceId || !name.length || !duration) return nil;
    return @{@"id": resourceId, @"name": name, @"artists": artists ?: @[], @"duration": duration};
}

- (void)searchSongs:(NSString *)keyword completion:(void(^)(NSArray<NSDictionary *> *songs))completion {
    [self eapiPath:@"/search/song/list/page"
              data:@{@"offset": @"0",
                     @"scene": @"NORMAL",
                     @"needCorrect": @"true",
                     @"checkToken": YTMUNetEaseCheckToken,
                     @"keyword": keyword ?: @"",
                     @"limit": @"10",
                     @"verifyId": @1}
            params:@{@"_nmclfl": @"1"}
        completion:^(NSDictionary *json, NSError *error) {
        if (error) {
            YTMULyricsLog(@"NetEase search failed keyword=%@ error=%@", keyword, error.localizedDescription);
            completion(@[]);
            return;
        }
        NSMutableArray *rawItems = [NSMutableArray array];
        NSArray *resources = YTMULyricsJSONArrayAtPath(json, @[@"data", @"resources"]);
        NSArray *songs = YTMULyricsJSONArrayAtPath(json, @[@"result", @"songs"]);
        if ([resources isKindOfClass:[NSArray class]]) [rawItems addObjectsFromArray:resources];
        if ([songs isKindOfClass:[NSArray class]]) [rawItems addObjectsFromArray:songs];
        NSMutableArray *parsed = [NSMutableArray array];
        for (id raw in rawItems) {
            NSDictionary *song = [self parseSong:raw];
            if (song) [parsed addObject:song];
        }
        completion(parsed);
    }];
}

- (NSArray<NSString *> *)keywordsForInfo:(YTMULyricsSearchInfo *)info {
    NSMutableArray *titles = [NSMutableArray array];
    for (NSString *candidate in @[info.title ?: @"", info.alternativeTitle ?: @""]) {
        NSString *clean = YTMULyricsStripSearchNoise(candidate);
        if (!clean.length) continue;
        [titles addObject:clean];
        NSArray *parts = [clean componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"-–—/|:：／｜│"]];
        for (NSString *part in parts) {
            NSString *partClean = YTMULyricsStripSearchNoise(part);
            if (partClean.length > 1) [titles addObject:partClean];
        }
    }
    NSMutableArray *keywords = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    NSArray *artists = YTMULyricsSplitArtists(info.artist, info.tags);
    for (NSString *title in titles) {
        NSString *key = YTMULyricsCompactString(title);
        if (key.length && ![seen containsObject:key]) {
            [seen addObject:key];
            [keywords addObject:title];
        }
        for (NSString *artist in [artists subarrayWithRange:NSMakeRange(0, MIN(2, artists.count))]) {
            NSString *combined = [NSString stringWithFormat:@"%@ %@", title, artist];
            NSString *combinedKey = YTMULyricsCompactString(combined);
            if (combinedKey.length && ![seen containsObject:combinedKey]) {
                [seen addObject:combinedKey];
                [keywords addObject:combined];
            }
        }
        if (keywords.count >= 16) break;
    }
    return keywords;
}

- (CGFloat)artistScoreForSong:(NSDictionary *)song artistNames:(NSArray<NSString *> *)artistNames {
    NSArray *rawArtists = YTMULyricsJSONArrayAtPath(song, @[@"artists"]);
    CGFloat best = 0;
    for (id item in rawArtists) {
        NSString *name = YTMULyricsJSONStringAtPath(item, @[@"name"]) ?: @"";
        for (NSString *artist in artistNames) {
            best = MAX(best, YTMULyricsSimilarity(name, artist));
        }
    }
    return artistNames.count ? best : 0.5;
}

- (NSDictionary *)bestSongFromSongs:(NSArray<NSDictionary *> *)songs info:(YTMULyricsSearchInfo *)info {
    NSArray *artists = YTMULyricsSplitArtists(info.artist, info.tags);
    NSDictionary *best = nil;
    CGFloat bestScore = 0;
    BOOL hasDuration = isfinite(info.duration) && info.duration > 0;
    for (id candidate in songs) {
        if (![candidate isKindOfClass:[NSDictionary class]]) continue;
        NSDictionary *song = candidate;
        NSString *name = YTMULyricsJSONStringAtPath(song, @[@"name"]) ?: @"";
        CGFloat titleScore = MAX(YTMULyricsSimilarity(info.title, name), YTMULyricsSimilarity(info.alternativeTitle, name));
        CGFloat artistScore = [self artistScoreForSong:song artistNames:artists];
        NSTimeInterval duration = [YTMULyricsJSONNumberAtPath(song, @[@"duration"]) doubleValue] / 1000.0;
        NSTimeInterval delta = hasDuration ? fabs(duration - info.duration) : 0;
        if (titleScore < 0.70) continue;
        if (hasDuration && delta > 25) continue;
        if (artistScore < 0.32 && titleScore < 0.92) continue;
        CGFloat durationScore = hasDuration ? MAX(0, 1 - delta / 25.0) : 0.2;
        CGFloat score = titleScore * 1.65 + artistScore * 0.7 + durationScore * 0.4;
        if (score > bestScore) {
            bestScore = score;
            best = song;
        }
    }
    return bestScore >= 1.45 ? best : nil;
}

- (void)getLyric:(NSNumber *)songId completion:(void(^)(NSDictionary *lyric))completion {
    [self eapiPath:@"/song/lyric/v1"
              data:@{@"id": songId,
                     @"tv": @"-1",
                     @"yv": @"-1",
                     @"rv": @"-1",
                     @"lv": @"-1",
                     @"verifyId": @1}
            params:@{@"_nmclfl": @"1"}
        completion:^(NSDictionary *json, NSError *error) {
        completion(error ? nil : json);
    }];
}

- (void)searchWithInfo:(YTMULyricsSearchInfo *)info completion:(void (^)(YTMULyricsResult *, NSError *))completion {
    [self registerIfNeeded:^{
        NSArray *keywords = [self keywordsForInfo:info];
        if (!keywords.count) {
            completion(nil, nil);
            return;
        }

        dispatch_group_t group = dispatch_group_create();
        NSMutableArray *allSongs = [NSMutableArray array];
        for (NSString *keyword in keywords) {
            dispatch_group_enter(group);
            [self searchSongs:keyword completion:^(NSArray<NSDictionary *> *songs) {
                @synchronized (allSongs) {
                    [allSongs addObjectsFromArray:songs];
                }
                dispatch_group_leave(group);
            }];
        }
        dispatch_group_notify(group, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            NSMutableDictionary<NSNumber *, NSDictionary *> *unique = [NSMutableDictionary dictionary];
            for (NSDictionary *song in allSongs) {
                NSNumber *songId = YTMULyricsJSONNumberAtPath(song, @[@"id"]);
                if (songId) unique[songId] = song;
            }
            NSDictionary *best = [self bestSongFromSongs:unique.allValues info:info];
            if (!best) {
                completion(nil, nil);
                return;
            }
            [self getLyric:YTMULyricsJSONNumberAtPath(best, @[@"id"]) completion:^(NSDictionary *lyric) {
                NSString *rawLyrics = [YTMULRCParser stripNetEaseMetadata:YTMULyricsJSONStringAtPath(lyric, @[@"lrc", @"lyric"]) ?: @""];
                if (!rawLyrics.length) {
                    completion(nil, nil);
                    return;
                }
                NSString *translation = [YTMULRCParser stripNetEaseMetadata:YTMULyricsJSONStringAtPath(lyric, @[@"tlyric", @"lyric"]) ?: @""];
                YTMULyricsResult *result = [[YTMULyricsResult alloc] init];
                result.sourceName = [self providerName];
                result.title = YTMULyricsJSONStringAtPath(best, @[@"name"]) ?: info.title;
                NSMutableArray *artistNames = [NSMutableArray array];
                for (id artist in YTMULyricsJSONArrayAtPath(best, @[@"artists"]) ?: @[]) {
                    NSString *name = YTMULyricsJSONStringAtPath(artist, @[@"name"]);
                    if (name.length) [artistNames addObject:name];
                }
                result.artists = artistNames.count ? artistNames : (info.artist.length ? @[info.artist] : @[]);
                result.plainLyrics = rawLyrics;
                result.lines = [YTMULRCParser parseLRC:rawLyrics];
                result.duration = [YTMULyricsJSONNumberAtPath(best, @[@"duration"]) doubleValue] / 1000.0;
                if (translation.length) {
                    NSArray *translatedSynced = [YTMULRCParser parseLRC:translation];
                    NSMutableArray *translatedTexts = [NSMutableArray array];
                    if (translatedSynced.count) {
                        for (YTMULyricLine *line in translatedSynced) [translatedTexts addObject:line.text ?: @""];
                    } else {
                        [translatedTexts addObjectsFromArray:[YTMULRCParser plainLinesFromLyrics:translation]];
                    }
                    result.officialTranslatedLines = translatedTexts;
                    result.officialTranslationLanguage = @"zh-CN";
                    result.officialTranslationProvider = [self providerName];
                }
                YTMULyricsLog(@"NetEase match title=%@ lines=%lu officialTranslation=%d",
                              result.title,
                              (unsigned long)result.lineTexts.count,
                              result.officialTranslatedLines.count > 0);
                completion(result.hasText ? result : nil, nil);
            }];
        });
    } failure:^(NSError *error) {
        completion(nil, error);
    }];
}

@end
