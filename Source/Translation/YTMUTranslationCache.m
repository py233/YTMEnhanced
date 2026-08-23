#import "YTMUTranslationCache.h"
#import "YTMUTranslationTypes.h"
#import <UIKit/UIKit.h>
#import "../Utils/YTMUDigest.h"
#import "../Utils/YTMUPaths.h"

@implementation YTMUTranslationCacheEntry
- (BOOL)isRememberedFailure {
    if (self.failedAt <= 0) return NO;
    NSTimeInterval age = [[NSDate date] timeIntervalSince1970] - self.failedAt;
    return age >= 0 && age < YTMUTranslationFailureTTL;
}
@end

const NSTimeInterval YTMUTranslationFailureTTL = 24 * 60 * 60;

@interface YTMUTranslationCache ()
@property (nonatomic, strong) NSCache<NSString *, YTMUTranslationCacheEntry *> *memoryCache;
@property (nonatomic, strong) dispatch_queue_t ioQueue;
@end

@implementation YTMUTranslationCache

+ (instancetype)sharedCache {
    static YTMUTranslationCache *cache;
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
        _memoryCache.countLimit = 10;
        _memoryCache.totalCostLimit = 512 * 1024;
        _ioQueue = dispatch_queue_create("com.ytmultimate.translation-cache", DISPATCH_QUEUE_SERIAL);
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

- (void)clearMemoryCache {
    [self.memoryCache removeAllObjects];
    YTMUTranslationLog(@"translation memory cache cleared");
}

- (NSUInteger)costForEntry:(YTMUTranslationCacheEntry *)entry {
    NSUInteger cost = 1024;
    for (NSString *line in entry.translatedLines ?: @[]) cost += line.length * sizeof(unichar) + 32;
    return cost;
}

- (YTMUTranslationCacheEntry *)memoryEntryFromEntry:(YTMUTranslationCacheEntry *)entry {
    YTMUTranslationCacheEntry *copy = [[YTMUTranslationCacheEntry alloc] init];
    copy.cacheKey = entry.cacheKey ?: @"";
    copy.strategyVersion = entry.strategyVersion ?: YTMUTranslationStrategyVersion;
    copy.videoId = entry.videoId ?: @"";
    copy.targetLanguage = entry.targetLanguage ?: @"";
    copy.provider = entry.provider ?: @"";
    copy.model = entry.model ?: @"";
    copy.sourceHash = entry.sourceHash ?: @"";
    copy.lineCount = entry.lineCount;
    copy.sourceLines = @[];
    copy.translatedLines = entry.translatedLines ?: @[];
    copy.createdAt = entry.createdAt;
    copy.failedAt = entry.failedAt;
    return copy;
}

+ (NSString *)sourceHashForLines:(NSArray<NSString *> *)lines {
    NSArray *safeLines = lines ?: @[];
    NSData *json = [NSJSONSerialization dataWithJSONObject:safeLines options:0 error:nil];
    if (json) return YTMUSHA1HexForData(json);
    return YTMUSHA1Hex([safeLines componentsJoinedByString:@"\n"]);
}

+ (NSString *)keyForVideoId:(NSString *)videoId
                   language:(NSString *)language
                   provider:(NSString *)provider
                      model:(NSString *)model
                      lines:(NSArray<NSString *> *)lines {
    NSString *sourceHash = [self sourceHashForLines:lines];
    return [NSString stringWithFormat:@"%@::%@::%@::%@::%@::%lu::%@",
            YTMUTranslationStrategyVersion,
            videoId ?: @"",
            language ?: @"",
            provider ?: @"",
            model ?: @"",
            (unsigned long)lines.count,
            sourceHash];
}

- (NSString *)cacheDirectory {
    return YTMUCachesSubdirectory(@"Translations");
}

- (NSString *)filePathForKey:(NSString *)key {
    NSString *fileName = [[YTMUSHA1Hex(key) stringByAppendingString:@".json"] copy];
    return [[self cacheDirectory] stringByAppendingPathComponent:fileName];
}

- (void)ensureCacheDirectory {
    [[NSFileManager defaultManager] createDirectoryAtPath:[self cacheDirectory]
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
}

- (YTMUTranslationCacheEntry *)entryFromDictionary:(NSDictionary *)dict fallbackKey:(NSString *)key {
    if (![dict isKindOfClass:[NSDictionary class]]) return nil;
    NSArray *translated = dict[@"translatedLines"] ?: dict[@"translated"] ?: dict[@"lines"];
    NSArray *source = dict[@"sourceLines"];
    if (![translated isKindOfClass:[NSArray class]]) return nil;

    NSMutableArray *cleanTranslated = [NSMutableArray arrayWithCapacity:translated.count];
    for (id line in translated) {
        [cleanTranslated addObject:[line isKindOfClass:[NSString class]] ? line : @""];
    }

    NSMutableArray *cleanSource = [NSMutableArray array];
    if ([source isKindOfClass:[NSArray class]]) {
        for (id line in source) {
            [cleanSource addObject:[line isKindOfClass:[NSString class]] ? line : @""];
        }
    }

    YTMUTranslationCacheEntry *entry = [[YTMUTranslationCacheEntry alloc] init];
    entry.cacheKey = [dict[@"key"] isKindOfClass:[NSString class]] ? dict[@"key"] : key;
    entry.strategyVersion = [dict[@"strategyVersion"] isKindOfClass:[NSString class]] ? dict[@"strategyVersion"] : YTMUTranslationStrategyVersion;
    entry.videoId = [dict[@"videoId"] isKindOfClass:[NSString class]] ? dict[@"videoId"] : @"";
    entry.targetLanguage = [dict[@"targetLanguage"] isKindOfClass:[NSString class]] ? dict[@"targetLanguage"] : @"";
    entry.provider = [dict[@"provider"] isKindOfClass:[NSString class]] ? dict[@"provider"] : @"";
    entry.model = [dict[@"model"] isKindOfClass:[NSString class]] ? dict[@"model"] : @"";
    entry.sourceHash = [dict[@"sourceHash"] isKindOfClass:[NSString class]] ? dict[@"sourceHash"] : @"";
    entry.lineCount = [dict[@"lineCount"] isKindOfClass:[NSNumber class]] && [dict[@"lineCount"] unsignedIntegerValue]
        ? [dict[@"lineCount"] unsignedIntegerValue] : cleanTranslated.count;
    entry.sourceLines = cleanSource;
    entry.translatedLines = cleanTranslated;
    entry.createdAt = [dict[@"createdAt"] isKindOfClass:[NSNumber class]] ? [dict[@"createdAt"] doubleValue] : 0;
    entry.failedAt = [dict[@"failedAt"] isKindOfClass:[NSNumber class]] ? [dict[@"failedAt"] doubleValue] : 0;
    return entry;
}

- (NSDictionary *)dictionaryFromEntry:(YTMUTranslationCacheEntry *)entry {
    return @{
        @"key": entry.cacheKey ?: @"",
        @"strategyVersion": entry.strategyVersion ?: YTMUTranslationStrategyVersion,
        @"videoId": entry.videoId ?: @"",
        @"targetLanguage": entry.targetLanguage ?: @"",
        @"provider": entry.provider ?: @"",
        @"model": entry.model ?: @"",
        @"sourceHash": entry.sourceHash ?: @"",
        @"lineCount": @(entry.lineCount),
        @"sourceLines": entry.sourceLines ?: @[],
        @"translatedLines": entry.translatedLines ?: @[],
        @"createdAt": @(entry.createdAt ?: [[NSDate date] timeIntervalSince1970]),
        @"failedAt": @(entry.failedAt),
    };
}

- (YTMUTranslationCacheEntry *)entryForKey:(NSString *)key {
    if (!key.length) return nil;

    YTMUTranslationCacheEntry *memoryEntry = [self.memoryCache objectForKey:key];
    if (memoryEntry) return memoryEntry;

    NSData *data = [NSData dataWithContentsOfFile:[self filePathForKey:key]];
    if (!data) return nil;

    NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    YTMUTranslationCacheEntry *entry = [self entryFromDictionary:dict fallbackKey:key];
    if (entry) {
        YTMUTranslationCacheEntry *memoryEntry = [self memoryEntryFromEntry:entry];
        [self.memoryCache setObject:memoryEntry forKey:key cost:[self costForEntry:memoryEntry]];
    }
    return entry;
}

- (void)storeEntry:(YTMUTranslationCacheEntry *)entry {
    if (!entry.cacheKey.length || !entry.translatedLines) return;
    YTMUTranslationCacheEntry *memoryEntry = [self memoryEntryFromEntry:entry];
    [self.memoryCache setObject:memoryEntry forKey:entry.cacheKey cost:[self costForEntry:memoryEntry]];

    dispatch_async(self.ioQueue, ^{
        [self ensureCacheDirectory];
        NSDictionary *dict = [self dictionaryFromEntry:entry];
        NSData *data = [NSJSONSerialization dataWithJSONObject:dict options:NSJSONWritingPrettyPrinted error:nil];
        if (data) {
            [data writeToFile:[self filePathForKey:entry.cacheKey] atomically:YES];
        }
    });
}

- (NSUInteger)clearAll {
    [self.memoryCache removeAllObjects];

    NSString *dir = [self cacheDirectory];
    NSArray<NSString *> *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil];
    NSUInteger count = 0;
    for (NSString *file in files) {
        if (![file.pathExtension isEqualToString:@"json"]) continue;
        NSString *path = [dir stringByAppendingPathComponent:file];
        if ([[NSFileManager defaultManager] removeItemAtPath:path error:nil]) {
            count++;
        }
    }
    return count;
}

@end
