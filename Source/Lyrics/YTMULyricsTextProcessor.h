#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface YTMULyricsTextProcessor : NSObject
+ (NSString *)canonicalize:(NSString *)text;
+ (NSString *)simplifyUnicode:(NSString *)text;
+ (NSString *)convertChineseText:(NSString *)text mode:(NSString *)mode;
+ (NSString *)googleTransliterationFromJSON:(id)json;
+ (BOOL)hasChinese:(NSString *)text;
+ (BOOL)hasJapaneseKana:(NSString *)text;
+ (BOOL)hasRomanizableText:(NSString *)text;
+ (BOOL)hasCJKIdeograph:(NSString *)text;
+ (BOOL)needsRomanizationForText:(NSString *)text preferredLanguage:(NSString *)language;
@end

NS_ASSUME_NONNULL_END
