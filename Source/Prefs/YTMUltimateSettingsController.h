#import <UIKit/UIKit.h>
#import "PremiumSettingsController.h"
#import "PlayerSettingsController.h"
#import "ThemeSettingsController.h"
#import "NavBarSettingsController.h"
#import "TabBarSettingsController.h"
#import "TranslationSettingsController.h"
#import "ScrobblingSettingsController.h"

@interface YTMUltimateSettingsController : UIViewController <UITableViewDelegate, UITableViewDataSource>
@property (nonatomic, strong) UITableView* tableView;
@end
