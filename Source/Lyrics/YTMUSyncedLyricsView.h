#import <UIKit/UIKit.h>
#import "YTMULyricsTypes.h"

@class YTPlayerViewController;

NS_ASSUME_NONNULL_BEGIN

@interface YTMUSyncedLyricsView : UIView
@property (nonatomic, weak, nullable) YTPlayerViewController *playerViewController;
- (void)reloadFromManager;
- (void)updatePlaybackTimeMs:(NSTimeInterval)timeMs;
@end

NS_ASSUME_NONNULL_END
