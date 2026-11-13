#import "ARRecordSession.h"
#import <AVFoundation/AVFoundation.h>
#import "ARCapture.h"
#import "AREngine.h"
#import "ARRecognizer.h"

static NSError *ARRecordError(NSString *message) {
    return [NSError errorWithDomain:@"AutoRedact.Record" code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
}

/// 等待写入的一帧（像素已复制，不占用截屏队列的缓冲区）。
@interface ARPendingFrame : NSObject {
@public
    CVPixelBufferRef pixels;
    CMTime pts;
    double time;
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
@property (nonatomic, strong) NSMutableArray<ARPendingFrame *> *pending; // 帧队列上访问
@property (nonatomic) BOOL recognizing;                                  // 帧队列上访问
@property (nonatomic) double lastRecognitionTime;                        // 帧队列上访问
@property (nonatomic) double newestFrameTime;                            // 帧队列上访问
@property (nonatomic) BOOL sessionStarted;                               // 帧队列上访问
@property (nonatomic) NSUInteger droppedFrames;                          // 帧队列上访问
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
    [AREngine resetTrackerWidth:size.width height:size.height padding:MAX(6, size.height / 150) hold:0.5];
    dispatch_sync(self.capture.frameQueue, ^{
        [self.pending removeAllObjects];
        self.recognizing = NO;
        self.lastRecognitionTime = -INFINITY;
        self.newestFrameTime = -INFINITY;
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

static CVPixelBufferRef ARCopyPixels(CVPixelBufferRef source, CVPixelBufferPoolRef pool) {
    CVPixelBufferRef copy = NULL;
    NSDictionary *aux = @{(id)kCVPixelBufferPoolAllocationThresholdKey: @24};
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
    if (!self.copyPool) return;
    CVPixelBufferRef copy = ARCopyPixels(pixels, self.copyPool);
    if (!copy) {
        // 缓冲区用完（识别太慢），丢弃这一帧，宁可少一帧也不写未打码的画面。
        self.droppedFrames++;
        return;
    }
    ARPendingFrame *frame = [ARPendingFrame new];
    frame->pixels = copy;
    frame->pts = pts;
    frame->time = time;
    [self.pending addObject:frame];
    self.newestFrameTime = time;

    double interval = 1.0 / MAX(self.recognitionsPerSecond, 0.5);
    if (!self.recognizing && time - self.lastRecognitionTime >= interval) {
        [self recognizeFrame:frame];
    }
    [self drainForce:NO];
}

- (void)recognizeFrame:(ARPendingFrame *)frame {
    self.recognizing = YES;
    self.lastRecognitionTime = frame->time;
    CVPixelBufferRef pixels = CVPixelBufferRetain(frame->pixels);
    double time = frame->time;
    dispatch_async(self.recognizeQueue, ^{
        NSArray<ARDetection *> *detections = [self.recognizer detectionsInPixelBuffer:pixels];
        CVPixelBufferRelease(pixels);
        dispatch_async(self.capture.frameQueue, ^{
            [AREngine addDetections:detections atTime:time];
            self.recognizing = NO;
            dispatch_async(dispatch_get_main_queue(), ^{ self.currentCount = detections.count; });
            [self drainForce:NO];
        });
    });
}

/// 写入已经可以确定打码区域的帧。force 为 YES 时写入全部（结束时使用）。
- (void)drainForce:(BOOL)force {
    double latest = [AREngine latestTime];
    while (self.pending.count) {
        ARPendingFrame *frame = self.pending.firstObject;
        // 之后已有识别结果才写入；识别严重滞后（超过 2 秒）时也写入，使用最近的结果并保持遮挡。
        if (!force && latest < frame->time && self.newestFrameTime - frame->time < 2.0) break;
        [self.pending removeObjectAtIndex:0];
        [self writeFrame:frame];
    }
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
    NSArray<NSValue *> *boxes = [AREngine boxesAtTime:frame->time];
    CIImage *image = ARRedactImage([CIImage imageWithCVPixelBuffer:frame->pixels], boxes, self.style);
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
        // 帧队列：对最后一帧再识别一次，保证结尾的帧也有“之后”的结果，然后全部写完。
        ARPendingFrame *last = self.pending.lastObject;
        if (last) {
            [AREngine addDetections:[self.recognizer detectionsInPixelBuffer:last->pixels] atTime:last->time];
        }
        [self drainForce:YES];
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
