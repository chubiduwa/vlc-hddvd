//! Our main video decoder for Advanced Content (private fourcc `hdvc`): VLC's own decoder (nested, through
//! codec_glue.c), with the frame times corrected. EVOBs time only the first frame of each EVOBU, and VLC
//! interpolates the others with a fixed frame duration, which breaks 3:2 pulldown into a hitch every half
//! second (retime.zig). The pictures are copied through unchanged; the sub video and the graphics are VLC
//! overlays above them (pipdec.zig, …).

const std = @import("std");
const vlc = @import("vlc");
const present = @import("present.zig");
const compose = @import("compose.zig");
const retime = @import("retime.zig");

const gpa = std.heap.c_allocator;

/// VLC_FOURCC('h','d','v','c').
pub const fourcc: u32 = std.mem.readInt(u32, "hdvc", .little);

pub const Nested = opaque {};
pub extern fn hddvd_nested_new(parent: *vlc.vlc_object_t, fmt: *const vlc.es_format_t, cat: @FieldType(vlc.es_format_t, "i_cat"), codec: u32, ctx: *anyopaque, kind: c_int) ?*Nested;
pub extern fn hddvd_nested_decode(n: *Nested, b: ?*vlc.block_t) void;
pub extern fn hddvd_nested_flush(n: *Nested) void;
pub extern fn hddvd_nested_delete(n: ?*Nested) void;
extern fn hddvd_dec_update_video(dec: *vlc.decoder_t) c_int;
extern fn hddvd_dec_new_picture(dec: *vlc.decoder_t) ?*vlc.picture_t;
extern fn hddvd_dec_queue_video(dec: *vlc.decoder_t, pic: *vlc.picture_t) void;
extern fn hddvd_block_release(b: *vlc.block_t) void;

/// Nested decoder kinds: 0 here, 1 the sub video (pipdec.zig), 2 and 3 audio (adec.zig dispatches them all).
pub const kind_main = 0;

fn log(obj: *vlc.vlc_object_t, prio: c_int, src: std.builtin.SourceLocation, comptime fmt: [*:0]const u8, args: anytype) void {
    @call(.auto, vlc.vlc_Log, .{ obj, prio, "hddvd", src.file, @as(c_uint, src.line), src.fn_name, fmt } ++ args);
}

const Sys = struct {
    dec: *vlc.decoder_t,
    pres: *present.Presentation,
    main: ?*Nested = null,
    format: ?vlc.video_format_t = null,
    timer: retime.Retimer = retime.Retimer.init(0, 0),
    /// Timestamp of the last block, to reject pictures with nonsensical dates.
    last_pts: i64 = 0,
};

fn sysOf(dec: *vlc.decoder_t) *Sys {
    return @ptrCast(@alignCast(dec.p_sys));
}

fn open(o: *vlc.vlc_object_t) callconv(.c) c_int {
    const dec: *vlc.decoder_t = @ptrCast(o);
    if (dec.fmt_in.i_cat != vlc.VIDEO_ES or dec.fmt_in.i_codec != fourcc) return vlc.VLC_EGENERIC;
    const x = present.Presentation.fromExtra(&dec.fmt_in) orelse return vlc.VLC_EGENERIC;
    const s = gpa.create(Sys) catch return vlc.VLC_ENOMEM;
    s.* = .{ .dec = dec, .pres = x.pres };
    s.main = hddvd_nested_new(o, &dec.fmt_in, dec.fmt_in.i_cat, x.codec, s, kind_main) orelse {
        gpa.destroy(s);
        return vlc.VLC_EGENERIC;
    };
    x.pres.ref();
    dec.p_sys = @ptrCast(s);
    dec.pf_decode = decode;
    dec.pf_flush = flush;
    dec.fmt_out.i_codec = vlc.VLC_CODEC_I420;
    x.pres.clock.register(dec, true);
    return vlc.VLC_SUCCESS;
}

fn close(o: *vlc.vlc_object_t) callconv(.c) void {
    const dec: *vlc.decoder_t = @ptrCast(o);
    const s = sysOf(dec);
    s.pres.clock.register(dec, false);
    hddvd_nested_delete(s.main);
    s.pres.unref();
    gpa.destroy(s);
}

fn decode(dec_c: [*c]vlc.decoder_t, block_c: [*c]vlc.block_t) callconv(.c) c_int {
    const dec: *vlc.decoder_t = dec_c;
    const s = sysOf(dec);
    const block: ?*vlc.block_t = block_c;
    if (block) |b| {
        if (b.i_pts > 0) s.last_pts = b.i_pts;
    }
    if (s.main) |m| hddvd_nested_decode(m, block) else if (block) |b| hddvd_block_release(b);
    return vlc.VLC_SUCCESS;
}

fn flush(dec_c: [*c]vlc.decoder_t) callconv(.c) void {
    const s = sysOf(dec_c);
    if (s.main) |m| hddvd_nested_flush(m);
    s.timer.reset();
}

fn supported(chroma: u32) bool {
    return chroma == vlc.VLC_CODEC_I420 or chroma == vlc.VLC_CODEC_J420 or chroma == vlc.VLC_CODEC_YV12;
}

/// A decoded picture's visible area as 4:2:0 planes (U then V).
pub fn yuvOf(pic: *vlc.picture_t) ?compose.Yuv {
    if (!supported(pic.format.i_chroma) or pic.i_planes < 3) return null;
    const f = &pic.format;
    const w: usize = f.i_visible_width;
    const h: usize = f.i_visible_height;
    const swap = pic.format.i_chroma == vlc.VLC_CODEC_YV12;
    const pu = &pic.p[if (swap) 2 else 1];
    const pv = &pic.p[if (swap) 1 else 2];
    const yp = &pic.p[0];
    const xo: usize = f.i_x_offset;
    const yo: usize = f.i_y_offset;
    return .{
        .y = .{ .px = yp.p_pixels + yo * @as(usize, @intCast(yp.i_pitch)) + xo, .pitch = @intCast(yp.i_pitch), .w = w, .h = h },
        .u = .{ .px = pu.p_pixels + yo / 2 * @as(usize, @intCast(pu.i_pitch)) + xo / 2, .pitch = @intCast(pu.i_pitch), .w = (w + 1) / 2, .h = (h + 1) / 2 },
        .v = .{ .px = pv.p_pixels + yo / 2 * @as(usize, @intCast(pv.i_pitch)) + xo / 2, .pitch = @intCast(pv.i_pitch), .w = (w + 1) / 2, .h = (h + 1) / 2 },
    };
}

// ---- nested decoder output (via adec.zig's dispatcher) ------------------------------------------------------

pub fn onFormat(ctx: *anyopaque, inner: *vlc.decoder_t) c_int {
    const s: *Sys = @ptrCast(@alignCast(ctx));
    const f = &inner.fmt_out.unnamed_0.video;
    if (!supported(inner.fmt_out.i_codec)) {
        log(@ptrCast(s.dec), vlc.VLC_MSG_ERR, @src(), "unsupported decoded chroma %4.4s", .{@as([*]const u8, @ptrCast(&inner.fmt_out.i_codec))});
        return vlc.VLC_EGENERIC;
    }
    if (s.format) |old| if (old.i_visible_width == f.i_visible_width and old.i_visible_height == f.i_visible_height and
        old.i_frame_rate == f.i_frame_rate and old.i_frame_rate_base == f.i_frame_rate_base) return vlc.VLC_SUCCESS;
    log(@ptrCast(s.dec), vlc.VLC_MSG_DBG, @src(), "main video: %ux%u, %u/%u fps", .{ f.i_visible_width, f.i_visible_height, f.i_frame_rate, f.i_frame_rate_base });
    s.format = f.*;
    s.timer = retime.Retimer.init(f.i_frame_rate, f.i_frame_rate_base);
    const out = &s.dec.fmt_out.unnamed_0.video;
    out.* = f.*;
    out.i_chroma = vlc.VLC_CODEC_I420;
    out.p_palette = null;
    s.dec.fmt_out.i_codec = vlc.VLC_CODEC_I420;
    return hddvd_dec_update_video(s.dec);
}

pub fn onPicture(ctx: *anyopaque, pic: *vlc.picture_t) void {
    const s: *Sys = @ptrCast(@alignCast(ctx));
    defer vlc.picture_Release(pic);
    if (s.format == null) return;
    // A picture dated far from the stream (a decoder guessing a timestamp) cannot be placed: drop it.
    if (pic.date <= 0 or (s.last_pts > 0 and @abs(pic.date - s.last_pts) > 10_000_000)) return;
    const src = yuvOf(pic) orelse return;
    const out = hddvd_dec_new_picture(s.dec) orelse return;
    if (yuvOf(out)) |dst| compose.copy(dst, src);
    out.date = s.timer.frame(pic.date, pic.i_nb_fields);
    out.b_force = pic.b_force;
    out.b_progressive = pic.b_progressive;
    out.b_top_field_first = pic.b_top_field_first;
    out.i_nb_fields = pic.i_nb_fields;
    hddvd_dec_queue_video(s.dec, out);
}

comptime {
    const hidden: std.builtin.SymbolVisibility = .hidden;
    @export(&open, .{ .name = "HddvdVdecOpen", .visibility = hidden });
    @export(&close, .{ .name = "HddvdVdecClose", .visibility = hidden });
}
