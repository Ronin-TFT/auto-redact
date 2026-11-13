#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

/// 屏幕遮挡模式（用于 Zoom、腾讯会议等共享屏幕）：识别到敏感信息后，在屏幕上盖一块不透明的遮挡，
/// 之后逐帧追踪画面移动，让遮挡紧贴文字。遮挡块会被共享出去，你自己也能看到；识别时会排除遮挡块本身。
/// 从未识别过的新内容在下一次识别前可能短暂露出。
@interface AROverlaySession : NSObject
@property (nonatomic) BOOL recognizesChinese;
@property (nonatomic) double recognitionsPerSecond;
@property (nonatomic, readonly) NSUInteger currentCount;
@property (nonatomic, readonly, getter=isRunning) BOOL running;
@property (nonatomic, copy, nullable) void (^updateHandler)(NSUInteger count);
@property (nonatomic, copy, nullable) void (^interruptedHandler)(NSError *_Nullable error);

- (void)startDisplay:(CGDirectDisplayID)displayID screenFrame:(NSRect)screenFrame completion:(void (^)(NSError *_Nullable error))completion;
- (void)stop;
@end

/// 画面像素矩形（左上角原点）转换为屏幕坐标（Cocoa，左下角原点）。
NSRect ARScreenRectFromPixelRect(NSRect pixelRect, CGSize pixelSize, NSRect screenFrame);

NS_ASSUME_NONNULL_END
