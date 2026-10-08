//! The sub video (picture-in-picture) of Advanced Content (private fourcc `hdpv`, an SPU decoder): VLC 3 would
//! give a second video stream its own window, so the demux turns the sub video ES into a sub-picture ES for
//! this decoder. It decodes the frames with a nested VLC decoder (codec_glue.c), corrects their times
//! (retime.zig), and hands them to the overlay (overlay.zig), which draws the frame on screen as the bottom
//! of its planes, at the layout the application set (position, size, opacity, luma key; HD DVD Vol. 1
//! §4.3.13.3.4).
//!
//! Frames are decoded ahead of display (VLC's buffering), so they wait in a ring with their display dates,
//! refreshed from the decoder's clock on every decode call (VLC adjusts its clock as it plays, and shifts it
//! across a pause). The overlay shows the latest frame whose display date has come; when none has, it keeps
//! what it shows rather than blank the picture.

const std = @import("std");
const vlc = @import("vlc");
const present = @import("present.zig");
const retime = @import("retime.zig");
const vdec = @import("vdec.zig");

const gpa = std.heap.c_allocator;

/// VLC_FOURCC('h','d','p','v').
pub const fourcc: u32 = std.mem.readInt(u32, "hdpv", .little);
pub const kind = 1;

extern fn hddvd_block_release(b: *vlc.block_t) void;

fn log(obj: *vlc.vlc_object_t, prio: c_int, src: std.builtin.SourceLocation, comptime fmt: [*:0]const u8, args: anytype) void {
    @call(.auto, vlc.vlc_Log, .{ obj, prio, "hddvd", src.file, @as(c_uint, src.line), src.fn_name, fmt } ++ args);
}

const ring_len = 64;

pub const Frame = struct {
    pic: *vlc.picture_t,
    /// Stream timestamp (retimed).
    date: i64,
    /// Display date (mdate() time), 0 until the clock could tell.
    display: i64 = 0,
};

/// Decoded frames, shared by the decoder thread (producer) and the overlay (video output thread).
pub const Pip = struct {
    refs: std.atomic.Value(u32) = .init(1),
    lock: vlc.vlc_mutex_t = undefined,
    // Under lock:
    ring: [ring_len]Frame = undefined,
    n: usize = 0,

    fn create() ?*Pip {
        const p = gpa.create(Pip) catch return null;
        p.* = .{};
        vlc.vlc_mutex_init(&p.lock);
        return p;
    }

    pub fn ref(p: *Pip) void {
        _ = p.refs.fetchAdd(1, .monotonic);
    }

    pub fn unref(p: *Pip) void {
        if (p.refs.fetchSub(1, .acq_rel) != 1) return;
        p.clear();
        vlc.vlc_mutex_destroy(&p.lock);
        gpa.destroy(p);
    }

    pub fn lockIt(p: *Pip) void {
        vlc.vlc_mutex_lock(&p.lock);
    }

    pub fn unlock(p: *Pip) void {
        vlc.vlc_mutex_unlock(&p.lock);
    }

    /// Drops every frame (lock held or not shared yet).
    fn clear(p: *Pip) void {
        for (p.ring[0..p.n]) |f| vlc.picture_Release(f.pic);
        p.n = 0;
    }

    /// Index of the frame on screen at display date `ts`: the latest one due (lock held).
    pub fn at(p: *const Pip, ts: i64) ?usize {
        var chosen: ?usize = null;
        for (p.ring[0..p.n], 0..) |f, i| {
            if (f.display > 0 and f.display <= ts + 2000) chosen = i;
        }
        return chosen;
    }

    /// The frame to show at display date `ts` (lock held): the one due, or, when none is due yet, the oldest
    /// one kept. Earlier frames will not be shown again and are dropped, so it stays first in the ring.
    pub fn take(p: *Pip, ts: i64) ?Frame {
        if (p.n == 0) return null;
        const i = p.at(ts) orelse 0;
        for (p.ring[0..i]) |f| vlc.picture_Release(f.pic);
        std.mem.copyForwards(Frame, p.ring[0 .. p.n - i], p.ring[i..p.n]);
        p.n -= i;
        return p.ring[0];
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
    pres: *present.Presentation,
    pip: *Pip,
    nested: ?*vdec.Nested = null,
    codec: u32,
    timer: retime.Retimer = retime.Retimer.init(0, 0),
    rate: [2]u32 = .{ 0, 0 },
    last_pts: i64 = 0,
};

fn sysOf(dec: *vlc.decoder_t) *Sys {
    return @ptrCast(@alignCast(dec.p_sys));
}

fn open(o: *vlc.vlc_object_t) callconv(.c) c_int {
    const dec: *vlc.decoder_t = @ptrCast(o);
    if (dec.fmt_in.i_cat != vlc.SPU_ES or dec.fmt_in.i_codec != fourcc) return vlc.VLC_EGENERIC;
    const x = present.Presentation.fromExtra(&dec.fmt_in) orelse return vlc.VLC_EGENERIC;
    const pip = Pip.create() orelse return vlc.VLC_ENOMEM;
    const s = gpa.create(Sys) catch {
        pip.unref();
        return vlc.VLC_ENOMEM;
    };
    s.* = .{ .dec = dec, .pres = x.pres, .pip = pip, .codec = x.codec };
    s.nested = vdec.hddvd_nested_new(o, &dec.fmt_in, vlc.VIDEO_ES, x.codec, s, kind) orelse {
        pip.unref();
        gpa.destroy(s);
        return vlc.VLC_EGENERIC;
    };
    x.pres.ref();
    x.pres.setPip(pip);
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
    s.pres.setPip(null);
    s.pres.unref();
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
    vlc.vlc_mutex_unlock(&pip.lock);
}

comptime {
    const hidden: std.builtin.SymbolVisibility = .hidden;
    @export(&open, .{ .name = "HddvdPipOpen", .visibility = hidden });
    @export(&close, .{ .name = "HddvdPipClose", .visibility = hidden });
}
