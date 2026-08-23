#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// One plist per key under <YTMUCachesDirectory()>/<subdirectory>/<sha1(key)>.plist,
// stamped with a schema version. Reads are synchronous; writes and removal
// happen on a private serial queue. Shared by the title-normalize,
// description-extract and InnerTube caches, which used to carry three
// copies of this.
@interface YTMUPlistStore : NSObject

- (instancetype)initWithSubdirectory:(NSString *)subdirectory schemaVersion:(NSInteger)schemaVersion;

@property (nonatomic, readonly) NSString *directory;
@property (nonatomic, readonly) NSInteger schemaVersion;

- (NSString *)pathForKey:(NSString *)key;
// The stored dictionary, or nil when there is none or its "v" is not this
// store's schema version.
- (nullable NSDictionary *)plistForKey:(NSString *)key;
// Writes asynchronously, creating the directory, and forces "v" to the
// store's schema version.
- (void)writePlist:(NSDictionary *)plist forKey:(NSString *)key;
- (void)removeAll;

@end

NS_ASSUME_NONNULL_END
