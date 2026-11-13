#import "ARAppDelegate.h"
#import "ARCapture.h"
#import "AREngine.h"
#import "ARHotkeys.h"
#import "ARLayout.h"
#import "ARMicrophone.h"
#import "AROverlaySession.h"
#import "ARPerformance.h"
#import "ARPrivacyWindows.h"
#import "ARRecognizer.h"
#import "ARRecordSession.h"
#import "ARRegionSelector.h"
#import "ARReviewController.h"

/// 交给文字引擎的类型。
static NSArray<NSString *> *ARKinds(void) {
    return @[@"phone", @"email", @"idcard", @"bankcard", @"secret", @"password", @"ip", @"keyword"];
}

/// 不靠文字识别的类型（Vision 直接检测）。
static NSArray<NSString *> *ARVisualKinds(void) { return @[@"qrcode", @"face"]; }

static NSDictionary<NSString *, NSString *> *ARKindNames(void) {
    return @{@"phone": @"手机号", @"email": @"邮箱", @"idcard": @"身份证号", @"bankcard": @"银行卡号",
             @"secret": @"API 密钥 / 令牌", @"password": @"密码 / 验证码", @"ip": @"IP 地址", @"keyword": @"自定义关键词",
             @"qrcode": @"二维码 / 条形码", @"face": @"人脸"};
}

NSArray<NSString *> *ARSplitKeywords(NSString *text) {
    NSCharacterSet *separators = [NSCharacterSet characterSetWithCharactersInString:@",，、;；\n\r"];
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *part in [text componentsSeparatedByCharactersInSet:separators]) {
        NSString *word = [part stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (word.length && ![out containsObject:word]) [out addObject:word];
    }
    return out;
}

static NSString *ARDuration(NSTimeInterval seconds) {
    long t = lround(MAX(0, seconds));
    return t >= 3600 ? [NSString stringWithFormat:@"%ld:%02ld:%02ld", t / 3600, (t / 60) % 60, t % 60]
                     : [NSString stringWithFormat:@"%ld:%02ld", t / 60, t % 60];
}

static CGDirectDisplayID ARDisplayID(NSScreen *screen) {
    return [screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue];
}

static NSTextField *ARNote(NSString *text) {
    NSTextField *note = [NSTextField wrappingLabelWithString:text];
    note.textColor = NSColor.secondaryLabelColor;
    note.font = [NSFont systemFontOfSize:12];
    return note;
}

static NSGridView *ARFormGrid(NSArray<NSArray<NSView *> *> *rows) {
    NSGridView *grid = [NSGridView gridViewWithViews:rows];
    grid.rowSpacing = 8;
    grid.columnSpacing = 12;
    [grid columnAtIndex:0].xPlacement = NSGridCellPlacementTrailing;
    return grid;
}

@interface ARAppDelegate ()
@property (nonatomic, strong) NSWindow *window;
// 常规
@property (nonatomic, strong) NSPopUpButton *modePopup;
@property (nonatomic, strong) NSPopUpButton *screenPopup;
@property (nonatomic, strong) NSPopUpButton *areaPopup;
@property (nonatomic, strong) NSButton *areaButton;
@property (nonatomic, strong) NSTextField *areaLabel;
@property (nonatomic) NSRect customArea; // Cocoa 全局坐标，NSZeroRect 表示未选择
@property (nonatomic, strong) NSSlider *rateSlider;
@property (nonatomic, strong) NSTextField *rateLabel;
@property (nonatomic, strong) NSTextField *recommendLabel;
@property (nonatomic, strong) NSButton *useRecommendedButton;
@property (nonatomic) NSInteger recommendedRate;
/// 每次开始测速递增，丢弃过时的测速结果（切换“精确识别”时会重新测）。
@property (nonatomic) NSUInteger measureGeneration;
@property (nonatomic, strong) NSTextField *modeNote;
// 打码内容
@property (nonatomic, strong) NSDictionary<NSString *, NSButton *> *kindChecks;
@property (nonatomic, strong) NSTextField *keywordsField;
@property (nonatomic, strong) NSButton *chineseCheck;
// 隐私
@property (nonatomic, copy) NSArray<NSDictionary<NSString *, NSString *> *> *privacyApps;
@property (nonatomic, strong) NSTextField *privacyLabel;
@property (nonatomic, strong) NSButton *addAppButton;
@property (nonatomic, strong) NSButton *clearAppsButton;
@property (nonatomic, strong) NSButton *notificationCheck;
@property (nonatomic, copy) NSArray<NSValue *> *fixedRegions; // Cocoa 全局坐标
@property (nonatomic, strong) NSTextField *fixedLabel;
@property (nonatomic, strong) NSButton *addFixedButton;
@property (nonatomic, strong) NSButton *clearFixedButton;
// 录屏与声音
@property (nonatomic, strong) NSPopUpButton *stylePopup;
@property (nonatomic, strong) NSPopUpButton *qualityPopup;
@property (nonatomic, strong) NSPopUpButton *fpsPopup;
@property (nonatomic, strong) NSButton *cursorCheck;
@property (nonatomic, strong) NSButton *systemAudioCheck;
@property (nonatomic, strong) NSButton *micCheck;
@property (nonatomic, strong) NSPopUpButton *micPopup;
@property (nonatomic, strong) NSButton *reviewCheck;
@property (nonatomic, strong) NSTextField *folderLabel;
// 快捷键
@property (nonatomic, strong) ARHotkeys *hotkeys;
@property (nonatomic, strong) NSTextField *hotkeyStatus;
// 底部
@property (nonatomic, strong) NSButton *startButton;
@property (nonatomic, strong) NSButton *checkButton;
@property (nonatomic, strong) NSButton *reviewButton;
@property (nonatomic, strong) NSTextField *statusField;
@property (nonatomic, strong) NSStatusItem *statusItem;
@property (nonatomic, strong, nullable) NSTimer *timer;
@property (nonatomic, strong) NSURL *folderURL;
@property (nonatomic, strong, nullable) NSURL *lastRecordingURL;
@property (nonatomic, copy) NSArray<NSDictionary *> *lastSegments;
@property (nonatomic, strong) ARRecordSession *recordSession;
@property (nonatomic, strong) AROverlaySession *overlaySession;
@property (nonatomic, strong, nullable) ARCapture *checkCapture;
@property (nonatomic, strong, nullable) NSWindow *areaBorder;
@property (nonatomic, strong) NSMutableArray<ARReviewController *> *reviewControllers;
@property (nonatomic) BOOL busy;
@end

@implementation ARAppDelegate

#pragma mark - 启动

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    NSURL *movies = [NSFileManager.defaultManager URLsForDirectory:NSMoviesDirectory inDomains:NSUserDomainMask].firstObject;
    self.folderURL = [movies ?: [NSURL fileURLWithPath:NSHomeDirectory()] URLByAppendingPathComponent:@"自动打码" isDirectory:YES];
    self.privacyApps = @[];
    self.fixedRegions = @[];
    self.lastSegments = @[];
    self.customArea = NSZeroRect;
    self.reviewControllers = [NSMutableArray array];
    self.recordSession = [ARRecordSession new];
    self.overlaySession = [AROverlaySession new];
    __weak ARAppDelegate *weakSelf = self;
    self.recordSession.interruptedHandler = ^(NSURL *url, NSError *error) { [weakSelf recordingFinished:url error:error interrupted:YES]; };
    self.overlaySession.interruptedHandler = ^(NSError *error) {
        [weakSelf.timer invalidate];
        [weakSelf setStatus:[NSString stringWithFormat:@"遮挡已停止：%@", error.localizedDescription ?: @"系统中断"]];
        [weakSelf updateControls];
    };
    self.overlaySession.updateHandler = ^(NSUInteger count) { [weakSelf tick:nil]; };

    [self buildWindow];
    [self loadSettings];
    [self buildStatusItem];
    [self registerHotkeys];
    [self updateControls];
    [self measureRecognitionSpeed];
    [self showMainWindow:nil];
    if (!CGPreflightScreenCaptureAccess()) {
        [self setStatus:@"首次使用需要屏幕录制权限：点“检查当前屏幕”后按提示在系统设置中允许，然后重新打开 App"];
    }
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)app { return NO; }

- (BOOL)applicationShouldHandleReopen:(NSApplication *)app hasVisibleWindows:(BOOL)visible {
    [self showMainWindow:nil];
    return YES;
}

- (BOOL)applicationSupportsSecureRestorableState:(NSApplication *)app { return YES; }

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)app {
    [self saveSettings];
    [self.hotkeys unregister];
    [self.overlaySession stop];
    if (!self.recordSession.running) return NSTerminateNow;
    [self.recordSession stopWithCompletion:^(NSURL *url, NSError *error) {
        [NSApp replyToApplicationShouldTerminate:YES];
    }];
    return NSTerminateLater;
}

- (void)showMainWindow:(id)sender {
    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

#pragma mark - 界面

- (NSPopUpButton *)popup:(NSArray<NSString *> *)titles tags:(NSArray<NSNumber *> *)tags {
    NSPopUpButton *popup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [popup addItemsWithTitles:titles];
    for (NSUInteger i = 0; i < tags.count && i < popup.numberOfItems; i++) [popup itemAtIndex:(NSInteger)i].tag = tags[i].integerValue;
    popup.target = self;
    popup.action = @selector(settingChanged:);
    return popup;
}

- (NSButton *)check:(NSString *)title {
    return [NSButton checkboxWithTitle:title target:self action:@selector(settingChanged:)];
}

- (NSTabViewItem *)tab:(NSString *)title views:(NSArray<NSView *> *)views fill:(NSArray<NSView *> *)fill {
    NSStackView *stack = ARColumn(views, 10);
    ARFillWidth(stack, fill);
    NSView *content = [NSView new];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:content.topAnchor constant:14],
        [stack.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:16],
        [stack.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-16],
        [stack.bottomAnchor constraintLessThanOrEqualToAnchor:content.bottomAnchor constant:-14],
    ]];
    NSTabViewItem *item = [[NSTabViewItem alloc] initWithIdentifier:title];
    item.label = title;
    item.view = content;
    return item;
}

- (NSTabViewItem *)buildGeneralTab {
    self.modePopup = [self popup:@[@"录屏并打码", @"屏幕遮挡（会议共享）"] tags:@[@0, @1]];
    self.screenPopup = [self popup:@[] tags:@[]];
    for (NSScreen *screen in NSScreen.screens) {
        // 用菜单项添加：两块同名显示器时 addItemWithTitle: 会合并成一项。
        NSMenuItem *item = [self.screenPopup.menu addItemWithTitle:screen.localizedName action:nil keyEquivalent:@""];
        item.tag = ARDisplayID(screen);
    }
    self.areaPopup = [self popup:@[@"整个屏幕", @"自定义区域"] tags:@[@0, @1]];
    self.areaButton = [NSButton buttonWithTitle:@"选择区域…" target:self action:@selector(chooseArea:)];
    self.areaLabel = ARLabel(@"", 12, NO);
    self.areaLabel.textColor = NSColor.secondaryLabelColor;

    self.rateSlider = [NSSlider sliderWithValue:5 minValue:ARMinRecognitionRate maxValue:ARMaxRecognitionRate
                                         target:self action:@selector(rateChanged:)];
    self.rateSlider.numberOfTickMarks = ARMaxRecognitionRate - ARMinRecognitionRate + 1;
    self.rateSlider.allowsTickMarkValuesOnly = YES;
    [self.rateSlider.widthAnchor constraintEqualToConstant:200].active = YES;
    self.rateLabel = ARLabel(@"", 13, NO);
    self.rateLabel.font = [NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightRegular];
    [self.rateLabel.widthAnchor constraintGreaterThanOrEqualToConstant:76].active = YES;
    self.recommendLabel = ARLabel(@"正在测试本机识别速度…", 12, NO);
    self.recommendLabel.textColor = NSColor.secondaryLabelColor;
    self.useRecommendedButton = [NSButton buttonWithTitle:@"使用推荐值" target:self action:@selector(useRecommendedRate:)];
    self.useRecommendedButton.controlSize = NSControlSizeSmall;
    self.useRecommendedButton.enabled = NO;

    NSGridView *grid = ARFormGrid(@[
        @[ARLabel(@"模式", 13, NO), self.modePopup],
        @[ARLabel(@"屏幕", 13, NO), self.screenPopup],
        @[ARLabel(@"录制范围", 13, NO), ARRow(@[self.areaPopup, self.areaButton, self.areaLabel], 8)],
        @[ARLabel(@"识别频率", 13, NO), ARRow(@[self.rateSlider, self.rateLabel], 8)],
        @[NSGridCell.emptyContentView, ARRow(@[self.recommendLabel, self.useRecommendedButton], 8)],
    ]);
    self.modeNote = ARNote(@"");
    return [self tab:@"常规" views:@[grid, self.modeNote] fill:@[self.modeNote]];
}

- (NSTabViewItem *)buildKindsTab {
    NSMutableDictionary *checks = [NSMutableDictionary dictionary];
    NSMutableArray *views = [NSMutableArray array];
    for (NSString *kind in [ARKinds() arrayByAddingObjectsFromArray:ARVisualKinds()]) {
        NSButton *check = [self check:ARKindNames()[kind]];
        check.state = ([kind isEqualToString:@"ip"] || [kind isEqualToString:@"face"]) ? NSControlStateValueOff : NSControlStateValueOn;
        checks[kind] = check;
        [views addObject:check];
    }
    self.kindChecks = checks;
    NSGridView *kindGrid = [NSGridView gridViewWithViews:@[
        @[views[0], views[1], views[2], views[3]],
        @[views[4], views[5], views[6], views[7]],
        @[views[8], views[9], NSGridCell.emptyContentView, NSGridCell.emptyContentView],
    ]];
    kindGrid.columnSpacing = 14;
    kindGrid.rowSpacing = 6;

    self.keywordsField = [NSTextField textFieldWithString:@""];
    self.keywordsField.placeholderString = @"自定义关键词，用逗号分隔，例如：张三, 公司内部项目名";
    self.keywordsField.target = self;
    self.keywordsField.action = @selector(settingChanged:);
    self.chineseCheck = [NSButton checkboxWithTitle:@"精确识别：支持中文，小字、浅色字、深色模式更可靠（较慢，推荐频率会随之降低）"
                                             target:self action:@selector(chineseChanged:)];
    NSTextField *note = ARNote(@"二维码、条形码和人脸不依赖文字识别，按画面直接检测。人脸的遮挡范围会比脸略大一些。");
    return [self tab:@"打码内容" views:@[kindGrid, self.keywordsField, self.chineseCheck, note] fill:@[self.keywordsField, note]];
}

- (NSTabViewItem *)buildPrivacyTab {
    self.privacyLabel = [NSTextField wrappingLabelWithString:@""];
    self.privacyLabel.font = [NSFont systemFontOfSize:12];
    self.addAppButton = [NSButton buttonWithTitle:@"添加 App…" target:self action:@selector(addPrivacyApp:)];
    self.clearAppsButton = [NSButton buttonWithTitle:@"清空" target:self action:@selector(clearPrivacyApps:)];
    self.notificationCheck = [self check:@"遮住系统通知（横幅、通知中心）"];
    self.notificationCheck.state = NSControlStateValueOn;
    NSTextField *appNote = ARNote(@"这些 App 的窗口整块处理，不依赖文字识别：录屏时不会出现在录像里，遮挡模式下整块盖住。适合微信、邮件、密码管理器等。");

    self.fixedLabel = ARLabel(@"", 12, NO);
    self.addFixedButton = [NSButton buttonWithTitle:@"添加区域…" target:self action:@selector(addFixedRegion:)];
    self.clearFixedButton = [NSButton buttonWithTitle:@"清空" target:self action:@selector(clearFixedRegions:)];
    NSTextField *fixedNote = ARNote(@"框选屏幕上始终需要遮住的位置，例如书签栏、侧边栏。录屏和遮挡模式都会生效。");

    return [self tab:@"隐私" views:@[
        ARLabel(@"隐私 App", 13, YES), self.privacyLabel, ARRow(@[self.addAppButton, self.clearAppsButton], 8), self.notificationCheck, appNote,
        ARLabel(@"固定遮挡区域", 13, YES), ARRow(@[self.fixedLabel, self.addFixedButton, self.clearFixedButton], 8), fixedNote,
    ] fill:@[self.privacyLabel, appNote, fixedNote]];
}

- (NSTabViewItem *)buildRecordTab {
    self.stylePopup = [self popup:@[@"马赛克", @"模糊", @"色块"] tags:@[@0, @1, @2]];
    self.qualityPopup = [self popup:@[@"1080p（推荐）", @"原始分辨率"] tags:@[@1920, @0]];
    self.fpsPopup = [self popup:@[@"30 帧/秒", @"60 帧/秒"] tags:@[@30, @60]];
    self.cursorCheck = [self check:@"录制鼠标指针"];
    self.cursorCheck.state = NSControlStateValueOn;
    self.systemAudioCheck = [self check:@"系统声音"];
    self.micCheck = [self check:@"麦克风"];
    self.micPopup = [self popup:@[@"系统默认"] tags:@[@0]];
    for (NSDictionary *device in [ARMicrophone availableDevices]) {
        NSMenuItem *item = [self.micPopup.menu addItemWithTitle:device[@"name"] action:nil keyEquivalent:@""];
        item.representedObject = device[@"id"];
    }
    self.reviewCheck = [self check:@"录完后打开复查窗口（可逐帧检查、手动补打码）"];
    self.reviewCheck.state = NSControlStateValueOn;
    self.folderLabel = ARLabel(@"", 12, NO);
    self.folderLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [self.folderLabel setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSGridView *grid = ARFormGrid(@[
        @[ARLabel(@"打码样式", 13, NO), self.stylePopup],
        @[ARLabel(@"画质", 13, NO), ARRow(@[self.qualityPopup, self.fpsPopup, self.cursorCheck], 8)],
        @[ARLabel(@"声音", 13, NO), ARRow(@[self.systemAudioCheck, self.micCheck, self.micPopup], 8)],
        @[ARLabel(@"复查", 13, NO), self.reviewCheck],
        @[ARLabel(@"保存到", 13, NO), ARRow(@[self.folderLabel,
                                              [NSButton buttonWithTitle:@"更改…" target:self action:@selector(chooseFolder:)],
                                              [NSButton buttonWithTitle:@"在 Finder 中显示" target:self action:@selector(revealInFinder:)]], 8)],
    ]);
    NSTextField *note = ARNote(@"录像会比实时画面晚约半秒写入：每一帧都等识别完成再打码，录出来的视频里每一帧都已遮住。"
                               @"系统声音不包含本 App；麦克风首次使用需要授权。这些设置只对录屏模式生效。");
    return [self tab:@"录屏与声音" views:@[grid, note] fill:@[note]];
}

- (NSTabViewItem *)buildHotkeyTab {
    NSGridView *grid = ARFormGrid(@[
        @[ARLabel([ARHotkeys nameForAction:ARHotkeyActionRecord], 13, NO), ARLabel(@"开始 / 停止录屏", 13, NO)],
        @[ARLabel([ARHotkeys nameForAction:ARHotkeyActionOverlay], 13, NO), ARLabel(@"开始 / 停止屏幕遮挡", 13, NO)],
    ]);
    self.hotkeyStatus = ARNote(@"");
    NSTextField *note = ARNote(@"App 在后台、窗口关闭时也能使用。开始录屏 / 遮挡时使用当前保存的设置。");
    return [self tab:@"快捷键" views:@[grid, note, self.hotkeyStatus] fill:@[note, self.hotkeyStatus]];
}

- (void)buildWindow {
    self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 680, 520)
                                              styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable
                                                backing:NSBackingStoreBuffered
                                                  defer:NO];
    self.window.title = @"自动打码";
    self.window.releasedWhenClosed = NO;
    [self.window center];

    NSTabView *tabs = [NSTabView new];
    for (NSTabViewItem *item in @[[self buildGeneralTab], [self buildKindsTab], [self buildPrivacyTab],
                                  [self buildRecordTab], [self buildHotkeyTab]]) {
        [tabs addTabViewItem:item];
    }
    [tabs.heightAnchor constraintGreaterThanOrEqualToConstant:300].active = YES;

    self.startButton = [NSButton buttonWithTitle:@"开始" target:self action:@selector(toggleRunning:)];
    self.startButton.keyEquivalent = @"\r";
    [self.startButton.widthAnchor constraintGreaterThanOrEqualToConstant:100].active = YES;
    self.checkButton = [NSButton buttonWithTitle:@"检查当前屏幕" target:self action:@selector(checkScreen:)];
    self.reviewButton = [NSButton buttonWithTitle:@"复查上次录像" target:self action:@selector(openLastReview:)];
    self.statusField = [NSTextField wrappingLabelWithString:@"准备就绪"];
    self.statusField.font = [NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightRegular];

    NSTextField *subtitle = ARLabel(@"录屏、共享屏幕时自动遮住手机号、邮箱、密钥、二维码等敏感信息", 13, NO);
    subtitle.textColor = NSColor.secondaryLabelColor;
    NSStackView *stack = ARColumn(@[
        ARLabel(@"自动打码", 22, YES), subtitle, tabs,
        ARRow(@[self.startButton, self.checkButton, self.reviewButton], 10), self.statusField,
    ], 10);
    [stack setCustomSpacing:2 afterView:stack.arrangedSubviews[0]];
    ARFillWidth(stack, @[tabs, self.statusField]);
    ARPin(stack, self.window.contentView, 20);
}

- (void)buildStatusItem {
    self.statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    NSImage *image = [NSImage imageWithSystemSymbolName:@"eye.slash" accessibilityDescription:@"自动打码"];
    if (image) {
        image.template = YES;
        self.statusItem.button.image = image;
    } else {
        self.statusItem.button.title = @"打码";
    }
    NSMenu *menu = [NSMenu new];
    [menu addItemWithTitle:@"开始" action:@selector(toggleRunning:) keyEquivalent:@""].target = self;
    [menu addItemWithTitle:@"检查当前屏幕" action:@selector(checkScreen:) keyEquivalent:@""].target = self;
    [menu addItem:NSMenuItem.separatorItem];
    [menu addItemWithTitle:@"显示窗口" action:@selector(showMainWindow:) keyEquivalent:@""].target = self;
    [menu addItemWithTitle:@"退出自动打码" action:@selector(terminate:) keyEquivalent:@""].target = NSApp;
    self.statusItem.menu = menu;
}

- (BOOL)isRunning { return self.recordSession.running || self.overlaySession.running; }
- (BOOL)overlayMode { return self.modePopup.selectedTag == 1; }

- (BOOL)validateMenuItem:(NSMenuItem *)item {
    if (item.action == @selector(toggleRunning:)) {
        item.title = self.isRunning ? @"停止" : ([self overlayMode] ? @"开始遮挡" : @"开始录屏");
        return !self.busy;
    }
    if (item.action == @selector(checkScreen:)) return !self.busy && !self.isRunning;
    return YES;
}

- (void)updateControls {
    BOOL running = self.isRunning, overlay = [self overlayMode], editable = !running && !self.busy;
    self.startButton.title = running ? @"停止" : (overlay ? @"开始遮挡" : @"开始录屏");
    self.startButton.enabled = !self.busy;
    self.checkButton.enabled = editable;
    self.reviewButton.hidden = !self.lastRecordingURL;
    self.reviewButton.enabled = editable;
    self.folderLabel.stringValue = self.folderURL.path;
    self.modeNote.stringValue = overlay
        ? @"遮挡模式会在屏幕上的敏感信息处盖上深色遮挡块，共享屏幕时对方看到的是遮挡块，你自己也会看到。"
          @"新出现的内容在下一次识别前（约 0.2 秒）可能短暂露出；涉及高度敏感的信息，请先关闭再共享。遮挡模式始终覆盖整块屏幕。"
        : @"录屏模式：每一帧都在识别、追踪后才写入录像，滚动、拖动时遮挡会跟着文字走。画面不变时不重复识别，只变化一小块时只识别那一块。";

    BOOL custom = self.areaPopup.selectedTag == 1;
    self.areaButton.hidden = !custom;
    self.areaLabel.hidden = !custom;
    self.areaLabel.stringValue = NSIsEmptyRect(self.customArea) ? @"尚未选择"
        : [NSString stringWithFormat:@"%.0f × %.0f", self.customArea.size.width, self.customArea.size.height];

    NSMutableArray *names = [NSMutableArray array];
    for (NSDictionary *app in self.privacyApps) [names addObject:app[@"name"] ?: app[@"id"]];
    self.privacyLabel.stringValue = names.count ? [names componentsJoinedByString:@"、"] : @"未添加";
    self.fixedLabel.stringValue = self.fixedRegions.count ? [NSString stringWithFormat:@"已添加 %lu 块", (unsigned long)self.fixedRegions.count] : @"未添加";

    NSMutableArray<NSControl *> *controls = [NSMutableArray arrayWithArray:@[
        self.modePopup, self.screenPopup, self.areaPopup, self.areaButton, self.rateSlider, self.keywordsField, self.chineseCheck,
        self.addAppButton, self.clearAppsButton, self.notificationCheck, self.addFixedButton, self.clearFixedButton,
        self.stylePopup, self.qualityPopup, self.fpsPopup, self.cursorCheck, self.systemAudioCheck, self.micCheck, self.reviewCheck]];
    [controls addObjectsFromArray:self.kindChecks.allValues];
    for (NSControl *control in controls) control.enabled = editable;
    self.micPopup.enabled = editable && self.micCheck.state == NSControlStateValueOn;
    [self updateRateLabel];
    NSImage *image = [NSImage imageWithSystemSymbolName:running ? @"eye.slash.fill" : @"eye.slash" accessibilityDescription:@"自动打码"];
    if (image) {
        image.template = YES;
        self.statusItem.button.image = image;
    }
}

- (void)setStatus:(NSString *)text {
    self.statusField.stringValue = text;
}

#pragma mark - 识别频率

- (void)updateRateLabel {
    NSInteger rate = self.rateSlider.integerValue;
    self.rateLabel.stringValue = [NSString stringWithFormat:@"每秒 %ld 次", (long)rate];
    self.useRecommendedButton.enabled = self.recommendedRate > 0 && rate != self.recommendedRate && !self.isRunning;
}

- (void)rateChanged:(id)sender {
    [self updateRateLabel];
    [self saveSettings];
}

- (void)useRecommendedRate:(id)sender {
    if (self.recommendedRate <= 0) return;
    self.rateSlider.integerValue = self.recommendedRate;
    [self rateChanged:nil];
}

- (void)chineseChanged:(id)sender {
    [self settingChanged:sender];
    [self measureRecognitionSpeed];
}

/// 实测本机识别一帧的耗时，给出推荐频率。
- (void)measureRecognitionSpeed {
    NSUInteger generation = ++self.measureGeneration;
    BOOL chinese = self.chineseCheck.state == NSControlStateValueOn;
    BOOL appleSilicon = ARIsAppleSilicon();
    NSString *chip = ARChipName();
    self.recommendedRate = ARRecommendedRate(0, appleSilicon);
    self.recommendLabel.stringValue = [NSString stringWithFormat:@"正在测试本机识别速度…（%@）", chip];
    [self updateRateLabel];
    ARMeasureRecognition(chinese, ^(double seconds) {
        if (generation != self.measureGeneration) return;
        self.recommendedRate = ARRecommendedRate(seconds, appleSilicon);
        if (seconds > 0) {
            self.recommendLabel.stringValue = [NSString stringWithFormat:@"推荐：每秒 %ld 次（%@ · %@识别一帧约 %.0f 毫秒）",
                                               (long)self.recommendedRate, chip, chinese ? @"精确模式" : @"快速模式",
                                               seconds * 1000];
        } else {
            self.recommendLabel.stringValue = [NSString stringWithFormat:@"推荐：每秒 %ld 次（%@）", (long)self.recommendedRate, chip];
        }
        // 第一次使用（没有保存过频率）时直接采用推荐值。
        if (![NSUserDefaults.standardUserDefaults objectForKey:@"rate"]) {
            self.rateSlider.integerValue = self.recommendedRate;
            [self saveSettings];
        }
        [self updateRateLabel];
    });
}

- (void)settingChanged:(id)sender {
    if (sender == self.areaPopup && self.areaPopup.selectedTag == 1 && NSIsEmptyRect(self.customArea)) {
        [self updateControls];
        [self chooseArea:nil];
        return;
    }
    if (sender == self.micCheck && self.micCheck.state == NSControlStateValueOn) {
        [ARMicrophone requestAccess:^(BOOL granted) {
            if (granted) return;
            self.micCheck.state = NSControlStateValueOff;
            [self setStatus:@"没有麦克风权限：请在 系统设置 > 隐私与安全性 > 麦克风 中允许“自动打码”"];
            [self updateControls];
            [self saveSettings];
        }];
    }
    [self updateControls];
    [self saveSettings];
}

#pragma mark - 录制范围、隐私 App、固定区域

- (void)chooseArea:(id)sender {
    [self.window orderOut:nil];
    [ARRegionSelector selectRegionWithPrompt:@"拖拽选择录制范围 · 回车选择整块屏幕 · Esc 取消" completion:^(NSRect rect, NSScreen *screen) {
        [self showMainWindow:nil];
        if (screen && !NSIsEmptyRect(rect)) {
            self.customArea = rect;
            [self.screenPopup selectItemWithTag:ARDisplayID(screen)];
        } else if (NSIsEmptyRect(self.customArea)) {
            [self.areaPopup selectItemWithTag:0];
        }
        [self updateControls];
        [self saveSettings];
    }];
}

- (void)addPrivacyApp:(NSButton *)sender {
    NSMenu *menu = [NSMenu new];
    NSArray *added = [self.privacyApps valueForKey:@"id"];
    for (NSDictionary *app in [ARPrivacyWindows runningApps]) {
        if ([added containsObject:app[@"id"]]) continue;
        NSMenuItem *item = [menu addItemWithTitle:app[@"name"] action:@selector(addRunningApp:) keyEquivalent:@""];
        item.target = self;
        item.representedObject = app;
    }
    if (menu.numberOfItems) [menu addItem:NSMenuItem.separatorItem];
    [menu addItemWithTitle:@"其他 App…" action:@selector(addOtherApp:) keyEquivalent:@""].target = self;
    [menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(0, NSHeight(sender.bounds) + 4) inView:sender];
}

- (void)addPrivacyAppID:(NSString *)bundleID name:(NSString *)name {
    if (!bundleID.length || [[self.privacyApps valueForKey:@"id"] containsObject:bundleID]) return;
    self.privacyApps = [self.privacyApps arrayByAddingObject:@{@"id": bundleID, @"name": name.length ? name : bundleID}];
    [self updateControls];
    [self saveSettings];
}

- (void)addRunningApp:(NSMenuItem *)item {
    NSDictionary *app = item.representedObject;
    [self addPrivacyAppID:app[@"id"] name:app[@"name"]];
}

- (void)addOtherApp:(id)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseDirectories = NO;
    panel.treatsFilePackagesAsDirectories = NO;
    panel.directoryURL = [NSURL fileURLWithPath:@"/Applications" isDirectory:YES];
    panel.prompt = @"添加";
    panel.message = @"选择要整块隐藏的 App";
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        if (response != NSModalResponseOK || !panel.URL) return;
        NSBundle *bundle = [NSBundle bundleWithURL:panel.URL];
        if (!bundle.bundleIdentifier) {
            [self setStatus:@"这不是一个 App，或无法读取它的标识"];
            return;
        }
        NSString *name = [NSFileManager.defaultManager displayNameAtPath:panel.URL.path];
        if ([name.pathExtension isEqualToString:@"app"]) name = name.stringByDeletingPathExtension;
        [self addPrivacyAppID:bundle.bundleIdentifier name:name];
    }];
}

- (void)clearPrivacyApps:(id)sender {
    self.privacyApps = @[];
    [self updateControls];
    [self saveSettings];
}

- (void)addFixedRegion:(id)sender {
    [self.window orderOut:nil];
    [ARRegionSelector selectRegionWithPrompt:@"拖拽框选始终需要遮住的位置 · Esc 取消" completion:^(NSRect rect, NSScreen *screen) {
        [self showMainWindow:nil];
        if (screen && !NSIsEmptyRect(rect)) {
            self.fixedRegions = [self.fixedRegions arrayByAddingObject:[NSValue valueWithRect:rect]];
            [self updateControls];
            [self saveSettings];
        }
    }];
}

- (void)clearFixedRegions:(id)sender {
    self.fixedRegions = @[];
    [self updateControls];
    [self saveSettings];
}

- (NSArray<NSString *> *)privacyBundleIDs {
    NSMutableArray *ids = [NSMutableArray arrayWithArray:[self.privacyApps valueForKey:@"id"]];
    if (self.notificationCheck.state == NSControlStateValueOn) [ids addObject:ARNotificationCenterBundleID];
    return ids;
}

#pragma mark - 快捷键

- (void)registerHotkeys {
    self.hotkeys = [ARHotkeys new];
    __weak ARAppDelegate *weakSelf = self;
    self.hotkeys.handler = ^(ARHotkeyAction action) { [weakSelf hotkeyPressed:action]; };
    NSArray<NSString *> *failed = [self.hotkeys registerDefaults];
    self.hotkeyStatus.stringValue = failed.count
        ? [NSString stringWithFormat:@"以下快捷键已被其他 App 占用，无法使用：%@", [failed componentsJoinedByString:@"、"]]
        : @"快捷键已启用。";
}

- (void)hotkeyPressed:(ARHotkeyAction)action {
    if (self.busy) return;
    BOOL wantsOverlay = action == ARHotkeyActionOverlay;
    if (self.isRunning) {
        // 只停止对应的那一种。
        if ((wantsOverlay && self.overlaySession.running) || (!wantsOverlay && self.recordSession.running)) [self toggleRunning:nil];
        return;
    }
    [self.modePopup selectItemWithTag:wantsOverlay ? 1 : 0];
    [self settingChanged:self.modePopup];
    [self toggleRunning:nil];
}

#pragma mark - 设置

- (void)loadSettings {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    if ([d objectForKey:@"mode"]) [self.modePopup selectItemWithTag:[d integerForKey:@"mode"]];
    if ([d objectForKey:@"display"]) [self.screenPopup selectItemWithTag:[d integerForKey:@"display"]];
    NSString *area = [d stringForKey:@"area"];
    if (area.length) self.customArea = NSRectFromString(area);
    if ([d integerForKey:@"areaMode"] == 1 && !NSIsEmptyRect(self.customArea)) [self.areaPopup selectItemWithTag:1];
    NSArray *kinds = [d arrayForKey:@"kinds"];
    if (kinds) {
        for (NSString *kind in self.kindChecks) self.kindChecks[kind].state = [kinds containsObject:kind] ? NSControlStateValueOn : NSControlStateValueOff;
        // 0.1 版保存的设置里没有这两项：二维码默认开启。
        if (![d objectForKey:@"visualKinds"]) self.kindChecks[@"qrcode"].state = NSControlStateValueOn;
    }
    self.keywordsField.stringValue = [d stringForKey:@"keywords"] ?: @"";
    self.chineseCheck.state = [d boolForKey:@"chinese"] ? NSControlStateValueOn : NSControlStateValueOff;
    if ([d objectForKey:@"rate"]) self.rateSlider.integerValue = MIN(MAX([d integerForKey:@"rate"], ARMinRecognitionRate), ARMaxRecognitionRate);
    [self updateRateLabel];
    NSMutableArray *apps = [NSMutableArray array];
    for (id app in [d arrayForKey:@"privacyApps"] ?: @[]) {
        if ([app isKindOfClass:NSDictionary.class] && [app[@"id"] isKindOfClass:NSString.class]) [apps addObject:app];
    }
    self.privacyApps = apps;
    if ([d objectForKey:@"notifications"]) self.notificationCheck.state = [d boolForKey:@"notifications"] ? NSControlStateValueOn : NSControlStateValueOff;
    NSMutableArray *fixed = [NSMutableArray array];
    for (id rect in [d arrayForKey:@"fixedRegions"] ?: @[]) {
        if ([rect isKindOfClass:NSString.class] && !NSIsEmptyRect(NSRectFromString(rect))) [fixed addObject:[NSValue valueWithRect:NSRectFromString(rect)]];
    }
    self.fixedRegions = fixed;
    if ([d objectForKey:@"style"]) [self.stylePopup selectItemWithTag:[d integerForKey:@"style"]];
    if ([d objectForKey:@"quality"]) [self.qualityPopup selectItemWithTag:[d integerForKey:@"quality"]];
    if ([d objectForKey:@"fps"]) [self.fpsPopup selectItemWithTag:[d integerForKey:@"fps"]];
    if ([d objectForKey:@"cursor"]) self.cursorCheck.state = [d boolForKey:@"cursor"] ? NSControlStateValueOn : NSControlStateValueOff;
    self.systemAudioCheck.state = [d boolForKey:@"systemAudio"] ? NSControlStateValueOn : NSControlStateValueOff;
    self.micCheck.state = [d boolForKey:@"microphone"] ? NSControlStateValueOn : NSControlStateValueOff;
    NSString *micID = [d stringForKey:@"microphoneID"];
    for (NSMenuItem *item in self.micPopup.itemArray) {
        if (micID.length && [item.representedObject isEqual:micID]) [self.micPopup selectItem:item];
    }
    if ([d objectForKey:@"review"]) self.reviewCheck.state = [d boolForKey:@"review"] ? NSControlStateValueOn : NSControlStateValueOff;
    NSString *folder = [d stringForKey:@"folder"];
    if (folder.length) self.folderURL = [NSURL fileURLWithPath:folder isDirectory:YES];
}

- (void)saveSettings {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    [d setInteger:self.modePopup.selectedTag forKey:@"mode"];
    [d setInteger:self.screenPopup.selectedTag forKey:@"display"];
    [d setInteger:self.areaPopup.selectedTag forKey:@"areaMode"];
    [d setObject:NSStringFromRect(self.customArea) forKey:@"area"];
    NSMutableArray *kinds = [NSMutableArray arrayWithArray:[self selectedKinds]];
    for (NSString *kind in ARVisualKinds()) {
        if (self.kindChecks[kind].state == NSControlStateValueOn) [kinds addObject:kind];
    }
    [d setObject:kinds forKey:@"kinds"];
    [d setBool:YES forKey:@"visualKinds"];
    [d setObject:self.keywordsField.stringValue forKey:@"keywords"];
    [d setBool:self.chineseCheck.state == NSControlStateValueOn forKey:@"chinese"];
    [d setInteger:self.rateSlider.integerValue forKey:@"rate"];
    [d setObject:self.privacyApps forKey:@"privacyApps"];
    [d setBool:self.notificationCheck.state == NSControlStateValueOn forKey:@"notifications"];
    NSMutableArray *fixed = [NSMutableArray array];
    for (NSValue *rect in self.fixedRegions) [fixed addObject:NSStringFromRect(rect.rectValue)];
    [d setObject:fixed forKey:@"fixedRegions"];
    [d setInteger:self.stylePopup.selectedTag forKey:@"style"];
    [d setInteger:self.qualityPopup.selectedTag forKey:@"quality"];
    [d setInteger:self.fpsPopup.selectedTag forKey:@"fps"];
    [d setBool:self.cursorCheck.state == NSControlStateValueOn forKey:@"cursor"];
    [d setBool:self.systemAudioCheck.state == NSControlStateValueOn forKey:@"systemAudio"];
    [d setBool:self.micCheck.state == NSControlStateValueOn forKey:@"microphone"];
    NSString *micID = self.micPopup.selectedItem.representedObject;
    if (micID) [d setObject:micID forKey:@"microphoneID"]; else [d removeObjectForKey:@"microphoneID"];
    [d setBool:self.reviewCheck.state == NSControlStateValueOn forKey:@"review"];
    [d setObject:self.folderURL.path forKey:@"folder"];
}

/// 选中的文字类型（交给引擎）。
- (NSArray<NSString *> *)selectedKinds {
    NSMutableArray *kinds = [NSMutableArray array];
    for (NSString *kind in ARKinds()) {
        if (self.kindChecks[kind].state == NSControlStateValueOn) [kinds addObject:kind];
    }
    return kinds;
}

- (BOOL)detectsCodes { return self.kindChecks[@"qrcode"].state == NSControlStateValueOn; }
- (BOOL)detectsFaces { return self.kindChecks[@"face"].state == NSControlStateValueOn; }

/// 把界面设置交给识别引擎；什么都没选时提示。
- (BOOL)applyDetectionSettings {
    NSArray<NSString *> *kinds = [self selectedKinds];
    NSArray<NSString *> *keywords = ARSplitKeywords(self.keywordsField.stringValue);
    if ([kinds containsObject:@"keyword"] && !keywords.count) {
        NSMutableArray *withoutKeyword = [kinds mutableCopy];
        [withoutKeyword removeObject:@"keyword"];
        kinds = withoutKeyword;
    }
    BOOL hasOther = self.detectsCodes || self.detectsFaces || self.fixedRegions.count || self.privacyApps.count;
    if (!kinds.count && !hasOther) {
        [self setStatus:@"请至少选择一种打码内容"];
        return NO;
    }
    // 引擎收到空列表会用默认类型；只选了二维码 / 人脸 / 隐私项时，传一个不会匹配任何文字的配置。
    if (!kinds.count) kinds = @[@"keyword"];
    NSString *error = nil;
    if (![AREngine configureKinds:kinds keywords:keywords error:&error]) {
        [self setStatus:error ?: @"设置无效"];
        return NO;
    }
    [self saveSettings];
    return YES;
}

- (NSScreen *)selectedScreen {
    for (NSScreen *screen in NSScreen.screens) {
        if (ARDisplayID(screen) == (CGDirectDisplayID)self.screenPopup.selectedTag) return screen;
    }
    return NSScreen.screens.firstObject;
}

- (BOOL)ensurePermission {
    if (CGPreflightScreenCaptureAccess()) return YES;
    CGRequestScreenCaptureAccess();
    [self setStatus:@"需要屏幕录制权限：请在 系统设置 > 隐私与安全性 > 屏幕与系统录音 中允许“自动打码”，然后退出并重新打开 App"];
    return NO;
}

#pragma mark - 开始与停止

- (void)toggleRunning:(id)sender {
    if (self.busy) return;
    if (self.overlaySession.running) {
        [self.overlaySession stop];
        [self.timer invalidate];
        [self setStatus:@"遮挡已停止"];
        [self updateControls];
        return;
    }
    if (self.recordSession.running) {
        self.busy = YES;
        [self setStatus:@"正在完成打码并保存…"];
        [self updateControls];
        [self.recordSession stopWithCompletion:^(NSURL *url, NSError *error) {
            [self recordingFinished:url error:error interrupted:NO];
        }];
        return;
    }
    if (![self ensurePermission] || ![self applyDetectionSettings]) return;
    if ([self overlayMode]) {
        [self startOverlay];
    } else if (self.micCheck.state == NSControlStateValueOn) {
        self.busy = YES;
        [self updateControls];
        [ARMicrophone requestAccess:^(BOOL granted) {
            self.busy = NO;
            if (!granted) {
                [self setStatus:@"没有麦克风权限：请在 系统设置 > 隐私与安全性 > 麦克风 中允许，或在“录屏与声音”里关闭麦克风"];
                [self updateControls];
                return;
            }
            [self startRecording];
        }];
    } else {
        [self startRecording];
    }
}

- (void)startOverlay {
    NSScreen *screen = [self selectedScreen];
    self.busy = YES;
    [self updateControls];
    self.overlaySession.recognitionsPerSecond = (double)self.rateSlider.integerValue;
    self.overlaySession.recognizesChinese = self.chineseCheck.state == NSControlStateValueOn;
    self.overlaySession.detectsCodes = self.detectsCodes;
    self.overlaySession.detectsFaces = self.detectsFaces;
    self.overlaySession.privacyBundleIDs = self.privacyBundleIDs;
    self.overlaySession.fixedRegions = self.fixedRegions;
    [self.overlaySession startDisplay:ARDisplayID(screen) screenFrame:screen.frame completion:^(NSError *error) {
        [self startedWithError:error];
    }];
}

- (void)startRecording {
    NSScreen *screen = [self selectedScreen];
    CGRect source = CGRectNull;
    NSRect border = NSZeroRect;
    if (self.areaPopup.selectedTag == 1) {
        source = ARDisplayLocalRect(self.customArea, screen.frame);
        if (CGRectIsNull(source) || source.size.width < 16 || source.size.height < 16) {
            [self setStatus:@"录制范围不在所选屏幕上，请在“常规”里重新选择区域"];
            return;
        }
        border = NSIntersectionRect(self.customArea, screen.frame);
    }
    NSMutableArray<NSValue *> *fixed = [NSMutableArray array];
    for (NSValue *region in self.fixedRegions) {
        CGRect local = ARDisplayLocalRect(region.rectValue, screen.frame);
        if (!CGRectIsNull(local)) [fixed addObject:[NSValue valueWithRect:local]];
    }

    self.busy = YES;
    [self updateControls];
    ARRecordSession *session = self.recordSession;
    session.recognitionsPerSecond = (double)self.rateSlider.integerValue;
    session.recognizesChinese = self.chineseCheck.state == NSControlStateValueOn;
    session.detectsCodes = self.detectsCodes;
    session.detectsFaces = self.detectsFaces;
    session.style = (ARRedactStyle)self.stylePopup.selectedTag;
    session.fixedRegions = fixed;
    session.excludedBundleIDs = self.privacyBundleIDs;
    session.recordsSystemAudio = self.systemAudioCheck.state == NSControlStateValueOn;
    session.recordsMicrophone = self.micCheck.state == NSControlStateValueOn;
    session.microphoneID = self.micPopup.selectedItem.representedObject;

    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.dateFormat = @"yyyy-MM-dd HH.mm.ss";
    NSURL *url = [self.folderURL URLByAppendingPathComponent:
                  [NSString stringWithFormat:@"打码录屏 %@.mp4", [formatter stringFromDate:[NSDate date]]]];
    [session startDisplay:ARDisplayID(screen)
               sourceRect:source
                 maxWidth:self.qualityPopup.selectedTag
                      fps:self.fpsPopup.selectedTag
              showsCursor:self.cursorCheck.state == NSControlStateValueOn
                outputURL:url
               completion:^(NSError *error) {
        if (!error && !NSIsEmptyRect(border)) self.areaBorder = [ARRegionSelector borderWindowForRect:border];
        [self startedWithError:error];
    }];
}

- (void)startedWithError:(NSError *)error {
    self.busy = NO;
    if (error) {
        [self setStatus:[NSString stringWithFormat:@"无法开始：%@。如果刚授予了屏幕录制权限，请退出并重新打开 App", error.localizedDescription]];
    } else {
        self.timer = [NSTimer scheduledTimerWithTimeInterval:0.5 target:self selector:@selector(tick:) userInfo:nil repeats:YES];
        [self tick:nil];
    }
    [self updateControls];
}

- (void)tick:(NSTimer *)timer {
    if (self.recordSession.running) {
        NSDate *started = self.recordSession.startedAt;
        [self setStatus:[NSString stringWithFormat:@"● 录制中 %@ · 当前打码 %lu 处 · %@ 停止",
                         ARDuration(started ? -started.timeIntervalSinceNow : 0), (unsigned long)self.recordSession.currentCount,
                         [ARHotkeys nameForAction:ARHotkeyActionRecord]]];
    } else if (self.overlaySession.running) {
        [self setStatus:[NSString stringWithFormat:@"● 遮挡中 · 当前遮挡 %lu 处 · %@ 停止", (unsigned long)self.overlaySession.currentCount,
                         [ARHotkeys nameForAction:ARHotkeyActionOverlay]]];
    }
}

- (void)recordingFinished:(NSURL *)url error:(NSError *)error interrupted:(BOOL)interrupted {
    self.busy = NO;
    [self.timer invalidate];
    self.timer = nil;
    [self.areaBorder orderOut:nil];
    self.areaBorder = nil;
    if (url) {
        self.lastRecordingURL = url;
        self.lastSegments = self.recordSession.segments ?: @[];
        [self setStatus:[NSString stringWithFormat:@"%@已保存：%@（打码 %lu 段）", interrupted ? @"录制被系统中断，" : @"",
                         url.lastPathComponent, (unsigned long)self.lastSegments.count]];
        if (self.reviewCheck.state == NSControlStateValueOn) [self openLastReview:nil];
    } else {
        [self setStatus:[NSString stringWithFormat:@"保存失败：%@", error.localizedDescription ?: @"未知错误"]];
    }
    [self updateControls];
}

#pragma mark - 复查

- (void)openLastReview:(id)sender {
    NSURL *url = self.lastRecordingURL;
    if (!url || ![NSFileManager.defaultManager fileExistsAtPath:url.path]) {
        [self setStatus:@"找不到上次的录像"];
        return;
    }
    ARReviewController *review = [[ARReviewController alloc] initWithURL:url segments:self.lastSegments
                                                              kindNames:ARKindNames() style:(ARRedactStyle)self.stylePopup.selectedTag];
    [self.reviewControllers addObject:review];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(reviewWindowWillClose:)
                                               name:NSWindowWillCloseNotification object:review.window];
    [review showWindow:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

- (void)reviewWindowWillClose:(NSNotification *)notification {
    NSWindow *window = notification.object;
    [NSNotificationCenter.defaultCenter removeObserver:self name:NSWindowWillCloseNotification object:window];
    for (ARReviewController *review in [self.reviewControllers copy]) {
        if (review.window == window) [self.reviewControllers removeObject:review];
    }
}

#pragma mark - 检查当前屏幕

- (void)checkScreen:(id)sender {
    if (self.busy || self.isRunning) return;
    if (![self ensurePermission] || ![self applyDetectionSettings]) return;
    self.busy = YES;
    [self updateControls];
    [self setStatus:@"正在识别当前屏幕…"];
    ARCapture *capture = [ARCapture new];
    ARRecognizer *recognizer = [ARRecognizer new];
    recognizer.recognizesChinese = self.chineseCheck.state == NSControlStateValueOn;
    recognizer.detectsCodes = self.detectsCodes;
    recognizer.detectsFaces = self.detectsFaces;
    self.checkCapture = capture;
    __block BOOL done = NO;
    void (^finish)(NSString *) = ^(NSString *message) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.busy = NO;
            self.checkCapture = nil;
            [self setStatus:message];
            [self updateControls];
        });
    };
    ARCaptureOptions *options = [ARCaptureOptions new];
    options.displayID = ARDisplayID([self selectedScreen]);
    options.maxWidth = 0;
    options.fps = 2;
    options.showsCursor = NO;
    options.sourceRect = CGRectNull;
    [capture startWithOptions:options prepare:^BOOL(CGSize size, NSError **error) { return YES; }
                 frameHandler:^(CMSampleBufferRef sample, CVPixelBufferRef pixels, double time) {
        if (done) return;
        done = YES;
        NSArray<ARDetection *> *detections = [recognizer detectionsInPixelBuffer:pixels];
        [capture stopWithCompletion:^{}];
        if (!detections.count) {
            finish(@"当前屏幕没有发现需要打码的信息");
            return;
        }
        NSCountedSet *kinds = [NSCountedSet set];
        for (ARDetection *d in detections) [kinds addObject:d.kind];
        NSMutableArray *parts = [NSMutableArray array];
        for (NSString *kind in [ARKinds() arrayByAddingObjectsFromArray:ARVisualKinds()]) {
            if ([kinds countForObject:kind]) [parts addObject:[NSString stringWithFormat:@"%@ %lu", ARKindNames()[kind], (unsigned long)[kinds countForObject:kind]]];
        }
        finish([NSString stringWithFormat:@"当前屏幕发现 %lu 处：%@", (unsigned long)detections.count, [parts componentsJoinedByString:@" · "]]);
    } audioHandler:nil completion:^(NSError *error) {
        if (error) finish([NSString stringWithFormat:@"无法识别屏幕：%@", error.localizedDescription]);
    }];
}

#pragma mark - 保存位置

- (void)chooseFolder:(id)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = NO;
    panel.canChooseDirectories = YES;
    panel.canCreateDirectories = YES;
    panel.prompt = @"选择";
    panel.directoryURL = self.folderURL;
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        if (response != NSModalResponseOK || !panel.URL) return;
        self.folderURL = panel.URL;
        [self saveSettings];
        [self updateControls];
    }];
}

- (void)revealInFinder:(id)sender {
    if (self.lastRecordingURL && [NSFileManager.defaultManager fileExistsAtPath:self.lastRecordingURL.path]) {
        [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[self.lastRecordingURL]];
        return;
    }
    [NSFileManager.defaultManager createDirectoryAtURL:self.folderURL withIntermediateDirectories:YES attributes:nil error:NULL];
    [NSWorkspace.sharedWorkspace openURL:self.folderURL];
}

@end
