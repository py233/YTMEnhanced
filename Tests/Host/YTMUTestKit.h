// Minimal host-side test kit. No XCTest dependency so the suite runs with
// plain clang against the Mac Catalyst SDK — see Tests/Host/run.sh.
#import <Foundation/Foundation.h>

typedef void (^YTMUTestBlock)(void);

void YTMUTestRegister(const char *name, YTMUTestBlock block);
void YTMUTestFail(const char *file, int line, NSString *message);
NSUInteger YTMUTestRunAll(void);

// Registers a test at static-init time. Usage:
//   YTMU_TEST(name) { ... assertions ... }
#define YTMU_TEST(NAME) \
    static void YTMUTest_##NAME(void); \
    __attribute__((constructor)) static void YTMUTestReg_##NAME(void) { YTMUTestRegister(#NAME, ^{ YTMUTest_##NAME(); }); } \
    static void YTMUTest_##NAME(void)

#define YTMU_ASSERT(COND, ...) do { \
    if (!(COND)) { YTMUTestFail(__FILE__, __LINE__, [NSString stringWithFormat:@"" __VA_ARGS__]); } \
} while (0)

#define YTMU_ASSERT_EQ_STR(A, B) do { \
    NSString *_a = (A); NSString *_b = (B); \
    if (!((_a == nil && _b == nil) || [_a isEqualToString:_b])) { \
        YTMUTestFail(__FILE__, __LINE__, [NSString stringWithFormat:@"expected %@, got %@", _b, _a]); \
    } \
} while (0)

#define YTMU_ASSERT_EQ_INT(A, B) do { \
    long long _a = (long long)(A); long long _b = (long long)(B); \
    if (_a != _b) { YTMUTestFail(__FILE__, __LINE__, [NSString stringWithFormat:@"expected %lld, got %lld", _b, _a]); } \
} while (0)

// Runs BLOCK and asserts it throws an ObjC exception (used to pin down the
// *old* crashing behaviour in regression tests).
#define YTMU_ASSERT_THROWS(BLOCK) do { \
    BOOL _threw = NO; @try { BLOCK; } @catch (NSException *e) { _threw = YES; } \
    if (!_threw) { YTMUTestFail(__FILE__, __LINE__, @"expected an exception, none thrown"); } \
} while (0)

#define YTMU_ASSERT_NO_THROW(BLOCK) do { \
    @try { BLOCK; } @catch (NSException *e) { \
        YTMUTestFail(__FILE__, __LINE__, [NSString stringWithFormat:@"unexpected exception %@: %@", e.name, e.reason]); } \
} while (0)

// Spins the main run loop until COND is true or TIMEOUT seconds pass.
BOOL YTMUTestWaitUntil(NSTimeInterval timeout, BOOL (^cond)(void));
