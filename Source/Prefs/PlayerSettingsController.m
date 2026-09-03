#import "PlayerSettingsController.h"
#import "../Utils/YTMUSettings.h"

@implementation PlayerSettingsController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = LOC(@"PLAYER_SETTINGS");
}

- (NSArray<NSDictionary *> *)playerRows {
    return @[
        @{@"title": LOC(@"DOWNLOAD_AUDIO"), @"desc": LOC(@"DOWNLOAD_AUDIO_DESC"), @"key": @"downloadAudio"},
        @{@"title": LOC(@"DOWNLOAD_COVER"), @"desc": LOC(@"DOWNLOAD_COVER_DESC"), @"key": @"downloadCoverImage"},
        @{@"title": LOC(@"PLAYBACK_RATE_BUTTON"), @"desc": LOC(@"PLAYBACK_RATE_BUTTON_DESC"), @"key": @"playbackRateButton"},
        @{@"title": LOC(@"VOLBAR"), @"desc": LOC(@"VOLBAR_DESC"), @"key": @"volBar"},
        @{@"title": LOC(@"NO_AUTORADIO"), @"desc": LOC(@"NO_AUTORADIO_DESC"), @"key": @"disableAutoRadio"},
        @{@"title": LOC(@"SKIP_CONTENT_WARNING"), @"desc": LOC(@"SKIP_CONTENT_WARNING_DESC"), @"key": @"skipWarning"},
    ];
}

#pragma mark - Table view

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 4;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch (section) {
        case 0: return [self playerRows].count;
        case 2: return 3;
        case 3: return 2;
        default: return 1;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return section == 3 ? LOC(@"SEEK_TIME_FOOTER") : nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 0) {
        NSArray<NSDictionary *> *rows = [self playerRows];
        NSDictionary *row = rows[MIN((NSUInteger)indexPath.row, rows.count - 1)];
        return [self switchCellWithTitle:row[@"title"] detail:row[@"desc"] key:row[@"key"] fallback:NO];
    }
    if (indexPath.section == 1) {
        NSArray *items = @[[UIImage systemImageNamed:@"music.note"] ?: @"A", [UIImage systemImageNamed:@"film"] ?: @"V"];
        return [self segmentedCellWithTitle:LOC(@"AV_DEFAULT_MODE") items:items key:@"audioVideoMode" fallback:0];
    }
    if (indexPath.section == 2) {
        if (indexPath.row == 0) {
            return [self switchCellWithTitle:LOC(@"SKIP_NONMUSIC_PARTS") detail:LOC(@"SKIP_NONMUSIC_PARTS_DESC") key:@"sponsorBlock" fallback:NO];
        }
        if (indexPath.row == 1) {
            return [self segmentedCellWithTitle:LOC(@"SB_BEHAVIOR") items:@[LOC(@"SB_SKIP"), LOC(@"SB_ASK")] key:@"sbSkipMode" fallback:0];
        }
        return [self sponsorDurationCell];
    }
    if (indexPath.row == 0) {
        return [self switchCellWithTitle:LOC(@"SEEK_BUTTONS") detail:nil key:@"seekButtons" fallback:NO];
    }
    return [self fullWidthSegmentedCellWithItems:@[LOC(@"DEFAULT"), @"10", @"20", @"30", @"60"] key:@"seekTime" fallback:0];
}

- (UITableViewCell *)sponsorDurationCell {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"sbDurationCell"];
    cell.textLabel.text = LOC(@"SB_NOTIF_DURATION");
    cell.textLabel.adjustsFontSizeToFitWidth = YES;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;

    UITextField *textField = [[UITextField alloc] initWithFrame:CGRectMake(0, 0, 80, 44)];
    textField.text = [NSString stringWithFormat:@"%ld", (long)YTMUSettingsInteger(@"sbDuration", 10)];
    textField.font = [UIFont systemFontOfSize:13.0];
    textField.keyboardType = UIKeyboardTypeNumberPad;
    textField.textAlignment = NSTextAlignmentRight;
    textField.inputAccessoryView = [self KBToolbar:textField];
    textField.delegate = self;
    cell.accessoryView = textField;
    return cell;
}

#pragma mark - SponsorBlock toast duration

- (void)textFieldDidEndEditing:(UITextField *)textField {
    NSArray *emptyVals = @[@"", @"0"];
    NSInteger duration = [emptyVals containsObject:textField.text ?: @""] ? 10 : [textField.text integerValue];
    if (duration <= 0) duration = 10;
    YTMUSettingsSetObject(@"sbDuration", @(duration));
    textField.text = [NSString stringWithFormat:@"%ld", (long)duration];
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
