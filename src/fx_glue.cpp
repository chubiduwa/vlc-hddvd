/* A stereo float audio output through RtAudio, for effect sounds while VLC is paused (adv/fxout.zig).
 * RtAudio is C++; its C API cannot tell a device's current rate, and opening a CoreAudio device at another rate
 * changes the device's rate under VLC's own output, so this opens at the current one. */

#include "RtAudio.h"
#include <cstring>
#include <new>
#include <string>

extern "C" {

typedef void (*hddvd_fx_fill_t)(void *ctx, float *out, unsigned frames, unsigned channels);

struct hddvd_fx {
    RtAudio audio;
    std::string error;
    hddvd_fx_fill_t fill = nullptr;
    void *ctx = nullptr;
    unsigned channels = 0;

    hddvd_fx() : audio(RtAudio::UNSPECIFIED, [this](RtAudioErrorType, const std::string &text) { error = text; }) {}
};

struct hddvd_fx_device {
    unsigned id;
    unsigned channels;
    int is_default;
    char name[256];
};

static int Callback(void *out, void *, unsigned frames, double, RtAudioStreamStatus, void *data)
{
    hddvd_fx *fx = static_cast<hddvd_fx *>(data);
    fx->fill(fx->ctx, static_cast<float *>(out), frames, fx->channels);
    return 0;
}

hddvd_fx *hddvd_fx_new(void)
{
    try {
        hddvd_fx *fx = new hddvd_fx();
        fx->audio.showWarnings(false);
        return fx;
    } catch (...) {
        return nullptr;
    }
}

void hddvd_fx_delete(hddvd_fx *fx)
{
    if (fx == nullptr)
        return;
    if (fx->audio.isStreamOpen())
        fx->audio.closeStream();
    delete fx;
}

/* The output devices, up to `max`; returns how many there are. */
unsigned hddvd_fx_devices(hddvd_fx *fx, hddvd_fx_device *out, unsigned max)
{
    try {
        unsigned n = 0;
        for (unsigned id : fx->audio.getDeviceIds()) {
            RtAudio::DeviceInfo info = fx->audio.getDeviceInfo(id);
            if (info.outputChannels == 0)
                continue;
            if (n < max) {
                hddvd_fx_device *d = &out[n];
                d->id = id;
                d->channels = info.outputChannels;
                d->is_default = info.isDefaultOutput;
                std::strncpy(d->name, info.name.c_str(), sizeof(d->name) - 1);
                d->name[sizeof(d->name) - 1] = '\0';
            }
            n++;
        }
        return n;
    } catch (...) {
        return 0;
    }
}

/* Opens and starts `channels` float channels on device `id` at its current rate, calling `fill` for every
 * buffer. Returns the rate, or 0 (see hddvd_fx_error). */
unsigned hddvd_fx_open(hddvd_fx *fx, unsigned id, unsigned channels, hddvd_fx_fill_t fill, void *ctx)
{
    try {
        if (fx->audio.isStreamOpen())
            fx->audio.closeStream();
        RtAudio::DeviceInfo info = fx->audio.getDeviceInfo(id);
        unsigned rate = info.currentSampleRate ? info.currentSampleRate : info.preferredSampleRate;
        if (rate == 0)
            rate = 48000;
        fx->fill = fill;
        fx->ctx = ctx;
        fx->channels = channels;
        RtAudio::StreamParameters params;
        params.deviceId = id;
        params.nChannels = channels;
        unsigned frames = rate / 100; /* 10 ms */
        RtAudio::StreamOptions options;
        options.streamName = "VLC HD DVD effect sounds";
        if (fx->audio.openStream(&params, nullptr, RTAUDIO_FLOAT32, rate, &frames, Callback, fx, &options) != RTAUDIO_NO_ERROR)
            return 0;
        if (fx->audio.startStream() != RTAUDIO_NO_ERROR) {
            fx->audio.closeStream();
            return 0;
        }
        return fx->audio.getStreamSampleRate();
    } catch (...) {
        fx->error = "exception";
        return 0;
    }
}

void hddvd_fx_close(hddvd_fx *fx)
{
    if (fx->audio.isStreamOpen())
        fx->audio.closeStream();
}

const char *hddvd_fx_error(hddvd_fx *fx)
{
    return fx->error.c_str();
}

}
