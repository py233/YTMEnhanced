#import "YTMUTranslationTypes.h"

NSString *const YTMUTranslationStrategyVersion = @"whole-song-v2";

NSString *const YTMUTranslationProviderGoogle    = @"google-translate";
NSString *const YTMUTranslationProviderAnthropic = @"anthropic";
NSString *const YTMUTranslationProviderGemini    = @"gemini";
NSString *const YTMUTranslationProviderOpenAI    = @"openai-compatible";

NSString *const YTMUTranslationErrorDomain = @"YTMUTranslationErrorDomain";

NSString *YTMUTranslationDefaultModelForProvider(NSString *providerName) {
    if ([providerName isEqualToString:YTMUTranslationProviderAnthropic]) return @"claude-haiku-4-5-20251001";
    if ([providerName isEqualToString:YTMUTranslationProviderGemini]) return @"gemini-2.0-flash";
    if ([providerName isEqualToString:YTMUTranslationProviderOpenAI]) return @"gpt-4o-mini";
    return @"";
}

@implementation YTMUTranslationRequest
@end

BOOL YTMUTranslationDebugLoggingEnabled(void) {
    NSDictionary *dict = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"YTMUltimate"] ?: @{};
    id value = dict[@"translationDebugLogs"];
    return value == nil ? NO : [value boolValue];
}

void YTMUTranslationLogImpl(NSString *format, ...) {
    if (!YTMUTranslationDebugLoggingEnabled() || !format.length) return;

    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSLog(@"[YTMUTranslation] %@", message);
}
