// Exception-free KVC: the hooks probe private YouTube Music objects by key
// name on every layout pass; an unknown key must cost a few lookups, not a
// thrown-and-caught NSUnknownKeyException.
#import "YTMUTestKit.h"
#import "Utils/YTMUKVC.h"
#import <QuartzCore/QuartzCore.h>

@interface YTMUKVCFixture : NSObject {
    @public NSString *_ivarOnly;      // no accessor at all
    NSNumber *_isFlag;                // KVC "_isKey" form
    NSString *_underscorePropertyBacking;
}
@property (nonatomic, copy) NSString *plainProperty;
@property (nonatomic, readonly) NSString *readOnly;
@property (nonatomic) BOOL isSelected;
- (NSString *)_privateAccessor;
@end
@implementation YTMUKVCFixture
- (instancetype)init { self = [super init]; _ivarOnly = @"ivar"; _isFlag = @YES; _plainProperty = @"prop"; return self; }
- (NSString *)readOnly { return @"ro"; }
- (NSString *)_privateAccessor { return @"private"; }
@end

@interface YTMUKVCNoIvarAccess : NSObject { @public NSString *_hidden; }
@end
@implementation YTMUKVCNoIvarAccess
+ (BOOL)accessInstanceVariablesDirectly { return NO; }
@end

YTMU_TEST(SafeKVC_readsEverythingKVCWouldRead) {
    YTMUKVCFixture *f = [[YTMUKVCFixture alloc] init];
    YTMU_ASSERT_EQ_STR(YTMUSafeValueForKey(f, @"plainProperty"), @"prop");
    YTMU_ASSERT_EQ_STR(YTMUSafeValueForKey(f, @"readOnly"), @"ro");
    YTMU_ASSERT_EQ_STR(YTMUSafeValueForKey(f, @"_ivarOnly"), @"ivar");       // ivar by its own name
    YTMU_ASSERT_EQ_STR(YTMUSafeValueForKey(f, @"ivarOnly"), @"ivar");        // ivar via _key rule
    YTMU_ASSERT([YTMUSafeValueForKey(f, @"flag") boolValue], "_isKey ivar form");
    YTMU_ASSERT([YTMUSafeValueForKey(f, @"selected") boolValue] == NO && YTMUSafeValueForKey(f, @"selected") != nil, "isSelected accessor form");
    YTMU_ASSERT_EQ_STR(YTMUSafeValueForKey(f, @"_privateAccessor"), @"private");
    YTMU_ASSERT_EQ_STR(YTMUSafeValueForKey(@{@"k": @"v"}, @"k"), @"v");
    YTMU_ASSERT_EQ_STR(YTMUSafeValueForKeyPath(@{@"a": @{@"b": f}}, @"a.b.plainProperty"), @"prop");
    YTMU_ASSERT(YTMUSafeValueForKeyPath(f, @"plainProperty.nope.deeper") == nil, "broken path reads nil");
}

YTMU_TEST(SafeKVC_unknownKeys_readNil_andRespectAccessInstanceVariablesDirectly) {
    YTMUKVCFixture *f = [[YTMUKVCFixture alloc] init];
    YTMU_ASSERT(YTMUSafeValueForKey(f, @"definitelyNotAKey") == nil, "unknown key → nil");
    YTMU_ASSERT(YTMUSafeValueForKey(f, @"a.b") == nil && YTMUSafeValueForKey(f, @"@count") == nil, "paths/operators are refused");
    YTMU_ASSERT(!YTMUKVCCanReadKey(f, @"definitelyNotAKey") && YTMUKVCCanReadKey(f, @"plainProperty"), "can-read verdicts");
    YTMU_ASSERT(YTMUSafeValueForKey(nil, @"x") == nil && YTMUSafeValueForKey(f, @"") == nil, "nil / empty guards");
    YTMUKVCNoIvarAccess *n = [[YTMUKVCNoIvarAccess alloc] init];
    n->_hidden = @"h";
    YTMU_ASSERT(YTMUSafeValueForKey(n, @"hidden") == nil, "ivar-only key on a class that forbids direct ivar access must read nil (KVC would throw)");
}

YTMU_TEST(SafeKVC_set_writesResolvableKeys_andRefusesOthers) {
    YTMUKVCFixture *f = [[YTMUKVCFixture alloc] init];
    YTMU_ASSERT(YTMUSafeSetValueForKey(f, @"plainProperty", @"changed"), "setter must be accepted");
    YTMU_ASSERT_EQ_STR(f.plainProperty, @"changed");
    YTMU_ASSERT(YTMUSafeSetValueForKey(f, @"_ivarOnly", @"viaIvar"), "ivar write");
    YTMU_ASSERT_EQ_STR(f->_ivarOnly, @"viaIvar");
    YTMU_ASSERT(!YTMUSafeSetValueForKey(f, @"noSuchThing", @1), "unknown key must be refused, not thrown");
    YTMU_ASSERT(!YTMUSafeSetValueForKey(f, @"readOnly", @"x"), "read-only property without ivar is refused");
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    YTMU_ASSERT(YTMUSafeSetValueForKey(d, @"k", @"v") && [d[@"k"] isEqual:@"v"], "dictionaries are written directly");
}

YTMU_TEST(SafeKVC_unknownKeyProbeIsCheap) {
    YTMUKVCFixture *f = [[YTMUKVCFixture alloc] init];
    (void)YTMUSafeValueForKey(f, @"_asyncdisplaykit_node");   // warm the per-class cache
    CFTimeInterval t0 = CACurrentMediaTime();
    for (int i = 0; i < 20000; i++) (void)YTMUSafeValueForKey(f, @"_asyncdisplaykit_node");
    double perCall = (CACurrentMediaTime() - t0) / 20000.0 * 1e6;
    printf("        unknown-key probe: %.2f µs/call\n", perCall);
    // A thrown NSUnknownKeyException costs tens of microseconds; the probe
    // must stay well under that so per-frame view-tree scans are affordable.
    YTMU_ASSERT(perCall < 5.0, "unknown-key probe too slow: %.2f µs", perCall);
}
