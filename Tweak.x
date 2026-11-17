#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <AudioToolbox/AudioToolbox.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <signal.h>
#import <dlfcn.h>
#import <math.h>
#import "CSRingV2.h"

#define CS_DOMAIN CFSTR("com.vn.circleswitcher")
#define CS_LOGFILE @"/var/mobile/Documents/CircleSwitcher.log"
#define CS_TEST_NOTE CFSTR("com.vn.circleswitcher/test")
#define CS_RESPRING_NOTE CFSTR("com.vn.circleswitcher/respring")
#define CS_RELOAD_NOTE CFSTR("com.vn.circleswitcher/reload")

#pragma mark - High-DPI Asset Loader (@3x / @2x Rootless + Rootful)

static UIImage *csLoadAsset(NSString *baseName, BOOL templateMode) {
    static NSMutableDictionary<NSString *, UIImage *> *cache;
    if (!cache) cache = [NSMutableDictionary new];
    NSString *cacheKey = [NSString stringWithFormat:@"%@_%d", baseName, templateMode];
    UIImage *hit = cache[cacheKey];
    if (hit) return hit;

    NSArray<NSString *> *dirs = @[
        @"/var/jb/Library/Application Support/CircleSwitcher",
        @"/Library/Application Support/CircleSwitcher"
    ];
    NSArray<NSString *> *suffixes = @[@"@3x.png", @"@2x.png", @".png"];
    NSArray<NSNumber *> *scales = @[@3.0, @2.0, @1.0];

    UIImage *loaded = nil;
    for (NSString *dir in dirs) {
        for (NSUInteger i = 0; i < suffixes.count; i++) {
            NSString *full = [dir stringByAppendingPathComponent:[baseName stringByAppendingString:suffixes[i]]];
            UIImage *raw = [UIImage imageWithContentsOfFile:full];
            if (raw && raw.CGImage) {
                loaded = [UIImage imageWithCGImage:raw.CGImage scale:scales[i].doubleValue orientation:UIImageOrientationUp];
                break;
            }
        }
        if (loaded) break;
    }
    if (loaded) {
        if (templateMode) {
            loaded = [loaded imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
        }
        cache[cacheKey] = loaded;
    }
    return loaded;
}

#pragma mark - Zero-Allocation CGPath Cache

static CGPathRef csCachedRoundedPath(CGFloat w, CGFloat h, CGFloat cr) {
    static NSMutableDictionary<NSString *, id> *pathCache;
    if (!pathCache) pathCache = [NSMutableDictionary new];
    int qw = (int)llround(w * 2.0);
    int qh = (int)llround(h * 2.0);
    int qr = (int)llround(cr * 2.0);
    NSString *key = [NSString stringWithFormat:@"%d_%d_%d", qw, qh, qr];
    id existing = pathCache[key];
    if (existing) return (__bridge CGPathRef)existing;

    if (pathCache.count > 260) [pathCache removeAllObjects];
    UIBezierPath *bp = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, qw / 2.0, qh / 2.0) cornerRadius:qr / 2.0];
    CGPathRef cg = bp.CGPath;
    if (cg) pathCache[key] = (__bridge id)cg;
    return cg;
}

#pragma mark - Preferences

static BOOL prefBool(CFStringRef key, BOOL def) {
    CFPropertyListRef v = CFPreferencesCopyAppValue(key, CS_DOMAIN);
    if (!v) return def;
    BOOL r = def;
    if (CFGetTypeID(v) == CFBooleanGetTypeID()) r = CFBooleanGetValue(v);
    else if (CFGetTypeID(v) == CFNumberGetTypeID()) { int n = 0; CFNumberGetValue(v, kCFNumberIntType, &n); r = (n != 0); }
    CFRelease(v);
    return r;
}

static double prefDouble(CFStringRef key, double def) {
    CFPropertyListRef v = CFPreferencesCopyAppValue(key, CS_DOMAIN);
    if (!v) return def;
    double r = def;
    if (CFGetTypeID(v) == CFNumberGetTypeID()) CFNumberGetValue(v, kCFNumberDoubleType, &r);
    CFRelease(v);
    return r;
}

typedef struct {
    BOOL enabled, icon, onlyFront, nameIcon, ram, inertia, haptic, dots, bubOn, keepPinned, debug;
    BOOL ringGlow, namePill, snapCircle, chevron, crispText, motionBlurOn;
    BOOL glassOverlay, velTilt;
    int count, namePos, mode, style;
    double radius, tilt, cam, blur, size, off, bubSize;
    double iconSize, centerSize, dim, bgBlur, glowHue;
    double gap, cardCorner, glowAmt, moveBlur, openSpeed, springStiffness;
    BOOL openAnim;
} CSCfg;
static CSCfg C;

static void loadCfg(void) {
    CFPreferencesAppSynchronize(CS_DOMAIN);
    C.enabled = prefBool(CFSTR("enabled"), YES);
    C.mode = (int)prefDouble(CFSTR("mode"), 0);
    if (C.mode < 0 || C.mode > 3) C.mode = 0;
    C.icon = prefBool(CFSTR("icon"), YES);
    C.onlyFront = prefBool(CFSTR("onlyFront"), NO);
    C.nameIcon = prefBool(CFSTR("nameIcon"), YES);
    C.ram = prefBool(CFSTR("ram"), NO);
    C.inertia = prefBool(CFSTR("inertia"), YES);
    C.haptic = prefBool(CFSTR("haptic"), YES);
    C.dots = prefBool(CFSTR("dots"), YES);
    C.bubOn = prefBool(CFSTR("bubOn"), YES);
    C.keepPinned = prefBool(CFSTR("keepPinned"), YES);
    C.debug = prefBool(CFSTR("debug"), NO);
    C.crispText = prefBool(CFSTR("crispText"), YES);
    C.motionBlurOn = prefBool(CFSTR("motionBlurOn"), YES);
    C.glassOverlay = prefBool(CFSTR("glassOverlay"), YES);
    C.velTilt = prefBool(CFSTR("velTilt"), YES);
    C.count = (int)lround(prefDouble(CFSTR("count"), 8));
    if (C.count < 3) C.count = 3;
    if (C.count > 12) C.count = 12;
    C.namePos = (int)prefDouble(CFSTR("namePos"), 2);
    C.radius = prefDouble(CFSTR("radius"), 125);
    C.tilt = prefDouble(CFSTR("tilt"), 32);
    C.cam = prefDouble(CFSTR("cam"), 22);
    C.blur = prefDouble(CFSTR("blur"), 1.5);
    C.size = prefDouble(CFSTR("size"), 100);
    C.off = prefDouble(CFSTR("off"), 0);
    C.bubSize = prefDouble(CFSTR("bubSize"), 56);
    C.style = (int)prefDouble(CFSTR("style"), 1);
    if (C.style < 0 || C.style > 3) C.style = 1;
    C.ringGlow = prefBool(CFSTR("ringGlow"), YES);
    C.namePill = prefBool(CFSTR("namePill"), YES);
    C.snapCircle = prefBool(CFSTR("snapCircle"), YES);
    C.chevron = prefBool(CFSTR("chevron"), YES);
    C.iconSize = prefDouble(CFSTR("iconSize"), 100);
    C.centerSize = prefDouble(CFSTR("centerSize"), 100);
    C.dim = prefDouble(CFSTR("dim"), 35);
    C.bgBlur = prefDouble(CFSTR("bgBlur"), 10);
    C.glowHue = prefDouble(CFSTR("glowHue"), 215);
    C.gap = prefDouble(CFSTR("gap"), 100);
    C.cardCorner = prefDouble(CFSTR("cardCorner"), 28);
    C.glowAmt = prefDouble(CFSTR("glowAmt"), 75);
    C.moveBlur = prefDouble(CFSTR("moveBlur"), 4.2);
    C.openSpeed = prefDouble(CFSTR("openSpeed"), 100);
    C.springStiffness = prefDouble(CFSTR("springStiffness"), 100);
    C.openAnim = prefBool(CFSTR("openAnim"), YES);
}

static CSRingCfg csCfgWithBank(double velBankRad) {
    CSRingCfg c;
    c.radius = C.radius; c.tilt = C.tilt; c.cam = C.cam; c.size = C.size; c.off = C.off; c.count = C.count;
    c.style = C.style; c.iconSize = C.iconSize; c.centerSize = C.centerSize; c.gap = C.gap;
    c.velBank = C.velTilt ? velBankRad : 0.0;
    return c;
}

static NSArray<NSString *> *pinList(void) {
    CFPropertyListRef v = CFPreferencesCopyAppValue(CFSTR("pins"), CS_DOMAIN);
    NSArray *a = (__bridge_transfer NSArray *)v;
    return [a isKindOfClass:NSArray.class] ? a : @[];
}
static void setPinList(NSArray<NSString *> *a) {
    CFPreferencesSetAppValue(CFSTR("pins"), (__bridge CFPropertyListRef)a, CS_DOMAIN);
    CFPreferencesAppSynchronize(CS_DOMAIN);
}

#pragma mark - Logging

static NSMutableArray<NSString *> *csLines;

static void csLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void csLog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *m = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    if (!C.debug) return;
    NSLog(@"[CircleSwitcher] %@", m);
    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], m];
    @synchronized (csLines) {
        [csLines addObject:line];
        if (csLines.count > 400) [csLines removeObjectsInRange:NSMakeRange(0, 100)];
    }
    @try {
        NSFileManager *fm = NSFileManager.defaultManager;
        if (![fm fileExistsAtPath:CS_LOGFILE]) [fm createFileAtPath:CS_LOGFILE contents:nil attributes:nil];
        if ([[fm attributesOfItemAtPath:CS_LOGFILE error:nil] fileSize] > 400 * 1024) [@"" writeToFile:CS_LOGFILE atomically:YES encoding:NSUTF8StringEncoding error:nil];
        NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:CS_LOGFILE];
        [h seekToEndOfFile];
        [h writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [h closeFile];
    } @catch (NSException *e) {}
}

#pragma mark - Runtime & High-FPS DisplayLink (Zero available-macro)

static id send0(id o, NSString *s) {
    SEL sel = NSSelectorFromString(s);
    if (o && [o respondsToSelector:sel]) return ((id (*)(id, SEL))objc_msgSend)(o, sel);
    return nil;
}
static id send1(id o, NSString *s, id a) {
    SEL sel = NSSelectorFromString(s);
    if (o && [o respondsToSelector:sel]) return ((id (*)(id, SEL, id))objc_msgSend)(o, sel, a);
    return nil;
}
static double clampd(double v, double a, double b) { return v < a ? a : (v > b ? b : v); }
static double normDeg(double a) { a = fmod(a + 180.0, 360.0); if (a < 0) a += 360.0; return a - 180.0; }
static double wrap360(double a) { a = fmod(a, 360.0); if (a < 0) a += 360.0; return a; }

static inline CGFloat csScreenScale(void) {
    static CGFloat sc = 0;
    if (sc <= 0) sc = MAX(1.0, UIScreen.mainScreen.scale);
    return sc;
}

static inline CGFloat csSnapPx(CGFloat v) {
    CGFloat sc = csScreenScale();
    return round(v * sc) / sc;
}

static inline CGPoint csSnapPoint(CGPoint p) {
    return CGPointMake(csSnapPx(p.x), csSnapPx(p.y));
}

// ABI-compatible HFA struct matching CAFrameRateRange without triggering ___isOSVersionAtLeast
typedef struct {
    float minimum;
    float maximum;
    float preferred;
} CSFrameRateRange;

static void csConfigureHighFPSLink(CADisplayLink *link) {
    if (!link) return;
    SEL sel = NSSelectorFromString(@"setPreferredFrameRateRange:");
    if ([link respondsToSelector:sel]) {
        CSFrameRateRange range = {60.0f, 120.0f, 120.0f};
        ((void (*)(id, SEL, CSFrameRateRange))objc_msgSend)(link, sel, range);
    }
}

#pragma mark - App Info

@interface CSItem : NSObject
@property (nonatomic, copy) NSString *bid, *name;
@property (nonatomic, strong) UIImage *icon;
@property (nonatomic, strong) UIColor *color;
@property (nonatomic, assign) int pid;
@property (nonatomic, assign) double ram;
@property (nonatomic, assign) BOOL pinned;
@end
@implementation CSItem
@end

static id mainSwitcher(void) {
    return send0((id)NSClassFromString(@"SBMainSwitcherViewController"), @"sharedInstance");
}

static id sbApp(NSString *bid) {
    id ac = send0((id)NSClassFromString(@"SBApplicationController"), @"sharedInstance");
    return send1(ac, @"applicationWithBundleIdentifier:", bid);
}

static NSString *appName(NSString *bid) {
    NSString *n = send0(sbApp(bid), @"displayName");
    if ([n isKindOfClass:NSString.class] && n.length) return n;
    id px = send1((id)NSClassFromString(@"LSApplicationProxy"), @"applicationProxyForIdentifier:", bid);
    n = send0(px, @"localizedName");
    if ([n isKindOfClass:NSString.class] && n.length) return n;
    return bid.pathExtension.length ? bid.pathExtension : bid;
}

static UIImage *appIcon(NSString *bid) {
    Class k = UIImage.class;
    SEL s = NSSelectorFromString(@"_applicationIconImageForBundleIdentifier:format:scale:");
    if ([k respondsToSelector:s]) {
        @try { return ((id (*)(id, SEL, id, int, double))objc_msgSend)(k, s, bid, 2, csScreenScale()); } @catch (NSException *e) {}
    }
    return nil;
}

static int appPid(NSString *bid) {
    id a = sbApp(bid);
    if (!a) return 0;
    @try {
        id ps = send0(a, @"processState");
        if (ps) {
            SEL pidSel = NSSelectorFromString(@"pid");
            if ([ps respondsToSelector:pidSel]) {
                int p = ((int (*)(id, SEL))objc_msgSend)(ps, pidSel);
                if (p > 1) return p;
            }
            id pv = [ps valueForKey:@"pid"];
            if (pv && [pv intValue] > 1) return [pv intValue];
        }
    } @catch (NSException *e) {}
    @try {
        id p = [a valueForKey:@"pid"];
        if (p && [p intValue] > 1) return [p intValue];
    } @catch (NSException *e) {}
    return 0;
}

extern int proc_pid_rusage(int pid, int flavor, void *buffer);
static double ramMB(int pid) {
    if (pid <= 1) return 0;
    uint64_t buf[64];
    memset(buf, 0, sizeof(buf));
    if (proc_pid_rusage(pid, 2, buf) != 0) return 0;
    uint64_t fp = buf[2 + 7];
    return (double)fp / (1024.0 * 1024.0);
}

static UIColor *shade(UIColor *c, CGFloat f) {
    CGFloat r = 0, g = 0, b = 0, a = 0;
    if (![c getRed:&r green:&g blue:&b alpha:&a]) return c;
    return [UIColor colorWithRed:MIN(1, r * f) green:MIN(1, g * f) blue:MIN(1, b * f) alpha:1];
}

static UIColor *avgColor(UIImage *img) {
    if (!img.CGImage) return nil;
    uint8_t px[4] = {0, 0, 0, 0};
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef c = CGBitmapContextCreate(px, 1, 1, 8, 4, cs, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    if (!c) { CGColorSpaceRelease(cs); return nil; }
    CGContextSetInterpolationQuality(c, kCGInterpolationMedium);
    CGContextDrawImage(c, CGRectMake(0, 0, 1, 1), img.CGImage);
    CGContextRelease(c); CGColorSpaceRelease(cs);
    return [UIColor colorWithRed:px[0] / 255.0 green:px[1] / 255.0 blue:px[2] / 255.0 alpha:1];
}

static UIColor *hashColor(NSString *s) {
    NSUInteger h = 5381;
    for (NSUInteger i = 0; i < s.length; i++) h = h * 33 + [s characterAtIndex:i];
    return [UIColor colorWithHue:(h % 360) / 360.0 saturation:0.55 brightness:0.62 alpha:1];
}

static NSMutableDictionary<NSString *, CSItem *> *itemCache;

static CSItem *itemFor(NSString *bid) {
    CSItem *it = itemCache[bid];
    if (!it) {
        it = [CSItem new];
        it.bid = bid;
        it.name = appName(bid);
        it.icon = appIcon(bid);
        UIColor *c = avgColor(it.icon);
        it.color = c ?: hashColor(bid);
        itemCache[bid] = it;
    }
    it.pid = appPid(bid);
    it.ram = C.ram ? ramMB(it.pid) : 0;
    return it;
}

static BOOL csIsUserFacing(NSString *b) {
    if (!b.length) return NO;
    for (NSString *bad in @[@"PosterBoard", @"Spotlight", @"ViewService", @"Service", @"Extension", @"springboard", @"SpringBoard", @"Siri", @"CarPlay", @"InCall", @"AccessibilityUIServer", @"PreBoard", @"ShareSheet", @"RemoteViewService", @"WebContent"])
        if ([b rangeOfString:bad].location != NSNotFound) return NO;
    return YES;
}

static NSArray *csFetchRawLayouts(void) {
    id ms = mainSwitcher();
    NSArray *layouts = send0(ms, @"recentAppLayouts");
    if (![layouts isKindOfClass:NSArray.class] || !layouts.count)
        layouts = send0(send0((id)NSClassFromString(@"SBRecentAppLayouts"), @"sharedInstance"), @"recents");
    if (![layouts isKindOfClass:NSArray.class] || !layouts.count)
        layouts = send0(ms, @"appLayouts");
    if (![layouts isKindOfClass:NSArray.class] || !layouts.count) {
        @try {
            for (UIViewController *cvc in [(UIViewController *)ms childViewControllers]) {
                NSArray *al = send0(cvc, @"appLayouts");
                if ([al isKindOfClass:NSArray.class] && al.count) { layouts = al; break; }
            }
        } @catch (NSException *e) {}
    }
    return [layouts isKindOfClass:NSArray.class] ? layouts : @[];
}

static NSArray<NSString *> *recentBundleIDs(void) {
    NSMutableArray *out = [NSMutableArray array];
    @try {
        NSArray *layouts = csFetchRawLayouts();
        for (id lay in layouts) {
            NSArray *items = send0(lay, @"allItems");
            if (![items isKindOfClass:NSArray.class]) continue;
            for (id it in items) {
                NSString *b = send0(it, @"bundleIdentifier");
                if ([b isKindOfClass:NSString.class] && b.length && ![out containsObject:b]) [out addObject:b];
            }
        }
        if (!out.count) {
            id ac = send0((id)NSClassFromString(@"SBApplicationController"), @"sharedInstance");
            NSArray *run = send0(ac, @"runningApplications");
            if ([run isKindOfClass:NSArray.class]) {
                for (id app in run) {
                    NSString *b = send0(app, @"bundleIdentifier");
                    if ([b isKindOfClass:NSString.class] && b.length && ![out containsObject:b]) [out addObject:b];
                }
            }
        }
    } @catch (NSException *e) { csLog(@"recents exception: %@", e); }
    [out removeObject:@"com.apple.springboard"];
    NSMutableArray *clean = [NSMutableArray array];
    for (NSString *b in out) if (csIsUserFacing(b)) [clean addObject:b];
    return clean;
}

static void csRemoveLayoutForBundleID(NSString *bid) {
    if (!bid.length) return;
    @try {
        NSArray *layouts = [csFetchRawLayouts() copy];
        id ral = send0((id)NSClassFromString(@"SBRecentAppLayouts"), @"sharedInstance");
        id ms = mainSwitcher();
        for (id lay in layouts) {
            NSArray *items = send0(lay, @"allItems");
            BOOL match = NO;
            if ([items isKindOfClass:NSArray.class]) {
                for (id it in items) {
                    NSString *b = send0(it, @"bundleIdentifier");
                    if ([b isEqualToString:bid]) { match = YES; break; }
                }
            }
            if (!match) continue;
            for (id target in @[ral ?: NSNull.null, ms ?: NSNull.null]) {
                if (target == NSNull.null) continue;
                for (NSString *selName in @[@"remove:", @"removeAppLayout:", @"_deleteAppLayout:"]) {
                    SEL s = NSSelectorFromString(selName);
                    if ([target respondsToSelector:s]) {
                        @try { ((void (*)(id, SEL, id))objc_msgSend)(target, s, lay); } @catch (NSException *e) {}
                    }
                }
            }
        }
    } @catch (NSException *e) {}
}

static BOOL killApp(NSString *bid) {
    int pid = appPid(bid);
    BOOL killed = NO;
    if (pid > 1) {
        int r = kill(pid, SIGKILL);
        csLog(@"kill %@ pid=%d -> %d", bid, pid, r);
        killed = (r == 0);
    }
    csRemoveLayoutForBundleID(bid);
    return killed || (pid <= 1);
}

static void openApp(NSString *bid) {
    csLog(@"open %@", bid);
    @try {
        id ws = send0((id)NSClassFromString(@"LSApplicationWorkspace"), @"defaultWorkspace");
        SEL s = NSSelectorFromString(@"openApplicationWithBundleID:");
        if (ws && [ws respondsToSelector:s]) { ((BOOL (*)(id, SEL, id))objc_msgSend)(ws, s, bid); return; }
        id sb = UIApplication.sharedApplication;
        SEL l = NSSelectorFromString(@"launchApplicationWithIdentifier:suspended:");
        if ([sb respondsToSelector:l]) ((BOOL (*)(id, SEL, id, BOOL))objc_msgSend)(sb, l, bid, NO);
    } @catch (NSException *e) { csLog(@"open exception: %@", e); }
    id ms = mainSwitcher();
    for (NSString *n in @[@"dismissSwitcherNoninteractively", @"dismissSwitcherNoninteractivelyWithSource:"]) {
        SEL s = NSSelectorFromString(n);
        if ([ms respondsToSelector:s]) {
            @try { if ([n hasSuffix:@":"]) ((void (*)(id, SEL, long long))objc_msgSend)(ms, s, 0); else ((void (*)(id, SEL))objc_msgSend)(ms, s); } @catch (NSException *e) {}
            break;
        }
    }
}

#pragma mark - Card & Label Views (with @3x Glass Rim & Halo Assets)

@interface CSLabel : UILabel
@end
@implementation CSLabel
- (instancetype)initWithFrame:(CGRect)f {
    if ((self = [super initWithFrame:f])) {
        self.contentScaleFactor = csScreenScale();
        self.layer.contentsScale = csScreenScale();
        self.layer.shouldRasterize = NO;
    }
    return self;
}
- (void)drawTextInRect:(CGRect)r { [super drawTextInRect:UIEdgeInsetsInsetRect(r, UIEdgeInsetsMake(4, 14, 4, 14))]; }
- (CGSize)sizeThatFits:(CGSize)size {
    CGSize s = [super sizeThatFits:size];
    return CGSizeMake(ceil(s.width + 28), ceil(s.height + 8));
}
@end

static NSAttributedString *labelFor(CSItem *it) {
    NSMutableAttributedString *as = [NSMutableAttributedString new];
    UIFont *f = [UIFont systemFontOfSize:(C.namePill ? 13 : 16) weight:UIFontWeightSemibold];
    NSDictionary *at = @{NSFontAttributeName: f, NSForegroundColorAttributeName: UIColor.whiteColor};
    if (C.nameIcon && it.icon) {
        NSTextAttachment *ta = [NSTextAttachment new];
        ta.image = it.icon; ta.bounds = CGRectMake(0, -3, 15, 15);
        [as appendAttributedString:[NSAttributedString attributedStringWithAttachment:ta]];
        [as appendAttributedString:[[NSAttributedString alloc] initWithString:@"  " attributes:at]];
    }
    [as appendAttributedString:[[NSAttributedString alloc] initWithString:(it.name ?: it.bid) attributes:at]];
    if (it.pinned) {
        UIImage *pin = [[UIImage systemImageNamed:@"pin.fill"] imageWithTintColor:UIColor.whiteColor renderingMode:UIImageRenderingModeAlwaysOriginal];
        if (pin) {
            NSTextAttachment *ta = [NSTextAttachment new];
            ta.image = pin; ta.bounds = CGRectMake(0, -1, 10, 11);
            [as appendAttributedString:[[NSAttributedString alloc] initWithString:@" " attributes:at]];
            [as appendAttributedString:[NSAttributedString attributedStringWithAttachment:ta]];
        }
    }
    if (C.ram && it.ram > 0) {
        [as appendAttributedString:[[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@"  %d MB", (int)it.ram]
            attributes:@{NSFontAttributeName: [UIFont systemFontOfSize:11], NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:0.75]}]];
    }
    return as;
}

@interface CSCard : UIView
@property (nonatomic, strong) UIView *front, *back;
@property (nonatomic, strong) CAGradientLayer *grad;
@property (nonatomic, strong) UIImageView *icon, *icon2, *glassRimView, *haloView;
@property (nonatomic, strong) id blurFilter;
@property (nonatomic, assign) double lastBlurRadius;
@property (nonatomic, assign) CGRect hit;
@property (nonatomic, assign) CGFloat zv;
@property (nonatomic, assign) BOOL circle, neon;
- (void)configure:(CSItem *)it showIcon:(BOOL)on;
- (void)setBlur:(double)r;
- (void)setGlow:(double)k;
@end

@implementation CSCard
- (instancetype)initWithFrame:(CGRect)f {
    if ((self = [super initWithFrame:f])) {
        self.layer.contentsScale = csScreenScale();
        self.layer.shouldRasterize = NO;
        _lastBlurRadius = -1;

        _haloView = [UIImageView new];
        _haloView.image = csLoadAsset(@"orb_halo", YES);
        _haloView.contentMode = UIViewContentModeScaleToFill;
        _haloView.userInteractionEnabled = NO;
        [self addSubview:_haloView];

        _front = [UIView new];
        _front.layer.cornerRadius = 18; _front.layer.masksToBounds = YES;
        _front.layer.borderWidth = 0.5; _front.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.25].CGColor;
        _grad = [CAGradientLayer layer];
        [_front.layer addSublayer:_grad];
        _icon = [UIImageView new]; _icon.contentMode = UIViewContentModeScaleAspectFit; _icon.layer.cornerRadius = 12; _icon.clipsToBounds = YES;
        [_front addSubview:_icon];

        _glassRimView = [UIImageView new];
        _glassRimView.image = csLoadAsset(@"glass_rim", NO);
        _glassRimView.contentMode = UIViewContentModeScaleToFill;
        _glassRimView.userInteractionEnabled = NO;
        [_front addSubview:_glassRimView];

        _back = [UIView new];
        _back.backgroundColor = [UIColor colorWithWhite:0.14 alpha:1];
        _back.layer.cornerRadius = 18; _back.layer.masksToBounds = YES;
        _back.layer.borderWidth = 0.5; _back.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.2].CGColor;
        _icon2 = [UIImageView new]; _icon2.contentMode = UIViewContentModeScaleAspectFit; _icon2.alpha = 0.35;
        [_back addSubview:_icon2];
        [self addSubview:_front]; [self addSubview:_back];
        _back.hidden = YES;
    }
    return self;
}
- (void)configure:(CSItem *)it showIcon:(BOOL)on {
    UIColor *c = it.color ?: [UIColor darkGrayColor];
    self.grad.colors = @[(id)shade(c, 1.15).CGColor, (id)shade(c, 0.55).CGColor];
    self.grad.startPoint = CGPointMake(0.5, 0); self.grad.endPoint = CGPointMake(0.5, 1);
    self.icon.image = it.icon; self.icon.hidden = !(on && it.icon);
    self.icon2.image = it.icon; self.icon2.hidden = !(on && it.icon);
}
- (void)layoutSubviews {
    [super layoutSubviews];
    self.front.frame = self.bounds; self.back.frame = self.bounds;
    self.grad.frame = self.bounds;
    self.glassRimView.frame = self.front.bounds;
    self.haloView.frame = CGRectInset(self.bounds, -self.bounds.size.width * 0.22, -self.bounds.size.height * 0.22);

    CGFloat bw = self.bounds.size.width;
    CGFloat s = bw * (self.circle ? 0.62 : 0.56);
    self.icon.frame = CGRectMake((bw - s) / 2, (self.bounds.size.height - s) / 2, s, s);
    self.icon2.frame = self.icon.frame;
    CGFloat cr = self.circle ? bw / 2 : (self.neon ? C.cardCorner : 18);
    self.front.layer.cornerRadius = cr; self.back.layer.cornerRadius = cr;
    self.icon.layer.cornerRadius = self.circle ? s * 0.225 : 12;
    self.front.layer.borderWidth = self.circle ? 1.5 : (self.neon ? 2.0 : 0.5);
    UIColor *nb = [UIColor colorWithHue:fmod(C.glowHue, 360.0) / 360.0 saturation:0.45 brightness:1 alpha:0.9];
    self.front.layer.borderColor = (self.neon ? nb : [UIColor colorWithWhite:1 alpha:self.circle ? 0.55 : 0.25]).CGColor;
    self.glassRimView.hidden = !(self.circle && C.glassOverlay && self.glassRimView.image);
}
- (void)setGlow:(double)k {
    UIColor *g = [UIColor colorWithHue:fmod(C.glowHue, 360.0) / 360.0 saturation:0.55 brightness:1 alpha:1];
    if (self.circle && C.ringGlow && self.haloView.image) {
        self.haloView.hidden = NO;
        self.haloView.tintColor = g;
        self.haloView.alpha = (CGFloat)((0.22 + 0.72 * k) * (C.glowAmt / 100.0));
    } else {
        self.haloView.hidden = YES;
    }
    if ((!self.circle && !self.neon) || !C.ringGlow) { self.layer.shadowOpacity = 0; return; }
    self.layer.shadowColor = g.CGColor; self.layer.shadowOffset = CGSizeZero;
    self.layer.shadowRadius = 8 + 10 * k; self.layer.shadowOpacity = (float)((0.20 + 0.55 * k) * (self.neon ? C.glowAmt / 100.0 : 0.8));
}
- (void)setBlur:(double)r {
    @try {
        if (fabs(r - self.lastBlurRadius) < 0.08) return;
        self.lastBlurRadius = r;
        if (r < 0.15) { if (self.layer.filters) self.layer.filters = nil; return; }
        if (!self.blurFilter) self.blurFilter = send1((id)NSClassFromString(@"CAFilter"), @"filterWithType:", @"gaussianBlur");
        if (!self.blurFilter) return;
        [self.blurFilter setValue:@(r) forKey:@"inputRadius"];
        self.layer.filters = @[self.blurFilter];
    } @catch (NSException *e) {}
}
@end

#pragma mark - Bubbles and Window

@class CSOverlay;
static CSOverlay *csOverlay;
static UIWindow *csWin;
static UIViewController *csRoot;
static NSMutableArray *csBubbles;

@interface CSPassWindow : UIWindow
@end
@implementation CSPassWindow
- (UIView *)hitTest:(CGPoint)p withEvent:(UIEvent *)e {
    UIView *v = [super hitTest:p withEvent:e];
    if (v == self || v == self.rootViewController.view) return nil;
    return v;
}
@end

static UIWindow *ensureWindow(void) {
    if (csWin) return csWin;
    @try {
        UIWindowScene *sc = nil;
        for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
            if ([s isKindOfClass:UIWindowScene.class]) { sc = (UIWindowScene *)s; break; }
        }
        csWin = sc ? [[CSPassWindow alloc] initWithWindowScene:sc] : [[CSPassWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
        csWin.frame = UIScreen.mainScreen.bounds;
        csWin.windowLevel = 100000;
        csWin.backgroundColor = UIColor.clearColor;
        csRoot = [UIViewController new];
        csRoot.view.backgroundColor = UIColor.clearColor;
        csWin.rootViewController = csRoot;
        csWin.hidden = NO;
        csLog(@"window created (scene=%d)", sc != nil);
    } @catch (NSException *e) { csLog(@"window exception: %@", e); csWin = nil; }
    return csWin;
}

@interface CSBubble : UIView
@property (nonatomic, strong) CSItem *item;
@end
static UIView *csTrash;
static void csRemoveBubble(CSBubble *b);

@implementation CSBubble
- (instancetype)initWithItem:(CSItem *)it {
    CGFloat s = C.bubSize;
    if ((self = [super initWithFrame:CGRectMake(0, 0, s, s)])) {
        _item = it;
        self.backgroundColor = it.color ?: UIColor.darkGrayColor;
        self.layer.cornerRadius = s / 2;
        self.layer.borderWidth = 1.5; self.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.6].CGColor;
        self.layer.shadowColor = UIColor.blackColor.CGColor; self.layer.shadowOpacity = 0.35; self.layer.shadowRadius = 6; self.layer.shadowOffset = CGSizeMake(0, 3);
        UIImageView *iv = [[UIImageView alloc] initWithFrame:CGRectInset(self.bounds, s * 0.2, s * 0.2)];
        iv.contentMode = UIViewContentModeScaleAspectFit; iv.layer.cornerRadius = 8; iv.clipsToBounds = YES;
        iv.image = it.icon;
        if (!it.icon || !C.icon) {
            UILabel *l = [[UILabel alloc] initWithFrame:self.bounds];
            NSString *nm = it.name.length ? it.name : (it.bid.length ? it.bid : @"?");
            l.text = [nm substringWithRange:[nm rangeOfComposedCharacterSequenceAtIndex:0]];
            l.textAlignment = NSTextAlignmentCenter;
            l.textColor = UIColor.whiteColor; l.font = [UIFont boldSystemFontOfSize:s * 0.45];
            [self addSubview:l];
        } else [self addSubview:iv];

        UIImage *rim = csLoadAsset(@"glass_rim", NO);
        if (rim) {
            UIImageView *rv = [[UIImageView alloc] initWithFrame:self.bounds];
            rv.image = rim;
            rv.userInteractionEnabled = NO;
            [self addSubview:rv];
        }

        [self addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onPan:)]];
        [self addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onTap:)]];
    }
    return self;
}
- (void)onTap:(UITapGestureRecognizer *)g {
    NSString *bid = self.item.bid;
    csRemoveBubble(self);
    openApp(bid);
}
- (void)onPan:(UIPanGestureRecognizer *)g {
    UIView *host = self.superview;
    if (!host) return;
    CGSize sz = host.bounds.size;
    if (g.state == UIGestureRecognizerStateBegan) {
        if (!csTrash) {
            csTrash = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 64, 64)];
            csTrash.layer.cornerRadius = 32; csTrash.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.8];
            UIImageView *x = [[UIImageView alloc] initWithImage:[[UIImage systemImageNamed:@"xmark"] imageWithTintColor:UIColor.whiteColor renderingMode:UIImageRenderingModeAlwaysOriginal]];
            x.frame = CGRectMake(20, 20, 24, 24); x.contentMode = UIViewContentModeScaleAspectFit; [csTrash addSubview:x];
        }
        csTrash.center = CGPointMake(sz.width / 2, sz.height - 90); csTrash.alpha = 0;
        [host addSubview:csTrash]; [host bringSubviewToFront:self];
        [UIView animateWithDuration:0.2 animations:^{ csTrash.alpha = 1; }];
    }
    CGPoint t = [g translationInView:host];
    self.center = CGPointMake(self.center.x + t.x, self.center.y + t.y);
    [g setTranslation:CGPointZero inView:host];
    BOOL near = hypot(self.center.x - csTrash.center.x, self.center.y - csTrash.center.y) < 60;
    csTrash.transform = near ? CGAffineTransformMakeScale(1.25, 1.25) : CGAffineTransformIdentity;
    if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled) {
        [csTrash removeFromSuperview]; csTrash.transform = CGAffineTransformIdentity;
        if (near) { csRemoveBubble(self); return; }
        CGFloat s = C.bubSize;
        CGFloat x = self.center.x < sz.width / 2 ? s / 2 + 8 : sz.width - s / 2 - 8;
        CGFloat y = clampd(self.center.y, 80, sz.height - 160);
        [UIView animateWithDuration:0.3 delay:0 usingSpringWithDamping:0.8 initialSpringVelocity:0 options:0 animations:^{ self.center = CGPointMake(x, y); } completion:nil];
    }
}
@end

static void csRemoveBubble(CSBubble *b) {
    [csBubbles removeObject:b];
    [UIView animateWithDuration:0.2 animations:^{ b.alpha = 0; b.transform = CGAffineTransformMakeScale(0.3, 0.3); } completion:^(BOOL f) { [b removeFromSuperview]; }];
}

static NSSet<NSString *> *csBubbleIDs(void) {
    NSMutableSet *s = [NSMutableSet set];
    for (CSBubble *b in csBubbles) if (b.item.bid) [s addObject:b.item.bid];
    return s;
}

static void csAddBubble(CSItem *it, CGPoint from) {
    if (!ensureWindow()) return;
    if (!csBubbles) csBubbles = [NSMutableArray array];
    CSBubble *b = [[CSBubble alloc] initWithItem:it];
    b.center = from; b.transform = CGAffineTransformMakeScale(0.6, 0.6);
    [csRoot.view addSubview:b];
    [csBubbles addObject:b];
    CGSize sz = csRoot.view.bounds.size;
    CGFloat y = 130 + (csBubbles.count - 1) * (C.bubSize + 12);
    [UIView animateWithDuration:0.4 delay:0 usingSpringWithDamping:0.75 initialSpringVelocity:0 options:0 animations:^{
        b.transform = CGAffineTransformIdentity; b.center = CGPointMake(sz.width - C.bubSize / 2 - 8, y);
    } completion:nil];
    csLog(@"bubble added: %@", it.bid);
}

#pragma mark - Overlay (Mode 2 with Damped Spring Engine & Backdrop Asset)

@interface CSOverlay : UIView <UIGestureRecognizerDelegate>
@property (nonatomic, strong) UIVisualEffectView *blurBg;
@property (nonatomic, strong) UIImageView *backdropAssetView;
@property (nonatomic, strong) UIView *ring, *labelHost, *dotsView, *bubble;
@property (nonatomic, strong) UIImageView *bubbleIcon, *chev;
@property (nonatomic, strong) CAShapeLayer *glowRing;
@property (nonatomic, strong) NSMutableArray<CSCard *> *cards;
@property (nonatomic, strong) NSMutableArray<CSLabel *> *labels;
@property (nonatomic, strong) NSMutableArray<CSItem *> *items;
@property (nonatomic, strong) UIButton *xBtn, *cleanBtn, *exitBtn;
@property (nonatomic, strong) UILabel *emptyLabel, *toastLabel;
@property (nonatomic, assign) double rot, vel, dragY, lastRot, smoothBank;
@property (nonatomic, assign) CSSpring1D rotSpring, dragSpring;
@property (nonatomic, assign) int anim;
@property (nonatomic, assign) NSInteger front, panMode;
@property (nonatomic, copy) NSString *prevBID, *startBID;
@property (nonatomic, strong) CADisplayLink *link;
@property (nonatomic, strong) NSDate *armX, *armClean, *lastBgTap, *lastTouch;
@property (nonatomic, assign) BOOL testMode;
@property (nonatomic, assign) CGPoint panStart, panAccum;
@property (nonatomic, strong) UIImpactFeedbackGenerator *hapticGen;
- (void)reloadItems;
- (void)relayout;
- (void)relayoutRing;
- (void)relayoutCards;
- (void)stopLink;
- (BOOL)userRecentlyTouched:(NSTimeInterval)sec;
@end

static void csHideOverlay(void);
static BOOL csForceHidden;

@implementation CSOverlay

- (instancetype)initWithFrame:(CGRect)f {
    if ((self = [super initWithFrame:f])) {
        _cards = [NSMutableArray array]; _labels = [NSMutableArray array]; _items = [NSMutableArray array];
        _front = -2; _lastTouch = [NSDate date];
        self.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

        _blurBg = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark]];
        _blurBg.frame = self.bounds; _blurBg.autoresizingMask = self.autoresizingMask;
        [self addSubview:_blurBg];

        _backdropAssetView = [[UIImageView alloc] initWithFrame:self.bounds];
        _backdropAssetView.autoresizingMask = self.autoresizingMask;
        _backdropAssetView.image = csLoadAsset(@"ambient_backdrop", NO);
        _backdropAssetView.contentMode = UIViewContentModeScaleToFill;
        _backdropAssetView.userInteractionEnabled = NO;
        [self addSubview:_backdropAssetView];

        _glowRing = [CAShapeLayer layer];
        _glowRing.fillColor = nil; _glowRing.lineWidth = 4.5; _glowRing.hidden = YES;
        [self.layer addSublayer:_glowRing];

        _bubble = [UIView new]; _bubble.userInteractionEnabled = NO; _bubble.hidden = YES;
        _bubble.backgroundColor = [UIColor colorWithRed:0.12 green:0.2 blue:0.5 alpha:0.45];
        _bubble.layer.borderWidth = 1.5; _bubble.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.45].CGColor;
        _bubble.layer.shadowColor = [UIColor colorWithRed:0.4 green:0.5 blue:1 alpha:1].CGColor;
        _bubble.layer.shadowOpacity = 0.7; _bubble.layer.shadowRadius = 16; _bubble.layer.shadowOffset = CGSizeZero;
        _bubbleIcon = [UIImageView new]; _bubbleIcon.contentMode = UIViewContentModeScaleAspectFit; _bubbleIcon.clipsToBounds = YES;
        [_bubble addSubview:_bubbleIcon]; [self addSubview:_bubble];

        _chev = [[UIImageView alloc] initWithImage:[[UIImage systemImageNamed:@"chevron.compact.up" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:30 weight:UIImageSymbolWeightMedium]] imageWithTintColor:[UIColor colorWithWhite:1 alpha:0.75] renderingMode:UIImageRenderingModeAlwaysOriginal]];
        _chev.hidden = YES; _chev.userInteractionEnabled = NO; [self addSubview:_chev];

        _ring = [UIView new]; _ring.userInteractionEnabled = NO; [self addSubview:_ring];
        _labelHost = [UIView new]; _labelHost.userInteractionEnabled = NO; _labelHost.frame = self.bounds; _labelHost.autoresizingMask = self.autoresizingMask;
        [self addSubview:_labelHost];
        _dotsView = [UIView new]; _dotsView.userInteractionEnabled = NO; [self addSubview:_dotsView];

        _emptyLabel = [UILabel new]; _emptyLabel.text = @"Không có app nào đang mở";
        _emptyLabel.textColor = [UIColor colorWithWhite:1 alpha:0.7]; _emptyLabel.font = [UIFont systemFontOfSize:15];
        _emptyLabel.textAlignment = NSTextAlignmentCenter; _emptyLabel.hidden = YES; [self addSubview:_emptyLabel];

        _toastLabel = [CSLabel new]; _toastLabel.font = [UIFont systemFontOfSize:13]; _toastLabel.textColor = UIColor.whiteColor;
        _toastLabel.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.9]; _toastLabel.layer.cornerRadius = 13; _toastLabel.layer.masksToBounds = YES;
        _toastLabel.alpha = 0; [self addSubview:_toastLabel];

        _xBtn = [self roundButton:@"xmark" action:@selector(onCloseAll)];
        _cleanBtn = [self roundButton:@"memorychip" action:@selector(onClean)];
        for (UIButton *gb in @[_xBtn, _cleanBtn]) {
            gb.backgroundColor = [UIColor colorWithWhite:1 alpha:0.12];
            gb.layer.borderWidth = 1; gb.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.28].CGColor;
        }
        _exitBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        [_exitBtn setTitle:@"Thoát thử" forState:UIControlStateNormal];
        _exitBtn.tintColor = UIColor.whiteColor; _exitBtn.backgroundColor = [UIColor colorWithWhite:0.15 alpha:0.9];
        _exitBtn.layer.cornerRadius = 15; _exitBtn.hidden = YES;
        [_exitBtn addTarget:self action:@selector(onExit) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:_exitBtn];

        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onPan:)];
        pan.delegate = self; [self addGestureRecognizer:pan];
        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onTap:)];
        tap.delegate = self; [self addGestureRecognizer:tap];
        UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(onLong:)];
        lp.minimumPressDuration = 0.45; lp.delegate = self; [self addGestureRecognizer:lp];
        UILongPressGestureRecognizer *esc = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(onEscape:)];
        esc.minimumPressDuration = 1.6; esc.allowableMovement = 30; esc.delegate = self; [self addGestureRecognizer:esc];
    }
    return self;
}

- (void)dealloc { [self stopLink]; }

- (UIButton *)roundButton:(NSString *)sym action:(SEL)a {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.frame = CGRectMake(0, 0, 46, 46); b.layer.cornerRadius = 23;
    b.backgroundColor = [UIColor colorWithWhite:0.15 alpha:0.9]; b.tintColor = UIColor.whiteColor;
    UIImage *im = [UIImage systemImageNamed:sym withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:20]];
    if (im) [b setImage:im forState:UIControlStateNormal]; else [b setTitle:@"X" forState:UIControlStateNormal];
    [b addTarget:self action:a forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:b];
    return b;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g shouldReceiveTouch:(UITouch *)t { return ![t.view isKindOfClass:UIControl.class]; }
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)o { return YES; }

- (void)touchedNow { self.lastTouch = [NSDate date]; }
- (BOOL)userRecentlyTouched:(NSTimeInterval)sec { return -[self.lastTouch timeIntervalSinceNow] < sec; }

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat W = self.bounds.size.width, H = self.bounds.size.height;
    if (C.style <= 1) {
        self.xBtn.bounds = CGRectMake(0, 0, 170, 46);
        self.xBtn.center = CGPointMake(W / 2, H - 92);
        self.cleanBtn.center = CGPointMake(W / 2 - 124, H - 92);
    } else {
        self.xBtn.bounds = CGRectMake(0, 0, 46, 46);
        self.xBtn.center = CGPointMake(W / 2, H - 70);
        self.cleanBtn.center = CGPointMake(W / 2 - 80, H - 70);
    }
    self.emptyLabel.frame = CGRectMake(0, H * 0.44, W, 24);
    self.exitBtn.frame = CGRectMake(16, 56, 92, 30);
    [self relayout];
}

- (double)step { return self.items.count ? 360.0 / self.items.count : 360.0; }
- (NSString *)frontBID { return (self.front >= 0 && self.front < (NSInteger)self.items.count) ? self.items[self.front].bid : nil; }

- (void)toast:(NSString *)t {
    self.toastLabel.text = t; [self.toastLabel sizeToFit];
    CGRect f = self.toastLabel.frame; f.size.height = 26;
    self.toastLabel.frame = f; self.toastLabel.center = csSnapPoint(CGPointMake(self.bounds.size.width / 2, 70));
    self.toastLabel.alpha = 1;
    [UIView animateWithDuration:0.3 delay:1.6 options:0 animations:^{ self.toastLabel.alpha = 0; } completion:nil];
}

- (void)buzz {
    if (!C.haptic) return;
    @try {
        if (!self.hapticGen) self.hapticGen = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
        [self.hapticGen impactOccurred];
    } @catch (NSException *e) { AudioServicesPlaySystemSound(1519); }
}

- (void)reloadItems {
    NSArray *ids = recentBundleIDs();
    NSSet *bub = csBubbleIDs();
    NSArray *pins = pinList();
    NSMutableArray<NSString *> *use = [NSMutableArray array];
    for (NSString *b in ids) { if (![bub containsObject:b]) [use addObject:b]; if ((int)use.count >= C.count) break; }
    NSString *current = use.firstObject;
    self.prevBID = use.count > 1 ? use[1] : nil;
    NSMutableArray<CSItem *> *pinned = [NSMutableArray array], *rest = [NSMutableArray array];
    for (NSString *b in use) {
        CSItem *it = itemFor(b);
        it.pinned = [pins containsObject:b];
        [(it.pinned ? pinned : rest) addObject:it];
    }
    self.items = [NSMutableArray arrayWithArray:pinned];
    [self.items addObjectsFromArray:rest];
    [self rebuildViews];
    NSInteger idx = 0;
    for (NSUInteger i = 0; i < self.items.count; i++) if ([self.items[i].bid isEqualToString:current]) { idx = (NSInteger)i; break; }
    self.rot = idx * [self step]; self.dragY = 0; self.anim = 0; self.front = -2; self.smoothBank = 0;
    [self relayout];
}

- (void)rebuildViews {
    for (UIView *v in self.cards) [v removeFromSuperview];
    for (UIView *v in self.labels) [v removeFromSuperview];
    [self.cards removeAllObjects]; [self.labels removeAllObjects];
    for (CSItem *it in self.items) {
        BOOL circ = C.style <= 1;
        CSCard *c = [[CSCard alloc] initWithFrame:circ ? CGRectMake(0, 0, 100, 100) : CGRectMake(0, 0, 110, 186)];
        c.circle = circ; c.neon = (C.style == 3);
        [c configure:it showIcon:C.icon];
        [self.ring addSubview:c]; [self.cards addObject:c];
        CSLabel *l = [CSLabel new];
        l.backgroundColor = C.namePill ? [UIColor colorWithWhite:0.1 alpha:0.82] : UIColor.clearColor;
        l.layer.cornerRadius = 12; l.layer.masksToBounds = YES;
        if (!C.namePill) { l.layer.shadowColor = UIColor.blackColor.CGColor; l.layer.shadowOpacity = 0.55; l.layer.shadowRadius = 3; l.layer.shadowOffset = CGSizeZero; l.layer.masksToBounds = NO; }
        l.attributedText = labelFor(it); [l sizeToFit];
        [self.labelHost addSubview:l]; [self.labels addObject:l];
    }
    self.emptyLabel.hidden = self.items.count > 0;
}

- (void)rebuildDots {
    for (UIView *v in self.dotsView.subviews) [v removeFromSuperview];
    CGFloat W = self.bounds.size.width, H = self.bounds.size.height;
    NSUInteger n = self.items.count;
    CGFloat total = n * 10 - 4;
    self.dotsView.frame = CGRectMake((W - total) / 2, H - (C.style >= 2 ? 125 : 150), total, 6);
    self.dotsView.hidden = !C.dots || n == 0;
    for (NSUInteger i = 0; i < n; i++) {
        UIView *d = [[UIView alloc] initWithFrame:CGRectMake(i * 10, 0, 6, 6)];
        d.layer.cornerRadius = 3;
        BOOL on = ((NSInteger)i == self.front);
        d.backgroundColor = on ? UIColor.whiteColor : [UIColor colorWithWhite:1 alpha:0.35];
        d.transform = on ? CGAffineTransformMakeScale(1.4, 1.4) : CGAffineTransformIdentity;
        [self.dotsView addSubview:d];
    }
}

- (void)applyBackground {
    self.backgroundColor = [UIColor colorWithWhite:0 alpha:CSClamp(C.dim, 0, 90) / 100.0];
    self.blurBg.hidden = C.bgBlur < 0.5;
    self.blurBg.alpha = CSClamp(C.bgBlur / 10.0, 0, 1);
    self.backdropAssetView.hidden = (self.backdropAssetView.image == nil);
}

- (void)relayout {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [self applyBackground];
    BOOL circ = C.style <= 1;
    if (!circ) {
        self.glowRing.hidden = YES; self.bubble.hidden = YES; self.chev.hidden = YES;
        [self relayoutCards];
    } else [self relayoutRing];
    [CATransaction commit];
}

- (void)relayoutRing {
    NSInteger n = self.items.count;
    if (n != (NSInteger)self.cards.count) return;
    CGFloat W = self.bounds.size.width, H = self.bounds.size.height;
    CGFloat cx = csSnapPx(W / 2), cy = csSnapPx(H * 0.46);
    self.ring.bounds = CGRectMake(0, 0, 2, 2); self.ring.center = CGPointMake(cx, cy);
    self.ring.layer.sublayerTransform = CATransform3DIdentity;
    double step = [self step];
    double deltaRot = normDeg(self.rot - self.lastRot);
    self.lastRot = self.rot;
    double spd = fabs(deltaRot);
    double targetBank = CSClamp(deltaRot * 0.015, -0.105, 0.105);
    self.smoothBank = self.smoothBank * 0.65 + targetBank * 0.35;
    if (fabs(self.smoothBank) < 0.002) self.smoothBank = 0;

    CSRingCfg cfg = csCfgWithBank(self.smoothBank);
    double mblur = C.motionBlurOn ? C.moveBlur * MIN(1.0, spd / MAX(step * 0.16, 0.35)) : 0;

    if (C.ringGlow) {
        double gx, gy, rx, ry; CSRingGlowRect(cfg, &gx, &gy, &rx, &ry);
        UIColor *g = [UIColor colorWithHue:fmod(C.glowHue, 360.0) / 360.0 saturation:0.6 brightness:1 alpha:1];
        self.glowRing.path = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(cx + gx - rx, cy + gy - ry, rx * 2, ry * 2)].CGPath;
        self.glowRing.strokeColor = [g colorWithAlphaComponent:0.75].CGColor;
        self.glowRing.shadowColor = g.CGColor; self.glowRing.shadowOpacity = 0.9; self.glowRing.shadowRadius = 12; self.glowRing.shadowOffset = CGSizeZero;
        self.glowRing.hidden = NO;
    } else self.glowRing.hidden = YES;

    double best = 1e9; NSInteger front = -1;
    NSMutableArray *order = [NSMutableArray array];
    double selDia = 0, selY = 0;
    for (NSInteger i = 0; i < n; i++) {
        CSCard *card = self.cards[i]; CSLabel *lb = self.labels[i];
        double phi = normDeg(i * step - self.rot);
        CSPose p = CSRingPoseCircle(phi, step, cfg, W);
        double y = p.y;
        if (i == self.front && self.dragY != 0) y += self.dragY;
        if (fabs(card.bounds.size.width - 100) > 0.5 || fabs(card.bounds.size.height - 100) > 0.5) card.bounds = CGRectMake(0, 0, 100, 100);
        double f = p.dia / 100.0;
        card.layer.position = csSnapPoint(CGPointMake(1 + p.x, 1 + y));
        CATransform3D t = CATransform3DIdentity;
        if (!C.crispText || fabs(p.yaw) > 0.008) {
            t.m34 = -1.0 / p.perspective;
            t = CATransform3DRotate(t, p.yaw, 0, 1, 0);
        }
        t = CATransform3DScale(t, f, f, 1);
        card.layer.transform = t; card.layer.zPosition = p.z + p.k * 2;
        double op = p.opacity;
        if (i == self.front && self.dragY < 0) op *= MAX(0.2, 1 + self.dragY / 220.0);
        card.alpha = op;
        double distBlur = (C.style == 1 ? C.blur * MIN(1.0, fabs(phi) / 90.0) : 0);
        [card setBlur:distBlur + mblur];
        [card setGlow:p.k];
        card.front.hidden = NO; card.back.hidden = YES;
        double px = cx + p.x, py = cy + y, rr = p.dia / 2;
        card.hit = CGRectMake(px - rr, py - rr, rr * 2, rr * 2); card.zv = p.z + p.k * 2;
        [order addObject:card];
        if (fabs(phi) < best) { best = fabs(phi); front = i; selDia = p.dia; selY = py; }
        BOOL isFront = fabs(phi) <= step / 2;
        BOOL show = C.namePos != 3 && isFront;
        lb.hidden = !show;
        if (show) {
            double bubR = 59.0 * C.centerSize / 100.0 * C.size / 100.0;
            double ly;
            if (C.style == 0) {
                ly = C.namePos == 0 ? py - rr - 18 : (C.namePos == 1 ? cy + C.off + bubR + 26 : cy + C.off + cfg.radius * 1.25 + selDia / 2 + 28);
                lb.center = csSnapPoint(CGPointMake(C.namePos == 0 ? px : cx, ly));
            } else {
                ly = C.namePos == 0 ? py - rr - 22 : (C.namePos == 1 ? py : py + rr + 22);
                lb.center = csSnapPoint(CGPointMake(px, ly));
            }
            lb.transform = CGAffineTransformIdentity;
            lb.alpha = 1;
        }
    }
    [order sortUsingComparator:^NSComparisonResult(CSCard *a, CSCard *b) { return a.zv < b.zv ? NSOrderedAscending : NSOrderedDescending; }];
    for (CSCard *c in order) [self.ring bringSubviewToFront:c];
    BOOL flat = C.style == 0 && n > 0;
    self.bubble.hidden = !flat;
    if (flat) {
        double bd = 118.0 * C.centerSize / 100.0 * C.size / 100.0;
        self.bubble.bounds = CGRectMake(0, 0, bd, bd); self.bubble.center = csSnapPoint(CGPointMake(cx, cy + C.off));
        self.bubble.layer.cornerRadius = bd / 2;
        self.bubbleIcon.frame = CGRectInset(self.bubble.bounds, bd * 0.24, bd * 0.24);
        self.bubbleIcon.layer.cornerRadius = bd * 0.12;
        if (front >= 0 && front < n) self.bubbleIcon.image = self.items[front].icon;
        self.bubbleIcon.hidden = !C.icon;
    }
    self.chev.hidden = !(C.style == 0 && C.chevron && n > 0);
    if (!self.chev.hidden) self.chev.center = csSnapPoint(CGPointMake(cx, selY - selDia / 2 - (C.namePos == 0 && C.style == 0 ? 52 : 26)));
    if (front != self.front) {
        BOOL first = (self.front == -2);
        self.front = front;
        if (!first) [self buzz];
        [self rebuildDots];
    }
}

- (void)relayoutCards {
    NSInteger n = self.items.count;
    if (n != (NSInteger)self.cards.count) return;
    CGFloat W = self.bounds.size.width, H = self.bounds.size.height, P = 900;
    CGFloat cx = csSnapPx(W / 2), cy = csSnapPx(H * 0.46 + C.off);
    self.ring.bounds = CGRectMake(0, 0, 2, 2); self.ring.center = CGPointMake(cx, cy);
    CATransform3D persp = CATransform3DIdentity; persp.m34 = -1.0 / P;
    self.ring.layer.sublayerTransform = persp;
    double step = [self step], e = C.cam * M_PI / 180.0;
    CGFloat w = 110 * C.size / 100.0, h = 186 * C.size / 100.0;
    BOOL neon = C.style == 3;
    double gm = neon ? C.gap / 100.0 : 1.0;
    double spd = fabs(normDeg(self.rot - self.lastRot)); self.lastRot = self.rot;
    double mblur = C.motionBlurOn ? C.moveBlur * MIN(1.0, spd / MAX(step * 0.16, 0.35)) : 0;
    double best = 1e9; NSInteger front = -1;
    NSMutableArray *order = [NSMutableArray array];
    for (NSInteger i = 0; i < n; i++) {
        CSCard *card = self.cards[i]; CSLabel *lb = self.labels[i];
        double phi = normDeg(i * step - self.rot), r = phi * gm * M_PI / 180.0;
        double kk = CSClamp(1.0 - fabs(phi) / MAX(step, 1.0), 0, 1), ks = kk * kk * (3.0 - 2.0 * kk);
        double fsc = neon ? 0.80 + 0.30 * ks : 1.0;
        double x = C.radius * sin(r), depth = C.radius * cos(r) - C.radius;
        double z = depth * cos(e), y = depth * sin(e);
        if (i == self.front && self.dragY != 0) y += self.dragY;
        double yaw = -C.tilt * clampd(phi / 45.0, -1, 1) * M_PI / 180.0;
        BOOL back = cos(yaw) < 0;
        double s = 1.0 / (1.0 - z / P);
        if (fabs(card.bounds.size.width - w) > 0.5 || fabs(card.bounds.size.height - h) > 0.5) card.bounds = CGRectMake(0, 0, w, h);
        card.center = CGPointMake(1, 1);
        CATransform3D t = CATransform3DIdentity;
        t = CATransform3DTranslate(t, x, y, z);
        if (!C.crispText || fabs(yaw) > 0.008) t = CATransform3DRotate(t, yaw, 0, 1, 0);
        if (neon) t = CATransform3DScale(t, fsc, fsc, 1);
        card.layer.transform = t;
        double op = 0.4 + 0.6 * (cos(r) + 1) / 2;
        if (i == self.front && self.dragY < 0) op *= MAX(0.2, 1 + self.dragY / 220.0);
        card.alpha = op;
        double bl = C.blur * MIN(1.0, fabs(phi) / 90.0) + (C.namePos == 1 ? 1.5 : 0) + mblur;
        [card setBlur:bl];
        [card setGlow:ks];
        card.front.hidden = back; card.back.hidden = !back;
        double px = cx + x * s, py = cy + y * s;
        double hw = (w * fsc * s / 2) * MAX(fabs(cos(yaw)), 0.25), hh = h * fsc * s / 2;
        card.hit = CGRectMake(px - hw, py - hh, hw * 2, hh * 2); card.zv = z;
        [order addObject:card];
        BOOL show = C.namePos != 3 && !(C.onlyFront && fabs(phi) > 20);
        lb.hidden = !show;
        if (show) {
            double ly = C.namePos == 0 ? py - hh - 16 : (C.namePos == 2 ? py + hh + 16 : py);
            lb.center = csSnapPoint(CGPointMake(px, ly));
            lb.transform = CGAffineTransformMakeScale(s, s);
            lb.alpha = op;
        }
        if (fabs(phi) < best) { best = fabs(phi); front = i; }
    }
    [order sortUsingComparator:^NSComparisonResult(CSCard *a, CSCard *b) { return a.zv < b.zv ? NSOrderedAscending : NSOrderedDescending; }];
    for (CSCard *c in order) [self.ring bringSubviewToFront:c];
    if (front != self.front) {
        BOOL first = (self.front == -2);
        self.front = front;
        if (!first) [self buzz];
        [self rebuildDots];
    }
}

- (void)startLink {
    if (!self.link) {
        self.link = [CADisplayLink displayLinkWithTarget:self selector:@selector(onFrame:)];
        csConfigureHighFPSLink(self.link);
        [self.link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    }
    self.link.paused = NO;
}

- (void)stopLink {
    if (self.link) { [self.link invalidate]; self.link = nil; }
}

- (void)onFrame:(CADisplayLink *)l {
    double dt = MAX(0.001, l.targetTimestamp - l.timestamp);
    double stiff = 240.0 * (CSClamp(C.springStiffness, 50, 180) / 100.0);
    double damp = 2.0 * sqrt(stiff) * 0.94; // smooth critically-damped spring

    if (self.anim == 1) {
        CSSpringStep(&_rotSpring, dt, stiff, damp);
        self.rot = _rotSpring.pos;
        if (!_rotSpring.active) { self.rot = wrap360(self.rot); self.anim = 0; l.paused = YES; }
    } else if (self.anim == 2) {
        self.rot += self.vel * dt;
        self.vel *= pow(0.935, dt * 60);
        if (fabs(self.vel) < 35) {
            double st = [self step];
            _rotSpring.pos = self.rot;
            _rotSpring.vel = self.vel; // carry momentum seamlessly into spring!
            _rotSpring.target = round(self.rot / st) * st;
            _rotSpring.active = YES;
            self.anim = 1;
        }
    } else if (self.anim == 3) {
        CSSpringStep(&_dragSpring, dt, 320.0, 28.0);
        self.dragY = _dragSpring.pos;
        if (!_dragSpring.active) { self.dragY = 0; self.anim = 0; l.paused = YES; }
    } else {
        l.paused = YES;
    }
    [self relayout];
}

- (void)tweenTo:(double)to withVelocity:(double)vel {
    _rotSpring.pos = self.rot;
    _rotSpring.vel = vel;
    _rotSpring.target = to;
    _rotSpring.active = YES;
    self.anim = 1;
    [self startLink];
}

- (void)snap {
    double st = [self step];
    [self tweenTo:round(self.rot / st) * st withVelocity:0];
}

- (void)rotateToIndex:(NSInteger)i {
    [self tweenTo:self.rot + normDeg(i * [self step] - self.rot) withVelocity:0];
}

- (CSCard *)cardAt:(CGPoint)p {
    CSCard *best = nil;
    for (CSCard *c in self.cards) {
        if (CGRectContainsPoint(c.hit, p) && (!best || c.zv > best.zv)) best = c;
    }
    return best;
}

- (void)onPan:(UIPanGestureRecognizer *)g {
    [self touchedNow];
    CGPoint t = [g translationInView:self];
    double step = [self step];
    if (g.state == UIGestureRecognizerStateBegan) {
        self.anim = 0; _rotSpring.active = NO; self.panMode = 0; self.panAccum = CGPointZero; self.startBID = [self frontBID];
        CGPoint cur = [g locationInView:self]; self.panStart = CGPointMake(cur.x - t.x, cur.y - t.y);
    }
    if (g.state == UIGestureRecognizerStateChanged || g.state == UIGestureRecognizerStateBegan) {
        self.panAccum = CGPointMake(self.panAccum.x + t.x, self.panAccum.y + t.y);
        [g setTranslation:CGPointZero inView:self];
        if (self.panMode == 0 && hypot(self.panAccum.x, self.panAccum.y) > 8) {
            if (fabs(self.panAccum.x) >= fabs(self.panAccum.y)) {
                self.panMode = 1;
                self.rot -= self.panAccum.x * (step / 110.0);
            } else {
                CSCard *c = [self cardAt:self.panStart];
                BOOL onFront = c && [self.cards indexOfObject:c] == self.front;
                self.panMode = onFront ? 2 : 3;
            }
        } else if (self.panMode == 1) {
            self.rot -= t.x * (step / 110.0);
        } else if (self.panMode == 2) {
            self.dragY = clampd(self.panAccum.y, -300, 60);
        }
        [self relayout];
    } else if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled || g.state == UIGestureRecognizerStateFailed) {
        if (self.panMode == 1) {
            NSString *fb = [self frontBID];
            if (fb && self.startBID && ![fb isEqualToString:self.startBID]) self.prevBID = self.startBID;
            double v = -[g velocityInView:self].x * (step / 110.0);
            if (C.inertia && fabs(v) > 65) { self.vel = v; self.anim = 2; [self startLink]; }
            else [self tweenTo:round(self.rot / step) * step withVelocity:v];
        } else if (self.panMode == 2) {
            if (self.dragY < -90) { [self closeFront]; }
            else if (self.dragY > 45) { [self togglePinFront]; }
            _dragSpring.pos = self.dragY; _dragSpring.vel = 0; _dragSpring.target = 0; _dragSpring.active = YES;
            self.anim = 3; [self startLink];
        } else { [self snap]; }
        self.panMode = 0;
    }
}

- (void)onTap:(UITapGestureRecognizer *)g {
    [self touchedNow];
    CGPoint p = [g locationInView:self];
    CSCard *c = [self cardAt:p];
    if (c) {
        NSInteger i = [self.cards indexOfObject:c];
        if (i == self.front) { [self openFront]; }
        else { self.prevBID = [self frontBID]; [self rotateToIndex:i]; }
        return;
    }
    NSDate *now = [NSDate date];
    if (self.lastBgTap && [now timeIntervalSinceDate:self.lastBgTap] < 0.32) { self.lastBgTap = nil; [self goBack]; }
    else self.lastBgTap = now;
}

- (void)onLong:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    [self touchedNow];
    if (!C.bubOn) return;
    CSCard *c = [self cardAt:[g locationInView:self]];
    if (!c || [self.cards indexOfObject:c] != self.front) return;
    [self bubbleFront];
}

- (void)onEscape:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    csLog(@"escape long-press: force hide");
    csForceHidden = YES; csHideOverlay();
}

- (void)onExit {
    CFPreferencesSetAppValue(CFSTR("testShow"), kCFBooleanFalse, CS_DOMAIN);
    CFPreferencesAppSynchronize(CS_DOMAIN);
    csHideOverlay();
}

- (void)openFront {
    NSString *b = [self frontBID];
    if (!b) return;
    [self buzz];
    csForceHidden = YES;
    csHideOverlay();
    openApp(b);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        csForceHidden = NO;
    });
}

- (void)goBack {
    if (!self.prevBID) return;
    for (NSUInteger i = 0; i < self.items.count; i++) {
        if ([self.items[i].bid isEqualToString:self.prevBID]) {
            self.prevBID = [self frontBID];
            [self rotateToIndex:(NSInteger)i];
            [self toast:[NSString stringWithFormat:@"Quay lại %@", self.items[i].name]];
            return;
        }
    }
}

- (void)removeItemAt:(NSInteger)k {
    if (k < 0 || k >= (NSInteger)self.items.count) return;
    [self.items removeObjectAtIndex:k];
    [self rebuildViews];
    double st = [self step];
    NSInteger nk = MIN(k, MAX((NSInteger)self.items.count - 1, 0));
    self.rot = nk * st; self.front = -2; self.dragY = 0;
    [self relayout];
}

- (void)closeFront {
    NSInteger k = self.front;
    if (k < 0 || k >= (NSInteger)self.items.count) return;
    CSItem *it = self.items[k];
    killApp(it.bid); [self buzz];
    [self toast:[NSString stringWithFormat:@"Đã đóng %@", it.name]];
    self.dragY = 0; [self removeItemAt:k];
}

- (void)bubbleFront {
    NSInteger k = self.front;
    if (k < 0 || k >= (NSInteger)self.items.count) return;
    CSItem *it = self.items[k];
    CGPoint from = [self convertPoint:CGPointMake(self.bounds.size.width / 2, self.bounds.size.height * 0.46 + C.off) toView:csRoot.view];
    csAddBubble(it, from); [self buzz];
    [self removeItemAt:k];
    [self toast:@"Đã tạo bong bóng"];
}

- (void)togglePinFront {
    NSInteger k = self.front;
    if (k < 0 || k >= (NSInteger)self.items.count) return;
    CSItem *it = self.items[k];
    NSMutableArray *pins = [pinList() mutableCopy];
    if ([pins containsObject:it.bid]) [pins removeObject:it.bid]; else [pins addObject:it.bid];
    setPinList(pins); [self buzz];
    it.pinned = [pins containsObject:it.bid];
    [self toast:[NSString stringWithFormat:@"%@ %@", it.pinned ? @"Đã ghim" : @"Đã bỏ ghim", it.name]];
    NSMutableArray *pinned = [NSMutableArray array], *rest = [NSMutableArray array];
    for (CSItem *x in self.items) [(x.pinned ? pinned : rest) addObject:x];
    [pinned addObjectsFromArray:rest]; self.items = pinned;
    [self rebuildViews];
    NSUInteger idx = [self.items indexOfObject:it];
    self.rot = idx * [self step]; self.front = -2; self.dragY = 0;
    [self relayout];
}

- (void)runKill:(BOOL)all {
    NSArray *pins = pinList();
    NSString *keep = [self frontBID];
    int n = 0;
    for (CSItem *it in [self.items copy]) {
        if (!all && [it.bid isEqualToString:keep]) continue;
        if (C.keepPinned && [pins containsObject:it.bid]) continue;
        if (killApp(it.bid)) n++;
    }
    [self buzz];
    [self toast:[NSString stringWithFormat:@"Đã đóng %d app", n]];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self reloadItems]; });
}

- (void)onCloseAll {
    [self touchedNow];
    if (self.armX && -[self.armX timeIntervalSinceNow] < 3) { self.armX = nil; [self runKill:YES]; }
    else { self.armX = [NSDate date]; [self toast:@"Chạm X lần nữa để đóng tất cả"]; }
}

- (void)onClean {
    [self touchedNow];
    if (self.armClean && -[self.armClean timeIntervalSinceNow] < 3) { self.armClean = nil; [self runKill:NO]; }
    else { self.armClean = [NSDate date]; [self toast:@"Chạm lần nữa để dọn RAM (đóng app nền)"]; }
}
@end

#pragma mark - Show / Hide / Detection

static NSDate *csBoot;
static NSDate *csShownAt;
static int csTickCount;
static NSString *csLastSig;

static void csShowOverlay(BOOL test) {
    loadCfg();
    if (!ensureWindow()) return;
    if (!csOverlay) csOverlay = [[CSOverlay alloc] initWithFrame:csRoot.view.bounds];
    csOverlay.testMode = test; csOverlay.exitBtn.hidden = !test;
    csOverlay.userInteractionEnabled = YES;
    if (csOverlay.superview != csRoot.view) {
        csOverlay.frame = csRoot.view.bounds;
        csOverlay.alpha = 0;
        [csRoot.view addSubview:csOverlay];
    }
    [csOverlay reloadItems];
    if (C.openAnim) {
        double sp = CSClamp(C.openSpeed, 40, 250) / 100.0;
        csOverlay.ring.transform = CGAffineTransformMakeScale(0.35, 0.35);
        csOverlay.labelHost.alpha = 0;
        [UIView animateWithDuration:0.52 / sp delay:0 usingSpringWithDamping:0.78 initialSpringVelocity:0.65
                            options:UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionBeginFromCurrentState
                         animations:^{ csOverlay.ring.transform = CGAffineTransformIdentity; csOverlay.alpha = 1; } completion:nil];
        [UIView animateWithDuration:0.28 / sp delay:0.10 / sp options:0 animations:^{ csOverlay.labelHost.alpha = 1; } completion:nil];
    } else {
        csOverlay.ring.transform = CGAffineTransformIdentity; csOverlay.labelHost.alpha = 1;
        [UIView animateWithDuration:0.2 animations:^{ csOverlay.alpha = 1; }];
    }
    for (UIView *b in csBubbles) [csRoot.view bringSubviewToFront:b];
    csShownAt = [NSDate date];
    csLog(@"overlay shown (test=%d)", test);
}

static void csHideOverlay(void) {
    if (!csOverlay || !csOverlay.superview) return;
    CSOverlay *o = csOverlay;
    o.userInteractionEnabled = NO;
    double sp = CSClamp(C.openSpeed, 40, 250) / 100.0;
    [UIView animateWithDuration:0.18 / sp delay:0 options:UIViewAnimationOptionBeginFromCurrentState animations:^{
        o.alpha = 0; if (C.openAnim) o.ring.transform = CGAffineTransformMakeScale(0.6, 0.6);
    } completion:^(BOOL f) {
        if (o.alpha == 0) {
            [o stopLink];
            [o removeFromSuperview];
            o.ring.transform = CGAffineTransformIdentity;
        }
    }];
    csLog(@"overlay hidden");
}

static int csHookVis = -1;

static NSArray<NSString *> *csProbeNames(Class cls) {
    static NSMutableDictionary *cache;
    if (!cache) cache = [NSMutableDictionary new];
    NSString *key = NSStringFromClass(cls);
    NSArray *hit = cache[key];
    if (hit) return hit;
    NSMutableArray *out = [NSMutableArray array];
    for (Class k = cls; k && k != NSObject.class && k != UIViewController.class && k != UIResponder.class && k != UIView.class; k = class_getSuperclass(k)) {
        unsigned n = 0;
        Method *ms = class_copyMethodList(k, &n);
        for (unsigned i = 0; i < n; i++) {
            NSString *name = NSStringFromSelector(method_getName(ms[i]));
            if ([name containsString:@":"]) continue;
            char *rt = method_copyReturnType(ms[i]);
            BOOL isBool = rt && (rt[0] == 'B' || rt[0] == 'c');
            free(rt);
            if (!isBool) continue;
            NSString *l = name.lowercaseString;
            if ([l containsString:@"visible"] || [l containsString:@"showing"] || [l containsString:@"presented"]) {
                if (![out containsObject:name]) [out addObject:name];
            }
        }
        free(ms);
    }
    cache[key] = out;
    return out;
}

static int csDetectVisible(void) {
    id ms = mainSwitcher();
    NSMutableArray *objs = [NSMutableArray array];
    id coord = send0((id)NSClassFromString(@"SBMainSwitcherControllerCoordinator"), @"sharedInstance");
    if (coord) [objs addObject:coord];
    if (ms) {
        [objs addObject:ms];
        @try { for (id c in [(UIViewController *)ms childViewControllers]) { if ([NSStringFromClass([c class]) rangeOfString:@"Switcher"].location != NSNotFound) [objs addObject:c]; } } @catch (NSException *e) {}
    }
    if (!objs.count) return csHookVis;

    NSArray *known = @[@"isAnySwitcherVisible", @"isMainSwitcherVisible", @"isSwitcherVisible", @"isSwitcherShowing", @"isVisible"];
    NSMutableString *sig = [NSMutableString string];
    int result = -1;
    for (id o in objs) {
        NSString *cn = NSStringFromClass([o class]);
        NSMutableArray *names = [NSMutableArray array];
        for (NSString *k in known) if ([o respondsToSelector:NSSelectorFromString(k)]) [names addObject:k];
        for (NSString *k in csProbeNames([o class])) {
            if (![names containsObject:k] && [k.lowercaseString containsString:@"switcher"]) [names addObject:k];
        }
        for (NSString *n in names) {
            BOOL b = NO;
            @try { b = ((BOOL (*)(id, SEL))objc_msgSend)(o, NSSelectorFromString(n)); } @catch (NSException *e) { continue; }
            [sig appendFormat:@"%@.%@=%d ", cn, n, b];
            if (result == -1) result = b ? 1 : 0;
        }
    }
    if (result == -1 && csHookVis != -1) { result = csHookVis; [sig appendFormat:@"hookVis=%d ", csHookVis]; }
    if (![sig isEqualToString:csLastSig]) { csLastSig = [sig copy]; csLog(@"switcher signals: %@", sig); }
    return result;
}

static void csSyncOverlayImmediate(void) {
    if (!C.enabled || C.mode != 2) return;
    if (-[csBoot timeIntervalSinceNow] < 4) return;
    if (csOverlay.superview && csOverlay.testMode) return;
    int vis = csDetectVisible();
    BOOL shown = csOverlay.superview != nil;
    if (vis == 1 && !shown && !csForceHidden) csShowOverlay(NO);
    else if (vis == 0) { csForceHidden = NO; if (shown) csHideOverlay(); }
}

static NSString *csChain(Class k) {
    NSMutableArray *a = [NSMutableArray array];
    for (; k; k = class_getSuperclass(k)) [a addObject:NSStringFromClass(k)];
    return [a componentsJoinedByString:@" < "];
}

static void csStaticDump(void) {
    static BOOL done;
    if (done) return;
    done = YES;
    csLog(@"=== STATIC DUMP iOS %@ arch=%s", UIDevice.currentDevice.systemVersion,
#if __arm64e__
          "arm64e"
#else
          "arm64"
#endif
    );
    NSArray *names = @[@"SBSwitcherViewController", @"SBDeckSwitcherViewController", @"SBFluidSwitcherViewController",
                       @"SBDeckSwitcherItemContainer", @"SBFluidSwitcherItemContainer", @"SBRecentAppLayouts",
                       @"SBMainSwitcherControllerCoordinator", @"SBDeckSwitcherPersonality", @"SBAppLayout"];
    for (NSString *cn in names) {
        Class k = NSClassFromString(cn);
        if (!k) { csLog(@"class %@ = nil", cn); continue; }
        unsigned n = 0; Method *ms = class_copyMethodList(k, &n);
        NSMutableArray *mn = [NSMutableArray array];
        for (unsigned i = 0; i < n; i++) [mn addObject:NSStringFromSelector(method_getName(ms[i]))];
        free(ms);
        NSString *joined = [mn componentsJoinedByString:@" "];
        if (joined.length > 6000) joined = [joined substringToIndex:6000];
        csLog(@"class %@ chain: %@ | methods(%u): %@", cn, csChain(k), n, joined);
    }
}

#pragma mark - Mode 0: True Circular Morph + @3x Glass Rim/Halo + Damped Spring Physics

#define CS_MARKER @"/var/mobile/Documents/CircleSwitcher.armed"
static BOOL csTripped, csMarkerOn;
static double csLastApply;
static const void *kMineP = &kMineP, *kMineT = &kMineT, *kSysP = &kSysP, *kSysT = &kSysT, *kSysO = &kSysO, *kApplied = &kApplied, *kMineO = &kMineO, *kSysZ = &kSysZ;
static const void *kCrispApplied = &kCrispApplied, *kOrigRast = &kOrigRast;
static const void *kOrigMask = &kOrigMask, *kMaskSaved = &kMaskSaved, *kCircleMask = &kCircleMask, *kCircleRim = &kCircleRim;
static const void *kGlassRimView = &kGlassRimView, *kHaloView = &kHaloView;
static const void *kBlurFilter = &kBlurFilter, *kLastBlur = &kLastBlur;
static const void *kStableSlot = &kStableSlot;

static BOOL csM0Active;
static double csM0Rot, csM0Vel, csM0Step;
static double csM0LastRot, csM0LastAvgK, csM0LastTs, csM0SmoothBlur, csM0SmoothBank;
static CSSpring1D csM0Spring;
static int csM0Anim, csM0Count;
static NSInteger csM0FrontSlot = -1;
static CGRect csM0Hits[40];
static double csM0Z[40];
static __weak UIViewController *csM0VC;
static __weak UIScrollView *csM0ScrollView;
static CADisplayLink *csM0Link;
static UIImpactFeedbackGenerator *csM0Haptic;

static void csM0Buzz(void) {
    if (!C.haptic) return;
    @try {
        if (!csM0Haptic) csM0Haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
        [csM0Haptic impactOccurred];
    } @catch (NSException *e) { AudioServicesPlaySystemSound(1519); }
}

static void csDeckLayout(UIViewController *vc);

static void csSetScrollEnabled(UIView *root, BOOL enabled) {
    if (!csM0ScrollView && root) {
        for (UIView *sub in root.subviews) {
            if ([sub isKindOfClass:UIScrollView.class]) { csM0ScrollView = (UIScrollView *)sub; break; }
            for (UIView *sub2 in sub.subviews) {
                if ([sub2 isKindOfClass:UIScrollView.class]) { csM0ScrollView = (UIScrollView *)sub2; break; }
            }
            if (csM0ScrollView) break;
        }
    }
    if (csM0ScrollView && csM0ScrollView.scrollEnabled != enabled) {
        csM0ScrollView.scrollEnabled = enabled;
    }
}

@interface CSM0Handler : NSObject <UIGestureRecognizerDelegate>
@end
@implementation CSM0Handler

- (void)startLink {
    if (!csM0Link) {
        csM0Link = [CADisplayLink displayLinkWithTarget:self selector:@selector(onFrame:)];
        csConfigureHighFPSLink(csM0Link);
        [csM0Link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    }
    csM0Link.paused = NO;
}

- (void)onFrame:(CADisplayLink *)l {
    if (!csM0Active || !csM0VC) { csM0Anim = 0; csM0Spring.active = NO; l.paused = YES; return; }
    double dt = MAX(0.001, l.targetTimestamp - l.timestamp);
    double stiff = 250.0 * (CSClamp(C.springStiffness, 50, 180) / 100.0);
    double damp = 2.0 * sqrt(stiff) * 0.93;

    if (csM0Anim == 1) {
        CSSpringStep(&csM0Spring, dt, stiff, damp);
        csM0Rot = csM0Spring.pos;
        if (!csM0Spring.active) {
            csM0Rot = wrap360(csM0Rot);
            csM0Anim = 0;
            l.paused = YES;
        }
    } else if (csM0Anim == 2) {
        csM0Rot += csM0Vel * dt;
        csM0Vel *= pow(0.935, dt * 60);
        if (fabs(csM0Vel) < 35) {
            double st = MAX(1.0, csM0Step);
            csM0Spring.pos = csM0Rot;
            csM0Spring.vel = csM0Vel; // seamless momentum handoff into damped spring
            csM0Spring.target = round(csM0Rot / st) * st;
            csM0Spring.active = YES;
            csM0Anim = 1;
        }
    } else { l.paused = YES; }
    csDeckLayout(csM0VC);
}

- (void)tweenTo:(double)to withVelocity:(double)vel {
    csM0Spring.pos = csM0Rot;
    csM0Spring.vel = vel;
    csM0Spring.target = to;
    csM0Spring.active = YES;
    csM0Anim = 1;
    [self startLink];
}

- (void)snapWithVelocity:(double)vel {
    double st = MAX(1.0, csM0Step);
    [self tweenTo:round(csM0Rot / st) * st withVelocity:vel];
}

- (NSInteger)hitSlotAt:(CGPoint)p {
    NSInteger best = -1;
    double bestZ = -1e18;
    for (int j = 0; j < csM0Count && j < 40; j++) {
        if (CGRectContainsPoint(csM0Hits[j], p) && csM0Z[j] > bestZ) { bestZ = csM0Z[j]; best = j; }
    }
    return best;
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)g {
    if (!csM0Active || C.mode != 0 || !C.enabled) return NO;
    UIView *v = g.view;
    if (!v) return NO;
    CGSize sz = v.bounds.size;
    CGPoint pt = [g locationInView:v];
    if (pt.y > sz.height - 44 || pt.y < 54) return NO;

    if ([g isKindOfClass:UIPanGestureRecognizer.class]) {
        CGPoint vel = [(UIPanGestureRecognizer *)g velocityInView:v];
        return fabs(vel.x) > fabs(vel.y) * 1.1;
    }
    if ([g isKindOfClass:UITapGestureRecognizer.class]) {
        NSInteger slot = [self hitSlotAt:pt];
        return (slot >= 0 && slot != csM0FrontSlot);
    }
    return NO;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    if ([g isKindOfClass:UIPanGestureRecognizer.class] && [other.view isKindOfClass:UIScrollView.class]) return NO;
    return YES;
}

- (void)onPan:(UIPanGestureRecognizer *)g {
    UIView *v = g.view;
    if (!v || !csM0Active) return;
    double step = MAX(1.0, csM0Step);
    if (g.state == UIGestureRecognizerStateBegan) {
        csM0Anim = 0; csM0Spring.active = NO;
        [g setTranslation:CGPointZero inView:v];
    } else if (g.state == UIGestureRecognizerStateChanged) {
        CGPoint t = [g translationInView:v];
        [g setTranslation:CGPointZero inView:v];
        csM0Rot -= t.x * (step / 105.0);
        if (csM0VC) csDeckLayout(csM0VC);
    } else if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled) {
        double vel = -[g velocityInView:v].x * (step / 105.0);
        if (C.inertia && fabs(vel) > 65) { csM0Vel = vel; csM0Anim = 2; [self startLink]; }
        else [self snapWithVelocity:vel];
    }
}

- (void)onTap:(UITapGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateEnded || !csM0Active) return;
    CGPoint pt = [g locationInView:g.view];
    NSInteger slot = [self hitSlotAt:pt];
    if (slot >= 0 && slot != csM0FrontSlot) {
        double step = MAX(1.0, csM0Step);
        double target = csM0Rot + normDeg(slot * step - csM0Rot);
        [self tweenTo:target withVelocity:0];
    }
}
@end

static CSM0Handler *csM0Handler;
static const void *kM0Installed = &kM0Installed;

static void csEnsureM0Gestures(UIView *v) {
    if (!v || [objc_getAssociatedObject(v, kM0Installed) boolValue]) return;
    if (!csM0Handler) csM0Handler = [CSM0Handler new];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:csM0Handler action:@selector(onPan:)];
    pan.delegate = csM0Handler; pan.cancelsTouchesInView = YES;
    [v addGestureRecognizer:pan];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:csM0Handler action:@selector(onTap:)];
    tap.delegate = csM0Handler; tap.cancelsTouchesInView = YES;
    [v addGestureRecognizer:tap];

    objc_setAssociatedObject(v, kM0Installed, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static BOOL csT3Near(CATransform3D a, CATransform3D b) {
    return fabs(a.m11 - b.m11) < 1e-3 && fabs(a.m12 - b.m12) < 1e-3 && fabs(a.m21 - b.m21) < 1e-3 && fabs(a.m22 - b.m22) < 1e-3 &&
           fabs(a.m34 - b.m34) < 1e-6 && fabs(a.m41 - b.m41) < 0.05 && fabs(a.m42 - b.m42) < 0.05 && fabs(a.m43 - b.m43) < 0.05;
}

static BOOL csIsHeaderClass(NSString *n) {
    return [n rangeOfString:@"Header"].location != NSNotFound ||
           [n rangeOfString:@"IconImageContainer"].location != NSNotFound ||
           [n rangeOfString:@"TitleView"].location != NSNotFound ||
           [n rangeOfString:@"AppExpose"].location != NSNotFound ||
           [n rangeOfString:@"Shelf"].location != NSNotFound;
}

static void csSuppressSwitcherHeaders(UIView *v, int depth, BOOL hide) {
    if (!v || depth > 8) return;
    NSString *n = NSStringFromClass(v.class);
    if (csIsHeaderClass(n)) {
        if (hide) {
            if (!v.hidden) v.hidden = YES;
            if (v.alpha > 0.001) v.alpha = 0;
        } else {
            v.hidden = NO;
            v.alpha = 1;
        }
        return;
    }
    if ([n rangeOfString:@"SnapshotView"].location != NSNotFound || [n rangeOfString:@"LiveContentView"].location != NSNotFound) return;
    for (UIView *sub in v.subviews) {
        csSuppressSwitcherHeaders(sub, depth + 1, hide);
    }
}

static void csCollect(UIView *v, int d, NSMutableArray *cards, NSMutableArray *heads, int *budget) {
    if (--(*budget) < 0 || d > 10) return;
    NSString *n = NSStringFromClass(v.class);
    if (csIsHeaderClass(n)) { [heads addObject:v]; return; }
    if ([n rangeOfString:@"ItemContainer"].location != NSNotFound) {
        [cards addObject:v];
        return;
    }
    for (UIView *x in v.subviews) csCollect(x, d + 1, cards, heads, budget);
}

static void csApplyCrispness(UIView *v, int depth, BOOL enable) {
    if (!v || depth > 2) return;
    CALayer *L = v.layer;
    CGFloat sc = csScreenScale();
    if (enable) {
        if (![objc_getAssociatedObject(v, kCrispApplied) boolValue]) {
            objc_setAssociatedObject(v, kOrigRast, @(L.shouldRasterize), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(v, kCrispApplied, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        if (L.shouldRasterize) L.shouldRasterize = NO;
        if (L.contentsScale < sc) L.contentsScale = sc;
        L.minificationFilter = kCAFilterTrilinear;
        L.magnificationFilter = kCAFilterLinear;
    } else {
        if ([objc_getAssociatedObject(v, kCrispApplied) boolValue]) {
            NSNumber *orig = objc_getAssociatedObject(v, kOrigRast);
            if (orig) L.shouldRasterize = orig.boolValue;
            objc_setAssociatedObject(v, kCrispApplied, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
    for (UIView *sub in v.subviews) {
        csApplyCrispness(sub, depth + 1, enable);
    }
}

static void csApplyCardMotionBlur(UIView *c, double radius) {
    @try {
        CALayer *L = c.layer;
        NSNumber *prev = objc_getAssociatedObject(c, kLastBlur);
        if (prev && fabs(prev.doubleValue - radius) < 0.08) return;
        objc_setAssociatedObject(c, kLastBlur, @(radius), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (radius < 0.15) {
            if (L.filters) L.filters = nil;
            return;
        }
        id f = objc_getAssociatedObject(c, kBlurFilter);
        if (!f) {
            f = send1((id)NSClassFromString(@"CAFilter"), @"filterWithType:", @"gaussianBlur");
            if (!f) return;
            objc_setAssociatedObject(c, kBlurFilter, f, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        [f setValue:@(radius) forKey:@"inputRadius"];
        L.filters = @[f];
    } @catch (NSException *e) {}
}

typedef struct { BOOL ok; CGPoint pos, scr; CATransform3D t; double sc, op, z; } CSSys;

static CSSys csCapture(UIView *c) {
    CSSys s; memset(&s, 0, sizeof s);
    UIView *sv = c.superview;
    if (!sv || !c.window) return s;
    CALayer *L = c.layer;
    NSValue *mp = objc_getAssociatedObject(c, kMineP), *mt = objc_getAssociatedObject(c, kMineT);
    NSNumber *mo = objc_getAssociatedObject(c, kMineO);
    CGPoint curP = L.position; CATransform3D curT = L.transform;
    BOOL mine = mp && mt && mo && fabs(curP.x - mp.CGPointValue.x) < 0.05 && fabs(curP.y - mp.CGPointValue.y) < 0.05 &&
                csT3Near(curT, mt.CATransform3DValue) && fabs(L.opacity - mo.floatValue) < 0.01;
    if (!mine) {
        objc_setAssociatedObject(c, kSysP, [NSValue valueWithCGPoint:curP], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(c, kSysT, [NSValue valueWithCATransform3D:curT], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(c, kSysO, @(L.opacity), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(c, kSysZ, @(L.zPosition), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    NSValue *spv = objc_getAssociatedObject(c, kSysP), *stv = objc_getAssociatedObject(c, kSysT);
    if (!spv || !stv) return s;
    s.pos = spv.CGPointValue; s.t = stv.CATransform3DValue;
    NSNumber *so = objc_getAssociatedObject(c, kSysO);
    NSNumber *sz = objc_getAssociatedObject(c, kSysZ);
    s.op = so ? so.doubleValue : 1.0;
    s.z = sz ? sz.doubleValue : 0.0;
    if (!isfinite(s.pos.x) || !isfinite(s.pos.y)) return s;
    CGAffineTransform st = CATransform3DGetAffineTransform(s.t);
    s.sc = hypot(st.a, st.b);
    s.scr = [sv convertPoint:s.pos toView:nil];
    s.ok = YES;
    return s;
}

static const void *kHid = &kHid;

// Smooth circular morph + @3x Liquid Glass Rim & Outer Halo overlay + Cached CGPath
static void csSetCircleMorph(UIView *c, BOOL on, double kMorph, double highlightK) {
    CALayer *L = c.layer;
    CAShapeLayer *mine = objc_getAssociatedObject(c, kCircleMask);
    CAShapeLayer *rim = objc_getAssociatedObject(c, kCircleRim);
    UIImageView *glassView = objc_getAssociatedObject(c, kGlassRimView);
    UIImageView *haloView = objc_getAssociatedObject(c, kHaloView);

    if (!on || kMorph <= 0.01) {
        if ([objc_getAssociatedObject(c, kMaskSaved) boolValue]) {
            L.mask = objc_getAssociatedObject(c, kOrigMask);
            objc_setAssociatedObject(c, kOrigMask, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(c, kMaskSaved, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        } else if (mine && L.mask == mine) {
            L.mask = nil;
        }
        if (rim) rim.hidden = YES;
        if (glassView) glassView.hidden = YES;
        if (haloView) haloView.hidden = YES;
        return;
    }

    if (![objc_getAssociatedObject(c, kMaskSaved) boolValue]) {
        objc_setAssociatedObject(c, kOrigMask, L.mask, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(c, kMaskSaved, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    CGFloat bw = c.bounds.size.width, bh = c.bounds.size.height;
    if (bw < 1 || bh < 1) return;

    if (!mine) {
        mine = [CAShapeLayer layer];
        mine.fillColor = UIColor.blackColor.CGColor;
        mine.contentsScale = csScreenScale();
        objc_setAssociatedObject(c, kCircleMask, mine, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (!rim) {
        rim = [CAShapeLayer layer];
        rim.fillColor = UIColor.clearColor.CGColor;
        rim.contentsScale = csScreenScale();
        [L addSublayer:rim];
        objc_setAssociatedObject(c, kCircleRim, rim, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    // Quintic smoothstep for silkier interactive morph progression
    double t = CSClamp(kMorph, 0.0, 1.0);
    double ts = t * t * t * (t * (t * 6.0 - 15.0) + 10.0);
    CGFloat curH = bh + (bw - bh) * ts;
    CGFloat yOff = (bh - curH) * 0.5;
    CGRect targetRect = CGRectMake(0, yOff, bw, curH);
    CGFloat cr = 47.0 + (bw * 0.5 - 47.0) * ts;
    if (cr > curH * 0.5) cr = curH * 0.5;

    CGPathRef cachedUnitPath = csCachedRoundedPath(bw, curH, cr);
    CGAffineTransform shift = CGAffineTransformMakeTranslation(0, yOff);
    CGPathRef path = CGPathCreateCopyByTransformingPath(cachedUnitPath, &shift);

    mine.frame = c.bounds;
    mine.path = path;
    if (L.mask != mine) L.mask = mine;

    // @3x Liquid Glass Rim asset overlay
    UIImage *glassImg = C.glassOverlay ? csLoadAsset(@"glass_rim", NO) : nil;
    if (glassImg) {
        if (!glassView) {
            glassView = [UIImageView new];
            glassView.image = glassImg;
            glassView.contentMode = UIViewContentModeScaleToFill;
            glassView.userInteractionEnabled = NO;
            [c addSubview:glassView];
            objc_setAssociatedObject(c, kGlassRimView, glassView, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        glassView.hidden = NO;
        glassView.frame = targetRect;
        glassView.alpha = (CGFloat)(ts * (0.72 + 0.28 * highlightK));
        if (c.subviews.lastObject != glassView) [c bringSubviewToFront:glassView];
    } else if (glassView) {
        glassView.hidden = YES;
    }

    // @3x Radial Orb Halo asset behind card
    UIImage *haloImg = C.ringGlow ? csLoadAsset(@"orb_halo", YES) : nil;
    if (haloImg && c.superview) {
        if (!haloView) {
            haloView = [UIImageView new];
            haloView.image = haloImg;
            haloView.contentMode = UIViewContentModeScaleToFill;
            haloView.userInteractionEnabled = NO;
            objc_setAssociatedObject(c, kHaloView, haloView, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        if (haloView.superview != c.superview) [c.superview insertSubview:haloView belowSubview:c];
        haloView.hidden = NO;
        haloView.tintColor = [UIColor colorWithHue:fmod(C.glowHue, 360.0) / 360.0 saturation:0.60 brightness:1.0 alpha:1.0];
        CGFloat haloDia = bw * 1.44;
        haloView.bounds = CGRectMake(0, 0, haloDia, haloDia);
        haloView.layer.position = L.position;
        haloView.layer.transform = L.transform;
        haloView.layer.zPosition = L.zPosition - 0.5;
        haloView.alpha = (CGFloat)(ts * (0.20 + 0.72 * highlightK) * (C.glowAmt / 100.0));
    } else if (haloView) {
        haloView.hidden = YES;
    }

    // Glowing crisp rim stroke
    rim.hidden = NO;
    rim.frame = c.bounds;
    rim.path = path;
    if (L.sublayers.lastObject != rim) [L addSublayer:rim];
    UIColor *glowCol = C.ringGlow
        ? [UIColor colorWithHue:fmod(C.glowHue, 360.0) / 360.0 saturation:0.55 brightness:1.0 alpha:(0.45 + 0.50 * highlightK) * ts]
        : [UIColor colorWithWhite:1.0 alpha:(0.35 + 0.45 * highlightK) * ts];
    rim.strokeColor = glowCol.CGColor;
    rim.lineWidth = (2.4 + 3.0 * highlightK) * (bw / 100.0);

    if (path) CGPathRelease(path);
}

static const void *kNeon = &kNeon;
static void csSetNeon(UIView *c, BOOL on, double k) {
    CALayer *L = c.layer;
    if (!on) {
        if ([objc_getAssociatedObject(c, kNeon) boolValue]) { L.shadowOpacity = 0; objc_setAssociatedObject(c, kNeon, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
        return;
    }
    UIColor *g = [UIColor colorWithHue:fmod(C.glowHue, 360.0) / 360.0 saturation:0.55 brightness:1 alpha:1];
    L.shadowColor = g.CGColor; L.shadowOffset = CGSizeZero;
    L.shadowRadius = 10 + 14 * k; L.shadowOpacity = (float)((0.2 + 0.7 * k) * C.glowAmt / 100.0);
    L.shadowPath = csCachedRoundedPath(c.bounds.size.width, c.bounds.size.height, C.cardCorner);
    objc_setAssociatedObject(c, kNeon, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void csHideHead(UIView *h, BOOL hide) {
    BOOL was = [objc_getAssociatedObject(h, kHid) boolValue];
    if (hide) {
        if (!was) objc_setAssociatedObject(h, kHid, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (!h.hidden) h.hidden = YES;
        if (h.alpha > 0.001) h.alpha = 0;
    } else if (was) {
        h.hidden = NO;
        h.alpha = 1;
        objc_setAssociatedObject(h, kHid, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static NSString *csTitleOf(UIView *v, int d) {
    if (d > 6) return nil;
    if ([v isKindOfClass:UILabel.class]) {
        NSString *tx = ((UILabel *)v).text;
        if (tx.length && [tx rangeOfString:@"Bubble"].location == NSNotFound) return tx;
    }
    for (UIView *x in v.subviews) { NSString *t = csTitleOf(x, d + 1); if (t) return t; }
    return nil;
}

static CSLabel *csNameL;
static void csShowName(NSString *t, CGPoint c) {
    if (!t.length || C.namePos == 3) { csNameL.hidden = YES; return; }
    if (!ensureWindow()) return;
    if (!csNameL) {
        csNameL = [CSLabel new]; csNameL.userInteractionEnabled = NO;
        csNameL.textColor = UIColor.whiteColor; csNameL.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
        csNameL.layer.cornerRadius = 14;
        [csRoot.view addSubview:csNameL];
    }
    if (C.namePill) {
        csNameL.backgroundColor = [UIColor colorWithRed:0.08 green:0.10 blue:0.16 alpha:0.86];
        csNameL.layer.masksToBounds = YES;
        csNameL.layer.borderWidth = 0.8;
        csNameL.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.28].CGColor;
        csNameL.layer.shadowOpacity = 0;
    } else {
        csNameL.backgroundColor = UIColor.clearColor;
        csNameL.layer.masksToBounds = NO;
        csNameL.layer.borderWidth = 0;
        csNameL.layer.shadowColor = UIColor.blackColor.CGColor;
        csNameL.layer.shadowOpacity = 0.65;
        csNameL.layer.shadowRadius = 4;
        csNameL.layer.shadowOffset = CGSizeZero;
    }
    if (![csNameL.text isEqualToString:t]) { csNameL.text = t; [csNameL sizeToFit]; }
    CGSize sz = csNameL.bounds.size;
    CGFloat minY = 112.0;
    CGFloat x = csSnapPx(c.x - sz.width / 2.0);
    CGFloat y = csSnapPx(MAX(minY, c.y - sz.height / 2.0));
    csNameL.frame = CGRectMake(x, y, sz.width, sz.height);
    csNameL.hidden = NO;
}

static void csRestore(UIView *c, CSSys s) {
    if (![objc_getAssociatedObject(c, kApplied) boolValue]) return;
    csSetCircleMorph(c, NO, 0, 0);
    csSetNeon(c, NO, 0);
    csApplyCrispness(c, 0, NO);
    csApplyCardMotionBlur(c, 0);
    CALayer *L = c.layer;
    L.position = s.pos; L.transform = s.t; L.opacity = (float)s.op; L.zPosition = (CGFloat)s.z; L.doubleSided = YES;
    objc_setAssociatedObject(c, kApplied, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(c, kMineP, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(c, kMineT, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(c, kMineO, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(c, kStableSlot, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void csStamp(UIView *c) {
    CALayer *L = c.layer;
    objc_setAssociatedObject(c, kMineP, [NSValue valueWithCGPoint:L.position], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(c, kMineT, [NSValue valueWithCATransform3D:L.transform], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(c, kMineO, @(L.opacity), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(c, kApplied, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static NSArray *csCards, *csHeads;
static __weak UIView *csCacheRoot;
static NSUInteger csCacheSig;
static double csNextScan;

static NSUInteger csSigOf(void) {
    UIView *a = csCards.firstObject, *b = csHeads.firstObject;
    return a.superview.subviews.count * 131 + b.superview.subviews.count + csCards.count * 7 + csHeads.count;
}

static BOOL csCacheValid(UIView *root) {
    if (!csCards.count || csCacheRoot != root) return NO;
    for (UIView *c in csCards) if (!c.window) return NO;
    return csSigOf() == csCacheSig;
}

static void csRefresh(UIView *root) {
    if (csCacheValid(root)) return;
    double now = CACurrentMediaTime();
    if (now < csNextScan) return;
    NSMutableArray *cards = [NSMutableArray array], *heads = [NSMutableArray array];
    int budget = 1600;
    csCollect(root, 0, cards, heads, &budget);
    csCards = cards; csHeads = heads; csCacheRoot = root; csCacheSig = csSigOf();
    if (!cards.count) csNextScan = now + 0.25;
}

static void csDeckLayout(UIViewController *vc) {
    if (!C.enabled || C.mode != 0 || csTripped || -[csBoot timeIntervalSinceNow] < 4) return;
    static BOOL busy;
    if (busy || !vc.isViewLoaded) return;
    busy = YES;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    @try {
        csM0VC = vc;
        csEnsureM0Gestures(vc.view);
        csRefresh(vc.view);
        NSArray *cards = csCards, *heads = csHeads;
        int n = (int)MIN((NSUInteger)40, cards.count);
        if (n > 0) {
            double W = UIScreen.mainScreen.bounds.size.width;
            CSSys sy[40]; double bw[40], ssc[40], newX[40], newY[40], ratio[40], cardZ[40];
            BOOL vis[40], act[40]; int order[40], m = 0;
            for (int i = 0; i < n; i++) {
                UIView *c = cards[i];
                sy[i] = csCapture(c);
                bw[i] = MAX(1, c.bounds.size.width);
                ssc[i] = sy[i].sc * bw[i] / W;
                vis[i] = sy[i].ok && !c.hidden && sy[i].op > 0.01 && ssc[i] > 0.02;
                act[i] = NO;
                cardZ[i] = -1e9;
                if (vis[i]) order[m++] = i;
            }

            BOOL hasLockedSlots = csM0Active;
            if (hasLockedSlots) {
                for (int a = 0; a < m; a++) {
                    if (!objc_getAssociatedObject(cards[order[a]], kStableSlot)) { hasLockedSlots = NO; break; }
                }
            }
            if (hasLockedSlots) {
                for (int a = 1; a < m; a++) {
                    int t = order[a], b = a - 1;
                    int st = [objc_getAssociatedObject(cards[t], kStableSlot) intValue];
                    while (b >= 0 && [objc_getAssociatedObject(cards[order[b]], kStableSlot) intValue] > st) {
                        order[b + 1] = order[b]; b--;
                    }
                    order[b + 1] = t;
                }
            } else {
                for (int a = 1; a < m; a++) {
                    int t = order[a], b = a - 1;
                    while (b >= 0 && sy[order[b]].scr.x > sy[t].scr.x) { order[b + 1] = order[b]; b--; }
                    order[b + 1] = t;
                }
            }

            if (m > 0) {
                int capM = MIN(m, C.count);
                int ctr = 0; double bestCtr = 1e9;
                for (int j = 0; j < capM; j++) {
                    double d = fabs(sy[order[j]].scr.x - W / 2);
                    if (d < bestCtr) { bestCtr = d; ctr = j; }
                }
                double step = capM > 0 ? (360.0 / capM) : 360.0;
                csM0Step = step;
                csM0Count = capM;

                double avgK = 0;
                for (int j = 0; j < capM; j++) avgK += clampd((0.92 - ssc[order[j]]) / 0.30, 0, 1);
                avgK /= MAX(1, capM);

                // Velocity-coupled motion blur & dynamic swipe banking
                double nowTs = CACurrentMediaTime();
                double dt = csM0LastTs > 0 ? clampd(nowTs - csM0LastTs, 0.004, 0.05) : 0.016;
                csM0LastTs = nowTs;
                double signedDRot = normDeg(csM0Rot - csM0LastRot);
                double dRot = fabs(signedDRot);
                csM0LastRot = csM0Rot;
                double dK = fabs(avgK - csM0LastAvgK);
                csM0LastAvgK = avgK;

                double spinVel = dRot / dt;
                double morphVel = dK / dt;
                double targetBlur = 0;
                if (C.motionBlurOn) {
                    double spinFactor = clampd((spinVel - 35.0) / 460.0, 0.0, 1.0);
                    double morphFactor = (avgK > 0.03 && avgK < 0.97) ? clampd(morphVel / 2.2, 0.0, 1.0) : 0.0;
                    targetBlur = C.moveBlur * MAX(spinFactor, morphFactor * 0.95);
                }
                if (targetBlur < 0.08 && csM0SmoothBlur < 0.18) csM0SmoothBlur = 0;
                else csM0SmoothBlur = csM0SmoothBlur * 0.42 + targetBlur * 0.58;

                double targetBank = C.velTilt ? CSClamp((signedDRot / dt) * 0.00024, -0.105, 0.105) : 0.0;
                csM0SmoothBank = csM0SmoothBank * 0.60 + targetBank * 0.40;
                if (fabs(csM0SmoothBank) < 0.002) csM0SmoothBank = 0;

                if (avgK > 0.06 && !csM0Active) {
                    csM0Active = YES;
                    csM0Rot = ctr * step;
                    csM0LastRot = csM0Rot;
                    csM0Anim = 0;
                    csM0Spring.active = NO;
                    csM0FrontSlot = ctr;
                    for (int j = 0; j < capM; j++) {
                        objc_setAssociatedObject(cards[order[j]], kStableSlot, @(j), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                    }
                    csSetScrollEnabled(vc.view, NO);
                } else if (avgK <= 0.06 && csM0Active) {
                    csM0Active = NO;
                    csM0Anim = 0;
                    csM0Spring.active = NO;
                    csM0FrontSlot = -1;
                    csM0SmoothBlur = 0;
                    csM0SmoothBank = 0;
                    csSetScrollEnabled(vc.view, YES);
                }

                CSRingCfg cfg = csCfgWithBank(csM0SmoothBank);
                BOOL circ = C.style <= 1;
                int frontIdx = -1;
                NSInteger newFrontSlot = -1;
                double bestPhi = 1e9;

                for (int j = 0; j < m; j++) {
                    int i = order[j]; UIView *c = cards[i];
                    if (j >= capM) {
                        csRestore(c, sy[i]);
                        c.alpha = 0;
                        continue;
                    }
                    double k = clampd((0.92 - ssc[i]) / 0.30, 0, 1);
                    if (k < 0.001) { csRestore(c, sy[i]); continue; }

                    double phi = normDeg(j * step - csM0Rot);
                    if (fabs(phi) < bestPhi) { bestPhi = fabs(phi); frontIdx = i; newFrontSlot = j; }

                    CSPose p = circ ? CSRingPoseCircle(phi, step, cfg, W) : (C.style == 3 ? CSRingPoseStrip(phi, step, cfg) : CSRingPose(phi, cfg));
                    double scale = ssc[i] + (p.scale - ssc[i]) * k;
                    double f = scale * W / bw[i];
                    CGPoint scr = CGPointMake(sy[i].scr.x + (W / 2 + p.x - sy[i].scr.x) * k, sy[i].scr.y + p.y * k);
                    CGPoint pos = [c.superview convertPoint:scr fromView:nil];
                    if (C.crispText) pos = csSnapPoint(pos);

                    double effYaw = p.yaw * k;
                    CATransform3D t = CATransform3DIdentity;
                    if (!C.crispText || fabs(effYaw) > 0.008) {
                        t.m34 = -1.0 / p.perspective;
                        t = CATransform3DRotate(t, effYaw, 0, 1, 0);
                    }
                    t = CATransform3DScale(t, f, f, 1);
                    if (!isfinite(pos.x) || !isfinite(pos.y) || !isfinite(f) || f <= 0.001 || !isfinite(p.z) || !isfinite(p.opacity)) continue;

                    csApplyCrispness(c, 0, C.crispText);

                    double distBlur = (C.style >= 1) ? C.blur * MIN(1.0, fabs(phi) / 110.0) * k : 0;
                    csApplyCardMotionBlur(c, csM0SmoothBlur + distBlur);

                    CALayer *L = c.layer;
                    L.position = pos; L.transform = t;
                    L.opacity = (float)(sy[i].op * (1 + (p.opacity - 1) * k));

                    double zz = (1000.0 + p.z + p.k * 160.0) * k;
                    L.zPosition = zz;
                    L.doubleSided = cos(effYaw) >= 0;

                    csSetCircleMorph(c, circ && C.snapCircle, k, p.k);
                    csSetNeon(c, C.style == 3 && C.ringGlow && k > 0.05, p.k * k);
                    csStamp(c);

                    double hw = (bw[i] * f) / 2.0;
                    double hh = circ ? hw : (c.bounds.size.height * f) / 2.0;
                    csM0Hits[j] = CGRectMake(scr.x - hw, scr.y - hh, hw * 2, hh * 2);
                    csM0Z[j] = zz;
                    cardZ[i] = zz;

                    csLastApply = CACurrentMediaTime();
                    act[i] = YES; newX[i] = scr.x; newY[i] = scr.y;
                    ratio[i] = scale / MAX(0.05, ssc[i]);
                }

                if (csM0Active && newFrontSlot != csM0FrontSlot) {
                    if (csM0FrontSlot != -1) csM0Buzz();
                    csM0FrontSlot = newFrontSlot;
                }

                BOOL any = NO;
                for (int i = 0; i < n; i++) if (act[i]) any = YES;

                if (any) {
                    int zOrd[40], zCnt = 0;
                    for (int i = 0; i < n; i++) if (act[i]) zOrd[zCnt++] = i;
                    for (int a = 1; a < zCnt; a++) {
                        int key = zOrd[a], b = a - 1;
                        while (b >= 0 && cardZ[zOrd[b]] > cardZ[key]) { zOrd[b + 1] = zOrd[b]; b--; }
                        zOrd[b + 1] = key;
                    }
                    for (int a = 0; a < zCnt; a++) {
                        UIView *cv = cards[zOrd[a]];
                        if (cv.superview) {
                            UIImageView *hv = objc_getAssociatedObject(cv, kHaloView);
                            if (hv && !hv.hidden && hv.superview == cv.superview) {
                                [cv.superview bringSubviewToFront:hv];
                            }
                            if (cv.superview.subviews.lastObject != cv) {
                                [cv.superview bringSubviewToFront:cv];
                            }
                        }
                    }
                }

                csSuppressSwitcherHeaders(vc.view, 0, any);
                int hn = (int)MIN((NSUInteger)80, heads.count);
                NSString *frontName = nil;
                for (int q = 0; q < hn; q++) {
                    UIView *h = heads[q];
                    if (!any) { csHideHead(h, NO); continue; }
                    csHideHead(h, YES);
                    if (frontIdx >= 0 && !frontName && h.window && [h isDescendantOfView:cards[frontIdx]]) {
                        frontName = csTitleOf(h, 0);
                    }
                }
                if (any && frontIdx >= 0 && !frontName) {
                    frontName = csTitleOf(cards[frontIdx], 0);
                }
                if (any && frontIdx >= 0) {
                    double dia = ratio[frontIdx] * ssc[frontIdx] * W;
                    double hh = circ ? dia : dia * (UIScreen.mainScreen.bounds.size.height / W);
                    double ly = C.namePos == 0 ? newY[frontIdx] - hh / 2 - 22 : (C.namePos == 1 ? newY[frontIdx] : newY[frontIdx] + hh / 2 + 26);
                    csShowName(frontName, CGPointMake(newX[frontIdx], ly));
                } else if (csNameL) {
                    csNameL.hidden = YES;
                }
            }
        }
    } @catch (NSException *e) { csLog(@"deck layout exception: %@", e); }
    [CATransaction commit];
    busy = NO;
}

static void csGuardTick(void) {
    double up = -[csBoot timeIntervalSinceNow];
    double now = CACurrentMediaTime();
    BOOL recent = csLastApply > 0 && now - csLastApply < 3;
    BOOL need = up < 8 || recent;
    if (need && !csMarkerOn) { [@"1" writeToFile:CS_MARKER atomically:NO encoding:NSUTF8StringEncoding error:nil]; csMarkerOn = YES; }
    else if (!need && csMarkerOn) { [NSFileManager.defaultManager removeItemAtPath:CS_MARKER error:nil]; csMarkerOn = NO; }
}

static void csTick(void) {
    if (++csTickCount % 12 == 1) loadCfg();
    csGuardTick();
    if (!C.enabled || C.mode != 2) {
        if (csOverlay.superview && !csOverlay.testMode) csHideOverlay();
        if (C.enabled && C.mode == 1 && -[csBoot timeIntervalSinceNow] > 10) csStaticDump();
        return;
    }
    if (-[csBoot timeIntervalSinceNow] < 4) return;
    if (csOverlay.superview && csOverlay.testMode) return;
    int vis = csDetectVisible();
    BOOL shown = csOverlay.superview != nil;
    if (vis == 1 && !shown && !csForceHidden) csShowOverlay(NO);
    else if (vis == 0) { csForceHidden = NO; if (shown) csHideOverlay(); }
    else if (vis == 1 && shown && csShownAt && -[csShownAt timeIntervalSinceNow] > 90 && ![csOverlay userRecentlyTouched:90]) {
        csForceHidden = YES; csHideOverlay();
    }
    if (shown) for (UIView *b in csBubbles) [csRoot.view bringSubviewToFront:b];
}

static void csTestNote(CFNotificationCenterRef c, void *o, CFStringRef n, const void *obj, CFDictionaryRef ui) {
    dispatch_async(dispatch_get_main_queue(), ^{
        CFPreferencesAppSynchronize(CS_DOMAIN);
        if (prefBool(CFSTR("testShow"), NO)) csShowOverlay(YES); else csHideOverlay();
    });
}

static void csReloadNote(CFNotificationCenterRef c, void *o, CFStringRef n, const void *obj, CFDictionaryRef ui) {
    dispatch_async(dispatch_get_main_queue(), ^{
        loadCfg();
        if (csOverlay.superview) [csOverlay relayout];
        if (csM0VC) csDeckLayout(csM0VC);
    });
}

static void csRespringNote(CFNotificationCenterRef c, void *o, CFStringRef n, const void *obj, CFDictionaryRef ui) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSFileManager.defaultManager removeItemAtPath:CS_MARKER error:nil];
        csMarkerOn = NO;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            id svc = send0((id)NSClassFromString(@"FBSystemService"), @"sharedInstance");
            SEL s = NSSelectorFromString(@"exitAndRelaunch:");
            if (svc && [svc respondsToSelector:s]) ((void (*)(id, SEL, BOOL))objc_msgSend)(svc, s, YES);
            else exit(0);
        });
    });
}

#pragma mark - Hooks

%group FluidHook
%hook SBFluidSwitcherViewController
- (void)viewDidLayoutSubviews {
    %orig;
    csDeckLayout((UIViewController *)self);
}
- (void)viewWillAppear:(BOOL)animated {
    %orig;
    csHookVis = 1;
    csSyncOverlayImmediate();
}
- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    csHookVis = 0;
    csM0Active = NO;
    csM0Spring.active = NO;
    csM0SmoothBlur = 0;
    csM0SmoothBank = 0;
    csSetScrollEnabled(((UIViewController *)self).view, YES);
    csSuppressSwitcherHeaders(((UIViewController *)self).view, 0, NO);
    if (csNameL) csNameL.hidden = YES;
    csSyncOverlayImmediate();
}
%end
%end

%group FluidScroll
%hook SBFluidSwitcherViewController
- (void)scrollViewDidScroll:(UIScrollView *)sv {
    %orig;
    csDeckLayout((UIViewController *)self);
}
%end
%end

%group DeckHook
%hook SBDeckSwitcherViewController
- (void)viewDidLayoutSubviews {
    %orig;
    csDeckLayout((UIViewController *)self);
}
- (void)viewWillAppear:(BOOL)animated {
    %orig;
    csHookVis = 1;
    csSyncOverlayImmediate();
}
- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    csHookVis = 0;
    csM0Active = NO;
    csM0Spring.active = NO;
    csM0SmoothBlur = 0;
    csM0SmoothBank = 0;
    csSetScrollEnabled(((UIViewController *)self).view, YES);
    csSuppressSwitcherHeaders(((UIViewController *)self).view, 0, NO);
    if (csNameL) csNameL.hidden = YES;
    csSyncOverlayImmediate();
}
%end
%end

%group DeckScroll
%hook SBDeckSwitcherViewController
- (void)scrollViewDidScroll:(UIScrollView *)sv {
    %orig;
    csDeckLayout((UIViewController *)self);
}
%end
%end

%group ItemContainerHook
%hook SBFluidSwitcherItemContainer
- (void)layoutSubviews {
    %orig;
    if (csM0Active && csM0VC) {
        csDeckLayout(csM0VC);
    }
}
%end
%end

%ctor {
    if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.springboard"]) return;
    csLines = [NSMutableArray new];
    itemCache = [NSMutableDictionary new];
    csBubbles = [NSMutableArray new];
    csBoot = [NSDate date];
    loadCfg();
    csLog(@"CircleSwitcher v1.5.0 loaded in %@", NSBundle.mainBundle.bundleIdentifier);

    if ([NSFileManager.defaultManager fileExistsAtPath:CS_MARKER]) {
        csTripped = YES;
        [NSFileManager.defaultManager removeItemAtPath:CS_MARKER error:nil];
        int three = 3; CFNumberRef nm = CFNumberCreate(NULL, kCFNumberIntType, &three);
        CFPreferencesSetAppValue(CFSTR("mode"), nm, CS_DOMAIN); CFRelease(nm);
        CFPreferencesAppSynchronize(CS_DOMAIN);
        loadCfg();
        csLog(@"CRASH GUARD: SpringBoard died during startup -> mode set to 3 (inert)");
        return;
    }
    [@"1" writeToFile:CS_MARKER atomically:NO encoding:NSUTF8StringEncoding error:nil];
    csMarkerOn = YES;

    [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationWillTerminateNotification object:nil queue:nil usingBlock:^(NSNotification *n) {
        [NSFileManager.defaultManager removeItemAtPath:CS_MARKER error:nil];
    }];

    Class fluid = NSClassFromString(@"SBFluidSwitcherViewController");
    Class deck = NSClassFromString(@"SBDeckSwitcherViewController");
    Class itemCont = NSClassFromString(@"SBFluidSwitcherItemContainer");
    if (fluid) {
        %init(FluidHook);
        if ([fluid instancesRespondToSelector:@selector(scrollViewDidScroll:)]) { %init(FluidScroll); }
    }
    if (deck && deck != fluid && ![deck isSubclassOfClass:fluid]) {
        %init(DeckHook);
        if ([deck instancesRespondToSelector:@selector(scrollViewDidScroll:)]) { %init(DeckScroll); }
    }
    if (itemCont) {
        %init(ItemContainerHook);
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        CFNotificationCenterRef dc = CFNotificationCenterGetDarwinNotifyCenter();
        CFNotificationCenterAddObserver(dc, NULL, csTestNote, CS_TEST_NOTE, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        CFNotificationCenterAddObserver(dc, NULL, csRespringNote, CS_RESPRING_NOTE, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        CFNotificationCenterAddObserver(dc, NULL, csReloadNote, CS_RELOAD_NOTE, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        NSTimer *tm = [NSTimer timerWithTimeInterval:0.25 repeats:YES block:^(NSTimer *t) { csTick(); }];
        [NSRunLoop.mainRunLoop addTimer:tm forMode:NSRunLoopCommonModes];
    });
}
