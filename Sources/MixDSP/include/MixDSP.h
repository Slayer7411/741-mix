// MixDSP – schlanker Echtzeit-Audiokern von MINOS-741.
// Ein einziger Render-Callback rechnet alle Decks: Abspielen (Tempo/Keylock/Loop/Reverse/Flux),
// Kanalzug (Gain, EQ, Filter), 4 FX-Units (Filter, Delay, Reverb – zwei Typen, Gater, Roll, Flanger, Phaser),
// Fader/Crossfader, Routing auf Kanalpaare.
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
#define MDSP_FX_CHAIN 4        // Plugins in Reihe je FX-Unit und im Master-Bus
#define MDSP_MASTER_UNIT (-1)  // `unit` der Kette des Master-Busses (mdsp_set_fx_chain & Co., `deck` egal)

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
    MDFX_REVERB_TYPE,                       // 0 = Reverb (Allpass-Ring, Standard), 1 = Reverb (FDN)
    MDFX_REVERB_FREEZE,                     // 1 = Eingang zu, Fahne steht (nur solange der Hall an ist)
    // Beat-FX im Raster der Master-Clock (AMOUNT × D/W = Anteil, 0 = trocken unverändert)
    MDFX_GATER_ON, MDFX_GATER_AMOUNT,       // Tiefe 0…1
    MDFX_GATER_BEATS,                       // Periode in Beats (1/16 … 1/2, Triole × 2/3)
    MDFX_GATER_SHAPE, MDFX_GATER_WIDTH,     // Form 0 = Rechteck … 1 = Abklingen, offener Anteil 0,05…0,95
    MDFX_GATER_MUTE,                        // 1 = Tor zu
    MDFX_ROLL_ON, MDFX_ROLL_AMOUNT,         // Puffer-Wiederholer
    MDFX_ROLL_BEATS,                        // Länge in Beats (1/32 … 1)
    MDFX_ROLL_REVERSE, MDFX_ROLL_DECAY,     // rückwärts 0/1, Abklingen in dB je Beat (0 = keins)
    MDFX_FLANGER_ON, MDFX_FLANGER_AMOUNT,
    MDFX_FLANGER_BEATS, MDFX_FLANGER_HZ,    // LFO-Periode in Beats; ≤ 0 = frei mit Hz
    MDFX_FLANGER_DEPTH, MDFX_FLANGER_FEEDBACK, MDFX_FLANGER_SPREAD, MDFX_FLANGER_FREEZE,   // 0…1, Spread 1 = 180° L/R, Freeze = LFO steht
    MDFX_PHASER_ON, MDFX_PHASER_AMOUNT,
    MDFX_PHASER_BEATS, MDFX_PHASER_HZ,
    MDFX_PHASER_DEPTH, MDFX_PHASER_FEEDBACK, MDFX_PHASER_STAGES, MDFX_PHASER_FREEZE,      // Stufen 4 oder 8
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

/// erstes Plugin der Kette von FX-Unit × Deck setzen (NULL = keins). Liefert das vorherige; das darf erst geschlossen werden,
/// wenn mdsp_fx_plugin_released() true liefert (Audio-Thread hat einen ganzen Block ohne es gerechnet).
MDPlugin *mdsp_set_fx_plugin(MDEngine *e, int unit, int deck, MDPlugin *p);
/// steht `old` in keinem Platz der Kette mehr und hat der Audio-Thread seitdem einen ganzen Block gerechnet?
bool mdsp_fx_plugin_released(MDEngine *e, int unit, int deck, MDPlugin *old);
/// wie mdsp_fx_chain_needs_reset/_reset_done für Platz 0
bool mdsp_fx_plugin_needs_reset(MDEngine *e, int unit, int deck);
void mdsp_fx_plugin_reset_done(MDEngine *e, int unit, int deck);

/// Plugin-Kette von FX-Unit × Deck (unit = MDSP_MASTER_UNIT: Master-Bus) in einem Schritt setzen: bis zu MDSP_FX_CHAIN
/// Plugins in Reihe (Platz 0 zuerst), NULL = Platz leer. Ein herausgenommenes Plugin erst schließen, wenn
/// mdsp_fx_plugin_released() true liefert. D/W der Unit wirkt auf die ganze Kette (trocken = Eingang der Kette)
void mdsp_set_fx_chain(MDEngine *e, int unit, int deck, MDPlugin *const *plugins, int count);
/// Platz an/aus (gilt für alle Decks der Unit); aus = durchreichen, die Fahne des Plugins klingt aus. Standard an
void mdsp_set_fx_chain_on(MDEngine *e, int unit, int slot, bool on);
/// NaN im Deck oder aus dem Plugin: der Platz wird durchgereicht, bis der Steuer-Thread das Plugin zurückgesetzt hat
/// (mdplug_reset) und mdsp_fx_chain_reset_done() meldet
bool mdsp_fx_chain_needs_reset(MDEngine *e, int unit, int deck, int slot);
void mdsp_fx_chain_reset_done(MDEngine *e, int unit, int deck, int slot);
/// Master-Bus: Kette nach der Summe der Decks, vor Master-Lautstärke und Begrenzung. Aus = Eingang zu, Fahnen klingen aus
void mdsp_set_master_fx(MDEngine *e, bool on, float dryWet);
/// Kanalpaar des Master-Busses (erster Kanal, -1 = aus – externer Mixer hat keinen Summenpunkt)
void mdsp_set_master_fx_channel(MDEngine *e, int firstChannel);
/// Pegel des Master-Paars nach dem Master-Bus, vor der Master-Lautstärke (0, solange kein Paar gesetzt ist)
void mdsp_master_levels(MDEngine *e, float *rms, float *peak);

void mdsp_seek(MDEngine *e, int deck, double seconds);
void mdsp_set_loop(MDEngine *e, int deck, bool active, double startSeconds, double endSeconds);
/// Instant Double: am Anfang des nächsten Blocks die hörbare Position von `source` übernehmen (sample-genau zum Quell-Deck,
/// gleiche Datei vorausgesetzt). Gilt nach mdsp_set_track/mdsp_seek desselben Blocks
void mdsp_follow(MDEngine *e, int deck, int source);
/// Schnitt (nicht destruktiv): nur zwischen Start und Ende ist etwas hörbar (Sekunden, Ende <= 0 = Track-Ende).
/// Sprünge und Ladeposition landen im Schnitt, ein Loop wirkt nur bis zu dessen Ende, vorwärts stoppt das Deck am Ende
/// wie am Track-Ende, rückwärts bleibt es am Start stehen. Ende <= Start = kein Schnitt. Gilt bis zum nächsten Aufruf.
void mdsp_set_trim(MDEngine *e, int deck, double startSeconds, double endSeconds);

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

/// Decks parallel rechnen: Deck A im Audio-Thread, B–D auf eigenen Echtzeit-Threads, Summe danach (gleiches Ergebnis
/// wie seriell). Steuer-Thread; die Threads entstehen beim ersten Einschalten und bleiben bis mdsp_destroy
void mdsp_set_parallel(MDEngine *e, bool on);
bool mdsp_parallel(MDEngine *e);
/// Profil des schwersten Render-Blocks seit dem letzten Aufruf: Nanosekunden je Abschnitt
/// [0–3] Deck A–D (parallel: nur A, B–D stecken in [4]), [4] Warten auf die Worker, [5] Summe + Master-Bus,
/// [6] Master-Lautstärke/Begrenzung/Clock, [7] Vorhören; `frames` = Blockgröße. Setzt die Messung zurück
void mdsp_render_profile(MDEngine *e, uint64_t *parts, int count, uint32_t *frames);
/// Diagnose: Worker gestartet, davon in der Workgroup des Geräts, davon mit Echtzeit-Policy
void mdsp_parallel_info(MDEngine *e, int *workers, int *joined, int *realtime);
/// Workgroup des Geräte-IO-Threads für die Worker (Apple: os_workgroup_t, wird retained; sonst ignoriert) und die
/// Blockdauer in Sekunden für ihre Echtzeit-Policy. Nach jedem Öffnen des Geräts setzen; NULL = keine Workgroup
void mdsp_set_workgroup(MDEngine *e, void *workgroup, double periodSeconds);

#ifdef __cplusplus
}
#endif
#endif
