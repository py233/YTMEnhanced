#import "YTMUTestFakeLLM.h"

@interface YTMUTestFakeLLM ()
@property (nonatomic, readwrite) NSUInteger callCount;
@property (nonatomic, readwrite) NSUInteger translateCount;
@property (nonatomic, copy, readwrite) NSString *lastUserPrompt;
@end

@implementation YTMUTestFakeLLM
- (instancetype)init { self = [super init]; _name = @"fake"; return self; }
- (NSString *)providerName { return self.name; }
- (NSString *)modelIdentifier { return @"fake-model"; }

- (void)completeWithSystemPrompt:(NSString *)systemPrompt
                      userPrompt:(NSString *)userPrompt
                  expectJSONMode:(BOOL)expectJSONMode
                      completion:(void (^)(NSString *_Nullable, NSError *_Nullable))completion {
    self.callCount++;
    self.lastUserPrompt = userPrompt;
    NSString *text = self.responseText; NSError *error = self.responseError;
    // Mirror the real providers: complete asynchronously, off the main thread.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        completion(error ? nil : text, error);
    });
}

- (void)translateRequest:(YTMUTranslationRequest *)request
              completion:(void (^)(NSArray<NSString *> *_Nullable, NSError *_Nullable))completion {
    self.translateCount++;
    NSArray *lines = self.translatedLines; NSError *error = self.translationError;
    if (self.translationHandler) { NSError *e = nil; lines = self.translationHandler(request, &e); error = e; }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        completion(error ? nil : lines, error);
    });
}
@end
