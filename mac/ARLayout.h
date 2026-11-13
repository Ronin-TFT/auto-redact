// 界面布局辅助函数（自动布局）。
#pragma once
#import <Cocoa/Cocoa.h>

static inline NSTextField *ARLabel(NSString *text, CGFloat size, BOOL bold) {
    NSTextField *label = [NSTextField labelWithString:text];
    label.font = bold ? [NSFont boldSystemFontOfSize:size] : [NSFont systemFontOfSize:size];
    return label;
}

static inline NSTextField *ARField(NSString *text, CGFloat width) {
    NSTextField *field = [NSTextField textFieldWithString:text];
    [field.widthAnchor constraintEqualToConstant:width].active = YES;
    return field;
}

static inline NSStackView *ARRow(NSArray<NSView *> *views, CGFloat spacing) {
    NSStackView *stack = [NSStackView stackViewWithViews:views];
    stack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    stack.alignment = NSLayoutAttributeCenterY;
    stack.spacing = spacing;
    return stack;
}

static inline NSStackView *ARColumn(NSArray<NSView *> *views, CGFloat spacing) {
    NSStackView *stack = [NSStackView stackViewWithViews:views];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.distribution = NSStackViewDistributionFill;
    stack.spacing = spacing;
    return stack;
}

static inline void ARFillWidth(NSStackView *stack, NSArray<NSView *> *views) {
    for (NSView *view in views) [view.widthAnchor constraintEqualToAnchor:stack.widthAnchor].active = YES;
}

static inline void ARPin(NSView *child, NSView *parent, CGFloat inset) {
    child.translatesAutoresizingMaskIntoConstraints = NO;
    [parent addSubview:child];
    [NSLayoutConstraint activateConstraints:@[
        [child.topAnchor constraintEqualToAnchor:parent.topAnchor constant:inset],
        [child.leadingAnchor constraintEqualToAnchor:parent.leadingAnchor constant:inset],
        [child.trailingAnchor constraintEqualToAnchor:parent.trailingAnchor constant:-inset],
        [child.bottomAnchor constraintEqualToAnchor:parent.bottomAnchor constant:-inset],
    ]];
}
