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
// Converts a raw player time to milliseconds, guessing the unit from its
// magnitude relative to `duration` (see the implementation for the rules).
// Returns -1 when rawTime is unusable.
- (NSTimeInterval)normalizedPlaybackTimeMsForRawTime:(NSTimeInterval)rawTime duration:(NSTimeInterval)duration;

@end

NS_ASSUME_NONNULL_END
