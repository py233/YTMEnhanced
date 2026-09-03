#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

// KVC against private YouTube Music objects, without exceptions.
//
// The hooks read the app's objects by key name (`_controller`, `_node`,
// `playerResponse`, …). When a newer build renames one, -valueForKey:
// raises NSUnknownKeyException. Catching that is correct but expensive —
// an Objective-C throw captures a backtrace and unwinds through C++ frames,
// tens to hundreds of microseconds each — and some call sites probe dozens
// of keys per view on every layout pass. So these helpers first check, via
// the runtime, whether KVC could resolve the key at all (accessor methods,
// then ivars when the class allows direct ivar access, in KVC's own search
// order) and only then call into KVC. Unknown keys cost a few hash lookups
// and return nil. The verdict is cached per (class, key).
//
// A @try stays around the actual KVC call as a last line of defence against
// classes with custom -valueForUndefinedKey: behaviour.

// -valueForKey: that returns nil instead of throwing. NSDictionary objects
// are read with -objectForKey:.
id _Nullable YTMUSafeValueForKey(id _Nullable object, NSString *key);

// Dot-separated key path walked with YTMUSafeValueForKey at every step.
id _Nullable YTMUSafeValueForKeyPath(id _Nullable object, NSString *keyPath);

// -setValue:forKey: that returns NO instead of throwing when the key cannot
// be resolved (no setter, no ivar).
BOOL YTMUSafeSetValueForKey(id _Nullable object, NSString *key, id _Nullable value);

// YES when KVC could resolve `key` on `object` for reading (cached).
BOOL YTMUKVCCanReadKey(id _Nullable object, NSString *key);

// Same verdict for a class without an instance — used by the startup
// diagnostics to report which private keys a new app build renamed.
BOOL YTMUKVCClassCanReadKey(Class _Nullable cls, NSString *key);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
