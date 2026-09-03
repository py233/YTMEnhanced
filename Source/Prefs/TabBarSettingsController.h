#import "YTMUSettingsTableController.h"

@interface OtherSettingsController : YTMUSettingsTableController
@end

@interface YTAssetLoader : NSObject
- (instancetype)initWithBundle:(NSBundle *)bundle;
- (UIImage *)imageNamed:(NSString *)image;
@end
