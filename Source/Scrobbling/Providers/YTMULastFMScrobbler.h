#import <Foundation/Foundation.h>
#import "../YTMUScrobbleTypes.h"

NS_ASSUME_NONNULL_BEGIN

@interface YTMULastFMScrobbler : NSObject <YTMUScrobbler>

#pragma mark - Auth flow used by ScrobblingSettingsController.

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

@end

NS_ASSUME_NONNULL_END
