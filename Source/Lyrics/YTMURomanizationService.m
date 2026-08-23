#import "YTMURomanizationService.h"
#import "YTMULyricsTextProcessor.h"
#import "../Utils/YTMUConcurrencyLimiter.h"

@interface YTMURomanizationService ()
@property (nonatomic, strong) NSCache<NSString *, NSArray<NSString *> *> *memoryCache;
@end

@implementation YTMURomanizationService

+ (instancetype)sharedService {
    static YTMURomanizationService *service;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ service = [[self alloc] init]; });
    return service;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _endpointBaseURL = @"https://translate.googleapis.com";
        _memoryCache = [[NSCache alloc] init];
        _memoryCache.countLimit = 8;
    }
    return self;
}

#pragma mark - Classification

- (NSString *)sourceLanguageForLines:(NSArray<NSString *> *)lines {
    for (NSString *line in lines ?: @[]) {
        if ([YTMULyricsTextProcessor hasJapaneseKana:line ?: @""]) return @"ja";
    }
    return @"auto";
}

- (NSArray<NSDictionary *> *)romanizableItemsForLines:(NSArray<NSString *> *)lines
                                            existing:(NSArray<NSString *> *)existing
                                      sourceLanguage:(NSString *)sourceLanguage {
    NSMutableArray<NSDictionary *> *items = [NSMutableArray array];
    [lines enumerateObjectsUsingBlock:^(NSString *lineText, NSUInteger idx, BOOL *stop) {
        NSString *text = [lineText stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSString *already = idx < existing.count ? existing[idx] : @"";
        if (!text.length || already.length) return;
        if (![YTMULyricsTextProcessor needsRomanizationForText:text preferredLanguage:sourceLanguage]) return;
        [items addObject:@{@"index": @(idx), @"text": text}];
    }];
    return items;
}

#pragma mark - Memory cache

- (NSString *)cacheKeyForVideoId:(NSString *)videoId source:(NSString *)source lines:(NSArray<NSString *> *)lines {
    return [NSString stringWithFormat:@"%@::%@::%lu::%@",
            videoId ?: @"",
            source ?: @"",
            (unsigned long)lines.count,
            YTMULyricsCompactString([lines componentsJoinedByString:@"|"] ?: @"")];
}

- (NSArray<NSString *> *)cachedLinesForKey:(NSString *)key {
    return key.length ? [self.memoryCache objectForKey:key] : nil;
}

- (void)storeLines:(NSArray<NSString *> *)lines forKey:(NSString *)key {
    if (!key.length) return;
    if (lines.count) [self.memoryCache setObject:lines forKey:key];
    else [self.memoryCache removeObjectForKey:key];
}

- (void)clearMemoryCache {
    [self.memoryCache removeAllObjects];
    YTMULyricsLog(@"romanization memory cache cleared");
}

#pragma mark - Network

static NSString *YTMURomanizationFormEncode(NSString *value) {
    static NSCharacterSet *allowed;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSMutableCharacterSet *set = [[NSCharacterSet URLQueryAllowedCharacterSet] mutableCopy];
        [set removeCharactersInString:@"!*'();:@&=+$,/?%#[]"];
        allowed = [set copy];
    });
    NSString *encoded = [value stringByAddingPercentEncodingWithAllowedCharacters:allowed] ?: @"";
    return [encoded stringByReplacingOccurrencesOfString:@"%20" withString:@"+"];
}

- (void)romanizeText:(NSString *)text sourceLanguage:(NSString *)sourceLanguage completion:(void (^)(NSString *))completion {
    if (!text.length) {
        completion(@"");
        return;
    }
    // translate.googleapis.com with client=gtx is the long-stable public
    // endpoint used by web translate widgets, yt-dlp, and most OSS
    // translation tools. GET-only, no auth, no cookies. Returns a proper
    // JSON envelope when dj=1 is set. Note the translation provider
    // (YTMUGoogleTranslateProvider) POSTs to translate.google.com with
    // client=at and that works fine; it was this GET transliteration path
    // that came back empty / CAPTCHA'd from client=at, hence the split.
    NSString *source = sourceLanguage.length ? sourceLanguage : @"auto";
    NSString *base = self.endpointBaseURL.length ? self.endpointBaseURL : @"https://translate.googleapis.com";
    while ([base hasSuffix:@"/"]) base = [base substringToIndex:base.length - 1];
    NSString *urlString = [NSString stringWithFormat:
        @"%@/translate_a/single?client=gtx&sl=%@&tl=en&dt=rm&dj=1&q=%@",
        base, YTMURomanizationFormEncode(source), YTMURomanizationFormEncode(text)];
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        completion(@"");
        return;
    }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"GET";
    request.timeoutInterval = 10.0;
    // Browser UA — googleapis is permissive but a plain CFNetwork ua
    // occasionally trips its bot heuristics on aggressive workloads.
    [request setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 18_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.1 Mobile/15E148 Safari/604.1"
       forHTTPHeaderField:@"User-Agent"];
    [request setValue:@"application/json, text/plain, */*" forHTTPHeaderField:@"Accept"];

    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            YTMULyricsLog(@"google romanization network error: %@", error.localizedDescription);
            completion(@"");
            return;
        }
        NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]] ? [(NSHTTPURLResponse *)response statusCode] : 0;
        if (status < 200 || status >= 300) {
            NSString *preview = @"";
            if (data.length) {
                NSUInteger headLen = MIN(data.length, (NSUInteger)160);
                preview = [[NSString alloc] initWithData:[data subdataWithRange:NSMakeRange(0, headLen)] encoding:NSUTF8StringEncoding] ?: @"<non-utf8>";
            }
            YTMULyricsLog(@"google romanization HTTP %ld bodyLen=%lu preview=%@", (long)status, (unsigned long)data.length, preview);
            completion(@"");
            return;
        }
        NSError *jsonError = nil;
        id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError] : nil;
        if (!json || jsonError) {
            NSString *preview = @"";
            if (data.length) {
                NSUInteger headLen = MIN(data.length, (NSUInteger)160);
                preview = [[NSString alloc] initWithData:[data subdataWithRange:NSMakeRange(0, headLen)] encoding:NSUTF8StringEncoding] ?: @"<non-utf8>";
            }
            YTMULyricsLog(@"google romanization JSON parse failed err=%@ bodyLen=%lu preview=%@",
                          jsonError.localizedDescription ?: @"<empty>", (unsigned long)data.length, preview);
            completion(@"");
            return;
        }
        completion([YTMULyricsTextProcessor googleTransliterationFromJSON:json] ?: @"");
    }] resume];
}

- (void)romanizeItems:(NSArray<NSDictionary *> *)items
                limit:(NSUInteger)limit
       sourceLanguage:(NSString *)sourceLanguage
                 into:(NSMutableArray<NSString *> *)romanized
       shouldContinue:(BOOL (^)(void))shouldContinue
           completion:(void (^)(NSArray<NSString *> *))completion {
    NSUInteger total = MIN(items.count, limit);
    if (total == 0) {
        completion([romanized copy]);
        return;
    }
    // Google's per-segment endpoint is happy to take parallel requests as
    // long as we don't pummel it; 6 in flight cuts wall time ~5x over a
    // serial chain without tripping rate limits.
    static const NSUInteger kMaxConcurrent = 6;
    __weak typeof(self) weakSelf = self;
    [YTMUConcurrencyLimiter runItems:total
                         concurrency:kMaxConcurrent
                         shouldStart:shouldContinue
                                work:^(NSUInteger i, dispatch_block_t done) {
        NSDictionary *item = items[i];
        NSUInteger lineIndex = [item[@"index"] unsignedIntegerValue];
        NSString *text = item[@"text"] ?: @"";
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) { done(); return; }
        [strongSelf romanizeText:text sourceLanguage:sourceLanguage completion:^(NSString *value) {
            if (value.length) {
                @synchronized (romanized) {
                    if (lineIndex < romanized.count) romanized[lineIndex] = value;
                }
            }
            done();
        }];
    } completion:^{
        dispatch_async(dispatch_get_main_queue(), ^{ completion([romanized copy]); });
    }];
}

@end
