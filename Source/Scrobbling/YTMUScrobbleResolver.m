#import "YTMUScrobbleResolver.h"
#import "YTMUScrobbleTitleCleaner.h"
#import "YTMUScrobbleManager.h"
#import "Providers/YTMULastFMScrobbler.h"
#import "Providers/YTMUListenBrainzScrobbler.h"
#import "../Lyrics/YTMULyricsTitleNormalizer.h"
#import "../Lyrics/YTMULyricsTypes.h"
#import "../Translation/YTMUTranslator.h"
#import "../Translation/YTMUTranslationTypes.h"

// Cache TTL: corrections + MBID assignments are stable on the order
// of months, but we re-query every 30 days so that backend curation
// (artist renames, MBID merges) gets picked up eventually.
static const NSTimeInterval kResolverCacheTTLSeconds = 30 * 24 * 60 * 60;

// Hard cap on cache entries. LRU eviction on insert. Sized to cover
// a typical heavy-listener's library; well below NSUserDefaults
// performance cliffs for dict size.
static const NSUInteger kResolverCacheMaxEntries = 200;

// NSUserDefaults keys (under the existing "YTMUltimate" nested dict).
static NSString *const kLastFMCacheKey = @"lastfm_correctionCache";
static NSString *const kListenBrainzCacheKey = @"listenbrainz_metadataCache";

// Bump when the candidate-generation strategy changes. Cached entries
// written under a lower schema are auto-invalidated on read so users
// don't get stuck on sub-optimal winners chosen before new candidates
// (slash-L / slash-R / romaji) became available.
//
// History:
//   1 = original `track.getCorrection` entries (no "listeners" field)
//   2 = `track.search` single-candidate (primary only)
//   3 = `track.search` multi-candidate (primary + slash-L/R + romaji)
//   4 = adds sub-artist split candidates (e.g. "zuki & 初音ミク" tried
//       as "zuki" + "初音ミク" on the primary track, since last.fm
//       canonical often lives under just one of the collaborators)
//   5 = adds English-CJK alias hyphen split ("Suzaku-朱雀-" → "Suzaku")
//       AND artist.getInfo fallback when track.search misses entirely
//       (submit to the most popular sub-artist alias even when the
//       specific track has no canonical entry)
//   6 = restricts hyphen-split sub-artists to ASCII-only fragments —
//       v5 was promoting unrelated CJK same-name artists (e.g. "朱雀"
//       7,058 listeners is a traditional-music artist that has
//       nothing to do with Suzaku the Vocaloid producer)
//   7 = removes artist.getInfo popularity fallback. v5/v6 attached
//       scrobbles to "the most popular sub-artist" when no track-level
//       canonical was found, but that's just guessing — a popular
//       same-name artist isn't necessarily the canonical author of
//       *this* song. Now we require BOTH track AND artist to match a
//       real last.fm entry; if no candidate hits, we cache miss and
//       let Tier 3 LLM / cleaned values handle submission.
//   8 = cleaner now preserves trailing dashes when they're glued to
//       the last char ("Suzaku-朱雀-" kept as-is, not stripped to
//       "Suzaku-朱雀"). Tracks whose raw artist had a trailing dash
//       previously cached under the stripped form — invalidate so
//       the new (correct) cleaned artist drives the search.
static NSInteger const kLastFMCacheSchemaVersion = 8;

@interface YTMUScrobbleResolver ()
// In-memory mirror of the on-disk cache. Loaded once at init.
// Each value is a dict shaped like:
//   { @"ts": @(unix), @"track": ..., @"artist": ..., ... }
// "no match" entries set track/artist to NSNull so a subsequent
// query knows to skip the network call but still pass through Tier 1.
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSDictionary *> *lastfmCache;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSDictionary *> *listenbrainzCache;

// Per-listen guard so back-to-back calls (e.g. broadcaster ticks
// glitching) don't fire duplicate network requests for the same
// signature. Keys are signatures; values are NSNumber boxed BOOL.
@property (nonatomic, strong) NSMutableSet<NSString *> *inflightSignatures;

// Same shape as above but separately for LLM, which is much more
// expensive than corrections so we want a stricter dedupe.
@property (nonatomic, strong) NSMutableSet<NSString *> *inflightLLMVideoIds;
@end

// One candidate to feed last.fm `track.search`. `label` is a short
// tag like "primary"/"romaji"/"slash-L"/"slash-R" plus optional
// "+sub-artist" qualifier for telemetry.
@interface YTMUScrobbleCandidate : NSObject
@property (nonatomic, copy) NSString *track;
@property (nonatomic, copy) NSString *artist;
@property (nonatomic, copy) NSString *label;
@end
@implementation YTMUScrobbleCandidate
@end

@implementation YTMUScrobbleResolver

+ (instancetype)sharedResolver {
    static YTMUScrobbleResolver *resolver;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        resolver = [[self alloc] init];
    });
    return resolver;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _lastfmCache = [self loadCacheForKey:kLastFMCacheKey];
        _listenbrainzCache = [self loadCacheForKey:kListenBrainzCacheKey];
        _inflightSignatures = [NSMutableSet set];
        _inflightLLMVideoIds = [NSMutableSet set];
    }
    return self;
}

#pragma mark - Tier 1 (sync)

- (void)applyTier1ToListen:(YTMUListen *)listen {
    if (!listen || ![listen hasMinimumMetadata]) return;
    YTMUScrobbleCleanedMeta *meta = [YTMUScrobbleTitleCleaner cleanTrack:listen.trackName
                                                                 artist:listen.artist
                                                                  album:listen.albumName];
    listen.cleanedTrack = meta.track;
    listen.cleanedArtist = meta.artist;
    listen.cleanedAlbum = meta.album.length ? meta.album : nil;
    BOOL changed = ![meta.track isEqualToString:listen.trackName] || ![meta.artist isEqualToString:listen.artist];
    YTMUScrobbleLog(@"[resolver] tier1%@ track=\"%@\"%@ artist=\"%@\"%@ videoId=%@",
                    changed ? @" CLEANED" : @" passthrough",
                    listen.trackName,
                    changed && ![meta.track isEqualToString:listen.trackName]
                        ? [NSString stringWithFormat:@" → \"%@\"", meta.track] : @"",
                    listen.artist,
                    changed && ![meta.artist isEqualToString:listen.artist]
                        ? [NSString stringWithFormat:@" → \"%@\"", meta.artist] : @"",
                    listen.videoId ?: @"(none)");
}

#pragma mark - Tier 2 + Tier 3 (async)

- (void)resolveAsyncForListen:(YTMUListen *)listen {
    if (!listen || ![listen hasMinimumMetadata]) return;
    NSString *signature = [self signatureForListen:listen];
    @synchronized (self.inflightSignatures) {
        if ([self.inflightSignatures containsObject:signature]) {
            YTMUScrobbleLog(@"[resolver] already inflight, skip signature=%@", signature);
            return;
        }
        [self.inflightSignatures addObject:signature];
    }

    // Try cache for both providers up front. Cached "no match" is a
    // valid result — we honor it without hitting the network again.
    NSDictionary *cachedLastFM = [self readCache:self.lastfmCache key:signature];
    NSDictionary *cachedLB = [self readCache:self.listenbrainzCache key:signature];

    // Cache validation. Two independent reasons to drop a cached entry:
    //
    // 1) STALE SCHEMA — written under an older candidate-generation
    //    strategy. We bumped the schema version when we added slash-L /
    //    slash-R candidates so entries that "won" with just `primary`
    //    don't keep blocking us from trying the new candidates.
    //
    // 2) POISONED TRACK NAME — written by a pre-fix build that didn't
    //    verify result.track overlapped the input, e.g. MIMI search
    //    returning "いいじゃない" as winner for "消えない温度".
    //
    // Either condition → invalidate + remove + fall through to fresh
    // search.
    if (cachedLastFM) {
        BOOL shouldInvalidate = NO;
        NSString *reason = nil;
        // Schema check.
        NSInteger schema = [cachedLastFM[@"schema"] integerValue];
        if (schema < kLastFMCacheSchemaVersion) {
            shouldInvalidate = YES;
            reason = [NSString stringWithFormat:@"stale schema v%ld (current v%ld)",
                      (long)schema, (long)kLastFMCacheSchemaVersion];
        }
        // Track-name verification (only on search-format entries with
        // a positive track; "no match" sentinels stay).
        if (!shouldInvalidate) {
            id cachedTrack = cachedLastFM[@"track"];
            BOOL isSearchEntry = cachedLastFM[@"listeners"] != nil;
            BOOL hasMatch = [cachedTrack isKindOfClass:[NSString class]]
                && [(NSString *)cachedTrack length] > 0;
            if (isSearchEntry && hasMatch) {
                NSString *cleanedTrack = listen.cleanedTrack.length
                    ? listen.cleanedTrack : listen.trackName;
                if (![self track:cachedTrack matchesInput:cleanedTrack]) {
                    shouldInvalidate = YES;
                    reason = [NSString stringWithFormat:@"track mismatch (cached=\"%@\" input=\"%@\")",
                              cachedTrack, cleanedTrack];
                }
            }
        }
        if (shouldInvalidate) {
            YTMUScrobbleLog(@"[resolver] lf cache invalidated (%@) for sig=%@", reason, signature);
            cachedLastFM = nil;
            @synchronized (self.lastfmCache) {
                [self.lastfmCache removeObjectForKey:signature];
                YTMUScrobbleSetDefaults(kLastFMCacheKey, self.lastfmCache);
            }
        }
    }

    BOOL lastfmDone = NO;
    BOOL lbDone = NO;

    if (cachedLastFM) {
        [self applyLastFMResult:cachedLastFM toListen:listen fromCache:YES];
        lastfmDone = YES;
    }
    if (cachedLB) {
        [self applyLBResult:cachedLB toListen:listen fromCache:YES];
        lbDone = YES;
    }

    __weak typeof(self) weakSelf = self;

    dispatch_group_t group = dispatch_group_create();

    if (!lastfmDone) {
        dispatch_group_enter(group);
        [self fetchLastFMCorrectionForListen:listen completion:^{
            dispatch_group_leave(group);
        }];
    }
    if (!lbDone) {
        dispatch_group_enter(group);
        [self fetchLBMetadataForListen:listen completion:^{
            dispatch_group_leave(group);
        }];
    }

    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        @synchronized (strongSelf.inflightSignatures) {
            [strongSelf.inflightSignatures removeObject:signature];
        }
        // Tier 3 fires only when BOTH Tier 2 paths missed canonical.
        // The check below reads the listen's mutated state, so it
        // correctly accounts for both fresh network results and
        // cache hits applied earlier in this call.
        BOOL lfMissed = listen.correctedTrack == nil && listen.correctedArtist == nil;
        BOOL lbMissed = listen.recordingMBID == nil;
        YTMUScrobbleLog(@"[resolver] tier2 summary sig=%@ lf=%@ lb=%@ → tier3=%@",
                        signature,
                        lfMissed ? @"miss" : [NSString stringWithFormat:@"\"%@\" / \"%@\"",
                                              listen.correctedTrack ?: @"", listen.correctedArtist ?: @""],
                        lbMissed ? @"miss" : [NSString stringWithFormat:@"mbid=%@", listen.recordingMBID],
                        (lfMissed && lbMissed) ? @"will run" : @"skip");
        if (lfMissed && lbMissed) {
            [strongSelf maybeRunLLMNormalizeForListen:listen];
        }
    });
}

#pragma mark - Last.fm (Tier 2a)

// Normalize an artist string for cross-source comparison. Lower-cases,
// drops all whitespace, and unifies the multiple Vocaloid separators
// ("×", "・", "&", ",", "、") into one canonical token. Used to test
// whether a track.search result's artist field matches the input
// artist closely enough to count.
- (NSString *)normalizeArtistForCompare:(NSString *)s {
    if (s.length == 0) return @"";
    NSMutableString *out = [[s.lowercaseString stringByTrimmingCharactersInSet:
                             [NSCharacterSet characterSetWithCharactersInString:@" .。、,·"]]
                            mutableCopy];
    NSDictionary *map = @{
        @"×": @"&", @"・": @"&", @"·": @"&", @"、": @"&", @",": @"&", @" & ": @"&",
    };
    for (NSString *k in map) {
        [out replaceOccurrencesOfString:k withString:map[k]
                                options:0 range:NSMakeRange(0, out.length)];
    }
    NSRegularExpression *ws = [NSRegularExpression regularExpressionWithPattern:@"\\s+"
                                                                       options:0 error:nil];
    [ws replaceMatchesInString:out options:0
                          range:NSMakeRange(0, out.length) withTemplate:@""];
    return out;
}

// Does `resultArtist` plausibly refer to the same artist as our input
// `inputArtist`? Three accept rules in priority order:
//   1) Normalized equality ("MIMI" ≈ "MiMi", "tosho_aTe" ≈ "tosho_aTe")
//   2) Either side contains the other as a substring after normalize
//      (handles "PIKASONIC & Tatsunoshin" vs input "PIKASONIC", or
//      input "PIKASONIC & Tatsunoshin" vs result "PIKASONIC")
//   3) Reject otherwise — random tracks with the same title but a
//      different artist must not win.
- (BOOL)artist:(NSString *)resultArtist matchesInput:(NSString *)inputArtist {
    NSString *r = [self normalizeArtistForCompare:resultArtist];
    NSString *i = [self normalizeArtistForCompare:inputArtist];
    if (r.length == 0 || i.length == 0) return NO;
    if ([r isEqualToString:i]) return YES;
    // Be conservative on substring match: require min length 3 on the
    // shorter side to avoid "ia" matching every artist with "ia" in
    // the name. Vocaloid singer names tend to be ≥ 3 chars normalized.
    NSString *shorter = r.length <= i.length ? r : i;
    NSString *longer = r.length <= i.length ? i : r;
    if (shorter.length < 3) return NO;
    return [longer containsString:shorter];
}

// Normalize a track title for similarity compare. Lowercase, drop
// feat. credits, then keep only letters / digits / CJK characters
// — strips all punctuation and whitespace so "海辺の電話ボックス !"
// matches "海辺の電話ボックス" and "Fiction (feat. IA)" matches
// plain "Fiction". Used to prevent last.fm's fuzzy search from
// returning unrelated same-artist tracks as winners.
- (NSString *)normalizeTrackForCompare:(NSString *)s {
    if (s.length == 0) return @"";
    NSMutableString *out = [s.lowercaseString mutableCopy];
    // Drop "(feat. X)" / "(featuring X)" / "(ft. X)" / "(with X)".
    static NSRegularExpression *featParen;
    static NSRegularExpression *featBare;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        featParen = [NSRegularExpression regularExpressionWithPattern:
                     @"\\s*\\(\\s*(?:feat\\.?|featuring|ft\\.?|with)\\b[^)]*\\)\\s*"
                                                              options:NSRegularExpressionCaseInsensitive
                                                                error:nil];
        featBare = [NSRegularExpression regularExpressionWithPattern:
                    @"\\s+(?:feat\\.?|featuring|ft\\.?)\\b\\s*\\S.*$"
                                                             options:NSRegularExpressionCaseInsensitive
                                                               error:nil];
    });
    [featParen replaceMatchesInString:out options:0
                                range:NSMakeRange(0, out.length) withTemplate:@""];
    [featBare replaceMatchesInString:out options:0
                               range:NSMakeRange(0, out.length) withTemplate:@""];
    // Keep only letters, digits, CJK ideographs / kana / hangul.
    // Everything else (punctuation, brackets, whitespace) dropped.
    NSMutableString *clean = [NSMutableString stringWithCapacity:out.length];
    for (NSUInteger i = 0; i < out.length; i++) {
        unichar c = [out characterAtIndex:i];
        BOOL isAlnum = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
        BOOL isCJK = (c >= 0x3040 && c <= 0x309F) || (c >= 0x30A0 && c <= 0x30FF)
            || (c >= 0x4E00 && c <= 0x9FFF) || (c >= 0xAC00 && c <= 0xD7AF);
        if (isAlnum || isCJK) [clean appendFormat:@"%C", c];
    }
    return clean;
}

// Does `resultTrack` plausibly refer to the same SONG as `inputTrack`?
// Rules:
//   1) Normalized equality after stripping feat./punctuation
//   2) One side is a substring of the other AND shorter is ≥ 4 chars
//      AND shorter/longer ratio ≥ 0.5
//   3) Reject otherwise.
//
// Why this matters: last.fm `track.search` is fuzzy. When the input
// track is niche / missing on last.fm, it falls back to returning
// the input ARTIST's popular tracks — wholly unrelated songs. Without
// this check, "消えない温度 (feat. KAFU)" by MIMI gets matched to
// MIMI's "いいじゃない" (375 listeners) — a completely different song.
// The artist filter alone is not enough; we must verify the track
// name actually resembles what the user is playing.
- (BOOL)track:(NSString *)resultTrack matchesInput:(NSString *)inputTrack {
    NSString *r = [self normalizeTrackForCompare:resultTrack];
    NSString *i = [self normalizeTrackForCompare:inputTrack];
    if (r.length == 0 || i.length == 0) return NO;
    if ([r isEqualToString:i]) return YES;
    NSString *shorter = r.length <= i.length ? r : i;
    NSString *longer = r.length <= i.length ? i : r;
    // Sub-4-char shorter side is too ambiguous (e.g. "追憶" 2 chars
    // would match many unrelated tracks containing those chars).
    // Only an exact normalized match is allowed in that range.
    if (shorter.length < 4) return NO;
    if (![longer containsString:shorter]) return NO;
    // The shorter form has to cover at least half the longer form to
    // count as "same song with extra annotation" — avoids matching
    // "Sky" inside "Skyrocket" or "風" inside "風時計".
    double ratio = (double)shorter.length / (double)longer.length;
    return ratio >= 0.5;
}

// Filter results: keep only those whose artist plausibly matches input
// AND whose track title plausibly matches the candidate we asked for.
// Sort descending by listeners. Return all that survived; caller picks
// the top.
- (NSArray<YTMULastFMSearchResult *> *)filterAndSort:(NSArray<YTMULastFMSearchResult *> *)results
                                       matchingArtist:(NSString *)inputArtist
                                                track:(NSString *)inputTrack {
    if (results.count == 0) return @[];
    NSMutableArray *kept = [NSMutableArray array];
    for (YTMULastFMSearchResult *r in results) {
        if (![self artist:r.artist matchesInput:inputArtist]) continue;
        if (![self track:r.track matchesInput:inputTrack]) continue;
        [kept addObject:r];
    }
    [kept sortUsingComparator:^NSComparisonResult(YTMULastFMSearchResult *a, YTMULastFMSearchResult *b) {
        if (a.listeners == b.listeners) return NSOrderedSame;
        return a.listeners > b.listeners ? NSOrderedAscending : NSOrderedDescending;
    }];
    return kept;
}

- (void)fetchLastFMCorrectionForListen:(YTMUListen *)listen
                            completion:(void (^)(void))completion {
    YTMULastFMScrobbler *lf = [YTMUScrobbleManager sharedManager].lastfm;
    if (![lf isConfigured]) {
        // No api_key → skip Tier 2a cleanly.
        completion();
        return;
    }
    NSString *signature = [self signatureForListen:listen];
    NSString *primaryTrack = listen.cleanedTrack.length ? listen.cleanedTrack : listen.trackName;
    NSString *artist = listen.cleanedArtist.length ? listen.cleanedArtist : listen.artist;

    // Build the candidate list. Each candidate is a (track, artist)
    // pair that last.fm `track.search` will be fed with. The winner
    // is whichever candidate's top result has the most listeners.
    // Dedup is by (track + "|" + artist) — alternates that collapse
    // to existing pairs are skipped to avoid duplicate API calls.
    NSMutableArray<YTMUScrobbleCandidate *> *candidates = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];

    YTMUScrobbleCandidate *(^addCandidate)(NSString *, NSString *, NSString *) =
        ^YTMUScrobbleCandidate *(NSString *track, NSString *artistArg, NSString *label) {
        if (track.length == 0) return nil;
        NSString *useArtist = artistArg.length ? artistArg : artist;
        NSString *key = [NSString stringWithFormat:@"%@|%@", track, useArtist];
        if ([seen containsObject:key]) return nil;
        [seen addObject:key];
        YTMUScrobbleCandidate *c = [[YTMUScrobbleCandidate alloc] init];
        c.track = track;
        c.artist = useArtist;
        c.label = label;
        [candidates addObject:c];
        return c;
    };

    // Compute track-shape candidates first, then cartesian with the
    // artist candidates. This covers cases where the canonical entry
    // lives at e.g. "flow" by "Suzaku" (slash-L track × sub-artist
    // alias) — neither dimension alone is enough.
    NSArray<NSString *> *artistsToTry = [YTMUScrobbleTitleCleaner subArtistsForArtist:artist];

    NSMutableArray<NSDictionary *> *trackVariants = [NSMutableArray array];
    [trackVariants addObject:@{@"track": primaryTrack, @"label": @"primary"}];

    // Slash-left: when raw is "X / Y" and the cleaner didn't recognize
    // Y as artist/voicebank, we keep the full form as primary. But X
    // alone is sometimes the canonical entry with more listeners (e.g.
    // rinri 終着 / 鳴花ヒメ = 23 listeners, 終着 alone = 43).
    YTMUScrobbleCleanedMeta *slashL = [YTMUScrobbleTitleCleaner
                                       slashLeftVariantForTrack:listen.trackName
                                                         artist:listen.artist
                                                          album:listen.albumName];
    if (slashL.track.length && ![slashL.track isEqualToString:primaryTrack]) {
        [trackVariants addObject:@{@"track": slashL.track, @"label": @"slash-L"}];
    }

    // Slash-right: rare canonical-form, but worth checking — user
    // explicitly asked for both sides to be tried.
    YTMUScrobbleCleanedMeta *slashR = [YTMUScrobbleTitleCleaner
                                       slashRightVariantForTrack:listen.trackName
                                                          artist:listen.artist
                                                           album:listen.albumName];
    if (slashR.track.length && ![slashR.track isEqualToString:primaryTrack]) {
        [trackVariants addObject:@{@"track": slashR.track, @"label": @"slash-R"}];
    }

    // Romaji: ASCII side of "CJK - Romaji" split. last.fm's canonical
    // sometimes is the ROMAJI form (tosho_aTe "Shizume Chiku Zensen"
    // 350 listeners vs CJK 0), sometimes the CJK form (MiMi
    // "海辺の電話ボックス" 355 vs romaji 3).
    YTMUScrobbleCleanedMeta *romajiVariant = [YTMUScrobbleTitleCleaner
                                              romajiVariantForTrack:listen.trackName
                                                             artist:listen.artist
                                                              album:listen.albumName];
    if (romajiVariant.track.length && ![romajiVariant.track isEqualToString:primaryTrack]) {
        [trackVariants addObject:@{@"track": romajiVariant.track, @"label": @"romaji"}];
    }

    // Cartesian product: every track candidate × every artist candidate.
    // Each pair becomes one search call. Worst case = 4 tracks × 4
    // artists = 16 parallel calls (rare). For most tracks: 1 × 1 = 1.
    // The track-name + artist filter on each result set protects
    // against same-artist-different-song fuzzy matches.
    for (NSDictionary *tv in trackVariants) {
        NSString *t = tv[@"track"];
        NSString *tLabel = tv[@"label"];
        for (NSString *a in artistsToTry) {
            NSString *label;
            BOOL isFullArtist = [a isEqualToString:artist];
            if ([tLabel isEqualToString:@"primary"] && isFullArtist) {
                label = @"primary";
            } else if (isFullArtist) {
                label = tLabel;
            } else {
                label = [NSString stringWithFormat:@"%@+artist=%@", tLabel, a];
            }
            addCandidate(t, a, label);
        }
    }

    // Parallel search every candidate. lock guards the shared result
    // dictionaries since searchTrack:'s completion is on an arbitrary
    // queue.
    dispatch_group_t group = dispatch_group_create();
    NSMutableDictionary<NSString *, NSArray *> *resultsByLabel = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSError *> *errorsByLabel = [NSMutableDictionary dictionary];
    NSObject *lock = [[NSObject alloc] init];

    for (YTMUScrobbleCandidate *c in candidates) {
        dispatch_group_enter(group);
        [lf searchTrack:c.track
                 artist:c.artist
                  limit:5
             completion:^(NSArray<YTMULastFMSearchResult *> *results, NSError *error) {
            @synchronized (lock) {
                if (results) resultsByLabel[c.label] = results;
                if (error) errorsByLabel[c.label] = error;
            }
            dispatch_group_leave(group);
        }];
    }

    __weak typeof(self) weakSelf = self;
    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) {
            completion();
            return;
        }
        // If EVERY candidate erred (no usable data anywhere), bail
        // without caching — next attempt may succeed.
        if (errorsByLabel.count == candidates.count && resultsByLabel.count == 0) {
            NSString *firstErr = [[errorsByLabel.allValues firstObject] localizedDescription];
            YTMUScrobbleLog(@"[resolver] lf search error (all candidates) sig=%@ err=%@",
                            signature, firstErr ?: @"unknown");
            completion();
            return;
        }

        // Per-candidate: filter (artist + track name match), sort by
        // listeners desc, take top. Then pick the global winner across
        // candidates by listener count. The artist filter uses the
        // FULL input artist so a sub-artist search returning the
        // canonical "Zuki" still passes substring match against
        // "zuki & 初音ミク".
        YTMULastFMSearchResult *winner = nil;
        NSString *winnerLabel = nil;
        NSMutableArray<NSString *> *summary = [NSMutableArray array];
        for (YTMUScrobbleCandidate *c in candidates) {
            NSArray *results = resultsByLabel[c.label] ?: @[];
            NSArray *filtered = [strongSelf filterAndSort:results
                                          matchingArtist:artist
                                                   track:c.track];
            YTMULastFMSearchResult *top = filtered.firstObject;
            [summary addObject:[NSString stringWithFormat:@"%@=%ld",
                                c.label, (long)top.listeners]];
            if (top && (!winner || top.listeners > winner.listeners)) {
                winner = top;
                winnerLabel = c.label;
            }
        }

        NSDictionary *entry;
        if (winner && winner.listeners > 0) {
            entry = @{
                @"ts": @([[NSDate date] timeIntervalSince1970]),
                @"track": winner.track,
                @"artist": winner.artist,
                @"trackMBID": winner.mbid ?: @"",
                @"listeners": @(winner.listeners),
                @"source": winnerLabel,
                @"schema": @(kLastFMCacheSchemaVersion),
            };
            YTMUScrobbleLog(@"[resolver] lf search sig=%@ → \"%@\" / \"%@\" (%ld listeners, src=%@; tried %@)",
                            signature, winner.track, winner.artist,
                            (long)winner.listeners, winnerLabel,
                            [summary componentsJoinedByString:@" "]);
        } else {
            // No (track, artist) pair survived both filters across any
            // candidate combination — last.fm has no real canonical
            // entry for this song under any of the artist aliases we
            // tried. Cache miss; Tier 3 LLM may still produce a better
            // title, and final submission falls back to cleaned values
            // (which lets last.fm create an orphan entry but keeps the
            // scrobble under the user-visible artist name rather than
            // mis-attributing to some popular same-name artist).
            entry = @{
                @"ts": @([[NSDate date] timeIntervalSince1970]),
                @"track": @"",
                @"artist": @"",
                @"schema": @(kLastFMCacheSchemaVersion),
            };
            YTMUScrobbleLog(@"[resolver] lf search sig=%@ → no (track,artist) canonical (tried %@)",
                            signature, [summary componentsJoinedByString:@" "]);
        }
        [strongSelf writeCache:strongSelf.lastfmCache forKey:signature
                         entry:entry persistTo:kLastFMCacheKey];
        [strongSelf applyLastFMResult:entry toListen:listen fromCache:NO];
        completion();
    });
}

- (void)applyLastFMResult:(NSDictionary *)entry toListen:(YTMUListen *)listen fromCache:(BOOL)fromCache {
    if (![entry isKindOfClass:[NSDictionary class]]) return;
    id track = entry[@"track"];
    id artist = entry[@"artist"];
    // Empty string or non-string = cached "no match", skip mutation.
    // (We used to use NSNull here, but NSUserDefaults rejects NSNull
    // and crashes the host app at write time. Empty string is plist-
    // compatible and has the same "miss" semantics.)
    if (![track isKindOfClass:[NSString class]] || ![artist isKindOfClass:[NSString class]]
        || [(NSString *)track length] == 0 || [(NSString *)artist length] == 0) {
        if (fromCache) YTMUScrobbleLog(@"[resolver] lf cache hit (no match) track=\"%@\"", listen.trackName);
        return;
    }
    // Retroactive echo check on cache reads: pre-fix builds (running
    // the old `track.getCorrection` path) wrote last.fm's verbatim-
    // echo response as if it were a real correction. Detect that
    // pattern at read time so old poisoned entries don't keep
    // blocking Tier 3 from firing. We compare against the cleaned
    // values; if the stored result equals them case-insensitively,
    // treat as no canonical found.
    //
    // ONLY applies to legacy entries — new search-based entries
    // carry a "listeners" field, and their result CAN legitimately
    // equal the cleaned form (e.g. English-pop "Sad Machine" by
    // "Porter Robinson" — cleaned input matches canonical exactly).
    // Treating those as echo would block legitimate canonicalization
    // and trigger unnecessary Tier 3 LLM calls on already-canonical
    // English tracks.
    BOOL isLegacyEntry = entry[@"listeners"] == nil;
    if (fromCache && isLegacyEntry) {
        NSString *cleanedTrack = listen.cleanedTrack.length ? listen.cleanedTrack : listen.trackName;
        NSString *cleanedArtist = listen.cleanedArtist.length ? listen.cleanedArtist : listen.artist;
        if ([(NSString *)track caseInsensitiveCompare:cleanedTrack ?: @""] == NSOrderedSame
            && [(NSString *)artist caseInsensitiveCompare:cleanedArtist ?: @""] == NSOrderedSame) {
            YTMUScrobbleLog(@"[resolver] lf cache hit was legacy poisoned echo, ignoring track=\"%@\"", listen.trackName);
            return;
        }
    }
    listen.correctedTrack = track;
    listen.correctedArtist = artist;
    if (fromCache) YTMUScrobbleLog(@"[resolver] lf cache hit \"%@\" / \"%@\"", track, artist);
    // Note: last.fm MBIDs are present in `entry` but we don't write
    // them to listen.recordingMBID — LB's recording_mbid is the
    // authoritative one for scrobble submission. last.fm's track
    // MBID is informational and isn't used in the scrobble body.
}

#pragma mark - ListenBrainz (Tier 2b)

- (void)fetchLBMetadataForListen:(YTMUListen *)listen
                      completion:(void (^)(void))completion {
    YTMUListenBrainzScrobbler *lb = [YTMUScrobbleManager sharedManager].listenbrainz;
    // LB's metadata lookup endpoint rejects unauthenticated requests
    // with HTTP 401 even though some docs imply auth is optional —
    // gate on isConfigured so we don't spam the API with calls that
    // will only ever fail. Users without an LB token still get the
    // last.fm + LLM tiers; LB enrichment just needs the user to
    // paste a token in settings.
    if (![lb isConfigured]) {
        completion();
        return;
    }
    NSString *signature = [self signatureForListen:listen];
    NSString *track = listen.cleanedTrack.length ? listen.cleanedTrack : listen.trackName;
    NSString *artist = listen.cleanedArtist.length ? listen.cleanedArtist : listen.artist;
    NSString *album = listen.cleanedAlbum.length ? listen.cleanedAlbum : listen.albumName;
    [lb fetchMetadataLookupForTrack:track
                             artist:artist
                              album:album
                         completion:^(YTMUListenBrainzMatch *match, NSError *error) {
        if (error) {
            YTMUScrobbleLog(@"[resolver] lb lookup error sig=%@ err=%@", signature, error.localizedDescription);
            completion();
            return;
        }
        NSDictionary *entry;
        if (match) {
            NSMutableDictionary *mutable = [NSMutableDictionary dictionary];
            mutable[@"ts"] = @([[NSDate date] timeIntervalSince1970]);
            mutable[@"track"] = match.track.length ? match.track : @"";
            mutable[@"artist"] = match.artist.length ? match.artist : @"";
            mutable[@"release"] = match.releaseName.length ? match.releaseName : @"";
            mutable[@"recordingMBID"] = match.recordingMBID ?: @"";
            mutable[@"artistMBIDs"] = match.artistMBIDs ?: @[];
            mutable[@"releaseMBID"] = match.releaseMBID ?: @"";
            entry = mutable;
            YTMUScrobbleLog(@"[resolver] lb lookup sig=%@ → mbid=%@", signature, match.recordingMBID);
        } else {
            entry = @{
                @"ts": @([[NSDate date] timeIntervalSince1970]),
                @"recordingMBID": @"",
            };
            YTMUScrobbleLog(@"[resolver] lb lookup sig=%@ → no match", signature);
        }
        [self writeCache:self.listenbrainzCache forKey:signature entry:entry persistTo:kListenBrainzCacheKey];
        [self applyLBResult:entry toListen:listen fromCache:NO];
        completion();
    }];
}

- (void)applyLBResult:(NSDictionary *)entry toListen:(YTMUListen *)listen fromCache:(BOOL)fromCache {
    if (![entry isKindOfClass:[NSDictionary class]]) return;
    id mbid = entry[@"recordingMBID"];
    if (![mbid isKindOfClass:[NSString class]] || [(NSString *)mbid length] == 0) {
        if (fromCache) YTMUScrobbleLog(@"[resolver] lb cache hit (no match) track=\"%@\"", listen.trackName);
        return;
    }
    listen.recordingMBID = mbid;
    id artistMBIDs = entry[@"artistMBIDs"];
    if ([artistMBIDs isKindOfClass:[NSArray class]] && [(NSArray *)artistMBIDs count]) {
        listen.artistMBIDs = artistMBIDs;
    }
    id releaseMBID = entry[@"releaseMBID"];
    if ([releaseMBID isKindOfClass:[NSString class]] && [(NSString *)releaseMBID length]) {
        listen.releaseMBID = releaseMBID;
    }
    // Prefer LB's canonical names ONLY when last.fm corrections didn't
    // already write a value — last.fm tends to use English titles for
    // international releases, which is friendlier for users on the
    // last.fm side; LB tends to use original-language titles.
    id track = entry[@"track"];
    id artist = entry[@"artist"];
    if ([track isKindOfClass:[NSString class]] && [(NSString *)track length]
        && !listen.correctedTrack.length) {
        listen.correctedTrack = track;
    }
    if ([artist isKindOfClass:[NSString class]] && [(NSString *)artist length]
        && !listen.correctedArtist.length) {
        listen.correctedArtist = artist;
    }
    if (fromCache) YTMUScrobbleLog(@"[resolver] lb cache hit mbid=%@", mbid);
}

#pragma mark - LLM normalize (Tier 3)

- (void)maybeRunLLMNormalizeForListen:(YTMUListen *)listen {
    NSString *videoId = listen.videoId.length ? listen.videoId : nil;
    if (!videoId) {
        // No videoId = no stable cache key for the LLM normalizer.
        // Skip — the normalizer's blacklist + per-videoId cache rely
        // on a real id; making one up would defeat both.
        return;
    }
    id<YTMULLMCompletionProvider> llm = [[YTMUTranslator sharedTranslator] currentLLMCompletionProvider];
    if (!llm) {
        YTMUScrobbleLog(@"[resolver] tier3 skipped: no LLM provider configured");
        return;
    }
    YTMULyricsTitleNormalizer *normalizer = [YTMULyricsTitleNormalizer sharedNormalizer];

    @synchronized (self.inflightLLMVideoIds) {
        if ([self.inflightLLMVideoIds containsObject:videoId]) return;
        [self.inflightLLMVideoIds addObject:videoId];
    }

    // Build a search-info struct shaped like the lyrics path passes
    // in. We don't have a YT description handy in the scrobble path,
    // but title/artist/album are usually enough for the LLM to do
    // its job.
    YTMULyricsSearchInfo *info = [[YTMULyricsSearchInfo alloc] init];
    info.title = listen.cleanedTrack.length ? listen.cleanedTrack : listen.trackName;
    info.artist = listen.cleanedArtist.length ? listen.cleanedArtist : listen.artist;
    info.album = listen.cleanedAlbum.length ? listen.cleanedAlbum : listen.albumName;
    info.videoId = videoId;

    YTMULyricsTitleNormalization *cached = [normalizer cachedNormalizationForInfo:info];
    if (cached) {
        [self applyLLMNormalization:cached toListen:listen fromCache:YES];
        @synchronized (self.inflightLLMVideoIds) {
            [self.inflightLLMVideoIds removeObject:videoId];
        }
        return;
    }

    YTMUScrobbleLog(@"[resolver] tier3 llm normalize triggered videoId=%@", videoId);
    __weak typeof(self) weakSelf = self;
    NSString *providerName = NSStringFromClass([(id)llm class]);
    [normalizer normalizeForInfo:info
                        provider:llm
                    providerName:providerName
                      completion:^(YTMULyricsTitleNormalization *result, NSError *error) {
        typeof(self) strongSelf = weakSelf;
        @synchronized (strongSelf.inflightLLMVideoIds) {
            [strongSelf.inflightLLMVideoIds removeObject:videoId];
        }
        if (error || !result) {
            YTMUScrobbleLog(@"[resolver] tier3 llm normalize failed videoId=%@ err=%@",
                            videoId, error.localizedDescription);
            return;
        }
        [strongSelf applyLLMNormalization:result toListen:listen fromCache:NO];
    }];
}

- (void)applyLLMNormalization:(YTMULyricsTitleNormalization *)result
                     toListen:(YTMUListen *)listen
                    fromCache:(BOOL)fromCache {
    NSString *llmTitle = result.titleCandidates.firstObject;
    NSString *llmArtist = result.artistCandidates.firstObject;
    // Apply LLM title when we still don't have a correction. The
    // title is the high-value signal — it strips bilingual romaji
    // tails ("- Samenai Kodokuno Koroshikata"), VOCALOID brackets,
    // and "[Official Music Video]"-style cruft that last.fm's
    // corrections doesn't catch for non-English titles.
    if (llmTitle.length && !listen.correctedTrack.length) {
        listen.correctedTrack = llmTitle;
    }
    YTMUScrobbleLog(@"[resolver] tier3 applied%@ track=\"%@\" (llm suggested artist=\"%@\" conf=%.2f)",
                    fromCache ? @" (cache)" : @"",
                    llmTitle ?: @"",
                    llmArtist ?: @"",
                    result.confidence);

    // LLM-suggested artist treated as a SEARCH HINT, not a direct
    // override. Rationale:
    //
    //   * The lyrics-path normalizer extracts "the real composer"
    //     (Vocaloid producer) which is correct for lyrics search but
    //     wrong for scrobble attribution when the YT uploader IS the
    //     creator (e.g. `tosho_aTe` is their own producer alias).
    //   * Tier 3 only fires AFTER Tier 2 missed for the cleaned
    //     artist — so when the channel-name attribution has its own
    //     popular canonical on last.fm (tosho_aTe / *Luna / etc.),
    //     we already submitted to it and Tier 3 is skipped.
    //   * When Tier 3 DOES fire, the channel name has no canonical.
    //     In that case the LLM-suggested artist (original producer)
    //     IS plausibly where the canonical lives — but we don't
    //     trust it blindly. We re-run track.search with (LLM title,
    //     LLM artist) and only override if a real popular entry
    //     comes back. If nothing real exists under the LLM artist
    //     either, we fall through to the cleaned channel attribution.
    //
    // Threshold: LLM confidence ≥ 0.85 — high-confidence producer
    // identification only. Lower-confidence guesses are ignored to
    // avoid LLM artist hallucinations bleeding into scrobbles.
    NSString *cleanedArtist = listen.cleanedArtist.length
        ? listen.cleanedArtist : listen.artist;
    if (llmArtist.length == 0
        || [llmArtist isEqualToString:cleanedArtist]
        || result.confidence < 0.85) {
        return;
    }
    YTMULastFMScrobbler *lf = [YTMUScrobbleManager sharedManager].lastfm;
    if (![lf isConfigured]) return;

    NSString *searchTrack = llmTitle.length
        ? llmTitle
        : (listen.cleanedTrack.length ? listen.cleanedTrack : listen.trackName);
    NSString *signature = [self signatureForListen:listen];
    YTMUScrobbleLog(@"[resolver] tier3 llm-hint search: track=\"%@\" artist=\"%@\" (vs cleaned artist=\"%@\")",
                    searchTrack, llmArtist, cleanedArtist);

    __weak typeof(self) weakSelf = self;
    [lf searchTrack:searchTrack
             artist:llmArtist
              limit:5
         completion:^(NSArray<YTMULastFMSearchResult *> *searchResults, NSError *err) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (err) {
            YTMUScrobbleLog(@"[resolver] tier3 llm-hint search error: %@", err.localizedDescription);
            return;
        }
        NSArray *filtered = [strongSelf filterAndSort:searchResults
                                       matchingArtist:llmArtist
                                                track:searchTrack];
        YTMULastFMSearchResult *hit = filtered.firstObject;
        if (!hit || hit.listeners <= 0) {
            YTMUScrobbleLog(@"[resolver] tier3 llm-hint search → no real canonical under LLM artist (%lu raw, %lu filtered)",
                            (unsigned long)searchResults.count,
                            (unsigned long)filtered.count);
            return;
        }
        listen.correctedTrack = hit.track;
        listen.correctedArtist = hit.artist;
        // Persist to Tier 2 cache so future plays of the same song
        // skip Tier 3 entirely and pick up the canonical directly.
        NSDictionary *entry = @{
            @"ts": @([[NSDate date] timeIntervalSince1970]),
            @"track": hit.track,
            @"artist": hit.artist,
            @"trackMBID": hit.mbid ?: @"",
            @"listeners": @(hit.listeners),
            @"source": @"tier3-llm-hint",
            @"schema": @(kLastFMCacheSchemaVersion),
        };
        [strongSelf writeCache:strongSelf.lastfmCache
                        forKey:signature
                         entry:entry
                     persistTo:kLastFMCacheKey];
        YTMUScrobbleLog(@"[resolver] tier3 llm-hint search HIT → \"%@\" / \"%@\" (%ld listeners), cached",
                        hit.track, hit.artist, (long)hit.listeners);
    }];
}

#pragma mark - Cache

- (NSMutableDictionary<NSString *, NSDictionary *> *)loadCacheForKey:(NSString *)defaultsKey {
    NSDictionary *root = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"YTMUltimate"] ?: @{};
    id raw = root[defaultsKey];
    if (![raw isKindOfClass:[NSDictionary class]]) return [NSMutableDictionary dictionary];
    return [NSMutableDictionary dictionaryWithDictionary:raw];
}

- (nullable NSDictionary *)readCache:(NSMutableDictionary<NSString *, NSDictionary *> *)cache
                                 key:(NSString *)key {
    NSDictionary *entry = cache[key];
    if (![entry isKindOfClass:[NSDictionary class]]) return nil;
    NSTimeInterval ts = [entry[@"ts"] doubleValue];
    if ([[NSDate date] timeIntervalSince1970] - ts > kResolverCacheTTLSeconds) {
        // Stale — let it fall through to a fresh fetch.
        return nil;
    }
    return entry;
}

- (void)writeCache:(NSMutableDictionary<NSString *, NSDictionary *> *)cache
            forKey:(NSString *)key
             entry:(NSDictionary *)entry
         persistTo:(NSString *)defaultsKey {
    @synchronized (cache) {
        cache[key] = entry;
        // LRU eviction: when over cap, drop oldest by ts. Naive but
        // 200 entries is small enough that the O(N log N) sort here
        // is negligible vs the cost of skipping a cache hit.
        if (cache.count > kResolverCacheMaxEntries) {
            NSArray<NSString *> *sorted = [cache.allKeys sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
                NSTimeInterval ta = [cache[a][@"ts"] doubleValue];
                NSTimeInterval tb = [cache[b][@"ts"] doubleValue];
                return ta < tb ? NSOrderedAscending : NSOrderedDescending;
            }];
            NSUInteger toDrop = cache.count - kResolverCacheMaxEntries;
            for (NSUInteger i = 0; i < toDrop && i < sorted.count; i++) {
                [cache removeObjectForKey:sorted[i]];
            }
        }
        YTMUScrobbleSetDefaults(defaultsKey, cache);
    }
}

- (void)clearCaches {
    @synchronized (self.lastfmCache) {
        [self.lastfmCache removeAllObjects];
        YTMUScrobbleSetDefaults(kLastFMCacheKey, @{});
    }
    @synchronized (self.listenbrainzCache) {
        [self.listenbrainzCache removeAllObjects];
        YTMUScrobbleSetDefaults(kListenBrainzCacheKey, @{});
    }
}

#pragma mark - Signature

- (NSString *)signatureForListen:(YTMUListen *)listen {
    // Use raw values (pre-cleanup) so cache hits work even after
    // we tune the Tier 1 rules — if we keyed by cleaned, every rule
    // change would invalidate cached results that are still correct.
    return [NSString stringWithFormat:@"%@|%@",
            listen.trackName ?: @"",
            listen.artist ?: @""];
}

@end
