#import <UIKit/UIKit.h>
#import "YTMULyricsTypes.h"

@class YTPlayerViewController;

NS_ASSUME_NONNULL_BEGIN

@interface YTMUSyncedLyricsView : UIView
@property (nonatomic, weak, nullable) YTPlayerViewController *playerViewController;
// While the user is dragging (or the scroll is still decelerating) the view
// never auto-follows the active line; once the interaction ends it waits
// this long — every new interaction resets the wait — before smoothly
// scrolling back. The karaoke highlight keeps updating throughout.
@property (nonatomic) NSTimeInterval followResumeDelay;   // default 3.0
- (void)reloadFromManager;
- (void)updatePlaybackTimeMs:(NSTimeInterval)timeMs;
@end

NS_ASSUME_NONNULL_END
