// MixDSP – schlanker Echtzeit-Audiokern von MINOS-741.
// Ein einziger Render-Callback rechnet alle Decks: Abspielen (Tempo/Keylock/Loop/Reverse/Flux),
// Kanalzug (Gain, EQ, Filter), 4 FX-Units (Filter, Delay, Reverb), Fader/Crossfader, Routing auf Kanalpaare.
// Der Audio-Thread nimmt keine Sperren und fordert keinen Speicher an. Steuerwerte sind atomar.
#ifndef MIXDSP_H
#define MIXDSP_H

#include <stdint.h>
#include <stdbool.h>
// plattformneutral: der Kern kennt kein CoreAudio/ASIO – Anschlüsse liegen in eigenen Backend-Dateien

#ifdef __cplusplus
extern "C" {
#endif

#define MDSP_DECKS 4
#define MDSP_FX_UNITS 4
#define MDSP_MAX_FRAMES 4096   // größter Block je Durchlauf (größere Puffer rechnet mdsp_render in Teilen)

typedef struct MDEngine MDEngine;
typedef struct MDPlugin MDPlugin;   // Effekt-Plugin (Backend-Datei, z. B. MixDSPAUHost.h)

/// Parameter je Deck (mdsp_set_param)
typedef enum {
    MD_RATE = 0,        // Tempo-Faktor (1 = Original), inkl. Nudge/Bend
    MD_KEYLOCK,         // 0/1
    MD_KEYSHIFT,        // Halbtöne
    MD_PLAYING,         // 0/1
    MD_REVERSE,         // 0/1
    MD_FLUX,            // 0/1
    MD_GAIN_DB,         // Kanal-Gain inkl. Auto-Gain
    MD_EQ_LOW, MD_EQ_MID, MD_EQ_HIGH,   // dB (≤ -96 = Kill)
    MD_FILTER,          // -1 … 1 (LP … HP)
    MD_FILTER_RES,      // Resonanz 0.2 … 1.5
    MD_VOLUME,          // Fader × Crossfader, 0 … 1
    MD_FX1_ASSIGN, MD_FX2_ASSIGN, MD_FX3_ASSIGN, MD_FX4_ASSIGN,   // 0/1 (fortlaufend)
    MD_OUT_CHANNEL,     // erster Kanal des Ausgangspaars (0-basiert)
    MD_PARAM_COUNT
} MDParam;

/// Parameter je FX-Unit (mdsp_set_fx)
typedef enum {
    MDFX_DRYWET = 0,
    MDFX_FILTER_ON, MDFX_FILTER_AMOUNT,     // amount 0…1 (0.5 = aus, links LP, rechts HP)
    MDFX_DELAY_ON, MDFX_DELAY_AMOUNT, MDFX_DELAY_SECONDS, MDFX_DELAY_FEEDBACK,
    MDFX_REVERB_ON, MDFX_REVERB_AMOUNT, MDFX_REVERB_SIZE,
    MDFX_FILTER_RES,
    MDFX_REVERB_HP, MDFX_REVERB_LP,         // Filter vor dem Hall: 0…1 (HP 0 = aus, LP 1 = aus)
    MDFX_REVERB_DWSEND,                     // 1 = D/W regelt, wie viel in den Hall geht (Single), 0 = D/W regelt den Hall-Anteil
    MDFX_REVERB_LEVEL,                      // Hall-Pegel, linear (1 = bei vollem D/W Hall ≈ 4 dB unter dem Track)
    MDFX_REVERB_BRIGHT,                     // Helligkeit 0…1 (Höhen-Nachhall 35…90 %, Hochpass vor dem Hall 150…400 Hz, Höhenregal −4…+6 dB)
    MDFX_REVERB_PREDELAY,                   // Vorverzögerung in Sekunden (0…0,2)
    MDFX_PLUGIN_ON,                         // Plugin der Unit an (aus = Eingang zu, Fahne klingt aus)
    MDFX_PARAM_COUNT
} MDFXParam;

MDEngine *mdsp_create(double sampleRate);
void mdsp_destroy(MDEngine *e);

/// Track-Puffer setzen (Deck wird dabei gestoppt). Liefert die Übergabe-Generation. Speicher gehört dem Aufrufer;
/// der vorherige Puffer darf erst weg, wenn mdsp_track_consumed() für diese Generation true liefert
/// (Audio-Thread hat den neuen übernommen und liest den alten nicht mehr).
uint32_t mdsp_set_track(MDEngine *e, int deck, const float *left, const float *right, int64_t frames, double trackRate, double startSeconds);
bool mdsp_track_consumed(MDEngine *e, int deck, uint32_t generation);

void mdsp_set_param(MDEngine *e, int deck, MDParam p, float v);
void mdsp_set_fx(MDEngine *e, int unit, MDFXParam p, float v);
void mdsp_set_master(MDEngine *e, float volume);

/// Plugin für FX-Unit × Deck setzen (NULL = keins). Liefert das vorherige; das darf erst geschlossen werden,
/// wenn mdsp_fx_plugin_released() true liefert (Audio-Thread hat einen ganzen Block ohne es gerechnet).
MDPlugin *mdsp_set_fx_plugin(MDEngine *e, int unit, int deck, MDPlugin *p);
bool mdsp_fx_plugin_released(MDEngine *e, int unit, int deck, MDPlugin *old);
/// NaN im Deck: das Plugin der Unit wird nicht mehr gerechnet, bis der Steuer-Thread es zurückgesetzt hat
/// (mdplug_reset) und mdsp_fx_plugin_reset_done() meldet
bool mdsp_fx_plugin_needs_reset(MDEngine *e, int unit, int deck);
void mdsp_fx_plugin_reset_done(MDEngine *e, int unit, int deck);

void mdsp_seek(MDEngine *e, int deck, double seconds);
void mdsp_set_loop(MDEngine *e, int deck, bool active, double startSeconds, double endSeconds);

double mdsp_position(MDEngine *e, int deck);      // Sekunden (hörbare Position)
double mdsp_flux_position(MDEngine *e, int deck);
bool mdsp_loop(MDEngine *e, int deck, double *start, double *end);
bool mdsp_playing(MDEngine *e, int deck);          // false nach Track-Ende
void mdsp_levels(MDEngine *e, int deck, float *rms, float *peak);

/// Master-Clock im Kern (gleiche Zeitbasis wie das Audio): BPM, Beat-Position, Metronom
void mdsp_clock_set_bpm(MDEngine *e, double bpm);
void mdsp_clock_set_beat(MDEngine *e, double beat);   // Phase neu setzen (übernimmt der nächste Block)
double mdsp_clock_beat(MDEngine *e);
/// Beat am Anfang des zuletzt gerenderten Blocks und dessen Host-Zeit (mach_absolute_time, ohne Ausgabelatenz)
bool mdsp_clock_stamp(MDEngine *e, double *beat, uint64_t *hostTime);
void mdsp_set_render_host(MDEngine *e, uint64_t hostTime);
void mdsp_metronome(MDEngine *e, bool on, float volume, int firstChannel);

/// Vorlauf des Keylock-Stretchers in Sekunden (wird beim Abspielen ausgeglichen: hörbare Position stimmt)
double mdsp_keylock_latency(MDEngine *e);

/// Direkt rendern (Tests/Offline): out[ch][frame]
void mdsp_render(MDEngine *e, float **out, int channels, int frames);

#ifdef __cplusplus
}
#endif
#endif
