#import <Foundation/Foundation.h>
#import "Translation/YTMUTranslationTypes.h"

// Canned YTMULLMCompletionProvider for exercising the title-normalizer and
// description-extractor parsers without a network.
@interface YTMUTestFakeLLM : NSObject <YTMULLMCompletionProvider>
@property (nonatomic, copy) NSString *responseText;   // returned to every caller
@property (nonatomic, strong) NSError *responseError; // if set, returned instead
@property (nonatomic, readonly) NSUInteger callCount;
@property (nonatomic, copy, readonly) NSString *lastUserPrompt;
@end
