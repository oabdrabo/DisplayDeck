#import "WindowManager.h"
#import <Cocoa/Cocoa.h>
#import <ApplicationServices/ApplicationServices.h>
#import <Carbon/Carbon.h>

// Threshold (px) from a screen edge for drag-snap to engage, and the band near a
// corner within which an edge becomes a quarter rather than a half.
static const CGFloat kEdgeThreshold = 14.0;
static const CGFloat kCornerBand    = 140.0;

#pragma mark - Accessibility window helpers (AX uses global, top-left/Y-down coords)

static AXUIElementRef copyFocusedWindow(pid_t *outPid) {
    AXUIElementRef sys = AXUIElementCreateSystemWide();
    if (!sys) return NULL;
    CFTypeRef appRef = NULL;
    AXUIElementCopyAttributeValue(sys, kAXFocusedApplicationAttribute, &appRef);
    CFRelease(sys);
    if (!appRef) return NULL;
    if (outPid) AXUIElementGetPid((AXUIElementRef)appRef, outPid);
    CFTypeRef winRef = NULL;
    AXUIElementCopyAttributeValue((AXUIElementRef)appRef, kAXFocusedWindowAttribute, &winRef);
    CFRelease(appRef);
    return (AXUIElementRef)winRef;
}

static BOOL axGetFrame(AXUIElementRef w, CGRect *out) {
    CFTypeRef pv = NULL, sv = NULL;
    CGPoint p; CGSize s;
    if (AXUIElementCopyAttributeValue(w, kAXPositionAttribute, &pv) != kAXErrorSuccess) return NO;
    if (AXUIElementCopyAttributeValue(w, kAXSizeAttribute, &sv) != kAXErrorSuccess) {
        CFRelease(pv); return NO;
    }
    BOOL ok = AXValueGetValue(pv, kAXValueCGPointType, &p) &&
              AXValueGetValue(sv, kAXValueCGSizeType, &s);
    CFRelease(pv); CFRelease(sv);
    if (ok) *out = CGRectMake(p.x, p.y, s.width, s.height);
    return ok;
}

static void axSetFrame(AXUIElementRef w, CGRect f) {
    AXValueRef pos = AXValueCreate(kAXValueCGPointType, &f.origin);
    AXValueRef siz = AXValueCreate(kAXValueCGSizeType, &f.size);
    // Order matters and a second position set settles windows that clamp size first.
    AXUIElementSetAttributeValue(w, kAXPositionAttribute, pos);
    AXUIElementSetAttributeValue(w, kAXSizeAttribute, siz);
    AXUIElementSetAttributeValue(w, kAXPositionAttribute, pos);
    CFRelease(pos); CFRelease(siz);
}

// The NSScreen whose CG bounds contain a global (top-left) point.
static NSScreen *screenForCGPoint(CGPoint p) {
    for (NSScreen *s in [NSScreen screens]) {
        CGDirectDisplayID did = [s.deviceDescription[@"NSScreenNumber"] unsignedIntValue];
        if (CGRectContainsPoint(CGDisplayBounds(did), p)) return s;
    }
    return [NSScreen mainScreen];
}

// Visible frame (minus menu bar / Dock) in CG global top-left coords.
static CGRect visibleFrameCG(NSScreen *s) {
    CGDirectDisplayID did = [s.deviceDescription[@"NSScreenNumber"] unsignedIntValue];
    CGRect full = CGDisplayBounds(did);
    NSRect fc = s.frame, vc = s.visibleFrame;       // Cocoa, bottom-left
    CGFloat left   = vc.origin.x - fc.origin.x;
    CGFloat right  = NSMaxX(fc) - NSMaxX(vc);
    CGFloat top    = NSMaxY(fc) - NSMaxY(vc);        // menu bar (Cocoa top == CG top)
    CGFloat bottom = vc.origin.y - fc.origin.y;      // Dock at bottom
    return CGRectMake(full.origin.x + left,
                      full.origin.y + top,
                      full.size.width  - left - right,
                      full.size.height - top - bottom);
}

static CGRect rectForLayout(DDSnap l, CGRect v, CGRect cur) {
    CGFloat x = v.origin.x, y = v.origin.y, w = v.size.width, h = v.size.height;
    switch (l) {
        case DDSnapLeftHalf:      return CGRectMake(x,           y,         w/2, h);
        case DDSnapRightHalf:     return CGRectMake(x + w/2,     y,         w/2, h);
        case DDSnapTopHalf:       return CGRectMake(x,           y,         w,   h/2);
        case DDSnapBottomHalf:    return CGRectMake(x,           y + h/2,   w,   h/2);
        case DDSnapTopLeft:       return CGRectMake(x,           y,         w/2, h/2);
        case DDSnapTopRight:      return CGRectMake(x + w/2,     y,         w/2, h/2);
        case DDSnapBottomLeft:    return CGRectMake(x,           y + h/2,   w/2, h/2);
        case DDSnapBottomRight:   return CGRectMake(x + w/2,     y + h/2,   w/2, h/2);
        case DDSnapLeftThird:     return CGRectMake(x,           y,         w/3, h);
        case DDSnapCenterThird:   return CGRectMake(x + w/3,     y,         w/3, h);
        case DDSnapRightThird:    return CGRectMake(x + 2*w/3,   y,         w/3, h);
        case DDSnapLeftTwoThirds: return CGRectMake(x,           y,       2*w/3, h);
        case DDSnapRightTwoThirds:return CGRectMake(x + w/3,     y,       2*w/3, h);
        case DDSnapMaximize:      return v;
        case DDSnapCenter:        return CGRectMake(x + (w - cur.size.width)/2,
                                                    y + (h - cur.size.height)/2,
                                                    cur.size.width, cur.size.height);
        case DDSnapRestore:       return cur;  // handled by caller
    }
    return v;
}

#pragma mark - Coordinate conversion (Cocoa bottom-left <-> CG top-left)

static CGFloat primaryHeight(void) {
    NSArray<NSScreen *> *screens = [NSScreen screens];
    return screens.count ? NSMaxY(screens[0].frame) : 0;
}
static CGPoint cocoaToCG(NSPoint p) { return CGPointMake(p.x, primaryHeight() - p.y); }
static NSRect cgToCocoaRect(CGRect r) {
    return NSMakeRect(r.origin.x, primaryHeight() - (r.origin.y + r.size.height),
                      r.size.width, r.size.height);
}

#pragma mark - Hotkey table

#define DD_HOTKEY_COUNT 16
typedef struct { UInt32 key; DDSnap layout; } DDHotkey;
static const DDHotkey kHotkeys[] = {
    { kVK_LeftArrow,  DDSnapLeftHalf },   { kVK_RightArrow, DDSnapRightHalf },
    { kVK_UpArrow,    DDSnapTopHalf },    { kVK_DownArrow,  DDSnapBottomHalf },
    { kVK_Return,     DDSnapMaximize },   { kVK_ANSI_C,     DDSnapCenter },
    { kVK_ANSI_U,     DDSnapTopLeft },    { kVK_ANSI_I,     DDSnapTopRight },
    { kVK_ANSI_J,     DDSnapBottomLeft }, { kVK_ANSI_K,     DDSnapBottomRight },
    { kVK_ANSI_D,     DDSnapLeftThird },  { kVK_ANSI_F,     DDSnapCenterThird },
    { kVK_ANSI_G,     DDSnapRightThird }, { kVK_ANSI_E,     DDSnapLeftTwoThirds },
    { kVK_ANSI_T,     DDSnapRightTwoThirds }, { kVK_ANSI_Z,  DDSnapRestore },
};
static const size_t kHotkeyCount = sizeof(kHotkeys) / sizeof(*kHotkeys);
_Static_assert(sizeof(kHotkeys) / sizeof(*kHotkeys) == DD_HOTKEY_COUNT, "hotkey count mismatch");

static OSStatus HotKeyHandler(EventHandlerCallRef next, EventRef e, void *ud);

@interface WindowManager () {
    EventHotKeyRef _hotkeyRefs[DD_HOTKEY_COUNT];
    EventHandlerRef _handler;
    BOOL _hotkeysOn;
    BOOL _dragOn;
}
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSValue *> *restoreFrames; // pid -> frame
@property (nonatomic) id dragMon;
@property (nonatomic) id upMon;
@property (nonatomic) id downMon;
@property (nonatomic) BOOL dragging;
@property (nonatomic) pid_t dragPid;
@property (nonatomic) DDSnap pendingLayout;
@property (nonatomic) BOOL hasPending;
@property (nonatomic, strong) NSWindow *preview;
@end

@implementation WindowManager

+ (instancetype)shared {
    static WindowManager *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [[WindowManager alloc] init]; });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) _restoreFrames = [NSMutableDictionary dictionary];
    return self;
}

- (BOOL)hasAccessibility { return AXIsProcessTrusted(); }

- (void)requestAccessibility {
    NSDictionary *opts = @{(__bridge NSString *)kAXTrustedCheckOptionPrompt: @YES};
    AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)opts);
}

#pragma mark - Snapping

- (void)snap:(DDSnap)layout {
    if (![self hasAccessibility]) { [self requestAccessibility]; return; }
    pid_t pid = 0;
    AXUIElementRef w = copyFocusedWindow(&pid);
    if (!w) return;
    [self applyLayout:layout toWindow:w pid:pid];
    CFRelease(w);
}

- (void)applyLayout:(DDSnap)layout toWindow:(AXUIElementRef)w pid:(pid_t)pid {
    CGRect cur;
    if (!axGetFrame(w, &cur) || cur.size.width < 1) return;

    CGRect target;
    if (layout == DDSnapRestore) {
        NSValue *saved = self.restoreFrames[@(pid)];
        if (!saved) return;
        target = saved.rectValue;
        [self.restoreFrames removeObjectForKey:@(pid)];
    } else {
        CGPoint center = CGPointMake(CGRectGetMidX(cur), CGRectGetMidY(cur));
        CGRect v = visibleFrameCG(screenForCGPoint(center));
        target = rectForLayout(layout, v, cur);
        // Skip no-ops (already at the target) so a double-trigger — e.g. the menu
        // shortcut firing alongside the global hot key while the menu is open —
        // doesn't overwrite the saved frame with the already-snapped one. Otherwise
        // remember where it was so ⌃⌥Z / "Restore" can undo this snap.
        BOOL noop = fabs(cur.origin.x - target.origin.x) < 2 &&
                    fabs(cur.origin.y - target.origin.y) < 2 &&
                    fabs(cur.size.width  - target.size.width)  < 2 &&
                    fabs(cur.size.height - target.size.height) < 2;
        if (noop) return;
        self.restoreFrames[@(pid)] = [NSValue valueWithRect:cur];
    }
    axSetFrame(w, target);
}

#pragma mark - Global hotkeys (Carbon)

- (void)setHotkeysEnabled:(BOOL)enabled {
    if (enabled == _hotkeysOn) return;
    _hotkeysOn = enabled;
    if (enabled) {
        if (!_handler) {
            EventTypeSpec spec = { kEventClassKeyboard, kEventHotKeyPressed };
            InstallApplicationEventHandler(&HotKeyHandler, 1, &spec,
                                           (__bridge void *)self, &_handler);
        }
        UInt32 mods = controlKey | optionKey;
        for (size_t i = 0; i < kHotkeyCount; i++) {
            EventHotKeyID hkid = { .signature = 'DDwm', .id = (UInt32)i };
            RegisterEventHotKey(kHotkeys[i].key, mods, hkid,
                                GetApplicationEventTarget(), 0, &_hotkeyRefs[i]);
        }
    } else {
        for (size_t i = 0; i < kHotkeyCount; i++) {
            if (_hotkeyRefs[i]) { UnregisterEventHotKey(_hotkeyRefs[i]); _hotkeyRefs[i] = NULL; }
        }
    }
}

- (void)fireHotkeyIndex:(UInt32)i {
    if (i < kHotkeyCount) [self snap:kHotkeys[i].layout];
}

#pragma mark - Snap on drag

- (void)setDragSnapEnabled:(BOOL)enabled {
    if (enabled == _dragOn) return;
    _dragOn = enabled;
    if (enabled) {
        __weak __typeof(self) ws = self;
        self.downMon = [NSEvent addGlobalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown
                                                              handler:^(NSEvent *e){ (void)e; [ws onMouseDown]; }];
        self.dragMon = [NSEvent addGlobalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDragged
                                                              handler:^(NSEvent *e){ (void)e; [ws onMouseDragged]; }];
        self.upMon   = [NSEvent addGlobalMonitorForEventsMatchingMask:NSEventMaskLeftMouseUp
                                                              handler:^(NSEvent *e){ (void)e; [ws onMouseUp]; }];
    } else {
        if (self.downMon) { [NSEvent removeMonitor:self.downMon]; self.downMon = nil; }
        if (self.dragMon) { [NSEvent removeMonitor:self.dragMon]; self.dragMon = nil; }
        if (self.upMon)   { [NSEvent removeMonitor:self.upMon];   self.upMon = nil; }
        [self hidePreview];
        self.dragging = NO;
    }
}

// Arm only when the press lands in the focused window's titlebar band — avoids
// snapping on text selection or content drags.
- (void)onMouseDown {
    self.dragging = NO;
    self.hasPending = NO;
    if (![self hasAccessibility]) return;
    pid_t pid = 0;
    AXUIElementRef w = copyFocusedWindow(&pid);
    if (!w) return;
    CGRect f;
    if (axGetFrame(w, &f)) {
        CGPoint m = cocoaToCG([NSEvent mouseLocation]);
        CGRect titlebar = CGRectMake(f.origin.x, f.origin.y, f.size.width, 32);
        if (CGRectContainsPoint(titlebar, m)) { self.dragging = YES; self.dragPid = pid; }
    }
    CFRelease(w);
}

- (void)onMouseDragged {
    if (!self.dragging) return;
    CGPoint m = cocoaToCG([NSEvent mouseLocation]);
    NSScreen *scr = screenForCGPoint(m);
    CGDirectDisplayID did = [scr.deviceDescription[@"NSScreenNumber"] unsignedIntValue];
    CGRect b = CGDisplayBounds(did);

    BOOL nearL = (m.x - CGRectGetMinX(b)) < kEdgeThreshold;
    BOOL nearR = (CGRectGetMaxX(b) - m.x) < kEdgeThreshold;
    BOOL nearT = (m.y - CGRectGetMinY(b)) < kEdgeThreshold;
    BOOL nearB = (CGRectGetMaxY(b) - m.y) < kEdgeThreshold;
    BOOL topBand = (m.y - CGRectGetMinY(b)) < kCornerBand;
    BOOL botBand = (CGRectGetMaxY(b) - m.y) < kCornerBand;

    DDSnap layout = DDSnapMaximize; BOOL has = YES;
    if (nearL)      layout = topBand ? DDSnapTopLeft  : (botBand ? DDSnapBottomLeft  : DDSnapLeftHalf);
    else if (nearR) layout = topBand ? DDSnapTopRight : (botBand ? DDSnapBottomRight : DDSnapRightHalf);
    else if (nearT) layout = DDSnapMaximize;
    else if (nearB) layout = DDSnapBottomHalf;
    else            has = NO;

    self.hasPending = has;
    self.pendingLayout = layout;
    if (has) [self showPreviewRect:rectForLayout(layout, visibleFrameCG(scr), CGRectZero)];
    else     [self hidePreview];
}

- (void)onMouseUp {
    BOOL act = self.dragging && self.hasPending;
    DDSnap layout = self.pendingLayout;
    pid_t pid = self.dragPid;
    self.dragging = NO;
    self.hasPending = NO;
    [self hidePreview];
    if (!act) return;
    // Apply to the window that was being dragged.
    AXUIElementRef w = copyFocusedWindow(NULL);
    if (w) { [self applyLayout:layout toWindow:w pid:pid]; CFRelease(w); }
}

#pragma mark - Drag preview overlay

- (void)showPreviewRect:(CGRect)cgRect {
    if (!self.preview) {
        NSWindow *p = [[NSWindow alloc] initWithContentRect:NSZeroRect
                                                  styleMask:NSWindowStyleMaskBorderless
                                                    backing:NSBackingStoreBuffered
                                                      defer:NO];
        p.level = NSStatusWindowLevel;
        p.opaque = NO;
        p.backgroundColor = [NSColor clearColor];
        p.ignoresMouseEvents = YES;
        p.hasShadow = NO;
        p.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                               NSWindowCollectionBehaviorStationary |
                               NSWindowCollectionBehaviorIgnoresCycle;
        NSView *v = [[NSView alloc] initWithFrame:NSZeroRect];
        v.wantsLayer = YES;
        v.layer.backgroundColor = [[NSColor systemBlueColor] colorWithAlphaComponent:0.22].CGColor;
        v.layer.borderColor = [[NSColor systemBlueColor] colorWithAlphaComponent:0.9].CGColor;
        v.layer.borderWidth = 2.0;
        v.layer.cornerRadius = 10.0;
        p.contentView = v;
        self.preview = p;
    }
    [self.preview setFrame:cgToCocoaRect(cgRect) display:YES];
    [self.preview orderFrontRegardless];
}

- (void)hidePreview { [self.preview orderOut:nil]; }

@end

static OSStatus HotKeyHandler(EventHandlerCallRef next, EventRef e, void *ud) {
    (void)next;
    EventHotKeyID hk;
    if (GetEventParameter(e, kEventParamDirectObject, typeEventHotKeyID, NULL,
                          sizeof hk, NULL, &hk) != noErr) return eventNotHandledErr;
    WindowManager *self = (__bridge WindowManager *)ud;
    UInt32 idx = hk.id;
    dispatch_async(dispatch_get_main_queue(), ^{ [self fireHotkeyIndex:idx]; });
    return noErr;
}
