#import <Foundation/Foundation.h>
#import "YTMUScrobbleTypes.h"

NS_ASSUME_NONNULL_BEGIN

// Orchestrates Tier 1 → Tier 2 → Tier 3 of the scrobble normalization
// pipeline. The manager calls into this on every track change and
// the resolver mutates the same YTMUListen instance as results come
// back from the network — so submission paths that read `[listen
// bestTrack]` etc. automatically pick up whatever resolution stage
// has completed by the time they fire.
@interface YTMUScrobbleResolver : NSObject

+ (instancetype)sharedResolver;

// Tier 1 (synchronous, sub-millisecond). Runs the regex cleaner and
// writes `listen.cleaned*`. Safe to call before the broadcaster
// notification has even fully dispatched. Idempotent.
- (void)applyTier1ToListen:(YTMUListen *)listen;

// Tier 2 + Tier 3 (async). Reads `listen.cleaned*` (caller must have
// run Tier 1 first), kicks off last.fm/ListenBrainz lookups in
// parallel, and on miss + LLM availability falls through to the
// existing lyrics-side LLM normalizer. As each tier produces a
// canonical name, mutates the listen's `corrected*` / `*MBID`
// fields. No completion callback — submissions are time-driven and
// just read the listen's current state at fire time.
- (void)resolveAsyncForListen:(YTMUListen *)listen;

// Wipes both in-memory and persisted caches. Hooked into a future
// "clear caches" affordance; not in the v1 settings UI.
- (void)clearCaches;

@end

NS_ASSUME_NONNULL_END
