#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "FFMpegDownloader.h"
#import "Headers/YTUIResources.h"
#import "Headers/YTMActionSheetController.h"
#import "Headers/YTMActionRowView.h"
#import "Headers/YTIPlayerOverlayRenderer.h"
#import "Headers/YTIPlayerOverlayActionSupportedRenderers.h"
#import "Headers/YTMNowPlayingViewController.h"
#import "Headers/YTPlayerView.h"
#import "Headers/YTIThumbnailDetails_Thumbnail.h"
#import "Headers/YTIFormatStream.h"
#import "Headers/YTAlertView.h"
#import "Headers/ELMNodeController.h"
#import "Lyrics/YTMULyricsPlaybackState.h"
#import "Utils/YTMUKVC.h"
#import "Utils/YTMUHLSManifest.h"
#import "Utils/YTMUSettings.h"

// The player that is playing right now. The lyrics hooks observe every
// player activation (and every time tick) and keep a weak reference in
// YTMULyricsPlaybackState, so this is the same object the Now Playing
// screen is showing — no view-hierarchy walking needed. Upstream's original
// `playingVC.parentViewController.playerViewController` chain is kept as a
// fallback, but read without assuming the parent's class: newer YouTube
// Music builds re-parent the Now Playing controller, and sending
// -playerViewController to the wrong class is what used to crash here.
static YTPlayerViewController *YTMUDownloadCurrentPlayer(UIViewController *playingVC) {
    YTPlayerViewController *tracked = [YTMULyricsPlaybackState sharedState].playerViewController;
    if (tracked) return tracked;
    id candidate = YTMUSafeValueForKey(playingVC.parentViewController, @"playerViewController");
    Class playerClass = NSClassFromString(@"YTPlayerViewController");
    return (playerClass && [candidate isKindOfClass:playerClass]) ? candidate : nil;
}

// `playerResponse` is read by key: on some builds the property getter is
// gone but the ivar is still there, and KVC reaches both.
static id YTMUDownloadPlayerResponse(YTPlayerViewController *player) {
    return YTMUSafeValueForKey(player, @"playerResponse") ?: YTMUSafeValueForKey(player, @"contentPlayerResponse");
}

static NSString *YTMUDownloadString(id object, NSString *key) {
    id value = YTMUSafeValueForKey(object, key);
    if ([value isKindOfClass:[NSString class]]) return value;
    if ([value respondsToSelector:@selector(stringValue)]) return [value stringValue];
    return @"";
}

static NSString *YTMUDownloadSanitizeFileComponent(NSString *string) {
    NSString *safe = string.length ? string : @"Unknown";
    for (NSString *part in @[@"/", @":", @"\n", @"\r"]) {
        safe = [safe stringByReplacingOccurrencesOfString:part withString:@""];
    }
    return safe;
}

static void YTMUDownloadShowAlert(NSString *titleKey, NSString *subtitleKey) {
    YTAlertView *alertView = [%c(YTAlertView) infoDialog];
    alertView.title = LOC(titleKey);
    alertView.subtitle = LOC(subtitleKey);
    [alertView show];
}

@interface UIView ()
- (UIViewController *)_viewControllerForAncestor;
@end

@interface ELMTouchCommandPropertiesHandler : NSObject
- (void)downloadAudio:(YTPlayerViewController *)playerVC;
- (void)downloadCoverImage:(YTPlayerViewController *)playerVC;
@end

// The download-badge tap. Called from the single handleTap hook in
// Source/SelectableLyrics.x (two hooks of one method in two files used to
// chain in link order). Returns YES when the tap was a download-badge tap
// and has been handled; `callOriginal` runs the app's own handler (the
// "Premium download" choice).
BOOL YTMUDownloadHandleTap(ELMTouchCommandPropertiesHandler *handler, dispatch_block_t callOriginal) {
    if (class_getInstanceVariable([handler class], "_controller") == NULL ||
        class_getInstanceVariable([handler class], "_tapRecognizer") == NULL) {
        return NO;
    }

    ELMNodeController *node = YTMUSafeValueForKey(handler, @"_controller");
    UIGestureRecognizer *tapRecognizer = YTMUSafeValueForKey(handler, @"_tapRecognizer");
    if (![node.key isEqualToString:@"music_download_badge_1"]) return NO;

    UIViewController *ancestor = [tapRecognizer.view respondsToSelector:@selector(_viewControllerForAncestor)] ? tapRecognizer.view._viewControllerForAncestor : nil;
    if (![ancestor isKindOfClass:%c(YTMNowPlayingViewController)]) return NO;

    YTMNowPlayingViewController *playingVC = (YTMNowPlayingViewController *)ancestor;
    YTPlayerViewController *playerVC = YTMUDownloadCurrentPlayer(playingVC);
    id playerResponse = YTMUDownloadPlayerResponse(playerVC);

    if (!playerVC || !playerResponse) {
        YTMUDownloadShowAlert(@"DONT_RUSH", @"DONT_RUSH_DESC");
        return YES;
    }

    YTMActionSheetController *sheetController = [%c(YTMActionSheetController) musicActionSheetController];
    sheetController.sourceView = tapRecognizer.view;
    [sheetController addHeaderWithTitle:LOC(@"SELECT_ACTION") subtitle:nil];

    [sheetController addAction:[%c(YTActionSheetAction) actionWithTitle:LOC(@"DOWNLOAD_AUDIO") iconImage:[%c(YTUIResources) audioOutline] style:0 handler:^{
        [handler downloadAudio:playerVC];
    }]];

    [sheetController addAction:[%c(YTActionSheetAction) actionWithTitle:LOC(@"DOWNLOAD_COVER") iconImage:[%c(YTUIResources) outlineImageWithColor:[UIColor whiteColor]] style:0 handler:^{
        [handler downloadCoverImage:playerVC];
    }]];

    [sheetController addAction:[%c(YTActionSheetAction) actionWithTitle:LOC(@"DOWNLOAD_PREMIUM") iconImage:[%c(YTUIResources) downloadOutline] secondaryIconImage:[%c(YTUIResources) youtubePremiumBadgeLight] accessibilityIdentifier:nil handler:^{
        if (callOriginal) callOriginal();
    }]];

    if (YTMU(@"downloadAudio") && YTMU(@"downloadCoverImage")) {
        [sheetController presentFromViewController:playingVC animated:YES completion:nil];
    } else if (YTMU(@"downloadAudio")) {
        [handler downloadAudio:playerVC];
    } else if (YTMU(@"downloadCoverImage")) {
        [handler downloadCoverImage:playerVC];
    }
    return YES;
}

%hook ELMTouchCommandPropertiesHandler

%new
- (void)downloadAudio:(YTPlayerViewController *)playerVC {
    id playerResponse = YTMUDownloadPlayerResponse(playerVC);
    id playerData = YTMUSafeValueForKey(playerResponse, @"playerData");
    id videoDetails = YTMUSafeValueForKey(playerData, @"videoDetails");
    NSString *manifestURLString = YTMUDownloadString(YTMUSafeValueForKey(playerData, @"streamingData"), @"hlsManifestURL");
    NSURL *manifestURL = manifestURLString.length ? [NSURL URLWithString:manifestURLString] : nil;
    if (!playerResponse || !manifestURL) {
        YTMUDownloadShowAlert(@"OOPS", @"LINK_NOT_FOUND");
        return;
    }

    NSString *title = YTMUDownloadSanitizeFileComponent(YTMUDownloadString(videoDetails, @"title"));
    NSString *author = YTMUDownloadSanitizeFileComponent(YTMUDownloadString(videoDetails, @"author"));
    NSString *tempName = YTMUDownloadString(playerVC, @"contentVideoID");
    id durationValue = YTMUSafeValueForKey(playerVC, @"currentVideoTotalMediaTime");
    NSInteger duration = [durationValue respondsToSelector:@selector(doubleValue)] ? (NSInteger)round([durationValue doubleValue]) : 0;
    NSMutableArray *thumbnails = YTMUSafeValueForKey(YTMUSafeValueForKey(videoDetails, @"thumbnail"), @"thumbnailsArray");
    YTIThumbnailDetails_Thumbnail *thumbnail = [thumbnails isKindOfClass:[NSArray class]] ? thumbnails.lastObject : nil;
    NSURL *coverSourceURL = thumbnail.URL.length ? [NSURL URLWithString:thumbnail.URL] : nil;

    // The master playlist and the cover are fetched off the main thread —
    // upstream did both synchronously inside the tap handler and froze the UI
    // for the round trips. A spinner covers the wait; FFMpegDownloader then
    // shows its own progress HUD.
    MBProgressHUD *hud = [MBProgressHUD showHUDAddedTo:[UIApplication sharedApplication].keyWindow animated:YES];
    hud.mode = MBProgressHUDModeIndeterminate;

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSData *manifestData = [NSData dataWithContentsOfURL:manifestURL];
        NSString *manifest = manifestData ? [[NSString alloc] initWithData:manifestData encoding:NSUTF8StringEncoding] : nil;
        NSString *audioURL = YTMUHLSAudioStreamURLFromManifest(manifest);
        NSData *coverData = (audioURL.length && coverSourceURL) ? [NSData dataWithContentsOfURL:coverSourceURL] : nil;

        dispatch_async(dispatch_get_main_queue(), ^{
            [hud hideAnimated:YES];
            if (!audioURL.length) {
                YTMUDownloadShowAlert(@"OOPS", @"LINK_NOT_FOUND");
                return;
            }
            FFMpegDownloader *ffmpeg = [[FFMpegDownloader alloc] init];
            ffmpeg.tempName = tempName;
            ffmpeg.mediaName = [NSString stringWithFormat:@"%@ - %@", author, title];
            ffmpeg.duration = duration;
            [ffmpeg downloadAudio:audioURL];

            if (coverData) {
                NSURL *documentsURL = [[[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask] lastObject];
                NSURL *folderURL = [documentsURL URLByAppendingPathComponent:@"YTMusicUltimate"];
                [[NSFileManager defaultManager] createDirectoryAtURL:folderURL withIntermediateDirectories:YES attributes:nil error:nil];
                NSURL *coverURL = [folderURL URLByAppendingPathComponent:[NSString stringWithFormat:@"%@ - %@.png", author, title]];
                [coverData writeToURL:coverURL atomically:YES];
            }
        });
    });
}

%new
- (void)downloadCoverImage:(YTPlayerViewController *)playerVC {
    id playerResponse = YTMUDownloadPlayerResponse(playerVC);
    id videoDetails = YTMUSafeValueForKey(YTMUSafeValueForKey(playerResponse, @"playerData"), @"videoDetails");
    NSMutableArray *thumbnails = YTMUSafeValueForKey(YTMUSafeValueForKey(videoDetails, @"thumbnail"), @"thumbnailsArray");
    YTIThumbnailDetails_Thumbnail *thumbnail = [thumbnails isKindOfClass:[NSArray class]] ? thumbnails.lastObject : nil;
    if (!thumbnail.URL.length) {
        YTMUDownloadShowAlert(@"OOPS", @"LINK_NOT_FOUND");
        return;
    }
    // Ask for the 2048-square variant by rewriting the size segment of the
    // largest thumbnail's URL (upstream substituted the width for both
    // dimensions, which only matched square art). `height` is read by key:
    // the private header we compile against only declares `width`.
    id heightValue = YTMUSafeValueForKey(thumbnail, @"height");
    unsigned int height = [heightValue respondsToSelector:@selector(unsignedIntValue)] ? [heightValue unsignedIntValue] : thumbnail.width;
    NSString *sizeSegment = [NSString stringWithFormat:@"w%u-h%u-", thumbnail.width, height];
    NSString *thumbnailURL = [thumbnail.URL stringByReplacingOccurrencesOfString:sizeSegment withString:@"w2048-h2048-"];

    FFMpegDownloader *ffmpeg = [[FFMpegDownloader alloc] init];
    [ffmpeg downloadImage:[NSURL URLWithString:thumbnailURL]];
}
%end
