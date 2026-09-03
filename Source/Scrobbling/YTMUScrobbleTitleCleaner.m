#import "YTMUScrobbleTitleCleaner.h"

@implementation YTMUScrobbleCleanedMeta
@end

#pragma mark - Known voicebank names

// Names of VOCALOID / SynthV / UTAU / CeVIO voicebanks that YT Music
// uploaders commonly append to titles as " / VoicebankName". These
// are SINGER instruments, not artists — last.fm wants the producer
// (which YT Music already shows as the artist field) and the song
// name, with the voicebank ideally appearing as a `feat.` credit
// embedded in the title rather than glued onto the end with a slash.
//
// This list is hand-curated and intentionally incomplete: there are
// hundreds of voicebanks. We cover the ones the user's library shows
// and the canonical lineup. Match is case-insensitive against the
// exact suffix (after slash), so additions later are trivial.
static NSArray<NSString *> *YTMUSCKnownVoicebanks(void) {
    static NSArray<NSString *> *list;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        list = @[
            // Crypton Future Media flagship voicebanks
            @"初音ミク", @"Hatsune Miku", @"HATSUNE MIKU", @"miku",
            @"鏡音リン", @"鏡音レン", @"Kagamine Rin", @"Kagamine Len",
            @"巡音ルカ", @"Megurine Luka",
            @"KAITO", @"MEIKO",
            // Internet Co. / others
            @"GUMI", @"Megpoid",
            @"IA", @"ONE", @"Lily", @"Mew",
            @"v_flower", @"flower", @"フラワー", @"Fukase",
            // CeVIO / SynthV
            @"可不", @"KAF", @"KAFU",
            @"星界", @"Sekai",
            @"裏命",
            @"音街ウナ", @"OTOMACHI Una",
            @"小春六花", @"Koharu Rikka",
            // UTAU
            @"重音テト", @"Kasane Teto", @"テト", @"Teto",
            @"波音リツ", @"Namine Ritsu",
            @"デフォ子", @"Defoko",
            // Misc commonly featured
            @"ナースロボ_タイプT", @"NurseRobo_TypeT",
            @"ナースロボ＿タイプT",
        ];
    });
    return list;
}

static BOOL YTMUSCSuffixIsKnownVoicebank(NSString *suffix) {
    NSString *trimmed = [suffix stringByTrimmingCharactersInSet:
                         [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0) return NO;
    for (NSString *vb in YTMUSCKnownVoicebanks()) {
        if ([trimmed caseInsensitiveCompare:vb] == NSOrderedSame) return YES;
    }
    return NO;
}

// "Mostly ASCII" — used to detect romaji / English-translation
// suffixes on CJK-titled songs (e.g. "醒めない孤独の殺し方 - Samenai
// Kodokuno Koroshikata"). We say "mostly" because YT Music uploaders
// sometimes mix in CJK punctuation in the romaji block; a strict
// 100% ASCII check would miss those.
static BOOL YTMUSCIsMostlyASCII(NSString *str) {
    if (str.length == 0) return NO;
    NSUInteger asciiCount = 0;
    for (NSUInteger i = 0; i < str.length; i++) {
        unichar c = [str characterAtIndex:i];
        if (c < 128) asciiCount++;
    }
    return (double)asciiCount / (double)str.length > 0.7;
}

// "Mostly CJK" — heuristic for "the original title is in CJK so a
// trailing ASCII chunk is probably a romaji transliteration or
// English translation".
static BOOL YTMUSCIsMostlyCJK(NSString *str) {
    if (str.length == 0) return NO;
    NSUInteger cjkCount = 0;
    for (NSUInteger i = 0; i < str.length; i++) {
        unichar c = [str characterAtIndex:i];
        // Hiragana 0x3040-0x309F, Katakana 0x30A0-0x30FF,
        // CJK Unified Ideographs 0x4E00-0x9FFF, Hangul 0xAC00-0xD7AF
        if ((c >= 0x3040 && c <= 0x309F) ||
            (c >= 0x30A0 && c <= 0x30FF) ||
            (c >= 0x4E00 && c <= 0x9FFF) ||
            (c >= 0xAC00 && c <= 0xD7AF)) {
            cjkCount++;
        }
    }
    return (double)cjkCount / (double)str.length > 0.3;
}

// Does this look like a "feat. X" / "featuring X" / "ft. X" /
// "with X" string? We KEEP these because they're legitimate
// featuring credits.
static BOOL YTMUSCLooksLikeFeaturing(NSString *str) {
    NSString *lower = [str.lowercaseString stringByTrimmingCharactersInSet:
                       [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return [lower hasPrefix:@"feat."] || [lower hasPrefix:@"feat "] ||
           [lower hasPrefix:@"featuring "] || [lower hasPrefix:@"ft."] ||
           [lower hasPrefix:@"ft "] || [lower hasPrefix:@"with "];
}

#pragma mark - Regex builder

// Build an NSRegularExpression once. The pattern strings below are
// trusted (compile-time constants), so any pattern error is a
// programmer bug — we assert in DEBUG and fall through to a no-op
// in release rather than crashing the host app on a typo.
static NSRegularExpression *YTMUSCRegex(NSString *pattern, NSRegularExpressionOptions options) {
    NSError *err = nil;
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:pattern
                                                                        options:options
                                                                          error:&err];
    NSCAssert(re != nil, @"YTMUScrobbleTitleCleaner bad pattern %@: %@", pattern, err);
    return re;
}

// Apply a sequence of (regex, replacement) pairs against `string`,
// trim whitespace, and collapse runs of internal whitespace. Returns
// the trimmed result.
static NSString *YTMUSCApplyRules(NSString *input, NSArray<NSArray *> *rules) {
    if (input.length == 0) return @"";
    NSMutableString *s = [input mutableCopy];
    for (NSArray *rule in rules) {
        NSRegularExpression *re = rule[0];
        NSString *replacement = rule[1];
        [re replaceMatchesInString:s
                           options:0
                             range:NSMakeRange(0, s.length)
                      withTemplate:replacement];
    }
    // Collapse internal whitespace runs and trim edges.
    static NSRegularExpression *whitespaceRun;
    static NSRegularExpression *edgeJunk;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        whitespaceRun = YTMUSCRegex(@"\\s{2,}", 0);
        // Strip leading/trailing dashes / spaces / colons left over
        // after dropping parenthesized chunks at the start or end.
        //
        // TRAILING side has a subtle constraint: we only strip dashes
        // when they're SEPARATED from the body by whitespace (residue
        // pattern like "Cher - " left over after stripping "- Topic").
        // A dash glued directly to the last character ("Suzaku-朱雀-")
        // is part of the artist name itself — kanji-romanization alias
        // formats commonly end in "-" and stripping it sends scrobbles
        // to a 0-listener orphan instead of the user's real entry.
        //
        // Trailing pattern reads as:
        //   "trailing whitespace" optionally followed by
        //   "trailing whitespace-then-dash-then-junk" (the residue
        //   case). Either alone matches; combined matches both.
        edgeJunk = YTMUSCRegex(
            @"^[\\s\\-\\u2013\\u2014:]+|\\s+[\\s\\-\\u2013\\u2014:]*$",
            0);
    });
    [whitespaceRun replaceMatchesInString:s
                                  options:0
                                    range:NSMakeRange(0, s.length)
                             withTemplate:@" "];
    [edgeJunk replaceMatchesInString:s
                             options:0
                               range:NSMakeRange(0, s.length)
                        withTemplate:@""];
    return [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

#pragma mark - Rule tables

// Rules applied in order to the track field. Most patterns are case-
// insensitive — `i` option. The big "(...)" groups capture an entire
// parenthesized chunk to drop, not a sub-piece, so order between them
// doesn't usually conflict.
static NSArray<NSArray *> *YTMUSCTrackRules(void) {
    static NSArray<NSArray *> *rules;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        rules = @[
            // Markdown-style **emphasis** prefixes that occasionally appear.
            @[YTMUSCRegex(@"\\*+\\s?\\S+\\s?\\*+$", 0), @""],
            // [Anything in square brackets]
            @[YTMUSCRegex(@"\\[[^\\]]+\\]", 0), @""],
            // 【Anything in Chinese full-width brackets】
            @[YTMUSCRegex(@"【[^】]+】", 0), @""],
            // (Lyrics) / (Lyric Video) / (Lyrics Video)
            @[YTMUSCRegex(@"\\([^)]*lyrics?[^)]*\\)", NSRegularExpressionCaseInsensitive), @""],
            // (Official Video) / (Official Music Video) / (Official Audio) etc.
            @[YTMUSCRegex(@"\\([^)]*official[^)]*(video|audio|mv|m/v)[^)]*\\)", NSRegularExpressionCaseInsensitive), @""],
            // (Music Video) / (Audio) / (Visualizer) / (Visual)
            @[YTMUSCRegex(@"\\([^)]*(music video|m/v|visualizer|visual)[^)]*\\)", NSRegularExpressionCaseInsensitive), @""],
            // (MV) / (PV) / (HD) / (HQ) as standalone-ish tokens
            @[YTMUSCRegex(@"\\(\\s*(MV|PV|HD|HQ|4K|8K)\\s*\\)", NSRegularExpressionCaseInsensitive), @""],
            // (2024) — bare year in parens
            @[YTMUSCRegex(@"\\(\\s*\\d{4}\\s*\\)", 0), @""],
            // " - Official Music Video" trailing dash form
            @[YTMUSCRegex(@"\\s*[\\-\\u2013\\u2014]\\s*official\\s*(music\\s*)?(video|audio|m/v)\\s*$", NSRegularExpressionCaseInsensitive), @""],
            // "| anything" right-of-pipe is virtually always platform noise
            @[YTMUSCRegex(@"\\s*\\|.*$", 0), @""],
            // Trailing video file extension (very rare on YT Music but
            // shows up on some YouTube imports).
            @[YTMUSCRegex(@"\\.(avi|wmv|mpg|mpeg|flv|mp4)$", NSRegularExpressionCaseInsensitive), @""],
            // "/Covered by X" or "/Cover by X" suffix — common when
            // someone uploads a cover. We drop the whole "/...by X"
            // chunk and leave the bare title for canonical matching.
            @[YTMUSCRegex(@"\\s*\\/\\s*Cover(ed)?\\s+by\\s+[^/]+$", NSRegularExpressionCaseInsensitive), @""],
            // Japanese platform-tag tail: "大百科" / "ニコ動" left
            // over after 【】 stripping (nicovideo conventions).
            @[YTMUSCRegex(@"\\s*大百科\\s*$", 0), @""],
            // De-dup back-to-back identical featuring credits like
            // "(feat. 初音ミク) (feat. 初音ミク)" — the second is a
            // YT Music upload-form artifact.
            @[YTMUSCRegex(@"(\\(\\s*(?:feat\\.|featuring|ft\\.)[^)]*\\))\\s+\\1", NSRegularExpressionCaseInsensitive), @"$1"],
            // niconico-karaoke platform tail: tracks uploaded by
            // cover/karaoke channels often append "ニコカラ" (the JP
            // contraction of nicovideo karaoke) plus "onvocal" /
            // "offvocal" version markers. The real song name is
            // whatever is to the left.
            @[YTMUSCRegex(@"\\s+ニコカラ(\\s+(on|off)vocal)?\\s*$", NSRegularExpressionCaseInsensitive), @""],
            @[YTMUSCRegex(@"\\s+(on|off)\\s*vocal\\s*$", NSRegularExpressionCaseInsensitive), @""],
            @[YTMUSCRegex(@"\\s+一発撮り\\s*$", 0), @""],
        ];
    });
    return rules;
}

// Artist field: only a handful of patterns. We're conservative here
// because the artist name is what last.fm uses as the primary match
// key — an over-strip can mis-route the scrobble to the wrong artist.
static NSArray<NSArray *> *YTMUSCArtistRules(void) {
    static NSArray<NSArray *> *rules;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        rules = @[
            // YouTube auto-suffix on "ArtistName - Topic" auto-generated
            // channels. Examples: "Cher - Topic", "Hatsune Miku - Topic".
            @[YTMUSCRegex(@"\\s*[\\-\\u2013\\u2014]\\s*Topic\\s*$", NSRegularExpressionCaseInsensitive), @""],
            // VEVO channel suffix.
            @[YTMUSCRegex(@"\\s*VEVO\\s*$", NSRegularExpressionCaseInsensitive), @""],
            // Trailing parenthesized junk on the artist field. Real
            // artist names occasionally have parens (e.g. "P!nk (Live)"
            // wouldn't have parens in their artist label) — when in
            // doubt, drop the parens chunk.
            @[YTMUSCRegex(@"\\s*\\(.*\\)\\s*$", 0), @""],
        ];
    });
    return rules;
}

// Album rules: very conservative. Just strip square/Chinese brackets
// and bare years. Album titles legitimately contain "(Deluxe)" / "(EP)"
// / "(Remastered)" etc. that we don't want to lose.
static NSArray<NSArray *> *YTMUSCAlbumRules(void) {
    static NSArray<NSArray *> *rules;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        rules = @[
            @[YTMUSCRegex(@"\\[[^\\]]+\\]", 0), @""],
            @[YTMUSCRegex(@"【[^】]+】", 0), @""],
            @[YTMUSCRegex(@"\\(\\s*\\d{4}\\s*\\)", 0), @""],
        ];
    });
    return rules;
}

#pragma mark - Artist/Title split

// When `artist` is empty, a generic channel name, or marked "- Topic"
// and the track field looks like "Artist – Title", split it. We're
// strict about WHEN to split because real titles can contain dashes
// for legitimate reasons (e.g. "16:9 — Title").
//
// Returns YES (and fills out `*outArtist` / `*outTrack`) if we did
// the split. Returns NO otherwise; caller keeps the original values.
static BOOL YTMUSCTrySplitTitle(NSString *track,
                                 NSString *artist,
                                 NSString *__autoreleasing *outArtist,
                                 NSString *__autoreleasing *outTrack) {
    if (track.length == 0) return NO;

    // Only split when the artist slot is missing or generic. The
    // "" / "Topic" cases catch the common YT-auto-channel state
    // after artist-rule stripping. We also treat a one-token artist
    // that's a substring of the track as "looks like a channel
    // suffix the user'd want stripped" — but be careful not to
    // accept everything.
    BOOL artistMissing = artist.length == 0
        || [artist caseInsensitiveCompare:@"Topic"] == NSOrderedSame
        || [artist caseInsensitiveCompare:@"Various Artists"] == NSOrderedSame;
    if (!artistMissing) return NO;

    // Match "<left> [- – —] <right>" with optional surrounding spaces.
    // Use the FIRST dash from the left so "Artist – Song – (Live)" splits
    // as artist="Artist" track="Song – (Live)".
    static NSRegularExpression *splitRe;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        splitRe = YTMUSCRegex(@"^([^\\-\\u2013\\u2014]+?)\\s*[\\-\\u2013\\u2014]\\s*(.+)$", 0);
    });
    NSTextCheckingResult *m = [splitRe firstMatchInString:track options:0 range:NSMakeRange(0, track.length)];
    if (!m || m.numberOfRanges < 3) return NO;
    NSString *left = [track substringWithRange:[m rangeAtIndex:1]];
    NSString *right = [track substringWithRange:[m rangeAtIndex:2]];

    // Sanity: both sides must be non-trivial. Avoid silly splits like
    // "a-track" or trim-only-whitespace results.
    left = [left stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    right = [right stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (left.length < 2 || right.length < 2) return NO;

    *outArtist = left;
    *outTrack = right;
    return YES;
}

#pragma mark - Public API

@implementation YTMUScrobbleTitleCleaner

// Normalize an artist string for fuzzy equality. Collapses common
// multi-artist separators ("×", "&", "・", ",", "·", "、") into a
// single canonical form so we can compare "tosho_aTe × ukaihi"
// against "tosho_aTe & ukaihi" without a false negative. Also
// lowercases and trims punctuation tails like "Seeka ." → "seeka".
NSString *YTMUScrobbleNormalizeArtistForCompare(NSString *s) {
    if (s.length == 0) return @"";
    NSString *trimmed = [s stringByTrimmingCharactersInSet:
                         [NSCharacterSet characterSetWithCharactersInString:@" .。、,·"]];
    NSMutableString *out = [trimmed.lowercaseString mutableCopy];
    // Map all the artist-separator variants to one canonical token.
    NSDictionary *map = @{
        @"×": @"&",
        @"・": @"&",
        @"·": @"&",
        @"、": @"&",
        @",": @"&",
    };
    for (NSString *src in map) {
        [out replaceOccurrencesOfString:src
                             withString:map[src]
                                options:0
                                  range:NSMakeRange(0, out.length)];
    }
    // Collapse any whitespace.
    static NSRegularExpression *ws;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ ws = YTMUSCRegex(@"\\s+", 0); });
    [ws replaceMatchesInString:out options:0 range:NSMakeRange(0, out.length) withTemplate:@""];
    return out;
}

// Strip trailing " / Suffix" patterns when Suffix is either a copy
// of the artist (YT Music's redundant "Title / Artist" upload
// convention — `Twilight Line / HACHI` when artist is HACHI) or a
// known VOCALOID voicebank (`プラスティック / 初音ミク`). We keep
// "/ Suffix" otherwise so legitimate slashes in the title survive
// (e.g. AC/DC, "He/Him").
static NSString *YTMUSCStripSlashSuffix(NSString *track, NSString *artist) {
    if (track.length == 0) return track;
    // Last unescaped slash in the string. Splitting on the LAST one
    // (not first) lets the title keep any earlier slashes —
    // "Black/White / Artist" loses only the " / Artist" tail.
    // Handle both ASCII "/" and the fullwidth "／" (U+FF0F) which
    // YT Music uploaders often use in JP titles.
    NSRange ascii = [track rangeOfString:@"/" options:NSBackwardsSearch];
    NSRange wide = [track rangeOfString:@"／" options:NSBackwardsSearch];
    NSRange slashRange = NSMakeRange(NSNotFound, 0);
    if (ascii.location == NSNotFound) {
        slashRange = wide;
    } else if (wide.location == NSNotFound) {
        slashRange = ascii;
    } else {
        slashRange = ascii.location > wide.location ? ascii : wide;
    }
    if (slashRange.location == NSNotFound) return track;

    NSString *left = [track substringToIndex:slashRange.location];
    NSString *right = [track substringFromIndex:NSMaxRange(slashRange)];
    left = [left stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    right = [right stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    // Trim trailing punctuation like "Seeka ." → "Seeka" so the
    // equality check survives YT Music's odd spacing/punctuation
    // conventions.
    NSCharacterSet *trailingPunct = [NSCharacterSet characterSetWithCharactersInString:@" .。、,，"];
    NSString *rightCleaned = [right stringByTrimmingCharactersInSet:trailingPunct];
    NSString *artistCleaned = [artist stringByTrimmingCharactersInSet:trailingPunct];

    if (left.length < 2 || rightCleaned.length == 0) return track;
    // KEEP the suffix if it's a "feat. X" credit — those are part
    // of the canonical title and last.fm renders them correctly.
    if (YTMUSCLooksLikeFeaturing(rightCleaned)) return track;

    // Before comparing, drop trailing featuring credits from the
    // right side so e.g. "utumiyqcom × ukaihi (feat. HATSUNE MIKU)"
    // still matches an artist field of "utumiyqcom & ukaihi", and
    // "弓絃 feat.初音ミク" matches "弓絃". Two passes: parenthesized
    // first, then bare suffix. Both target the *trailing* feat
    // credit only; legitimate "ArtistA feat. ArtistB" mid-string
    // artist labels stay intact.
    static NSRegularExpression *featParen;
    static NSRegularExpression *featBare;
    static dispatch_once_t featOnce;
    dispatch_once(&featOnce, ^{
        featParen = YTMUSCRegex(@"\\s*\\(\\s*(?:feat\\.|featuring|ft\\.)[^)]*\\)\\s*$", NSRegularExpressionCaseInsensitive);
        // `\\b` after the keyword catches both "feat. X" (space) and
        // "feat.X" (no space) — common in YT-uploaded Japanese
        // titles like "弓絃 feat.初音ミク". `\\.?` makes the period
        // optional so plain `featuring` matches too. The trailing
        // `\\S.+$` requires at least one non-space character after
        // so we don't strip a dangling " feat." with no target.
        featBare = YTMUSCRegex(@"\\s+(?:feat|featuring|ft)\\b\\.?\\s*\\S.*$", NSRegularExpressionCaseInsensitive);
    });
    NSMutableString *rightForCompare = [rightCleaned mutableCopy];
    [featParen replaceMatchesInString:rightForCompare options:0
                                range:NSMakeRange(0, rightForCompare.length) withTemplate:@""];
    [featBare replaceMatchesInString:rightForCompare options:0
                               range:NSMakeRange(0, rightForCompare.length) withTemplate:@""];
    NSString *rightNorm = YTMUScrobbleNormalizeArtistForCompare(rightForCompare);
    NSString *artistNorm = YTMUScrobbleNormalizeArtistForCompare(artistCleaned);
    BOOL suffixIsArtist = artistNorm.length > 0 && [rightNorm isEqualToString:artistNorm];
    BOOL suffixIsVoicebank = YTMUSCSuffixIsKnownVoicebank(rightCleaned);
    if (!suffixIsArtist && !suffixIsVoicebank) return track;
    // Capture any feat. credit that lived on the slash side and
    // re-attach it to the left so we keep "弓絃 feat.初音ミク" → title
    // gets "(feat. 初音ミク)" rather than dropping the credit. Last.fm
    // canonical Vocaloid entries typically carry the feat. credit.
    static NSRegularExpression *featCapture;
    static dispatch_once_t captureOnce;
    dispatch_once(&captureOnce, ^{
        featCapture = YTMUSCRegex(
            @"(\\(\\s*(?:feat\\.?|featuring|ft\\.?|with)\\b[^)]*\\)|"
            @"(?:feat\\.?|featuring|ft\\.?)\\b\\s*\\S.*)$",
            NSRegularExpressionCaseInsensitive);
    });
    NSTextCheckingResult *fm = [featCapture firstMatchInString:rightCleaned
                                                       options:0
                                                         range:NSMakeRange(0, rightCleaned.length)];
    if (fm && fm.numberOfRanges >= 2) {
        NSString *credit = [rightCleaned substringWithRange:[fm rangeAtIndex:1]];
        credit = [credit stringByTrimmingCharactersInSet:
                  [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (credit.length > 0) {
            if (![credit hasPrefix:@"("]) {
                credit = [NSString stringWithFormat:@"(%@)", credit];
            }
            // If the left side ALREADY carries any feat. keyword the
            // credit is redundant — different romanizations ("初音ミク"
            // vs "HATSUNE MIKU") would otherwise duplicate. We trust
            // the left's existing credit.
            static NSRegularExpression *leftHasFeat;
            static dispatch_once_t leftFeatOnce;
            dispatch_once(&leftFeatOnce, ^{
                leftHasFeat = YTMUSCRegex(
                    @"(?:feat\\.?|featuring|ft\\.?)\\b",
                    NSRegularExpressionCaseInsensitive);
            });
            NSRange leftFeatRange = [leftHasFeat rangeOfFirstMatchInString:left
                                                                   options:0
                                                                     range:NSMakeRange(0, left.length)];
            if (leftFeatRange.location == NSNotFound) {
                return [NSString stringWithFormat:@"%@ %@", left, credit];
            }
        }
    }
    return left;
}

// Strip trailing " - Romaji"/"- English" annotation when the title
// is mostly CJK and the suffix is mostly ASCII (e.g. "醒めない孤独の
// 殺し方 - Samenai Kodokuno Koroshikata"). Preserves featuring
// credits and song-internal dashes ("Black - White") that don't
// match this CJK-vs-ASCII contrast.
//
// IMPORTANT: when the romaji side carries a "(feat. X)" or trailing
// "feat. X" credit, we re-attach that credit to the kept CJK title.
// Last.fm's canonical entries DO carry feat. credits for Vocaloid
// tracks ("(feat. Hatsune Miku)" etc.), and dropping them causes
// scrobbles to land on the no-listener fallback entry instead of
// the populated canonical one.
static NSString *YTMUSCStripRomajiSuffix(NSString *track) {
    if (track.length == 0) return track;
    // Match the LAST dash (regular `-`, en-dash, em-dash) splitting
    // into "title - suffix". We require at least one space on each
    // side of the dash so we don't break hyphenated single words.
    static NSRegularExpression *re;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        re = [NSRegularExpression regularExpressionWithPattern:
              @"^(.+?)\\s+[\\-\\u2013\\u2014]\\s+(.+)$"
                                                       options:0
                                                         error:nil];
    });
    NSTextCheckingResult *m = [re firstMatchInString:track options:0 range:NSMakeRange(0, track.length)];
    if (!m || m.numberOfRanges < 3) return track;
    NSString *left = [track substringWithRange:[m rangeAtIndex:1]];
    NSString *right = [track substringWithRange:[m rangeAtIndex:2]];
    left = [left stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    right = [right stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (left.length < 2 || right.length < 2) return track;
    // KEEP "feat. X" / "ft. X" credits unconditionally — entire right
    // side IS the featuring credit, don't dismantle it.
    if (YTMUSCLooksLikeFeaturing(right)) return track;
    // Only strip when the contrast is clear: CJK title + ASCII-heavy
    // suffix. This catches "醒めない... - Samenai Kodokuno..." but
    // leaves "Mako - Our Story" alone (both sides are ASCII —
    // probably a real two-part title).
    if (!(YTMUSCIsMostlyCJK(left) && YTMUSCIsMostlyASCII(right))) {
        return track;
    }
    // Extract any (feat. X) or trailing bare "feat. X" credit from
    // the romaji side and append it to the left so feat. credit
    // survives the strip. Without this, "胡蝶の夢 - Life is but a
    // dream (feat. HATSUNE MIKU)" would lose the Hatsune Miku credit
    // and miss the canonical last.fm entry.
    static NSRegularExpression *featExtract;
    static dispatch_once_t featOnce;
    dispatch_once(&featOnce, ^{
        // Either a parenthesized "(feat. X)" or a trailing bare
        // "feat. X" credit. We anchor with `$` so we only capture a
        // credit that runs to the END of the right side — anywhere
        // else and it's probably embedded in the song name.
        featExtract = YTMUSCRegex(
            @"(\\(\\s*(?:feat\\.?|featuring|ft\\.?|with)\\b[^)]*\\)|"
            @"(?:feat\\.?|featuring|ft\\.?)\\b\\s*\\S.*)$",
            NSRegularExpressionCaseInsensitive);
    });
    NSTextCheckingResult *fm = [featExtract firstMatchInString:right
                                                       options:0
                                                         range:NSMakeRange(0, right.length)];
    if (fm && fm.numberOfRanges >= 2) {
        NSString *credit = [right substringWithRange:[fm rangeAtIndex:1]];
        credit = [credit stringByTrimmingCharactersInSet:
                  [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        // Wrap in parens if it's a bare "feat. X" without enclosing
        // parens — canonical streaming-platform titles use parens.
        if (![credit hasPrefix:@"("]) {
            credit = [NSString stringWithFormat:@"(%@)", credit];
        }
        return [NSString stringWithFormat:@"%@ %@", left, credit];
    }
    return left;
}

// Companion to YTMUSCStripRomajiSuffix — returns the ROMAJI side of a
// "CJK - Romaji" split instead of the CJK side. The resolver feeds
// this back into the cleaner pipeline as a popularity-ranking
// alternate candidate (see +romajiVariantForTrack:). Returns nil if
// the input doesn't have a clean CJK-ASCII split.
static NSString *YTMUSCExtractRomajiSide(NSString *track) {
    if (track.length == 0) return nil;
    static NSRegularExpression *re;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        re = [NSRegularExpression regularExpressionWithPattern:
              @"^(.+?)\\s+[\\-\\u2013\\u2014]\\s+(.+)$"
                                                       options:0
                                                         error:nil];
    });
    NSTextCheckingResult *m = [re firstMatchInString:track options:0
                                                range:NSMakeRange(0, track.length)];
    if (!m || m.numberOfRanges < 3) return nil;
    NSString *left = [track substringWithRange:[m rangeAtIndex:1]];
    NSString *right = [track substringWithRange:[m rangeAtIndex:2]];
    left = [left stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    right = [right stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (left.length < 2 || right.length < 2) return nil;
    // If the right side starts with feat./ft./featuring, the whole
    // right side IS the feat. credit — there's no separate romaji
    // here to extract.
    if (YTMUSCLooksLikeFeaturing(right)) return nil;
    // Same contrast check as the strip variant: CJK left + ASCII right.
    // We're not stripping anything; we're just exposing the ASCII
    // side as an alternate candidate.
    if (!(YTMUSCIsMostlyCJK(left) && YTMUSCIsMostlyASCII(right))) return nil;
    return right;
}

+ (nullable YTMUScrobbleCleanedMeta *)romajiVariantForTrack:(NSString *)track
                                                     artist:(NSString *)artist
                                                      album:(NSString *)album {
    if (track.length == 0) return nil;
    // Pre-clean to drop brackets, "(Official MV)", "| Topic", etc.
    // before looking for the CJK-ASCII split — uploader noise often
    // sits OUTSIDE the dash separator and would shift the split.
    NSString *phase1 = YTMUSCApplyRules(track, YTMUSCTrackRules());
    NSString *romajiSide = YTMUSCExtractRomajiSide(phase1);
    if (!romajiSide) return nil;
    YTMUScrobbleCleanedMeta *meta = [[YTMUScrobbleCleanedMeta alloc] init];
    meta.track = romajiSide;
    // Artist/album cleaning is identical to the primary pipeline —
    // we only diverge on which side of the romaji split we keep.
    meta.artist = YTMUSCApplyRules(artist ?: @"", YTMUSCArtistRules());
    meta.album = YTMUSCApplyRules(album ?: @"", YTMUSCAlbumRules());
    return meta;
}

// Find the LAST slash position in `s` (either ASCII "/" or fullwidth
// "／"). Used by slash-variant generators. Returns NSNotFound if no
// slash anywhere.
static NSUInteger YTMUSCLastSlashPosition(NSString *s) {
    NSRange ascii = [s rangeOfString:@"/" options:NSBackwardsSearch];
    NSRange wide = [s rangeOfString:@"／" options:NSBackwardsSearch];
    if (ascii.location == NSNotFound && wide.location == NSNotFound) return NSNotFound;
    if (ascii.location == NSNotFound) return wide.location;
    if (wide.location == NSNotFound) return ascii.location;
    return MAX(ascii.location, wide.location);
}

+ (nullable YTMUScrobbleCleanedMeta *)slashLeftVariantForTrack:(NSString *)track
                                                        artist:(NSString *)artist
                                                         album:(NSString *)album {
    if (track.length == 0) return nil;
    NSString *phase1 = YTMUSCApplyRules(track, YTMUSCTrackRules());
    NSUInteger slashPos = YTMUSCLastSlashPosition(phase1);
    if (slashPos == NSNotFound) return nil;
    NSString *left = [[phase1 substringToIndex:slashPos]
                      stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (left.length < 2) return nil;
    YTMUScrobbleCleanedMeta *meta = [[YTMUScrobbleCleanedMeta alloc] init];
    meta.track = left;
    meta.artist = YTMUSCApplyRules(artist ?: @"", YTMUSCArtistRules());
    meta.album = YTMUSCApplyRules(album ?: @"", YTMUSCAlbumRules());
    return meta;
}

+ (nullable YTMUScrobbleCleanedMeta *)slashRightVariantForTrack:(NSString *)track
                                                         artist:(NSString *)artist
                                                          album:(NSString *)album {
    if (track.length == 0) return nil;
    NSString *phase1 = YTMUSCApplyRules(track, YTMUSCTrackRules());
    NSUInteger slashPos = YTMUSCLastSlashPosition(phase1);
    if (slashPos == NSNotFound) return nil;
    // "／" is 3 UTF-8 bytes but 1 unichar — substringFromIndex uses
    // unichar count, so +1 advances past the slash either way.
    NSString *right = [[phase1 substringFromIndex:slashPos + 1]
                       stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (right.length < 2) return nil;
    // "X / feat. Y" — right side IS a feat. credit, not a song title.
    // Skip; the primary candidate already carries that info.
    if (YTMUSCLooksLikeFeaturing(right)) return nil;
    YTMUScrobbleCleanedMeta *meta = [[YTMUScrobbleCleanedMeta alloc] init];
    meta.track = right;
    meta.artist = YTMUSCApplyRules(artist ?: @"", YTMUSCArtistRules());
    meta.album = YTMUSCApplyRules(album ?: @"", YTMUSCAlbumRules());
    return meta;
}

// Used only inside +subArtistsForArtist:. Whether `s` contains BOTH
// ASCII letters AND CJK characters — used to detect "English-CJK
// alias" artist fields like "Suzaku-朱雀-" / "Suzaku-朱雀" where the
// hyphen joins romanization to original-language name, and the
// hyphen-split halves are each a real artist alias on last.fm.
static BOOL YTMUSCArtistHasAsciiAndCJK(NSString *s) {
    BOOL ascii = NO, cjk = NO;
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')) ascii = YES;
        if ((c >= 0x3040 && c <= 0x309F) || (c >= 0x30A0 && c <= 0x30FF)
            || (c >= 0x4E00 && c <= 0x9FFF) || (c >= 0xAC00 && c <= 0xD7AF)) cjk = YES;
        if (ascii && cjk) return YES;
    }
    return NO;
}

+ (NSArray<NSString *> *)subArtistsForArtist:(NSString *)artist {
    if (artist.length == 0) return @[];
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    NSString *full = [artist stringByTrimmingCharactersInSet:
                      [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (full.length == 0) return @[];
    [out addObject:full];

    void (^tryAdd)(NSString *) = ^(NSString *raw) {
        NSString *p = [raw stringByTrimmingCharactersInSet:
                       [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        // Also trim leading/trailing hyphen leftovers from edge-junk
        // residue (e.g. "Suzaku" pulled from "Suzaku-朱雀-" — middle
        // empty token would be "" before trim, but a real piece like
        // "朱雀" might come with stray dashes after the split).
        p = [p stringByTrimmingCharactersInSet:
             [NSCharacterSet characterSetWithCharactersInString:@"-–— "]];
        if (p.length < 2) return;
        if ([p isEqualToString:full]) return;
        for (NSString *existing in out) {
            if ([existing caseInsensitiveCompare:p] == NSOrderedSame) return;
        }
        [out addObject:p];
    };

    // Step 1: normalize multi-character separators to a single sentinel
    // so we can use componentsSeparatedByCharactersInSet for splitting.
    // " feat. " " featuring " " ft. " " x " (with spaces, so we don't
    // accidentally split a letter "x" inside a word) all become "&".
    NSMutableString *prepped = [full mutableCopy];
    static NSArray<NSString *> *multiSeps;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Order matters: longer patterns first so " featuring " isn't
        // half-consumed by " feat " etc.
        multiSeps = @[@" featuring ", @" feat. ", @" feat ", @" ft. ",
                      @" ft ", @" with ", @" x "];
    });
    for (NSString *sep in multiSeps) {
        NSRange r;
        while ((r = [prepped rangeOfString:sep options:NSCaseInsensitiveSearch]).location != NSNotFound) {
            [prepped replaceCharactersInRange:r withString:@"&"];
        }
    }

    // Step 2: split on single-character separators. These are the
    // common collab/list joiners in JP/CJK YT Music artist fields.
    NSCharacterSet *sepSet = [NSCharacterSet characterSetWithCharactersInString:@"&×・·、,,"];
    NSArray *parts = [prepped componentsSeparatedByCharactersInSet:sepSet];
    for (NSString *raw in parts) tryAdd(raw);

    // Step 3: English-CJK alias on hyphen. Only when the artist string
    // mixes ASCII letters AND CJK characters do we split on `-` / `–` /
    // `—` — this conservatively avoids breaking ASCII names that
    // legitimately use hyphens ("Jay-Z", "AC-DC", "FKA-twigs").
    // Catches "Suzaku-朱雀" / "Suzaku-朱雀-" → exposes "Suzaku" alone
    // (3,313-listener canonical) instead of the orphan alias.
    //
    // CRITICAL: only ADD the ASCII half, NOT the CJK half. The CJK
    // side of an English-CJK alias is the original-language name and
    // almost always collides with an unrelated CJK artist on last.fm
    // (e.g. splitting "Suzaku-朱雀-" we get "朱雀" which is a 7,058-
    // listener traditional-music artist, NOTHING to do with Suzaku
    // the Vocaloid producer). Submitting to that collision would be
    // worse than submitting to the orphan alias.
    if (YTMUSCArtistHasAsciiAndCJK(full)) {
        NSCharacterSet *hyphens = [NSCharacterSet characterSetWithCharactersInString:@"-–—"];
        NSArray *hyphenParts = [full componentsSeparatedByCharactersInSet:hyphens];
        for (NSString *raw in hyphenParts) {
            NSString *p = [raw stringByTrimmingCharactersInSet:
                           [NSCharacterSet whitespaceAndNewlineCharacterSet]];
            p = [p stringByTrimmingCharactersInSet:
                 [NSCharacterSet characterSetWithCharactersInString:@"-–— "]];
            if (p.length < 2) continue;
            // Must be PURE ASCII (letters/digits/punctuation only).
            // Skip pure-CJK fragments and any still-mixed fragments.
            BOOL pureAscii = YES;
            for (NSUInteger i = 0; i < p.length; i++) {
                if ([p characterAtIndex:i] >= 128) {
                    pureAscii = NO;
                    break;
                }
            }
            if (!pureAscii) continue;
            tryAdd(p);
        }
    }

    return out;
}

+ (YTMUScrobbleCleanedMeta *)cleanTrack:(NSString *)track
                                 artist:(NSString *)artist
                                  album:(NSString *)album {
    YTMUScrobbleCleanedMeta *out = [[YTMUScrobbleCleanedMeta alloc] init];

    // First sweep: independent rule application on each field.
    NSString *cleanedArtist = YTMUSCApplyRules(artist ?: @"", YTMUSCArtistRules());
    NSString *cleanedTrack = YTMUSCApplyRules(track ?: @"", YTMUSCTrackRules());
    NSString *cleanedAlbum = YTMUSCApplyRules(album ?: @"", YTMUSCAlbumRules());

    // Second pass: if the artist field is now empty/generic, try to
    // split the track field. Run the per-field cleanup once more on
    // each side so the new artist also gets "Topic" / VEVO trimmed
    // and the new track loses any noise that was hiding behind the
    // artist segment.
    NSString *splitArtist = nil;
    NSString *splitTrack = nil;
    if (YTMUSCTrySplitTitle(cleanedTrack, cleanedArtist, &splitArtist, &splitTrack)) {
        cleanedArtist = YTMUSCApplyRules(splitArtist, YTMUSCArtistRules());
        cleanedTrack = YTMUSCApplyRules(splitTrack, YTMUSCTrackRules());
    }

    // Third pass: strip YT Music's "Title / Artist" / "Title /
    // Voicebank" appendage and "Title - Romaji" annotation. These
    // patterns appear hundreds of times in the user's library and
    // last.fm has no way to canonicalize them away on its end.
    cleanedTrack = YTMUSCStripSlashSuffix(cleanedTrack, cleanedArtist);
    cleanedTrack = YTMUSCStripRomajiSuffix(cleanedTrack);

    out.track = cleanedTrack;
    out.artist = cleanedArtist;
    out.album = cleanedAlbum;
    return out;
}

@end
