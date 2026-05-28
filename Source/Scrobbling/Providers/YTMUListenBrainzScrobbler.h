#import <Foundation/Foundation.h>
#import "../YTMUScrobbleTypes.h"

NS_ASSUME_NONNULL_BEGIN

// Result of a /1/metadata/lookup call. Track/artist/release names are
// the values ListenBrainz believes are canonical for the recording.
// MBIDs are the MusicBrainz identifiers — recording_mbid is the
// useful one to attach to scrobble submissions.
@interface YTMUListenBrainzMatch : NSObject
@property (nonatomic, copy, nullable) NSString *track;
@property (nonatomic, copy, nullable) NSString *artist;
// `releaseName` not `release` — `release` collides with NSObject's
// runtime selector and would generate a synthesized getter that
// shadows it.
@property (nonatomic, copy, nullable) NSString *releaseName;
@property (nonatomic, copy, nullable) NSString *recordingMBID;
@property (nonatomic, copy, nullable) NSArray<NSString *> *artistMBIDs;
@property (nonatomic, copy, nullable) NSString *releaseMBID;
@end

@interface YTMUListenBrainzScrobbler : NSObject <YTMUScrobbler>

// Validates the stored user token against /1/validate-token. Used by
// the settings UI status row to confirm a paste is correct without
// having to play a song first.
- (void)validateTokenWithCompletion:(void (^)(BOOL ok, NSString *_Nullable username, NSError *_Nullable error))completion;

// Calls /1/metadata/lookup to resolve a YT-Music-shaped (track,
// artist) pair against ListenBrainz's MusicBrainz-backed metadata
// index. No auth required, free. Completion is invoked on an
// arbitrary queue. Returns nil match if ListenBrainz has no entry.
- (void)fetchMetadataLookupForTrack:(NSString *)track
                             artist:(NSString *)artist
                              album:(nullable NSString *)album
                         completion:(void (^)(YTMUListenBrainzMatch *_Nullable match,
                                               NSError *_Nullable error))completion;

@end

NS_ASSUME_NONNULL_END
