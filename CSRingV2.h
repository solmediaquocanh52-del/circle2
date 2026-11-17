// CSRingV2.h - cong thuc vong 3D DUNG CHUNG cho switcher that (Tweak.x) va khung xem truoc (prefs).
// style: 0 = vong phang (anh mau 1), 1 = vong nghieng 3D (anh mau 2), 2 = the chu nhat (kieu cu), 3 = dai the neon
#ifndef CSRING_V2_H
#define CSRING_V2_H
#include <math.h>

typedef struct {
    double radius, tilt, cam, size, off;
    int count;
    int style;
    double iconSize, centerSize, gap;
} CSRingCfg;

typedef struct {
    double x, y;        // lech so voi tam (px, theo man hinh that)
    double z;           // zPosition
    double scale;       // ti le the so voi chieu rong man hinh
    double yaw;         // radian, quay quanh truc Y
    double opacity;     // 0..1
    double perspective; // P cho m34
    double dia;         // duong kinh hinh tron (px man hinh), 0 neu kieu the
    double k;           // 0..1: muc "dang duoc chon" (1 = o vi tri chinh)
} CSPose;

static inline double CSMaxD(double a, double b) { return a > b ? a : b; }
static inline double CSClamp(double v, double a, double b) { return v < a ? a : (v > b ? b : v); }

static inline CSRingCfg CSRingDefaults(void) {
    CSRingCfg c;
    c.radius = 120; c.tilt = 35; c.cam = 22; c.size = 100; c.off = 0; c.count = 8;
    c.style = 1; c.iconSize = 100; c.centerSize = 100; c.gap = 100;
    return c;
}

// Kieu the chu nhat (cu). phi = goc cua the tren vong (do), 0 = o chinh giua phia truoc
static inline CSPose CSRingPose(double phi, CSRingCfg c) {
    const double P = 900.0;
    double r = phi * M_PI / 180.0, e = c.cam * M_PI / 180.0, R = c.radius * 2.2;
    double depth = R * cos(r) - R;
    double z = depth * cos(e), y = depth * sin(e);
    double s = 1.0 / (1.0 - z / P);
    CSPose p;
    p.x = R * sin(r) * s;
    p.y = c.off + y * s;
    p.z = z;
    p.scale = 0.46 * c.size / 100.0 * s;
    p.yaw = -c.tilt * CSClamp(phi / 45.0, -1, 1) * M_PI / 180.0;
    p.opacity = 0.4 + 0.6 * (cos(r) + 1.0) / 2.0;
    p.perspective = P;
    p.dia = 0; p.k = 0;
    return p;
}

// Kieu 3: dai the 3D phat sang (the chu nhat, the giua to, 2 ben nho va nghieng). gap = khoang cach (%)
static inline CSPose CSRingPoseStrip(double phi, double step, CSRingCfg c) {
    CSPose p = CSRingPose(phi * c.gap / 100.0, c);
    double k = CSClamp(1.0 - fabs(phi) / CSMaxD(step, 1.0), 0, 1);
    double ks = k * k * (3.0 - 2.0 * k);
    p.k = ks;
    p.scale *= (0.80 + 0.30 * ks);
    return p;
}

// Kieu hinh tron. step = goc giua 2 app lien tiep (do). W = chieu rong man hinh (de doi dia -> scale)
static inline CSPose CSRingPoseCircle(double phi, double step, CSRingCfg c, double W) {
    const double P = 900.0;
    double r = phi * M_PI / 180.0;
    double k = CSClamp(1.0 - fabs(phi) / CSMaxD(step, 1.0), 0, 1);
    double ks = k * k * (3.0 - 2.0 * k);
    double sz = c.size / 100.0;
    CSPose p;
    p.perspective = P; p.k = ks;
    if (c.style == 0) {
        // Vong phang: app dang chon o dinh, to hon; o giua la "bong bong" (ve rieng)
        double R = c.radius * 1.25;
        p.x = R * sin(r); p.y = c.off - R * cos(r); p.z = 0; p.yaw = 0;
        p.dia = 62.0 * c.iconSize / 100.0 * sz * (1.0 + 0.45 * ks);
        p.opacity = 1.0;
    } else {
        // Vong nghieng 3D: app dang chon o giua, TO (hinh tron), cac app khac chay vong sau
        double R = c.radius * 1.5, e = c.cam * M_PI / 180.0;
        double depth = R * cos(r) - R;
        double z = depth * cos(e), y = depth * sin(e);
        double s = 1.0 / (1.0 - z / P);
        double small = 64.0 * c.iconSize / 100.0 * sz * s;
        double big = 210.0 * c.centerSize / 100.0 * sz;
        p.x = R * sin(r) * s; p.y = c.off + y * s; p.z = z;
        p.yaw = -c.tilt * CSClamp(phi / 45.0, -1, 1) * M_PI / 180.0;
        p.dia = small + (big - small) * ks;
        p.opacity = 0.45 + 0.55 * (cos(r) + 1.0) / 2.0;
    }
    p.scale = p.dia / CSMaxD(W, 1.0);
    return p;
}

// Hinh elip cua vong sang (tuong doi voi tam): x, y la tam, rx, ry la ban kinh
static inline void CSRingGlowRect(CSRingCfg c, double *x, double *y, double *rx, double *ry) {
    if (c.style == 0) { double R = c.radius * 1.25; *x = 0; *y = c.off; *rx = R; *ry = R; return; }
    double R = c.radius * 1.5, e = c.cam * M_PI / 180.0;
    *x = 0; *rx = R * 0.9; *ry = CSMaxD(10.0, R * sin(e) * 0.9); *y = c.off - *ry;
}

#endif
