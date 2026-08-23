#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString *const YTMUTranslationStrategyVersion;

extern NSString *const YTMUTranslationProviderGoogle;
extern NSString *const YTMUTranslationProviderAnthropic;
extern NSString *const YTMUTranslationProviderGemini;
extern NSString *const YTMUTranslationProviderOpenAI;

extern NSString *const YTMUTranslationErrorDomain;

// The model each LLM provider uses when the user has not picked one. The
// provider, the manager's attribution label and the settings picker all
// read this so they cannot drift apart. Google Translate has no model
// and returns @"".
NSString *YTMUTranslationDefaultModelForProvider(NSString *providerName);

BOOL YTMUTranslationDebugLoggingEnabled(void);
void YTMUTranslationLogImpl(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
// Macro so argument expressions are skipped entirely when logging is off.
#define YTMUTranslationLog(...) do { if (YTMUTranslationDebugLoggingEnabled()) YTMUTranslationLogImpl(__VA_ARGS__); } while (0)

typedef NS_ENUM(NSInteger, YTMUTranslationErrorCode) {
    YTMUTranslationErrorUnknown        = 1,
    YTMUTranslationErrorNetwork        = 2,
    YTMUTranslationErrorParse          = 3,
    YTMUTranslationErrorLineCount      = 4,
    YTMUTranslationErrorMissingAPIKey  = 5,
    YTMUTranslationErrorEmptyResponse  = 6,
    YTMUTranslationErrorHTTPStatus     = 7,
};

@interface YTMUTranslationRequest : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSArray<NSString *> *artists;
@property (nonatomic, copy) NSString *targetLanguageCode;       // e.g. "zh-Hans", "auto"
@property (nonatomic, copy) NSString *resolvedTargetLanguage;   // human-readable, e.g. "Simplified Chinese"
@property (nonatomic, copy) NSArray<NSString *> *lines;
@end

@protocol YTMULLMCompletionProvider <NSObject>
// Generic single-turn chat completion. Used by the title normalizer to ask
// the LLM for canonical song metadata. Implementors should request JSON
// output when expectJSONMode is YES (the caller will do best-effort parsing
// either way). Returns the raw assistant text on success.
- (void)completeWithSystemPrompt:(NSString *)systemPrompt
                      userPrompt:(NSString *)userPrompt
                  expectJSONMode:(BOOL)expectJSONMode
                      completion:(void(^)(NSString *_Nullable text, NSError *_Nullable error))completion;
@end

@protocol YTMUTranslationProvider <NSObject>
- (NSString *)providerName;       // matches the YTMUTranslationProvider* constants above
- (NSString *)modelIdentifier;    // for cache keying
- (void)translateRequest:(YTMUTranslationRequest *)request
              completion:(void(^)(NSArray<NSString *> *_Nullable lines, NSError *_Nullable error))completion;
@end

NS_ASSUME_NONNULL_END
