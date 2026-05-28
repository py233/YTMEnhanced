#import <Foundation/Foundation.h>
#import "../YTMUScrobbleTypes.h"

NS_ASSUME_NONNULL_BEGIN

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

@end

NS_ASSUME_NONNULL_END
