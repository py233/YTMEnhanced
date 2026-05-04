#import <UIKit/UIKit.h>
#import "Headers/YTPlayerViewController.h"
#import "Lyrics/YTMULyricsManager.h"
#import "Lyrics/YTMUSyncedLyricsView.h"
#import "Translation/YTMUTranslationContext.h"

static BOOL YTMUSyncedLyricsEnabled(void) {
    NSDictionary *dict = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"YTMUltimate"] ?: @{};
    return [dict[@"YTMUltimateIsEnabled"] boolValue] && [dict[@"syncedLyricsEnabled"] boolValue];
}

@interface YTPlayerViewController ()
@property (nonatomic, retain) YTMUSyncedLyricsView *ytmuSyncedLyricsView;
- (void)ytmu_attachSyncedLyricsViewIfNeeded;
- (void)ytmu_layoutSyncedLyricsView;
@end

%hook YTPlayerViewController

%property (nonatomic, retain) YTMUSyncedLyricsView *ytmuSyncedLyricsView;

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    [self ytmu_attachSyncedLyricsViewIfNeeded];
}

- (void)viewDidLayoutSubviews {
    %orig;
    [self ytmu_layoutSyncedLyricsView];
}

- (void)playbackController:(id)arg1 didActivateVideo:(id)arg2 withPlaybackData:(id)arg3 {
    %orig;

    NSString *videoId = self.currentVideoID ?: self.contentVideoID ?: @"";
    YTIVideoDetails *details = self.playerResponse.playerData.videoDetails;
    NSString *title = details.title ?: @"";
    NSString *artist = details.author ?: @"";
    NSTimeInterval duration = self.currentVideoTotalMediaTime;
    [[YTMUTranslationContext sharedContext] updateWithVideoId:videoId title:title artist:artist];

    if (!YTMUSyncedLyricsEnabled()) {
        [[YTMULyricsManager sharedManager] clearCurrent];
        return;
    }

    [self ytmu_attachSyncedLyricsViewIfNeeded];
    YTMULyricsSearchInfo *info = [[YTMULyricsSearchInfo alloc] init];
    info.videoId = videoId;
    info.title = title;
    info.alternativeTitle = title;
    info.artist = artist;
    info.duration = duration;
    [[YTMULyricsManager sharedManager] refreshWithInfo:info];
}

- (void)singleVideo:(id)video currentVideoTimeDidChange:(id)time {
    %orig;
    [self.ytmuSyncedLyricsView updatePlaybackTimeMs:self.currentVideoMediaTime * 1000.0];
}

- (void)potentiallyMutatedSingleVideo:(id)video currentVideoTimeDidChange:(id)time {
    %orig;
    [self.ytmuSyncedLyricsView updatePlaybackTimeMs:self.currentVideoMediaTime * 1000.0];
}

%new
- (void)ytmu_attachSyncedLyricsViewIfNeeded {
    if (!YTMUSyncedLyricsEnabled()) {
        self.ytmuSyncedLyricsView.hidden = YES;
        return;
    }
    if (!self.ytmuSyncedLyricsView) {
        self.ytmuSyncedLyricsView = [[YTMUSyncedLyricsView alloc] initWithFrame:CGRectZero];
        self.ytmuSyncedLyricsView.playerViewController = self;
        self.ytmuSyncedLyricsView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
        [self.view addSubview:self.ytmuSyncedLyricsView];
        [self ytmu_layoutSyncedLyricsView];
        [self.ytmuSyncedLyricsView reloadFromManager];
    }
}

%new
- (void)ytmu_layoutSyncedLyricsView {
    if (!self.ytmuSyncedLyricsView) return;
    UIEdgeInsets safe = self.view.safeAreaInsets;
    CGFloat width = self.view.bounds.size.width - 20;
    CGFloat height = MIN(MAX(self.view.bounds.size.height * 0.38, 210), 360);
    CGFloat y = self.view.bounds.size.height - height - safe.bottom - 14;
    self.ytmuSyncedLyricsView.frame = CGRectMake(10, MAX(safe.top + 12, y), width, height);
}

%end

%ctor {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithDictionary:[defaults dictionaryForKey:@"YTMUltimate"] ?: @{}];
    YTMULyricsSetDefault(dict, @"syncedLyricsEnabled", @(NO));
    YTMULyricsSetDefault(dict, @"lyricsPreferredSource", @"auto");
    YTMULyricsSetDefault(dict, @"lyricsShowInexact", @(YES));
    YTMULyricsSetDefault(dict, @"lyricsRomanization", @(YES));
    YTMULyricsSetDefault(dict, @"lyricsConvertChinese", @"disabled");
    YTMULyricsSetDefault(dict, @"lyricsShowTimeCodes", @(NO));
    YTMULyricsSetDefault(dict, @"lyricsLineEffect", @"fancy");
    YTMULyricsSetDefault(dict, @"lyricsFontSize", @"small");
    YTMULyricsSetDefault(dict, @"lyricsDefaultText", @"♪");
    YTMULyricsSetDefault(dict, @"lyricsTranslationEnabled", @(NO));
    [defaults setObject:dict forKey:@"YTMUltimate"];
    YTMULyricsLog(@"synced lyrics module loaded");
}
