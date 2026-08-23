#import "YTMUNetEaseProvider.h"
#import "../YTMULRCParser.h"
#import "../../Utils/NSBundle+YTMU.h"
#import <CommonCrypto/CommonCrypto.h>
#import <CommonCrypto/CommonDigest.h>
#import <float.h>

static NSString *const YTMUNetEaseAESKey = @"e82ckenh8dichen8";
static NSString *const YTMUNetEaseEncodeKey = @"3go8&$8*3*3h0k(2)2";
static NSString *const YTMUNetEaseCheckToken = @"9ca17ae2e6ffcda170e2e6ee8ad85dba908ca4d74da9ac8ea2d44e938f9eadc66da5a8979af572a5a9b68ac12af0feaec3b92aa69af9b1d372f6b8adccb35e968b9bb6c14f908d0099fb6ff48efdacd361f5b6ee9e";

static BOOL YTMUNetEaseHasJapaneseOrCJK(NSString *value) {
    return YTMULyricsRegexMatches(value, @"[\\u3040-\\u30ff\\u3400-\\u9fff]", 0);
}

static BOOL YTMUNetEaseHasLatin(NSString *value) {
    return YTMULyricsRegexMatches(value, @"[A-Za-z]", 0);
}

static BOOL YTMUNetEaseHasNonLatinRomanizableText(NSString *value) {
    return YTMULyricsRegexMatches(value, @"[\\u3040-\\u30ff\\uac00-\\ud7af\\u0e00-\\u0e7f\\u0980-\\u09ff\\u0900-\\u097f]", 0);
}

static BOOL YTMUNetEaseRegexTest(NSString *value, NSString *pattern) {
    return YTMULyricsRegexMatches(value, pattern, NSRegularExpressionCaseInsensitive);
}

// --- Candidate scoring -------------------------------------------------
// Each NetEase search hit is scored against the search info and then has to
// clear one of two gates: "strict" (confident, surfaced as an exact match)
// or "inexact" (surfaced only when the user allows inexact lyrics). These
// were tuned by hand against real doujin / vocaloid / K-pop collisions; the
// fixture in Tests/Host/Test_NetEaseRanking.m pins the resulting order, so
// change a number here and that test will tell you what moved.
//
// Combined score = title·W_TITLE + artist·W_ARTIST + duration·W_DURATION,
// where each component is 0…1 and duration decays linearly to 0 over
// kDurationDecaySeconds of mismatch (a flat kDurationScoreWhenUnknown when
// the player gave us no duration).
static const CGFloat YTMUNetEaseWeightTitle = 1.65;
static const CGFloat YTMUNetEaseWeightArtist = 0.7;
static const CGFloat YTMUNetEaseWeightDuration = 0.4;
static const NSTimeInterval YTMUNetEaseDurationDecaySeconds = 25.0;
static const CGFloat YTMUNetEaseDurationScoreWhenUnknown = 0.2;
// Ranking: scores closer than this are considered tied on score and fall
// back to duration delta, then song id.
static const CGFloat YTMUNetEaseScoreTieWindow = 0.08;
// Strict gate.
static const CGFloat YTMUNetEaseStrictMinTitle = 0.72;
static const NSTimeInterval YTMUNetEaseStrictMaxDurationDelta = 25;          // hard cut
static const NSTimeInterval YTMUNetEaseStrictSoftDurationDelta = 15;         // beyond this the title must be near-exact…
static const CGFloat YTMUNetEaseStrictTitleForSoftDuration = 0.90;          // …this good
static const CGFloat YTMUNetEaseStrictMinArtist = 0.35;                       // unless the title is essentially exact…
static const CGFloat YTMUNetEaseStrictTitleOverridesArtist = 0.92;           // …this good
static const CGFloat YTMUNetEaseStrictMinArtistAmbiguousLatin = 0.55;        // short Latin titles ("Terminal") need the artist
static const CGFloat YTMUNetEaseStrictMinScore = 1.55;
// Inexact gate (looser copy of the above).
static const CGFloat YTMUNetEaseInexactMinTitle = 0.62;
static const NSTimeInterval YTMUNetEaseInexactMaxDurationDelta = 45;
static const CGFloat YTMUNetEaseInexactTitleNeedsArtistBelow = 0.80;
static const CGFloat YTMUNetEaseInexactMinArtist = 0.25;
static const CGFloat YTMUNetEaseInexactLatinTitleOverride = 0.90;
static const CGFloat YTMUNetEaseInexactMinArtistAmbiguousLatin = 0.45;
static const CGFloat YTMUNetEaseInexactMinScore = 1.25;

@interface YTMUNetEaseProvider ()
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *cookies;
@property (nonatomic) BOOL initialized;
@end

// Everything derived from the search info that both the keyword pass and
// the candidate-scoring pass need. Built once per search (it is the
// expensive part — tag filtering, title splitting, dozens of similarity
// calls) instead of once per pass.
@interface YTMUNetEaseSearchContext : NSObject
@property (nonatomic, copy) NSArray<NSString *> *artists;          // split primary artist + artist-like tags
@property (nonatomic, copy) NSArray<NSString *> *featured;         // feat./ft. names pulled from the titles
@property (nonatomic, copy) NSArray<NSString *> *titleTags;
@property (nonatomic, copy) NSArray<NSDictionary *> *titleCandidates;
@end
@implementation YTMUNetEaseSearchContext
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

// `cookies` is read while building a request (whichever thread searches)
// and written from NSURLSession's completion queue; both sides take the
// same lock so an enumeration never races a set.
- (NSString *)cookieHeader {
    NSMutableArray *parts = [NSMutableArray array];
    @synchronized (self.cookies) {
        [self.cookies enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *obj, BOOL *stop) {
            [parts addObject:[NSString stringWithFormat:@"%@=%@", key, obj]];
        }];
    }
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
        if (name.length && value.length) {
            @synchronized (self.cookies) { self.cookies[name] = value; }
        }
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
        completion(nil, [NSError errorWithDomain:@"YTMUNetEase" code:1 userInfo:@{NSLocalizedDescriptionKey: YTMULocalized(@"LYRICS_ERROR_NETEASE_CRYPTO", @"NetEase encryption failed")}]);
        return;
    }

    NSMutableArray *queryParts = [NSMutableArray array];
    [params enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *obj, BOOL *stop) {
        [queryParts addObject:[NSString stringWithFormat:@"%@=%@", key, YTMULyricsEncodeQuery(obj)]];
    }];
    NSString *url = [NSString stringWithFormat:@"https://interface.music.163.com/eapi%@%@", path, queryParts.count ? [@"?" stringByAppendingString:[queryParts componentsJoinedByString:@"&"]] : @""];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    request.HTTPMethod = @"POST";
    // Default NSURLRequest timeout is 60s. Without an explicit cap a
    // misbehaving NetEase API call would block the entire raw-pass
    // pipeline for a full minute. 8s is comfortable for healthy
    // responses (typically <2s) and keeps the worst-case bounded.
    request.timeoutInterval = 8.0;
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
        NSHTTPURLResponse *http = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
        [self captureCookiesFromResponse:http];
        NSInteger status = http.statusCode;
        if (status < 200 || status >= 300) {
            completion(nil, [NSError errorWithDomain:@"YTMUNetEase" code:status userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:YTMULocalized(@"LYRICS_ERROR_HTTP_STATUS_FORMAT", @"HTTP %ld"), (long)status]}]);
            return;
        }
        id json = responseData ? [NSJSONSerialization JSONObjectWithData:responseData options:0 error:&error] : nil;
        if (![json isKindOfClass:[NSDictionary class]]) {
            completion(nil, error ?: [NSError errorWithDomain:@"YTMUNetEase" code:2 userInfo:@{NSLocalizedDescriptionKey: YTMULocalized(@"LYRICS_ERROR_NETEASE_BAD_JSON", @"NetEase returned invalid JSON")}]);
            return;
        }
        NSNumber *code = YTMULyricsJSONNumberAtPath(json, @[@"code"]);
        if (code && code.integerValue != 200) {
            completion(nil, [NSError errorWithDomain:@"YTMUNetEase" code:code.integerValue userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:YTMULocalized(@"LYRICS_ERROR_NETEASE_API_FORMAT", @"API error %ld"), (long)code.integerValue]}]);
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

- (BOOL)isLikelyArtistFragment:(NSString *)value {
    return YTMUNetEaseRegexTest(value ?: @"", @"(?:初音ミク|Hatsune\\s*Miku|鏡音|Kagamine|巡音|Megurine|音街ウナ|Otomachi\\s*Una|重音テト|Kasane\\s*Teto|可不|KAFU|星界|SEKAI|裏命|RIME|狐子|COKO|羽累|HARU|花隈千冬|Hanakuma\\s*Chifuyu|ナースロボ|Nurse\\s*Robot|タイプT|Type\\s*T|ずんだもん|Zundamon|KAITO|MEIKO|GUMI|IA|ONE|flower|vflower|CeVIO|VOCALOID|UTAU|SynthV|VOICEVOX|VOICEROID)");
}

- (NSArray<NSString *> *)uniqueStringsByCompact:(NSArray<NSString *> *)values {
    NSMutableArray<NSString *> *output = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (NSString *value in values ?: @[]) {
        NSString *key = YTMULyricsCompactString(value ?: @"");
        if (!key.length || [seen containsObject:key]) continue;
        [seen addObject:key];
        [output addObject:value];
    }
    return output;
}

- (NSArray<NSString *> *)uniqueStringsBySearchText:(NSArray<NSString *> *)values {
    NSMutableArray<NSString *> *output = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (NSString *value in values ?: @[]) {
        NSString *key = YTMULyricsNormalizeLoose(value ?: @"");
        if (!key.length || [seen containsObject:key]) continue;
        [seen addObject:key];
        [output addObject:value];
    }
    return output;
}

- (NSString *)stripSearchPunctuation:(NSString *)value {
    if (!value.length) return @"";
    NSMutableString *mutable = [[value stringByFoldingWithOptions:NSWidthInsensitiveSearch
                                                           locale:[NSLocale currentLocale]] mutableCopy];
    CFStringTransform((__bridge CFMutableStringRef)mutable, NULL, kCFStringTransformFullwidthHalfwidth, NO);
    NSRegularExpression *punctuation = YTMULyricsCachedRegex(@"[^\\p{L}\\p{N}\\s]+", 0);
    NSString *stripped = [punctuation stringByReplacingMatchesInString:mutable
                                                               options:0
                                                                 range:NSMakeRange(0, mutable.length)
                                                          withTemplate:@" "];
    NSRegularExpression *spaces = YTMULyricsCachedRegex(@"\\s+", 0);
    NSString *collapsed = [spaces stringByReplacingMatchesInString:stripped
                                                           options:0
                                                             range:NSMakeRange(0, stripped.length)
                                                      withTemplate:@" "];
    return [collapsed stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

- (NSDictionary *)filterArtistTagValuesForTitle:(NSString *)title
                               alternativeTitle:(NSString *)alternativeTitle
                                          album:(NSString *)album
                                         artist:(NSString *)artist
                                           tags:(NSArray<NSString *> *)tags {
    NSArray<NSString *> *primaryArtistNames = YTMULyricsSplitArtists(artist, nil);
    BOOL hasFeaturedArtist = [self featuredArtistNamesFromTitles:@[title ?: @"", alternativeTitle ?: @""]].count > 0;
    NSMutableArray<NSString *> *songTitleValues = [NSMutableArray array];
    if (title.length) [songTitleValues addObject:title];
    if (alternativeTitle.length) [songTitleValues addObject:alternativeTitle];

    if (album.length) {
        BOOL albumLooksLikeTitle = NO;
        for (NSString *value in songTitleValues) {
            if (YTMULyricsSimilarity(album, value) >= 0.92) {
                albumLooksLikeTitle = YES;
                break;
            }
        }
        if (albumLooksLikeTitle) [songTitleValues addObject:album];
    }

    NSMutableArray<NSString *> *titleKeyValues = [NSMutableArray array];
    for (NSString *value in songTitleValues) {
        if (value.length) [titleKeyValues addObject:value];
        NSString *stripped = YTMULyricsStripSearchNoise(value);
        if (stripped.length) [titleKeyValues addObject:stripped];
    }
    NSArray<NSString *> *titleKeys = [self uniqueStringsByCompact:titleKeyValues];
    NSMutableArray<NSString *> *compactTitleKeys = [NSMutableArray array];
    for (NSString *value in titleKeys ?: @[]) {
        NSString *key = YTMULyricsCompactString(value);
        if (key.length) [compactTitleKeys addObject:key];
    }

    NSMutableArray<NSString *> *artistTags = [NSMutableArray array];
    NSMutableArray<NSString *> *titleTags = [NSMutableArray array];
    NSMutableArray<NSString *> *ignored = [NSMutableArray array];
    BOOL seenTitleTag = NO;
    for (NSString *tag in tags ?: @[]) {
        NSMutableArray<NSString *> *tagKeys = [NSMutableArray array];
        NSString *rawKey = YTMULyricsCompactString(tag ?: @"");
        NSString *strippedKey = YTMULyricsCompactString(YTMULyricsStripSearchNoise(tag ?: @""));
        if (rawKey.length) [tagKeys addObject:rawKey];
        if (strippedKey.length) [tagKeys addObject:strippedKey];

        BOOL titleLike = NO;
        for (NSString *tagKey in tagKeys) {
            if ([compactTitleKeys containsObject:tagKey]) {
                titleLike = YES;
                break;
            }
        }
        BOOL localizedTitleLike = !hasFeaturedArtist &&
                                  seenTitleTag &&
                                  YTMUNetEaseHasNonLatinRomanizableText(tag ?: @"") &&
                                  ![self isArtistLike:tag artistNames:primaryArtistNames] &&
                                  ![self isLikelyArtistFragment:tag];
        if (titleLike || localizedTitleLike) {
            [ignored addObject:tag ?: @""];
            [titleTags addObject:tag ?: @""];
            if (titleLike) seenTitleTag = YES;
            continue;
        }
        if (tag.length) [artistTags addObject:tag];
    }

    return @{
        @"artistTags": artistTags,
        @"titleTags": [self uniqueStringsByCompact:titleTags],
        @"ignored": ignored,
    };
}

- (NSArray<NSString *> *)featuredArtistNamesFromTitles:(NSArray<NSString *> *)titles {
    NSMutableArray<NSString *> *featured = [NSMutableArray array];
    NSRegularExpression *block = YTMULyricsCachedRegex(@"[\\(\\[\\{（【［][^\\)\\]\\}】］）]*(?:feat|ft|featuring)\\.?\\s+([^\\)\\]\\}】］）]+)[\\)\\]\\}】］）]", NSRegularExpressionCaseInsensitive);
    NSRegularExpression *tail = YTMULyricsCachedRegex(@"(?:^|[\\s\\u3000\\(（\\[])(?:feat|ft|featuring)\\.?\\s+(.+)$", NSRegularExpressionCaseInsensitive);
    for (NSString *title in titles ?: @[]) {
        if (!title.length) continue;
        NSArray<NSTextCheckingResult *> *matches = [block matchesInString:title options:0 range:NSMakeRange(0, title.length)];
        for (NSTextCheckingResult *match in matches) {
            if (match.numberOfRanges < 2) continue;
            NSString *value = [title substringWithRange:[match rangeAtIndex:1]];
            if (value.length) [featured addObject:value];
        }
        NSTextCheckingResult *tailMatch = [tail firstMatchInString:title options:0 range:NSMakeRange(0, title.length)];
        if (tailMatch && tailMatch.numberOfRanges >= 2) {
            NSString *value = [title substringWithRange:[tailMatch rangeAtIndex:1]];
            if (value.length) [featured addObject:value];
        }
    }
    return YTMULyricsSplitArtists([featured componentsJoinedByString:@","], nil);
}

- (NSArray<NSString *> *)searchArtistNamesForArtistNames:(NSArray<NSString *> *)artistNames
                                     featuredArtistNames:(NSArray<NSString *> *)featuredArtistNames {
    NSMutableArray<NSString *> *values = [NSMutableArray array];
    NSUInteger primaryCount = MIN((NSUInteger)2, artistNames.count);
    for (NSUInteger idx = 0; idx < primaryCount; idx++) {
        NSString *artist = artistNames[idx];
        if (artist.length) [values addObject:artist];
        NSString *withoutPunctuation = [self stripSearchPunctuation:artist];
        if (withoutPunctuation.length && ![withoutPunctuation isEqualToString:artist]) {
            [values addObject:withoutPunctuation];
        }
    }
    for (NSString *featured in featuredArtistNames ?: @[]) {
        if (featured.length) [values addObject:featured];
    }
    NSArray<NSString *> *unique = [self uniqueStringsBySearchText:values];
    return unique.count > 4 ? [unique subarrayWithRange:NSMakeRange(0, 4)] : unique;
}

- (BOOL)isArtistLike:(NSString *)fragment artistNames:(NSArray<NSString *> *)artistNames {
    NSString *key = YTMULyricsCompactString(fragment ?: @"");
    if (!key.length) return YES;
    if ([self isLikelyArtistFragment:fragment]) return YES;
    for (NSString *artist in artistNames ?: @[]) {
        NSString *artistKey = YTMULyricsCompactString(artist);
        if (!artistKey.length) continue;
        if ([key isEqualToString:artistKey] ||
            (key.length >= 3 && [artistKey containsString:key]) ||
            (artistKey.length >= 3 && [key containsString:artistKey]) ||
            YTMULyricsSimilarity(fragment, artist) >= 0.90) {
            return YES;
        }
    }
    return NO;
}

- (NSString *)cleanTitleFragment:(NSString *)fragment artistNames:(NSArray<NSString *> *)artistNames {
    NSString *clean = YTMULyricsStripSearchNoise(fragment ?: @"");
    if (!clean.length) return @"";

    NSRegularExpression *brackets = YTMULyricsCachedRegex(@"[\\(\\[\\{（【［]([^\\)\\]\\}）】］]+)[\\)\\]\\}）】］]", 0);
    NSMutableString *mutable = [clean mutableCopy];
    NSArray<NSTextCheckingResult *> *matches = [brackets matchesInString:clean options:0 range:NSMakeRange(0, clean.length)];
    for (NSTextCheckingResult *match in [matches reverseObjectEnumerator]) {
        if (match.numberOfRanges < 2) continue;
        NSString *content = [clean substringWithRange:[match rangeAtIndex:1]];
        if ([self isArtistLike:content artistNames:artistNames]) {
            [mutable replaceCharactersInRange:match.range withString:@" "];
        }
    }

    NSRegularExpression *spaces = YTMULyricsCachedRegex(@"\\s+", 0);
    NSString *out = [spaces stringByReplacingMatchesInString:mutable options:0 range:NSMakeRange(0, mutable.length) withTemplate:@" "];
    return [out stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

- (NSArray<NSString *> *)splitTitle:(NSString *)title artistNames:(NSArray<NSString *> *)artistNames {
    NSString *cleaned = [self cleanTitleFragment:title artistNames:artistNames];
    if (!cleaned.length) return @[];

    NSMutableArray<NSString *> *parts = [NSMutableArray arrayWithObject:cleaned];
    NSRegularExpression *quoted = YTMULyricsCachedRegex(@"[「『](.+?)[」』]", 0);
    NSArray<NSTextCheckingResult *> *quoteMatches = [quoted matchesInString:cleaned options:0 range:NSMakeRange(0, cleaned.length)];
    for (NSTextCheckingResult *match in quoteMatches) {
        if (match.numberOfRanges < 2) continue;
        NSString *part = [self cleanTitleFragment:[cleaned substringWithRange:[match rangeAtIndex:1]] artistNames:artistNames];
        if (part.length) [parts addObject:part];
    }

    NSRegularExpression *delimiter = YTMULyricsCachedRegex(@"\\s+[-–—]\\s+|\\s+[/|]\\s+|[／｜│]|\\s+:\\s+|[：]", 0);
    NSString *split = [delimiter stringByReplacingMatchesInString:cleaned options:0 range:NSMakeRange(0, cleaned.length) withTemplate:@"\n"];
    for (NSString *raw in [split componentsSeparatedByString:@"\n"]) {
        NSString *part = [self cleanTitleFragment:raw artistNames:artistNames];
        if (part.length) [parts addObject:part];
    }

    NSMutableArray<NSString *> *unique = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (NSString *part in parts) {
        NSString *key = YTMULyricsCompactString(part);
        if (key.length <= 1 || [seen containsObject:key]) continue;
        if (YTMUNetEaseRegexTest(part, @"\\b(?:official|music\\s*video|mv|pv|lyric|audio)\\b")) continue;
        if ([self isArtistLike:part artistNames:artistNames]) continue;
        [seen addObject:key];
        [unique addObject:part];
    }
    return unique;
}

- (NSArray<NSDictionary *> *)titleCandidatesForInfo:(YTMULyricsSearchInfo *)info
                                        artistNames:(NSArray<NSString *> *)artistNames
                                          titleTags:(NSArray<NSString *> *)titleTags {
    NSMutableArray<NSDictionary *> *candidates = [NSMutableArray array];
    void (^addCandidate)(NSString *, CGFloat, BOOL) = ^(NSString *title, CGFloat weight, BOOL withArtist) {
        NSString *clean = [self cleanTitleFragment:title artistNames:artistNames];
        NSString *key = YTMULyricsCompactString(clean);
        if (!key.length || [self isArtistLike:clean artistNames:artistNames]) return;
        [candidates addObject:@{@"title": clean, @"weight": @(weight), @"withArtist": @(withArtist)}];
    };

    NSMutableArray<NSString *> *rawSourceTitles = [NSMutableArray array];
    if (info.title.length) [rawSourceTitles addObject:info.title];
    if (info.alternativeTitle.length) [rawSourceTitles addObject:info.alternativeTitle];
    for (NSString *tag in titleTags ?: @[]) {
        if (tag.length) [rawSourceTitles addObject:tag];
    }
    NSArray *sourceTitles = [self uniqueStringsByCompact:rawSourceTitles];
    for (NSString *sourceTitle in sourceTitles) {
        if (!sourceTitle.length) continue;
        BOOL sourceLooksSplit = YTMUNetEaseRegexTest(YTMULyricsStripSearchNoise(sourceTitle), @"\\s+[-–—]\\s+|\\s+[/|]\\s+|[／｜│]|\\s+:\\s+|[：]");
        addCandidate(sourceTitle, sourceLooksSplit ? 0.62 : 0.88, NO);

        NSArray<NSString *> *parts = [self splitTitle:sourceTitle artistNames:artistNames];
        for (NSUInteger idx = 0; idx < parts.count; idx++) {
            NSString *part = parts[idx];
            BOOL hasCJK = YTMUNetEaseHasJapaneseOrCJK(part);
            CGFloat weight = idx == 0 ? (hasCJK ? 1.28 : 1.12) : (hasCJK ? 0.96 : 0.78);
            addCandidate(part, weight, YES);
        }
    }

    [candidates sortUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
        CGFloat a = [left[@"weight"] doubleValue];
        CGFloat b = [right[@"weight"] doubleValue];
        if (a > b) return NSOrderedAscending;
        if (a < b) return NSOrderedDescending;
        return NSOrderedSame;
    }];
    NSMutableArray<NSDictionary *> *unique = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (NSDictionary *candidate in candidates) {
        NSString *key = YTMULyricsCompactString(candidate[@"title"] ?: @"");
        if (!key.length || [seen containsObject:key]) continue;
        [seen addObject:key];
        [unique addObject:candidate];
        if (unique.count >= 8) break;
    }
    return unique;
}

- (YTMUNetEaseSearchContext *)searchContextForInfo:(YTMULyricsSearchInfo *)info {
    NSDictionary *tagGroups = [self filterArtistTagValuesForTitle:info.title
                                                 alternativeTitle:info.alternativeTitle
                                                            album:info.album
                                                           artist:info.artist
                                                             tags:info.tags];
    NSArray *artistTags = tagGroups[@"artistTags"] ?: @[];
    YTMUNetEaseSearchContext *context = [[YTMUNetEaseSearchContext alloc] init];
    context.titleTags = tagGroups[@"titleTags"] ?: @[];
    context.artists = YTMULyricsSplitArtists(info.artist, artistTags);
    context.featured = [self featuredArtistNamesFromTitles:@[info.title ?: @"", info.alternativeTitle ?: @""]];
    context.titleCandidates = [self titleCandidatesForInfo:info artistNames:context.artists titleTags:context.titleTags];
    return context;
}

- (NSArray<NSString *> *)keywordsForInfo:(YTMULyricsSearchInfo *)info {
    return [self keywordsForInfo:info context:[self searchContextForInfo:info]];
}

- (NSArray<NSString *> *)keywordsForInfo:(YTMULyricsSearchInfo *)info context:(YTMUNetEaseSearchContext *)context {
    NSArray *artists = context.artists;
    NSArray *featured = context.featured;
    NSArray *titleTags = context.titleTags;
    NSArray<NSDictionary *> *titles = context.titleCandidates;
    NSArray<NSString *> *searchArtists = [self searchArtistNamesForArtistNames:artists featuredArtistNames:featured];
    NSMutableArray *keywords = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    for (NSDictionary *candidate in titles) {
        NSString *title = candidate[@"title"] ?: @"";
        NSString *key = YTMULyricsCompactString(title);
        if (key.length && ![seen containsObject:key]) {
            [seen addObject:key];
            [keywords addObject:title];
        }
        if (![candidate[@"withArtist"] boolValue]) continue;
        for (NSString *artist in searchArtists) {
            NSString *combined = [NSString stringWithFormat:@"%@ %@", title, artist];
            NSString *combinedKey = YTMULyricsCompactString(combined);
            if (combinedKey.length && ![seen containsObject:combinedKey]) {
                [seen addObject:combinedKey];
                [keywords addObject:combined];
            }
        }
        if (keywords.count >= 16) break;
    }
    YTMULyricsLog(@"NetEase prepared search candidates=%lu keywords=%@ artists=%@ titleTags=%@ featured=%@",
                  (unsigned long)titles.count,
                  keywords,
                  artists,
                  titleTags,
                  featured);
    return keywords;
}

- (NSDictionary *)bestTitleScoreForSongTitle:(NSString *)songTitle candidates:(NSArray<NSDictionary *> *)candidates fallbackInfo:(YTMULyricsSearchInfo *)info {
    CGFloat bestScore = MAX(YTMULyricsSimilarity(info.title, songTitle), YTMULyricsSimilarity(info.alternativeTitle, songTitle));
    NSString *bestTitle = info.title ?: @"";
    for (NSDictionary *candidate in candidates) {
        NSString *title = candidate[@"title"] ?: @"";
        CGFloat weight = [candidate[@"weight"] doubleValue];
        CGFloat score = MIN(1.0, YTMULyricsSimilarity(title, songTitle) * MAX(0.1, weight));
        if (score > bestScore) {
            bestScore = score;
            bestTitle = title;
        }
    }
    return @{@"score": @(bestScore), @"title": bestTitle ?: @""};
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

- (BOOL)isAllowedStrictRankedSong:(NSDictionary *)item hasComparableDuration:(BOOL)hasDuration hasArtistNames:(BOOL)hasArtists {
    CGFloat titleScore = [item[@"titleScore"] doubleValue];
    CGFloat artistScore = [item[@"artistScore"] doubleValue];
    NSTimeInterval durationDelta = [item[@"durationDelta"] doubleValue];
    CGFloat score = [item[@"score"] doubleValue];
    BOOL latinOnlyTitle = [item[@"latinOnlyTitle"] boolValue];
    BOOL ambiguousLatinTitle = [item[@"ambiguousLatinTitle"] boolValue];

    if (titleScore < YTMUNetEaseStrictMinTitle) return NO;
    if (hasDuration && durationDelta > YTMUNetEaseStrictMaxDurationDelta) return NO;
    if (hasDuration && durationDelta > YTMUNetEaseStrictSoftDurationDelta && titleScore < YTMUNetEaseStrictTitleForSoftDuration) return NO;
    if (artistScore < YTMUNetEaseStrictMinArtist && titleScore < YTMUNetEaseStrictTitleOverridesArtist) return NO;
    if (latinOnlyTitle && hasArtists && artistScore < YTMUNetEaseStrictMinArtist) return NO;
    if (ambiguousLatinTitle && artistScore < YTMUNetEaseStrictMinArtistAmbiguousLatin) return NO;
    return score >= YTMUNetEaseStrictMinScore;
}

- (BOOL)isAllowedInexactRankedSong:(NSDictionary *)item hasComparableDuration:(BOOL)hasDuration hasArtistNames:(BOOL)hasArtists {
    if (!YTMULyricsSettingsBool(@"lyricsShowInexact", YES)) return NO;

    CGFloat titleScore = [item[@"titleScore"] doubleValue];
    CGFloat artistScore = [item[@"artistScore"] doubleValue];
    NSTimeInterval durationDelta = [item[@"durationDelta"] doubleValue];
    CGFloat score = [item[@"score"] doubleValue];
    BOOL latinOnlyTitle = [item[@"latinOnlyTitle"] boolValue];
    BOOL ambiguousLatinTitle = [item[@"ambiguousLatinTitle"] boolValue];

    if (titleScore < YTMUNetEaseInexactMinTitle) return NO;
    if (hasDuration && durationDelta > YTMUNetEaseInexactMaxDurationDelta) return NO;
    if (titleScore < YTMUNetEaseInexactTitleNeedsArtistBelow && artistScore < YTMUNetEaseInexactMinArtist) return NO;
    if (latinOnlyTitle && hasArtists && artistScore < YTMUNetEaseInexactMinArtist && titleScore < YTMUNetEaseInexactLatinTitleOverride) return NO;
    if (ambiguousLatinTitle && artistScore < YTMUNetEaseInexactMinArtistAmbiguousLatin) return NO;
    return score >= YTMUNetEaseInexactMinScore;
}

- (NSArray<NSDictionary *> *)candidateSongsFromSongs:(NSArray<NSDictionary *> *)songs info:(YTMULyricsSearchInfo *)info {
    return [self candidateSongsFromSongs:songs info:info context:[self searchContextForInfo:info]];
}

- (NSArray<NSDictionary *> *)candidateSongsFromSongs:(NSArray<NSDictionary *> *)songs
                                                info:(YTMULyricsSearchInfo *)info
                                             context:(YTMUNetEaseSearchContext *)context {
    NSArray *artists = context.artists;
    NSArray *featured = context.featured;
    NSMutableArray<NSString *> *scoreArtistValues = [NSMutableArray arrayWithArray:artists ?: @[]];
    [scoreArtistValues addObjectsFromArray:featured ?: @[]];
    NSArray *scoreArtistNames = [self uniqueStringsBySearchText:scoreArtistValues];
    NSArray *titleCandidates = context.titleCandidates;
    NSMutableArray<NSDictionary *> *ranked = [NSMutableArray array];
    BOOL hasDuration = isfinite(info.duration) && info.duration > 0;
    for (id candidate in songs) {
        if (![candidate isKindOfClass:[NSDictionary class]]) continue;
        NSDictionary *song = candidate;
        NSString *name = YTMULyricsJSONStringAtPath(song, @[@"name"]) ?: @"";
        NSString *cleanName = YTMULyricsStripSearchNoise(name);
        NSDictionary *titleMatch = [self bestTitleScoreForSongTitle:cleanName candidates:titleCandidates fallbackInfo:info];
        CGFloat titleScore = [titleMatch[@"score"] doubleValue];
        NSString *bestTitle = titleMatch[@"title"] ?: @"";
        CGFloat artistScore = [self artistScoreForSong:song artistNames:scoreArtistNames];
        NSTimeInterval duration = [YTMULyricsJSONNumberAtPath(song, @[@"duration"]) doubleValue] / 1000.0;
        NSTimeInterval delta = hasDuration ? fabs(duration - info.duration) : 0;
        BOOL latinOnlyTitle = YTMUNetEaseHasLatin(bestTitle.length ? bestTitle : info.title) && !YTMUNetEaseHasJapaneseOrCJK(bestTitle.length ? bestTitle : info.title);
        BOOL ambiguousLatinTitle = latinOnlyTitle && YTMULyricsCompactString(bestTitle.length ? bestTitle : info.title).length <= 6;
        CGFloat durationScore = hasDuration ? MAX(0, 1 - delta / YTMUNetEaseDurationDecaySeconds) : YTMUNetEaseDurationScoreWhenUnknown;
        CGFloat score = titleScore * YTMUNetEaseWeightTitle + artistScore * YTMUNetEaseWeightArtist + durationScore * YTMUNetEaseWeightDuration;
        [ranked addObject:@{
            @"song": song,
            @"titleScore": @(titleScore),
            @"artistScore": @(artistScore),
            @"durationDelta": @(delta),
            @"score": @(score),
            @"ambiguousLatinTitle": @(ambiguousLatinTitle),
            @"latinOnlyTitle": @(latinOnlyTitle),
        }];
    }

    [ranked sortUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
        CGFloat a = [left[@"score"] doubleValue];
        CGFloat b = [right[@"score"] doubleValue];
        if (fabs(b - a) > YTMUNetEaseScoreTieWindow) {
            if (a > b) return NSOrderedAscending;
            if (a < b) return NSOrderedDescending;
        }
        NSTimeInterval leftDelta = [left[@"durationDelta"] doubleValue];
        NSTimeInterval rightDelta = [right[@"durationDelta"] doubleValue];
        if (leftDelta < rightDelta) return NSOrderedAscending;
        if (leftDelta > rightDelta) return NSOrderedDescending;
        // Exact ties: order by song id so the pick is stable across plays
        // (the input comes from a dictionary's allValues, whose order is
        // arbitrary, and sortUsingComparator: is not stable).
        NSNumber *leftId = YTMULyricsJSONNumberAtPath(left[@"song"], @[@"id"]) ?: @0;
        NSNumber *rightId = YTMULyricsJSONNumberAtPath(right[@"song"], @[@"id"]) ?: @0;
        return [leftId compare:rightId];
    }];

    BOOL hasArtists = scoreArtistNames.count > 0;
    NSMutableArray<NSDictionary *> *strictMatches = [NSMutableArray array];
    NSMutableSet<NSNumber *> *strictIds = [NSMutableSet set];
    for (NSDictionary *item in ranked) {
        if (![self isAllowedStrictRankedSong:item hasComparableDuration:hasDuration hasArtistNames:hasArtists]) continue;
        NSMutableDictionary *match = [item mutableCopy];
        match[@"strict"] = @YES;
        [strictMatches addObject:match];
        NSNumber *songId = YTMULyricsJSONNumberAtPath(item[@"song"], @[@"id"]);
        if (songId) [strictIds addObject:songId];
    }

    NSMutableArray<NSDictionary *> *matches = [NSMutableArray arrayWithArray:strictMatches];
    for (NSDictionary *item in ranked) {
        NSNumber *songId = YTMULyricsJSONNumberAtPath(item[@"song"], @[@"id"]);
        if (songId && [strictIds containsObject:songId]) continue;
        if (![self isAllowedInexactRankedSong:item hasComparableDuration:hasDuration hasArtistNames:hasArtists]) continue;
        NSMutableDictionary *match = [item mutableCopy];
        match[@"strict"] = @NO;
        [matches addObject:match];
    }

    NSMutableArray *debugTop = [NSMutableArray array];
    for (NSUInteger idx = 0; idx < MIN((NSUInteger)8, ranked.count); idx++) {
        NSDictionary *item = ranked[idx];
        NSDictionary *song = item[@"song"];
        NSMutableArray *names = [NSMutableArray array];
        for (id artist in YTMULyricsJSONArrayAtPath(song, @[@"artists"]) ?: @[]) {
            NSString *artistName = YTMULyricsJSONStringAtPath(artist, @[@"name"]);
            if (artistName.length) [names addObject:artistName];
        }
        [debugTop addObject:@{
            @"id": YTMULyricsJSONNumberAtPath(song, @[@"id"]) ?: @0,
            @"title": YTMULyricsJSONStringAtPath(song, @[@"name"]) ?: @"",
            @"artists": names,
            @"titleScore": item[@"titleScore"] ?: @0,
            @"artistScore": item[@"artistScore"] ?: @0,
            @"durationDelta": item[@"durationDelta"] ?: @0,
            @"score": item[@"score"] ?: @0,
        }];
    }
    YTMULyricsLog(@"NetEase ranked results count=%lu matches=%lu scoreArtists=%@ top=%@",
                  (unsigned long)ranked.count,
                  (unsigned long)matches.count,
                  scoreArtistNames,
                  debugTop);
    return matches;
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

- (NSString *)timeStringForMilliseconds:(NSTimeInterval)timeInMs {
    NSInteger totalMs = MAX(0, (NSInteger)llround(timeInMs));
    return [NSString stringWithFormat:@"%02ld:%02ld.%02ld",
            (long)(totalMs / 60000),
            (long)((totalMs % 60000) / 1000),
            (long)((totalMs % 1000) / 10)];
}

- (BOOL)isNetEaseCreditLine:(NSString *)text timeInMs:(NSTimeInterval)timeInMs {
    if (timeInMs > 12000) return NO;
    NSString *trimmed = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!trimmed.length) return NO;
    return YTMUNetEaseRegexTest(trimmed, @"^(?:作词|作詞|作曲|编曲|編曲|制作人|和声|和聲|混音|母带|母帶|录音|錄音|吉他|贝斯|貝斯|鼓|钢琴|鋼琴|键盘|鍵盤|Lyricist|Composer|Arranger|Producer|Mixing|Mastering|Vocal|Guitar|Bass|Drums)\\s*[:：]");
}

- (NSArray<YTMULyricLine *> *)normalizedNetEaseLines:(NSArray<YTMULyricLine *> *)sourceLines {
    NSMutableArray<YTMULyricLine *> *lines = [NSMutableArray arrayWithCapacity:sourceLines.count];
    for (YTMULyricLine *line in sourceLines ?: @[]) {
        if (line) [lines addObject:[line copy]];
    }

    [lines sortUsingComparator:^NSComparisonResult(YTMULyricLine *a, YTMULyricLine *b) {
        if (a.timeInMs < b.timeInMs) return NSOrderedAscending;
        if (a.timeInMs > b.timeInMs) return NSOrderedDescending;
        return NSOrderedSame;
    }];

    for (NSUInteger idx = 0; idx < lines.count; idx++) {
        YTMULyricLine *line = lines[idx];
        if (idx + 1 < lines.count) {
            line.durationMs = MAX(0, lines[idx + 1].timeInMs - line.timeInMs);
        } else if (!isfinite(line.durationMs) || line.durationMs <= 0) {
            line.durationMs = 3500;
        }
    }
    if (lines.firstObject && lines.firstObject.timeInMs > 300) {
        YTMULyricLine *empty = [YTMULyricLine lineWithTime:@"00:00.00"
                                                  timeInMs:0
                                                durationMs:lines.firstObject.timeInMs
                                                      text:@""];
        [lines insertObject:empty atIndex:0];
    }
    return lines;
}

- (NSArray<YTMULyricLine *> *)parseNetEaseJSONLyrics:(NSString *)lyrics {
    if (!lyrics.length) return @[];
    NSMutableArray<YTMULyricLine *> *lines = [NSMutableArray array];
    for (NSString *rawLine in [lyrics componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        NSString *line = [rawLine stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (!line.length || ![line hasPrefix:@"{"]) continue;
        NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
        NSError *error = nil;
        id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:&error] : nil;
        if (![json isKindOfClass:[NSDictionary class]]) continue;
        NSNumber *time = YTMULyricsJSONNumberAtPath(json, @[@"t"]);
        NSArray *segments = YTMULyricsJSONArrayAtPath(json, @[@"c"]);
        if (!time || ![segments isKindOfClass:[NSArray class]]) continue;

        NSMutableString *text = [NSMutableString string];
        for (id segment in segments) {
            NSString *piece = YTMULyricsJSONStringAtPath(segment, @[@"tx"]);
            if (piece.length) [text appendString:piece];
        }
        NSString *trimmed = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSTimeInterval timeInMs = time.doubleValue;
        if ([self isNetEaseCreditLine:trimmed timeInMs:timeInMs]) continue;
        [lines addObject:[YTMULyricLine lineWithTime:[self timeStringForMilliseconds:timeInMs]
                                            timeInMs:timeInMs
                                          durationMs:INFINITY
                                                text:trimmed]];
    }
    return [self normalizedNetEaseLines:lines];
}

- (NSArray<YTMULyricLine *> *)parseNetEaseLyrics:(NSString *)lyrics {
    NSArray<YTMULyricLine *> *lrcLines = [YTMULRCParser parseLRC:[YTMULRCParser stripNetEaseMetadata:lyrics]];
    NSMutableArray<YTMULyricLine *> *kept = [NSMutableArray array];
    BOOL hasText = NO;
    for (YTMULyricLine *line in lrcLines ?: @[]) {
        NSString *text = [line.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if ([self isNetEaseCreditLine:line.text timeInMs:line.timeInMs]) continue;
        [kept addObject:line];
        if (text.length) hasText = YES;
    }
    if (hasText) return [self normalizedNetEaseLines:kept];
    return [self parseNetEaseJSONLyrics:lyrics];
}

- (NSString *)plainLyricsFromLines:(NSArray<YTMULyricLine *> *)lines {
    NSMutableArray<NSString *> *parts = [NSMutableArray arrayWithCapacity:lines.count];
    for (YTMULyricLine *line in lines) {
        NSString *text = [line.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (text.length) [parts addObject:text];
    }
    return [parts componentsJoinedByString:@"\n"];
}

- (NSArray<NSString *> *)romanizedTextsFromLyrics:(NSString *)romanizedLyrics sourceLines:(NSArray<YTMULyricLine *> *)sourceLines {
    if (!romanizedLyrics.length || !sourceLines.count) return @[];
    NSArray<YTMULyricLine *> *romanizedLines = [YTMULRCParser parseLRC:romanizedLyrics];
    if (!romanizedLines.count) return @[];

    NSMutableArray<NSString *> *aligned = [NSMutableArray arrayWithCapacity:sourceLines.count];
    for (NSUInteger i = 0; i < sourceLines.count; i++) [aligned addObject:@""];

    if (romanizedLines.count == sourceLines.count) {
        for (NSUInteger i = 0; i < sourceLines.count; i++) {
            aligned[i] = romanizedLines[i].text ?: @"";
        }
        return aligned;
    }

    NSMutableSet<NSNumber *> *used = [NSMutableSet set];
    for (NSUInteger idx = 0; idx < sourceLines.count; idx++) {
        YTMULyricLine *source = sourceLines[idx];
        if (![source.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].length) continue;
        NSUInteger bestIndex = NSNotFound;
        NSTimeInterval bestDelta = DBL_MAX;
        for (NSUInteger r = 0; r < romanizedLines.count; r++) {
            if ([used containsObject:@(r)]) continue;
            YTMULyricLine *roman = romanizedLines[r];
            NSString *text = [roman.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (!text.length) continue;
            NSTimeInterval delta = fabs(roman.timeInMs - source.timeInMs);
            if (delta < bestDelta) {
                bestDelta = delta;
                bestIndex = r;
            }
        }
        if (bestIndex != NSNotFound && bestDelta <= 500.0) {
            aligned[idx] = romanizedLines[bestIndex].text ?: @"";
            [used addObject:@(bestIndex)];
        }
    }
    return aligned;
}

- (void)resolveCandidateMatches:(NSArray<NSDictionary *> *)matches
                           index:(NSUInteger)index
                            info:(YTMULyricsSearchInfo *)info
                      completion:(void (^)(YTMULyricsResult *, NSError *))completion {
    if (index >= matches.count) {
        completion(nil, nil);
        return;
    }

    NSDictionary *match = matches[index];
    NSDictionary *best = match[@"song"];
    NSNumber *songId = YTMULyricsJSONNumberAtPath(best, @[@"id"]);
    if (!songId) {
        [self resolveCandidateMatches:matches index:index + 1 info:info completion:completion];
        return;
    }

    [self getLyric:songId completion:^(NSDictionary *lyric) {
        NSString *rawLyrics = YTMULyricsJSONStringAtPath(lyric, @[@"lrc", @"lyric"]) ?: @"";
        NSArray<YTMULyricLine *> *parsedLines = [self parseNetEaseLyrics:rawLyrics];
        NSString *plainLyrics = [self plainLyricsFromLines:parsedLines];
        if (!plainLyrics.length) {
            YTMULyricsLog(@"NetEase skipped empty lyric id=%@ title=%@ rawLength=%lu",
                          songId,
                          YTMULyricsJSONStringAtPath(best, @[@"name"]) ?: @"",
                          (unsigned long)rawLyrics.length);
            [self resolveCandidateMatches:matches index:index + 1 info:info completion:completion];
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
        result.plainLyrics = plainLyrics;
        result.lines = parsedLines;
        result.duration = [YTMULyricsJSONNumberAtPath(best, @[@"duration"]) doubleValue] / 1000.0;
        result.inexact = ![match[@"strict"] boolValue];

        NSString *romanized = [YTMULRCParser stripNetEaseMetadata:YTMULyricsJSONStringAtPath(lyric, @[@"romalrc", @"lyric"]) ?: @""];
        NSArray<NSString *> *romanizedTexts = [self romanizedTextsFromLyrics:romanized sourceLines:result.lines];
        if (romanizedTexts.count == result.lines.count) {
            result.romanizedLineTexts = romanizedTexts;
            NSMutableArray<YTMULyricLine *> *lines = [NSMutableArray arrayWithCapacity:result.lines.count];
            for (NSUInteger idx = 0; idx < result.lines.count; idx++) {
                YTMULyricLine *line = [result.lines[idx] copy];
                line.romanizedText = idx < romanizedTexts.count ? romanizedTexts[idx] : @"";
                [lines addObject:line];
            }
            result.lines = lines;
        }
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
        YTMULyricsLog(@"NetEase match title=%@ artists=%@ lines=%lu inexact=%d translation=%d",
                      result.title,
                      result.artists,
                      (unsigned long)result.lineTexts.count,
                      result.inexact,
                      result.officialTranslatedLines.count > 0);
        completion(result.hasText ? result : nil, nil);
    }];
}

- (void)searchWithInfo:(YTMULyricsSearchInfo *)info completion:(void (^)(YTMULyricsResult *, NSError *))completion {
    // Keyword generation and candidate scoring are regex / similarity
    // heavy. registerIfNeeded: calls `ready` synchronously once the session
    // is registered, i.e. on the caller's (main) thread — hop off it first.
    // Every completion path below already runs on a background queue, so
    // callers see no difference.
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
    [self registerIfNeeded:^{
        YTMUNetEaseSearchContext *context = [self searchContextForInfo:info];
        NSArray *keywords = [self keywordsForInfo:info context:context];
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
            NSArray<NSDictionary *> *matches = [self candidateSongsFromSongs:unique.allValues info:info context:context];
            if (!matches.count) {
                completion(nil, nil);
                return;
            }
            [self resolveCandidateMatches:matches index:0 info:info completion:completion];
        });
    } failure:^(NSError *error) {
        completion(nil, error);
    }];
    });
}

@end
