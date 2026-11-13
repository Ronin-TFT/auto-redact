#import "ARAppDelegate.h"
#import "ARCapture.h"
#import "AREngine.h"
#import "ARLayout.h"
#import "AROverlaySession.h"
#import "ARPerformance.h"
#import "ARRecognizer.h"
#import "ARRecordSession.h"

static NSArray<NSString *> *ARKinds(void) {
    return @[@"phone", @"email", @"idcard", @"bankcard", @"secret", @"password", @"ip", @"keyword"];
}

static NSDictionary<NSString *, NSString *> *ARKindNames(void) {
    return @{@"phone": @"手机号", @"email": @"邮箱", @"idcard": @"身份证号", @"bankcard": @"银行卡号",
             @"secret": @"API 密钥 / 令牌", @"password": @"密码 / 验证码", @"ip": @"IP 地址", @"keyword": @"自定义关键词"};
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

@interface ARAppDelegate ()
@property (nonatomic, strong) NSWindow *window;
@property (nonatomic, strong) NSPopUpButton *modePopup;
@property (nonatomic, strong) NSPopUpButton *screenPopup;
@property (nonatomic, strong) NSDictionary<NSString *, NSButton *> *kindChecks;
@property (nonatomic, strong) NSTextField *keywordsField;
@property (nonatomic, strong) NSButton *chineseCheck;
@property (nonatomic, strong) NSSlider *rateSlider;
@property (nonatomic, strong) NSTextField *rateLabel;
@property (nonatomic, strong) NSTextField *recommendLabel;
@property (nonatomic, strong) NSButton *useRecommendedButton;
@property (nonatomic) NSInteger recommendedRate;
/// 每次开始测速递增，丢弃过时的测速结果（切换“精确识别”时会重新测）。
@property (nonatomic) NSUInteger measureGeneration;
@property (nonatomic, strong) NSPopUpButton *stylePopup;
@property (nonatomic, strong) NSPopUpButton *qualityPopup;
@property (nonatomic, strong) NSPopUpButton *fpsPopup;
@property (nonatomic, strong) NSButton *cursorCheck;
@property (nonatomic, strong) NSTextField *folderLabel;
@property (nonatomic, strong) NSStackView *recordOptions;
@property (nonatomic, strong) NSTextField *overlayNote;
@property (nonatomic, strong) NSButton *startButton;
@property (nonatomic, strong) NSButton *checkButton;
@property (nonatomic, strong) NSTextField *statusField;
@property (nonatomic, strong) NSStatusItem *statusItem;
@property (nonatomic, strong, nullable) NSTimer *timer;
@property (nonatomic, strong) NSURL *folderURL;
@property (nonatomic, strong, nullable) NSURL *lastRecordingURL;
@property (nonatomic, strong) ARRecordSession *recordSession;
@property (nonatomic, strong) AROverlaySession *overlaySession;
@property (nonatomic, strong, nullable) ARCapture *checkCapture;
@property (nonatomic) BOOL busy;
@end

@implementation ARAppDelegate

#pragma mark - 启动

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    NSURL *movies = [NSFileManager.defaultManager URLsForDirectory:NSMoviesDirectory inDomains:NSUserDomainMask].firstObject;
    self.folderURL = [movies ?: [NSURL fileURLWithPath:NSHomeDirectory()] URLByAppendingPathComponent:@"自动打码" isDirectory:YES];
    self.recordSession = [ARRecordSession new];
    self.overlaySession = [AROverlaySession new];
    __weak ARAppDelegate *weakSelf = self;
    self.recordSession.interruptedHandler = ^(NSURL *url, NSError *error) { [weakSelf recordingFinished:url error:error interrupted:YES]; };
    self.overlaySession.interruptedHandler = ^(NSError *error) {
        [weakSelf setStatus:[NSString stringWithFormat:@"遮挡已停止：%@", error.localizedDescription ?: @"系统中断"]];
        [weakSelf updateControls];
    };
    self.overlaySession.updateHandler = ^(NSUInteger count) { [weakSelf tick:nil]; };

    [self buildWindow];
    [self loadSettings];
    [self buildStatusItem];
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
    return popup;
}

- (void)buildWindow {
    self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 640, 640)
                                              styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable
                                                backing:NSBackingStoreBuffered
                                                  defer:NO];
    self.window.title = @"自动打码";
    self.window.releasedWhenClosed = NO;
    [self.window center];

    self.modePopup = [self popup:@[@"录屏并打码", @"屏幕遮挡（会议共享）"] tags:@[@0, @1]];
    self.modePopup.target = self;
    self.modePopup.action = @selector(settingChanged:);
    self.screenPopup = [self popup:@[] tags:@[]];
    for (NSScreen *screen in NSScreen.screens) {
        // 用菜单项添加：两块同名显示器时 addItemWithTitle: 会合并成一项。
        NSMenuItem *item = [self.screenPopup.menu addItemWithTitle:screen.localizedName action:nil keyEquivalent:@""];
        item.tag = ARDisplayID(screen);
    }

    NSMutableDictionary *checks = [NSMutableDictionary dictionary];
    NSMutableArray *checkViews = [NSMutableArray array];
    for (NSString *kind in ARKinds()) {
        NSButton *check = [NSButton checkboxWithTitle:ARKindNames()[kind] target:self action:@selector(settingChanged:)];
        check.state = [kind isEqualToString:@"ip"] ? NSControlStateValueOff : NSControlStateValueOn;
        checks[kind] = check;
        [checkViews addObject:check];
    }
    self.kindChecks = checks;
    NSGridView *kindGrid = [NSGridView gridViewWithViews:@[
        @[checkViews[0], checkViews[1], checkViews[2], checkViews[3]],
        @[checkViews[4], checkViews[5], checkViews[6], checkViews[7]],
    ]];
    kindGrid.columnSpacing = 14;
    kindGrid.rowSpacing = 6;

    self.keywordsField = [NSTextField textFieldWithString:@""];
    self.keywordsField.placeholderString = @"自定义关键词，用逗号分隔，例如：张三, 公司内部项目名";
    self.chineseCheck = [NSButton checkboxWithTitle:@"精确识别：支持中文，小字、浅色字、深色模式更可靠（较慢，推荐频率会随之降低）" target:self action:@selector(chineseChanged:)];
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

    self.stylePopup = [self popup:@[@"马赛克", @"模糊", @"色块"] tags:@[@0, @1, @2]];
    self.qualityPopup = [self popup:@[@"1080p（推荐）", @"原始分辨率"] tags:@[@1920, @0]];
    self.fpsPopup = [self popup:@[@"30 帧/秒", @"60 帧/秒"] tags:@[@30, @60]];
    self.cursorCheck = [NSButton checkboxWithTitle:@"录制鼠标指针" target:nil action:nil];
    self.cursorCheck.state = NSControlStateValueOn;
    self.folderLabel = ARLabel(@"", 12, NO);
    self.folderLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [self.folderLabel setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSGridView *recordGrid = [NSGridView gridViewWithViews:@[
        @[ARLabel(@"打码样式", 13, NO), self.stylePopup],
        @[ARLabel(@"画质", 13, NO), ARRow(@[self.qualityPopup, self.fpsPopup, self.cursorCheck], 8)],
        @[ARLabel(@"保存到", 13, NO), ARRow(@[self.folderLabel,
                                              [NSButton buttonWithTitle:@"更改…" target:self action:@selector(chooseFolder:)],
                                              [NSButton buttonWithTitle:@"在 Finder 中显示" target:self action:@selector(revealInFinder:)]], 8)],
    ]];
    recordGrid.rowSpacing = 8;
    recordGrid.columnSpacing = 12;
    [recordGrid columnAtIndex:0].xPlacement = NSGridCellPlacementTrailing;
    NSTextField *recordNote = [NSTextField wrappingLabelWithString:
        @"录像会比实时画面晚约半秒写入：每一帧都等识别完成再打码，录出来的视频里每一帧都已遮住。"];
    recordNote.textColor = NSColor.secondaryLabelColor;
    recordNote.font = [NSFont systemFontOfSize:12];
    self.recordOptions = ARColumn(@[recordGrid, recordNote], 8);
    ARFillWidth(self.recordOptions, @[recordNote]);

    self.overlayNote = [NSTextField wrappingLabelWithString:
        @"遮挡模式会在屏幕上的敏感信息处盖上深色遮挡块，共享屏幕时对方看到的是遮挡块，你自己也会看到。"
        @"新出现的内容在下一次识别前（约 0.2 秒）可能短暂露出；涉及高度敏感的信息，请先关闭再共享。"];
    self.overlayNote.textColor = NSColor.secondaryLabelColor;
    self.overlayNote.font = [NSFont systemFontOfSize:12];

    NSGridView *topGrid = [NSGridView gridViewWithViews:@[
        @[ARLabel(@"模式", 13, NO), self.modePopup],
        @[ARLabel(@"屏幕", 13, NO), self.screenPopup],
        @[ARLabel(@"识别频率", 13, NO), ARRow(@[self.rateSlider, self.rateLabel], 8)],
        @[NSGridCell.emptyContentView, ARRow(@[self.recommendLabel, self.useRecommendedButton], 8)],
    ]];
    topGrid.rowSpacing = 8;
    topGrid.columnSpacing = 12;
    [topGrid columnAtIndex:0].xPlacement = NSGridCellPlacementTrailing;

    self.startButton = [NSButton buttonWithTitle:@"开始" target:self action:@selector(toggleRunning:)];
    self.startButton.keyEquivalent = @"\r";
    [self.startButton.widthAnchor constraintGreaterThanOrEqualToConstant:100].active = YES;
    self.checkButton = [NSButton buttonWithTitle:@"检查当前屏幕" target:self action:@selector(checkScreen:)];
    self.statusField = [NSTextField wrappingLabelWithString:@"准备就绪"];
    self.statusField.font = [NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightRegular];

    NSTextField *subtitle = ARLabel(@"录屏、共享屏幕时自动遮住手机号、邮箱、密钥等敏感信息", 13, NO);
    subtitle.textColor = NSColor.secondaryLabelColor;
    NSStackView *stack = ARColumn(@[
        ARLabel(@"自动打码", 22, YES), subtitle,
        topGrid,
        ARLabel(@"打码内容", 14, YES), kindGrid, self.keywordsField, self.chineseCheck,
        ARLabel(@"录屏", 14, YES), self.recordOptions, self.overlayNote,
        ARRow(@[self.startButton, self.checkButton], 10), self.statusField,
    ], 10);
    [stack setCustomSpacing:2 afterView:stack.arrangedSubviews[0]];
    [stack setCustomSpacing:16 afterView:subtitle];
    ARFillWidth(stack, @[self.keywordsField, self.recordOptions, self.overlayNote, self.statusField]);
    ARPin(stack, self.window.contentView, 22);
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
    BOOL running = self.isRunning, overlay = [self overlayMode];
    self.startButton.title = running ? @"停止" : (overlay ? @"开始遮挡" : @"开始录屏");
    self.startButton.enabled = !self.busy;
    self.checkButton.enabled = !self.busy && !running;
    self.recordOptions.hidden = overlay;
    self.overlayNote.hidden = !overlay;
    self.folderLabel.stringValue = self.folderURL.path;
    NSMutableArray<NSControl *> *controls = [NSMutableArray arrayWithArray:@[self.modePopup, self.screenPopup, self.rateSlider,
                                                                             self.keywordsField, self.chineseCheck, self.stylePopup,
                                                                             self.qualityPopup, self.fpsPopup, self.cursorCheck]];
    [controls addObjectsFromArray:self.kindChecks.allValues];
    for (NSControl *control in controls) control.enabled = !running && !self.busy;
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
                                               (long)self.recommendedRate, chip, chinese ? @"含中文" : @"",
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
    [self updateControls];
    [self saveSettings];
}

#pragma mark - 设置

- (void)loadSettings {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    if ([d objectForKey:@"mode"]) [self.modePopup selectItemWithTag:[d integerForKey:@"mode"]];
    if ([d objectForKey:@"display"]) [self.screenPopup selectItemWithTag:[d integerForKey:@"display"]];
    NSArray *kinds = [d arrayForKey:@"kinds"];
    if (kinds) {
        for (NSString *kind in ARKinds()) self.kindChecks[kind].state = [kinds containsObject:kind] ? NSControlStateValueOn : NSControlStateValueOff;
    }
    self.keywordsField.stringValue = [d stringForKey:@"keywords"] ?: @"";
    self.chineseCheck.state = [d boolForKey:@"chinese"] ? NSControlStateValueOn : NSControlStateValueOff;
    if ([d objectForKey:@"rate"]) self.rateSlider.integerValue = MIN(MAX([d integerForKey:@"rate"], ARMinRecognitionRate), ARMaxRecognitionRate);
    [self updateRateLabel];
    if ([d objectForKey:@"style"]) [self.stylePopup selectItemWithTag:[d integerForKey:@"style"]];
    if ([d objectForKey:@"quality"]) [self.qualityPopup selectItemWithTag:[d integerForKey:@"quality"]];
    if ([d objectForKey:@"fps"]) [self.fpsPopup selectItemWithTag:[d integerForKey:@"fps"]];
    if ([d objectForKey:@"cursor"]) self.cursorCheck.state = [d boolForKey:@"cursor"] ? NSControlStateValueOn : NSControlStateValueOff;
    NSString *folder = [d stringForKey:@"folder"];
    if (folder.length) self.folderURL = [NSURL fileURLWithPath:folder isDirectory:YES];
}

- (void)saveSettings {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    [d setInteger:self.modePopup.selectedTag forKey:@"mode"];
    [d setInteger:self.screenPopup.selectedTag forKey:@"display"];
    [d setObject:[self selectedKinds] forKey:@"kinds"];
    [d setObject:self.keywordsField.stringValue forKey:@"keywords"];
    [d setBool:self.chineseCheck.state == NSControlStateValueOn forKey:@"chinese"];
    [d setInteger:self.rateSlider.integerValue forKey:@"rate"];
    [d setInteger:self.stylePopup.selectedTag forKey:@"style"];
    [d setInteger:self.qualityPopup.selectedTag forKey:@"quality"];
    [d setInteger:self.fpsPopup.selectedTag forKey:@"fps"];
    [d setBool:self.cursorCheck.state == NSControlStateValueOn forKey:@"cursor"];
    [d setObject:self.folderURL.path forKey:@"folder"];
}

- (NSArray<NSString *> *)selectedKinds {
    NSMutableArray *kinds = [NSMutableArray array];
    for (NSString *kind in ARKinds()) {
        if (self.kindChecks[kind].state == NSControlStateValueOn) [kinds addObject:kind];
    }
    return kinds;
}

/// 把界面设置交给识别引擎；什么都没选时提示。
- (BOOL)applyDetectionSettings {
    NSArray<NSString *> *kinds = [self selectedKinds];
    NSArray<NSString *> *keywords = ARSplitKeywords(self.keywordsField.stringValue);
    if (!kinds.count || (kinds.count == 1 && [kinds.firstObject isEqualToString:@"keyword"] && !keywords.count)) {
        [self setStatus:@"请至少选择一种打码内容"];
        return NO;
    }
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
    NSScreen *screen = [self selectedScreen];
    double rate = (double)self.rateSlider.integerValue;
    BOOL chinese = self.chineseCheck.state == NSControlStateValueOn;
    self.busy = YES;
    [self updateControls];
    if ([self overlayMode]) {
        self.overlaySession.recognitionsPerSecond = rate;
        self.overlaySession.recognizesChinese = chinese;
        [self.overlaySession startDisplay:ARDisplayID(screen) screenFrame:screen.frame completion:^(NSError *error) {
            [self startedWithError:error];
        }];
    } else {
        self.recordSession.recognitionsPerSecond = rate;
        self.recordSession.recognizesChinese = chinese;
        self.recordSession.style = (ARRedactStyle)self.stylePopup.selectedTag;
        NSDateFormatter *formatter = [NSDateFormatter new];
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        formatter.dateFormat = @"yyyy-MM-dd HH.mm.ss";
        NSURL *url = [self.folderURL URLByAppendingPathComponent:
                      [NSString stringWithFormat:@"打码录屏 %@.mp4", [formatter stringFromDate:[NSDate date]]]];
        [self.recordSession startDisplay:ARDisplayID(screen)
                                maxWidth:self.qualityPopup.selectedTag
                                     fps:self.fpsPopup.selectedTag
                             showsCursor:self.cursorCheck.state == NSControlStateValueOn
                               outputURL:url
                              completion:^(NSError *error) { [self startedWithError:error]; }];
    }
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
        [self setStatus:[NSString stringWithFormat:@"● 录制中 %@ · 当前打码 %lu 处",
                         ARDuration(started ? -started.timeIntervalSinceNow : 0), (unsigned long)self.recordSession.currentCount]];
    } else if (self.overlaySession.running) {
        [self setStatus:[NSString stringWithFormat:@"● 遮挡中 · 当前遮挡 %lu 处", (unsigned long)self.overlaySession.currentCount]];
    }
}

- (void)recordingFinished:(NSURL *)url error:(NSError *)error interrupted:(BOOL)interrupted {
    self.busy = NO;
    [self.timer invalidate];
    self.timer = nil;
    if (url) {
        self.lastRecordingURL = url;
        [self setStatus:[NSString stringWithFormat:@"%@已保存：%@", interrupted ? @"录制被系统中断，" : @"", url.lastPathComponent]];
    } else {
        [self setStatus:[NSString stringWithFormat:@"保存失败：%@", error.localizedDescription ?: @"未知错误"]];
    }
    [self updateControls];
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
    [capture startDisplay:ARDisplayID([self selectedScreen]) maxWidth:0 fps:2 showsCursor:NO
                  prepare:^BOOL(CGSize size, NSError **error) { return YES; }
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
        for (NSString *kind in ARKinds()) {
            if ([kinds countForObject:kind]) [parts addObject:[NSString stringWithFormat:@"%@ %lu", ARKindNames()[kind], (unsigned long)[kinds countForObject:kind]]];
        }
        finish([NSString stringWithFormat:@"当前屏幕发现 %lu 处：%@", (unsigned long)detections.count, [parts componentsJoinedByString:@" · "]]);
    } completion:^(NSError *error) {
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
