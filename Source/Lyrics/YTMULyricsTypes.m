#import "YTMULyricsTypes.h"

NSString *const YTMULyricsSourceYTMusic = @"YTMusic";
NSString *const YTMULyricsSourceLRCLib = @"LRCLIB";
NSString *const YTMULyricsSourceNetEase = @"NetEase";
NSString *const YTMULyricsSourceMusixMatch = @"Musixmatch";
NSString *const YTMULyricsSourceGenius = @"Genius";
NSString *const YTMULyricsSourceDescription = @"Description";

NSString *const YTMULyricsDidUpdateNotification = @"YTMULyricsDidUpdateNotification";
NSString *const YTMULyricsStateDidChangeNotification = @"YTMULyricsStateDidChangeNotification";
NSString *const YTMULyricsSettingsDidChangeNotification = @"YTMULyricsSettingsDidChangeNotification";
NSString *const YTMULyricsSettingChangedKey = @"key";

@implementation YTMULyricLine

+ (BOOL)supportsSecureCoding {
    return YES;
}

+ (instancetype)lineWithTime:(NSString *)time
                    timeInMs:(NSTimeInterval)timeInMs
                  durationMs:(NSTimeInterval)durationMs
                        text:(NSString *)text {
    YTMULyricLine *line = [[self alloc] init];
    line.time = time ?: @"";
    line.timeInMs = timeInMs;
    line.durationMs = durationMs;
    line.text = text ?: @"";
    line.romanizedText = @"";
    return line;
}

- (id)copyWithZone:(NSZone *)zone {
    YTMULyricLine *copy = [[[self class] allocWithZone:zone] init];
    copy.time = self.time ?: @"";
    copy.timeInMs = self.timeInMs;
    copy.durationMs = self.durationMs;
    copy.text = self.text ?: @"";
    copy.romanizedText = self.romanizedText ?: @"";
    return copy;
}

- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeObject:self.time ?: @"" forKey:@"time"];
    [coder encodeDouble:self.timeInMs forKey:@"timeInMs"];
    [coder encodeDouble:self.durationMs forKey:@"durationMs"];
    [coder encodeObject:self.text ?: @"" forKey:@"text"];
    [coder encodeObject:self.romanizedText ?: @"" forKey:@"romanizedText"];
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super init];
    if (self) {
        _time = [coder decodeObjectOfClass:[NSString class] forKey:@"time"] ?: @"";
        _timeInMs = [coder decodeDoubleForKey:@"timeInMs"];
        _durationMs = [coder decodeDoubleForKey:@"durationMs"];
        _text = [coder decodeObjectOfClass:[NSString class] forKey:@"text"] ?: @"";
        _romanizedText = [coder decodeObjectOfClass:[NSString class] forKey:@"romanizedText"] ?: @"";
    }
    return self;
}

@end

@implementation YTMULyricsResult

+ (BOOL)supportsSecureCoding {
    return YES;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _sourceName = @"";
        _title = @"";
        _artists = @[];
        _plainLyrics = @"";
        _lines = @[];
        _romanizedLineTexts = @[];
        _officialTranslatedLines = @[];
        _officialTranslationLanguage = @"";
        _officialTranslationProvider = @"";
    }
    return self;
}

- (id)copyWithZone:(NSZone *)zone {
    YTMULyricsResult *copy = [[[self class] allocWithZone:zone] init];
    copy.sourceName = self.sourceName ?: @"";
    copy.title = self.title ?: @"";
    copy.artists = [[NSArray alloc] initWithArray:self.artists ?: @[] copyItems:YES];
    copy.plainLyrics = self.plainLyrics ?: @"";
    copy.lines = [[NSArray alloc] initWithArray:self.lines ?: @[] copyItems:YES];
    copy.romanizedLineTexts = [self.romanizedLineTexts copy] ?: @[];
    copy.officialTranslatedLines = [self.officialTranslatedLines copy] ?: @[];
    copy.officialTranslationLanguage = self.officialTranslationLanguage ?: @"";
    copy.officialTranslationProvider = self.officialTranslationProvider ?: @"";
    copy.duration = self.duration;
    copy.inexact = self.inexact;
    return copy;
}

- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeObject:self.sourceName ?: @"" forKey:@"sourceName"];
    [coder encodeObject:self.title ?: @"" forKey:@"title"];
    [coder encodeObject:self.artists ?: @[] forKey:@"artists"];
    [coder encodeObject:self.plainLyrics ?: @"" forKey:@"plainLyrics"];
    [coder encodeObject:self.lines ?: @[] forKey:@"lines"];
    [coder encodeObject:self.romanizedLineTexts ?: @[] forKey:@"romanizedLineTexts"];
    [coder encodeObject:self.officialTranslatedLines ?: @[] forKey:@"officialTranslatedLines"];
    [coder encodeObject:self.officialTranslationLanguage ?: @"" forKey:@"officialTranslationLanguage"];
    [coder encodeObject:self.officialTranslationProvider ?: @"" forKey:@"officialTranslationProvider"];
    [coder encodeDouble:self.duration forKey:@"duration"];
    [coder encodeBool:self.inexact forKey:@"inexact"];
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [self init];
    if (self) {
        NSSet *stringArrayClasses = [NSSet setWithObjects:[NSArray class], [NSString class], nil];
        NSSet *lineArrayClasses = [NSSet setWithObjects:[NSArray class], [YTMULyricLine class], nil];
        _sourceName = [coder decodeObjectOfClass:[NSString class] forKey:@"sourceName"] ?: @"";
        _title = [coder decodeObjectOfClass:[NSString class] forKey:@"title"] ?: @"";
        _artists = [coder decodeObjectOfClasses:stringArrayClasses forKey:@"artists"] ?: @[];
        _plainLyrics = [coder decodeObjectOfClass:[NSString class] forKey:@"plainLyrics"] ?: @"";
        _lines = [coder decodeObjectOfClasses:lineArrayClasses forKey:@"lines"] ?: @[];
        _romanizedLineTexts = [coder decodeObjectOfClasses:stringArrayClasses forKey:@"romanizedLineTexts"] ?: @[];
        _officialTranslatedLines = [coder decodeObjectOfClasses:stringArrayClasses forKey:@"officialTranslatedLines"] ?: @[];
        _officialTranslationLanguage = [coder decodeObjectOfClass:[NSString class] forKey:@"officialTranslationLanguage"] ?: @"";
        _officialTranslationProvider = [coder decodeObjectOfClass:[NSString class] forKey:@"officialTranslationProvider"] ?: @"";
        _duration = [coder decodeDoubleForKey:@"duration"];
        _inexact = [coder decodeBoolForKey:@"inexact"];
    }
    return self;
}

- (NSArray<NSString *> *)lineTexts {
    if ([self isSynced]) {
        NSMutableArray *texts = [NSMutableArray arrayWithCapacity:self.lines.count];
        for (YTMULyricLine *line in self.lines) {
            [texts addObject:line.text ?: @""];
        }
        return texts;
    }

    NSArray *raw = [self.plainLyrics componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    NSMutableArray *texts = [NSMutableArray arrayWithCapacity:raw.count];
    for (NSString *line in raw) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (trimmed.length) [texts addObject:trimmed];
    }
    return texts;
}

- (BOOL)hasText {
    if (self.plainLyrics.length) return YES;
    for (YTMULyricLine *line in self.lines) {
        if ([line.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].length) return YES;
    }
    return NO;
}

- (BOOL)isSynced {
    return self.lines.count > 0;
}

@end

@implementation YTMULyricsSearchInfo

- (instancetype)init {
    self = [super init];
    if (self) {
        _videoId = @"";
        _title = @"";
        _alternativeTitle = @"";
        _artist = @"";
        _album = @"";
        _tags = @[];
        _shortDescription = @"";
    }
    return self;
}

- (id)copyWithZone:(NSZone *)zone {
    YTMULyricsSearchInfo *copy = [[[self class] allocWithZone:zone] init];
    copy.videoId = self.videoId ?: @"";
    copy.title = self.title ?: @"";
    copy.alternativeTitle = self.alternativeTitle ?: @"";
    copy.artist = self.artist ?: @"";
    copy.album = self.album ?: @"";
    copy.duration = self.duration;
    copy.tags = [self.tags copy] ?: @[];
    copy.shortDescription = self.shortDescription ?: @"";
    return copy;
}

@end

static NSDictionary *YTMULyricsSettingsDictionary(void) {
    return [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"YTMUltimate"] ?: @{};
}

BOOL YTMULyricsDebugLoggingEnabled(void) {
    id value = YTMULyricsSettingsDictionary()[@"translationDebugLogs"];
    return value == nil ? NO : [value boolValue];
}

void YTMULyricsLogImpl(NSString *format, ...) {
    if (!YTMULyricsDebugLoggingEnabled() || !format.length) return;

    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSLog(@"[YTMULyrics] %@", message);
}

NSString *YTMULyricsSettingsString(NSString *key, NSString *fallback) {
    id value = YTMULyricsSettingsDictionary()[key];
    if ([value isKindOfClass:[NSString class]] && [(NSString *)value length]) return value;
    return fallback ?: @"";
}

BOOL YTMULyricsSettingsBool(NSString *key, BOOL fallback) {
    id value = YTMULyricsSettingsDictionary()[key];
    return value == nil ? fallback : [value boolValue];
}

NSInteger YTMULyricsSettingsInteger(NSString *key, NSInteger fallback) {
    id value = YTMULyricsSettingsDictionary()[key];
    return value == nil ? fallback : [value integerValue];
}

void YTMULyricsSetDefault(NSMutableDictionary *dict, NSString *key, id value) {
    if (dict[key] == nil && key.length && value) dict[key] = value;
}

NSInteger YTMULyricsClampTimingOffsetMs(NSInteger value) {
    return MIN(10000, MAX(-10000, value));
}

static NSMutableDictionary *YTMULyricsMutableSettings(void) {
    return [NSMutableDictionary dictionaryWithDictionary:YTMULyricsSettingsDictionary()];
}

static NSMutableDictionary *YTMULyricsMutableTimingOffsetsFromSettings(NSDictionary *settings) {
    NSDictionary *stored = [settings[@"lyricsTimingOffsets"] isKindOfClass:[NSDictionary class]] ? settings[@"lyricsTimingOffsets"] : @{};
    return [NSMutableDictionary dictionaryWithDictionary:stored];
}

static void YTMULyricsSaveSettings(NSMutableDictionary *settings, BOOL notify, NSString *key) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setObject:settings ?: @{} forKey:@"YTMUltimate"];
    [defaults synchronize];
    if (notify && key.length) {
        [[NSNotificationCenter defaultCenter] postNotificationName:YTMULyricsSettingsDidChangeNotification
                                                            object:nil
                                                          userInfo:@{YTMULyricsSettingChangedKey: key}];
    }
}

NSString *YTMULyricsTimingOffsetKeyForInfo(YTMULyricsSearchInfo *info) {
    NSString *videoId = [info.videoId stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (videoId.length) return [@"video:" stringByAppendingString:videoId];

    NSString *titleKey = YTMULyricsCompactString(info.title ?: @"");
    NSString *artistKey = YTMULyricsCompactString(info.artist ?: @"");
    NSInteger duration = (NSInteger)llround(info.duration > 0 ? info.duration : 0);
    if (!titleKey.length && !artistKey.length) return @"";
    return [NSString stringWithFormat:@"song:%@:%@:%ld", titleKey, artistKey, (long)duration];
}

NSInteger YTMULyricsTimingOffsetForKey(NSString *key) {
    if (!key.length) return 0;
    NSDictionary *settings = YTMULyricsSettingsDictionary();
    NSDictionary *offsets = [settings[@"lyricsTimingOffsets"] isKindOfClass:[NSDictionary class]] ? settings[@"lyricsTimingOffsets"] : @{};
    id value = offsets[key];
    return [value respondsToSelector:@selector(integerValue)] ? YTMULyricsClampTimingOffsetMs([value integerValue]) : 0;
}

NSInteger YTMULyricsCurrentTimingOffsetForKey(NSString *key) {
    NSDictionary *settings = YTMULyricsSettingsDictionary();
    NSString *activeKey = [settings[@"lyricsTimingOffsetActiveKey"] isKindOfClass:[NSString class]] ? settings[@"lyricsTimingOffsetActiveKey"] : @"";
    if (key.length && [activeKey isEqualToString:key]) {
        id value = settings[@"lyricsTimingOffsetMs"];
        return [value respondsToSelector:@selector(integerValue)] ? YTMULyricsClampTimingOffsetMs([value integerValue]) : 0;
    }
    return YTMULyricsTimingOffsetForKey(key);
}

void YTMULyricsActivateTimingOffsetForInfo(YTMULyricsSearchInfo *info, BOOL notify) {
    NSString *key = YTMULyricsTimingOffsetKeyForInfo(info);
    NSInteger offset = YTMULyricsTimingOffsetForKey(key);
    NSMutableDictionary *settings = YTMULyricsMutableSettings();
    settings[@"lyricsTimingOffsetActiveKey"] = key ?: @"";
    settings[@"lyricsTimingOffsetMs"] = @(offset);
    YTMULyricsSaveSettings(settings, notify, @"lyricsTimingOffsetMs");
}

void YTMULyricsSetTimingOffsetForKey(NSString *key, NSInteger value, BOOL notify) {
    NSInteger clamped = YTMULyricsClampTimingOffsetMs(value);
    NSMutableDictionary *settings = YTMULyricsMutableSettings();
    NSMutableDictionary *offsets = YTMULyricsMutableTimingOffsetsFromSettings(settings);
    NSString *activeKey = key.length ? key : ([settings[@"lyricsTimingOffsetActiveKey"] isKindOfClass:[NSString class]] ? settings[@"lyricsTimingOffsetActiveKey"] : @"");

    if (activeKey.length) {
        if (clamped == 0) {
            [offsets removeObjectForKey:activeKey];
        } else {
            offsets[activeKey] = @(clamped);
        }
        while (offsets.count > 512) {
            NSString *drop = nil;
            for (NSString *candidate in offsets.allKeys) {
                if (![candidate isEqualToString:activeKey]) {
                    drop = candidate;
                    break;
                }
            }
            if (!drop.length) break;
            [offsets removeObjectForKey:drop];
        }
    }

    settings[@"lyricsTimingOffsets"] = offsets;
    settings[@"lyricsTimingOffsetActiveKey"] = activeKey ?: @"";
    settings[@"lyricsTimingOffsetMs"] = @(clamped);
    YTMULyricsSaveSettings(settings, notify, @"lyricsTimingOffsetMs");
}

NSRegularExpression *YTMULyricsCachedRegex(NSString *pattern, NSRegularExpressionOptions options) {
    static NSCache<NSString *, NSRegularExpression *> *cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ cache = [[NSCache alloc] init]; });
    NSString *key = [NSString stringWithFormat:@"%lu|%@", (unsigned long)options, pattern];
    NSRegularExpression *regex = [cache objectForKey:key];
    if (regex) return regex;
    regex = [NSRegularExpression regularExpressionWithPattern:pattern options:options error:nil];
    if (regex) [cache setObject:regex forKey:key];
    return regex;
}

BOOL YTMULyricsRegexMatches(NSString *value, NSString *pattern, NSRegularExpressionOptions options) {
    if (!value.length) return NO;
    NSRegularExpression *regex = YTMULyricsCachedRegex(pattern, options);
    return [regex firstMatchInString:value options:0 range:NSMakeRange(0, value.length)] != nil;
}

static NSString *YTMULyricsCollapseWhitespace(NSString *value) {
    return [YTMULyricsCachedRegex(@"\\s+", 0) stringByReplacingMatchesInString:value options:0 range:NSMakeRange(0, value.length) withTemplate:@" "];
}

NSString *YTMULyricsNormalizeLoose(NSString *value) {
    if (!value.length) return @"";
    NSMutableString *mutable = [[value stringByFoldingWithOptions:NSWidthInsensitiveSearch | NSCaseInsensitiveSearch
                                                           locale:[NSLocale currentLocale]] mutableCopy];
    CFStringTransform((__bridge CFMutableStringRef)mutable, NULL, kCFStringTransformFullwidthHalfwidth, NO);
    CFStringTransform((__bridge CFMutableStringRef)mutable, NULL, kCFStringTransformStripCombiningMarks, NO);
    NSString *lower = [mutable.lowercaseString stringByReplacingOccurrencesOfString:@"_" withString:@" "];
    NSString *collapsed = YTMULyricsCollapseWhitespace(lower);
    return [collapsed stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

NSString *YTMULyricsCompactString(NSString *value) {
    // Memoised: the similarity helpers call this in O(candidates × titles)
    // loops with the same few strings on one side of every comparison.
    static NSCache<NSString *, NSString *> *cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ cache = [[NSCache alloc] init]; cache.countLimit = 2048; });
    if (!value.length) return @"";
    NSString *cached = [cache objectForKey:value];
    if (cached) return cached;
    NSString *normalized = YTMULyricsNormalizeLoose(value);
    NSString *compact = [YTMULyricsCachedRegex(@"[^\\p{L}\\p{N}]+", 0) stringByReplacingMatchesInString:normalized options:0 range:NSMakeRange(0, normalized.length) withTemplate:@""];
    [cache setObject:compact forKey:[value copy]];
    return compact;
}

static NSUInteger YTMULevenshtein(NSString *a, NSString *b) {
    NSUInteger m = a.length;
    NSUInteger n = b.length;
    if (m == 0) return n;
    if (n == 0) return m;

    // Plain C buffers: the boxed-NSNumber version allocated O(m·n) objects
    // and this runs thousands of times per NetEase search.
    unichar *ca = malloc(m * sizeof(unichar));
    unichar *cb = malloc(n * sizeof(unichar));
    NSUInteger *prev = malloc((n + 1) * sizeof(NSUInteger));
    NSUInteger *cur = malloc((n + 1) * sizeof(NSUInteger));
    [a getCharacters:ca range:NSMakeRange(0, m)];
    [b getCharacters:cb range:NSMakeRange(0, n)];
    for (NSUInteger j = 0; j <= n; j++) prev[j] = j;

    for (NSUInteger i = 1; i <= m; i++) {
        cur[0] = i;
        for (NSUInteger j = 1; j <= n; j++) {
            NSUInteger cost = ca[i - 1] == cb[j - 1] ? 0 : 1;
            NSUInteger del = prev[j] + 1;
            NSUInteger ins = cur[j - 1] + 1;
            NSUInteger sub = prev[j - 1] + cost;
            cur[j] = MIN(MIN(del, ins), sub);
        }
        NSUInteger *tmp = prev;
        prev = cur;
        cur = tmp;
    }
    NSUInteger distance = prev[n];
    free(ca); free(cb); free(prev); free(cur);
    return distance;
}

CGFloat YTMULyricsSimilarity(NSString *left, NSString *right) {
    NSString *a = YTMULyricsCompactString(left);
    NSString *b = YTMULyricsCompactString(right);
    if (!a.length || !b.length) return 0;
    if ([a isEqualToString:b]) return 1;
    if (a.length >= 3 && b.length >= 3 && ([a containsString:b] || [b containsString:a])) return 0.94;
    NSUInteger maxLen = MAX(a.length, b.length);
    NSUInteger distance = YTMULevenshtein(a, b);
    return MAX(0, 1.0 - ((CGFloat)distance / (CGFloat)maxLen));
}

NSString *YTMULyricsStripSearchNoise(NSString *value) {
    if (!value.length) return @"";
    NSString *out = value;
    NSArray<NSString *> *patterns = @[
        @"[\\s\\u3000]*[\\(\\[\\{（【［][^\\)\\]\\}）】］]*(?:feat|ft|featuring)\\.?\\s+[^\\)\\]\\}）】］]*[\\)\\]\\}）】］]",
        @"[\\s\\u3000]*[\\(\\[\\{（【［][^\\)\\]\\}）】］]*(?:official|music\\s*video|mv|pv|lyric\\s*video|lyrics?|audio|visualizer)[^\\)\\]\\}）】］]*[\\)\\]\\}）】］]",
        @"(?:official|music\\s*video|mv|pv|lyric\\s*video|lyrics?|audio|visualizer|full\\s*ver\\.?|short\\s*ver\\.?)",
        @"(?:公式|オフィシャル|ミュージックビデオ|歌詞付き|字幕|中文字幕|中日字幕|ＭＶ|ＰＶ)",
        @"(?:^|[\\s\\u3000\\(（\\[])(?:feat|ft|featuring)\\.?\\s+.+$"
    ];
    for (NSString *pattern in patterns) {
        NSRegularExpression *re = YTMULyricsCachedRegex(pattern, NSRegularExpressionCaseInsensitive);
        out = [re stringByReplacingMatchesInString:out options:0 range:NSMakeRange(0, out.length) withTemplate:@" "];
    }
    out = YTMULyricsCollapseWhitespace(out);
    return [out stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

NSArray<NSString *> *YTMULyricsSplitArtists(NSString *artist, NSArray<NSString *> *tags) {
    NSMutableArray<NSString *> *items = [NSMutableArray array];
    NSMutableArray<NSString *> *sources = [NSMutableArray array];
    if (artist.length) [sources addObject:artist];
    for (NSString *tag in tags ?: @[]) if (tag.length) [sources addObject:tag];

    NSRegularExpression *splitter = YTMULyricsCachedRegex(@"\\s*(?:[&,、，/／|｜;；]|\\band\\b|\\bfeat\\.?\\b|\\bft\\.?\\b)\\s*",
                                                        NSRegularExpressionCaseInsensitive);
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (NSString *source in sources) {
        NSString *split = [splitter stringByReplacingMatchesInString:source options:0 range:NSMakeRange(0, source.length) withTemplate:@"\n"];
        NSArray *parts = [split componentsSeparatedByString:@"\n"];
        for (NSString *part in parts) {
            NSString *clean = YTMULyricsStripSearchNoise(part);
            NSString *key = YTMULyricsCompactString(clean);
            if (clean.length && ![seen containsObject:key]) {
                [seen addObject:key];
                [items addObject:clean];
            }
        }
    }
    return items;
}

NSString *YTMULyricsEncodeQuery(NSString *value) {
    return [value stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]] ?: @"";
}

NSString *YTMULyricsJSONStringFromObject(id object) {
    if (!object) return @"{}";
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:nil];
    if (!data) return @"{}";
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"{}";
}

id YTMULyricsJSONValueAtPath(id object, NSArray *path) {
    id current = object;
    for (id key in path ?: @[]) {
        if (!current || current == (id)kCFNull) return nil;
        if ([key isKindOfClass:[NSString class]]) {
            if (![current isKindOfClass:[NSDictionary class]]) return nil;
            current = ((NSDictionary *)current)[key];
        } else if ([key isKindOfClass:[NSNumber class]]) {
            if (![current isKindOfClass:[NSArray class]]) return nil;
            NSUInteger index = [key unsignedIntegerValue];
            NSArray *array = (NSArray *)current;
            if (index >= array.count) return nil;
            current = array[index];
        } else {
            return nil;
        }
    }
    return current == (id)kCFNull ? nil : current;
}

NSDictionary *YTMULyricsJSONDictionaryAtPath(id object, NSArray *path) {
    id value = YTMULyricsJSONValueAtPath(object, path);
    return [value isKindOfClass:[NSDictionary class]] ? value : nil;
}

NSArray *YTMULyricsJSONArrayAtPath(id object, NSArray *path) {
    id value = YTMULyricsJSONValueAtPath(object, path);
    return [value isKindOfClass:[NSArray class]] ? value : nil;
}

NSString *YTMULyricsJSONStringAtPath(id object, NSArray *path) {
    id value = YTMULyricsJSONValueAtPath(object, path);
    return [value isKindOfClass:[NSString class]] ? value : nil;
}

NSNumber *YTMULyricsJSONNumberAtPath(id object, NSArray *path) {
    id value = YTMULyricsJSONValueAtPath(object, path);
    if ([value isKindOfClass:[NSNumber class]]) return value;
    if ([value isKindOfClass:[NSString class]]) {
        NSString *text = [(NSString *)value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (!text.length) return nil;
        NSScanner *scanner = [NSScanner scannerWithString:text];
        double parsed = 0;
        if ([scanner scanDouble:&parsed] && scanner.isAtEnd && isfinite(parsed)) return @(parsed);
    }
    return nil;
}
