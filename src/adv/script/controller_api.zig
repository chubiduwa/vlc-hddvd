//! Controllers and the cursor (HD DVD Annex Z.5): ControllerManager and its Controller objects, and the
//! CursorManager, which drives the engine's Cursor Manager (Annex W Table W-6). ControllerKeyEvent and
//! ControllerEvent are in events.zig.
//!
//! The player has two controllers: the remote control (VLC's keys and hotkeys, id 1) and the mouse (id 2).
//! No VLC dependency.

const std = @import("std");
const js = @import("js.zig");
const host = @import("host.zig");
const planes = @import("../planes.zig");
const image = @import("../image.zig");
const engine = @import("../engine/engine.zig");
const uri = @import("../uri.zig");

const Value = js.Value;
const Script = host.Script;

pub const ControllerType = enum(u32) { other = 0, remote_controller = 1, keyboard = 2, mouse = 3, front_panel = 4, game_pad = 5 };

pub const Controller = struct {
    id: u32,
    type: ControllerType,
    cursor: bool,
    connected: bool = true,

    fn getId(c: *Controller) js.Error!u32 {
        if (!c.connected) return error.InvalidCall;
        return c.id;
    }
    fn getType(c: *Controller) js.Error!u32 {
        if (!c.connected) return error.InvalidCall;
        return @backingInt(c.type);
    }
    fn getCursor(c: *Controller) js.Error!bool {
        if (!c.connected) return error.InvalidCall;
        return c.cursor;
    }

    pub const js_class: js.Class = .{
        .name = "Controller",
        .members = &.{
            js.prop("id", getId, null),
            js.prop("type", getType, null),
            js.prop("cursor", getCursor, null),
            js.constant("OTHER", 0),
            js.constant("REMOTE_CONTROLLER", 1),
            js.constant("KEYBOARD", 2),
            js.constant("MOUSE", 3),
            js.constant("FRONT_PANEL", 4),
            js.constant("GAME_PAD", 5),
        },
    };
};

/// The player's controllers (the same objects for every context of the engine).
pub var controllers = [_]Controller{
    .{ .id = 1, .type = .remote_controller, .cursor = false },
    .{ .id = 2, .type = .mouse, .cursor = true },
};

/// ControllerManager (Z.5.4): a singleton per context; the same Controller object for the same controller.
pub const Manager = struct {
    objs: [controllers.len]?Value = @splat(null),

    fn getCount(_: *Manager) u32 {
        var n: u32 = 0;
        for (controllers) |c| n += @intFromBool(c.connected);
        return n;
    }

    fn getController(m: *Manager, cx: *js.Context, index: u32) js.Error!Value {
        var n: u32 = 0;
        for (&controllers, 0..) |*c, i| {
            if (!c.connected) continue;
            if (n == index) {
                if (m.objs[i]) |v| return cx.dup(v);
                const v = try cx.wrap(Controller, c);
                m.objs[i] = cx.dup(v);
                return v;
            }
            n += 1;
        }
        return error.Argument;
    }

    pub fn release(m: *Manager, cx: *js.Context) void {
        for (&m.objs) |*o| if (o.*) |v| {
            cx.free(v);
            o.* = null;
        };
    }

    pub const js_class: js.Class = .{
        .name = "ControllerManager",
        .members = &.{
            js.prop("count", getCount, null),
            js.method("getController", getController),
        },
    };
};

// ---- CursorManager (Z.5.5) ------------------------------------------------------------------------------------------

/// What the cursor's script side remembers (the image's URI; Table W-6's other values are the engine's).
pub const CursorState = struct {
    image_uri: ?[]u8 = null,
    /// The image script set (owned; the engine's cursor holds another reference).
    image: ?*planes.Image = null,

    pub fn deinit(c: *CursorState, gpa: std.mem.Allocator) void {
        if (c.image_uri) |u| gpa.free(u);
        if (c.image) |im| im.unref();
        c.* = .{};
    }
};

/// The engine's cursor, or a stand-in when there is no engine (tests of a lone script).
fn cursorOf(s: *Script) *planes.Cursor {
    if (s.world.eng) |e| return &e.cursor;
    return &s.world.lone_cursor;
}

fn changed(s: *Script) void {
    if (s.world.eng) |e| e.cursor_changed = true;
}

pub const CursorManager = struct {
    pub const js_owner = true;

    fn getImage(s: *Script) js.Error!Value {
        const u = s.world.cursor.image_uri orelse return js.undefined;
        return s.cx.string(u);
    }
    fn getX(s: *Script) u32 {
        return @intCast(@max(0, cursorOf(s).x));
    }
    fn getY(s: *Script) u32 {
        return @intCast(@max(0, cursorOf(s).y));
    }
    fn getHotX(s: *Script) u32 {
        return @intCast(@max(0, cursorOf(s).hot_x));
    }
    fn getHotY(s: *Script) u32 {
        return @intCast(@max(0, cursorOf(s).hot_y));
    }
    fn getEnable(s: *Script) bool {
        return cursorOf(s).enabled;
    }
    fn setEnable(s: *Script, v: bool) void {
        cursorOf(s).enabled = v;
        changed(s);
    }
    fn getVisible(s: *Script) bool {
        return cursorOf(s).visible;
    }
    fn setVisible(s: *Script, v: bool) void {
        cursorOf(s).visible = v;
        changed(s);
    }
    fn getRegionX(s: *Script) u32 {
        return @intCast(@max(0, cursorOf(s).region.x));
    }
    fn getRegionY(s: *Script) u32 {
        return @intCast(@max(0, cursorOf(s).region.y));
    }
    fn getRegionW(s: *Script) u32 {
        return @intCast(@max(0, cursorOf(s).region.w));
    }
    fn getRegionH(s: *Script) u32 {
        return @intCast(@max(0, cursorOf(s).region.h));
    }

    /// setImage(uri, hotSpotX, hotSpotY): null restores the player's image; the file must be in the File
    /// Cache (Z.5.5.3).
    fn setImage(s: *Script, u: js.NullStr, hx: u32, hy: u32) js.Error!void {
        const c = cursorOf(s);
        const st = &s.world.cursor;
        const path = u.s orelse {
            st.deinit(s.gpa);
            c.image = null;
            c.hot_x = 0;
            c.hot_y = 0;
            changed(s);
            return;
        };
        if (!uri.valid(path) or uri.locate(path) == null) return error.Argument;
        if (hx > 255 or hy > 255) return error.Argument;
        const f = s.world.files orelse return error.FileNotFound;
        const bytes = f.read(s.gpa, path) catch return error.FileNotFound;
        defer s.gpa.free(bytes);
        var canvas = image.decode(s.gpa, bytes) catch return error.FileNotFound;
        if (canvas.w > 256 or canvas.h > 256) {
            canvas.deinit(s.gpa);
            return error.FileNotFound;
        }
        const im = s.gpa.create(planes.Image) catch {
            canvas.deinit(s.gpa);
            return error.OutOfMemory;
        };
        im.* = .{ .gpa = s.gpa, .canvas = canvas };
        const copy = s.gpa.dupe(u8, path) catch {
            im.unref();
            return error.OutOfMemory;
        };
        st.deinit(s.gpa);
        st.image_uri = copy;
        st.image = im;
        c.image = im;
        c.hot_x = @intCast(hx);
        c.hot_y = @intCast(hy);
        changed(s);
    }

    /// moveCursor(x, y): inside the cursor region, else HDDVD_E_ARGUMENT.
    fn moveCursor(s: *Script, x: u32, y: u32) js.Error!void {
        const c = cursorOf(s);
        if (x > std.math.maxInt(i32) or y > std.math.maxInt(i32)) return error.Argument;
        if (!c.region.contains(@intCast(x), @intCast(y))) return error.Argument;
        c.x = @intCast(x);
        c.y = @intCast(y);
        changed(s);
    }

    /// setRegion(x, y, width, height): inside the aperture; a cursor outside moves to its origin.
    fn setRegion(s: *Script, x: u32, y: u32, w: u32, h: u32) js.Error!void {
        const c = cursorOf(s);
        const aw: u64 = s.world.aperture_w;
        const ah: u64 = s.world.aperture_h;
        if (w == 0 or h == 0 or @as(u64, x) + w > aw or @as(u64, y) + h > ah) return error.Argument;
        c.setRegion(.{ .x = @intCast(x), .y = @intCast(y), .w = @intCast(w), .h = @intCast(h) });
        changed(s);
    }

    pub const js_class: js.Class = .{
        .name = "CursorManager",
        .members = &.{
            js.prop("image", getImage, null),
            js.prop("x", getX, null),
            js.prop("y", getY, null),
            js.prop("hotSpotX", getHotX, null),
            js.prop("hotSpotY", getHotY, null),
            js.prop("enable", getEnable, setEnable),
            js.prop("visible", getVisible, setVisible),
            js.prop("regionX", getRegionX, null),
            js.prop("regionY", getRegionY, null),
            js.prop("regionWidth", getRegionW, null),
            js.prop("regionHeight", getRegionH, null),
            js.method("setImage", setImage),
            js.method("moveCursor", moveCursor),
            js.method("setRegion", setRegion),
        },
    };
};

// ---- tests --------------------------------------------------------------------------------------------------

const testenv = @import("testenv.zig");

test "ControllerManager and CursorManager" {
    const e = try testenv.Env.create();
    defer e.destroy();
    const png = try image.testPng(std.testing.allocator, 2, 2, &.{ .{ 255, 0, 0, 255 }, .{ 255, 0, 0, 255 }, .{ 255, 0, 0, 255 }, .{ 255, 0, 0, 255 } });
    defer std.testing.allocator.free(png);
    try e.temp.write("arrow.png", png, 0, true);
    try e.run(
        \\var M = ControllerManager; assertEq(M.count, 2);
        \\var r = M.getController(0); assertEq(r, M.getController(0)); assertEq(r.id, 1); assertEq(r.type, r.REMOTE_CONTROLLER); assertEq(r.cursor, false);
        \\var m = M.getController(1); assertEq(m.type, 3); assertEq(m.MOUSE, 3); assertEq(m.cursor, true);
        \\assertThrows(function () { M.getController(2); }, "HDDVD_E_ARGUMENT");
        \\r.id = 5; assertEq(r.id, 1, "read-only");
        \\var C = CursorManager; assertEq(C.image, undefined);
        \\C.setRegion(100, 100, 200, 100); assertEq(C.regionX, 100); assertEq(C.regionWidth, 200);
        \\assert(C.x >= 100 && C.x < 300 && C.y >= 100 && C.y < 200, "the cursor moved into the region");
        \\assertThrows(function () { C.setRegion(1800, 0, 200, 100); }, "HDDVD_E_ARGUMENT");
        \\assertThrows(function () { C.setRegion(0, 0, 0, 100); }, "HDDVD_E_ARGUMENT");
        \\C.moveCursor(150, 120); assertEq(C.x, 150); assertEq(C.y, 120);
        \\assertThrows(function () { C.moveCursor(10, 10); }, "HDDVD_E_ARGUMENT");
        \\C.setImage("file:///filecache/arrow.png", 1, 2); assertEq(C.image, "file:///filecache/arrow.png"); assertEq(C.hotSpotY, 2);
        \\assertThrows(function () { C.setImage("file:///filecache/none.png", 0, 0); }, "HDDVD_E_FILENOTFOUND");
        \\assertThrows(function () { C.setImage("file:///filecache/arrow.png", 256, 0); }, "HDDVD_E_ARGUMENT");
        \\C.setImage(null, 0, 0); assertEq(C.image, undefined); assertEq(C.hotSpotX, 0);
        \\C.visible = false; assertEq(C.visible, false); C.enable = false; assertEq(C.enable, false);
    , "controller.js");
}
