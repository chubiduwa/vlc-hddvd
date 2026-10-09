//! The API objects of a script context beyond the Application object (HD DVD Annex Z): the Application's
//! FileIO, Diagnostics, ControllerManager, Drawing and Network, and the Global object's named items Player,
//! DataCache, PersistentStorageManager and CursorManager. Each comes from its own module; this sets them up in a
//! new context, keeps their per-context state, and answers the system parameter XPath variables (Annex W.2).
//! No VLC dependency.

const std = @import("std");
const js = @import("js.zig");
const dom = @import("../dom.zig");
const xpath = @import("../xpath.zig");
const host = @import("host.zig");
const controller_api = @import("controller_api.zig");
const fileio_api = @import("fileio_api.zig");
const diag_api = @import("diag_api.zig");
const storage_api = @import("storage_api.zig");
const player_api = @import("player_api.zig");
const draw_api = @import("draw_api.zig");
const net_api = @import("net_api.zig");

const Value = js.Value;
const Script = host.Script;

/// What the API objects of one context keep.
pub const State = struct {
    controllers: controller_api.Manager = .{},
    diag: diag_api.Diag = .{},
    removed_listeners: std.ArrayList(*diag_api.Listener) = .empty,
    devices: storage_api.Devices = .{},
    player: player_api.State = .{},
    draw: draw_api.State = .{},
    net: net_api.State = .{},

    /// Before the context goes: every value held is released.
    pub fn deinit(st: *State, s: *Script) void {
        fileio_api.TextStream.releaseAll(s);
        st.controllers.release(s.cx);
        st.diag.deinit(s);
        for (st.removed_listeners.items) |l| {
            if (l.obj) |o| s.cx.free(o);
            l.name.deinit(s.gpa);
            l.buf.deinit(s.gpa);
            s.gpa.destroy(l);
        }
        st.removed_listeners.deinit(s.gpa);
        st.devices.deinit(s);
        st.player.deinit(s);
        st.draw.deinit(s);
        st.net.deinit(s);
    }
};

/// An object of `class` for the context's owner (members taking the Script as `self`).
fn ownerObject(s: *Script, class: *const js.Class) js.Error!Value {
    return s.cx.wrapAs(Script, class, s);
}

/// Makes the context's API objects and binds the named ones on the Global object `g`.
pub fn setup(s: *Script, g: Value) !void {
    const cx = s.cx;
    // Application members (host.zig reads them with `kept`).
    try s.keep("FileIO", try ownerObject(s, &fileio_api.FileIO.js_class));
    try s.keep("Diagnostics", try ownerObject(s, &diag_api.Diagnostics.js_class));
    try s.keep("Diagnostics.trace", try ownerObject(s, &diag_api.Trace.js_class));
    try s.keep("Diagnostics.listeners", try ownerObject(s, &diag_api.Collection.js_class));
    try s.keep("ControllerManager", try cx.wrap(controller_api.Manager, &s.apis.controllers));
    try s.keep("Drawing", try ownerObject(s, &draw_api.Drawing.js_class));
    try s.keep("Network", try ownerObject(s, &net_api.Network.js_class));
    // Named items of the Global object.
    const named = [_]struct { [:0]const u8, *const js.Class }{
        .{ "DataCache", &storage_api.DataCache.js_class },
        .{ "PersistentStorageManager", &storage_api.Manager.js_class },
        .{ "CursorManager", &controller_api.CursorManager.js_class },
    };
    for (named) |n| {
        const v = try ownerObject(s, n[1]);
        try s.keep(n[0], v);
        try cx.defineValue(g, n[0], cx.dup(v), 0);
    }
    const player = try player_api.make(s);
    try s.keep("Player", player);
    try cx.defineValue(g, "Player", cx.dup(player), 0);
    try storage_api.exposeConstructors(cx);
    try net_api.exposeConstructors(cx);
}

/// The value of system parameter variable `name` (Annex W.2), or null if there is none.
pub fn systemVariable(s: *Script, name: []const u8) ?xpath.Value {
    return player_api.systemVariable(s.world, name);
}

/// AnimatableElement.drawingArea: the DrawingArea of an <object type="x-application/graphic">, else null.
pub fn drawingAreaOf(s: *Script, n: *dom.Node) js.Error!Value {
    return draw_api.drawingAreaOf(s, n);
}
