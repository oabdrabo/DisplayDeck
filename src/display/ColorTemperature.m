#import "ColorTemperature.h"
#include <math.h>

static NSString *const kWarmthKey = @"DDWarmth";
static NSString *const kAutoKey   = @"DDWarmthAuto";
static const double kNeutralKelvin = 6500.0;
static const double kWarmestKelvin = 3400.0;
static const float  kDefaultNightWarmth = 0.5f;   // used when auto is on and no value set
enum { kRampSize = 256 };

// Night intensity 0 (neutral/day) … 1 (full warm). Time-based (no location):
// full warmth 20:00–06:00, with 1-hour linear transitions at dusk and dawn.
static float nightRamp(void) {
    NSDateComponents *c = [[NSCalendar currentCalendar]
        components:NSCalendarUnitHour | NSCalendarUnitMinute fromDate:[NSDate date]];
    double h = c.hour + c.minute / 60.0;
    if (h >= 20.0 || h < 6.0)       return 1.0f;
    if (h >= 18.0 && h < 20.0)      return (float)((h - 18.0) / 2.0);   // dusk ramp up
    if (h >= 6.0  && h < 8.0)       return (float)(1.0 - (h - 6.0) / 2.0); // dawn ramp down
    return 0.0f;
}

@interface ColorTemperature ()
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSNumber *> *warmths;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic) float lastRamp;
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
        _lastRamp = -1.0f;
        NSDictionary *saved = [[NSUserDefaults standardUserDefaults] dictionaryForKey:kWarmthKey];
        for (NSString *key in saved) {
            if ([saved[key] isKindOfClass:[NSNumber class]]) {
                _warmths[@((CGDirectDisplayID)key.longLongValue)] = saved[key];
            }
        }
        // Re-evaluate the night schedule each minute while auto is on.
        _timer = [NSTimer scheduledTimerWithTimeInterval:60 target:self
                    selector:@selector(tick) userInfo:nil repeats:YES];
    }
    return self;
}

- (void)tick {
    if (!self.autoEnabled) return;
    float r = nightRamp();
    if (fabsf(r - self.lastRamp) < 0.005f) return;   // nothing changed → no flicker
    self.lastRamp = r;
    [self reapply];
}

- (BOOL)autoEnabled {
    NSNumber *v = [[NSUserDefaults standardUserDefaults] objectForKey:kAutoKey];
    return v ? v.boolValue : YES;   // default ON — warms automatically at night
}

- (void)setAutoEnabled:(BOOL)autoEnabled {
    [[NSUserDefaults standardUserDefaults] setBool:autoEnabled forKey:kAutoKey];
    self.lastRamp = -1.0f;
    [self reapply];
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

// The night target for a display: the value the user set, else a sensible default
// so auto-warmth does something out of the box.
- (float)nightTargetForDisplay:(CGDirectDisplayID)displayID {
    NSNumber *e = self.warmths[@(displayID)];
    return e ? e.floatValue : kDefaultNightWarmth;
}

// Slider value: the explicit setting, or (when auto is on) the default night target.
- (float)warmthForDisplay:(CGDirectDisplayID)displayID {
    NSNumber *e = self.warmths[@(displayID)];
    if (e) return e.floatValue;
    return self.autoEnabled ? kDefaultNightWarmth : 0.0f;
}

- (void)persist {
    NSMutableDictionary<NSString *, NSNumber *> *out = [NSMutableDictionary dictionary];
    for (NSNumber *key in self.warmths) out[key.stringValue] = self.warmths[key];
    [[NSUserDefaults standardUserDefaults] setObject:out forKey:kWarmthKey];
}

- (void)setWarmth:(float)warmth forDisplay:(CGDirectDisplayID)displayID {
    if (warmth <= 0.001f) [self.warmths removeObjectForKey:@(displayID)];
    else                  self.warmths[@(displayID)] = @(warmth);
    [self persist];
    self.lastRamp = -1.0f;
    [self reapply];
}

static NSArray<NSNumber *> *activeDisplays(void) {
    CGDirectDisplayID ids[16];
    uint32_t n = 0;
    if (CGGetActiveDisplayList(16, ids, &n) != kCGErrorSuccess) return @[];
    NSMutableArray<NSNumber *> *out = [NSMutableArray arrayWithCapacity:n];
    for (uint32_t i = 0; i < n; i++) [out addObject:@(ids[i])];
    return out;
}

- (void)reapply {
    CGDisplayRestoreColorSyncSettings();
    if (self.autoEnabled) {
        float ramp = nightRamp();
        self.lastRamp = ramp;
        if (ramp <= 0.001f) return;   // daytime → neutral
        for (NSNumber *d in activeDisplays()) {
            float applied = [self nightTargetForDisplay:d.unsignedIntValue] * ramp;
            if (applied > 0.001f) [self setRampForDisplay:d.unsignedIntValue warmth:applied];
        }
    } else {
        for (NSNumber *key in self.warmths) {
            float w = self.warmths[key].floatValue;
            if (w > 0.001f) [self setRampForDisplay:key.unsignedIntValue warmth:w];
        }
    }
}

- (void)restoreAll {
    CGDisplayRestoreColorSyncSettings();
}

@end
