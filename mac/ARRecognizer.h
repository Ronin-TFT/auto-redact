#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN

/// 一处敏感信息：像素坐标（左上角原点）与类型。
@interface ARDetection : NSObject
@property (nonatomic, readonly) NSRect rect;
@property (nonatomic, readonly, copy) NSString *kind;
/// 内容指纹（被打码文字的哈希，不保存原文），用于在前后两次识别之间找到同一处文字。
@property (nonatomic, readonly) uint32_t key;
- (instancetype)initWithRect:(NSRect)rect kind:(NSString *)kind key:(uint32_t)key;
@end

/// 文字的 32 位指纹（FNV-1a），保证不为 0。
uint32_t ARTextKey(NSString *text);

/// 用 Vision 识别画面中的文字，再交给引擎找出敏感信息。同步执行，请在后台队列调用。
@interface ARRecognizer : NSObject
/// YES 时使用精确模式并识别中文（用于中文关键词，较慢）；NO 时为快速模式（英文与数字）。
@property (nonatomic) BOOL recognizesChinese;
- (NSArray<ARDetection *> *)detectionsInPixelBuffer:(CVPixelBufferRef)buffer;
@end

/// 按字符位置估算 range 在整行 line 中的位置（归一化坐标），用于识别结果没有精确位置时。
CGRect ARApproximateRangeBox(CGRect line, NSString *text, NSRange range);

/// Vision 的归一化矩形（左下角原点）转换为像素矩形（左上角原点）。
NSRect ARPixelRectFromNormalized(CGRect normalized, size_t width, size_t height);

NS_ASSUME_NONNULL_END
