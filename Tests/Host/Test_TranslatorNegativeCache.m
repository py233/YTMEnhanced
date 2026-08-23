// M6: a parse / line-count translation failure is remembered for a while
// (no repeat LLM spend on every play); network errors are not.
#import "YTMUTestKit.h"
#import "YTMUTestSettings.h"
#import "YTMUTestFakeLLM.h"
#import "Translation/YTMUTranslator.h"
#import "Translation/YTMUTranslationCache.h"
#import "Translation/YTMUTranslationTypes.h"

@interface YTMUTranslationCache (YTMUTesting)
- (NSString *)filePathForKey:(NSString *)key;
- (void)clearMemoryCache;
@end

static YTMUTestFakeLLM *InstallFake(void) {
    YTMUTestFakeLLM *fake = [[YTMUTestFakeLLM alloc] init];
    [[YTMUTranslator sharedTranslator] setValue:@{@"fake": fake} forKey:@"providers"];
    YTMUTestSetSettings(@{@"YTMUltimateIsEnabled": @YES, @"translationProvider": @"fake",
                          @"translationTargetLang": @"en", @"translationDebugLogs": @NO});
    [[YTMUTranslationCache sharedCache] clearAll];
    return fake;
}

static NSError *Translate(NSArray *lines, NSString *videoId, NSArray **out) {
    __block NSError *err = nil; __block NSArray *got = nil; __block BOOL done = NO;
    [[YTMUTranslator sharedTranslator] translateLines:lines videoId:videoId title:@"t" artist:@"a"
        completion:^(NSArray<NSString *> *translated, NSError *error) { got = translated; err = error; done = YES; }];
    YTMUTestWaitUntil(10, ^BOOL{ return done; });
    if (out) *out = got;
    return err;
}

static NSArray *TenLines(void) {
    NSMutableArray *a = [NSMutableArray array];
    for (int i = 1; i <= 10; i++) [a addObject:[NSString stringWithFormat:@"line %d", i]];
    return a;
}

YTMU_TEST(Translator_lineCountFailure_isRemembered_untilTTL) {
    YTMUTestFakeLLM *fake = InstallFake();
    fake.translatedLines = @[@"only", @"three", @"back"];       // 10 source lines → never aligns, > 8 so no per-line path
    NSArray *lines = TenLines();
    NSArray *got = nil;
    NSError *err = Translate(lines, @"neg-1", &got);
    YTMU_ASSERT(got == nil && err != nil, "expected failure");
    YTMU_ASSERT_EQ_INT(fake.translateCount, 2);                 // whole + one retry
    NSUInteger calls = fake.translateCount;

    err = Translate(lines, @"neg-1", &got);
    YTMU_ASSERT(err != nil, "second attempt must also fail (from the sentinel)");
    YTMU_ASSERT_EQ_INT(fake.translateCount, calls);           // provider not asked again

    // Age the sentinel past the TTL → provider is asked again.
    NSString *key = [YTMUTranslationCache keyForVideoId:@"neg-1" language:@"en" provider:@"fake" model:@"fake-model" lines:lines];
    NSString *path = [[YTMUTranslationCache sharedCache] filePathForKey:key];
    YTMU_ASSERT(YTMUTestWaitUntil(3, ^BOOL{ return [[NSFileManager defaultManager] fileExistsAtPath:path]; }), "sentinel not persisted at %@", path);
    NSMutableDictionary *dict = [[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:path] options:0 error:nil] mutableCopy];
    dict[@"failedAt"] = @([[NSDate date] timeIntervalSince1970] - YTMUTranslationFailureTTL - 60);
    [[NSJSONSerialization dataWithJSONObject:dict options:0 error:nil] writeToFile:path atomically:YES];
    [[YTMUTranslationCache sharedCache] clearMemoryCache];
    fake.translatedLines = TenLines();                            // now it works
    err = Translate(lines, @"neg-1", &got);
    YTMU_ASSERT(err == nil && got.count == 10, "after TTL the provider must be retried and succeed (err=%@)", err);
    YTMU_ASSERT(fake.translateCount > calls, "provider should have been called again");
}

YTMU_TEST(Translator_perLineFallbackAlsoFailing_isRemembered) {
    YTMUTestFakeLLM *fake = InstallFake();
    // Whole-song: misaligned. Per-line (1-line requests): parse error.
    fake.translationHandler = ^NSArray *(YTMUTranslationRequest *request, NSError **error) {
        if (request.lines.count == 1) {
            *error = [NSError errorWithDomain:YTMUTranslationErrorDomain code:YTMUTranslationErrorParse userInfo:@{NSLocalizedDescriptionKey: @"parse"}];
            return nil;
        }
        return @[@"x"];
    };
    NSArray *lines = @[@"l1", @"l2", @"l3", @"l4"];
    NSError *err = Translate(lines, @"neg-perline", NULL);
    YTMU_ASSERT(err != nil, "expected failure");
    NSUInteger calls = fake.translateCount;
    YTMU_ASSERT(calls == 2 + 4, "expected whole+retry+4 per-line, got %lu", (unsigned long)calls);
    err = Translate(lines, @"neg-perline", NULL);
    YTMU_ASSERT(err != nil, "sentinel should answer");
    YTMU_ASSERT_EQ_INT(fake.translateCount, calls);
}

YTMU_TEST(Translator_networkFailure_isNotRemembered) {
    YTMUTestFakeLLM *fake = InstallFake();
    fake.translationError = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorNotConnectedToInternet userInfo:nil];
    NSArray *lines = @[@"l1", @"l2", @"l3"];
    NSError *err = Translate(lines, @"neg-net", NULL);
    YTMU_ASSERT(err != nil, "expected network failure");
    NSUInteger calls = fake.translateCount;
    YTMU_ASSERT(calls >= 2, "expected at least whole+retry, got %lu", (unsigned long)calls);
    fake.translationError = nil; fake.translatedLines = @[@"x", @"y", @"z"];
    NSArray *got = nil;
    err = Translate(lines, @"neg-net", &got);
    YTMU_ASSERT(err == nil && got.count == 3, "network failure must not block the next attempt (err=%@)", err);
}

YTMU_TEST(Translator_successAfterFailure_replacesSentinel) {
    YTMUTestFakeLLM *fake = InstallFake();
    NSArray *lines = TenLines();
    fake.translatedLines = @[@"bad", @"worse", @"worst"];        // misaligned → failure remembered
    (void)Translate(lines, @"neg-replace", NULL);
    // A different model/provider key is not affected; same key is blocked —
    // but once the sentinel expires and a success lands it is replaced.
    NSString *key = [YTMUTranslationCache keyForVideoId:@"neg-replace" language:@"en" provider:@"fake" model:@"fake-model" lines:lines];
    YTMU_ASSERT(YTMUTestWaitUntil(3, ^BOOL{ return [[YTMUTranslationCache sharedCache] entryForKey:key].isRememberedFailure; }), "failure not remembered");
    NSString *path = [[YTMUTranslationCache sharedCache] filePathForKey:key];
    YTMU_ASSERT(YTMUTestWaitUntil(3, ^BOOL{ return [[NSFileManager defaultManager] fileExistsAtPath:path]; }), "sentinel not on disk yet");
    NSMutableDictionary *dict = [[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:path] options:0 error:nil] mutableCopy];
    dict[@"failedAt"] = @(1);
    [[NSJSONSerialization dataWithJSONObject:dict options:0 error:nil] writeToFile:path atomically:YES];
    [[YTMUTranslationCache sharedCache] clearMemoryCache];
    fake.translatedLines = TenLines();
    NSArray *got = nil;
    NSError *err = Translate(lines, @"neg-replace", &got);
    YTMU_ASSERT(err == nil && got.count == 10, "expected success, err=%@", err);
    YTMU_ASSERT(YTMUTestWaitUntil(3, ^BOOL{
        [[YTMUTranslationCache sharedCache] clearMemoryCache];
        YTMUTranslationCacheEntry *e = [[YTMUTranslationCache sharedCache] entryForKey:key];
        return e.translatedLines.count == 10 && e.failedAt == 0;
    }), "success must overwrite the sentinel on disk");
}
