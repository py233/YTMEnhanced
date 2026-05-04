#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface YTMULyricsTextProcessor : NSObject
+ (NSString *)canonicalize:(NSString *)text;
+ (NSString *)simplifyUnicode:(NSString *)text;
+ (NSString *)convertChineseText:(NSString *)text mode:(NSString *)mode;
+ (NSString *)romanizeText:(NSString *)text;
+ (BOOL)hasChinese:(NSString *)text;
+ (BOOL)hasRomanizableText:(NSString *)text;
@end

NS_ASSUME_NONNULL_END
