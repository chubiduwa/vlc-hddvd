//! Audio mixing for Advanced Content (HD DVD Vol. 1 §4.3.13.4): main audio, sub audio and effect audio summed
//! into one stream with per-channel gains. Samples are 32-bit float, interleaved in VLC's channel order.
//! No VLC dependency.

const std = @import("std");

/// VLC's AOUT_CHAN_* bits in VLC's interleaving order (pi_vlc_chan_order_wg4).
pub const chan = struct {
    pub const left: u32 = 0x2;
    pub const right: u32 = 0x4;
    pub const middle_left: u32 = 0x100;
    pub const middle_right: u32 = 0x200;
    pub const rear_left: u32 = 0x20;
    pub const rear_right: u32 = 0x40;
    pub const rear_center: u32 = 0x10;
    pub const center: u32 = 0x1;
    pub const lfe: u32 = 0x1000;
};

pub const order = [_]u32{ chan.left, chan.right, chan.middle_left, chan.middle_right, chan.rear_left, chan.rear_right, chan.rear_center, chan.center, chan.lfe };

pub const max_channels = order.len;

/// The channels of a mask, in interleaving order.
pub const Layout = struct {
    mask: u32,
    n: usize,
    ch: [max_channels]u32,

    pub fn of(mask: u32) Layout {
        var l: Layout = .{ .mask = mask, .n = 0, .ch = undefined };
        for (order) |c| if (mask & c != 0) {
            l.ch[l.n] = c;
            l.n += 1;
        };
        return l;
    }

    pub fn index(l: Layout, c: u32) ?usize {
        for (l.ch[0..l.n], 0..) |x, i| if (x == c) return i;
        return null;
    }
};

pub const SampleFormat = enum { u8, s16, s32, f32, f64 };

/// Converts interleaved samples to float.
pub fn toFloat(fmt: SampleFormat, src: []const u8, out: []f32) void {
    switch (fmt) {
        .u8 => for (out, 0..) |*o, i| {
            o.* = (@as(f32, @floatFromInt(src[i])) - 128) / 128;
        },
        .s16 => for (out, 0..) |*o, i| {
            o.* = @as(f32, @floatFromInt(std.mem.readInt(i16, src[i * 2 ..][0..2], .little))) / 32768;
        },
        .s32 => for (out, 0..) |*o, i| {
            o.* = @floatCast(@as(f64, @floatFromInt(std.mem.readInt(i32, src[i * 4 ..][0..4], .little))) / 2147483648.0);
        },
        .f32 => for (out, 0..) |*o, i| {
            o.* = @bitCast(std.mem.readInt(u32, src[i * 4 ..][0..4], .little));
        },
        .f64 => for (out, 0..) |*o, i| {
            o.* = @floatCast(@as(f64, @bitCast(std.mem.readInt(u64, src[i * 8 ..][0..8], .little))));
        },
    }
}

/// Gains from source channels to destination channels: out[d] += in[s] * g[d][s].
pub const Matrix = struct {
    g: [max_channels][max_channels]f32 = @splat(@splat(0)),

    /// The usual up/down mix: matching channels pass through; a missing centre, rear or middle channel folds
    /// into its front pair at -3 dB; mono feeds left and right; a missing LFE is dropped.
    pub fn default(src: Layout, dst: Layout) Matrix {
        var m: Matrix = .{};
        const k: f32 = std.math.sqrt1_2;
        for (src.ch[0..src.n], 0..) |c, si| {
            if (dst.index(c)) |di| {
                m.g[di][si] = 1;
                continue;
            }
            const targets: []const u32 = switch (c) {
                chan.center => &.{ chan.left, chan.right },
                chan.rear_left, chan.middle_left => &.{ chan.rear_left, chan.middle_left, chan.left },
                chan.rear_right, chan.middle_right => &.{ chan.rear_right, chan.middle_right, chan.right },
                chan.rear_center => &.{ chan.rear_left, chan.rear_right },
                chan.left, chan.right => &.{chan.center},
                else => &.{},
            };
            if (c == chan.center and src.n == 1) { // mono
                if (dst.index(chan.left)) |l| m.g[l][si] = k;
                if (dst.index(chan.right)) |r| m.g[r][si] = k;
                continue;
            }
            if (c == chan.center or c == chan.rear_center) {
                for (targets) |t| if (dst.index(t)) |di| {
                    m.g[di][si] = k;
                };
                continue;
            }
            for (targets) |t| if (dst.index(t)) |di| {
                m.g[di][si] = if (t == chan.left or t == chan.right) k else 1;
                break;
            };
        }
        return m;
    }

    pub fn scale(m: *Matrix, gain: f32) void {
        for (&m.g) |*row| for (row) |*v| {
            v.* *= gain;
        };
    }
};

/// out (dst layout) += in (src layout) through m, for `frames` frames.
pub fn mixFrames(out: []f32, dst: Layout, in: []const f32, src: Layout, frames: usize, m: *const Matrix) void {
    for (0..frames) |f| {
        const o = out[f * dst.n ..][0..dst.n];
        const s = in[f * src.n ..][0..src.n];
        for (o, 0..) |*ov, di| {
            var acc: f32 = 0;
            for (s, 0..) |sv, si| acc += sv * m.g[di][si];
            ov.* += acc;
        }
    }
}

/// Multiplies each channel by its gain.
pub fn applyGains(buf: []f32, l: Layout, gains: []const f32) void {
    var i: usize = 0;
    while (i + l.n <= buf.len) : (i += l.n) {
        for (buf[i..][0..l.n], gains[0..l.n]) |*v, g| v.* *= g;
    }
}

/// Linear-interpolation resampler, streaming (keeps the last input frame).
pub const Resampler = struct {
    in_rate: u32,
    out_rate: u32,
    channels: usize,
    /// Position of the next output frame, in input frames, relative to `prev`.
    pos: f64 = 0,
    prev: [max_channels]f32 = @splat(0),
    primed: bool = false,

    /// Resamples `in` (frames × channels) and appends to `out`.
    pub fn process(r: *Resampler, gpa: std.mem.Allocator, in: []const f32, out: *std.ArrayList(f32)) !void {
        const n = r.channels;
        const frames = in.len / n;
        if (frames == 0) return;
        if (r.in_rate == r.out_rate) return out.appendSlice(gpa, in[0 .. frames * n]);
        if (!r.primed) { // start exactly on the first input frame
            @memcpy(r.prev[0..n], in[0..n]);
            r.pos = 1;
            r.primed = true;
        }
        const step = @as(f64, @floatFromInt(r.in_rate)) / @as(f64, @floatFromInt(r.out_rate));
        // Input frame k (k = 0 is `prev`, then in[0..]).
        while (r.pos < @as(f64, @floatFromInt(frames))) {
            const i: usize = @intFromFloat(@floor(r.pos));
            const t: f32 = @floatCast(r.pos - @floor(r.pos));
            for (0..n) |c| {
                const a = if (i == 0) r.prev[c] else in[(i - 1) * n + c];
                const b = in[i * n + c];
                try out.append(gpa, a + (b - a) * t);
            }
            r.pos += step;
        }
        r.pos -= @floatFromInt(frames);
        @memcpy(r.prev[0..n], in[(frames - 1) * n ..][0..n]);
    }
};

/// Decoded audio waiting to be mixed, in the destination layout and rate, from timestamp `start` (µs).
pub const Fifo = struct {
    rate: u32,
    channels: usize,
    buf: std.ArrayList(f32) = .empty,
    /// Timestamp of buf[0]; null while empty.
    start: ?i64 = null,

    pub fn deinit(f: *Fifo, gpa: std.mem.Allocator) void {
        f.buf.deinit(gpa);
    }

    pub fn clear(f: *Fifo) void {
        f.buf.clearRetainingCapacity();
        f.start = null;
    }

    fn frames(f: *const Fifo) usize {
        return f.buf.items.len / f.channels;
    }

    /// Appends frames starting at timestamp `ts`. A gap or overlap with what is queued restarts the queue
    /// there (a discontinuity), unless it is within a millisecond.
    pub fn push(f: *Fifo, gpa: std.mem.Allocator, ts: i64, samples: []const f32) !void {
        if (f.start) |s| {
            const end = s + @divFloor(@as(i64, @intCast(f.frames())) * 1_000_000, f.rate);
            if (@abs(ts - end) > 1000) f.clear();
        }
        if (f.start == null) f.start = ts;
        try f.buf.appendSlice(gpa, samples);
    }

    /// Adds the queued frames that fall within [ts, ts + frames) into `out` with matrix `m`, then drops
    /// everything before the end of that span.
    pub fn mixInto(f: *Fifo, out: []f32, dst: Layout, ts: i64, frames_n: usize, m: *const Matrix, src: Layout) void {
        const s = f.start orelse return;
        // Offset of `ts` in the queue, in frames (may be negative: the queue starts later).
        const off: i64 = @divFloor((ts - s) * @as(i64, f.rate), 1_000_000);
        const have: i64 = @intCast(f.frames());
        var o: usize = 0;
        while (o < frames_n) : (o += 1) {
            const q = off + @as(i64, @intCast(o));
            if (q < 0) continue;
            if (q >= have) break;
            mixFrames(out[o * dst.n ..][0..dst.n], dst, f.buf.items[@as(usize, @intCast(q)) * src.n ..][0..src.n], src, 1, m);
        }
        const drop: i64 = std.math.clamp(off + @as(i64, @intCast(frames_n)), 0, have);
        if (drop > 0) {
            const d: usize = @intCast(drop);
            const rest = f.buf.items.len - d * f.channels;
            std.mem.copyForwards(f32, f.buf.items[0..rest], f.buf.items[d * f.channels ..]);
            f.buf.shrinkRetainingCapacity(rest);
            f.start = s + @divFloor(@as(i64, @intCast(d)) * 1_000_000, f.rate);
            if (rest == 0) f.start = null;
        }
    }
};

/// Effect sounds being played (one at a time per the spec, Annex Z EffectAudio; a new one replaces the old).
pub const Effects = struct {
    /// Samples in the output layout and rate, and how far they have been played.
    samples: []f32 = &.{},
    pos: usize = 0,
    channels: usize = 2,

    pub fn deinit(e: *Effects, gpa: std.mem.Allocator) void {
        gpa.free(e.samples);
        e.* = .{};
    }

    pub fn start(e: *Effects, gpa: std.mem.Allocator, samples: []f32, channels: usize) void {
        gpa.free(e.samples);
        e.* = .{ .samples = samples, .channels = channels };
    }

    pub fn playing(e: *const Effects) bool {
        return e.pos < e.samples.len;
    }

    /// Adds the next frames of the current sound to `out` (same layout) with `gain`.
    pub fn mixInto(e: *Effects, out: []f32, gain: f32) void {
        const n = @min(out.len, e.samples.len - e.pos);
        for (out[0..n], e.samples[e.pos..][0..n]) |*o, s| o.* += s * gain;
        e.pos += n;
    }
};

// ---- tests --------------------------------------------------------------------------------------------------

const testing = std.testing;

test "layouts follow VLC's channel order" {
    const l = Layout.of(chan.left | chan.right | chan.center | chan.lfe | chan.rear_left | chan.rear_right);
    try testing.expectEqual(6, l.n);
    try testing.expectEqual(chan.left, l.ch[0]);
    try testing.expectEqual(chan.rear_left, l.ch[2]);
    try testing.expectEqual(chan.center, l.ch[4]);
    try testing.expectEqual(chan.lfe, l.ch[5]);
    try testing.expectEqual(@as(?usize, 4), l.index(chan.center));
}

test "sample conversion" {
    var out: [2]f32 = undefined;
    toFloat(.s16, &.{ 0x00, 0x40, 0x00, 0xc0 }, &out);
    try testing.expectEqual(@as(f32, 0.5), out[0]);
    try testing.expectEqual(@as(f32, -0.5), out[1]);
    toFloat(.u8, &.{ 128, 192 }, &out);
    try testing.expectEqual(@as(f32, 0), out[0]);
    try testing.expectEqual(@as(f32, 0.5), out[1]);
}

test "up and down mix matrices" {
    const stereo = Layout.of(chan.left | chan.right);
    const s51 = Layout.of(chan.left | chan.right | chan.center | chan.lfe | chan.rear_left | chan.rear_right);
    // Stereo into 5.1: left to left, right to right.
    const up = Matrix.default(stereo, s51);
    try testing.expectEqual(@as(f32, 1), up.g[0][0]);
    try testing.expectEqual(@as(f32, 1), up.g[1][1]);
    try testing.expectEqual(@as(f32, 0), up.g[4][0]);
    // 5.1 into stereo: centre and surrounds fold at -3 dB, LFE dropped.
    const down = Matrix.default(s51, stereo);
    try testing.expectApproxEqAbs(@as(f32, 0.7071), down.g[0][4], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.7071), down.g[0][2], 0.001);
    try testing.expectEqual(@as(f32, 0), down.g[0][3]);
    try testing.expectEqual(@as(f32, 0), down.g[0][5]);
    // Mono into stereo.
    const mono = Matrix.default(Layout.of(chan.center), stereo);
    try testing.expectApproxEqAbs(@as(f32, 0.7071), mono.g[1][0], 0.001);

    var out = [_]f32{ 0.1, 0.1, 0, 0 };
    const in = [_]f32{ 0.5, 0.25, 1, 0 };
    mixFrames(&out, stereo, &in, stereo, 2, &Matrix.default(stereo, stereo));
    try testing.expectEqualSlices(f32, &.{ 0.6, 0.35, 1, 0 }, &out);
}

test "resampling" {
    var r: Resampler = .{ .in_rate = 24000, .out_rate = 48000, .channels = 1 };
    var out: std.ArrayList(f32) = .empty;
    defer out.deinit(testing.allocator);
    try r.process(testing.allocator, &.{ 0, 1, 2, 3 }, &out);
    try r.process(testing.allocator, &.{ 4, 5 }, &out);
    // Twice as many frames (the last input frame is the next call's start), ramping across the call boundary.
    try testing.expectEqual(10, out.items.len);
    for (out.items, 0..) |v, i| try testing.expectApproxEqAbs(@as(f32, @floatFromInt(i)) * 0.5, v, 0.001);
}

test "fifo alignment by timestamp" {
    const gpa = testing.allocator;
    const mono = Layout.of(chan.center);
    var f: Fifo = .{ .rate = 1000, .channels = 1 };
    defer f.deinit(gpa);
    try f.push(gpa, 10_000, &.{ 1, 2, 3, 4, 5 }); // 10 ms … 15 ms
    var out: [4]f32 = @splat(0);
    const m = Matrix.default(mono, mono);
    // Output block at 8 ms: the queue starts 2 frames in.
    f.mixInto(&out, mono, 8_000, 4, &m, mono);
    try testing.expectEqualSlices(f32, &.{ 0, 0, 1, 2 }, &out);
    out = @splat(0);
    f.mixInto(&out, mono, 12_000, 4, &m, mono);
    try testing.expectEqualSlices(f32, &.{ 3, 4, 5, 0 }, &out);
    try testing.expectEqual(null, f.start);
    // A discontinuity restarts the queue.
    try f.push(gpa, 100_000, &.{ 7, 8 });
    try f.push(gpa, 500_000, &.{9});
    try testing.expectEqual(@as(?i64, 500_000), f.start);
}

test "effect sounds" {
    const gpa = testing.allocator;
    var e: Effects = .{};
    defer e.deinit(gpa);
    const s = try gpa.dupe(f32, &.{ 1, 1, 1 });
    e.start(gpa, s, 1);
    var out: [2]f32 = @splat(0.5);
    e.mixInto(&out, 0.5);
    try testing.expectEqualSlices(f32, &.{ 1, 1 }, &out);
    try testing.expect(e.playing());
    e.mixInto(&out, 1);
    try testing.expect(!e.playing());
}
