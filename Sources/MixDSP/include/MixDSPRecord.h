// Aufnahme: Ringpuffer Audio-Thread -> Schreib-Thread (ein Schreiber, ein Leser, ohne Sperre) und Abgriffe im Kern.
// Stereo, Float32, verschachtelt. Der Speicher wird beim Anlegen einmal berührt (keine Seitenfehler im Audio-Thread).
#ifndef MIXDSP_RECORD_H
#define MIXDSP_RECORD_H
#include <stdint.h>
#include <stdbool.h>
#include "MixDSP.h"
#ifdef __cplusplus
extern "C" {
#endif

typedef struct MDRing MDRing;

/// Platz für mindestens `capacityFrames` Stereo-Frames (aufgerundet auf eine Zweierpotenz). Steuer-Thread
MDRing *mdsp_ring_create(int capacityFrames);
/// erst freigeben, wenn kein Abgriff mehr darauf zeigt (mdsp_set_record_tap NULL + ein Block, oder Gerät steht)
void mdsp_ring_destroy(MDRing *r);
int mdsp_ring_capacity(MDRing *r);

/// Audio-Thread: `frames` Frames anhängen (`right` NULL = links doppelt). Pegel immer; Samples nur, wenn scharf.
/// Kein Platz für den ganzen Block: Block verworfen, Frames und Ereignis gezählt (nie blockieren, nie überschreiben)
void mdsp_ring_write(MDRing *r, const float *left, const float *right, int frames);
/// Aufnahme an/aus (an: der nächste geschriebene Block ist der erste der Aufnahme)
void mdsp_ring_set_armed(MDRing *r, bool armed);
bool mdsp_ring_armed(MDRing *r);

/// Leser: bis zu `maxFrames` Frames entschachtelt nach left/right, liefert die Anzahl
int mdsp_ring_read(MDRing *r, float *left, float *right, int maxFrames);
/// Leser: Frames bereit
int mdsp_ring_available(MDRing *r);
/// Leser: alles Gelesene verwerfen und Zähler auf 0 (vor dem Scharfschalten)
void mdsp_ring_reset(MDRing *r);
/// seit dem letzten Reset verworfene Blöcke (Aussetzer) und Frames; geschriebene Frames
uint32_t mdsp_ring_overflows(MDRing *r);
uint64_t mdsp_ring_dropped_frames(MDRing *r);
uint64_t mdsp_ring_written_frames(MDRing *r);
/// Spitze je Kanal seit dem letzten Abholen (ein Abholer, Anzeige)
void mdsp_ring_take_peak(MDRing *r, float *left, float *right);

/// Abgriff des internen Masters: das Paar ab `firstChannel` nach Master-Lautstärke und Begrenzung, ohne Metronom und
/// ohne Vorhören. NULL = aus. Der Ring muss leben, bis ein Block ohne ihn gerechnet wurde (mdsp_record_tap_released)
void mdsp_set_record_tap(MDEngine *e, MDRing *ring, int firstChannel);
/// zeigt kein Abgriff mehr auf `ring` und hat der Audio-Thread seitdem einen ganzen Block gerechnet?
bool mdsp_record_tap_released(MDEngine *e, MDRing *ring);

/// Rechenzeit des Abgriffs im letzten Abhol-Fenster: Nanosekunden gesamt und im schwersten Block (setzt zurück)
void mdsp_record_tap_cost(MDEngine *e, uint64_t *totalNs, uint64_t *worstNs, uint32_t *blocks);

#ifdef __cplusplus
}
#endif
#endif
