//! The planes of Advanced Content above the main video, as one VLC overlay (private fourcc `hdov`, an SPU
//! decoder of an ES the demux adds for it). HD DVD Vol. 1 §4.3.13.3 stacks, from the bottom: main video, sub
//! video, sub-picture, graphics, cursor. VLC 3 orders separate subpictures by their start dates, so the four
//! upper planes are the regions of a single long-lived subpicture, in that order:
//!
//! - the sub video frame on screen (pipdec.zig), scaled, with its opacity and luma key;
//! - the sub-picture plane: the display periods of the selected sub-picture streams (spudec.zig);
//! - the graphics plane: the engine's last finished frame, only its tiles that hold anything;
//! - the cursor.
//!
//! The graphics frame's clear rectangles (§7.8.4) are holes through the sub-picture plane, and with target
//! `main` through the sub video plane too. VLC asks the subpicture's updater before every rendered video frame
//! whether anything changed, and rebuilds its regions when it did. Seeking flushes this decoder, which deletes
//! the subpicture; the demux then sends a new block, which starts another.

const std = @import("std");
const vlc = @import("vlc");
const present = @import("present.zig");
const planes = @import("planes.zig");
const raster = @import("raster.zig");
const compose = @import("compose.zig");
const vdec = @import("vdec.zig");
const spudec = @import("../spudec.zig");

const gpa = std.heap.c_allocator;

/// VLC_FOURCC('h','d','o','v').
pub const fourcc: u32 = std.mem.readInt(u32, "hdov", .little);

extern fn hddvd_ov_new(dec: *vlc.decoder_t, sys: *anyopaque) ?*vlc.subpicture_t;
extern fn hddvd_spu_queue(dec: *vlc.decoder_t, spu: *vlc.subpicture_t) void;
extern fn hddvd_region_new_rgba(w: c_uint, h: c_uint) ?*vlc.subpicture_region_t;
extern fn hddvd_region_new_yuva(w: c_uint, h: c_uint) ?*vlc.subpicture_region_t;
extern fn hddvd_block_release(b: *vlc.block_t) void;

/// How many subpictures of this decoder are alive (normally 0 or 1); shared with their updaters, which can
/// outlive the decoder.
const Live = struct {
    refs: std.atomic.Value(u32) = .init(1),
    count: std.atomic.Value(u32) = .init(0),

    fn unref(l: *Live) void {
        if (l.refs.fetchSub(1, .acq_rel) == 1) gpa.destroy(l);
    }
};

const Sys = struct {
    pres: *present.Presentation,
    live: *Live,
    /// Flushed since the last subpicture started: the next block starts another. A flush only marks the
    /// subpicture for deletion, which the video output does at its next redraw, so it may still count as live.
    flushed: bool = false,
};

fn open(o: *vlc.vlc_object_t) callconv(.c) c_int {
    const dec: *vlc.decoder_t = @ptrCast(o);
    if (dec.fmt_in.i_cat != vlc.SPU_ES or dec.fmt_in.i_codec != fourcc) return vlc.VLC_EGENERIC;
    const x = present.Presentation.fromExtra(&dec.fmt_in) orelse return vlc.VLC_EGENERIC;
    const s = gpa.create(Sys) catch return vlc.VLC_ENOMEM;
    const live = gpa.create(Live) catch {
        gpa.destroy(s);
        return vlc.VLC_ENOMEM;
    };
    live.* = .{};
    x.pres.ref();
    s.* = .{ .pres = x.pres, .live = live };
    dec.p_sys = @ptrCast(s);
    dec.pf_decode = decode;
    dec.pf_flush = flush;
    dec.fmt_out.i_codec = vlc.VLC_CODEC_RGBA;
    x.pres.clock.register(dec, true);
    return vlc.VLC_SUCCESS;
}

fn close(o: *vlc.vlc_object_t) callconv(.c) void {
    const dec: *vlc.decoder_t = @ptrCast(o);
    const s: *Sys = @ptrCast(@alignCast(dec.p_sys));
    s.pres.clock.register(dec, false);
    s.pres.unref();
    s.live.unref();
    gpa.destroy(s);
}

fn flush(dec_c: [*c]vlc.decoder_t) callconv(.c) void {
    const s: *Sys = @ptrCast(@alignCast(dec_c.*.p_sys));
    s.flushed = true;
}

/// Any block (the demux sends one after each clock reset, and now and then) starts the subpicture if there
/// is none, at the block's time.
fn decode(dec_c: [*c]vlc.decoder_t, block_c: [*c]vlc.block_t) callconv(.c) c_int {
    const dec: *vlc.decoder_t = dec_c;
    const s: *Sys = @ptrCast(@alignCast(dec.p_sys));
    const block: *vlc.block_t = block_c orelse return vlc.VLC_SUCCESS;
    const pts = block.i_pts;
    hddvd_block_release(block);
    if (pts > 0 and (s.flushed or s.live.count.load(.acquire) == 0)) {
        s.flushed = false;
        @call(.auto, vlc.vlc_Log, .{ @as(*vlc.vlc_object_t, @ptrCast(dec)), vlc.VLC_MSG_DBG, "hddvd", @src().file, @as(c_uint, @src().line), @src().fn_name, "overlay: new subpicture at %lld", @as(c_longlong, pts) });
        start(dec, s, pts);
    }
    return vlc.VLC_SUCCESS;
}

const early_start: i64 = 10_000_000;

fn start(dec: *vlc.decoder_t, s: *Sys, pts: i64) void {
    const view = gpa.create(View) catch return;
    view.* = .{ .pres = s.pres, .live = s.live };
    s.pres.ref();
    _ = s.live.refs.fetchAdd(1, .monotonic);
    _ = s.live.count.fetchAdd(1, .acq_rel);
    const sub = hddvd_ov_new(dec, view) orelse {
        destroy(view);
        return;
    };
    // Started a while before the block's time: VLC draws a paused picture's subtitles at the date of the pause,
    // and a subpicture recreated during a pause (after the disc-menu key's flush) would otherwise start just
    // after it and stay hidden until playback resumes. It lasts until replaced, so starting early changes nothing
    // else. (The decoder's preroll check is on the block's time, not this one.)
    sub.*.i_start = @max(1, pts - early_start);
    sub.*.i_stop = 0;
    sub.*.b_ephemer = true;
    sub.*.b_subtitle = true; // follows the video's clock (and VLC shifts it across pauses)
    sub.*.b_absolute = true;
    sub.*.i_original_picture_width = s.pres.aperture_w;
    sub.*.i_original_picture_height = s.pres.aperture_h;
    hddvd_spu_queue(dec, sub);
}

// ---- the subpicture's updater (spu_glue.c), on the video output thread ---------------------------------------

/// What a drawing depends on; the regions are rebuilt when it changes.
const Look = struct {
    planes_gen: u32,
    layout_gen: u32,
    /// Stream timestamp of the sub video frame to show, or null for none (no decoder or no frame).
    pip: ?i64,
    /// Hash of the visible sub-picture periods.
    periods: u64,
};

const View = struct {
    pres: *present.Presentation,
    live: *Live,
    drawn: ?Look = null,
};

/// What should be on screen at display date `ts`.
fn look(view: *View, ts: i64) Look {
    const pres = view.pres;
    var l: Look = .{
        .planes_gen = pres.planes_gen.load(.acquire),
        .layout_gen = pres.layout_gen.load(.acquire),
        .pip = null,
        .periods = 0,
    };
    if (pres.holdPip()) |pip| {
        defer pip.unref();
        pip.lockIt();
        defer pip.unlock();
        if (pip.at(ts)) |i| {
            l.pip = pip.ring[i].date;
        } else if (pip.n > 0) {
            // Nothing due yet: keep what is shown, or show the oldest frame if nothing is.
            l.pip = if (view.drawn) |d| d.pip orelse pip.ring[0].date else pip.ring[0].date;
        }
    }
    l.periods = visiblePeriods(pres, ts, null);
    return l;
}

/// Hashes the sub-picture periods visible at display date `ts`, and lists them in `out` if given (their
/// bitmaps referenced).
fn visiblePeriods(pres: *present.Presentation, ts: i64, out: ?*std.ArrayList(present.SpuPeriod)) u64 {
    pres.lockIt();
    const any = pres.periods.items.len > 0;
    pres.unlock();
    if (!any) return 0;
    const now = pres.streamAt(ts) orelse return 0;
    var h = std.hash.Wyhash.init(0);
    pres.lockIt();
    defer pres.unlock();
    for (pres.periods.items) |q| {
        if (q.start > now or (q.stop != 0 and q.stop <= now)) continue;
        h.update(std.mem.asBytes(&q.id));
        if (out) |list| {
            list.append(gpa, q) catch continue;
            q.bitmap.ref();
        }
    }
    return h.final();
}

fn validate(sys: *anyopaque, fmt_changed: bool, ts: i64) callconv(.c) bool {
    const view: *View = @ptrCast(@alignCast(sys));
    if (fmt_changed) return true;
    const d = view.drawn orelse return true;
    return !std.meta.eql(look(view, ts), d);
}

fn update(sys: *anyopaque, sub: *vlc.subpicture_t, ts: i64) callconv(.c) void {
    const view: *View = @ptrCast(@alignCast(sys));
    const pres = view.pres;
    view.drawn = look(view, ts);
    var tail: *?*vlc.subpicture_region_t = @ptrCast(&sub.p_region);

    const frame = pres.holdGraphics();
    defer if (frame) |f| f.unref();
    const clears: []const planes.ClearRect = if (frame) |f| f.clears.items else &.{};

    subVideo(view, ts, clears, &tail);
    subPictures(pres, ts, clears, &tail);
    if (frame) |f| graphics(f, &tail);
    cursor(pres, &tail);

    // Periods that ended a while ago will not be shown again.
    if (pres.streamAt(ts)) |now| pres.dropPeriods(null, now - 1_000_000);
}

fn append(tail: **?*vlc.subpicture_region_t, r: *vlc.subpicture_region_t, x: i32, y: i32) void {
    r.i_x = x;
    r.i_y = y;
    tail.*.* = r;
    tail.* = @ptrCast(&r.p_next);
}

/// The sub video frame due, at the application's layout.
fn subVideo(view: *View, ts: i64, clears: []const planes.ClearRect, tail: **?*vlc.subpicture_region_t) void {
    const pres = view.pres;
    const pip = pres.holdPip() orelse return;
    defer pip.unref();
    pres.lockIt();
    const alpha = pres.sub_alpha;
    const layout = pres.sub_layout;
    const key = pres.luma_key;
    const aspect = pres.sub_aspect;
    pres.unlock();

    pip.lockIt();
    defer pip.unlock();
    const f = pip.take(ts) orelse return;
    if (alpha == 0) return; // hidden
    const full = vdec.yuvOf(f.pic) orelse return;
    // Its size in square pixels (Vol. 1 §4.3.12, Table 4.3.12-1: 720×480 16:9 is 853×480), which
    // applications lay out. An SD sub video's aspect ratio is in the EVOB attributes: its stream may not carry
    // one (VC-1 then decodes as square pixels).
    const sq = subSquareSize(&f.pic.format, aspect);
    const aw: u32 = pres.aperture_w;
    const ah: u32 = pres.aperture_h;
    const placed = compose.place(layout orelse .{ .rect = .{
        .x = @divTrunc(@as(i32, @intCast(aw)) - @as(i32, @intCast(sq[0])), 2),
        .y = @divTrunc(@as(i32, @intCast(ah)) - @as(i32, @intCast(sq[1])), 2),
        .w = @intCast(sq[0]),
        .h = @intCast(sq[1]),
    } }, sq[0], sq[1], aw, ah) orelse return;
    const src = if (placed.crop) |c| full.crop(c, placed.space[0], placed.space[1]) else full;
    const r = placed.dest;
    if (r.w <= 0 or r.h <= 0) return;
    const region = hddvd_region_new_rgba(@intCast(r.w), @intCast(r.h)) orelse return;
    const plane = &region.*.p_picture.*.p[0];
    const pitch: usize = @intCast(plane.i_pitch);
    const w: usize = @intCast(r.w);
    const h: usize = @intCast(r.h);
    const px = plane.p_pixels[0 .. pitch * h];
    const matrix: compose.Matrix = if (full.height() > 576) .bt709 else .bt601;
    compose.toRgba(px, pitch, w, h, src, alpha, key, matrix);
    planes.punch(px, pitch, 4, 3, .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h }, clears, true);
    append(tail, region, r.x, r.y);
}

fn subSquareSize(f: *const vlc.video_format_t, aspect: ?[2]u32) [2]u32 {
    const h = f.i_visible_height;
    if (aspect) |a| if (h > 0 and h <= 576) return .{ (h * a[0] + a[1] / 2) / a[1], h };
    return vdec.squareSize(f);
}

/// The sub-picture periods visible, in their own colours.
fn subPictures(pres: *present.Presentation, ts: i64, clears: []const planes.ClearRect, tail: **?*vlc.subpicture_region_t) void {
    var list: std.ArrayList(present.SpuPeriod) = .empty;
    defer {
        for (list.items) |q| q.bitmap.unref();
        list.deinit(gpa);
    }
    _ = visiblePeriods(pres, ts, &list);
    for (list.items) |q| {
        const bm = q.bitmap;
        const region = hddvd_region_new_yuva(bm.w, bm.h) orelse continue;
        spudec.paint(region, bm, &q.own, null, false);
        const a = &region.*.p_picture.*.p[3];
        const pitch: usize = @intCast(a.i_pitch);
        planes.punchPlane(a.p_pixels[0 .. pitch * bm.h], pitch, .{ .x = bm.x, .y = bm.y, .w = bm.w, .h = bm.h }, clears, false);
        append(tail, region, bm.x, bm.y);
    }
}

/// The graphics plane's occupied tiles, with straight alpha.
fn graphics(f: *planes.Frame, tail: **?*vlc.subpicture_region_t) void {
    const spans = f.spans(gpa) catch return;
    defer gpa.free(spans);
    for (spans) |r| {
        const region = hddvd_region_new_rgba(@intCast(r.w), @intCast(r.h)) orelse continue;
        copyRgba(region, f.canvas, r);
        append(tail, region, r.x, r.y);
    }
}

fn cursor(pres: *present.Presentation, tail: **?*vlc.subpicture_region_t) void {
    const c = pres.holdCursor() orelse return;
    defer c.image.unref();
    const aperture: raster.Rect = .{ .x = 0, .y = 0, .w = pres.aperture_w, .h = pres.aperture_h };
    const placed = c.cursor.imageRect(c.image);
    const r = placed.intersect(aperture) orelse return;
    const region = hddvd_region_new_rgba(@intCast(r.w), @intCast(r.h)) orelse return;
    copyRgba(region, c.image.canvas, r.offset(-placed.x, -placed.y));
    append(tail, region, r.x, r.y);
}

/// Copies the `r` part of `src` into an RGBA region of its size, unpremultiplied.
fn copyRgba(region: *vlc.subpicture_region_t, src: raster.Canvas, r: raster.Rect) void {
    const plane = &region.p_picture.*.p[0];
    const pitch: usize = @intCast(plane.i_pitch);
    for (0..@intCast(r.h)) |y| {
        const srow = src.row(@as(usize, @intCast(r.y)) + y)[@intCast(r.x)..][0..@intCast(r.w)];
        const drow: [*][4]u8 = @ptrCast(plane.p_pixels + y * pitch);
        for (srow, 0..) |p, x| drow[x] = raster.unpremultiply(p);
    }
}

fn destroy(sys: *anyopaque) callconv(.c) void {
    const view: *View = @ptrCast(@alignCast(sys));
    _ = view.live.count.fetchSub(1, .acq_rel);
    view.live.unref();
    view.pres.unref();
    gpa.destroy(view);
}

comptime {
    const hidden: std.builtin.SymbolVisibility = .hidden;
    @export(&open, .{ .name = "HddvdOverlayOpen", .visibility = hidden });
    @export(&close, .{ .name = "HddvdOverlayClose", .visibility = hidden });
    @export(&validate, .{ .name = "hddvd_ov_validate", .visibility = hidden });
    @export(&update, .{ .name = "hddvd_ov_update", .visibility = hidden });
    @export(&destroy, .{ .name = "hddvd_ov_destroy", .visibility = hidden });
}
