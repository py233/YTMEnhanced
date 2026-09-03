#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

// Helpers for text that comes back from an LLM or a Server-Sent-Events
// stream. The three JSON consumers (translation, title normalization,
// description extraction) used to carry their own copy of the fence
// stripping and the brace-balanced object scan; the SSE providers their
// own copy of the event walker. They now share these.

// Strips a leading ``` fence (with optional language tag) and a trailing
// ```; trims whitespace. Text without fences comes back trimmed.
NSString *YTMULLMStripMarkdownFences(NSString *_Nullable text);

// The substring from `openIndex` (which must point at a `{`) to its
// matching `}`, honouring JSON string literals and escapes. nil when the
// object never closes (truncated output).
NSString *_Nullable YTMULLMBalancedObjectSubstring(NSString *text, NSUInteger openIndex);

// Best-effort extraction of the first JSON object in a model reply:
// fences stripped → whole text → greedy first `{` … last `}` →
// brace-balanced scan from the first `{`. nil when nothing parses as a
// dictionary.
NSDictionary *_Nullable YTMULLMFirstJSONObject(NSString *_Nullable text);

// Walks a buffered Server-Sent-Events body and calls `block` with the JSON
// dictionary of each event's first `data:` line. Events are blank-line
// separated, with LF or CRLF endings; `[DONE]` and non-JSON payloads are
// skipped.
void YTMUSSEEnumerateJSONEvents(NSData *_Nullable data, void (NS_NOESCAPE ^block)(NSDictionary *json));

// One JSON POST the way every LLM provider makes it: `body` serialised as
// the request body, `Content-Type: application/json`, the given headers,
// `timeout` as NSURLSession's idle timeout. `status` is 0 when the
// response is not an HTTP response (or `error` is set).
void YTMULLMPostJSON(NSString *url,
                     NSDictionary<NSString *, NSString *> *_Nullable headers,
                     id body,
                     NSTimeInterval timeout,
                     void (^completion)(NSData *_Nullable data, NSInteger status, NSError *_Nullable error));

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
