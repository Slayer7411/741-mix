// Vorhören im Kern (Browser): eigener Player auf einem eigenen Kanalpaar desselben Geräts, im selben Render-Callback.
// Nur Abspielen (Rate des Tracks, kein Keylock/EQ/FX), nach dem Master gemischt: Master-Volume und Decks wirken nicht.
// Steuerung von jedem Thread außer dem Audio-Thread; im Audio-Thread nur Atomics, kein Speicher, keine Sperren.
#ifndef MIXDSP_PREVIEW_H
#define MIXDSP_PREVIEW_H
#include "MixDSP.h"
#ifdef __cplusplus
extern "C" {
#endif

/// Track-Puffer setzen (NULL = keiner), hält an. Liefert die Übergabe-Generation; der vorherige Puffer darf erst weg,
/// wenn mdsp_preview_track_consumed() für sie true liefert. Ein spielender Track blendet erst aus (5 ms), dann Wechsel.
uint32_t mdsp_preview_set_track(MDEngine *e, const float *left, const float *right, int64_t frames, double trackRate, double startSeconds);
bool mdsp_preview_track_consumed(MDEngine *e, uint32_t generation);
/// Spielen/Pause des zuletzt gesetzten Tracks (Ein-/Ausblenden 5 ms)
void mdsp_preview_play(MDEngine *e, bool play);
/// Sprung (Sekunden): ausblenden, springen, einblenden. Landet im Schnitt
void mdsp_preview_seek(MDEngine *e, double seconds);
/// Schnitt wie mdsp_set_trim: hörbar nur zwischen Start und Ende (Ende <= 0 = Track-Ende), am Ende hält der Player an
void mdsp_preview_set_trim(MDEngine *e, double startSeconds, double endSeconds);
/// Lautstärke linear (0 … 2)
void mdsp_preview_set_volume(MDEngine *e, float volume);
/// erster Kanal des Ausgangspaars (0-basiert), < 0 = aus. Paar nicht am Gerät = stumm (nie auf ein anderes Paar).
/// mute = nur Pegel messen, nichts ausgeben (Selbsttest)
void mdsp_preview_set_output(MDEngine *e, int firstChannel, bool mute);
double mdsp_preview_position(MDEngine *e);   // Sekunden
bool mdsp_preview_playing(MDEngine *e);       // false nach dem Ende (Schnitt oder Track)
/// Pegel nach der Lautstärke (auch stumm geschaltet)
void mdsp_preview_levels(MDEngine *e, float *rms, float *peak);
/// Paar, auf das der letzte Block geschrieben hat (erster Kanal), -1 = keins
int mdsp_preview_routed(MDEngine *e);

#ifdef __cplusplus
}
#endif
#endif
