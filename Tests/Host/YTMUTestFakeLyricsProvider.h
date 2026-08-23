#import <Foundation/Foundation.h>
#import "Lyrics/YTMULyricsTypes.h"

// Scriptable YTMULyricsProvider: returns a canned result / error after an
// optional delay, and records every search it receives.
@interface YTMUTestFakeLyricsProvider : NSObject <YTMULyricsProvider>
@property (nonatomic, copy) NSString *name;
@property (nonatomic, strong) YTMULyricsResult *result;      // nil → miss
@property (nonatomic, strong) NSError *error;
@property (nonatomic) NSTimeInterval delay;                   // seconds before completing
@property (nonatomic, readonly) NSUInteger searchCount;
@property (nonatomic, copy, readonly) YTMULyricsSearchInfo *lastInfo;
- (instancetype)initWithName:(NSString *)name;
@end

// Helpers shared by pipeline tests.
YTMULyricsResult *YTMUTestSyncedResult(NSString *source, NSString *title, NSString *artist, NSUInteger lines);
YTMULyricsResult *YTMUTestPlainResult(NSString *source, NSString *title, NSString *artist, NSUInteger lines);
YTMULyricsSearchInfo *YTMUTestInfo(NSString *videoId, NSString *title, NSString *artist);
