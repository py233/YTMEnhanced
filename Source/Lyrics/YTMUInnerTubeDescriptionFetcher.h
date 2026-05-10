#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Fetches the long-form video description directly from YouTube's
// InnerTube `/youtubei/v1/player` endpoint, bypassing YT Music's
// stripped-down player response.
//
// Why this exists: YT Music's client receives a player-response payload
// from its server that does NOT carry the `microformat` block and
// leaves `videoDetails.shortDescription` empty (verified via reflection
// dump). The actual description still lives on YouTube's side; we just
// need to ask the right client. The `IOS` InnerTube client returns the
// full microformat + description for any public video without auth.
//
// All callbacks are dispatched on the main queue.
typedef void(^YTMUInnerTubeDescriptionCompletion)(NSString *_Nullable description, NSError *_Nullable error);

@interface YTMUInnerTubeDescriptionFetcher : NSObject

+ (instancetype)sharedFetcher;

// Fetch (or look up cached) the description for a given videoId.
// Returns the empty string + nil error when the description was
// successfully fetched but the video genuinely has no description —
// callers should treat that as a "no description available" signal,
// not as an error.
- (void)fetchDescriptionForVideoId:(NSString *)videoId
                        completion:(YTMUInnerTubeDescriptionCompletion)completion;

// Synchronous cache lookup — returns nil if we haven't fetched yet.
// The empty string means "we fetched and it was confirmed empty".
- (nullable NSString *)cachedDescriptionForVideoId:(NSString *)videoId;

- (void)clearCache;

@end

NS_ASSUME_NONNULL_END
