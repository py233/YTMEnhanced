#import <UIKit/UIKit.h>
#import "../Headers/Localization.h"

@interface ScrobblingSettingsController : UIViewController <UITableViewDelegate, UITableViewDataSource, UITextFieldDelegate>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, weak) UITextField *activeTextField;
@end
