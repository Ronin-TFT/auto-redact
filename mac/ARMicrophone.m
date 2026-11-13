#import "ARMicrophone.h"
#import <AVFoundation/AVFoundation.h>

@interface ARMicrophone () <AVCaptureAudioDataOutputSampleBufferDelegate>
@property (nonatomic, strong, nullable) AVCaptureSession *session;
@property (nonatomic, strong) dispatch_queue_t queue;
@property (nonatomic, copy, nullable) void (^handler)(CMSampleBufferRef);
@end

@implementation ARMicrophone

- (instancetype)init {
    if ((self = [super init])) _queue = dispatch_queue_create("AutoRedact.Microphone", DISPATCH_QUEUE_SERIAL);
    return self;
}

+ (NSArray<AVCaptureDevice *> *)devices {
    AVCaptureDeviceDiscoverySession *discovery =
        [AVCaptureDeviceDiscoverySession discoverySessionWithDeviceTypes:@[AVCaptureDeviceTypeBuiltInMicrophone, AVCaptureDeviceTypeExternalUnknown]
                                                               mediaType:AVMediaTypeAudio
                                                                position:AVCaptureDevicePositionUnspecified];
    return discovery.devices;
}

+ (NSArray<NSDictionary<NSString *, NSString *> *> *)availableDevices {
    NSMutableArray *out = [NSMutableArray array];
    for (AVCaptureDevice *device in [self devices]) [out addObject:@{@"id": device.uniqueID, @"name": device.localizedName}];
    return out;
}

+ (void)requestAccess:(void (^)(BOOL))completion {
    [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:^(BOOL granted) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(granted); });
    }];
}

- (BOOL)startWithDeviceID:(NSString *)deviceID handler:(void (^)(CMSampleBufferRef))handler error:(NSError **)error {
    AVCaptureDevice *device = deviceID.length ? [AVCaptureDevice deviceWithUniqueID:deviceID] : nil;
    if (!device) device = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeAudio];
    if (!device) {
        if (error) *error = [NSError errorWithDomain:@"AutoRedact.Microphone" code:1 userInfo:@{NSLocalizedDescriptionKey: @"找不到麦克风"}];
        return NO;
    }
    AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:device error:error];
    if (!input) return NO;
    AVCaptureSession *session = [AVCaptureSession new];
    AVCaptureAudioDataOutput *output = [AVCaptureAudioDataOutput new];
    // 统一为 48 kHz 单声道浮点 PCM，录像里的麦克风音轨按这个格式编码。
    output.audioSettings = @{
        AVFormatIDKey: @(kAudioFormatLinearPCM),
        AVSampleRateKey: @48000,
        AVNumberOfChannelsKey: @1,
        AVLinearPCMBitDepthKey: @32,
        AVLinearPCMIsFloatKey: @YES,
        AVLinearPCMIsNonInterleaved: @NO,
        AVLinearPCMIsBigEndianKey: @NO,
    };
    [output setSampleBufferDelegate:self queue:self.queue];
    if (![session canAddInput:input] || ![session canAddOutput:output]) {
        if (error) *error = [NSError errorWithDomain:@"AutoRedact.Microphone" code:2 userInfo:@{NSLocalizedDescriptionKey: @"无法使用这个麦克风"}];
        return NO;
    }
    [session addInput:input];
    [session addOutput:output];
    self.handler = handler;
    self.session = session;
    [session startRunning];
    return YES;
}

- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
    void (^handler)(CMSampleBufferRef) = self.handler;
    if (handler && CMSampleBufferIsValid(sampleBuffer)) handler(sampleBuffer);
}

- (void)stop {
    self.handler = nil;
    [self.session stopRunning];
    self.session = nil;
}

@end
