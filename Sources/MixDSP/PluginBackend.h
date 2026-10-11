// Gemeinsame Hülle der Plugin-Backends (Audio Unit, VST3): der Kern sieht nur MDPlugin und ruft process/reset.
// Nicht öffentlich – die C-Schnittstellen stehen in MixDSPAUHost.h und MixDSPVST3Host.h.
#ifndef MIXDSP_PLUGINBACKEND_H
#define MIXDSP_PLUGINBACKEND_H
#include "MixDSP.h"
#include <atomic>
#include <cstdint>

enum MDPluginKind { MDPLUG_KIND_AU = 1, MDPLUG_KIND_VST3 = 2 };

struct MDPlugin {
    explicit MDPlugin(int k) : kind(k) {}
    virtual ~MDPlugin() = default;
    /// Audio-Thread: L/R an Ort und Stelle rechnen, ohne Sperren und ohne Speicher. Bei Fehler bleibt das Signal.
    virtual void process(float *L, float *R, int n) = 0;
    /// Steuer-Thread: Zustand löschen (Hall, Delay-Puffer)
    virtual void reset() = 0;
    const int kind;
    /// Nachklingzeit laut Plugin in Samples (UINT32_MAX = endlos); der Kern rechnet mindestens so lange weiter
    std::atomic<uint32_t> tailFrames{0};
    /// Audio-Thread schreibt, Steuer-Thread liest: Blöcke, die das Plugin nicht gerechnet hat (Fehler, Zeitüberschreitung
    /// eines isolierten Plugins), und Frames, die zuletzt ohne Unterbrechung fehlschlugen
    std::atomic<uint64_t> failedBlocks{0}, failingFrames{0};
    /// Master-Clock vor jedem Block (nur Audio-Thread): BPM (0 = unbekannt) und Beat am Blockanfang
    double tempo = 0, beat = 0;
};

#endif
