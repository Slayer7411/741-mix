#include "MixDSPCoreAudio.h"
#include <mach/mach_time.h>

extern "C" OSStatus mdsp_au_render(void *ref, AudioUnitRenderActionFlags *, const AudioTimeStamp *, UInt32, UInt32 frames,
                                   AudioBufferList *io) {
    auto *e = static_cast<MDEngine *>(ref);
    mdsp_set_render_host(e, mach_absolute_time());
    float *out[64];
    int ch = 0;
    for (UInt32 b = 0; b < io->mNumberBuffers && ch < 64; b++) out[ch++] = static_cast<float *>(io->mBuffers[b].mData);
    mdsp_render(e, out, ch, int(frames));
    return noErr;
}

extern "C" AURenderCallback mdsp_render_callback(void) { return mdsp_au_render; }
