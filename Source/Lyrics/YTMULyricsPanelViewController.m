#import "YTMULyricsPanelViewController.h"
#import "YTMULyricsPanelSupport.h"

@implementation YTMULyricsPanelViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithRed:0.035 green:0.095 blue:0.135 alpha:1.0];

    self.closeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    UIImage *closeImage = nil;
    if (@available(iOS 13.0, *)) closeImage = [UIImage systemImageNamed:@"xmark"];
    if (closeImage) {
        [self.closeButton setImage:closeImage forState:UIControlStateNormal];
    } else {
        [self.closeButton setTitle:YTMULyricsPageLocalized(@"CLOSE", @"Close") forState:UIControlStateNormal];
        self.closeButton.titleLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightSemibold];
    }
    self.closeButton.tintColor = [UIColor whiteColor];
    [self.closeButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.closeButton.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.12];
    self.closeButton.layer.cornerRadius = 17.0;
    self.closeButton.clipsToBounds = YES;
    [self.closeButton addTarget:self action:@selector(ytmu_closeLyricsPanel:) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.closeButton];

    self.lyricsOverlayView = [[YTMULyricsTabOverlayView alloc] initWithFrame:CGRectZero];
    self.lyricsOverlayView.playerViewController = self.playerViewController;
    [self.view addSubview:self.lyricsOverlayView];
    [self.view bringSubviewToFront:self.closeButton];
    [self.lyricsOverlayView ytmu_renderTabOverlay];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    UIEdgeInsets safe = UIEdgeInsetsZero;
    if (@available(iOS 11.0, *)) safe = self.view.safeAreaInsets;
    CGFloat top = safe.top + 15.0;
    CGFloat closeWidth = 34.0;
    self.closeButton.frame = CGRectMake(self.view.bounds.size.width - safe.right - closeWidth - 14.0,
                                        top,
                                        closeWidth,
                                        34.0);
    self.lyricsOverlayView.frame = self.view.bounds;
}

- (void)ytmu_closeLyricsPanel:(id)sender {
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end
