#import <Foundation/Foundation.h>
#import "Translation/YTMUTranslationTypes.h"

// Canned provider for both LLM completion (title-normalize, description-
// extract) and line translation. Inject into YTMUTranslator's private
// `providers` map under a name, then select it via `translationProvider`.
@interface YTMUTestFakeLLM : NSObject <YTMULLMCompletionProvider, YTMUTranslationProvider>
@property (nonatomic, copy) NSString *name;                    // providerName, default "fake"
@property (nonatomic, copy) NSString *responseText;            // completion text
@property (nonatomic, strong) NSError *responseError;          // if set, returned instead
@property (nonatomic, copy) NSArray<NSString *> *translatedLines; // translateRequest: result
@property (nonatomic, strong) NSError *translationError;
@property (nonatomic, copy) NSArray<NSString *> *(^translationHandler)(YTMUTranslationRequest *request, NSError **error);
@property (nonatomic, readonly) NSUInteger callCount;          // completion calls
@property (nonatomic, readonly) NSUInteger translateCount;     // translateRequest calls
@property (nonatomic, copy, readonly) NSString *lastUserPrompt;
@end
