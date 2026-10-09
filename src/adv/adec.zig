//! Our mixing audio decoder for Advanced Content (private fourcc `hdam`): VLC 3 gives each audio stream its own
//! output and cannot mix, so the main audio, the sub audio (commentary) and effect sounds (menus) are decoded
//! and mixed here (mix.zig) into the one stream VLC plays, whose volume and mute then apply to all of them
//! (HD DVD Vol. 1 §4.3.13.4).
//!
//! - Main audio blocks come on this ES; sub audio packets are forwarded into it by the demux, prefixed with
//!   present.sub_audio_magic and their codec. Both are decoded by nested VLC decoders (codec_glue.c).
//! - Effect sounds are handed over by the engine through the Presentation.
//! - VLC decodes about a second ahead of presentation, so decoded main audio is held and only mixed (with the
//!   sub audio for the same time and any effect sound just started) shortly before it is played: a menu click
//!   is heard within that margin, not a second later. While paused nothing is released, so effect sounds
//!   started then are dropped once stale.

const std = @import("std");
const vlc = @import("vlc");
const present = @import("present.zig");
const mix = @import("mix.zig");
const vdec = @import("vdec.zig");
const pipdec = @import("pipdec.zig");

const gpa = std.heap.c_allocator;

/// VLC_FOURCC('h','d','a','m').
pub const fourcc: u32 = std.mem.readInt(u32, "hdam", .little);

const Nested = opaque {};
extern fn hddvd_nested_new(parent: *vlc.vlc_object_t, fmt: *const vlc.es_format_t, cat: @FieldType(vlc.es_format_t, "i_cat"), codec: u32, ctx: *anyopaque, kind: c_int) ?*Nested;
extern fn hddvd_nested_decode(n: *Nested, b: ?*vlc.block_t) void;
extern fn hddvd_nested_flush(n: *Nested) void;
extern fn hddvd_nested_delete(n: ?*Nested) void;
extern fn hddvd_dec_update_audio(dec: *vlc.decoder_t) c_int;
extern fn hddvd_dec_queue_audio(dec: *vlc.decoder_t, b: *vlc.block_t) void;
extern fn hddvd_audio_fmt_fl32(fmt: *vlc.audio_format_t, rate: c_uint, channels: c_uint) void;
extern fn hddvd_block_release(b: *vlc.block_t) void;
extern fn hddvd_now_us() i64;

const kind_main = 2;
const kind_sub = 3;

/// How long before its play date mixed audio is handed to VLC (µs).
const release_margin: i64 = 250_000;
/// Effect sounds older than this when output resumes are dropped (µs).
const effect_stale: i64 = 200_000;

fn log(obj: *vlc.vlc_object_t, prio: c_int, src: std.builtin.SourceLocation, comptime fmt: [*:0]const u8, args: anytype) void {
    @call(.auto, vlc.vlc_Log, .{ obj, prio, "hddvd", src.file, @as(c_uint, src.line), src.fn_name, fmt } ++ args);
}

const Held = struct {
    pts: i64,
    length: i64,
    frames: usize,
    samples: []f32,
};

const Input = struct {
    layout: mix.Layout = mix.Layout.of(0),
    rate: u32 = 0,
    format: ?mix.SampleFormat = null,
};

const Sys = struct {
    dec: *vlc.decoder_t,
    pres: *present.Presentation,
    main: ?*Nested = null,
    sub: ?*Nested = null,
    sub_codec: u32 = 0,
    main_in: Input = .{},
    sub_in: Input = .{},
    /// Output: FL32 at the main audio's rate and channels.
    out: mix.Layout = mix.Layout.of(0),
    out_rate: u32 = 0,
    held: std.ArrayList(Held) = .empty,
    sub_fifo: mix.Fifo = .{ .rate = 48000, .channels = 2 },
    sub_resampler: ?mix.Resampler = null,
    effects: mix.Effects = .{},
    /// Timestamp of the last block received.
    last_pts: i64 = 0,
    /// Something was output since the last flush. Before that VLC is buffering: it waits for every decoder's
    /// first output and reports no display dates, so audio goes out at once.
    started: bool = false,
    scratch: std.ArrayList(f32) = .empty,

    fn dropHeld(s: *Sys) void {
        for (s.held.items) |h| gpa.free(h.samples);
        s.held.clearRetainingCapacity();
    }
};

fn sysOf(dec: *vlc.decoder_t) *Sys {
    return @ptrCast(@alignCast(dec.p_sys));
}

fn open(o: *vlc.vlc_object_t) callconv(.c) c_int {
    const dec: *vlc.decoder_t = @ptrCast(o);
    if (dec.fmt_in.i_cat != vlc.AUDIO_ES or dec.fmt_in.i_codec != fourcc) return vlc.VLC_EGENERIC;
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
    dec.fmt_out.i_codec = vlc.VLC_CODEC_FL32;
    x.pres.clock.register(dec, true);
    return vlc.VLC_SUCCESS;
}

fn close(o: *vlc.vlc_object_t) callconv(.c) void {
    const dec: *vlc.decoder_t = @ptrCast(o);
    const s = sysOf(dec);
    s.pres.clock.register(dec, false);
    hddvd_nested_delete(s.main);
    hddvd_nested_delete(s.sub);
    s.dropHeld();
    s.held.deinit(gpa);
    s.sub_fifo.deinit(gpa);
    s.effects.deinit(gpa);
    s.scratch.deinit(gpa);
    s.pres.unref();
    gpa.destroy(s);
}

fn decode(dec_c: [*c]vlc.decoder_t, block_c: [*c]vlc.block_t) callconv(.c) c_int {
    const dec: *vlc.decoder_t = dec_c;
    const s = sysOf(dec);
    const block: *vlc.block_t = block_c orelse {
        // Drain: everything decoded is output now.
        if (s.main) |m| hddvd_nested_decode(m, null);
        release(s, true);
        return vlc.VLC_SUCCESS;
    };
    if (block.i_pts > 0) s.last_pts = block.i_pts;
    const data = block.p_buffer[0..block.i_buffer];
    if (present.subPrefix(data, present.sub_audio_magic)) |codec| {
        block.p_buffer += present.sub_prefix_len;
        block.i_buffer -= present.sub_prefix_len;
        if (s.sub == null or codec != s.sub_codec) {
            hddvd_nested_delete(s.sub);
            s.sub = hddvd_nested_new(@ptrCast(dec), &dec.fmt_in, vlc.AUDIO_ES, codec, s, kind_sub);
            s.sub_codec = codec;
            s.sub_in = .{};
        }
        if (s.sub) |n| hddvd_nested_decode(n, block) else hddvd_block_release(block);
    } else if (s.main) |m| hddvd_nested_decode(m, block) else hddvd_block_release(block);
    release(s, false);
    return vlc.VLC_SUCCESS;
}

fn flush(dec_c: [*c]vlc.decoder_t) callconv(.c) void {
    const s = sysOf(dec_c);
    if (s.main) |m| hddvd_nested_flush(m);
    if (s.sub) |n| hddvd_nested_flush(n);
    s.dropHeld();
    s.sub_fifo.clear();
    s.started = false;
    if (s.sub_resampler) |*r| r.* = .{ .in_rate = r.in_rate, .out_rate = r.out_rate, .channels = r.channels };
}

fn sampleFormat(codec: u32) ?mix.SampleFormat {
    return switch (codec) {
        vlc.VLC_CODEC_FL32 => .f32,
        vlc.VLC_CODEC_S16N => .s16,
        vlc.VLC_CODEC_S32N => .s32,
        vlc.VLC_CODEC_FL64 => .f64,
        vlc.VLC_CODEC_U8 => .u8,
        else => null,
    };
}

fn onFormat(s: *Sys, kind: c_int, inner: *vlc.decoder_t) c_int {
    const a = &inner.fmt_out.unnamed_0.unnamed_0.audio;
    const fmt = sampleFormat(inner.fmt_out.i_codec) orelse {
        log(@ptrCast(s.dec), vlc.VLC_MSG_ERR, @src(), "unsupported decoded audio %4.4s", .{@as([*]const u8, @ptrCast(&inner.fmt_out.i_codec))});
        return vlc.VLC_EGENERIC;
    };
    const in: Input = .{ .layout = mix.Layout.of(a.i_physical_channels), .rate = a.i_rate, .format = fmt };
    const prev = if (kind == kind_main) s.main_in else s.sub_in;
    if (prev.rate != in.rate or prev.layout.mask != in.layout.mask or prev.format != in.format) log(@ptrCast(s.dec), vlc.VLC_MSG_DBG, @src(), "%s audio: %4.4s %u Hz, %u channels", .{
        @as([*:0]const u8, if (kind == kind_main) "main" else "sub"), @as([*]const u8, @ptrCast(&inner.fmt_out.i_codec)), a.i_rate, @as(c_uint, @intCast(in.layout.n)),
    });
    if (kind == kind_sub) {
        // Decoders report their format with every block: only a change restarts the queue.
        const same = prev.rate == in.rate and prev.layout.mask == in.layout.mask and prev.format == in.format;
        s.sub_in = in;
        if (s.out_rate != 0 and (!same or s.sub_resampler == null)) setupSub(s);
        return vlc.VLC_SUCCESS;
    }
    s.main_in = in;
    if (s.out_rate != in.rate or s.out.mask != in.layout.mask) {
        release(s, true); // what was decoded in the old format goes out first
        s.out = in.layout;
        s.out_rate = in.rate;
        const of = &s.dec.fmt_out.unnamed_0.unnamed_0.audio;
        hddvd_audio_fmt_fl32(of, in.rate, in.layout.mask);
        s.dec.fmt_out.i_codec = vlc.VLC_CODEC_FL32;
        if (hddvd_dec_update_audio(s.dec) != 0) return vlc.VLC_EGENERIC;
        if (s.sub_in.rate != 0) setupSub(s);
    }
    return vlc.VLC_SUCCESS;
}

fn setupSub(s: *Sys) void {
    s.sub_fifo.deinit(gpa);
    s.sub_fifo = .{ .rate = s.out_rate, .channels = s.sub_in.layout.n };
    s.sub_resampler = .{ .in_rate = s.sub_in.rate, .out_rate = s.out_rate, .channels = s.sub_in.layout.n };
}

fn onAudio(s: *Sys, kind: c_int, b: *vlc.block_t) void {
    defer hddvd_block_release(b);
    const in = if (kind == kind_main) s.main_in else s.sub_in;
    const fmt = in.format orelse return;
    const n = in.layout.n;
    if (n == 0) return;
    const frames: usize = b.i_nb_samples;
    if (b.i_pts <= 0) return; // no timestamp: cannot be placed
    if (s.last_pts > 0 and @abs(b.i_pts - s.last_pts) > 10_000_000) return; // far from the stream
    const samples = gpa.alloc(f32, frames * n) catch return;
    mix.toFloat(fmt, b.p_buffer[0..b.i_buffer], samples);
    if (kind == kind_main) {
        s.held.append(gpa, .{ .pts = b.i_pts, .length = b.i_length, .frames = frames, .samples = samples }) catch gpa.free(samples);
        return;
    }
    defer gpa.free(samples);
    const r = &(s.sub_resampler orelse return);
    s.scratch.clearRetainingCapacity();
    r.process(gpa, samples, &s.scratch) catch return;
    s.sub_fifo.push(gpa, b.i_pts, s.scratch.items) catch {};
}

/// Mixes and outputs the held main audio that is due (all of it with `all`).
fn release(s: *Sys, all: bool) void {
    const now = hddvd_now_us();
    var done: usize = 0;
    defer {
        for (s.held.items[0..done]) |h| gpa.free(h.samples);
        const rest = s.held.items.len - done;
        std.mem.copyForwards(Held, s.held.items[0..rest], s.held.items[done..]);
        s.held.shrinkRetainingCapacity(rest);
    }
    for (s.held.items) |*h| {
        if (!all) {
            const f = s.dec.pf_get_display_date orelse break;
            const date = f(s.dec, h.pts);
            // No date: buffering (output at once, see `started`) or paused (hold).
            if (date <= 0 and s.started) break;
            if (date > 0 and date - now > release_margin) break;
        }
        output(s, h, now);
        s.started = true;
        done += 1;
    }
}

fn output(s: *Sys, h: *Held, now: i64) void {
    if (s.out.n == 0) return;
    const pres = s.pres;
    var gains: [mix.max_channels]f32 = undefined;
    pres.lockIt();
    gains = pres.main_gains;
    const sub_gain = pres.sub_gain;
    const effect_gain = pres.effect_gain;
    const new_effect = pres.effect;
    pres.effect = null;
    pres.unlock();

    if (new_effect) |e| startEffect(s, e, now);
    mix.applyGains(h.samples, s.out, &gains);
    if (sub_gain > 0 and s.sub_in.layout.n > 0) {
        var m = mix.Matrix.default(s.sub_in.layout, s.out);
        m.scale(sub_gain);
        s.sub_fifo.mixInto(h.samples, s.out, h.pts, h.frames, &m, s.sub_in.layout);
    } else s.sub_fifo.mixInto(&.{}, s.out, h.pts, 0, &mix.Matrix{}, s.sub_in.layout); // keep the queue aligned
    if (s.effects.playing()) s.effects.mixInto(h.samples, effect_gain);

    const out = vlc.decoder_NewAudioBuffer(s.dec, @intCast(h.frames)) orelse return;
    @memcpy(out.*.p_buffer[0 .. h.samples.len * 4], std.mem.sliceAsBytes(h.samples));
    out.*.i_pts = h.pts;
    out.*.i_length = h.length;
    hddvd_dec_queue_audio(s.dec, out);
}

/// Converts an effect sound to the output layout and rate and starts it (replacing any playing one).
fn startEffect(s: *Sys, e: present.Effect, now: i64) void {
    defer gpa.free(e.samples);
    // Requested while paused (nothing was being output): stale by now.
    if (now - e.at > effect_stale) return;
    const src = mix.Layout.of(if (e.channels == 1) mix.chan.center else mix.chan.left | mix.chan.right);
    var resampled: std.ArrayList(f32) = .empty;
    defer resampled.deinit(gpa);
    var r: mix.Resampler = .{ .in_rate = e.rate, .out_rate = s.out_rate, .channels = src.n };
    r.process(gpa, e.samples, &resampled) catch return;
    const frames = resampled.items.len / src.n;
    const out = gpa.alloc(f32, frames * s.out.n) catch return;
    @memset(out, 0);
    const m = mix.Matrix.default(src, s.out);
    mix.mixFrames(out, s.out, resampled.items, src, frames, &m);
    s.effects.start(gpa, out, s.out.n);
}

// ---- nested decoder callbacks (codec_glue.c), for vdec.zig, pipdec.zig and this module ----------------------

fn onNestedFormat(ctx: *anyopaque, kind: c_int, inner: *vlc.decoder_t) callconv(.c) c_int {
    return switch (kind) {
        vdec.kind_main => vdec.onFormat(ctx, inner),
        pipdec.kind => pipdec.onFormat(ctx, inner),
        else => onFormat(@ptrCast(@alignCast(ctx)), kind, inner),
    };
}

fn onNestedPicture(ctx: *anyopaque, kind: c_int, pic: *vlc.picture_t) callconv(.c) void {
    switch (kind) {
        vdec.kind_main => vdec.onPicture(ctx, pic),
        pipdec.kind => pipdec.onPicture(ctx, pic),
        else => vlc.picture_Release(pic),
    }
}

fn onNestedAudio(ctx: *anyopaque, kind: c_int, b: *vlc.block_t) callconv(.c) void {
    if (kind < kind_main) return hddvd_block_release(b);
    onAudio(@ptrCast(@alignCast(ctx)), kind, b);
}

comptime {
    const hidden: std.builtin.SymbolVisibility = .hidden;
    @export(&open, .{ .name = "HddvdAdecOpen", .visibility = hidden });
    @export(&close, .{ .name = "HddvdAdecClose", .visibility = hidden });
    @export(&onNestedFormat, .{ .name = "hddvd_nested_on_format", .visibility = hidden });
    @export(&onNestedPicture, .{ .name = "hddvd_nested_on_picture", .visibility = hidden });
    @export(&onNestedAudio, .{ .name = "hddvd_nested_on_audio", .visibility = hidden });
}
