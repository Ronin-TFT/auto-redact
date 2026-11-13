#import "AROverlaySession.h"
#import "ARCapture.h"
#import "AREngine.h"
#import "ARRecognizer.h"
#import <CoreMedia/CoreMedia.h>

NSSize ARScrollSince(NSArray<NSArray<NSNumber *> *> *events, double since) {
    double dx = 0, dy = 0;
    for (NSArray<NSNumber *> *e in events) {
        if (e.count == 3 && e[0].doubleValue > since) {
            dx += fabs(e[1].doubleValue);
            dy += fabs(e[2].doubleValue);
        }
    }
    return NSMakeSize(dx, dy);
}

static double ARHostNow(void) {
    return CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()));
}

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
/// 最近一次识别得到的遮挡位置（屏幕坐标），以及对应画面的时间。
@property (nonatomic, strong) NSArray<NSValue *> *baseFrames;
@property (nonatomic) double baseTime;
/// 最近的滚动事件 [时间, |dx|, |dy|]（主线程访问）。
@property (nonatomic, strong) NSMutableArray<NSArray<NSNumber *> *> *scrollEvents;
@property (nonatomic, strong, nullable) id globalScrollMonitor;
@property (nonatomic, strong, nullable) id localScrollMonitor;
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
        _baseFrames = @[];
        _scrollEvents = [NSMutableArray array];
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
        if (!error) {
            self.running = YES;
            [self installScrollMonitors];
        }
        completion(error);
    }];
}

// 一检测到滚动就把遮挡块沿滚动方向扩大，不等下一次识别。
- (void)installScrollMonitors {
    __weak AROverlaySession *weakSelf = self;
    void (^record)(NSEvent *) = ^(NSEvent *event) {
        AROverlaySession *strongSelf = weakSelf;
        if (!strongSelf.running) return;
        double scale = event.hasPreciseScrollingDeltas ? 1.0 : 12.0;
        [strongSelf.scrollEvents addObject:@[@(event.timestamp), @(event.scrollingDeltaX * scale), @(event.scrollingDeltaY * scale)]];
        [strongSelf layoutCovers];
    };
    self.globalScrollMonitor = [NSEvent addGlobalMonitorForEventsMatchingMask:NSEventMaskScrollWheel handler:record];
    self.localScrollMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskScrollWheel handler:^NSEvent *(NSEvent *event) {
        record(event);
        return event;
    }];
}

- (void)removeScrollMonitors {
    if (self.globalScrollMonitor) [NSEvent removeMonitor:self.globalScrollMonitor];
    if (self.localScrollMonitor) [NSEvent removeMonitor:self.localScrollMonitor];
    self.globalScrollMonitor = nil;
    self.localScrollMonitor = nil;
    [self.scrollEvents removeAllObjects];
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
        dispatch_async(self.capture.frameQueue, ^{
            [AREngine addDetections:detections atTime:time];
            // 从画面时间到下一次更新前，按滚动速度预测文字会经过的位置。
            double ahead = MAX(0, ARHostNow() - time) + 1.0 / MAX(self.recognitionsPerSecond, 0.5) + 0.1;
            NSArray<NSValue *> *boxes = [AREngine boxesAtTime:time ahead:ahead];
            self.recognizing = NO;
            dispatch_async(dispatch_get_main_queue(), ^{ [self showBoxes:boxes frameTime:time]; });
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

- (void)showBoxes:(NSArray<NSValue *> *)boxes frameTime:(double)frameTime {
    if (!self.running) return;
    CGSize pixelSize = self.capture.pixelSize;
    NSMutableArray<NSValue *> *frames = [NSMutableArray arrayWithCapacity:boxes.count];
    for (NSValue *box in boxes) {
        [frames addObject:[NSValue valueWithRect:ARScreenRectFromPixelRect(box.rectValue, pixelSize, self.screenFrame)]];
    }
    self.baseFrames = frames;
    self.baseTime = frameTime;
    // 识别所用画面之前的滚动已经反映在结果里，只保留之后的。
    NSIndexSet *old = [self.scrollEvents indexesOfObjectsPassingTest:^BOOL(NSArray<NSNumber *> *e, NSUInteger idx, BOOL *stop) {
        return e[0].doubleValue <= frameTime - 1.0;
    }];
    [self.scrollEvents removeObjectsAtIndexes:old];
    [self layoutCovers];
    self.currentCount = boxes.count;
    if (self.updateHandler) self.updateHandler(boxes.count);
}

/// 按识别结果放置遮挡块；画面之后发生的滚动，让遮挡块向两个方向扩大相应距离。
- (void)layoutCovers {
    NSSize scroll = ARScrollSince(self.scrollEvents, self.baseTime);
    NSArray<NSValue *> *frames = self.baseFrames;
    while (self.covers.count < frames.count) [self.covers addObject:[self newCoverWindow]];
    for (NSUInteger i = 0; i < self.covers.count; i++) {
        NSWindow *cover = self.covers[i];
        if (i < frames.count) {
            NSRect frame = NSInsetRect(frames[i].rectValue, -scroll.width, -scroll.height);
            [cover setFrame:NSIntersectionRect(frame, self.screenFrame) display:YES];
            [cover orderFrontRegardless];
        } else {
            [cover orderOut:nil];
        }
    }
}

- (void)stop {
    self.running = NO;
    [self removeScrollMonitors];
    self.baseFrames = @[];
    [self.capture stopWithCompletion:^{}];
    for (NSWindow *cover in self.covers) [cover orderOut:nil];
    self.currentCount = 0;
}

@end
