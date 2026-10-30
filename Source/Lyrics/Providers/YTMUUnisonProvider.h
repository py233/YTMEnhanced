#import <Foundation/Foundation.h>
#import "../YTMULyricsTypes.h"

@interface YTMUUnisonProvider : NSObject <YTMULyricsProvider>
@property (nonatomic, copy) NSString *endpointBaseURL;
@end
