#import <CoreMedia/CoreMedia.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 麦克风录音（AVCaptureSession），输出 48 kHz 单声道 PCM。
@interface ARMicrophone : NSObject
/// 可用的麦克风：@{@"id": 设备 ID, @"name": 名称}。
+ (NSArray<NSDictionary<NSString *, NSString *> *> *)availableDevices;
/// 请求麦克风权限，completion 在主线程调用。
+ (void)requestAccess:(void (^)(BOOL granted))completion;
/// deviceID 为 nil 时使用系统默认麦克风。handler 在内部队列上调用。
- (BOOL)startWithDeviceID:(nullable NSString *)deviceID handler:(void (^)(CMSampleBufferRef sample))handler error:(NSError *_Nullable *_Nullable)error;
- (void)stop;
@end

NS_ASSUME_NONNULL_END
