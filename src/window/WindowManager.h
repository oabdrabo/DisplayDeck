#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, DDSnap) {
    DDSnapLeftHalf = 0,
    DDSnapRightHalf,
    DDSnapTopHalf,
    DDSnapBottomHalf,
    DDSnapTopLeft,
    DDSnapTopRight,
    DDSnapBottomLeft,
    DDSnapBottomRight,
    DDSnapLeftThird,
    DDSnapCenterThird,
    DDSnapRightThird,
    DDSnapLeftTwoThirds,
    DDSnapRightTwoThirds,
    DDSnapMaximize,
    DDSnapCenter,
    DDSnapRestore,
};

// Tiling/window management for the focused window, via the Accessibility API
// (the same permission Picture-in-Picture uses). Three ways to trigger a snap:
// the menu, global keyboard shortcuts (⌃⌥ + key), and dragging a window to a
// screen edge/corner (with a live preview).
@interface WindowManager : NSObject

+ (instancetype)shared;

- (BOOL)hasAccessibility;
- (void)requestAccessibility;

// Snap the currently-focused window to a layout.
- (void)snap:(DDSnap)layout;

// Global ⌃⌥ keyboard shortcuts (registered system-wide via Carbon hot keys).
- (void)setHotkeysEnabled:(BOOL)enabled;

// Snap-on-drag: drag a window to a screen edge/corner to tile it.
- (void)setDragSnapEnabled:(BOOL)enabled;

@end

NS_ASSUME_NONNULL_END
