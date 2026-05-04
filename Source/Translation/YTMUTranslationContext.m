#import "YTMUTranslationContext.h"
#import "YTMUTranslationTypes.h"

@interface YTMUTranslationContext ()
@property (nonatomic, copy, readwrite) NSString *videoId;
@property (nonatomic, copy, readwrite) NSString *title;
@property (nonatomic, copy, readwrite) NSString *artist;
@end

@implementation YTMUTranslationContext

+ (instancetype)sharedContext {
    static YTMUTranslationContext *context;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        context = [[self alloc] init];
    });
    return context;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _videoId = @"";
        _title = @"";
        _artist = @"";
    }
    return self;
}

- (void)updateWithVideoId:(NSString *)videoId title:(NSString *)title artist:(NSString *)artist {
    @synchronized (self) {
        _videoId = [videoId copy] ?: @"";
        _title = [title copy] ?: @"";
        _artist = [artist copy] ?: @"";
    }
    YTMUTranslationLog(@"context updated videoId=%@ title=%@ artist=%@",
                       videoId.length ? videoId : @"<empty>",
                       title.length ? title : @"<empty>",
                       artist.length ? artist : @"<empty>");
}

@end
