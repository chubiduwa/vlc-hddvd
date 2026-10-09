//! Tests only: a lone script context with in-memory files (a disc, the Resource Area, the API Managed Area and
//! a persistent storage device), and a pump for its work items. Deliveries go to the script itself.

const std = @import("std");
const js = @import("js.zig");
const host = @import("host.zig");
const files_mod = @import("files.zig");
const memfs = @import("../memfs.zig");
const pstore = @import("../pstore.zig");

const t = std.testing;

pub const provider = "11111111-2222-3333-4444-555555555555";

pub const Env = struct {
    world: *host.World,
    script: *host.Script,
    backend: files_mod.TestBackend,
    temp: memfs.Fs,
    store: pstore.Store,
    files: files_mod.Files,

    /// Heap-allocated (the files and the script keep pointers into it).
    pub fn create() !*Env {
        const e = try t.allocator.create(Env);
        errdefer t.allocator.destroy(e);
        e.backend = .init(t.allocator);
        e.temp = .init(t.allocator);
        e.store = try pstore.Store.init(t.allocator, provider.*, 7);
        e.files = .{ .gpa = t.allocator, .temp = &e.temp, .store = &e.store, .backend = e.backend.backend() };
        e.world = try host.World.create(t.allocator);
        e.world.files = &e.files;
        e.world.log = print;
        e.world.diagnostics_unlocked = true;
        e.script = try host.Script.create(e.world, null);
        e.script.cx.runScript(prelude, "cb.js") catch return error.JsTestFailed;
        return e;
    }

    pub fn destroy(e: *Env) void {
        e.script.destroy();
        e.world.destroy();
        e.store.deinit();
        e.temp.deinit();
        e.backend.deinit();
        t.allocator.destroy(e);
    }

    fn print(_: *anyopaque, msg: []const u8) void {
        std.debug.print("{s}\n", .{msg});
    }

    /// Runs `src` (after the assertion prelude), then the work items until none are left.
    pub fn run(e: *Env, src: []const u8, name: [:0]const u8) !void {
        try js.testing.run(e.script.cx, src, name);
        try e.pump();
    }

    /// Ticks: advances the clocks by one tick and runs the timers and the work items due, `n` times or until
    /// nothing is queued (n == 0).
    pub fn ticks(e: *Env, n: usize) !void {
        var i: usize = 0;
        while (n == 0 or i < n) : (i += 1) {
            e.world.tick += 1;
            e.world.title_time += 1;
            e.world.now_us += 16_683;
            e.backend.time += 17;
            const s = e.script;
            s.runTimers();
            const now: @import("sched.zig").Now = .{ .title = e.world.title_time, .app = s.appTicks(), .page = s.appTicks() };
            try s.queue.mark(t.allocator, now);
            var any = false;
            while (s.queue.next(now, s, dropJob)) |job| {
                any = true;
                switch (job) {
                    .delivery => |d| {
                        d.visited.append(d.arena.allocator(), s.uid) catch {};
                        _ = s.deliver(d, null);
                        d.destroy();
                    },
                    else => s.run(job),
                }
            }
            if (n == 0 and !any and s.queue.len() == 0) break;
            if (i > 1000) return error.Runaway;
        }
        const g = e.script.cx.global();
        defer e.script.cx.free(g);
        // A failure inside a callback is recorded in __failure by the tests.
        const f = try e.script.cx.get(g, "__failure");
        defer e.script.cx.free(f);
        if (!js.c.JS_IsUndefined(f)) {
            const msg = try e.script.cx.toStringAlloc(t.allocator, f);
            defer t.allocator.free(msg);
            std.debug.print("callback failure: {s}\n", .{msg});
            return error.JsTestFailed;
        }
    }

    pub fn pump(e: *Env) !void {
        try e.ticks(0);
    }

    fn dropJob(s: *host.Script, job: host.Job) void {
        s.dropJob(job);
    }
};

/// Wraps a callback so that an assertion failing inside it is recorded (callbacks' exceptions are only
/// reported): `cb(function () { … })`.
pub const prelude =
    \\var __failure;
    \\function cb(f) { return function () { try { return f.apply(this, arguments); } catch (e) { if (__failure === undefined) { __failure = String(e) + (e && e.stack ? "\n" + e.stack : ""); } } }; }
    \\
;
