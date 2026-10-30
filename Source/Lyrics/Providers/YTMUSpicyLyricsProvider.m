#import "YTMUSpicyLyricsProvider.h"
#import "../YTMUWordLyricsParser.h"

@implementation YTMUSpicyLyricsProvider

- (instancetype)init {
    self = [super init];
    if (self) _endpointBaseURL = @"https://api.spicylyrics.org";
    return self;
}

- (NSString *)providerName { return YTMULyricsSourceSpicyLyrics; }

- (void)searchWithInfo:(YTMULyricsSearchInfo *)info completion:(void (^)(YTMULyricsResult *, NSError *))completion {
    NSString *trackId = nil;
    NSRegularExpression *spotify = [NSRegularExpression regularExpressionWithPattern:@"(?:spotify:track:|open\\.spotify\\.com/track/)?([A-Za-z0-9]{22})" options:0 error:nil];
    NSMutableArray *candidates = [NSMutableArray arrayWithObjects:info.videoId ?: @"", info.album ?: @"", info.shortDescription ?: @"", nil];
    [candidates addObjectsFromArray:info.tags ?: @[]];
    for (NSString *candidate in candidates) {
        NSTextCheckingResult *match = [spotify firstMatchInString:candidate options:0 range:NSMakeRange(0, candidate.length)];
        if (match.numberOfRanges >= 2) { trackId = [candidate substringWithRange:[match rangeAtIndex:1]]; break; }
    }
    if (!trackId.length) { completion(nil, nil); return; }
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@/v1/lyrics/%@", self.endpointBaseURL, trackId]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.timeoutInterval = 8.0;
    [request setValue:@"YTMEnhanced/1.0" forHTTPHeaderField:@"User-Agent"];
    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) { completion(nil, error); return; }
        NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]] ? [(NSHTTPURLResponse *)response statusCode] : 0;
        if (status == 404) { completion(nil, nil); return; }
        if (status < 200 || status >= 300) { completion(nil, [NSError errorWithDomain:@"YTMUSpicyLyrics" code:status userInfo:nil]); return; }
        NSDictionary *json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        YTMULyricsResult *result = YTMUWordLyricsResultFromSpicyJSON(json ?: @{}, info, [self providerName]);
        completion(result, nil);
    }] resume];
}

@end
