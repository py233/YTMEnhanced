#import <UIKit/UIKit.h>
#import <NaturalLanguage/NaturalLanguage.h>
#import "Headers/YTPlayerViewController.h"
#import "Translation/YTMUTranslationContext.h"
#import "Translation/YTMUTranslator.h"
#import "Translation/YTMUPromptBuilder.h"

static BOOL YTMU(NSString *key) {
    NSDictionary *YTMUltimateDict = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"YTMUltimate"] ?: @{};
    return [YTMUltimateDict[key] boolValue];
}

static NSString *YTMUString(NSString *key, NSString *fallback) {
    NSDictionary *YTMUltimateDict = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"YTMUltimate"] ?: @{};
    id value = YTMUltimateDict[key];
    if ([value isKindOfClass:[NSString class]] && [(NSString *)value length]) return value;
    return fallback ?: @"";
}

static BOOL selectableLyrics(void) {
    return YTMU(@"YTMUltimateIsEnabled") && YTMU(@"selectableLyrics");
}

static BOOL bilingualLyrics(void) {
    return selectableLyrics() && YTMU(@"bilingualLyrics");
}

static NSArray<NSString *> *YTMULinesFromString(NSString *text) {
    NSArray *raw = [text componentsSeparatedByString:@"\n"];
    NSMutableArray *lines = [NSMutableArray arrayWithCapacity:raw.count];
    for (NSString *line in raw) {
        [lines addObject:[line stringByReplacingOccurrencesOfString:@"\r" withString:@""]];
    }
    return lines;
}

static NSString *YTMULanguageFamily(NSString *language) {
    NSString *normalized = [[language ?: @"" lowercaseString] stringByReplacingOccurrencesOfString:@"_" withString:@"-"];
    NSString *primary = [normalized componentsSeparatedByString:@"-"].firstObject ?: normalized;
    if ([primary isEqualToString:@"cmn"] || [primary isEqualToString:@"yue"]) return @"zh";
    if ([primary isEqualToString:@"nb"] || [primary isEqualToString:@"nn"]) return @"no";
    if ([primary isEqualToString:@"tl"]) return @"fil";
    return primary;
}

static BOOL YTMUSourceLanguageMatchesTarget(NSArray<NSString *> *lines, NSString *targetLanguage) {
    NSMutableArray *parts = [NSMutableArray array];
    for (NSString *line in lines) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (trimmed.length) [parts addObject:trimmed];
    }

    NSString *text = [parts componentsJoinedByString:@"\n"];
    if (text.length < 24) return NO;

    NLLanguageRecognizer *recognizer = [[NLLanguageRecognizer alloc] init];
    [recognizer processString:text];
    NSString *detected = recognizer.dominantLanguage;
    if (!detected.length) return NO;

    return [YTMULanguageFamily(detected) isEqualToString:YTMULanguageFamily(targetLanguage)];
}

static NSAttributedString *YTMUCombinedLyricsAttributedText(UILabel *label,
                                                           NSArray<NSString *> *sourceLines,
                                                           NSArray<NSString *> *translatedLines) {
    UIFont *font = label.font ?: [UIFont systemFontOfSize:15.0];
    UIColor *textColor = label.textColor ?: [UIColor labelColor];
    UIFont *translationFont = [font fontWithSize:font.pointSize * 0.92];
    UIColor *translationColor = [textColor colorWithAlphaComponent:0.72];

    NSMutableParagraphStyle *normalParagraph = [[NSMutableParagraphStyle alloc] init];
    normalParagraph.paragraphSpacing = 0.0;

    NSMutableParagraphStyle *pairEndParagraph = [[NSMutableParagraphStyle alloc] init];
    pairEndParagraph.paragraphSpacing = 8.0;

    NSMutableAttributedString *combined = [[NSMutableAttributedString alloc] init];
    for (NSUInteger idx = 0; idx < sourceLines.count; idx++) {
        NSString *source = sourceLines[idx] ?: @"";
        NSString *translated = idx < translatedLines.count ? translatedLines[idx] : @"";
        BOOL shouldShowTranslation = translated.length &&
            ![YTMUPromptBuilder isSkippableLine:source] &&
            ![[YTMUPromptBuilder simplifyUnicode:source] isEqualToString:[YTMUPromptBuilder simplifyUnicode:translated]];

        NSDictionary *sourceAttributes = @{
            NSFontAttributeName: font,
            NSForegroundColorAttributeName: textColor,
            NSParagraphStyleAttributeName: shouldShowTranslation ? normalParagraph : pairEndParagraph,
        };
        NSDictionary *translationAttributes = @{
            NSFontAttributeName: translationFont,
            NSForegroundColorAttributeName: translationColor,
            NSParagraphStyleAttributeName: pairEndParagraph,
        };

        [combined appendAttributedString:[[NSAttributedString alloc] initWithString:source attributes:sourceAttributes]];
        if (shouldShowTranslation) {
            [combined appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n" attributes:sourceAttributes]];
            [combined appendAttributedString:[[NSAttributedString alloc] initWithString:translated attributes:translationAttributes]];
        }
        if (idx + 1 < sourceLines.count) {
            [combined appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n" attributes:translationAttributes]];
        }
    }

    return combined;
}

@interface YTFormattedStringLabel : UILabel
@end

@interface YTMLightweightMusicDescriptionShelfCell : UIView
@property (retain, nonatomic) UITextView *lyrics;
@property (copy, nonatomic) NSString *translationRequestVideoId;
@end

%hook YTMLightweightMusicDescriptionShelfCell

%property (retain, nonatomic) UITextView *lyrics;
%property (copy, nonatomic) NSString *translationRequestVideoId;

- (id)initWithFrame:(CGRect)frame {
    self = %orig;
    if (self && selectableLyrics()) {
        UIView *container = [self valueForKey:@"_descriptionContainer"];
        self.lyrics = [[UITextView alloc] init];
        self.lyrics.backgroundColor = [UIColor clearColor];
        self.lyrics.editable = NO;
        self.lyrics.scrollEnabled = NO;
        self.lyrics.showsVerticalScrollIndicator = NO;
        [container addSubview:self.lyrics];
    }
    return self;
}

- (void)setRenderer:(id)renderer {
    %orig;

    if (selectableLyrics()) {
        YTFormattedStringLabel *lyrics = [self valueForKey:@"_descriptionLabel"];
        if (!lyrics || !self.lyrics) {
            YTMUTranslationLog(@"lyrics hook skipped: missing label/textView");
            return;
        }

        lyrics.userInteractionEnabled = YES;
        lyrics.hidden = YES;
        self.lyrics.font = lyrics.font;
        self.lyrics.textColor = lyrics.textColor;
        self.lyrics.attributedText = lyrics.attributedText;

        if (!bilingualLyrics()) return;

        NSString *text = lyrics.attributedText.string ?: lyrics.text ?: @"";
        NSArray<NSString *> *lines = YTMULinesFromString(text);
        if (!text.length || !lines.count) {
            YTMUTranslationLog(@"lyrics hook skipped: empty lyrics text");
            return;
        }

        NSString *targetLanguage = [YTMUPromptBuilder effectiveTargetCode:YTMUString(@"translationTargetLang", @"auto")];
        if (YTMUSourceLanguageMatchesTarget(lines, targetLanguage)) {
            YTMUTranslationLog(@"lyrics hook skipped: source language matches target=%@", targetLanguage);
            return;
        }

        YTMUTranslationContext *context = [YTMUTranslationContext sharedContext];
        NSString *videoId = context.videoId ?: @"";
        if (!videoId.length) {
            YTMUTranslationLog(@"lyrics hook skipped: missing current videoId lines=%lu", (unsigned long)lines.count);
            return;
        }

        self.translationRequestVideoId = videoId;
        YTMUTranslationLog(@"lyrics hook requesting translation videoId=%@ target=%@ lines=%lu",
                           videoId,
                           targetLanguage,
                           (unsigned long)lines.count);
        [[YTMUTranslator sharedTranslator] translateLines:lines
                                                  videoId:videoId
                                                    title:context.title
                                                   artist:context.artist
                                               completion:^(NSArray<NSString *> *translatedLines, NSError *error) {
            if (error || translatedLines.count != lines.count) {
                YTMUTranslationLog(@"lyrics hook translation failed videoId=%@ error=%@ translatedLines=%lu expected=%lu",
                                   videoId,
                                   error.localizedDescription ?: @"<line-count-mismatch>",
                                   (unsigned long)translatedLines.count,
                                   (unsigned long)lines.count);
                return;
            }
            if (![videoId isEqualToString:[YTMUTranslationContext sharedContext].videoId]) {
                YTMUTranslationLog(@"lyrics hook dropped stale result videoId=%@ current=%@",
                                   videoId,
                                   [YTMUTranslationContext sharedContext].videoId ?: @"<empty>");
                return;
            }
            if (![videoId isEqualToString:self.translationRequestVideoId]) {
                YTMUTranslationLog(@"lyrics hook dropped reused cell result videoId=%@ cellVideoId=%@",
                                   videoId,
                                   self.translationRequestVideoId ?: @"<empty>");
                return;
            }

            self.lyrics.attributedText = YTMUCombinedLyricsAttributedText(lyrics, lines, translatedLines);
            YTMUTranslationLog(@"lyrics hook rendered bilingual lyrics videoId=%@ lines=%lu",
                               videoId,
                               (unsigned long)lines.count);
        }];
    }
}

- (void)layoutSubviews {
    %orig;

    if (selectableLyrics()) {
        YTFormattedStringLabel *lyrics = [self valueForKey:@"_descriptionLabel"];
        self.lyrics.frame = lyrics.frame;
    }
}

%end

%hook YTPlayerViewController

- (void)playbackController:(id)arg1 didActivateVideo:(id)arg2 withPlaybackData:(id)arg3 {
    %orig;

    NSString *videoId = self.currentVideoID ?: self.contentVideoID ?: @"";
    YTIVideoDetails *details = self.playerResponse.playerData.videoDetails;
    [[YTMUTranslationContext sharedContext] updateWithVideoId:videoId
                                                        title:details.title
                                                       artist:details.author];
}

%end

%ctor {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithDictionary:[defaults dictionaryForKey:@"YTMUltimate"] ?: @{}];

    if (dict[@"bilingualLyrics"] == nil) {
        dict[@"bilingualLyrics"] = @(NO);
    }
    if (dict[@"translationProvider"] == nil) {
        dict[@"translationProvider"] = YTMUTranslationProviderGoogle;
    }
    if (dict[@"translationTargetLang"] == nil) {
        dict[@"translationTargetLang"] = @"auto";
    }
    if (dict[@"translationBaseUrl"] == nil) {
        dict[@"translationBaseUrl"] = @"https://api.openai.com/v1";
    }
    if (dict[@"translationDebugLogs"] == nil) {
        dict[@"translationDebugLogs"] = @(YES);
    }

    [defaults setObject:dict forKey:@"YTMUltimate"];
}
