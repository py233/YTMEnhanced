#import "YTMUTestKit.h"
#import "Utils/YTMUDigest.h"
#import "Utils/YTMUPlistStore.h"
#import "Utils/YTMUInflightCoalescer.h"
#import "Utils/YTMUPaths.h"

YTMU_TEST(Digest_sha1_knownVectors) {
    YTMU_ASSERT_EQ_STR(YTMUSHA1Hex(@"abc"), @"a9993e364706816aba3e25717850c26c9cd0d89d");
    YTMU_ASSERT_EQ_STR(YTMUSHA1Hex(@""), @"da39a3ee5e6b4b0d3255bfef95601890afd80709");
    YTMU_ASSERT_EQ_STR(YTMUSHA1HexForData([@"abc" dataUsingEncoding:NSUTF8StringEncoding]), YTMUSHA1Hex(@"abc"));
}

YTMU_TEST(PlistStore_roundTrip_versionCheck_emptyKey_removeAll) {
    YTMUPlistStore *store = [[YTMUPlistStore alloc] initWithSubdirectory:@"StoreTest" schemaVersion:3];
    YTMU_ASSERT([store.directory hasPrefix:YTMUCachesDirectory()], "store must live under the caches root");
    [store writePlist:@{@"text": @"hello"} forKey:@"k1"];
    YTMU_ASSERT(YTMUTestWaitUntil(3, ^BOOL{ return [store plistForKey:@"k1"] != nil; }), "write never landed");
    NSDictionary *back = [store plistForKey:@"k1"];
    YTMU_ASSERT_EQ_STR(back[@"text"], @"hello");
    YTMU_ASSERT_EQ_INT([back[@"v"] integerValue], 3);          // stamped
    // a different schema version reads as missing
    YTMUPlistStore *newer = [[YTMUPlistStore alloc] initWithSubdirectory:@"StoreTest" schemaVersion:4];
    YTMU_ASSERT([newer plistForKey:@"k1"] == nil, "old schema must not be served");
    // empty key maps to a stable sentinel path rather than crashing, but reads nil
    YTMU_ASSERT([[store pathForKey:@""] hasSuffix:[YTMUSHA1Hex(@"<empty>") stringByAppendingString:@".plist"]], "empty key path");
    YTMU_ASSERT([store plistForKey:@""] == nil, "empty key reads nil");
    [store removeAll];
    YTMU_ASSERT(YTMUTestWaitUntil(3, ^BOOL{ return [store plistForKey:@"k1"] == nil; }), "removeAll never landed");
}

YTMU_TEST(InflightCoalescer_firstBegins_restJoin_takeDrains) {
    YTMUInflightCoalescer<dispatch_block_t> *c = [[YTMUInflightCoalescer alloc] init];
    __block int hits = 0;
    BOOL first = [c beginOrJoinKey:@"a" completion:^{ hits += 1; }];
    BOOL second = [c beginOrJoinKey:@"a" completion:^{ hits += 10; }];
    BOOL other = [c beginOrJoinKey:@"b" completion:^{ hits += 100; }];
    YTMU_ASSERT(first && !second && other, "first begins, same-key joins, other key begins");
    NSArray<dispatch_block_t> *a = [c takeCompletionsForKey:@"a"];
    YTMU_ASSERT_EQ_INT(a.count, 2);
    for (dispatch_block_t b in a) b();
    YTMU_ASSERT_EQ_INT(hits, 11);
    YTMU_ASSERT_EQ_INT([c takeCompletionsForKey:@"a"].count, 0);     // drained
    YTMU_ASSERT([c beginOrJoinKey:@"a" completion:^{}], "after take, the key is free again");
    YTMU_ASSERT_EQ_INT([c takeCompletionsForKey:@"b"].count, 1);
}
