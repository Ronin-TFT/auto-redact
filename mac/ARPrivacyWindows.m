#import "ARPrivacyWindows.h"
#import <unistd.h>

NSString *const ARNotificationCenterBundleID = @"com.apple.notificationcenterui";

NSRect ARCocoaRectFromWindowBounds(CGRect b, CGFloat primaryHeight) {
    return NSMakeRect(b.origin.x, primaryHeight - b.origin.y - b.size.height, b.size.width, b.size.height);
}

@implementation ARPrivacyWindows

+ (NSArray<NSValue *> *)windowFramesForBundleIDs:(NSArray<NSString *> *)bundleIDs {
    if (!bundleIDs.count) return @[];
    NSSet<NSString *> *wanted = [NSSet setWithArray:bundleIDs];
    NSMutableSet<NSNumber *> *pids = [NSMutableSet set];
    for (NSRunningApplication *app in NSWorkspace.sharedWorkspace.runningApplications) {
        if (app.bundleIdentifier && [wanted containsObject:app.bundleIdentifier]) [pids addObject:@(app.processIdentifier)];
    }
    if (!pids.count) return @[];
    CGFloat primaryHeight = NSScreen.screens.firstObject.frame.size.height;
    NSArray *windows = CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements,
                                                                   kCGNullWindowID));
    NSMutableArray<NSValue *> *frames = [NSMutableArray array];
    for (NSDictionary *info in windows) {
        NSNumber *pid = info[(id)kCGWindowOwnerPID];
        if (!pid || pid.intValue == getpid() || ![pids containsObject:pid]) continue;
        // 跳过菜单栏图标（状态栏层级）和完全透明的窗口。
        NSInteger layer = [info[(id)kCGWindowLayer] integerValue];
        double alpha = info[(id)kCGWindowAlpha] ? [info[(id)kCGWindowAlpha] doubleValue] : 1;
        if (layer == kCGStatusWindowLevel || alpha <= 0.01) continue;
        CGRect bounds;
        if (!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)info[(id)kCGWindowBounds], &bounds)) continue;
        if (bounds.size.width < 8 || bounds.size.height < 8) continue;
        [frames addObject:[NSValue valueWithRect:ARCocoaRectFromWindowBounds(bounds, primaryHeight)]];
    }
    return frames;
}

+ (NSArray<NSDictionary<NSString *, NSString *> *> *)runningApps {
    NSMutableArray *apps = [NSMutableArray array];
    NSString *me = NSBundle.mainBundle.bundleIdentifier;
    for (NSRunningApplication *app in NSWorkspace.sharedWorkspace.runningApplications) {
        if (app.activationPolicy != NSApplicationActivationPolicyRegular || !app.bundleIdentifier || !app.localizedName) continue;
        if ([app.bundleIdentifier isEqualToString:me ?: @""]) continue;
        [apps addObject:@{@"id": app.bundleIdentifier, @"name": app.localizedName}];
    }
    [apps sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"name"] localizedStandardCompare:b[@"name"]];
    }];
    return apps;
}

@end
