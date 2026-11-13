#import <Foundation/Foundation.h>
#import "ARRedact.h"

NS_ASSUME_NONNULL_BEGIN

/// 录屏并打码。画面延迟约半秒写入：每一帧都等它之后的一次识别完成，
/// 用前后两次识别结果的并集打码，因此录像里的每一帧都已打码。
@interface ARRecordSession : NSObject
@property (nonatomic) ARRedactStyle style;
@property (nonatomic) BOOL recognizesChinese;
/// 每秒识别次数。
@property (nonatomic) double recognitionsPerSecond;
/// 当前画面里打码的处数（主线程读取）。
@property (nonatomic, readonly) NSUInteger currentCount;
@property (nonatomic, readonly, getter=isRunning) BOOL running;
@property (nonatomic, readonly, nullable) NSDate *startedAt;
/// 系统中断录制时调用（主线程），文件已尽量保存。
@property (nonatomic, copy, nullable) void (^interruptedHandler)(NSURL *_Nullable url, NSError *_Nullable error);

- (void)startDisplay:(CGDirectDisplayID)displayID
            maxWidth:(NSInteger)maxWidth
                 fps:(NSInteger)fps
         showsCursor:(BOOL)showsCursor
           outputURL:(NSURL *)url
          completion:(void (^)(NSError *_Nullable error))completion;
- (void)stopWithCompletion:(void (^)(NSURL *_Nullable url, NSError *_Nullable error))completion;
@end

NS_ASSUME_NONNULL_END
