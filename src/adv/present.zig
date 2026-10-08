//! Presentation state of Advanced Content shared by the demux, the HDi engine and our decoders (vdec.zig,
//! adec.zig): the video layout of the main and sub video planes, audio mixing levels and pending effect
//! sounds, plus the clock registry. Reference-counted: decoders can outlive the demux briefly.

const std = @import("std");
const vlc = @import("vlc");
const spudec = @import("../spudec.zig");
const compose = @import("compose.zig");
const mix = @import("mix.zig");

const gpa = std.heap.c_allocator;

/// es_format_t.p_extra of our ESes: magic, *Presentation, then the real codec (u32).
pub const extra_magic = "HDDVDAV1";
pub const extra_len = extra_magic.len + @sizeOf(usize) + 4;

/// Prefix of a sub audio block forwarded into the main audio ES: magic then the stream's codec.
pub const sub_audio_magic = "HDSUBAUD";
pub const sub_prefix_len = 12;

pub const Effect = struct {
    /// Interleaved float samples (owned).
    samples: []f32,
    channels: usize,
    rate: u32,
    /// When it was requested (mdate()); sounds requested while paused go stale.
    at: i64,
};

pub const Presentation = struct {
    refs: std.atomic.Value(u32) = .init(1),
    lock: vlc.vlc_mutex_t = undefined,
    /// Display dates for the demux, through any open decoder.
    clock: *spudec.Shared,
    /// Bumped whenever the sub video layout changes (the overlay redraws).
    layout_gen: std.atomic.Value(u32) = .init(0),
    aperture_w: u16 = 1920,
    aperture_h: u16 = 1080,

    // Under lock:
    /// Main video area (null: the whole aperture) and the colour outside it (Y, Cb, Cr). Not applied yet: the
    /// main video is VLC's video plane (only the sub video and graphics are ours).
    main_rect: ?compose.Rect = null,
    outer: [3]u8 = .{ 16, 128, 128 },
    /// Sub video area (null: its native size, centred) and opacity (0 = hidden, the default, §4.3.13.3.4).
    sub_rect: ?compose.Rect = null,
    sub_alpha: u8 = 0,
    /// Sub video luma key range (from the EVOB attributes), or null.
    luma_key: ?[2]u8 = null,
    /// Gains: main audio per output channel, sub audio and effect audio overall.
    main_gains: [mix.max_channels]f32 = @splat(1),
    sub_gain: f32 = 1,
    effect_gain: f32 = 1,
    /// An effect sound to start, taken by the mixer.
    effect: ?Effect = null,
    /// Bumped by the mixer when an effect sound finishes (for the engine's callbacks).
    effects_done: u32 = 0,

    pub fn create(clock: *spudec.Shared) ?*Presentation {
        const p = gpa.create(Presentation) catch return null;
        clock.ref();
        p.* = .{ .clock = clock };
        vlc.vlc_mutex_init(&p.lock);
        return p;
    }

    pub fn ref(p: *Presentation) void {
        _ = p.refs.fetchAdd(1, .monotonic);
    }

    pub fn unref(p: *Presentation) void {
        if (p.refs.fetchSub(1, .acq_rel) != 1) return;
        if (p.effect) |e| gpa.free(e.samples);
        p.clock.unref();
        vlc.vlc_mutex_destroy(&p.lock);
        gpa.destroy(p);
    }

    /// Sets the sub video layout (null rect: native size, centred; alpha 0: hidden).
    pub fn setSubLayout(p: *Presentation, rect: ?compose.Rect, alpha: u8) void {
        p.lockIt();
        p.sub_rect = rect;
        p.sub_alpha = alpha;
        p.unlock();
        _ = p.layout_gen.fetchAdd(1, .release);
    }

    pub fn lockIt(p: *Presentation) void {
        vlc.vlc_mutex_lock(&p.lock);
    }

    pub fn unlock(p: *Presentation) void {
        vlc.vlc_mutex_unlock(&p.lock);
    }

    /// p_extra for an ES whose real codec is `codec`.
    pub fn extra(p: *Presentation, codec: u32) [extra_len]u8 {
        var e: [extra_len]u8 = undefined;
        @memcpy(e[0..extra_magic.len], extra_magic);
        std.mem.writeInt(usize, e[extra_magic.len..][0..@sizeOf(usize)], @intFromPtr(p), .native);
        std.mem.writeInt(u32, e[extra_magic.len + @sizeOf(usize) ..][0..4], codec, .native);
        return e;
    }

    /// Decodes an ES's p_extra: the Presentation (not referenced) and the real codec.
    pub fn fromExtra(fmt: *const vlc.es_format_t) ?struct { pres: *Presentation, codec: u32 } {
        if (fmt.i_extra != extra_len or fmt.p_extra == null) return null;
        const e: *const [extra_len]u8 = @ptrCast(fmt.p_extra);
        if (!std.mem.eql(u8, e[0..extra_magic.len], extra_magic)) return null;
        return .{
            .pres = @ptrFromInt(std.mem.readInt(usize, e[extra_magic.len..][0..@sizeOf(usize)], .native)),
            .codec = std.mem.readInt(u32, e[extra_magic.len + @sizeOf(usize) ..][0..4], .native),
        };
    }

    /// Replaces the pending effect sound (takes `e.samples`).
    pub fn playEffect(p: *Presentation, e: Effect) void {
        p.lockIt();
        defer p.unlock();
        if (p.effect) |old| gpa.free(old.samples);
        p.effect = e;
    }
};

/// Splits a forwarded sub-stream block's prefix: the codec, or null if `data` is not prefixed with `magic`.
pub fn subPrefix(data: []const u8, comptime magic: []const u8) ?u32 {
    if (data.len < sub_prefix_len or !std.mem.eql(u8, data[0..8], magic)) return null;
    return std.mem.readInt(u32, data[8..12], .native);
}
