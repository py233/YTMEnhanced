#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

// The one door to the tweak's settings dictionary (NSUserDefaults key
// "YTMUltimate").
//
// Why it exists: every module used to read the dictionary, mutate its own
// copy and write the whole thing back — from the main thread (prefs UI,
// lyrics timing offsets on every song change) and from NSURLSession
// completion queues (scrobble caches / queue). Two overlapping
// read-modify-writes silently dropped one of the two writes. Here every
// write runs under one lock, and readers get an immutable snapshot that is
// refreshed after every in-process change, so hot paths (colour hooks,
// display links) pay for a pointer copy instead of a defaults lookup.
//
// All functions are safe to call from any thread.

// The NSUserDefaults key the dictionary lives under.
FOUNDATION_EXPORT NSString *const YTMUSettingsDefaultsKey;

// Posted (on the writing thread) after a write through this facade that
// actually changed something. userInfo[YTMUSettingsChangedKeysUserInfoKey]
// is an NSArray<NSString *> of the keys the caller declared as changed.
FOUNDATION_EXPORT NSNotificationName const YTMUSettingsDidChangeNotification;
FOUNDATION_EXPORT NSString *const YTMUSettingsChangedKeysUserInfoKey;

// Immutable snapshot of the whole dictionary (never nil).
NSDictionary<NSString *, id> *YTMUSettingsSnapshot(void);

// Re-read from NSUserDefaults. Only needed after a write that bypassed the
// facade from *outside* the process; in-process writes refresh the snapshot
// through NSUserDefaultsDidChangeNotification.
void YTMUSettingsReload(void);

// Typed readers. `fallback` is used when the key is absent or of the wrong
// type; the string reader also treats an empty string as absent.
id _Nullable YTMUSettingsObject(NSString *key);
BOOL YTMUSettingsBool(NSString *key, BOOL fallback);
NSInteger YTMUSettingsInteger(NSString *key, NSInteger fallback);
double YTMUSettingsDouble(NSString *key, double fallback);
NSString *YTMUSettingsString(NSString *key, NSString *_Nullable fallback);

// The hook files' historical shorthand: `[dict[key] boolValue]` — absent
// keys read as NO.
BOOL YTMU(NSString *key);
// Master switch AND `key`. Most feature hooks gate on exactly this.
BOOL YTMUEnabled(NSString *key);

// Atomic read-modify-write. `mutate` receives the authoritative dictionary
// under the facade lock; whatever it leaves behind is persisted. When the
// block changes nothing, nothing is written and no notification is posted.
// `changedKeys` is only carried into the notification.
void YTMUSettingsUpdate(void (^mutate)(NSMutableDictionary<NSString *, id> *settings),
                        NSArray<NSString *> *_Nullable changedKeys);

// Writes one key (nil removes it).
void YTMUSettingsSetObject(NSString *key, id _Nullable value);

// Writes every key of `defaults` that is currently absent. Present keys are
// left alone, so this is safe to run on every launch.
void YTMUSettingsRegisterDefaults(NSDictionary<NSString *, id> *defaults);

// Every default the tweak seeds at launch (one table instead of six %ctor
// copies). Applied by Source/Defaults.x; exposed so tests can inspect it.
NSDictionary<NSString *, id> *YTMUSettingsBuiltInDefaults(void);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
