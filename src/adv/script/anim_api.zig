//! The Animated Property API (HD DVD Annex Z.13, Vol. 3 §7.6.3.4): AnimatableDocument (getProperties, load,
//! `document.<id>`), AnimatableElement (style, state, core, drawingArea) and AnimatableProperty, whose property
//! blocks override the markup's animation of an element's properties.
//!
//! The script override block of each element is kept here (`Overrides`): setProperty holds a value until unset;
//! animateProperty animates a value list over its duration on the application clock and then holds the last
//! value (it is defined as `<animate fill="hold">`). Each tick, before the cascade, the style values go into
//! the page's script layer and the state values into the elements' states.
//!
//! State attributes (§7.6.3.4.1): only focused, enabled and value can be set. Once script sets one, that kind of
//! state is in "global state": markup timing and the user no longer change it, until any unsetProperty. The
//! focused global state is shared by all applications; enabled and value are per application.
//! No VLC dependency.

const std = @import("std");
const js = @import("js.zig");
const dom = @import("../dom.zig");
const style = @import("../markup/style.zig");
const anim = @import("../markup/anim.zig");
const page_mod = @import("../markup/page.zig");
const dom_api = @import("dom_api.zig");
const host = @import("host.zig");

const Value = js.Value;
const Node = dom.Node;
const Script = host.Script;

pub const Space = enum {
    style,
    state,
    core,

    pub fn uri(s: Space) []const u8 {
        return switch (s) {
            .style => style.ns,
            .state => page_mod.state_ns,
            .core => page_mod.core_ns,
        };
    }

    fn of(u: []const u8) ?Space {
        inline for (comptime std.enums.values(Space)) |s| if (std.mem.eql(u8, u, s.uri())) return s;
        return null;
    }
};

pub const StateName = enum { foreground, focused, pointer, actioned, enabled, value };

/// Core attributes (§7.5.3.2): all are animation "none" but value.
const core_names = [_][]const u8{ "accessKey", "coords", "id", "condition", "mode", "name", "shape", "src", "type", "value", "xml:base", "xml:lang", "xml:space" };

// ---- the override block -------------------------------------------------------------------------------------------

pub const Override = struct {
    node: *Node,
    space: Space,
    /// Property (style), state or core attribute name.
    name: []const u8,
    values: [][]u8,
    /// Application ticks.
    start: u64,
    /// null: setProperty (indefinite).
    dur: ?u64,
    linear: bool,

    fn free(o: *Override, gpa: std.mem.Allocator) void {
        for (o.values) |v| gpa.free(v);
        gpa.free(o.values);
        gpa.free(o.name);
    }

    /// The value at application tick `now` (allocated from `a`, or one of the values).
    pub fn at(o: *const Override, a: std.mem.Allocator, now: u64) []const u8 {
        const d = o.dur orelse return o.values[0];
        const f: f64 = if (d == 0) 1 else @as(f64, @floatFromInt(now -| o.start)) / @as(f64, @floatFromInt(d));
        const prop: ?style.Prop = if (o.space == .style) style.Prop.byName(o.name) else null;
        const vals: []const []const u8 = @ptrCast(o.values);
        return anim.sample(a, prop, vals, @min(f, 1), o.linear);
    }
};

pub const Overrides = struct {
    list: std.ArrayList(Override) = .empty,
    /// Global state of enabled and value in this application (focused: World.focus_locked).
    enabled_locked: bool = false,
    value_locked: bool = false,
    /// What `apply` computed this tick.
    arena: std.heap.ArenaAllocator,
    /// The last apply set values in the page (they are cleared at the next).
    applied: bool = false,

    pub fn init(gpa: std.mem.Allocator) Overrides {
        return .{ .arena = .init(gpa) };
    }

    pub fn deinit(o: *Overrides, gpa: std.mem.Allocator) void {
        for (o.list.items) |*x| x.free(gpa);
        o.list.deinit(gpa);
        o.arena.deinit();
    }

    /// Every override goes (document.load(), a new page).
    pub fn clear(o: *Overrides, gpa: std.mem.Allocator) void {
        for (o.list.items) |*x| x.free(gpa);
        o.list.clearRetainingCapacity();
    }

    fn find(o: *Overrides, n: *Node, space: Space, name: []const u8) ?usize {
        for (o.list.items, 0..) |x, i| if (x.node == n and x.space == space and std.mem.eql(u8, x.name, name)) return i;
        return null;
    }

    fn put(o: *Overrides, gpa: std.mem.Allocator, x: Override) !void {
        if (o.find(x.node, x.space, x.name)) |i| {
            o.list.items[i].free(gpa);
            o.list.items[i] = x;
        } else try o.list.append(gpa, x);
    }

    fn remove(o: *Overrides, gpa: std.mem.Allocator, n: *Node, space: Space, name: []const u8) void {
        const i = o.find(n, space, name) orelse return;
        o.list.items[i].free(gpa);
        _ = o.list.orderedRemove(i);
    }

    /// The current value of an override, if there is one.
    pub fn valueOf(o: *Overrides, a: std.mem.Allocator, n: *Node, space: Space, name: []const u8, now: u64) ?[]const u8 {
        const i = o.find(n, space, name) orelse return null;
        return o.list.items[i].at(a, now);
    }

    /// Before the cascade: the style overrides into the page's script layer (values valid until the next
    /// apply), the state overrides through `s`.
    pub fn apply(o: *Overrides, s: *Script, p: *page_mod.Page, now: u64) void {
        _ = o.arena.reset(.retain_capacity);
        const a = o.arena.allocator();
        p.script.clearRetainingCapacity();
        o.applied = o.list.items.len > 0;
        for (o.list.items) |*x| {
            const el = page_mod.Page.elemOf(x.node) orelse continue;
            const v = x.at(a, now);
            switch (x.space) {
                .style => {
                    const prop = style.Prop.byName(x.name) orelse continue;
                    p.script.put(p.gpa, .{ .elem = el, .prop = prop }, v) catch {};
                },
                .state => s.applyState(p, el, std.meta.stringToEnum(StateName, x.name) orelse continue, v),
                .core => {},
            }
        }
    }
};

// ---- AnimatableProperty -------------------------------------------------------------------------------------------

pub const Prop = struct {
    node: *Node,
    space: Space,
    obj: *anyopaque = undefined,

    fn make(s: *Script, n: *Node, space: Space) js.Error!Value {
        const p = try s.gpa.create(Prop);
        p.* = .{ .node = n, .space = space };
        const class = switch (space) {
            .style => &style_class,
            .state => &state_class,
            .core => &core_class,
        };
        return dom_api.wrapDependent(s, Prop, class, p, n.doc) catch |e| {
            s.gpa.destroy(p);
            return e;
        };
    }

    fn finalize(ptr: *anyopaque, _: *js.Runtime) void {
        const p: *Prop = @ptrCast(@alignCast(ptr));
        const doc = p.node.doc;
        const obj = p.obj;
        doc.gpa.destroy(p);
        dom_api.dropDependent(doc, obj);
    }

    fn getNamespace(p: *Prop) []const u8 {
        return p.space.uri();
    }

    fn getElement(p: *Prop, cx: *js.Context) js.Error!Value {
        return dom_api.wrap(scriptOf(cx), p.node);
    }

    /// getProperty (Z.13.1.3).
    fn getProperty(p: *Prop, cx: *js.Context, name: []const u8) js.Error!Value {
        const s = scriptOf(cx);
        var arena: std.heap.ArenaAllocator = .init(s.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        switch (p.space) {
            .style => {
                const prop = style.Prop.byName(name) orelse return error.Argument;
                if (s.overrides.valueOf(a, p.node, .style, name, s.appTicks())) |v| return cx.string(v);
                const el = page_mod.Page.elemOf(p.node) orelse return cx.string("");
                const pg = s.page() orelse return cx.string("");
                // backgroundImage with absolute URIs: §7.5.2.4.3.2 says the specified URI, but discs
                // rebuild image names by cutting the value at its last "/", which only works with resolved
                // URIs (what the players it was made for must have returned) [disc].
                if (prop == .backgroundImage) {
                    var w: std.Io.Writer.Allocating = .init(a);
                    for (el.style.backgroundImage, 0..) |u, i| {
                        const abs = pg.resolve(p.node, u) catch null;
                        defer if (abs) |x| pg.gpa.free(x);
                        w.writer.print("{s}url('{s}')", .{ if (i > 0) " " else "", abs orelse u }) catch return error.OutOfMemory;
                    }
                    return cx.string(w.written());
                }
                return cx.string(pg.propertyString(a, el, prop) catch "");
            },
            .state => {
                const which = std.meta.stringToEnum(StateName, name) orelse return error.Argument;
                if (s.overrides.valueOf(a, p.node, .state, name, s.appTicks())) |v| return cx.string(v);
                const el = page_mod.Page.elemOf(p.node) orelse return cx.string(if (which == .enabled) "true" else if (which == .value) "" else "false");
                const st = el.state;
                return cx.string(switch (which) {
                    .foreground => boolStr(st.foreground),
                    .focused => boolStr(st.focused),
                    .pointer => boolStr(st.pointer),
                    .actioned => boolStr(st.actioned),
                    .enabled => boolStr(st.enabled),
                    .value => st.value,
                });
            },
            .core => {
                if (!isCore(name)) return error.Argument;
                if (s.overrides.valueOf(a, p.node, .core, name, s.appTicks())) |v| return cx.string(v);
                return cx.string(coreAttr(p.node, name) orelse "");
            },
        }
    }

    /// setProperty: an indefinite override.
    fn setProperty(p: *Prop, cx: *js.Context, name: []const u8, value: []const u8) js.Error!void {
        try p.override(cx, name, value, null);
    }

    /// animateProperty: `values` (";"-separated) over `duration` seconds, then held.
    fn animateProperty(p: *Prop, cx: *js.Context, name: []const u8, values: []const u8, duration: js.Number) js.Error!void {
        if (!(duration.v > 0) or std.math.isInf(duration.v)) return error.Argument;
        try p.override(cx, name, values, duration.v);
    }

    fn override(p: *Prop, cx: *js.Context, name: []const u8, raw: []const u8, seconds: ?f64) js.Error!void {
        const s = scriptOf(cx);
        const linear: bool = switch (p.space) {
            .style => blk: {
                const prop = style.Prop.byName(name) orelse return error.Argument;
                if (prop.anim() == .none) return error.Argument;
                break :blk prop.anim() == .linear;
            },
            .state => blk: {
                const which = std.meta.stringToEnum(StateName, name) orelse return error.Argument;
                if (which != .focused and which != .enabled and which != .value) return error.Argument;
                break :blk false;
            },
            .core => blk: {
                if (!std.mem.eql(u8, name, "value")) return error.Argument;
                break :blk false;
            },
        };
        var vals: std.ArrayList([]u8) = .empty;
        errdefer {
            for (vals.items) |v| s.gpa.free(v);
            vals.deinit(s.gpa);
        }
        if (seconds == null) {
            try p.validate(s, name, raw);
            try vals.append(s.gpa, try s.gpa.dupe(u8, std.mem.trim(u8, raw, " \t\r\n")));
        } else {
            var it = std.mem.splitScalar(u8, raw, ';');
            while (it.next()) |v_raw| {
                const v = std.mem.trim(u8, v_raw, " \t\r\n");
                try p.validate(s, name, v);
                try vals.append(s.gpa, try s.gpa.dupe(u8, v));
            }
            if (vals.items.len == 0) return error.Argument;
        }
        const ticks: ?u64 = if (seconds) |sec| @intFromFloat(@max(1, @round(sec * s.tickRate()))) else null;
        const name_copy = try s.gpa.dupe(u8, name);
        errdefer s.gpa.free(name_copy);
        const values = try vals.toOwnedSlice(s.gpa);
        errdefer {
            for (values) |v| s.gpa.free(v);
            s.gpa.free(values);
        }
        try s.overrides.put(s.gpa, .{ .node = p.node, .space = p.space, .name = name_copy, .values = values, .start = s.appTicks(), .dur = ticks, .linear = linear });
        if (p.space == .state) {
            const which = std.meta.stringToEnum(StateName, name).?;
            s.lockState(which);
            // Reflected at once in the DOM and the element's state.
            if (s.page()) |pg| if (page_mod.Page.elemOf(p.node)) |el| s.applyState(pg, el, which, values[0]);
        }
    }

    fn validate(p: *Prop, s: *Script, name: []const u8, v: []const u8) js.Error!void {
        switch (p.space) {
            .style => {
                const prop = style.Prop.byName(name).?;
                var arena: std.heap.ArenaAllocator = .init(s.gpa);
                defer arena.deinit();
                var scratch: style.Style = .initial(1080);
                const parent: style.Style = .initial(1080);
                if (!style.apply(&scratch, prop, v, .{ .parent = &parent, .aperture_h = 1080, .arena = arena.allocator() })) {
                    if (s.world.rt.trace_throws) s.world.print("script {s}: style {s}: bad value \"{s}\"", .{ s.name(), name, v });
                    return error.Argument;
                }
            },
            .state => {
                if (std.mem.eql(u8, name, "value")) return;
                if (!std.mem.eql(u8, v, "true") and !std.mem.eql(u8, v, "false")) return error.Argument;
            },
            .core => {},
        }
    }

    /// unsetProperty: the override goes; any unset ends every global state (§7.6.3.4.1).
    fn unsetProperty(p: *Prop, cx: *js.Context, name: []const u8) js.Error!void {
        const s = scriptOf(cx);
        switch (p.space) {
            .style => _ = style.Prop.byName(name) orelse return error.Argument,
            .state => _ = std.meta.stringToEnum(StateName, name) orelse return error.Argument,
            .core => if (!isCore(name)) return error.Argument,
        }
        s.overrides.remove(s.gpa, p.node, p.space, name);
        s.unlockStates();
    }

    fn Named(comptime space: Space, comptime name: [:0]const u8) type {
        return struct {
            fn get(p: *Prop, cx: *js.Context) js.Error!Value {
                return p.getProperty(cx, name);
            }
            fn set(p: *Prop, cx: *js.Context, v: []const u8) js.Error!void {
                _ = space;
                return p.setProperty(cx, name, v);
            }
        };
    }

    const common = [_]js.Member{
        js.prop("namespace", getNamespace, null),
        js.prop("element", getElement, null),
        js.method("getProperty", getProperty),
        js.method("setProperty", setProperty),
        js.method("animateProperty", animateProperty),
        js.method("unsetProperty", unsetProperty),
    };

    /// A property per style attribute; read-only when its animation is "none" (Z.13.1.2.1).
    fn styleMembers() [common.len + style.count]js.Member {
        var out: [common.len + style.count]js.Member = undefined;
        for (common, 0..) |m, i| out[i] = m;
        for (std.enums.values(style.Prop), common.len..) |sp, i| {
            const N = Named(.style, @tagName(sp));
            out[i] = if (sp.anim() == .none) js.prop(@tagName(sp), N.get, null) else js.prop(@tagName(sp), N.get, N.set);
        }
        return out;
    }

    fn stateMembers() [common.len + 6]js.Member {
        var out: [common.len + 6]js.Member = undefined;
        for (common, 0..) |m, i| out[i] = m;
        for (std.enums.values(StateName), common.len..) |sn, i| {
            const N = Named(.state, @tagName(sn));
            const settable = sn == .focused or sn == .enabled or sn == .value;
            out[i] = if (settable) js.prop(@tagName(sn), N.get, N.set) else js.prop(@tagName(sn), N.get, null);
        }
        return out;
    }

    fn coreMembers() [common.len + core_names.len]js.Member {
        var out: [common.len + core_names.len]js.Member = undefined;
        for (common, 0..) |m, i| out[i] = m;
        for (core_names, common.len..) |cn, i| {
            const N = Named(.core, cn[0..cn.len :0] ++ "");
            out[i] = if (std.mem.eql(u8, cn, "value")) js.prop(cn[0..cn.len :0] ++ "", N.get, N.set) else js.prop(cn[0..cn.len :0] ++ "", N.get, null);
        }
        return out;
    }

    const style_members = styleMembers();
    const state_members = stateMembers();
    const core_members = coreMembers();

    pub const js_class = style_class;
};

const style_class: js.Class = .{ .name = "AnimatableProperty", .finalize = Prop.finalize, .members = &Prop.style_members };
const state_class: js.Class = .{ .name = "AnimatableProperty", .finalize = Prop.finalize, .members = &Prop.state_members };
const core_class: js.Class = .{ .name = "AnimatableProperty", .finalize = Prop.finalize, .members = &Prop.core_members };

fn boolStr(b: bool) []const u8 {
    return if (b) "true" else "false";
}

fn isCore(name: []const u8) bool {
    for (core_names) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

fn coreAttr(n: *Node, name: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, name, "xml:")) return n.attrNS(dom.xml_ns, name[4..]);
    return n.attr(name);
}

fn scriptOf(cx: *js.Context) *Script {
    return @ptrCast(@alignCast(cx.owner.?));
}

// ---- AnimatableDocument, AnimatableElement --------------------------------------------------------------------------

fn getProperties(_: *Node, cx: *js.Context, el_v: Value, ns: []const u8) js.Error!Value {
    const el = dom_api.nodeOf(cx, el_v) orelse return error.Argument;
    if (el.type != .element) return error.Argument;
    const space = Space.of(ns) orelse return error.Argument;
    return Prop.make(scriptOf(cx), el, space);
}

fn load(n: *Node, cx: *js.Context) js.Error!void {
    try scriptOf(cx).reloadPage(n.doc);
}

pub const document_members = [_]js.Member{
    js.method("getProperties", getProperties),
    js.method("load", load),
};

fn getStyle(n: *Node, cx: *js.Context) js.Error!Value {
    return Prop.make(scriptOf(cx), n, .style);
}

fn getState(n: *Node, cx: *js.Context) js.Error!Value {
    return Prop.make(scriptOf(cx), n, .state);
}

fn getCore(n: *Node, cx: *js.Context) js.Error!Value {
    return Prop.make(scriptOf(cx), n, .core);
}

fn getDrawingArea(n: *Node, cx: *js.Context) js.Error!Value {
    return scriptOf(cx).drawingAreaOf(n);
}

pub const element_members = [_]js.Member{
    js.prop("style", getStyle, null),
    js.prop("state", getState, null),
    js.prop("core", getCore, null),
    js.prop("drawingArea", getDrawingArea, null),
};
