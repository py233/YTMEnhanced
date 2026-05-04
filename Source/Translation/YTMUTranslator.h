#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface YTMUTranslator : NSObject

+ (instancetype)sharedTranslator;

- (void)translateLines:(NSArray<NSString *> *)lines
               videoId:(NSString *)videoId
                 title:(nullable NSString *)title
                artist:(nullable NSString *)artist
            completion:(void(^)(NSArray<NSString *> *_Nullable translatedLines, NSError *_Nullable error))completion;

@end

NS_ASSUME_NONNULL_END
