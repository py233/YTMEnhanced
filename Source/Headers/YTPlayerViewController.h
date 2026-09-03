#import <UIKit/UIKit.h>
#import "YTPlayerResponse.h"

@class YTMUSponsorBlockState;

@interface YTPlayerViewController : UIViewController
@property (nonatomic, assign, readonly) YTPlayerResponse *playerResponse;
@property (readonly, nonatomic) NSString *contentVideoID;
@property (nonatomic, assign, readonly) CGFloat currentVideoTotalMediaTime;
// Added by Source/SponsorBlock.x.
@property (nonatomic, strong) YTMUSponsorBlockState *ytmu_sponsorBlockState;

- (void)seekToTime:(CGFloat)time;
- (NSString *)currentVideoID;
- (CGFloat)currentVideoMediaTime;
- (void)ytmu_skipSponsorSegmentIfNeeded;
@end
