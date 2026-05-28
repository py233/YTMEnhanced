#import "YTMUScrobbleTypes.h"

NSNotificationName const YTMUPlaybackTrackChangedNotification = @"YTMUPlaybackTrackChangedNotification";
NSNotificationName const YTMUPlaybackStateChangedNotification = @"YTMUPlaybackStateChangedNotification";

NSString *const kYTMUPlaybackUserInfoListen = @"listen";
NSString *const kYTMUPlaybackUserInfoPreviousListen = @"previousListen";
NSString *const kYTMUPlaybackUserInfoElapsedSeconds = @"elapsedSeconds";
NSString *const kYTMUPlaybackUserInfoIsPlaying = @"isPlaying";

// last.fm spec: tracks shorter than 30s are never scrobble-eligible.
// Threshold is min(duration/2, 240s) once that minimum length is met.
static const NSTimeInterval kScrobbleMinTrackDuration = 30.0;
static const NSTimeInterval kScrobbleAbsoluteThreshold = 240.0;

@implementation YTMUListen

- (id)copyWithZone:(NSZone *)zone {
    YTMUListen *copy = [[YTMUListen allocWithZone:zone] init];
    copy.trackName = self.trackName;
    copy.artist = self.artist;
    copy.albumName = self.albumName;
    copy.durationSeconds = self.durationSeconds;
    copy.startedAtUnix = self.startedAtUnix;
    copy.elapsedPlayedSeconds = self.elapsedPlayedSeconds;
    copy.videoId = self.videoId;
    return copy;
}

- (BOOL)hasMinimumMetadata {
    return self.trackName.length > 0 && self.artist.length > 0;
}

- (BOOL)hasReachedScrobbleThreshold {
    if (self.durationSeconds < kScrobbleMinTrackDuration) return NO;
    NSTimeInterval threshold = MIN(self.durationSeconds / 2.0, kScrobbleAbsoluteThreshold);
    return self.elapsedPlayedSeconds >= threshold;
}

- (NSDictionary<NSString *, id> *)serialize {
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    if (self.trackName) dict[@"track"] = self.trackName;
    if (self.artist) dict[@"artist"] = self.artist;
    if (self.albumName) dict[@"album"] = self.albumName;
    if (self.videoId) dict[@"videoId"] = self.videoId;
    dict[@"duration"] = @(self.durationSeconds);
    dict[@"startedAt"] = @(self.startedAtUnix);
    dict[@"elapsed"] = @(self.elapsedPlayedSeconds);
    return dict;
}

+ (instancetype)deserialize:(NSDictionary<NSString *, id> *)dict {
    if (![dict isKindOfClass:[NSDictionary class]]) return nil;
    YTMUListen *listen = [[YTMUListen alloc] init];
    id track = dict[@"track"];
    id artist = dict[@"artist"];
    if (![track isKindOfClass:[NSString class]] || ![artist isKindOfClass:[NSString class]]) return nil;
    listen.trackName = track;
    listen.artist = artist;
    id album = dict[@"album"];
    if ([album isKindOfClass:[NSString class]]) listen.albumName = album;
    id videoId = dict[@"videoId"];
    if ([videoId isKindOfClass:[NSString class]]) listen.videoId = videoId;
    listen.durationSeconds = [dict[@"duration"] doubleValue];
    listen.startedAtUnix = [dict[@"startedAt"] doubleValue];
    listen.elapsedPlayedSeconds = [dict[@"elapsed"] doubleValue];
    return listen;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<YTMUListen %p track=\"%@\" artist=\"%@\" dur=%.1f elapsed=%.1f>",
            self, self.trackName, self.artist, self.durationSeconds, self.elapsedPlayedSeconds];
}

@end

#pragma mark - Defaults helpers

NSString *YTMUScrobbleDefaultsString(NSString *key, NSString *fallback) {
    NSDictionary *dict = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"YTMUltimate"] ?: @{};
    id value = dict[key];
    if ([value isKindOfClass:[NSString class]]) {
        NSString *str = [(NSString *)value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (str.length) return str;
    }
    return fallback ?: @"";
}

BOOL YTMUScrobbleDefaultsBool(NSString *key, BOOL fallback) {
    NSDictionary *dict = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"YTMUltimate"] ?: @{};
    id value = dict[key];
    if ([value respondsToSelector:@selector(boolValue)]) return [value boolValue];
    return fallback;
}

void YTMUScrobbleSetDefaults(NSString *key, id _Nullable value) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithDictionary:
                                 [defaults dictionaryForKey:@"YTMUltimate"] ?: @{}];
    if (value) {
        dict[key] = value;
    } else {
        [dict removeObjectForKey:key];
    }
    [defaults setObject:dict forKey:@"YTMUltimate"];
}

#pragma mark - Logging

void YTMUScrobbleLog(NSString *format, ...) {
    if (!YTMUScrobbleDefaultsBool(@"scrobbleDebugLogs", YES)) return;
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSLog(@"[YTMUltimate][scrobble] %@", message);
}
