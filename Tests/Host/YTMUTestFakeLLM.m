#import "YTMUTestFakeLLM.h"

@interface YTMUTestFakeLLM ()
@property (nonatomic, readwrite) NSUInteger callCount;
@property (nonatomic, copy, readwrite) NSString *lastUserPrompt;
@end

@implementation YTMUTestFakeLLM
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
@end
