// 原生部分的回归测试：坐标换算、引擎封装、打码渲染，以及用 Vision 真实识别合成图片中的手机号和邮箱。
// 构建运行（需先编译静态库）：
//   go build -buildmode=c-archive -o build/libredact.a .
//   clang -fobjc-arc -I build -I mac tests/mac_test.m $(ls mac/*.m | grep -v main.m) mac/ARMotion.c build/libredact.a \
//     -framework Cocoa -framework ScreenCaptureKit -framework AVFoundation -framework CoreMedia -framework CoreVideo \
//     -framework CoreImage -framework Vision -framework CoreFoundation -framework AVKit -framework Carbon -o build/mac-test && build/mac-test
#import <Cocoa/Cocoa.h>
#include <assert.h>
#import "ARAppDelegate.h"
#import "ARCapture.h"
#import "AREngine.h"
#import "AROverlaySession.h"
#import "ARHotkeys.h"
#import "ARPatchExporter.h"
#import "ARPrivacyWindows.h"
#import "ARRecordSession.h"
#import "ARReviewController.h"
#import "ARRecognizer.h"
#import "ARPerformance.h"
#import "ARRedact.h"

static BOOL near(CGFloat a, CGFloat b) { return fabs(a - b) < 0.5; }

/// 白底黑字的 BGRA 画面。
static CVPixelBufferRef renderText(NSString *text, size_t width, size_t height, CGFloat fontSize) {
    CVPixelBufferRef buffer = NULL;
    NSDictionary *attrs = @{(id)kCVPixelBufferIOSurfacePropertiesKey: @{}};
    CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, (__bridge CFDictionaryRef)attrs, &buffer);
    CVPixelBufferLockBaseAddress(buffer, 0);
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(CVPixelBufferGetBaseAddress(buffer), width, height, 8,
                                             CVPixelBufferGetBytesPerRow(buffer), space,
                                             kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGContextSetRGBFillColor(ctx, 1, 1, 1, 1);
    CGContextFillRect(ctx, CGRectMake(0, 0, width, height));
    NSGraphicsContext *gc = [NSGraphicsContext graphicsContextWithCGContext:ctx flipped:NO];
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext = gc;
    [text drawAtPoint:NSMakePoint(40, height / 2.0 - fontSize / 2)
       withAttributes:@{NSFontAttributeName: [NSFont systemFontOfSize:fontSize], NSForegroundColorAttributeName: NSColor.blackColor}];
    [NSGraphicsContext restoreGraphicsState];
    CGContextRelease(ctx);
    CGColorSpaceRelease(space);
    CVPixelBufferUnlockBaseAddress(buffer, 0);
    return buffer;
}

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];

        // 坐标换算
        NSRect pixel = ARPixelRectFromNormalized(CGRectMake(0.25, 0.5, 0.5, 0.25), 1000, 400);
        assert(near(pixel.origin.x, 250) && near(pixel.origin.y, 100) && near(pixel.size.width, 500) && near(pixel.size.height, 100));
        NSRect screen = ARScreenRectFromPixelRect(NSMakeRect(100, 50, 200, 40), CGSizeMake(2000, 1000), NSMakeRect(1440, 0, 1000, 500));
        assert(near(screen.origin.x, 1490) && near(screen.origin.y, 455) && near(screen.size.width, 100) && near(screen.size.height, 20));
        CGSize size = ARCaptureSize(CGSizeMake(1512, 982), 2, 1920);
        assert(size.width == 1920 && (long)size.height % 2 == 0 && size.height <= 1248);
        CGSize fivek = ARCaptureSize(CGSizeMake(2560, 1440), 2, 0);
        assert(fivek.width <= 4096 && fivek.height <= 2304);
        CGRect approx = ARApproximateRangeBox(CGRectMake(0, 0, 1, 0.1), @"abcdefghij", NSMakeRange(4, 2));
        assert(near(approx.origin.x * 100, 30) && near(approx.size.width * 100, 40));
        CGRect wide = ARApproximateRangeBox(CGRectMake(0, 0, 1, 0.1), @"电话ab", NSMakeRange(2, 2));
        assert(near(wide.origin.x * 100, 50) && near(wide.size.width * 100, 50));
        assert(ARTextKey(@"13800138000") == ARTextKey(@"13800138000") && ARTextKey(@"a") != ARTextKey(@"b") && ARTextKey(@"") != 0);
        // 推荐频率：识别最多占一半时间，限制在滑块范围内
        assert(ARRecommendedRate(0.1, YES) == 5);
        assert(ARRecommendedRate(0.04, YES) == 12);
        assert(ARRecommendedRate(0.01, YES) == ARMaxRecognitionRate);
        assert(ARRecommendedRate(2.0, NO) == ARMinRecognitionRate);
        assert(ARRecommendedRate(0, YES) == 6 && ARRecommendedRate(0, NO) == 3);
        assert(ARChipName().length > 0);
        NSArray *words = ARSplitKeywords(@" 张三，李四, 张三\n项目 X ");
        assert([words isEqualToArray:(@[@"张三", @"李四", @"项目 X"])]);

        // 0.2：录制区域、识别区域、复查、隐私窗口的坐标换算
        // 屏幕 (1440,0,1000,500) 中，全局 (1540,400,200,50) 距屏幕顶部 50 点。
        CGRect local = ARDisplayLocalRect(CGRectMake(1540, 400, 200, 50), CGRectMake(1440, 0, 1000, 500));
        assert(near(local.origin.x, 100) && near(local.origin.y, 50) && near(local.size.width, 200) && near(local.size.height, 50));
        CGRect clipped = ARDisplayLocalRect(CGRectMake(1400, 450, 100, 100), CGRectMake(1440, 0, 1000, 500));
        assert(near(clipped.origin.x, 0) && near(clipped.origin.y, 0) && near(clipped.size.width, 60) && near(clipped.size.height, 50));
        assert(CGRectIsNull(ARDisplayLocalRect(CGRectMake(0, 0, 100, 100), CGRectMake(1440, 0, 1000, 500))));
        // 录制区域 (100,50,800,400) 点，捕获 1600×800 像素：区域内 (200,100,100,50) → (200,100,200,100) 像素。
        NSRect inCapture = ARCapturePixelRect(CGRectMake(200, 100, 100, 50), CGRectMake(100, 50, 800, 400), CGSizeMake(1600, 800));
        assert(near(inCapture.origin.x, 200) && near(inCapture.origin.y, 100) && near(inCapture.size.width, 200) && near(inCapture.size.height, 100));
        CGRect roi = ARNormalizedFromPixelRect(NSMakeRect(100, 0, 500, 100), 1000, 400);
        assert(near(roi.origin.x * 100, 10) && near(roi.origin.y * 100, 75) && near(roi.size.width * 100, 50) && near(roi.size.height * 100, 25));
        CGRect inFull = ARNormalizedInROI(CGRectMake(0.5, 0.5, 0.5, 0.5), roi);
        assert(near(inFull.origin.x * 100, 35) && near(inFull.origin.y * 1000, 875) && near(inFull.size.width * 100, 25));
        NSRect back = ARPixelRectFromNormalized(inFull, 1000, 400);
        assert(near(back.origin.x, 350) && near(back.origin.y, 0) && near(back.size.width, 250) && near(back.size.height, 50));
        // 画面在视图中位于 (0,50,800,450)，录像 1600×900：视图 (100,400,200,100) → 录像 (200,0,400,200)。
        NSRect video = ARVideoRectFromViewRect(NSMakeRect(100, 400, 200, 100), NSMakeRect(0, 50, 800, 450), CGSizeMake(1600, 900));
        assert(near(video.origin.x, 200) && near(video.origin.y, 0) && near(video.size.width, 400) && near(video.size.height, 200));
        assert(NSIsEmptyRect(ARVideoRectFromViewRect(NSMakeRect(0, 0, 10, 10), NSMakeRect(0, 50, 800, 450), CGSizeMake(1600, 900))));
        NSArray *masks = @[[[ARManualMask alloc] initWithRect:NSMakeRect(0, 0, 10, 10) start:1 end:2],
                           [[ARManualMask alloc] initWithRect:NSMakeRect(5, 5, 10, 10) start:1.5 end:3]];
        assert(ARMasksAtTime(masks, 0.5).count == 0 && ARMasksAtTime(masks, 1.0).count == 1);
        assert(ARMasksAtTime(masks, 1.75).count == 2 && ARMasksAtTime(masks, 2.5).count == 1 && ARMasksAtTime(masks, 3.1).count == 0);
        NSRect cocoa = ARCocoaRectFromWindowBounds(CGRectMake(10, 20, 300, 200), 900);
        assert(near(cocoa.origin.x, 10) && near(cocoa.origin.y, 680) && near(cocoa.size.width, 300) && near(cocoa.size.height, 200));
        assert([[ARHotkeys nameForAction:ARHotkeyActionRecord] isEqualToString:@"⌃⌥⌘R"]);
        assert([[ARHotkeys nameForAction:ARHotkeyActionOverlay] isEqualToString:@"⌃⌥⌘H"]);
        assert(ARNotificationCenterBundleID.length > 0);

        // 引擎封装
        // 数组字面量里的逗号会被 assert 宏当作参数分隔，先存到变量里。
        NSArray *engineKinds = @[@"phone", @"email", @"keyword"];
        BOOL configured = [AREngine configureKinds:engineKinds keywords:@[@"张三"] error:NULL];
        assert(configured);
        NSArray *found = [AREngine findInLines:@[@"张三 13800138000", @"无"]];
        assert(found.count == 2 && [found[0] count] == 2 && [found[1] count] == 0);
        assert(NSEqualRanges([found[0][1][@"range"] rangeValue], NSMakeRange(3, 11)));

        // 打码渲染：框内像素改变，框外不变
        CVPixelBufferRef base = renderText(@"13800138000", 800, 200, 60);
        CIContext *context = [CIContext contextWithOptions:nil];
        CIImage *original = [CIImage imageWithCVPixelBuffer:base];
        for (ARRedactStyle style = ARRedactStyleMosaic; style <= ARRedactStyleSolid; style++) {
            CIImage *redacted = ARRedactImage(original, @[[NSValue valueWithRect:NSMakeRect(0, 0, 800, 200)]], style);
            assert(CGRectEqualToRect(redacted.extent, original.extent));
            CVPixelBufferRef out = NULL;
            CVPixelBufferCreate(kCFAllocatorDefault, 800, 200, kCVPixelFormatType_32BGRA,
                                (__bridge CFDictionaryRef)@{(id)kCVPixelBufferIOSurfacePropertiesKey: @{}}, &out);
            [context render:redacted toCVPixelBuffer:out];
            CVPixelBufferLockBaseAddress(base, kCVPixelBufferLock_ReadOnly);
            CVPixelBufferLockBaseAddress(out, kCVPixelBufferLock_ReadOnly);
            size_t changed = 0;
            for (size_t y = 0; y < 200; y++) {
                const uint8_t *a = (const uint8_t *)CVPixelBufferGetBaseAddress(base) + y * CVPixelBufferGetBytesPerRow(base);
                const uint8_t *b = (const uint8_t *)CVPixelBufferGetBaseAddress(out) + y * CVPixelBufferGetBytesPerRow(out);
                for (size_t x = 0; x < 800 * 4; x += 4) if (abs((int)a[x] - (int)b[x]) > 40) changed++;
            }
            CVPixelBufferUnlockBaseAddress(out, kCVPixelBufferLock_ReadOnly);
            CVPixelBufferUnlockBaseAddress(base, kCVPixelBufferLock_ReadOnly);
            assert(changed > 1000);
            CVPixelBufferRelease(out);
        }
        CIImage *untouched = ARRedactImage(original, @[], ARRedactStyleMosaic);
        assert(untouched == original);
        CVPixelBufferRelease(base);

        // 真实识别：合成画面中的手机号与邮箱
        NSArray *visionKinds = @[@"phone", @"email"];
        configured = [AREngine configureKinds:visionKinds keywords:@[] error:NULL];
        assert(configured);
        CVPixelBufferRef screenshot = renderText(@"Phone 13800138000   Email zhang.san@example.com   Version 1.2.3", 1800, 240, 44);
        NSArray<ARDetection *> *detections = [[ARRecognizer new] detectionsInPixelBuffer:screenshot];
        NSCountedSet *kinds = [NSCountedSet set];
        for (ARDetection *d in detections) {
            [kinds addObject:d.kind];
            assert(d.rect.size.width > 20 && d.rect.size.height > 10);
            assert(d.rect.origin.x >= 0 && NSMaxX(d.rect) <= 1800 && d.rect.origin.y >= 0 && NSMaxY(d.rect) <= 240);
        }
        printf("recognized %lu sensitive items\n", (unsigned long)detections.count);
        assert([kinds countForObject:@"phone"] == 1 && [kinds countForObject:@"email"] == 1);
        // 手机号在左、邮箱在右，且“Phone”这个词本身不在手机号的框里。
        ARDetection *phone = nil, *email = nil;
        for (ARDetection *d in detections) {
            if ([d.kind isEqualToString:@"phone"]) phone = d;
            if ([d.kind isEqualToString:@"email"]) email = d;
        }
        assert(NSMaxX(phone.rect) < email.rect.origin.x);
        assert(phone.rect.origin.x > 100);
        CVPixelBufferRelease(screenshot);

        // 二维码：用 CoreImage 生成后识别
        CIFilter *qr = [CIFilter filterWithName:@"CIQRCodeGenerator"];
        [qr setValue:[@"https://example.com/secret-invite" dataUsingEncoding:NSUTF8StringEncoding] forKey:@"inputMessage"];
        CIImage *code = [qr.outputImage imageByApplyingTransform:CGAffineTransformMakeScale(10, 10)];
        code = [code imageByApplyingTransform:CGAffineTransformMakeTranslation(300, 100)];
        CIImage *canvas = [[CIImage imageWithColor:[CIColor whiteColor]] imageByCroppingToRect:CGRectMake(0, 0, 1000, 500)];
        CVPixelBufferRef qrBuffer = NULL;
        CVPixelBufferCreate(kCFAllocatorDefault, 1000, 500, kCVPixelFormatType_32BGRA,
                            (__bridge CFDictionaryRef)@{(id)kCVPixelBufferIOSurfacePropertiesKey: @{}}, &qrBuffer);
        [context render:[code imageByCompositingOverImage:canvas] toCVPixelBuffer:qrBuffer];
        ARRecognizer *codeRecognizer = [ARRecognizer new];
        codeRecognizer.detectsCodes = YES;
        NSArray<ARDetection *> *codes = [codeRecognizer detectionsInPixelBuffer:qrBuffer];
        BOOL foundCode = NO;
        for (ARDetection *d in codes) {
            if (![d.kind isEqualToString:@"qrcode"]) continue;
            foundCode = YES;
            assert(d.rect.size.width > 100 && d.rect.origin.x > 250 && NSMaxX(d.rect) < 760);
        }
        assert(foundCode);
        // 只识别最右边一块（二维码在 300~700 列之间）：这块区域里没有二维码。
        NSArray<ARDetection *> *rightOnly = [codeRecognizer detectionsInPixelBuffer:qrBuffer region:NSMakeRect(780, 0, 220, 500)];
        for (ARDetection *d in rightOnly) assert(![d.kind isEqualToString:@"qrcode"]);
        CVPixelBufferRelease(qrBuffer);

        puts("geometry, engine, redaction rendering, Vision text and QR code recognition passed");
    }
    return 0;
}
