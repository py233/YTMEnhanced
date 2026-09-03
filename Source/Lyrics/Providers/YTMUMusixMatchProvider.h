#import "../YTMULyricsTypes.h"

@interface YTMUMusixMatchProvider : NSObject <YTMULyricsProvider>

// API root, defaulting to https://apic.musixmatch.com. Only the host tests
// set this, to point the provider at a local server.
@property (nonatomic, copy) NSString *endpointBaseURL;

@end
