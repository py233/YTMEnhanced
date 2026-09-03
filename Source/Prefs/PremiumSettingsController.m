#import "PremiumSettingsController.h"

@implementation PremiumSettingsController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = LOC(@"PREMIUM_SETTINGS");
}

- (NSArray<NSDictionary *> *)rows {
    return @[
        @{@"title": LOC(@"NO_ADS"), @"desc": LOC(@"NO_ADS_DESC"), @"key": @"noAds"},
        @{@"title": LOC(@"BACKGROUND_PLAYBACK"), @"desc": LOC(@"BACKGROUND_PLAYBACK_DESC"), @"key": @"backgroundPlayback"},
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
