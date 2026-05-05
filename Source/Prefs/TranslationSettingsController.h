#import <UIKit/UIKit.h>
#import "../Headers/Localization.h"

@interface TranslationSettingsController : UIViewController <UITableViewDelegate, UITableViewDataSource, UITextFieldDelegate>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, weak) UITextField *activeTextField;
- (UIView *)KBToolbar:(UITextField *)textField;
@end
