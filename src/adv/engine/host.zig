//! Runs the HDi engine (engine.zig) on a thread of its own: applications keep running while VLC is paused,
//! when the demux is not called, and scripts must never hold up the demux (HD DVD Vol. 3 §7.2.3: ticks are
//! received whatever the play state). The demux posts events and takes the engine's commands through
//! queues; the engine reads the title time from the Presentation's clock, polls the mouse, and publishes its
//! graphics frames and cursor to the overlay (overlay.zig).

const std = @import("std");
const vlc = @import("vlc");
const engine = @import("engine.zig");
const testpage = @import("testpage.zig");
const apps = @import("../markup/apps.zig");
const planes = @import("../planes.zig");
const present = @import("../present.zig");
const mix = @import("../mix.zig");
const fxout = @import("../fxout.zig");

const gpa = std.heap.c_allocator;

extern fn hddvd_now_us() i64;
extern fn hddvd_mouse_poll(m: ?*anyopaque, x: *c_int, y: *c_int) c_int;
extern fn hddvd_key_poll(m: ?*anyopaque) u32;
extern fn hddvd_input_pause(demux: *vlc.demux_t, paused: bool) void;
extern fn hddvd_aout_settings(demux: *vlc.demux_t, out: *fxout.Settings) void;

fn log(obj: *vlc.vlc_object_t, prio: c_int, src: std.builtin.SourceLocation, comptime fmt: [*:0]const u8, args: anytype) void {
    @call(.auto, vlc.vlc_Log, .{ obj, prio, "hddvd", src.file, @as(c_uint, src.line), src.fn_name, fmt } ++ args);
}

pub const Options = struct {
    tick_base: u8,
    /// Frames per second of the title time base.
    fps: u32,
    test_page: bool = false,
    /// The disc's applications (not with the test page).
    apps: ?apps.Config = null,
};

pub const Host = struct {
    /// The demux.
    obj: *vlc.vlc_object_t,
    pres: *present.Presentation,
    /// The demux's mouse handle (nav_glue.c), or null.
    mouse: ?*anyopaque,
    thread: vlc.vlc_thread_t = undefined,
    lock: vlc.vlc_mutex_t = undefined,
    wake: vlc.vlc_cond_t = undefined,

    // Under lock:
    stop: bool = false,
    events: std.ArrayList(engine.Event) = .empty,
    commands: std.ArrayList(engine.Command) = .empty,

    // The engine thread's own:
    eng: engine.Engine,
    /// Frames to render into: one shown, one being drawn, one spare while the overlay reads an old one.
    pool: [3]?*planes.Frame = @splat(null),
    /// Effect sounds started while VLC is paused.
    fx: fxout.Output = .{},

    pub fn create(obj: *vlc.vlc_object_t, pres: *present.Presentation, mouse: ?*anyopaque, opts: Options) !*Host {
        const h = try gpa.create(Host);
        errdefer gpa.destroy(h);
        h.* = .{
            .obj = obj,
            .pres = pres,
            .mouse = mouse,
            .eng = .init(gpa, pres.aperture_w, pres.aperture_h, opts.tick_base),
        };
        errdefer h.eng.deinit();
        if (opts.test_page) {
            h.eng.setScene(try testpage.TestPage.create(gpa, opts.fps), hddvd_now_us());
        } else if (opts.apps) |cfg| {
            var c = cfg;
            c.log = logApps;
            c.log_ctx = obj;
            h.eng.setScene(try apps.Apps.create(gpa, c, pres.aperture_w, pres.aperture_h), hddvd_now_us());
        }
        pres.ref();
        vlc.vlc_mutex_init(&h.lock);
        vlc.vlc_cond_init(&h.wake);
        if (vlc.vlc_clone(&h.thread, run, h, vlc.VLC_THREAD_PRIORITY_LOW) != 0) {
            vlc.vlc_cond_destroy(&h.wake);
            vlc.vlc_mutex_destroy(&h.lock);
            pres.unref();
            return error.ThreadFailed;
        }
        return h;
    }

    pub fn destroy(h: *Host) void {
        vlc.vlc_mutex_lock(&h.lock);
        h.stop = true;
        vlc.vlc_cond_signal(&h.wake);
        vlc.vlc_mutex_unlock(&h.lock);
        vlc.vlc_join(h.thread, null);
        h.fx.deinit();
        vlc.vlc_cond_destroy(&h.wake);
        vlc.vlc_mutex_destroy(&h.lock);
        h.pres.publishGraphics(null);
        var c = h.pres.cursor;
        c.visible = false;
        c.image = null;
        h.pres.setCursor(c);
        for (h.pool) |f| if (f) |x| x.unref();
        h.eng.deinit();
        h.events.deinit(gpa);
        h.commands.deinit(gpa);
        h.pres.unref();
        gpa.destroy(h);
    }

    fn logApps(ctx: *anyopaque, msg: []const u8) void {
        const obj: *vlc.vlc_object_t = @ptrCast(@alignCast(ctx));
        log(obj, vlc.VLC_MSG_DBG, @src(), "%.*s", .{ @as(c_int, @intCast(msg.len)), msg.ptr });
    }

    /// Queues an event for the engine (any thread).
    pub fn post(h: *Host, ev: engine.Event) void {
        vlc.vlc_mutex_lock(&h.lock);
        defer vlc.vlc_mutex_unlock(&h.lock);
        h.events.append(gpa, ev) catch return;
        vlc.vlc_cond_signal(&h.wake);
    }

    /// Moves the engine's pending commands into `out` (the demux thread; never blocks for long).
    pub fn takeCommands(h: *Host, out: *std.ArrayList(engine.Command)) void {
        vlc.vlc_mutex_lock(&h.lock);
        defer vlc.vlc_mutex_unlock(&h.lock);
        out.appendSlice(gpa, h.commands.items) catch return;
        h.commands.clearRetainingCapacity();
    }

    fn run(data: ?*anyopaque) callconv(.c) ?*anyopaque {
        const h: *Host = @ptrCast(@alignCast(data));
        var batch: std.ArrayList(engine.Event) = .empty;
        defer batch.deinit(gpa);
        vlc.vlc_mutex_lock(&h.lock);
        while (!h.stop) {
            const now = hddvd_now_us();
            const due = h.eng.nextTick(now);
            if (h.events.items.len == 0 and due > now) {
                _ = vlc.vlc_cond_timedwait(&h.wake, &h.lock, due);
                if (h.events.items.len == 0 and hddvd_now_us() < due) continue;
            }
            std.mem.swap(std.ArrayList(engine.Event), &batch, &h.events);
            vlc.vlc_mutex_unlock(&h.lock);
            h.turn(batch.items);
            batch.clearRetainingCapacity();
            vlc.vlc_mutex_lock(&h.lock);
        }
        vlc.vlc_mutex_unlock(&h.lock);
        return null;
    }

    /// One pass of the engine thread: events in, a tick if due, the planes out.
    fn turn(h: *Host, events: []const engine.Event) void {
        const e = &h.eng;
        for (events) |ev| e.post(ev) catch {};
        var x: c_int = 0;
        var y: c_int = 0;
        while (true) {
            switch (hddvd_mouse_poll(h.mouse, &x, &y)) {
                1 => e.post(.{ .mouse_move = .{ .x = x, .y = y } }) catch {},
                2 => e.post(.{ .mouse_down = .{ .x = x, .y = y } }) catch {},
                3 => e.post(.{ .mouse_up = .{ .x = x, .y = y } }) catch {},
                else => break,
            }
        }
        // Keys VLC has no navigation action for: Backspace is the Cancel gesture (VK_ESC), since VLC takes Esc.
        // The Mac's backspace key ("delete") reaches VLC as KEY_DELETE, a PC's as KEY_BACKSPACE. The digit keys
        // are the remote's VK_0–VK_9 (Annex V), which games use for text entry; their codes are the same.
        while (true) {
            const k = hddvd_key_poll(h.mouse);
            if (k == 0) break;
            const vk: ?u8 = if (k == 0x08 or k == 0x00360000) // KEY_BACKSPACE, KEY_DELETE (vlc_actions.h), no modifiers
                engine.keys.esc
            else if (k >= '0' and k <= '9')
                @intCast(k)
            else
                null;
            if (vk) |code| {
                e.post(.{ .key_down = code }) catch {};
                e.post(.{ .key_up = code }) catch {};
            }
        }
        const now = hddvd_now_us();
        const r = e.step(now, h.pres.titleNow(now) orelse e.title_time);
        if (r.redraw) {
            if (h.frame()) |f| {
                e.render(f);
                h.pres.publishGraphics(if (e.scene != null) f else null);
            } else e.dirty = true; // retried at the next tick
        }
        if (r.cursor) h.pres.setCursor(e.cursor);
        h.dispatch(now);
        h.fx.update(now, h, settings);
    }

    /// Hands the engine's commands on. The demux carries out most of them, but a paused VLC does not call the
    /// demux, so pause and resume, audio levels and effect sounds are carried out here.
    fn dispatch(h: *Host, now: i64) void {
        const e = &h.eng;
        defer e.outbox.clearRetainingCapacity();
        for (e.outbox.items) |cmd| switch (cmd) {
            .pause => |on| hddvd_input_pause(@ptrCast(h.obj), on),
            .mixing => |m| h.pres.setMixing(m.main, m.sub, m.effect),
            .effect_play => |p| h.playEffect(p.data, p.repeat, now),
            .effect_stop => {
                h.fx.stop();
                h.pres.stopEffect();
            },
            else => {
                vlc.vlc_mutex_lock(&h.lock);
                defer vlc.vlc_mutex_unlock(&h.lock);
                h.commands.append(gpa, cmd) catch {};
            },
        };
    }

    /// Plays an effect sound (takes `data`, a WAV file): through our mixer (adec.zig) while VLC plays, through
    /// our own output while it is paused. One sound at a time: each replaces the other's.
    fn playEffect(h: *Host, data: []u8, repeat: u32, now: i64) void {
        defer gpa.free(data);
        const w = mix.decodeWav(gpa, data, repeat) catch |err| {
            log(h.obj, vlc.VLC_MSG_WARN, @src(), "effect sound: %s", .{@errorName(err).ptr});
            return;
        };
        const p = h.pres;
        p.lockIt();
        const paused = p.paused;
        const rows = p.effect_mix;
        const gain = p.effect_gain;
        p.unlock();
        if (!paused) {
            h.fx.stop();
            p.playEffect(.{ .samples = w.samples, .channels = w.channels, .rate = w.rate, .at = now });
            return;
        }
        defer gpa.free(w.samples);
        p.stopEffect();
        const s = settings(h);
        if (h.fx.play(w.samples, w.channels, w.rate, rows, gain, s, now)) |msg| {
            log(h.obj, vlc.VLC_MSG_WARN, @src(), "effect sound while paused: %s", .{msg});
        } else if (!s.audible) {
            log(h.obj, vlc.VLC_MSG_DBG, @src(), "effect sound while paused: not played, VLC has no audio output", .{});
        } else log(h.obj, vlc.VLC_MSG_DBG, @src(), "effect sound while paused: %s at %u Hz, amplitude %.5f", .{
            @as([*:0]const u8, @ptrCast(&h.fx.device_name)), @as(c_uint, h.fx.rate), @as(f64, s.amplitude),
        });
    }

    /// VLC's audio output settings, which effect sounds played while paused follow.
    fn settings(h: *Host) fxout.Settings {
        var s: fxout.Settings = .{};
        hddvd_aout_settings(@ptrCast(h.obj), &s);
        return s;
    }

    /// A frame the overlay is not reading.
    fn frame(h: *Host) ?*planes.Frame {
        for (&h.pool) |*slot| {
            if (slot.*) |f| {
                if (f.unshared()) return f;
            } else {
                slot.* = planes.Frame.create(gpa, h.pres.aperture_w, h.pres.aperture_h) catch return null;
                return slot.*;
            }
        }
        log(h.obj, vlc.VLC_MSG_DBG, @src(), "graphics: no free frame, skipping a redraw", .{});
        return null;
    }
};
