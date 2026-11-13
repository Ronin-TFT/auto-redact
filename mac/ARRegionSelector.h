#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

/// 全屏选区：在每块屏幕上盖一层半透明遮罩，拖拽框选区域（录制区域、固定遮挡区域）。
@interface ARRegionSelector : NSObject
/// rect 为 Cocoa 全局坐标（左下角原点）。回车选择鼠标所在的整块屏幕，Esc 取消；
/// 取消时 rect 为 NSZeroRect、screen 为 nil。
+ (void)selectRegionWithCompletion:(void (^)(NSRect rect, NSScreen *_Nullable screen))completion;
/// 同上，prompt 为屏幕上显示的提示文字。
+ (void)selectRegionWithPrompt:(NSString *)prompt completion:(void (^)(NSRect rect, NSScreen *_Nullable screen))completion;

/// 录制自定义区域时在屏幕上标出范围的红色虚线边框（不会被录进视频）。
+ (NSWindow *)borderWindowForRect:(NSRect)globalRect;
@end

NS_ASSUME_NONNULL_END
