// Aufnahme-Ringpuffer (MixDSPRecord.h): ein Schreiber (Audio-Thread), ein Leser (Schreib-Queue).
// Fortlaufende 64-Bit-Zähler für Schreib- und Leseposition, Index = Zähler & Maske. Kein Überschreiben: passt ein Block
// nicht mehr, wird er verworfen und gezählt.
#include "MixDSPRecord.h"
#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdlib>
#include <cstring>
#if defined(__APPLE__)
#include <Accelerate/Accelerate.h>
#endif

struct MDRing {
    float *buf = nullptr;   // verschachtelt L R
    uint64_t cap = 0, mask = 0;
    alignas(64) std::atomic<uint64_t> w{0};
    alignas(64) std::atomic<uint64_t> rd{0};
    std::atomic<bool> armed{false};
    std::atomic<uint32_t> overflows{0};
    std::atomic<uint64_t> dropped{0}, written{0};
    std::atomic<float> peakL{0}, peakR{0};
    // nur Leser: Stand beim letzten Reset
    uint32_t baseOver = 0;
    uint64_t baseDropped = 0, baseWritten = 0;
};

static inline float peakOf(const float *x, int n) {
#if defined(__APPLE__)
    float m = 0;
    vDSP_maxmgv(x, 1, &m, vDSP_Length(n));
    return m;
#else
    float m = 0;
    for (int i = 0; i < n; i++) m = std::max(m, std::fabs(x[i]));
    return m;
#endif
}

static inline void raise(std::atomic<float> &a, float v) {
    if (!(v == v)) return;
    float cur = a.load(std::memory_order_relaxed);
    while (v > cur && !a.compare_exchange_weak(cur, v, std::memory_order_relaxed)) {}
}

extern "C" {

MDRing *mdsp_ring_create(int capacityFrames) {
    uint64_t cap = 1024;
    while (cap < uint64_t(std::max(1, capacityFrames))) cap <<= 1;
    auto *r = new MDRing();
    r->buf = static_cast<float *>(std::calloc(size_t(cap) * 2, sizeof(float)));
    if (!r->buf) { delete r; return nullptr; }
    std::memset(r->buf, 0, size_t(cap) * 2 * sizeof(float));   // Seiten jetzt anfassen, nicht im Audio-Thread
    r->cap = cap; r->mask = cap - 1;
    return r;
}

void mdsp_ring_destroy(MDRing *r) {
    if (!r) return;
    std::free(r->buf);
    delete r;
}

int mdsp_ring_capacity(MDRing *r) { return r ? int(r->cap) : 0; }

void mdsp_ring_write(MDRing *r, const float *L, const float *R, int n) {
    if (!r || !L || n <= 0) return;
    if (!R) R = L;
    raise(r->peakL, peakOf(L, n));
    raise(r->peakR, peakOf(R, n));
    if (!r->armed.load(std::memory_order_acquire)) return;
    uint64_t w = r->w.load(std::memory_order_relaxed);
    uint64_t used = w - r->rd.load(std::memory_order_acquire);
    if (used + uint64_t(n) > r->cap) {
        r->overflows.fetch_add(1, std::memory_order_relaxed);
        r->dropped.fetch_add(uint64_t(n), std::memory_order_relaxed);
        return;
    }
    float *b = r->buf;
    uint64_t m = r->mask;
    int first = int(std::min<uint64_t>(uint64_t(n), r->cap - (w & m)));
    float *o = b + (w & m) * 2;
    for (int i = 0; i < first; i++) { o[2 * i] = L[i]; o[2 * i + 1] = R[i]; }
    for (int i = first; i < n; i++) { b[2 * (i - first)] = L[i]; b[2 * (i - first) + 1] = R[i]; }
    r->w.store(w + uint64_t(n), std::memory_order_release);
    r->written.fetch_add(uint64_t(n), std::memory_order_relaxed);
}

void mdsp_ring_set_armed(MDRing *r, bool on) { if (r) r->armed.store(on, std::memory_order_release); }
bool mdsp_ring_armed(MDRing *r) { return r && r->armed.load(std::memory_order_acquire); }

int mdsp_ring_available(MDRing *r) {
    if (!r) return 0;
    return int(r->w.load(std::memory_order_acquire) - r->rd.load(std::memory_order_relaxed));
}

int mdsp_ring_read(MDRing *r, float *L, float *R, int maxFrames) {
    if (!r || maxFrames <= 0) return 0;
    uint64_t rd = r->rd.load(std::memory_order_relaxed);
    uint64_t avail = r->w.load(std::memory_order_acquire) - rd;
    int n = int(std::min<uint64_t>(avail, uint64_t(maxFrames)));
    const float *b = r->buf;
    for (int i = 0; i < n; i++) {
        uint64_t k = ((rd + uint64_t(i)) & r->mask) * 2;
        if (L) L[i] = b[k];
        if (R) R[i] = b[k + 1];
    }
    r->rd.store(rd + uint64_t(n), std::memory_order_release);
    return n;
}

void mdsp_ring_reset(MDRing *r) {
    if (!r) return;
    r->rd.store(r->w.load(std::memory_order_acquire), std::memory_order_release);
    r->baseOver = r->overflows.load(std::memory_order_relaxed);
    r->baseDropped = r->dropped.load(std::memory_order_relaxed);
    r->baseWritten = r->written.load(std::memory_order_relaxed);
}

uint32_t mdsp_ring_overflows(MDRing *r) { return r ? r->overflows.load(std::memory_order_relaxed) - r->baseOver : 0; }
uint64_t mdsp_ring_dropped_frames(MDRing *r) { return r ? r->dropped.load(std::memory_order_relaxed) - r->baseDropped : 0; }
uint64_t mdsp_ring_written_frames(MDRing *r) { return r ? r->written.load(std::memory_order_relaxed) - r->baseWritten : 0; }

void mdsp_ring_take_peak(MDRing *r, float *l, float *rr) {
    float a = r ? r->peakL.exchange(0, std::memory_order_relaxed) : 0;
    float b = r ? r->peakR.exchange(0, std::memory_order_relaxed) : 0;
    if (l) *l = a;
    if (rr) *rr = b;
}

} // extern "C"
