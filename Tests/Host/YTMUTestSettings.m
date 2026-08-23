#import "YTMUTestSettings.h"

static NSString *YTMUTestDomainName(void) {
    return [[NSBundle mainBundle] bundleIdentifier] ?: [[NSProcessInfo processInfo] processName];
}

void YTMUTestResetDefaultsDomain(void) {
    [[NSUserDefaults standardUserDefaults] removePersistentDomainForName:YTMUTestDomainName()];
}

void YTMUTestSetSettings(NSDictionary *settings) {
    [[NSUserDefaults standardUserDefaults] setObject:settings ?: @{} forKey:@"YTMUltimate"];
}

NSDictionary *YTMUTestSettings(void) {
    return [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"YTMUltimate"] ?: @{};
}
