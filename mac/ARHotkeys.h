#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 全局快捷键（应用在后台时也能触发）：⌃⌥⌘R 开始/停止录屏，⌃⌥⌘H 开始/停止遮挡。
typedef NS_ENUM(NSUInteger, ARHotkeyAction) {
    ARHotkeyActionRecord = 1,
    ARHotkeyActionOverlay = 2,
};

@interface ARHotkeys : NSObject
@property (nonatomic, copy, nullable) void (^handler)(ARHotkeyAction action);
/// 注册快捷键，返回注册失败（被占用）的快捷键名称。
- (NSArray<NSString *> *)registerDefaults;
- (void)unregister;
+ (NSString *)nameForAction:(ARHotkeyAction)action;
@end

NS_ASSUME_NONNULL_END
