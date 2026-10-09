//! Effect sounds while VLC is paused. The Sound Decoder plays effect audio whenever the applications ask, whatever
//! the Title Timeline does (HD DVD Vol. 1 §4.3.12.1.1, §4.3.13.4.1), but a paused VLC pauses its audio output,
//! which plays our mixer's stream (adec.zig). So a sound started while paused plays through an output of its own
//! (RtAudio, fx_glue.cpp), on the device VLC uses, at VLC's volume and mute.
//!
//! The engine thread owns it (engine/host.zig). The stream is opened for a sound and closed once idle.

const std = @import("std");
const mix = @import("mix.zig");

const gpa = std.heap.c_allocator;

const Fx = opaque {};
const Device = extern struct {
    id: c_uint,
    channels: c_uint,
    is_default: c_int,
    name: [256]u8,
};
extern fn hddvd_fx_new() ?*Fx;
extern fn hddvd_fx_delete(fx: ?*Fx) void;
extern fn hddvd_fx_devices(fx: *Fx, out: [*]Device, max: c_uint) c_uint;
extern fn hddvd_fx_open(fx: *Fx, id: c_uint, channels: c_uint, fill: *const fn (?*anyopaque, [*]f32, c_uint, c_uint) callconv(.c) void, ctx: ?*anyopaque) c_uint;
extern fn hddvd_fx_close(fx: *Fx) void;
extern fn hddvd_fx_error(fx: *Fx) [*:0]const u8;

/// VLC's audio output settings (nav_glue.c): whether it plays sound at all, its volume as an amplitude, and its
/// device's name.
pub const Settings = extern struct {
    audible: bool = true,
    amplitude: f32 = 1,
    device: [256]u8 = @splat(0),

    pub fn deviceName(s: *const Settings) []const u8 {
        return std.mem.sliceTo(&s.device, 0);
    }
};

const stereo = mix.Layout.of(mix.chan.left | mix.chan.right);
/// How often VLC's volume is read again while a sound plays (µs).
const settings_period: i64 = 100_000;
/// How long the stream stays open after a sound (µs).
const idle_close: i64 = 2_000_000;

pub const Output = struct {
    fx: ?*Fx = null,
    /// The device and rate of the open stream (rate 0: closed).
    device: c_uint = 0,
    rate: u32 = 0,
    /// The open device's name (for the log).
    device_name: [256]u8 = @splat(0),
    /// The sound playing, shared with the audio callback under `busy`.
    busy: std.atomic.Value(bool) = .init(false),
    sound: mix.Effects = .{},
    gain: f32 = 1,
    /// The applications' effect gain times VLC's volume.
    app_gain: f32 = 1,
    last_settings: i64 = 0,
    idle_since: i64 = 0,

    pub fn deinit(o: *Output) void {
        hddvd_fx_delete(o.fx); // stops the callback
        o.sound.deinit(gpa);
        o.* = .{};
    }

    fn acquire(o: *Output) void {
        while (o.busy.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
    }

    fn release(o: *Output) void {
        o.busy.store(false, .release);
    }

    /// Starts an effect sound (mono or stereo samples at `rate`), replacing any playing. Returns an error message
    /// if no output could be opened.
    pub fn play(o: *Output, samples: []const f32, channels: usize, rate: u32, rows: ?[2][mix.hd_channels]u8, gain: f32, settings: Settings, now: i64) ?[*:0]const u8 {
        o.stop();
        if (!settings.audible) return null; // VLC itself is silent (no audio output, or the dummy one)
        if (o.fx == null) o.fx = hddvd_fx_new();
        const fx = o.fx orelse return "cannot create an audio output";
        var devices: [32]Device = undefined;
        const n = @min(hddvd_fx_devices(fx, &devices, devices.len), devices.len);
        const id = pickDevice(devices[0..n], settings.deviceName()) orelse return "no audio output device";
        if (o.rate == 0 or id != o.device) {
            hddvd_fx_close(fx);
            o.rate = 0;
            const r = hddvd_fx_open(fx, id, stereo.n, fill, o);
            if (r == 0) return hddvd_fx_error(fx);
            o.device = id;
            o.rate = r;
            for (devices[0..n]) |d| if (d.id == id) {
                o.device_name = d.name;
            };
        }
        const out = mix.convertEffect(gpa, samples, channels, rate, stereo, o.rate, rows) catch return "out of memory";
        o.acquire();
        o.sound.start(gpa, out, stereo.n);
        o.app_gain = gain;
        o.gain = gain * settings.amplitude;
        o.release();
        o.last_settings = now;
        return null;
    }

    pub fn stop(o: *Output) void {
        o.acquire();
        o.sound.deinit(gpa);
        o.release();
    }

    pub fn playing(o: *Output) bool {
        o.acquire();
        defer o.release();
        return o.sound.playing();
    }

    /// Called on each engine turn: follows VLC's volume while a sound plays (`settings` is called at most every
    /// `settings_period`), and closes the stream once idle.
    pub fn update(o: *Output, now: i64, ctx: anytype, comptime settings: fn (@TypeOf(ctx)) Settings) void {
        if (o.rate == 0) return;
        if (o.playing()) {
            o.idle_since = now;
            if (now - o.last_settings < settings_period) return;
            o.last_settings = now;
            const s = settings(ctx);
            o.acquire();
            o.gain = o.app_gain * s.amplitude;
            o.release();
        } else if (now - o.idle_since > idle_close) {
            hddvd_fx_close(o.fx.?);
            o.rate = 0;
        }
    }

    /// The audio callback (RtAudio's thread).
    fn fill(ctx: ?*anyopaque, out: [*]f32, frames: c_uint, channels: c_uint) callconv(.c) void {
        const o: *Output = @ptrCast(@alignCast(ctx));
        const buf = out[0 .. @as(usize, frames) * channels];
        @memset(buf, 0);
        // Never wait here: the engine thread holds `busy` only to swap the sound or the gain.
        if (o.busy.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return;
        defer o.release();
        if (o.sound.playing()) o.sound.mixInto(buf, o.gain);
    }
};

/// The device whose name is VLC's device name (CoreAudio's names in RtAudio are "Manufacturer: Name"), else the
/// default output, else the first.
fn pickDevice(devices: []const Device, vlc_name: []const u8) ?c_uint {
    if (vlc_name.len > 0) for (devices) |*d| {
        const name = std.mem.sliceTo(&d.name, 0);
        if (std.mem.eql(u8, name, vlc_name)) return d.id;
        if (std.mem.endsWith(u8, name, vlc_name) and name.len >= vlc_name.len + 2 and
            std.mem.eql(u8, name[name.len - vlc_name.len - 2 ..][0..2], ": ")) return d.id;
    };
    for (devices) |d| if (d.is_default != 0) return d.id;
    return if (devices.len > 0) devices[0].id else null;
}

// ---- tests --------------------------------------------------------------------------------------------------

const testing = std.testing;

fn testDevice(id: c_uint, name: []const u8, default: bool) Device {
    var d: Device = .{ .id = id, .channels = 2, .is_default = @intFromBool(default), .name = @splat(0) };
    @memcpy(d.name[0..name.len], name);
    return d;
}

test "the effect output picks VLC's device by name" {
    const devices = [_]Device{
        testDevice(130, "Apple Inc.: MacBook Pro Speakers", true),
        testDevice(131, "Generic: USB DAC", false),
        testDevice(132, "Speakers (Realtek(R) Audio)", false),
    };
    try testing.expectEqual(@as(?c_uint, 131), pickDevice(&devices, "USB DAC"));
    try testing.expectEqual(@as(?c_uint, 132), pickDevice(&devices, "Speakers (Realtek(R) Audio)"));
    // VLC's "System Sound Output Device", an unknown one, or none: the default output.
    try testing.expectEqual(@as(?c_uint, 130), pickDevice(&devices, "System Sound Output Device"));
    try testing.expectEqual(@as(?c_uint, 130), pickDevice(&devices, "DAC"));
    try testing.expectEqual(@as(?c_uint, 130), pickDevice(&devices, ""));
    try testing.expectEqual(@as(?c_uint, null), pickDevice(&.{}, ""));
}

test "the effect output's callback plays the sound once, at its gain" {
    var o: Output = .{};
    defer o.sound.deinit(gpa);
    const s = try gpa.alloc(f32, 6);
    @memcpy(s, &[_]f32{ 0.5, -0.5, 0.25, -0.25, 1, -1 });
    o.sound.start(gpa, s, 2);
    o.gain = 0.5;
    var buf: [4]f32 = undefined;
    Output.fill(&o, &buf, 2, 2);
    try testing.expectEqualSlices(f32, &.{ 0.25, -0.25, 0.125, -0.125 }, &buf);
    Output.fill(&o, &buf, 2, 2);
    try testing.expectEqualSlices(f32, &.{ 0.5, -0.5, 0, 0 }, &buf);
    try testing.expect(!o.playing());
    // Busy (the engine thread swapping the sound): silence, without waiting.
    o.busy.store(true, .monotonic);
    buf = @splat(1);
    Output.fill(&o, &buf, 2, 2);
    try testing.expectEqualSlices(f32, &.{ 0, 0, 0, 0 }, &buf);
}
