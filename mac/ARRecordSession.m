#import "ARRecordSession.h"
#import <AVFoundation/AVFoundation.h>
#import "ARCapture.h"
#import "ARMotion.h"
#import "ARRecognizer.h"

static NSError *ARRecordError(NSString *message) {
    return [NSError errorWithDomain:@"AutoRedact.Record" code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
}

/// 写入前等待的最短时间：之后的一次识别要比这一帧晚这么久，
/// 让刚滚进画面、当时还识别不到的内容能被往回追踪补上。
static const double ARReadyDelay = 0.25;
/// 缓存画面的内存上限（字节）。
static const double ARBufferBudget = 600.0 * 1024 * 1024;
static const int ARMaxBoxes = 256;

/// 等待写入的一帧（像素已复制，不占用截屏队列的缓冲区）。
@interface ARPendingFrame : NSObject {
@public
    CVPixelBufferRef pixels;
    CMTime pts;
    double time;
    long motionId;
}
@end

@implementation ARPendingFrame
- (void)dealloc {
    if (pixels) CVPixelBufferRelease(pixels);
}
@end

@interface ARRecordSession ()
@property (nonatomic, strong) ARCapture *capture;
@property (nonatomic, strong) ARRecognizer *recognizer;
@property (nonatomic, strong) dispatch_queue_t recognizeQueue;
@property (nonatomic, strong) CIContext *ciContext;
@property (nonatomic, strong, nullable) AVAssetWriter *writer;
@property (nonatomic, strong, nullable) AVAssetWriterInput *input;
@property (nonatomic, strong, nullable) AVAssetWriterInputPixelBufferAdaptor *adaptor;
@property (nonatomic) CVPixelBufferPoolRef copyPool;
// 以下只在帧队列上访问。
@property (nonatomic) ARMotionSession *motion;
/// 每次开始递增；丢弃上一次运行还没完成的识别结果。
@property (nonatomic) NSUInteger generation;
@property (nonatomic, strong) NSMutableArray<ARPendingFrame *> *pending;
@property (nonatomic) NSUInteger maxPending;
@property (nonatomic) BOOL recognizing;
@property (nonatomic) double lastRecognitionTime;
@property (nonatomic) BOOL sessionStarted;
@property (nonatomic) NSUInteger droppedFrames;
@property (nonatomic, readwrite) NSUInteger currentCount;
@property (nonatomic, readwrite, getter=isRunning) BOOL running;
@property (nonatomic, readwrite, nullable) NSDate *startedAt;
@property (nonatomic, strong, nullable) NSURL *outputURL;
@end

@implementation ARRecordSession

- (instancetype)init {
    if ((self = [super init])) {
        _capture = [ARCapture new];
        _recognizer = [ARRecognizer new];
        _recognizeQueue = dispatch_queue_create("AutoRedact.Recognize", DISPATCH_QUEUE_SERIAL);
        _ciContext = [CIContext contextWithOptions:nil];
        _pending = [NSMutableArray array];
        _recognitionsPerSecond = 5;
        __weak ARRecordSession *weakSelf = self;
        _capture.stoppedHandler = ^(NSError *error) { [weakSelf handleInterruption:error]; };
    }
    return self;
}

- (void)dealloc {
    if (_copyPool) CVPixelBufferPoolRelease(_copyPool);
    if (_motion) ARMotionDestroy(_motion);
}

- (void)startDisplay:(CGDirectDisplayID)displayID maxWidth:(NSInteger)maxWidth fps:(NSInteger)fps showsCursor:(BOOL)showsCursor
           outputURL:(NSURL *)url completion:(void (^)(NSError *))completion {
    if (self.running) {
        completion(ARRecordError(@"已经在录制"));
        return;
    }
    self.recognizer.recognizesChinese = self.recognizesChinese;
    NSInteger frameRate = MAX(fps, 1);
    [self.capture startDisplay:displayID maxWidth:maxWidth fps:frameRate showsCursor:showsCursor
                       prepare:^BOOL(CGSize size, NSError **error) {
        return [self prepareWriterURL:url size:size fps:frameRate error:error];
    } frameHandler:^(CMSampleBufferRef sample, CVPixelBufferRef pixels, double time) {
        [self handleFrame:pixels pts:CMSampleBufferGetPresentationTimeStamp(sample) time:time];
    } completion:^(NSError *error) {
        if (error) {
            [self.writer cancelWriting];
            [NSFileManager.defaultManager removeItemAtURL:url error:NULL];
            [self resetWriter];
            completion(error);
            return;
        }
        self.running = YES;
        self.startedAt = [NSDate date];
        self.outputURL = url;
        completion(nil);
    }];
}

- (BOOL)prepareWriterURL:(NSURL *)url size:(CGSize)size fps:(NSInteger)fps error:(NSError **)error {
    [NSFileManager.defaultManager createDirectoryAtURL:url.URLByDeletingLastPathComponent withIntermediateDirectories:YES
                                            attributes:nil error:NULL];
    AVAssetWriter *writer = [AVAssetWriter assetWriterWithURL:url fileType:AVFileTypeMPEG4 error:error];
    if (!writer) return NO;
    NSDictionary *settings = @{
        AVVideoCodecKey: AVVideoCodecTypeH264,
        AVVideoWidthKey: @(size.width),
        AVVideoHeightKey: @(size.height),
        AVVideoCompressionPropertiesKey: @{
            AVVideoAverageBitRateKey: @(MAX(2e6, size.width * size.height * fps * 0.1)),
            AVVideoExpectedSourceFrameRateKey: @(fps),
            AVVideoMaxKeyFrameIntervalKey: @(fps * 2),
        },
    };
    AVAssetWriterInput *input = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:settings];
    input.expectsMediaDataInRealTime = YES;
    NSDictionary *bufferAttributes = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferWidthKey: @(size.width),
        (id)kCVPixelBufferHeightKey: @(size.height),
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
    };
    AVAssetWriterInputPixelBufferAdaptor *adaptor =
        [AVAssetWriterInputPixelBufferAdaptor assetWriterInputPixelBufferAdaptorWithAssetWriterInput:input
                                                                         sourcePixelBufferAttributes:bufferAttributes];
    if (![writer canAddInput:input]) {
        if (error) *error = ARRecordError(@"无法使用该尺寸编码视频");
        return NO;
    }
    [writer addInput:input];
    if (![writer startWriting]) {
        if (error) *error = writer.error ?: ARRecordError(@"无法开始写入录屏文件");
        return NO;
    }
    if (self.copyPool) CVPixelBufferPoolRelease(self.copyPool);
    CVPixelBufferPoolRef pool = NULL;
    CVPixelBufferPoolCreate(kCFAllocatorDefault, NULL, (__bridge CFDictionaryRef)bufferAttributes, &pool);
    if (!pool) {
        [writer cancelWriting];
        if (error) *error = ARRecordError(@"无法分配画面缓冲区");
        return NO;
    }
    self.copyPool = pool;
    self.writer = writer;
    self.input = input;
    self.adaptor = adaptor;

    // 缓存帧数：覆盖“等待之后的识别 + 识别间隔 + 识别耗时”，同时不超过内存上限。
    double frameBytes = size.width * size.height * 4;
    NSUInteger wanted = (NSUInteger)ceil(fps * (ARReadyDelay + 1.0 / MAX(self.recognitionsPerSecond, 0.5) + 0.5)) + 4;
    NSUInteger affordable = (NSUInteger)MAX(8.0, floor(ARBufferBudget / MAX(frameBytes, 1)));
    NSUInteger maxPending = MIN(wanted, affordable);
    int factor = size.width > 1280 ? 2 : 1;
    ARMotionSession *motion = ARMotionCreate((int)size.width, (int)size.height, factor, MAX(6, size.height / 150), 0.6);
    dispatch_sync(self.capture.frameQueue, ^{
        if (self.motion) ARMotionDestroy(self.motion);
        self.motion = motion;
        self.maxPending = maxPending;
        self.generation++;
        [self.pending removeAllObjects];
        self.recognizing = NO;
        self.lastRecognitionTime = -INFINITY;
        self.sessionStarted = NO;
        self.droppedFrames = 0;
    });
    return YES;
}

- (void)resetWriter {
    self.writer = nil;
    self.input = nil;
    self.adaptor = nil;
}

#pragma mark - 帧处理（帧队列）

static CVPixelBufferRef ARCopyPixels(CVPixelBufferRef source, CVPixelBufferPoolRef pool, NSUInteger threshold) {
    CVPixelBufferRef copy = NULL;
    NSDictionary *aux = @{(id)kCVPixelBufferPoolAllocationThresholdKey: @(threshold)};
    if (CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool, (__bridge CFDictionaryRef)aux, &copy) != kCVReturnSuccess) {
        return NULL;
    }
    CVPixelBufferLockBaseAddress(source, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferLockBaseAddress(copy, 0);
    size_t height = MIN(CVPixelBufferGetHeight(source), CVPixelBufferGetHeight(copy));
    size_t srcRow = CVPixelBufferGetBytesPerRow(source), dstRow = CVPixelBufferGetBytesPerRow(copy);
    size_t row = MIN(srcRow, dstRow);
    const uint8_t *src = CVPixelBufferGetBaseAddress(source);
    uint8_t *dst = CVPixelBufferGetBaseAddress(copy);
    for (size_t y = 0; y < height; y++) memcpy(dst + y * dstRow, src + y * srcRow, row);
    CVPixelBufferUnlockBaseAddress(copy, 0);
    CVPixelBufferUnlockBaseAddress(source, kCVPixelBufferLock_ReadOnly);
    return copy;
}

- (void)handleFrame:(CVPixelBufferRef)pixels pts:(CMTime)pts time:(double)time {
    if (!self.copyPool || !self.motion) return;
    // 缓存已满：先用目前的追踪结果写出最早的帧（它们已被逐帧追踪遮住），而不是丢掉新画面。
    if (self.pending.count + 2 >= self.maxPending) [self drainCount:self.pending.count + 2 - self.maxPending + 1];
    CVPixelBufferRef copy = ARCopyPixels(pixels, self.copyPool, self.maxPending + 2);
    if (!copy) {
        self.droppedFrames++;
        return;
    }
    ARPendingFrame *frame = [ARPendingFrame new];
    frame->pixels = copy;
    frame->pts = pts;
    frame->time = time;
    CVPixelBufferLockBaseAddress(copy, kCVPixelBufferLock_ReadOnly);
    frame->motionId = ARMotionAddFrame(self.motion, CVPixelBufferGetBaseAddress(copy), (int)CVPixelBufferGetBytesPerRow(copy), time);
    CVPixelBufferUnlockBaseAddress(copy, kCVPixelBufferLock_ReadOnly);
    [self.pending addObject:frame];

    double interval = 1.0 / MAX(self.recognitionsPerSecond, 0.5);
    if (!self.recognizing && time - self.lastRecognitionTime >= interval) [self recognizeFrame:frame];
    [self drainReady];
}

- (void)recognizeFrame:(ARPendingFrame *)frame {
    self.recognizing = YES;
    self.lastRecognitionTime = frame->time;
    CVPixelBufferRef pixels = CVPixelBufferRetain(frame->pixels);
    long motionId = frame->motionId;
    NSUInteger generation = self.generation;
    dispatch_async(self.recognizeQueue, ^{
        NSArray<ARDetection *> *detections = [self.recognizer detectionsInPixelBuffer:pixels];
        CVPixelBufferRelease(pixels);
        dispatch_async(self.capture.frameQueue, ^{
            if (generation != self.generation) return;
            [self addDetections:detections frame:motionId];
            self.recognizing = NO;
            dispatch_async(dispatch_get_main_queue(), ^{ self.currentCount = detections.count; });
            [self drainReady];
        });
    });
}

- (void)addDetections:(NSArray<ARDetection *> *)detections frame:(long)motionId {
    if (!self.motion) return;
    NSUInteger n = detections.count;
    ARBox *boxes = calloc(MAX(n, 1), sizeof(ARBox));
    uint32_t *keys = calloc(MAX(n, 1), sizeof(uint32_t));
    for (NSUInteger i = 0; i < n; i++) {
        NSRect r = detections[i].rect;
        boxes[i] = (ARBox){r.origin.x, r.origin.y, r.size.width, r.size.height};
        keys[i] = detections[i].key;
    }
    ARMotionAddDetections(self.motion, motionId, boxes, keys, (int)n);
    free(boxes);
    free(keys);
}

/// 写入已经确定打码区域的帧。
- (void)drainReady {
    if (!self.motion) return;
    while (self.pending.count && ARMotionFrameReady(self.motion, self.pending.firstObject->motionId, ARReadyDelay)) {
        [self writeOldest];
    }
}

- (void)drainCount:(NSUInteger)count {
    for (NSUInteger i = 0; i < count && self.pending.count; i++) [self writeOldest];
}

- (void)writeOldest {
    ARPendingFrame *frame = self.pending.firstObject;
    [self.pending removeObjectAtIndex:0];
    [self writeFrame:frame];
    ARMotionRelease(self.motion, frame->motionId + 1);
}

- (void)writeFrame:(ARPendingFrame *)frame {
    AVAssetWriter *writer = self.writer;
    AVAssetWriterInputPixelBufferAdaptor *adaptor = self.adaptor;
    if (!writer || writer.status != AVAssetWriterStatusWriting || !adaptor) return;
    if (!self.sessionStarted) {
        [writer startSessionAtSourceTime:frame->pts];
        self.sessionStarted = YES;
    }
    if (!adaptor.assetWriterInput.readyForMoreMediaData) {
        self.droppedFrames++;
        return;
    }
    CVPixelBufferRef output = NULL;
    if (!adaptor.pixelBufferPool ||
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, adaptor.pixelBufferPool, &output) != kCVReturnSuccess) {
        self.droppedFrames++;
        return;
    }
    ARBox boxes[ARMaxBoxes];
    int n = ARMotionBoxesForFrame(self.motion, frame->motionId, boxes, ARMaxBoxes);
    NSMutableArray<NSValue *> *rects = [NSMutableArray arrayWithCapacity:(NSUInteger)n];
    for (int i = 0; i < n; i++) [rects addObject:[NSValue valueWithRect:NSMakeRect(boxes[i].x, boxes[i].y, boxes[i].w, boxes[i].h)]];
    CIImage *image = ARRedactImage([CIImage imageWithCVPixelBuffer:frame->pixels], rects, self.style);
    [self.ciContext render:image toCVPixelBuffer:output];
    [adaptor appendPixelBuffer:output withPresentationTime:frame->pts];
    CVPixelBufferRelease(output);
}

#pragma mark - 结束

- (void)stopWithCompletion:(void (^)(NSURL *, NSError *))completion {
    if (!self.running) {
        completion(nil, ARRecordError(@"没有正在进行的录制"));
        return;
    }
    self.running = NO;
    NSURL *url = self.outputURL;
    [self.capture stopWithCompletion:^{
        // 帧队列：等正在进行的识别完成，再对最后一帧识别一次，让结尾的帧也有之后的结果，然后全部写完。
        dispatch_sync(self.recognizeQueue, ^{});
        ARPendingFrame *last = self.pending.lastObject;
        if (last) [self addDetections:[self.recognizer detectionsInPixelBuffer:last->pixels] frame:last->motionId];
        [self drainCount:self.pending.count];
        AVAssetWriter *writer = self.writer;
        BOOL started = self.sessionStarted;
        void (^finish)(NSURL *, NSError *) = ^(NSURL *savedURL, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self resetWriter];
                self.startedAt = nil;
                self.currentCount = 0;
                completion(savedURL, error);
            });
        };
        if (self.motion) {
            ARMotionDestroy(self.motion);
            self.motion = NULL;
        }
        if (!writer || !started) {
            [writer cancelWriting];
            [NSFileManager.defaultManager removeItemAtURL:url error:NULL];
            finish(nil, ARRecordError(@"没有录到画面：请确认已在“屏幕与系统录音”中允许“自动打码”"));
            return;
        }
        [self.input markAsFinished];
        [writer finishWritingWithCompletionHandler:^{
            if (writer.status == AVAssetWriterStatusCompleted) {
                finish(url, nil);
            } else {
                finish(nil, writer.error ?: ARRecordError(@"保存录屏失败"));
            }
        }];
    }];
}

- (void)handleInterruption:(NSError *)error {
    if (!self.running) return;
    [self stopWithCompletion:^(NSURL *url, NSError *stopError) {
        if (self.interruptedHandler) self.interruptedHandler(url, error ?: stopError);
    }];
}

@end
