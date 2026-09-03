#import "TabBarSettingsController.h"
#import "../Utils/YTMUSettings.h"

@implementation OtherSettingsController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = LOC(@"TABBAR_SETTINGS");
}

- (NSArray<NSDictionary *> *)tabRows {
    return @[
        @{@"title": LOC(@"REMOVE_TABBAR_LABELS"), @"key": @"noTabBarLabels"},
        @{@"title": LOC(@"HIDE_HOME"), @"key": @"hideHomeTab"},
        @{@"title": LOC(@"HIDE_SAMPLES"), @"key": @"hideSamplesTab"},
        @{@"title": LOC(@"HIDE_EXPLORE"), @"key": @"hideExploreTab"},
        @{@"title": LOC(@"HIDE_LIBRARY"), @"key": @"hideLibraryTab"},
        @{@"title": LOC(@"HIDE_DOWNLOADS"), @"key": @"hideDownloadsTab"},
    ];
}

#pragma mark - Table view

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    return 45;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 2;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return section == 1 ? [self tabRows].count : 1;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return section == 0 ? LOC(@"STARTUP_TAB") : LOC(@"TAB_SETTINGS");
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 0) {
        NSArray *icons = @[[self tbImageNamed:@"yt_outline_home_24pt"],
                           [self tbImageNamed:@"youtube_outline/samples_24pt"],
                           [self tbImageNamed:@"yt_outline_compass_24pt"],
                           [self tbImageNamed:@"yt_outline_library_music_24pt"],
                           [self tbImageNamed:@"icons/downloads"]];
        return [self fullWidthSegmentedCellWithItems:icons key:@"startupPage" fallback:0];
    }
    NSArray<NSDictionary *> *rows = [self tabRows];
    NSDictionary *row = rows[MIN((NSUInteger)indexPath.row, rows.count - 1)];
    return [self switchCellWithTitle:row[@"title"] detail:nil key:row[@"key"] fallback:NO];
}

// The startup-tab picker's icons come from the app's own asset catalog.
// When a build renames an asset (or the loader class), a system symbol
// stands in — UISegmentedControl's item list must never contain nil.
- (UIImage *)tbImageNamed:(NSString *)imageName {
    BOOL isDownloads = [imageName isEqualToString:@"icons/downloads"];
    YTAssetLoader *al = [[NSClassFromString(@"YTAssetLoader") alloc] initWithBundle:isDownloads ? NSBundle.ytmu_defaultBundle : [NSBundle mainBundle]];
    UIImage *image = [al imageNamed:imageName];
    if (image) return image;

    NSDictionary<NSString *, NSString *> *fallbacks = @{
        @"yt_outline_home_24pt": @"house",
        @"youtube_outline/samples_24pt": @"play.rectangle",
        @"yt_outline_compass_24pt": @"safari",
        @"yt_outline_library_music_24pt": @"music.note.list",
        @"icons/downloads": @"arrow.down.circle",
    };
    return [UIImage systemImageNamed:fallbacks[imageName] ?: @"questionmark.circle"] ?: [[UIImage alloc] init];
}

@end
