// The settings facade: atomic read-modify-write across threads, snapshot
// coherence with raw NSUserDefaults writes, typed readers, seeding.
#import "YTMUTestKit.h"
#import "YTMUTestSettings.h"
#import "Utils/YTMUSettings.h"
#import <QuartzCore/QuartzCore.h>

YTMU_TEST(Settings_snapshotFollowsRawDefaultsWrites_andTypedReaders) {
    YTMUTestSetSettings(@{@"YTMUltimateIsEnabled": @YES, @"noAds": @NO, @"seekTime": @3,
                          @"lyricsFontPointSize": @21.5, @"translationProvider": @"gemini", @"emptyString": @""});
    YTMU_ASSERT(YTMU(@"YTMUltimateIsEnabled"), "YTMU() must see a raw write immediately");
    YTMU_ASSERT(!YTMU(@"noAds") && !YTMU(@"missing"), "NO and absent both read as NO");
    YTMU_ASSERT(!YTMUEnabled(@"noAds") && YTMUEnabled(@"YTMUltimateIsEnabled"), "YTMUEnabled ANDs the master switch");
    YTMU_ASSERT_EQ_INT(YTMUSettingsInteger(@"seekTime", 9), 3);
    YTMU_ASSERT_EQ_INT(YTMUSettingsInteger(@"absent", 9), 9);
    YTMU_ASSERT(fabs(YTMUSettingsDouble(@"lyricsFontPointSize", 0) - 21.5) < 1e-9, "double reader");
    YTMU_ASSERT_EQ_STR(YTMUSettingsString(@"translationProvider", @"x"), @"gemini");
    YTMU_ASSERT_EQ_STR(YTMUSettingsString(@"emptyString", @"fallback"), @"fallback");
    YTMU_ASSERT_EQ_STR(YTMUSettingsString(@"seekTime", @"fallback"), @"fallback");   // wrong type → fallback
    YTMU_ASSERT(YTMUSettingsBool(@"absent", YES), "bool fallback");

    // A second raw replacement of the whole dictionary is seen too.
    YTMUTestSetSettings(@{@"YTMUltimateIsEnabled": @NO});
    YTMU_ASSERT(!YTMU(@"YTMUltimateIsEnabled"), "snapshot must refresh after the dictionary is replaced");
    YTMU_ASSERT(YTMUSettingsObject(@"seekTime") == nil, "old keys are gone after replacement");
}

YTMU_TEST(Settings_setObject_writesThrough_andNotifies) {
    YTMUTestSetSettings(@{@"a": @1});
    __block NSArray *notifiedKeys = nil;
    id observer = [[NSNotificationCenter defaultCenter] addObserverForName:YTMUSettingsDidChangeNotification object:nil queue:nil
                                                                usingBlock:^(NSNotification *note) { notifiedKeys = note.userInfo[YTMUSettingsChangedKeysUserInfoKey]; }];
    YTMUSettingsSetObject(@"b", @"two");
    YTMU_ASSERT_EQ_STR(YTMUTestSettings()[@"b"], @"two");           // persisted
    YTMU_ASSERT_EQ_INT([YTMUTestSettings()[@"a"] integerValue], 1);  // untouched
    YTMU_ASSERT([notifiedKeys isEqualToArray:@[@"b"]], "notification carries the key, got %@", notifiedKeys);

    notifiedKeys = nil;
    YTMUSettingsSetObject(@"b", @"two");                              // same value → no write, no notification
    YTMU_ASSERT(notifiedKeys == nil, "unchanged write must not notify");

    YTMUSettingsSetObject(@"b", nil);
    YTMU_ASSERT(YTMUTestSettings()[@"b"] == nil && YTMUSettingsObject(@"b") == nil, "nil removes the key");
    [[NSNotificationCenter defaultCenter] removeObserver:observer];
}

YTMU_TEST(Settings_registerDefaults_onlyFillsAbsentKeys) {
    YTMUTestSetSettings(@{@"noAds": @NO});
    YTMUSettingsRegisterDefaults(@{@"noAds": @YES, @"fresh": @"seeded"});
    YTMU_ASSERT(!YTMU(@"noAds"), "present key must not be overwritten by a default");
    YTMU_ASSERT_EQ_STR(YTMUSettingsString(@"fresh", @""), @"seeded");
    // The built-in table is applied the same way and is idempotent.
    YTMUSettingsRegisterDefaults(YTMUSettingsBuiltInDefaults());
    NSDictionary *after = YTMUTestSettings();
    YTMUSettingsRegisterDefaults(YTMUSettingsBuiltInDefaults());
    YTMU_ASSERT([YTMUTestSettings() isEqualToDictionary:after], "second seeding must be a no-op");
    YTMU_ASSERT(!YTMU(@"noAds"), "user value survives seeding");
    YTMU_ASSERT_EQ_STR(YTMUSettingsString(@"lyricsPreferredSource", @""), @"auto");
}

// The bug this facade replaces: two threads each doing read → modify → write
// of the whole dictionary lost one of the two writes. Every write below must
// survive.
YTMU_TEST(Settings_concurrentWritesFromManyThreads_loseNothing) {
    YTMUTestSetSettings(@{});
    const int threads = 6, perThread = 40;
    dispatch_group_t group = dispatch_group_create();
    for (int t = 0; t < threads; t++) {
        dispatch_group_async(group, dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
            for (int i = 0; i < perThread; i++) {
                NSString *key = [NSString stringWithFormat:@"t%d_%d", t, i];
                YTMUSettingsSetObject(key, @(i));
                // and a shared counter that every thread bumps
                YTMUSettingsUpdate(^(NSMutableDictionary *s) { s[@"counter"] = @([s[@"counter"] integerValue] + 1); }, @[@"counter"]);
            }
        });
    }
    YTMU_ASSERT(dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20 * NSEC_PER_SEC))) == 0, "writers did not finish");
    NSDictionary *final = YTMUTestSettings();
    NSUInteger present = 0;
    for (int t = 0; t < threads; t++) for (int i = 0; i < perThread; i++) {
        if ([final[[NSString stringWithFormat:@"t%d_%d", t, i]] integerValue] == i) present++;
    }
    YTMU_ASSERT_EQ_INT(present, threads * perThread);
    YTMU_ASSERT_EQ_INT([final[@"counter"] integerValue], threads * perThread);
    YTMU_ASSERT([YTMUSettingsSnapshot() isEqualToDictionary:final], "snapshot must equal what is on disk");
}

YTMU_TEST(Settings_snapshotReadIsCheapEnoughForHotPaths) {
    YTMUTestSetSettings(@{@"YTMUltimateIsEnabled": @YES, @"lowContrast": @NO});
    (void)YTMU(@"lowContrast");
    CFTimeInterval t0 = CACurrentMediaTime();
    for (int i = 0; i < 50000; i++) (void)YTMUEnabled(@"lowContrast");
    double perCall = (CACurrentMediaTime() - t0) / 50000.0 * 1e6;
    printf("        YTMUEnabled: %.2f µs/call\n", perCall);
    YTMU_ASSERT(perCall < 3.0, "settings read too slow for +[UIColor whiteColor]-class hooks: %.2f µs", perCall);
}
