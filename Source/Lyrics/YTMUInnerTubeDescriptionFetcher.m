#import "YTMUInnerTubeDescriptionFetcher.h"
#import "YTMULyricsTypes.h"
#import <CommonCrypto/CommonDigest.h>

// Persistent cache layout:
//   $CACHES/YTMUltimate/InnerTubeDescription/<sha1(videoId)>.plist
// Plist keys:
//   v          : schema version (currently 1)
//   text       : the full description string ("" means no description)
//   ts         : epoch seconds when this cache entry was written
//
// Cached entries live for YTMUInnerTubeCacheTTL after which we re-fetch.
//
// Failure tracking lives in NSUserDefaults under
//   YTMUInnerTubeFetchFailures = { videoId: { count: int, ts: epoch } }
// videoIds with count >= 3 are skipped for 6h after the last failure.

static const NSInteger YTMUInnerTubeSchemaVersion = 1;
static const NSTimeInterval YTMUInnerTubeCacheTTL = 30 * 24 * 60 * 60; // 30 days
static const NSInteger YTMUInnerTubeFailureThreshold = 3;
static const NSTimeInterval YTMUInnerTubeBlacklistDuration = 6 * 60 * 60;
static const NSTimeInterval YTMUInnerTubeRequestTimeout = 8.0;
static NSString *const YTMUInnerTubeFailuresKey = @"YTMUInnerTubeFetchFailures";

// IOS InnerTube client identifiers. These come straight from yt-dlp's
// upstream extractor (the "ios" client) and are the most reliable way to
// pull a full microformat + description without auth or signature
// solving. They will need updating periodically as YouTube bumps client
// versions; if requests start returning errors we should refresh these
// from yt-dlp's `_INNERTUBE_CLIENTS` table.
static NSString *const YTMUInnerTubeIOSAPIKey = @"AIzaSyB-63vPrdThhKuerbB2N_l7Kwwcxj6yUAc";
static NSString *const YTMUInnerTubeIOSClientName = @"IOS";
static NSString *const YTMUInnerTubeIOSClientVersion = @"20.10.38";
static NSString *const YTMUInnerTubeIOSDeviceModel = @"iPhone16,2";
static NSString *const YTMUInnerTubeIOSOSVersion = @"18.1.0.22B83";
static NSString *const YTMUInnerTubeIOSUserAgent =
    @"com.google.ios.youtube/20.10.38 (iPhone16,2; U; CPU iOS 18_1_1 like Mac OS X)";

static NSString *YTMUInnerTubeSHA1(NSString *string) {
    NSData *data = [string dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
    unsigned char digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *output = [NSMutableString stringWithCapacity:CC_SHA1_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA1_DIGEST_LENGTH; i++) [output appendFormat:@"%02x", digest[i]];
    return output;
}

static NSError *YTMUInnerTubeError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"YTMUInnerTubeDescriptionFetcher"
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: message ?: @"fetch failed"}];
}

@interface YTMUInnerTubeDescriptionFetcher ()
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) dispatch_queue_t ioQueue;
// In-flight: videoId → array of pending completions. While a request
// is in flight, follow-on calls join the queue. Guarded by @synchronized.
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSMutableArray<YTMUInnerTubeDescriptionCompletion> *> *inflight;
@end

@implementation YTMUInnerTubeDescriptionFetcher

+ (instancetype)sharedFetcher {
    static YTMUInnerTubeDescriptionFetcher *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [[self alloc] init]; });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        config.timeoutIntervalForRequest = YTMUInnerTubeRequestTimeout;
        config.timeoutIntervalForResource = YTMUInnerTubeRequestTimeout;
        config.HTTPAdditionalHeaders = @{
            @"User-Agent": YTMUInnerTubeIOSUserAgent,
            @"X-YouTube-Client-Name": @"5",
            @"X-YouTube-Client-Version": YTMUInnerTubeIOSClientVersion,
            @"Accept-Language": @"en-US,en;q=0.9",
        };
        _session = [NSURLSession sessionWithConfiguration:config];
        _ioQueue = dispatch_queue_create("com.ytmultimate.innertube-fetch", DISPATCH_QUEUE_SERIAL);
        _inflight = [NSMutableDictionary dictionary];
    }
    return self;
}

#pragma mark - Disk cache

- (NSString *)cacheDirectory {
    NSString *cacheRoot = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    return [[cacheRoot stringByAppendingPathComponent:@"YTMUltimate"] stringByAppendingPathComponent:@"InnerTubeDescription"];
}

- (NSString *)filePathForVideoId:(NSString *)videoId {
    return [[self cacheDirectory] stringByAppendingPathComponent:[YTMUInnerTubeSHA1(videoId) stringByAppendingString:@".plist"]];
}

- (nullable NSString *)cachedDescriptionForVideoId:(NSString *)videoId {
    if (!videoId.length) return nil;
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:[self filePathForVideoId:videoId]];
    if (![dict isKindOfClass:[NSDictionary class]]) return nil;
    if ([dict[@"v"] integerValue] != YTMUInnerTubeSchemaVersion) return nil;
    NSTimeInterval ts = [dict[@"ts"] doubleValue];
    if (ts > 0 && ([[NSDate date] timeIntervalSince1970] - ts) > YTMUInnerTubeCacheTTL) return nil;
    NSString *text = [dict[@"text"] isKindOfClass:[NSString class]] ? dict[@"text"] : nil;
    return text; // empty string is a valid "confirmed no description" cache entry
}

- (void)writeCacheText:(NSString *)text forVideoId:(NSString *)videoId {
    if (!videoId.length || !text) return;
    NSDictionary *plist = @{
        @"v":    @(YTMUInnerTubeSchemaVersion),
        @"text": text,
        @"ts":   @([[NSDate date] timeIntervalSince1970]),
    };
    dispatch_async(self.ioQueue, ^{
        NSString *dir = [self cacheDirectory];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:nil];
        [plist writeToFile:[self filePathForVideoId:videoId] atomically:YES];
    });
}

#pragma mark - Failure blacklist

- (NSDictionary *)allFailures {
    NSDictionary *dict = [[NSUserDefaults standardUserDefaults] dictionaryForKey:YTMUInnerTubeFailuresKey];
    return [dict isKindOfClass:[NSDictionary class]] ? dict : @{};
}

- (void)setAllFailures:(NSDictionary *)failures {
    [[NSUserDefaults standardUserDefaults] setObject:(failures ?: @{}) forKey:YTMUInnerTubeFailuresKey];
}

- (BOOL)isBlacklistedForVideoId:(NSString *)videoId {
    if (!videoId.length) return NO;
    NSDictionary *entry = [self allFailures][videoId];
    if (![entry isKindOfClass:[NSDictionary class]]) return NO;
    NSInteger count = [entry[@"count"] integerValue];
    NSTimeInterval ts = [entry[@"ts"] doubleValue];
    if (count < YTMUInnerTubeFailureThreshold) return NO;
    NSTimeInterval age = [[NSDate date] timeIntervalSince1970] - ts;
    return age >= 0 && age < YTMUInnerTubeBlacklistDuration;
}

- (void)recordFailureForVideoId:(NSString *)videoId {
    if (!videoId.length) return;
    NSMutableDictionary *all = [[self allFailures] mutableCopy];
    NSMutableDictionary *entry = [[all[videoId] isKindOfClass:[NSDictionary class]] ? all[videoId] : @{} mutableCopy];
    entry[@"count"] = @([entry[@"count"] integerValue] + 1);
    entry[@"ts"] = @([[NSDate date] timeIntervalSince1970]);
    all[videoId] = entry;
    [self setAllFailures:all];
}

- (void)clearFailureForVideoId:(NSString *)videoId {
    if (!videoId.length) return;
    NSMutableDictionary *all = [[self allFailures] mutableCopy];
    if (all[videoId]) {
        [all removeObjectForKey:videoId];
        [self setAllFailures:all];
    }
}

#pragma mark - Request building & parsing

- (NSURLRequest *)requestForVideoId:(NSString *)videoId {
    NSString *urlString = [NSString stringWithFormat:
        @"https://www.youtube.com/youtubei/v1/player?key=%@&prettyPrint=false",
        YTMUInnerTubeIOSAPIKey];
    NSURL *url = [NSURL URLWithString:urlString];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    request.timeoutInterval = YTMUInnerTubeRequestTimeout;
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];

    NSDictionary *body = @{
        @"context": @{
            @"client": @{
                @"clientName":     YTMUInnerTubeIOSClientName,
                @"clientVersion":  YTMUInnerTubeIOSClientVersion,
                @"deviceMake":     @"Apple",
                @"deviceModel":    YTMUInnerTubeIOSDeviceModel,
                @"platform":       @"MOBILE",
                @"osName":         @"iPhone",
                @"osVersion":      YTMUInnerTubeIOSOSVersion,
                @"hl":             @"en",
                @"gl":             @"US",
                @"userAgent":      YTMUInnerTubeIOSUserAgent,
            },
        },
        @"videoId":        videoId ?: @"",
        @"contentCheckOk": @YES,
        @"racyCheckOk":    @YES,
    };
    NSError *error = nil;
    NSData *bodyData = [NSJSONSerialization dataWithJSONObject:body options:0 error:&error];
    if (!bodyData) return nil;
    request.HTTPBody = bodyData;
    return request;
}

// Pull the description out of a parsed InnerTube response. Tries every
// known location in the response shape; returns @"" when the request
// succeeded but the video genuinely has no description (private/empty).
- (NSString *)descriptionFromResponse:(NSDictionary *)json {
    if (![json isKindOfClass:[NSDictionary class]]) return nil;

    // Path 1: videoDetails.shortDescription. The IOS client populates
    // this for almost every video — this is the primary path.
    NSDictionary *videoDetails = json[@"videoDetails"];
    if ([videoDetails isKindOfClass:[NSDictionary class]]) {
        NSString *desc = videoDetails[@"shortDescription"];
        if ([desc isKindOfClass:[NSString class]]) return desc;
    }

    // Path 2: microformat.playerMicroformatRenderer.description.simpleText
    NSDictionary *microformat = json[@"microformat"];
    if ([microformat isKindOfClass:[NSDictionary class]]) {
        NSDictionary *renderer = microformat[@"playerMicroformatRenderer"];
        if ([renderer isKindOfClass:[NSDictionary class]]) {
            NSDictionary *descObj = renderer[@"description"];
            if ([descObj isKindOfClass:[NSDictionary class]]) {
                NSString *simple = descObj[@"simpleText"];
                if ([simple isKindOfClass:[NSString class]] && simple.length) return simple;
                NSArray *runs = descObj[@"runs"];
                if ([runs isKindOfClass:[NSArray class]] && runs.count) {
                    NSMutableString *joined = [NSMutableString string];
                    for (id run in runs) {
                        if (![run isKindOfClass:[NSDictionary class]]) continue;
                        NSString *t = ((NSDictionary *)run)[@"text"];
                        if ([t isKindOfClass:[NSString class]]) [joined appendString:t];
                    }
                    return joined;
                }
            }
        }
    }

    return nil;
}

#pragma mark - Public

- (void)fetchDescriptionForVideoId:(NSString *)videoId completion:(YTMUInnerTubeDescriptionCompletion)completion {
    if (!completion) return;
    if (!videoId.length) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(nil, YTMUInnerTubeError(1, @"missing videoId"));
        });
        return;
    }

    NSString *cached = [self cachedDescriptionForVideoId:videoId];
    if (cached) {
        YTMULyricsLog(@"innertube cache hit videoId=%@ len=%lu", videoId, (unsigned long)cached.length);
        dispatch_async(dispatch_get_main_queue(), ^{ completion(cached, nil); });
        return;
    }

    if ([self isBlacklistedForVideoId:videoId]) {
        YTMULyricsLog(@"innertube blacklisted videoId=%@ — skipping fetch", videoId);
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(nil, YTMUInnerTubeError(2, @"videoId blacklisted after repeated failures"));
        });
        return;
    }

    YTMUInnerTubeDescriptionCompletion completionCopy = [completion copy];
    BOOL alreadyInFlight = NO;
    @synchronized (self.inflight) {
        NSMutableArray *queue = self.inflight[videoId];
        if (queue) {
            [queue addObject:completionCopy];
            alreadyInFlight = YES;
        } else {
            self.inflight[videoId] = [NSMutableArray arrayWithObject:completionCopy];
        }
    }
    if (alreadyInFlight) {
        YTMULyricsLog(@"innertube joined in-flight videoId=%@", videoId);
        return;
    }

    NSURLRequest *request = [self requestForVideoId:videoId];
    if (!request) {
        [self fanoutForVideoId:videoId result:nil error:YTMUInnerTubeError(3, @"failed to build request")];
        return;
    }

    YTMULyricsLog(@"innertube fetch start videoId=%@", videoId);
    NSDate *start = [NSDate date];
    __weak typeof(self) weakSelf = self;
    NSURLSessionDataTask *task = [self.session dataTaskWithRequest:request
                                                 completionHandler:^(NSData *data, NSURLResponse *response, NSError *netError) {
        NSTimeInterval elapsed = [[NSDate date] timeIntervalSinceDate:start];
        if (netError) {
            YTMULyricsLog(@"innertube network error videoId=%@ err=%@ (%.2fs)",
                          videoId, netError.localizedDescription, elapsed);
            [weakSelf recordFailureForVideoId:videoId];
            [weakSelf fanoutForVideoId:videoId result:nil error:netError];
            return;
        }
        NSInteger status = [(NSHTTPURLResponse *)response statusCode];
        if (status < 200 || status >= 300) {
            YTMULyricsLog(@"innertube HTTP %ld videoId=%@ (%.2fs)", (long)status, videoId, elapsed);
            [weakSelf recordFailureForVideoId:videoId];
            [weakSelf fanoutForVideoId:videoId
                                result:nil
                                 error:YTMUInnerTubeError(status, [NSString stringWithFormat:@"HTTP %ld", (long)status])];
            return;
        }
        NSError *jsonError = nil;
        id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError] : nil;
        if (!json || jsonError) {
            YTMULyricsLog(@"innertube parse failed videoId=%@ err=%@ (%.2fs)",
                          videoId, jsonError.localizedDescription, elapsed);
            [weakSelf recordFailureForVideoId:videoId];
            [weakSelf fanoutForVideoId:videoId result:nil error:jsonError ?: YTMUInnerTubeError(4, @"invalid JSON")];
            return;
        }

        NSString *description = [weakSelf descriptionFromResponse:json];
        if (description == nil) {
            // No description shape we recognize. Treat as transient
            // failure — record and back off.
            YTMULyricsLog(@"innertube no description path matched videoId=%@ keys=%@",
                          videoId, [[json isKindOfClass:[NSDictionary class]] ? [(NSDictionary *)json allKeys] : @[] componentsJoinedByString:@","]);
            [weakSelf recordFailureForVideoId:videoId];
            [weakSelf fanoutForVideoId:videoId result:nil error:YTMUInnerTubeError(5, @"no description in response")];
            return;
        }

        // Empty string is a valid "video genuinely has no description"
        // result — cache it so we don't retry every play.
        YTMULyricsLog(@"innertube fetch ok videoId=%@ len=%lu (%.2fs)",
                      videoId, (unsigned long)description.length, elapsed);
        [weakSelf writeCacheText:description forVideoId:videoId];
        [weakSelf clearFailureForVideoId:videoId];
        [weakSelf fanoutForVideoId:videoId result:description error:nil];
    }];
    [task resume];
}

- (void)fanoutForVideoId:(NSString *)videoId result:(NSString *)description error:(NSError *)error {
    NSArray<YTMUInnerTubeDescriptionCompletion> *callbacks;
    @synchronized (self.inflight) {
        callbacks = [self.inflight[videoId] copy];
        [self.inflight removeObjectForKey:videoId];
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        for (YTMUInnerTubeDescriptionCompletion cb in callbacks) cb(description, error);
    });
}

- (void)clearCache {
    dispatch_async(self.ioQueue, ^{
        [[NSFileManager defaultManager] removeItemAtPath:[self cacheDirectory] error:nil];
    });
    [self setAllFailures:@{}];
}

@end
