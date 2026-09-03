#import "YTMUKVC.h"
#import <objc/runtime.h>

typedef NS_ENUM(NSInteger, YTMUKVCAccess) {
    YTMUKVCAccessRead = 0,
    YTMUKVCAccessWrite = 1,
};

static NSString *YTMUKVCCapitalized(NSString *key) {
    if (!key.length) return key;
    return [[[key substringToIndex:1] uppercaseString] stringByAppendingString:[key substringFromIndex:1]];
}

static BOOL YTMUKVCClassHasIvar(Class cls, NSString *name) {
    return class_getInstanceVariable(cls, name.UTF8String) != NULL;
}

// Mirrors NSKeyValueCoding's search order closely enough for our purpose:
// read  → get<Key>, <key>, is<Key>, _<key> (methods); then _<key>, _is<Key>,
//         <key>, is<Key> (ivars, only when accessInstanceVariablesDirectly).
// write → set<Key>:, _set<Key>: (methods); then _<key>, _is<Key>, <key>,
//         is<Key> (ivars, same condition).
static BOOL YTMUKVCResolveUncached(Class cls, NSString *key, YTMUKVCAccess access) {
    NSString *capitalized = YTMUKVCCapitalized(key);
    NSArray<NSString *> *selectors;
    if (access == YTMUKVCAccessRead) {
        selectors = @[[@"get" stringByAppendingString:capitalized],
                      key,
                      [@"is" stringByAppendingString:capitalized],
                      [@"_" stringByAppendingString:key]];
    } else {
        selectors = @[[NSString stringWithFormat:@"set%@:", capitalized],
                      [NSString stringWithFormat:@"_set%@:", capitalized]];
    }
    for (NSString *name in selectors) {
        if (class_getInstanceMethod(cls, NSSelectorFromString(name)) != NULL) return YES;
    }
    if (![cls accessInstanceVariablesDirectly]) return NO;
    NSArray<NSString *> *ivars = @[[@"_" stringByAppendingString:key],
                                   [@"_is" stringByAppendingString:capitalized],
                                   key,
                                   [@"is" stringByAppendingString:capitalized]];
    for (NSString *name in ivars) {
        if (YTMUKVCClassHasIvar(cls, name)) return YES;
    }
    return NO;
}

static BOOL YTMUKVCResolveClass(Class cls, NSString *key, YTMUKVCAccess access) {
    if (!cls || !key.length) return NO;
    // Keys with dots or @-operators are key paths / collection operators;
    // never probe those blindly.
    if ([key rangeOfString:@"."].location != NSNotFound || [key hasPrefix:@"@"]) return NO;
    static NSMutableDictionary<NSString *, NSNumber *> *cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ cache = [NSMutableDictionary dictionary]; });
    NSString *cacheKey = [NSString stringWithFormat:@"%p|%ld|%@", (void *)cls, (long)access, key];
    @synchronized (cache) {
        NSNumber *known = cache[cacheKey];
        if (known) return known.boolValue;
    }
    BOOL resolvable = YTMUKVCResolveUncached(cls, key, access);
    @synchronized (cache) {
        if (cache.count > 4096) [cache removeAllObjects];
        cache[cacheKey] = @(resolvable);
    }
    return resolvable;
}

static BOOL YTMUKVCResolve(id object, NSString *key, YTMUKVCAccess access) {
    if (!object) return NO;
    return YTMUKVCResolveClass(object_getClass(object), key, access);
}

BOOL YTMUKVCCanReadKey(id object, NSString *key) {
    if ([object isKindOfClass:[NSDictionary class]]) return YES;
    return YTMUKVCResolve(object, key, YTMUKVCAccessRead);
}

BOOL YTMUKVCClassCanReadKey(Class cls, NSString *key) {
    return YTMUKVCResolveClass(cls, key, YTMUKVCAccessRead);
}

id YTMUSafeValueForKey(id object, NSString *key) {
    if (!object || !key.length) return nil;
    if ([object isKindOfClass:[NSDictionary class]]) return ((NSDictionary *)object)[key];
    if (!YTMUKVCResolve(object, key, YTMUKVCAccessRead)) return nil;
    @try {
        return [object valueForKey:key];
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

id YTMUSafeValueForKeyPath(id object, NSString *keyPath) {
    if (!object || !keyPath.length) return nil;
    id current = object;
    for (NSString *component in [keyPath componentsSeparatedByString:@"."]) {
        current = YTMUSafeValueForKey(current, component);
        if (!current) return nil;
    }
    return current;
}

BOOL YTMUSafeSetValueForKey(id object, NSString *key, id value) {
    if (!object || !key.length) return NO;
    if ([object isKindOfClass:[NSMutableDictionary class]]) {
        if (value) ((NSMutableDictionary *)object)[key] = value;
        else [(NSMutableDictionary *)object removeObjectForKey:key];
        return YES;
    }
    if (!YTMUKVCResolve(object, key, YTMUKVCAccessWrite)) return NO;
    @try {
        [object setValue:value forKey:key];
        return YES;
    } @catch (__unused NSException *exception) {
        return NO;
    }
}
