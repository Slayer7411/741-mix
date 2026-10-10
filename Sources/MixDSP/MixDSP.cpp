// MixDSP – Echtzeitkern. Regeln für alles, was in render() läuft:
// keine Sperren, kein new/delete, keine Systemaufrufe, nur vorab angelegter Speicher.
#include "MixDSP.h"
#include "MixDSPAUHost.h"
#include <atomic>
#include <cmath>
#include <cstring>
#include <algorithm>
#include <vector>
#include <memory>
#if defined(__x86_64__) || defined(__i386__)
#include <xmmintrin.h>
#endif


#include "signalsmith-stretch/signalsmith-stretch.h"

namespace {

constexpr int kMaxFrames = MDSP_MAX_FRAMES;
constexpr int kMaxIn = kMaxFrames * 5;   // Eingang je Block bei Tempo bis 4× (+Reserve)
constexpr double kPi = 3.14159265358979323846;
constexpr float kReverbRef = 0.42f;       // Hall-Eingangsgewicht bei Pegel 1 (Abgleich: siehe Reverb::run)

inline float dbToLin(float db) { return db <= -95.f ? 0.f : std::pow(10.f, db / 20.f); }

/// Denormals im Render-Block auf 0 (ausklingende Filter/Hall: auf Intel sonst bis ×100 Rechenzeit je Sample).
/// Setzt die Einstellung des Threads am Ende zurück (Tests/Offline rufen aus fremden Threads).
struct DenormalGuard {
#if defined(__aarch64__)
    uint64_t old;
    DenormalGuard() { asm volatile("mrs %0, fpcr" : "=r"(old)); uint64_t v = old | (uint64_t(1) << 24); asm volatile("msr fpcr, %0" :: "r"(v)); }
    ~DenormalGuard() { asm volatile("msr fpcr, %0" :: "r"(old)); }
#elif defined(__x86_64__) || defined(__i386__)
    unsigned old;
    DenormalGuard() { old = _mm_getcsr(); _mm_setcsr(old | 0x8040); }   // FTZ | DAZ
    ~DenormalGuard() { _mm_setcsr(old); }
#endif
};

// ---------- Biquad (RBJ) ----------
struct Biquad {
    float b0 = 1, b1 = 0, b2 = 0, a1 = 0, a2 = 0;
    float z1[2] = {0, 0}, z2[2] = {0, 0};
    void setIdentity() { b0 = 1; b1 = b2 = a1 = a2 = 0; }
    void clearState() { z1[0] = z1[1] = z2[0] = z2[1] = 0; }
    /// Frequenz unter Nyquist halten: darüber wird der Filter instabil (Geräte mit 16–32 kHz)
    static double safeF(double f, double fs) { return std::clamp(f, 1.0, fs * 0.45); }
    void set(double c0, double c1, double c2, double d0, double d1, double d2) {
        b0 = float(c0 / d0); b1 = float(c1 / d0); b2 = float(c2 / d0); a1 = float(d1 / d0); a2 = float(d2 / d0);
    }
    void lowpass(double f, double q, double fs) {
        f = safeF(f, fs);
        double w = 2 * kPi * f / fs, c = std::cos(w), a = std::sin(w) / (2 * q);
        set((1 - c) / 2, 1 - c, (1 - c) / 2, 1 + a, -2 * c, 1 - a);
    }
    void highpass(double f, double q, double fs) {
        f = safeF(f, fs);
        double w = 2 * kPi * f / fs, c = std::cos(w), a = std::sin(w) / (2 * q);
        set((1 + c) / 2, -(1 + c), (1 + c) / 2, 1 + a, -2 * c, 1 - a);
    }
    void peaking(double f, double q, double db, double fs) {
        f = safeF(f, fs);
        double A = std::pow(10, db / 40), w = 2 * kPi * f / fs, c = std::cos(w), a = std::sin(w) / (2 * q);
        set(1 + a * A, -2 * c, 1 - a * A, 1 + a / A, -2 * c, 1 - a / A);
    }
    void shelf(bool low, double f, double db, double fs) {
        f = safeF(f, fs);
        double A = std::pow(10, db / 40), w = 2 * kPi * f / fs, c = std::cos(w), s = std::sin(w);
        double a = s / 2 * std::sqrt(2.0), sq = 2 * std::sqrt(A) * a;
        if (low) set(A * ((A + 1) - (A - 1) * c + sq), 2 * A * ((A - 1) - (A + 1) * c), A * ((A + 1) - (A - 1) * c - sq),
                     (A + 1) + (A - 1) * c + sq, -2 * ((A - 1) + (A + 1) * c), (A + 1) + (A - 1) * c - sq);
        else set(A * ((A + 1) + (A - 1) * c + sq), -2 * A * ((A - 1) + (A + 1) * c), A * ((A + 1) + (A - 1) * c - sq),
                 (A + 1) - (A - 1) * c + sq, 2 * ((A - 1) - (A + 1) * c), (A + 1) - (A - 1) * c - sq);
    }
    inline float tick(int ch, float x) {
        float y = b0 * x + z1[ch];
        z1[ch] = b1 * x - a1 * y + z2[ch];
        z2[ch] = b2 * x - a2 * y;
        return y;
    }
    void run(float *L, float *R, int n) {
        for (int i = 0; i < n; i++) { L[i] = tick(0, L[i]); R[i] = tick(1, R[i]); }
    }
};

/// Ein-Knopf-Filter: v < 0 Lowpass, v > 0 Highpass, |v| klein = aus
struct SweepFilter {
    Biquad bq;
    float lastV = 999, lastQ = -1;
    bool active = false;
    void update(float v, float res, double fs) {
        if (v == lastV && res == lastQ) return;
        lastV = v; lastQ = res;
        double q = 0.5 + res * 2.0;
        if (v < -0.02f) { bq.lowpass(20000.0 * std::pow(60.0 / 20000.0, -v), q, fs); active = true; }
        else if (v > 0.02f) { bq.highpass(25.0 * std::pow(9000.0 / 25.0, v), q, fs); active = true; }
        else active = false;
    }
    void run(float *L, float *R, int n) { if (active) bq.run(L, R, n); }
};

// ---------- Delay (stereo, beat-synchron gesteuert von außen) ----------
// Aus = Eingang zu, Echo läuft aus (Spillover); erst wenn es verklungen ist, wird nicht mehr gerechnet
struct Delay {
    std::vector<float> bufL, bufR;
    int w = 0;
    float send = 0, tail = 0;
    void init(double fs) { bufL.assign(size_t(fs * 2.1), 0); bufR.assign(size_t(fs * 2.1), 0); }
    void clear() { std::fill(bufL.begin(), bufL.end(), 0); std::fill(bufR.begin(), bufR.end(), 0); send = tail = 0; }
    bool active() const { return send > 0.0005f || tail > 1e-5f; }
    void run(float *L, float *R, int n, double seconds, float feedback, float wet, double fs, bool on) {
        int len = int(bufL.size());
        int d = std::clamp(int(seconds * fs), 1, len - 1);
        float target = on ? 1.f : 0.f, peak = 0;
        for (int i = 0; i < n; i++) {
            send += (target - send) * 0.002f;
            int r = w - d; if (r < 0) r += len;
            float dl = bufL[r], dr = bufR[r];
            bufL[w] = L[i] * send + dl * feedback;
            bufR[w] = R[i] * send + dr * feedback;
            L[i] += dl * wet; R[i] += dr * wet;
            peak = std::max(peak, std::max(std::fabs(dl), std::fabs(dr)));
            if (++w >= len) w = 0;
        }
        tail = peak;
        if (!on && !active()) clear();
    }
};

// ---------- Reverb (Diffusor + FDN mit 16 Leitungen) ----------
// Eingang stereo -> Diffusor (4 Stufen × 8 Kanäle, Hadamard-Mischung, ohne Rückkopplung: dicht ab der ersten ms)
// -> Rückkopplungsnetz aus 16 Verzögerungsleitungen (Primzahl-Längen 30 … 110 ms, Hadamard-Matrix, je Leitung
// Hochregal-Dämpfung: Höhen klingen schneller ab, bleiben aber hörbar), Leselänge jeder Leitung schwankt langsam
// (Allpass-Interpolation, verlustfrei) -> keine stehenden Resonanzen. L/R aus orthogonalen Summen der Leitungen.
// Nachhall 0,4 s … 25 s (Größe 0,9) … 200 s (Größe 1, fast eingefroren).
constexpr int kRvLines = 16, kRvDiffCh = 8, kRvDiffSteps = 4;
constexpr int kRvTank[kRvLines] = {1721, 4447, 1871, 1571, 2887, 3739, 3137, 1447, 2039, 4861, 2221, 1321, 3433, 2647, 4079, 2423};   // Samples bei 44,1 kHz
constexpr int kRvDiff[kRvDiffSteps][kRvDiffCh] = {{1229, 499, 709, 449, 1117, 211, 1693, 1531}, {607, 863, 17, 359, 991, 199, 467, 683},
                                                   {19, 149, 61, 457, 251, 307, 409, 241}, {197, 7, 193, 89, 59, 127, 37, 157}};
constexpr float kRvRates[kRvLines] = {0.28f, 0.58f, 0.43f, 0.78f, 0.33f, 0.68f, 0.47f, 0.93f, 0.72f, 0.18f, 1.02f, 0.53f, 0.83f, 0.38f, 0.62f, 0.22f};   // Hz
constexpr double kRvModMs = 0.35;          // Schwankung der Leselänge ± ms
constexpr double kRvDampHz = 3000;         // Eckfrequenz der Höhen-Dämpfung in den Leitungen
constexpr double kRvBuildS = 2.5;          // Pegelabgleich: gleiche Lautheit nach so langem Einspielen, unabhängig von der Größe

/// Nachhallzeit (s) aus der Größe 0…1
inline double reverbT60(double size) {
    size = std::clamp(size, 0.0, 1.0);
    if (size <= 0.9) return 0.4 * std::pow(25.0 / 0.4, size / 0.9);
    return 25.0 * std::pow(8.0, (size - 0.9) / 0.1);
}

/// Hadamard-Mischung (ungewichtet, schnelle Walsh-Transformation)
template <int N> inline void hadamard(float *v) {
    for (int h = 1; h < N; h *= 2)
        for (int i = 0; i < N; i += 2 * h)
            for (int j = i; j < i + h; j++) { float a = v[j], b = v[j + h]; v[j] = a + b; v[j + h] = a - b; }
}

struct Reverb {
    // Verzögerungen hintereinander in einem Puffer, je Leitung die nächste Zweierpotenz (Maske), ein gemeinsamer
    // Schreibzähler. Zwischen den Leitungen kRvPad Abstand: sonst fallen alle Zugriffe in dieselben Cache-Sätze (Rechenzeit ×3)
    static constexpr int kRvPad = 160;
    std::vector<float> tank; int tOff[kRvLines] = {}, tMask[kRvLines] = {};
    std::vector<float> diff; int dOff[kRvDiffSteps][kRvDiffCh] = {}, dMask[kRvDiffSteps][kRvDiffCh] = {}, diffD[kRvDiffSteps][kRvDiffCh] = {};
    unsigned wpos = 0;                                    // Schreibzähler (läuft über, Masken schneiden zu)
    float base[kRvLines] = {}, depth = 0;                 // Leselänge in Samples, Schwankung ± Samples
    float phase[kRvLines] = {}, step[kRvLines] = {}, mod[kRvLines] = {};   // LFO je Leitung
    float apY[kRvLines] = {};                             // Zustand der Allpass-Interpolation
    float shX[kRvLines] = {}, shY[kRvLines] = {};         // Zustand der Dämpfung
    float b0[kRvLines] = {}, b1[kRvLines] = {}, a1 = 0;   // Dämpfung je Leitung (Gleichanteil-Verstärkung eingerechnet)
    float inGain = 0;                                     // Pegelabgleich über die Größe
    Biquad hp1, hp2, lp;     // nur dieser Frequenzbereich geht in den Hall
    Biquad lowCut;           // Hochpass vor dem Hall (150 … 400 Hz mit der Helligkeit): Bass/Kick machen die Fahne sonst mulmig
    Biquad tilt;             // Höhenregal am Ausgang (Luft): -4 … +6 dB ab 7 kHz mit der Helligkeit
    std::vector<float> preL, preR; int preW = 0;          // Vorverzögerung (stereo, vor dem Diffusor), Platz für 200 ms
    float preSm = -1;                                     // geglättete Vorverzögerung in Samples (Regler springt nicht hörbar)
    float lastHP = -1, lastLP = -1, lastBright = -1, lastSize = -1;
    bool hpOn = false, lpOn = false;
    float send = 0, tail = 0;
    double fs = 44100;
    bool active() const { return send > 0.0005f || tail > 1e-5f; }
    void init(double rate) {
        fs = rate;
        double k = fs / 44100.0;
        preL.assign(size_t(fs * 0.2) + 1, 0); preR.assign(preL.size(), 0); preW = 0;
        depth = float(kRvModMs * 0.001 * fs);
        auto pow2 = [](int n) { int p = 1; while (p < n) p *= 2; return p; };
        int total = 0;
        for (int i = 0; i < kRvLines; i++) {
            base[i] = float(std::round(kRvTank[i] * k));
            int len = pow2(int(base[i] + depth) + 4);
            tOff[i] = total; tMask[i] = len - 1; total += len + kRvPad;
            step[i] = float(2 * kPi * kRvRates[i] / fs); phase[i] = float(i) * 0.9f; mod[i] = std::sin(phase[i]);
        }
        tank.assign(size_t(total), 0);
        total = 0;
        for (int s = 0; s < kRvDiffSteps; s++)
            for (int c = 0; c < kRvDiffCh; c++) {
                diffD[s][c] = std::max(1, int(std::round(kRvDiff[s][c] * k)));
                int len = pow2(diffD[s][c] + 1);
                dOff[s][c] = total; dMask[s][c] = len - 1; total += len + kRvPad;
            }
        diff.assign(size_t(total), 0);
        wpos = 0;
        lastBright = lastSize = -1;
    }
    void clear() {
        std::fill(preL.begin(), preL.end(), 0); std::fill(preR.begin(), preR.end(), 0);
        std::fill(tank.begin(), tank.end(), 0); std::fill(diff.begin(), diff.end(), 0);
        for (int i = 0; i < kRvLines; i++) apY[i] = shX[i] = shY[i] = 0;
        send = tail = 0;
    }
    /// Dämpfung und Pegel aus Größe und Helligkeit (nur bei Änderung)
    void tune(float size, float bright) {
        double t60 = reverbT60(size);
        double hfRatio = 0.35 + 0.55 * bright;            // Nachhall der Höhen ÷ Nachhall gesamt: dunkel 0,35 … hell 0,9
        double K = std::tan(kPi * Biquad::safeF(kRvDampHz, fs) / fs);
        a1 = float((K - 1) / (K + 1));
        for (int i = 0; i < kRvLines; i++) {
            double sec = base[i] / fs;
            double gLo = std::pow(10.0, -3 * sec / t60), gHi = std::pow(10.0, -3 * sec / (t60 * hfRatio));
            double r = gHi / gLo;
            b0[i] = float(gLo * (K + r) / (K + 1)); b1[i] = float(gLo * (K - r) / (K + 1));
        }
        // Energie nach kRvBuildS Einspielen ∝ T60/13,8 · (1 − e^(−13,8 · t / T60)) -> Eingang mit 1/√ davon
        double tau = t60 / 13.8, eff = tau * (1 - std::exp(-kRvBuildS / tau));
        inGain = float(1 / std::sqrt(eff));
    }
    /// Send-Effekt: das trockene Signal bleibt unverändert, der Hall kommt dazu.
    /// `level` = wie viel hineingeht (aus = Eingang zu, Hall klingt aus), `wet` = Hall-Anteil am Ausgang.
    /// hpP/lpP 0…1: Hochpass 20 Hz…8 kHz (24 dB), Tiefpass 500 Hz…20 kHz – so entsteht z. B. ein heller Swipe aus den Höhen.
    /// `gain` = Hall-Pegel linear (Einstellung), `bright` 0…1 = Helligkeit, `preS` = Vorverzögerung in Sekunden.
    void run(float *L, float *R, int n, float size, float level, float wet, float hpP, float lpP,
             float gain, float bright, float preS, bool on, bool loud) {
        if (hpP != lastHP) {
            lastHP = hpP;
            hpOn = hpP >= 0.01f;
            if (!hpOn) { hp1.setIdentity(); hp2.setIdentity(); hp1.clearState(); hp2.clearState(); }
            else { double f = std::min(20 * std::pow(400.0, double(hpP)), fs * 0.45); hp1.highpass(f, 0.54, fs); hp2.highpass(f, 1.31, fs); }
        }
        if (lpP != lastLP) {
            lastLP = lpP;
            lpOn = lpP <= 0.99f;
            if (!lpOn) { lp.setIdentity(); lp.clearState(); } else lp.lowpass(std::min(500 * std::pow(40.0, double(lpP)), fs * 0.45), 0.707, fs);
        }
        bright = std::clamp(bright, 0.f, 1.f); size = std::clamp(size, 0.f, 1.f);
        if (bright != lastBright) {
            lowCut.highpass(150 * std::pow(400.0 / 150, double(bright)), 0.707, fs);
            tilt.shelf(false, 7000, -4 + 10 * double(bright), fs);
        }
        if (bright != lastBright || std::fabs(size - lastSize) > 1e-4f) { lastBright = bright; lastSize = size; tune(size, bright); }
        // kReverbRef: gain 1 -> Hall allein ≈ 4 dB unter dem Track, mit Hall ≈ 1,2× so laut wie trocken (rosa Rauschen, volles D/W)
        float g = kReverbRef * inGain * gain;
        // Single-Modus: was der Hochpass wegnimmt, kommt als Pegel zurück (Swipe aus den Höhen), max. +30 dB.
        // Abgleich an zwei Techno-Tracks: volles D/W gesamt ÷ trocken 1,02 … 1,45 über HP 0 … 0,9 (vorher bis 2,33)
        if (loud) g *= std::pow(10.f, std::min(30.f, 16 * hpP + std::max(0.f, hpP - 0.5f) * 6) / 20);
        int preLen = int(preL.size());
        // ganze Samples als Ziel: ein gebrochener Lesepunkt mittelt zwei Samples (bei 15 ms: -8 dB bei 16 kHz)
        float preT = std::clamp(std::round(float(preS * fs)), 0.f, float(preLen - 2));
        if (preSm < 0) preSm = preT;
        // LFO: Wert am Blockende, dazwischen linear
        float dmod[kRvLines];
        for (int j = 0; j < kRvLines; j++) {
            phase[j] += step[j] * n; if (phase[j] > 2 * float(kPi)) phase[j] -= 2 * float(kPi);
            dmod[j] = (std::sin(phase[j]) - mod[j]) / float(n);
        }
        float target = on ? level : 0.f, peak = 0;
        const float hd = 0.25f, he = 0.35355339f;   // 1/√16, 1/√8
        for (int i = 0; i < n; i++) {
            send += (target - send) * 0.002f;
            float xl = L[i], xr = R[i];
            if (hpOn) { xl = hp2.tick(0, hp1.tick(0, xl)); xr = hp2.tick(1, hp1.tick(1, xr)); }
            if (lpOn) { xl = lp.tick(0, xl); xr = lp.tick(1, xr); }
            xl = lowCut.tick(0, xl); xr = lowCut.tick(1, xr);
            preL[preW] = xl; preR[preW] = xr;               // Vorverzögerung: erst schreiben, dann preSm Samples zurück lesen (0 = direkt)
            preSm += (preT - preSm) * 0.0005f;
            int d0 = int(preSm); float f = preSm - float(d0);
            int r0 = preW - d0; if (r0 < 0) r0 += preLen;
            int r1 = r0 - 1; if (r1 < 0) r1 += preLen;
            xl = preL[r0] + (preL[r1] - preL[r0]) * f; xr = preR[r0] + (preR[r1] - preR[r0]) * f;
            if (++preW >= preLen) preW = 0;
            // Diffusor: je Stufe verzögern, Kanäle tauschen/umpolen, Hadamard
            float gs = g * send * 0.5f;
            float v[kRvDiffCh];
            for (int c = 0; c < kRvDiffCh; c++) v[c] = (c & 1 ? xr : xl) * gs;
            for (int s = 0; s < kRvDiffSteps; s++) {
                float u[kRvDiffCh];
                for (int c = 0; c < kRvDiffCh; c++) {
                    float *b = diff.data() + dOff[s][c];
                    b[wpos & unsigned(dMask[s][c])] = v[c];
                    u[c] = b[(wpos - unsigned(diffD[s][c])) & unsigned(dMask[s][c])];
                }
                for (int c = 0; c < kRvDiffCh; c++) v[c] = ((c + s) & 1 ? -u[(c + 3) & 7] : u[(c + 3) & 7]);
                hadamard<kRvDiffCh>(v);
                for (int c = 0; c < kRvDiffCh; c++) v[c] *= he;
            }
            // Leitungen lesen (Allpass-Interpolation, Bruchteil 0,5 … 1,5), dämpfen, mischen, zurückschreiben.
            // Getrennte Schleifen: Lesen/Schreiben einzeln, der Rest läuft vektorisiert über alle 16 Leitungen
            float y[kRvLines], m[kRvLines], u0[kRvLines], u1[kRvLines], eta[kRvLines];
            int M[kRvLines];
            for (int j = 0; j < kRvLines; j++) {
                mod[j] += dmod[j];
                float D = base[j] + depth * mod[j];
                M[j] = int(D - 0.5f);
                float fr = D - float(M[j]);
                eta[j] = (1 - fr) / (1 + fr);
            }
            for (int j = 0; j < kRvLines; j++) {
                const float *b = tank.data() + tOff[j];
                unsigned mk = unsigned(tMask[j]), r = wpos - unsigned(M[j]);
                u0[j] = b[r & mk]; u1[j] = b[(r - 1) & mk];
            }
            for (int j = 0; j < kRvLines; j++) {
                float out = eta[j] * (u0[j] - apY[j]) + u1[j];
                apY[j] = out; y[j] = out;
                float sh = b0[j] * out + b1[j] * shX[j] - a1 * shY[j];
                shX[j] = out; shY[j] = sh; m[j] = sh * hd;
            }
            hadamard<kRvLines>(m);
            for (int j = 0; j < 8; j++) m[j] += v[j];
            for (int j = 8; j < kRvLines; j++) m[j] += (j & 1) ? -v[(j + 3) & 7] : v[(j + 3) & 7];
            for (int j = 0; j < kRvLines; j++) tank[size_t(tOff[j]) + (wpos & unsigned(tMask[j]))] = m[j];
            wpos++;
            // Ausgang: orthogonale Summen (L/R unkorreliert) + Diffusor-Ausgang als frühe Dichte
            float ol = 0, orr = 0;
            for (int j = 0; j < kRvLines; j++) { ol += y[j]; orr += (j & 1) ? -y[j] : y[j]; }
            float el = 0, er = 0;
            for (int c = 0; c < kRvDiffCh; c++) { el += v[c]; er += (c & 2) ? -v[c] : v[c]; }
            ol = (ol * hd + el * he * 0.5f); orr = (orr * hd + er * he * 0.5f);
            ol = tilt.tick(0, ol); orr = tilt.tick(1, orr);
            L[i] += ol * wet; R[i] += orr * wet;
            peak = std::max(peak, std::max(std::fabs(ol), std::fabs(orr)));
        }
        for (int j = 0; j < kRvLines; j++) mod[j] = std::sin(phase[j]);   // Rundungsfehler der Rampe nicht aufsummieren
        tail = peak;
        if (!on && !active()) clear();
    }
};

// ---------- Plugin (Audio Unit o. ä., über MixDSPAUHost.h) ----------
// wie Delay/Reverb: aus = Eingang zu, Ausgang klingt aus; erst nach 1 s unter -100 dB wird nicht mehr gerechnet
struct PluginSlot {
    std::atomic<MDPlugin *> plugin{nullptr};
    std::atomic<uint64_t> releaseAt{0};   // Render-Zähler, ab dem das vorherige Plugin frei ist
    // nur Audio-Thread
    MDPlugin *last = nullptr;
    float send = 0;
    int quiet = 0x7fffffff;   // Samples in Folge unter der Schwelle
    std::vector<float> dryL, dryR;
    bool tail(double fs) const { return last && quiet < int(fs); }
    bool active(double fs) const { return send > 0.0005f || tail(fs); }
    /// out = dry·(1 − dw·send) + wet·dw – an: klassisches Dry/Wet, aus: trocken + ausklingende Fahne
    void run(MDPlugin *p, float *L, float *R, int n, float dw, bool on, double fs) {
        float target = on ? 1.f : 0.f;
        std::memcpy(dryL.data(), L, sizeof(float) * n); std::memcpy(dryR.data(), R, sizeof(float) * n);
        float s = send;
        for (int i = 0; i < n; i++) { s += (target - s) * 0.002f; L[i] *= s; R[i] *= s; }
        mdplug_process(p, L, R, n);
        float peak = 0;
        for (int i = 0; i < n; i++) {
            send += (target - send) * 0.002f;
            float wl = L[i], wr = R[i];
            if (!std::isfinite(wl)) wl = 0;
            if (!std::isfinite(wr)) wr = 0;
            peak = std::max(peak, std::max(std::fabs(wl), std::fabs(wr)));
            float k = 1 - dw * send;
            L[i] = dryL[i] * k + wl * dw; R[i] = dryR[i] * k + wr * dw;
        }
        if (on || peak >= 1e-5f) quiet = 0; else if (quiet < 0x7fff0000) quiet += n;
    }
};

struct FXChain {   // eine FX-Unit für ein Deck
    SweepFilter filter; Delay delay; Reverb reverb; PluginSlot plug;
};

struct TrackSlot { const float *L = nullptr, *R = nullptr; int64_t frames = 0; double rate = 44100; double start = 0; };

struct Deck {
    // vom Steuer-Thread geschrieben
    std::atomic<float> p[MD_PARAM_COUNT];
    std::atomic<double> pendingSeek{NAN};
    std::atomic<int> loopVersion{0};
    std::atomic<bool> loopActiveReq{false};
    std::atomic<double> loopStartReq{0}, loopEndReq{0};
    // Track-Übergabe: Steuer-Thread füllt Slot (gen & 1) und veröffentlicht gen, Audio-Thread übernimmt und bestätigt
    TrackSlot slots[2];
    std::atomic<uint32_t> pendingGen{0};    // 0 = nichts ausstehend
    std::atomic<uint32_t> consumedGen{0};   // zuletzt übernommene Generation
    uint32_t loadGen = 0;                   // nur Steuer-Thread

    // vom Audio-Thread gelesen/geschrieben, nach außen atomar gespiegelt
    std::atomic<double> posOut{0}, fluxOut{0};
    std::atomic<bool> playingOut{false}, loopActiveOut{false};
    std::atomic<double> loopStartOut{0}, loopEndOut{0};
    std::atomic<float> rms{0}, peak{0};

    // nur Audio-Thread
    TrackSlot cur;
    double pos = 0, flux = 0, inAcc = 0;
    bool loopActive = false; double loopStart = 0, loopEnd = 0; int seenLoop = 0;
    bool wasStretching = false;
    double latSm = 0;   // geglättete Keylock-Latenz (sonst springt die Position bei Tempowechseln)
    int latDir = 1;     // Richtung, in die der Lesekopf der Latenz vorausläuft
    float gainSm = 1, volSm = 0;
    Biquad eqL, eqM, eqH; float lastEq[3] = {999, 999, 999};
    SweepFilter chanFilter;
    FXChain fx[MDSP_FX_UNITS];
    signalsmith::stretch::SignalsmithStretch<float> stretch;
    std::vector<float> inL, inR, outL, outR;

    Deck() {
        for (auto &x : p) x.store(0);
        p[MD_RATE].store(1); p[MD_VOLUME].store(1); p[MD_FILTER_RES].store(0.6f);
    }
};

} // namespace

struct Clock {
    std::atomic<double> bpm{128}, setBeat{NAN}, beatOut{0};
    std::atomic<bool> metroOn{false};
    std::atomic<float> metroVol{0.5f};
    std::atomic<int> metroCh{0};
    double beat = 0;
    // Beat am Blockanfang + Host-Zeit des Blocks (für Link), per Sequenzzähler konsistent lesbar
    std::atomic<uint32_t> stampSeq{0};
    std::atomic<double> stampBeat{0};
    std::atomic<uint64_t> stampHost{0};
    // Klick-Synthese (kurzer Sinus mit Abklingen)
    double clickPhase = 0, clickFreq = 1000; float clickEnv = 0;
};

struct MDEngine {
    double fs;
    Clock clock;
    Deck decks[MDSP_DECKS];
    std::atomic<float> fxp[MDSP_FX_UNITS][MDFX_PARAM_COUNT];
    std::atomic<float> master{0.85f};
    float masterSm = 0.85f;
    uint64_t renderHost = 0;   // setzt der CoreAudio-Callback vor jedem Block
    std::atomic<uint64_t> renders{0};   // fertig gerechnete Blöcke (Plugin-Übergabe)
};

// ---------- Lesen aus dem Track ----------

/// ganzzahlig lesen (für den Keylock-Weg), mit Richtung und Loop
static void readInput(Deck &d, float *L, float *R, int n, int dir) {
    const TrackSlot &t = d.cur;
    for (int i = 0; i < n; i++) {
        int64_t k = int64_t(d.pos);
        if (k >= 0 && k < t.frames) { L[i] = t.L[k]; R[i] = t.R[k]; } else { L[i] = R[i] = 0; }
        d.pos += dir;
        if (d.loopActive) {
            double ls = d.loopStart * t.rate, le = d.loopEnd * t.rate;
            if (dir > 0 && d.pos >= le) d.pos -= (le - ls);
            if (dir < 0 && d.pos < ls) d.pos += (le - ls);
        }
        if (d.pos < 0) d.pos = 0;
    }
}

/// Stretch nach einem Sprung vorfüllen: Audio, das an der aktuellen Position endet (keine Lücke, kein Verschmieren)
static void primeStretch(Deck &d, int dir, double rateSrc) {
    const TrackSlot &t = d.cur;
    int n = std::min(kMaxIn, d.stretch.inputLatency() * 2 + 1024);
    for (int i = 0; i < n; i++) {
        int64_t k = int64_t(d.pos) - int64_t(dir) * (n - i);
        d.inL[i] = (k >= 0 && k < t.frames) ? t.L[k] : 0.f;
        d.inR[i] = (k >= 0 && k < t.frames) ? t.R[k] : 0.f;
    }
    float *ins[2] = {d.inL.data(), d.inR.data()};
    d.stretch.seek(ins, n, rateSrc);
}

/// gebrochen lesen mit 4-Punkt-Hermite (Varispeed, Tonhöhe folgt dem Tempo)
static void readResampled(Deck &d, float *L, float *R, int n, double step) {
    const TrackSlot &t = d.cur;
    auto at = [&](const float *b, int64_t k) -> float { return (k >= 0 && k < t.frames) ? b[k] : 0.f; };
    for (int i = 0; i < n; i++) {
        int64_t k = int64_t(std::floor(d.pos));
        float f = float(d.pos - double(k));
        for (int c = 0; c < 2; c++) {
            const float *b = c == 0 ? t.L : t.R;
            float xm1 = at(b, k - 1), x0 = at(b, k), x1 = at(b, k + 1), x2 = at(b, k + 2);
            float c1 = 0.5f * (x1 - xm1), c2 = xm1 - 2.5f * x0 + 2 * x1 - 0.5f * x2, c3 = 0.5f * (x2 - xm1) + 1.5f * (x0 - x1);
            float y = ((c3 * f + c2) * f + c1) * f + x0;
            (c == 0 ? L : R)[i] = y;
        }
        d.pos += step;
        if (d.loopActive) {
            double ls = d.loopStart * t.rate, le = d.loopEnd * t.rate;
            if (step > 0 && d.pos >= le) d.pos -= (le - ls);
            if (step < 0 && d.pos < ls) d.pos += (le - ls);
        }
        if (d.pos < 0) d.pos = 0;
    }
}

/// NaN/Inf im Deck (kaputte Samples, instabiler Zustand): alle rekursiven Zustände zurück, sonst bleibt das Deck
/// dauerhaft stumm. Läuft im Audio-Thread – nur Füllen vorhandener Puffer.
static void healDeck(Deck &d) {
    for (Biquad *b : {&d.eqL, &d.eqM, &d.eqH, &d.chanFilter.bq}) b->clearState();
    for (auto &c : d.fx) {
        c.filter.bq.clearState(); c.delay.clear(); c.reverb.clear();
        for (Biquad *b : {&c.reverb.hp1, &c.reverb.hp2, &c.reverb.lp, &c.reverb.lowCut, &c.reverb.tilt}) b->clearState();   // Reverb::clear() lässt die Filter stehen
    }
    d.stretch.reset();
    d.wasStretching = false; d.latSm = 0; d.inAcc = 0;
    if (!std::isfinite(d.pos)) d.pos = 0;
    if (!std::isfinite(d.flux)) d.flux = d.pos;
    d.gainSm = 0; d.volSm = 0;   // weich wieder einblenden
}

// ---------- ein Deck rendern und in die Ausgänge mischen ----------

static void renderDeck(MDEngine *e, Deck &d, float **out, int channels, int n) {
    // ausstehende Änderungen übernehmen
    uint32_t pg = d.pendingGen.exchange(0);
    if (pg) {
        d.cur = d.slots[pg & 1];
        d.pos = d.cur.start * d.cur.rate; d.flux = d.pos;
        d.loopActive = false; d.inAcc = 0;
        d.stretch.reset();
        d.consumedGen.store(pg);
    }
    bool jumped = pg != 0;
    double seek = d.pendingSeek.exchange(NAN);
    if (!std::isnan(seek) && d.cur.frames > 0) {
        d.pos = std::max(0.0, seek) * d.cur.rate; d.flux = d.pos; d.inAcc = 0;
        jumped = true;
    }
    int lv = d.loopVersion.load();
    if (lv != d.seenLoop) {
        d.seenLoop = lv;
        d.loopActive = d.loopActiveReq.load(); d.loopStart = d.loopStartReq.load(); d.loopEnd = d.loopEndReq.load();
    }

    bool playing = d.p[MD_PLAYING].load() > 0.5f && d.cur.frames > 0;
    // Keylock aus oder Stopp: Lesekopf (läuft der Stretch-Latenz voraus) auf die hörbare Position zurück
    bool stretchNow = playing && (d.p[MD_KEYLOCK].load() > 0.5f || d.p[MD_KEYSHIFT].load() != 0);
    if (d.wasStretching && !stretchNow) {
        if (!jumped) { d.pos = std::max(0.0, d.pos - d.latSm * d.latDir); d.flux = std::max(0.0, d.flux - d.latSm * d.latDir); }
        d.latSm = 0; d.wasStretching = false;
    }
    // Deck steht: weiterrechnen, solange Echo oder Hall noch klingen (gemessen, kein festes Zeitlimit)
    bool fxTail = false;
    for (int u = 0; u < MDSP_FX_UNITS; u++) {
        if (d.p[MD_FX1_ASSIGN + u].load() > 0.5f &&
            (d.fx[u].delay.tail > 1e-5f || d.fx[u].reverb.tail > 1e-5f || d.fx[u].plug.active(e->fs))) fxTail = true;
    }
    if (!playing && !fxTail) {   // Deck steht, kein Hall/Echo-Rest → nichts rechnen
        d.rms.store(d.rms.load() * 0.8f); d.peak.store(d.peak.load() * 0.8f);
        d.playingOut.store(false);
        d.posOut.store(d.pos / d.cur.rate); d.fluxOut.store(d.flux / d.cur.rate);
        return;
    }

    float *L = d.outL.data(), *R = d.outR.data();
    double rate = std::clamp(double(d.p[MD_RATE].load()), 0.03, 4.0);
    double srcRatio = d.cur.rate / e->fs;
    int dir = d.p[MD_REVERSE].load() > 0.5f ? -1 : 1;
    float keyShift = d.p[MD_KEYSHIFT].load();
    bool stretching = playing && (d.p[MD_KEYLOCK].load() > 0.5f || keyShift != 0);
    bool fluxOn = d.p[MD_FLUX].load() > 0.5f;
    double latencySrc = 0;

    if (!playing) {
        std::memset(L, 0, sizeof(float) * n); std::memset(R, 0, sizeof(float) * n);
    } else if (stretching) {
        if (d.wasStretching && !jumped && dir != d.latDir) {   // Reverse umgeschaltet: von der hörbaren Position aus neu
            d.pos = std::max(0.0, d.pos - d.latSm * d.latDir); d.flux = std::max(0.0, d.flux - d.latSm * d.latDir);
            d.wasStretching = false;
        }
        if (!d.wasStretching || jumped) {
            // Eingang um die Latenz vorauslesen → hörbar exakt an der Zielposition
            d.latSm = d.stretch.inputLatency() + d.stretch.outputLatency() * rate * srcRatio;
            d.latDir = dir;
            d.pos += d.latSm * dir; d.flux += d.latSm * dir;
            primeStretch(d, dir, rate * srcRatio);
        }
        // Eingangslänge für dieses Ausgangsfenster (gebrochen aufsummiert)
        d.inAcc = std::min(d.inAcc + n * rate * srcRatio, double(kMaxIn));   // begrenzt: int-Überlauf bei extremen Raten
        int nIn = std::clamp(int(d.inAcc), 0, kMaxIn);
        d.inAcc -= nIn;
        readInput(d, d.inL.data(), d.inR.data(), nIn, dir);
        double transpose = std::pow(2.0, keyShift / 12.0);
        if (d.p[MD_KEYLOCK].load() <= 0.5f) transpose *= rate;   // ohne Keylock folgt die Tonhöhe dem Tempo
        d.stretch.setTransposeFactor(float(transpose));
        float *ins[2] = {d.inL.data(), d.inR.data()}, *outs[2] = {L, R};
        d.stretch.process(ins, nIn, outs, n);
        latencySrc = d.stretch.inputLatency() + d.stretch.outputLatency() * rate * srcRatio;
    } else {
        readResampled(d, L, R, n, rate * srcRatio * dir);
    }
    d.wasStretching = stretching;

    // Flux: Schattenposition läuft normal weiter, solange Loop/Reverse aktiv
    if (fluxOn && (dir < 0 || d.loopActive)) d.flux += n * rate * srcRatio; else d.flux = d.pos;

    if (playing && d.pos >= double(d.cur.frames)) { d.p[MD_PLAYING].store(0); }

    // Kanalzug: Gain, EQ, Filter
    float g = dbToLin(d.p[MD_GAIN_DB].load());
    float eq[3] = {d.p[MD_EQ_LOW].load(), d.p[MD_EQ_MID].load(), d.p[MD_EQ_HIGH].load()};
    if (eq[0] != d.lastEq[0]) { d.eqL.shelf(true, 100, std::max(-40.f, eq[0]), e->fs); d.lastEq[0] = eq[0]; }
    if (eq[1] != d.lastEq[1]) { d.eqM.peaking(1000, 0.7, std::max(-40.f, eq[1]), e->fs); d.lastEq[1] = eq[1]; }
    if (eq[2] != d.lastEq[2]) { d.eqH.shelf(false, 10000, std::max(-40.f, eq[2]), e->fs); d.lastEq[2] = eq[2]; }
    for (int i = 0; i < n; i++) {
        d.gainSm += (g - d.gainSm) * 0.002f;
        L[i] *= d.gainSm; R[i] *= d.gainSm;
    }
    if (eq[0] != 0) d.eqL.run(L, R, n);
    if (eq[1] != 0) d.eqM.run(L, R, n);
    if (eq[2] != 0) d.eqH.run(L, R, n);
    // Kill: unter -95 dB das Band zusätzlich ganz herausnehmen ist mit Shelf/Peak bei -40 dB praktisch erreicht
    d.chanFilter.update(d.p[MD_FILTER].load(), d.p[MD_FILTER_RES].load(), e->fs);
    d.chanFilter.run(L, R, n);

    // FX-Units
    for (int u = 0; u < MDSP_FX_UNITS; u++) {
        if (d.p[MD_FX1_ASSIGN + u].load() <= 0.5f) continue;
        auto &fp = e->fxp[u];
        float dw = fp[MDFX_DRYWET].load();
        FXChain &c = d.fx[u];
        if (fp[MDFX_FILTER_ON].load() > 0.5f) {
            c.filter.update((fp[MDFX_FILTER_AMOUNT].load() * 2 - 1) * dw, fp[MDFX_FILTER_RES].load(), e->fs);
            c.filter.run(L, R, n);
        }
        bool delayOn = fp[MDFX_DELAY_ON].load() > 0.5f, reverbOn = fp[MDFX_REVERB_ON].load() > 0.5f;
        if (delayOn || c.delay.active()) {
            float a = fp[MDFX_DELAY_AMOUNT].load();
            c.delay.run(L, R, n, fp[MDFX_DELAY_SECONDS].load(), fp[MDFX_DELAY_FEEDBACK].load() * (0.4f + 0.6f * a), a * dw, e->fs, delayOn);
        }
        if (reverbOn || c.reverb.active()) {
            bool dwSend = fp[MDFX_REVERB_DWSEND].load() > 0.5f;
            float amt = fp[MDFX_REVERB_AMOUNT].load();
            c.reverb.run(L, R, n, fp[MDFX_REVERB_SIZE].load(), dwSend ? dw : 1.f, dwSend ? amt : amt * dw,
                         fp[MDFX_REVERB_HP].load(), fp[MDFX_REVERB_LP].load(),
                         fp[MDFX_REVERB_LEVEL].load(), fp[MDFX_REVERB_BRIGHT].load(), fp[MDFX_REVERB_PREDELAY].load(),
                         reverbOn, dwSend);
        }
        MDPlugin *pl = c.plug.plugin.load(std::memory_order_acquire);
        bool plugOn = pl && fp[MDFX_PLUGIN_ON].load() > 0.5f;
        if (pl != c.plug.last) { c.plug.last = pl; c.plug.send = 0; c.plug.quiet = 0x7fffffff; }   // neues Plugin: ohne Fahne
        if (pl && (plugOn || c.plug.active(e->fs))) c.plug.run(pl, L, R, n, dw, plugOn, e->fs);
    }

    // Lautstärke + Ausgangspaar
    float vol = d.p[MD_VOLUME].load();
    int ch = std::clamp(int(d.p[MD_OUT_CHANNEL].load()), 0, std::max(0, channels - 2));
    float *oL = out[ch], *oR = out[std::min(ch + 1, channels - 1)];
    float sum = 0, pk = 0;
    for (int i = 0; i < n; i++) {
        d.volSm += (vol - d.volSm) * 0.002f;
        float l = L[i] * d.volSm, r = R[i] * d.volSm;
        L[i] = l; R[i] = r;
        sum += (l * l + r * r) * 0.5f; pk = std::max(pk, std::max(std::fabs(l), std::fabs(r)));
    }
    if (std::isfinite(sum)) {
        for (int i = 0; i < n; i++) { oL[i] += L[i]; oR[i] += R[i]; }
    } else {   // Block verwerfen (andere Decks bleiben hörbar), Deck zurücksetzen
        healDeck(d);
        sum = pk = 0;
    }
    float rms = std::sqrt(sum / std::max(1, n));
    d.rms.store(d.rms.load() * 0.7f + rms * 0.3f);
    d.peak.store(std::max(pk, d.peak.load() * 0.85f));

    // Zustand nach außen: hörbare Position (Keylock-Latenz abgezogen)
    if (stretching) d.latSm += (latencySrc - d.latSm) * 0.02;   // Latenz hängt leicht vom Tempo ab → glätten
    double heard = std::max(0.0, d.pos - d.latSm * d.latDir);
    d.posOut.store(heard / d.cur.rate);
    d.fluxOut.store(std::max(0.0, d.flux - d.latSm * d.latDir) / d.cur.rate);
    d.playingOut.store(d.p[MD_PLAYING].load() > 0.5f);
    d.loopActiveOut.store(d.loopActive);
    d.loopStartOut.store(d.loopStart); d.loopEndOut.store(d.loopEnd);
}

// ---------- C-Schnittstelle ----------

extern "C" {

MDEngine *mdsp_create(double sampleRate) {
    auto *e = new MDEngine();
    e->fs = sampleRate;
    for (auto &d : e->decks) {
        d.inL.assign(kMaxIn, 0); d.inR.assign(kMaxIn, 0);
        d.outL.assign(kMaxFrames, 0); d.outR.assign(kMaxFrames, 0);
        d.stretch.presetDefault(2, float(sampleRate));
        primeStretch(d, 1, 1.0);   // interne Puffer einmal anlegen (nicht erst im Audio-Thread)
        for (auto &c : d.fx) {
            c.delay.init(sampleRate); c.reverb.init(sampleRate);
            c.plug.dryL.assign(kMaxFrames, 0); c.plug.dryR.assign(kMaxFrames, 0);
        }
    }
    for (auto &u : e->fxp) for (auto &x : u) x.store(0);
    for (int u = 0; u < MDSP_FX_UNITS; u++) {
        e->fxp[u][MDFX_DRYWET].store(1); e->fxp[u][MDFX_DELAY_SECONDS].store(0.46f);
        e->fxp[u][MDFX_DELAY_FEEDBACK].store(0.45f); e->fxp[u][MDFX_REVERB_SIZE].store(0.6f);
        e->fxp[u][MDFX_FILTER_RES].store(0.4f);
        e->fxp[u][MDFX_REVERB_HP].store(0); e->fxp[u][MDFX_REVERB_LP].store(1); e->fxp[u][MDFX_REVERB_DWSEND].store(0);
        e->fxp[u][MDFX_REVERB_LEVEL].store(1); e->fxp[u][MDFX_REVERB_BRIGHT].store(0.6f); e->fxp[u][MDFX_REVERB_PREDELAY].store(0.015f);
        for (auto p : {MDFX_FILTER_AMOUNT, MDFX_DELAY_AMOUNT, MDFX_REVERB_AMOUNT}) e->fxp[u][p].store(0.5f);
    }
    return e;
}

void mdsp_destroy(MDEngine *e) { delete e; }

uint32_t mdsp_set_track(MDEngine *e, int deck, const float *left, const float *right, int64_t frames, double trackRate, double startSeconds) {
    Deck &d = e->decks[deck];
    d.p[MD_PLAYING].store(0);
    uint32_t gen = ++d.loadGen;
    if (gen == 0) gen = ++d.loadGen;   // 0 heißt „nichts ausstehend“
    // Slot der vorletzten Übergabe: längst übernommen oder nie gelesen (von der letzten überholt)
    // Rate 0/NaN (kaputte Datei) → Engine-Rate, sonst Division durch 0 bei jeder Positionsmeldung
    if (!(trackRate > 0) || !std::isfinite(trackRate)) trackRate = e->fs;
    if (!left || !right || frames < 0) { left = right = nullptr; frames = 0; }
    d.slots[gen & 1] = TrackSlot{left, right, frames, trackRate, std::isfinite(startSeconds) ? std::max(0.0, startSeconds) : 0};
    d.pendingGen.store(gen);
    return gen;
}

bool mdsp_track_consumed(MDEngine *e, int deck, uint32_t gen) {
    return int32_t(e->decks[deck].consumedGen.load() - gen) >= 0;
}
void mdsp_set_param(MDEngine *e, int deck, MDParam p, float v) { e->decks[deck].p[p].store(v); }
void mdsp_set_fx(MDEngine *e, int unit, MDFXParam p, float v) { e->fxp[unit][p].store(v); }
void mdsp_set_master(MDEngine *e, float v) { e->master.store(v); }

MDPlugin *mdsp_set_fx_plugin(MDEngine *e, int unit, int deck, MDPlugin *p) {
    PluginSlot &s = e->decks[deck].fx[unit].plug;
    MDPlugin *old = s.plugin.exchange(p, std::memory_order_acq_rel);
    // ein Block, der vor dem Tausch begann, kann das alte noch rechnen – frei erst nach dem nächsten fertigen Block
    s.releaseAt.store(e->renders.load() + 1);
    return old;
}

bool mdsp_fx_plugin_released(MDEngine *e, int unit, int deck, MDPlugin *old) {
    PluginSlot &s = e->decks[deck].fx[unit].plug;
    if (!old) return true;
    if (s.plugin.load() == old) return false;
    return e->renders.load() >= s.releaseAt.load();
}
void mdsp_seek(MDEngine *e, int deck, double s) { e->decks[deck].pendingSeek.store(s); }

void mdsp_set_loop(MDEngine *e, int deck, bool active, double s, double en) {
    Deck &d = e->decks[deck];
    d.loopActiveReq.store(active); d.loopStartReq.store(s); d.loopEndReq.store(en);
    d.loopVersion.fetch_add(1);
    // sofort nach außen sichtbar (Kern fragt direkt danach ab)
    d.loopActiveOut.store(active); d.loopStartOut.store(s); d.loopEndOut.store(en);
}

double mdsp_position(MDEngine *e, int deck) {
    Deck &d = e->decks[deck];
    double s = d.pendingSeek.load();
    return std::isnan(s) ? d.posOut.load() : s;
}
double mdsp_flux_position(MDEngine *e, int deck) { return e->decks[deck].fluxOut.load(); }
bool mdsp_loop(MDEngine *e, int deck, double *s, double *en) {
    Deck &d = e->decks[deck];
    *s = d.loopStartOut.load(); *en = d.loopEndOut.load();
    return d.loopActiveOut.load();
}
bool mdsp_playing(MDEngine *e, int deck) { return e->decks[deck].p[MD_PLAYING].load() > 0.5f; }
void mdsp_levels(MDEngine *e, int deck, float *rms, float *peak) { *rms = e->decks[deck].rms.load(); *peak = e->decks[deck].peak.load(); }

void mdsp_render(MDEngine *e, float **out, int channels, int frames) {
    if (!out || channels <= 0 || frames <= 0) return;
    DenormalGuard ftz;
    for (int c = 0; c < channels; c++) std::memset(out[c], 0, sizeof(float) * frames);
    int done = 0;
    while (done < frames) {
        int n = std::min(kMaxFrames, frames - done);
        float *o[64];
        for (int c = 0; c < channels && c < 64; c++) o[c] = out[c] + done;
        for (auto &d : e->decks) renderDeck(e, d, o, std::min(channels, 64), n);
        done += n;
    }
    float m = e->master.load();
    Clock &k = e->clock;
    double sb = k.setBeat.exchange(NAN);
    if (!std::isnan(sb)) k.beat = sb;
    double beatStart = k.beat;
    double perSample = k.bpm.load() / 60.0 / e->fs;
    bool metro = k.metroOn.load();
    float mv = k.metroVol.load();
    int mc = std::clamp(k.metroCh.load(), 0, std::max(0, channels - 2));
    for (int i = 0; i < frames; i++) {
        e->masterSm += (m - e->masterSm) * 0.002f;
        for (int c = 0; c < channels; c++) {
            float x = out[c][i] * e->masterSm;
            out[c][i] = x > 1.f ? 1.f : (x < -1.f ? -1.f : (x == x ? x : 0.f));   // harte Begrenzung als letzte Sicherung, NaN → 0
        }
        // Clock weiterzählen, bei jedem Beat klicken (Takt-Eins höher)
        double before = k.beat;
        k.beat += perSample;
        if (std::floor(k.beat) != std::floor(before)) {
            long b = long(std::floor(k.beat));
            k.clickFreq = (b % 4 == 0) ? 1600 : 1000;
            k.clickEnv = 1; k.clickPhase = 0;
        }
        if (metro && k.clickEnv > 0.001f) {
            float c = float(std::sin(k.clickPhase)) * k.clickEnv * mv * 0.5f;
            k.clickPhase += 2 * kPi * k.clickFreq / e->fs;
            k.clickEnv *= 0.9985f;
            out[mc][i] += c;
            if (mc + 1 < channels) out[mc + 1][i] += c;
        } else if (k.clickEnv > 0) {
            k.clickEnv *= 0.9985f;
        }
    }
    k.beatOut.store(k.beat);
    k.stampSeq.fetch_add(1, std::memory_order_acq_rel);
    k.stampBeat.store(beatStart, std::memory_order_relaxed);
    k.stampHost.store(e->renderHost, std::memory_order_relaxed);
    k.stampSeq.fetch_add(1, std::memory_order_release);
    e->renders.fetch_add(1);
}

void mdsp_set_render_host(MDEngine *e, uint64_t hostTime) { e->renderHost = hostTime; }

bool mdsp_clock_stamp(MDEngine *e, double *beat, uint64_t *hostTime) {
    Clock &k = e->clock;
    for (int i = 0; i < 8; i++) {
        uint32_t s = k.stampSeq.load(std::memory_order_acquire);
        if (s & 1) continue;
        double b = k.stampBeat.load(std::memory_order_relaxed);
        uint64_t h = k.stampHost.load(std::memory_order_relaxed);
        if (k.stampSeq.load(std::memory_order_acquire) == s) { *beat = b; *hostTime = h; return h != 0; }
    }
    return false;
}

void mdsp_clock_set_bpm(MDEngine *e, double bpm) { e->clock.bpm.store(std::clamp(bpm, 20.0, 300.0)); }
void mdsp_clock_set_beat(MDEngine *e, double beat) { e->clock.setBeat.store(beat); e->clock.beatOut.store(beat); }
double mdsp_clock_beat(MDEngine *e) { return e->clock.beatOut.load(); }
double mdsp_keylock_latency(MDEngine *e) { return e->decks[0].stretch.outputLatency() / e->fs; }
void mdsp_metronome(MDEngine *e, bool on, float volume, int ch) {
    e->clock.metroOn.store(on); e->clock.metroVol.store(volume); e->clock.metroCh.store(ch);
}

} // extern "C"
