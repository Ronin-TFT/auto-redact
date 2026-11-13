#import "ARReviewController.h"
#import <AVFoundation/AVFoundation.h>
#import <AVKit/AVKit.h>
#import "ARLayout.h"
#import "ARPatchExporter.h"

NSRect ARVideoRectFromViewRect(NSRect r, NSRect vb, CGSize size) {
    NSRect clipped = NSIntersectionRect(r, vb);
    if (NSIsEmptyRect(clipped) || vb.size.width <= 0 || vb.size.height <= 0) return NSZeroRect;
    double sx = size.width / vb.size.width, sy = size.height / vb.size.height;
    return NSMakeRect((clipped.origin.x - vb.origin.x) * sx, (NSMaxY(vb) - NSMaxY(clipped)) * sy,
                      clipped.size.width * sx, clipped.size.height * sy);
}

static NSString *ARTime(double seconds) {
    long t = lround(MAX(0, seconds));
    return [NSString stringWithFormat:@"%ld:%02ld", t / 60, t % 60];
}

/// 盖在播放器上、用于拖拽框选遮挡区域的视图。
@interface ARMaskDrawView : NSView
@property (nonatomic) NSRect selection;
@property (nonatomic) NSPoint anchor;
@property (nonatomic, copy, nullable) void (^changed)(NSRect selection);
@end

@implementation ARMaskDrawView
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }
- (void)resetCursorRects { [self addCursorRect:self.bounds cursor:NSCursor.crosshairCursor]; }
- (void)mouseDown:(NSEvent *)event {
    self.anchor = [self convertPoint:event.locationInWindow fromView:nil];
    self.selection = NSZeroRect;
    [self setNeedsDisplay:YES];
}
- (void)mouseDragged:(NSEvent *)event {
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    self.selection = NSMakeRect(MIN(p.x, self.anchor.x), MIN(p.y, self.anchor.y), fabs(p.x - self.anchor.x), fabs(p.y - self.anchor.y));
    [self setNeedsDisplay:YES];
}
- (void)mouseUp:(NSEvent *)event {
    if (self.changed) self.changed(self.selection);
}
- (void)drawRect:(NSRect)dirtyRect {
    [[NSColor colorWithWhite:0 alpha:0.15] setFill];
    NSRectFill(self.bounds);
    if (!NSIsEmptyRect(self.selection)) {
        [[NSColor colorWithRed:1 green:0.2 blue:0.2 alpha:0.35] setFill];
        NSRectFillUsingOperation(self.selection, NSCompositingOperationSourceOver);
        NSBezierPath *path = [NSBezierPath bezierPathWithRect:self.selection];
        path.lineWidth = 2;
        [NSColor.systemRedColor setStroke];
        [path stroke];
    }
}
@end

@interface ARReviewController ()
@property (nonatomic, strong) NSURL *url;
@property (nonatomic, strong) NSArray<NSDictionary *> *segments;
@property (nonatomic, strong) NSDictionary<NSString *, NSString *> *kindNames;
@property (nonatomic) ARRedactStyle style;
@property (nonatomic) CGSize videoSize;
@property (nonatomic, strong) AVPlayerView *playerView;
@property (nonatomic, strong) ARMaskDrawView *drawView;
@property (nonatomic, strong) NSButton *drawButton;
@property (nonatomic, strong) NSTextField *rangeLabel;
@property (nonatomic, strong) NSTextField *masksLabel;
@property (nonatomic, strong) NSButton *exportButton;
@property (nonatomic, strong) NSProgressIndicator *progress;
@property (nonatomic, strong) NSTextField *statusLabel;
@property (nonatomic) NSRect pendingRect; // 录像像素坐标
@property (nonatomic) double pendingStart;
@property (nonatomic) double pendingEnd;
@property (nonatomic, strong) NSMutableArray<ARManualMask *> *masks;
@end

@implementation ARReviewController

- (instancetype)initWithURL:(NSURL *)url segments:(NSArray<NSDictionary *> *)segments kindNames:(NSDictionary<NSString *, NSString *> *)kindNames
                      style:(ARRedactStyle)style {
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1100, 680)
                                                   styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                                             NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
                                                     backing:NSBackingStoreBuffered defer:NO];
    if ((self = [super initWithWindow:window])) {
        _url = url;
        _segments = segments;
        _kindNames = kindNames;
        _style = style;
        _masks = [NSMutableArray array];
        _pendingStart = _pendingEnd = -1;
        window.title = [@"复查录像 · " stringByAppendingString:url.lastPathComponent];
        window.releasedWhenClosed = NO;
        window.contentMinSize = NSMakeSize(900, 560);
        AVAssetTrack *track = [[AVURLAsset URLAssetWithURL:url options:nil] tracksWithMediaType:AVMediaTypeVideo].firstObject;
        _videoSize = track ? track.naturalSize : CGSizeMake(1920, 1080);
        [self buildUI];
        [window center];
    }
    return self;
}

- (void)buildUI {
    NSView *content = self.window.contentView;
    self.playerView = [AVPlayerView new];
    self.playerView.player = [AVPlayer playerWithURL:self.url];
    self.playerView.controlsStyle = AVPlayerViewControlsStyleInline;
    self.playerView.showsFrameSteppingButtons = YES;
    self.drawView = [ARMaskDrawView new];
    self.drawView.hidden = YES;
    __weak ARReviewController *weakSelf = self;
    self.drawView.changed = ^(NSRect selection) { [weakSelf selectionChanged:selection]; };

    // 右侧：打码片段列表
    NSStackView *segmentList = ARColumn(@[], 4);
    if (!self.segments.count) [segmentList addArrangedSubview:ARLabel(@"这次录制没有识别到需要打码的内容", 12, NO)];
    for (NSUInteger i = 0; i < self.segments.count; i++) {
        NSDictionary *segment = self.segments[i];
        NSString *title = [NSString stringWithFormat:@"%@ – %@  %@", ARTime([segment[@"start"] doubleValue]),
                           ARTime([segment[@"end"] doubleValue] + 1), self.kindNames[segment[@"kind"]] ?: segment[@"kind"]];
        NSButton *button = [NSButton buttonWithTitle:title target:self action:@selector(jumpToSegment:)];
        button.tag = (NSInteger)i;
        button.bezelStyle = NSBezelStyleRecessed;
        [segmentList addArrangedSubview:button];
    }
    NSScrollView *segmentScroll = [NSScrollView new];
    segmentScroll.hasVerticalScroller = YES;
    segmentScroll.drawsBackground = NO;
    NSView *listHolder = [NSView new];
    ARPin(segmentList, listHolder, 4);
    listHolder.translatesAutoresizingMaskIntoConstraints = NO;
    segmentScroll.documentView = listHolder;
    [listHolder.widthAnchor constraintEqualToAnchor:segmentScroll.contentView.widthAnchor].active = YES;
    [segmentScroll.heightAnchor constraintGreaterThanOrEqualToConstant:160].active = YES;
    [segmentScroll setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationVertical];

    NSTextField *hint = [NSTextField wrappingLabelWithString:
        @"点片段跳到对应位置，用播放器的 ◀︎ ▶︎ 逐帧检查。发现漏遮时：点“框选区域”在画面上拖出范围，播放到开始处点“设为起点”，到结束处点“设为终点”，再点“添加遮挡”。"];
    hint.font = [NSFont systemFontOfSize:12];
    hint.textColor = NSColor.secondaryLabelColor;
    self.drawButton = [NSButton buttonWithTitle:@"框选区域" target:self action:@selector(toggleDraw:)];
    self.rangeLabel = ARLabel(@"尚未设置", 12, NO);
    self.masksLabel = ARLabel(@"手动补充 0 处", 12, NO);
    self.exportButton = [NSButton buttonWithTitle:@"导出修正版" target:self action:@selector(exportPatched:)];
    self.exportButton.enabled = NO;
    self.progress = [NSProgressIndicator new];
    self.progress.style = NSProgressIndicatorStyleBar;
    self.progress.indeterminate = NO;
    self.progress.minValue = 0;
    self.progress.maxValue = 1;
    self.progress.hidden = YES;
    self.statusLabel = [NSTextField wrappingLabelWithString:@""];
    self.statusLabel.font = [NSFont systemFontOfSize:12];

    NSStackView *side = ARColumn(@[
        ARLabel(@"打码片段", 14, YES), segmentScroll,
        ARLabel(@"手动补充遮挡", 14, YES), hint,
        ARRow(@[self.drawButton,
                [NSButton buttonWithTitle:@"设为起点" target:self action:@selector(setStart:)],
                [NSButton buttonWithTitle:@"设为终点" target:self action:@selector(setEnd:)]], 6),
        self.rangeLabel,
        ARRow(@[[NSButton buttonWithTitle:@"添加遮挡" target:self action:@selector(addMask:)],
                [NSButton buttonWithTitle:@"清空" target:self action:@selector(clearMasks:)], self.masksLabel], 6),
        ARRow(@[self.exportButton, [NSButton buttonWithTitle:@"在 Finder 中显示" target:self action:@selector(reveal:)]], 6),
        self.progress, self.statusLabel,
    ], 8);
    ARFillWidth(side, @[segmentScroll, hint, self.progress, self.statusLabel]);

    for (NSView *view in @[self.playerView, self.drawView, side]) {
        view.translatesAutoresizingMaskIntoConstraints = NO;
        [content addSubview:view];
    }
    [NSLayoutConstraint activateConstraints:@[
        [self.playerView.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
        [self.playerView.topAnchor constraintEqualToAnchor:content.topAnchor],
        [self.playerView.bottomAnchor constraintEqualToAnchor:content.bottomAnchor],
        [self.drawView.leadingAnchor constraintEqualToAnchor:self.playerView.leadingAnchor],
        [self.drawView.trailingAnchor constraintEqualToAnchor:self.playerView.trailingAnchor],
        [self.drawView.topAnchor constraintEqualToAnchor:self.playerView.topAnchor],
        [self.drawView.bottomAnchor constraintEqualToAnchor:self.playerView.bottomAnchor],
        [side.leadingAnchor constraintEqualToAnchor:self.playerView.trailingAnchor constant:14],
        [side.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-14],
        [side.topAnchor constraintEqualToAnchor:content.topAnchor constant:14],
        [side.bottomAnchor constraintLessThanOrEqualToAnchor:content.bottomAnchor constant:-14],
        [side.widthAnchor constraintEqualToConstant:300],
    ]];
}

- (double)currentTime {
    return CMTimeGetSeconds(self.playerView.player.currentTime);
}

- (void)jumpToSegment:(NSButton *)sender {
    double start = MAX(0, [self.segments[(NSUInteger)sender.tag][@"start"] doubleValue] - 0.5);
    [self.playerView.player pause];
    [self.playerView.player seekToTime:CMTimeMakeWithSeconds(start, 600) toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero];
}

- (void)toggleDraw:(id)sender {
    self.drawView.hidden = !self.drawView.hidden;
    self.drawButton.title = self.drawView.hidden ? @"框选区域" : @"完成框选";
    if (!self.drawView.hidden) [self.playerView.player pause];
}

- (void)selectionChanged:(NSRect)selection {
    self.pendingRect = ARVideoRectFromViewRect(selection, self.playerView.videoBounds, self.videoSize);
    [self updateLabels];
}

- (void)setStart:(id)sender {
    self.pendingStart = [self currentTime];
    [self updateLabels];
}

- (void)setEnd:(id)sender {
    self.pendingEnd = [self currentTime];
    [self updateLabels];
}

- (void)updateLabels {
    NSString *area = NSIsEmptyRect(self.pendingRect) ? @"未框选区域"
                                                    : [NSString stringWithFormat:@"区域 %.0f×%.0f", self.pendingRect.size.width, self.pendingRect.size.height];
    NSString *start = self.pendingStart >= 0 ? ARTime(self.pendingStart) : @"未设起点";
    NSString *end = self.pendingEnd >= 0 ? ARTime(self.pendingEnd) : @"未设终点";
    self.rangeLabel.stringValue = [NSString stringWithFormat:@"%@ · %@ – %@", area, start, end];
    self.masksLabel.stringValue = [NSString stringWithFormat:@"手动补充 %lu 处", (unsigned long)self.masks.count];
    self.exportButton.enabled = self.masks.count > 0;
}

- (void)addMask:(id)sender {
    if (NSIsEmptyRect(self.pendingRect) || self.pendingStart < 0 || self.pendingEnd < 0) {
        self.statusLabel.stringValue = @"请先框选区域并设置起点和终点";
        return;
    }
    // 两端各多遮 0.2 秒，避免恰好漏掉边界上的帧。
    [self.masks addObject:[[ARManualMask alloc] initWithRect:NSInsetRect(self.pendingRect, -4, -4)
                                                       start:MAX(0, MIN(self.pendingStart, self.pendingEnd) - 0.2)
                                                         end:MAX(self.pendingStart, self.pendingEnd) + 0.2]];
    self.pendingRect = NSZeroRect;
    self.pendingStart = self.pendingEnd = -1;
    self.drawView.selection = NSZeroRect;
    [self.drawView setNeedsDisplay:YES];
    self.statusLabel.stringValue = @"已添加，可继续添加或导出修正版";
    [self updateLabels];
}

- (void)clearMasks:(id)sender {
    [self.masks removeAllObjects];
    [self updateLabels];
}

- (void)exportPatched:(id)sender {
    NSString *name = [[self.url.lastPathComponent stringByDeletingPathExtension] stringByAppendingString:@" 修正版.mp4"];
    NSURL *destination = [self.url.URLByDeletingLastPathComponent URLByAppendingPathComponent:name];
    self.exportButton.enabled = NO;
    self.progress.hidden = NO;
    self.progress.doubleValue = 0;
    self.statusLabel.stringValue = @"正在导出…";
    [ARPatchExporter exportURL:self.url to:destination masks:[self.masks copy] style:self.style
                      progress:^(double fraction) { self.progress.doubleValue = fraction; }
                    completion:^(NSError *error) {
        self.progress.hidden = YES;
        self.exportButton.enabled = self.masks.count > 0;
        if (error) {
            self.statusLabel.stringValue = [@"导出失败：" stringByAppendingString:error.localizedDescription];
            return;
        }
        self.statusLabel.stringValue = [@"已导出：" stringByAppendingString:name];
        [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[destination]];
    }];
}

- (void)reveal:(id)sender {
    [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[self.url]];
}

@end
