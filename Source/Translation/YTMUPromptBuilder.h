#import <Foundation/Foundation.h>
#import "YTMUTranslationTypes.h"

NS_ASSUME_NONNULL_BEGIN

@interface YTMUPromptBuilder : NSObject

+ (NSString *)systemPromptForRequest:(YTMUTranslationRequest *)request;
+ (NSString *)userPromptForRequest:(YTMUTranslationRequest *)request;

// Parse JSON response from LLM. Returns nil on total failure. Tries:
// (a) parse as-is; (b) strip ``` fences; (c) extract first {...} substring;
// (d) extract first [...] substring.
+ (nullable NSArray<NSString *> *)parseLinesFromJSON:(NSString *)raw
                                            expected:(NSUInteger)expected;

// True for ♪/dashes/punctuation-only lines, mirroring pear-desktop's skipPattern.
+ (BOOL)isSkippableLine:(NSString *)line;


// Map a BCP-47-ish language code (e.g. "zh-Hans", "ja", "auto") to a human
// language name suitable for putting into the LLM prompt.
+ (NSString *)resolveLanguageName:(NSString *)code;

// "auto" → user's locale, mapping zh → zh-Hans/zh-Hant via region.
+ (NSString *)effectiveTargetCode:(NSString *)code;

@end

NS_ASSUME_NONNULL_END
