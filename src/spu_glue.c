/*
 * C glue for the HD DVD sub-picture decoder (spudec.zig): VLC's subpicture updater callbacks, and wrappers for
 * the static inline decoder/video-format helpers.
 */

#ifdef _WIN32
# include "win32_fixups.h" /* must precede the VLC headers */
#endif
#include <vlc_common.h>
#include <vlc_codec.h>
#include <vlc_subpicture.h>

/* Implemented in Zig. */
bool hddvd_spu_validate(void *sys, bool fmt_changed);
void hddvd_spu_update(void *sys, subpicture_t *spu);
void hddvd_spu_destroy(void *sys);

/* Called before every rendered frame: non-zero (VLC_EGENERIC) asks for pf_update. */
static int Validate(subpicture_t *spu, bool src_changed, const video_format_t *src, bool dst_changed,
                    const video_format_t *dst, vlc_tick_t ts)
{
    (void)src; (void)dst; (void)ts;
    return hddvd_spu_validate(spu->updater.p_sys, src_changed || dst_changed) ? VLC_EGENERIC : VLC_SUCCESS;
}

static void Update(subpicture_t *spu, const video_format_t *src, const video_format_t *dst, vlc_tick_t ts)
{
    (void)src; (void)dst; (void)ts;
    hddvd_spu_update(spu->updater.p_sys, spu);
}

static void Destroy(subpicture_t *spu)
{
    hddvd_spu_destroy(spu->updater.p_sys);
}

/* A subpicture drawn by spudec.zig on demand; NULL if there is no video output (sys is then not owned). */
subpicture_t *hddvd_spu_new(decoder_t *dec, void *sys)
{
    subpicture_updater_t updater = {
        .pf_validate = Validate,
        .pf_update = Update,
        .pf_destroy = Destroy,
        .p_sys = (subpicture_updater_sys_t *)sys,
    };
    return decoder_NewSubpicture(dec, &updater);
}

void hddvd_spu_queue(decoder_t *dec, subpicture_t *spu)
{
    decoder_QueueSub(dec, spu);
}

subpicture_region_t *hddvd_region_new_yuva(unsigned width, unsigned height)
{
    video_format_t fmt;
    video_format_Init(&fmt, VLC_CODEC_YUVA);
    fmt.i_sar_num = 0; /* 0 = the video's aspect ratio, as spudec does */
    fmt.i_sar_den = 1;
    fmt.i_width = fmt.i_visible_width = width;
    fmt.i_height = fmt.i_visible_height = height;
    subpicture_region_t *r = subpicture_region_New(&fmt);
    video_format_Clean(&fmt);
    return r;
}

/* ---- picture-in-picture overlay (adv/pipdec.zig) ------------------------------------------------------- */

bool hddvd_pip_validate(void *sys, bool fmt_changed, vlc_tick_t ts, vlc_tick_t start);
void hddvd_pip_update(void *sys, subpicture_t *spu, vlc_tick_t ts, vlc_tick_t start);
void hddvd_pip_destroy(void *sys);

static int PipValidate(subpicture_t *spu, bool src_changed, const video_format_t *src, bool dst_changed,
                       const video_format_t *dst, vlc_tick_t ts)
{
    (void)src; (void)dst;
    return hddvd_pip_validate(spu->updater.p_sys, src_changed || dst_changed, ts, spu->i_start) ? VLC_EGENERIC : VLC_SUCCESS;
}

static void PipUpdate(subpicture_t *spu, const video_format_t *src, const video_format_t *dst, vlc_tick_t ts)
{
    (void)src; (void)dst;
    hddvd_pip_update(spu->updater.p_sys, spu, ts, spu->i_start);
}

static void PipDestroy(subpicture_t *spu)
{
    hddvd_pip_destroy(spu->updater.p_sys);
}

/* The long-lived subpicture showing the sub video; NULL if there is no video output (sys is then not owned). */
subpicture_t *hddvd_pip_new(decoder_t *dec, void *sys)
{
    subpicture_updater_t updater = {
        .pf_validate = PipValidate,
        .pf_update = PipUpdate,
        .pf_destroy = PipDestroy,
        .p_sys = (subpicture_updater_sys_t *)sys,
    };
    return decoder_NewSubpicture(dec, &updater);
}

subpicture_region_t *hddvd_region_new_rgba(unsigned width, unsigned height)
{
    video_format_t fmt;
    video_format_Init(&fmt, VLC_CODEC_RGBA);
    fmt.i_sar_num = 1;
    fmt.i_sar_den = 1;
    fmt.i_width = fmt.i_visible_width = width;
    fmt.i_height = fmt.i_visible_height = height;
    subpicture_region_t *r = subpicture_region_New(&fmt);
    video_format_Clean(&fmt);
    return r;
}
