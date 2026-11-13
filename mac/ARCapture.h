#import <CoreMedia/CoreMedia.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 一块屏幕的画面流（ScreenCaptureKit）。本 App 自己的窗口（遮挡块等）不会出现在画面里。
@interface ARCapture : NSObject
/// 画面像素大小（开始后有效）。
@property (nonatomic, readonly) CGSize pixelSize;
/// 系统中断录制时调用（主线程）。
@property (nonatomic, copy, nullable) void (^stoppedHandler)(NSError *error);

/// 开始捕获。maxWidth 限制输出宽度（保持比例，0 表示原始分辨率）；
/// prepare 在开始前于主线程调用，传入像素大小，返回 NO 则取消；
/// frameHandler 在内部串行队列上调用，time 为画面时间（秒）；completion 在主线程调用。
- (void)startDisplay:(CGDirectDisplayID)displayID
            maxWidth:(NSInteger)maxWidth
                 fps:(NSInteger)fps
         showsCursor:(BOOL)showsCursor
             prepare:(BOOL (^)(CGSize pixelSize, NSError *_Nullable *_Nullable error))prepare
        frameHandler:(void (^)(CMSampleBufferRef sample, CVPixelBufferRef pixels, double time))frameHandler
          completion:(void (^)(NSError *_Nullable error))completion;

/// 停止捕获；completion 在帧队列上调用，此后不会再有新的帧。
- (void)stopWithCompletion:(void (^)(void))completion;

/// 帧回调所在的队列，可用于和帧处理同步。
@property (nonatomic, readonly) dispatch_queue_t frameQueue;
@end

/// 把屏幕像素尺寸限制在 maxWidth 以内，保持比例并取偶数。
CGSize ARCaptureSize(CGSize points, CGFloat scale, NSInteger maxWidth);

NS_ASSUME_NONNULL_END
