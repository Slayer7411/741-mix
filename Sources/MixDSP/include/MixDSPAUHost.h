// Audio-Unit-Host für MixDSP (macOS): ein Effekt-Plugin ("aufx"/"aumf", v2 oder v3 über die Bridge) als MDPlugin.
// Öffnen/Schließen auf dem Steuer-Thread, mdplug_process() im Audio-Thread (keine Sperren, kein Speicher).
// Schließen, Zurücksetzen, Rechnen: MixDSPPlugin.h (gleich für alle Formate).
#ifndef MIXDSP_AUHOST_H
#define MIXDSP_AUHOST_H
#include "MixDSPPlugin.h"
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
/// die AudioUnit (AudioComponentInstance) für Parameter, Zustand und Ansicht; NULL bei anderen Formaten
void *mdplug_audio_unit(MDPlugin *p);

#ifdef __cplusplus
}
#endif
#endif
