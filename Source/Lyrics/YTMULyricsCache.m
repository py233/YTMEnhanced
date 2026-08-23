#import "YTMULyricsCache.h"
#import <UIKit/UIKit.h>
#import "../Utils/YTMUDigest.h"
#import "../Utils/YTMUPaths.h"

@interface YTMULyricsCache ()
@property (nonatomic, strong) NSCache<NSString *, YTMULyricsResult *> *memoryCache;
@property (nonatomic, strong) dispatch_queue_t ioQueue;
@end

@implementation YTMULyricsCache

+ (instancetype)sharedCache {
    static YTMULyricsCache *cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [[self alloc] init];
    });
    return cache;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _memoryCache = [[NSCache alloc] init];
        // Six providers × a probe round per song writes up to 6 entries;
        // 8 churned constantly. 32 covers a few songs of back-and-forth.
        _memoryCache.countLimit = 32;
        _memoryCache.totalCostLimit = 768 * 1024;
        _ioQueue = dispatch_queue_create("com.ytmultimate.lyrics-cache", DISPATCH_QUEUE_SERIAL);
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(clearMemoryCache)
                                                     name:UIApplicationDidReceiveMemoryWarningNotification
                                                   object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (NSUInteger)costForResult:(YTMULyricsResult *)result {
    NSUInteger cost = result.plainLyrics.length * sizeof(unichar);
    for (YTMULyricLine *line in result.lines ?: @[]) cost += line.text.length * sizeof(unichar) + 64;
    for (NSString *line in result.romanizedLineTexts ?: @[]) cost += line.length * sizeof(unichar) + 32;
    for (NSString *line in result.officialTranslatedLines ?: @[]) cost += line.length * sizeof(unichar) + 32;
    cost += result.title.length * sizeof(unichar) + result.artists.description.length * sizeof(unichar);
    return MAX((NSUInteger)1024, cost);
}

- (void)clearMemoryCache {
    [self.memoryCache removeAllObjects];
    YTMULyricsLog(@"lyrics memory cache cleared");
}

+ (NSString *)cacheKeyForInfo:(YTMULyricsSearchInfo *)info source:(NSString *)source {
    NSString *signature = [@[source ?: @"",
                             info.videoId ?: @"",
                             YTMULyricsCompactString(info.title ?: @""),
                             YTMULyricsCompactString(info.artist ?: @""),
                             @((NSInteger)llround(info.duration ?: 0)).stringValue] componentsJoinedByString:@"::"];
    return [NSString stringWithFormat:@"lyrics-v8::%@", signature];
}

- (NSString *)cacheDirectory {
    return YTMUCachesSubdirectory(@"Lyrics");
}

- (NSString *)filePathForKey:(NSString *)key {
    return [[self cacheDirectory] stringByAppendingPathComponent:[YTMUSHA1Hex(key) stringByAppendingString:@".bin"]];
}

- (void)ensureCacheDirectory {
    [[NSFileManager defaultManager] createDirectoryAtPath:[self cacheDirectory]
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
}

- (YTMULyricsResult *)resultForKey:(NSString *)key {
    if (!key.length) return nil;
    YTMULyricsResult *memory = [self.memoryCache objectForKey:key];
    if (memory) return memory;

    NSData *data = [NSData dataWithContentsOfFile:[self filePathForKey:key]];
    if (!data) return nil;

    NSError *error = nil;
    NSSet *classes = [NSSet setWithObjects:
                      [YTMULyricsResult class],
                      [YTMULyricLine class],
                      [NSArray class],
                      [NSString class],
                      [NSNumber class],
                      nil];
    YTMULyricsResult *result = [NSKeyedUnarchiver unarchivedObjectOfClasses:classes fromData:data error:&error];
    if (!result || error) {
        YTMULyricsLog(@"lyrics cache read failed key=%@ error=%@", key, error.localizedDescription ?: @"<unknown>");
        return nil;
    }
    [self.memoryCache setObject:result forKey:key cost:[self costForResult:result]];
    return result;
}

- (void)storeResult:(YTMULyricsResult *)result forKey:(NSString *)key {
    if (!key.length || !result.hasText) return;
    [self.memoryCache setObject:result forKey:key cost:[self costForResult:result]];
    dispatch_async(self.ioQueue, ^{
        [self ensureCacheDirectory];
        NSError *error = nil;
        NSData *data = [NSKeyedArchiver archivedDataWithRootObject:result requiringSecureCoding:YES error:&error];
        if (data && !error) [data writeToFile:[self filePathForKey:key] atomically:YES];
    });
}

- (NSUInteger)clearAll {
    [self.memoryCache removeAllObjects];
    NSString *dir = [self cacheDirectory];
    NSArray<NSString *> *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil];
    NSUInteger count = 0;
    for (NSString *file in files) {
        NSString *path = [dir stringByAppendingPathComponent:file];
        if ([[NSFileManager defaultManager] removeItemAtPath:path error:nil]) count++;
    }
    return count;
}

@end
