#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

@interface ColorTemperature : NSObject

+ (instancetype)shared;

// Auto-warm at night (Night Shift style, schedule-based). On by default.
@property (nonatomic) BOOL autoEnabled;

- (float)warmthForDisplay:(CGDirectDisplayID)displayID;
- (void)setWarmth:(float)warmth forDisplay:(CGDirectDisplayID)displayID;
- (void)reapply;
- (void)restoreAll;

@end

NS_ASSUME_NONNULL_END
