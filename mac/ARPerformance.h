#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 识别频率滑块的范围（每秒次数）。
extern const NSInteger ARMinRecognitionRate;
extern const NSInteger ARMaxRecognitionRate;

/// 芯片名称，例如“Apple M2 Pro”或 Intel 处理器型号。
NSString *ARChipName(void);

/// 根据识别一帧的耗时推荐每秒识别次数：识别最多占用一半时间，留出余量给逐帧追踪和录制编码。
/// seconds 不大于 0 时（尚未测出）按芯片类型给默认值。
NSInteger ARRecommendedRate(double secondsPerRecognition, BOOL appleSilicon);

/// 是否为 Apple 芯片。
BOOL ARIsAppleSilicon(void);

/// 在后台用一张 1920×1080 的样例画面实测识别一帧的耗时（秒），completion 在主线程调用。
void ARMeasureRecognition(BOOL recognizesChinese, void (^completion)(double seconds));

NS_ASSUME_NONNULL_END
