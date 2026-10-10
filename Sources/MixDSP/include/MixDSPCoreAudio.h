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
#ifdef __cplusplus
}
#endif
#endif
