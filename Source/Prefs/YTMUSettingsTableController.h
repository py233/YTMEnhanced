#import <UIKit/UIKit.h>
#import "../Headers/Localization.h"

NS_ASSUME_NONNULL_BEGIN

// Shared scaffolding for the settings screens: the inset-grouped table,
// automatic row height, no row highlight, and cell builders whose control
// writes the settings key it carries (in `accessibilityIdentifier`). A
// screen is then a list of rows, not a switch statement plus a tag table
// that has to be kept in step with it.
@interface YTMUSettingsTableController : UIViewController <UITableViewDelegate, UITableViewDataSource>

@property (nonatomic, strong) UITableView *tableView;

// A row with an ABCSwitch bound to `key`; toggling writes the key.
- (UITableViewCell *)switchCellWithTitle:(NSString *)title
                                  detail:(nullable NSString *)detail
                                     key:(NSString *)key
                                fallback:(BOOL)fallback;

// Same, but the toggle calls `action` on the controller (the switch's
// accessibilityIdentifier carries the key) for screens that need to do
// more than store the value.
- (UITableViewCell *)switchCellWithTitle:(NSString *)title
                                  detail:(nullable NSString *)detail
                                     key:(NSString *)key
                                fallback:(BOOL)fallback
                                  action:(SEL)action;

// A titled row whose accessory is a UISegmentedControl bound to an
// integer key; selecting writes the index.
- (UITableViewCell *)segmentedCellWithTitle:(NSString *)title
                                      items:(NSArray *)items
                                        key:(NSString *)key
                                   fallback:(NSInteger)fallback;

// A segmented control filling the whole row (no title), bound like above.
- (UITableViewCell *)fullWidthSegmentedCellWithItems:(NSArray *)items
                                                 key:(NSString *)key
                                            fallback:(NSInteger)fallback;

// Value1-style row with a disclosure indicator.
- (UITableViewCell *)choiceCellWithTitle:(NSString *)title detail:(nullable NSString *)detail;

@end

NS_ASSUME_NONNULL_END
