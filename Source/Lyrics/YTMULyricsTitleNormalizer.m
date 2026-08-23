#import "YTMULyricsTitleNormalizer.h"
#import "../Utils/NSBundle+YTMU.h"
#import "../Utils/YTMUPlistStore.h"
#import "../Utils/YTMUInflightCoalescer.h"

// Persistent storage layout:
//   $CACHES/YTMUltimate/TitleNormalize/<sha1(videoId)>.plist
// Plist keys:
//   v          : schema version (currently 1)
//   title_p    : primary title
//   title_alts : array of alternate titles
//   artist_p   : primary artist
//   artist_alts: array of alternate artists
//   lang       : ISO 639-1 or ""
//   confidence : double
//   raw_t      : raw input title (sanity-check on read)
//   raw_a      : raw input artist
//
// Failures are not persisted: a parse failure is retried on the next
// refresh. (An earlier failure blacklist in NSUserDefaults was removed;
// -clearCache still deletes its legacy key.)

static const NSInteger YTMULNSchemaVersion = 1;
static NSString *const YTMULNLegacyFailuresKey = @"YTMULTitleNormalizeFailures";

static NSError *YTMULNError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"YTMULyricsTitleNormalizer"
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: message ?: YTMULocalized(@"LYRICS_ERROR_TITLE_NORMALIZE", @"normalize failed")}];
}

#pragma mark - YTMULyricsTitleNormalization

@implementation YTMULyricsTitleNormalization

- (instancetype)init {
    self = [super init];
    if (self) {
        _titleCandidates = @[];
        _artistCandidates = @[];
        _language = @"";
        _confidence = 0.0;
    }
    return self;
}

@end

#pragma mark - YTMULyricsTitleNormalizer

@interface YTMULyricsTitleNormalizer ()
@property (nonatomic, strong) YTMUPlistStore *store;
// While a request for a videoId is in flight, follow-on calls join its
// completion queue and the AI is hit just once.
@property (nonatomic, strong) YTMUInflightCoalescer<YTMULyricsTitleNormalizerCompletion> *inflight;
@end

@implementation YTMULyricsTitleNormalizer

+ (instancetype)sharedNormalizer {
    static YTMULyricsTitleNormalizer *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[self alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _store = [[YTMUPlistStore alloc] initWithSubdirectory:@"TitleNormalize" schemaVersion:YTMULNSchemaVersion];
        _inflight = [[YTMUInflightCoalescer alloc] init];
    }
    return self;
}

#pragma mark - Disk cache

- (nullable NSDictionary *)readPlistForVideoId:(NSString *)videoId {
    return [self.store plistForKey:videoId];
}

- (void)writePlist:(NSDictionary *)dict forVideoId:(NSString *)videoId {
    [self.store writePlist:dict forKey:videoId];
}

- (YTMULyricsTitleNormalization *)normalizationFromPlist:(NSDictionary *)dict {
    YTMULyricsTitleNormalization *n = [[YTMULyricsTitleNormalization alloc] init];
    NSString *titlePrimary = [dict[@"title_p"] isKindOfClass:[NSString class]] ? dict[@"title_p"] : @"";
    NSArray *titleAlts = [dict[@"title_alts"] isKindOfClass:[NSArray class]] ? dict[@"title_alts"] : @[];
    NSString *artistPrimary = [dict[@"artist_p"] isKindOfClass:[NSString class]] ? dict[@"artist_p"] : @"";
    NSArray *artistAlts = [dict[@"artist_alts"] isKindOfClass:[NSArray class]] ? dict[@"artist_alts"] : @[];

    NSMutableArray<NSString *> *titles = [NSMutableArray array];
    if (titlePrimary.length) [titles addObject:titlePrimary];
    for (id alt in titleAlts) if ([alt isKindOfClass:[NSString class]] && [(NSString *)alt length] && ![titles containsObject:alt]) [titles addObject:alt];

    NSMutableArray<NSString *> *artists = [NSMutableArray array];
    if (artistPrimary.length) [artists addObject:artistPrimary];
    for (id alt in artistAlts) if ([alt isKindOfClass:[NSString class]] && [(NSString *)alt length] && ![artists containsObject:alt]) [artists addObject:alt];

    n.titleCandidates = titles;
    n.artistCandidates = artists;
    n.language = [dict[@"lang"] isKindOfClass:[NSString class]] ? dict[@"lang"] : @"";
    n.confidence = [dict[@"confidence"] doubleValue];
    return n;
}

- (nullable YTMULyricsTitleNormalization *)cachedNormalizationForInfo:(YTMULyricsSearchInfo *)info {
    NSDictionary *dict = [self readPlistForVideoId:info.videoId];
    if (!dict) return nil;
    YTMULyricsTitleNormalization *n = [self normalizationFromPlist:dict];
    if (!n.titleCandidates.count || !n.artistCandidates.count) return nil;
    return n;
}

#pragma mark - Prompts

static NSString *const YTMULNSystemPrompt =
@"You are a music metadata normalizer. Your only job is to extract the canonical song title and artist for a YouTube Music video so they can be used to look up lyrics in third-party databases (LRCLIB, NetEase, Musixmatch, Genius). Output strict JSON only, with no markdown fences and no commentary.\n"
@"\n"
@"Rules:\n"
@"- The YouTube channel/uploader is often NOT the actual artist. Cover channels, label aggregators, individual fans uploading old OSTs, or doujin/Vocaloid distributors all post under names that do not match the performer or composer. Identify the real artist from the title, description, and any staff list (\"曲: ...\" / \"歌: ...\" / \"作詞: ...\" / \"vocal:\" / \"music:\").\n"
@"- For Japanese songs: prefer the kanji/Japanese form as title_primary, since Japanese lyrics databases index by the original Japanese title. Put romaji and any English subtitle in title_alts.\n"
@"- For Korean songs: prefer hangul as title_primary; put hanja or English subtitle in title_alts.\n"
@"- For Chinese songs: keep the original script as it appears in the title (do not convert simplified <-> traditional).\n"
@"- Strip noise: 【】 [] () prefixes, \"official video\", \"MV\", \"PV\", \"Lyric Video\", \"Cover by X\", uploader credits. Subtitles like \"(Only to me in 10 years)\" can move to title_alts.\n"
@"- featuring / with / × artists go into artist_alts unless the title clearly puts them as a co-lead.\n"
@"- For Vocaloid / VOCALOID-P songs: the producer (P) is the artist_primary; the voicebank (Hatsune Miku, 鏡音リン, etc.) is in artist_alts.\n"
@"- If you cannot identify a confident answer, return your best guess with a low confidence score; do not return placeholders or empty strings.\n"
@"\n"
@"Output exactly this JSON shape (no extra fields, no markdown):\n"
@"{\"title_primary\":\"\",\"title_alts\":[],\"artist_primary\":\"\",\"artist_alts\":[],\"language\":\"\",\"confidence\":0.0}";

- (NSString *)userPromptForInfo:(YTMULyricsSearchInfo *)info {
    NSMutableString *out = [NSMutableString string];
    [out appendFormat:@"title: %@\n", info.title.length ? info.title : @"(empty)"];
    [out appendFormat:@"channel/uploader: %@\n", info.artist.length ? info.artist : @"(empty)"];
    if (info.album.length) [out appendFormat:@"album: %@\n", info.album];
    if (info.shortDescription.length) {
        // Only feed the first ~600 chars of description — staff lists
        // almost always live at the top; the rest is credits/links/CC
        // notices that just inflate token count.
        NSString *desc = info.shortDescription;
        if (desc.length > 600) {
            // Cut on a composed-character boundary: a raw UTF-16 index can
            // land inside an emoji's surrogate pair, and a lone surrogate
            // makes the whole request body unserialisable.
            NSRange last = [desc rangeOfComposedCharacterSequenceAtIndex:600];
            desc = [desc substringToIndex:last.location];
        }
        [out appendFormat:@"description (truncated): %@\n", desc];
    }
    // OpenAI's Responses API rejects requests with `text.format=json_object`
    // unless the literal word "json" appears in the user message body
    // (error: "Response input messages must contain the word 'json' in some
    // form to use 'text.format' of type 'json_object'"). The system prompt
    // doesn't count for that gateway check, so include it here too.
    [out appendString:@"\nRespond with strict json only, matching the schema in the instructions.\n"];
    return out;
}

#pragma mark - JSON parsing

// Strip ```json…``` (any language tag) by walking characters: skip
// the opening ``` + optional language tag + separating whitespace, and
// strip a trailing ``` if present. The earlier "find first newline"
// approach failed silently when a model emitted `\`\`\`{...}\`\`\``
// with no newline after the fence.
- (NSString *)stripMarkdownFences:(NSString *)text {
    NSString *trimmed = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([trimmed hasPrefix:@"```"]) {
        NSUInteger i = 3;
        while (i < trimmed.length) {
            unichar c = [trimmed characterAtIndex:i];
            if (c == '\n' || c == '\r' || c == ' ' || c == '\t') break;
            i++;
        }
        while (i < trimmed.length) {
            unichar c = [trimmed characterAtIndex:i];
            if (c != '\n' && c != '\r' && c != ' ' && c != '\t') break;
            i++;
        }
        trimmed = [trimmed substringFromIndex:i];
    }
    if ([trimmed hasSuffix:@"```"]) trimmed = [trimmed substringToIndex:trimmed.length - 3];
    return [trimmed stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

- (nullable NSDictionary *)parseJSON:(NSString *)text {
    if (!text.length) return nil;
    NSString *clean = [self stripMarkdownFences:text];
    NSData *data = [clean dataUsingEncoding:NSUTF8StringEncoding];
    if (data) {
        id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if ([obj isKindOfClass:[NSDictionary class]]) return obj;
    }
    // Greedy first { … last } (handles prose like "Here's the JSON:" + trailing notes).
    NSRange open = [clean rangeOfString:@"{"];
    NSRange close = [clean rangeOfString:@"}" options:NSBackwardsSearch];
    if (open.location != NSNotFound && close.location != NSNotFound && close.location > open.location) {
        NSString *substr = [clean substringWithRange:NSMakeRange(open.location, close.location - open.location + 1)];
        NSData *substrData = [substr dataUsingEncoding:NSUTF8StringEncoding];
        id obj = substrData ? [NSJSONSerialization JSONObjectWithData:substrData options:0 error:nil] : nil;
        if ([obj isKindOfClass:[NSDictionary class]]) return obj;
    }
    // Brace-balanced extraction: respects JSON string literals so
    // braces inside `"..."` don't confuse the depth counter. Catches
    // mid-output trailing prose / fence remnants that would otherwise
    // drag `lastIndexOf` past the real closing brace.
    if (open.location != NSNotFound) {
        NSUInteger len = clean.length;
        NSUInteger depth = 0;
        BOOL inString = NO;
        BOOL escape = NO;
        NSUInteger endIdx = NSNotFound;
        for (NSUInteger i = open.location; i < len; i++) {
            unichar c = [clean characterAtIndex:i];
            if (inString) {
                if (escape) { escape = NO; continue; }
                if (c == '\\') { escape = YES; continue; }
                if (c == '"') inString = NO;
                continue;
            }
            if (c == '"') { inString = YES; continue; }
            if (c == '{') { depth++; }
            else if (c == '}') {
                if (depth > 0) depth--;
                if (depth == 0) { endIdx = i; break; }
            }
        }
        if (endIdx != NSNotFound) {
            NSString *substr = [clean substringWithRange:NSMakeRange(open.location, endIdx - open.location + 1)];
            NSData *substrData = [substr dataUsingEncoding:NSUTF8StringEncoding];
            id obj = substrData ? [NSJSONSerialization JSONObjectWithData:substrData options:0 error:nil] : nil;
            if ([obj isKindOfClass:[NSDictionary class]]) return obj;
        }
    }
    return nil;
}

- (nullable YTMULyricsTitleNormalization *)normalizationFromResponseDict:(NSDictionary *)dict {
    if (!dict) return nil;
    NSString *titlePrimary = [dict[@"title_primary"] isKindOfClass:[NSString class]] ? [(NSString *)dict[@"title_primary"] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] : @"";
    NSString *artistPrimary = [dict[@"artist_primary"] isKindOfClass:[NSString class]] ? [(NSString *)dict[@"artist_primary"] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] : @"";
    if (!titlePrimary.length || !artistPrimary.length) return nil;

    NSMutableArray<NSString *> *titles = [NSMutableArray arrayWithObject:titlePrimary];
    for (id alt in [dict[@"title_alts"] isKindOfClass:[NSArray class]] ? dict[@"title_alts"] : @[]) {
        if (![alt isKindOfClass:[NSString class]]) continue;
        NSString *trimmed = [(NSString *)alt stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (trimmed.length && ![titles containsObject:trimmed]) [titles addObject:trimmed];
    }

    NSMutableArray<NSString *> *artists = [NSMutableArray arrayWithObject:artistPrimary];
    for (id alt in [dict[@"artist_alts"] isKindOfClass:[NSArray class]] ? dict[@"artist_alts"] : @[]) {
        if (![alt isKindOfClass:[NSString class]]) continue;
        NSString *trimmed = [(NSString *)alt stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (trimmed.length && ![artists containsObject:trimmed]) [artists addObject:trimmed];
    }

    YTMULyricsTitleNormalization *n = [[YTMULyricsTitleNormalization alloc] init];
    n.titleCandidates = titles;
    n.artistCandidates = artists;
    n.language = [dict[@"language"] isKindOfClass:[NSString class]] ? dict[@"language"] : @"";
    n.confidence = [dict[@"confidence"] respondsToSelector:@selector(doubleValue)] ? [dict[@"confidence"] doubleValue] : 0.0;
    return n;
}

#pragma mark - Public

- (void)normalizeForInfo:(YTMULyricsSearchInfo *)info
                provider:(id<YTMULLMCompletionProvider>)provider
            providerName:(NSString *)providerName
              completion:(YTMULyricsTitleNormalizerCompletion)completion {
    if (!completion) return;
    NSString *videoId = info.videoId ?: @"";
    if (!provider || !videoId.length) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(nil, YTMULNError(1, @"missing provider or videoId"));
        });
        return;
    }

    YTMULyricsTitleNormalization *cached = [self cachedNormalizationForInfo:info];
    if (cached) {
        YTMULyricsLog(@"normalize cache hit videoId=%@ titles=%lu artists=%lu",
                      videoId, (unsigned long)cached.titleCandidates.count, (unsigned long)cached.artistCandidates.count);
        dispatch_async(dispatch_get_main_queue(), ^{ completion(cached, nil); });
        return;
    }

    // In-flight dedup: if another caller already kicked off an AI request
    // for this videoId, join its completion queue instead of firing a
    // second HTTP request. YouTube Music's player metadata can flicker
    // for ~2s after a song change (we get the previous song's title with
    // the new videoId, then the correct title), and without this we'd
    // burn 2-3 AI calls per song change.
    if (![self.inflight beginOrJoinKey:videoId completion:completion]) {
        YTMULyricsLog(@"normalize joined in-flight videoId=%@", videoId);
        return;
    }

    NSString *systemPrompt = YTMULNSystemPrompt;
    NSString *userPrompt = [self userPromptForInfo:info];
    YTMULyricsLog(@"normalize start videoId=%@ provider=%@ rawTitle=%@ rawArtist=%@",
                  videoId, providerName ?: @"<unknown>", info.title, info.artist);

    __weak typeof(self) weakSelf = self;
    [provider completeWithSystemPrompt:systemPrompt
                            userPrompt:userPrompt
                        expectJSONMode:YES
                            completion:^(NSString * _Nullable text, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            // Fan out the result to every queued caller.
            void (^fanout)(YTMULyricsTitleNormalization *, NSError *) = ^(YTMULyricsTitleNormalization *result, NSError *err) {
                for (YTMULyricsTitleNormalizerCompletion cb in [weakSelf.inflight takeCompletionsForKey:videoId]) cb(result, err);
            };

            if (error) {
                YTMULyricsLog(@"normalize network/HTTP failed videoId=%@ err=%@", videoId, error.localizedDescription);
                fanout(nil, error);
                return;
            }

            NSDictionary *json = [weakSelf parseJSON:text];
            YTMULyricsTitleNormalization *result = [weakSelf normalizationFromResponseDict:json];
            if (!result) {
                YTMULyricsLog(@"normalize parse failed videoId=%@ raw=%@", videoId,
                              text.length > 200 ? [text substringToIndex:200] : (text ?: @""));
                fanout(nil, YTMULNError(3, @"could not parse normalize response"));
                return;
            }

            // Persist on success.
            NSDictionary *plist = @{
                @"v":           @(YTMULNSchemaVersion),
                @"title_p":     result.titleCandidates.firstObject ?: @"",
                @"title_alts":  result.titleCandidates.count > 1 ? [result.titleCandidates subarrayWithRange:NSMakeRange(1, result.titleCandidates.count - 1)] : @[],
                @"artist_p":    result.artistCandidates.firstObject ?: @"",
                @"artist_alts": result.artistCandidates.count > 1 ? [result.artistCandidates subarrayWithRange:NSMakeRange(1, result.artistCandidates.count - 1)] : @[],
                @"lang":        result.language ?: @"",
                @"confidence":  @(result.confidence),
                @"raw_t":       info.title ?: @"",
                @"raw_a":       info.artist ?: @"",
            };
            [weakSelf writePlist:plist forVideoId:videoId];
            YTMULyricsLog(@"normalize success videoId=%@ titles=%lu artists=%lu lang=%@ conf=%.2f primary=\"%@\" / \"%@\"",
                          videoId,
                          (unsigned long)result.titleCandidates.count,
                          (unsigned long)result.artistCandidates.count,
                          result.language,
                          result.confidence,
                          result.titleCandidates.firstObject,
                          result.artistCandidates.firstObject);
            fanout(result, nil);
        });
    }];
}

- (void)clearCache {
    [self.store removeAll];
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:YTMULNLegacyFailuresKey];
}

@end
