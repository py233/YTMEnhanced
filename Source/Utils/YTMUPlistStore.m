#import "YTMUPlistStore.h"
#import "YTMUPaths.h"
#import "YTMUDigest.h"

@interface YTMUPlistStore ()
@property (nonatomic, copy) NSString *directory;
@property (nonatomic) NSInteger schemaVersion;
@property (nonatomic, strong) dispatch_queue_t ioQueue;
@end

@implementation YTMUPlistStore

- (instancetype)initWithSubdirectory:(NSString *)subdirectory schemaVersion:(NSInteger)schemaVersion {
    self = [super init];
    if (self) {
        _directory = YTMUCachesSubdirectory(subdirectory);
        _schemaVersion = schemaVersion;
        _ioQueue = dispatch_queue_create([[@"com.ytmultimate.plist-store." stringByAppendingString:subdirectory] UTF8String], DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (NSString *)pathForKey:(NSString *)key {
    NSString *safeKey = key.length ? key : @"<empty>";
    return [self.directory stringByAppendingPathComponent:[YTMUSHA1Hex(safeKey) stringByAppendingString:@".plist"]];
}

- (NSDictionary *)plistForKey:(NSString *)key {
    if (!key.length) return nil;
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:[self pathForKey:key]];
    if (![dict isKindOfClass:[NSDictionary class]]) return nil;
    id version = dict[@"v"];
    if (![version isKindOfClass:[NSNumber class]] || [version integerValue] != self.schemaVersion) return nil;
    return dict;
}

- (void)writePlist:(NSDictionary *)plist forKey:(NSString *)key {
    if (!key.length || !plist) return;
    NSMutableDictionary *stamped = [plist mutableCopy];
    stamped[@"v"] = @(self.schemaVersion);
    NSString *path = [self pathForKey:key];
    NSString *directory = self.directory;
    dispatch_async(self.ioQueue, ^{
        [[NSFileManager defaultManager] createDirectoryAtPath:directory
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:nil];
        [stamped writeToFile:path atomically:YES];
    });
}

- (void)removeAll {
    NSString *directory = self.directory;
    dispatch_async(self.ioQueue, ^{
        [[NSFileManager defaultManager] removeItemAtPath:directory error:nil];
    });
}

@end
