#import <Foundation/Foundation.h>
#import "ARRedact.h"

NS_ASSUME_NONNULL_BEGIN

/// 一处手动补充的遮挡：录像像素坐标（左上角原点）与时间段（秒）。
@interface ARManualMask : NSObject
@property (nonatomic) NSRect rect;
@property (nonatomic) double start;
@property (nonatomic) double end;
- (instancetype)initWithRect:(NSRect)rect start:(double)start end:(double)end;
@end

/// 把手动补充的遮挡应用到已有录像上，导出新文件（声音原样保留）。
@interface ARPatchExporter : NSObject
/// progress 与 completion 在主线程调用。
+ (void)exportURL:(NSURL *)source
               to:(NSURL *)destination
            masks:(NSArray<ARManualMask *> *)masks
            style:(ARRedactStyle)style
         progress:(void (^)(double fraction))progress
       completion:(void (^)(NSError *_Nullable error))completion;
@end

/// 某一时刻需要遮挡的区域。
NSArray<NSValue *> *ARMasksAtTime(NSArray<ARManualMask *> *masks, double time);

NS_ASSUME_NONNULL_END
