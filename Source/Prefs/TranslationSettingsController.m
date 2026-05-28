#import "TranslationSettingsController.h"
#import "../Headers/ABCSwitch.h"
#import "../Translation/YTMUTranslationTypes.h"
#import "../Translation/YTMUPromptBuilder.h"
#import "../Translation/YTMUTranslationCache.h"
#import "../Lyrics/YTMULyricsCache.h"
#import "../Lyrics/YTMULyricsManager.h"
#import "../Lyrics/YTMULyricsTitleNormalizer.h"
#import "../Lyrics/YTMULyricsDescriptionExtractor.h"
#import "../Lyrics/YTMUInnerTubeDescriptionFetcher.h"
#import "../Lyrics/YTMULyricsTypes.h"

@interface YTMUTranslationLanguageController : UITableViewController
@property (nonatomic, copy) NSArray<NSDictionary *> *languages;
@property (nonatomic, copy) NSString *selectedCode;
@property (nonatomic, copy) void (^selectionHandler)(NSString *code);
@end

@implementation YTMUTranslationLanguageController

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.languages.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"languageCell"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"languageCell"];
    NSDictionary *language = self.languages[indexPath.row];
    cell.textLabel.text = language[@"title"];
    cell.accessoryType = [language[@"code"] isEqualToString:self.selectedCode] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *language = self.languages[indexPath.row];
    if (self.selectionHandler) self.selectionHandler(language[@"code"]);
    [self.navigationController popViewControllerAnimated:YES];
}

@end

@implementation TranslationSettingsController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = LOC(@"TRANSLATION_SETTINGS");
    [self ensureDefaults];

    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    [self.view addSubview:self.tableView];

    [NSLayoutConstraint activateConstraints:@[
        [self.tableView.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.tableView.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [self.tableView.widthAnchor constraintEqualToAnchor:self.view.widthAnchor],
        [self.tableView.heightAnchor constraintEqualToAnchor:self.view.heightAnchor]
    ]];

    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserver:self selector:@selector(keyboardWillShow:) name:UIKeyboardWillShowNotification object:nil];
    [nc addObserver:self selector:@selector(keyboardWillHide:) name:UIKeyboardWillHideNotification object:nil];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Keyboard avoidance

- (void)keyboardWillShow:(NSNotification *)note {
    NSDictionary *info = note.userInfo;
    CGRect endFrame = [info[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    CGRect endInView = [self.view convertRect:endFrame fromView:nil];
    CGFloat overlap = MAX(0, CGRectGetMaxY(self.tableView.frame) - CGRectGetMinY(endInView));
    NSTimeInterval duration = [info[UIKeyboardAnimationDurationUserInfoKey] doubleValue];
    UIViewAnimationCurve curve = (UIViewAnimationCurve)[info[UIKeyboardAnimationCurveUserInfoKey] integerValue];

    [UIView animateWithDuration:duration delay:0 options:(UIViewAnimationOptions)(curve << 16) animations:^{
        UIEdgeInsets inset = self.tableView.contentInset;
        inset.bottom = overlap;
        self.tableView.contentInset = inset;
        UIEdgeInsets indicator = self.tableView.verticalScrollIndicatorInsets;
        indicator.bottom = overlap;
        self.tableView.verticalScrollIndicatorInsets = indicator;
    } completion:nil];

    UITextField *active = self.activeTextField;
    if (active) {
        UITableViewCell *cell = (UITableViewCell *)active.superview;
        while (cell && ![cell isKindOfClass:[UITableViewCell class]]) cell = (UITableViewCell *)cell.superview;
        NSIndexPath *indexPath = cell ? [self.tableView indexPathForCell:cell] : nil;
        if (indexPath) {
            [self.tableView scrollToRowAtIndexPath:indexPath atScrollPosition:UITableViewScrollPositionMiddle animated:YES];
        }
    }
}

- (void)keyboardWillHide:(NSNotification *)note {
    NSTimeInterval duration = [note.userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue];
    UIViewAnimationCurve curve = (UIViewAnimationCurve)[note.userInfo[UIKeyboardAnimationCurveUserInfoKey] integerValue];
    [UIView animateWithDuration:duration delay:0 options:(UIViewAnimationOptions)(curve << 16) animations:^{
        UIEdgeInsets inset = self.tableView.contentInset;
        inset.bottom = 0;
        self.tableView.contentInset = inset;
        UIEdgeInsets indicator = self.tableView.verticalScrollIndicatorInsets;
        indicator.bottom = 0;
        self.tableView.verticalScrollIndicatorInsets = indicator;
    } completion:nil];
}

- (void)textFieldDidBeginEditing:(UITextField *)textField {
    self.activeTextField = textField;
}

- (void)ensureDefaults {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithDictionary:[defaults dictionaryForKey:@"YTMUltimate"] ?: @{}];
    YTMULyricsSetDefault(dict, @"bilingualLyrics", @(NO));
    YTMULyricsSetDefault(dict, @"syncedLyricsEnabled", @(NO));
    YTMULyricsSetDefault(dict, @"lyricsTranslationEnabled", dict[@"bilingualLyrics"] ?: @(NO));
    YTMULyricsSetDefault(dict, @"lyricsPreferredSource", @"auto");
    YTMULyricsSetDefault(dict, @"lyricsShowInexact", @(YES));
    YTMULyricsSetDefault(dict, @"lyricsRomanization", @(YES));
    YTMULyricsSetDefault(dict, @"lyricsConvertChinese", @"disabled");
    YTMULyricsSetDefault(dict, @"lyricsShowTimeCodes", @(NO));
    YTMULyricsSetDefault(dict, @"lyricsLineEffect", @"fancy");
    YTMULyricsSetDefault(dict, @"lyricsFontSize", @"small");
    YTMULyricsSetDefault(dict, @"lyricsTimingOffsetMs", @(0));
    YTMULyricsSetDefault(dict, @"lyricsTimingOffsetActiveKey", @"");
    YTMULyricsSetDefault(dict, @"lyricsTimingOffsets", @{});
    YTMULyricsSetDefault(dict, @"lyricsDefaultText", @"♪");
    YTMULyricsSetDefault(dict, @"translationProvider", YTMUTranslationProviderGoogle);
    YTMULyricsSetDefault(dict, @"translationTargetLang", @"auto");
    YTMULyricsSetDefault(dict, @"translationBaseUrl", @"https://api.openai.com/v1");
    YTMULyricsSetDefault(dict, @"translationDebugLogs", @(YES));
    [defaults setObject:dict forKey:@"YTMUltimate"];
}

- (NSMutableDictionary *)settings {
    return [NSMutableDictionary dictionaryWithDictionary:[[NSUserDefaults standardUserDefaults] dictionaryForKey:@"YTMUltimate"] ?: @{}];
}

- (void)setSetting:(id)value forKey:(NSString *)key {
    [self setSettings:@{key ?: @"": value ?: @""} notificationKey:key];
}

- (void)setSettings:(NSDictionary<NSString *, id> *)values notificationKey:(NSString *)notificationKey {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSMutableDictionary *dict = [self settings];
    [values enumerateKeysAndObjectsUsingBlock:^(NSString *key, id value, BOOL *stop) {
        if (key.length) dict[key] = value ?: @"";
    }];
    [defaults setObject:dict forKey:@"YTMUltimate"];
    [defaults synchronize];
    YTMULyricsLog(@"settings changed keys=%@", values.allKeys);
    NSDictionary *userInfo = notificationKey.length ? @{YTMULyricsSettingChangedKey: notificationKey} : @{};
    [[NSNotificationCenter defaultCenter] postNotificationName:YTMULyricsSettingsDidChangeNotification object:self userInfo:userInfo];
}

- (NSString *)stringSetting:(NSString *)key fallback:(NSString *)fallback {
    id value = [self settings][key];
    if ([value isKindOfClass:[NSString class]] && [(NSString *)value length]) return value;
    return fallback ?: @"";
}

- (BOOL)boolSetting:(NSString *)key fallback:(BOOL)fallback {
    id value = [self settings][key];
    return value == nil ? fallback : [value boolValue];
}

- (NSString *)currentProvider {
    NSString *provider = [self stringSetting:@"translationProvider" fallback:YTMUTranslationProviderGoogle];
    NSArray *valid = @[YTMUTranslationProviderGoogle, YTMUTranslationProviderAnthropic, YTMUTranslationProviderGemini, YTMUTranslationProviderOpenAI];
    return [valid containsObject:provider] ? provider : YTMUTranslationProviderGoogle;
}

- (NSArray<NSDictionary *> *)translationProviderOptions {
    return @[
        @{@"key": YTMUTranslationProviderGoogle, @"title": LOC(@"PROVIDER_GOOGLE")},
        @{@"key": YTMUTranslationProviderAnthropic, @"title": LOC(@"PROVIDER_ANTHROPIC")},
        @{@"key": YTMUTranslationProviderGemini, @"title": LOC(@"PROVIDER_GEMINI")},
        @{@"key": YTMUTranslationProviderOpenAI, @"title": LOC(@"PROVIDER_OPENAI")},
    ];
}

- (NSArray<NSDictionary *> *)lineEffectOptions {
    return @[
        @{@"key": @"fancy", @"title": LOC(@"LYRICS_EFFECT_FANCY")},
        @{@"key": @"scale", @"title": LOC(@"LYRICS_EFFECT_SCALE")},
        @{@"key": @"offset", @"title": LOC(@"LYRICS_EFFECT_OFFSET")},
        @{@"key": @"focus", @"title": LOC(@"LYRICS_EFFECT_FOCUS")},
    ];
}

- (NSArray<NSDictionary *> *)defaultTextOptions {
    return @[
        @{@"key": @"♪", @"title": @"♪"},
        @{@"key": @"space", @"title": @"\" \""},
        @{@"key": @"dots", @"title": @"..."},
        @{@"key": @"bullets", @"title": @"•••"},
        @{@"key": @"dash", @"title": @"———"},
    ];
}

- (NSArray<NSDictionary *> *)chineseConversionOptions {
    return @[
        @{@"key": @"disabled", @"title": LOC(@"LYRICS_CHINESE_DISABLED")},
        @{@"key": @"simplifiedToTraditional", @"title": LOC(@"LYRICS_CHINESE_S2T")},
        @{@"key": @"traditionalToSimplified", @"title": LOC(@"LYRICS_CHINESE_T2S")},
    ];
}

- (NSString *)titleForKey:(NSString *)key inOptions:(NSArray<NSDictionary *> *)options fallback:(NSString *)fallback {
    for (NSDictionary *option in options) {
        if ([option[@"key"] isEqualToString:key]) return option[@"title"];
    }
    return fallback ?: key;
}

- (NSString *)modelFallbackForProvider:(NSString *)provider {
    if ([provider isEqualToString:YTMUTranslationProviderAnthropic]) return @"claude-haiku-4-5-20251001";
    if ([provider isEqualToString:YTMUTranslationProviderGemini]) return @"gemini-2.0-flash";
    if ([provider isEqualToString:YTMUTranslationProviderOpenAI]) return @"gpt-4o-mini";
    return @"";
}

- (NSArray<NSDictionary *> *)providerConfigRows {
    NSString *provider = [self currentProvider];
    if ([provider isEqualToString:YTMUTranslationProviderGoogle]) return @[];
    NSMutableArray *rows = [NSMutableArray array];
    [rows addObject:@{@"title": LOC(@"TRANSLATION_API_KEY"), @"key": [@"translationApiKey_" stringByAppendingString:provider], @"secure": @(YES), @"fallback": @""}];
    [rows addObject:@{@"title": LOC(@"TRANSLATION_MODEL"), @"key": [@"translationModel_" stringByAppendingString:provider], @"secure": @(NO), @"fallback": [self modelFallbackForProvider:provider]}];
    // Base URL override is available for every API-based provider so
    // users can route through OpenRouter / Cloudflare AI Gateway /
    // self-hosted proxies for any of them. Each provider has its own
    // setting key so switching between them doesn't share state.
    if ([provider isEqualToString:YTMUTranslationProviderOpenAI]) {
        [rows addObject:@{@"title": LOC(@"TRANSLATION_BASE_URL"), @"key": @"translationBaseUrl", @"secure": @(NO), @"fallback": @"https://api.openai.com/v1"}];
    } else if ([provider isEqualToString:YTMUTranslationProviderAnthropic]) {
        [rows addObject:@{@"title": LOC(@"TRANSLATION_BASE_URL"), @"key": @"translationBaseUrl_anthropic", @"secure": @(NO), @"fallback": @"https://api.anthropic.com"}];
    } else if ([provider isEqualToString:YTMUTranslationProviderGemini]) {
        [rows addObject:@{@"title": LOC(@"TRANSLATION_BASE_URL"), @"key": @"translationBaseUrl_gemini", @"secure": @(NO), @"fallback": @"https://generativelanguage.googleapis.com"}];
    }
    return rows;
}

- (NSArray<NSDictionary *> *)languageOptions {
    NSArray *codes = @[@"auto", @"zh-CN", @"zh-TW", @"en", @"ja", @"ko", @"fr", @"de", @"es", @"pt-BR", @"pt-PT", @"it", @"nl", @"ru", @"uk", @"pl", @"tr", @"ar", @"he", @"fa", @"hi", @"bn", @"ur", @"ta", @"te", @"mr", @"id", @"ms", @"vi", @"th", @"fil", @"sw", @"sv", @"no", @"da", @"fi", @"cs", @"ro", @"hu", @"el", @"bg", @"sr", @"hr", @"sk", @"lt"];
    NSMutableArray *languages = [NSMutableArray arrayWithCapacity:codes.count];
    for (NSString *code in codes) [languages addObject:@{@"code": code, @"title": [self languageTitleForCode:code]}];
    return languages;
}

- (NSString *)languageTitleForCode:(NSString *)code {
    // The "follow app language" entry IS localized to the user's UI
    // language — it's a meta-instruction ("translate into whichever
    // language the app interface is currently in"), and the natural
    // reader is whoever is configuring the setting in their own UI
    // language. So a zh-Hans user sees "跟随应用语言", an en user
    // sees "Follow app language", etc. This is the only row in the
    // picker that follows UI language; everything else is the
    // language's own native name (autoglottonym).
    if ([code isEqualToString:@"auto"]) return LOC(@"TRANSLATION_FOLLOW_APP_LANG");
    // Show each language by its OWN native name (autoglottonym) — same
    // convention as pear-desktop, Telegram, iOS Settings. The picker
    // shows TARGET languages, so the natural reader of each row is a
    // speaker of that language; translating them all into the user's
    // UI language just obscures the choice whenever the user's device
    // language differs from the lyric target. Final rendering looks
    // like (for a zh-Hans user):
    //     跟随应用语言    ← localized to UI language
    //     简体中文
    //     繁體中文
    //     English
    //     日本語
    //     Português (Brasil)
    NSLocale *nativeLocale = [NSLocale localeWithLocaleIdentifier:code];
    NSString *native = [nativeLocale displayNameForKey:NSLocaleIdentifier value:code];
    if (native.length) {
        // Capitalize Latin-script names like "français" /
        // "português (brasil)" to match Apple's language-picker style.
        // CJK / RTL scripts have no case and pass through unchanged.
        return [native capitalizedStringWithLocale:nativeLocale];
    }
    // Defensive fallback: any code where NSLocale returns nothing.
    // Filipino's `fil` is the historical offender; everything else
    // NSLocale handles natively.
    static NSDictionary *manualFallback = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        manualFallback = @{
            @"fil": @"Filipino",
        };
    });
    return manualFallback[code] ?: code;
}

#pragma mark - Cells

- (UITableViewCell *)switchCellWithTitle:(NSString *)title detail:(NSString *)detail key:(NSString *)key fallback:(BOOL)fallback action:(SEL)action {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"switchCell"];
    cell.textLabel.text = title;
    cell.detailTextLabel.text = detail;
    cell.detailTextLabel.numberOfLines = 0;
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    ABCSwitch *switchControl = [[NSClassFromString(@"ABCSwitch") alloc] init];
    switchControl.onTintColor = [UIColor colorWithRed:30.0/255.0 green:150.0/255.0 blue:245.0/255.0 alpha:1.0];
    switchControl.on = [self boolSetting:key fallback:fallback];
    switchControl.accessibilityIdentifier = key;
    [switchControl addTarget:self action:action forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = switchControl;
    return cell;
}

- (UITableViewCell *)choiceCellWithTitle:(NSString *)title detail:(NSString *)detail {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"choiceCell"];
    cell.textLabel.text = title;
    cell.detailTextLabel.text = detail;
    cell.detailTextLabel.adjustsFontSizeToFitWidth = YES;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

#pragma mark - Table view

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    return UITableViewAutomaticDimension;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 7;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return 1;
    if (section == 1) return 2;
    if (section == 2) return 1;
    if (section == 3) return 2;
    if (section == 4) return [self providerConfigRows].count;
    if (section == 5) return 1;
    if (section == 6) return 1;
    return 0;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 0) {
        return [self switchCellWithTitle:LOC(@"BILINGUAL_LYRICS")
                                  detail:LOC(@"BILINGUAL_LYRICS_DESC")
                                     key:@"lyricsTranslationEnabled"
                                fallback:[self boolSetting:@"bilingualLyrics" fallback:NO]
                                  action:@selector(toggleTranslation:)];
    }

    if (indexPath.section == 1) {
        if (indexPath.row == 0) {
            NSString *key = [self stringSetting:@"lyricsDefaultText" fallback:@"♪"];
            return [self choiceCellWithTitle:LOC(@"LYRICS_DEFAULT_TEXT") detail:[self titleForKey:key inOptions:[self defaultTextOptions] fallback:key]];
        }
        NSString *key = [self stringSetting:@"lyricsConvertChinese" fallback:@"disabled"];
        return [self choiceCellWithTitle:LOC(@"LYRICS_CHINESE_CONVERSION") detail:[self titleForKey:key inOptions:[self chineseConversionOptions] fallback:key]];
    }

    if (indexPath.section == 2) {
        return [self switchCellWithTitle:LOC(@"LYRICS_SHOW_INEXACT") detail:@"" key:@"lyricsShowInexact" fallback:YES action:@selector(toggleSwitch:)];
    }

    if (indexPath.section == 3) {
        if (indexPath.row == 0) {
            NSString *provider = [self currentProvider];
            return [self choiceCellWithTitle:LOC(@"TRANSLATION_PROVIDER") detail:[self titleForKey:provider inOptions:[self translationProviderOptions] fallback:provider]];
        }
        NSString *language = [self stringSetting:@"translationTargetLang" fallback:@"auto"];
        return [self choiceCellWithTitle:LOC(@"TRANSLATION_TARGET_LANG") detail:[self languageTitleForCode:language]];
    }

    if (indexPath.section == 4) {
        NSArray *rows = [self providerConfigRows];
        NSDictionary *row = rows[indexPath.row];
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"textFieldCell"];
        cell.textLabel.text = row[@"title"];
        cell.textLabel.adjustsFontSizeToFitWidth = YES;
        UITextField *textField = [[UITextField alloc] initWithFrame:CGRectMake(0, 0, 210, 36)];
        textField.text = [self stringSetting:row[@"key"] fallback:row[@"fallback"]];
        textField.placeholder = row[@"fallback"];
        textField.font = [UIFont systemFontOfSize:13.0];
        textField.textAlignment = NSTextAlignmentRight;
        textField.autocorrectionType = UITextAutocorrectionTypeNo;
        textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
        textField.clearButtonMode = UITextFieldViewModeWhileEditing;
        textField.secureTextEntry = [row[@"secure"] boolValue];
        textField.accessibilityIdentifier = row[@"key"];
        textField.inputAccessoryView = [self KBToolbar:textField];
        textField.delegate = self;
        cell.accessoryView = textField;
        return cell;
    }

    if (indexPath.section == 5) {
        return [self switchCellWithTitle:LOC(@"TRANSLATION_DEBUG_LOGS") detail:LOC(@"TRANSLATION_DEBUG_LOGS_DESC") key:@"translationDebugLogs" fallback:YES action:@selector(toggleSwitch:)];
    }

    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"clearCacheCell"];
    cell.textLabel.text = LOC(@"TRANSLATION_CLEAR_CACHE");
    cell.textLabel.textColor = [UIColor systemRedColor];
    cell.imageView.image = [UIImage systemImageNamed:@"trash"];
    cell.imageView.tintColor = [UIColor systemRedColor];
    return cell;
}

- (BOOL)tableView:(UITableView *)tableView shouldHighlightRowAtIndexPath:(NSIndexPath *)indexPath {
    return indexPath.section == 1 || indexPath.section == 3 || indexPath.section == 6;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 1) {
        if (indexPath.row == 0) [self showOptionPickerWithTitle:LOC(@"LYRICS_DEFAULT_TEXT") key:@"lyricsDefaultText" options:[self defaultTextOptions] reloadSections:[NSIndexSet indexSetWithIndex:1]];
        else [self showOptionPickerWithTitle:LOC(@"LYRICS_CHINESE_CONVERSION") key:@"lyricsConvertChinese" options:[self chineseConversionOptions] reloadSections:[NSIndexSet indexSetWithIndex:1]];
    } else if (indexPath.section == 3 && indexPath.row == 0) {
        [self showProviderPicker];
    } else if (indexPath.section == 3 && indexPath.row == 1) {
        [self showLanguagePicker];
    } else if (indexPath.section == 6) {
        [self clearCaches];
    }
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
}

#pragma mark - Actions

- (void)toggleSwitch:(UISwitch *)sender {
    [self setSetting:@(sender.isOn) forKey:sender.accessibilityIdentifier];
}

- (void)toggleTranslation:(UISwitch *)sender {
    [self setSettings:@{@"lyricsTranslationEnabled": @(sender.isOn),
                        @"bilingualLyrics": @(sender.isOn),
                        @"syncedLyricsEnabled": @(sender.isOn)}
      notificationKey:@"lyricsTranslationEnabled"];
}

- (void)showOptionPickerWithTitle:(NSString *)title key:(NSString *)key options:(NSArray<NSDictionary *> *)options reloadSections:(NSIndexSet *)sections {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSDictionary *option in options) {
        NSString *value = option[@"key"];
        [alert addAction:[UIAlertAction actionWithTitle:option[@"title"] style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            [self setSetting:value forKey:key];
            [self.tableView reloadSections:sections withRowAnimation:UITableViewRowAnimationAutomatic];
        }]];
    }
    [alert addAction:[UIAlertAction actionWithTitle:LOC(@"CANCEL") style:UIAlertActionStyleCancel handler:nil]];
    alert.popoverPresentationController.sourceView = self.view;
    alert.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width / 2.0, self.view.bounds.size.height / 2.0, 1, 1);
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)showProviderPicker {
    [self showOptionPickerWithTitle:LOC(@"TRANSLATION_PROVIDER")
                                key:@"translationProvider"
                            options:[self translationProviderOptions]
                     reloadSections:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(3, 2)]];
}

- (void)showLanguagePicker {
    YTMUTranslationLanguageController *controller = [[YTMUTranslationLanguageController alloc] initWithStyle:UITableViewStyleInsetGrouped];
    controller.title = LOC(@"TRANSLATION_TARGET_LANG");
    controller.languages = [self languageOptions];
    controller.selectedCode = [self stringSetting:@"translationTargetLang" fallback:@"auto"];
    controller.selectionHandler = ^(NSString *code) {
        [self setSetting:code forKey:@"translationTargetLang"];
        [self.tableView reloadRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:1 inSection:3]] withRowAnimation:UITableViewRowAnimationAutomatic];
    };
    [self.navigationController pushViewController:controller animated:YES];
}

- (void)clearCaches {
    UIActivityIndicatorView *activityIndicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    [activityIndicator startAnimating];
    UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:6]];
    cell.accessoryView = activityIndicator;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSUInteger translations = [[YTMUTranslationCache sharedCache] clearAll];
        NSUInteger lyrics = [[YTMULyricsCache sharedCache] clearAll];
        [[YTMULyricsManager sharedManager] clearRomanizationCache];
        [[YTMULyricsTitleNormalizer sharedNormalizer] clearCache];
        [[YTMULyricsDescriptionExtractor sharedExtractor] clearCache];
        [[YTMUInnerTubeDescriptionFetcher sharedFetcher] clearCache];
        dispatch_async(dispatch_get_main_queue(), ^{
            cell.accessoryView = nil;
            NSString *format = [NSBundle.ytmu_defaultBundle localizedStringForKey:@"TRANSLATION_CACHE_CLEARED_FORMAT"
                                                                            value:@"Lyrics: %lu\nTranslations: %lu\nRomanization: memory cleared"
                                                                            table:nil];
            NSString *message = [NSString stringWithFormat:format, (unsigned long)lyrics, (unsigned long)translations];
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:LOC(@"DONE") message:message preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:LOC(@"DONE") style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:alert animated:YES completion:nil];
        });
    });
}

- (void)textFieldDidEndEditing:(UITextField *)textField {
    if (self.activeTextField == textField) self.activeTextField = nil;
    NSString *key = textField.accessibilityIdentifier;
    if (!key.length) return;
    NSString *value = [textField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] ?: @"";
    [self setSetting:value forKey:key];
    textField.text = [self stringSetting:key fallback:textField.placeholder ?: @""];
}

- (UIView *)KBToolbar:(UITextField *)textField {
    UIToolbar *toolbar = [[UIToolbar alloc] initWithFrame:CGRectMake(0, 0, CGRectGetWidth(self.view.frame), 44)];
    toolbar.barStyle = UIBarStyleDefault;
    UIBarButtonItem *flexibleSpace = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
    UIBarButtonItem *hideKeyboardButton = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(hideKeyboard)];
    [toolbar setItems:@[flexibleSpace, hideKeyboardButton]];
    return toolbar;
}

- (void)hideKeyboard {
    [self.view endEditing:YES];
}

@end
