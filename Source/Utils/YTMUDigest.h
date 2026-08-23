#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Lower-case hex SHA-1. Used for cache file names; not a security primitive.
NSString *YTMUSHA1Hex(NSString *string);
NSString *YTMUSHA1HexForData(NSData *data);

NS_ASSUME_NONNULL_END
