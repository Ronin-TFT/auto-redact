#import "AREngine.h"
#import "libredact.h"

static id ARJSON(char *raw) {
    if (!raw) return nil;
    NSData *data = [NSData dataWithBytes:raw length:strlen(raw)];
    ARFree(raw);
    return [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
}

static NSString *ARJSONString(id object) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:NULL];
    return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"null";
}

@implementation AREngine

+ (BOOL)configureKinds:(NSArray<NSString *> *)kinds keywords:(NSArray<NSString *> *)keywords error:(NSString **)error {
    NSString *json = ARJSONString(@{@"kinds": kinds, @"keywords": keywords});
    char *failure = ARConfigure((char *)json.UTF8String);
    if (failure) {
        if (error) *error = [NSString stringWithUTF8String:failure];
        ARFree(failure);
        return NO;
    }
    return YES;
}

+ (NSArray<NSArray<NSDictionary *> *> *)findInLines:(NSArray<NSString *> *)lines {
    if (!lines.count) return @[];
    NSArray *result = ARJSON(ARFind((char *)ARJSONString(lines).UTF8String));
    if (![result isKindOfClass:NSArray.class] || result.count != lines.count) return @[];
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:lines.count];
    for (NSArray *matches in result) {
        NSMutableArray *line = [NSMutableArray array];
        if ([matches isKindOfClass:NSArray.class]) {
            for (NSDictionary *m in matches) {
                if (![m isKindOfClass:NSDictionary.class]) continue;
                NSInteger start = [m[@"start"] integerValue], end = [m[@"end"] integerValue];
                if (end <= start) continue;
                [line addObject:@{@"range": [NSValue valueWithRange:NSMakeRange((NSUInteger)start, (NSUInteger)(end - start))],
                                  @"kind": m[@"kind"] ?: @""}];
            }
        }
        [out addObject:line];
    }
    return out;
}

+ (void)resetTrackerWidth:(double)width height:(double)height padding:(double)padding hold:(double)hold {
    ARTrackReset(width, height, padding, hold);
}

+ (void)addBoxes:(NSArray<NSValue *> *)rects atTime:(double)time {
    NSMutableArray *raw = [NSMutableArray arrayWithCapacity:rects.count];
    for (NSValue *value in rects) {
        NSRect r = value.rectValue;
        [raw addObject:@[@(r.origin.x), @(r.origin.y), @(r.size.width), @(r.size.height)]];
    }
    ARTrackAdd(time, (char *)ARJSONString(raw).UTF8String);
}

+ (double)latestTime {
    double latest = ARTrackLatest();
    return latest < -1e299 ? -INFINITY : latest;
}

+ (NSArray<NSValue *> *)boxesAtTime:(double)time {
    NSArray *raw = ARJSON(ARTrackBoxes(time));
    NSMutableArray *out = [NSMutableArray array];
    if (![raw isKindOfClass:NSArray.class]) return out;
    for (NSArray *r in raw) {
        if ([r isKindOfClass:NSArray.class] && r.count == 4) {
            [out addObject:[NSValue valueWithRect:NSMakeRect([r[0] doubleValue], [r[1] doubleValue], [r[2] doubleValue], [r[3] doubleValue])]];
        }
    }
    return out;
}

@end
