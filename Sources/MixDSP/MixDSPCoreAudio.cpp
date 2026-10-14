#include "MixDSPCoreAudio.h"
#include <mach/mach_time.h>
#include <algorithm>
#include <atomic>
#include <os/workgroup.h>

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
