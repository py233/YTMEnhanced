#import "YTMUSettings.h"

NSString *const YTMUSettingsDefaultsKey = @"YTMUltimate";
NSNotificationName const YTMUSettingsDidChangeNotification = @"YTMUSettingsDidChangeNotification";
NSString *const YTMUSettingsChangedKeysUserInfoKey = @"keys";

// The store is a tiny object rather than bare statics so the snapshot can
// be an `atomic` property (a lock-free-for-callers retain/autorelease read)
// and so it can observe NSUserDefaultsDidChangeNotification.
@interface YTMUSettingsStore : NSObject
@property (atomic, copy) NSDictionary<NSString *, id> *snapshot;
@end

@implementation YTMUSettingsStore

+ (instancetype)shared {
    static YTMUSettingsStore *store;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ store = [[self alloc] init]; });
    return store;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _snapshot = [self readFromDefaults];
        // Any in-process change to the defaults (a raw setObject: from the
        // host tests, or a writer that has not been migrated to the facade
        // yet) lands here and refreshes the snapshot. Foundation posts this
        // synchronously on the writing thread.
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(defaultsDidChange:)
                                                     name:NSUserDefaultsDidChangeNotification
                                                   object:nil];
    }
    return self;
}

- (NSDictionary *)readFromDefaults {
    NSDictionary *dict = [[NSUserDefaults standardUserDefaults] dictionaryForKey:YTMUSettingsDefaultsKey];
    return [dict isKindOfClass:[NSDictionary class]] ? dict : @{};
}

- (void)defaultsDidChange:(NSNotification *)note {
    // @synchronized is re-entrant, so this is safe when the notification is
    // delivered on the thread that is inside -update: (its own setObject:).
    @synchronized (self) {
        self.snapshot = [self readFromDefaults];
    }
}

// Returns YES when something was written.
- (BOOL)update:(void (^)(NSMutableDictionary<NSString *, id> *))mutate {
    BOOL changed = NO;
    @synchronized (self) {
        NSDictionary *before = [self readFromDefaults];
        NSMutableDictionary *working = [before mutableCopy];
        mutate(working);
        if (![working isEqualToDictionary:before]) {
            NSDictionary *frozen = [working copy];
            [[NSUserDefaults standardUserDefaults] setObject:frozen forKey:YTMUSettingsDefaultsKey];
            self.snapshot = frozen;
            changed = YES;
        }
    }
    return changed;
}

@end

NSDictionary<NSString *, id> *YTMUSettingsSnapshot(void) {
    return [YTMUSettingsStore shared].snapshot ?: @{};
}

void YTMUSettingsReload(void) {
    YTMUSettingsStore *store = [YTMUSettingsStore shared];
    @synchronized (store) {
        store.snapshot = [store readFromDefaults];
    }
}

id YTMUSettingsObject(NSString *key) {
    return key.length ? YTMUSettingsSnapshot()[key] : nil;
}

BOOL YTMUSettingsBool(NSString *key, BOOL fallback) {
    id value = YTMUSettingsObject(key);
    return [value respondsToSelector:@selector(boolValue)] ? [value boolValue] : fallback;
}

NSInteger YTMUSettingsInteger(NSString *key, NSInteger fallback) {
    id value = YTMUSettingsObject(key);
    return [value respondsToSelector:@selector(integerValue)] ? [value integerValue] : fallback;
}

double YTMUSettingsDouble(NSString *key, double fallback) {
    id value = YTMUSettingsObject(key);
    return [value respondsToSelector:@selector(doubleValue)] ? [value doubleValue] : fallback;
}

NSString *YTMUSettingsString(NSString *key, NSString *fallback) {
    id value = YTMUSettingsObject(key);
    if ([value isKindOfClass:[NSString class]] && [(NSString *)value length]) return value;
    return fallback ?: @"";
}

BOOL YTMU(NSString *key) {
    return YTMUSettingsBool(key, NO);
}

BOOL YTMUEnabled(NSString *key) {
    return YTMU(@"YTMUltimateIsEnabled") && YTMU(key);
}

void YTMUSettingsUpdate(void (^mutate)(NSMutableDictionary<NSString *, id> *), NSArray<NSString *> *changedKeys) {
    if (!mutate) return;
    BOOL changed = [[YTMUSettingsStore shared] update:mutate];
    if (changed) {
        [[NSNotificationCenter defaultCenter] postNotificationName:YTMUSettingsDidChangeNotification
                                                            object:nil
                                                          userInfo:@{YTMUSettingsChangedKeysUserInfoKey: changedKeys ?: @[]}];
    }
}

void YTMUSettingsSetObject(NSString *key, id value) {
    if (!key.length) return;
    YTMUSettingsUpdate(^(NSMutableDictionary<NSString *, id> *settings) {
        if (value) settings[key] = value;
        else [settings removeObjectForKey:key];
    }, @[key]);
}

void YTMUSettingsRegisterDefaults(NSDictionary<NSString *, id> *defaults) {
    if (!defaults.count) return;
    YTMUSettingsUpdate(^(NSMutableDictionary<NSString *, id> *settings) {
        [defaults enumerateKeysAndObjectsUsingBlock:^(NSString *key, id value, BOOL *stop) {
            if (settings[key] == nil) settings[key] = value;
        }];
    }, defaults.allKeys);
}

NSDictionary<NSString *, id> *YTMUSettingsBuiltInDefaults(void) {
    static NSDictionary *defaults;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        defaults = @{
            // Master switch and the upstream feature toggles that default on.
            @"YTMUltimateIsEnabled": @YES,
            @"backgroundPlayback": @YES,
            @"noAds": @YES,
            @"downloadAudio": @YES,
            @"downloadCoverImage": @YES,
            // SponsorBlock
            @"sbSkipMode": @0,
            @"sbDuration": @10,
            // Audio / video mode
            @"audioVideoMode": @0,
            // Lyrics
            @"syncedLyricsEnabled": @NO,
            @"bilingualLyrics": @NO,
            @"lyricsTranslationEnabled": @NO,
            @"lyricsPreferredSource": @"auto",
            @"lyricsShowInexact": @YES,
            @"lyricsRomanization": @YES,
            @"lyricsConvertChinese": @"disabled",
            @"lyricsShowTimeCodes": @NO,
            @"lyricsLineEffect": @"fancy",
            @"lyricsFontSize": @"small",
            @"lyricsTimingOffsetMs": @0,
            @"lyricsTimingOffsetActiveKey": @"",
            @"lyricsTimingOffsets": @{},
            @"lyricsDefaultText": @"♪",
            @"lyricsFocusBlur": @YES,
            // Translation
            @"translationProvider": @"google-translate",
            @"translationTargetLang": @"auto",
            @"translationBaseUrl": @"https://api.openai.com/v1",
            @"translationDebugLogs": @NO,
        };
    });
    return defaults;
}
