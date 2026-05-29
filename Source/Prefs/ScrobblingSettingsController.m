#import "ScrobblingSettingsController.h"
#import "../Headers/ABCSwitch.h"
#import "../Scrobbling/YTMUScrobbleManager.h"
#import "../Scrobbling/YTMUScrobbleTypes.h"
#import "../Scrobbling/Providers/YTMULastFMScrobbler.h"
#import "../Scrobbling/Providers/YTMUListenBrainzScrobbler.h"

// Section layout. Mirrors the TranslationSettingsController style
// (numbered sections with a fixed shape rather than a dynamic
// section list) so the table view code stays linear and predictable.
typedef NS_ENUM(NSInteger, ScrobblingSection) {
    ScrobblingSectionMaster = 0,
    ScrobblingSectionLastFM,
    ScrobblingSectionListenBrainz,
    ScrobblingSectionDebug,
    ScrobblingSectionCount,
};

@interface ScrobblingSettingsController ()
// Cached pending token from last.fm step 1. Held in memory only —
// users either complete step 2 immediately after, or abandon the
// flow entirely. No reason to persist this.
@property (nonatomic, copy, nullable) NSString *lastfmPendingToken;
@end

@implementation ScrobblingSettingsController

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = LOC(@"SCROBBLING_SETTINGS");

    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    [self.view addSubview:self.tableView];

    [NSLayoutConstraint activateConstraints:@[
        [self.tableView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
    ]];

    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserver:self selector:@selector(keyboardWillShow:) name:UIKeyboardWillShowNotification object:nil];
    [nc addObserver:self selector:@selector(keyboardWillHide:) name:UIKeyboardWillHideNotification object:nil];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Cell helpers

// Standard ABCSwitch row. NSUserDefaults key is the switch's
// accessibilityIdentifier — same convention as TranslationSettings.
- (UITableViewCell *)switchCellWithTitle:(NSString *)title
                                  detail:(nullable NSString *)detail
                                     key:(NSString *)key
                                fallback:(BOOL)fallback
                                  action:(SEL)action {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"switchCell"];
    cell.textLabel.text = title;
    cell.detailTextLabel.text = detail;
    cell.detailTextLabel.numberOfLines = 0;
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    ABCSwitch *switchControl = [[NSClassFromString(@"ABCSwitch") alloc] init];
    switchControl.onTintColor = [UIColor colorWithRed:30.0/255.0 green:150.0/255.0 blue:245.0/255.0 alpha:1.0];
    switchControl.on = YTMUScrobbleDefaultsBool(key, fallback);
    switchControl.accessibilityIdentifier = key;
    [switchControl addTarget:self action:action forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = switchControl;
    return cell;
}

- (UITableViewCell *)textFieldCellWithTitle:(NSString *)title
                                        key:(NSString *)key
                                placeholder:(nullable NSString *)placeholder
                                     secure:(BOOL)secure {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"textFieldCell"];
    cell.textLabel.text = title;
    cell.textLabel.adjustsFontSizeToFitWidth = YES;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    UITextField *textField = [[UITextField alloc] initWithFrame:CGRectMake(0, 0, 210, 36)];
    textField.text = YTMUScrobbleDefaultsString(key, @"");
    textField.placeholder = placeholder ?: @"";
    textField.font = [UIFont systemFontOfSize:13.0];
    textField.textAlignment = NSTextAlignmentRight;
    textField.autocorrectionType = UITextAutocorrectionTypeNo;
    textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    textField.clearButtonMode = UITextFieldViewModeWhileEditing;
    textField.secureTextEntry = secure;
    textField.accessibilityIdentifier = key;
    textField.inputAccessoryView = [self keyboardToolbar];
    textField.delegate = self;
    cell.accessoryView = textField;
    return cell;
}

- (UITableViewCell *)buttonCellWithTitle:(NSString *)title color:(UIColor *)color {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"buttonCell"];
    cell.textLabel.text = title;
    cell.textLabel.textColor = color;
    cell.textLabel.textAlignment = NSTextAlignmentCenter;
    return cell;
}

- (UITableViewCell *)statusCellWithTitle:(NSString *)title detail:(nullable NSString *)detail tint:(UIColor *)tint {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"statusCell"];
    cell.textLabel.text = title;
    cell.detailTextLabel.text = detail ?: @"";
    cell.detailTextLabel.textColor = tint;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    return cell;
}

- (UIView *)keyboardToolbar {
    UIToolbar *toolbar = [[UIToolbar alloc] initWithFrame:CGRectMake(0, 0, CGRectGetWidth(self.view.frame), 44)];
    toolbar.barStyle = UIBarStyleDefault;
    UIBarButtonItem *flex = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
    UIBarButtonItem *done = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(hideKeyboard)];
    [toolbar setItems:@[flex, done]];
    return toolbar;
}

- (void)hideKeyboard {
    [self.view endEditing:YES];
}

#pragma mark - Table view layout

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return ScrobblingSectionCount;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch (section) {
        case ScrobblingSectionMaster: return 1;
        case ScrobblingSectionLastFM: return 5;
        case ScrobblingSectionListenBrainz: return 4;
        case ScrobblingSectionDebug: return 1;
        default: return 0;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case ScrobblingSectionLastFM: return LOC(@"SCROBBLE_LASTFM_HEADER");
        case ScrobblingSectionListenBrainz: return LOC(@"SCROBBLE_LISTENBRAINZ_HEADER");
        default: return nil;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == ScrobblingSectionMaster) return LOC(@"SCROBBLE_MASTER_FOOTER");
    if (section == ScrobblingSectionLastFM) return LOC(@"SCROBBLE_LASTFM_FOOTER");
    if (section == ScrobblingSectionListenBrainz) return LOC(@"SCROBBLE_LISTENBRAINZ_FOOTER");
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    switch ((ScrobblingSection)indexPath.section) {
        case ScrobblingSectionMaster:
            return [self switchCellWithTitle:LOC(@"SCROBBLE_MASTER_ENABLE")
                                      detail:nil
                                         key:@"scrobblingEnabled"
                                    fallback:NO
                                      action:@selector(toggleMaster:)];

        case ScrobblingSectionLastFM:
            switch (indexPath.row) {
                case 0: return [self switchCellWithTitle:LOC(@"SCROBBLE_LASTFM_ENABLE")
                                                  detail:nil
                                                     key:@"lastfm_enabled"
                                                fallback:NO
                                                  action:@selector(toggleProvider:)];
                case 1: return [self textFieldCellWithTitle:LOC(@"SCROBBLE_API_KEY")
                                                        key:@"lastfm_apiKey"
                                                placeholder:@""
                                                     secure:NO];
                case 2: return [self textFieldCellWithTitle:LOC(@"SCROBBLE_API_SECRET")
                                                        key:@"lastfm_apiSecret"
                                                placeholder:@""
                                                     secure:YES];
                case 3: {
                    BOOL authed = [[YTMUScrobbleManager sharedManager].lastfm authenticatedUsername] != nil;
                    NSString *title = self.lastfmPendingToken
                        ? LOC(@"SCROBBLE_LASTFM_FINISH_AUTH")
                        : (authed ? LOC(@"SCROBBLE_LASTFM_SIGN_OUT") : LOC(@"SCROBBLE_LASTFM_AUTHENTICATE"));
                    UIColor *color = authed ? [UIColor systemRedColor] : self.view.tintColor;
                    return [self buttonCellWithTitle:title color:color];
                }
                case 4: {
                    NSString *username = [[YTMUScrobbleManager sharedManager].lastfm authenticatedUsername];
                    NSString *detail = username.length
                        ? [NSString stringWithFormat:LOC(@"SCROBBLE_CONNECTED_AS"), username]
                        : LOC(@"SCROBBLE_NOT_CONNECTED");
                    UIColor *tint = username.length ? [UIColor systemGreenColor] : [UIColor secondaryLabelColor];
                    return [self statusCellWithTitle:LOC(@"SCROBBLE_STATUS") detail:detail tint:tint];
                }
                default: break;
            }
            break;

        case ScrobblingSectionListenBrainz:
            switch (indexPath.row) {
                case 0: return [self switchCellWithTitle:LOC(@"SCROBBLE_LISTENBRAINZ_ENABLE")
                                                  detail:nil
                                                     key:@"listenbrainz_enabled"
                                                fallback:NO
                                                  action:@selector(toggleProvider:)];
                case 1: return [self textFieldCellWithTitle:LOC(@"SCROBBLE_USER_TOKEN")
                                                        key:@"listenbrainz_userToken"
                                                placeholder:@""
                                                     secure:YES];
                case 2: return [self textFieldCellWithTitle:LOC(@"SCROBBLE_API_ROOT")
                                                        key:@"listenbrainz_apiRoot"
                                                placeholder:@"https://api.listenbrainz.org"
                                                     secure:NO];
                case 3: return [self buttonCellWithTitle:LOC(@"SCROBBLE_LISTENBRAINZ_VALIDATE") color:self.view.tintColor];
                default: break;
            }
            break;

        case ScrobblingSectionDebug:
            return [self switchCellWithTitle:LOC(@"SCROBBLE_DEBUG_LOGS")
                                      detail:LOC(@"SCROBBLE_DEBUG_LOGS_DESC")
                                         key:@"scrobbleDebugLogs"
                                    fallback:NO
                                      action:@selector(toggleSwitch:)];
        default: break;
    }
    return [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"empty"];
}

#pragma mark - Selection

- (BOOL)tableView:(UITableView *)tableView shouldHighlightRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == ScrobblingSectionLastFM && indexPath.row == 3) return YES;
    if (indexPath.section == ScrobblingSectionListenBrainz && indexPath.row == 3) return YES;
    return NO;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == ScrobblingSectionLastFM && indexPath.row == 3) {
        [self handleLastFMButton];
    } else if (indexPath.section == ScrobblingSectionListenBrainz && indexPath.row == 3) {
        [self handleListenBrainzValidate];
    }
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
}

#pragma mark - Toggles

- (void)toggleMaster:(UISwitch *)sender {
    YTMUScrobbleSetDefaults(@"scrobblingEnabled", @(sender.isOn));
    if (sender.isOn) [[YTMUScrobbleManager sharedManager] flushQueueIfPossible];
}

- (void)toggleProvider:(UISwitch *)sender {
    YTMUScrobbleSetDefaults(sender.accessibilityIdentifier, @(sender.isOn));
    if (sender.isOn) [[YTMUScrobbleManager sharedManager] flushQueueIfPossible];
}

- (void)toggleSwitch:(UISwitch *)sender {
    YTMUScrobbleSetDefaults(sender.accessibilityIdentifier, @(sender.isOn));
}

#pragma mark - Last.fm auth flow

- (void)handleLastFMButton {
    YTMULastFMScrobbler *lastfm = [YTMUScrobbleManager sharedManager].lastfm;

    if ([lastfm authenticatedUsername]) {
        // Already authed → sign out.
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:LOC(@"SCROBBLE_LASTFM_SIGN_OUT")
                                                                       message:nil
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:LOC(@"CANCEL") style:UIAlertActionStyleCancel handler:nil]];
        [alert addAction:[UIAlertAction actionWithTitle:LOC(@"SCROBBLE_LASTFM_SIGN_OUT") style:UIAlertActionStyleDestructive handler:^(UIAlertAction *_) {
            [lastfm signOut];
            [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:ScrobblingSectionLastFM] withRowAnimation:UITableViewRowAnimationAutomatic];
        }]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }

    if (self.lastfmPendingToken) {
        // Step 2 — user has approved in Safari, now fetch session.
        [lastfm fetchSessionWithToken:self.lastfmPendingToken completion:^(NSString *username, NSError *err) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self.lastfmPendingToken = nil;
                if (username) {
                    [self showAlert:LOC(@"SCROBBLE_LASTFM_AUTHENTICATED") message:[NSString stringWithFormat:LOC(@"SCROBBLE_CONNECTED_AS"), username]];
                } else {
                    [self showAlert:LOC(@"SCROBBLE_LASTFM_AUTH_FAILED") message:err.localizedDescription];
                }
                [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:ScrobblingSectionLastFM] withRowAnimation:UITableViewRowAnimationAutomatic];
            });
        }];
        return;
    }

    // Step 1 — fetch a fresh token, then prompt user to open Safari.
    [lastfm fetchAuthTokenWithCompletion:^(NSString *token, NSError *err) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!token) {
                [self showAlert:LOC(@"SCROBBLE_LASTFM_AUTH_FAILED") message:err.localizedDescription];
                return;
            }
            self.lastfmPendingToken = token;
            NSString *apiKey = YTMUScrobbleDefaultsString(@"lastfm_apiKey", @"");
            NSString *authURL = [NSString stringWithFormat:@"https://www.last.fm/api/auth/?api_key=%@&token=%@",
                                 [apiKey stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]] ?: apiKey,
                                 [token stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]] ?: token];
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:LOC(@"SCROBBLE_LASTFM_OPEN_BROWSER")
                                                                           message:LOC(@"SCROBBLE_LASTFM_OPEN_BROWSER_MSG")
                                                                    preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:LOC(@"CANCEL") style:UIAlertActionStyleCancel handler:^(UIAlertAction *_) {
                self.lastfmPendingToken = nil;
            }]];
            [alert addAction:[UIAlertAction actionWithTitle:LOC(@"SCROBBLE_LASTFM_OPEN_SAFARI") style:UIAlertActionStyleDefault handler:^(UIAlertAction *_) {
                NSURL *url = [NSURL URLWithString:authURL];
                if ([[UIApplication sharedApplication] canOpenURL:url]) {
                    [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
                }
                [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:ScrobblingSectionLastFM] withRowAnimation:UITableViewRowAnimationAutomatic];
            }]];
            [self presentViewController:alert animated:YES completion:nil];
        });
    }];
}

- (void)handleListenBrainzValidate {
    YTMUListenBrainzScrobbler *lb = [YTMUScrobbleManager sharedManager].listenbrainz;
    [lb validateTokenWithCompletion:^(BOOL ok, NSString *username, NSError *err) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (ok) {
                [self showAlert:LOC(@"SCROBBLE_LISTENBRAINZ_OK") message:[NSString stringWithFormat:LOC(@"SCROBBLE_CONNECTED_AS"), username ?: @"?"]];
            } else {
                [self showAlert:LOC(@"SCROBBLE_LISTENBRAINZ_FAIL") message:err.localizedDescription];
            }
        });
    }];
}

- (void)showAlert:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:LOC(@"DONE") style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Text field

- (void)textFieldDidBeginEditing:(UITextField *)textField {
    self.activeTextField = textField;
}

- (void)textFieldDidEndEditing:(UITextField *)textField {
    if (self.activeTextField == textField) self.activeTextField = nil;
    NSString *key = textField.accessibilityIdentifier;
    if (!key.length) return;
    NSString *value = [textField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] ?: @"";
    YTMUScrobbleSetDefaults(key, value);
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

#pragma mark - Keyboard avoidance (copied from TranslationSettings)

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
    } completion:nil];
}

- (void)keyboardWillHide:(NSNotification *)note {
    NSTimeInterval duration = [note.userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue];
    UIViewAnimationCurve curve = (UIViewAnimationCurve)[note.userInfo[UIKeyboardAnimationCurveUserInfoKey] integerValue];
    [UIView animateWithDuration:duration delay:0 options:(UIViewAnimationOptions)(curve << 16) animations:^{
        UIEdgeInsets inset = self.tableView.contentInset;
        inset.bottom = 0;
        self.tableView.contentInset = inset;
    } completion:nil];
}

@end
