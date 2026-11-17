#import "CSRootListController.h"
#import <QuartzCore/QuartzCore.h>
#import "../CSRingV2.h"

#define CS_DOMAIN CFSTR("com.vn.circleswitcher")
#define CS_TEST_NOTE CFSTR("com.vn.circleswitcher/test")
#define CS_RESPRING_NOTE CFSTR("com.vn.circleswitcher/respring")
#define CS_RELOAD_NOTE CFSTR("com.vn.circleswitcher/reload")

static double csPrefD(CFStringRef key, double def) {
    CFPropertyListRef v = CFPreferencesCopyAppValue(key, CS_DOMAIN);
    if (!v) return def;
    double r = def;
    if (CFGetTypeID(v) == CFNumberGetTypeID()) CFNumberGetValue(v, kCFNumberDoubleType, &r);
    CFRelease(v);
    return r;
}

static BOOL csPrefB(CFStringRef key, BOOL def) {
    CFPropertyListRef v = CFPreferencesCopyAppValue(key, CS_DOMAIN);
    if (!v) return def;
    BOOL r = def;
    if (CFGetTypeID(v) == CFBooleanGetTypeID()) r = CFBooleanGetValue(v);
    else if (CFGetTypeID(v) == CFNumberGetTypeID()) { int n = 0; CFNumberGetValue(v, kCFNumberIntType, &n); r = (n != 0); }
    CFRelease(v);
    return r;
}

static double csNormDeg(double a) {
    a = fmod(a + 180.0, 360.0);
    if (a < 0) a += 360.0;
    return a - 180.0;
}

static UIColor *csColorFromHex(NSString *hex) {
    if (!hex.length) return [UIColor systemBlueColor];
    NSString *clean = [hex stringByReplacingOccurrencesOfString:@"#" withString:@""];
    unsigned int rgb = 0;
    [[NSScanner scannerWithString:clean] scanHexInt:&rgb];
    return [UIColor colorWithRed:((rgb >> 16) & 0xFF) / 255.0
                           green:((rgb >> 8) & 0xFF) / 255.0
                            blue:(rgb & 0xFF) / 255.0
                           alpha:1.0];
}

static UIImage *csBundleImg(NSString *name) {
    NSBundle *b = [NSBundle bundleForClass:NSClassFromString(@"CSRootListController")];
    if (b) {
        UIImage *im = [UIImage imageNamed:name inBundle:b compatibleWithTraitCollection:nil];
        if (im) return im;
    }
    NSArray *paths = @[
        [NSString stringWithFormat:@"/var/jb/Library/PreferenceBundles/CircleSwitcherPrefs.bundle/%@@3x.png", name],
        [NSString stringWithFormat:@"/var/jb/Library/Application Support/CircleSwitcher/%@@3x.png", name],
        [NSString stringWithFormat:@"/Library/Application Support/CircleSwitcher/%@@3x.png", name]
    ];
    for (NSString *p in paths) {
        UIImage *raw = [UIImage imageWithContentsOfFile:p];
        if (raw && raw.CGImage) {
            return [UIImage imageWithCGImage:raw.CGImage scale:3.0 orientation:UIImageOrientationUp];
        }
    }
    return nil;
}

static UIImage *csBadgeIcon(NSString *symbolName, UIColor *bgColor) {
    if (!symbolName.length) return nil;
    CGSize sz = CGSizeMake(29, 29);
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
    fmt.opaque = NO;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:sz format:fmt];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, 29, 29) cornerRadius:6.8];
        [bgColor setFill];
        [path fill];

        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:15.5 weight:UIImageSymbolWeightSemibold];
        UIImage *sym = [[UIImage systemImageNamed:symbolName withConfiguration:cfg] imageWithTintColor:UIColor.whiteColor renderingMode:UIImageRenderingModeAlwaysOriginal];
        if (sym) {
            CGSize s = sym.size;
            [sym drawInRect:CGRectMake((29 - s.width) / 2.0, (29 - s.height) / 2.0, s.width, s.height)];
        }
    }];
}

@interface CSPreviewView : UIView
@property (nonatomic, strong) CAShapeLayer *glowRing;
@property (nonatomic, strong) UIView *centerBubble;
@property (nonatomic, strong) NSMutableArray<UIView *> *cards;
@property (nonatomic, strong) UILabel *statusBadge;
@property (nonatomic, strong) CADisplayLink *link;
@property (nonatomic, assign) double rot, vel;
@property (nonatomic, assign) CSSpring1D spring;
- (void)reloadPreview;
@end

@implementation CSPreviewView

- (instancetype)initWithFrame:(CGRect)f {
    if ((self = [super initWithFrame:f])) {
        self.backgroundColor = [UIColor colorWithRed:0.06 green:0.08 blue:0.13 alpha:1.0];
        self.layer.cornerRadius = 18;
        self.layer.borderWidth = 1;
        self.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.14].CGColor;
        self.clipsToBounds = YES;

        _glowRing = [CAShapeLayer layer];
        _glowRing.fillColor = nil;
        _glowRing.lineWidth = 3.5;
        [self.layer addSublayer:_glowRing];

        _centerBubble = [UIView new];
        _centerBubble.backgroundColor = [UIColor colorWithRed:0.15 green:0.28 blue:0.65 alpha:0.55];
        _centerBubble.layer.borderWidth = 1.2;
        _centerBubble.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.5].CGColor;
        [self addSubview:_centerBubble];

        _cards = [NSMutableArray array];

        _statusBadge = [[UILabel alloc] initWithFrame:CGRectMake(12, 10, 185, 22)];
        _statusBadge.font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
        _statusBadge.textColor = [UIColor colorWithRed:0.45 green:0.78 blue:1.0 alpha:1.0];
        _statusBadge.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
        _statusBadge.layer.cornerRadius = 11;
        _statusBadge.clipsToBounds = YES;
        _statusBadge.textAlignment = NSTextAlignmentCenter;
        [self addSubview:_statusBadge];

        UILabel *hint = [[UILabel alloc] initWithFrame:CGRectMake(12, f.size.height - 24, f.size.width - 24, 18)];
        hint.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
        hint.text = @"Vuốt trái / phải để thử vật lý lò xo 3D";
        hint.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
        hint.textColor = [UIColor colorWithWhite:1 alpha:0.55];
        hint.textAlignment = NSTextAlignmentCenter;
        [self addSubview:hint];

        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onPan:)];
        [self addGestureRecognizer:pan];
        [self reloadPreview];
    }
    return self;
}

- (void)dealloc {
    if (_link) { [_link invalidate]; _link = nil; }
}

- (void)startLink {
    if (!self.link) {
        self.link = [CADisplayLink displayLinkWithTarget:self selector:@selector(onFrame:)];
        [self.link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    }
    self.link.paused = NO;
}

- (void)onFrame:(CADisplayLink *)l {
    double dt = MAX(0.001, l.targetTimestamp - l.timestamp);
    double stiff = 240.0 * (CSClamp(csPrefD(CFSTR("springStiffness"), 100), 50, 180) / 100.0);
    double damp = 2.0 * sqrt(stiff) * 0.92;
    if (_spring.active) {
        CSSpringStep(&_spring, dt, stiff, damp);
        self.rot = _spring.pos;
        if (!_spring.active) l.paused = YES;
        [self reloadPreview];
    } else {
        l.paused = YES;
    }
}

- (void)onPan:(UIPanGestureRecognizer *)g {
    CGPoint t = [g translationInView:self];
    [g setTranslation:CGPointZero inView:self];
    int count = (int)lround(csPrefD(CFSTR("count"), 8));
    if (count < 3) count = 3;
    double step = 360.0 / count;
    if (g.state == UIGestureRecognizerStateBegan) {
        _spring.active = NO;
    } else if (g.state == UIGestureRecognizerStateChanged) {
        self.rot -= t.x * (step / 90.0);
        [self reloadPreview];
    } else if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled) {
        double v = -[g velocityInView:self].x * (step / 90.0);
        double projected = self.rot + v * 0.14;
        _spring.pos = self.rot;
        _spring.vel = v;
        _spring.target = round(projected / step) * step;
        _spring.active = YES;
        [self startLink];
    }
}

- (void)reloadPreview {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    CFPreferencesAppSynchronize(CS_DOMAIN);
    CSRingCfg cfg;
    cfg.radius = csPrefD(CFSTR("radius"), 125) * 0.62;
    cfg.tilt = csPrefD(CFSTR("tilt"), 32);
    cfg.cam = csPrefD(CFSTR("cam"), 22);
    cfg.size = csPrefD(CFSTR("size"), 100) * 0.62;
    cfg.off = csPrefD(CFSTR("off"), 0) * 0.5;
    cfg.count = (int)lround(csPrefD(CFSTR("count"), 8));
    if (cfg.count < 3) cfg.count = 3;
    if (cfg.count > 12) cfg.count = 12;
    cfg.style = (int)csPrefD(CFSTR("style"), 1);
    cfg.iconSize = csPrefD(CFSTR("iconSize"), 100);
    cfg.centerSize = csPrefD(CFSTR("centerSize"), 100);
    cfg.gap = csPrefD(CFSTR("gap"), 100);
    cfg.velBank = 0;

    NSArray *styleNames = @[@"Vòng phẳng", @"Vòng tròn kính 3D", @"Thẻ 3D", @"Dải Neon"];
    NSString *stName = (cfg.style >= 0 && cfg.style < 4) ? styleNames[cfg.style] : @"Vòng tròn kính 3D";
    self.statusBadge.text = [NSString stringWithFormat:@"%@ • %d app", stName, cfg.count];

    BOOL ringGlow = csPrefB(CFSTR("ringGlow"), YES);
    BOOL glassOverlay = csPrefB(CFSTR("glassOverlay"), YES);
    double glowHue = csPrefD(CFSTR("glowHue"), 215);
    double glowAmt = csPrefD(CFSTR("glowAmt"), 75);
    double cardCorner = csPrefD(CFSTR("cardCorner"), 28);
    UIImage *glassImg = glassOverlay ? csBundleImg(@"glass_rim") : nil;

    while ((int)self.cards.count < cfg.count) {
        UIView *v = [UIView new];
        v.layer.borderWidth = 1.5;
        UIImageView *rim = [[UIImageView alloc] initWithFrame:v.bounds];
        rim.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        rim.tag = 99;
        [v addSubview:rim];
        [self addSubview:v];
        [self.cards addObject:v];
    }
    while ((int)self.cards.count > cfg.count) {
        [self.cards.lastObject removeFromSuperview];
        [self.cards removeLastObject];
    }

    CGFloat W = self.bounds.size.width > 10 ? self.bounds.size.width : 350;
    CGFloat H = self.bounds.size.height > 10 ? self.bounds.size.height : 206;
    CGFloat cx = W / 2.0, cy = H * 0.50;
    double step = 360.0 / cfg.count;
    BOOL circ = (cfg.style <= 1);

    if (circ && ringGlow) {
        double gx, gy, rx, ry;
        CSRingGlowRect(cfg, &gx, &gy, &rx, &ry);
        UIColor *g = [UIColor colorWithHue:fmod(glowHue, 360.0) / 360.0 saturation:0.65 brightness:1 alpha:1];
        self.glowRing.path = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(cx + gx - rx, cy + gy - ry, rx * 2, ry * 2)].CGPath;
        self.glowRing.strokeColor = [g colorWithAlphaComponent:0.8].CGColor;
        self.glowRing.shadowColor = g.CGColor;
        self.glowRing.shadowOpacity = 0.85;
        self.glowRing.shadowRadius = 8;
        self.glowRing.hidden = NO;
    } else {
        self.glowRing.hidden = YES;
    }

    self.centerBubble.hidden = (cfg.style != 0);
    if (cfg.style == 0) {
        double bd = 118.0 * cfg.centerSize / 100.0 * cfg.size / 100.0;
        self.centerBubble.bounds = CGRectMake(0, 0, bd, bd);
        self.centerBubble.center = CGPointMake(cx, cy + cfg.off);
        self.centerBubble.layer.cornerRadius = bd / 2.0;
    }

    NSArray *palette = @[
        [UIColor systemBlueColor], [UIColor systemIndigoColor], [UIColor systemPinkColor],
        [UIColor systemTealColor], [UIColor systemOrangeColor], [UIColor systemPurpleColor],
        [UIColor systemGreenColor], [UIColor systemRedColor]
    ];

    NSMutableArray *order = [NSMutableArray array];
    for (int i = 0; i < cfg.count; i++) {
        UIView *card = self.cards[i];
        card.backgroundColor = palette[i % palette.count];
        UIImageView *rim = (UIImageView *)[card viewWithTag:99];
        double phi = csNormDeg(i * step - self.rot);
        CSPose p = circ ? CSRingPoseCircle(phi, step, cfg, W) : (cfg.style == 3 ? CSRingPoseStrip(phi, step, cfg) : CSRingPose(phi, cfg));

        if (circ) {
            card.bounds = CGRectMake(0, 0, 100, 100);
            card.layer.cornerRadius = 50;
            rim.image = glassImg;
            rim.hidden = (glassImg == nil);
            double f = p.dia / 100.0;
            card.center = CGPointMake(cx + p.x, cy + p.y);
            CATransform3D t = CATransform3DIdentity;
            t.m34 = -1.0 / p.perspective;
            t = CATransform3DRotate(t, p.yaw, 0, 1, 0);
            t = CATransform3DScale(t, f, f, 1);
            card.layer.transform = t;
        } else {
            rim.hidden = YES;
            CGFloat cw = 72 * cfg.size / 100.0, ch = 122 * cfg.size / 100.0;
            card.bounds = CGRectMake(0, 0, cw, ch);
            card.layer.cornerRadius = (cfg.style == 3) ? cardCorner * 0.6 : 12;
            card.center = CGPointMake(cx + p.x, cy + p.y);
            CATransform3D t = CATransform3DIdentity;
            t.m34 = -1.0 / p.perspective;
            t = CATransform3DRotate(t, p.yaw, 0, 1, 0);
            if (cfg.style == 3) {
                double kk = CSClamp(1.0 - fabs(phi) / MAX(step, 1.0), 0, 1);
                double ks = kk * kk * (3.0 - 2.0 * kk);
                double fsc = 0.80 + 0.30 * ks;
                t = CATransform3DScale(t, fsc, fsc, 1);
            }
            card.layer.transform = t;
        }

        UIColor *g = [UIColor colorWithHue:fmod(glowHue, 360.0) / 360.0 saturation:0.55 brightness:1 alpha:1];
        card.layer.borderColor = (cfg.style == 3 || circ ? g : [UIColor colorWithWhite:1 alpha:0.6]).CGColor;
        if (ringGlow && (circ || cfg.style == 3)) {
            card.layer.shadowColor = g.CGColor;
            card.layer.shadowOffset = CGSizeZero;
            card.layer.shadowRadius = 8;
            card.layer.shadowOpacity = (float)((0.3 + 0.6 * p.k) * (cfg.style == 3 ? glowAmt / 100.0 : 1.0));
        } else {
            card.layer.shadowOpacity = 0;
        }
        card.alpha = p.opacity;
        card.layer.zPosition = p.z + p.k * 5;
        [order addObject:card];
    }
    [order sortUsingComparator:^NSComparisonResult(UIView *a, UIView *b) {
        return a.layer.zPosition < b.layer.zPosition ? NSOrderedAscending : NSOrderedDescending;
    }];
    for (UIView *c in order) [self bringSubviewToFront:c];
    [self bringSubviewToFront:self.statusBadge];
    [CATransaction commit];
}
@end

@implementation CSRootListController {
    CSPreviewView *_preview;
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
        for (PSSpecifier *spec in _specifiers) {
            NSString *sym = [spec propertyForKey:@"sfSymbol"];
            if (sym.length) {
                NSString *hex = [spec propertyForKey:@"sfColor"];
                UIImage *badge = csBadgeIcon(sym, csColorFromHex(hex));
                if (badge) [spec setProperty:badge forKey:@"iconImage"];
            }
        }
    }
    return _specifiers;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Respring"
                                                                              style:UIBarButtonItemStyleDone
                                                                             target:self
                                                                             action:@selector(respringAction)];

    CGFloat W = self.view.bounds.size.width;
    UIView *headerWrap = [[UIView alloc] initWithFrame:CGRectMake(0, 0, W, 304)];

    UIImageView *banner = [[UIImageView alloc] initWithFrame:CGRectMake(16, 10, W - 32, 72)];
    banner.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    banner.backgroundColor = [UIColor colorWithRed:0.08 green:0.11 blue:0.20 alpha:1.0];
    banner.image = csBundleImg(@"prefs_banner");
    banner.contentMode = UIViewContentModeScaleAspectFill;
    banner.layer.cornerRadius = 16;
    banner.clipsToBounds = YES;

    UIImageView *logo = [[UIImageView alloc] initWithFrame:CGRectMake(12, 16, 40, 40)];
    logo.backgroundColor = [UIColor colorWithWhite:1 alpha:0.12];
    logo.layer.cornerRadius = 11;
    logo.layer.borderWidth = 0.8;
    logo.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.25].CGColor;
    logo.contentMode = UIViewContentModeCenter;
    logo.image = [[UIImage systemImageNamed:@"circle.hexagongrid.fill"
                          withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:20 weight:UIImageSymbolWeightBold]]
                  imageWithTintColor:[UIColor colorWithRed:0.48 green:0.75 blue:1.0 alpha:1.0]
                  renderingMode:UIImageRenderingModeAlwaysOriginal];
    [banner addSubview:logo];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(62, 15, W - 180, 22)];
    title.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    title.text = @"CircleSwitcher";
    title.textColor = UIColor.whiteColor;
    title.font = [UIFont systemFontOfSize:17 weight:UIFontWeightBold];
    [banner addSubview:title];

    UILabel *sub = [[UILabel alloc] initWithFrame:CGRectMake(62, 38, W - 110, 17)];
    sub.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    sub.text = @"Liquid Glass @3x • Vật lý lò xo 120Hz";
    sub.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    sub.textColor = [UIColor colorWithWhite:1 alpha:0.78];
    [banner addSubview:sub];

    UILabel *ver = [[UILabel alloc] initWithFrame:CGRectMake(W - 118, 16, 74, 20)];
    ver.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    ver.text = @"v1.5.0";
    ver.font = [UIFont systemFontOfSize:10 weight:UIFontWeightBold];
    ver.textColor = [UIColor colorWithRed:0.55 green:0.82 blue:1.0 alpha:1.0];
    ver.backgroundColor = [UIColor colorWithWhite:1 alpha:0.14];
    ver.layer.cornerRadius = 10;
    ver.clipsToBounds = YES;
    ver.textAlignment = NSTextAlignmentCenter;
    [banner addSubview:ver];

    [headerWrap addSubview:banner];

    _preview = [[CSPreviewView alloc] initWithFrame:CGRectMake(16, 90, W - 32, 204)];
    _preview.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [headerWrap addSubview:_preview];

    self.tableView.tableHeaderView = headerWrap;
}

- (id)readPreferenceValue:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    id defaultVal = [specifier propertyForKey:@"default"];
    if (!key) return defaultVal;
    CFPropertyListRef v = CFPreferencesCopyAppValue((__bridge CFStringRef)key, CS_DOMAIN);
    if (!v) return defaultVal;
    return (__bridge_transfer id)v;
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    if (!key) return;
    CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)value, CS_DOMAIN);
    CFPreferencesAppSynchronize(CS_DOMAIN);
    [_preview reloadPreview];
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CS_RELOAD_NOTE, NULL, NULL, YES);
}

- (void)testOverlayAction {
    CFPreferencesSetAppValue(CFSTR("testShow"), kCFBooleanTrue, CS_DOMAIN);
    CFPreferencesAppSynchronize(CS_DOMAIN);
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CS_TEST_NOTE, NULL, NULL, YES);
}

- (void)resetDefaultsAction {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Đặt lại mặc định?"
                                                                message:@"Khôi phục toàn bộ thông số kính 3D, vật lý lò xo và độ nét về giá trị gốc."
                                                         preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"Hủy" style:UIAlertActionStyleCancel handler:nil]];
    [ac addAction:[UIAlertAction actionWithTitle:@"Đặt lại" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        NSArray *keys = @[
            @"enabled", @"mode", @"style", @"crispText", @"motionBlurOn", @"glassOverlay", @"velTilt",
            @"springStiffness", @"count", @"radius", @"tilt", @"cam", @"size",
            @"iconSize", @"centerSize", @"gap", @"off", @"cardCorner", @"snapCircle",
            @"ringGlow", @"glowHue", @"glowAmt", @"blur", @"moveBlur", @"dim", @"bgBlur",
            @"namePos", @"namePill", @"icon", @"nameIcon", @"onlyFront", @"ram",
            @"dots", @"chevron", @"inertia", @"haptic", @"openAnim", @"openSpeed",
            @"bubOn", @"bubSize", @"keepPinned", @"debug"
        ];
        for (NSString *k in keys) {
            CFPreferencesSetAppValue((__bridge CFStringRef)k, NULL, CS_DOMAIN);
        }
        CFPreferencesAppSynchronize(CS_DOMAIN);
        [self reloadSpecifiers];
        [_preview reloadPreview];
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CS_RELOAD_NOTE, NULL, NULL, YES);
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)respringAction {
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CS_RESPRING_NOTE, NULL, NULL, YES);
}

@end
