#import "YTMUDigest.h"
#import <CommonCrypto/CommonDigest.h>

NSString *YTMUSHA1HexForData(NSData *data) {
    unsigned char digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *output = [NSMutableString stringWithCapacity:CC_SHA1_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA1_DIGEST_LENGTH; i++) [output appendFormat:@"%02x", digest[i]];
    return output;
}

NSString *YTMUSHA1Hex(NSString *string) {
    return YTMUSHA1HexForData([string dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data]);
}
