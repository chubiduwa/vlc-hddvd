//! The sub video (picture-in-picture) of Advanced Content as a VLC overlay (private fourcc `hdpv`, an SPU
//! decoder): VLC 3 would give a second video stream its own window, so the demux turns the sub video ES into a
//! sub-picture ES for this decoder. It decodes the frames with a nested VLC decoder (codec_glue.c), corrects
//! their times (retime.zig), and shows them through one long-lived subpicture whose updater picks, for each
//! rendered video frame, the sub video frame on screen and draws it as RGBA at the layout the application set
//! (position, size, opacity, luma key; HD DVD Vol. 1 §4.3.13.3.4).
//!
//! Frames are decoded ahead of display (VLC's buffering), so they wait in a ring with their display dates,
//! refreshed from the decoder's clock on every decode call (VLC adjusts its clock as it plays, and shifts it
//! across a pause). The updater shows the latest frame whose display date has come; when none has, it keeps
//! what it shows rather than blank the picture.

const std = @import("std");
const vlc = @import("vlc");
const present = @import("present.zig");
const compose = @import("compose.zig");
const retime = @import("retime.zig");
const vdec = @import("vdec.zig");

const gpa = std.heap.c_allocator;

/// VLC_FOURCC('h','d','p','v').
pub const fourcc: u32 = std.mem.readInt(u32, "hdpv", .little);
pub const kind = 1;

extern fn hddvd_pip_new(dec: *vlc.decoder_t, sys: *anyopaque) ?*vlc.subpicture_t;
extern fn hddvd_spu_queue(dec: *vlc.decoder_t, spu: *vlc.subpicture_t) void;
extern fn hddvd_region_new_rgba(w: c_uint, h: c_uint) ?*vlc.subpicture_region_t;
extern fn hddvd_block_release(b: *vlc.block_t) void;

fn log(obj: *vlc.vlc_object_t, prio: c_int, src: std.builtin.SourceLocation, comptime fmt: [*:0]const u8, args: anytype) void {
    @call(.auto, vlc.vlc_Log, .{ obj, prio, "hddvd", src.file, @as(c_uint, src.line), src.fn_name, fmt } ++ args);
}

const ring_len = 64;

const Frame = struct {
    pic: *vlc.picture_t,
    /// Stream timestamp (retimed).
    date: i64,
    /// Display date (mdate() time), 0 until the clock could tell.
    display: i64 = 0,
};

/// Decoded frames, shared by the decoder thread (producer) and the subpictures' updater (video output thread).
const Pip = struct {
    refs: std.atomic.Value(u32) = .init(1),
    lock: vlc.vlc_mutex_t = undefined,
    pres: *present.Presentation,
    // Under lock:
    ring: [ring_len]Frame = undefined,
    n: usize = 0,
    /// Live subpictures (normally 0 or 1): a new one is needed when it reaches 0.
    live: u32 = 0,

    fn create(pres: *present.Presentation) ?*Pip {
        const p = gpa.create(Pip) catch return null;
        p.* = .{ .pres = pres };
        pres.ref();
        vlc.vlc_mutex_init(&p.lock);
        return p;
    }

    fn ref(p: *Pip) void {
        _ = p.refs.fetchAdd(1, .monotonic);
    }

    fn unref(p: *Pip) void {
        if (p.refs.fetchSub(1, .acq_rel) != 1) return;
        p.clear();
        p.pres.unref();
        vlc.vlc_mutex_destroy(&p.lock);
        gpa.destroy(p);
    }

    /// Drops every frame (lock held or not shared yet).
    fn clear(p: *Pip) void {
        for (p.ring[0..p.n]) |f| vlc.picture_Release(f.pic);
        p.n = 0;
    }

    /// Index of the frame on screen at display date `ts`: the latest one due (lock held).
    fn at(p: *const Pip, ts: i64) ?usize {
        var chosen: ?usize = null;
        for (p.ring[0..p.n], 0..) |f, i| {
            if (f.display > 0 and f.display <= ts + 2000) chosen = i;
        }
        return chosen;
    }

    /// Refreshes the frames' display dates from a decoder's clock (lock held). No date (paused, buffering):
    /// the previous ones are kept.
    fn refresh(p: *Pip, dec: *vlc.decoder_t) void {
        const f = dec.pf_get_display_date orelse return;
        for (p.ring[0..p.n]) |*fr| {
            const d = f(dec, fr.date);
            if (d > 0) fr.display = d;
        }
    }
};

const Sys = struct {
    dec: *vlc.decoder_t,
    pip: *Pip,
    nested: ?*vdec.Nested = null,
    codec: u32,
    timer: retime.Retimer = retime.Retimer.init(0, 0),
    rate: [2]u32 = .{ 0, 0 },
    last_pts: i64 = 0,
    width: c_int,
    height: c_int,
};

fn sysOf(dec: *vlc.decoder_t) *Sys {
    return @ptrCast(@alignCast(dec.p_sys));
}

fn open(o: *vlc.vlc_object_t) callconv(.c) c_int {
    const dec: *vlc.decoder_t = @ptrCast(o);
    if (dec.fmt_in.i_cat != vlc.SPU_ES or dec.fmt_in.i_codec != fourcc) return vlc.VLC_EGENERIC;
    const x = present.Presentation.fromExtra(&dec.fmt_in) orelse return vlc.VLC_EGENERIC;
    const pip = Pip.create(x.pres) orelse return vlc.VLC_ENOMEM;
    const s = gpa.create(Sys) catch {
        pip.unref();
        return vlc.VLC_ENOMEM;
    };
    s.* = .{ .dec = dec, .pip = pip, .codec = x.codec, .width = x.pres.aperture_w, .height = x.pres.aperture_h };
    s.nested = vdec.hddvd_nested_new(o, &dec.fmt_in, vlc.VIDEO_ES, x.codec, s, kind) orelse {
        pip.unref();
        gpa.destroy(s);
        return vlc.VLC_EGENERIC;
    };
    dec.p_sys = @ptrCast(s);
    dec.pf_decode = decode;
    dec.pf_flush = flush;
    dec.fmt_out.i_codec = vlc.VLC_CODEC_RGBA;
    return vlc.VLC_SUCCESS;
}

fn close(o: *vlc.vlc_object_t) callconv(.c) void {
    const dec: *vlc.decoder_t = @ptrCast(o);
    const s = sysOf(dec);
    vdec.hddvd_nested_delete(s.nested);
    s.pip.unref();
    gpa.destroy(s);
}

fn decode(dec_c: [*c]vlc.decoder_t, block_c: [*c]vlc.block_t) callconv(.c) c_int {
    const s = sysOf(dec_c);
    const block: ?*vlc.block_t = block_c;
    if (block) |b| {
        if (b.i_pts > 0) s.last_pts = b.i_pts;
    }
    if (s.nested) |n| vdec.hddvd_nested_decode(n, block) else if (block) |b| hddvd_block_release(b);
    vlc.vlc_mutex_lock(&s.pip.lock);
    s.pip.refresh(s.dec);
    vlc.vlc_mutex_unlock(&s.pip.lock);
    return vlc.VLC_SUCCESS;
}

fn flush(dec_c: [*c]vlc.decoder_t) callconv(.c) void {
    const s = sysOf(dec_c);
    if (s.nested) |n| vdec.hddvd_nested_flush(n);
    s.timer.reset();
    const pip = s.pip;
    vlc.vlc_mutex_lock(&pip.lock);
    pip.clear();
    vlc.vlc_mutex_unlock(&pip.lock);
}

// ---- nested decoder output (via adec.zig's dispatcher) ------------------------------------------------------

pub fn onFormat(ctx: *anyopaque, inner: *vlc.decoder_t) c_int {
    const s: *Sys = @ptrCast(@alignCast(ctx));
    const f = &inner.fmt_out.unnamed_0.video;
    if (s.rate[0] != f.i_frame_rate or s.rate[1] != f.i_frame_rate_base) {
        log(@ptrCast(s.dec), vlc.VLC_MSG_DBG, @src(), "sub video: %ux%u, %u/%u fps", .{ f.i_visible_width, f.i_visible_height, f.i_frame_rate, f.i_frame_rate_base });
        s.rate = .{ f.i_frame_rate, f.i_frame_rate_base };
        s.timer = retime.Retimer.init(f.i_frame_rate, f.i_frame_rate_base);
    }
    return vlc.VLC_SUCCESS;
}

pub fn onPicture(ctx: *anyopaque, pic: *vlc.picture_t) void {
    const s: *Sys = @ptrCast(@alignCast(ctx));
    if (pic.date <= 0 or (s.last_pts > 0 and @abs(pic.date - s.last_pts) > 10_000_000) or vdec.yuvOf(pic) == null) {
        vlc.picture_Release(pic);
        return;
    }
    const date = s.timer.frame(pic.date, pic.i_nb_fields);
    const pip = s.pip;
    vlc.vlc_mutex_lock(&pip.lock);
    if (pip.n == ring_len) { // should not happen: the oldest frame is shown no more
        vlc.picture_Release(pip.ring[0].pic);
        std.mem.copyForwards(Frame, pip.ring[0 .. ring_len - 1], pip.ring[1..]);
        pip.n -= 1;
    }
    pip.ring[pip.n] = .{ .pic = pic, .date = date };
    pip.n += 1;
    pip.refresh(s.dec);
    const need_sub = pip.live == 0;
    vlc.vlc_mutex_unlock(&pip.lock);
    if (need_sub) newSubpicture(s, date);
}

/// One subpicture's updater state.
const View = struct {
    pip: *Pip,
    /// Stream timestamp of the frame drawn, and the layout generation it was drawn with.
    drawn: i64 = -1,
    drawn_gen: u32 = 0,
};

/// Starts the long-lived subpicture at stream time `date`.
fn newSubpicture(s: *Sys, date: i64) void {
    const pip = s.pip;
    const view = gpa.create(View) catch return;
    view.* = .{ .pip = pip };
    pip.ref();
    vlc.vlc_mutex_lock(&pip.lock);
    pip.live += 1;
    vlc.vlc_mutex_unlock(&pip.lock);
    const sub = hddvd_pip_new(s.dec, view) orelse {
        destroy(view);
        return;
    };
    sub.*.i_start = date;
    sub.*.i_stop = 0;
    sub.*.b_ephemer = true;
    sub.*.b_subtitle = true;
    sub.*.b_absolute = true;
    sub.*.i_original_picture_width = s.width;
    sub.*.i_original_picture_height = s.height;
    hddvd_spu_queue(s.dec, sub);
}

// ---- the subpicture's updater (spu_glue.c), on the video output thread ---------------------------------------

fn validate(sys: *anyopaque, fmt_changed: bool, ts: i64, start: i64) callconv(.c) bool {
    _ = start;
    const view: *View = @ptrCast(@alignCast(sys));
    const pip = view.pip;
    if (fmt_changed or pip.pres.layout_gen.load(.acquire) != view.drawn_gen) return true;
    vlc.vlc_mutex_lock(&pip.lock);
    defer vlc.vlc_mutex_unlock(&pip.lock);
    // Nothing due yet: keep what is shown.
    const i = pip.at(ts) orelse return view.drawn < 0 and pip.n > 0;
    return pip.ring[i].date != view.drawn;
}

fn update(sys: *anyopaque, sub: *vlc.subpicture_t, ts: i64, start: i64) callconv(.c) void {
    _ = start;
    const view: *View = @ptrCast(@alignCast(sys));
    const pip = view.pip;
    const pres = pip.pres;
    pres.lockIt();
    const alpha = pres.sub_alpha;
    const rect = pres.sub_rect;
    const key = pres.luma_key;
    const gen = pres.layout_gen.load(.acquire);
    pres.unlock();

    vlc.vlc_mutex_lock(&pip.lock);
    defer vlc.vlc_mutex_unlock(&pip.lock);
    view.drawn_gen = gen;
    if (pip.n == 0) return;
    // The frame due, or (redrawing for a new layout or size before any is due) the oldest one kept.
    const i = pip.at(ts) orelse 0;
    // Earlier frames will not be shown again; the one drawn stays first in the ring.
    for (pip.ring[0..i]) |f| vlc.picture_Release(f.pic);
    std.mem.copyForwards(Frame, pip.ring[0 .. pip.n - i], pip.ring[i..pip.n]);
    pip.n -= i;
    const f = pip.ring[0];
    view.drawn = f.date;
    if (alpha == 0) return; // hidden: no region

    const src = vdec.yuvOf(f.pic) orelse return;
    const r = rect orelse compose.Rect{
        .x = @divTrunc(@as(i32, pres.aperture_w) - @as(i32, @intCast(src.width())), 2),
        .y = @divTrunc(@as(i32, pres.aperture_h) - @as(i32, @intCast(src.height())), 2),
        .w = @intCast(src.width()),
        .h = @intCast(src.height()),
    };
    if (r.w <= 0 or r.h <= 0) return;
    const region = hddvd_region_new_rgba(@intCast(r.w), @intCast(r.h)) orelse return;
    const plane = &region.*.p_picture.*.p[0];
    const pitch: usize = @intCast(plane.i_pitch);
    const w: usize = @intCast(r.w);
    const h: usize = @intCast(r.h);
    const matrix: compose.Matrix = if (src.height() > 576) .bt709 else .bt601;
    compose.toRgba(plane.p_pixels[0 .. pitch * h], pitch, w, h, src, alpha, key, matrix);
    region.*.i_x = r.x;
    region.*.i_y = r.y;
    sub.p_region = region;
}

fn destroy(sys: *anyopaque) callconv(.c) void {
    const view: *View = @ptrCast(@alignCast(sys));
    const pip = view.pip;
    gpa.destroy(view);
    vlc.vlc_mutex_lock(&pip.lock);
    pip.live -= 1;
    vlc.vlc_mutex_unlock(&pip.lock);
    pip.unref();
}

comptime {
    const hidden: std.builtin.SymbolVisibility = .hidden;
    @export(&open, .{ .name = "HddvdPipOpen", .visibility = hidden });
    @export(&close, .{ .name = "HddvdPipClose", .visibility = hidden });
    @export(&validate, .{ .name = "hddvd_pip_validate", .visibility = hidden });
    @export(&update, .{ .name = "hddvd_pip_update", .visibility = hidden });
    @export(&destroy, .{ .name = "hddvd_pip_destroy", .visibility = hidden });
}
