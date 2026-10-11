// Effekt-Plugin im Kern (MDPlugin), unabhängig vom Format: Audio Unit (MixDSPAUHost.h) oder VST3 (MixDSPVST3Host.h).
// Öffnen/Schließen auf dem Steuer-Thread, mdplug_process() im Audio-Thread (keine Sperren, kein Speicher).
#ifndef MIXDSP_PLUGIN_H
#define MIXDSP_PLUGIN_H
#include "MixDSP.h"
#ifdef __cplusplus
extern "C" {
#endif

typedef enum { MDPLUG_AU = 1, MDPLUG_VST3 = 2 } MDPluginFormat;

/// Format der Instanz (0 bei NULL)
int mdplug_format(MDPlugin *p);
/// schließen – erst, wenn der Audio-Thread das Plugin sicher nicht mehr nutzt (mdsp_fx_plugin_released)
void mdplug_close(MDPlugin *p);
/// internen Zustand löschen (Hallfahnen, Delay-Puffer); Steuer-Thread
void mdplug_reset(MDPlugin *p);
/// L/R an Ort und Stelle durch das Plugin rechnen (Audio-Thread). Bei Fehler bleibt das Signal unverändert.
void mdplug_process(MDPlugin *p, float *L, float *R, int n);
/// nicht gerechnete Blöcke seit dem Öffnen und Frames, die zuletzt ohne Unterbrechung fehlschlugen (Steuer-Thread)
void mdplug_failures(MDPlugin *p, uint64_t *blocks, uint64_t *frames);

#ifdef __cplusplus
}
#endif
#endif
