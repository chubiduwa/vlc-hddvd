//! Picture operations for the video planes (HD DVD Vol. 1 §4.3.13.3): copying the main video through, and
//! turning a sub video picture into a scaled RGBA overlay with its alpha and luma key. Pictures are 8-bit
//! 4:2:0 YUV. No VLC dependency.

const std = @import("std");

pub const Plane = struct {
    px: [*]u8,
    pitch: usize,
    w: usize,
    h: usize,

    pub fn row(p: Plane, y: usize) []u8 {
        return p.px[y * p.pitch ..][0..p.w];
    }
};

/// A 4:2:0 picture: full-size luma, half-size chroma.
pub const Yuv = struct {
    y: Plane,
    u: Plane,
    v: Plane,

    pub fn width(p: Yuv) usize {
        return p.y.w;
    }

    pub fn height(p: Yuv) usize {
        return p.y.h;
    }
};

pub const Rect = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,
};

/// Copies `src` into `dst` (same size; the overlap if not).
pub fn copy(dst: Yuv, src: Yuv) void {
    inline for (.{ "y", "u", "v" }) |name| {
        const d = @field(dst, name);
        const s = @field(src, name);
        const w = @min(d.w, s.w);
        for (0..@min(d.h, s.h)) |y| @memcpy(d.row(y)[0..w], s.row(y)[0..w]);
    }
}

/// YUV to RGB matrix: BT.601 for SD sources, BT.709 for HD (studio range).
pub const Matrix = enum { bt601, bt709 };

/// Draws `src` scaled to `w`×`h` into `dst` (RGBA, straight alpha, `pitch` bytes per row), with opacity
/// `alpha`. With a luma key, source pixels whose luma is within [key[0], key[1]] are transparent (sub video,
/// Vol. 3 §6.3.1.2.3 EVOB_VS_LUMA).
pub fn toRgba(dst: []u8, pitch: usize, w: usize, h: usize, src: Yuv, alpha: u8, key: ?[2]u8, m: Matrix) void {
    if (w == 0 or h == 0 or src.width() == 0 or src.height() == 0) return;
    // Coefficients ×1024 for studio-range input (Y 16–235, C 16–240).
    const k: struct { rv: i32, gu: i32, gv: i32, bu: i32 } = switch (m) {
        .bt601 => .{ .rv = 1634, .gu = 401, .gv = 832, .bu = 2066 },
        .bt709 => .{ .rv = 1836, .gu = 218, .gv = 546, .bu = 2163 },
    };
    const cw = (w + 1) / 2;
    const ch = (h + 1) / 2;
    for (0..h) |y| {
        const out = dst[y * pitch ..][0 .. w * 4];
        for (0..w) |x| {
            const yy = sample(src.y, x, y, w, h);
            const o = out[x * 4 ..][0..4];
            if (key) |kr| if (yy >= kr[0] and yy <= kr[1]) {
                o.* = .{ 0, 0, 0, 0 };
                continue;
            };
            const u: i32 = @as(i32, sample(src.u, x / 2, y / 2, cw, ch)) - 128;
            const v: i32 = @as(i32, sample(src.v, x / 2, y / 2, cw, ch)) - 128;
            const c: i32 = (@as(i32, yy) - 16) * 1192; // 255/219 ×1024
            o[0] = clamp8((c + k.rv * v + 512) >> 10);
            o[1] = clamp8((c - k.gu * u - k.gv * v + 512) >> 10);
            o[2] = clamp8((c + k.bu * u + 512) >> 10);
            o[3] = alpha;
        }
    }
}

fn clamp8(v: i32) u8 {
    return @intCast(std.math.clamp(v, 0, 255));
}

/// Bilinear sample of `p` at destination pixel (x, y) of a dw×dh scaled image.
fn sample(p: Plane, x: usize, y: usize, dw: usize, dh: usize) u8 {
    if (dw == p.w and dh == p.h) return p.px[y * p.pitch + x];
    // Source coordinates in 16.16 fixed point, pixel centres aligned.
    const fx: i64 = @as(i64, @intCast(((x * 2 + 1) * p.w << 16) / (2 * dw))) - (1 << 15);
    const fy: i64 = @as(i64, @intCast(((y * 2 + 1) * p.h << 16) / (2 * dh))) - (1 << 15);
    const sx = std.math.clamp(fx, 0, (@as(i64, @intCast(p.w)) - 1) << 16);
    const sy = std.math.clamp(fy, 0, (@as(i64, @intCast(p.h)) - 1) << 16);
    const ix: usize = @intCast(sx >> 16);
    const iy: usize = @intCast(sy >> 16);
    const ax: u64 = @intCast(sx & 0xffff);
    const ay: u64 = @intCast(sy & 0xffff);
    const x1 = @min(ix + 1, p.w - 1);
    const y1 = @min(iy + 1, p.h - 1);
    const a = p.px[iy * p.pitch + ix];
    const b = p.px[iy * p.pitch + x1];
    const c = p.px[y1 * p.pitch + ix];
    const d = p.px[y1 * p.pitch + x1];
    const top = @as(u64, a) * (0x10000 - ax) + @as(u64, b) * ax;
    const bot = @as(u64, c) * (0x10000 - ax) + @as(u64, d) * ax;
    return @intCast((top * (0x10000 - ay) + bot * ay + (1 << 31)) >> 32);
}

// ---- tests --------------------------------------------------------------------------------------------------

const testing = std.testing;

const TestPic = struct {
    buf: []u8,
    pic: Yuv,

    fn init(w: usize, h: usize, c: [3]u8) !TestPic {
        const cw = (w + 1) / 2;
        const chh = (h + 1) / 2;
        const buf = try testing.allocator.alloc(u8, w * h + 2 * cw * chh);
        @memset(buf[0 .. w * h], c[0]);
        @memset(buf[w * h ..][0 .. cw * chh], c[1]);
        @memset(buf[w * h + cw * chh ..], c[2]);
        return .{ .buf = buf, .pic = .{
            .y = .{ .px = buf.ptr, .pitch = w, .w = w, .h = h },
            .u = .{ .px = buf.ptr + w * h, .pitch = cw, .w = cw, .h = chh },
            .v = .{ .px = buf.ptr + w * h + cw * chh, .pitch = cw, .w = cw, .h = chh },
        } };
    }

    fn deinit(t: TestPic) void {
        testing.allocator.free(t.buf);
    }
};

test "copy" {
    const src = try TestPic.init(4, 4, .{ 200, 60, 70 });
    defer src.deinit();
    const dst = try TestPic.init(4, 4, .{ 16, 128, 128 });
    defer dst.deinit();
    copy(dst.pic, src.pic);
    try testing.expectEqualSlices(u8, src.buf, dst.buf);
}

test "colour conversion" {
    var px: [4]u8 = undefined;
    const white = try TestPic.init(2, 2, .{ 235, 128, 128 });
    defer white.deinit();
    toRgba(&px, 4, 1, 1, white.pic, 200, null, .bt601);
    try testing.expectEqualSlices(u8, &.{ 255, 255, 255, 200 }, &px);
    const black = try TestPic.init(2, 2, .{ 16, 128, 128 });
    defer black.deinit();
    toRgba(&px, 4, 1, 1, black.pic, 255, null, .bt709);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 255 }, &px);
    // Pure red in BT.601 studio range: Y 81, Cb 90, Cr 240.
    const red = try TestPic.init(2, 2, .{ 81, 90, 240 });
    defer red.deinit();
    toRgba(&px, 4, 1, 1, red.pic, 255, null, .bt601);
    try testing.expect(px[0] >= 253 and px[1] <= 2 and px[2] <= 2);
}

test "scaling and luma key" {
    const src = try TestPic.init(4, 4, .{ 200, 128, 128 });
    defer src.deinit();
    src.pic.y.px[0] = 10; // keyed out where it dominates
    var out: [2 * 2 * 4]u8 = undefined;
    toRgba(&out, 8, 2, 2, src.pic, 255, .{ 0, 100 }, .bt601);
    try testing.expectEqual(255, out[3 + 4]); // top right opaque
    try testing.expectEqual(255, out[3 + 12]);
    // Top left samples the dark pixel bilinearly: luma (10+200+200+200)/4 > 100, kept.
    try testing.expectEqual(255, out[3]);
    var big: [8 * 8 * 4]u8 = undefined;
    toRgba(&big, 32, 8, 8, src.pic, 255, .{ 0, 100 }, .bt601);
    try testing.expectEqual(0, big[3]); // upscaled 2×: the dark corner is keyed out
    try testing.expectEqual(255, big[4 * 7 + 3]);
}
