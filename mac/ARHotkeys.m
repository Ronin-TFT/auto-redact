#import "ARHotkeys.h"
#import <Carbon/Carbon.h>

@interface ARHotkeys () {
    EventHandlerRef _handlerRef;
    EventHotKeyRef _refs[2];
}
- (void)fire:(UInt32)identifier;
@end

static OSStatus ARHotkeyEventHandler(EventHandlerCallRef next, EventRef event, void *userData) {
    EventHotKeyID hotkeyID;
    if (GetEventParameter(event, kEventParamDirectObject, typeEventHotKeyID, NULL, sizeof(hotkeyID), NULL, &hotkeyID) != noErr) {
        return eventNotHandledErr;
    }
    [(__bridge ARHotkeys *)userData fire:hotkeyID.id];
    return noErr;
}

@implementation ARHotkeys

+ (NSString *)nameForAction:(ARHotkeyAction)action {
    return action == ARHotkeyActionRecord ? @"⌃⌥⌘R" : @"⌃⌥⌘H";
}

- (void)fire:(UInt32)identifier {
    if (self.handler && (identifier == ARHotkeyActionRecord || identifier == ARHotkeyActionOverlay)) {
        self.handler((ARHotkeyAction)identifier);
    }
}

- (NSArray<NSString *> *)registerDefaults {
    [self unregister];
    if (!_handlerRef) {
        EventTypeSpec type = {kEventClassKeyboard, kEventHotKeyPressed};
        InstallEventHandler(GetApplicationEventTarget(), ARHotkeyEventHandler, 1, &type, (__bridge void *)self, &_handlerRef);
    }
    UInt32 modifiers = controlKey | optionKey | cmdKey;
    UInt32 keys[2] = {kVK_ANSI_R, kVK_ANSI_H};
    NSMutableArray<NSString *> *failed = [NSMutableArray array];
    for (UInt32 i = 0; i < 2; i++) {
        EventHotKeyID hotkeyID = {'ARDT', i + 1};
        if (RegisterEventHotKey(keys[i], modifiers, hotkeyID, GetApplicationEventTarget(), 0, &_refs[i]) != noErr) {
            _refs[i] = NULL;
            [failed addObject:[ARHotkeys nameForAction:(ARHotkeyAction)(i + 1)]];
        }
    }
    return failed;
}

- (void)unregister {
    for (int i = 0; i < 2; i++) {
        if (_refs[i]) UnregisterEventHotKey(_refs[i]);
        _refs[i] = NULL;
    }
}

- (void)dealloc {
    [self unregister];
    if (_handlerRef) RemoveEventHandler(_handlerRef);
}

@end
