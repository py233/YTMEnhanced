#import "ThemeSettingsController.h"

@implementation ThemeSettingsController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = LOC(@"THEME_SETTINGS");
}

- (NSArray<NSDictionary *> *)rows {
    return @[
        @{@"title": LOC(@"OLED_DARK_THEME"), @"desc": LOC(@"OLED_DARK_THEME_DESC"), @"key": @"oledTheme"},
        @{@"title": LOC(@"OLED_DARK_KEYBOARD"), @"desc": LOC(@"OLED_DARK_KEYBOARD_DESC"), @"key": @"oledKeyboard"},
        @{@"title": LOC(@"LOW_CONTRAST"), @"desc": LOC(@"LOW_CONTRAST_DESC"), @"key": @"lowContrast"},
    ];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return [self rows].count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSArray<NSDictionary *> *rows = [self rows];
    NSDictionary *row = rows[MIN((NSUInteger)indexPath.row, rows.count - 1)];
    return [self switchCellWithTitle:row[@"title"] detail:row[@"desc"] key:row[@"key"] fallback:NO];
}

@end
