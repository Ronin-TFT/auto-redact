#import <Cocoa/Cocoa.h>
#import "ARAppDelegate.h"

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        ARAppDelegate *delegate = [ARAppDelegate new];
        app.delegate = delegate;

        NSMenu *menuBar = [NSMenu new];
        NSMenuItem *appItem = [[NSMenuItem alloc] initWithTitle:@"自动打码" action:nil keyEquivalent:@""];
        NSMenu *appMenu = [[NSMenu alloc] initWithTitle:@"自动打码"];
        [appMenu addItemWithTitle:@"显示窗口" action:@selector(showMainWindow:) keyEquivalent:@"0"];
        [appMenu addItem:NSMenuItem.separatorItem];
        [appMenu addItemWithTitle:@"隐藏自动打码" action:@selector(hide:) keyEquivalent:@"h"];
        [appMenu addItemWithTitle:@"退出自动打码" action:@selector(terminate:) keyEquivalent:@"q"];
        appItem.submenu = appMenu;
        [menuBar addItem:appItem];
        NSMenuItem *editItem = [[NSMenuItem alloc] initWithTitle:@"编辑" action:nil keyEquivalent:@""];
        NSMenu *editMenu = [[NSMenu alloc] initWithTitle:@"编辑"];
        [editMenu addItemWithTitle:@"剪切" action:@selector(cut:) keyEquivalent:@"x"];
        [editMenu addItemWithTitle:@"复制" action:@selector(copy:) keyEquivalent:@"c"];
        [editMenu addItemWithTitle:@"粘贴" action:@selector(paste:) keyEquivalent:@"v"];
        [editMenu addItemWithTitle:@"全选" action:@selector(selectAll:) keyEquivalent:@"a"];
        editItem.submenu = editMenu;
        [menuBar addItem:editItem];
        NSMenuItem *windowItem = [[NSMenuItem alloc] initWithTitle:@"窗口" action:nil keyEquivalent:@""];
        NSMenu *windowMenu = [[NSMenu alloc] initWithTitle:@"窗口"];
        [windowMenu addItemWithTitle:@"关闭窗口" action:@selector(performClose:) keyEquivalent:@"w"];
        [windowMenu addItemWithTitle:@"最小化" action:@selector(performMiniaturize:) keyEquivalent:@"m"];
        windowItem.submenu = windowMenu;
        [menuBar addItem:windowItem];
        app.mainMenu = menuBar;

        [app run];
    }
    return 0;
}
