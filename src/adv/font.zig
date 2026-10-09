//! Fonts for Advanced Content text (HD DVD Vol. 3 §7.3.2, Vol. 1 §4.3.19.10): OpenType/TrueType through
//! stb_truetype, with a cache of rendered glyphs (alpha masks) per size and quarter-pixel position, and
//! drawing into premultiplied canvases. No VLC dependency.

const std = @import("std");
const stb = @import("stb");
const raster = @import("raster.zig");

pub const Error = error{ BadFont, OutOfMemory };

pub const VMetrics = struct {
    /// Above the baseline (positive) and below it (positive), in pixels at the size asked.
    ascent: f32,
    descent: f32,
    line_gap: f32,
};

pub const Glyph = struct {
    w: u32,
    h: u32,
    /// Offset of the mask's top left from the pen position on the baseline.
    x: i32,
    y: i32,
    alpha: []u8,
};

const Key = struct { glyph: u32, sx: u32, sy: u32, sub: u8 };

pub const Font = struct {
    gpa: std.mem.Allocator,
    data: []u8,
    info: stb.stbtt_fontinfo,
    cache: std.AutoHashMapUnmanaged(Key, Glyph) = .empty,
    cached_bytes: usize = 0,

    /// Most bytes of glyph masks kept; the cache is emptied when it grows past this.
    const max_cache = 8 * 1024 * 1024;

    /// Loads a font file (copied). OpenType collections use their first font.
    pub fn create(gpa: std.mem.Allocator, bytes: []const u8) Error!*Font {
        const f = try gpa.create(Font);
        errdefer gpa.destroy(f);
        const data = try gpa.dupe(u8, bytes);
        errdefer gpa.free(data);
        f.* = .{ .gpa = gpa, .data = data, .info = undefined };
        const off = stb.stbtt_GetFontOffsetForIndex(data.ptr, 0);
        if (off < 0 or stb.stbtt_InitFont(&f.info, data.ptr, off) == 0) return error.BadFont;
        return f;
    }

    pub fn destroy(f: *Font) void {
        f.dropCache();
        f.cache.deinit(f.gpa);
        f.gpa.free(f.data);
        f.gpa.destroy(f);
    }

    fn dropCache(f: *Font) void {
        var it = f.cache.valueIterator();
        while (it.next()) |g| f.gpa.free(g.alpha);
        f.cache.clearRetainingCapacity();
        f.cached_bytes = 0;
    }

    /// Pixels per font unit for a font size (the em) of `size` pixels.
    pub fn scale(f: *const Font, size: f32) f32 {
        return stb.stbtt_ScaleForMappingEmToPixels(&f.info, size);
    }

    /// Line metrics at a block size of `size` pixels: the OS/2 typographic ones, or the hhea ones when those
    /// are all 0 or absent (§7.3.2.2).
    pub fn vmetrics(f: *const Font, size: f32) VMetrics {
        var a: c_int = 0;
        var d: c_int = 0;
        var g: c_int = 0;
        if (stb.stbtt_GetFontVMetricsOS2(&f.info, &a, &d, &g) == 0 or (a == 0 and d == 0 and g == 0))
            stb.stbtt_GetFontVMetrics(&f.info, &a, &d, &g);
        const s = f.scale(size);
        return .{ .ascent = @as(f32, @floatFromInt(a)) * s, .descent = -@as(f32, @floatFromInt(d)) * s, .line_gap = @as(f32, @floatFromInt(g)) * s };
    }

    /// The glyph for a code point (0: the font has none, its .notdef).
    pub fn glyphIndex(f: *const Font, cp: u21) u32 {
        return @intCast(stb.stbtt_FindGlyphIndex(&f.info, cp));
    }

    /// Advance width of a glyph, in pixels.
    pub fn advance(f: *const Font, g: u32, size: f32) f32 {
        var adv: c_int = 0;
        var lsb: c_int = 0;
        stb.stbtt_GetGlyphHMetrics(&f.info, @intCast(g), &adv, &lsb);
        return @as(f32, @floatFromInt(adv)) * f.scale(size);
    }

    /// Kerning between two glyphs, in pixels (the 'kern' table).
    pub fn kern(f: *const Font, a: u32, b: u32, size: f32) f32 {
        if (f.info.kern == 0 and f.info.gpos == 0) return 0;
        return @as(f32, @floatFromInt(stb.stbtt_GetGlyphKernAdvance(&f.info, @intCast(a), @intCast(b)))) * f.scale(size);
    }

    /// The rendered mask of glyph `g` at `sx`×`sy` pixels (inline and block font sizes), its pen at a
    /// quarter-pixel offset `sub` (0–3).
    pub fn glyph(f: *Font, g: u32, sx: f32, sy: f32, sub: u2) Error!Glyph {
        const key: Key = .{ .glyph = g, .sx = @intFromFloat(@round(sx * 64)), .sy = @intFromFloat(@round(sy * 64)), .sub = sub };
        if (f.cache.get(key)) |hit| return hit;
        if (f.cached_bytes > max_cache) f.dropCache();
        const s = f.scale(sx);
        const t = f.scale(sy);
        const shift = @as(f32, @floatFromInt(sub)) / 4;
        var x0: c_int = 0;
        var y0: c_int = 0;
        var x1: c_int = 0;
        var y1: c_int = 0;
        stb.stbtt_GetGlyphBitmapBoxSubpixel(&f.info, @intCast(g), s, t, shift, 0, &x0, &y0, &x1, &y1);
        const w: u32 = @intCast(@max(0, x1 - x0));
        const h: u32 = @intCast(@max(0, y1 - y0));
        const alpha = try f.gpa.alloc(u8, w * h);
        errdefer f.gpa.free(alpha);
        if (w > 0 and h > 0) stb.stbtt_MakeGlyphBitmapSubpixel(&f.info, alpha.ptr, @intCast(w), @intCast(h), @intCast(w), s, t, shift, 0, @intCast(g));
        const out: Glyph = .{ .w = w, .h = h, .x = x0, .y = y0, .alpha = alpha };
        try f.cache.put(f.gpa, key, out);
        f.cached_bytes += alpha.len;
        return out;
    }

    /// Draws glyph `g` with its pen at (x, baseline) in `color`, at `sx`×`sy` pixels. `slant` shears it
    /// (pixels to the right per pixel above the baseline: italic and oblique are synthesized, §7.6.3.3.2.27).
    pub fn draw(f: *Font, cv: raster.Canvas, clip: raster.Rect, x: f32, baseline: i32, g: u32, sx: f32, sy: f32, slant: f32, color: raster.Color) void {
        const px = @floor(x);
        const sub: u2 = @intFromFloat(@min(3, @floor((x - px) * 4)));
        const gl = f.glyph(g, sx, sy, sub) catch return;
        if (gl.w == 0) return;
        const gx = @as(i32, @intFromFloat(px)) + gl.x;
        const gy = baseline + gl.y;
        if (slant == 0) return mask(cv, clip, gx, gy, gl.w, gl.h, gl.alpha, color);
        for (0..gl.h) |row| {
            const above: f32 = @floatFromInt(-(gl.y + @as(i32, @intCast(row))));
            const shift: i32 = @intFromFloat(@round(above * slant));
            mask(cv, clip, gx + shift, gy + @as(i32, @intCast(row)), gl.w, 1, gl.alpha[row * gl.w ..][0..gl.w], color);
        }
    }
};

/// Composites `color` through an alpha mask at (x, y).
pub fn mask(cv: raster.Canvas, clip: raster.Rect, x: i32, y: i32, w: u32, h: u32, alpha: []const u8, color: raster.Color) void {
    const placed: raster.Rect = .{ .x = x, .y = y, .w = @intCast(w), .h = @intCast(h) };
    const a = clip.intersect(cv.bounds()) orelse return;
    const d = a.intersect(placed) orelse return;
    const p = color.premultiplied();
    for (@intCast(d.y)..@intCast(d.bottom())) |cy| {
        const row = cv.row(cy);
        const my = @as(usize, @intCast(@as(i32, @intCast(cy)) - y)) * w;
        for (@intCast(d.x)..@intCast(d.right())) |cx| {
            const m = alpha[my + @as(usize, @intCast(@as(i32, @intCast(cx)) - x))];
            if (m == 0) continue;
            row[cx] = raster.over(row[cx], raster.fade(p, m));
        }
    }
}

// ---- a synthetic font for tests ------------------------------------------------------------------------------

/// A TrueType font for tests: 1000 units per em, ascender 800, descender -200; 'A' is a 500×700 square
/// (advance 600), the space is empty (advance 250), everything else is .notdef (empty, advance 500).
pub fn testFont(gpa: std.mem.Allocator) ![]u8 {
    var tables: [7]struct { tag: *const [4]u8, data: std.ArrayList(u8) } = .{
        .{ .tag = "cmap", .data = .empty }, .{ .tag = "glyf", .data = .empty }, .{ .tag = "head", .data = .empty },
        .{ .tag = "hhea", .data = .empty }, .{ .tag = "hmtx", .data = .empty }, .{ .tag = "loca", .data = .empty },
        .{ .tag = "maxp", .data = .empty },
    };
    defer for (&tables) |*t| t.data.deinit(gpa);
    const W = struct {
        fn u16be(l: *std.ArrayList(u8), a: std.mem.Allocator, v: u16) !void {
            try l.appendSlice(a, &std.mem.toBytes(std.mem.nativeToBig(u16, v)));
        }
        fn i16be(l: *std.ArrayList(u8), a: std.mem.Allocator, v: i16) !void {
            try u16be(l, a, @bitCast(v));
        }
        fn u32be(l: *std.ArrayList(u8), a: std.mem.Allocator, v: u32) !void {
            try l.appendSlice(a, &std.mem.toBytes(std.mem.nativeToBig(u32, v)));
        }
    };
    // cmap: format 4, segments ' ' -> 2, 'A' -> 1, 0xFFFF end.
    {
        const l = &tables[0].data;
        try W.u16be(l, gpa, 0);
        try W.u16be(l, gpa, 1);
        try W.u16be(l, gpa, 3);
        try W.u16be(l, gpa, 1);
        try W.u32be(l, gpa, 12);
        const seg = [_][3]u16{ .{ 0x20, 0x20, 2 }, .{ 0x41, 0x41, 1 }, .{ 0xffff, 0xffff, 0 } };
        try W.u16be(l, gpa, 4);
        try W.u16be(l, gpa, 16 + 8 * seg.len);
        try W.u16be(l, gpa, 0);
        try W.u16be(l, gpa, 2 * seg.len);
        try W.u16be(l, gpa, 4);
        try W.u16be(l, gpa, 1);
        try W.u16be(l, gpa, 2);
        for (seg) |s| try W.u16be(l, gpa, s[1]);
        try W.u16be(l, gpa, 0);
        for (seg) |s| try W.u16be(l, gpa, s[0]);
        for (seg) |s| try W.u16be(l, gpa, if (s[0] == 0xffff) 1 else s[2] -% s[0]);
        for (seg) |_| try W.u16be(l, gpa, 0);
    }
    // glyf: .notdef empty, 'A' a square, space empty.
    {
        const l = &tables[1].data;
        try W.i16be(l, gpa, 1);
        for ([_]i16{ 0, 0, 500, 700 }) |v| try W.i16be(l, gpa, v);
        try W.u16be(l, gpa, 3);
        try W.u16be(l, gpa, 0);
        try l.appendSlice(gpa, &.{ 1, 1, 1, 1 });
        for ([_]i16{ 0, 0, 500, 0 }) |v| try W.i16be(l, gpa, v); // x deltas: (0,0) (0,700) (500,700) (500,0)
        for ([_]i16{ 0, 700, 0, -700 }) |v| try W.i16be(l, gpa, v);
    }
    const glyph1_len: u16 = @intCast(tables[1].data.items.len);
    // head
    {
        const l = &tables[2].data;
        try W.u32be(l, gpa, 0x00010000);
        try W.u32be(l, gpa, 0x00010000);
        try W.u32be(l, gpa, 0);
        try W.u32be(l, gpa, 0x5F0F3CF5);
        try W.u16be(l, gpa, 0);
        try W.u16be(l, gpa, 1000);
        try l.appendNTimes(gpa, 0, 16);
        for ([_]i16{ 0, -200, 600, 800 }) |v| try W.i16be(l, gpa, v);
        try W.u16be(l, gpa, 0);
        try W.u16be(l, gpa, 8);
        try W.i16be(l, gpa, 2);
        try W.i16be(l, gpa, 0); // short loca
        try W.i16be(l, gpa, 0);
    }
    // hhea
    {
        const l = &tables[3].data;
        try W.u32be(l, gpa, 0x00010000);
        for ([_]i16{ 800, -200, 0 }) |v| try W.i16be(l, gpa, v);
        try W.u16be(l, gpa, 600);
        try l.appendNTimes(gpa, 0, 22);
        try W.u16be(l, gpa, 3);
    }
    // hmtx
    for ([_]u16{ 500, 600, 250 }) |adv| {
        try W.u16be(&tables[4].data, gpa, adv);
        try W.i16be(&tables[4].data, gpa, 0);
    }
    // loca (short: offsets / 2)
    for ([_]u16{ 0, 0, glyph1_len / 2, glyph1_len / 2 }) |v| try W.u16be(&tables[5].data, gpa, v);
    // maxp 0.5
    try W.u32be(&tables[6].data, gpa, 0x00005000);
    try W.u16be(&tables[6].data, gpa, 3);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try W.u32be(&out, gpa, 0x00010000);
    try W.u16be(&out, gpa, tables.len);
    try W.u16be(&out, gpa, 64);
    try W.u16be(&out, gpa, 2);
    try W.u16be(&out, gpa, tables.len * 16 - 64);
    var off: u32 = 12 + 16 * tables.len;
    for (tables) |t| {
        try out.appendSlice(gpa, t.tag);
        try W.u32be(&out, gpa, 0);
        try W.u32be(&out, gpa, off);
        try W.u32be(&out, gpa, @intCast(t.data.items.len));
        off += @intCast((t.data.items.len + 3) / 4 * 4);
    }
    for (tables) |t| {
        try out.appendSlice(gpa, t.data.items);
        try out.appendNTimes(gpa, 0, (4 - t.data.items.len % 4) % 4);
    }
    return out.toOwnedSlice(gpa);
}

// ---- tests --------------------------------------------------------------------------------------------------

const testing = std.testing;

test "the synthetic font's metrics and glyphs" {
    const gpa = testing.allocator;
    const bytes = try testFont(gpa);
    defer gpa.free(bytes);
    const f = try Font.create(gpa, bytes);
    defer f.destroy();
    const m = f.vmetrics(100);
    try testing.expectApproxEqAbs(@as(f32, 80), m.ascent, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 20), m.descent, 0.01);
    const a = f.glyphIndex('A');
    try testing.expectEqual(@as(u32, 1), a);
    try testing.expectEqual(@as(u32, 2), f.glyphIndex(' '));
    try testing.expectEqual(@as(u32, 0), f.glyphIndex('z'));
    try testing.expectApproxEqAbs(@as(f32, 60), f.advance(a, 100), 0.01);
    const g = try f.glyph(a, 100, 100, 0);
    try testing.expectEqual(@as(u32, 50), g.w);
    try testing.expectEqual(@as(u32, 70), g.h);
    try testing.expectEqual(@as(i32, -70), g.y);

    var c = try raster.Canvas.init(gpa, 100, 100);
    defer c.deinit(gpa);
    f.draw(c, c.bounds(), 10, 90, a, 100, 100, 0, .{ .r = 255, .g = 255, .b = 255 });
    try testing.expectEqual(raster.Px{ 255, 255, 255, 255 }, c.at(30, 50));
    try testing.expectEqual(@as(u8, 0), c.at(30, 15)[3]); // above the square
    try testing.expectEqual(@as(u8, 0), c.at(65, 50)[3]); // right of it
    try testing.expectError(error.BadFont, Font.create(gpa, "nope"));
    // Anamorphic: half as wide.
    const narrow = try f.glyph(a, 50, 100, 0);
    try testing.expectEqual(@as(u32, 25), narrow.w);
    try testing.expectEqual(@as(u32, 70), narrow.h);
}
