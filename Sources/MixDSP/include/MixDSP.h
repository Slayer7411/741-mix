// MixDSP – schlanker Echtzeit-Audiokern von MINOS-741.
// Ein einziger Render-Callback rechnet alle Decks: Abspielen (Tempo/Keylock/Loop/Reverse/Flux),
// Kanalzug (Gain, EQ, Filter), 2 FX-Units (Filter, Delay, Reverb), Fader/Crossfader, Routing auf Kanalpaare.
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
#define MDSP_FX_UNITS 2

typedef struct MDEngine MDEngine;

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
    MD_FX1_ASSIGN, MD_FX2_ASSIGN,       // 0/1
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
    MDFX_PARAM_COUNT
} MDFXParam;

MDEngine *mdsp_create(double sampleRate);
void mdsp_destroy(MDEngine *e);

/// Track-Puffer setzen (Deck wird dabei gestoppt). Speicher gehört dem Aufrufer und muss gültig bleiben,
/// bis mdsp_buffer_released() für dieses Deck true liefert (Audio-Thread hat den alten Puffer losgelassen).
void mdsp_set_track(MDEngine *e, int deck, const float *left, const float *right, int64_t frames, double trackRate, double startSeconds);
bool mdsp_buffer_released(MDEngine *e, int deck);

void mdsp_set_param(MDEngine *e, int deck, MDParam p, float v);
void mdsp_set_fx(MDEngine *e, int unit, MDFXParam p, float v);
void mdsp_set_master(MDEngine *e, float volume);

void mdsp_seek(MDEngine *e, int deck, double seconds);
void mdsp_set_loop(MDEngine *e, int deck, bool active, double startSeconds, double endSeconds);

double mdsp_position(MDEngine *e, int deck);      // Sekunden (hörbare Position)
double mdsp_flux_position(MDEngine *e, int deck);
bool mdsp_loop(MDEngine *e, int deck, double *start, double *end);
bool mdsp_playing(MDEngine *e, int deck);          // false nach Track-Ende
void mdsp_levels(MDEngine *e, int deck, float *rms, float *peak);

/// Direkt rendern (Tests/Offline): out[ch][frame]
void mdsp_render(MDEngine *e, float **out, int channels, int frames);

#ifdef __cplusplus
}
#endif
#endif
