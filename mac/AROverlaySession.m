#import "AROverlaySession.h"
#import "ARCapture.h"
#import "ARMotion.h"
#import "ARPrivacyWindows.h"
#import "ARRecognizer.h"

/// 追踪用的画面帧率；遮挡块每一帧都会更新位置。
static const NSInteger ARTrackingFPS = 30;
/// 保留最近的画面帧数，用于识别结果出来后从那一帧追踪到当前。
static const long ARKeepFrames = 24;
/// 画面到屏幕上显示遮挡的延迟（帧），按速度提前覆盖。
static const double ARLatencyFrames = 2;
/// 至少每隔这么久识别一次整个画面（其余时候只识别变化的区域）。
static const double ARFullInterval = 1.0;
enum { ARMaxBoxes = 256 };

NSRect ARScreenRectFromPixelRect(NSRect r, CGSize pixelSize, NSRect screen) {
    CGFloat sx = screen.size.width / MAX(pixelSize.width, 1), sy = screen.size.height / MAX(pixelSize.height, 1);
    return NSMakeRect(NSMinX(screen) + r.origin.x * sx,
                      NSMaxY(screen) - (r.origin.y + r.size.height) * sy,
                      r.size.width * sx, r.size.height * sy);
}

@interface ARCoverView : NSView
@property (nonatomic, copy) NSString *label;
@end

@implementation ARCoverView
- (void)drawRect:(NSRect)dirtyRect {
    [[NSColor colorWithRed:0.12 green:0.12 blue:0.13 alpha:1] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:4 yRadius:4] fill];
    NSString *label = self.label ?: @"已隐藏";
    if (self.bounds.size.width >= 64 && self.bounds.size.height >= 16) {
        NSDictionary *attrs = @{NSFontAttributeName: [NSFont systemFontOfSize:MIN(13, self.bounds.size.height * 0.6)],
                                NSForegroundColorAttributeName: [NSColor colorWithWhite:1 alpha:0.6]};
        NSSize size = [label sizeWithAttributes:attrs];
        [label drawAtPoint:NSMakePoint(NSMidX(self.bounds) - size.width / 2, NSMidY(self.bounds) - size.height / 2) withAttributes:attrs];
    }
}
@end

/// 一组遮挡窗口（按需增减，复用）。
@interface ARCoverPool : NSObject
@property (nonatomic, copy) NSString *label;
@property (nonatomic, strong) NSMutableArray<NSWindow *> *windows;
- (void)showFrames:(NSArray<NSValue *> *)frames;
- (void)hideAll;
@end

@implementation ARCoverPool
- (instancetype)initWithLabel:(NSString *)label {
    if ((self = [super init])) {
        _label = [label copy];
        _windows = [NSMutableArray array];
    }
    return self;
}

- (NSWindow *)newWindow {
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
    ARCoverView *view = [ARCoverView new];
    view.label = self.label;
    window.contentView = view;
    return window;
}

- (void)showFrames:(NSArray<NSValue *> *)frames {
    while (self.windows.count < frames.count) [self.windows addObject:[self newWindow]];
    for (NSUInteger i = 0; i < self.windows.count; i++) {
        NSWindow *cover = self.windows[i];
        if (i < frames.count) {
            NSRect frame = frames[i].rectValue;
            if (!NSEqualRects(cover.frame, frame)) [cover setFrame:frame display:YES];
            if (!cover.isVisible) [cover orderFrontRegardless];
        } else if (cover.isVisible) {
            [cover orderOut:nil];
        }
    }
}

- (void)hideAll {
    for (NSWindow *cover in self.windows) [cover orderOut:nil];
}
@end

@interface AROverlaySession ()
@property (nonatomic, strong) ARCapture *capture;
@property (nonatomic, strong) ARRecognizer *recognizer;
@property (nonatomic, strong) dispatch_queue_t recognizeQueue;
@property (nonatomic, strong) ARCoverPool *detectionCovers;
@property (nonatomic, strong) ARCoverPool *privacyCovers;
@property (nonatomic, strong) ARCoverPool *fixedCovers;
@property (nonatomic, strong, nullable) NSTimer *privacyTimer;
@property (nonatomic) NSRect screenFrame;
// 以下只在帧队列上访问。
@property (nonatomic) ARMotionSession *motion;
@property (nonatomic) NSUInteger generation;
@property (nonatomic) BOOL recognizing;
@property (nonatomic) double lastRecognitionTime;
@property (nonatomic) double lastFullTime;
@property (nonatomic) long lastRecognizedFrame;
@property (nonatomic, readwrite) NSUInteger currentCount;
@property (nonatomic, readwrite, getter=isRunning) BOOL running;
@end

@implementation AROverlaySession

- (instancetype)init {
    if ((self = [super init])) {
        _capture = [ARCapture new];
        _recognizer = [ARRecognizer new];
        _recognizeQueue = dispatch_queue_create("AutoRedact.OverlayRecognize", DISPATCH_QUEUE_SERIAL);
        _detectionCovers = [[ARCoverPool alloc] initWithLabel:@"已隐藏"];
        _privacyCovers = [[ARCoverPool alloc] initWithLabel:@"隐私窗口"];
        _fixedCovers = [[ARCoverPool alloc] initWithLabel:@"已隐藏"];
        _privacyBundleIDs = @[];
        _fixedRegions = @[];
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
    self.recognizer.detectsCodes = self.detectsCodes;
    self.recognizer.detectsFaces = self.detectsFaces;
    self.screenFrame = screenFrame;
    ARCaptureOptions *options = [ARCaptureOptions new];
    options.displayID = displayID;
    options.maxWidth = 0; // 原始分辨率：小字识别更可靠
    options.fps = ARTrackingFPS;
    options.showsCursor = NO;
    [self.capture startWithOptions:options prepare:^BOOL(CGSize size, NSError **error) {
        ARMotionSession *motion = ARMotionCreate((int)size.width, (int)size.height, ARMotionFactorForWidth((int)size.width),
                                                 MAX(6, size.height / 150), 0.6);
        dispatch_sync(self.capture.frameQueue, ^{
            if (self.motion) ARMotionDestroy(self.motion);
            self.motion = motion;
            self.generation++;
            self.recognizing = NO;
            self.lastRecognitionTime = -INFINITY;
            self.lastFullTime = -INFINITY;
            self.lastRecognizedFrame = -1;
        });
        return YES;
    } frameHandler:^(CMSampleBufferRef sample, CVPixelBufferRef pixels, double time) {
        [self handleFrame:pixels time:time];
    } audioHandler:nil completion:^(NSError *error) {
        if (!error) {
            self.running = YES;
            [self.fixedCovers showFrames:self.fixedRegions];
            __weak AROverlaySession *weakSelf = self;
            // 隐私窗口：每秒更新 15 次位置，跟随窗口移动和打开关闭。
            if (self.privacyBundleIDs.count) {
                self.privacyTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 / 15 repeats:YES block:^(NSTimer *timer) {
                    AROverlaySession *strongSelf = weakSelf;
                    if (!strongSelf.running) return;
                    [strongSelf.privacyCovers showFrames:[ARPrivacyWindows windowFramesForBundleIDs:strongSelf.privacyBundleIDs]];
                }];
                [self.privacyTimer fire];
            }
        }
        completion(error);
    }];
}

#pragma mark - 帧处理（帧队列）

- (void)handleFrame:(CVPixelBufferRef)pixels time:(double)time {
    if (!self.motion) return;
    CVPixelBufferLockBaseAddress(pixels, kCVPixelBufferLock_ReadOnly);
    long frameId = ARMotionAddFrame(self.motion, CVPixelBufferGetBaseAddress(pixels), (int)CVPixelBufferGetBytesPerRow(pixels), time);
    CVPixelBufferUnlockBaseAddress(pixels, kCVPixelBufferLock_ReadOnly);
    // 上次识别的那一帧要留着，用来比较画面变化。
    long keepFrom = frameId - ARKeepFrames;
    if (self.lastRecognizedFrame >= 0 && self.lastRecognizedFrame < keepFrom) keepFrom = self.lastRecognizedFrame;
    ARMotionRelease(self.motion, keepFrom);

    double interval = 1.0 / MAX(self.recognitionsPerSecond, 0.5);
    if (!self.recognizing && time - self.lastRecognitionTime >= interval) {
        ARBox region;
        ARRecognizePlan plan = ARMotionPlanRecognition(self.motion, self.lastRecognizedFrame, frameId, time - self.lastFullTime,
                                                       ARFullInterval, 32, &region);
        if (plan == ARRecognizeNone) {
            // 画面和上次识别时一样，不必识别；以这一帧作为之后比较的基准。
            self.lastRecognizedFrame = frameId;
            self.lastRecognitionTime = time;
        } else {
            NSRect roi = plan == ARRecognizeRegion ? NSMakeRect(region.x, region.y, region.w, region.h) : NSZeroRect;
            self.recognizing = YES;
            self.lastRecognitionTime = time;
            if (plan == ARRecognizeFull) self.lastFullTime = time;
            self.lastRecognizedFrame = frameId;
            CVPixelBufferRetain(pixels);
            NSUInteger generation = self.generation;
            dispatch_async(self.recognizeQueue, ^{
                NSArray<ARDetection *> *detections = [self.recognizer detectionsInPixelBuffer:pixels region:roi];
                CVPixelBufferRelease(pixels);
                dispatch_async(self.capture.frameQueue, ^{
                    if (generation != self.generation) return;
                    [self addDetections:detections frame:frameId];
                    self.recognizing = NO;
                    [self publishBoxes];
                });
            });
        }
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
    CGSize pixelSize = self.capture.pixelSize;
    NSRect screen = self.screenFrame;
    NSMutableArray<NSValue *> *frames = [NSMutableArray arrayWithCapacity:(NSUInteger)n];
    for (int i = 0; i < n; i++) {
        NSRect r = ARScreenRectFromPixelRect(NSMakeRect(boxes[i].x, boxes[i].y, boxes[i].w, boxes[i].h), pixelSize, screen);
        [frames addObject:[NSValue valueWithRect:NSIntersectionRect(r, screen)]];
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.running) return;
        [self.detectionCovers showFrames:frames];
        if (self.currentCount != frames.count) {
            self.currentCount = frames.count;
            if (self.updateHandler) self.updateHandler(frames.count);
        }
    });
}

- (void)stop {
    self.running = NO;
    [self.privacyTimer invalidate];
    self.privacyTimer = nil;
    [self.capture stopWithCompletion:^{
        // 帧队列：此后不会再有新帧。
        if (self.motion) {
            ARMotionDestroy(self.motion);
            self.motion = NULL;
        }
    }];
    [self.detectionCovers hideAll];
    [self.privacyCovers hideAll];
    [self.fixedCovers hideAll];
    self.currentCount = 0;
}

@end
