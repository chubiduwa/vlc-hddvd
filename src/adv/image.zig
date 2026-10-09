//! Image decoding for Advanced Content (HD DVD Vol. 1 §4.3.19.10, Vol. 3 §6.5.1, §7.8.3): PNG (including 8-bit
//! indexed with transparency, as cursor images are) and JPEG, through stb_image, into premultiplied RGBA
//! canvases; and MNG-VLC animations (§6.5.1.3), whose frames are their embedded PNGs, decoded one at a time.
//! No VLC dependency.

const std = @import("std");
const stb = @import("stb");
const raster = @import("raster.zig");

pub const Error = error{ BadImage, OutOfMemory };

/// Largest side accepted (the aperture is at most 1920×1080; images may be bigger and cropped, within reason).
pub const max_side = 8192;

pub const Kind = enum { png, jpeg, mng, unknown };

pub fn kindOf(bytes: []const u8) Kind {
    if (std.mem.startsWith(u8, bytes, "\x89PNG\r\n\x1a\n")) return .png;
    if (std.mem.startsWith(u8, bytes, "\x8aMNG\r\n\x1a\n")) return .mng;
    if (std.mem.startsWith(u8, bytes, "\xff\xd8\xff")) return .jpeg;
    return .unknown;
}

/// Decodes a PNG or JPEG into a premultiplied canvas (caller frees it).
pub fn decode(gpa: std.mem.Allocator, bytes: []const u8) Error!raster.Canvas {
    switch (kindOf(bytes)) {
        .png, .jpeg => {},
        else => return error.BadImage,
    }
    if (bytes.len > std.math.maxInt(c_int)) return error.BadImage;
    var w: c_int = 0;
    var h: c_int = 0;
    var n: c_int = 0;
    const px = stb.stbi_load_from_memory(bytes.ptr, @intCast(bytes.len), &w, &h, &n, 4) orelse return error.BadImage;
    defer stb.stbi_image_free(px);
    if (w <= 0 or h <= 0 or w > max_side or h > max_side) return error.BadImage;
    const c = try raster.Canvas.init(gpa, @intCast(w), @intCast(h));
    const src: [*]const [4]u8 = @ptrCast(px);
    for (c.px, src[0..c.px.len]) |*d, s| d.* = (raster.Color{ .r = s[0], .g = s[1], .b = s[2], .a = s[3] }).premultiplied();
    return c;
}

/// A decoded image: a still, or an MNG whose frames are decoded when asked for (the last one is kept).
pub const Image = struct {
    w: u32,
    h: u32,
    data: union(enum) { still: raster.Canvas, mng: Mng },
    cached: ?struct { i: u32, c: raster.Canvas } = null,

    pub fn load(gpa: std.mem.Allocator, bytes: []const u8) Error!Image {
        if (kindOf(bytes) == .mng) {
            const m = try Mng.parse(gpa, bytes);
            return .{ .w = m.w, .h = m.h, .data = .{ .mng = m } };
        }
        const c = try decode(gpa, bytes);
        return .{ .w = c.w, .h = c.h, .data = .{ .still = c } };
    }

    pub fn deinit(im: *Image, gpa: std.mem.Allocator) void {
        switch (im.data) {
            .still => |*c| c.deinit(gpa),
            .mng => |*m| m.deinit(gpa),
        }
        if (im.cached) |*x| x.c.deinit(gpa);
        im.* = undefined;
    }

    /// The MNG animation, if it is one.
    pub fn animation(im: *const Image) ?*const Mng {
        return switch (im.data) {
            .mng => |*m| m,
            .still => null,
        };
    }

    pub fn frameCount(im: *const Image) u32 {
        return switch (im.data) {
            .still => 1,
            .mng => |m| @intCast(m.frames.len),
        };
    }

    /// Frame `i` (an index past the last is the last), or null if it cannot be decoded.
    pub fn frame(im: *Image, gpa: std.mem.Allocator, i_in: u32) ?*const raster.Canvas {
        switch (im.data) {
            .still => |*c| return c,
            .mng => |*m| {
                if (m.frames.len == 0) return null;
                const i = @min(i_in, m.frames.len - 1);
                if (im.cached) |*x| {
                    if (x.i == i) return &x.c;
                    x.c.deinit(gpa);
                    im.cached = null;
                }
                const c = m.decodeFrame(gpa, @intCast(i)) catch return null;
                im.cached = .{ .i = @intCast(i), .c = c };
                return &im.cached.?.c;
            },
        }
    }
};

/// An MNG-VLC datastream (§6.5.1.3): MHDR, then PNG images (IHDR … IEND), each one frame of one tick, with a
/// global PLTE/tRNS, BACK and TERM; it ends with MEND. Other chunks are optional and ignored.
pub const Mng = struct {
    bytes: []u8,
    w: u32,
    h: u32,
    ticks_per_second: u32,
    frames: []Frame,
    /// Global PLTE and tRNS chunks (whole chunks), for images with an empty PLTE.
    plte: ?[]const u8 = null,
    trns: ?[]const u8 = null,
    /// BACK: the colour the frame is cleared to before each image.
    back: ?raster.Color = null,
    term: Term = .{},

    pub const Frame = struct { start: usize, end: usize, empty_plte: bool, has_trns: bool };

    /// TERM (§6.5.1.3.1 Table 6.5.1.3.1-2). Without one, the last frame stays.
    pub const Term = struct {
        /// 0: show the last frame, 1: cease displaying, 2: show the first frame, 3: repeat.
        action: u8 = 0,
        /// After the last iteration of a repeat: 0, 1 or 2 as above.
        after: u8 = 0,
        /// Ticks between iterations.
        delay: u32 = 0,
        /// Iterations (0x7FFFFFFF: forever).
        max: u32 = 1,
    };

    pub fn parse(gpa: std.mem.Allocator, src: []const u8) Error!Mng {
        if (kindOf(src) != .mng) return error.BadImage;
        const bytes = try gpa.dupe(u8, src);
        errdefer gpa.free(bytes);
        var frames: std.ArrayList(Frame) = .empty;
        errdefer frames.deinit(gpa);
        var m: Mng = .{ .bytes = bytes, .w = 0, .h = 0, .ticks_per_second = 1, .frames = &.{} };
        var pos: usize = 8;
        var cur: ?Frame = null;
        var first = true;
        while (pos + 12 <= bytes.len) {
            const len = std.mem.readInt(u32, bytes[pos..][0..4], .big);
            if (len > bytes.len - pos - 12) return error.BadImage;
            const ty = bytes[pos + 4 ..][0..4];
            const data = bytes[pos + 8 ..][0..len];
            const end = pos + 12 + len;
            defer pos = end;
            if (first) {
                if (!std.mem.eql(u8, ty, "MHDR") or len < 12) return error.BadImage;
                first = false;
                m.w = std.mem.readInt(u32, data[0..4], .big);
                m.h = std.mem.readInt(u32, data[4..8], .big);
                m.ticks_per_second = @max(1, std.mem.readInt(u32, data[8..12], .big));
                if (m.w == 0 or m.h == 0 or m.w > max_side or m.h > max_side) return error.BadImage;
                continue;
            }
            if (std.mem.eql(u8, ty, "MEND")) break;
            if (cur) |*f| {
                if (std.mem.eql(u8, ty, "PLTE") and len == 0) f.empty_plte = true;
                if (std.mem.eql(u8, ty, "tRNS")) f.has_trns = true;
                if (std.mem.eql(u8, ty, "IEND")) {
                    f.end = end;
                    try frames.append(gpa, f.*);
                    cur = null;
                }
                continue;
            }
            if (std.mem.eql(u8, ty, "IHDR")) {
                cur = .{ .start = pos, .end = end, .empty_plte = false, .has_trns = false };
            } else if (std.mem.eql(u8, ty, "PLTE")) {
                m.plte = bytes[pos..end];
            } else if (std.mem.eql(u8, ty, "tRNS")) {
                m.trns = bytes[pos..end];
            } else if (std.mem.eql(u8, ty, "BACK") and len >= 6) {
                // 16-bit samples.
                m.back = .{ .r = data[0], .g = data[2], .b = data[4], .a = 255 };
            } else if (std.mem.eql(u8, ty, "TERM") and len >= 1) {
                m.term = .{ .action = @min(data[0], 3) };
                if (data[0] == 3 and len >= 10) {
                    m.term.after = @min(data[1], 2);
                    m.term.delay = std.mem.readInt(u32, data[2..6], .big);
                    m.term.max = std.mem.readInt(u32, data[6..10], .big);
                }
            }
        }
        if (first) return error.BadImage;
        m.frames = try frames.toOwnedSlice(gpa);
        return m;
    }

    pub fn deinit(m: *Mng, gpa: std.mem.Allocator) void {
        gpa.free(m.frames);
        gpa.free(m.bytes);
        m.* = undefined;
    }

    /// Frame `i` as a canvas of the MNG's frame size: BACK (or transparent), then the image at the top left.
    pub fn decodeFrame(m: *const Mng, gpa: std.mem.Allocator, i: u32) Error!raster.Canvas {
        const f = m.frames[i];
        // The embedded image as a PNG datastream, with the global palette where its PLTE is empty.
        var png: std.ArrayList(u8) = .empty;
        defer png.deinit(gpa);
        try png.appendSlice(gpa, "\x89PNG\r\n\x1a\n");
        var pos = f.start;
        while (pos < f.end) {
            const len = std.mem.readInt(u32, m.bytes[pos..][0..4], .big);
            const end = pos + 12 + len;
            const ty = m.bytes[pos + 4 ..][0..4];
            if (std.mem.eql(u8, ty, "PLTE") and len == 0) {
                if (m.plte) |g| try png.appendSlice(gpa, g);
                if (!f.has_trns) if (m.trns) |g| try png.appendSlice(gpa, g);
            } else try png.appendSlice(gpa, m.bytes[pos..end]);
            pos = end;
        }
        var layer = try decode(gpa, png.items);
        defer layer.deinit(gpa);
        var c = try raster.Canvas.init(gpa, m.w, m.h);
        if (m.back) |b| c.fill(c.bounds(), c.bounds(), b);
        c.blit(c.bounds(), 0, 0, layer, layer.bounds(), 255);
        return c;
    }

    /// The frame shown at graphics tick `k` after the animation started, ticks at `rate` per second (Vol. 1
    /// §4.3.19.10.5): the first frame that starts in the tick's period, else the one showing at its start
    /// (frames faster than the ticks are dropped, slower ones stay). Null: nothing is shown (TERM: cease).
    pub fn frameAt(m: *const Mng, k: u64, rate: u32) ?u32 {
        if (m.frames.len == 0 or rate == 0) return null;
        const f: u64 = m.ticks_per_second;
        const r: u64 = rate;
        // MNG ticks starting in [k/r, (k+1)/r).
        const j0 = std.math.divCeil(u64, k * f, r) catch unreachable;
        var j = j0;
        while (j * r < (k + 1) * f) : (j += 1) if (m.startsAt(j)) return m.stateAt(j);
        return if (j0 == 0) m.stateAt(0) else m.stateAt(j0 - 1);
    }

    /// Ticks per iteration, and iterations (null: forever).
    fn loop(m: *const Mng) struct { len: u64, n: ?u64 } {
        const n: u64 = m.frames.len;
        if (m.term.action != 3) return .{ .len = n, .n = 1 };
        return .{ .len = n + m.term.delay, .n = if (m.term.max == 0x7FFFFFFF) null else @max(1, m.term.max) };
    }

    /// Whether a frame (or the end state) starts at MNG tick `j`.
    fn startsAt(m: *const Mng, j: u64) bool {
        const l = m.loop();
        if (l.n) |n| if (j >= n * l.len) return j == n * l.len;
        return j % l.len < m.frames.len;
    }

    /// What shows during MNG tick `j`.
    fn stateAt(m: *const Mng, j: u64) ?u32 {
        const n: u32 = @intCast(m.frames.len);
        const l = m.loop();
        if (l.n) |it| if (j >= it * l.len) return switch (if (m.term.action == 3) m.term.after else m.term.action) {
            1 => null,
            2 => 0,
            else => n - 1,
        };
        return @intCast(@min(j % l.len, n - 1));
    }
};

// ---- tests --------------------------------------------------------------------------------------------------

const testing = std.testing;

/// A PNG of `w`×`h` RGBA pixels (stored, uncompressed deflate), for tests.
pub fn testPng(gpa: std.mem.Allocator, w: u32, h: u32, px: []const [4]u8) ![]u8 {
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(gpa);
    for (0..h) |y| {
        try raw.append(gpa, 0); // filter: none
        for (px[y * w ..][0..w]) |p| try raw.appendSlice(gpa, &p);
    }
    // zlib stream with stored blocks.
    var z: std.ArrayList(u8) = .empty;
    defer z.deinit(gpa);
    try z.appendSlice(gpa, &.{ 0x78, 0x01 });
    var i: usize = 0;
    while (true) {
        const n = @min(raw.items.len - i, 65535);
        const last = i + n == raw.items.len;
        try z.append(gpa, if (last) 1 else 0);
        try z.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToLittle(u16, @intCast(n))));
        try z.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToLittle(u16, ~@as(u16, @intCast(n)))));
        try z.appendSlice(gpa, raw.items[i..][0..n]);
        i += n;
        if (last) break;
    }
    try z.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToBig(u32, std.hash.Adler32.hash(raw.items))));

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "\x89PNG\r\n\x1a\n");
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], w, .big);
    std.mem.writeInt(u32, ihdr[4..8], h, .big);
    ihdr[8..13].* = .{ 8, 6, 0, 0, 0 }; // 8-bit RGBA
    try chunk(gpa, &out, "IHDR", &ihdr);
    try chunk(gpa, &out, "IDAT", z.items);
    try chunk(gpa, &out, "IEND", "");
    return out.toOwnedSlice(gpa);
}

fn chunk(gpa: std.mem.Allocator, out: *std.ArrayList(u8), kind: *const [4]u8, data: []const u8) !void {
    var len: [4]u8 = undefined;
    std.mem.writeInt(u32, &len, @intCast(data.len), .big);
    try out.appendSlice(gpa, &len);
    try out.appendSlice(gpa, kind);
    try out.appendSlice(gpa, data);
    var crc = std.hash.Crc32.init();
    crc.update(kind);
    crc.update(data);
    var c: [4]u8 = undefined;
    std.mem.writeInt(u32, &c, crc.final(), .big);
    try out.appendSlice(gpa, &c);
}

test "decode a PNG, premultiplied" {
    const gpa = testing.allocator;
    const png = try testPng(gpa, 2, 1, &.{ .{ 255, 0, 0, 255 }, .{ 0, 0, 255, 128 } });
    defer gpa.free(png);
    try testing.expectEqual(Kind.png, kindOf(png));
    var c = try decode(gpa, png);
    defer c.deinit(gpa);
    try testing.expectEqual(@as(u32, 2), c.w);
    try testing.expectEqual(raster.Px{ 255, 0, 0, 255 }, c.at(0, 0));
    try testing.expectEqual(raster.Px{ 0, 0, 128, 128 }, c.at(1, 0));
    try testing.expectError(error.BadImage, decode(gpa, "not an image"));
    try testing.expectError(error.BadImage, decode(gpa, png[0..20]));
}

/// An MNG of 2×1 frames from the RGBA pixels of each, with optional BACK and TERM data, for tests.
pub fn testMng(gpa: std.mem.Allocator, tps: u32, frames: []const [2][4]u8, back: ?[6]u8, term: ?[]const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "\x8aMNG\r\n\x1a\n");
    var mhdr: [28]u8 = @splat(0);
    std.mem.writeInt(u32, mhdr[0..4], 2, .big);
    std.mem.writeInt(u32, mhdr[4..8], 1, .big);
    std.mem.writeInt(u32, mhdr[8..12], tps, .big);
    std.mem.writeInt(u32, mhdr[24..28], 0x1C9, .big);
    try chunk(gpa, &out, "MHDR", &mhdr);
    if (term) |t| try chunk(gpa, &out, "TERM", t);
    if (back) |b| try chunk(gpa, &out, "BACK", &b);
    for (frames) |f| {
        const png = try testPng(gpa, 2, 1, &f);
        defer gpa.free(png);
        try out.appendSlice(gpa, png[8..]);
    }
    try chunk(gpa, &out, "MEND", "");
    return out.toOwnedSlice(gpa);
}

test "MNG frames, background and termination" {
    const gpa = testing.allocator;
    const red: [4]u8 = .{ 255, 0, 0, 255 };
    const clear: [4]u8 = .{ 0, 0, 0, 0 };
    const blue: [4]u8 = .{ 0, 0, 255, 255 };
    const bytes = try testMng(gpa, 10, &.{ .{ red, clear }, .{ blue, blue }, .{ clear, red } }, .{ 0, 0, 0xff, 0xff, 0, 0 }, null);
    defer gpa.free(bytes);
    var im = try Image.load(gpa, bytes);
    defer im.deinit(gpa);
    try testing.expectEqual(@as(u32, 3), im.frameCount());
    try testing.expectEqual(@as(u32, 2), im.w);
    // BACK (green) shows where the image is transparent.
    const f0 = im.frame(gpa, 0).?;
    try testing.expectEqual(raster.Px{ 255, 0, 0, 255 }, f0.at(0, 0));
    try testing.expectEqual(raster.Px{ 0, 255, 0, 255 }, f0.at(1, 0));
    try testing.expectEqual(raster.Px{ 0, 0, 255, 255 }, im.frame(gpa, 1).?.at(1, 0));
    try testing.expectEqual(raster.Px{ 255, 0, 0, 255 }, im.frame(gpa, 9).?.at(1, 0));

    // 10 frames a second on 30 ticks a second: each frame stays three ticks; then the last one stays.
    const m = im.animation().?;
    const want = [_]?u32{ 0, 0, 0, 1, 1, 1, 2, 2, 2, 2, 2 };
    for (want, 0..) |w, k| try testing.expectEqual(w, m.frameAt(k, 30));
    // On 5 ticks a second, the frames between ticks are dropped: the first one in each tick's period shows.
    try testing.expectEqual(@as(?u32, 0), m.frameAt(0, 5));
    try testing.expectEqual(@as(?u32, 2), m.frameAt(1, 5));
}

test "MNG repeats with TERM" {
    const gpa = testing.allocator;
    const a: [4]u8 = .{ 255, 0, 0, 255 };
    // Repeat twice, a tick of delay between iterations, then cease (action after iteration 1).
    const term: [10]u8 = .{ 3, 1, 0, 0, 0, 1, 0, 0, 0, 2 };
    const bytes = try testMng(gpa, 1, &.{ .{ a, a }, .{ a, a } }, null, &term);
    defer gpa.free(bytes);
    var m = try Mng.parse(gpa, bytes);
    defer m.deinit(gpa);
    const want = [_]?u32{ 0, 1, 1, 0, 1, 1, null, null };
    for (want, 0..) |w, k| try testing.expectEqual(w, m.frameAt(k, 1));
    // Forever, and action 2 (the first frame) once over.
    m.term.max = 0x7FFFFFFF;
    try testing.expectEqual(@as(?u32, 0), m.frameAt(3000, 1));
    m.term = .{ .action = 2 };
    try testing.expectEqual(@as(?u32, 1), m.frameAt(1, 1));
    try testing.expectEqual(@as(?u32, 0), m.frameAt(2, 1));
    try testing.expectError(error.BadImage, Mng.parse(gpa, "\x8aMNG\r\n\x1a\n"));
}
