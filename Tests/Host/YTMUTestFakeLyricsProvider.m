#import "YTMUTestFakeLyricsProvider.h"

@interface YTMUTestFakeLyricsProvider ()
@property (nonatomic, readwrite) NSUInteger searchCount;
@property (nonatomic, copy, readwrite) YTMULyricsSearchInfo *lastInfo;
@end

@implementation YTMUTestFakeLyricsProvider
- (instancetype)initWithName:(NSString *)name { self = [super init]; _name = [name copy]; return self; }
- (NSString *)providerName { return self.name; }
- (void)searchWithInfo:(YTMULyricsSearchInfo *)info completion:(void (^)(YTMULyricsResult *, NSError *))completion {
    self.searchCount++;
    self.lastInfo = info;
    YTMULyricsResult *r = self.result ? [self.result copy] : nil; NSError *e = self.error;
    // Real providers complete on NSURLSession's queue; mimic "not main".
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(self.delay * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{ completion(r, e); });
}
@end

YTMULyricsResult *YTMUTestSyncedResult(NSString *source, NSString *title, NSString *artist, NSUInteger lines) {
    YTMULyricsResult *r = [[YTMULyricsResult alloc] init];
    r.sourceName = source; r.title = title; r.artists = artist.length ? @[artist] : @[];
    NSMutableArray *arr = [NSMutableArray array];
    for (NSUInteger i = 0; i < lines; i++) {
        [arr addObject:[YTMULyricLine lineWithTime:@"" timeInMs:(NSTimeInterval)(i * 1000) durationMs:1000
                                              text:[NSString stringWithFormat:@"%@ line %lu", source, (unsigned long)(i + 1)]]];
    }
    r.lines = arr;
    return r;
}

YTMULyricsResult *YTMUTestPlainResult(NSString *source, NSString *title, NSString *artist, NSUInteger lines) {
    YTMULyricsResult *r = [[YTMULyricsResult alloc] init];
    r.sourceName = source; r.title = title; r.artists = artist.length ? @[artist] : @[];
    NSMutableArray *arr = [NSMutableArray array];
    for (NSUInteger i = 0; i < lines; i++) [arr addObject:[NSString stringWithFormat:@"%@ plain %lu", source, (unsigned long)(i + 1)]];
    r.plainLyrics = [arr componentsJoinedByString:@"\n"];
    return r;
}

YTMULyricsSearchInfo *YTMUTestInfo(NSString *videoId, NSString *title, NSString *artist) {
    YTMULyricsSearchInfo *info = [[YTMULyricsSearchInfo alloc] init];
    info.videoId = videoId; info.title = title; info.artist = artist; info.duration = 200;
    return info;
}
