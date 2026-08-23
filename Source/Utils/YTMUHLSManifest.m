#import "YTMUHLSManifest.h"

NSString *YTMUHLSAudioStreamURLFromManifest(NSString *manifest) {
    if (!manifest.length) return nil;
    NSArray<NSString *> *lines = [manifest componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    for (NSString *groupID in @[@"234", @"233"]) {   // preference order
        NSString *needle = [NSString stringWithFormat:@"TYPE=AUDIO,GROUP-ID=\"%@\"", groupID];
        for (NSString *line in lines) {
            if (![line containsString:needle]) continue;
            NSRange start = [line rangeOfString:@"https://"];
            if (start.location == NSNotFound) continue;
            NSRange end = [line rangeOfString:@"index.m3u8" options:0 range:NSMakeRange(start.location, line.length - start.location)];
            if (end.location == NSNotFound) continue;
            return [line substringWithRange:NSMakeRange(start.location, NSMaxRange(end) - start.location)];
        }
    }
    return nil;
}
