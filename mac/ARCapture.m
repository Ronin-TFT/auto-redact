#import "ARCapture.h"
#import <AppKit/AppKit.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <unistd.h>

static NSError *ARCaptureError(NSString *message) {
    return [NSError errorWithDomain:@"AutoRedact.Capture" code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
}

CGSize ARCaptureSize(CGSize points, CGFloat scale, NSInteger maxWidth) {
    double w = points.width * MAX(scale, 1), h = points.height * MAX(scale, 1);
    double limit = maxWidth > 0 ? MIN((double)maxWidth, 4096.0) : 4096.0;
    // H.264 编码上限约 4096×2304。
    double factor = MIN(1.0, MIN(limit / MAX(w, 1), 2304.0 / MAX(h, 1)));
    long pw = (long)floor(w * factor), ph = (long)floor(h * factor);
    pw -= pw % 2;
    ph -= ph % 2;
    return CGSizeMake(MAX(pw, 2), MAX(ph, 2));
}

@interface ARCapture () <SCStreamOutput, SCStreamDelegate>
@property (nonatomic, readwrite) CGSize pixelSize;
@property (nonatomic, readwrite) dispatch_queue_t frameQueue;
@property (nonatomic, strong, nullable) SCStream *stream;
@property (nonatomic, copy, nullable) void (^frameHandler)(CMSampleBufferRef, CVPixelBufferRef, double);
@end

@implementation ARCapture

- (instancetype)init {
    if ((self = [super init])) {
        _frameQueue = dispatch_queue_create("AutoRedact.Frames", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (void)startDisplay:(CGDirectDisplayID)displayID maxWidth:(NSInteger)maxWidth fps:(NSInteger)fps showsCursor:(BOOL)showsCursor
             prepare:(BOOL (^)(CGSize, NSError **))prepare
        frameHandler:(void (^)(CMSampleBufferRef, CVPixelBufferRef, double))frameHandler
          completion:(void (^)(NSError *))completion {
    if (self.stream) {
        completion(ARCaptureError(@"已经在运行"));
        return;
    }
    [SCShareableContent getShareableContentExcludingDesktopWindows:NO onScreenWindowsOnly:YES
                                                 completionHandler:^(SCShareableContent *content, NSError *contentError) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (contentError || !content) {
                completion(contentError ?: ARCaptureError(@"无法获取屏幕内容"));
                return;
            }
            SCDisplay *display = nil;
            for (SCDisplay *candidate in content.displays) {
                if (candidate.displayID == displayID) display = candidate;
            }
            if (!display) {
                completion(ARCaptureError(@"找不到这块屏幕，请重新选择"));
                return;
            }
            CGFloat scale = 1;
            for (NSScreen *screen in NSScreen.screens) {
                if ([screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue] == displayID) scale = screen.backingScaleFactor;
            }
            NSMutableArray<SCRunningApplication *> *excluded = [NSMutableArray array];
            for (SCRunningApplication *app in content.applications) {
                if (app.processID == getpid()) [excluded addObject:app];
            }
            SCContentFilter *filter = [[SCContentFilter alloc] initWithDisplay:display excludingApplications:excluded exceptingWindows:@[]];
            CGSize size = ARCaptureSize(CGSizeMake(display.width, display.height), scale, maxWidth);
            NSError *prepareError = nil;
            if (!prepare(size, &prepareError)) {
                completion(prepareError ?: ARCaptureError(@"无法准备录制"));
                return;
            }
            SCStreamConfiguration *config = [SCStreamConfiguration new];
            config.width = (size_t)size.width;
            config.height = (size_t)size.height;
            config.minimumFrameInterval = CMTimeMake(1, (int32_t)MAX(fps, 1));
            config.showsCursor = showsCursor;
            config.pixelFormat = kCVPixelFormatType_32BGRA;
            config.queueDepth = 8;

            SCStream *stream = [[SCStream alloc] initWithFilter:filter configuration:config delegate:self];
            NSError *outputError = nil;
            if (![stream addStreamOutput:self type:SCStreamOutputTypeScreen sampleHandlerQueue:self.frameQueue error:&outputError]) {
                completion(outputError ?: ARCaptureError(@"无法接收屏幕画面"));
                return;
            }
            self.pixelSize = size;
            self.frameHandler = frameHandler;
            self.stream = stream;
            [stream startCaptureWithCompletionHandler:^(NSError *startError) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (startError) {
                        self.stream = nil;
                        self.frameHandler = nil;
                    }
                    completion(startError);
                });
            }];
        });
    }];
}

- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer ofType:(SCStreamOutputType)type {
    if (type != SCStreamOutputTypeScreen || !CMSampleBufferIsValid(sampleBuffer)) return;
    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, false);
    if (!attachments || CFArrayGetCount(attachments) == 0) return;
    NSDictionary *info = (__bridge NSDictionary *)CFArrayGetValueAtIndex(attachments, 0);
    NSNumber *status = info[SCStreamFrameInfoStatus];
    if (!status || status.integerValue != SCFrameStatusComplete) return;
    CVPixelBufferRef pixels = CMSampleBufferGetImageBuffer(sampleBuffer);
    void (^handler)(CMSampleBufferRef, CVPixelBufferRef, double) = self.frameHandler;
    if (!pixels || !handler) return;
    handler(sampleBuffer, pixels, CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer)));
}

- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (stream != self.stream) return;
        self.stream = nil;
        dispatch_async(self.frameQueue, ^{ self.frameHandler = nil; });
        if (self.stoppedHandler) self.stoppedHandler(error);
    });
}

- (void)stopWithCompletion:(void (^)(void))completion {
    SCStream *stream = self.stream;
    self.stream = nil;
    void (^finish)(void) = ^{
        dispatch_async(self.frameQueue, ^{
            self.frameHandler = nil;
            completion();
        });
    };
    if (!stream) {
        finish();
        return;
    }
    [stream stopCaptureWithCompletionHandler:^(NSError *error) { finish(); }];
}

@end
