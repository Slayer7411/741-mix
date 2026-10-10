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
constexpr float kReverbRef = 0.0175f;     // Hall-Eingangsgewicht bei Pegel 1 (Abgleich: siehe Reverb::run)
constexpr double kReverbLowCut = 200;     // Hz, Hochpass vor dem Hall

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

// ---------- Reverb (Freeverb-Struktur, weich abgestimmt) ----------
// gegen metallischen Klang: Eingangs-Diffusion, gedämpfte Kammfilter, Lesepunkt der Kammfilter schwankt langsam
// um wenige Samples (keine stehenden Resonanzen), sanfter Tiefpass am Ausgang
struct Comb {
    std::vector<float> b; int i = 0; float store = 0;
    float phase = 0, step = 0, mod = 0;   // LFO (Bogenmaß je Sample), aktueller Wert -1…1
    void lfo(int n) { mod = std::sin(phase); phase += step * n; if (phase > 2 * float(kPi)) phase -= 2 * float(kPi); }
    inline float tick(float x, float fb, float damp, float depth) {
        int n = int(b.size());
        // Leseposition vor dem Schreibzeiger: Verzögerung n-1-m, m = 0…depth Samples, gebrochen gelesen
        float rp = float(i) + 1 + depth * (0.5f + 0.5f * mod);
        if (rp >= n) rp -= n;
        int r0 = int(rp), r1 = r0 + 1; if (r1 >= n) r1 = 0;
        float f = rp - float(r0);
        float y = b[r0] + (b[r1] - b[r0]) * f;
        store = y * (1 - damp) + store * damp;
        b[i] = x + store * fb;
        if (++i >= n) i = 0;
        return y;
    }
};
struct Allpass {
    std::vector<float> b; int i = 0;
    inline float tick(float x) {
        float bo = b[i], y = -x + bo;
        b[i] = x + bo * 0.5f;
        if (++i >= int(b.size())) i = 0;
        return y;
    }
};
struct Reverb {
    Comb cL[8], cR[8]; Allpass aL[4], aR[4], inA[2];
    Biquad hp1, hp2, lp;     // nur dieser Frequenzbereich geht in den Hall
    Biquad lowCut;           // fester Hochpass vor dem Hall: Bass/Kick bauen sich in den Kammfiltern sonst stark auf (laut, mulmig)
    std::vector<float> pre; int preW = 0;    // Vorverzögerung (mono, vor der Diffusion), Platz für 200 ms
    float preSm = -1;                        // geglättete Vorverzögerung in Samples (Regler springt nicht hörbar)
    float lastHP = -1, lastLP = -1, lastBright = -1;
    float send = 0, tail = 0;
    float damp = 0.4f;                       // Dämpfung in den Kammfiltern (aus der Helligkeit)
    float outL = 0, outR = 0, out2L = 0, out2R = 0, outA = 0.5f;   // Ausgangs-Tiefpass (zwei Einpole hintereinander, 12 dB/Okt)
    bool active() const { return send > 0.0005f || tail > 1e-5f; }
    void init(double fs) {
        pre.assign(size_t(fs * 0.2) + 1, 0); preW = 0;
        lowCut.highpass(kReverbLowCut, 0.707, fs);
        const int ct[8] = {1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617}, at[4] = {556, 441, 341, 225}, it[2] = {113, 79};
        const float rates[8] = {0.31f, 0.47f, 0.59f, 0.73f, 0.41f, 0.53f, 0.67f, 0.83f};   // Hz, je Kammfilter anders
        double k = fs / 44100.0;
        for (int j = 0; j < 8; j++) {
            cL[j].b.assign(size_t(ct[j] * k), 0); cR[j].b.assign(size_t((ct[j] + 23) * k), 0);
            cL[j].step = float(2 * kPi * rates[j] / fs); cR[j].step = float(2 * kPi * rates[j] * 1.13 / fs);
            cL[j].phase = j * 0.7f; cR[j].phase = j * 0.7f + 1.9f;
        }
        for (int j = 0; j < 4; j++) { aL[j].b.assign(size_t(at[j] * k), 0); aR[j].b.assign(size_t((at[j] + 23) * k), 0); }
        for (int j = 0; j < 2; j++) inA[j].b.assign(size_t(it[j] * k), 0);
        lastBright = -1;
    }
    void clear() {
        std::fill(pre.begin(), pre.end(), 0);
        for (auto &c : cL) { std::fill(c.b.begin(), c.b.end(), 0); c.store = 0; }
        for (auto &c : cR) { std::fill(c.b.begin(), c.b.end(), 0); c.store = 0; }
        for (auto &a : aL) std::fill(a.b.begin(), a.b.end(), 0);
        for (auto &a : aR) std::fill(a.b.begin(), a.b.end(), 0);
        for (auto &a : inA) std::fill(a.b.begin(), a.b.end(), 0);
        send = tail = 0; outL = outR = out2L = out2R = 0;
    }
    /// Send-Effekt: das trockene Signal bleibt unverändert, der Hall kommt dazu.
    /// `level` = wie viel hineingeht (aus = Eingang zu, Hall klingt aus), `wet` = Hall-Anteil am Ausgang.
    /// hpP/lpP 0…1: Hochpass 20 Hz…8 kHz (24 dB), Tiefpass 500 Hz…20 kHz – so entsteht z. B. ein heller Swipe aus den Höhen.
    /// `gain` = Hall-Pegel linear (Einstellung), `bright` 0…1 = Helligkeit, `preS` = Vorverzögerung in Sekunden.
    void run(float *L, float *R, int n, float size, float level, float wet, float hpP, float lpP,
             float gain, float bright, float preS, double fs, bool on, bool loud) {
        if (hpP != lastHP) {
            lastHP = hpP;
            if (hpP < 0.01f) { hp1.setIdentity(); hp2.setIdentity(); }
            else { double f = std::min(20 * std::pow(400.0, double(hpP)), fs * 0.45); hp1.highpass(f, 0.54, fs); hp2.highpass(f, 1.31, fs); }
        }
        if (lpP != lastLP) {
            lastLP = lpP;
            if (lpP > 0.99f) lp.setIdentity(); else lp.lowpass(std::min(500 * std::pow(40.0, double(lpP)), fs * 0.45), 0.707, fs);
        }
        if (bright != lastBright) {
            lastBright = bright;
            float b = std::clamp(bright, 0.f, 1.f);
            damp = 0.6f - 0.45f * b;                                            // dunkel 0,6 … hell 0,15
            outA = float(1 - std::exp(-2 * kPi * 2500 * std::pow(4.8, double(b)) / fs));   // Tiefpass 2,5 … 12 kHz
        }
        float fb = 0.75f + 0.235f * size;                    // Nachhall ~1 s … ~20 s
        float depth = 3.f;                                   // Modulation ±1,5 Samples
        // gleiche Lautheit über Größe: was die kürzere Fahne weniger aufbaut, kommt als Pegel zurück.
        // kReverbRef: gain 1 -> Hall allein ≈ 4 dB unter dem Track, mit Hall ≈ 1,2× so laut wie trocken
        // (rosa Rauschen, volles D/W, gemessen in EngineTests; vorher Single +12 dB, Gruppe +3 dB)
        float g = kReverbRef * std::sqrt((1 - fb) / 0.15f) * gain;
        // Single-Modus: was der Hochpass wegnimmt, kommt als Pegel zurück (Swipe aus den Höhen), max. +35 dB
        if (loud) g *= std::pow(10.f, std::min(35.f, 34 * hpP + std::max(0.f, hpP - 0.7f) * 30) / 20);
        int preLen = int(pre.size());
        float preT = std::clamp(float(preS * fs), 0.f, float(preLen - 2));
        if (preSm < 0) preSm = preT;
        float target = on ? level : 0.f, peak = 0;
        for (int j = 0; j < 8; j++) { cL[j].lfo(n); cR[j].lfo(n); }
        for (int i = 0; i < n; i++) {
            send += (target - send) * 0.002f;
            float x = (L[i] + R[i]) * 0.5f;
            x = lowCut.tick(0, lp.tick(0, hp2.tick(0, hp1.tick(0, x))));
            pre[preW] = x;                                   // Vorverzögerung: erst schreiben, dann preSm Samples zurück lesen (0 = direkt)
            preSm += (preT - preSm) * 0.0005f;
            int d0 = int(preSm); float f = preSm - float(d0);
            int r0 = preW - d0; if (r0 < 0) r0 += preLen;
            int r1 = r0 - 1; if (r1 < 0) r1 += preLen;
            x = pre[r0] + (pre[r1] - pre[r0]) * f;
            if (++preW >= preLen) preW = 0;
            float in = inA[1].tick(inA[0].tick(x * g * send)), ol = 0, orr = 0;
            for (int j = 0; j < 8; j++) { ol += cL[j].tick(in, fb, damp, depth); orr += cR[j].tick(in, fb, damp, depth); }
            for (int j = 0; j < 4; j++) { ol = aL[j].tick(ol); orr = aR[j].tick(orr); }
            outL += outA * (ol - outL); outR += outA * (orr - outR);
            out2L += outA * (outL - out2L); out2R += outA * (outR - out2R);
            L[i] += out2L * wet; R[i] += out2R * wet;
            peak = std::max(peak, std::max(std::fabs(out2L), std::fabs(out2R)));
        }
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
        for (Biquad *b : {&c.reverb.hp1, &c.reverb.hp2, &c.reverb.lp, &c.reverb.lowCut}) b->clearState();   // Reverb::clear() lässt die Filter stehen
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
                         e->fs, reverbOn, dwSend);
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
        e->fxp[u][MDFX_REVERB_LEVEL].store(1); e->fxp[u][MDFX_REVERB_BRIGHT].store(0.4f); e->fxp[u][MDFX_REVERB_PREDELAY].store(0.015f);
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
void mdsp_metronome(MDEngine *e, bool on, float volume, int ch) {
    e->clock.metroOn.store(on); e->clock.metroVol.store(volume); e->clock.metroCh.store(ch);
}

} // extern "C"
