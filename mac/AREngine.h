#import <Foundation/Foundation.h>

@class ARDetection;

NS_ASSUME_NONNULL_BEGIN

/// Go 识别与跟踪引擎（静态库）的封装。跟踪器全局只有一个，同一时间只能有一个打码任务。
@interface AREngine : NSObject
/// 设置识别类型（phone、email、idcard、bankcard、secret、password、ip、keyword）与自定义关键词。
+ (BOOL)configureKinds:(NSArray<NSString *> *)kinds keywords:(NSArray<NSString *> *)keywords error:(NSString *_Nullable *_Nullable)error;
/// 每行返回需要打码的范围（NSRange，UTF-16）与类型，元素为 @{@"range": NSValue, @"kind": NSString}。
+ (NSArray<NSArray<NSDictionary *> *> *)findInLines:(NSArray<NSString *> *)lines;
+ (void)resetTrackerWidth:(double)width height:(double)height padding:(double)padding hold:(double)hold;
/// rects 为像素坐标（左上角原点）的 NSRect。
+ (void)addBoxes:(NSArray<NSValue *> *)rects atTime:(double)time;
/// 记录识别结果，同时传入内容指纹，滚动时更准确。
+ (void)addDetections:(NSArray<ARDetection *> *)detections atTime:(double)time;
/// 最近一次识别的时间；没有时返回 -INFINITY。
+ (double)latestTime;
+ (NSArray<NSValue *> *)boxesAtTime:(double)time;
/// 实时遮挡用：额外覆盖按滚动速度预测的 ahead 秒内的位置。
+ (NSArray<NSValue *> *)boxesAtTime:(double)time ahead:(double)ahead;
@end

NS_ASSUME_NONNULL_END
