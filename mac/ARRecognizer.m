#import "ARRecognizer.h"
#import <Vision/Vision.h>
#import "AREngine.h"

NSRect ARPixelRectFromNormalized(CGRect n, size_t width, size_t height) {
    return NSMakeRect(n.origin.x * width, (1.0 - n.origin.y - n.size.height) * height,
                      n.size.width * width, n.size.height * height);
}

/// 按字符位置估算一段文字在整行中的位置（中日韩等宽字符按 2 个单位），两侧各多留一个字符。
CGRect ARApproximateRangeBox(CGRect line, NSString *text, NSRange range) {
    __block CGFloat total = 0, before = 0, inside = 0;
    [text enumerateSubstringsInRange:NSMakeRange(0, text.length) options:NSStringEnumerationByComposedCharacterSequences
                          usingBlock:^(NSString *sub, NSRange subRange, NSRange enclosing, BOOL *stop) {
        unichar c = [sub characterAtIndex:0];
        BOOL wideChar = (c >= 0x1100 && c <= 0x115F) || (c >= 0x2E80 && c <= 0xA4CF) || (c >= 0xAC00 && c <= 0xD7A3) ||
                        (c >= 0xF900 && c <= 0xFAFF) || (c >= 0xFE30 && c <= 0xFE4F) || (c >= 0xFF00 && c <= 0xFF60) ||
                        (c >= 0xD800 && c <= 0xDBFF);
        CGFloat w = wideChar ? 2 : 1;
        total += w;
        if (NSMaxRange(subRange) <= range.location) before += w;
        else if (subRange.location < NSMaxRange(range)) inside += w;
    }];
    if (total <= 0) return line;
    CGFloat unit = line.size.width / total;
    CGFloat x = line.origin.x + (before - 1) * unit;
    CGFloat w = (inside + 2) * unit;
    CGFloat minX = MAX(line.origin.x, x), maxX = MIN(CGRectGetMaxX(line), x + w);
    return CGRectMake(minX, line.origin.y, MAX(0, maxX - minX), line.size.height);
}

uint32_t ARTextKey(NSString *text) {
    uint32_t hash = 2166136261u;
    for (NSUInteger i = 0; i < text.length; i++) {
        hash ^= [text characterAtIndex:i];
        hash *= 16777619u;
    }
    return hash ? hash : 1;
}

@implementation ARDetection
- (instancetype)initWithRect:(NSRect)rect kind:(NSString *)kind key:(uint32_t)key {
    if ((self = [super init])) {
        _rect = rect;
        _kind = [kind copy];
        _key = key;
    }
    return self;
}
@end

@implementation ARRecognizer

- (NSArray<ARDetection *> *)detectionsInPixelBuffer:(CVPixelBufferRef)buffer {
    @autoreleasepool {
        VNRecognizeTextRequest *request = [VNRecognizeTextRequest new];
        request.usesLanguageCorrection = NO;
        // 默认会忽略高度小于画面 1/32 的文字（1080p 下约 34 像素，比普通正文还大），小字因此时有时无。
        request.minimumTextHeight = 0;
        if (self.recognizesChinese) {
            request.recognitionLevel = VNRequestTextRecognitionLevelAccurate;
            request.recognitionLanguages = @[@"zh-Hans", @"en-US"];
        } else {
            request.recognitionLevel = VNRequestTextRecognitionLevelFast;
        }
        VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCVPixelBuffer:buffer options:@{}];
        if (![handler performRequests:@[request] error:NULL]) return @[];

        NSMutableArray<VNRecognizedText *> *texts = [NSMutableArray array];
        NSMutableArray<VNRecognizedTextObservation *> *observations = [NSMutableArray array];
        NSMutableArray<NSString *> *lines = [NSMutableArray array];
        for (VNRecognizedTextObservation *observation in request.results) {
            VNRecognizedText *top = [observation topCandidates:1].firstObject;
            if (!top.string.length) continue;
            [texts addObject:top];
            [observations addObject:observation];
            [lines addObject:top.string];
        }
        NSArray<NSArray<NSDictionary *> *> *found = [AREngine findInLines:lines];
        size_t width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer);
        NSMutableArray<ARDetection *> *out = [NSMutableArray array];
        for (NSUInteger i = 0; i < found.count && i < texts.count; i++) {
            for (NSDictionary *match in found[i]) {
                NSRange range = [match[@"range"] rangeValue];
                if (NSMaxRange(range) > texts[i].string.length) continue;
                CGRect line = observations[i].boundingBox;
                VNRectangleObservation *box = [texts[i] boundingBoxForRange:range error:NULL];
                CGRect normalized = box ? box.boundingBox : line;
                // 快速模式下有时只返回整行位置：按字符位置估算这一段的位置。
                if (range.length < texts[i].string.length * 0.8 && normalized.size.width >= line.size.width * 0.95) {
                    normalized = ARApproximateRangeBox(line, texts[i].string, range);
                }
                [out addObject:[[ARDetection alloc] initWithRect:ARPixelRectFromNormalized(normalized, width, height)
                                                            kind:match[@"kind"]
                                                             key:ARTextKey([texts[i].string substringWithRange:range])]];
            }
        }
        return out;
    }
}

@end
