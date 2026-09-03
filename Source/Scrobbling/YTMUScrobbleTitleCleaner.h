#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Synchronous output of the Tier 1 regex pipeline. The three fields
// are always non-nil but may equal the input if nothing was stripped.
@interface YTMUScrobbleCleanedMeta : NSObject
@property (nonatomic, copy) NSString *track;
@property (nonatomic, copy) NSString *artist;
@property (nonatomic, copy) NSString *album;
@end

// Pure-static utility. Strips YouTube/YT-Music platform noise from
// track/artist/album strings before they get sent to last.fm and
// ListenBrainz. Design notes:
//
//   - "Platform noise" = [Official Music Video] / (Audio) / | Topic
//     etc. — wrapper text that indicates how the upload was framed
//     rather than the song itself.
//   - "Recording-version markers" — (Live) (Remaster) (Acoustic)
//     (Slowed + Reverb) etc. — are PRESERVED. Those usually do
//     correspond to a distinct release on the canonical service,
//     and collapsing them would mis-attribute listens.
//   - When the artist field is empty / the YouTube auto-channel
//     "X - Topic" / equal to a generic channel name, the cleaner
//     also tries to split "Artist – Title" out of the track string.
//
// Rule order matters; rules are applied sequentially via
// NSRegularExpression. References:
//   - pano-scrobbler MetadataUtils.kt (Kotlin port of WebScrobbler
//     filter rules)
//   - last.fm's own canonical-name conventions for English/CJK titles
@interface YTMUScrobbleTitleCleaner : NSObject

+ (YTMUScrobbleCleanedMeta *)cleanTrack:(nullable NSString *)track
                                 artist:(nullable NSString *)artist
                                  album:(nullable NSString *)album;

// Generate a romaji-preferring alternate candidate. last.fm's canonical
// entry for a Vocaloid/JP track is sometimes the ROMAJI form (e.g.
// tosho_aTe's "Shizume Chiku Zensen (feat. Nurse Robot_Type T)" has
// 350 listeners while the CJK form has none), and sometimes the CJK
// form (e.g. MiMi's "海辺の電話ボックス" has 355 listeners while romaji
// has 3). Without trying both, we'd lose half the canonical matches.
//
// Returns nil if the input track doesn't have a "CJK - Romaji" split
// (so no alternate variant is meaningful). The returned meta has its
// .track set to the romaji side; .artist / .album are still the
// rule-cleaned versions of the inputs (no romaji preference for
// artist field — artist canonicalization is artist-search's job).
+ (nullable YTMUScrobbleCleanedMeta *)romajiVariantForTrack:(nullable NSString *)track
                                                     artist:(nullable NSString *)artist
                                                      album:(nullable NSString *)album;

// Generate slash-split alternate candidates. When the track title has
// "X / Y" structure and the Tier 1 cleaner didn't recognize Y as an
// artist name or known voicebank, we don't strip it — leaving the
// full "X / Y" form. But last.fm often has BOTH "X / Y" and a cleaner
// "X" entry, with very different listener counts. Example: rinri's
// "終着 / 鳴花ヒメ" = 23 listeners, while "終着" alone = 43 listeners
// (43 > 23 because 鳴花ヒメ is a CeVIO voicebank not in our list, so
// uploaders splitting the same song differently caused the fragmented
// entries).
//
// Returns nil if the input has no slash. Otherwise returns the LEFT
// (or RIGHT) side as a track candidate. Caller search-tries each and
// picks whichever variant has the highest listener count.
+ (nullable YTMUScrobbleCleanedMeta *)slashLeftVariantForTrack:(nullable NSString *)track
                                                        artist:(nullable NSString *)artist
                                                         album:(nullable NSString *)album;

+ (nullable YTMUScrobbleCleanedMeta *)slashRightVariantForTrack:(nullable NSString *)track
                                                         artist:(nullable NSString *)artist
                                                          album:(nullable NSString *)album;

// Generate sub-artist candidates for collaboration credits. YT Music's
// artist field often joins multiple artists ("zuki & 初音ミク",
// "PIKASONIC & Tatsunoshin", "Aiobahn × 牧野由依"). last.fm's canonical
// entry, however, is frequently filed under JUST ONE of them (e.g.
// "Zuki" alone owns "一度でいいから頭を撫でて" — 81 listeners, while
// the joint artist orphans to 0). Returns an ordered array starting
// with the FULL input followed by each sub-artist split on common
// separators (& × ・ 、 , and " feat./ft./featuring/x " variants).
// Returns just [@""] (or empty) if input is empty.
+ (NSArray<NSString *> *)subArtistsForArtist:(nullable NSString *)artist;

@end


// Artist name folded for "is this the same artist" comparisons: lowercase,
// separator variants (× ・ · 、 ,) mapped to "&", whitespace removed. Shared
// by the cleaner's slash-suffix logic and the resolver's match rules.
NSString *YTMUScrobbleNormalizeArtistForCompare(NSString *_Nullable artist);

NS_ASSUME_NONNULL_END
