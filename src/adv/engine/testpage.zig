//! A graphics test page generated in code (--hddvd-test-page), to check the overlay before markup exists:
//! - the title clock as HH:MM:SS:FF and a progress bar: they stop while paused and jump on seeks;
//! - the application clock in seconds and a box sliding with it: they keep moving while paused;
//! - the play state;
//! - a clear rectangle (target main) cut into a panel: subtitles and the sub video do not show through it;
//! - the cursor, enabled (it follows the mouse) and visible.
//! No VLC dependency.

const std = @import("std");
const engine = @import("engine.zig");
const planes = @import("../planes.zig");
const raster = @import("../raster.zig");

const Rect = raster.Rect;

pub const TestPage = struct {
    /// Frames per second of the title time base.
    fps: u32,
    clocks: engine.Clocks = .{ .app = 0, .page = 0, .title = 0 },
    playing: bool = true,

    pub fn create(gpa: std.mem.Allocator, fps: u32) !engine.Scene {
        const t = try gpa.create(TestPage);
        t.* = .{ .fps = fps };
        return .{ .ctx = t, .vtable = &vtable };
    }

    const vtable: engine.Scene.VTable = .{ .tick = tick, .render = render, .deinit = deinit };

    fn tick(ctx: *anyopaque, e: *engine.Engine, c: engine.Clocks) bool {
        const t: *TestPage = @ptrCast(@alignCast(ctx));
        if (!e.cursor.enabled) {
            e.cursor.enabled = true;
            e.cursor.visible = true;
            e.cursor.moveTo(@intCast(e.aperture_w / 2), @intCast(e.aperture_h / 2));
            e.cursor_changed = true;
        }
        const playing = e.play_state == .playing;
        const changed = c.app != t.clocks.app or c.title != t.clocks.title or playing != t.playing;
        t.clocks = c;
        t.playing = playing;
        return changed;
    }

    fn render(ctx: *anyopaque, e: *engine.Engine, f: *planes.Frame) void {
        const t: *TestPage = @ptrCast(@alignCast(ctx));
        const cv = f.canvas;
        const all = cv.bounds();
        // Laid out for 1920×1080, scaled for 1280×720.
        const s: Scale = .{ .num = @intCast(e.aperture_w), .den = 1920 };
        const panel = s.rect(64, 820, 1100, 200);
        cv.fill(all, panel, .{ .r = 10, .g = 12, .b = 40, .a = 180 });

        // Title clock, as HH:MM:SS:FF.
        var buf: [32]u8 = undefined;
        const fr = t.clocks.title;
        const secs = fr / t.fps;
        const txt = std.fmt.bufPrint(&buf, "TITLE {d:0>2}:{d:0>2}:{d:0>2}:{d:0>2}", .{ secs / 3600, secs / 60 % 60, secs % 60, fr % t.fps }) catch "";
        text(cv, all, s.x(96), s.y(840), s.n(5), txt, .{ .r = 255, .g = 255, .b = 255 });
        // Application clock, in seconds.
        const app_s = @divTrunc(e.rate.us(t.clocks.app), 1_000_000);
        const txt2 = std.fmt.bufPrint(&buf, "APP {d}", .{app_s}) catch "";
        text(cv, all, s.x(760), s.y(840), s.n(5), txt2, .{ .r = 160, .g = 220, .b = 255 });

        // Progress through the title.
        const bar = s.rect(96, 930, 900, 24);
        cv.fill(all, bar, .{ .r = 255, .g = 255, .b = 255, .a = 90 });
        if (e.title_duration > 0) {
            const w: i32 = @intCast(@as(u64, @intCast(bar.w)) * @min(t.clocks.title, e.title_duration) / e.title_duration);
            cv.fill(all, .{ .x = bar.x, .y = bar.y, .w = w, .h = bar.h }, .{ .r = 80, .g = 200, .b = 80 });
        }
        // A box sliding with the application clock.
        const span: u64 = @intCast(bar.w - s.n(40));
        const bx = bar.x + @as(i32, @intCast(t.clocks.app * @as(u64, @intCast(s.n(6))) % span));
        cv.fill(all, .{ .x = bx, .y = s.y(970), .w = s.n(40), .h = s.n(40) }, .{ .r = 255, .g = 140, .b = 0, .a = 220 });

        // Play state: two bars or a triangle.
        const ix = s.x(1060);
        const iy = s.y(925);
        const ih = s.n(60);
        if (t.playing) {
            for (0..@intCast(ih)) |row| {
                const r: i32 = @intCast(row);
                const half = @divTrunc(ih, 2);
                const w = if (r < half) r else ih - r;
                cv.fill(all, .{ .x = ix, .y = iy + r, .w = w, .h = 1 }, .{ .r = 255, .g = 255, .b = 255 });
            }
        } else {
            cv.fill(all, .{ .x = ix, .y = iy, .w = s.n(18), .h = ih }, .{ .r = 255, .g = 255, .b = 255 });
            cv.fill(all, .{ .x = ix + s.n(30), .y = iy, .w = s.n(18), .h = ih }, .{ .r = 255, .g = 255, .b = 255 });
        }

        // A panel with a clear rectangle cut into it, framed.
        cv.fill(all, s.rect(1200, 800, 400, 240), .{ .r = 40, .g = 10, .b = 10, .a = 200 });
        const hole = s.rect(1240, 840, 320, 160);
        cv.fill(all, .{ .x = hole.x - 4, .y = hole.y - 4, .w = hole.w + 8, .h = hole.h + 8 }, .{ .r = 255, .g = 220, .b = 0 });
        f.clearRect(all, hole, .main) catch {};
    }

    fn deinit(ctx: *anyopaque, gpa: std.mem.Allocator) void {
        const t: *TestPage = @ptrCast(@alignCast(ctx));
        gpa.destroy(t);
    }
};

/// Scales 1920-wide layout coordinates to the aperture.
const Scale = struct {
    num: i32,
    den: i32,

    fn n(s: Scale, v: i32) i32 {
        return @max(1, @divTrunc(v * s.num, s.den));
    }
    fn x(s: Scale, v: i32) i32 {
        return @divTrunc(v * s.num, s.den);
    }
    const y = x;
    fn rect(s: Scale, rx: i32, ry: i32, w: i32, h: i32) Rect {
        return .{ .x = s.x(rx), .y = s.y(ry), .w = s.n(w), .h = s.n(h) };
    }
};

// ---- a 5×7 pixel font for the few characters the page uses ---------------------------------------------------

const Glyph = struct { ch: u8, rows: [7]u5 };

const font = [_]Glyph{
    .{ .ch = '0', .rows = .{ 0b01110, 0b10001, 0b10011, 0b10101, 0b11001, 0b10001, 0b01110 } },
    .{ .ch = '1', .rows = .{ 0b00100, 0b01100, 0b00100, 0b00100, 0b00100, 0b00100, 0b01110 } },
    .{ .ch = '2', .rows = .{ 0b01110, 0b10001, 0b00001, 0b00010, 0b00100, 0b01000, 0b11111 } },
    .{ .ch = '3', .rows = .{ 0b11111, 0b00010, 0b00100, 0b00010, 0b00001, 0b10001, 0b01110 } },
    .{ .ch = '4', .rows = .{ 0b00010, 0b00110, 0b01010, 0b10010, 0b11111, 0b00010, 0b00010 } },
    .{ .ch = '5', .rows = .{ 0b11111, 0b10000, 0b11110, 0b00001, 0b00001, 0b10001, 0b01110 } },
    .{ .ch = '6', .rows = .{ 0b00110, 0b01000, 0b10000, 0b11110, 0b10001, 0b10001, 0b01110 } },
    .{ .ch = '7', .rows = .{ 0b11111, 0b00001, 0b00010, 0b00100, 0b01000, 0b01000, 0b01000 } },
    .{ .ch = '8', .rows = .{ 0b01110, 0b10001, 0b10001, 0b01110, 0b10001, 0b10001, 0b01110 } },
    .{ .ch = '9', .rows = .{ 0b01110, 0b10001, 0b10001, 0b01111, 0b00001, 0b00010, 0b01100 } },
    .{ .ch = ':', .rows = .{ 0b00000, 0b01100, 0b01100, 0b00000, 0b01100, 0b01100, 0b00000 } },
    .{ .ch = 'A', .rows = .{ 0b01110, 0b10001, 0b10001, 0b11111, 0b10001, 0b10001, 0b10001 } },
    .{ .ch = 'E', .rows = .{ 0b11111, 0b10000, 0b10000, 0b11110, 0b10000, 0b10000, 0b11111 } },
    .{ .ch = 'I', .rows = .{ 0b01110, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b01110 } },
    .{ .ch = 'L', .rows = .{ 0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0b11111 } },
    .{ .ch = 'P', .rows = .{ 0b11110, 0b10001, 0b10001, 0b11110, 0b10000, 0b10000, 0b10000 } },
    .{ .ch = 'T', .rows = .{ 0b11111, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100 } },
};

fn glyph(ch: u8) ?*const [7]u5 {
    for (&font) |*g| if (g.ch == ch) return &g.rows;
    return null;
}

/// Draws `s` with its top left at (x, y), each font pixel `px`×`px`. Unknown characters are spaces.
pub fn text(cv: raster.Canvas, clip: Rect, x: i32, y: i32, px: i32, s: []const u8, color: raster.Color) void {
    var cx = x;
    for (s) |ch| {
        if (glyph(ch)) |rows| for (rows, 0..) |bits, ry| {
            for (0..5) |rx| {
                if ((bits >> @intCast(4 - rx)) & 1 == 0) continue;
                cv.fill(clip, .{ .x = cx + @as(i32, @intCast(rx)) * px, .y = y + @as(i32, @intCast(ry)) * px, .w = px, .h = px }, color);
            }
        };
        cx += 6 * px;
    }
}

// ---- tests --------------------------------------------------------------------------------------------------

const testing = std.testing;

test "the test page draws, animates and cuts its hole" {
    const gpa = testing.allocator;
    var e = engine.Engine.init(gpa, 1920, 1080, 60);
    defer e.deinit();
    e.setScene(try TestPage.create(gpa, 60), 0);
    try e.post(.{ .title_begin = .{ .title = 0, .duration = 6000 } });
    const s0 = e.step(0, 0);
    try testing.expect(s0.redraw and s0.cursor);
    try testing.expect(e.cursor.visible and e.cursor.enabled);

    const f = try planes.Frame.create(gpa, 1920, 1080);
    defer f.unref();
    e.render(f);
    try testing.expectEqual(1, f.clears.items.len);
    try testing.expectEqual(raster.Px{ 0, 0, 0, 0 }, f.canvas.at(1300, 900)); // in the hole
    try testing.expectEqual(@as(u8, 255), f.canvas.at(1237, 900)[3]); // its frame
    try testing.expect(f.canvas.at(70, 830)[3] > 0); // the panel
    try testing.expect(!f.occupied.isSet(0)); // the top left is empty

    // Paused, the application clock still moves the box.
    try e.post(.{ .play_state = .paused });
    try testing.expect(e.step(100_000, 30).redraw);
    try testing.expectEqual(@as(u64, 0), e.title_time);

    // The title clock text.
    var c = try raster.Canvas.init(gpa, 40, 10);
    defer c.deinit(gpa);
    text(c, c.bounds(), 0, 0, 1, "1:", .{ .r = 255, .g = 255, .b = 255 });
    try testing.expectEqual(@as(u8, 255), c.at(2, 0)[3]); // the top of the 1
    try testing.expectEqual(@as(u8, 255), c.at(7, 1)[3]); // the colon
    try testing.expectEqual(@as(u8, 0), c.at(0, 0)[3]);
}
