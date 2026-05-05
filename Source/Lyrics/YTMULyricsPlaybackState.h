#import <Foundation/Foundation.h>

@class YTPlayerViewController;

NS_ASSUME_NONNULL_BEGIN

@interface YTMULyricsPlaybackState : NSObject

@property (nonatomic, weak, nullable) YTPlayerViewController *playerViewController;
@property (nonatomic) NSTimeInterval lastPlaybackTimeMs;
@property (nonatomic) NSTimeInterval lastPlaybackWallClock;

+ (instancetype)sharedState;
- (void)notePlayerViewController:(nullable YTPlayerViewController *)playerViewController;
- (void)notePlaybackTimeMs:(NSTimeInterval)timeMs;
- (NSTimeInterval)currentPlaybackTimeMs;

@end

NS_ASSUME_NONNULL_END
