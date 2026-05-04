#import <UIKit/UIKit.h>
#import "Headers/YTPlayerViewController.h"
#import "Lyrics/YTMULyricsManager.h"
#import "Lyrics/YTMUSyncedLyricsView.h"
#import "Translation/YTMUTranslationContext.h"

static BOOL YTMUSyncedLyricsEnabled(void) {
    NSDictionary *dict = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"YTMUltimate"] ?: @{};
    return [dict[@"YTMUltimateIsEnabled"] boolValue] && [dict[@"syncedLyricsEnabled"] boolValue];
}

static void YTMULogOfficialLyricsProbe(id object, NSString *event, NSString *source, NSData *data, NSString *entityKey) {
    if (!YTMULyricsDebugLoggingEnabled()) return;
    static NSMutableSet<NSString *> *seen;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        seen = [NSMutableSet set];
    });

    NSString *signature = [NSString stringWithFormat:@"%@::%@::%@::%lu::%@",
                           NSStringFromClass([object class]),
                           event ?: @"",
                           source ?: @"",
                           (unsigned long)data.length,
                           entityKey ?: @""];
    @synchronized (seen) {
        if ([seen containsObject:signature]) return;
        [seen addObject:signature];
    }
    YTMULyricsLog(@"official lyrics probe event=%@ class=%@ source=%@ dataBytes=%lu entityKey=%@",
                  event ?: @"<unknown>",
                  NSStringFromClass([object class]),
                  source.length ? source : @"<empty>",
                  (unsigned long)data.length,
                  entityKey.length ? entityKey : @"<empty>");
}

@interface YTPlayerViewController ()
@property (nonatomic, retain) YTMUSyncedLyricsView *ytmuSyncedLyricsView;
- (void)ytmu_attachSyncedLyricsViewIfNeeded;
- (void)ytmu_layoutSyncedLyricsView;
@end

@interface YTClientLyricsDataModel : NSObject
- (NSString *)lyricsSource;
- (NSData *)data;
@end

@interface YTMusicLyricsEntityModel : NSObject
- (id)clientLyricsData;
- (NSData *)data;
- (NSString *)entityKey;
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

    YTMULyricsSearchInfo *info = [[YTMULyricsSearchInfo alloc] init];
    info.videoId = videoId;
    info.title = title;
    info.alternativeTitle = title;
    info.artist = artist;
    info.duration = duration;

    if (!YTMUSyncedLyricsEnabled()) {
        [[YTMULyricsManager sharedManager] refreshWithInfo:info];
        return;
    }

    [self ytmu_attachSyncedLyricsViewIfNeeded];
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

%group YTMUOfficialLyricsProbe

%hook YTClientLyricsDataModel

- (NSString *)lyricsSource {
    NSString *source = %orig;
    NSData *data = nil;
    @try {
        data = [self data];
    } @catch (__unused NSException *exception) {
        data = nil;
    }
    YTMULogOfficialLyricsProbe(self, @"clientLyricsData.lyricsSource", source, data, @"");
    return source;
}

%end

%hook YTMusicLyricsEntityModel

- (id)clientLyricsData {
    id clientData = %orig;
    NSString *source = @"";
    if ([clientData respondsToSelector:@selector(lyricsSource)]) {
        source = [clientData lyricsSource];
    }
    NSData *data = nil;
    NSString *entityKey = @"";
    @try {
        data = [self data];
        entityKey = [self entityKey];
    } @catch (__unused NSException *exception) {
        data = nil;
        entityKey = @"";
    }
    YTMULogOfficialLyricsProbe(self, @"musicLyricsEntity.clientLyricsData", source, data, entityKey);
    return clientData;
}

%end

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
    %init;
    YTMULyricsLog(@"synced lyrics module loaded");
    if (NSClassFromString(@"YTClientLyricsDataModel") || NSClassFromString(@"YTMusicLyricsEntityModel")) {
        %init(YTMUOfficialLyricsProbe);
        YTMULyricsLog(@"official lyrics probe installed");
    }
}
