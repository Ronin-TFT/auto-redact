#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface ARAppDelegate : NSObject <NSApplicationDelegate, NSMenuItemValidation>
- (IBAction)showMainWindow:(nullable id)sender;
- (IBAction)toggleRunning:(nullable id)sender;
- (IBAction)checkScreen:(nullable id)sender;
@end

/// 把关键词输入框的内容拆成列表（逗号、顿号、换行分隔）。
NSArray<NSString *> *ARSplitKeywords(NSString *text);

NS_ASSUME_NONNULL_END
