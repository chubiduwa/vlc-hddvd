//! Presentation state of Advanced Content shared by the demux, the HDi engine and our decoders (vdec.zig,
//! adec.zig, pipdec.zig, spudec.zig, overlay.zig): the video layout of the main and sub video planes, audio
//! mixing levels and pending effect sounds, the planes the overlay draws (sub video, sub-picture, graphics,
//! cursor), the Title Timeline's clock, plus the clock registry. Reference-counted: decoders can outlive the
//! demux briefly.

const std = @import("std");
const vlc = @import("vlc");
const spudec = @import("../spudec.zig");
const spu = @import("../spu.zig");
const compose = @import("compose.zig");
const mix = @import("mix.zig");
const planes = @import("planes.zig");
const pipdec = @import("pipdec.zig");
const xpl = @import("xpl.zig");

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

/// One display period of a sub-picture unit on the sub-picture plane (from spudec.zig).
pub const SpuPeriod = struct {
    /// Unique, to tell what the overlay drew.
    id: u32 = 0,
    /// Decoding stream (0x20 + n).
    stream: u5,
    bitmap: *spu.Bitmap,
    own: spu.Lut,
    /// Stream timestamps; `stop` 0: until the stream's next unit.
    start: i64,
    stop: i64,
};

/// Most sub-picture periods kept (older ones are dropped first).
const max_periods = 32;

pub const Presentation = struct {
    refs: std.atomic.Value(u32) = .init(1),
    lock: vlc.vlc_mutex_t = undefined,
    /// Display dates for the demux, through any open decoder.
    clock: *spudec.Shared,
    /// Bumped whenever the sub video layout changes (the overlay redraws).
    layout_gen: std.atomic.Value(u32) = .init(0),
    /// Bumped whenever the graphics frame, the cursor, the sub-picture periods or the sub video decoder change.
    planes_gen: std.atomic.Value(u32) = .init(0),
    aperture_w: u16 = 1920,
    aperture_h: u16 = 1080,
    time_base: xpl.TimeBase = .fps60,

    // Under lock:
    /// The main video's layout (by default its height fitted to the aperture's and centred), and the colour
    /// outside it (Y, Cb, Cr). Our main video decoder (vdec.zig) composites it into the aperture.
    main_layout: compose.Layout = .fit,
    outer: [3]u8 = .{ 16, 128, 128 },
    /// The sub video's layout (null: its native size, centred) and opacity (0 = hidden, the default,
    /// §4.3.13.3.4).
    sub_layout: ?compose.Layout = null,
    sub_alpha: u8 = 0,
    /// Sub video display aspect ratio (from the EVOB attributes), or null.
    sub_aspect: ?[2]u32 = null,
    /// Sub video luma key range (from the EVOB attributes), or null.
    luma_key: ?[2]u8 = null,
    /// The applications' audio levels (Annex W, Table W-4; null: not set, the usual mix): main volumes, and the
    /// sub and effect audio mix-downs.
    main_volume: ?[mix.hd_channels]u8 = null,
    sub_mix: ?[2][mix.hd_channels]u8 = null,
    effect_mix: ?[2][mix.hd_channels]u8 = null,
    /// Overall gains on top: sub audio (--hddvd-sub-mix) and effect audio.
    sub_gain: f32 = 1,
    effect_gain: f32 = 1,
    /// An effect sound to start, taken by the mixer, or the one playing to stop.
    effect: ?Effect = null,
    stop_effect: bool = false,
    /// VLC is paused: its audio output does not play, so effect sounds go to their own output (fxout.zig).
    paused: bool = false,

    /// The sub video decoder's frames (pipdec.zig), while it is open.
    pip: ?*pipdec.Pip = null,
    /// The graphics plane: the last frame the engine finished.
    graphics: ?*planes.Frame = null,
    cursor: planes.Cursor,
    /// The default cursor image (the player's own).
    default_cursor: ?*planes.Image = null,
    /// Sub-picture periods (Advanced Content only; Standard Content draws its own subpictures).
    periods: std.ArrayList(SpuPeriod) = .empty,
    next_period: u32 = 1,

    /// The Title Timeline: title time `ref_time` (frames) is at stream timestamp `ref_ts`.
    ref_time: u64 = 0,
    ref_ts: i64 = 0,
    duration: u64 = 0,
    /// The last title time worked out, kept while the clock cannot tell (paused, buffering).
    last_time: ?u64 = null,
    /// Display date minus stream timestamp, as last seen, and the timestamp it was seen at.
    offset: ?i64 = null,
    offset_ts: i64 = 0,

    pub fn create(clock: *spudec.Shared) ?*Presentation {
        const p = gpa.create(Presentation) catch return null;
        clock.ref();
        p.* = .{ .clock = clock, .cursor = .init(1920, 1080) };
        p.default_cursor = planes.defaultCursor(gpa) catch null;
        vlc.vlc_mutex_init(&p.lock);
        return p;
    }

    pub fn ref(p: *Presentation) void {
        _ = p.refs.fetchAdd(1, .monotonic);
    }

    pub fn unref(p: *Presentation) void {
        if (p.refs.fetchSub(1, .acq_rel) != 1) return;
        if (p.effect) |e| gpa.free(e.samples);
        if (p.graphics) |f| f.unref();
        if (p.cursor.image) |im| im.unref();
        if (p.default_cursor) |im| im.unref();
        for (p.periods.items) |q| q.bitmap.unref();
        p.periods.deinit(gpa);
        p.clock.unref();
        vlc.vlc_mutex_destroy(&p.lock);
        gpa.destroy(p);
    }

    pub fn setAperture(p: *Presentation, w: u16, h: u16) void {
        p.aperture_w = w;
        p.aperture_h = h;
        p.cursor = .init(w, h);
    }

    /// Sets the sub video's layout and opacity (null: native size, centred; alpha 0: hidden).
    pub fn setSubLayout(p: *Presentation, layout: ?compose.Layout, alpha: u8) void {
        p.lockIt();
        p.sub_layout = layout;
        p.sub_alpha = alpha;
        p.unlock();
        _ = p.layout_gen.fetchAdd(1, .release);
    }

    /// The main video's layout (an application's changeLayout).
    pub fn setMainPlace(p: *Presentation, layout: compose.Layout) void {
        p.lockIt();
        defer p.unlock();
        p.main_layout = layout;
    }

    /// The sub video's layout (an application's changeLayout), keeping its opacity.
    pub fn setSubPlace(p: *Presentation, layout: ?compose.Layout) void {
        p.lockIt();
        p.sub_layout = layout;
        p.unlock();
        _ = p.layout_gen.fetchAdd(1, .release);
    }

    pub fn setSubAlpha(p: *Presentation, alpha: u8) void {
        p.lockIt();
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

    fn changed(p: *Presentation) void {
        _ = p.planes_gen.fetchAdd(1, .release);
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
        p.stop_effect = false;
    }

    /// Stops the effect sound playing (or about to).
    pub fn stopEffect(p: *Presentation) void {
        p.lockIt();
        defer p.unlock();
        if (p.effect) |old| gpa.free(old.samples);
        p.effect = null;
        p.stop_effect = true;
    }

    pub fn setPaused(p: *Presentation, paused: bool) void {
        p.lockIt();
        defer p.unlock();
        p.paused = paused;
    }

    /// The applications' audio levels (Table W-4).
    pub fn setMixing(p: *Presentation, main: [mix.hd_channels]u8, sub: [2][mix.hd_channels]u8, effect: [2][mix.hd_channels]u8) void {
        p.lockIt();
        defer p.unlock();
        p.main_volume = main;
        p.sub_mix = sub;
        p.effect_mix = effect;
    }

    // ---- the planes ---------------------------------------------------------------------------------------

    /// The sub video decoder opens (pip) or closes (null).
    pub fn setPip(p: *Presentation, pip: ?*pipdec.Pip) void {
        p.lockIt();
        const old = p.pip;
        p.pip = pip;
        if (pip) |x| x.ref();
        p.unlock();
        if (old) |x| x.unref();
        p.changed();
    }

    /// The sub video frames, referenced, or null.
    pub fn holdPip(p: *Presentation) ?*pipdec.Pip {
        p.lockIt();
        defer p.unlock();
        const x = p.pip orelse return null;
        x.ref();
        return x;
    }

    /// Shows graphics frame `f` (referenced here; null: an empty graphics plane).
    pub fn publishGraphics(p: *Presentation, f: ?*planes.Frame) void {
        if (f) |x| x.ref();
        p.lockIt();
        const old = p.graphics;
        p.graphics = f;
        p.unlock();
        if (old) |x| x.unref();
        p.changed();
    }

    /// The graphics frame shown, referenced, or null.
    pub fn holdGraphics(p: *Presentation) ?*planes.Frame {
        p.lockIt();
        defer p.unlock();
        const f = p.graphics orelse return null;
        f.ref();
        return f;
    }

    /// Sets the cursor (its image is referenced here).
    pub fn setCursor(p: *Presentation, c: planes.Cursor) void {
        if (c.image) |im| im.ref();
        p.lockIt();
        const old = p.cursor.image;
        p.cursor = c;
        p.unlock();
        if (old) |im| im.unref();
        p.changed();
    }

    /// The cursor to draw: its position and image (referenced), or null if hidden.
    pub fn holdCursor(p: *Presentation) ?struct { cursor: planes.Cursor, image: *planes.Image } {
        p.lockIt();
        defer p.unlock();
        const c = p.cursor;
        if (!c.visible) return null;
        const im = c.image orelse p.default_cursor orelse return null;
        im.ref();
        return .{ .cursor = c, .image = im };
    }

    /// New display periods of decoding stream `stream` (their bitmaps are referenced here). The stream's open
    /// period ends where the first new one starts.
    pub fn addPeriods(p: *Presentation, stream: u5, new: []const SpuPeriod) void {
        if (new.len == 0) return;
        p.lockIt();
        for (p.periods.items) |*q| {
            if (q.stream == stream and q.stop == 0) q.stop = @max(q.start, new[0].start);
        }
        for (new) |n| {
            if (p.periods.items.len == max_periods) {
                p.periods.items[0].bitmap.unref();
                _ = p.periods.orderedRemove(0);
            }
            var q = n;
            q.id = p.next_period;
            p.next_period +%= 1;
            q.bitmap.ref();
            p.periods.append(gpa, q) catch q.bitmap.unref();
        }
        p.unlock();
        p.changed();
    }

    /// Drops the periods of `stream` (its decoder flushed or closed), or those that ended before `before`.
    pub fn dropPeriods(p: *Presentation, stream: ?u5, before: ?i64) void {
        p.lockIt();
        var i: usize = 0;
        var n: usize = 0;
        while (i < p.periods.items.len) {
            const q = p.periods.items[i];
            const gone = if (stream) |s| q.stream == s else (q.stop != 0 and q.stop < before.?);
            if (gone) {
                q.bitmap.unref();
                _ = p.periods.orderedRemove(i);
                n += 1;
            } else i += 1;
        }
        p.unlock();
        if (n > 0) p.changed();
    }

    // ---- the Title Timeline's clock -----------------------------------------------------------------------

    /// The demux positions the Title Timeline: title time `ref_time` will be shown at stream timestamp `ref_ts`.
    pub fn setTimeline(p: *Presentation, ref_time: u64, ref_ts: i64, duration: u64) void {
        p.lockIt();
        defer p.unlock();
        p.ref_time = ref_time;
        p.ref_ts = ref_ts;
        p.duration = duration;
        p.last_time = null;
        p.offset = null;
    }

    /// The title time on screen at `now` (mdate()), or the last one known while the clock cannot tell
    /// (paused, buffering), or null if there was none yet.
    pub fn titleNow(p: *Presentation, now: i64) ?u64 {
        p.lockIt();
        const ref_time = p.ref_time;
        const ref_ts = p.ref_ts;
        const duration = p.duration;
        p.unlock();
        const date = (p.clock.displayDate(ref_ts) catch null) orelse {
            p.lockIt();
            defer p.unlock();
            return p.last_time;
        };
        // The reference may still be ahead of the screen (negative elapsed time) after a seamless join.
        const tb = p.time_base;
        const t = @min(tb.frames(tb.us(ref_time) + (now - date)), duration);
        p.lockIt();
        defer p.unlock();
        if (p.ref_ts == ref_ts) p.last_time = t;
        return t;
    }

    /// The stream timestamp shown at display date `date` (as a subpicture updater gets it), or null before
    /// the clock could ever tell.
    pub fn streamAt(p: *Presentation, date: i64) ?i64 {
        p.lockIt();
        const at = if (p.offset != null) p.offset_ts else p.ref_ts;
        p.unlock();
        const d = (p.clock.displayDate(at) catch null) orelse {
            p.lockIt();
            defer p.unlock();
            return if (p.offset) |o| date - o else null;
        };
        p.lockIt();
        defer p.unlock();
        p.offset = d - at;
        // Measure next time near this point, so a playback rate other than 1 drifts little.
        p.offset_ts = date - p.offset.?;
        return date - p.offset.?;
    }
};

/// Splits a forwarded sub-stream block's prefix: the codec, or null if `data` is not prefixed with `magic`.
pub fn subPrefix(data: []const u8, comptime magic: []const u8) ?u32 {
    if (data.len < sub_prefix_len or !std.mem.eql(u8, data[0..8], magic)) return null;
    return std.mem.readInt(u32, data[8..12], .native);
}
