/*
 * C glue for our compositing video decoder and mixing audio decoder (adv/vdec.zig, adv/adec.zig): VLC 3 cannot
 * composite two video streams or mix two audio streams, so those decoders run VLC's own packetizers and
 * decoders inside them ("nested" decoders, as the transcode stream output does) and combine the results.
 * All decisions are made in Zig; this is plumbing over VLC's static inline helpers.
 */

#ifdef _WIN32
# include "win32_fixups.h" /* must precede the VLC headers */
#endif
#include <vlc_common.h>
#include <vlc_codec.h>
#include <vlc_modules.h>
#include <vlc_picture.h>
#include <vlc_aout.h>
#include <vlc_block.h>

/* Implemented in Zig: decoded output of a nested decoder (`kind` as given to hddvd_nested_new). */
int hddvd_nested_on_format(void *ctx, int kind, decoder_t *dec);
void hddvd_nested_on_picture(void *ctx, int kind, picture_t *pic);
void hddvd_nested_on_audio(void *ctx, int kind, block_t *block);

typedef struct hddvd_nested
{
    vlc_object_t *parent;
    es_format_t fmt;   /* input format, with the real codec */
    decoder_t *pk;     /* packetizer */
    decoder_t *dec;    /* decoder, created once the packetizer has described the stream */
    void *ctx;
    int kind;
    bool failed;
} hddvd_nested_t;

static int VideoFormatUpdate(decoder_t *dec)
{
    hddvd_nested_t *n = dec->p_queue_ctx;
    dec->fmt_out.video.i_chroma = dec->fmt_out.i_codec;
    return hddvd_nested_on_format(n->ctx, n->kind, dec);
}

static picture_t *VideoBufferNew(decoder_t *dec)
{
    return picture_NewFromFormat(&dec->fmt_out.video);
}

static int QueueVideo(decoder_t *dec, picture_t *pic)
{
    hddvd_nested_t *n = dec->p_queue_ctx;
    hddvd_nested_on_picture(n->ctx, n->kind, pic);
    return 0;
}

static int AudioFormatUpdate(decoder_t *dec)
{
    hddvd_nested_t *n = dec->p_queue_ctx;
    dec->fmt_out.audio.i_format = dec->fmt_out.i_codec;
    aout_FormatPrepare(&dec->fmt_out.audio);
    return hddvd_nested_on_format(n->ctx, n->kind, dec);
}

static int QueueAudio(decoder_t *dec, block_t *block)
{
    hddvd_nested_t *n = dec->p_queue_ctx;
    hddvd_nested_on_audio(n->ctx, n->kind, block);
    return 0;
}

static decoder_t *NewModule(hddvd_nested_t *n, const es_format_t *fmt, bool packetizer)
{
    decoder_t *d = vlc_object_create(n->parent, sizeof(*d));
    if (d == NULL)
        return NULL;
    d->p_module = NULL;
    d->p_sys = NULL;
    es_format_Copy(&d->fmt_in, fmt);
    es_format_Init(&d->fmt_out, fmt->i_cat, 0);
    d->b_frame_drop_allowed = false;
    d->p_queue_ctx = n;

    const char *cap;
    const char *name = NULL;
    bool strict = false;
    if (packetizer)
        cap = "packetizer";
    else if (fmt->i_cat == VIDEO_ES)
    {
        d->fmt_in.b_packetized = true;
        d->pf_vout_format_update = VideoFormatUpdate;
        d->pf_vout_buffer_new = VideoBufferNew;
        d->pf_queue_video = QueueVideo;
        /* Software decoding: the pictures are composited on the CPU. */
        var_Create(d, "avcodec-hw", VLC_VAR_STRING);
        var_SetString(d, "avcodec-hw", "none");
        cap = "video decoder";
        name = "avcodec";
        strict = true;
    }
    else
    {
        d->fmt_in.b_packetized = true;
        d->pf_aout_format_update = AudioFormatUpdate;
        d->pf_queue_audio = QueueAudio;
        cap = "audio decoder";
        /* Decoded samples (not the S/PDIF pass-through "decoder"): they are mixed. */
        name = "avcodec,lpcm,araw,mpg123,faad,dts";
        strict = true;
    }
    d->p_module = module_need(d, cap, name, strict);
    if (d->p_module == NULL)
    {
        es_format_Clean(&d->fmt_in);
        es_format_Clean(&d->fmt_out);
        vlc_object_release(d);
        return NULL;
    }
    return d;
}

static void DeleteModule(decoder_t *d)
{
    if (d == NULL)
        return;
    module_unneed(d, d->p_module);
    es_format_Clean(&d->fmt_in);
    es_format_Clean(&d->fmt_out);
    vlc_object_release(d);
}

/* A packetizer + decoder for `codec` of category `cat`, with the rest of `fmt` (from the ES; its stream
 * attributes are dropped if the ES has another category). NULL if VLC has no packetizer. */
hddvd_nested_t *hddvd_nested_new(vlc_object_t *parent, const es_format_t *fmt, int cat, vlc_fourcc_t codec, void *ctx, int kind)
{
    hddvd_nested_t *n = calloc(1, sizeof(*n));
    if (n == NULL)
        return NULL;
    n->parent = parent;
    n->ctx = ctx;
    n->kind = kind;
    if (fmt->i_cat == cat)
        es_format_Copy(&n->fmt, fmt);
    else
    {
        es_format_Init(&n->fmt, cat, codec);
        n->fmt.i_id = fmt->i_id;
        n->fmt.i_group = fmt->i_group;
    }
    n->fmt.i_codec = codec;
    n->fmt.i_original_fourcc = 0;
    n->fmt.b_packetized = false;
    free(n->fmt.p_extra); /* ours (the shared-state pointer) */
    n->fmt.p_extra = NULL;
    n->fmt.i_extra = 0;
    n->pk = NewModule(n, &n->fmt, true);
    if (n->pk == NULL)
    {
        msg_Err(parent, "no packetizer for %4.4s", (const char *)&codec);
        es_format_Clean(&n->fmt);
        free(n);
        return NULL;
    }
    return n;
}

static void Decode(hddvd_nested_t *n, block_t *b, bool retry)
{
    if (n->dec == NULL && !n->failed)
    {
        const es_format_t *f = n->pk->fmt_out.i_codec != 0 ? &n->pk->fmt_out : &n->fmt;
        n->dec = NewModule(n, f, false);
        if (n->dec == NULL)
        {
            msg_Err(n->parent, "no decoder for %4.4s", (const char *)&f->i_codec);
            n->failed = true;
        }
    }
    if (n->dec == NULL)
    {
        if (b != NULL)
            block_Release(b);
        return;
    }
    int ret = n->dec->pf_decode(n->dec, b);
    if (ret == VLCDEC_RELOAD)
    {
        /* The decoder asks to be replaced (e.g. a format change): retry once with a new one. */
        DeleteModule(n->dec);
        n->dec = NULL;
        if (retry)
            Decode(n, b, false);
        else
            block_Release(b);
    }
}

/* Packetizes and decodes a block (NULL drains everything). */
void hddvd_nested_decode(hddvd_nested_t *n, block_t *b)
{
    block_t **pp = b != NULL ? &b : NULL;
    block_t *out;
    while ((out = n->pk->pf_packetize(n->pk, pp)) != NULL)
    {
        while (out != NULL)
        {
            block_t *next = out->p_next;
            out->p_next = NULL;
            Decode(n, out, true);
            out = next;
        }
    }
    if (b == NULL && n->dec != NULL)
        n->dec->pf_decode(n->dec, NULL);
}

/* A decoder's pf_flush may call owner functions (avcodec's calls decoder_AbortPictures, which needs the
 * decoder owner a nested decoder does not have): the decoder is recreated instead. */
void hddvd_nested_flush(hddvd_nested_t *n)
{
    if (n->pk->pf_flush != NULL)
        n->pk->pf_flush(n->pk);
    DeleteModule(n->dec);
    n->dec = NULL;
    n->failed = false;
}

void hddvd_nested_delete(hddvd_nested_t *n)
{
    if (n == NULL)
        return;
    DeleteModule(n->dec);
    DeleteModule(n->pk);
    es_format_Clean(&n->fmt);
    free(n);
}

/* ---- the outer decoder's output (static inline helpers) ------------------------------------------------ */

int hddvd_dec_update_video(decoder_t *dec)
{
    return decoder_UpdateVideoFormat(dec);
}

picture_t *hddvd_dec_new_picture(decoder_t *dec)
{
    return decoder_NewPicture(dec);
}

void hddvd_dec_queue_video(decoder_t *dec, picture_t *pic)
{
    decoder_QueueVideo(dec, pic);
}

int hddvd_dec_update_audio(decoder_t *dec)
{
    return decoder_UpdateAudioFormat(dec);
}

void hddvd_dec_queue_audio(decoder_t *dec, block_t *b)
{
    decoder_QueueAudio(dec, b);
}

/* Prepares an FL32 audio format with `channels` (an AOUT_CHAN_* mask) at `rate`. */
void hddvd_audio_fmt_fl32(audio_format_t *fmt, unsigned rate, unsigned channels)
{
    fmt->i_format = VLC_CODEC_FL32;
    fmt->i_rate = rate;
    fmt->i_physical_channels = channels;
    fmt->i_chan_mode = 0;
    aout_FormatPrepare(fmt);
}
