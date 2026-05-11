#import "YTMUInnerTubeDescriptionFetcher.h"
#import "YTMULyricsTypes.h"
#import "../Utils/NSBundle+YTMU.h"
#import <CommonCrypto/CommonDigest.h>

// Persistent cache layout (v3 schema):
//   $CACHES/YTMUltimate/InnerTubeDescription/<sha1(videoId)>.plist
// Plist keys:
//   v          : schema version (currently 3)
//   text       : description string ("" = confirmed no description)
//   title      : canonical video title ("" = none extracted)
//   ts         : epoch seconds when this cache entry was written
//
// Schema bumps:
//   v=1: only `text` (description string)
//   v=2: same; failure-blacklist semantics fixed
//   v=3: added `title` so we can override YT Music's simplified
//        song-title with the full video title

static const NSInteger YTMUInnerTubeSchemaVersion = 3;
static const NSTimeInterval YTMUInnerTubeCacheTTL = 30 * 24 * 60 * 60; // 30 days
static const NSInteger YTMUInnerTubeFailureThreshold = 3;
static const NSTimeInterval YTMUInnerTubeBlacklistDuration = 6 * 60 * 60;
static const NSTimeInterval YTMUInnerTubeRequestTimeout = 8.0;
static NSString *const YTMUInnerTubeFailuresKey = @"YTMUInnerTubeFetchFailures";

// We use the WEB InnerTube client. WEB has a stable public API key
// and consistently returns full videoDetails + microformat blocks
// for music videos. The previous IOS client occasionally returned
// stripped responses for music content (only response-level fields,
// no videoDetails) which left us unable to extract anything. WEB
// behaves the same as fetching the watch page in a browser.
static NSString *const YTMUInnerTubeAPIKey = @"AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8";
static NSString *const YTMUInnerTubeClientName = @"WEB";
static NSString *const YTMUInnerTubeClientVersion = @"2.20241010.05.00";
static NSString *const YTMUInnerTubeUserAgent =
    @"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.1 Safari/605.1.15";

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
                           userInfo:@{NSLocalizedDescriptionKey: message ?: YTMULocalized(@"LYRICS_ERROR_INNERTUBE_FETCH", @"fetch failed")}];
}

@implementation YTMUInnerTubeMetadata
@end

@interface YTMUInnerTubeDescriptionFetcher ()
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) dispatch_queue_t ioQueue;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSMutableArray<YTMUInnerTubeMetadataCompletion> *> *inflight;
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
            @"User-Agent": YTMUInnerTubeUserAgent,
            @"X-YouTube-Client-Name": @"1",
            @"X-YouTube-Client-Version": YTMUInnerTubeClientVersion,
            @"Origin": @"https://www.youtube.com",
            @"Referer": @"https://www.youtube.com/",
            @"Accept-Language": @"en-US,en;q=0.9",
        };
        _session = [NSURLSession sessionWithConfiguration:config];
        _ioQueue = dispatch_queue_create("com.ytmultimate.innertube-fetch", DISPATCH_QUEUE_SERIAL);
        _inflight = [NSMutableDictionary dictionary];

        // One-shot wipe of stale failure bookkeeping. Older builds:
        // (a) recorded "valid response with no description fields" as
        // failure → permanent music-video blacklist after 3 plays;
        // (b) was on IOS client which sometimes returned stripped
        // responses for music content. Both are fixed now, so wipe
        // the poisoned NSUserDefaults state on first launch of the
        // new logic.
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        if ([defaults integerForKey:@"YTMUInnerTubeFailureSchema"] < 3) {
            [defaults removeObjectForKey:YTMUInnerTubeFailuresKey];
            [defaults setInteger:3 forKey:@"YTMUInnerTubeFailureSchema"];
        }
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

- (nullable YTMUInnerTubeMetadata *)cachedMetadataForVideoId:(NSString *)videoId {
    if (!videoId.length) return nil;
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:[self filePathForVideoId:videoId]];
    if (![dict isKindOfClass:[NSDictionary class]]) return nil;
    if ([dict[@"v"] integerValue] != YTMUInnerTubeSchemaVersion) return nil;
    NSTimeInterval ts = [dict[@"ts"] doubleValue];
    if (ts > 0 && ([[NSDate date] timeIntervalSince1970] - ts) > YTMUInnerTubeCacheTTL) return nil;
    YTMUInnerTubeMetadata *meta = [[YTMUInnerTubeMetadata alloc] init];
    meta.videoDescription = [dict[@"text"] isKindOfClass:[NSString class]] ? dict[@"text"] : @"";
    meta.canonicalTitle = [dict[@"title"] isKindOfClass:[NSString class]] ? dict[@"title"] : @"";
    return meta;
}

- (nullable NSString *)cachedDescriptionForVideoId:(NSString *)videoId {
    return [self cachedMetadataForVideoId:videoId].videoDescription;
}

- (nullable NSString *)cachedCanonicalTitleForVideoId:(NSString *)videoId {
    NSString *title = [self cachedMetadataForVideoId:videoId].canonicalTitle;
    return title.length ? title : nil;
}

- (void)writeCacheMetadata:(YTMUInnerTubeMetadata *)meta forVideoId:(NSString *)videoId {
    if (!videoId.length || !meta) return;
    NSDictionary *plist = @{
        @"v":     @(YTMUInnerTubeSchemaVersion),
        @"text":  meta.videoDescription ?: @"",
        @"title": meta.canonicalTitle ?: @"",
        @"ts":    @([[NSDate date] timeIntervalSince1970]),
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
        YTMUInnerTubeAPIKey];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlString]];
    request.HTTPMethod = @"POST";
    request.timeoutInterval = YTMUInnerTubeRequestTimeout;
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];

    NSDictionary *body = @{
        @"context": @{
            @"client": @{
                @"clientName":     YTMUInnerTubeClientName,
                @"clientVersion":  YTMUInnerTubeClientVersion,
                @"hl":             @"en",
                @"gl":             @"US",
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

// Pull description + canonical title out of a parsed InnerTube response.
// Returns nil only when the response is structurally NOT a valid player
// response. A valid response with no description/title fields returns
// a metadata object with empty strings (cached as confirmed-empty).
- (YTMUInnerTubeMetadata *)metadataFromResponse:(NSDictionary *)json {
    if (![json isKindOfClass:[NSDictionary class]]) return nil;

    NSString *description = nil;
    NSString *canonicalTitle = nil;

    // videoDetails has both shortDescription and title (the proper
    // video title — what we'd see if we opened the watch page in a
    // browser). This is the primary, authoritative source.
    NSDictionary *videoDetails = json[@"videoDetails"];
    if ([videoDetails isKindOfClass:[NSDictionary class]]) {
        if ([videoDetails[@"shortDescription"] isKindOfClass:[NSString class]]) {
            description = videoDetails[@"shortDescription"];
        }
        if ([videoDetails[@"title"] isKindOfClass:[NSString class]]) {
            canonicalTitle = videoDetails[@"title"];
        }
    }

    // microformat as fallback for both fields.
    NSDictionary *microformat = json[@"microformat"];
    if ([microformat isKindOfClass:[NSDictionary class]]) {
        NSDictionary *renderer = microformat[@"playerMicroformatRenderer"];
        if ([renderer isKindOfClass:[NSDictionary class]]) {
            if (!description.length) {
                NSDictionary *descObj = renderer[@"description"];
                if ([descObj isKindOfClass:[NSDictionary class]]) {
                    NSString *simple = descObj[@"simpleText"];
                    if ([simple isKindOfClass:[NSString class]] && simple.length) {
                        description = simple;
                    } else {
                        NSArray *runs = descObj[@"runs"];
                        if ([runs isKindOfClass:[NSArray class]] && runs.count) {
                            NSMutableString *joined = [NSMutableString string];
                            for (id run in runs) {
                                if (![run isKindOfClass:[NSDictionary class]]) continue;
                                NSString *t = ((NSDictionary *)run)[@"text"];
                                if ([t isKindOfClass:[NSString class]]) [joined appendString:t];
                            }
                            description = joined;
                        }
                    }
                }
            }
            if (!canonicalTitle.length) {
                NSDictionary *titleObj = renderer[@"title"];
                if ([titleObj isKindOfClass:[NSDictionary class]]) {
                    NSString *simple = titleObj[@"simpleText"];
                    if ([simple isKindOfClass:[NSString class]]) canonicalTitle = simple;
                }
                if (!canonicalTitle.length) {
                    NSString *raw = renderer[@"title"];
                    if ([raw isKindOfClass:[NSString class]]) canonicalTitle = raw;
                }
            }
        }
    }

    // Determine if the response is structurally valid even when both
    // fields are empty. Valid responses always carry response-level
    // metadata; a stripped/error response wouldn't have any of these.
    BOOL responseLooksValid = json[@"playabilityStatus"] || json[@"responseContext"] ||
                              json[@"trackingParams"] || json[@"frameworkUpdates"];

    if (!description && !canonicalTitle && !responseLooksValid) {
        return nil; // truly malformed
    }

    YTMUInnerTubeMetadata *meta = [[YTMUInnerTubeMetadata alloc] init];
    meta.videoDescription = description ?: @"";
    meta.canonicalTitle = canonicalTitle ?: @"";
    return meta;
}

#pragma mark - Public

- (void)fetchMetadataForVideoId:(NSString *)videoId completion:(YTMUInnerTubeMetadataCompletion)completion {
    if (!completion) return;
    if (!videoId.length) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(nil, YTMUInnerTubeError(1, @"missing videoId"));
        });
        return;
    }

    YTMUInnerTubeMetadata *cached = [self cachedMetadataForVideoId:videoId];
    if (cached) {
        YTMULyricsLog(@"innertube cache hit videoId=%@ descLen=%lu titleLen=%lu",
                      videoId,
                      (unsigned long)cached.videoDescription.length,
                      (unsigned long)cached.canonicalTitle.length);
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

    YTMUInnerTubeMetadataCompletion completionCopy = [completion copy];
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
            NSString *preview = @"";
            if (data.length) {
                NSUInteger headLen = MIN(data.length, (NSUInteger)160);
                NSData *head = [data subdataWithRange:NSMakeRange(0, headLen)];
                preview = [[NSString alloc] initWithData:head encoding:NSUTF8StringEncoding] ?: @"<non-utf8>";
            }
            YTMULyricsLog(@"innertube HTTP %ld videoId=%@ preview=%@", (long)status, videoId, preview);
            [weakSelf recordFailureForVideoId:videoId];
            [weakSelf fanoutForVideoId:videoId
                                result:nil
                                 error:YTMUInnerTubeError(status, [NSString stringWithFormat:@"HTTP %ld", (long)status])];
            return;
        }
        NSError *jsonError = nil;
        id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError] : nil;
        if (!json || jsonError) {
            YTMULyricsLog(@"innertube parse failed videoId=%@ err=%@",
                          videoId, jsonError.localizedDescription ?: @"<empty>");
            [weakSelf recordFailureForVideoId:videoId];
            [weakSelf fanoutForVideoId:videoId result:nil error:jsonError ?: YTMUInnerTubeError(4, @"invalid JSON")];
            return;
        }

        YTMUInnerTubeMetadata *meta = [weakSelf metadataFromResponse:json];
        if (!meta) {
            YTMULyricsLog(@"innertube response not recognized as player response videoId=%@ keys=%@",
                          videoId,
                          [[json isKindOfClass:[NSDictionary class]] ? [(NSDictionary *)json allKeys] : @[]
                              componentsJoinedByString:@","]);
            [weakSelf recordFailureForVideoId:videoId];
            [weakSelf fanoutForVideoId:videoId result:nil error:YTMUInnerTubeError(5, @"malformed response")];
            return;
        }

        YTMULyricsLog(@"innertube fetch ok videoId=%@ descLen=%lu titleLen=%lu (%.2fs)",
                      videoId,
                      (unsigned long)meta.videoDescription.length,
                      (unsigned long)meta.canonicalTitle.length,
                      elapsed);
        [weakSelf writeCacheMetadata:meta forVideoId:videoId];
        [weakSelf clearFailureForVideoId:videoId];
        [weakSelf fanoutForVideoId:videoId result:meta error:nil];
    }];
    [task resume];
}

- (void)fanoutForVideoId:(NSString *)videoId result:(YTMUInnerTubeMetadata *)meta error:(NSError *)error {
    NSArray<YTMUInnerTubeMetadataCompletion> *callbacks;
    @synchronized (self.inflight) {
        callbacks = [self.inflight[videoId] copy];
        [self.inflight removeObjectForKey:videoId];
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        for (YTMUInnerTubeMetadataCompletion cb in callbacks) cb(meta, error);
    });
}

- (void)clearCache {
    dispatch_async(self.ioQueue, ^{
        [[NSFileManager defaultManager] removeItemAtPath:[self cacheDirectory] error:nil];
    });
    [self setAllFailures:@{}];
}

@end
