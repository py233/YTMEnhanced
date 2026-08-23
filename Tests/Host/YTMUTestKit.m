#import "YTMUTestKit.h"

@interface YTMUTestCase : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) YTMUTestBlock block;
@end
@implementation YTMUTestCase
@end

static NSMutableArray<YTMUTestCase *> *gTests;
static NSMutableArray<NSString *> *gCurrentFailures;

void YTMUTestRegister(const char *name, YTMUTestBlock block) {
    if (!gTests) gTests = [NSMutableArray array];
    YTMUTestCase *t = [[YTMUTestCase alloc] init];
    t.name = [NSString stringWithUTF8String:name];
    t.block = block;
    [gTests addObject:t];
}

void YTMUTestFail(const char *file, int line, NSString *message) {
    NSString *f = [[NSString stringWithUTF8String:file] lastPathComponent];
    [gCurrentFailures addObject:[NSString stringWithFormat:@"    %@:%d  %@", f, line, message]];
}

BOOL YTMUTestWaitUntil(NSTimeInterval timeout, BOOL (^cond)(void)) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while (!cond()) {
        if ([deadline timeIntervalSinceNow] <= 0) return NO;
        [[NSRunLoop mainRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
    }
    return YES;
}

NSUInteger YTMUTestRunAll(void) {
    [gTests sortUsingComparator:^NSComparisonResult(YTMUTestCase *a, YTMUTestCase *b) { return [a.name compare:b.name]; }];
    NSUInteger failed = 0;
    printf("Running %lu host tests\n", (unsigned long)gTests.count);
    for (YTMUTestCase *t in gTests) {
        gCurrentFailures = [NSMutableArray array];
        @autoreleasepool {
            @try {
                t.block();
            } @catch (NSException *e) {
                [gCurrentFailures addObject:[NSString stringWithFormat:@"    uncaught %@: %@", e.name, e.reason]];
            }
        }
        if (gCurrentFailures.count) {
            failed++;
            printf("  FAIL  %s\n%s\n", t.name.UTF8String, [gCurrentFailures componentsJoinedByString:@"\n"].UTF8String);
        } else {
            printf("  ok    %s\n", t.name.UTF8String);
        }
    }
    printf("%lu passed, %lu failed\n", (unsigned long)(gTests.count - failed), (unsigned long)failed);
    return failed;
}
