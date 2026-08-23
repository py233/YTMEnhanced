#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// -valueForKey: that returns nil instead of throwing for an unknown key.
// The hooks read private YouTube Music objects by key name; when the app
// renames one we want a graceful miss, not NSUnknownKeyException.
id _Nullable YTMUSafeValueForKey(id _Nullable object, NSString *key);

NS_ASSUME_NONNULL_END
