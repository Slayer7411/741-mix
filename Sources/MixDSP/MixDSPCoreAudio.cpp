#include "MixDSPCoreAudio.h"
#include <mach/mach_time.h>
#include <algorithm>
#include <atomic>
#include <os/workgroup.h>
#include <cstddef>
#include <cstdlib>

namespace {
// DSP-Last: Summen je Abhol-Fenster, Spitze in Promille, Überläufe fortlaufend
struct LoadStats {
    std::atomic<uint64_t> busy{0}, budget{0};
    std::atomic<uint32_t> peak{0}, over{0}, blocks{0};
    std::atomic<double> ticksPerFrame{0};
};
LoadStats gLoad;
}

extern "C" void mdsp_load_set_rate(double fps) {
    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);
    double ticksPerSecond = 1e9 * double(tb.denom) / double(tb.numer);
    gLoad.ticksPerFrame.store(fps > 0 ? ticksPerSecond / fps : 0, std::memory_order_relaxed);
}

extern "C" void mdsp_load_record(uint64_t start, uint64_t end, uint32_t frames) {
    double tpf = gLoad.ticksPerFrame.load(std::memory_order_relaxed);
    if (tpf <= 0 || frames == 0) return;
    uint64_t busy = end - start, budget = uint64_t(double(frames) * tpf);
    if (budget == 0) return;
    gLoad.busy.fetch_add(busy, std::memory_order_relaxed);
    gLoad.budget.fetch_add(budget, std::memory_order_relaxed);
    gLoad.blocks.fetch_add(1, std::memory_order_relaxed);
    uint32_t pm = uint32_t(std::min<uint64_t>(busy * 1000 / budget, 100000));
    uint32_t p = gLoad.peak.load(std::memory_order_relaxed);
    while (pm > p && !gLoad.peak.compare_exchange_weak(p, pm, std::memory_order_relaxed)) {}
    if (busy > budget) gLoad.over.fetch_add(1, std::memory_order_relaxed);
}

extern "C" MDLoad mdsp_load_take(void) {
    MDLoad r;
    uint64_t busy = gLoad.busy.exchange(0, std::memory_order_relaxed), budget = gLoad.budget.exchange(0, std::memory_order_relaxed);
    r.average = budget ? double(busy) / double(budget) : 0;
    r.peak = gLoad.peak.exchange(0, std::memory_order_relaxed) / 1000.0;
    r.blocks = gLoad.blocks.exchange(0, std::memory_order_relaxed);
    r.overloads = gLoad.over.load(std::memory_order_relaxed);
    return r;
}

extern "C" void mdsp_load_reset_overloads(void) { gLoad.over.store(0, std::memory_order_relaxed); }

extern "C" OSStatus mdsp_au_render(void *ref, AudioUnitRenderActionFlags *, const AudioTimeStamp *, UInt32, UInt32 frames,
                                   AudioBufferList *io) {
    auto *e = static_cast<MDEngine *>(ref);
    uint64_t t0 = mach_absolute_time();
    mdsp_set_render_host(e, t0);
    float *out[64];
    int ch = 0;
    for (UInt32 b = 0; b < io->mNumberBuffers && ch < 64; b++) out[ch++] = static_cast<float *>(io->mBuffers[b].mData);
    mdsp_render(e, out, ch, int(frames));
    mdsp_load_record(t0, mach_absolute_time(), frames);
    return noErr;
}

extern "C" AURenderCallback mdsp_render_callback(void) { return mdsp_au_render; }

extern "C" void mdsp_au_join_workgroup(MDEngine *e, AudioUnit au, double periodSeconds) {
    os_workgroup_t wg = nullptr;
    UInt32 size = sizeof(wg);
    if (au && AudioUnitGetProperty(au, kAudioOutputUnitProperty_OSWorkgroup, kAudioUnitScope_Global, 0, &wg, &size) != noErr) wg = nullptr;
    mdsp_set_workgroup(e, wg, periodSeconds);   // Kern hält seine eigene Referenz
    if (wg) os_release(wg);
}

// ---------- Eingang (Aufnahme) ----------

struct MDInput {
    AudioUnit au = nullptr;
    MDRing *ring = nullptr;
    int first = 0;
    int channels = 0, maxFrames = 0;
    float **bufs = nullptr;
    AudioBufferList *abl = nullptr;
    std::atomic<uint32_t> blocks{0}, errors{0}, oversized{0};
    std::atomic<uint64_t> totalNs{0}, worstNs{0};
};

static double gTicksToNs = [] { mach_timebase_info_data_t tb; mach_timebase_info(&tb); return double(tb.numer) / double(tb.denom); }();

extern "C" MDInput *mdsp_input_create(int channels, int maxFrames) {
    if (channels < 1 || maxFrames < 1) return nullptr;
    auto *in = new MDInput();
    in->channels = channels; in->maxFrames = maxFrames;
    in->bufs = new float *[size_t(channels)];
    size_t ablSize = offsetof(AudioBufferList, mBuffers) + sizeof(AudioBuffer) * size_t(channels);
    in->abl = static_cast<AudioBufferList *>(calloc(1, ablSize));
    in->abl->mNumberBuffers = UInt32(channels);
    for (int c = 0; c < channels; c++) {
        in->bufs[c] = static_cast<float *>(calloc(size_t(maxFrames), sizeof(float)));
        in->abl->mBuffers[c].mNumberChannels = 1;
        in->abl->mBuffers[c].mData = in->bufs[c];
        in->abl->mBuffers[c].mDataByteSize = UInt32(maxFrames * sizeof(float));
    }
    return in;
}

extern "C" void mdsp_input_destroy(MDInput *in) {
    if (!in) return;
    for (int c = 0; c < in->channels; c++) free(in->bufs[c]);
    delete[] in->bufs;
    free(in->abl);
    delete in;
}

extern "C" void mdsp_input_set(MDInput *in, AudioUnit au, MDRing *ring, int first) {
    if (!in) return;
    in->au = au; in->ring = ring; in->first = std::clamp(first, 0, std::max(0, in->channels - 1));
}

static OSStatus mdsp_input_render(void *ref, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *ts, UInt32 bus, UInt32 frames,
                                  AudioBufferList *) {
    auto *in = static_cast<MDInput *>(ref);
    uint64_t t0 = mach_absolute_time();
    if (!in->au || int(frames) > in->maxFrames) { in->oversized.fetch_add(1, std::memory_order_relaxed); return noErr; }
    for (int c = 0; c < in->channels; c++) {
        in->abl->mBuffers[c].mData = in->bufs[c];   // AUHAL darf die Zeiger beim Rendern umsetzen
        in->abl->mBuffers[c].mDataByteSize = UInt32(frames * sizeof(float));
    }
    OSStatus st = AudioUnitRender(in->au, flags, ts, bus, frames, in->abl);
    if (st != noErr) { in->errors.fetch_add(1, std::memory_order_relaxed); return st; }
    int l = in->first, r = in->first + 1 < in->channels ? in->first + 1 : in->first;
    mdsp_ring_write(in->ring, static_cast<const float *>(in->abl->mBuffers[l].mData),
                    static_cast<const float *>(in->abl->mBuffers[r].mData), int(frames));
    uint64_t dt = uint64_t(double(mach_absolute_time() - t0) * gTicksToNs);
    in->blocks.fetch_add(1, std::memory_order_relaxed);
    in->totalNs.fetch_add(dt, std::memory_order_relaxed);
    if (dt > in->worstNs.load(std::memory_order_relaxed)) in->worstNs.store(dt, std::memory_order_relaxed);
    return noErr;
}

extern "C" AURenderCallback mdsp_input_callback(void) { return mdsp_input_render; }

extern "C" MDInputStats mdsp_input_take_stats(MDInput *in) {
    MDInputStats s{};
    if (!in) return s;
    s.blocks = in->blocks.exchange(0, std::memory_order_relaxed);
    s.renderErrors = in->errors.load(std::memory_order_relaxed);
    s.oversized = in->oversized.load(std::memory_order_relaxed);
    s.totalNs = in->totalNs.exchange(0, std::memory_order_relaxed);
    s.worstNs = in->worstNs.exchange(0, std::memory_order_relaxed);
    return s;
}
