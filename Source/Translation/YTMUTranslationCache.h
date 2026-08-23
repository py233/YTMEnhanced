#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface YTMUTranslationCacheEntry : NSObject
@property (nonatomic, copy) NSString *cacheKey;
@property (nonatomic, copy) NSString *strategyVersion;
@property (nonatomic, copy) NSString *videoId;
@property (nonatomic, copy) NSString *targetLanguage;
@property (nonatomic, copy) NSString *provider;
@property (nonatomic, copy) NSString *model;
@property (nonatomic, copy) NSString *sourceHash;
@property (nonatomic) NSUInteger lineCount;
@property (nonatomic, copy) NSArray<NSString *> *sourceLines;
@property (nonatomic, copy) NSArray<NSString *> *translatedLines;
@property (nonatomic) NSTimeInterval createdAt;
// Non-zero marks a remembered failure (translatedLines empty): the
// provider returned something unparseable / misaligned for this exact
// source, which tends to repeat. Honoured for YTMUTranslationFailureTTL.
@property (nonatomic) NSTimeInterval failedAt;
- (BOOL)isRememberedFailure;
@end

// How long a parse / line-count failure is remembered before the provider
// is asked again for the same song + language + provider + model.
extern const NSTimeInterval YTMUTranslationFailureTTL;

@interface YTMUTranslationCache : NSObject

+ (instancetype)sharedCache;

// Build the canonical key string from the parts.
+ (NSString *)keyForVideoId:(NSString *)videoId
                   language:(NSString *)language
                   provider:(NSString *)provider
                      model:(NSString *)model
                      lines:(NSArray<NSString *> *)lines;

// SHA1 of the joined-with-newlines source lines (matches buildSourceHash semantics).
+ (NSString *)sourceHashForLines:(NSArray<NSString *> *)lines;

- (nullable YTMUTranslationCacheEntry *)entryForKey:(NSString *)key;
- (void)storeEntry:(YTMUTranslationCacheEntry *)entry;
- (NSUInteger)clearAll;

@end

NS_ASSUME_NONNULL_END
