#import "YTMUSettingsTableController.h"

@interface TranslationSettingsController : YTMUSettingsTableController <UITextFieldDelegate>
@property (nonatomic, weak) UITextField *activeTextField;
- (UIView *)KBToolbar:(UITextField *)textField;
@end
