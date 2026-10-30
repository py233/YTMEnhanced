#import <Foundation/Foundation.h>
#import "../YTMULyricsTypes.h"

@interface YTMUBetterLyricsProvider : NSObject <YTMULyricsProvider>
@property (nonatomic, copy) NSString *endpointBaseURL;
@end
