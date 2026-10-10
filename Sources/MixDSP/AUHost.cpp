// Audio-Unit-Host: eine AudioComponentInstance je FX-Unit × Deck. Eingang kommt über einen Render-Callback aus den
// Puffern, die mdplug_process() übergibt; der Ausgang wird in vorab angelegte Puffer gerendert und erst bei Erfolg kopiert.
#include "MixDSPAUHost.h"
#include <AudioToolbox/AudioToolbox.h>
#include <mach/mach_time.h>
#include <algorithm>
#include <cstdio>
#include <cstring>
#include <vector>

struct MDPlugin {
    AudioUnit au = nullptr;
    uint32_t maxFrames = 0;
    // Eingang des aktuellen Blocks (zeigt auf die Puffer von mdplug_process)
    const float *inL = nullptr, *inR = nullptr;
    int inFrames = 0;
    // Ausgang: vorab angelegt, 2 Kanäle
    std::vector<float> outL, outR;
    std::vector<unsigned char> ablStorage;   // AudioBufferList mit 2 Puffern
    AudioBufferList *abl = nullptr;
    Float64 sampleTime = 0;
    bool initialized = false;
};

// liefert dem Plugin den Eingang des laufenden Blocks (Audio-Thread, innerhalb von AudioUnitRender)
static OSStatus inputCallback(void *ref, AudioUnitRenderActionFlags *, const AudioTimeStamp *, UInt32, UInt32 frames,
                              AudioBufferList *io) {
    auto *p = static_cast<MDPlugin *>(ref);
    const float *src[2] = {p->inL, p->inR};
    for (UInt32 b = 0; b < io->mNumberBuffers && b < 2; b++) {
        AudioBuffer &buf = io->mBuffers[b];
        size_t have = size_t(std::max(0, std::min(int(frames), p->inFrames)));
        if (!buf.mData) {   // Plugin möchte unseren Puffer direkt lesen
            if (have == frames && src[b]) { buf.mData = const_cast<float *>(src[b]); buf.mDataByteSize = UInt32(frames * sizeof(float)); continue; }
            return kAudioUnitErr_InvalidParameter;
        }
        auto *dst = static_cast<float *>(buf.mData);
        if (src[b] && have) std::memcpy(dst, src[b], have * sizeof(float));
        if (have < frames) std::memset(dst + have, 0, (frames - have) * sizeof(float));
        buf.mDataByteSize = UInt32(frames * sizeof(float));
    }
    return noErr;
}

static void fail(char *err, int errLen, const char *what, OSStatus st) {
    if (err && errLen > 0) std::snprintf(err, size_t(errLen), "%s (%d)", what, int(st));
}

extern "C" {

// fertige Instanz einrichten (Formate, Blockgröße, Eingang, Initialize); bei Fehler wird sie geschlossen
static MDPlugin *configure(AudioUnit au, double sampleRate, uint32_t maxFrames, char *err, int errLen) {
    auto *p = new MDPlugin();
    p->au = au;
    p->maxFrames = std::max(1u, maxFrames);
    AudioStreamBasicDescription fmt{};
    fmt.mSampleRate = sampleRate; fmt.mFormatID = kAudioFormatLinearPCM;
    fmt.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved;
    fmt.mBytesPerPacket = 4; fmt.mFramesPerPacket = 1; fmt.mBytesPerFrame = 4; fmt.mChannelsPerFrame = 2; fmt.mBitsPerChannel = 32;
    OSStatus st = AudioUnitSetProperty(p->au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &fmt, sizeof fmt);
    if (st != noErr) { fail(err, errLen, "input format rejected", st); mdplug_close(p); return nullptr; }
    st = AudioUnitSetProperty(p->au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &fmt, sizeof fmt);
    if (st != noErr) { fail(err, errLen, "output format rejected", st); mdplug_close(p); return nullptr; }
    UInt32 mf = p->maxFrames;
    st = AudioUnitSetProperty(p->au, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &mf, sizeof mf);
    if (st != noErr) { fail(err, errLen, "max frames rejected", st); mdplug_close(p); return nullptr; }
    AURenderCallbackStruct cb{inputCallback, p};
    st = AudioUnitSetProperty(p->au, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &cb, sizeof cb);
    if (st != noErr) { fail(err, errLen, "input callback rejected", st); mdplug_close(p); return nullptr; }
    st = AudioUnitInitialize(p->au);
    if (st != noErr) { fail(err, errLen, "initialize failed", st); mdplug_close(p); return nullptr; }
    p->initialized = true;

    p->outL.assign(p->maxFrames, 0); p->outR.assign(p->maxFrames, 0);
    p->ablStorage.assign(sizeof(AudioBufferList) + sizeof(AudioBuffer), 0);
    p->abl = reinterpret_cast<AudioBufferList *>(p->ablStorage.data());
    p->abl->mNumberBuffers = 2;
    return p;
}


MDPlugin *mdplug_open(uint32_t type, uint32_t subtype, uint32_t manufacturer, double sampleRate, uint32_t maxFrames,
                      char *err, int errLen) {
    if (err && errLen > 0) err[0] = 0;
    AudioComponentDescription desc{};
    desc.componentType = type; desc.componentSubType = subtype; desc.componentManufacturer = manufacturer;
    AudioComponent comp = AudioComponentFindNext(nullptr, &desc);
    if (!comp) { fail(err, errLen, "audio unit not installed", 0); return nullptr; }
    AudioUnit au = nullptr;
    OSStatus st = AudioComponentInstanceNew(comp, &au);
    if (st != noErr || !au) { fail(err, errLen, "instance failed", st); if (au) AudioComponentInstanceDispose(au); return nullptr; }
    return configure(au, sampleRate, maxFrames, err, errLen);
}

MDPlugin *mdplug_wrap(void *audioUnit, double sampleRate, uint32_t maxFrames, char *err, int errLen) {
    if (err && errLen > 0) err[0] = 0;
    if (!audioUnit) { fail(err, errLen, "no instance", 0); return nullptr; }
    return configure(static_cast<AudioUnit>(audioUnit), sampleRate, maxFrames, err, errLen);
}

void mdplug_close(MDPlugin *p) {
    if (!p) return;
    if (p->au) {
        if (p->initialized) AudioUnitUninitialize(p->au);
        AudioComponentInstanceDispose(p->au);
    }
    delete p;
}

void *mdplug_audio_unit(MDPlugin *p) { return p ? static_cast<void *>(p->au) : nullptr; }

void mdplug_reset(MDPlugin *p) { if (p && p->au) AudioUnitReset(p->au, kAudioUnitScope_Global, 0); }

void mdplug_process(MDPlugin *p, float *L, float *R, int n) {
    if (!p || !p->au || n <= 0 || uint32_t(n) > p->maxFrames) return;
    p->inL = L; p->inR = R; p->inFrames = n;
    p->abl->mBuffers[0].mNumberChannels = 1; p->abl->mBuffers[0].mData = p->outL.data(); p->abl->mBuffers[0].mDataByteSize = UInt32(n * sizeof(float));
    p->abl->mBuffers[1].mNumberChannels = 1; p->abl->mBuffers[1].mData = p->outR.data(); p->abl->mBuffers[1].mDataByteSize = UInt32(n * sizeof(float));
    AudioTimeStamp ts{};
    ts.mSampleTime = p->sampleTime; ts.mHostTime = mach_absolute_time();
    ts.mFlags = kAudioTimeStampSampleTimeValid | kAudioTimeStampHostTimeValid;
    AudioUnitRenderActionFlags flags = 0;
    OSStatus st = AudioUnitRender(p->au, &flags, &ts, 0, UInt32(n), p->abl);
    p->sampleTime += n;
    p->inL = p->inR = nullptr; p->inFrames = 0;
    if (st != noErr) return;   // Signal bleibt trocken
    // Plugin darf die Zeiger ersetzt haben (eigene Puffer)
    const float *oL = static_cast<const float *>(p->abl->mBuffers[0].mData), *oR = static_cast<const float *>(p->abl->mBuffers[1].mData);
    if (!oL || !oR) return;
    std::memcpy(L, oL, size_t(n) * sizeof(float));
    std::memcpy(R, oR, size_t(n) * sizeof(float));
}

} // extern "C"
