#import "NavBarSettingsController.h"

@implementation NavBarSettingsController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = LOC(@"NAVBAR_SETTINGS");
}

- (NSArray<NSDictionary *> *)rows {
    return @[
        @{@"title": LOC(@"DONT_STICK_HEADERS"), @"desc": LOC(@"DONT_STICK_HEADERS_DESC"), @"key": @"noStickyHeaders"},
        @{@"title": LOC(@"HIDE_HISTORY_BUTTON"), @"desc": LOC(@"HIDE_HISTORY_BUTTON_DESC"), @"key": @"hideHistoryButton"},
        @{@"title": LOC(@"HIDE_CAST_BUTTON"), @"desc": LOC(@"HIDE_CAST_BUTTON_DESC"), @"key": @"hideCastButton"},
        @{@"title": LOC(@"HIDE_FILTER_BUTTON"), @"desc": LOC(@"HIDE_FILTER_BUTTON_DESC"), @"key": @"hideFilterButton"},
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
