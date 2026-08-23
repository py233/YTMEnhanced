#import <UIKit/UIKit.h>
#import "YTMULyricsTabOverlayView.h"
#import "../Headers/YTPlayerViewController.h"


// Full-screen modal host for YTMULyricsTabOverlayView, presented from the
// Lyrics chip in the Now Playing action bar.
@interface YTMULyricsPanelViewController : UIViewController
@property (retain, nonatomic) YTMULyricsTabOverlayView *lyricsOverlayView;
@property (retain, nonatomic) UIButton *closeButton;
@property (assign, nonatomic) YTPlayerViewController *playerViewController;
@end

