#import "YTMULyricsDescriptionExtractor.h"
#import "../Utils/NSBundle+YTMU.h"
#import "../Utils/YTMUPlistStore.h"
#import "../Utils/YTMUInflightCoalescer.h"

// Persistent storage layout:
//   $CACHES/YTMUltimate/DescriptionLyrics/<sha1(videoId)>.plist
// Plist keys:
//   v             : schema version (currently 1)
//   src_lines     : array of source-language lyric lines
//   lang          : ISO 639-1 of source lyrics, or ""
//   tr_lines      : array of translated lines (count==src_lines or empty)
//   tr_lang       : ISO 639-1 of translation, or ""
//   confidence    : double
//   raw_t         : raw input title (sanity-check on read)
//   raw_a         : raw input artist
//   failed_at     : (optional) epoch seconds of a parse/verify failure.
//                   Such an entry has empty src_lines and is honoured as
//                   a miss for YTMULDEFailureTTL, then retried.
//
// (An earlier failure blacklist in NSUserDefaults was removed;
// -clearCache still deletes its legacy key.)

static const NSInteger YTMULDESchemaVersion = 1;
static NSString *const YTMULDELegacyFailuresKey = @"YTMULDescriptionExtractFailures";

// How long a parse/verify failure is remembered before the LLM is asked
// again. Failures here are usually deterministic (the model keeps
// normalising punctuation the verifier rejects), so without this every
// play of such a song re-spent an LLM call.
static const NSTimeInterval YTMULDEFailureTTL = 6 * 60 * 60;

// Description blocks under this length almost never contain a real lyric
// section — typically uploader handle + one-liner + URL. Skip the AI call
// to save tokens on songs that can't possibly hit.
static const NSUInteger YTMULDEMinDescriptionLength = 200;

// Verification threshold: at least this fraction of the AI's returned
// lyric lines must appear verbatim in the original description before we
// trust the extraction. Anti-hallucination guard.
static const double YTMULDEVerifyMinRatio = 0.7;


static NSError *YTMULDEError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"YTMULyricsDescriptionExtractor"
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: message ?: YTMULocalized(@"LYRICS_ERROR_DESCRIPTION_EXTRACT", @"extract failed")}];
}

#pragma mark - YTMULyricsDescriptionExtraction

@implementation YTMULyricsDescriptionExtraction

- (instancetype)init {
    self = [super init];
    if (self) {
        _sourceLines = @[];
        _language = @"";
        _translatedLines = @[];
        _translationLanguage = @"";
        _confidence = 0.0;
    }
    return self;
}

@end

#pragma mark - YTMULyricsDescriptionExtractor

@interface YTMULyricsDescriptionExtractor ()
@property (nonatomic, strong) YTMUPlistStore *store;
// One AI call per videoId even when several refresh passes overlap.
@property (nonatomic, strong) YTMUInflightCoalescer<YTMULyricsDescriptionExtractorCompletion> *inflight;
@end

@implementation YTMULyricsDescriptionExtractor

+ (instancetype)sharedExtractor {
    static YTMULyricsDescriptionExtractor *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[self alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _store = [[YTMUPlistStore alloc] initWithSubdirectory:@"DescriptionLyrics" schemaVersion:YTMULDESchemaVersion];
        _inflight = [[YTMUInflightCoalescer alloc] init];
    }
    return self;
}

#pragma mark - Disk cache

// Kept as a seam for tests that inspect the on-disk record.
- (NSString *)filePathForVideoId:(NSString *)videoId {
    return [self.store pathForKey:videoId];
}

- (nullable NSDictionary *)readPlistForVideoId:(NSString *)videoId {
    return [self.store plistForKey:videoId];
}

- (void)writePlist:(NSDictionary *)dict forVideoId:(NSString *)videoId {
    [self.store writePlist:dict forKey:videoId];
}

- (YTMULyricsDescriptionExtraction *)extractionFromPlist:(NSDictionary *)dict {
    // Check elements, not just containers: a damaged plist must not hand a
    // non-string to appendString: downstream.
    NSArray *(^strings)(id) = ^NSArray *(id value) {
        if (![value isKindOfClass:[NSArray class]]) return @[];
        NSMutableArray *out = [NSMutableArray array];
        for (id item in (NSArray *)value) if ([item isKindOfClass:[NSString class]]) [out addObject:item];
        return out;
    };
    YTMULyricsDescriptionExtraction *e = [[YTMULyricsDescriptionExtraction alloc] init];
    e.sourceLines = strings(dict[@"src_lines"]);
    e.language = [dict[@"lang"] isKindOfClass:[NSString class]] ? dict[@"lang"] : @"";
    e.translatedLines = strings(dict[@"tr_lines"]);
    e.translationLanguage = [dict[@"tr_lang"] isKindOfClass:[NSString class]] ? dict[@"tr_lang"] : @"";
    e.confidence = [dict[@"confidence"] isKindOfClass:[NSNumber class]] ? [dict[@"confidence"] doubleValue] : 0.0;
    return e;
}

- (nullable YTMULyricsDescriptionExtraction *)cachedExtractionForInfo:(YTMULyricsSearchInfo *)info {
    NSDictionary *dict = [self readPlistForVideoId:info.videoId];
    if (!dict) return nil;
    // A remembered parse/verify failure is honoured as a miss until its TTL
    // runs out, then forgotten so the model gets another chance.
    id failedAt = dict[@"failed_at"];
    if ([failedAt isKindOfClass:[NSNumber class]]) {
        NSTimeInterval age = [[NSDate date] timeIntervalSince1970] - [failedAt doubleValue];
        if (age < 0 || age >= YTMULDEFailureTTL) return nil;
        return [[YTMULyricsDescriptionExtraction alloc] init];
    }
    YTMULyricsDescriptionExtraction *e = [self extractionFromPlist:dict];
    // Empty/null cache hits ARE meaningful — they record "we already
    // checked this videoId and there were no lyrics in the description".
    // We still return them so callers don't re-fire the AI request. The
    // provider treats empty sourceLines as a miss.
    return e;
}

#pragma mark - Prompts

static NSString *const YTMULDESystemPrompt =
@"You are a lyrics extraction assistant. Your only job is to recognize and pull verbatim song lyrics from a YouTube video description block. You will receive a description that the uploader wrote — sometimes it contains the full lyrics, sometimes only fragments, sometimes nothing.\n"
@"\n"
@"Strict rules — non-negotiable:\n"
@"1. Output only text that LITERALLY appears in the description. Never write, complete, paraphrase, translate, transliterate, romanize, regenerate, or fix anything. Copy character-for-character including kanji form, punctuation, full-width vs half-width, capitalization, spaces.\n"
@"2. If the description has no lyric block, return has_lyrics=false. A single line, a slogan, a hashtag list, a credit roll, a CC notice, a chord chart, or just URLs do NOT count as lyrics.\n"
@"3. Partial lyrics are still lyrics — return has_lyrics=true, set confidence to reflect completeness (e.g. only chorus → 0.4).\n"
@"4. If the description carries a side-by-side translation (very common for Japanese/Korean songs uploaded with 日中 or 日英 translation), extract both: source_lyrics in the original language, translation_lyrics in the second language. Each must be the same number of non-empty lines. If alignment is ambiguous, leave translation_lyrics empty.\n"
@"5. Strip from your output: uploader name, song credits (作詞:/作曲:/編曲:/Vocal:/Mix:), upload-date stamps, social links, hashtags, copyright notices, \"歌詞\"/\"Lyrics:\" headers themselves, store URLs, support links, OST/album info, mastering credits, video description boilerplate. Keep ONLY the actual lyric lines.\n"
@"6. Preserve the original line breaks. Do not collapse, merge, or expand stanzas. Skip blank lines between stanzas in your output (do not include them).\n"
@"7. Use ISO 639-1 codes for language fields (\"ja\", \"ko\", \"zh\", \"en\", \"fr\", ...).\n"
@"\n"
@"Output exactly this JSON shape, no markdown fences, no commentary:\n"
@"{\"has_lyrics\":false,\"language\":\"\",\"source_lyrics\":\"\",\"translation_lyrics\":\"\",\"translation_language\":\"\",\"confidence\":0.0}\n"
@"source_lyrics and translation_lyrics are plain strings with \\n separating lines (NOT arrays).";

- (NSString *)userPromptForInfo:(YTMULyricsSearchInfo *)info {
    NSMutableString *out = [NSMutableString string];
    [out appendFormat:@"video title: %@\n", info.title.length ? info.title : @"(empty)"];
    [out appendFormat:@"channel/uploader: %@\n", info.artist.length ? info.artist : @"(empty)"];
    [out appendString:@"\ndescription begin >>>\n"];
    [out appendString:info.shortDescription ?: @""];
    [out appendString:@"\n<<< description end\n"];
    // Mirror the json keyword in the user message — OpenAI's Responses
    // API gateway requires it when text.format=json_object even though
    // the system prompt also has it.
    [out appendString:@"\nReturn strict json only, schema as described.\n"];
    return out;
}

#pragma mark - JSON parsing

// Strip ```json…``` (any language tag) by walking characters. See the
// matching parser in YTMULyricsTitleNormalizer for the rationale —
// the older "find first newline" approach quietly failed when models
// emitted a fence with no newline after the language tag.
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
    // Greedy first { … last }
    NSRange open = [clean rangeOfString:@"{"];
    NSRange close = [clean rangeOfString:@"}" options:NSBackwardsSearch];
    if (open.location != NSNotFound && close.location != NSNotFound && close.location > open.location) {
        NSString *substr = [clean substringWithRange:NSMakeRange(open.location, close.location - open.location + 1)];
        NSData *substrData = [substr dataUsingEncoding:NSUTF8StringEncoding];
        id obj = substrData ? [NSJSONSerialization JSONObjectWithData:substrData options:0 error:nil] : nil;
        if ([obj isKindOfClass:[NSDictionary class]]) return obj;
    }
    // Brace-balanced extraction with string-literal awareness.
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

#pragma mark - Verification

// Normalize a line for "is this in the description" comparison: trim
// whitespace and fold full-width/half-width so 「いきる　」 and "いきる"
// match, but DON'T case-fold or strip punctuation — Japanese kanji vs
// hiragana etc. should NOT compare equal.
- (NSString *)verifyKeyForLine:(NSString *)line {
    NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!trimmed.length) return @"";
    NSMutableString *mutable = [trimmed mutableCopy];
    CFStringTransform((__bridge CFMutableStringRef)mutable, NULL, kCFStringTransformFullwidthHalfwidth, NO);
    NSRegularExpression *spaces = YTMULyricsCachedRegex(@"\\s+", 0);
    return [spaces stringByReplacingMatchesInString:mutable options:0 range:NSMakeRange(0, mutable.length) withTemplate:@" "];
}

- (BOOL)verifyLines:(NSArray<NSString *> *)candidateLines againstDescription:(NSString *)description {
    if (!candidateLines.count || !description.length) return NO;
    NSString *descKey = [self verifyKeyForLine:description];
    NSUInteger checked = 0;
    NSUInteger matched = 0;
    for (NSString *line in candidateLines) {
        NSString *key = [self verifyKeyForLine:line];
        if (key.length < 2) continue; // single-char interjections aren't reliable signal
        checked++;
        if ([descKey rangeOfString:key].location != NSNotFound) matched++;
    }
    if (checked == 0) return NO;
    double ratio = (double)matched / (double)checked;
    return ratio >= YTMULDEVerifyMinRatio;
}

#pragma mark - Build extraction

- (NSArray<NSString *> *)splitLyricsString:(NSString *)str {
    if (!str.length) return @[];
    NSArray<NSString *> *raw = [str componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    for (NSString *line in raw) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (trimmed.length) [out addObject:trimmed];
    }
    return out;
}

- (nullable YTMULyricsDescriptionExtraction *)extractionFromResponseDict:(NSDictionary *)dict
                                                              description:(NSString *)description {
    if (!dict) return nil;
    // `has_lyrics` is model output: it can be missing, JSON null (NSNull,
    // which does not respond to boolValue), or the wrong type. Only an
    // explicit false is a negative verdict; anything else means "let the
    // verified source_lyrics decide" so a malformed field can neither
    // crash us nor cache a bogus 30-day negative for a song whose
    // description really does carry the lyrics.
    id hasLyricsValue = dict[@"has_lyrics"];
    BOOL hasLyricsKnown = [hasLyricsValue isKindOfClass:[NSNumber class]] ||
                          [hasLyricsValue isKindOfClass:[NSString class]];
    BOOL hasLyrics = hasLyricsKnown ? [hasLyricsValue boolValue] : YES;
    if (!hasLyrics) {
        // Valid "no lyrics" verdict — return an empty extraction so we
        // can cache the negative result.
        YTMULyricsDescriptionExtraction *e = [[YTMULyricsDescriptionExtraction alloc] init];
        e.sourceLines = @[];
        e.translatedLines = @[];
        e.confidence = 0.0;
        return e;
    }

    NSString *sourceStr = [dict[@"source_lyrics"] isKindOfClass:[NSString class]] ? dict[@"source_lyrics"] : @"";
    NSArray<NSString *> *sourceLines = [self splitLyricsString:sourceStr];
    if (sourceLines.count < 2) return nil; // single-line "lyrics" is almost certainly garbage

    if (![self verifyLines:sourceLines againstDescription:description]) {
        return nil; // anti-hallucination: AI made up content that isn't in the description
    }

    NSString *translationStr = [dict[@"translation_lyrics"] isKindOfClass:[NSString class]] ? dict[@"translation_lyrics"] : @"";
    NSArray<NSString *> *translationLines = [self splitLyricsString:translationStr];
    // Only honor translation when alignment is exact — otherwise discard.
    // (Mismatched counts would render as offset bilingual text, which is
    // worse than no translation.)
    if (translationLines.count != sourceLines.count) translationLines = @[];

    YTMULyricsDescriptionExtraction *e = [[YTMULyricsDescriptionExtraction alloc] init];
    e.sourceLines = sourceLines;
    e.language = [dict[@"language"] isKindOfClass:[NSString class]] ? dict[@"language"] : @"";
    e.translatedLines = translationLines;
    e.translationLanguage = [dict[@"translation_language"] isKindOfClass:[NSString class]] ? dict[@"translation_language"] : @"";
    e.confidence = [dict[@"confidence"] respondsToSelector:@selector(doubleValue)] ? [dict[@"confidence"] doubleValue] : 0.5;
    return e;
}

#pragma mark - Public

- (void)extractForInfo:(YTMULyricsSearchInfo *)info
              provider:(id<YTMULLMCompletionProvider>)provider
          providerName:(NSString *)providerName
            completion:(YTMULyricsDescriptionExtractorCompletion)completion {
    if (!completion) return;
    NSString *videoId = info.videoId ?: @"";
    if (!provider || !videoId.length) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(nil, YTMULDEError(1, @"missing provider or videoId"));
        });
        return;
    }
    if (info.shortDescription.length < YTMULDEMinDescriptionLength) {
        // Description is too short to plausibly carry a lyric block.
        // Don't even bother with the AI — return an empty extraction so
        // the provider treats this as a normal miss.
        YTMULyricsLog(@"description extract skipped videoId=%@ — description too short (%lu chars)",
                      videoId, (unsigned long)info.shortDescription.length);
        dispatch_async(dispatch_get_main_queue(), ^{
            completion([[YTMULyricsDescriptionExtraction alloc] init], nil);
        });
        return;
    }

    YTMULyricsDescriptionExtraction *cached = [self cachedExtractionForInfo:info];
    if (cached) {
        YTMULyricsLog(@"description extract cache hit videoId=%@ lines=%lu translated=%lu",
                      videoId, (unsigned long)cached.sourceLines.count, (unsigned long)cached.translatedLines.count);
        dispatch_async(dispatch_get_main_queue(), ^{ completion(cached, nil); });
        return;
    }

    // In-flight dedup: same videoId can fire multiple refresh passes
    // (initial raw, then a normalize re-pass, plus YT metadata flickering)
    // — we want exactly one AI call per song.
    if (![self.inflight beginOrJoinKey:videoId completion:completion]) {
        YTMULyricsLog(@"description extract joined in-flight videoId=%@", videoId);
        return;
    }

    NSString *systemPrompt = YTMULDESystemPrompt;
    NSString *userPrompt = [self userPromptForInfo:info];
    YTMULyricsLog(@"description extract start videoId=%@ provider=%@ descLen=%lu",
                  videoId,
                  providerName ?: @"<unknown>",
                  (unsigned long)info.shortDescription.length);

    NSString *originalDescription = info.shortDescription ?: @"";
    NSString *originalTitle = info.title ?: @"";
    NSString *originalArtist = info.artist ?: @"";

    __weak typeof(self) weakSelf = self;
    [provider completeWithSystemPrompt:systemPrompt
                            userPrompt:userPrompt
                        expectJSONMode:YES
                            completion:^(NSString * _Nullable text, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            void (^fanout)(YTMULyricsDescriptionExtraction *, NSError *) = ^(YTMULyricsDescriptionExtraction *result, NSError *err) {
                for (YTMULyricsDescriptionExtractorCompletion cb in [weakSelf.inflight takeCompletionsForKey:videoId]) cb(result, err);
            };

            if (error) {
                YTMULyricsLog(@"description extract network/HTTP failed videoId=%@ err=%@",
                              videoId, error.localizedDescription);
                fanout(nil, error);
                return;
            }

            NSDictionary *json = [weakSelf parseJSON:text];
            YTMULyricsDescriptionExtraction *result = [weakSelf extractionFromResponseDict:json
                                                                                description:originalDescription];
            if (!result) {
                YTMULyricsLog(@"description extract parse/verify failed videoId=%@ raw=%@",
                              videoId,
                              text.length > 200 ? [text substringToIndex:200] : (text ?: @""));
                // Remember the failure for a while: the next refresh of this
                // song (and the normalize re-pass right behind it) must not
                // spend another LLM call on what is almost always the same
                // deterministic verify miss.
                [weakSelf writePlist:@{
                    @"v":          @(YTMULDESchemaVersion),
                    @"src_lines":  @[],
                    @"tr_lines":   @[],
                    @"failed_at":  @([[NSDate date] timeIntervalSince1970]),
                    @"raw_t":      originalTitle,
                    @"raw_a":      originalArtist,
                } forVideoId:videoId];
                fanout(nil, YTMULDEError(3, @"could not parse or verify extract response"));
                return;
            }

            // Persist (negative results too — they save tokens on later refreshes).
            NSDictionary *plist = @{
                @"v":          @(YTMULDESchemaVersion),
                @"src_lines":  result.sourceLines ?: @[],
                @"lang":       result.language ?: @"",
                @"tr_lines":   result.translatedLines ?: @[],
                @"tr_lang":    result.translationLanguage ?: @"",
                @"confidence": @(result.confidence),
                @"raw_t":      originalTitle,
                @"raw_a":      originalArtist,
            };
            [weakSelf writePlist:plist forVideoId:videoId];
            YTMULyricsLog(@"description extract success videoId=%@ lines=%lu translated=%lu lang=%@ tr_lang=%@ conf=%.2f",
                          videoId,
                          (unsigned long)result.sourceLines.count,
                          (unsigned long)result.translatedLines.count,
                          result.language,
                          result.translationLanguage,
                          result.confidence);
            fanout(result, nil);
        });
    }];
}

- (void)clearCache {
    [self.store removeAll];
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:YTMULDELegacyFailuresKey];
}

@end
