#import "AROverlaySession.h"
#import "ARCapture.h"
#import "ARMotion.h"
#import "ARRecognizer.h"

/// 追踪用的画面帧率；遮挡块每一帧都会更新位置。
static const NSInteger ARTrackingFPS = 30;
/// 保留最近的画面帧数，用于识别结果出来后从那一帧追踪到当前。
static const long ARKeepFrames = 24;
/// 画面到屏幕上显示遮挡的延迟（帧），按速度提前覆盖。
static const double ARLatencyFrames = 2;
static const int ARMaxBoxes = 256;

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
// 以下只在帧队列上访问。
@property (nonatomic) ARMotionSession *motion;
/// 每次开始递增；丢弃上一次运行还没完成的识别结果。
@property (nonatomic) NSUInteger generation;
@property (nonatomic) BOOL recognizing;
@property (nonatomic) double lastRecognitionTime;
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

- (void)dealloc {
    if (_motion) ARMotionDestroy(_motion);
}

- (void)startDisplay:(CGDirectDisplayID)displayID screenFrame:(NSRect)screenFrame completion:(void (^)(NSError *))completion {
    if (self.running) {
        completion(nil);
        return;
    }
    self.recognizer.recognizesChinese = self.recognizesChinese;
    self.screenFrame = screenFrame;
    // 只用于识别与追踪，不需要原始分辨率。
    [self.capture startDisplay:displayID maxWidth:1920 fps:ARTrackingFPS showsCursor:NO
                       prepare:^BOOL(CGSize size, NSError **error) {
        ARMotionSession *motion = ARMotionCreate((int)size.width, (int)size.height, size.width > 1280 ? 2 : 1,
                                                 MAX(6, size.height / 150), 0.6);
        dispatch_sync(self.capture.frameQueue, ^{
            if (self.motion) ARMotionDestroy(self.motion);
            self.motion = motion;
            self.generation++;
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

#pragma mark - 帧处理（帧队列）

- (void)handleFrame:(CVPixelBufferRef)pixels time:(double)time {
    if (!self.motion) return;
    CVPixelBufferLockBaseAddress(pixels, kCVPixelBufferLock_ReadOnly);
    long frameId = ARMotionAddFrame(self.motion, CVPixelBufferGetBaseAddress(pixels), (int)CVPixelBufferGetBytesPerRow(pixels), time);
    CVPixelBufferUnlockBaseAddress(pixels, kCVPixelBufferLock_ReadOnly);
    ARMotionRelease(self.motion, frameId - ARKeepFrames);

    double interval = 1.0 / MAX(self.recognitionsPerSecond, 0.5);
    if (!self.recognizing && time - self.lastRecognitionTime >= interval) {
        self.recognizing = YES;
        self.lastRecognitionTime = time;
        CVPixelBufferRetain(pixels);
        NSUInteger generation = self.generation;
        dispatch_async(self.recognizeQueue, ^{
            NSArray<ARDetection *> *detections = [self.recognizer detectionsInPixelBuffer:pixels];
            CVPixelBufferRelease(pixels);
            dispatch_async(self.capture.frameQueue, ^{
                if (generation != self.generation) return;
                [self addDetections:detections frame:frameId];
                self.recognizing = NO;
                [self publishBoxes];
            });
        });
    }
    [self publishBoxes];
}

- (void)addDetections:(NSArray<ARDetection *> *)detections frame:(long)frameId {
    if (!self.motion) return;
    NSUInteger n = detections.count;
    ARBox *boxes = calloc(MAX(n, 1), sizeof(ARBox));
    uint32_t *keys = calloc(MAX(n, 1), sizeof(uint32_t));
    for (NSUInteger i = 0; i < n; i++) {
        NSRect r = detections[i].rect;
        boxes[i] = (ARBox){r.origin.x, r.origin.y, r.size.width, r.size.height};
        keys[i] = detections[i].key;
    }
    ARMotionAddDetections(self.motion, frameId, boxes, keys, (int)n);
    free(boxes);
    free(keys);
}

/// 当前位置加上之后几帧按速度会经过的位置（抵消画面到屏幕显示的延迟）。
- (void)publishBoxes {
    if (!self.motion) return;
    ARBox boxes[ARMaxBoxes];
    int n = ARMotionPredictedBoxes(self.motion, ARLatencyFrames, boxes, ARMaxBoxes);
    NSMutableArray<NSValue *> *rects = [NSMutableArray arrayWithCapacity:(NSUInteger)n];
    for (int i = 0; i < n; i++) [rects addObject:[NSValue valueWithRect:NSMakeRect(boxes[i].x, boxes[i].y, boxes[i].w, boxes[i].h)]];
    dispatch_async(dispatch_get_main_queue(), ^{ [self showBoxes:rects]; });
}

#pragma mark - 遮挡窗口（主线程）

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
            NSRect frame = NSIntersectionRect(ARScreenRectFromPixelRect(boxes[i].rectValue, pixelSize, self.screenFrame), self.screenFrame);
            if (!NSEqualRects(cover.frame, frame)) [cover setFrame:frame display:YES];
            if (!cover.isVisible) [cover orderFrontRegardless];
        } else if (cover.isVisible) {
            [cover orderOut:nil];
        }
    }
    if (self.currentCount != boxes.count) {
        self.currentCount = boxes.count;
        if (self.updateHandler) self.updateHandler(boxes.count);
    }
}

- (void)stop {
    self.running = NO;
    [self.capture stopWithCompletion:^{
        // 帧队列：此后不会再有新帧。
        if (self.motion) {
            ARMotionDestroy(self.motion);
            self.motion = NULL;
        }
    }];
    for (NSWindow *cover in self.covers) [cover orderOut:nil];
    self.currentCount = 0;
}

@end
