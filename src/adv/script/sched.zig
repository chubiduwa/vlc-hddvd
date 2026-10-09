//! The application scheduler's queue (HD DVD Vol. 3 §8.5): work items with a begin and an end time on one of
//! the application's clocks (title, application, page). At each tick the items due (begin at or before the
//! clock) are marked; the marked ones are then run in order, the late ones (end passed) dropped. Items added
//! while the marked ones run wait for the next tick, whatever their begin time, so a tick always ends.
//!
//! Marked items run in the order they were queued (the spec orders by begin time first; items with different
//! clocks cannot be compared, and the items due in one tick are run in that tick anyway).
//! No VLC dependency.

const std = @import("std");

pub const Clock = enum { title, app, page };

/// The clocks at a tick: title time in frames, application and page time in ticks.
pub const Now = struct {
    title: u64,
    app: u64,
    page: u64,

    pub fn of(n: Now, clock: Clock) u64 {
        return switch (clock) {
            .title => n.title,
            .app => n.app,
            .page => n.page,
        };
    }
};

pub fn Queue(comptime Job: type) type {
    return struct {
        const Self = @This();

        pub const Item = struct {
            job: Job,
            clock: Clock = .app,
            begin: u64 = 0,
            /// Dropped once its clock reaches this (null: never).
            end: ?u64 = null,
            seq: u64 = 0,
        };

        items: std.ArrayList(Item) = .empty,
        marked: std.ArrayList(Item) = .empty,
        /// The next marked item to run.
        next_marked: usize = 0,
        seq: u64 = 0,

        pub fn deinit(q: *Self, gpa: std.mem.Allocator) void {
            q.items.deinit(gpa);
            q.marked.deinit(gpa);
        }

        pub fn push(q: *Self, gpa: std.mem.Allocator, item: Item) !void {
            var it = item;
            it.seq = q.seq;
            q.seq += 1;
            try q.items.append(gpa, it);
        }

        /// Marks the items due at `now`, in the order they were queued.
        pub fn mark(q: *Self, gpa: std.mem.Allocator, now: Now) !void {
            q.marked.clearRetainingCapacity();
            q.next_marked = 0;
            var i: usize = 0;
            while (i < q.items.items.len) {
                const it = q.items.items[i];
                if (it.begin <= now.of(it.clock)) {
                    try q.marked.append(gpa, it);
                    _ = q.items.orderedRemove(i);
                } else i += 1;
            }
        }

        /// The next marked item to run at `now`, or null when the tick's are done. Late items are dropped
        /// through `drop` (it frees their job).
        pub fn next(q: *Self, now: Now, ctx: anytype, comptime drop: fn (@TypeOf(ctx), Job) void) ?Job {
            while (q.next_marked < q.marked.items.len) {
                const it = q.marked.items[q.next_marked];
                q.next_marked += 1;
                if (it.end) |e| if (now.of(it.clock) >= e) {
                    drop(ctx, it.job);
                    continue;
                };
                return it.job;
            }
            return null;
        }

        /// Removes the items for which `pred` is true (a timer stopped, the page clock reset), unmarked or not
        /// yet run; `drop` frees their job.
        pub fn removeIf(q: *Self, ctx: anytype, comptime pred: fn (@TypeOf(ctx), *const Item) bool, comptime drop: fn (@TypeOf(ctx), Job) void) void {
            var i: usize = 0;
            while (i < q.items.items.len) {
                if (pred(ctx, &q.items.items[i])) {
                    drop(ctx, q.items.items[i].job);
                    _ = q.items.orderedRemove(i);
                } else i += 1;
            }
            i = q.next_marked;
            while (i < q.marked.items.len) {
                if (pred(ctx, &q.marked.items[i])) {
                    drop(ctx, q.marked.items[i].job);
                    _ = q.marked.orderedRemove(i);
                } else i += 1;
            }
        }

        pub fn len(q: *const Self) usize {
            return q.items.items.len + (q.marked.items.len - q.next_marked);
        }
    };
}

// ---- tests ------------------------------------------------------------------------------------------------------

const t = std.testing;

fn noDrop(_: *std.ArrayList(u32), _: u32) void {}

fn logDrop(l: *std.ArrayList(u32), j: u32) void {
    l.append(t.allocator, j + 100) catch {};
}

test "marking, order, late items and new items wait" {
    var q: Queue(u32) = .{};
    defer q.deinit(t.allocator);
    var dropped: std.ArrayList(u32) = .empty;
    defer dropped.deinit(t.allocator);
    try q.push(t.allocator, .{ .job = 1, .clock = .app, .begin = 5 });
    try q.push(t.allocator, .{ .job = 2, .clock = .title, .begin = 0 });
    try q.push(t.allocator, .{ .job = 3, .clock = .app, .begin = 2, .end = 4 });
    try q.push(t.allocator, .{ .job = 4, .clock = .page, .begin = 9 });

    const now: Now = .{ .title = 0, .app = 5, .page = 3 };
    try q.mark(t.allocator, now);
    try t.expectEqual(@as(?u32, 1), q.next(now, &dropped, logDrop));
    // Queued while the marked ones run: next tick.
    try q.push(t.allocator, .{ .job = 5, .clock = .app, .begin = 0 });
    try t.expectEqual(@as(?u32, 2), q.next(now, &dropped, logDrop));
    try t.expectEqual(@as(?u32, null), q.next(now, &dropped, logDrop)); // 3 is late
    try t.expectEqualSlices(u32, &.{103}, dropped.items);
    try t.expectEqual(2, q.len());

    const later: Now = .{ .title = 1, .app = 6, .page = 9 };
    try q.mark(t.allocator, later);
    try t.expectEqual(@as(?u32, 4), q.next(later, &dropped, logDrop));
    try t.expectEqual(@as(?u32, 5), q.next(later, &dropped, logDrop));
    try t.expectEqual(0, q.len());
}

test "removing items" {
    var q: Queue(u32) = .{};
    defer q.deinit(t.allocator);
    var dropped: std.ArrayList(u32) = .empty;
    defer dropped.deinit(t.allocator);
    for (0..4) |i| try q.push(t.allocator, .{ .job = @intCast(i), .clock = if (i % 2 == 0) .page else .app });
    const now: Now = .{ .title = 0, .app = 0, .page = 0 };
    try q.mark(t.allocator, now);
    _ = q.next(now, &dropped, logDrop);
    q.removeIf(&dropped, struct {
        fn f(_: *std.ArrayList(u32), it: *const Queue(u32).Item) bool {
            return it.clock == .page;
        }
    }.f, logDrop);
    try t.expectEqualSlices(u32, &.{102}, dropped.items);
    try t.expectEqual(@as(?u32, 1), q.next(now, &dropped, noDrop));
    try t.expectEqual(@as(?u32, 3), q.next(now, &dropped, noDrop));
}
