#import "TranslationSettingsController.h"
#import "../Translation/YTMUTranslationTypes.h"
#import "../Translation/YTMUPromptBuilder.h"
#import "../Translation/YTMUTranslationCache.h"

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
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"languageCell"];
    }

    NSDictionary *language = self.languages[indexPath.row];
    cell.textLabel.text = language[@"title"];
    cell.accessoryType = [language[@"code"] isEqualToString:self.selectedCode] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *language = self.languages[indexPath.row];
    NSString *code = language[@"code"];
    if (self.selectionHandler) self.selectionHandler(code);
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
    [self.view addSubview:self.tableView];

    [NSLayoutConstraint activateConstraints:@[
        [self.tableView.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.tableView.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [self.tableView.widthAnchor constraintEqualToAnchor:self.view.widthAnchor],
        [self.tableView.heightAnchor constraintEqualToAnchor:self.view.heightAnchor]
    ]];
}

- (void)ensureDefaults {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithDictionary:[defaults dictionaryForKey:@"YTMUltimate"] ?: @{}];
    if (dict[@"bilingualLyrics"] == nil) dict[@"bilingualLyrics"] = @(NO);
    if (dict[@"translationProvider"] == nil) dict[@"translationProvider"] = YTMUTranslationProviderGoogle;
    if (dict[@"translationTargetLang"] == nil) dict[@"translationTargetLang"] = @"auto";
    if (dict[@"translationBaseUrl"] == nil) dict[@"translationBaseUrl"] = @"https://api.openai.com/v1";
    if (dict[@"translationDebugLogs"] == nil) dict[@"translationDebugLogs"] = @(YES);
    [defaults setObject:dict forKey:@"YTMUltimate"];
}

- (NSMutableDictionary *)settings {
    return [NSMutableDictionary dictionaryWithDictionary:[[NSUserDefaults standardUserDefaults] dictionaryForKey:@"YTMUltimate"] ?: @{}];
}

- (void)setSetting:(id)value forKey:(NSString *)key {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSMutableDictionary *dict = [self settings];
    dict[key] = value ?: @"";
    [defaults setObject:dict forKey:@"YTMUltimate"];
}

- (NSString *)stringSetting:(NSString *)key fallback:(NSString *)fallback {
    id value = [self settings][key];
    if ([value isKindOfClass:[NSString class]] && [(NSString *)value length]) return value;
    return fallback ?: @"";
}

- (NSString *)currentProvider {
    NSString *provider = [self stringSetting:@"translationProvider" fallback:YTMUTranslationProviderGoogle];
    NSArray *valid = @[YTMUTranslationProviderGoogle, YTMUTranslationProviderAnthropic, YTMUTranslationProviderGemini, YTMUTranslationProviderOpenAI];
    return [valid containsObject:provider] ? provider : YTMUTranslationProviderGoogle;
}

- (NSArray<NSDictionary *> *)providerOptions {
    return @[
        @{@"key": YTMUTranslationProviderGoogle, @"title": LOC(@"PROVIDER_GOOGLE")},
        @{@"key": YTMUTranslationProviderAnthropic, @"title": LOC(@"PROVIDER_ANTHROPIC")},
        @{@"key": YTMUTranslationProviderGemini, @"title": LOC(@"PROVIDER_GEMINI")},
        @{@"key": YTMUTranslationProviderOpenAI, @"title": LOC(@"PROVIDER_OPENAI")},
    ];
}

- (NSString *)providerTitle:(NSString *)provider {
    for (NSDictionary *option in [self providerOptions]) {
        if ([option[@"key"] isEqualToString:provider]) return option[@"title"];
    }
    return provider;
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
    [rows addObject:@{
        @"title": LOC(@"TRANSLATION_API_KEY"),
        @"key": [@"translationApiKey_" stringByAppendingString:provider],
        @"secure": @(YES),
        @"fallback": @"",
    }];
    [rows addObject:@{
        @"title": LOC(@"TRANSLATION_MODEL"),
        @"key": [@"translationModel_" stringByAppendingString:provider],
        @"secure": @(NO),
        @"fallback": [self modelFallbackForProvider:provider],
    }];
    if ([provider isEqualToString:YTMUTranslationProviderOpenAI]) {
        [rows addObject:@{
            @"title": LOC(@"TRANSLATION_BASE_URL"),
            @"key": @"translationBaseUrl",
            @"secure": @(NO),
            @"fallback": @"https://api.openai.com/v1",
        }];
    }
    return rows;
}

- (NSArray<NSDictionary *> *)languageOptions {
    NSArray *codes = @[@"auto", @"zh-CN", @"zh-TW", @"en", @"ja", @"ko", @"fr", @"de", @"es", @"pt-BR", @"pt-PT", @"it", @"nl", @"ru", @"uk", @"pl", @"tr", @"ar", @"he", @"fa", @"hi", @"bn", @"ur", @"ta", @"te", @"mr", @"id", @"ms", @"vi", @"th", @"fil", @"sw", @"sv", @"no", @"da", @"fi", @"cs", @"ro", @"hu", @"el", @"bg", @"sr", @"hr", @"sk", @"lt"];
    NSMutableArray *languages = [NSMutableArray arrayWithCapacity:codes.count];
    for (NSString *code in codes) {
        [languages addObject:@{@"code": code, @"title": [self languageTitleForCode:code]}];
    }
    return languages;
}

- (NSString *)languageTitleForCode:(NSString *)code {
    if ([code isEqualToString:@"auto"]) return LOC(@"TRANSLATION_AUTO");

    NSDictionary *manual = @{
        @"zh-CN": @"Chinese (Simplified)",
        @"zh-TW": @"Chinese (Traditional)",
        @"pt-BR": @"Portuguese (Brazil)",
        @"pt-PT": @"Portuguese (Portugal)",
        @"fil": @"Filipino",
    };
    if (manual[code]) return manual[code];

    NSString *display = [[NSLocale currentLocale] displayNameForKey:NSLocaleIdentifier value:code];
    return display.length ? display : code;
}

#pragma mark - Table view

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    return UITableViewAutomaticDimension;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 4;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return 1;
    if (section == 1) return 2;
    if (section == 2) return [self providerConfigRows].count;
    if (section == 3) return 1;
    return 0;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSMutableDictionary *dict = [self settings];

    if (indexPath.section == 0) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"bilingualLyricsCell"];
        cell.textLabel.text = LOC(@"BILINGUAL_LYRICS");
        cell.detailTextLabel.text = LOC(@"BILINGUAL_LYRICS_DESC");
        cell.detailTextLabel.numberOfLines = 0;
        cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];

        ABCSwitch *switchControl = [[NSClassFromString(@"ABCSwitch") alloc] init];
        switchControl.onTintColor = [UIColor colorWithRed:30.0/255.0 green:150.0/255.0 blue:245.0/255.0 alpha:1.0];
        switchControl.on = [dict[@"bilingualLyrics"] boolValue];
        [switchControl addTarget:self action:@selector(toggleBilingualLyrics:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = switchControl;
        return cell;
    }

    if (indexPath.section == 1) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"choiceCell"];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        if (indexPath.row == 0) {
            NSString *provider = [self currentProvider];
            cell.textLabel.text = LOC(@"TRANSLATION_PROVIDER");
            cell.detailTextLabel.text = [self providerTitle:provider];
        } else {
            NSString *language = [self stringSetting:@"translationTargetLang" fallback:@"auto"];
            cell.textLabel.text = LOC(@"TRANSLATION_TARGET_LANG");
            cell.detailTextLabel.text = [self languageTitleForCode:language];
        }
        return cell;
    }

    if (indexPath.section == 2) {
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

    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"clearCacheCell"];
    cell.textLabel.text = LOC(@"TRANSLATION_CLEAR_CACHE");
    cell.textLabel.textColor = [UIColor systemRedColor];
    cell.imageView.image = [UIImage systemImageNamed:@"trash"];
    cell.imageView.tintColor = [UIColor systemRedColor];
    return cell;
}

- (BOOL)tableView:(UITableView *)tableView shouldHighlightRowAtIndexPath:(NSIndexPath *)indexPath {
    return indexPath.section == 1 || indexPath.section == 3;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 1 && indexPath.row == 0) {
        [self showProviderPicker];
    } else if (indexPath.section == 1 && indexPath.row == 1) {
        [self showLanguagePicker];
    } else if (indexPath.section == 3) {
        [self clearTranslationCache];
    }
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
}

#pragma mark - Actions

- (void)toggleBilingualLyrics:(UISwitch *)sender {
    [self setSetting:@([sender isOn]) forKey:@"bilingualLyrics"];
}

- (void)showProviderPicker {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:LOC(@"TRANSLATION_PROVIDER")
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSDictionary *option in [self providerOptions]) {
        NSString *key = option[@"key"];
        UIAlertAction *action = [UIAlertAction actionWithTitle:option[@"title"]
                                                         style:UIAlertActionStyleDefault
                                                       handler:^(UIAlertAction *action) {
            [self setSetting:key forKey:@"translationProvider"];
            NSIndexSet *sections = [NSIndexSet indexSetWithIndexesInRange:NSMakeRange(1, 2)];
            [self.tableView reloadSections:sections withRowAnimation:UITableViewRowAnimationAutomatic];
        }];
        [alert addAction:action];
    }
    [alert addAction:[UIAlertAction actionWithTitle:LOC(@"CANCEL") style:UIAlertActionStyleCancel handler:nil]];
    alert.popoverPresentationController.sourceView = self.view;
    alert.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width / 2.0, self.view.bounds.size.height / 2.0, 1, 1);
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)showLanguagePicker {
    YTMUTranslationLanguageController *controller = [[YTMUTranslationLanguageController alloc] initWithStyle:UITableViewStyleInsetGrouped];
    controller.title = LOC(@"TRANSLATION_TARGET_LANG");
    controller.languages = [self languageOptions];
    controller.selectedCode = [self stringSetting:@"translationTargetLang" fallback:@"auto"];
    controller.selectionHandler = ^(NSString *code) {
        [self setSetting:code forKey:@"translationTargetLang"];
        [self.tableView reloadRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:1 inSection:1]] withRowAnimation:UITableViewRowAnimationAutomatic];
    };
    [self.navigationController pushViewController:controller animated:YES];
}

- (void)clearTranslationCache {
    UIActivityIndicatorView *activityIndicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    [activityIndicator startAnimating];
    UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:3]];
    cell.accessoryView = activityIndicator;

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSUInteger count = [[YTMUTranslationCache sharedCache] clearAll];
        dispatch_async(dispatch_get_main_queue(), ^{
            cell.accessoryView = nil;
            NSString *message = [NSString stringWithFormat:@"%lu", (unsigned long)count];
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:LOC(@"DONE") message:message preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:LOC(@"DONE") style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:alert animated:YES completion:nil];
        });
    });
}

- (void)textFieldDidEndEditing:(UITextField *)textField {
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
