// M8: the normalizer feeds the first ~600 chars of the description to the
// LLM. Cutting at a raw UTF-16 index can split an emoji's surrogate pair,
// which makes the request body unserialisable (NSJSONSerialization returns
// nil) and the whole normalize silently fails for that song.
#import "YTMUTestKit.h"
#import "Lyrics/YTMULyricsTitleNormalizer.h"

@interface YTMULyricsTitleNormalizer (YTMUTesting)
- (NSString *)userPromptForInfo:(YTMULyricsSearchInfo *)info;
@end

static BOOL HasLoneSurrogate(NSString *s) {
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        if (CFStringIsSurrogateHighCharacter(c)) {
            if (i + 1 >= s.length || !CFStringIsSurrogateLowCharacter([s characterAtIndex:i + 1])) return YES;
            i++;
        } else if (CFStringIsSurrogateLowCharacter(c)) {
            return YES;
        }
    }
    return NO;
}

YTMU_TEST(Normalizer_prompt_neverSplitsSurrogatePairAtTruncation) {
    // 599 ASCII chars, then an emoji straddling UTF-16 index 599/600, then more.
    NSMutableString *desc = [NSMutableString string];
    while (desc.length < 599) [desc appendString:@"x"];
    [desc appendString:@"😀 tail text that gets cut"];
    YTMULyricsSearchInfo *info = [[YTMULyricsSearchInfo alloc] init];
    info.title = @"T"; info.artist = @"A"; info.shortDescription = desc;

    NSString *prompt = [[YTMULyricsTitleNormalizer sharedNormalizer] userPromptForInfo:info];
    YTMU_ASSERT(!HasLoneSurrogate(prompt), "prompt contains a lone surrogate");
    // and it must still serialise as JSON (what every provider does with it)
    NSData *json = [NSJSONSerialization dataWithJSONObject:@{@"input": prompt} options:0 error:nil];
    YTMU_ASSERT(json != nil, "prompt is not JSON-serialisable");
    // truncation still happened (we did not just stop truncating)
    YTMU_ASSERT([prompt rangeOfString:@"tail text that gets cut"].location == NSNotFound, "description was not truncated");
}

YTMU_TEST(Normalizer_prompt_shortDescriptionUntouched) {
    YTMULyricsSearchInfo *info = [[YTMULyricsSearchInfo alloc] init];
    info.title = @"T"; info.artist = @"A"; info.shortDescription = @"short 😀 description";
    NSString *prompt = [[YTMULyricsTitleNormalizer sharedNormalizer] userPromptForInfo:info];
    YTMU_ASSERT([prompt containsString:@"short 😀 description"], "short description must pass through intact");
}
