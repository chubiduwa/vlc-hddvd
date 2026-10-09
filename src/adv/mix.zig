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

/// HD DVD's output channels (Annex W, Table W-4): L, R, C, Ls, Rs, Lb, Rb, LFE.
pub const hd_channels = 8;

/// The HD DVD output channel a VLC channel of `dst` plays: surround is VLC's middle pair in a 7.1 layout and its
/// rear pair otherwise; VLC's rear centre plays both backs.
fn hdOf(dst: Layout, c: u32) []const usize {
    const seven = dst.mask & (chan.middle_left | chan.middle_right) != 0;
    return switch (c) {
        chan.left => &.{0},
        chan.right => &.{1},
        chan.center => &.{2},
        chan.middle_left => &.{3},
        chan.middle_right => &.{4},
        chan.rear_left => if (seven) &.{5} else &.{3},
        chan.rear_right => if (seven) &.{6} else &.{4},
        chan.rear_center => &.{ 5, 6 },
        chan.lfe => &.{7},
        else => &.{},
    };
}

/// Per-channel gains for `dst` (in its order) from HD DVD volumes (0–255 each).
pub fn hdGains(dst: Layout, vol: [hd_channels]u8) [max_channels]f32 {
    var g: [max_channels]f32 = @splat(1);
    for (dst.ch[0..dst.n], 0..) |c, i| {
        const hd = hdOf(dst, c);
        if (hd.len == 0) continue;
        var sum: f32 = 0;
        for (hd) |k| sum += @floatFromInt(vol[k]);
        g[i] = sum / @as(f32, @floatFromInt(hd.len)) / 255;
    }
    return g;
}

/// A mix-down of a mono or stereo source into `dst` from HD DVD gains (`rows[0]` from the left input, `rows[1]`
/// from the right, 0–255 per output channel). A mono source feeds both rows at -3 dB; other source channels fold
/// into left and right first.
pub fn hdMatrix(src: Layout, dst: Layout, rows: [2][hd_channels]u8) Matrix {
    var m: Matrix = .{};
    // Source channels into the two HD DVD inputs.
    var into: [max_channels][2]f32 = @splat(.{ 0, 0 });
    if (src.n == 1) {
        into[0] = .{ std.math.sqrt1_2, std.math.sqrt1_2 };
    } else {
        const stereo = Layout.of(chan.left | chan.right);
        const fold = Matrix.default(src, stereo);
        for (0..src.n) |si| into[si] = .{ fold.g[0][si], fold.g[1][si] };
    }
    for (dst.ch[0..dst.n], 0..) |c, di| {
        const hd = hdOf(dst, c);
        for (0..src.n) |si| {
            var acc: f32 = 0;
            for (hd) |k| acc += (into[si][0] * @as(f32, @floatFromInt(rows[0][k])) + into[si][1] * @as(f32, @floatFromInt(rows[1][k]))) / 255;
            m.g[di][si] = if (hd.len > 0) acc / @as(f32, @floatFromInt(hd.len)) else 0;
        }
    }
    return m;
}

pub const Wav = struct {
    /// Interleaved samples, the whole sound `repeat` times (owned).
    samples: []f32,
    channels: usize,
    rate: u32,
};

/// Decodes a linear PCM WAV file (8, 16, 24 or 32-bit integer, or 32-bit float; mono or stereo), repeated.
pub fn decodeWav(gpa: std.mem.Allocator, data: []const u8, repeat: u32) !Wav {
    if (data.len < 12 or !std.mem.eql(u8, data[0..4], "RIFF") or !std.mem.eql(u8, data[8..12], "WAVE")) return error.BadWav;
    var fmt: ?struct { tag: u16, channels: u16, rate: u32, bits: u16 } = null;
    var pcm: ?[]const u8 = null;
    var i: usize = 12;
    while (i + 8 <= data.len) {
        const id = data[i..][0..4];
        const len = std.mem.readInt(u32, data[i + 4 ..][0..4], .little);
        const body = data[i + 8 ..][0..@min(len, data.len - i - 8)];
        if (std.mem.eql(u8, id, "fmt ") and body.len >= 16) {
            fmt = .{
                .tag = std.mem.readInt(u16, body[0..2], .little),
                .channels = std.mem.readInt(u16, body[2..4], .little),
                .rate = std.mem.readInt(u32, body[4..8], .little),
                .bits = std.mem.readInt(u16, body[14..16], .little),
            };
            if (fmt.?.tag == 0xfffe and body.len >= 26) fmt.?.tag = std.mem.readInt(u16, body[24..26], .little);
        } else if (std.mem.eql(u8, id, "data")) pcm = body;
        i += 8 + len + (len & 1);
    }
    const f = fmt orelse return error.BadWav;
    const d = pcm orelse return error.BadWav;
    if (f.channels < 1 or f.channels > 2 or f.rate == 0) return error.UnsupportedWav;
    const sf: SampleFormat = switch (f.tag) {
        1 => switch (f.bits) {
            8 => .u8,
            16 => .s16,
            24 => .s32, // widened below
            32 => .s32,
            else => return error.UnsupportedWav,
        },
        3 => if (f.bits == 32) .f32 else return error.UnsupportedWav,
        else => return error.UnsupportedWav,
    };
    const bytes: usize = f.bits / 8;
    const n = d.len / bytes / f.channels * f.channels;
    const one = try gpa.alloc(f32, n);
    defer gpa.free(one);
    if (f.bits == 24) {
        for (one, 0..) |*o, k| {
            const b = d[k * 3 ..][0..3];
            const v: i32 = @as(i32, @bitCast(@as(u32, b[0]) << 8 | @as(u32, b[1]) << 16 | @as(u32, b[2]) << 24));
            o.* = @as(f32, @floatFromInt(v)) / 2147483648.0;
        }
    } else toFloat(sf, d[0 .. n * bytes], one);
    const times = @max(repeat, 1);
    const out = try gpa.alloc(f32, n * times);
    for (0..times) |r| @memcpy(out[r * n ..][0..n], one);
    return .{ .samples = out, .channels = f.channels, .rate = f.rate };
}

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

test "HD DVD volumes and mix-downs" {
    const l51 = Layout.of(chan.left | chan.right | chan.center | chan.lfe | chan.rear_left | chan.rear_right);
    var vol: [hd_channels]u8 = @splat(255);
    vol[2] = 0; // centre
    vol[3] = 51; // Ls: VLC's rear left in 5.1
    const g = hdGains(l51, vol);
    try testing.expectEqual(@as(f32, 0), g[l51.index(chan.center).?]);
    try testing.expectApproxEqAbs(@as(f32, 0.2), g[l51.index(chan.rear_left).?], 1e-6);
    try testing.expectEqual(@as(f32, 1), g[l51.index(chan.left).?]);

    // Stereo sub audio: left into the centre only, right into the right only.
    const st = Layout.of(chan.left | chan.right);
    var rows: [2][hd_channels]u8 = @splat(@splat(0));
    rows[0][2] = 255;
    rows[1][1] = 255;
    const m = hdMatrix(st, l51, rows);
    try testing.expectEqual(@as(f32, 1), m.g[l51.index(chan.center).?][0]);
    try testing.expectEqual(@as(f32, 0), m.g[l51.index(chan.left).?][0]);
    try testing.expectEqual(@as(f32, 1), m.g[l51.index(chan.right).?][1]);
    // Mono: both rows at -3 dB.
    const mono = hdMatrix(Layout.of(chan.center), l51, rows);
    try testing.expectApproxEqAbs(std.math.sqrt1_2, mono.g[l51.index(chan.center).?][0], 1e-6);
    try testing.expectApproxEqAbs(std.math.sqrt1_2, mono.g[l51.index(chan.right).?][0], 1e-6);
}

test "WAV decoding" {
    const gpa = testing.allocator;
    var wav: [44 + 8]u8 = @splat(0);
    @memcpy(wav[0..4], "RIFF");
    @memcpy(wav[8..16], "WAVEfmt ");
    std.mem.writeInt(u32, wav[16..20], 16, .little);
    std.mem.writeInt(u16, wav[20..22], 1, .little);
    std.mem.writeInt(u16, wav[22..24], 2, .little);
    std.mem.writeInt(u32, wav[24..28], 48000, .little);
    std.mem.writeInt(u16, wav[34..36], 16, .little);
    @memcpy(wav[36..40], "data");
    std.mem.writeInt(u32, wav[40..44], 8, .little);
    std.mem.writeInt(i16, wav[44..46], 0x4000, .little);
    std.mem.writeInt(i16, wav[46..48], -0x4000, .little);
    const w = try decodeWav(gpa, &wav, 3);
    defer gpa.free(w.samples);
    try testing.expectEqual(2, w.channels);
    try testing.expectEqual(48000, w.rate);
    try testing.expectEqual(12, w.samples.len);
    try testing.expectEqual(@as(f32, 0.5), w.samples[0]);
    try testing.expectEqual(@as(f32, -0.5), w.samples[5]);
    try testing.expectError(error.BadWav, decodeWav(gpa, wav[0..10], 1));
}
