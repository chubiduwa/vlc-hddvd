//! HD DVD sub-picture decoder: a VLC "spu decoder" submodule for the private fourcc `hdsp`, with button
//! highlights (HD DVD Vol. 2 §5.1.4, §5.5).
//!
//! - The demux (hddvd.zig) reassembles each sub-picture unit (SPU) and sends it as one block: the PGC's 16-entry
//!   palette (16 x u32 BE 0x00YYCrCb) followed by the unit, in either header form, 2-bit or 8-bit.
//! - Each display period of the unit becomes a VLC subpicture whose region is drawn on demand by an updater: VLC
//!   asks pf_validate before every rendered frame, so when the demux changes the highlight (Shared.gen), the
//!   region is redrawn with the button rectangle in the HLI colours and the rest in the SPU's own colours. VLC 3's
//!   built-in mechanism (the input "highlight" variables) can only crop the SPU to the button, which hides every
//!   other button.

const std = @import("std");
const vlc = @import("vlc");
const hli = @import("hli.zig");
const spu = @import("spu.zig");

const gpa = std.heap.c_allocator;

extern fn hddvd_spu_new(dec: *vlc.decoder_t, sys: *anyopaque) ?*vlc.subpicture_t;
extern fn hddvd_spu_queue(dec: *vlc.decoder_t, spu: *vlc.subpicture_t) void;
extern fn hddvd_region_new_yuva(w: c_uint, h: c_uint) ?*vlc.subpicture_region_t;
extern fn hddvd_block_release(b: *vlc.block_t) void;

/// VLC_FOURCC('h','d','s','p').
pub const fourcc: u32 = std.mem.readInt(u32, "hdsp", .little);
/// Bytes in front of the unit in each block: the PGC palette.
pub const palette_size = 64;
/// es_format_t.p_extra of an `hdsp` ES: this magic followed by the *Shared pointer.
pub const extra_magic = "HDDVDSPU";

pub const unitSize = spu.unitSize;

/// The current highlight, written by the demux thread and read when VLC renders the subpictures.
pub const Shared = struct {
    refs: std.atomic.Value(u32) = .init(1),
    /// Bumped on every change; subpictures redraw when it differs from what they drew.
    gen: std.atomic.Value(u32) = .init(0),
    lock: vlc.vlc_mutex_t = undefined,
    // Under lock:
    active: bool = false,
    /// Bit n: decoding stream 0x20 + n carries buttons (HLI SP_USE); only those are highlighted.
    streams: u32 = 0,
    hl: hli.Highlight = undefined,
    /// Open decoders, through which the demux converts stream timestamps to display dates.
    decoders: [4]?*vlc.decoder_t = @splat(null),

    pub fn create() ?*Shared {
        const s = gpa.create(Shared) catch return null;
        s.* = .{};
        vlc.vlc_mutex_init(&s.lock);
        return s;
    }

    pub fn ref(s: *Shared) void {
        _ = s.refs.fetchAdd(1, .monotonic);
    }

    pub fn unref(s: *Shared) void {
        if (s.refs.fetchSub(1, .acq_rel) != 1) return;
        vlc.vlc_mutex_destroy(&s.lock);
        gpa.destroy(s);
    }

    /// Shows highlight `hl` on the button streams `streams`, or no highlight.
    pub fn set(s: *Shared, streams: u32, hl: ?*const hli.Highlight) void {
        vlc.vlc_mutex_lock(&s.lock);
        s.active = hl != null;
        s.streams = streams;
        if (hl) |h| s.hl = h.*;
        vlc.vlc_mutex_unlock(&s.lock);
        _ = s.gen.fetchAdd(1, .release);
    }

    /// When stream timestamp `ts` (as on the ES's blocks) is or was on screen: its display date (mdate() time),
    /// null while the clock cannot tell (starting, paused), or error.NoDecoder.
    pub fn displayDate(s: *Shared, ts: i64) error{NoDecoder}!?i64 {
        vlc.vlc_mutex_lock(&s.lock);
        defer vlc.vlc_mutex_unlock(&s.lock);
        for (s.decoders) |d| {
            const dec = d orelse continue;
            const f = dec.pf_get_display_date orelse continue;
            const date = f(dec, ts);
            return if (date > 0) date else null;
        }
        return error.NoDecoder;
    }

    /// Adds or removes a decoder whose clock the demux may read (sub-picture, video and audio decoders).
    pub fn register(s: *Shared, dec: *vlc.decoder_t, on: bool) void {
        vlc.vlc_mutex_lock(&s.lock);
        defer vlc.vlc_mutex_unlock(&s.lock);
        for (&s.decoders) |*d| {
            if (on and d.* == null) {
                d.* = dec;
                return;
            }
            if (!on and d.* == dec) d.* = null;
        }
    }

    /// The p_extra bytes that let the decoder find this object.
    pub fn extra(s: *Shared) [extra_magic.len + @sizeOf(usize)]u8 {
        var e: [extra_magic.len + @sizeOf(usize)]u8 = undefined;
        @memcpy(e[0..extra_magic.len], extra_magic);
        std.mem.writeInt(usize, e[extra_magic.len..], @intFromPtr(s), .native);
        return e;
    }
};

// ---- VLC decoder ------------------------------------------------------------------------------------------

const DecSys = struct {
    shared: *Shared,
    stream: u5,
    width: c_int,
    height: c_int,
};

/// One displayed subpicture (its updater's p_sys).
const Pic = struct {
    shared: *Shared,
    bitmap: *spu.Bitmap,
    stream: u5,
    depth8: bool,
    own: spu.Lut,
    /// Shared.gen this was last drawn for.
    gen: u32 = 0,
};

fn log(obj: *vlc.vlc_object_t, prio: c_int, src: std.builtin.SourceLocation, comptime fmt: [*:0]const u8, args: anytype) void {
    @call(.auto, vlc.vlc_Log, .{ obj, prio, "hddvd", src.file, @as(c_uint, src.line), src.fn_name, fmt } ++ args);
}

fn open(o: *vlc.vlc_object_t) callconv(.c) c_int {
    const dec: *vlc.decoder_t = @ptrCast(o);
    const fmt = &dec.fmt_in;
    if (fmt.i_cat != vlc.SPU_ES or fmt.i_codec != fourcc) return vlc.VLC_EGENERIC;
    const n = extra_magic.len + @sizeOf(usize);
    if (fmt.i_extra != n or fmt.p_extra == null) return vlc.VLC_EGENERIC;
    const e: *const [n]u8 = @ptrCast(fmt.p_extra);
    if (!std.mem.eql(u8, e[0..extra_magic.len], extra_magic)) return vlc.VLC_EGENERIC;
    const shared: *Shared = @ptrFromInt(std.mem.readInt(usize, e[extra_magic.len..], .native));

    const ds = gpa.create(DecSys) catch return vlc.VLC_ENOMEM;
    shared.ref();
    const spu_fmt = fmt.unnamed_0.subs.spu;
    ds.* = .{
        .shared = shared,
        .stream = @intCast(fmt.i_id & 0x1f),
        .width = if (spu_fmt.i_original_frame_width > 0) @intCast(spu_fmt.i_original_frame_width) else 1920,
        .height = if (spu_fmt.i_original_frame_height > 0) @intCast(spu_fmt.i_original_frame_height) else 1080,
    };
    dec.p_sys = @ptrCast(ds);
    dec.pf_decode = decode;
    dec.fmt_out.i_codec = fourcc;
    shared.register(dec, true);
    return vlc.VLC_SUCCESS;
}

fn close(o: *vlc.vlc_object_t) callconv(.c) void {
    const dec: *vlc.decoder_t = @ptrCast(o);
    const ds: *DecSys = @ptrCast(@alignCast(dec.p_sys));
    ds.shared.register(dec, false);
    ds.shared.unref();
    gpa.destroy(ds);
}

fn decode(dec_c: [*c]vlc.decoder_t, block_c: [*c]vlc.block_t) callconv(.c) c_int {
    const dec: *vlc.decoder_t = dec_c;
    const block: *vlc.block_t = block_c orelse return vlc.VLC_SUCCESS; // drain: nothing buffered
    defer hddvd_block_release(block);
    if (block.i_flags & vlc.BLOCK_FLAG_CORRUPTED != 0 or block.i_pts <= 0) return vlc.VLC_SUCCESS;
    const data = block.p_buffer[0..block.i_buffer];
    if (data.len <= palette_size) return vlc.VLC_SUCCESS;
    var palette: [16]u32 = undefined;
    for (&palette, 0..) |*p, i| p.* = std.mem.readInt(u32, data[i * 4 ..][0..4], .big);
    const unit = data[palette_size..];
    decodeUnit(dec, unit, block.i_pts, &palette) catch |err| {
        log(@ptrCast(dec), vlc.VLC_MSG_WARN, @src(), "dropping a sub-picture unit (%s)", .{@errorName(err).ptr});
    };
    return vlc.VLC_SUCCESS;
}

fn decodeUnit(dec: *vlc.decoder_t, unit: []const u8, pts: i64, palette: *const [16]u32) spu.Error!void {
    const ds: *DecSys = @ptrCast(@alignCast(dec.p_sys));
    var buf: [spu.max_events]spu.Event = undefined;
    const events = try spu.parse(unit, &buf);

    var bitmap: ?*spu.Bitmap = null;
    var bitmap_key: spu.State = .{};
    defer if (bitmap) |bm| bm.unref();

    for (events, 0..) |ev, i| {
        if (!ev.st.on) continue;
        const st = ev.st;
        const same = bitmap != null and std.meta.eql(st.area, bitmap_key.area) and
            std.meta.eql(st.pxa, bitmap_key.pxa) and st.depth8 == bitmap_key.depth8;
        if (!same) {
            if (bitmap) |bm| bm.unref();
            bitmap = null;
            bitmap = try spu.Bitmap.decode(unit, st);
            bitmap_key = st;
        }
        const bm = bitmap.?;

        const pic = try gpa.create(Pic);
        pic.* = .{ .shared = ds.shared, .bitmap = bm, .stream = ds.stream, .depth8 = st.depth8, .own = spu.ownColors(st, palette) };
        const sub = hddvd_spu_new(dec, pic) orelse {
            gpa.destroy(pic);
            continue; // no video output
        };
        ds.shared.ref();
        bm.ref();
        sub.*.i_start = pts + ev.delay_us;
        // Each display period lasts until the next DCSQ (which starts the next period or stops the display),
        // or, for the last one, until the next unit (ephemer).
        sub.*.i_stop = if (i + 1 < events.len) pts + events[i + 1].delay_us else 0;
        sub.*.b_ephemer = true;
        sub.*.b_subtitle = !st.forced;
        sub.*.b_absolute = true;
        sub.*.i_original_picture_width = ds.width;
        sub.*.i_original_picture_height = ds.height;
        hddvd_spu_queue(dec, sub);
    }
}

// Updater callbacks (via spu_glue.c), called by the video output while rendering.

fn validate(sys: *anyopaque, fmt_changed: bool) callconv(.c) bool {
    const pic: *Pic = @ptrCast(@alignCast(sys));
    return fmt_changed or pic.shared.gen.load(.acquire) != pic.gen;
}

fn update(sys: *anyopaque, sub: *vlc.subpicture_t) callconv(.c) void {
    const pic: *Pic = @ptrCast(@alignCast(sys));
    const sh = pic.shared;
    pic.gen = sh.gen.load(.acquire);

    var hl: ?hli.Highlight = null;
    vlc.vlc_mutex_lock(&sh.lock);
    if (sh.active and (sh.streams >> pic.stream) & 1 != 0) hl = sh.hl;
    vlc.vlc_mutex_unlock(&sh.lock);

    const bm = pic.bitmap;
    const region = hddvd_region_new_yuva(bm.w, bm.h) orelse return;
    const planes = &region.*.p_picture.*.p;
    const yp = planes[0].p_pixels;
    const up = planes[1].p_pixels;
    const vp = planes[2].p_pixels;
    const ap = planes[3].p_pixels;
    const pitch: [4]usize = .{ @intCast(planes[0].i_pitch), @intCast(planes[1].i_pitch), @intCast(planes[2].i_pitch), @intCast(planes[3].i_pitch) };

    for (0..bm.h) |y| {
        const ay = bm.y + y;
        const row_hl = if (hl) |*h| ay >= h.sy and ay <= h.ey else false;
        for (0..bm.w) |x| {
            const v = bm.px[y * bm.w + x];
            const ax = bm.x + x;
            const c = if (row_hl and ax >= hl.?.sx and ax <= hl.?.ex)
                (if (pic.depth8) hl.?.lut8[v] else hl.?.lut2[v & 3])
            else
                pic.own[v];
            yp[y * pitch[0] + x] = c[0];
            up[y * pitch[1] + x] = c[1];
            vp[y * pitch[2] + x] = c[2];
            ap[y * pitch[3] + x] = c[3];
        }
    }
    region.*.i_x = bm.x;
    region.*.i_y = bm.y;
    sub.p_region = region;
}

fn destroy(sys: *anyopaque) callconv(.c) void {
    const pic: *Pic = @ptrCast(@alignCast(sys));
    pic.bitmap.unref();
    pic.shared.unref();
    gpa.destroy(pic);
}

comptime {
    const hidden: std.builtin.SymbolVisibility = .hidden;
    @export(&open, .{ .name = "HddvdSpuOpen", .visibility = hidden });
    @export(&close, .{ .name = "HddvdSpuClose", .visibility = hidden });
    @export(&validate, .{ .name = "hddvd_spu_validate", .visibility = hidden });
    @export(&update, .{ .name = "hddvd_spu_update", .visibility = hidden });
    @export(&destroy, .{ .name = "hddvd_spu_destroy", .visibility = hidden });
}
