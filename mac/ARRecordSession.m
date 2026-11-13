#import "ARRecordSession.h"
#import <AVFoundation/AVFoundation.h>
#import <math.h>
#import <unistd.h>
#import "ARCapture.h"
#import "ARMicrophone.h"
#import "ARMotion.h"
#import "ARRecognizer.h"

static NSError *ARRecordError(NSString *message) {
    return [NSError errorWithDomain:@"AutoRedact.Record" code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
}

/// 写入前等待的最短时间：之后的一次识别要比这一帧晚这么久，让刚滚进画面的内容能被往回追踪补上。
static const double ARReadyDelay = 0.25;
/// 至少每隔这么久识别一次整个画面（其余时候只识别变化的区域）。
static const double ARFullInterval = 1.0;
/// 缓存画面的内存上限（字节）。
static const double ARBufferBudget = 700.0 * 1024 * 1024;
enum { ARMaxBoxes = 256 };
/// 同一类型间隔超过这么久就算新的一段（复查列表）。
static const double ARSegmentGap = 2.0;

NSRect ARCapturePixelRect(CGRect r, CGRect source, CGSize pixelSize) {
    double sx = pixelSize.width / MAX(source.size.width, 1), sy = pixelSize.height / MAX(source.size.height, 1);
    return NSMakeRect((r.origin.x - source.origin.x) * sx, (r.origin.y - source.origin.y) * sy, r.size.width * sx, r.size.height * sy);
}

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
@property (nonatomic, strong) ARMicrophone *microphone;
@property (nonatomic, strong) ARRecognizer *recognizer;
@property (nonatomic, strong) dispatch_queue_t recognizeQueue;
@property (nonatomic, strong) CIContext *ciContext;
@property (nonatomic, strong, nullable) AVAssetWriter *writer;
@property (nonatomic, strong, nullable) AVAssetWriterInput *input;
@property (nonatomic, strong, nullable) AVAssetWriterInput *systemAudioInput;
@property (nonatomic, strong, nullable) AVAssetWriterInput *micInput;
@property (nonatomic, strong, nullable) AVAssetWriterInputPixelBufferAdaptor *adaptor;
@property (nonatomic) CVPixelBufferPoolRef copyPool;
@property (nonatomic) CGSize outputSize;
@property (nonatomic, strong, nullable) NSTimer *privacyTimer;
// 以下只在帧队列上访问。
@property (nonatomic) ARMotionSession *motion;
@property (nonatomic) NSUInteger generation;
@property (nonatomic, strong) NSMutableArray<ARPendingFrame *> *pending;
@property (nonatomic) NSUInteger maxPending;
@property (nonatomic) BOOL recognizing;
@property (nonatomic) double lastRecognitionTime;
@property (nonatomic) double lastFullTime;
@property (nonatomic) long lastRecognizedFrame;
@property (nonatomic) BOOL sessionStarted;
@property (nonatomic) CMTime sessionStart;
@property (nonatomic) double firstFrameTime;
@property (nonatomic) NSUInteger droppedFrames;
@property (nonatomic, strong) NSArray<NSValue *> *fixedPixelRects;
@property (nonatomic, strong) NSMutableArray *systemAudio; // CMSampleBuffer，等视频写到对应时间再写入
@property (nonatomic, strong) NSMutableArray *micAudio;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSMutableDictionary *> *openSegments;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *closedSegments;
@property (nonatomic, readwrite) NSUInteger currentCount;
@property (nonatomic, readwrite, getter=isRunning) BOOL running;
@property (nonatomic, readwrite, nullable) NSDate *startedAt;
@property (nonatomic, readwrite, copy) NSArray<NSDictionary *> *segments;
@property (nonatomic, strong, nullable) NSURL *outputURL;
@end

@implementation ARRecordSession

- (instancetype)init {
    if ((self = [super init])) {
        _capture = [ARCapture new];
        _microphone = [ARMicrophone new];
        _recognizer = [ARRecognizer new];
        _recognizeQueue = dispatch_queue_create("AutoRedact.Recognize", DISPATCH_QUEUE_SERIAL);
        _ciContext = [CIContext contextWithOptions:nil];
        _pending = [NSMutableArray array];
        _systemAudio = [NSMutableArray array];
        _micAudio = [NSMutableArray array];
        _openSegments = [NSMutableDictionary dictionary];
        _closedSegments = [NSMutableArray array];
        _fixedRegions = @[];
        _excludedBundleIDs = @[];
        _segments = @[];
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

- (void)startDisplay:(CGDirectDisplayID)displayID sourceRect:(CGRect)sourceRect maxWidth:(NSInteger)maxWidth fps:(NSInteger)fps
         showsCursor:(BOOL)showsCursor outputURL:(NSURL *)url completion:(void (^)(NSError *))completion {
    if (self.running) {
        completion(ARRecordError(@"已经在录制"));
        return;
    }
    self.recognizer.recognizesChinese = self.recognizesChinese;
    self.recognizer.detectsCodes = self.detectsCodes;
    self.recognizer.detectsFaces = self.detectsFaces;
    self.segments = @[];
    NSInteger frameRate = MAX(fps, 1);
    ARCaptureOptions *options = [ARCaptureOptions new];
    options.displayID = displayID;
    options.maxWidth = 0; // 按原始分辨率捕获：小字识别更可靠，录像再按画质缩放
    options.fps = frameRate;
    options.showsCursor = showsCursor;
    options.sourceRect = sourceRect;
    options.capturesSystemAudio = self.recordsSystemAudio;
    options.excludedBundleIDs = self.excludedBundleIDs;

    __weak ARRecordSession *weakSelf = self;
    void (^audioHandler)(CMSampleBufferRef) = ^(CMSampleBufferRef sample) { [weakSelf enqueueAudio:sample microphone:NO]; };
    [self.capture startWithOptions:options prepare:^BOOL(CGSize size, NSError **error) {
        return [self prepareWriterURL:url captureSize:size maxWidth:maxWidth fps:frameRate error:error];
    } frameHandler:^(CMSampleBufferRef sample, CVPixelBufferRef pixels, double time) {
        [self handleFrame:pixels pts:CMSampleBufferGetPresentationTimeStamp(sample) time:time];
    } audioHandler:self.recordsSystemAudio ? audioHandler : nil completion:^(NSError *error) {
        if (error) {
            [self.writer cancelWriting];
            [NSFileManager.defaultManager removeItemAtURL:url error:NULL];
            [self resetWriter];
            completion(error);
            return;
        }
        // 固定遮挡区域换算为画面像素坐标。
        NSMutableArray<NSValue *> *fixed = [NSMutableArray array];
        for (NSValue *region in self.fixedRegions) {
            [fixed addObject:[NSValue valueWithRect:ARCapturePixelRect(region.rectValue, self.capture.sourceRect, self.capture.pixelSize)]];
        }
        dispatch_sync(self.capture.frameQueue, ^{ self.fixedPixelRects = fixed; });
        if (self.recordsMicrophone) {
            NSError *micError = nil;
            if (![self.microphone startWithDeviceID:self.microphoneID handler:^(CMSampleBufferRef sample) {
                     [weakSelf enqueueAudio:sample microphone:YES];
                 } error:&micError]) {
                NSLog(@"麦克风无法使用：%@", micError);
            }
        }
        // 录制中打开的隐私 App 也要排除。
        if (self.excludedBundleIDs.count) {
            self.privacyTimer = [NSTimer scheduledTimerWithTimeInterval:3 repeats:YES block:^(NSTimer *timer) {
                [weakSelf.capture updateExcludedBundleIDs:weakSelf.excludedBundleIDs];
            }];
        }
        self.running = YES;
        self.startedAt = [NSDate date];
        self.outputURL = url;
        completion(nil);
    }];
}

- (BOOL)prepareWriterURL:(NSURL *)url captureSize:(CGSize)size maxWidth:(NSInteger)maxWidth fps:(NSInteger)fps error:(NSError **)error {
    [NSFileManager.defaultManager createDirectoryAtURL:url.URLByDeletingLastPathComponent withIntermediateDirectories:YES
                                            attributes:nil error:NULL];
    AVAssetWriter *writer = [AVAssetWriter assetWriterWithURL:url fileType:AVFileTypeMPEG4 error:error];
    if (!writer) return NO;
    CGSize output = ARCaptureSize(size, 1, maxWidth);
    NSDictionary *settings = @{
        AVVideoCodecKey: AVVideoCodecTypeH264,
        AVVideoWidthKey: @(output.width),
        AVVideoHeightKey: @(output.height),
        AVVideoCompressionPropertiesKey: @{
            AVVideoAverageBitRateKey: @(MAX(2e6, output.width * output.height * fps * 0.1)),
            AVVideoExpectedSourceFrameRateKey: @(fps),
            AVVideoMaxKeyFrameIntervalKey: @(fps * 2),
        },
    };
    AVAssetWriterInput *input = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:settings];
    input.expectsMediaDataInRealTime = YES;
    NSDictionary *outputAttributes = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferWidthKey: @(output.width),
        (id)kCVPixelBufferHeightKey: @(output.height),
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
    };
    AVAssetWriterInputPixelBufferAdaptor *adaptor =
        [AVAssetWriterInputPixelBufferAdaptor assetWriterInputPixelBufferAdaptorWithAssetWriterInput:input
                                                                         sourcePixelBufferAttributes:outputAttributes];
    if (![writer canAddInput:input]) {
        if (error) *error = ARRecordError(@"无法使用该尺寸编码视频");
        return NO;
    }
    [writer addInput:input];
    AVAssetWriterInput *systemAudio = nil, *mic = nil;
    if (self.recordsSystemAudio) {
        systemAudio = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio outputSettings:@{
            AVFormatIDKey: @(kAudioFormatMPEG4AAC), AVSampleRateKey: @48000, AVNumberOfChannelsKey: @2, AVEncoderBitRateKey: @160000,
        }];
        systemAudio.expectsMediaDataInRealTime = YES;
        if ([writer canAddInput:systemAudio]) [writer addInput:systemAudio]; else systemAudio = nil;
    }
    if (self.recordsMicrophone) {
        mic = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio outputSettings:@{
            AVFormatIDKey: @(kAudioFormatMPEG4AAC), AVSampleRateKey: @48000, AVNumberOfChannelsKey: @1, AVEncoderBitRateKey: @96000,
        }];
        mic.expectsMediaDataInRealTime = YES;
        if ([writer canAddInput:mic]) [writer addInput:mic]; else mic = nil;
    }
    if (![writer startWriting]) {
        if (error) *error = writer.error ?: ARRecordError(@"无法开始写入录屏文件");
        return NO;
    }
    NSDictionary *captureAttributes = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferWidthKey: @(size.width),
        (id)kCVPixelBufferHeightKey: @(size.height),
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
    };
    if (self.copyPool) CVPixelBufferPoolRelease(self.copyPool);
    CVPixelBufferPoolRef pool = NULL;
    CVPixelBufferPoolCreate(kCFAllocatorDefault, NULL, (__bridge CFDictionaryRef)captureAttributes, &pool);
    if (!pool) {
        [writer cancelWriting];
        if (error) *error = ARRecordError(@"无法分配画面缓冲区");
        return NO;
    }
    self.copyPool = pool;
    self.writer = writer;
    self.input = input;
    self.systemAudioInput = systemAudio;
    self.micInput = mic;
    self.adaptor = adaptor;
    self.outputSize = output;

    // 缓存帧数：覆盖“等待之后的识别 + 识别间隔 + 识别耗时”，同时不超过内存上限。
    double frameBytes = size.width * size.height * 4;
    NSUInteger wanted = (NSUInteger)ceil(fps * (ARReadyDelay + 1.0 / MAX(self.recognitionsPerSecond, 0.5) + 0.5)) + 4;
    NSUInteger affordable = (NSUInteger)MAX(8.0, floor(ARBufferBudget / MAX(frameBytes, 1)));
    NSUInteger maxPending = MIN(wanted, affordable);
    ARMotionSession *motion = ARMotionCreate((int)size.width, (int)size.height, ARMotionFactorForWidth((int)size.width),
                                             MAX(6, size.height / 150), 0.6);
    dispatch_sync(self.capture.frameQueue, ^{
        if (self.motion) ARMotionDestroy(self.motion);
        self.motion = motion;
        self.generation++;
        self.maxPending = maxPending;
        [self.pending removeAllObjects];
        [self.systemAudio removeAllObjects];
        [self.micAudio removeAllObjects];
        [self.openSegments removeAllObjects];
        [self.closedSegments removeAllObjects];
        self.fixedPixelRects = @[];
        self.recognizing = NO;
        self.lastRecognitionTime = -INFINITY;
        self.lastFullTime = -INFINITY;
        self.lastRecognizedFrame = -1;
        self.sessionStarted = NO;
        self.firstFrameTime = NAN;
        self.droppedFrames = 0;
    });
    return YES;
}

- (void)resetWriter {
    self.writer = nil;
    self.input = nil;
    self.systemAudioInput = nil;
    self.micInput = nil;
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
    if (isnan(self.firstFrameTime)) self.firstFrameTime = time;
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
    if (!self.recognizing && time - self.lastRecognitionTime >= interval) {
        ARBox region;
        ARRecognizePlan plan = ARMotionPlanRecognition(self.motion, self.lastRecognizedFrame, frame->motionId,
                                                       time - self.lastFullTime, ARFullInterval, 32, &region);
        if (plan == ARRecognizeFull) {
            [self recognizeFrame:frame region:NSZeroRect];
        } else if (plan == ARRecognizeRegion) {
            [self recognizeFrame:frame region:NSMakeRect(region.x, region.y, region.w, region.h)];
        } else {
            // 画面和上次识别时一样，不必识别；以这一帧作为之后比较的基准。
            self.lastRecognizedFrame = frame->motionId;
            self.lastRecognitionTime = time;
        }
    }
    [self drainReady];
}

- (void)recognizeFrame:(ARPendingFrame *)frame region:(NSRect)region {
    self.recognizing = YES;
    self.lastRecognitionTime = frame->time;
    if (NSIsEmptyRect(region)) self.lastFullTime = frame->time;
    self.lastRecognizedFrame = frame->motionId;
    CVPixelBufferRef pixels = CVPixelBufferRetain(frame->pixels);
    long motionId = frame->motionId;
    double time = frame->time;
    NSUInteger generation = self.generation;
    dispatch_async(self.recognizeQueue, ^{
        NSArray<ARDetection *> *detections = [self.recognizer detectionsInPixelBuffer:pixels region:region];
        CVPixelBufferRelease(pixels);
        dispatch_async(self.capture.frameQueue, ^{
            if (generation != self.generation) return;
            [self addDetections:detections frame:motionId time:time];
            self.recognizing = NO;
            if (NSIsEmptyRect(region)) dispatch_async(dispatch_get_main_queue(), ^{ self.currentCount = detections.count; });
            [self drainReady];
        });
    });
}

- (void)addDetections:(NSArray<ARDetection *> *)detections frame:(long)motionId time:(double)time {
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
    [self logKinds:[detections valueForKey:@"kind"] atTime:time];
}

/// 记录每种类型出现的时间段，供录完后复查。
- (void)logKinds:(NSArray<NSString *> *)kinds atTime:(double)time {
    if (isnan(self.firstFrameTime)) return;
    double t = MAX(0, time - self.firstFrameTime);
    for (NSString *kind in [NSSet setWithArray:kinds]) {
        NSMutableDictionary *open = self.openSegments[kind];
        if (open && t - [open[@"end"] doubleValue] <= ARSegmentGap) {
            open[@"end"] = @(t);
        } else {
            if (open) [self.closedSegments addObject:[open copy]];
            self.openSegments[kind] = [@{@"kind": kind, @"start": @(t), @"end": @(t)} mutableCopy];
        }
    }
}

- (void)finishSegments {
    for (NSMutableDictionary *open in self.openSegments.allValues) [self.closedSegments addObject:[open copy]];
    [self.openSegments removeAllObjects];
    NSArray *sorted = [self.closedSegments sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"start"] compare:b[@"start"]];
    }];
    dispatch_async(dispatch_get_main_queue(), ^{ self.segments = sorted; });
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
        self.sessionStart = frame->pts;
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
    NSMutableArray<NSValue *> *rects = [NSMutableArray arrayWithArray:self.fixedPixelRects];
    for (int i = 0; i < n; i++) [rects addObject:[NSValue valueWithRect:NSMakeRect(boxes[i].x, boxes[i].y, boxes[i].w, boxes[i].h)]];
    CIImage *image = ARRedactImage([CIImage imageWithCVPixelBuffer:frame->pixels], rects, self.style);
    CGSize source = image.extent.size;
    if (source.width != self.outputSize.width || source.height != self.outputSize.height) {
        CIFilter *scale = [CIFilter filterWithName:@"CILanczosScaleTransform"];
        [scale setValue:image forKey:kCIInputImageKey];
        [scale setValue:@(self.outputSize.width / source.width) forKey:kCIInputScaleKey];
        [scale setValue:@((self.outputSize.height / source.height) / (self.outputSize.width / source.width)) forKey:kCIInputAspectRatioKey];
        image = scale.outputImage;
    }
    [self.ciContext render:image toCVPixelBuffer:output];
    [adaptor appendPixelBuffer:output withPresentationTime:frame->pts];
    CVPixelBufferRelease(output);
    [self flushAudioUpTo:frame->pts];
}

#pragma mark - 声音

- (void)enqueueAudio:(CMSampleBufferRef)sample microphone:(BOOL)microphone {
    CFRetain(sample);
    dispatch_async(self.capture.frameQueue, ^{
        NSMutableArray *queue = microphone ? self.micAudio : self.systemAudio;
        [queue addObject:(__bridge id)sample];
        CFRelease(sample);
        // 视频迟迟没写入时（例如还没开始）只保留最近 5 秒的声音。
        while (queue.count > 600) [queue removeObjectAtIndex:0];
    });
}

/// 声音跟随视频写入：只写到已写入视频的时间，保持两者交错，避免写入器因某条轨道超前而丢数据。
- (void)flushAudioUpTo:(CMTime)limit {
    if (!self.sessionStarted) return;
    for (int track = 0; track < 2; track++) {
        NSMutableArray *queue = track == 0 ? self.systemAudio : self.micAudio;
        AVAssetWriterInput *input = track == 0 ? self.systemAudioInput : self.micInput;
        while (queue.count) {
            CMSampleBufferRef sample = (__bridge CMSampleBufferRef)queue.firstObject;
            CMTime pts = CMSampleBufferGetPresentationTimeStamp(sample);
            if (CMTIME_IS_NUMERIC(limit) && CMTimeCompare(pts, limit) > 0) break;
            if (input && CMTimeCompare(pts, self.sessionStart) >= 0) {
                if (!input.readyForMoreMediaData) break;
                [input appendSampleBuffer:sample];
            }
            [queue removeObjectAtIndex:0];
        }
    }
}

#pragma mark - 结束

- (void)stopWithCompletion:(void (^)(NSURL *, NSError *))completion {
    if (!self.running) {
        completion(nil, ARRecordError(@"没有正在进行的录制"));
        return;
    }
    self.running = NO;
    [self.privacyTimer invalidate];
    self.privacyTimer = nil;
    [self.microphone stop];
    NSURL *url = self.outputURL;
    [self.capture stopWithCompletion:^{
        // 帧队列：等正在进行的识别完成，再对最后一帧识别一次，让结尾的帧也有之后的结果，然后全部写完。
        dispatch_sync(self.recognizeQueue, ^{});
        ARPendingFrame *last = self.pending.lastObject;
        if (last) [self addDetections:[self.recognizer detectionsInPixelBuffer:last->pixels] frame:last->motionId time:last->time];
        [self drainCount:self.pending.count];
        // 写完剩下的声音（写入器可能需要片刻才能接收更多数据）。
        for (int attempt = 0; attempt < 100 && (self.systemAudio.count || self.micAudio.count); attempt++) {
            [self flushAudioUpTo:kCMTimeInvalid];
            if (self.systemAudio.count || self.micAudio.count) usleep(10000);
        }
        [self finishSegments];
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
        [self.systemAudio removeAllObjects];
        [self.micAudio removeAllObjects];
        if (!writer || !started) {
            [writer cancelWriting];
            [NSFileManager.defaultManager removeItemAtURL:url error:NULL];
            finish(nil, ARRecordError(@"没有录到画面：请确认已在“屏幕与系统录音”中允许“自动打码”"));
            return;
        }
        [self.input markAsFinished];
        [self.systemAudioInput markAsFinished];
        [self.micInput markAsFinished];
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
