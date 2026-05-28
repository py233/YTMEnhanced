#import <Foundation/Foundation.h>
#import "../YTMUScrobbleTypes.h"

NS_ASSUME_NONNULL_BEGIN

@interface YTMUListenBrainzScrobbler : NSObject <YTMUScrobbler>

// Validates the stored user token against /1/validate-token. Used by
// the settings UI status row to confirm a paste is correct without
// having to play a song first.
- (void)validateTokenWithCompletion:(void (^)(BOOL ok, NSString *_Nullable username, NSError *_Nullable error))completion;

@end

NS_ASSUME_NONNULL_END
