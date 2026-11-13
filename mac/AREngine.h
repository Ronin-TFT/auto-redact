#import <Foundation/Foundation.h>


NS_ASSUME_NONNULL_BEGIN

/// Go 识别引擎（静态库）的封装：找出文字中需要打码的位置。
@interface AREngine : NSObject
/// 设置识别类型（phone、email、idcard、bankcard、secret、password、ip、keyword）与自定义关键词。
+ (BOOL)configureKinds:(NSArray<NSString *> *)kinds keywords:(NSArray<NSString *> *)keywords error:(NSString *_Nullable *_Nullable)error;
/// 每行返回需要打码的范围（NSRange，UTF-16）与类型，元素为 @{@"range": NSValue, @"kind": NSString}。
+ (NSArray<NSArray<NSDictionary *> *> *)findInLines:(NSArray<NSString *> *)lines;
@end

NS_ASSUME_NONNULL_END
