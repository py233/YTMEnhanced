// Tiny in-process HTTP/1.1 server for exercising the real NSURLSession code
// paths in providers. One canned response per server; records every request.
#import <Foundation/Foundation.h>

@interface YTMUTestHTTPRequest : NSObject
@property (nonatomic, copy) NSString *method;
@property (nonatomic, copy) NSString *path;
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *headers;
@property (nonatomic, copy) NSData *body;
@end

@interface YTMUTestHTTPServer : NSObject
@property (nonatomic, readonly) uint16_t port;
@property (nonatomic, readonly) NSString *baseURL;         // http://127.0.0.1:PORT
@property (nonatomic) NSInteger responseStatus;            // default 200
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *responseHeaders;
@property (nonatomic, copy) NSData *responseBody;
// Optional per-request hook; return nil to fall back to the canned response.
@property (nonatomic, copy) NSData *(^responder)(YTMUTestHTTPRequest *request, NSInteger *status, NSMutableDictionary<NSString *, NSString *> *headers);
@property (nonatomic, readonly) NSArray<YTMUTestHTTPRequest *> *requests;
@property (nonatomic) NSTimeInterval responseDelay;   // seconds to hold each response (simulates latency)

+ (instancetype)start;           // binds an ephemeral port on 127.0.0.1
- (void)stop;
- (void)setJSONResponse:(id)object status:(NSInteger)status;
- (void)setTextResponse:(NSString *)text contentType:(NSString *)contentType status:(NSInteger)status;
@end
