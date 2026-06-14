#import "ColorTemperature.h"
#include <math.h>

static NSString *const kWarmthKey = @"DDWarmth";
static const double kNeutralKelvin = 6500.0;
static const double kWarmestKelvin = 3400.0;
enum { kRampSize = 256 };

@interface ColorTemperature ()
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSNumber *> *warmths;
@end

@implementation ColorTemperature

+ (instancetype)shared {
    static ColorTemperature *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [[ColorTemperature alloc] init]; });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _warmths = [NSMutableDictionary dictionary];
        NSDictionary *saved = [[NSUserDefaults standardUserDefaults] dictionaryForKey:kWarmthKey];
        for (NSString *key in saved) {
            if ([saved[key] isKindOfClass:[NSNumber class]]) {
                _warmths[@((CGDirectDisplayID)key.longLongValue)] = saved[key];
            }
        }
    }
    return self;
}

static void temperatureGains(double kelvin, double *r, double *g, double *b) {
    double t = kelvin / 100.0, R, G, B;
    if (t <= 66) R = 255; else R = 329.698727446 * pow(t - 60, -0.1332047592);
    if (t <= 66) G = 99.4708025861 * log(t) - 161.1195681661;
    else         G = 288.1221695283 * pow(t - 60, -0.0755148492);
    if (t >= 66) B = 255; else if (t <= 19) B = 0;
    else         B = 138.5177312231 * log(t - 10) - 305.0447927307;
    *r = fmin(255, fmax(0, R)) / 255.0;
    *g = fmin(255, fmax(0, G)) / 255.0;
    *b = fmin(255, fmax(0, B)) / 255.0;
}

- (void)setRampForDisplay:(CGDirectDisplayID)displayID warmth:(float)warmth {
    double kelvin = kNeutralKelvin - warmth * (kNeutralKelvin - kWarmestKelvin);
    double rg, gg, bg;
    temperatureGains(kelvin, &rg, &gg, &bg);
    CGGammaValue r[kRampSize], g[kRampSize], b[kRampSize];
    for (uint32_t i = 0; i < kRampSize; i++) {
        double v = (double)i / (kRampSize - 1);
        r[i] = v * rg;
        g[i] = v * gg;
        b[i] = v * bg;
    }
    CGSetDisplayTransferByTable(displayID, kRampSize, r, g, b);
}

- (float)warmthForDisplay:(CGDirectDisplayID)displayID {
    return [self.warmths[@(displayID)] floatValue];
}

- (void)persist {
    NSMutableDictionary<NSString *, NSNumber *> *out = [NSMutableDictionary dictionary];
    for (NSNumber *key in self.warmths) {
        out[key.stringValue] = self.warmths[key];
    }
    [[NSUserDefaults standardUserDefaults] setObject:out forKey:kWarmthKey];
}

- (void)setWarmth:(float)warmth forDisplay:(CGDirectDisplayID)displayID {
    if (warmth <= 0.001f) {
        [self.warmths removeObjectForKey:@(displayID)];
        [self persist];
        [self reapply];
    } else {
        self.warmths[@(displayID)] = @(warmth);
        [self persist];
        [self setRampForDisplay:displayID warmth:warmth];
    }
}

- (void)reapply {
    CGDisplayRestoreColorSyncSettings();
    for (NSNumber *key in self.warmths) {
        float warmth = [self.warmths[key] floatValue];
        if (warmth > 0.001f) [self setRampForDisplay:key.unsignedIntValue warmth:warmth];
    }
}

- (void)restoreAll {
    CGDisplayRestoreColorSyncSettings();
}

@end
