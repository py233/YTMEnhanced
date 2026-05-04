#import <UIKit/UIKit.h>
#import "../Headers/Localization.h"

@interface TranslationSettingsController : UIViewController <UITableViewDelegate, UITableViewDataSource, UITextFieldDelegate>
@property (nonatomic, strong) UITableView *tableView;
- (UIView *)KBToolbar:(UITextField *)textField;
@end
