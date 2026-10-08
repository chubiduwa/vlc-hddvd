//! 2D drawing for the graphics and cursor planes (HD DVD Vol. 1 §4.3.13.3.1–2, Vol. 3 §7.3.1): RGBA canvases
//! with premultiplied alpha, rectangle fills, clears and image blits with source-over composition (the
//! painter's algorithm of §7.3.1.2), all clipped. The planes reach VLC with straight alpha (`unpremultiply`).
//! No VLC dependency.

const std = @import("std");

pub const Rect = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,

    pub fn right(r: Rect) i32 {
        return r.x + r.w;
    }

    pub fn bottom(r: Rect) i32 {
        return r.y + r.h;
    }

    pub fn empty(r: Rect) bool {
        return r.w <= 0 or r.h <= 0;
    }

    pub fn intersect(a: Rect, b: Rect) ?Rect {
        const x0 = @max(a.x, b.x);
        const y0 = @max(a.y, b.y);
        const x1 = @min(a.right(), b.right());
        const y1 = @min(a.bottom(), b.bottom());
        if (x1 <= x0 or y1 <= y0) return null;
        return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
    }

    pub fn contains(r: Rect, x: i32, y: i32) bool {
        return x >= r.x and y >= r.y and x < r.right() and y < r.bottom();
    }

    pub fn offset(r: Rect, dx: i32, dy: i32) Rect {
        return .{ .x = r.x + dx, .y = r.y + dy, .w = r.w, .h = r.h };
    }
};

/// A colour with straight alpha.
pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8 = 255,

    pub fn premultiplied(c: Color) Px {
        return .{ mul(c.r, c.a), mul(c.g, c.a), mul(c.b, c.a), c.a };
    }
};

/// A premultiplied RGBA pixel.
pub const Px = [4]u8;

/// x·y/255, rounded.
pub fn mul(x: u8, y: u8) u8 {
    return div255(@as(u32, x) * y);
}

fn div255(v: u32) u8 {
    return @intCast((v + 128 + ((v + 128) >> 8)) >> 8);
}

/// Source-over: `src` (premultiplied) over `dst` (premultiplied).
pub fn over(dst: Px, src: Px) Px {
    const inv: u32 = 255 - src[3];
    if (inv == 0) return src;
    return .{
        src[0] +| div255(dst[0] * inv),
        src[1] +| div255(dst[1] * inv),
        src[2] +| div255(dst[2] * inv),
        src[3] +| div255(dst[3] * inv),
    };
}

/// `p` scaled by opacity `o` (0–255).
pub fn fade(p: Px, o: u8) Px {
    if (o == 255) return p;
    return .{ mul(p[0], o), mul(p[1], o), mul(p[2], o), mul(p[3], o) };
}

/// Premultiplied to straight alpha.
pub fn unpremultiply(p: Px) Px {
    const a: u32 = p[3];
    if (a == 0) return .{ 0, 0, 0, 0 };
    if (a == 255) return p;
    return .{
        @intCast(@min(255, (@as(u32, p[0]) * 255 + a / 2) / a)),
        @intCast(@min(255, (@as(u32, p[1]) * 255 + a / 2) / a)),
        @intCast(@min(255, (@as(u32, p[2]) * 255 + a / 2) / a)),
        p[3],
    };
}

/// A premultiplied RGBA image; the planes and every decoded image.
pub const Canvas = struct {
    w: u32,
    h: u32,
    px: []Px,

    pub fn init(gpa: std.mem.Allocator, w: u32, h: u32) !Canvas {
        const px = try gpa.alloc(Px, @as(usize, w) * h);
        @memset(px, .{ 0, 0, 0, 0 });
        return .{ .w = w, .h = h, .px = px };
    }

    pub fn deinit(c: *Canvas, gpa: std.mem.Allocator) void {
        gpa.free(c.px);
        c.* = undefined;
    }

    pub fn bounds(c: Canvas) Rect {
        return .{ .x = 0, .y = 0, .w = @intCast(c.w), .h = @intCast(c.h) };
    }

    pub fn row(c: Canvas, y: usize) []Px {
        return c.px[y * c.w ..][0..c.w];
    }

    pub fn at(c: Canvas, x: i32, y: i32) Px {
        if (!c.bounds().contains(x, y)) return .{ 0, 0, 0, 0 };
        return c.px[@as(usize, @intCast(y)) * c.w + @as(usize, @intCast(x))];
    }

    /// Fills `r` with `color` composited over what is there.
    pub fn fill(c: Canvas, clip: Rect, r: Rect, color: Color) void {
        const p = color.premultiplied();
        const a = clip.intersect(c.bounds()) orelse return;
        const d = a.intersect(r) orelse return;
        for (@intCast(d.y)..@intCast(d.bottom())) |y| {
            const line = c.row(y)[@intCast(d.x)..@intCast(d.right())];
            if (p[3] == 255) @memset(line, p) else for (line) |*q| {
                q.* = over(q.*, p);
            }
        }
    }

    /// Sets `r` to transparent (a clear rectangle, Vol. 3 §7.8.4).
    pub fn clear(c: Canvas, clip: Rect, r: Rect) void {
        const a = clip.intersect(c.bounds()) orelse return;
        const d = a.intersect(r) orelse return;
        for (@intCast(d.y)..@intCast(d.bottom())) |y| @memset(c.row(y)[@intCast(d.x)..@intCast(d.right())], .{ 0, 0, 0, 0 });
    }

    /// Composites the `sr` part of `src` with its top left at (dx, dy), faded by `opacity`.
    pub fn blit(c: Canvas, clip: Rect, dx: i32, dy: i32, src: Canvas, sr: Rect, opacity: u8) void {
        if (opacity == 0) return;
        const s = sr.intersect(src.bounds()) orelse return;
        const placed = s.offset(dx - sr.x, dy - sr.y);
        const a = clip.intersect(c.bounds()) orelse return;
        const d = a.intersect(placed) orelse return;
        const sx0 = s.x + (d.x - placed.x);
        const sy0 = s.y + (d.y - placed.y);
        for (0..@intCast(d.h)) |i| {
            const srow = src.row(@as(usize, @intCast(sy0)) + i)[@intCast(sx0)..][0..@intCast(d.w)];
            const drow = c.row(@as(usize, @intCast(d.y)) + i)[@intCast(d.x)..][0..@intCast(d.w)];
            for (drow, srow) |*q, p| q.* = over(q.*, fade(p, opacity));
        }
    }

    /// Composites `src` scaled to the rectangle `to` (bilinear), faded by `opacity`.
    pub fn blitScaled(c: Canvas, clip: Rect, to: Rect, src: Canvas, opacity: u8) void {
        if (opacity == 0 or to.empty() or src.w == 0 or src.h == 0) return;
        if (to.w == src.w and to.h == src.h) return c.blit(clip, to.x, to.y, src, src.bounds(), opacity);
        const a = clip.intersect(c.bounds()) orelse return;
        const d = a.intersect(to) orelse return;
        // Source position of a destination pixel centre, in 1/256 pixels.
        const sx_step: i64 = @divTrunc(@as(i64, src.w) << 8, to.w);
        const sy_step: i64 = @divTrunc(@as(i64, src.h) << 8, to.h);
        for (@intCast(d.y)..@intCast(d.bottom())) |y| {
            const fy = (@as(i64, @as(i32, @intCast(y)) - to.y) * sy_step) + (sy_step >> 1) - 128;
            const drow = c.row(y);
            for (@intCast(d.x)..@intCast(d.right())) |x| {
                const fx = (@as(i64, @as(i32, @intCast(x)) - to.x) * sx_step) + (sx_step >> 1) - 128;
                drow[x] = over(drow[x], fade(sample(src, fx, fy), opacity));
            }
        }
    }
};

/// Bilinear sample at (fx, fy) in 1/256 pixels, clamped to the edges.
fn sample(src: Canvas, fx: i64, fy: i64) Px {
    const max_x: i64 = src.w - 1;
    const max_y: i64 = src.h - 1;
    const x0 = std.math.clamp(fx >> 8, 0, max_x);
    const y0 = std.math.clamp(fy >> 8, 0, max_y);
    const x1 = @min(x0 + 1, max_x);
    const y1 = @min(y0 + 1, max_y);
    const wx: u32 = if (fx < 0) 0 else @intCast(fx & 255);
    const wy: u32 = if (fy < 0) 0 else @intCast(fy & 255);
    const p00 = src.px[@intCast(y0 * src.w + x0)];
    const p10 = src.px[@intCast(y0 * src.w + x1)];
    const p01 = src.px[@intCast(y1 * src.w + x0)];
    const p11 = src.px[@intCast(y1 * src.w + x1)];
    var out: Px = undefined;
    for (0..4) |i| {
        const top = @as(u32, p00[i]) * (256 - wx) + @as(u32, p10[i]) * wx;
        const bot = @as(u32, p01[i]) * (256 - wx) + @as(u32, p11[i]) * wx;
        out[i] = @intCast((top * (256 - wy) + bot * wy + (1 << 15)) >> 16);
    }
    return out;
}

// ---- tests --------------------------------------------------------------------------------------------------

const testing = std.testing;

test "premultiplied arithmetic" {
    try testing.expectEqual(@as(u8, 128), mul(255, 128));
    try testing.expectEqual(@as(u8, 0), mul(200, 0));
    const half_red = (Color{ .r = 255, .g = 0, .b = 0, .a = 128 }).premultiplied();
    try testing.expectEqual(Px{ 128, 0, 0, 128 }, half_red);
    // Half red over opaque blue: purple, opaque.
    try testing.expectEqual(Px{ 128, 0, 127, 255 }, over(.{ 0, 0, 255, 255 }, half_red));
    try testing.expectEqual(Px{ 255, 0, 0, 128 }, unpremultiply(half_red));
    try testing.expectEqual(Px{ 0, 0, 0, 0 }, unpremultiply(.{ 0, 0, 0, 0 }));
    // Over transparent leaves the source.
    try testing.expectEqual(half_red, over(.{ 0, 0, 0, 0 }, half_red));
}

test "fill, clear and blit are clipped" {
    const gpa = testing.allocator;
    var c = try Canvas.init(gpa, 8, 4);
    defer c.deinit(gpa);
    const all = c.bounds();
    c.fill(all, .{ .x = -2, .y = -2, .w = 4, .h = 4 }, .{ .r = 10, .g = 20, .b = 30 });
    try testing.expectEqual(Px{ 10, 20, 30, 255 }, c.at(1, 1));
    try testing.expectEqual(Px{ 0, 0, 0, 0 }, c.at(2, 0));
    // A clip rectangle limits the fill.
    c.fill(.{ .x = 4, .y = 0, .w = 2, .h = 4 }, all, .{ .r = 1, .g = 2, .b = 3 });
    try testing.expectEqual(Px{ 1, 2, 3, 255 }, c.at(5, 3));
    try testing.expectEqual(Px{ 0, 0, 0, 0 }, c.at(6, 3));
    c.clear(all, .{ .x = 5, .y = 2, .w = 10, .h = 10 });
    try testing.expectEqual(Px{ 0, 0, 0, 0 }, c.at(5, 3));
    try testing.expectEqual(Px{ 1, 2, 3, 255 }, c.at(4, 3));

    var s = try Canvas.init(gpa, 2, 2);
    defer s.deinit(gpa);
    @memset(s.px, (Color{ .r = 255, .g = 255, .b = 255, .a = 255 }).premultiplied());
    s.px[3] = .{ 0, 0, 0, 0 };
    c.blit(all, 7, 3, s, s.bounds(), 255); // only the top-left source pixel lands
    try testing.expectEqual(Px{ 255, 255, 255, 255 }, c.at(7, 3));
    c.blit(all, 0, 2, s, s.bounds(), 128);
    try testing.expectEqual(Px{ 128, 128, 128, 128 }, c.at(1, 2));
    try testing.expectEqual(Px{ 0, 0, 0, 0 }, c.at(1, 3)); // transparent source pixel
}

test "scaled blit" {
    const gpa = testing.allocator;
    var c = try Canvas.init(gpa, 4, 4);
    defer c.deinit(gpa);
    var s = try Canvas.init(gpa, 1, 1);
    defer s.deinit(gpa);
    s.px[0] = .{ 0, 200, 0, 255 };
    c.blitScaled(c.bounds(), .{ .x = 1, .y = 1, .w = 2, .h = 3 }, s, 255);
    try testing.expectEqual(Px{ 0, 200, 0, 255 }, c.at(2, 3));
    try testing.expectEqual(Px{ 0, 0, 0, 0 }, c.at(3, 3));
    // Upscaling a 2×1 gradient keeps the ends and blends the middle.
    var g = try Canvas.init(gpa, 2, 1);
    defer g.deinit(gpa);
    g.px[0] = .{ 0, 0, 0, 255 };
    g.px[1] = .{ 255, 255, 255, 255 };
    var d = try Canvas.init(gpa, 4, 1);
    defer d.deinit(gpa);
    d.blitScaled(d.bounds(), d.bounds(), g, 255);
    try testing.expectEqual(@as(u8, 0), d.at(0, 0)[0]);
    try testing.expectEqual(@as(u8, 255), d.at(3, 0)[0]);
    try testing.expect(d.at(1, 0)[0] > 0 and d.at(1, 0)[0] < d.at(2, 0)[0]);
}
