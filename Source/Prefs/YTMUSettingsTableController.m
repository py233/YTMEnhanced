#import "YTMUSettingsTableController.h"
#import "../Headers/ABCSwitch.h"
#import "../Utils/YTMUSettings.h"

@implementation YTMUSettingsTableController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    [self.view addSubview:self.tableView];
    [NSLayoutConstraint activateConstraints:@[
        [self.tableView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
    ]];
}

#pragma mark - Cell builders

static UIColor *YTMUSettingsSwitchTint(void) {
    return [UIColor colorWithRed:30.0/255.0 green:150.0/255.0 blue:245.0/255.0 alpha:1.0];
}

- (UITableViewCell *)switchCellWithTitle:(NSString *)title detail:(NSString *)detail key:(NSString *)key fallback:(BOOL)fallback {
    return [self switchCellWithTitle:title detail:detail key:key fallback:fallback action:@selector(ytmu_settingSwitchChanged:)];
}

- (UITableViewCell *)switchCellWithTitle:(NSString *)title detail:(NSString *)detail key:(NSString *)key fallback:(BOOL)fallback action:(SEL)action {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"switchCell"];
    cell.textLabel.text = title;
    cell.textLabel.adjustsFontSizeToFitWidth = YES;
    cell.textLabel.numberOfLines = 0;
    cell.detailTextLabel.text = detail;
    cell.detailTextLabel.numberOfLines = 0;
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    ABCSwitch *switchControl = [[NSClassFromString(@"ABCSwitch") alloc] init];
    switchControl.onTintColor = YTMUSettingsSwitchTint();
    switchControl.on = YTMUSettingsBool(key, fallback);
    switchControl.accessibilityIdentifier = key;
    [switchControl addTarget:self action:action forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = switchControl;
    return cell;
}

- (UISegmentedControl *)segmentedControlWithItems:(NSArray *)items key:(NSString *)key fallback:(NSInteger)fallback {
    UISegmentedControl *control = [[UISegmentedControl alloc] initWithItems:items];
    NSInteger index = YTMUSettingsInteger(key, fallback);
    control.selectedSegmentIndex = (index >= 0 && index < (NSInteger)items.count) ? index : UISegmentedControlNoSegment;
    control.accessibilityIdentifier = key;
    [control addTarget:self action:@selector(ytmu_settingSegmentChanged:) forControlEvents:UIControlEventValueChanged];
    for (UIView *segmentView in control.subviews) {
        for (UIView *subview in segmentView.subviews) {
            if ([subview isKindOfClass:[UILabel class]]) ((UILabel *)subview).adjustsFontSizeToFitWidth = YES;
        }
    }
    return control;
}

- (UITableViewCell *)segmentedCellWithTitle:(NSString *)title items:(NSArray *)items key:(NSString *)key fallback:(NSInteger)fallback {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"segmentedCell"];
    cell.textLabel.text = title;
    cell.textLabel.adjustsFontSizeToFitWidth = YES;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.accessoryView = [self segmentedControlWithItems:items key:key fallback:fallback];
    return cell;
}

- (UITableViewCell *)fullWidthSegmentedCellWithItems:(NSArray *)items key:(NSString *)key fallback:(NSInteger)fallback {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"fullWidthSegmentedCell"];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    UISegmentedControl *control = [self segmentedControlWithItems:items key:key fallback:fallback];
    control.translatesAutoresizingMaskIntoConstraints = NO;
    [cell.contentView addSubview:control];
    [NSLayoutConstraint activateConstraints:@[
        [control.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
        [control.centerXAnchor constraintEqualToAnchor:cell.contentView.centerXAnchor],
        [control.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:5.0],
        [control.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-5.0],
    ]];
    return cell;
}

- (UITableViewCell *)choiceCellWithTitle:(NSString *)title detail:(NSString *)detail {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"choiceCell"];
    cell.textLabel.text = title;
    cell.detailTextLabel.text = detail;
    cell.detailTextLabel.adjustsFontSizeToFitWidth = YES;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

#pragma mark - Control actions

- (void)ytmu_settingSwitchChanged:(UISwitch *)sender {
    NSString *key = sender.accessibilityIdentifier;
    if (key.length) YTMUSettingsSetObject(key, @(sender.isOn));
}

- (void)ytmu_settingSegmentChanged:(UISegmentedControl *)sender {
    NSString *key = sender.accessibilityIdentifier;
    if (key.length) YTMUSettingsSetObject(key, @(sender.selectedSegmentIndex));
}

#pragma mark - Table view defaults (subclasses override the data source)

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    return UITableViewAutomaticDimension;
}

- (BOOL)tableView:(UITableView *)tableView shouldHighlightRowAtIndexPath:(NSIndexPath *)indexPath {
    return NO;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return 0;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    return [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"emptyCell"];
}

@end
