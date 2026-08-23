#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Fetches video description AND canonical video title directly from
// YouTube's InnerTube `/youtubei/v1/player` endpoint.
//
// Why we need both:
//
// • Description: YT Music's local player response strips description
//   out, so for vocaloid/doujin uploads where uploaders paste lyrics
//   into the description, we have to re-fetch from the public endpoint.
//
// • Canonical title: YT Music distinguishes "song" entries (from album
//   metadata, often with a simplified title like just "Terminal") from
//   "video" entries (the actual upload title, often the full
//   "ハテ - Terminal (feat. IA)"). The KVC path we have on the player
//   gives us the song title; lyric DBs index by the video title. Using
//   the simplified song title to search NetEase routinely hits an
//   unrelated K-pop track that happens to be called "Terminal", whereas
//   searching by the full video title finds the right entry.
//
// All callbacks are dispatched on the main queue.

@interface YTMUInnerTubeMetadata : NSObject
// Empty string means "fetched and confirmed no description". nil
// means we haven't fetched yet. Note: NOT named `description` —
// that's NSObject's debugDescription getter and we can't override it.
@property (nonatomic, copy, nullable) NSString *videoDescription;
// Canonical video title from videoDetails.title (or microformat
// fallback). nil means we couldn't get one — caller should keep
// using whatever player.title gave them.
@property (nonatomic, copy, nullable) NSString *canonicalTitle;
@end

typedef void(^YTMUInnerTubeMetadataCompletion)(YTMUInnerTubeMetadata *_Nullable metadata, NSError *_Nullable error);

@interface YTMUInnerTubeDescriptionFetcher : NSObject

+ (instancetype)sharedFetcher;

- (void)fetchMetadataForVideoId:(NSString *)videoId
                      completion:(YTMUInnerTubeMetadataCompletion)completion;

// Synchronous cache lookup — returns nil if we haven't fetched yet.
- (nullable YTMUInnerTubeMetadata *)cachedMetadataForVideoId:(NSString *)videoId;


- (void)clearCache;

@end

NS_ASSUME_NONNULL_END
