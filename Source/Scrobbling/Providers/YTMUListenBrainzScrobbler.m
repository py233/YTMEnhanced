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

#pragma mark - Submission

- (void)submitNowPlaying:(YTMUListen *)listen {
    if (![self isEnabled] || ![self isConfigured] || ![listen hasMinimumMetadata]) return;
    NSDictionary *body = [self bodyForListens:@[listen] listenType:@"playing_now" includeTimestamp:NO];
    [self submitBody:body completion:^(BOOL ok, NSError *err) {
        if (!ok) YTMUScrobbleLog(@"listenbrainz now-playing failed: %@", err.localizedDescription);
        else YTMUScrobbleLog(@"listenbrainz now-playing ok track=\"%@\"", listen.trackName);
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

        NSMutableDictionary *trackMeta = [NSMutableDictionary dictionary];
        trackMeta[@"track_name"] = listen.trackName ?: @"";
        trackMeta[@"artist_name"] = listen.artist ?: @"";
        if (listen.albumName.length) trackMeta[@"release_name"] = listen.albumName;
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
