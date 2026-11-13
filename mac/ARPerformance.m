#import "ARPerformance.h"
#import <Cocoa/Cocoa.h>
#import <CoreVideo/CoreVideo.h>
#import <sys/sysctl.h>
#import "ARRecognizer.h"

const NSInteger ARMinRecognitionRate = 1;
const NSInteger ARMaxRecognitionRate = 15;

static NSString *ARSysctlString(const char *name) {
    size_t size = 0;
    if (sysctlbyname(name, NULL, &size, NULL, 0) != 0 || size == 0) return nil;
    char *buffer = malloc(size);
    NSString *value = nil;
    if (sysctlbyname(name, buffer, &size, NULL, 0) == 0) value = [NSString stringWithUTF8String:buffer];
    free(buffer);
    return value;
}

NSString *ARChipName(void) {
    NSString *brand = ARSysctlString("machdep.cpu.brand_string");
    brand = [brand stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    return brand.length ? brand : @"未知处理器";
}

BOOL ARIsAppleSilicon(void) {
    int value = 0;
    size_t size = sizeof(value);
    return sysctlbyname("hw.optional.arm64", &value, &size, NULL, 0) == 0 && value == 1;
}

NSInteger ARRecommendedRate(double seconds, BOOL appleSilicon) {
    if (!(seconds > 0)) return appleSilicon ? 6 : 3;
    NSInteger rate = (NSInteger)floor(0.5 / seconds);
    return MIN(MAX(rate, ARMinRecognitionRate), ARMaxRecognitionRate);
}

/// 一张类似屏幕的样例画面：白底，多行混有手机号、邮箱的文字。
static CVPixelBufferRef ARSampleScreen(void) {
    const size_t width = 1920, height = 1080;
    CVPixelBufferRef buffer = NULL;
    CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                        (__bridge CFDictionaryRef)@{(id)kCVPixelBufferIOSurfacePropertiesKey: @{}}, &buffer);
    if (!buffer) return NULL;
    CVPixelBufferLockBaseAddress(buffer, 0);
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(CVPixelBufferGetBaseAddress(buffer), width, height, 8, CVPixelBufferGetBytesPerRow(buffer),
                                             space, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGContextSetRGBFillColor(ctx, 1, 1, 1, 1);
    CGContextFillRect(ctx, CGRectMake(0, 0, width, height));
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithCGContext:ctx flipped:NO];
    NSDictionary *attrs = @{NSFontAttributeName: [NSFont systemFontOfSize:22], NSForegroundColorAttributeName: NSColor.blackColor};
    for (int i = 0; i < 28; i++) {
        NSString *line = i % 3 == 0
            ? [NSString stringWithFormat:@"Customer %d  phone 1380013%04d  email user%d@example.com  order 2024%06d", i, 8000 + i, i, i * 37]
            : [NSString stringWithFormat:@"Line %d: the quick brown fox jumps over the lazy dog, settings and preferences panel", i];
        [line drawAtPoint:NSMakePoint(60, height - 50 - i * 36) withAttributes:attrs];
    }
    [NSGraphicsContext restoreGraphicsState];
    CGContextRelease(ctx);
    CGColorSpaceRelease(space);
    CVPixelBufferUnlockBaseAddress(buffer, 0);
    return buffer;
}

void ARMeasureRecognition(BOOL recognizesChinese, void (^completion)(double)) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        CVPixelBufferRef sample = ARSampleScreen();
        double seconds = 0;
        if (sample) {
            ARRecognizer *recognizer = [ARRecognizer new];
            recognizer.recognizesChinese = recognizesChinese;
            [recognizer detectionsInPixelBuffer:sample]; // 预热：第一次会加载模型
            double best = INFINITY;
            for (int i = 0; i < 3; i++) {
                NSDate *start = [NSDate date];
                [recognizer detectionsInPixelBuffer:sample];
                best = MIN(best, -start.timeIntervalSinceNow);
            }
            seconds = isfinite(best) ? best : 0;
            CVPixelBufferRelease(sample);
        }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(seconds); });
    });
}
