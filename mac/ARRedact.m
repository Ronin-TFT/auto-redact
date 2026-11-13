#import "ARRedact.h"
#import <AppKit/AppKit.h>

CIImage *ARRedactImage(CIImage *image, NSArray<NSValue *> *rects, ARRedactStyle style) {
    if (!rects.count) return image;
    CGRect extent = image.extent;
    CGFloat height = extent.size.height;
    CIImage *covered = nil;
    switch (style) {
    case ARRedactStyleMosaic: {
        CIFilter *filter = [CIFilter filterWithName:@"CIPixellate"];
        [filter setValue:image.imageByClampingToExtent forKey:kCIInputImageKey];
        [filter setValue:@(MAX(12.0, height / 60.0)) forKey:kCIInputScaleKey];
        [filter setValue:[CIVector vectorWithX:extent.origin.x Y:extent.origin.y] forKey:kCIInputCenterKey];
        covered = filter.outputImage;
        break;
    }
    case ARRedactStyleBlur: {
        CIFilter *filter = [CIFilter filterWithName:@"CIGaussianBlur"];
        [filter setValue:image.imageByClampingToExtent forKey:kCIInputImageKey];
        [filter setValue:@(MAX(16.0, height / 40.0)) forKey:kCIInputRadiusKey];
        covered = filter.outputImage;
        break;
    }
    case ARRedactStyleSolid:
        covered = [CIImage imageWithColor:[CIColor colorWithRed:0.12 green:0.12 blue:0.13]];
        break;
    }
    if (!covered) return image;
    CIImage *result = image;
    for (NSValue *value in rects) {
        NSRect r = value.rectValue;
        // 左上角原点 → Core Image 的左下角原点。
        CGRect ci = CGRectIntersection(CGRectMake(extent.origin.x + r.origin.x,
                                                  extent.origin.y + height - r.origin.y - r.size.height,
                                                  r.size.width, r.size.height), extent);
        if (CGRectIsEmpty(ci)) continue;
        result = [[covered imageByCroppingToRect:ci] imageByCompositingOverImage:result];
    }
    return [result imageByCroppingToRect:extent];
}
