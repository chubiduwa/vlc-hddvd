/*
 * The C side of the plugin, kept as small as possible:
 *  - the VLC module descriptor: the HD DVD demux and its sub-picture decoder (vlc_module_begin() macros
 *    generate the exported vlc_entry__3_0_0f, vlc_entry_copyright__3_0_0f and vlc_entry_license__3_0_0f);
 *  - va_list plumbing: VLC passes control arguments as va_list, and es_out_Control()/vlc_stream_Control()
 *    are inline variadic functions. The dispatchers below decode the arguments and call typed functions
 *    implemented in Zig (hddvd.zig), so Zig never touches a va_list.
 */

/* In-tree builds get these from __LIBVLC__; they become vlc_entry_copyright/license__3_0_0f. */
#define VLC_MODULE_COPYRIGHT "Copyright (C) the vlc-hddvd authors"
#define VLC_MODULE_LICENSE VLC_LICENSE_LGPL_2_1_PLUS

#ifdef _WIN32
# include "win32_fixups.h" /* must precede the VLC headers */
#endif
#include <vlc_common.h>
#include <vlc_plugin.h>
#include <vlc_demux.h>
#include <vlc_input.h>
#include <vlc_stream.h>

/* Implemented in Zig (hddvd.zig). */
int HddvdOpen(vlc_object_t *);
void HddvdClose(vlc_object_t *);
int HddvdSpuOpen(vlc_object_t *);
void HddvdSpuClose(vlc_object_t *);
int HddvdVdecOpen(vlc_object_t *);
void HddvdVdecClose(vlc_object_t *);
int HddvdAdecOpen(vlc_object_t *);
void HddvdAdecClose(vlc_object_t *);
int HddvdPipOpen(vlc_object_t *);
void HddvdPipClose(vlc_object_t *);
int HddvdOverlayOpen(vlc_object_t *);
void HddvdOverlayClose(vlc_object_t *);
int hddvd_get_position(demux_t *, double *);
int hddvd_set_position(demux_t *, double);
int hddvd_get_length(demux_t *, int64_t *);
int hddvd_get_time(demux_t *, int64_t *);
int hddvd_set_time(demux_t *, int64_t);
int hddvd_get_title_info(demux_t *, input_title_t ***, int *);
int hddvd_set_title(demux_t *, int);
int hddvd_set_seekpoint(demux_t *, int);
int hddvd_nav(demux_t *, int action);
void hddvd_set_pause(demux_t *, bool paused);
uint64_t hddvd_stream_size(stream_t *);

vlc_module_begin()
    set_shortname("HD DVD")
    set_description("HD DVD input (Standard and Advanced Content)")
    set_category(CAT_INPUT)
    set_subcategory(SUBCAT_INPUT_ACCESS)
    /* Like dvdread: an access_demux reached through its own scheme, e.g. hddvd:///Volumes/DISC */
    set_capability("access_demux", 0)
    add_shortcut("hddvd")
    set_callbacks(HddvdOpen, HddvdClose)
    add_string("hddvd-gprm", NULL, "Initial GPRMs (debugging)",
               "General parameters to set before playback starts, and again whenever a Title_Play resets them, "
               "as n=value pairs separated by commas (e.g. 1=5,2=1). Useful with hddvd:///disc.iso#title to start "
               "a title directly when it expects registers that the disc's menus normally set.", true)
    add_string("hddvd-pip", NULL, "Picture-in-picture layout (debugging)",
               "Advanced Content: show the sub video at x,y,width,height[,alpha] (aperture pixels, alpha 0-255) "
               "without waiting for the disc's application to place it.", true)
    add_string("hddvd-sub-mix", NULL, "Sub audio level (debugging)",
               "Advanced Content: mix the sub audio (e.g. a commentary) at this level (0-1) without waiting for "
               "the disc's application.", true)
    add_string("hddvd-markup-show", NULL, "Show markup elements (debugging)",
               "Advanced Content: show these elements of the applications' pages (ids, separated by commas), "
               "whatever their style says, to check the rendering before the disc's scripts run.", true)
    add_bool("hddvd-test-page", false, "Graphics test page (debugging)",
             "Advanced Content: draw a test page in the graphics plane (clocks, a moving box, a clear rectangle "
             "and the cursor) to check the overlay over playback, pause and seek.", true)

    /* Sub-pictures with button highlights (spudec.zig); only takes the ESes the demux marks with its fourcc. */
    add_submodule()
    set_description("HD DVD sub-pictures")
    set_capability("spu decoder", 50)
    set_callbacks(HddvdSpuOpen, HddvdSpuClose)

    /* Advanced Content: the main video with corrected frame times (adv/vdec.zig), the sub video decoded for the
     * overlay (adv/pipdec.zig), the overlay holding the sub video, sub-picture, graphics and cursor planes
     * (adv/overlay.zig), main + sub + effect audio mixed (adv/adec.zig). Only take the ESes the demux marks with
     * their fourccs. */
    add_submodule()
    set_description("HD DVD sub video")
    set_capability("spu decoder", 50)
    set_callbacks(HddvdPipOpen, HddvdPipClose)
    add_submodule()
    set_description("HD DVD graphics overlay")
    set_capability("spu decoder", 50)
    set_callbacks(HddvdOverlayOpen, HddvdOverlayClose)
    add_submodule()
    set_description("HD DVD main video")
    set_capability("video decoder", 50)
    set_callbacks(HddvdVdecOpen, HddvdVdecClose)
    add_submodule()
    set_description("HD DVD audio mixer")
    set_capability("audio decoder", 50)
    set_callbacks(HddvdAdecOpen, HddvdAdecClose)
vlc_module_end()

/* pf_control of the demux_t; installed by HddvdOpen (Zig). */
int HddvdDemuxControl(demux_t *demux, int query, va_list args)
{
    switch (query)
    {
        case DEMUX_CAN_SEEK:
        case DEMUX_CAN_PAUSE:
        case DEMUX_CAN_CONTROL_PACE:
            *va_arg(args, bool *) = true;
            return VLC_SUCCESS;

        case DEMUX_SET_PAUSE_STATE:
            hddvd_set_pause(demux, (bool)va_arg(args, int));
            return VLC_SUCCESS;

        case DEMUX_GET_PTS_DELAY:
            *va_arg(args, int64_t *) = INT64_C(1000) * var_InheritInteger(demux, "disc-caching");
            return VLC_SUCCESS;

        case DEMUX_GET_POSITION:
            return hddvd_get_position(demux, va_arg(args, double *));

        case DEMUX_SET_POSITION:
            return hddvd_set_position(demux, va_arg(args, double));

        case DEMUX_GET_LENGTH:
            return hddvd_get_length(demux, va_arg(args, int64_t *));

        case DEMUX_GET_TIME:
            return hddvd_get_time(demux, va_arg(args, int64_t *));

        case DEMUX_SET_TIME:
            return hddvd_set_time(demux, va_arg(args, int64_t));

        case DEMUX_GET_TITLE_INFO:
        {
            input_title_t ***titles = va_arg(args, input_title_t ***);
            int *count = va_arg(args, int *);
            *va_arg(args, int *) = 0; /* title offset */
            *va_arg(args, int *) = 0; /* seekpoint offset */
            return hddvd_get_title_info(demux, titles, count);
        }

        case DEMUX_SET_TITLE:
            return hddvd_set_title(demux, va_arg(args, int));

        case DEMUX_SET_SEEKPOINT:
            return hddvd_set_seekpoint(demux, va_arg(args, int));

        case DEMUX_NAV_ACTIVATE: return hddvd_nav(demux, 0);
        case DEMUX_NAV_UP:       return hddvd_nav(demux, 1);
        case DEMUX_NAV_DOWN:     return hddvd_nav(demux, 2);
        case DEMUX_NAV_LEFT:     return hddvd_nav(demux, 3);
        case DEMUX_NAV_RIGHT:    return hddvd_nav(demux, 4);
        case DEMUX_NAV_POPUP:    return hddvd_nav(demux, 5);
        case DEMUX_NAV_MENU:     return hddvd_nav(demux, 6);

        default:
            return VLC_EGENERIC;
    }
}

/* pf_control of the per-title stream that feeds VLC's "ps" demuxer; installed from Zig. */
int HddvdStreamControl(stream_t *s, int query, va_list args)
{
    switch (query)
    {
        case STREAM_CAN_SEEK:
        case STREAM_CAN_FASTSEEK:
        case STREAM_CAN_PAUSE:
        case STREAM_CAN_CONTROL_PACE:
            *va_arg(args, bool *) = true;
            return VLC_SUCCESS;

        case STREAM_GET_SIZE:
            *va_arg(args, uint64_t *) = hddvd_stream_size(s);
            return VLC_SUCCESS;

        case STREAM_GET_PTS_DELAY:
            *va_arg(args, int64_t *) = INT64_C(1000) * var_InheritInteger(s, "disc-caching");
            return VLC_SUCCESS;

        case STREAM_SET_PAUSE_STATE:
            return VLC_SUCCESS;

        default:
            return VLC_EGENERIC;
    }
}

/* Variadic wrappers callable from Zig (the VLC versions are static inline). */
int hddvd_es_out_control(es_out_t *out, int query, ...)
{
    va_list args;
    va_start(args, query);
    int ret = out->pf_control(out, query, args);
    va_end(args);
    return ret;
}

int hddvd_stream_get_size(stream_t *s, uint64_t *size)
{
    return vlc_stream_GetSize(s, size);
}

/* VLC object-tree helpers (macros over vlc_object_t casts). */
void hddvd_stream_delete(stream_t *s)
{
    vlc_stream_Delete(s);
}

/* var_InheritString() is static inline; the result is freed with hddvd_free(). */
char *hddvd_inherit_string(vlc_object_t *obj, const char *name)
{
    return var_InheritString(obj, name);
}

void hddvd_free(void *p)
{
    free(p);
}

void hddvd_set_update(demux_t *demux, unsigned flags, int title, int seekpoint)
{
    demux->info.i_update |= flags;
    demux->info.i_title = title;
    demux->info.i_seekpoint = seekpoint;
}

/* var_InheritBool() is static inline. */
bool hddvd_inherit_bool(vlc_object_t *obj, const char *name)
{
    return var_InheritBool(obj, name);
}
