/*
 * C glue for interactive playback (menus, buttons, stills) through the VLC 3 plugin API, reduced to
 * plumbing; all decisions are made in Zig.
 *
 *  - Mouse: VLC delivers "mouse-moved"/"mouse-clicked" on the vout thread. We only queue the latest event
 *    under a lock; the demux thread drains it (hddvd_mouse_poll), so the navigation VM is single-threaded.
 *  - ES output proxy: VLC's "ps" demuxer adds the elementary streams; it gets this proxy instead of the real
 *    es_out so Zig can fix up each es_format_t (SPU palette, languages) and learn the es_out_id_t of each
 *    stream id (for stream selection). Sub-picture units go to our own decoder (spudec.zig), which also draws
 *    the button highlights; VLC 3's input highlight variables can only crop to one button.
 */

#ifdef _WIN32
# include "win32_fixups.h" /* must precede the VLC headers */
#endif
#include <vlc_common.h>
#include <vlc_demux.h>
#include <vlc_es_out.h>
#include <vlc_input.h>
#include <vlc_vout.h>
#include <vlc_block.h>
#include <vlc_input_item.h>
#include <vlc_stream.h>

/* Implemented in Zig. */
void hddvd_es_fixup(demux_t *, es_format_t *);
void hddvd_es_added(demux_t *, int i_id, es_out_id_t *);
void hddvd_es_deleted(demux_t *, es_out_id_t *);
block_t *hddvd_es_filter(demux_t *, es_out_id_t *, block_t *);

/* ---- mouse ------------------------------------------------------------------------------------------ */

typedef struct
{
    vlc_mutex_t lock;
    vout_thread_t *vout;
    bool moved, clicked;
    int x, y;
} hddvd_mouse_t;

static int EventMouse(vlc_object_t *vout, char const *var, vlc_value_t oldval, vlc_value_t val, void *data)
{
    hddvd_mouse_t *m = data;
    vlc_mutex_lock(&m->lock);
    m->x = val.coords.x;
    m->y = val.coords.y;
    if (var[6] == 'm') /* mouse-moved */
        m->moved = true;
    else /* mouse-clicked */
        m->clicked = true;
    vlc_mutex_unlock(&m->lock);
    (void)vout; (void)oldval;
    return VLC_SUCCESS;
}

static void MouseDetach(hddvd_mouse_t *m)
{
    if (m->vout != NULL)
    {
        var_DelCallback(m->vout, "mouse-moved", EventMouse, m);
        var_DelCallback(m->vout, "mouse-clicked", EventMouse, m);
        vlc_object_release(m->vout);
        m->vout = NULL;
    }
}

static int EventIntf(vlc_object_t *input, char const *var, vlc_value_t oldval, vlc_value_t val, void *data)
{
    hddvd_mouse_t *m = data;
    if (val.i_int == INPUT_EVENT_VOUT)
    {
        MouseDetach(m);
        m->vout = input_GetVout((input_thread_t *)input);
        if (m->vout != NULL)
        {
            var_AddCallback(m->vout, "mouse-moved", EventMouse, m);
            var_AddCallback(m->vout, "mouse-clicked", EventMouse, m);
        }
    }
    (void)var; (void)oldval;
    return VLC_SUCCESS;
}

/* Starts listening for the input's video output (and so its mouse). NULL if there is no input (preparsing). */
void *hddvd_mouse_new(demux_t *demux)
{
    if (demux->p_input == NULL)
        return NULL;
    hddvd_mouse_t *m = calloc(1, sizeof(*m));
    if (m == NULL)
        return NULL;
    vlc_mutex_init(&m->lock);
    var_AddCallback(demux->p_input, "intf-event", EventIntf, m);
    return m;
}

void hddvd_mouse_delete(demux_t *demux, void *handle)
{
    hddvd_mouse_t *m = handle;
    if (m == NULL)
        return;
    var_DelCallback(demux->p_input, "intf-event", EventIntf, m);
    MouseDetach(m);
    vlc_mutex_destroy(&m->lock);
    free(m);
}

/* Takes the pending mouse state: returns 0 = nothing, 1 = moved, 2 = clicked (with the latest position). */
int hddvd_mouse_poll(void *handle, int *x, int *y)
{
    hddvd_mouse_t *m = handle;
    if (m == NULL)
        return 0;
    int ret = 0;
    vlc_mutex_lock(&m->lock);
    if (m->clicked)
        ret = 2;
    else if (m->moved)
        ret = 1;
    m->moved = m->clicked = false;
    *x = m->x;
    *y = m->y;
    vlc_mutex_unlock(&m->lock);
    return ret;
}

/* ---- es_out proxy --------------------------------------------------------------------------------------- */

struct es_out_sys_t
{
    demux_t *demux;
    es_out_t *parent;
};

static es_out_id_t *ProxyAdd(es_out_t *out, const es_format_t *fmt)
{
    es_format_t copy;
    es_format_Copy(&copy, fmt);
    hddvd_es_fixup(out->p_sys->demux, &copy);
    es_out_id_t *id = es_out_Add(out->p_sys->parent, &copy);
    if (id != NULL)
        hddvd_es_added(out->p_sys->demux, copy.i_id, id);
    es_format_Clean(&copy);
    return id;
}

static int ProxySend(es_out_t *out, es_out_id_t *id, block_t *block)
{
    block = hddvd_es_filter(out->p_sys->demux, id, block);
    if (block == NULL)
        return VLC_SUCCESS;
    return es_out_Send(out->p_sys->parent, id, block);
}

static void ProxyDel(es_out_t *out, es_out_id_t *id)
{
    hddvd_es_deleted(out->p_sys->demux, id);
    es_out_Del(out->p_sys->parent, id);
}

static int ProxyControl(es_out_t *out, int query, va_list args)
{
    return out->p_sys->parent->pf_control(out->p_sys->parent, query, args);
}

static void ProxyDestroy(es_out_t *out)
{
    free(out->p_sys);
    free(out);
}

es_out_t *hddvd_esout_new(demux_t *demux)
{
    es_out_t *out = malloc(sizeof(*out));
    es_out_sys_t *sys = malloc(sizeof(*sys));
    if (out == NULL || sys == NULL)
    {
        free(out);
        free(sys);
        return NULL;
    }
    sys->demux = demux;
    sys->parent = demux->out;
    out->pf_add = ProxyAdd;
    out->pf_send = ProxySend;
    out->pf_del = ProxyDel;
    out->pf_control = ProxyControl;
    out->pf_destroy = ProxyDestroy;
    out->p_sys = sys;
    return out;
}

void hddvd_esout_delete(es_out_t *out)
{
    if (out != NULL)
        out->pf_destroy(out);
}

/* ---- misc helpers callable from Zig ------------------------------------------------------------------- */

void hddvd_es_select(demux_t *demux, es_out_id_t *es, bool on)
{
    if (on)
        es_out_Control(demux->out, ES_OUT_SET_ES, es);
    else
        es_out_Control(demux->out, ES_OUT_SET_ES_STATE, es, false);
}

bool hddvd_es_selected(demux_t *demux, es_out_id_t *es)
{
    bool on = false;
    es_out_Control(demux->out, ES_OUT_GET_ES_STATE, es, &on);
    return on;
}

/* A sub-picture ES of our own on the input's output (not through the ps demuxer), for one of our decoders. */
es_out_id_t *hddvd_es_add_spu(demux_t *demux, vlc_fourcc_t codec, const void *extra, size_t len, const char *desc)
{
    es_format_t fmt;
    es_format_Init(&fmt, SPU_ES, codec);
    fmt.i_priority = ES_PRIORITY_NOT_DEFAULTABLE;
    fmt.b_packetized = true;
    fmt.psz_description = strdup(desc);
    fmt.p_extra = malloc(len);
    if (fmt.p_extra != NULL)
    {
        memcpy(fmt.p_extra, extra, len);
        fmt.i_extra = len;
    }
    es_out_id_t *es = es_out_Add(demux->out, &fmt); /* copies the format */
    /* Ours to free (not es_format_Clean: VLC's C runtime on Windows). */
    free(fmt.psz_description);
    free(fmt.p_extra);
    return es;
}

void hddvd_es_del(demux_t *demux, es_out_id_t *es)
{
    es_out_Del(demux->out, es);
}

void hddvd_es_send(demux_t *demux, es_out_id_t *es, block_t *block)
{
    es_out_Send(demux->out, es, block);
}

bool hddvd_es_out_empty(demux_t *demux)
{
    bool empty = true;
    es_out_Control(demux->out, ES_OUT_GET_EMPTY, &empty);
    return empty;
}

void hddvd_sleep_ms(int ms)
{
    msleep((mtime_t)ms * 1000);
}

int64_t hddvd_now_us(void)
{
    return mdate();
}

void hddvd_input_title_set_flags(input_title_t *t, int flags, const char *name)
{
    t->i_flags = flags;
    if (name != NULL)
        t->psz_name = strdup(name);
}

void hddvd_block_release(block_t *b)
{
    block_Release(b);
}

/* ISO 639 code as two bytes, e.g. 'e','n'. */
void hddvd_fmt_set_language(es_format_t *fmt, uint16_t code)
{
    char lang[3] = { (char)(code >> 8), (char)(code & 0xff), 0 };
    free(fmt->psz_language);
    fmt->psz_language = strdup(lang);
}

/* es_format_t.p_extra (freed by es_format_Clean). */
void hddvd_fmt_set_extra(es_format_t *fmt, const void *data, size_t len)
{
    free(fmt->p_extra);
    fmt->p_extra = malloc(len);
    fmt->i_extra = fmt->p_extra != NULL ? (int)len : 0;
    if (fmt->p_extra != NULL)
        memcpy(fmt->p_extra, data, len);
}

void hddvd_seekpoint_set_name(seekpoint_t *s, const char *name)
{
    if (name != NULL)
        s->psz_name = strdup(name);
}

/* Lists a folder through VLC's directory access (so file names never go through our C runtime's opendir):
 * calls cb(ctx, name) for each entry. */
int hddvd_list_dir(vlc_object_t *obj, const char *url, void (*cb)(void *, const char *), void *ctx)
{
    stream_t *s = vlc_stream_NewURL(obj, url);
    if (s == NULL)
        return VLC_EGENERIC;
    int ret = VLC_EGENERIC;
    input_item_t *item = input_item_New(url, NULL);
    input_item_node_t *node = item != NULL ? input_item_node_Create(item) : NULL;
    if (node != NULL)
    {
        ret = vlc_stream_ReadDir(s, node);
        if (ret == VLC_SUCCESS)
            for (int i = 0; i < node->i_children; i++)
                cb(ctx, node->pp_children[i]->p_item->psz_name);
        input_item_node_Delete(node);
    }
    if (item != NULL)
        input_item_Release(item);
    vlc_stream_Delete(s);
    return ret;
}

void hddvd_fmt_set_description(es_format_t *fmt, const char *desc)
{
    free(fmt->psz_description);
    fmt->psz_description = desc != NULL && desc[0] != 0 ? strdup(desc) : NULL;
}

/* ISO 639 code as a string, e.g. "en". */
void hddvd_fmt_set_language_str(es_format_t *fmt, const char *lang)
{
    free(fmt->psz_language);
    fmt->psz_language = strdup(lang);
}
