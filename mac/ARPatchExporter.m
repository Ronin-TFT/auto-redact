#import "ARPatchExporter.h"
#import <AVFoundation/AVFoundation.h>

static NSError *ARExportError(NSString *message) {
    return [NSError errorWithDomain:@"AutoRedact.Export" code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
}

@implementation ARManualMask
- (instancetype)initWithRect:(NSRect)rect start:(double)start end:(double)end {
    if ((self = [super init])) {
        _rect = rect;
        _start = MIN(start, end);
        _end = MAX(start, end);
    }
    return self;
}
@end

NSArray<NSValue *> *ARMasksAtTime(NSArray<ARManualMask *> *masks, double time) {
    NSMutableArray *out = [NSMutableArray array];
    for (ARManualMask *mask in masks) {
        if (time >= mask.start - 1e-3 && time <= mask.end + 1e-3) [out addObject:[NSValue valueWithRect:mask.rect]];
    }
    return out;
}

@implementation ARPatchExporter

+ (void)exportURL:(NSURL *)source to:(NSURL *)destination masks:(NSArray<ARManualMask *> *)masks style:(ARRedactStyle)style
         progress:(void (^)(double))progress completion:(void (^)(NSError *))completion {
    dispatch_queue_t queue = dispatch_queue_create("AutoRedact.Export", DISPATCH_QUEUE_SERIAL);
    dispatch_async(queue, ^{
        void (^fail)(NSError *) = ^(NSError *error) { dispatch_async(dispatch_get_main_queue(), ^{ completion(error); }); };
        AVURLAsset *asset = [AVURLAsset URLAssetWithURL:source options:nil];
        NSError *error = nil;
        AVAssetReader *reader = [AVAssetReader assetReaderWithAsset:asset error:&error];
        if (!reader) { fail(error); return; }
        AVAssetTrack *videoTrack = [asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
        if (!videoTrack) { fail(ARExportError(@"录像里没有画面")); return; }
        CGSize size = videoTrack.naturalSize;
        double duration = MAX(CMTimeGetSeconds(asset.duration), 0.001);

        AVAssetReaderTrackOutput *videoOutput = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:videoTrack outputSettings:@{
            (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
            (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
        }];
        [reader addOutput:videoOutput];

        [NSFileManager.defaultManager removeItemAtURL:destination error:NULL];
        AVAssetWriter *writer = [AVAssetWriter assetWriterWithURL:destination fileType:AVFileTypeMPEG4 error:&error];
        if (!writer) { fail(error); return; }
        float bitRate = videoTrack.estimatedDataRate > 0 ? videoTrack.estimatedDataRate : (float)(size.width * size.height * 3);
        AVAssetWriterInput *videoInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:@{
            AVVideoCodecKey: AVVideoCodecTypeH264,
            AVVideoWidthKey: @(size.width),
            AVVideoHeightKey: @(size.height),
            AVVideoCompressionPropertiesKey: @{AVVideoAverageBitRateKey: @(MAX(bitRate, 2e6))},
        }];
        AVAssetWriterInputPixelBufferAdaptor *adaptor = [AVAssetWriterInputPixelBufferAdaptor
            assetWriterInputPixelBufferAdaptorWithAssetWriterInput:videoInput
                                       sourcePixelBufferAttributes:@{
                                           (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
                                           (id)kCVPixelBufferWidthKey: @(size.width),
                                           (id)kCVPixelBufferHeightKey: @(size.height),
                                           (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
                                       }];
        [writer addInput:videoInput];

        // 声音原样复制（不重新编码）。
        NSMutableArray<AVAssetReaderTrackOutput *> *audioOutputs = [NSMutableArray array];
        NSMutableArray<AVAssetWriterInput *> *audioInputs = [NSMutableArray array];
        for (AVAssetTrack *track in [asset tracksWithMediaType:AVMediaTypeAudio]) {
            AVAssetReaderTrackOutput *output = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:track outputSettings:nil];
            CMFormatDescriptionRef hint = (__bridge CMFormatDescriptionRef)track.formatDescriptions.firstObject;
            AVAssetWriterInput *input = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio outputSettings:nil sourceFormatHint:hint];
            if (![reader canAddOutput:output] || ![writer canAddInput:input]) continue;
            [reader addOutput:output];
            [writer addInput:input];
            [audioOutputs addObject:output];
            [audioInputs addObject:input];
        }
        if (![reader startReading]) { fail(reader.error ?: ARExportError(@"无法读取录像")); return; }
        if (![writer startWriting]) { fail(writer.error ?: ARExportError(@"无法写入新录像")); return; }
        [writer startSessionAtSourceTime:kCMTimeZero];

        CIContext *context = [CIContext contextWithOptions:nil];
        dispatch_group_t group = dispatch_group_create();
        dispatch_group_enter(group);
        [videoInput requestMediaDataWhenReadyOnQueue:queue usingBlock:^{
            while (videoInput.readyForMoreMediaData) {
                CMSampleBufferRef sample = [videoOutput copyNextSampleBuffer];
                if (!sample) {
                    [videoInput markAsFinished];
                    dispatch_group_leave(group);
                    return;
                }
                CMTime pts = CMSampleBufferGetPresentationTimeStamp(sample);
                CVPixelBufferRef pixels = CMSampleBufferGetImageBuffer(sample);
                CVPixelBufferRef output = NULL;
                if (pixels && adaptor.pixelBufferPool &&
                    CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, adaptor.pixelBufferPool, &output) == kCVReturnSuccess) {
                    double t = CMTimeGetSeconds(pts);
                    CIImage *image = ARRedactImage([CIImage imageWithCVPixelBuffer:pixels], ARMasksAtTime(masks, t), style);
                    [context render:image toCVPixelBuffer:output];
                    [adaptor appendPixelBuffer:output withPresentationTime:pts];
                    CVPixelBufferRelease(output);
                    dispatch_async(dispatch_get_main_queue(), ^{ progress(MIN(1, t / duration)); });
                }
                CFRelease(sample);
            }
        }];
        for (NSUInteger i = 0; i < audioInputs.count; i++) {
            AVAssetWriterInput *input = audioInputs[i];
            AVAssetReaderTrackOutput *output = audioOutputs[i];
            dispatch_group_enter(group);
            [input requestMediaDataWhenReadyOnQueue:queue usingBlock:^{
                while (input.readyForMoreMediaData) {
                    CMSampleBufferRef sample = [output copyNextSampleBuffer];
                    if (!sample) {
                        [input markAsFinished];
                        dispatch_group_leave(group);
                        return;
                    }
                    [input appendSampleBuffer:sample];
                    CFRelease(sample);
                }
            }];
        }
        dispatch_group_notify(group, queue, ^{
            if (reader.status == AVAssetReaderStatusFailed) {
                [writer cancelWriting];
                { fail(reader.error ?: ARExportError(@"读取录像失败")); return; }
            }
            [writer finishWritingWithCompletionHandler:^{
                NSError *result = writer.status == AVAssetWriterStatusCompleted ? nil : (writer.error ?: ARExportError(@"导出失败"));
                dispatch_async(dispatch_get_main_queue(), ^{ completion(result); });
            }];
        });
    });
}

@end
