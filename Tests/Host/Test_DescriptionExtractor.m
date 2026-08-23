// H3: the description extractor reads LLM JSON; `has_lyrics` may arrive as
// null or as the wrong type. Must not crash, must not cache a bogus
// negative for a description that visibly contains the lyrics.
#import "YTMUTestKit.h"
#import "YTMUTestSettings.h"
#import "YTMUTestFakeLLM.h"
#import "Lyrics/YTMULyricsDescriptionExtractor.h"

static NSString *LongDescription(void) {
    // > 200 chars (YTMULDEMinDescriptionLength) with a verbatim lyric block.
    NSMutableString *d = [NSMutableString string];
    [d appendString:@"Official audio. Credits: music by A, words by B. Thanks for listening!\n"];
    [d appendString:@"Follow us everywhere, links in the channel. This line is filler so the block is long enough.\n"];
    [d appendString:@"More filler text to clear the minimum description length threshold used by the extractor.\n\n"];
    [d appendString:@"Lyrics:\nfirst line of the song\nsecond line of the song\nthird line of the song\nfourth line of the song\n"];
    return d;
}

static YTMULyricsSearchInfo *Info(NSString *videoId) {
    YTMULyricsSearchInfo *info = [[YTMULyricsSearchInfo alloc] init];
    info.videoId = videoId; info.title = @"T"; info.artist = @"A";
    info.shortDescription = LongDescription();
    return info;
}

static YTMULyricsDescriptionExtraction *Run(YTMULyricsSearchInfo *info, YTMUTestFakeLLM *llm, NSError **errOut) {
    __block YTMULyricsDescriptionExtraction *got = nil; __block NSError *err = nil; __block BOOL done = NO;
    [[YTMULyricsDescriptionExtractor sharedExtractor] extractForInfo:info provider:llm providerName:@"fake"
        completion:^(YTMULyricsDescriptionExtraction *e, NSError *error) { got = e; err = error; done = YES; }];
    YTMU_ASSERT(YTMUTestWaitUntil(5, ^BOOL{ return done; }), "extractor never completed");
    if (errOut) *errOut = err;
    return got;
}

YTMU_TEST(Extractor_hasLyricsNull_doesNotCrash_andUsesSourceLyrics) {
    YTMUTestFakeLLM *llm = [[YTMUTestFakeLLM alloc] init];
    llm.responseText = @"{\"has_lyrics\":null,\"source_lyrics\":\"first line of the song\\nsecond line of the song\\nthird line of the song\",\"language\":\"en\",\"confidence\":0.8}";
    NSError *err = nil;
    YTMULyricsDescriptionExtraction *e = Run(Info(@"h3-null-a"), llm, &err);
    YTMU_ASSERT(err == nil, "unexpected error %@", err);
    // null has_lyrics is "unknown" — the verified source_lyrics decide.
    YTMU_ASSERT_EQ_INT(e.sourceLines.count, 3);
    YTMU_ASSERT_EQ_STR(e.sourceLines.firstObject, @"first line of the song");
}

YTMU_TEST(Extractor_hasLyricsWrongType_doesNotCrash) {
    YTMUTestFakeLLM *llm = [[YTMUTestFakeLLM alloc] init];
    llm.responseText = @"{\"has_lyrics\":{\"oops\":1},\"source_lyrics\":\"\",\"confidence\":0.1}";
    NSError *err = nil;
    YTMULyricsDescriptionExtraction *e = Run(Info(@"h3-null-b"), llm, &err);
    // No usable lines and no explicit false → a parse failure (nil, error),
    // not a cached negative and not a crash.
    YTMU_ASSERT(e == nil, "expected nil extraction, got %lu lines", (unsigned long)e.sourceLines.count);
    YTMU_ASSERT(err != nil, "expected a parse error");
}

YTMU_TEST(Extractor_hasLyricsFalse_stillCachesNegative) {
    YTMUTestFakeLLM *llm = [[YTMUTestFakeLLM alloc] init];
    llm.responseText = @"{\"has_lyrics\":false,\"source_lyrics\":\"\",\"confidence\":0.9}";
    NSError *err = nil;
    YTMULyricsDescriptionExtraction *e = Run(Info(@"h3-false"), llm, &err);
    YTMU_ASSERT(err == nil, "unexpected error %@", err);
    YTMU_ASSERT(e != nil && e.sourceLines.count == 0, "expected an empty (negative) extraction");
    // Second call must be served from cache: the fake LLM is not hit again.
    NSUInteger calls = llm.callCount;
    YTMU_ASSERT(YTMUTestWaitUntil(1, ^BOOL{ return [[YTMULyricsDescriptionExtractor sharedExtractor] cachedExtractionForInfo:Info(@"h3-false")] != nil; }),
                "negative result was not persisted");
    (void)Run(Info(@"h3-false"), llm, &err);
    YTMU_ASSERT_EQ_INT(llm.callCount, calls);
}

YTMU_TEST(Extractor_hallucinatedLines_rejected) {
    YTMUTestFakeLLM *llm = [[YTMUTestFakeLLM alloc] init];
    llm.responseText = @"{\"has_lyrics\":true,\"source_lyrics\":\"this is not in the description\\nneither is this\\nnor this\",\"confidence\":0.9}";
    NSError *err = nil;
    YTMULyricsDescriptionExtraction *e = Run(Info(@"h3-halluc"), llm, &err);
    YTMU_ASSERT(e == nil, "anti-hallucination verify should reject");
    YTMU_ASSERT(err != nil, "expected verify error");
}

// M1: a parse/verify failure is remembered (TTL) so the LLM is not
// re-asked on every play, and is forgotten once the TTL passes.
@interface YTMULyricsDescriptionExtractor (YTMUTesting)
- (NSString *)filePathForVideoId:(NSString *)videoId;
@end

YTMU_TEST(Extractor_verifyFailure_isRememberedThenForgotten) {
    YTMUTestFakeLLM *llm = [[YTMUTestFakeLLM alloc] init];
    llm.responseText = @"{\"has_lyrics\":true,\"source_lyrics\":\"made up line one\\nmade up line two\\nmade up line three\",\"confidence\":0.9}";
    NSError *err = nil;
    YTMULyricsSearchInfo *info = Info(@"h-neg-ttl");
    YTMU_ASSERT(Run(info, llm, &err) == nil && err != nil, "first call should fail verification");
    YTMU_ASSERT_EQ_INT(llm.callCount, 1);
    // the failure record must reach disk
    NSString *path = [[YTMULyricsDescriptionExtractor sharedExtractor] filePathForVideoId:info.videoId];
    YTMU_ASSERT(YTMUTestWaitUntil(3, ^BOOL{ return [[NSFileManager defaultManager] fileExistsAtPath:path]; }), "failure not persisted");

    // Second call: served as a miss from the failure record, LLM untouched.
    YTMULyricsDescriptionExtraction *e = Run(info, llm, &err);
    YTMU_ASSERT(e != nil && e.sourceLines.count == 0 && err == nil, "expected a cached negative, got e=%@ err=%@", e, err);
    YTMU_ASSERT_EQ_INT(llm.callCount, 1);

    // Age the record past the TTL: next call must ask the LLM again.
    NSMutableDictionary *plist = [[NSDictionary dictionaryWithContentsOfFile:path] mutableCopy];
    plist[@"failed_at"] = @([[NSDate date] timeIntervalSince1970] - 7 * 60 * 60);
    [plist writeToFile:path atomically:YES];
    (void)Run(info, llm, &err);
    YTMU_ASSERT_EQ_INT(llm.callCount, 2);
}

// L12: a damaged plist with non-string line entries must not surface
// non-strings (the provider appends them to an NSMutableString).
YTMU_TEST(Extractor_corruptedPlist_nonStringLinesAreDropped) {
    YTMULyricsSearchInfo *info = Info(@"h-corrupt");
    NSString *path = [[YTMULyricsDescriptionExtractor sharedExtractor] filePathForVideoId:info.videoId];
    [[NSFileManager defaultManager] createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    [@{@"v": @1, @"src_lines": @[@"real line", @42, @{@"x": @1}, @"another real line"], @"tr_lines": @[@7], @"confidence": @"not a number"}
        writeToFile:path atomically:YES];
    YTMULyricsDescriptionExtraction *e = [[YTMULyricsDescriptionExtractor sharedExtractor] cachedExtractionForInfo:info];
    YTMU_ASSERT(e != nil, "cached entry should still load");
    YTMU_ASSERT_EQ_INT(e.sourceLines.count, 2);
    YTMU_ASSERT_EQ_INT(e.translatedLines.count, 0);
    for (id line in e.sourceLines) YTMU_ASSERT([line isKindOfClass:[NSString class]], "non-string leaked");
}
