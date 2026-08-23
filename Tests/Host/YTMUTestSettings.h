#import <Foundation/Foundation.h>
// Replaces the whole YTMUltimate settings dictionary the tweak reads from
// NSUserDefaults. The test binary has its own defaults domain, wiped at
// startup and exit by main.m, so nothing leaks onto the developer's Mac.
void YTMUTestSetSettings(NSDictionary *settings);
NSDictionary *YTMUTestSettings(void);
void YTMUTestResetDefaultsDomain(void);
