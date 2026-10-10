// Audio-Unit-Host für MixDSP (macOS): ein Effekt-Plugin ("aufx"/"aumf", v2 oder v3 über die Bridge) als MDPlugin.
// Öffnen/Schließen auf dem Steuer-Thread, mdplug_process() im Audio-Thread (keine Sperren, kein Speicher).
// Ein VST-Host für Windows wäre eine zweite Datei mit derselben Schnittstelle, der Kern bleibt gleich.
#ifndef MIXDSP_AUHOST_H
#define MIXDSP_AUHOST_H
#include "MixDSP.h"
#ifdef __cplusplus
extern "C" {
#endif

/// Plugin anlegen: Float32 nicht verschachtelt stereo mit `sampleRate` an Ein- und Ausgang, bis `maxFrames` je Block.
/// Liefert NULL bei Fehler, Grund in `err` (errLen Bytes).
MDPlugin *mdplug_open(uint32_t type, uint32_t subtype, uint32_t manufacturer, double sampleRate, uint32_t maxFrames,
                      char *err, int errLen);
/// fertige Instanz übernehmen (z. B. außerhalb des Prozesses über AudioComponentInstantiate angelegt) und einrichten wie
/// mdplug_open. Das Plugin gehört danach MDPlugin; bei Fehler wird es geschlossen und NULL geliefert.
MDPlugin *mdplug_wrap(void *audioUnit, double sampleRate, uint32_t maxFrames, char *err, int errLen);
/// schließen – erst, wenn der Audio-Thread das Plugin sicher nicht mehr nutzt (mdsp_fx_plugin_released)
void mdplug_close(MDPlugin *p);
/// die AudioUnit (AudioComponentInstance) für Parameter, Zustand und Ansicht
void *mdplug_audio_unit(MDPlugin *p);
/// internen Zustand löschen (Hallfahnen, Delay-Puffer)
void mdplug_reset(MDPlugin *p);
/// L/R an Ort und Stelle durch das Plugin rechnen (Audio-Thread). Bei Fehler bleibt das Signal unverändert.
void mdplug_process(MDPlugin *p, float *L, float *R, int n);

#ifdef __cplusplus
}
#endif
#endif
