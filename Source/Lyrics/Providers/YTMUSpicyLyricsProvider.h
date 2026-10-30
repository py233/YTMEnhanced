#import <Foundation/Foundation.h>
#import "../YTMULyricsTypes.h"

@interface YTMUSpicyLyricsProvider : NSObject <YTMULyricsProvider>
@property (nonatomic, copy) NSString *endpointBaseURL;
@end
