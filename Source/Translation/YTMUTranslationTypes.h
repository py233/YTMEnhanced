#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString *const YTMUTranslationStrategyVersion;

extern NSString *const YTMUTranslationProviderGoogle;
extern NSString *const YTMUTranslationProviderAnthropic;
extern NSString *const YTMUTranslationProviderGemini;
extern NSString *const YTMUTranslationProviderOpenAI;

extern NSString *const YTMUTranslationErrorDomain;

BOOL YTMUTranslationDebugLoggingEnabled(void);
void YTMUTranslationLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);

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

@protocol YTMUTranslationProvider <NSObject>
- (NSString *)providerName;       // matches the YTMUTranslationProvider* constants above
- (NSString *)modelIdentifier;    // for cache keying
- (void)translateRequest:(YTMUTranslationRequest *)request
              completion:(void(^)(NSArray<NSString *> *_Nullable lines, NSError *_Nullable error))completion;
@end

NS_ASSUME_NONNULL_END
