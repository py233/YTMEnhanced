#import "YTMUSettingsTableController.h"

@interface ScrobblingSettingsController : YTMUSettingsTableController <UITextFieldDelegate>
@property (nonatomic, weak) UITextField *activeTextField;
@end
