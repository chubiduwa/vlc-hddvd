//! The HDi engine core (HD DVD Vol. 3 §7.2–7.3, Vol. 1 §4.3.13.3.1): application ticks and their clocks, the
//! queues to and from the demux, the Cursor Manager, and the scene that renders the graphics plane. It is
//! single-threaded and has no VLC dependency: host.zig runs it on its own thread (applications run while VLC
//! is paused, when the demux is not called), feeding it events and the time.
//!
//! Ticks (§7.2.3.1) come at the playlist's tick rate (tickBase); a title's tickBaseDivisor keeps one in n.
//! Each carries three clocks:
//! - application: ticks since the engine started (per application from Phase 5); always increases, also
//!   while paused;
//! - page: ticks since the current page (scene) started;
//! - title: the title time on screen, in frames; it stops while paused and jumps with the Title Timeline.
//! A late host skips ticks rather than replaying them: the application clock never repeats a value, but it
//! can skip some.

const std = @import("std");
const planes = @import("../planes.zig");
const raster = @import("../raster.zig");
pub const keys = @import("keys.zig");

pub const PlayState = enum { playing, paused, stopped };

pub const Point = struct { x: i32, y: i32 };

/// From the demux and the user to the engine.
pub const Event = union(enum) {
    /// A title starts (null: the First Play title); `duration` in frames.
    title_begin: struct { title: ?u16, duration: u64, tick_divisor: u32 = 1 },
    title_end,
    /// The Title Timeline jumped to this title time (frames).
    jump: u64,
    play_state: PlayState,
    /// Mouse position, in aperture coordinates; the button is mouse button 1 (VK_MOUSE_1).
    mouse_move: Point,
    mouse_down: Point,
    mouse_up: Point,
    /// A user input key (Annex V).
    key_down: keys.Key,
    key_up: keys.Key,
};

/// From the engine to the demux.
pub const Command = union(enum) {
    /// Plays the title with this index (Player.playlist.titles[n].jump).
    play_title: u16,
    /// Jumps within the current title to a title time (frames).
    jump: u64,
};

pub const Clocks = struct {
    /// Ticks (at the tick rate, divisor included in the count).
    app: u64,
    page: u64,
    /// Frames.
    title: u64,
};

/// Ticks per second as a fraction: 60 and 24 run at 1000/1001 of that, like the 60fps time base.
pub const TickRate = struct {
    num: u64,
    den: u64,

    pub fn of(tick_base: u8) TickRate {
        return switch (tick_base) {
            50 => .{ .num = 50, .den = 1 },
            24 => .{ .num = 24000, .den = 1001 },
            else => .{ .num = 60000, .den = 1001 },
        };
    }

    /// Ticks elapsed in `t_us` microseconds (rounded down).
    pub fn ticks(r: TickRate, t_us: i64) u64 {
        return @as(u64, @intCast(@max(t_us, 0))) * r.num / (r.den * 1_000_000);
    }

    /// When tick `n` comes, in microseconds (rounded up).
    pub fn us(r: TickRate, n: u64) i64 {
        return @intCast((n * r.den * 1_000_000 + r.num - 1) / r.num);
    }
};

/// What renders the graphics plane: a test page now, the applications' markup from Phase 4.
pub const Scene = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Advances to the tick; true if what it draws changed.
        tick: *const fn (ctx: *anyopaque, e: *Engine, c: Clocks) bool,
        /// Takes a user input event, in the tick that processes it (before `tick`).
        input: ?*const fn (ctx: *anyopaque, e: *Engine, ev: Event) void = null,
        /// Draws into an empty frame.
        render: *const fn (ctx: *anyopaque, e: *Engine, f: *planes.Frame) void,
        deinit: *const fn (ctx: *anyopaque, gpa: std.mem.Allocator) void,
    };
};

pub const Step = struct {
    /// A tick was processed.
    ticked: bool = false,
    /// The graphics plane must be rendered again.
    redraw: bool = false,
    /// The cursor moved or changed.
    cursor: bool = false,
};

pub const Engine = struct {
    gpa: std.mem.Allocator,
    aperture_w: u32,
    aperture_h: u32,
    rate: TickRate,
    divisor: u32 = 1,

    /// When the application clock started (µs), and the page clock.
    start: ?i64 = null,
    page_start: i64 = 0,
    /// The last tick processed (counted from `start`).
    last_tick: ?u64 = null,

    /// The current title (null: the First Play title), once one has begun.
    title: ?u16 = null,
    in_title: bool = false,
    title_duration: u64 = 0,
    title_time: u64 = 0,
    play_state: PlayState = .playing,

    inbox: std.ArrayList(Event) = .empty,
    outbox: std.ArrayList(Command) = .empty,
    cursor: planes.Cursor,
    cursor_changed: bool = false,
    scene: ?Scene = null,
    /// The graphics plane must be rendered at the next tick.
    dirty: bool = true,

    pub fn init(gpa: std.mem.Allocator, aperture_w: u32, aperture_h: u32, tick_base: u8) Engine {
        return .{
            .gpa = gpa,
            .aperture_w = aperture_w,
            .aperture_h = aperture_h,
            .rate = .of(tick_base),
            .cursor = .init(aperture_w, aperture_h),
        };
    }

    pub fn deinit(e: *Engine) void {
        if (e.scene) |s| s.vtable.deinit(s.ctx, e.gpa);
        e.inbox.deinit(e.gpa);
        e.outbox.deinit(e.gpa);
    }

    /// Replaces the scene (the old one is freed); its page clock starts at `now`.
    pub fn setScene(e: *Engine, s: ?Scene, now: i64) void {
        if (e.scene) |old| old.vtable.deinit(old.ctx, e.gpa);
        e.scene = s;
        e.page_start = now;
        e.dirty = true;
    }

    /// Queues an event for the next tick. The Cursor Manager follows the mouse at once.
    pub fn post(e: *Engine, ev: Event) !void {
        switch (ev) {
            .mouse_move, .mouse_down, .mouse_up => |p| if (e.cursor.enabled) {
                const old = e.cursor;
                e.cursor.moveTo(p.x, p.y);
                if (old.x != e.cursor.x or old.y != e.cursor.y) e.cursor_changed = true;
            } else return, // no mouse events while the cursor is disabled (Annex Z.5.5.2 enable)
            else => {},
        }
        try e.inbox.append(e.gpa, ev);
    }

    /// Queues a command for the demux.
    pub fn command(e: *Engine, c: Command) void {
        e.outbox.append(e.gpa, c) catch {};
    }

    /// When the next tick to process is due, in µs (`now` if it is already).
    pub fn nextTick(e: *const Engine, now: i64) i64 {
        const s = e.start orelse return now;
        const div: u64 = e.divisor;
        const next = if (e.last_tick) |t| t + div else 0;
        return @max(now, s + e.rate.us(next));
    }

    /// Processes the tick due at `now` (µs, mdate()) if there is one, with title time `title_time` (frames)
    /// on screen.
    pub fn step(e: *Engine, now: i64, title_time: u64) Step {
        var r: Step = .{ .cursor = e.cursor_changed };
        e.cursor_changed = false;
        const s = e.start orelse blk: {
            e.start = now;
            e.page_start = now;
            break :blk now;
        };
        const div: u64 = e.divisor;
        const n = e.rate.ticks(now - s) / div * div; // the latest tick kept by the divisor
        if (e.last_tick) |t| if (n <= t) return r;
        e.last_tick = n;
        r.ticked = true;

        // 1. Events, in order (the script handler queue from Phase 5).
        for (e.inbox.items) |ev| {
            e.handle(ev);
            if (e.scene) |sc| if (sc.vtable.input) |f| f(sc.ctx, e, ev);
        }
        e.inbox.clearRetainingCapacity();
        if (e.play_state == .playing) e.title_time = title_time;
        const clocks: Clocks = .{ .app = n, .page = e.rate.ticks(now - e.page_start), .title = e.title_time };
        // 2.–5. Animations and layout; redraw on change.
        if (e.scene) |sc| if (sc.vtable.tick(sc.ctx, e, clocks)) {
            e.dirty = true;
        };
        r.redraw = e.dirty;
        e.dirty = false;
        if (e.cursor_changed) {
            r.cursor = true;
            e.cursor_changed = false;
        }
        return r;
    }

    fn handle(e: *Engine, ev: Event) void {
        switch (ev) {
            .title_begin => |t| {
                e.title = t.title;
                e.in_title = true;
                e.title_duration = t.duration;
                e.title_time = 0;
                if (t.tick_divisor != e.divisor) {
                    e.divisor = @max(1, t.tick_divisor);
                    if (e.last_tick) |l| e.last_tick = l / e.divisor * e.divisor;
                }
                e.dirty = true;
            },
            .title_end => {},
            .jump => |t| e.title_time = t,
            .play_state => |p| e.play_state = p,
            .mouse_move, .mouse_down, .mouse_up, .key_down, .key_up => {},
        }
    }

    /// Renders the scene into `f` (made empty first), then records which tiles it uses.
    pub fn render(e: *Engine, f: *planes.Frame) void {
        f.reset();
        if (e.scene) |sc| sc.vtable.render(sc.ctx, e, f);
        f.finish();
    }
};

// ---- tests --------------------------------------------------------------------------------------------------

const testing = std.testing;

test "tick rates" {
    const r = TickRate.of(60);
    try testing.expectEqual(@as(u64, 59), r.ticks(1_000_000)); // 59.94 per second
    try testing.expectEqual(@as(u64, 60), r.ticks(1_001_000));
    try testing.expectEqual(@as(i64, 1_001_000), r.us(60));
    try testing.expectEqual(@as(u64, 50), TickRate.of(50).ticks(1_000_000));
    try testing.expectEqual(@as(i64, 41709), TickRate.of(24).us(1));
}

const Counter = struct {
    ticks: u32 = 0,
    last: Clocks = undefined,
    renders: u32 = 0,

    fn tick(ctx: *anyopaque, _: *Engine, c: Clocks) bool {
        const self: *Counter = @ptrCast(@alignCast(ctx));
        self.ticks += 1;
        self.last = c;
        return c.app % 2 == 0;
    }

    fn render(ctx: *anyopaque, _: *Engine, f: *planes.Frame) void {
        const self: *Counter = @ptrCast(@alignCast(ctx));
        self.renders += 1;
        f.canvas.fill(f.canvas.bounds(), .{ .x = 0, .y = 0, .w = 1, .h = 1 }, .{ .r = 1, .g = 2, .b = 3 });
    }

    fn deinit(_: *anyopaque, _: std.mem.Allocator) void {}

    const vtable: Scene.VTable = .{ .tick = tick, .render = render, .deinit = deinit };
};

test "ticks, clocks and pause" {
    var e = Engine.init(testing.allocator, 1920, 1080, 50);
    defer e.deinit();
    var c: Counter = .{};
    e.setScene(.{ .ctx = &c, .vtable = &Counter.vtable }, 0);

    var s = e.step(1000, 0); // starts the clock: tick 0
    try testing.expect(s.ticked and s.redraw);
    try testing.expectEqual(@as(i64, 21000), e.nextTick(1000));
    s = e.step(5000, 0); // still tick 0
    try testing.expect(!s.ticked);
    s = e.step(21000, 7); // tick 1: odd, the scene did not change
    try testing.expect(s.ticked and !s.redraw);
    try testing.expectEqual(@as(u64, 7), c.last.title);

    // Paused: the title clock stops, the application clock goes on.
    try e.post(.{ .play_state = .paused });
    s = e.step(41000, 9);
    try testing.expectEqual(@as(u64, 2), c.last.app);
    try testing.expectEqual(@as(u64, 7), c.last.title);
    // A late host skips ticks.
    _ = e.step(201000, 9);
    try testing.expectEqual(@as(u64, 10), c.last.app);
    try testing.expectEqual(@as(u32, 4), c.ticks);
    // A jump while paused moves the title clock.
    try e.post(.{ .jump = 500 });
    _ = e.step(221000, 9);
    try testing.expectEqual(@as(u64, 500), c.last.title);

    // The page clock restarts with a new scene.
    var c2: Counter = .{};
    e.setScene(.{ .ctx = &c2, .vtable = &Counter.vtable }, 221000);
    _ = e.step(261000, 0);
    try testing.expectEqual(@as(u64, 2), c2.last.page);
    try testing.expectEqual(@as(u64, 13), c2.last.app);
}

test "tick divisor" {
    var e = Engine.init(testing.allocator, 1920, 1080, 50);
    defer e.deinit();
    try e.post(.{ .title_begin = .{ .title = 1, .duration = 100, .tick_divisor = 3 } });
    _ = e.step(0, 0);
    try testing.expectEqual(@as(?u64, 0), e.last_tick);
    try testing.expectEqual(@as(i64, 60000), e.nextTick(0));
    try testing.expect(!e.step(40000, 0).ticked);
    try testing.expect(e.step(60000, 0).ticked);
    try testing.expectEqual(@as(?u64, 3), e.last_tick);
}

test "cursor follows the mouse only when enabled" {
    var e = Engine.init(testing.allocator, 1920, 1080, 60);
    defer e.deinit();
    try e.post(.{ .mouse_move = .{ .x = 10, .y = 20 } });
    try testing.expectEqual(0, e.inbox.items.len);
    e.cursor.enabled = true;
    try e.post(.{ .mouse_move = .{ .x = 10, .y = 20 } });
    try testing.expectEqual(@as(i32, 20), e.cursor.y);
    const s = e.step(0, 0);
    try testing.expect(s.cursor);
    try testing.expect(!e.step(1, 0).cursor);
}

test "render records the tiles drawn" {
    var e = Engine.init(testing.allocator, 128, 64, 60);
    defer e.deinit();
    var c: Counter = .{};
    e.setScene(.{ .ctx = &c, .vtable = &Counter.vtable }, 0);
    const f = try planes.Frame.create(testing.allocator, 128, 64);
    defer f.unref();
    e.render(f);
    try testing.expectEqual(@as(u32, 1), c.renders);
    try testing.expect(f.occupied.isSet(0) and !f.occupied.isSet(1));
    try testing.expectEqual(raster.Px{ 1, 2, 3, 255 }, f.canvas.at(0, 0));
}
