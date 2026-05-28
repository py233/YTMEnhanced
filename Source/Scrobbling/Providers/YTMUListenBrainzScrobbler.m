#import "YTMUListenBrainzScrobbler.h"

static NSString *const kListenBrainzDefaultRoot = @"https://api.listenbrainz.org";

// ListenBrainz spec: a single submit-listens request may include up to
// 1000 listens. We cap our batch flush at the same number.
static const NSUInteger kListenBrainzBatchMax = 1000;

static NSError *YTMUListenBrainzError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"YTMUListenBrainz"
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: message ?: @"ListenBrainz error"}];
}

@implementation YTMUListenBrainzMatch
@end

@implementation YTMUListenBrainzScrobbler

- (NSString *)identifier {
    return @"listenbrainz";
}

#pragma mark Settings accessors

- (NSString *)apiRoot {
    NSString *configured = YTMUScrobbleDefaultsString(@"listenbrainz_apiRoot", kListenBrainzDefaultRoot);
    // Trim trailing slash so the path concatenation below stays clean.
    while ([configured hasSuffix:@"/"]) configured = [configured substringToIndex:configured.length - 1];
    return configured;
}

- (NSString *)userToken {
    return YTMUScrobbleDefaultsString(@"listenbrainz_userToken", @"");
}

- (BOOL)isEnabled {
    return YTMUScrobbleDefaultsBool(@"listenbrainz_enabled", NO);
}

- (BOOL)isConfigured {
    return self.userToken.length > 0;
}

#pragma mark - Token validation

- (void)validateTokenWithCompletion:(void (^)(BOOL, NSString *_Nullable, NSError *_Nullable))completion {
    NSString *token = self.userToken;
    if (!token.length) {
        completion(NO, nil, YTMUListenBrainzError(2001, @"Token missing"));
        return;
    }
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@/1/validate-token", self.apiRoot]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"GET";
    request.timeoutInterval = 30.0;
    [request setValue:[NSString stringWithFormat:@"Token %@", token] forHTTPHeaderField:@"Authorization"];

    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            completion(NO, nil, error);
            return;
        }
        NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]] ? [(NSHTTPURLResponse *)response statusCode] : 0;
        NSDictionary *json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if (status < 200 || status >= 300 || ![json isKindOfClass:[NSDictionary class]]) {
            completion(NO, nil, YTMUListenBrainzError(status, [NSString stringWithFormat:@"HTTP %ld", (long)status]));
            return;
        }
        BOOL valid = [json[@"valid"] respondsToSelector:@selector(boolValue)] && [json[@"valid"] boolValue];
        NSString *username = [json[@"user_name"] isKindOfClass:[NSString class]] ? json[@"user_name"] : nil;
        completion(valid, username, valid ? nil : YTMUListenBrainzError(2002, @"Token invalid"));
    }] resume];
}

#pragma mark - Metadata lookup

- (void)fetchMetadataLookupForTrack:(NSString *)track
                             artist:(NSString *)artist
                              album:(NSString *)album
                         completion:(void (^)(YTMUListenBrainzMatch *_Nullable, NSError *_Nullable))completion {
    if (!track.length || !artist.length) {
        completion(nil, YTMUListenBrainzError(2010, @"track/artist required"));
        return;
    }
    NSString *root = self.apiRoot;
    NSMutableCharacterSet *allowed = [NSCharacterSet.URLQueryAllowedCharacterSet mutableCopy];
    [allowed removeCharactersInString:@"&=+?#"];
    NSMutableArray<NSString *> *pairs = [NSMutableArray array];
    [pairs addObject:[NSString stringWithFormat:@"recording_name=%@",
                      [track stringByAddingPercentEncodingWithAllowedCharacters:allowed] ?: track]];
    [pairs addObject:[NSString stringWithFormat:@"artist_name=%@",
                      [artist stringByAddingPercentEncodingWithAllowedCharacters:allowed] ?: artist]];
    if (album.length) {
        [pairs addObject:[NSString stringWithFormat:@"release_name=%@",
                          [album stringByAddingPercentEncodingWithAllowedCharacters:allowed] ?: album]];
    }
    [pairs addObject:@"metadata=true"];
    NSString *urlString = [NSString stringWithFormat:@"%@/1/metadata/lookup?%@",
                           root, [pairs componentsJoinedByString:@"&"]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlString]];
    request.HTTPMethod = @"GET";
    request.timeoutInterval = 30.0;
    // ListenBrainz's metadata lookup endpoint actually does require
    // the user's auth token (despite some docs saying "optional").
    // Without this header live tests see HTTP 401 on every call.
    NSString *token = self.userToken;
    if (token.length) {
        [request setValue:[NSString stringWithFormat:@"Token %@", token] forHTTPHeaderField:@"Authorization"];
    }

    [[[NSURLSession sharedSession] dataTaskWithRequest:request
                                    completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            completion(nil, error);
            return;
        }
        NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]] ? [(NSHTTPURLResponse *)response statusCode] : 0;
        // 404 or 200-empty means "no match" — not a failure.
        if (status == 404) {
            completion(nil, nil);
            return;
        }
        if (status < 200 || status >= 300) {
            completion(nil, YTMUListenBrainzError(status, [NSString stringWithFormat:@"HTTP %ld", (long)status]));
            return;
        }
        if (data.length == 0) {
            completion(nil, nil);
            return;
        }
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (![json isKindOfClass:[NSDictionary class]] || json.count == 0) {
            completion(nil, nil);
            return;
        }
        // recording_mbid is the most useful piece. If the lookup
        // didn't return one, treat the whole result as "no canonical
        // match" so the resolver doesn't try to use partial data.
        NSString *recordingMBID = [json[@"recording_mbid"] isKindOfClass:[NSString class]] ? json[@"recording_mbid"] : nil;
        if (recordingMBID.length == 0) {
            completion(nil, nil);
            return;
        }
        YTMUListenBrainzMatch *match = [[YTMUListenBrainzMatch alloc] init];
        match.recordingMBID = recordingMBID;
        if ([json[@"release_mbid"] isKindOfClass:[NSString class]]) match.releaseMBID = json[@"release_mbid"];
        if ([json[@"artist_mbids"] isKindOfClass:[NSArray class]]) match.artistMBIDs = json[@"artist_mbids"];
        if ([json[@"recording_name"] isKindOfClass:[NSString class]]) match.track = json[@"recording_name"];
        if ([json[@"artist_credit_name"] isKindOfClass:[NSString class]]) match.artist = json[@"artist_credit_name"];
        if ([json[@"release_name"] isKindOfClass:[NSString class]]) match.releaseName = json[@"release_name"];
        completion(match, nil);
    }] resume];
}

#pragma mark - Submission

- (void)submitNowPlaying:(YTMUListen *)listen {
    if (![self isEnabled] || ![self isConfigured] || ![listen hasMinimumMetadata]) return;
    NSString *submittedTrack = [listen bestTrack];
    NSString *submittedArtist = [listen bestArtist];
    NSDictionary *body = [self bodyForListens:@[listen] listenType:@"playing_now" includeTimestamp:NO];
    [self submitBody:body completion:^(BOOL ok, NSError *err) {
        if (!ok) {
            YTMUScrobbleLog(@"listenbrainz now-playing failed track=\"%@\" / \"%@\": %@",
                            submittedTrack, submittedArtist, err.localizedDescription);
        } else {
            YTMUScrobbleLog(@"listenbrainz now-playing ok track=\"%@\" / \"%@\"",
                            submittedTrack, submittedArtist);
        }
    }];
}

- (void)submitScrobble:(YTMUListen *)listen completion:(YTMUScrobblerCompletion)completion {
    if (![self isEnabled] || ![self isConfigured] || ![listen hasMinimumMetadata]) {
        completion(NO, YTMUListenBrainzError(2003, @"Not configured or missing metadata"));
        return;
    }
    NSDictionary *body = [self bodyForListens:@[listen] listenType:@"single" includeTimestamp:YES];
    [self submitBody:body completion:completion];
}

- (void)submitBatch:(NSArray<YTMUListen *> *)listens completion:(YTMUScrobblerCompletion)completion {
    if (![self isEnabled] || ![self isConfigured] || listens.count == 0) {
        completion(NO, YTMUListenBrainzError(2003, @"Not configured or empty batch"));
        return;
    }
    NSArray *slice = listens.count > kListenBrainzBatchMax
        ? [listens subarrayWithRange:NSMakeRange(0, kListenBrainzBatchMax)]
        : listens;
    NSDictionary *body = [self bodyForListens:slice listenType:@"import" includeTimestamp:YES];
    [self submitBody:body completion:completion];
}

#pragma mark - Internal

- (NSDictionary *)bodyForListens:(NSArray<YTMUListen *> *)listens
                      listenType:(NSString *)listenType
                includeTimestamp:(BOOL)includeTimestamp {
    NSMutableArray *payload = [NSMutableArray arrayWithCapacity:listens.count];
    for (YTMUListen *listen in listens) {
        NSMutableDictionary *additional = [NSMutableDictionary dictionary];
        additional[@"media_player"] = @"YouTube Music (iOS)";
        additional[@"submission_client"] = @"YTMusicUltimate";
        if (listen.videoId.length) {
            additional[@"origin_url"] = [NSString stringWithFormat:@"https://music.youtube.com/watch?v=%@", listen.videoId];
            additional[@"music_service"] = @"music.youtube.com";
        }
        if (listen.durationSeconds > 0) additional[@"duration"] = @((long)round(listen.durationSeconds));
        // Attach MBIDs when the resolver found a canonical match.
        // ListenBrainz uses these to deduplicate against MusicBrainz
        // entries; without them, the listen still goes through but
        // takes the slower fuzzy-match path on the server side.
        if (listen.recordingMBID.length) additional[@"recording_mbid"] = listen.recordingMBID;
        if (listen.releaseMBID.length) additional[@"release_mbid"] = listen.releaseMBID;
        if (listen.artistMBIDs.count) additional[@"artist_mbids"] = listen.artistMBIDs;

        NSMutableDictionary *trackMeta = [NSMutableDictionary dictionary];
        // Best resolved values (corrected > cleaned > raw).
        trackMeta[@"track_name"] = [listen bestTrack];
        trackMeta[@"artist_name"] = [listen bestArtist];
        NSString *album = [listen bestAlbum];
        if (album.length) trackMeta[@"release_name"] = album;
        trackMeta[@"additional_info"] = additional;

        NSMutableDictionary *entry = [NSMutableDictionary dictionary];
        entry[@"track_metadata"] = trackMeta;
        if (includeTimestamp) entry[@"listened_at"] = @((long long)listen.startedAtUnix);
        [payload addObject:entry];
    }
    return @{@"listen_type": listenType, @"payload": payload};
}

- (void)submitBody:(NSDictionary *)body completion:(YTMUScrobblerCompletion)completion {
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@/1/submit-listens", self.apiRoot]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    request.timeoutInterval = 30.0;
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:[NSString stringWithFormat:@"Token %@", self.userToken] forHTTPHeaderField:@"Authorization"];
    NSError *jsonError = nil;
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:&jsonError];
    if (jsonError) {
        completion(NO, jsonError);
        return;
    }

    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            completion(NO, error);
            return;
        }
        NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]] ? [(NSHTTPURLResponse *)response statusCode] : 0;
        if (status < 200 || status >= 300) {
            NSString *body = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"";
            completion(NO, YTMUListenBrainzError(status, [NSString stringWithFormat:@"HTTP %ld: %@", (long)status, [body substringToIndex:MIN((NSUInteger)200, body.length)] ?: @""]));
            return;
        }
        completion(YES, nil);
    }] resume];
}

@end
