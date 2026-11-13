#import <Foundation/Foundation.h>
#import "ARRedact.h"

NS_ASSUME_NONNULL_BEGIN

/// 录屏并打码。按原始分辨率识别与追踪，录像按所选画质缩放；可同时录制系统声音和麦克风。
/// 画面延迟写入：每一帧都等之后的识别完成并往回追踪后再打码写入，录像里的每一帧都已打码。
@interface ARRecordSession : NSObject
@property (nonatomic) ARRedactStyle style;
@property (nonatomic) BOOL recognizesChinese;
@property (nonatomic) BOOL detectsCodes;
@property (nonatomic) BOOL detectsFaces;
/// 每秒识别次数上限（画面不变时会跳过，只变化一小块时只识别那一块）。
@property (nonatomic) double recognitionsPerSecond;
@property (nonatomic) BOOL recordsSystemAudio;
@property (nonatomic) BOOL recordsMicrophone;
@property (nonatomic, copy, nullable) NSString *microphoneID;
/// 始终打码的区域（屏幕内坐标，单位点，左上角原点）。
@property (nonatomic, copy) NSArray<NSValue *> *fixedRegions;
/// 不出现在录像里的 App（隐私窗口、系统通知）。
@property (nonatomic, copy) NSArray<NSString *> *excludedBundleIDs;
/// 当前画面里打码的处数（主线程读取）。
@property (nonatomic, readonly) NSUInteger currentCount;
@property (nonatomic, readonly, getter=isRunning) BOOL running;
@property (nonatomic, readonly, nullable) NSDate *startedAt;
/// 录制结束后可用：每段打码出现的时间（秒，相对录像开头）与类型，@{@"start", @"end", @"kind"}，按开始时间排序。
@property (nonatomic, readonly, copy) NSArray<NSDictionary *> *segments;
/// 系统中断录制时调用（主线程），文件已尽量保存。
@property (nonatomic, copy, nullable) void (^interruptedHandler)(NSURL *_Nullable url, NSError *_Nullable error);

/// sourceRect 为屏幕内的录制区域（单位点，左上角原点），CGRectNull 表示整块屏幕；maxWidth 为录像宽度上限（0 为原始）。
- (void)startDisplay:(CGDirectDisplayID)displayID
          sourceRect:(CGRect)sourceRect
            maxWidth:(NSInteger)maxWidth
                 fps:(NSInteger)fps
         showsCursor:(BOOL)showsCursor
           outputURL:(NSURL *)url
          completion:(void (^)(NSError *_Nullable error))completion;
- (void)stopWithCompletion:(void (^)(NSURL *_Nullable url, NSError *_Nullable error))completion;
@end

/// 把屏幕内的区域（单位点）换算为捕获画面中的像素区域。
NSRect ARCapturePixelRect(CGRect pointsRect, CGRect sourceRect, CGSize pixelSize);

NS_ASSUME_NONNULL_END
