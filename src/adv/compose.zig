//! Picture operations for the video planes (HD DVD Vol. 1 §4.3.13.3): placing the main video in the aperture,
//! and turning a sub video picture into a scaled RGBA overlay with its alpha and luma key. Pictures are 8-bit
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

    /// The part of the picture at `c` (x, y, w, h) in a `aw`×`ah` space the whole picture fills (an empty or
    /// out-of-range crop gives the whole picture). Luma coordinates are rounded to even.
    pub fn crop(p: Yuv, c: [4]u32, aw: u32, ah: u32) Yuv {
        if (c[2] == 0 or c[3] == 0 or aw == 0 or ah == 0) return p;
        const sx = @min(@as(usize, c[0]) * p.y.w / aw, p.y.w) & ~@as(usize, 1);
        const sy = @min(@as(usize, c[1]) * p.y.h / ah, p.y.h) & ~@as(usize, 1);
        const sw = @min(@as(usize, c[2]) * p.y.w / aw, p.y.w - sx) & ~@as(usize, 1);
        const sh = @min(@as(usize, c[3]) * p.y.h / ah, p.y.h - sy) & ~@as(usize, 1);
        if (sw == 0 or sh == 0) return p;
        return .{
            .y = .{ .px = p.y.px + sy * p.y.pitch + sx, .pitch = p.y.pitch, .w = sw, .h = sh },
            .u = .{ .px = p.u.px + sy / 2 * p.u.pitch + sx / 2, .pitch = p.u.pitch, .w = sw / 2, .h = sh / 2 },
            .v = .{ .px = p.v.px + sy / 2 * p.v.pitch + sx / 2, .pitch = p.v.pitch, .w = sw / 2, .h = sh / 2 },
        };
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

/// Fills a picture with one colour (Y, Cb, Cr).
pub fn fill(dst: Yuv, c: [3]u8) void {
    inline for (.{ "y", "u", "v" }, 0..) |name, i| {
        const d = @field(dst, name);
        for (0..d.h) |y| @memset(d.row(y), c[i]);
    }
}

/// Draws `src` scaled into `r` (luma coordinates, `r.y` even; clipped to `dst`), bilinearly. An interlaced
/// picture is scaled one field at a time, so it stays interlaced for the deinterlacer after us.
pub fn scaleFrame(dst: Yuv, r: Rect, src: Yuv, interlaced: bool) void {
    if (!interlaced or src.height() < 4) return scaleInto(dst, r, src);
    for (0..2) |parity| scaleInto(field(dst, parity), .{
        .x = r.x,
        .y = @divFloor(r.y, 2),
        .w = r.w,
        .h = @divFloor(r.h, 2),
    }, field(src, parity));
}

/// One field of a picture: every other row from `parity`, in luma and chroma.
fn field(p: Yuv, parity: usize) Yuv {
    const f = struct {
        fn plane(q: Plane, par: usize) Plane {
            return .{ .px = q.px + par * q.pitch, .pitch = q.pitch * 2, .w = q.w, .h = (q.h + 1 - par) / 2 };
        }
    };
    return .{ .y = f.plane(p.y, parity), .u = f.plane(p.u, parity), .v = f.plane(p.v, parity) };
}

/// Draws `src` scaled into `r` (luma coordinates; clipped to `dst`), bilinearly.
pub fn scaleInto(dst: Yuv, r: Rect, src: Yuv) void {
    if (r.w <= 0 or r.h <= 0) return;
    scalePlane(dst.y, r.x, r.y, @intCast(r.w), @intCast(r.h), src.y);
    // Chroma at half resolution; luma coordinates are even in practice.
    const cx = @divFloor(r.x, 2);
    const cy = @divFloor(r.y, 2);
    const cw: usize = @intCast(@divFloor(r.x + r.w + 1, 2) - cx);
    const ch: usize = @intCast(@divFloor(r.y + r.h + 1, 2) - cy);
    scalePlane(dst.u, cx, cy, cw, ch, src.u);
    scalePlane(dst.v, cx, cy, cw, ch, src.v);
}

/// Widest picture scaled by scaleInto.
const max_width = 8192;

fn scalePlane(d: Plane, rx: i32, ry: i32, rw: usize, rh: usize, s: Plane) void {
    if (rw == 0 or rh == 0 or s.w == 0 or s.h == 0) return;
    const x0: usize = @intCast(std.math.clamp(rx, 0, @as(i64, @intCast(d.w))));
    const x1: usize = @intCast(std.math.clamp(@as(i64, rx) + @as(i64, @intCast(rw)), 0, @as(i64, @intCast(d.w))));
    const y0: usize = @intCast(std.math.clamp(ry, 0, @as(i64, @intCast(d.h))));
    const y1: usize = @intCast(std.math.clamp(@as(i64, ry) + @as(i64, @intCast(rh)), 0, @as(i64, @intCast(d.h))));
    if (x0 >= x1 or y0 >= y1 or x1 - x0 > max_width) return;
    const ox: usize = @intCast(@as(i64, @intCast(x0)) - rx); // first visible column, within the scaled picture
    const oy: usize = @intCast(@as(i64, @intCast(y0)) - ry);
    if (rw == s.w and rh == s.h) { // same size: a copy
        for (y0..y1, oy..) |y, sy| @memcpy(d.row(y)[x0..x1], s.row(sy)[ox..][0 .. x1 - x0]);
        return;
    }
    // Source positions in 16.16 fixed point, pixel centres aligned (as `sample`), per column then per row.
    var xi: [max_width]u32 = undefined;
    var xf: [max_width]u32 = undefined;
    for (0..x1 - x0) |i| {
        const p = pos(ox + i, rw, s.w);
        xi[i] = p[0];
        xf[i] = p[1];
    }
    for (y0..y1, oy..) |y, sy| {
        const p = pos(sy, rh, s.h);
        const a = s.row(p[0]);
        const b = s.row(@min(p[0] + 1, s.h - 1));
        const fy: u64 = p[1];
        const out = d.row(y)[x0..x1];
        for (out, xi[0..out.len], xf[0..out.len]) |*o, ix, fx| {
            const ix1 = @min(ix + 1, s.w - 1);
            const top = @as(u64, a[ix]) * (0x10000 - fx) + @as(u64, a[ix1]) * fx;
            const bot = @as(u64, b[ix]) * (0x10000 - fx) + @as(u64, b[ix1]) * fx;
            o.* = @intCast((top * (0x10000 - fy) + bot * fy + (1 << 31)) >> 32);
        }
    }
}

/// Source index and 16-bit fraction for destination pixel `x` of `dn` scaled from `sn`.
fn pos(x: usize, dn: usize, sn: usize) [2]u32 {
    const f: i64 = @as(i64, @intCast(((x * 2 + 1) * sn << 16) / (2 * dn))) - (1 << 15);
    const c = std.math.clamp(f, 0, (@as(i64, @intCast(sn)) - 1) << 16);
    return .{ @intCast(c >> 16), @intCast(c & 0xffff) };
}

/// The main video's default place in a `aw`×`ah` aperture (Vol. 1 §4.3.13.3, Annex Z changeLayout with a null
/// scale): its height scaled to the aperture's and centred, without distortion, so 4:3 video gets side panels.
/// `dw`×`dh` is its size in square pixels (the Main Video coordinate system, §4.3.12). Even coordinates.
pub fn mainDefault(dw: u32, dh: u32, aw: u32, ah: u32) Rect {
    if (dw == 0 or dh == 0) return .{ .x = 0, .y = 0, .w = @intCast(aw), .h = @intCast(ah) };
    var w: u64 = (@as(u64, dw) * ah + dh / 2) / dh;
    var h: u64 = ah;
    if (w > aw) { // wider than the aperture: fit the width instead
        w = aw;
        h = (@as(u64, dh) * aw + dw / 2) / dw;
    }
    w &= ~@as(u64, 1);
    h &= ~@as(u64, 1);
    return .{
        .x = @intCast(((aw - w) / 2) & ~@as(u64, 1)),
        .y = @intCast(((ah - h) / 2) & ~@as(u64, 1)),
        .w = @intCast(w),
        .h = @intCast(h),
    };
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

test "cropping" {
    var y: [8 * 4]u8 = undefined;
    for (&y, 0..) |*v, i| v.* = @intCast(i);
    var u: [4 * 2]u8 = @splat(1);
    var v: [4 * 2]u8 = @splat(2);
    const p: Yuv = .{
        .y = .{ .px = &y, .pitch = 8, .w = 8, .h = 4 },
        .u = .{ .px = &u, .pitch = 4, .w = 4, .h = 2 },
        .v = .{ .px = &v, .pitch = 4, .w = 4, .h = 2 },
    };
    // The right half, bottom half, in a 16×8 space.
    const c = p.crop(.{ 8, 4, 8, 4 }, 16, 8);
    try std.testing.expectEqual(4, c.width());
    try std.testing.expectEqual(2, c.height());
    try std.testing.expectEqual(@as(u8, 2 * 8 + 4), c.y.px[0]);
    try std.testing.expectEqual(2, c.u.w);
    try std.testing.expectEqual(p.width(), p.crop(.{ 0, 0, 0, 0 }, 16, 8).width());
}

test "the main video's default place" {
    // 1920×1080 fills the aperture; 4:3 (640×480 square pixels) gets 240-pixel side panels; wider than
    // 16:9 is letterboxed.
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 1920, .h = 1080 }, mainDefault(1920, 1080, 1920, 1080));
    try testing.expectEqual(Rect{ .x = 240, .y = 0, .w = 1440, .h = 1080 }, mainDefault(640, 480, 1920, 1080));
    try testing.expectEqual(Rect{ .x = 160, .y = 0, .w = 960, .h = 720 }, mainDefault(640, 480, 1280, 720));
    try testing.expectEqual(Rect{ .x = 0, .y = 138, .w = 1920, .h = 802 }, mainDefault(2390, 998, 1920, 1080));
}

test "scaling into a rectangle" {
    const dst = try TestPic.init(8, 4, .{ 16, 128, 128 });
    defer dst.deinit();
    fill(dst.pic, .{ 1, 2, 3 });
    try testing.expectEqual(1, dst.pic.y.px[0]);
    try testing.expectEqual(3, dst.pic.v.px[3]);
    // A flat 2×2 picture doubled into the middle: x 2..6, y 0..4.
    const src = try TestPic.init(2, 2, .{ 200, 60, 70 });
    defer src.deinit();
    scaleInto(dst.pic, .{ .x = 2, .y = 0, .w = 4, .h = 4 }, src.pic);
    for (0..4) |y| try testing.expectEqualSlices(u8, &.{ 1, 1, 200, 200, 200, 200, 1, 1 }, dst.pic.y.row(y));
    try testing.expectEqualSlices(u8, &.{ 2, 60, 60, 2 }, dst.pic.u.row(0));
    // Clipped at the edges, and a same-size copy.
    scaleInto(dst.pic, .{ .x = -2, .y = -2, .w = 4, .h = 4 }, src.pic);
    try testing.expectEqual(200, dst.pic.y.px[0]);
    const ramp = try TestPic.init(2, 2, .{ 0, 128, 128 });
    defer ramp.deinit();
    ramp.pic.y.px[1] = 100;
    scaleInto(dst.pic, .{ .x = 6, .y = 2, .w = 2, .h = 2 }, ramp.pic);
    try testing.expectEqualSlices(u8, &.{ 0, 100 }, dst.pic.y.row(2)[6..8]);
    // Upscaling interpolates: 0 → 100 over four pixels.
    scaleInto(dst.pic, .{ .x = 0, .y = 0, .w = 4, .h = 2 }, ramp.pic);
    try testing.expectEqualSlices(u8, &.{ 0, 25, 75, 100 }, dst.pic.y.row(0)[0..4]);
}

test "interlaced pictures are scaled field by field" {
    // Rows alternate 10 (top field) and 200 (bottom field); doubled, the fields must not mix.
    const src = try TestPic.init(2, 4, .{ 0, 128, 128 });
    defer src.deinit();
    for (0..4) |y| @memset(src.pic.y.row(y), if (y % 2 == 0) 10 else 200);
    const dst = try TestPic.init(2, 8, .{ 0, 128, 128 });
    defer dst.deinit();
    scaleFrame(dst.pic, .{ .x = 0, .y = 0, .w = 2, .h = 8 }, src.pic, true);
    for (0..8) |y| try testing.expectEqual(@as(u8, if (y % 2 == 0) 10 else 200), dst.pic.y.row(y)[0]);
    // Progressive scaling blends them.
    scaleFrame(dst.pic, .{ .x = 0, .y = 0, .w = 2, .h = 8 }, src.pic, false);
    try testing.expect(dst.pic.y.row(2)[0] != 10 and dst.pic.y.row(2)[0] != 200);
}
