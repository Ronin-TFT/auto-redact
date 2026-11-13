#import <CoreImage/CoreImage.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, ARRedactStyle) {
    ARRedactStyleMosaic = 0, // 马赛克
    ARRedactStyleBlur = 1,   // 模糊
    ARRedactStyleSolid = 2,  // 色块
};

/// 在图像上给 rects（像素坐标，左上角原点）打码，返回新图像。
CIImage *ARRedactImage(CIImage *image, NSArray<NSValue *> *rects, ARRedactStyle style);

NS_ASSUME_NONNULL_END
