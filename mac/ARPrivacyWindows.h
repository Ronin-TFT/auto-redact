#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

/// 系统通知（横幅、通知中心）所属进程的 Bundle ID。
extern NSString *const ARNotificationCenterBundleID;

/// 隐私窗口：指定 App 的窗口整块遮住（遮挡模式）或不出现在录像里（录屏模式），不依赖文字识别。
@interface ARPrivacyWindows : NSObject
/// 这些 App 当前显示在屏幕上的窗口位置（Cocoa 全局坐标，左下角原点）。
+ (NSArray<NSValue *> *)windowFramesForBundleIDs:(NSArray<NSString *> *)bundleIDs;
/// 正在运行、有界面的 App：@{@"id": Bundle ID, @"name": 名称}，按名称排序，不含本 App。
+ (NSArray<NSDictionary<NSString *, NSString *> *> *)runningApps;
@end

/// CGWindowList 的窗口位置（以主屏左上角为原点）换算为 Cocoa 全局坐标。
NSRect ARCocoaRectFromWindowBounds(CGRect bounds, CGFloat primaryScreenHeight);

NS_ASSUME_NONNULL_END
