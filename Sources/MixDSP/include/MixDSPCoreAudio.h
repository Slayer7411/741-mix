// CoreAudio-Backend für MixDSP (macOS): Render-Callback für eine AUHAL-Ausgabe.
// Ein ASIO-Backend für Windows wäre eine zweite Datei dieser Art, der Kern bleibt gleich.
#ifndef MIXDSP_COREAUDIO_H
#define MIXDSP_COREAUDIO_H
#include <AudioToolbox/AudioToolbox.h>
#include "MixDSP.h"
#ifdef __cplusplus
extern "C" {
#endif
/// inRefCon = MDEngine*, nicht-verschachtelte Float32-Kanäle
OSStatus mdsp_au_render(void *inRefCon, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *ts,
                        UInt32 bus, UInt32 frames, AudioBufferList *io);
/// derselbe Callback, als AURenderCallback typisiert (für Swift)
AURenderCallback mdsp_render_callback(void);
/// Worker der parallelen Decks in die Workgroup des AUHAL-IO-Threads holen (nach AudioUnitInitialize, bei jedem Öffnen);
/// `periodSeconds` = Blockdauer des Geräts
void mdsp_au_join_workgroup(MDEngine *e, AudioUnit au, double periodSeconds);

/// DSP-Last des Render-Callbacks: Rechenzeit ÷ Blockdauer. Gemessen mit mach_absolute_time, gespeichert in Atomics
/// (keine Sperre, kein Speicher im Audio-Thread). Gilt für die eine Live-Ausgabe des Prozesses.
typedef struct {
    double average;      // Mittel seit dem letzten Abholen (0…1+, 1 = Budget voll)
    double peak;         // schwerster Block seit dem letzten Abholen
    uint32_t overloads;  // Blöcke über 100 % des Budgets seit Start/Zurücksetzen
    uint32_t blocks;     // gerechnete Blöcke seit dem letzten Abholen
} MDLoad;

/// Rate der Blöcke im Callback (Frames je Sekunde); vor dem Start setzen
void mdsp_load_set_rate(double framesPerSecond);
/// einen Block eintragen (Start-/Endzeit in mach_absolute_time-Ticks)
void mdsp_load_record(uint64_t start, uint64_t end, uint32_t frames);
/// Werte seit dem letzten Aufruf abholen (Mittel und Spitze werden dabei zurückgesetzt)
MDLoad mdsp_load_take(void);
void mdsp_load_reset_overloads(void);
#ifdef __cplusplus
}
#endif
#endif
