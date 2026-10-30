#import "YTMUBetterLyricsProvider.h"
#import "../YTMUWordLyricsParser.h"

@implementation YTMUBetterLyricsProvider

- (instancetype)init {
    self = [super init];
    if (self) _endpointBaseURL = @"https://api.betterlyrics.org";
    return self;
}

- (NSString *)providerName { return YTMULyricsSourceBetterLyrics; }

- (void)searchWithInfo:(YTMULyricsSearchInfo *)info completion:(void (^)(YTMULyricsResult *, NSError *))completion {
    if (!info.title.length && !info.artist.length) { completion(nil, nil); return; }
    NSMutableArray *parts = [NSMutableArray array];
    void (^add)(NSString *, NSString *) = ^(NSString *key, NSString *value) {
        if (value.length) [parts addObject:[NSString stringWithFormat:@"%@=%@", key, YTMULyricsEncodeQuery(value)]];
    };
    add(@"s", YTMULyricsStripSearchNoise(info.title ?: @""));
    add(@"a", info.artist);
    add(@"al", info.album);
    if (info.duration > 0) add(@"d", [NSString stringWithFormat:@"%ld", (long)llround(info.duration)]);
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@/getLyrics?%@", self.endpointBaseURL, [parts componentsJoinedByString:@"&"]]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.timeoutInterval = 8.0;
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) { completion(nil, error); return; }
        NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]] ? [(NSHTTPURLResponse *)response statusCode] : 0;
        if (status < 200 || status >= 300) { completion(nil, [NSError errorWithDomain:@"YTMUBetterLyrics" code:status userInfo:nil]); return; }
        NSDictionary *json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSString *ttml = [json[@"ttml"] isKindOfClass:[NSString class]] ? json[@"ttml"] : @"";
        NSArray *lines = YTMUWordLyricsParseTTML(ttml);
        if (!lines.count) { completion(nil, nil); return; }
        YTMULyricsResult *result = [[YTMULyricsResult alloc] init];
        result.sourceName = [self providerName];
        result.title = info.title;
        result.artists = info.artist.length ? @[info.artist] : @[];
        result.lines = lines;
        result.duration = info.duration;
        completion(result, nil);
    }] resume];
}

@end
