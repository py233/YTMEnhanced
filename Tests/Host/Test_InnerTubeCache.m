// InnerTube metadata cache: round trip, TTL, and stale schema — no network.
#import "YTMUTestKit.h"
#import "Lyrics/YTMUInnerTubeDescriptionFetcher.h"
#import "Utils/YTMUPlistStore.h"

@interface YTMUInnerTubeDescriptionFetcher (YTMUTesting)
- (void)writeCacheMetadata:(YTMUInnerTubeMetadata *)meta forVideoId:(NSString *)videoId;
@property (nonatomic, strong, readonly) YTMUPlistStore *store;
@end

YTMU_TEST(InnerTubeCache_roundTrip_ttl_schema) {
    YTMUInnerTubeDescriptionFetcher *f = [YTMUInnerTubeDescriptionFetcher sharedFetcher];
    YTMUInnerTubeMetadata *meta = [[YTMUInnerTubeMetadata alloc] init];
    meta.videoDescription = @"desc text"; meta.canonicalTitle = @"Canonical Title";
    [f writeCacheMetadata:meta forVideoId:@"it-1"];
    YTMU_ASSERT(YTMUTestWaitUntil(3, ^BOOL{ return [f cachedMetadataForVideoId:@"it-1"] != nil; }), "write never landed");
    YTMUInnerTubeMetadata *back = [f cachedMetadataForVideoId:@"it-1"];
    YTMU_ASSERT_EQ_STR(back.videoDescription, @"desc text");
    YTMU_ASSERT_EQ_STR(back.canonicalTitle, @"Canonical Title");
    YTMU_ASSERT([f cachedMetadataForVideoId:@""] == nil, "empty id reads nil");

    // Expired entry (ts 31 days ago) reads as missing.
    NSString *path = [f.store pathForKey:@"it-1"];
    NSMutableDictionary *plist = [[NSDictionary dictionaryWithContentsOfFile:path] mutableCopy];
    plist[@"ts"] = @([[NSDate date] timeIntervalSince1970] - 31 * 24 * 3600);
    [plist writeToFile:path atomically:YES];
    YTMU_ASSERT([f cachedMetadataForVideoId:@"it-1"] == nil, "expired entry must not be served");

    // Wrong schema reads as missing.
    plist[@"ts"] = @([[NSDate date] timeIntervalSince1970]);
    plist[@"v"] = @2;
    [plist writeToFile:path atomically:YES];
    YTMU_ASSERT([f cachedMetadataForVideoId:@"it-1"] == nil, "old schema must not be served");
}
