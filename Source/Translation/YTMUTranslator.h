#import <Foundation/Foundation.h>
#import "YTMUTranslationTypes.h"

NS_ASSUME_NONNULL_BEGIN

@interface YTMUTranslator : NSObject

+ (instancetype)sharedTranslator;

- (void)translateLines:(NSArray<NSString *> *)lines
               videoId:(NSString *)videoId
                 title:(nullable NSString *)title
                artist:(nullable NSString *)artist
            completion:(void(^)(NSArray<NSString *> *_Nullable translatedLines, NSError *_Nullable error))completion;

// Returns the LLM-capable provider for the user's currently selected
// translationProvider setting, or nil if (a) no provider is selected,
// (b) the selected provider is Google Translate (which doesn't expose a
// generic chat completion), or (c) no API key is configured. Used by the
// title normalizer to piggyback on the existing translation credentials.
- (nullable id<YTMULLMCompletionProvider>)currentLLMCompletionProvider;

// Display name of the provider currently selected for translation. Useful
// for diagnostic logging from the normalizer.
- (NSString *)currentProviderName;

@end

NS_ASSUME_NONNULL_END
