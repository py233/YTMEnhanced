#import "YTMUTestHTTPServer.h"
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <errno.h>

@implementation YTMUTestHTTPRequest
@end

@interface YTMUTestHTTPServer ()
@property (nonatomic) int listenFD;
@property (nonatomic, strong) dispatch_source_t acceptSource;
@property (nonatomic, strong) dispatch_queue_t queue;
@property (nonatomic, strong) NSMutableArray<YTMUTestHTTPRequest *> *mutableRequests;
@property (nonatomic, readwrite) uint16_t port;
@end

@implementation YTMUTestHTTPServer

+ (instancetype)start {
    YTMUTestHTTPServer *s = [[self alloc] init];
    return [s bind] ? s : nil;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _responseStatus = 200;
        _responseHeaders = @{@"Content-Type": @"application/json"};
        _responseBody = [@"{}" dataUsingEncoding:NSUTF8StringEncoding];
        _mutableRequests = [NSMutableArray array];
        _queue = dispatch_queue_create("ytmu.test.http", DISPATCH_QUEUE_SERIAL);
        _listenFD = -1;
    }
    return self;
}

- (NSArray<YTMUTestHTTPRequest *> *)requests {
    @synchronized (self.mutableRequests) { return [self.mutableRequests copy]; }
}

- (NSString *)baseURL { return [NSString stringWithFormat:@"http://127.0.0.1:%u", self.port]; }

- (void)setJSONResponse:(id)object status:(NSInteger)status {
    self.responseBody = [NSJSONSerialization dataWithJSONObject:object options:0 error:nil] ?: [NSData data];
    self.responseHeaders = @{@"Content-Type": @"application/json"};
    self.responseStatus = status;
}

- (void)setTextResponse:(NSString *)text contentType:(NSString *)contentType status:(NSInteger)status {
    self.responseBody = [text dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
    self.responseHeaders = @{@"Content-Type": contentType ?: @"text/plain"};
    self.responseStatus = status;
}

- (BOOL)bind {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return NO;
    int yes = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
    struct sockaddr_in addr; memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET; addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK); addr.sin_port = 0;
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) { close(fd); return NO; }
    if (listen(fd, 16) != 0) { close(fd); return NO; }
    socklen_t len = sizeof(addr);
    getsockname(fd, (struct sockaddr *)&addr, &len);
    self.port = ntohs(addr.sin_port);
    self.listenFD = fd;

    __weak typeof(self) weakSelf = self;
    self.acceptSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)fd, 0, self.queue);
    dispatch_source_set_event_handler(self.acceptSource, ^{
        int client = accept(fd, NULL, NULL);
        if (client < 0) return;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ [weakSelf serveClient:client]; });
    });
    dispatch_resume(self.acceptSource);
    return YES;
}

- (void)stop {
    if (self.acceptSource) { dispatch_source_cancel(self.acceptSource); self.acceptSource = nil; }
    if (self.listenFD >= 0) { close(self.listenFD); self.listenFD = -1; }
}

- (void)serveClient:(int)client {
    // Read headers (+ body per Content-Length). Good enough for our clients.
    NSMutableData *buf = [NSMutableData data];
    char tmp[4096];
    NSRange headerEnd = NSMakeRange(NSNotFound, 0);
    NSUInteger contentLength = 0;
    for (;;) {
        ssize_t n = read(client, tmp, sizeof(tmp));
        if (n <= 0) break;
        [buf appendBytes:tmp length:(NSUInteger)n];
        if (headerEnd.location == NSNotFound) {
            headerEnd = [buf rangeOfData:[@"\r\n\r\n" dataUsingEncoding:NSASCIIStringEncoding] options:0 range:NSMakeRange(0, buf.length)];
            if (headerEnd.location != NSNotFound) {
                NSString *head = [[NSString alloc] initWithData:[buf subdataWithRange:NSMakeRange(0, headerEnd.location)] encoding:NSUTF8StringEncoding] ?: @"";
                for (NSString *line in [head componentsSeparatedByString:@"\r\n"]) {
                    NSRange c = [line rangeOfString:@":"];
                    if (c.location != NSNotFound && [[line substringToIndex:c.location].lowercaseString isEqualToString:@"content-length"]) {
                        contentLength = (NSUInteger)[[line substringFromIndex:c.location + 1] integerValue];
                    }
                }
            }
        }
        if (headerEnd.location != NSNotFound && buf.length >= NSMaxRange(headerEnd) + contentLength) break;
    }

    YTMUTestHTTPRequest *req = [[YTMUTestHTTPRequest alloc] init];
    if (headerEnd.location != NSNotFound) {
        NSString *head = [[NSString alloc] initWithData:[buf subdataWithRange:NSMakeRange(0, headerEnd.location)] encoding:NSUTF8StringEncoding] ?: @"";
        NSArray<NSString *> *lines = [head componentsSeparatedByString:@"\r\n"];
        NSArray<NSString *> *reqLine = [lines.firstObject componentsSeparatedByString:@" "];
        req.method = reqLine.count > 0 ? reqLine[0] : @"";
        req.path = reqLine.count > 1 ? reqLine[1] : @"";
        NSMutableDictionary *hdrs = [NSMutableDictionary dictionary];
        for (NSString *line in [lines subarrayWithRange:NSMakeRange(1, lines.count - 1)]) {
            NSRange c = [line rangeOfString:@":"];
            if (c.location == NSNotFound) continue;
            hdrs[[line substringToIndex:c.location].lowercaseString] = [[line substringFromIndex:c.location + 1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        }
        req.headers = hdrs;
        NSUInteger bodyStart = NSMaxRange(headerEnd);
        req.body = buf.length > bodyStart ? [buf subdataWithRange:NSMakeRange(bodyStart, MIN(contentLength, buf.length - bodyStart))] : [NSData data];
    }
    @synchronized (self.mutableRequests) { [self.mutableRequests addObject:req]; }
    if (self.responseDelay > 0) usleep((useconds_t)(self.responseDelay * 1e6));

    NSInteger status = self.responseStatus;
    NSMutableDictionary *headers = [self.responseHeaders mutableCopy] ?: [NSMutableDictionary dictionary];
    NSData *body = self.responseBody ?: [NSData data];
    if (self.responder) {
        NSData *custom = self.responder(req, &status, headers);
        if (custom) body = custom;
    }
    NSMutableString *resp = [NSMutableString stringWithFormat:@"HTTP/1.1 %ld %@\r\n", (long)status, status == 200 ? @"OK" : @"Status"];
    [headers enumerateKeysAndObjectsUsingBlock:^(NSString *k, NSString *v, BOOL *stop) { [resp appendFormat:@"%@: %@\r\n", k, v]; }];
    [resp appendFormat:@"Content-Length: %lu\r\nConnection: close\r\n\r\n", (unsigned long)body.length];
    NSMutableData *out = [[resp dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
    [out appendData:body];
    const uint8_t *p = out.bytes; NSUInteger left = out.length;
    while (left > 0) {
        ssize_t w = write(client, p, left);
        if (w <= 0) break;
        p += w; left -= (NSUInteger)w;
    }
    close(client);
}

@end
