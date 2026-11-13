#import <CoreMedia/CoreMedia.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 截屏参数。
@interface ARCaptureOptions : NSObject
@property (nonatomic) CGDirectDisplayID displayID;
/// 输出宽度上限（像素，保持比例），0 表示原始分辨率（上限 4096）。
@property (nonatomic) NSInteger maxWidth;
@property (nonatomic) NSInteger fps;
@property (nonatomic) BOOL showsCursor;
/// 只捕获屏幕中的一块区域（屏幕内坐标，单位点，左上角原点）；CGRectNull 表示整块屏幕。
@property (nonatomic) CGRect sourceRect;
/// 同时捕获系统声音（不含本 App 的声音）。
@property (nonatomic) BOOL capturesSystemAudio;
/// 不出现在画面里的 App（Bundle ID）。本 App 的窗口总是不出现。
@property (nonatomic, copy) NSArray<NSString *> *excludedBundleIDs;
@end

/// 一块屏幕（或其中一块区域）的画面流（ScreenCaptureKit）。
@interface ARCapture : NSObject
/// 画面像素大小（开始后有效）。
@property (nonatomic, readonly) CGSize pixelSize;
/// 实际捕获的区域（屏幕内坐标，单位点，左上角原点）。
@property (nonatomic, readonly) CGRect sourceRect;
/// 系统中断录制时调用（主线程）。
@property (nonatomic, copy, nullable) void (^stoppedHandler)(NSError *error);
/// 帧回调所在的队列，可用于和帧处理同步。
@property (nonatomic, readonly) dispatch_queue_t frameQueue;

/// prepare 在开始前于主线程调用，传入像素大小，返回 NO 则取消；
/// frameHandler 在帧队列上调用，time 为画面时间（秒）；audioHandler 在音频队列上调用；completion 在主线程调用。
- (void)startWithOptions:(ARCaptureOptions *)options
                 prepare:(BOOL (^)(CGSize pixelSize, NSError *_Nullable *_Nullable error))prepare
            frameHandler:(void (^)(CMSampleBufferRef sample, CVPixelBufferRef pixels, double time))frameHandler
            audioHandler:(nullable void (^)(CMSampleBufferRef sample))audioHandler
              completion:(void (^)(NSError *_Nullable error))completion;

/// 更新不出现在画面里的 App（例如录制中新打开了隐私 App）。
- (void)updateExcludedBundleIDs:(NSArray<NSString *> *)bundleIDs;

/// 停止捕获；completion 在帧队列上调用，此后不会再有新的帧。
- (void)stopWithCompletion:(void (^)(void))completion;
@end

/// 把屏幕像素尺寸限制在 maxWidth 以内（0 表示 4096），保持比例并取偶数，高度不超过 2304。
CGSize ARCaptureSize(CGSize points, CGFloat scale, NSInteger maxWidth);

/// Cocoa 全局坐标（左下角原点）中的区域，换算为该屏幕内的坐标（左上角原点，单位点）；不相交时返回 CGRectNull。
CGRect ARDisplayLocalRect(CGRect globalRect, CGRect screenFrame);

NS_ASSUME_NONNULL_END
