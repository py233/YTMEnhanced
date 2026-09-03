#import "FFMpegDownloader.h"

@implementation FFMpegDownloader {
    Statistics *statistics;
    BOOL cancelControlsInstalled;
}

- (void)statisticsCallback:(Statistics *)newStatistics {
    dispatch_async(dispatch_get_main_queue(), ^{
        self->statistics = newStatistics;
        [self updateProgressDialog];
    });
}

- (void)showResultHUDWithText:(NSString *)text icon:(NSString *)iconName {
    [self.hud hideAnimated:NO];
    self.hud = [MBProgressHUD showHUDAddedTo:[UIApplication sharedApplication].keyWindow animated:YES];
    self.hud.mode = MBProgressHUDModeCustomView;
    self.hud.label.text = text;
    self.hud.label.numberOfLines = 0;
    UIImageView *iconView = [[UIImageView alloc] initWithImage:[self imageWithSystemIconNamed:iconName]];
    iconView.contentMode = UIViewContentModeScaleAspectFit;
    self.hud.customView = iconView;
    [self.hud hideAnimated:YES afterDelay:3.0];
}

- (void)downloadAudio:(NSString *)audioURL {
    statistics = nil;
    cancelControlsInstalled = NO;
    [MobileFFmpegConfig resetStatistics];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self setActive];
    });

    self.hud = [MBProgressHUD showHUDAddedTo:[UIApplication sharedApplication].keyWindow animated:YES];
    self.hud.mode = MBProgressHUDModeAnnularDeterminate;
    self.hud.label.text = LOC(@"DOWNLOADING");

    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSURL *documentsURL = [[fileManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask] lastObject];
    NSURL *destinationURL = [documentsURL URLByAppendingPathComponent:[NSString stringWithFormat:@"%@.m4a", self.tempName]];
    NSURL *folderURL = [documentsURL URLByAppendingPathComponent:@"YTMusicUltimate"];
    NSURL *outputURL = [folderURL URLByAppendingPathComponent:[NSString stringWithFormat:@"%@.m4a", self.mediaName]];
    [fileManager createDirectoryAtURL:folderURL withIntermediateDirectories:YES attributes:nil error:nil];
    [fileManager removeItemAtURL:destinationURL error:nil];

    [MobileFFmpegConfig setLogDelegate:self];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // Argument array, not a command string: the HLS URL carries query
        // parameters and the destination path carries the song title, and
        // the string parser splits both on spaces and quotes.
        int returnCode = [MobileFFmpeg executeWithArguments:@[@"-i", audioURL, @"-c", @"copy", destinationURL.path]];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (returnCode == RETURN_CODE_SUCCESS) {
                // A previous download of the same song must not make the
                // move fail (moveItemAtURL: refuses to overwrite).
                [fileManager removeItemAtURL:outputURL error:nil];
                NSError *moveError = nil;
                BOOL isMoved = [fileManager moveItemAtURL:destinationURL toURL:outputURL error:&moveError];
                if (isMoved) {
                    [[NSNotificationCenter defaultCenter] postNotificationName:@"ReloadDataNotification" object:nil];
                    [self showResultHUDWithText:LOC(@"DONE") icon:@"checkmark"];
                } else {
                    NSLog(@"[YTMUDownload] could not move %@ to %@: %@", destinationURL.path, outputURL.path, moveError);
                    [fileManager removeItemAtURL:destinationURL error:nil];
                    [self showResultHUDWithText:LOC(@"OOPS") icon:@"xmark"];
                }
            } else if (returnCode == RETURN_CODE_CANCEL) {
                [self.hud hideAnimated:YES];
                [fileManager removeItemAtURL:destinationURL error:nil];
            } else {
                NSLog(@"[YTMUDownload] ffmpeg failed rc=%d output=%@", returnCode, [MobileFFmpegConfig getLastCommandOutput]);
                [fileManager removeItemAtURL:destinationURL error:nil];
                [self showResultHUDWithText:LOC(@"OOPS") icon:@"xmark"];
            }
        });
    });
}

- (void)logCallback:(long)executionId :(int)level :(NSString*)message {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSLog(@"%@", message);
    });
}

- (void)setActive {
    [MobileFFmpegConfig setLogDelegate:self];
    [MobileFFmpegConfig setStatisticsDelegate:self];
}

// The HUD's own button becomes "Cancel" (stops ffmpeg) and a small close
// button in the corner just hides the HUD. Built once per download; the
// statistics callback used to re-add the targets on every tick.
- (void)installCancelControlsIfNeeded {
    if (cancelControlsInstalled || !self.hud) return;
    cancelControlsInstalled = YES;

    [self.hud.button setTitle:LOC(@"CANCEL") forState:UIControlStateNormal];
    [self.hud.button addTarget:self action:@selector(cancelDownloading:) forControlEvents:UIControlEventTouchUpInside];

    UIView *buttonSuperview = self.hud.button.superview;
    if (!buttonSuperview || [buttonSuperview viewWithTag:998]) return;
    UIButton *cancelButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [cancelButton setTag:998];
    UIImage *cancelImage = [[UIImage systemImageNamed:@"x.circle"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    [cancelButton setImage:cancelImage forState:UIControlStateNormal];
    [cancelButton setTintColor:[[UIColor labelColor] colorWithAlphaComponent:0.7]];
    [cancelButton addTarget:self action:@selector(cancelHUD:) forControlEvents:UIControlEventTouchUpInside];
    [buttonSuperview addSubview:cancelButton];
    cancelButton.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [cancelButton.topAnchor constraintEqualToAnchor:buttonSuperview.topAnchor constant:5.0],
        [cancelButton.leadingAnchor constraintEqualToAnchor:buttonSuperview.leadingAnchor constant:5.0],
        [cancelButton.widthAnchor constraintEqualToConstant:17.0],
        [cancelButton.heightAnchor constraintEqualToConstant:17.0]
    ]];
}

- (void)updateProgressDialog {
    if (statistics == nil) return;
    if (!self.hud || self.hud.mode != MBProgressHUDModeAnnularDeterminate) return;
    [self installCancelControlsIfNeeded];

    int timeInMilliseconds = [statistics getTime];
    if (timeInMilliseconds <= 0) return;
    if (self.duration <= 0) {
        // Unknown length: no percentage to show, but the elapsed time is
        // still worth something.
        self.hud.detailsLabel.text = [NSString stringWithFormat:@"%d s", timeInMilliseconds / 1000];
        return;
    }
    double percentage = MIN(1.0, (timeInMilliseconds / 1000.0) / (double)self.duration);
    self.hud.progress = percentage;
    self.hud.detailsLabel.text = [NSString stringWithFormat:@"%d%%", (int)(percentage * 100)];
}

- (void)cancelDownloading:(UIButton *)sender {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [MobileFFmpeg cancel];
    });
}

- (void)cancelHUD:(UIButton *)sender {
    [self.hud hideAnimated:YES];
}

- (void)downloadImage:(NSURL *)link {
    // Fetch off the main thread (the old version blocked the UI for the
    // whole round trip); all HUD / Photos work stays on main.
    dispatch_async(dispatch_get_main_queue(), ^{
        self.hud = [MBProgressHUD showHUDAddedTo:[UIApplication sharedApplication].keyWindow animated:YES];
        self.hud.mode = MBProgressHUDModeIndeterminate;
    });
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSData *imageData = link ? [NSData dataWithContentsOfURL:link] : nil;
        UIImage *image = imageData ? [UIImage imageWithData:imageData] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (image) UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil);
            [self.hud hideAnimated:NO];
            self.hud = [MBProgressHUD showHUDAddedTo:[UIApplication sharedApplication].keyWindow animated:YES];
            self.hud.mode = MBProgressHUDModeCustomView;
            self.hud.label.text = image ? LOC(@"SAVED_TO_PHOTOS") : LOC(@"LINK_NOT_FOUND");

            UIImageView *iconView = [[UIImageView alloc] initWithImage:[self imageWithSystemIconNamed:image ? @"checkmark" : @"xmark"]];
            iconView.contentMode = UIViewContentModeScaleAspectFit;
            self.hud.customView = iconView;

            [self.hud hideAnimated:YES afterDelay:2.0];
        });
    });
}

- (UIImage *)imageWithSystemIconNamed:(NSString *)iconName {
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(36, 36)];
    UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext * _Nonnull rendererContext) {
        UIImage *iconImage = [UIImage systemImageNamed:iconName];
        UIView *imageView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 36, 36)];
        UIImageView *iconImageView = [[UIImageView alloc] initWithImage:iconImage];
        iconImageView.contentMode = UIViewContentModeScaleAspectFit;
        iconImageView.clipsToBounds = YES;
        iconImageView.tintColor = [[UIColor labelColor] colorWithAlphaComponent:0.7f];
        iconImageView.frame = imageView.bounds;

        [imageView addSubview:iconImageView];
        [imageView.layer renderInContext:rendererContext.CGContext];
    }];
    return image;
}

- (void)shareMedia:(NSURL *)mediaURL {
    UIActivityViewController *activityViewController = [[UIActivityViewController alloc] initWithActivityItems:@[mediaURL] applicationActivities:nil];
    activityViewController.excludedActivityTypes = @[UIActivityTypeAssignToContact, UIActivityTypePrint];

    [activityViewController setCompletionWithItemsHandler:^(NSString *activityType, BOOL completed, NSArray *returnedItems, NSError *activityError) {
        [[NSFileManager defaultManager] removeItemAtURL:mediaURL error:nil];
    }];

    UIViewController *rootViewController = [UIApplication sharedApplication].keyWindow.rootViewController;
    [rootViewController presentViewController:activityViewController animated:YES completion:nil];
}

@end
