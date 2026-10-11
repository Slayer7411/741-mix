// Vorhör-Player im Kern (intern). Schnittstelle: MixDSPPreview.h. Übergabe wie bei den Decks: Generation, Atomics,
// Schnitt als Paar per Sequenzzähler. Kein rekursiver Zustand (kein Filter, kein Hall) -> nichts zurückzusetzen.
#ifndef MIXDSP_PREVIEW_INTERNAL_H
#define MIXDSP_PREVIEW_INTERNAL_H
#include "MixDSP.h"
#include <atomic>
#include <cmath>
#include <cstdint>

struct MDPreview {
    struct Slot { const float *L = nullptr, *R = nullptr; int64_t frames = 0; double rate = 44100, start = 0; };
    // vom Steuer-Thread geschrieben
    Slot slots[2];
    std::atomic<uint32_t> pendingGen{0};    // 0 = nichts ausstehend
    std::atomic<uint32_t> consumedGen{0};
    uint32_t loadGen = 0;                   // nur Steuer-Thread
    std::atomic<uint32_t> playGen{0};       // Generation, die spielen soll (0 = Pause); das Ende setzt 0 nur für die eigene
    std::atomic<double> pendingSeek{NAN};
    std::atomic<uint32_t> trimSeq{0};
    std::atomic<double> trimStartReq{0}, trimEndReq{0};
    std::atomic<float> volume{1};
    std::atomic<int> outCh{-1};
    std::atomic<bool> mute{false};
    // nach außen
    std::atomic<double> posOut{0};
    std::atomic<float> rms{0}, peak{0};
    std::atomic<int> routed{-1};
    // nur Audio-Thread
    Slot cur; uint32_t curGen = 0;
    double pos = 0, seekTo = NAN;
    double trimS = 0, trimE = 0; uint32_t seenTrim = 0;
    float gain = 0, volSm = 1;
};

/// Audio-Thread: Vorhören in `out` mischen (nach dem Master)
void mdpv_render(MDPreview &p, float **out, int channels, int frames, double fs);
/// Player des Kerns (MixDSP.cpp)
MDPreview &mdsp_preview_of(MDEngine *e);

#endif
