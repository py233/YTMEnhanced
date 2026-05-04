#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface YTMUTranslationContext : NSObject

@property (nonatomic, copy, readonly) NSString *videoId;
@property (nonatomic, copy, readonly) NSString *title;
@property (nonatomic, copy, readonly) NSString *artist;

+ (instancetype)sharedContext;
- (void)updateWithVideoId:(nullable NSString *)videoId
                    title:(nullable NSString *)title
                   artist:(nullable NSString *)artist;

@end

NS_ASSUME_NONNULL_END
