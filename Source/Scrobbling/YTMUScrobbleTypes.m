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
    copy.cleanedTrack = self.cleanedTrack;
    copy.cleanedArtist = self.cleanedArtist;
    copy.cleanedAlbum = self.cleanedAlbum;
    copy.correctedTrack = self.correctedTrack;
    copy.correctedArtist = self.correctedArtist;
    copy.correctedAlbum = self.correctedAlbum;
    copy.recordingMBID = self.recordingMBID;
    copy.artistMBIDs = self.artistMBIDs;
    copy.releaseMBID = self.releaseMBID;
    return copy;
}

#pragma mark - Submission helpers

// Pick the highest-priority non-empty value. The resolver writes
// corrected fields once a canonical name comes back from last.fm /
// LB / LLM; the manager writes cleaned fields synchronously from
// Tier 1 regex. Raw is the always-present fallback.
static NSString *YTMUListenFirstNonEmpty(NSString *a, NSString *b, NSString *c) {
    if (a.length) return a;
    if (b.length) return b;
    return c ?: @"";
}

- (NSString *)bestTrack {
    return YTMUListenFirstNonEmpty(self.correctedTrack, self.cleanedTrack, self.trackName);
}

- (NSString *)bestArtist {
    return YTMUListenFirstNonEmpty(self.correctedArtist, self.cleanedArtist, self.artist);
}

- (nullable NSString *)bestAlbum {
    // Album is optional; return nil rather than "" so providers can
    // skip the field entirely when empty (LB drops release_name when
    // missing, last.fm drops album=).
    NSString *best = YTMUListenFirstNonEmpty(self.correctedAlbum, self.cleanedAlbum, self.albumName);
    return best.length ? best : nil;
}

- (nullable NSString *)bestRecordingMBID {
    return self.recordingMBID.length ? self.recordingMBID : nil;
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
    // Persist normalization output so a queued offline listen
    // submits the canonical values once the queue drains rather
    // than re-running corrections against raw YT junk.
    if (self.cleanedTrack) dict[@"cleanedTrack"] = self.cleanedTrack;
    if (self.cleanedArtist) dict[@"cleanedArtist"] = self.cleanedArtist;
    if (self.cleanedAlbum) dict[@"cleanedAlbum"] = self.cleanedAlbum;
    if (self.correctedTrack) dict[@"correctedTrack"] = self.correctedTrack;
    if (self.correctedArtist) dict[@"correctedArtist"] = self.correctedArtist;
    if (self.correctedAlbum) dict[@"correctedAlbum"] = self.correctedAlbum;
    if (self.recordingMBID) dict[@"recordingMBID"] = self.recordingMBID;
    if (self.artistMBIDs.count) dict[@"artistMBIDs"] = self.artistMBIDs;
    if (self.releaseMBID) dict[@"releaseMBID"] = self.releaseMBID;
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
    id cleanedTrack = dict[@"cleanedTrack"];
    if ([cleanedTrack isKindOfClass:[NSString class]]) listen.cleanedTrack = cleanedTrack;
    id cleanedArtist = dict[@"cleanedArtist"];
    if ([cleanedArtist isKindOfClass:[NSString class]]) listen.cleanedArtist = cleanedArtist;
    id cleanedAlbum = dict[@"cleanedAlbum"];
    if ([cleanedAlbum isKindOfClass:[NSString class]]) listen.cleanedAlbum = cleanedAlbum;
    id correctedTrack = dict[@"correctedTrack"];
    if ([correctedTrack isKindOfClass:[NSString class]]) listen.correctedTrack = correctedTrack;
    id correctedArtist = dict[@"correctedArtist"];
    if ([correctedArtist isKindOfClass:[NSString class]]) listen.correctedArtist = correctedArtist;
    id correctedAlbum = dict[@"correctedAlbum"];
    if ([correctedAlbum isKindOfClass:[NSString class]]) listen.correctedAlbum = correctedAlbum;
    id recordingMBID = dict[@"recordingMBID"];
    if ([recordingMBID isKindOfClass:[NSString class]]) listen.recordingMBID = recordingMBID;
    id artistMBIDs = dict[@"artistMBIDs"];
    if ([artistMBIDs isKindOfClass:[NSArray class]]) listen.artistMBIDs = artistMBIDs;
    id releaseMBID = dict[@"releaseMBID"];
    if ([releaseMBID isKindOfClass:[NSString class]]) listen.releaseMBID = releaseMBID;
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
    if (!YTMUScrobbleDefaultsBool(@"scrobbleDebugLogs", NO)) return;
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSLog(@"[YTMUltimate][scrobble] %@", message);
}
