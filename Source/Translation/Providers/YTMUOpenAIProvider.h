#import <Foundation/Foundation.h>
#import "../YTMUTranslationTypes.h"

NS_ASSUME_NONNULL_BEGIN

@interface YTMUOpenAIProvider : NSObject <YTMUTranslationProvider, YTMULLMCompletionProvider>
@end

NS_ASSUME_NONNULL_END
