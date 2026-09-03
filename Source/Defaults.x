#import "Utils/YTMUSettings.h"

// The one place settings are seeded at launch. Every other %ctor used to
// carry its own copy of this (six of them, with overlapping keys and no
// defined order between them).
%ctor {
    YTMUSettingsRegisterDefaults(YTMUSettingsBuiltInDefaults());
    // `lyricsTranslationEnabled` historically mirrored `bilingualLyrics` when
    // it was first introduced; keep that migration for settings dictionaries
    // written before the key existed (RegisterDefaults above only fills it
    // with NO when absent, so this only runs for users who had bilingual on).
    YTMUSettingsUpdate(^(NSMutableDictionary<NSString *, id> *settings) {
        if (settings[@"lyricsTranslationEnabled"] == nil && [settings[@"bilingualLyrics"] boolValue]) {
            settings[@"lyricsTranslationEnabled"] = @YES;
        }
        // Left behind by the removed artwork-overlay lyrics view.
        [settings removeObjectForKey:@"lyricsArtworkOverlayEnabled"];
    }, @[@"lyricsTranslationEnabled"]);
}
