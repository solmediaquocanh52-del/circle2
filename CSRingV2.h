// CSRingV2.h - 3D Ring Geometry, SafeArea Adaptation & Critically Damped Spring Physics
// style: 0 = flat ring + center bubble, 1 = 3D glass orb ring, 2 = 3D cards, 3 = neon strip
#ifndef CSRING_V2_H
#define CSRING_V2_H
#include <math.h>

typedef struct {
    double radius, tilt, cam, size, off;
    int count;
    int style;
    double iconSize, centerSize, gap;
    double velBank;
    double screenW, screenH;
} CSRingCfg;

typedef struct {
    double x, y;        // offset from center (pt)
    double z;           // zPosition
    double scale;       // width ratio relative to screen width
    double yaw;         // radians around Y axis
    double opacity;     // 0..1
    double perspective; // P for m34
    double dia;         // circle diameter (pt)
    double k;           // 0..1 focus weight (1 = front center)
} CSPose;

typedef struct {
    double pos;
    double vel;
    double target;
    BOOL active;
} CSSpring1D;

static inline double CSMaxD(double a, double b) { return a > b ? a : b; }
static inline double CSMinD(double a, double b) { return a < b ? a : b; }
static inline double CSClamp(double v, double a, double b) { return v < a ? a : (v > b ? b : v); }

// 2ms sub-stepped critically damped spring solver (stable across 60Hz and 120Hz ProMotion)
static inline void CSSpringStep(CSSpring1D *s, double dt, double stiffness, double damping) {
    if (!s || !s->active) return;
    double rem = CSClamp(dt, 0.0005, 0.05);
    const double maxSub = 0.002;
    while (rem > 0.0) {
        double h = rem < maxSub ? rem : maxSub;
        double disp = s->pos - s->target;
        double acc = -stiffness * disp - damping * s->vel;
        s->vel += acc * h;
        s->pos += s->vel * h;
        rem -= h;
    }
    if (fabs(s->pos - s->target) < 0.035 && fabs(s->vel) < 0.35) {
        s->pos = s->target;
        s->vel = 0.0;
        s->active = NO;
    }
}

static inline double CSAdaptiveScale(double W, double H) {
    double shortSide = CSMinD(W, H);
    if (shortSide <= 1.0) return 1.0;
    // Scale gracefully from iPhone SE (375pt) through iPhone Pro Max (430pt) to iPad (768pt+)
    if (shortSide > 600.0) return CSMinD(1.45, shortSide / 460.0);
    return CSClamp(shortSide / 390.0, 0.90, 1.15);
}

static inline CSPose CSRingPose(double phi, CSRingCfg c) {
    const double P = 900.0;
    double adapt = CSAdaptiveScale(c.screenW, c.screenH);
    double r = phi * M_PI / 180.0, e = c.cam * M_PI / 180.0, R = c.radius * 2.2 * adapt;
    double depth = R * cos(r) - R;
    double z = depth * cos(e), y = depth * sin(e);
    double s = 1.0 / (1.0 - z / P);
    CSPose p;
    p.x = R * sin(r) * s;
    p.y = c.off + y * s;
    p.z = z;
    p.scale = 0.50 * c.size / 100.0 * s;
    p.yaw = -c.tilt * CSClamp(phi / 45.0, -1, 1) * M_PI / 180.0 + c.velBank * 0.65;
    p.opacity = 0.45 + 0.55 * (cos(r) + 1.0) / 2.0;
    p.perspective = P;
    p.dia = 0; p.k = 0;
    return p;
}

static inline CSPose CSRingPoseStrip(double phi, double step, CSRingCfg c) {
    CSPose p = CSRingPose(phi * c.gap / 100.0, c);
    double k = CSClamp(1.0 - fabs(phi) / CSMaxD(step, 1.0), 0, 1);
    double ks = k * k * (3.0 - 2.0 * k);
    p.k = ks;
    p.scale *= (0.82 + 0.32 * ks);
    return p;
}

static inline CSPose CSRingPoseCircle(double phi, double step, CSRingCfg c, double W) {
    const double P = 900.0;
    double adapt = CSAdaptiveScale(W, c.screenH > 0 ? c.screenH : 844.0);
    double r = phi * M_PI / 180.0;
    double k = CSClamp(1.0 - fabs(phi) / CSMaxD(step, 1.0), 0, 1);
    double ks = k * k * (3.0 - 2.0 * k);
    double sz = (c.size / 100.0) * adapt;
    CSPose p;
    p.perspective = P; p.k = ks;
    if (c.style == 0) {
        double R = c.radius * 1.25 * adapt;
        p.x = R * sin(r); p.y = c.off - R * cos(r); p.z = 0;
        p.yaw = c.velBank * 0.35;
        p.dia = 68.0 * c.iconSize / 100.0 * sz * (1.0 + 0.45 * ks);
        p.opacity = 1.0;
    } else {
        double R = c.radius * 1.48 * adapt, e = c.cam * M_PI / 180.0;
        double depth = R * cos(r) - R;
        double z = depth * cos(e), y = depth * sin(e);
        double s = 1.0 / (1.0 - z / P);
        double small = 70.0 * c.iconSize / 100.0 * sz * s;
        double big = 224.0 * c.centerSize / 100.0 * sz;
        p.x = R * sin(r) * s; p.y = c.off + y * s; p.z = z;
        // Strictly bound yaw <= 6 deg so circular orbs NEVER pinch into vertical strips
        double maxOrbYaw = CSMinD(6.0, CSMaxD(0.0, c.tilt * 0.16));
        p.yaw = -maxOrbYaw * CSClamp(phi / 60.0, -1, 1) * M_PI / 180.0 + c.velBank * 0.45;
        p.dia = small + (big - small) * ks;
        p.opacity = 0.62 + 0.38 * (cos(r) + 1.0) / 2.0;
    }
    p.scale = p.dia / CSMaxD(W, 1.0);
    return p;
}

static inline void CSRingGlowRect(CSRingCfg c, double *x, double *y, double *rx, double *ry) {
    double adapt = CSAdaptiveScale(c.screenW, c.screenH);
    if (c.style == 0) { double R = c.radius * 1.25 * adapt; *x = 0; *y = c.off; *rx = R; *ry = R; return; }
    double R = c.radius * 1.48 * adapt, e = c.cam * M_PI / 180.0;
    *x = 0; *rx = R * 0.92; *ry = CSMaxD(10.0, R * sin(e) * 0.92); *y = c.off - *ry;
}

#endif
