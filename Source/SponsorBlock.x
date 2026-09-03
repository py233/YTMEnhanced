#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import "Headers/Localization.h"
#import "Headers/YTMToastController.h"
#import "Headers/YTPlayerViewController.h"
#import "Utils/YTMUKVC.h"
#import "Utils/YTMUSettings.h"

// One video's SponsorBlock state: the segments the API returned for it
// and which of them have already been skipped (or offered) this play.
// Replaced wholesale on every video change and only ever touched on the
// main thread, so the time-tick hook never races the network reply.
@interface YTMUSponsorBlockState : NSObject
@property (nonatomic, copy) NSString *videoID;
@property (nonatomic, copy) NSArray<NSDictionary *> *segments;     // {UUID, category, segment: [start, end]}
@property (nonatomic, strong) NSMutableSet<NSString *> *handledUUIDs;
@end

@implementation YTMUSponsorBlockState
@end

static NSString *YTMUSponsorBlockCurrentVideoID(YTPlayerViewController *player) {
    NSString *videoID = nil;
    @try {
        // Direct calls into the private header; a renamed selector in a
        // newer app build lands here instead of aborting.
        videoID = player.currentVideoID ?: player.contentVideoID;
    } @catch (__unused NSException *exception) {
        videoID = nil;
    }
    if (![videoID isKindOfClass:[NSString class]] || !videoID.length) {
        id value = YTMUSafeValueForKey(player, @"currentVideoID") ?: YTMUSafeValueForKey(player, @"contentVideoID");
        if ([value isKindOfClass:[NSString class]]) videoID = value;
        else if ([value respondsToSelector:@selector(stringValue)]) videoID = [value stringValue];
    }
    return [videoID isKindOfClass:[NSString class]] ? videoID : @"";
}

static CGFloat YTMUSponsorBlockCurrentVideoTime(YTPlayerViewController *player) {
    @try {
        return player.currentVideoMediaTime;
    } @catch (__unused NSException *exception) {
        id value = YTMUSafeValueForKey(player, @"currentVideoMediaTime");
        return [value respondsToSelector:@selector(floatValue)] ? [value floatValue] : 0;
    }
}

// Validated copy of the API's array: every entry has a UUID, a category
// and a numeric [start, end] pair, so the per-tick check can trust it.
static NSArray<NSDictionary *> *YTMUSponsorBlockSegmentsFromResponse(id json) {
    if (![json isKindOfClass:[NSArray class]]) return @[];
    NSMutableArray<NSDictionary *> *segments = [NSMutableArray array];
    for (NSDictionary *entry in (NSArray *)json) {
        if (![entry isKindOfClass:[NSDictionary class]]) continue;
        NSString *uuid = entry[@"UUID"];
        NSArray *range = entry[@"segment"];
        if (![uuid isKindOfClass:[NSString class]] || !uuid.length) continue;
        if (![entry[@"category"] isKindOfClass:[NSString class]]) continue;
        if (![range isKindOfClass:[NSArray class]] || range.count < 2) continue;
        if (![range[0] respondsToSelector:@selector(floatValue)] || ![range[1] respondsToSelector:@selector(floatValue)]) continue;
        [segments addObject:entry];
    }
    return segments;
}

// Called from the single didActivateVideo hook in Source/SyncedLyrics.x
// (the method used to be hooked here as well; two hooks of one method in
// two files chained in link order).
void YTMUSponsorBlockVideoDidActivate(YTPlayerViewController *self) {
    self.ytmu_sponsorBlockState = nil;
    if (!YTMU(@"sponsorBlock")) return;

    NSString *videoID = YTMUSponsorBlockCurrentVideoID(self);
    if (!videoID.length) return;

    NSString *encodedVideoID = [videoID stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]] ?: videoID;
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"https://sponsor.ajay.app/api/skipSegments?videoID=%@&categories=%%5B%%22music_offtopic%%22%%5D", encodedVideoID]];
    if (!url) return;
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.timeoutInterval = 15.0;

    __weak typeof(self) weakSelf = self;
    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        // 404 = no segments for this video; anything unparseable is ignored.
        if (error || !data.length) return;
        NSArray<NSDictionary *> *segments = YTMUSponsorBlockSegmentsFromResponse([NSJSONSerialization JSONObjectWithData:data options:0 error:nil]);
        if (!segments.count) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            // The answer belongs to the video that was playing when the
            // request went out; a skip in the meantime makes it stale.
            if (![YTMUSponsorBlockCurrentVideoID(strongSelf) isEqualToString:videoID]) return;
            YTMUSponsorBlockState *state = [[YTMUSponsorBlockState alloc] init];
            state.videoID = videoID;
            state.segments = segments;
            state.handledUUIDs = [NSMutableSet set];
            strongSelf.ytmu_sponsorBlockState = state;
        });
    }] resume];
}

%hook YTPlayerViewController
%property (nonatomic, strong) YTMUSponsorBlockState *ytmu_sponsorBlockState;

- (void)singleVideo:(id)video currentVideoTimeDidChange:(id)time {
    %orig;

    [self ytmu_skipSponsorSegmentIfNeeded];
}

- (void)potentiallyMutatedSingleVideo:(id)video currentVideoTimeDidChange:(id)time {
    %orig;

    [self ytmu_skipSponsorSegmentIfNeeded];
}

%new
- (void)ytmu_skipSponsorSegmentIfNeeded {
    YTMUSponsorBlockState *state = self.ytmu_sponsorBlockState;
    if (!state.segments.count || !YTMU(@"sponsorBlock")) return;
    if (![YTMUSponsorBlockCurrentVideoID(self) isEqualToString:state.videoID]) return;

    CGFloat currentTime = YTMUSponsorBlockCurrentVideoTime(self);
    for (NSDictionary *segment in state.segments) {
        NSString *uuid = segment[@"UUID"];
        if ([state.handledUUIDs containsObject:uuid]) continue;
        if (![segment[@"category"] isEqual:@"music_offtopic"]) continue;
        NSArray *range = segment[@"segment"];
        CGFloat start = [range[0] floatValue];
        CGFloat end = [range[1] floatValue];
        if (currentTime < start || currentTime > end - 1) continue;

        [state.handledUUIDs addObject:uuid];
        NSInteger toastDuration = YTMUSettingsInteger(@"sbDuration", 10);
        __weak typeof(self) weakSelf = self;

        GOOHUDMessageAction *unskipAction = [[%c(GOOHUDMessageAction) alloc] init];
        unskipAction.title = LOC(@"UNSKIP");
        [unskipAction setHandler:^{
            [weakSelf seekToTime:start];
        }];

        GOOHUDMessageAction *skipAction = [[%c(GOOHUDMessageAction) alloc] init];
        skipAction.title = LOC(@"SKIP");
        [skipAction setHandler:^{
            [weakSelf seekToTime:end];
            [[%c(YTMToastController) alloc] showMessage:LOC(@"SEGMENT_SKIPPED") HUDMessageAction:unskipAction infoType:0 duration:toastDuration];
        }];

        if (YTMUSettingsInteger(@"sbSkipMode", 0) == 0) {
            [self seekToTime:end];
            [[%c(YTMToastController) alloc] showMessage:LOC(@"SEGMENT_SKIPPED") HUDMessageAction:unskipAction infoType:0 duration:toastDuration];
        } else {
            [[%c(YTMToastController) alloc] showMessage:LOC(@"FOUND_SEGMENT") HUDMessageAction:skipAction infoType:0 duration:toastDuration];
        }
        // The seek moved the playhead; any further segment is judged
        // against the new position on the next tick.
        break;
    }
}
%end
