#import "AROverlaySession.h"
#import "ARCapture.h"
#import "AREngine.h"
#import "ARRecognizer.h"

NSRect ARScreenRectFromPixelRect(NSRect r, CGSize pixelSize, NSRect screen) {
    CGFloat sx = screen.size.width / MAX(pixelSize.width, 1), sy = screen.size.height / MAX(pixelSize.height, 1);
    return NSMakeRect(NSMinX(screen) + r.origin.x * sx,
                      NSMaxY(screen) - (r.origin.y + r.size.height) * sy,
                      r.size.width * sx, r.size.height * sy);
}

@interface ARCoverView : NSView
@end

@implementation ARCoverView
- (void)drawRect:(NSRect)dirtyRect {
    [[NSColor colorWithRed:0.12 green:0.12 blue:0.13 alpha:1] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:4 yRadius:4] fill];
    if (self.bounds.size.width >= 64 && self.bounds.size.height >= 16) {
        NSDictionary *attrs = @{NSFontAttributeName: [NSFont systemFontOfSize:MIN(12, self.bounds.size.height * 0.6)],
                                NSForegroundColorAttributeName: [NSColor colorWithWhite:1 alpha:0.6]};
        NSString *label = @"已隐藏";
        NSSize size = [label sizeWithAttributes:attrs];
        [label drawAtPoint:NSMakePoint(NSMidX(self.bounds) - size.width / 2, NSMidY(self.bounds) - size.height / 2) withAttributes:attrs];
    }
}
@end

@interface AROverlaySession ()
@property (nonatomic, strong) ARCapture *capture;
@property (nonatomic, strong) ARRecognizer *recognizer;
@property (nonatomic, strong) dispatch_queue_t recognizeQueue;
@property (nonatomic, strong) NSMutableArray<NSWindow *> *covers;
@property (nonatomic) NSRect screenFrame;
@property (nonatomic) BOOL recognizing;           // 帧队列上访问
@property (nonatomic) double lastRecognitionTime; // 帧队列上访问
@property (nonatomic, readwrite) NSUInteger currentCount;
@property (nonatomic, readwrite, getter=isRunning) BOOL running;
@end

@implementation AROverlaySession

- (instancetype)init {
    if ((self = [super init])) {
        _capture = [ARCapture new];
        _recognizer = [ARRecognizer new];
        _recognizeQueue = dispatch_queue_create("AutoRedact.OverlayRecognize", DISPATCH_QUEUE_SERIAL);
        _covers = [NSMutableArray array];
        _recognitionsPerSecond = 5;
        __weak AROverlaySession *weakSelf = self;
        _capture.stoppedHandler = ^(NSError *error) {
            AROverlaySession *strongSelf = weakSelf;
            if (!strongSelf.running) return;
            [strongSelf stop];
            if (strongSelf.interruptedHandler) strongSelf.interruptedHandler(error);
        };
    }
    return self;
}

- (void)startDisplay:(CGDirectDisplayID)displayID screenFrame:(NSRect)screenFrame completion:(void (^)(NSError *))completion {
    if (self.running) {
        completion(nil);
        return;
    }
    self.recognizer.recognizesChinese = self.recognizesChinese;
    self.screenFrame = screenFrame;
    // 只用于识别，不需要原始分辨率。
    [self.capture startDisplay:displayID maxWidth:2048 fps:10 showsCursor:NO
                       prepare:^BOOL(CGSize size, NSError **error) {
        [AREngine resetTrackerWidth:size.width height:size.height padding:MAX(6, size.height / 150) hold:0.6];
        dispatch_sync(self.capture.frameQueue, ^{
            self.recognizing = NO;
            self.lastRecognitionTime = -INFINITY;
        });
        return YES;
    } frameHandler:^(CMSampleBufferRef sample, CVPixelBufferRef pixels, double time) {
        [self handleFrame:pixels time:time];
    } completion:^(NSError *error) {
        if (!error) self.running = YES;
        completion(error);
    }];
}

- (void)handleFrame:(CVPixelBufferRef)pixels time:(double)time {
    double interval = 1.0 / MAX(self.recognitionsPerSecond, 0.5);
    if (self.recognizing || time - self.lastRecognitionTime < interval) return;
    self.recognizing = YES;
    self.lastRecognitionTime = time;
    CVPixelBufferRetain(pixels);
    dispatch_async(self.recognizeQueue, ^{
        NSArray<ARDetection *> *detections = [self.recognizer detectionsInPixelBuffer:pixels];
        CVPixelBufferRelease(pixels);
        NSMutableArray<NSValue *> *rects = [NSMutableArray array];
        for (ARDetection *d in detections) [rects addObject:[NSValue valueWithRect:d.rect]];
        dispatch_async(self.capture.frameQueue, ^{
            [AREngine addBoxes:rects atTime:time];
            NSArray<NSValue *> *boxes = [AREngine boxesAtTime:time];
            self.recognizing = NO;
            dispatch_async(dispatch_get_main_queue(), ^{ [self showBoxes:boxes]; });
        });
    });
}

- (NSWindow *)newCoverWindow {
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 10, 10) styleMask:NSWindowStyleMaskBorderless
                                                     backing:NSBackingStoreBuffered defer:NO];
    window.releasedWhenClosed = NO;
    window.opaque = NO;
    window.backgroundColor = NSColor.clearColor;
    window.hasShadow = NO;
    window.ignoresMouseEvents = YES;
    window.level = NSScreenSaverWindowLevel - 1;
    window.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorStationary |
                                NSWindowCollectionBehaviorFullScreenAuxiliary | NSWindowCollectionBehaviorIgnoresCycle;
    window.contentView = [ARCoverView new];
    return window;
}

- (void)showBoxes:(NSArray<NSValue *> *)boxes {
    if (!self.running) return;
    CGSize pixelSize = self.capture.pixelSize;
    while (self.covers.count < boxes.count) [self.covers addObject:[self newCoverWindow]];
    for (NSUInteger i = 0; i < self.covers.count; i++) {
        NSWindow *cover = self.covers[i];
        if (i < boxes.count) {
            [cover setFrame:ARScreenRectFromPixelRect(boxes[i].rectValue, pixelSize, self.screenFrame) display:YES];
            [cover orderFrontRegardless];
        } else {
            [cover orderOut:nil];
        }
    }
    self.currentCount = boxes.count;
    if (self.updateHandler) self.updateHandler(boxes.count);
}

- (void)stop {
    self.running = NO;
    [self.capture stopWithCompletion:^{}];
    for (NSWindow *cover in self.covers) [cover orderOut:nil];
    self.currentCount = 0;
}

@end
