#import <Foundation/Foundation.h>
#import "../YTMUScrobbleTypes.h"

NS_ASSUME_NONNULL_BEGIN

#pragma mark - Title correction result

// Lightweight summary of one last.fm correction lookup. Track and
// artist are non-nil when the call succeeds — they may equal the
// input verbatim (meaning "last.fm thinks the input is already
// canonical"). The MBIDs are nil when last.fm has no MusicBrainz
// link for the entry.
@interface YTMULastFMCorrection : NSObject
@property (nonatomic, copy) NSString *track;
@property (nonatomic, copy) NSString *artist;
@property (nonatomic, copy, nullable) NSString *trackMBID;
@property (nonatomic, copy, nullable) NSString *artistMBID;
- (instancetype)initWithTrack:(NSString *)track
                       artist:(NSString *)artist
                    trackMBID:(nullable NSString *)trackMBID
                   artistMBID:(nullable NSString *)artistMBID;
@end

#pragma mark - Track search result

// One row from last.fm's `track.search` response. Critically, this
// carries `listeners` — the count of unique users who've scrobbled
// the track. We use it to popularity-rank multiple candidate
// titles (CJK vs romaji) and pick whichever is canonical on last.fm.
@interface YTMULastFMSearchResult : NSObject
@property (nonatomic, copy) NSString *track;
@property (nonatomic, copy) NSString *artist;
@property (nonatomic, copy, nullable) NSString *mbid;
@property (nonatomic, assign) NSInteger listeners;
- (instancetype)initWithTrack:(NSString *)track
                       artist:(NSString *)artist
                         mbid:(nullable NSString *)mbid
                    listeners:(NSInteger)listeners;
@end

#pragma mark - Provider

@interface YTMULastFMScrobbler : NSObject <YTMUScrobbler>

#pragma mark Auth flow (used by ScrobblingSettingsController)

// Step 1: ask last.fm for a fresh auth token. Completion runs on an
// arbitrary queue. On success caller should open
//   https://www.last.fm/api/auth/?api_key=KEY&token=TOKEN
// in Safari for the user to approve.
- (void)fetchAuthTokenWithCompletion:(void (^)(NSString *_Nullable token, NSError *_Nullable error))completion;

// Step 2: after user approves in Safari, call this with the same
// token. On success the session key + username are persisted into
// NSUserDefaults and the provider becomes isConfigured == YES.
- (void)fetchSessionWithToken:(NSString *)token
                   completion:(void (^)(NSString *_Nullable username, NSError *_Nullable error))completion;

// Clears stored session key + username. Used by the "Sign out" row.
- (void)signOut;

// Convenience for status row.
- (nullable NSString *)authenticatedUsername;

#pragma mark Title corrections (used by YTMUScrobbleResolver)

// Calls last.fm `track.getCorrection`. No signing / no session
// required — uses the stored api_key only. Completion is invoked on
// an arbitrary queue. When the user hasn't configured an api_key
// the correction is nil and error describes the missing config;
// the resolver treats this as "skip Tier 2a".
- (void)fetchCorrectionForTrack:(NSString *)track
                         artist:(NSString *)artist
                     completion:(void (^)(YTMULastFMCorrection *_Nullable correction,
                                           NSError *_Nullable error))completion;

// Calls last.fm `track.search`. Returns top `limit` matches, each
// carrying a `listeners` count from last.fm's index. The resolver
// uses this to popularity-rank multiple candidate titles (e.g. CJK
// vs romaji form of the same Vocaloid track) and submit whichever
// is canonical on last.fm. No signing required.
//
// Completion is invoked on an arbitrary queue. Returns nil results
// + error when api_key missing or HTTP fails. Empty results array
// (non-nil, count 0) means search ran but no matches found —
// caller should not treat as error.
- (void)searchTrack:(NSString *)track
             artist:(NSString *)artist
              limit:(NSUInteger)limit
         completion:(void (^)(NSArray<YTMULastFMSearchResult *> *_Nullable results,
                              NSError *_Nullable error))completion;

// Calls last.fm `artist.getInfo`. Used as a fallback when track.search
// finds no canonical entries for any candidate — we still want to know
// which sub-artist alias is the popular canonical one (e.g.
// "Suzaku-朱雀-" → "Suzaku" with 3,313 listeners) so we can scrobble
// to that artist even when the specific track is orphaned. Returns
// listener count (0 if artist not found or HTTP fails).
- (void)fetchArtistListenerCountForArtist:(NSString *)artist
                               completion:(void (^)(NSInteger listeners,
                                                     NSError *_Nullable error))completion;

@end

NS_ASSUME_NONNULL_END
