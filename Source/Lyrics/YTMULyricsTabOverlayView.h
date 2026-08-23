#import <UIKit/UIKit.h>
#import "../Headers/YTPlayerViewController.h"
#import "YTMUSyncedLyricsView.h"


// The in-app lyrics panel: source picker, now-playing header, plain / synced
// lyric body, font and timing controls. Hosted either inside the player tab
// (Source/SelectableLyrics.x) or in YTMULyricsPanelViewController.

@interface YTMULyricsTabOverlayView : UIView
@property (retain, nonatomic) UIScrollView *sourceScrollView;
@property (retain, nonatomic) NSArray *sourceButtons;
@property (retain, nonatomic) UIImageView *artworkImageView;
@property (retain, nonatomic) UILabel *nowPlayingTitleLabel;
@property (retain, nonatomic) UILabel *nowPlayingArtistLabel;
@property (retain, nonatomic) UIButton *menuButton;
@property (retain, nonatomic) UIView *headerSeparatorView;
@property (retain, nonatomic) UITextView *lyricsTextView;
@property (retain, nonatomic) YTMUSyncedLyricsView *syncedLyricsView;
@property (retain, nonatomic) UILabel *attributionLabel;
@property (retain, nonatomic) UIButton *fontDecreaseButton;
@property (retain, nonatomic) UIButton *fontIncreaseButton;
@property (retain, nonatomic) UILabel *fontSizeLabel;
@property (retain, nonatomic) UIButton *offsetDecreaseButton;
@property (retain, nonatomic) UIButton *offsetIncreaseButton;
@property (retain, nonatomic) UILabel *offsetLabel;
@property (retain, nonatomic) UIView *sheetBackdropView;
@property (retain, nonatomic) UIView *sheetContentView;
@property (retain, nonatomic) UILabel *sheetValueLabel;
@property (weak, nonatomic) UISlider *pendingFontSlider;
@property (assign, nonatomic) NSTimeInterval lastFontCommitTime;
@property (copy, nonatomic) NSString *lastRenderSignature;
@property (assign, nonatomic) YTPlayerViewController *playerViewController;
- (void)ytmu_renderTabOverlay;
- (void)ytmu_layoutSourceButtons;
- (void)ytmu_updateSourceButtons;
- (void)ytmu_updateFontControls;
- (void)ytmu_updateTimingControls;
- (void)ytmu_updateNowPlayingHeader;
- (void)ytmu_presentLyricsMenu:(UIButton *)sender;
- (void)ytmu_presentSourceMenuFromView:(UIView *)sourceView;
- (void)ytmu_presentSourceMenuFromCurrentSheet;
- (void)ytmu_presentFontSheet;
- (void)ytmu_presentTimingSheet;
- (UIButton *)ytmu_sheetDoneButtonAtY:(CGFloat)y title:(NSString *)title;
- (void)ytmu_sheetSwitchChanged:(UISwitch *)sender;
- (void)ytmu_sheetSourceSelected:(UIButton *)sender;
- (void)ytmu_fontSliderChanged:(UISlider *)sender;
- (void)ytmu_timingButtonTapped:(UIButton *)sender;
- (void)ytmu_dismissSheet;
- (void)ytmu_handleLyricsSettingsDidChange:(NSNotification *)notification;
- (void)ytmu_applyTimingOffsetChange;
- (void)ytmu_scrollSourceButtonIntoView:(UIButton *)button animated:(BOOL)animated;
- (void)ytmu_selectLyricsSource:(UIButton *)sender;
- (void)ytmu_cycleLyricsSource:(UISwipeGestureRecognizer *)gesture;
- (void)ytmu_adjustLyricsFontSize:(UIButton *)sender;
- (void)ytmu_adjustLyricsTiming:(UIButton *)sender;
- (void)ytmu_resetLyricsTiming:(UITapGestureRecognizer *)gesture;
@end

