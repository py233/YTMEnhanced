#import "YTMUUnisonProvider.h"
#import "../YTMUWordLyricsParser.h"

@implementation YTMUUnisonProvider

- (instancetype)init {
    self = [super init];
    if (self) _endpointBaseURL = @"https://unison.betterlyrics.org";
    return self;
}

- (NSString *)providerName { return YTMULyricsSourceUnison; }

- (void)searchWithInfo:(YTMULyricsSearchInfo *)info completion:(void (^)(YTMULyricsResult *, NSError *))completion {
    if (!info.videoId.length) { completion(nil, nil); return; }
    NSMutableArray *parts = [NSMutableArray arrayWithObject:[NSString stringWithFormat:@"v=%@", YTMULyricsEncodeQuery(info.videoId)]];
    if (info.title.length) [parts addObject:[NSString stringWithFormat:@"song=%@", YTMULyricsEncodeQuery(info.title)]];
    if (info.artist.length) [parts addObject:[NSString stringWithFormat:@"artist=%@", YTMULyricsEncodeQuery(info.artist)]];
    if (info.duration > 0) [parts addObject:[NSString stringWithFormat:@"duration=%ld", (long)llround(info.duration)]];
    if (info.album.length) [parts addObject:[NSString stringWithFormat:@"album=%@", YTMULyricsEncodeQuery(info.album)]];
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@/lyrics?%@", self.endpointBaseURL, [parts componentsJoinedByString:@"&"]]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.timeoutInterval = 8.0;
    [request setValue:@"YTMEnhanced/1.0" forHTTPHeaderField:@"User-Agent"];
    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) { completion(nil, error); return; }
        NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]] ? [(NSHTTPURLResponse *)response statusCode] : 0;
        if (status == 404) { completion(nil, nil); return; }
        if (status < 200 || status >= 300) { completion(nil, [NSError errorWithDomain:@"YTMUUnison" code:status userInfo:nil]); return; }
        NSDictionary *json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSDictionary *payload = [json[@"data"] isKindOfClass:[NSDictionary class]] ? json[@"data"] : json;
        NSString *format = [payload[@"format"] isKindOfClass:[NSString class]] ? payload[@"format"] : @"";
        NSString *lyrics = [payload[@"lyrics"] isKindOfClass:[NSString class]] ? payload[@"lyrics"] : @"";
        NSArray *lines = [format.lowercaseString isEqualToString:@"ttml"] ? YTMUWordLyricsParseTTML(lyrics) : @[];
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
