#import "YTMUTranslationTypes.h"
#import "../Utils/YTMUSettings.h"

NSString *const YTMUTranslationStrategyVersion = @"whole-song-v2";

NSString *const YTMUTranslationProviderGoogle    = @"google-translate";
NSString *const YTMUTranslationProviderAnthropic = @"anthropic";
NSString *const YTMUTranslationProviderGemini    = @"gemini";
NSString *const YTMUTranslationProviderOpenAI    = @"openai-compatible";

NSString *const YTMUTranslationErrorDomain = @"YTMUTranslationErrorDomain";
NSString *const YTMUTranslationErrorHTTPStatusKey = @"YTMUTranslationHTTPStatus";

NSError *YTMUTranslationMakeError(YTMUTranslationErrorCode code, NSString *message) {
    return [NSError errorWithDomain:YTMUTranslationErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: message.length ? message : @"Translation failed"}];
}

NSError *YTMUTranslationHTTPError(NSString *label, NSInteger status, NSData *body, NSUInteger bodyLimit) {
    NSString *bodyText = body.length ? [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding] : nil;
    if (!bodyText) bodyText = @"";
    if (bodyText.length > bodyLimit) bodyText = [bodyText substringToIndex:bodyLimit];
    return [NSError errorWithDomain:YTMUTranslationErrorDomain
                               code:YTMUTranslationErrorHTTPStatus
                           userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%@ %ld: %@", label, (long)status, bodyText],
                                      YTMUTranslationErrorHTTPStatusKey: @(status)}];
}

NSString *YTMUTranslationDefaultModelForProvider(NSString *providerName) {
    if ([providerName isEqualToString:YTMUTranslationProviderAnthropic]) return @"claude-haiku-4-5-20251001";
    if ([providerName isEqualToString:YTMUTranslationProviderGemini]) return @"gemini-2.0-flash";
    if ([providerName isEqualToString:YTMUTranslationProviderOpenAI]) return @"gpt-4o-mini";
    return @"";
}

@implementation YTMUTranslationRequest
@end

BOOL YTMUTranslationDebugLoggingEnabled(void) {
    return YTMUSettingsBool(@"translationDebugLogs", NO);
}

void YTMUTranslationLogImpl(NSString *format, ...) {
    if (!YTMUTranslationDebugLoggingEnabled() || !format.length) return;

    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSLog(@"[YTMUTranslation] %@", message);
}
