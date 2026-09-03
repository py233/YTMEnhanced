#import "YTMUltimateSettingsController.h"
#import "../Utils/YTMUSettings.h"
#import "../Utils/YTMUPaths.h"
#import "../Lyrics/YTMULyricsCache.h"
#import "../Lyrics/YTMURomanizationService.h"
#import "../Lyrics/YTMULyricsTitleNormalizer.h"
#import "../Lyrics/YTMULyricsDescriptionExtractor.h"
#import "../Lyrics/YTMUInnerTubeDescriptionFetcher.h"
#import "../Translation/YTMUTranslationCache.h"
#import "../Scrobbling/YTMUScrobbleResolver.h"

@interface YTMUltimateSettingsController ()
// The tweak's cache size, measured off the main thread on demand; nil
// while unknown (the row shows "…").
@property (nonatomic, copy) NSString *cacheSizeText;
@property (nonatomic) BOOL cacheSizeInFlight;
@end

@implementation YTMUltimateSettingsController

- (void)viewDidLoad {
    [super viewDidLoad];

    UIBarButtonItem *closeButton = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"xmark"]
                                                                    style:UIBarButtonItemStylePlain
                                                                   target:self
                                                                   action:@selector(closeButtonTapped:)]; 

    UIBarButtonItem *applyButton = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"checkmark"]
                                                                    style:UIBarButtonItemStylePlain
                                                                   target:self
                                                                   action:@selector(applyButtonTapped:)]; 

    self.navigationItem.leftBarButtonItem = closeButton;
    self.navigationItem.rightBarButtonItem = applyButton;

    // Show the system-localized generic "Back" on pushed sub-pages instead of
    // this screen's title, which otherwise shows next to short titles (e.g.
    // "Scrobbling") but collapses to "Back" next to longer ones.
    if (@available(iOS 14.0, *)) {
        self.navigationItem.backButtonDisplayMode = UINavigationItemBackButtonDisplayModeGeneric;
    }

    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    [self.view addSubview:self.tableView];

    [NSLayoutConstraint activateConstraints:@[
        [self.tableView.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.tableView.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [self.tableView.widthAnchor constraintEqualToAnchor:self.view.widthAnchor],
        [self.tableView.heightAnchor constraintEqualToAnchor:self.view.heightAnchor]
    ]];

    //Init isEnabled for first time
    YTMUSettingsRegisterDefaults(@{@"YTMUltimateIsEnabled": @YES});
}

#pragma mark - Table view stuff
- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    return UITableViewAutomaticDimension;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 4;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return section == 3 ? LOC(@"LINKS") : nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0) {
        return LOC(@"RESTART_FOOTER");
    } if (section == 3) {
        NSDictionary *infoDictionary = [[NSBundle mainBundle] infoDictionary];
        NSString *appVersion = infoDictionary[@"CFBundleShortVersionString"];
        return [NSString stringWithFormat:@"\nYouTubeMusic: v%@\nYTMEnhanced: v%@", appVersion, @(OS_STRINGIFY(TWEAK_VERSION))];
    }

    return nil;
}

- (void)tableView:(UITableView *)tableView willDisplayFooterView:(UIView *)view forSection:(NSInteger)section {
    if (section == 3) {
        UITableViewHeaderFooterView *footer = (UITableViewHeaderFooterView *)view;
        footer.textLabel.textAlignment = NSTextAlignmentCenter;
    }
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section{
    switch (section) {
        case 0:
            return 1;
        case 1:
            return 7;
        case 2:
            return 1;
        case 3:
            return 2;
        default:
            return 0;
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"cell"];
    if (cell == nil) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"cell"];
    }

    else {
        for (UIView *subview in cell.contentView.subviews) {
            [subview removeFromSuperview];
        }
    }

    NSDictionary *YTMUltimateDict = YTMUSettingsSnapshot();

    if (indexPath.section == 0) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"masterSection"];

        cell.textLabel.text = LOC(@"ENABLED");
        cell.textLabel.adjustsFontSizeToFitWidth = YES;
        cell.textLabel.textColor = [UIColor colorWithRed:230/255.0 green:75/255.0 blue:75/255.0 alpha:255/255.0];
        cell.imageView.image = [UIImage systemImageNamed:@"power"];
        cell.imageView.tintColor = [UIColor colorWithRed:230/255.0 green:75/255.0 blue:75/255.0 alpha:255/255.0];

        ABCSwitch *masterSwitch = [[NSClassFromString(@"ABCSwitch") alloc] init];
        masterSwitch.onTintColor = [UIColor colorWithRed:230/255.0 green:75/255.0 blue:75/255.0 alpha:255/255.0];
        [masterSwitch addTarget:self action:@selector(toggleMasterSwitch:) forControlEvents:UIControlEventValueChanged];
        masterSwitch.on = [YTMUltimateDict[@"YTMUltimateIsEnabled"] boolValue];
        cell.accessoryView = masterSwitch;

        return cell;
    }

    if (indexPath.section == 1) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"settingsSection"];

        NSArray *settingsData = @[
            @{@"title": LOC(@"PREMIUM_SETTINGS"), @"image": @"flame"},
            @{@"title": LOC(@"PLAYER_SETTINGS"), @"image": @"play.rectangle"},
            @{@"title": LOC(@"THEME_SETTINGS"), @"image": @"paintbrush"},
            @{@"title": LOC(@"NAVBAR_SETTINGS"), @"image": @"sidebar.trailing"},
            @{@"title": LOC(@"TABBAR_SETTINGS"), @"image": @"dock.rectangle"},
            @{@"title": LOC(@"TRANSLATION_SETTINGS"), @"image": @"character.bubble"},
            @{@"title": LOC(@"SCROBBLING_SETTINGS"), @"image": @"waveform.path"}
        ];

        NSDictionary *settingData = settingsData[indexPath.row];

        cell.textLabel.text = settingData[@"title"];
        cell.detailTextLabel.numberOfLines = 0;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.imageView.image = [UIImage systemImageNamed:settingData[@"image"]];

        return cell;
    }

    if (indexPath.section == 2) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"cacheSection"];

        cell.textLabel.text = LOC(@"CLEAR_CACHE");

        UILabel *cache = [[UILabel alloc] init];
        cache.text = self.cacheSizeText ?: @"…";
        cache.textColor = [UIColor secondaryLabelColor];
        cache.font = [UIFont systemFontOfSize:16];
        cache.textAlignment = NSTextAlignmentRight;
        [cache sizeToFit];

        cell.accessoryView = cache;
        cell.imageView.image = [UIImage systemImageNamed:@"trash"];
        cell.imageView.tintColor = [UIColor redColor];
        if (!self.cacheSizeText) [self measureCacheSize];

        return cell;
    }

    if (indexPath.section == 3) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"linkSection"];

        NSArray *settingsData = @[
            @{@"text": LOC(@"SOURCE_CODE"), @"detail": LOC(@"SOURCE_CODE_DESC"), @"image": @"github-24@2x"},
            @{@"text": @"Telegram", @"detail": @"@YTMEnhanced", @"systemImage": @"paperplane.circle.fill"}
        ];

        NSDictionary *settingData = settingsData[indexPath.row];

        cell.textLabel.text = settingData[@"text"];
        cell.textLabel.textColor = [UIColor systemBlueColor];
        cell.textLabel.adjustsFontSizeToFitWidth = YES;
        cell.detailTextLabel.text = settingData[@"detail"];
        cell.detailTextLabel.numberOfLines = 0;

        if (settingData[@"systemImage"]) {
            UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:20];
            cell.imageView.image = [UIImage systemImageNamed:settingData[@"systemImage"] withConfiguration:config];
            cell.imageView.tintColor = [UIColor systemBlueColor];
        } else {
            UIImage *image = [UIImage imageWithContentsOfFile:[NSBundle.ytmu_defaultBundle pathForResource:settingData[@"image"] ofType:@"png" inDirectory:@"icons"]];
            cell.imageView.image = [image imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
        }
        cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];

        return cell;
    }

    return cell;
}

// Only the tweak's own cache root (YTMUCachesDirectory) is measured and
// cleared. The app's caches under Library/Caches are not ours; upstream
// summed all of them on the main thread and deleted the whole directory.
static NSString *YTMUCacheSizeText(void) {
    NSString *cachePath = YTMUCachesDirectory();
    NSFileManager *fileManager = [NSFileManager defaultManager];
    unsigned long long folderSize = 0;
    for (NSString *fileName in [fileManager subpathsOfDirectoryAtPath:cachePath error:nil]) {
        NSDictionary *attributes = [fileManager attributesOfItemAtPath:[cachePath stringByAppendingPathComponent:fileName] error:nil];
        if ([attributes.fileType isEqualToString:NSFileTypeRegular]) folderSize += attributes.fileSize;
    }
    NSByteCountFormatter *formatter = [[NSByteCountFormatter alloc] init];
    formatter.countStyle = NSByteCountFormatterCountStyleFile;
    return [formatter stringFromByteCount:(long long)folderSize];
}

- (void)measureCacheSize {
    if (self.cacheSizeInFlight) return;
    self.cacheSizeInFlight = YES;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSString *text = YTMUCacheSizeText();
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf.cacheSizeInFlight = NO;
            strongSelf.cacheSizeText = text;
            [strongSelf.tableView reloadRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:0 inSection:2]] withRowAnimation:UITableViewRowAnimationNone];
        });
    });
}

- (void)clearCaches {
    // Each module drops its memory cache and its own files; whatever is
    // left under the root afterwards (older layouts, stray files) goes too.
    [[YTMULyricsCache sharedCache] clearAll];
    [[YTMUTranslationCache sharedCache] clearAll];
    [[YTMURomanizationService sharedService] clearMemoryCache];
    [[YTMULyricsTitleNormalizer sharedNormalizer] clearCache];
    [[YTMULyricsDescriptionExtractor sharedExtractor] clearCache];
    [[YTMUInnerTubeDescriptionFetcher sharedFetcher] clearCache];
    [[YTMUScrobbleResolver sharedResolver] clearCaches];
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSString *root = YTMUCachesDirectory();
        NSFileManager *fileManager = [NSFileManager defaultManager];
        for (NSString *child in [fileManager contentsOfDirectoryAtPath:root error:nil]) {
            [fileManager removeItemAtPath:[root stringByAppendingPathComponent:child] error:nil];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf.cacheSizeText = nil;
            [strongSelf.tableView reloadRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:0 inSection:2]] withRowAnimation:UITableViewRowAnimationNone];
        });
    });
}

#pragma mark - UITableViewDelegate
- (BOOL)tableView:(UITableView *)tableView shouldHighlightRowAtIndexPath:(NSIndexPath *)indexPath {
    return indexPath.section == 0 ? NO : YES;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 1) {
        NSArray *controllers = @[[PremiumSettingsController class],
                                 [PlayerSettingsController class],
                                 [ThemeSettingsController class],
                                 [NavBarSettingsController class],
                                 [OtherSettingsController class],
                                 [TranslationSettingsController class],
                                 [ScrobblingSettingsController class]];

        if (indexPath.row >= 0 && indexPath.row < controllers.count) {
            UIViewController *controller = [[controllers[indexPath.row] alloc] init];
            [self.navigationController pushViewController:controller animated:YES];
        }
    }

    if (indexPath.section == 2 && indexPath.row == 0) {
        UIActivityIndicatorView *activityIndicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
        activityIndicator.color = [UIColor labelColor];
        [activityIndicator startAnimating];
        UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
        cell.accessoryView = activityIndicator;
        [self clearCaches];
    }

    if (indexPath.section == 3) {
        NSArray *urls = @[@"https://github.com/py233/YTMEnhanced", @"https://t.me/YTMEnhanced"];

        if (indexPath.row >= 0 && indexPath.row < urls.count) {
            NSURL *url = [NSURL URLWithString:urls[indexPath.row]];
            if ([[UIApplication sharedApplication] canOpenURL:url]) {
                [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
            }
        }
    }

    [tableView deselectRowAtIndexPath:indexPath animated:YES];
}

#pragma mark - Nav bar stuff
- (NSString *)title {
    return @"YTMEnhanced";
}

- (void)closeButtonTapped:(id)sender {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)applyButtonTapped:(id)sender {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:LOC(@"WARNING") message:LOC(@"APPLY_MESSAGE") preferredStyle:UIAlertControllerStyleAlert];

    [alert addAction:[UIAlertAction actionWithTitle:LOC(@"CANCEL") style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:LOC(@"YES") style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [[UIApplication sharedApplication] performSelector:@selector(suspend)];
            [NSThread sleepForTimeInterval:1.0];
            exit(0);
        });
    }]];

    [self presentViewController:alert animated:YES completion:nil];
}

- (void)toggleMasterSwitch:(UISwitch *)sender {
    YTMUSettingsSetObject(@"YTMUltimateIsEnabled", @([sender isOn]));
}

@end
