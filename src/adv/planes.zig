//! The upper presentation planes of Advanced Content as they are handed to the overlay (HD DVD Vol. 1
//! §4.3.13.3, Vol. 3 §7.3.1, §7.8.4):
//!
//! - a graphics `Frame`: the graphics plane (premultiplied RGBA, aperture size) rendered by the engine, the
//!   clear rectangles it holds (holes through the sub-picture plane, and with target `main` through the sub
//!   video plane too), and which tiles hold anything, so only those reach VLC. Frames are double-buffered:
//!   the engine renders into one the overlay is not reading (§7.3.1.2);
//! - the `Cursor`: position, hot spot, image (default: the player's own arrow), visibility and region
//!   (Annex Z.5.5, Annex W Table W-6).
//!
//! No VLC dependency.

const std = @import("std");
const raster = @import("raster.zig");

const Rect = raster.Rect;

/// Side of the square tiles a frame is split into for the overlay.
pub const tile = 64;

pub const Target = enum { main, sub };

/// A clear rectangle (an `application/x-clearrect` object), in aperture coordinates.
pub const ClearRect = struct { rect: Rect, target: Target };

pub const Frame = struct {
    refs: std.atomic.Value(u32) = .init(1),
    gpa: std.mem.Allocator,
    canvas: raster.Canvas,
    clears: std.ArrayList(ClearRect) = .empty,
    /// One bit per tile, row-major: the tile has a pixel that is not transparent.
    occupied: std.DynamicBitSetUnmanaged,
    tiles_x: u32,
    tiles_y: u32,

    pub fn create(gpa: std.mem.Allocator, w: u32, h: u32) !*Frame {
        const f = try gpa.create(Frame);
        errdefer gpa.destroy(f);
        var canvas = try raster.Canvas.init(gpa, w, h);
        errdefer canvas.deinit(gpa);
        const tx = (w + tile - 1) / tile;
        const ty = (h + tile - 1) / tile;
        f.* = .{
            .gpa = gpa,
            .canvas = canvas,
            .occupied = try .initEmpty(gpa, tx * ty),
            .tiles_x = tx,
            .tiles_y = ty,
        };
        return f;
    }

    pub fn ref(f: *Frame) void {
        _ = f.refs.fetchAdd(1, .monotonic);
    }

    pub fn unref(f: *Frame) void {
        if (f.refs.fetchSub(1, .acq_rel) != 1) return;
        const gpa = f.gpa;
        f.canvas.deinit(gpa);
        f.clears.deinit(gpa);
        f.occupied.deinit(gpa);
        gpa.destroy(f);
    }

    /// True if only the caller holds it (the overlay is done with it).
    pub fn unshared(f: *Frame) bool {
        return f.refs.load(.acquire) == 1;
    }

    fn tileRect(f: *const Frame, tx: u32, ty: u32) Rect {
        const r: Rect = .{ .x = @intCast(tx * tile), .y = @intCast(ty * tile), .w = tile, .h = tile };
        return r.intersect(f.canvas.bounds()).?;
    }

    /// Makes the frame empty for a new rendering, clearing only the tiles that were drawn.
    pub fn reset(f: *Frame) void {
        var it = f.occupied.iterator(.{});
        while (it.next()) |i| f.canvas.clear(f.canvas.bounds(), f.tileRect(@intCast(i % f.tiles_x), @intCast(i / f.tiles_x)));
        f.occupied.unsetAll();
        f.clears.clearRetainingCapacity();
    }

    /// Records which tiles hold anything, once the frame is rendered.
    pub fn finish(f: *Frame) void {
        f.occupied.unsetAll();
        for (0..f.tiles_y) |ty| for (0..f.tiles_x) |tx| {
            const r = f.tileRect(@intCast(tx), @intCast(ty));
            const used = for (@intCast(r.y)..@intCast(r.bottom())) |y| {
                const line = f.canvas.row(y)[@intCast(r.x)..@intCast(r.right())];
                if (for (line) |p| {
                    if (p[3] != 0) break true;
                } else false) break true;
            } else false;
            if (used) f.occupied.set(ty * f.tiles_x + tx);
        };
    }

    /// Adds a clear rectangle: the graphics drawn so far are cleared there (§7.8.4.1).
    pub fn clearRect(f: *Frame, clip: Rect, r: Rect, target: Target) !void {
        const c = clip.intersect(r) orelse return;
        f.canvas.clear(f.canvas.bounds(), c);
        try f.clears.append(f.gpa, .{ .rect = c, .target = target });
    }

    /// The occupied part of the frame as rectangles: runs of occupied tiles in each row of tiles.
    pub fn spans(f: *const Frame, gpa: std.mem.Allocator) ![]Rect {
        var out: std.ArrayList(Rect) = .empty;
        errdefer out.deinit(gpa);
        for (0..f.tiles_y) |ty| {
            var tx: u32 = 0;
            while (tx < f.tiles_x) {
                if (!f.occupied.isSet(ty * f.tiles_x + tx)) {
                    tx += 1;
                    continue;
                }
                const first = tx;
                while (tx < f.tiles_x and f.occupied.isSet(ty * f.tiles_x + tx)) tx += 1;
                const a = f.tileRect(first, @intCast(ty));
                const b = f.tileRect(tx - 1, @intCast(ty));
                try out.append(gpa, .{ .x = a.x, .y = a.y, .w = b.right() - a.x, .h = a.h });
            }
        }
        return out.toOwnedSlice(gpa);
    }
};

/// Zeroes the alpha of the pixels of a region at `at` (`w`×`h`, `pitch` bytes per row, alpha byte `alpha_of`
/// in each `bpp`-byte pixel) that fall in the clear rectangles holing this plane. `sub_video`: the sub video
/// plane (only `main` targets reach it), else the sub-picture plane (every clear rectangle does).
pub fn punch(px: []u8, pitch: usize, bpp: usize, alpha_of: usize, at: Rect, clears: []const ClearRect, sub_video: bool) void {
    for (clears) |c| {
        if (sub_video and c.target != .main) continue;
        const h = at.intersect(c.rect) orelse continue;
        for (@intCast(h.y - at.y)..@intCast(h.bottom() - at.y)) |y| {
            for (@intCast(h.x - at.x)..@intCast(h.right() - at.x)) |x| px[y * pitch + x * bpp + alpha_of] = 0;
        }
    }
}

/// Like `punch` for a separate alpha plane (YUVA regions).
pub fn punchPlane(alpha: []u8, pitch: usize, at: Rect, clears: []const ClearRect, sub_video: bool) void {
    punch(alpha, pitch, 1, 0, at, clears, sub_video);
}

// ---- the cursor ---------------------------------------------------------------------------------------------

/// The maximum size of a cursor image (Vol. 1 §4.3.13.3.1).
pub const max_cursor = 256;

/// A refcounted cursor image.
pub const Image = struct {
    refs: std.atomic.Value(u32) = .init(1),
    gpa: std.mem.Allocator,
    canvas: raster.Canvas,

    pub fn create(gpa: std.mem.Allocator, w: u32, h: u32) !*Image {
        const im = try gpa.create(Image);
        errdefer gpa.destroy(im);
        im.* = .{ .gpa = gpa, .canvas = try .init(gpa, w, h) };
        return im;
    }

    pub fn ref(im: *Image) void {
        _ = im.refs.fetchAdd(1, .monotonic);
    }

    pub fn unref(im: *Image) void {
        if (im.refs.fetchSub(1, .acq_rel) != 1) return;
        im.canvas.deinit(im.gpa);
        im.gpa.destroy(im);
    }
};

pub const Cursor = struct {
    /// Position of the hot spot, in canvas coordinates.
    x: i32 = 0,
    y: i32 = 0,
    hot_x: i32 = 0,
    hot_y: i32 = 0,
    /// null: the player's default image.
    image: ?*Image = null,
    /// The player moves it with the mouse (`enable`), and shows it (`visible`). Both start false (Table W-6).
    enabled: bool = false,
    visible: bool = false,
    region: Rect,

    pub fn init(aperture_w: u32, aperture_h: u32) Cursor {
        return .{ .region = .{ .x = 0, .y = 0, .w = @intCast(aperture_w), .h = @intCast(aperture_h) } };
    }

    /// Moves the hot spot to (x, y), kept inside the region.
    pub fn moveTo(c: *Cursor, x: i32, y: i32) void {
        c.x = std.math.clamp(x, c.region.x, c.region.right() - 1);
        c.y = std.math.clamp(y, c.region.y, c.region.bottom() - 1);
    }

    /// Changes the region (setRegion); a cursor outside it moves to its origin.
    pub fn setRegion(c: *Cursor, r: Rect) void {
        c.region = r;
        if (!r.contains(c.x, c.y)) {
            c.x = r.x;
            c.y = r.y;
        }
    }

    /// Where the image is drawn.
    pub fn imageRect(c: Cursor, im: *const Image) Rect {
        return .{ .x = c.x - c.hot_x, .y = c.y - c.hot_y, .w = @intCast(im.canvas.w), .h = @intCast(im.canvas.h) };
    }
};

/// The player's default cursor: an arrow with its hot spot at (0, 0).
pub fn defaultCursor(gpa: std.mem.Allocator) !*Image {
    // Rows of the arrow: '#' outline, '.' fill.
    const shape = [_][]const u8{
        "#",
        "##",
        "#.#",
        "#..#",
        "#...#",
        "#....#",
        "#.....#",
        "#......#",
        "#.......#",
        "#........#",
        "#.........#",
        "#..........#",
        "#......#####",
        "#...#..#",
        "#..##..#",
        "#.#  #..#",
        "##   #..#",
        "#     #..#",
        "      #..#",
        "       ##",
    };
    const scale = 2; // a 1080-line aperture is usually seen scaled down
    const im = try Image.create(gpa, 12 * scale, shape.len * scale);
    for (shape, 0..) |line, y| for (line, 0..) |ch, x| {
        const p: raster.Px = switch (ch) {
            '#' => .{ 0, 0, 0, 255 },
            '.' => .{ 255, 255, 255, 255 },
            else => continue,
        };
        for (0..scale) |dy| for (0..scale) |dx| {
            im.canvas.px[(y * scale + dy) * im.canvas.w + x * scale + dx] = p;
        };
    };
    return im;
}

// ---- tests --------------------------------------------------------------------------------------------------

const testing = std.testing;

test "frame occupancy and spans" {
    const gpa = testing.allocator;
    const f = try Frame.create(gpa, 200, 130); // 4×3 tiles, the last ones partial
    defer f.unref();
    const all = f.canvas.bounds();
    f.canvas.fill(all, .{ .x = 10, .y = 10, .w = 100, .h = 4 }, .{ .r = 1, .g = 1, .b = 1 }); // tiles (0,0), (1,0)
    f.canvas.fill(all, .{ .x = 195, .y = 129, .w = 5, .h = 1 }, .{ .r = 1, .g = 1, .b = 1 }); // tile (3,2)
    f.finish();
    const s = try f.spans(gpa);
    defer gpa.free(s);
    try testing.expectEqual(2, s.len);
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 128, .h = 64 }, s[0]);
    try testing.expectEqual(Rect{ .x = 192, .y = 128, .w = 8, .h = 2 }, s[1]);
    // reset clears what was drawn.
    f.reset();
    try testing.expectEqual(raster.Px{ 0, 0, 0, 0 }, f.canvas.at(50, 12));
    f.finish();
    try testing.expectEqual(0, f.occupied.count());
}

test "clear rectangles punch the lower planes" {
    const gpa = testing.allocator;
    const f = try Frame.create(gpa, 64, 64);
    defer f.unref();
    const all = f.canvas.bounds();
    f.canvas.fill(all, all, .{ .r = 9, .g = 9, .b = 9 });
    try f.clearRect(all, .{ .x = 4, .y = 4, .w = 4, .h = 4 }, .sub);
    try f.clearRect(all, .{ .x = 60, .y = 60, .w = 10, .h = 10 }, .main); // clipped to the canvas
    try testing.expectEqual(raster.Px{ 0, 0, 0, 0 }, f.canvas.at(5, 5));
    try testing.expectEqual(Rect{ .x = 60, .y = 60, .w = 4, .h = 4 }, f.clears.items[1].rect);

    // A 2-pixel-wide RGBA region at (3, 5): x = 4 is in the `sub` hole.
    var px: [8]u8 = @splat(255);
    punch(&px, 8, 4, 3, .{ .x = 3, .y = 5, .w = 2, .h = 1 }, f.clears.items, false);
    try testing.expectEqual(@as(u8, 255), px[3]);
    try testing.expectEqual(@as(u8, 0), px[7]);
    // The sub video plane only gets `main` holes.
    px = @splat(255);
    punch(&px, 8, 4, 3, .{ .x = 3, .y = 5, .w = 2, .h = 1 }, f.clears.items, true);
    try testing.expectEqual(@as(u8, 255), px[7]);
}

test "cursor" {
    var c = Cursor.init(1920, 1080);
    c.moveTo(5000, -3);
    try testing.expectEqual(@as(i32, 1919), c.x);
    try testing.expectEqual(@as(i32, 0), c.y);
    c.setRegion(.{ .x = 100, .y = 100, .w = 10, .h = 10 });
    try testing.expectEqual(@as(i32, 100), c.x);
    const im = try defaultCursor(testing.allocator);
    defer im.unref();
    try testing.expectEqual(raster.Px{ 0, 0, 0, 255 }, im.canvas.at(0, 0));
    try testing.expectEqual(raster.Px{ 255, 255, 255, 255 }, im.canvas.at(2 * 1, 2 * 2));
    try testing.expectEqual(Rect{ .x = 100, .y = 100, .w = 24, .h = 40 }, c.imageRect(im));
}
