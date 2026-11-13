#import <Cocoa/Cocoa.h>
#import "ARRedact.h"

NS_ASSUME_NONNULL_BEGIN

/// 录完复查：播放录像、按打码片段跳转、逐帧检查，手动框选补充遮挡后导出修正版。
@interface ARReviewController : NSWindowController
/// segments 为录制时记录的打码片段 @{@"start", @"end", @"kind"}；kindNames 为类型的中文名。
- (instancetype)initWithURL:(NSURL *)url
                   segments:(NSArray<NSDictionary *> *)segments
                  kindNames:(NSDictionary<NSString *, NSString *> *)kindNames
                      style:(ARRedactStyle)style;
@end

/// 画面视图中的矩形（左下角原点）换算为录像像素坐标（左上角原点）。videoBounds 为画面在视图中的位置。
NSRect ARVideoRectFromViewRect(NSRect viewRect, NSRect videoBounds, CGSize videoSize);

NS_ASSUME_NONNULL_END
