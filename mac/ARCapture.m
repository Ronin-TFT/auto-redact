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

CGRect ARDisplayLocalRect(CGRect globalRect, CGRect screenFrame) {
    CGRect r = CGRectIntersection(CGRectStandardize(globalRect), screenFrame);
    if (CGRectIsNull(r) || CGRectIsEmpty(r)) return CGRectNull;
    return CGRectMake(r.origin.x - screenFrame.origin.x, CGRectGetMaxY(screenFrame) - CGRectGetMaxY(r), r.size.width, r.size.height);
}

@implementation ARCaptureOptions
- (instancetype)init {
    if ((self = [super init])) {
        _fps = 30;
        _sourceRect = CGRectNull;
        _excludedBundleIDs = @[];
    }
    return self;
}
@end

@interface ARCapture () <SCStreamOutput, SCStreamDelegate>
@property (nonatomic, readwrite) CGSize pixelSize;
@property (nonatomic, readwrite) CGRect sourceRect;
@property (nonatomic, readwrite) dispatch_queue_t frameQueue;
@property (nonatomic, strong) dispatch_queue_t audioQueue;
@property (nonatomic, strong, nullable) SCStream *stream;
@property (nonatomic, strong, nullable) SCDisplay *display;
@property (nonatomic, copy, nullable) void (^frameHandler)(CMSampleBufferRef, CVPixelBufferRef, double);
@property (nonatomic, copy, nullable) void (^audioHandler)(CMSampleBufferRef);
@end

@implementation ARCapture

- (instancetype)init {
    if ((self = [super init])) {
        _frameQueue = dispatch_queue_create("AutoRedact.Frames", DISPATCH_QUEUE_SERIAL);
        _audioQueue = dispatch_queue_create("AutoRedact.Audio", DISPATCH_QUEUE_SERIAL);
        _sourceRect = CGRectNull;
    }
    return self;
}

/// 本 App 与指定 Bundle ID 的 App。
static NSArray<SCRunningApplication *> *ARExcludedApps(SCShareableContent *content, NSArray<NSString *> *bundleIDs) {
    NSMutableArray<SCRunningApplication *> *apps = [NSMutableArray array];
    for (SCRunningApplication *app in content.applications) {
        if (app.processID == getpid() || [bundleIDs containsObject:app.bundleIdentifier ?: @""]) [apps addObject:app];
    }
    return apps;
}

- (void)startWithOptions:(ARCaptureOptions *)options prepare:(BOOL (^)(CGSize, NSError **))prepare
            frameHandler:(void (^)(CMSampleBufferRef, CVPixelBufferRef, double))frameHandler
            audioHandler:(void (^)(CMSampleBufferRef))audioHandler
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
                if (candidate.displayID == options.displayID) display = candidate;
            }
            if (!display) {
                completion(ARCaptureError(@"找不到这块屏幕，请重新选择"));
                return;
            }
            CGFloat scale = 1;
            for (NSScreen *screen in NSScreen.screens) {
                if ([screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue] == options.displayID) scale = screen.backingScaleFactor;
            }
            CGRect full = CGRectMake(0, 0, display.width, display.height);
            CGRect source = CGRectIsNull(options.sourceRect) ? full : CGRectIntersection(CGRectIntegral(options.sourceRect), full);
            if (CGRectIsNull(source) || source.size.width < 16 || source.size.height < 16) {
                completion(ARCaptureError(@"录制区域太小或不在这块屏幕上，请重新选择"));
                return;
            }
            SCContentFilter *filter = [[SCContentFilter alloc] initWithDisplay:display
                                                         excludingApplications:ARExcludedApps(content, options.excludedBundleIDs)
                                                              exceptingWindows:@[]];
            CGSize size = ARCaptureSize(source.size, scale, options.maxWidth);
            NSError *prepareError = nil;
            if (!prepare(size, &prepareError)) {
                completion(prepareError ?: ARCaptureError(@"无法准备录制"));
                return;
            }
            SCStreamConfiguration *config = [SCStreamConfiguration new];
            if (!CGRectEqualToRect(source, full)) config.sourceRect = source;
            config.width = (size_t)size.width;
            config.height = (size_t)size.height;
            config.minimumFrameInterval = CMTimeMake(1, (int32_t)MAX(options.fps, 1));
            config.showsCursor = options.showsCursor;
            config.pixelFormat = kCVPixelFormatType_32BGRA;
            config.queueDepth = 8;
            if (audioHandler && options.capturesSystemAudio) {
                config.capturesAudio = YES;
                config.excludesCurrentProcessAudio = YES;
                config.sampleRate = 48000;
                config.channelCount = 2;
            }

            SCStream *stream = [[SCStream alloc] initWithFilter:filter configuration:config delegate:self];
            NSError *outputError = nil;
            if (![stream addStreamOutput:self type:SCStreamOutputTypeScreen sampleHandlerQueue:self.frameQueue error:&outputError]) {
                completion(outputError ?: ARCaptureError(@"无法接收屏幕画面"));
                return;
            }
            if (config.capturesAudio &&
                ![stream addStreamOutput:self type:SCStreamOutputTypeAudio sampleHandlerQueue:self.audioQueue error:&outputError]) {
                completion(outputError ?: ARCaptureError(@"无法接收系统声音"));
                return;
            }
            self.pixelSize = size;
            self.sourceRect = source;
            self.frameHandler = frameHandler;
            self.audioHandler = config.capturesAudio ? audioHandler : nil;
            self.display = display;
            self.stream = stream;
            [stream startCaptureWithCompletionHandler:^(NSError *startError) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (startError) {
                        self.stream = nil;
                        self.frameHandler = nil;
                        self.audioHandler = nil;
                    }
                    completion(startError);
                });
            }];
        });
    }];
}

- (void)updateExcludedBundleIDs:(NSArray<NSString *> *)bundleIDs {
    SCStream *stream = self.stream;
    SCDisplay *display = self.display;
    if (!stream || !display) return;
    [SCShareableContent getShareableContentExcludingDesktopWindows:NO onScreenWindowsOnly:YES
                                                 completionHandler:^(SCShareableContent *content, NSError *error) {
        if (!content) return;
        SCContentFilter *filter = [[SCContentFilter alloc] initWithDisplay:display
                                                     excludingApplications:ARExcludedApps(content, bundleIDs)
                                                          exceptingWindows:@[]];
        [stream updateContentFilter:filter completionHandler:^(NSError *updateError) {}];
    }];
}

- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer ofType:(SCStreamOutputType)type {
    if (!CMSampleBufferIsValid(sampleBuffer)) return;
    if (type == SCStreamOutputTypeAudio) {
        void (^audio)(CMSampleBufferRef) = self.audioHandler;
        if (audio) audio(sampleBuffer);
        return;
    }
    if (type != SCStreamOutputTypeScreen) return;
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
        self.audioHandler = nil;
        dispatch_async(self.frameQueue, ^{ self.frameHandler = nil; });
        if (self.stoppedHandler) self.stoppedHandler(error);
    });
}

- (void)stopWithCompletion:(void (^)(void))completion {
    SCStream *stream = self.stream;
    self.stream = nil;
    self.audioHandler = nil;
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
