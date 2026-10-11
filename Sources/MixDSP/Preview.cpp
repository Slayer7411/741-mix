// Vorhör-Player: Rendern (Audio-Thread) und C-Schnittstelle (MixDSPPreview.h).
#include "Preview.h"
#include "MixDSPPreview.h"
#include <algorithm>

namespace {
constexpr double kRampS = 0.005;     // Ein-/Ausblenden bei Start, Pause, Sprung, Wechsel
constexpr double kEdgeS = 0.003;     // Rampe an geschnittenen Rändern (wie die Decks)
inline float clip(float x) { return x > 1.f ? 1.f : (x < -1.f ? -1.f : (x == x ? x : 0.f)); }
}

void mdpv_render(MDPreview &p, float **out, int channels, int n, double fs) {
    // neuer Track: erst ausblenden, dann übernehmen
    if (p.pendingGen.load(std::memory_order_acquire) && (p.gain <= 0 || p.cur.frames <= 0)) {
        if (uint32_t g = p.pendingGen.exchange(0, std::memory_order_acq_rel)) {
            p.cur = p.slots[g & 1]; p.curGen = g;
            p.pos = p.cur.start * p.cur.rate; p.seekTo = NAN; p.gain = 0;
            p.consumedGen.store(g, std::memory_order_release);
        }
    }
    double s = p.pendingSeek.exchange(NAN);
    if (!std::isnan(s)) p.seekTo = s;
    uint32_t q = p.trimSeq.load(std::memory_order_acquire);
    if (q != p.seenTrim && !(q & 1)) {
        double ts = p.trimStartReq.load(std::memory_order_relaxed), te = p.trimEndReq.load(std::memory_order_relaxed);
        std::atomic_thread_fence(std::memory_order_acquire);
        if (p.trimSeq.load(std::memory_order_relaxed) == q) { p.trimS = ts; p.trimE = te; p.seenTrim = q; }
    }
    const MDPreview::Slot &t = p.cur;
    float decay = 0.8f;
    if (t.frames <= 0 || !t.L || !t.R) {
        p.rms.store(p.rms.load() * decay); p.peak.store(p.peak.load() * decay); p.routed.store(-1);
        return;
    }
    // hörbarer Bereich (Frames): Schnitt, sonst die ganze Datei
    double fr = double(t.frames), lo = p.trimS * t.rate, hi = p.trimE * t.rate;
    if (!(hi > 0) || hi > fr) hi = fr;
    if (!(lo > 0)) lo = 0;
    if (!(hi > lo)) { lo = 0; hi = fr; }
    double edge = std::min(kEdgeS * t.rate, (hi - lo) / 2);
    double fadeIn = lo > 0 ? edge : 0, fadeOut = hi < fr ? edge : 0;

    bool play = p.curGen != 0 && p.playGen.load() == p.curGen;
    if (!std::isnan(p.seekTo) && (p.gain <= 0 || !play)) { p.pos = std::clamp(p.seekTo * t.rate, lo, hi); p.seekTo = NAN; }
    if (p.pos < lo) p.pos = lo;   // Schnitt-Anfang nach hinten verschoben
    if (play && p.pos >= hi) {    // Ende (Schnitt geändert oder erreicht)
        uint32_t g = p.curGen;
        p.playGen.compare_exchange_strong(g, 0);
        play = false;
    }
    if (!play && p.gain <= 0) {
        p.rms.store(p.rms.load() * decay); p.peak.store(p.peak.load() * decay); p.routed.store(-1);
        p.posOut.store((std::isnan(p.seekTo) ? std::min(p.pos, hi) : p.seekTo * t.rate) / t.rate);
        return;
    }

    int ch = p.outCh.load();
    bool exists = ch >= 0 && ch + 1 < channels;
    bool write = exists && !p.mute.load();
    p.routed.store(exists ? ch : -1);
    float *oL = write ? out[ch] : nullptr, *oR = write ? out[ch + 1] : nullptr;
    float target = play && std::isnan(p.seekTo) ? 1.f : 0.f, step = float(1.0 / (kRampS * fs));
    float vol = p.volume.load();
    double inc = t.rate / fs;
    float sum = 0, pk = 0;
    for (int i = 0; i < n; i++) {
        p.gain = p.gain < target ? std::min(target, p.gain + step) : std::max(target, p.gain - step);
        p.volSm += (vol - p.volSm) * 0.002f;
        float l = 0, r = 0;
        if (p.gain > 0 && p.pos < hi) {
            int64_t k = int64_t(p.pos), k1 = std::min(k + 1, t.frames - 1);
            float f = float(p.pos - double(k));
            l = t.L[k] + (t.L[k1] - t.L[k]) * f;
            r = t.R[k] + (t.R[k1] - t.R[k]) * f;
            double g = 1;
            if (p.pos < lo + fadeIn) g = (p.pos - lo) / fadeIn;
            if (p.pos > hi - 1 - fadeOut) g = std::min(g, (hi - 1 - p.pos) / fadeOut);
            float m = float(std::max(0.0, g)) * p.gain * p.volSm;
            l *= m; r *= m;
            if (!(std::isfinite(l) && std::isfinite(r))) l = r = 0;   // kaputte Samples: still
            p.pos += inc;
        }
        sum += (l * l + r * r) * 0.5f; pk = std::max(pk, std::max(std::fabs(l), std::fabs(r)));
        if (write) { oL[i] = clip(oL[i] + l); oR[i] = clip(oR[i] + r); }
    }
    if (play && p.pos >= hi) { uint32_t g = p.curGen; p.playGen.compare_exchange_strong(g, 0); }
    float rms = std::sqrt(sum / float(std::max(1, n)));
    p.rms.store(p.rms.load() * 0.7f + rms * 0.3f);
    p.peak.store(std::max(pk, p.peak.load() * 0.85f));
    p.posOut.store((std::isnan(p.seekTo) ? std::min(p.pos, hi) : p.seekTo * t.rate) / t.rate);
}

extern "C" {

uint32_t mdsp_preview_set_track(MDEngine *e, const float *left, const float *right, int64_t frames, double rate, double start) {
    MDPreview &p = mdsp_preview_of(e);
    p.playGen.store(0);
    uint32_t gen = ++p.loadGen;
    if (gen == 0) gen = ++p.loadGen;
    if (!(rate > 0) || !std::isfinite(rate)) rate = 44100;
    if (!left || !right || frames < 0) { left = right = nullptr; frames = 0; }
    p.slots[gen & 1] = MDPreview::Slot{left, right, frames, rate, std::isfinite(start) ? std::max(0.0, start) : 0};
    p.pendingSeek.store(NAN);
    p.pendingGen.store(gen, std::memory_order_release);
    return gen;
}

bool mdsp_preview_track_consumed(MDEngine *e, uint32_t gen) {
    return int32_t(mdsp_preview_of(e).consumedGen.load(std::memory_order_acquire) - gen) >= 0;
}

void mdsp_preview_play(MDEngine *e, bool play) {
    MDPreview &p = mdsp_preview_of(e);
    p.playGen.store(play ? p.loadGen : 0);
}

void mdsp_preview_seek(MDEngine *e, double s) {
    if (!std::isfinite(s)) return;
    MDPreview &p = mdsp_preview_of(e);
    double ts = p.trimStartReq.load(std::memory_order_relaxed), te = p.trimEndReq.load(std::memory_order_relaxed);
    s = std::max(s, std::max(0.0, ts));
    if (te > ts) s = std::min(s, te);
    p.pendingSeek.store(s);
}

void mdsp_preview_set_trim(MDEngine *e, double s, double en) {
    if (!std::isfinite(s) || !std::isfinite(en)) return;
    s = std::max(0.0, s);
    if (en <= 0) en = 0;
    else if (en <= s) { s = 0; en = 0; }
    MDPreview &p = mdsp_preview_of(e);
    p.trimSeq.fetch_add(1, std::memory_order_acq_rel);
    p.trimStartReq.store(s, std::memory_order_relaxed); p.trimEndReq.store(en, std::memory_order_relaxed);
    p.trimSeq.fetch_add(1, std::memory_order_release);
}

void mdsp_preview_set_volume(MDEngine *e, float v) { if (std::isfinite(v)) mdsp_preview_of(e).volume.store(std::clamp(v, 0.f, 2.f)); }

void mdsp_preview_set_output(MDEngine *e, int ch, bool mute) {
    MDPreview &p = mdsp_preview_of(e);
    p.outCh.store(ch < 0 ? -1 : ch); p.mute.store(mute);
}

double mdsp_preview_position(MDEngine *e) {
    MDPreview &p = mdsp_preview_of(e);
    double s = p.pendingSeek.load();
    return std::isnan(s) ? p.posOut.load() : s;
}

bool mdsp_preview_playing(MDEngine *e) { return mdsp_preview_of(e).playGen.load() != 0; }

void mdsp_preview_levels(MDEngine *e, float *rms, float *peak) {
    MDPreview &p = mdsp_preview_of(e);
    *rms = p.rms.load(); *peak = p.peak.load();
}

int mdsp_preview_routed(MDEngine *e) { return mdsp_preview_of(e).routed.load(); }

} // extern "C"
