// 生成 1024×1024 的应用图标：深色圆角底、两行文字、中间一段马赛克。
// 用法：make_icon <输出 png 路径>
#import <Cocoa/Cocoa.h>

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 2) return 1;
        NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:1024 pixelsHigh:1024
                                                                     bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
                                                                    colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
        [NSGraphicsContext saveGraphicsState];
        NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
        [[NSColor clearColor] setFill];
        NSRectFill(NSMakeRect(0, 0, 1024, 1024));
        [[NSColor colorWithRed:0.95 green:0.95 blue:0.97 alpha:1] setFill];
        [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(100, 100, 824, 824) xRadius:180 yRadius:180] fill];

        NSColor *ink = [NSColor colorWithRed:0.35 green:0.37 blue:0.42 alpha:1];
        [ink setFill];
        [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(210, 650, 600, 56) xRadius:28 yRadius:28] fill];
        [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(210, 310, 420, 56) xRadius:28 yRadius:28] fill];

        // 马赛克块
        NSArray<NSColor *> *tones = @[
            [NSColor colorWithRed:0.16 green:0.18 blue:0.24 alpha:1], [NSColor colorWithRed:0.30 green:0.33 blue:0.42 alpha:1],
            [NSColor colorWithRed:0.22 green:0.25 blue:0.32 alpha:1], [NSColor colorWithRed:0.40 green:0.44 blue:0.54 alpha:1],
        ];
        int cell = 76;
        for (int row = 0; row < 3; row++) {
            for (int col = 0; col < 8; col++) {
                [tones[(row * 3 + col * 5) % tones.count] setFill];
                NSRectFill(NSMakeRect(210 + col * cell, 400 + row * cell, cell, cell));
            }
        }
        [[NSColor colorWithRed:0.04 green:0.39 blue:0.84 alpha:1] setStroke];
        NSBezierPath *frame = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(196, 386, 8 * cell + 28, 3 * cell + 28) xRadius:16 yRadius:16];
        frame.lineWidth = 14;
        [frame stroke];

        [NSGraphicsContext restoreGraphicsState];
        NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        return [png writeToFile:[NSString stringWithUTF8String:argv[1]] atomically:YES] ? 0 : 1;
    }
}
