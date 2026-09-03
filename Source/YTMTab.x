#import "Headers/YTMBrowseViewController.h"
#import "Headers/YTPivotBarView.h"
#import "Headers/YTIPivotBarSupportedRenderers.h"
#import "Headers/YTAssetLoader.h"
#import "Prefs/YTMDownloads.h"
#import "Utils/YTMUSettings.h"

// The Downloads tab item is created with one of these two icon types (see
// the setRenderer: hook below) and this style hook draws the tweak's own
// icon for them. They are low enum values that YouTube Music's tab bar
// has never used for its own tabs; a collision would show the downloads
// icon on a YouTube tab, which is the signal to move to other values.
static const int YTMUDownloadsTabIconType = 1;
static const int YTMUDownloadsTabIconTypeCairo = 2;

%hook YTMPivotBarItemStyle
- (UIImage *)pivotBarItemIconImageWithIconType:(int)type color:(UIColor *)color useNewIcons:(BOOL)isNew selected:(BOOL)isSelected {
    if (type == YTMUDownloadsTabIconType || type == YTMUDownloadsTabIconTypeCairo) {
        NSString *imageName = isSelected ? @"icons/downloads_selected" : @"icons/downloads";
        if (type == YTMUDownloadsTabIconTypeCairo) imageName = isSelected ? @"icons/downloads_cairo_selected" : @"icons/downloads_cairo";

        static YTAssetLoader *loader;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{ loader = [[%c(YTAssetLoader) alloc] initWithBundle:NSBundle.ytmu_defaultBundle]; });
        return [loader imageNamed:imageName];
    }

    return %orig;
}
%end

// Every change to the tab bar's item list happens here, in one hook, in
// one order: drop the Upgrade tab, drop the tabs the user hid, then add
// the Downloads tab. (It used to be three hooks of the same method in
// three files whose order depended on link order.)
// https://gist.github.com/BandarHL/dce564ab717bed93d479fe849d654c75
static void YTMURemovePivotBarItems(YTIPivotBarRenderer *renderer, NSDictionary<NSString *, NSNumber *> *identifiersToRemove) {
    NSMutableArray<YTIPivotBarSupportedRenderers *> *items = [renderer itemsArray];
    for (NSString *identifier in identifiersToRemove) {
        if (![identifiersToRemove[identifier] boolValue]) continue;
        NSUInteger index = [items indexOfObjectPassingTest:^BOOL(YTIPivotBarSupportedRenderers *renderers, NSUInteger idx, BOOL *stop) {
            return [[[renderers pivotBarItemRenderer] pivotIdentifier] isEqualToString:identifier];
        }];
        if (index != NSNotFound) [items removeObjectAtIndex:index];
    }
}

%hook YTPivotBarView
- (void)setRenderer:(YTIPivotBarRenderer *)renderer {
    if (YTMU(@"YTMUltimateIsEnabled")) {
        YTMURemovePivotBarItems(renderer, @{
            @"SPunlimited": @YES,                                  // the Upgrade tab (PremiumStatus)
            @"FEmusic_home": @(YTMU(@"hideHomeTab")),
            @"FEmusic_immersive": @(YTMU(@"hideSamplesTab")),
            @"FEmusic_explore": @(YTMU(@"hideExploreTab")),
            @"FEmusic_library_landing": @(YTMU(@"hideLibraryTab")),
        });
    }

    if (YTMU(@"YTMUltimateIsEnabled") && !YTMU(@"hideDownloadsTab")) {
        YTIIcon *ytmuIcon = [%c(YTIIcon) new];
        ytmuIcon.iconType = YTMUDownloadsTabIconType;

        if ([[renderer description] containsString:@"TAB_BOOKMARK"]) {
            ytmuIcon.iconType = YTMUDownloadsTabIconTypeCairo;
        }

        YTIBrowseEndpoint *ytmuBrowseEndpoint = [%c(YTIBrowseEndpoint) new];
        ytmuBrowseEndpoint.browseId = @"FEytmu_downloads";

        YTICommand *ytmuCommand = [%c(YTICommand) new];
        ytmuCommand.browseEndpoint = ytmuBrowseEndpoint;

        YTIAccessibilityData *ytmuData = [%c(YTIAccessibilityData) new];
        ytmuData.label = LOC(@"DOWNLOADS");

        YTIAccessibilitySupportedDatas *ytmuAccessibility = [%c(YTIAccessibilitySupportedDatas) new];
        ytmuAccessibility.accessibilityData = ytmuData;

        YTIPivotBarItemRenderer *barItem = [[%c(YTIPivotBarItemRenderer) alloc] init];
        barItem.pivotIdentifier = @"FEytmu_downloads";
        barItem.targetId = @"pivot-ytmu-downloads";
        barItem.title = [%c(YTIFormattedString) formattedStringWithString:LOC(@"DOWNLOADS")];
        barItem.icon = ytmuIcon;
        barItem.navigationEndpoint = ytmuCommand;
        barItem.accessibility = ytmuAccessibility;

        YTIPivotBarSupportedRenderers *ytmuRenderer = [%c(YTIPivotBarSupportedRenderers) new];
        ytmuRenderer.pivotBarItemRenderer = barItem;

        [renderer.itemsArray addObject:ytmuRenderer];
    }

    %orig(renderer);
}
%end

%hook YTMBrowseViewController
- (void)viewDidLoad {
    %orig;

    if (YTMU(@"YTMUltimateIsEnabled") && !YTMU(@"hideDownloadsTab")) {
        YTICommand *navEndpoint = nil;

        if (class_getInstanceVariable([self class], "_navEndpoint") != NULL) {
            navEndpoint = [self valueForKey:@"_navEndpoint"];
        }

        if (class_getInstanceVariable([self class], "_navigationEndpoint") != NULL) {
            navEndpoint = [self valueForKey:@"_navigationEndpoint"];
        }

        if (navEndpoint) {
            if ([navEndpoint.browseEndpoint.browseId isEqualToString:@"FEytmu_downloads"]) {
                YTMDownloads *ytmuDownloadsVC = [[YTMDownloads alloc] init];
                [self addChildViewController:ytmuDownloadsVC];
                [ytmuDownloadsVC.view setFrame:CGRectMake(0.0f, 0.0f, self.view.frame.size.width, self.view.frame.size.height)];
                [self.view addSubview:ytmuDownloadsVC.view];
                [self.view endEditing:YES];
                [ytmuDownloadsVC didMoveToParentViewController:self];
            }
        }
    }
}
%end