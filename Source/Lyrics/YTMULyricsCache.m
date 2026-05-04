#import "YTMULyricsCache.h"
#import <CommonCrypto/CommonDigest.h>

@interface YTMULyricsCache ()
@property (nonatomic, strong) NSCache<NSString *, YTMULyricsResult *> *memoryCache;
@property (nonatomic, strong) dispatch_queue_t ioQueue;
@end

static NSString *YTMULyricsSHA1(NSString *string) {
    NSData *data = [string dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
    unsigned char digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *output = [NSMutableString stringWithCapacity:CC_SHA1_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA1_DIGEST_LENGTH; i++) [output appendFormat:@"%02x", digest[i]];
    return output;
}

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
        _memoryCache.countLimit = 60;
        _ioQueue = dispatch_queue_create("com.ytmultimate.lyrics-cache", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

+ (NSString *)cacheKeyForInfo:(YTMULyricsSearchInfo *)info source:(NSString *)source {
    NSString *signature = [@[source ?: @"",
                             info.videoId ?: @"",
                             YTMULyricsCompactString(info.title ?: @""),
                             YTMULyricsCompactString(info.artist ?: @""),
                             @((NSInteger)llround(info.duration ?: 0)).stringValue] componentsJoinedByString:@"::"];
    return [NSString stringWithFormat:@"lyrics-v1::%@", signature];
}

- (NSString *)cacheDirectory {
    NSString *cacheRoot = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    return [[cacheRoot stringByAppendingPathComponent:@"YTMUltimate"] stringByAppendingPathComponent:@"Lyrics"];
}

- (NSString *)filePathForKey:(NSString *)key {
    return [[self cacheDirectory] stringByAppendingPathComponent:[YTMULyricsSHA1(key) stringByAppendingString:@".bin"]];
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
    YTMULyricsResult *result = [NSKeyedUnarchiver unarchivedObjectOfClass:[YTMULyricsResult class] fromData:data error:&error];
    if (!result || error) return nil;
    [self.memoryCache setObject:result forKey:key];
    return result;
}

- (void)storeResult:(YTMULyricsResult *)result forKey:(NSString *)key {
    if (!key.length || !result.hasText) return;
    [self.memoryCache setObject:result forKey:key];
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
