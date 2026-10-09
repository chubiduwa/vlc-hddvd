//! Events for scripts (HD DVD Vol. 3 §8.3, Annex Z.5, Z.6, Z.11.3, Z.12.6): DOM Level 2 Events (Event,
//! MutationEvent, EventTarget, DocumentEvent, EventException) with the ECMAScript binding of its Appendix C, the
//! system event objects of Table Z.6.1-1, ControllerKeyEvent, ControllerEvent and PersistentStorageEvent.
//!
//! An event is described independently of any script context (`Spec`): one is delivered to each application in
//! turn, each getting its own Event object. Listeners are kept per target (a `Registry` per context), keyed by
//! the target's identity (the Application object, a DOM node).
//!
//! Dispatch follows DOM2 (capture from the top, the target, bubbling back up), except that at the target every
//! listener runs, capturing or not (as DOM Level 3 and the browsers do): scripts register key listeners on the
//! Application object with useCapture true and expect them to run when nothing has the focus [disc].
//! No VLC dependency.

const std = @import("std");
const js = @import("js.zig");
const keys = @import("../engine/keys.zig");

const c = js.c;
const Value = js.Value;

pub const Phase = enum(u8) { none = 0, capturing = 1, at_target = 2, bubbling = 3 };

/// The kind of event object: its class.
pub const Kind = enum {
    /// Created by script with createEvent (an Application Event: extensible, §8.2.4), or by markup's <event>.
    app,
    mutation,
    key,
    controller,
    storage,
    // System events (Table Z.6.1-1).
    title,
    scheduled,
    chapter,
    clip,
    video_track,
    audio_track,
    subtitle_track,
    application,
    play_state,
    play_speed,
    network_timeout,
    resource_not_found,
    streaming_buffer,
    network_connection,
    stop_request,

    pub fn system(k: Kind) bool {
        return @backingInt(k) >= @backingInt(Kind.title);
    }

    /// The object name, as createEvent would take it.
    pub fn objectName(k: Kind) []const u8 {
        return classOf(k).name;
    }
};

/// The ControllerKeyEvent fields (Z.5.3).
pub const KeyInfo = struct {
    id: u32 = 0,
    x: u32 = 0,
    y: u32 = 0,
    parent_x: u32 = 0,
    parent_y: u32 = 0,
    offset_x: u32 = 0,
    offset_y: u32 = 0,
    /// Annex V virtual key code; null: NaN.
    key: ?u32 = null,
    /// The character, as markup writes it (7.5.2.1); null: undefined.
    code: ?[]const u8 = null,
    dx: i32 = 0,
    dy: i32 = 0,
};

/// A property script added to an Application Event, carried to the other applications (§8.3.5: primitive
/// values, and Boolean and Number objects as their values).
pub const Extra = struct { name: []const u8, value: Value };

/// An event independent of any context. Strings are borrowed from whoever made it.
pub const Spec = struct {
    kind: Kind,
    type: []const u8,
    bubbles: bool = true,
    cancelable: bool = true,
    /// Title, event, clip or application id (null: undefined).
    id: ?[]const u8 = null,
    /// oldValue/newValue (null: NaN).
    old: ?u32 = null,
    new: ?u32 = null,
    uri: ?[]const u8 = null,
    /// The title time it occurred at, as a timecode (system events).
    time: ?[]const u8 = null,
    /// StreamingBufferEvent: the Secondary Video's elapsed time.
    elapsed: ?[]const u8 = null,
    connect: bool = false,
    key: KeyInfo = .{},
    extras: []const Extra = &.{},
};

/// An Event object's native side, owned by its wrapper.
pub const Event = struct {
    arena: std.heap.ArenaAllocator,
    kind: Kind,
    type: []const u8 = "",
    initialized: bool = false,
    bubbles: bool = false,
    cancelable: bool = false,
    phase: Phase = .none,
    stopped: bool = false,
    prevented: bool = false,
    /// Being dispatched (a second dispatchEvent is refused).
    dispatching: bool = false,
    /// ms (DOMTimeStamp).
    time_stamp: f64 = 0,
    target: Value = js.null,
    current: Value = js.null,
    id: ?[]const u8 = null,
    old: ?u32 = null,
    new: ?u32 = null,
    uri: ?[]const u8 = null,
    time: ?[]const u8 = null,
    elapsed: ?[]const u8 = null,
    connect: bool = false,
    key: KeyInfo = .{},
    // MutationEvent.
    related: Value = js.null,
    prev_value: []const u8 = "",
    new_value: []const u8 = "",
    attr_name: []const u8 = "",
    attr_change: u16 = 0,

    pub fn create(gpa: std.mem.Allocator, kind: Kind, now_ms: f64) !*Event {
        const e = try gpa.create(Event);
        e.* = .{ .arena = .init(gpa), .kind = kind, .time_stamp = now_ms };
        return e;
    }

    /// A new Event object in `cx` for `spec`, initialized.
    pub fn fromSpec(cx: *js.Context, spec: Spec, now_ms: f64) js.Error!Value {
        const e = try create(cx.gpa, spec.kind, now_ms);
        const v = cx.wrapAs(Event, classOf(spec.kind), e) catch |err| {
            e.destroy(cx.rt);
            return err;
        };
        errdefer cx.free(v);
        const a = e.arena.allocator();
        e.type = try a.dupe(u8, spec.type);
        e.initialized = true;
        e.bubbles = spec.bubbles;
        e.cancelable = spec.cancelable;
        e.id = if (spec.id) |s| try a.dupe(u8, s) else null;
        e.old = spec.old;
        e.new = spec.new;
        e.uri = if (spec.uri) |s| try a.dupe(u8, s) else null;
        e.time = if (spec.time) |s| try a.dupe(u8, s) else null;
        e.elapsed = if (spec.elapsed) |s| try a.dupe(u8, s) else null;
        e.connect = spec.connect;
        e.key = spec.key;
        if (spec.key.code) |s| e.key.code = try a.dupe(u8, s);
        for (spec.extras) |x| {
            const name = try a.dupeSentinel(u8, x.name, 0);
            try cx.set(v, name, cx.dup(x.value));
        }
        return v;
    }

    fn destroy(e: *Event, rt: *js.Runtime) void {
        c.JS_FreeValueRT(rt.rt, e.target);
        c.JS_FreeValueRT(rt.rt, e.current);
        c.JS_FreeValueRT(rt.rt, e.related);
        const gpa = e.arena.child_allocator;
        e.arena.deinit();
        gpa.destroy(e);
    }

    fn finalize(ptr: *anyopaque, rt: *js.Runtime) void {
        const e: *Event = @ptrCast(@alignCast(ptr));
        e.destroy(rt);
    }

    fn mark(ptr: *anyopaque, rt: *c.JSRuntime, m: ?*const c.JS_MarkFunc) void {
        const e: *Event = @ptrCast(@alignCast(ptr));
        c.JS_MarkValue(rt, e.target, m);
        c.JS_MarkValue(rt, e.current, m);
        c.JS_MarkValue(rt, e.related, m);
    }

    fn setValue(cx: *js.Context, slot: *Value, v: Value) void {
        cx.free(slot.*);
        slot.* = cx.dup(v);
    }

    // ---- Event (DOM2 Events §1.4) ----

    fn getType(e: *Event) []const u8 {
        return e.type;
    }
    fn getTarget(e: *Event, cx: *js.Context) Value {
        return cx.dup(e.target);
    }
    fn getCurrent(e: *Event, cx: *js.Context) Value {
        return cx.dup(e.current);
    }
    fn getPhase(e: *Event) u32 {
        return @backingInt(e.phase);
    }
    fn getBubbles(e: *Event) bool {
        return e.bubbles;
    }
    fn getCancelable(e: *Event) bool {
        return e.cancelable;
    }
    fn getTimeStamp(e: *Event) f64 {
        return e.time_stamp;
    }
    fn stopPropagation(e: *Event) void {
        e.stopped = true;
    }
    fn preventDefault(e: *Event) void {
        if (e.cancelable) e.prevented = true;
    }
    fn initEvent(e: *Event, type_: []const u8, can_bubble: bool, cancelable: bool) !void {
        if (e.dispatching) return; // DOM2: no effect once dispatched
        e.type = try e.arena.allocator().dupe(u8, type_);
        e.bubbles = can_bubble;
        e.cancelable = cancelable;
        e.initialized = true;
    }

    // ---- MutationEvent (DOM2 Events §1.6.4) ----

    fn getRelated(e: *Event, cx: *js.Context) Value {
        return cx.dup(e.related);
    }
    fn getPrevValue(e: *Event) []const u8 {
        return e.prev_value;
    }
    fn getNewValue(e: *Event) []const u8 {
        return e.new_value;
    }
    fn getAttrName(e: *Event) []const u8 {
        return e.attr_name;
    }
    fn getAttrChange(e: *Event) u32 {
        return e.attr_change;
    }
    fn initMutationEvent(e: *Event, cx: *js.Context, type_: []const u8, can_bubble: bool, cancelable: bool, related: js.Value, prev: js.NullStr, new: js.NullStr, attr: js.NullStr, change: u32) !void {
        try e.initEvent(type_, can_bubble, cancelable);
        const a = e.arena.allocator();
        setValue(cx, &e.related, related);
        e.prev_value = try a.dupe(u8, prev.s orelse "");
        e.new_value = try a.dupe(u8, new.s orelse "");
        e.attr_name = try a.dupe(u8, attr.s orelse "");
        e.attr_change = @truncate(change);
    }

    // ---- system events (Table Z.6.1-1) ----

    fn getId(e: *Event, cx: *js.Context) !Value {
        return if (e.id) |s| cx.string(s) else js.undefined;
    }
    fn getOld(e: *Event) f64 {
        return if (e.old) |x| @floatFromInt(x) else std.math.nan(f64);
    }
    fn getNew(e: *Event) f64 {
        return if (e.new) |x| @floatFromInt(x) else std.math.nan(f64);
    }
    fn getUri(e: *Event, cx: *js.Context) !Value {
        return if (e.uri) |s| cx.string(s) else js.undefined;
    }
    fn getTime(e: *Event, cx: *js.Context) !Value {
        // StreamingBufferEvent's own `time` is the Secondary Video's elapsed time.
        if (e.kind == .streaming_buffer) if (e.elapsed) |s| return cx.string(s);
        return if (e.time) |s| cx.string(s) else js.undefined;
    }
    fn getConnect(e: *Event) bool {
        return e.connect;
    }

    // ---- ControllerKeyEvent (Z.5.3) ----

    fn getKeyId(e: *Event) u32 {
        return e.key.id;
    }
    fn getX(e: *Event) u32 {
        return e.key.x;
    }
    fn getY(e: *Event) u32 {
        return e.key.y;
    }
    fn getParentX(e: *Event) u32 {
        return e.key.parent_x;
    }
    fn getParentY(e: *Event) u32 {
        return e.key.parent_y;
    }
    fn getOffsetX(e: *Event) u32 {
        return e.key.offset_x;
    }
    fn getOffsetY(e: *Event) u32 {
        return e.key.offset_y;
    }
    fn getKey(e: *Event) f64 {
        return if (e.key.key) |k| @floatFromInt(k) else std.math.nan(f64);
    }
    fn getCode(e: *Event, cx: *js.Context) !Value {
        return if (e.key.code) |s| cx.string(s) else js.undefined;
    }
    fn getDx(e: *Event) i32 {
        return e.key.dx;
    }
    fn getDy(e: *Event) i32 {
        return e.key.dy;
    }
    fn initControllerKeyEvent(e: *Event, type_: []const u8, can_bubble: bool, cancelable: bool, id: u32, x: u32, y: u32, px: u32, py: u32, ox: u32, oy: u32, key: u32, code: []const u8, dx: i32, dy: i32) !void {
        try e.initEvent(type_, can_bubble, cancelable);
        e.key = .{
            .id = id,
            .x = x,
            .y = y,
            .parent_x = px,
            .parent_y = py,
            .offset_x = ox,
            .offset_y = oy,
            .key = key,
            .code = try e.arena.allocator().dupe(u8, code),
            .dx = dx,
            .dy = dy,
        };
    }

    // ---- classes ----

    const event_members = [_]js.Member{
        js.prop("type", getType, null),
        js.prop("target", getTarget, null),
        js.prop("currentTarget", getCurrent, null),
        js.prop("eventPhase", getPhase, null),
        js.prop("bubbles", getBubbles, null),
        js.prop("cancelable", getCancelable, null),
        js.prop("timeStamp", getTimeStamp, null),
        js.method("stopPropagation", stopPropagation),
        js.method("preventDefault", preventDefault),
        js.method("initEvent", initEvent),
    } ++ phase_constants;

    pub const phase_constants = [_]js.Member{
        js.constant("CAPTURING_PHASE", 1),
        js.constant("AT_TARGET", 2),
        js.constant("BUBBLING_PHASE", 3),
    };

    pub const js_class: js.Class = .{ .name = "Event", .members = &event_members, .finalize = finalize, .mark = mark };

    const app_class: js.Class = .{ .name = "Event", .parent = &js_class, .finalize = finalize, .mark = mark, .extensible = true };

    pub const mutation_constants = [_]js.Member{
        js.constant("MODIFICATION", 1),
        js.constant("ADDITION", 2),
        js.constant("REMOVAL", 3),
    };
    pub const mutation_class: js.Class = .{
        .name = "MutationEvent",
        .parent = &js_class,
        .finalize = finalize,
        .mark = mark,
        .members = &([_]js.Member{
            js.prop("relatedNode", getRelated, null),
            js.prop("prevValue", getPrevValue, null),
            js.prop("newValue", getNewValue, null),
            js.prop("attrName", getAttrName, null),
            js.prop("attrChange", getAttrChange, null),
            js.method("initMutationEvent", initMutationEvent),
        } ++ mutation_constants),
    };

    const time_member = js.prop("time", getTime, null);
    const id_member = js.prop("id", getId, null);
    const old_member = js.prop("oldValue", getOld, null);
    const new_member = js.prop("newValue", getNew, null);
    const uri_member = js.prop("uri", getUri, null);

    fn system(comptime name: [:0]const u8, comptime members: []const js.Member) js.Class {
        return .{ .name = name, .parent = &js_class, .finalize = finalize, .mark = mark, .members = &([_]js.Member{time_member} ++ members[0..members.len].*) };
    }

    const title_class = system("TitleEvent", &.{ id_member, js.constant("BEGIN", "title_begin"), js.constant("END", "title_end") });
    const scheduled_class = system("ScheduledEvent", &.{ id_member, js.constant("EVENT", "scheduled_event") });
    const chapter_class = system("ChapterEvent", &.{ old_member, new_member, js.constant("CHANGE", "chapter") });
    const clip_class = system("ClipEvent", &.{ id_member, js.constant("BEGIN", "clip_begin"), js.constant("END", "clip_end") });
    const video_track_class = system("VideoTrackEvent", &.{ old_member, new_member, js.constant("CHANGE", "video_track") });
    const audio_track_class = system("AudioTrackEvent", &.{ old_member, new_member, js.constant("CHANGE", "audio_track") });
    const subtitle_track_class = system("SubtitleTrackEvent", &.{ old_member, new_member, js.constant("CHANGE", "subtitle_track") });
    const application_class = system("ApplicationEvent", &.{ id_member, js.constant("END", "application_end") });
    const play_state_class = system("PlayStateEvent", &.{ old_member, new_member, js.constant("CHANGE", "play_state") });
    const play_speed_class = system("PlaySpeedEvent", &.{ old_member, new_member, js.constant("CHANGE", "play_speed") });
    const network_timeout_class = system("NetworkTimeoutEvent", &.{ uri_member, js.constant("TIMEOUT", "network_timeout") });
    const resource_not_found_class = system("ResourceNotFoundEvent", &.{ uri_member, js.constant("NOT_FOUND", "resource_not_found") });
    const streaming_buffer_class: js.Class = .{
        .name = "StreamingBufferEvent",
        .parent = &js_class,
        .finalize = finalize,
        .mark = mark,
        .members = &.{ time_member, uri_member, js.constant("EMPTY", "buffer_empty"), js.constant("RESTART", "buffer_restart") },
    };
    const network_connection_class = system("NetworkConnectionEvent", &.{ js.prop("connect", getConnect, null), js.constant("CONNECTION", "network_connection") });
    const stop_request_class = system("StopRequestEvent", &.{js.constant("STOP", "stop_request")});
    // Z.5.1 names the controller event types "controller_connect"/"controller_disconnect" (Table Z.6.2-1 has
    // "controller_connected"/"…_disconnected"): the object's own definition is followed.
    pub const controller_class = system("ControllerEvent", &.{ js.constant("CONNECT", "controller_connect"), js.constant("DISCONNECT", "controller_disconnect") });
    pub const storage_class = system("PersistentStorageEvent", &.{js.constant("CHANGE", "storage_change")});

    pub const key_constants = [_]js.Member{
        js.constant("DOWN", "controller_key_down"),
        js.constant("UP", "controller_key_up"),
        js.constant("CURSOR_MOVE", "cursor_move"),
        js.constant("VECTOR", "controller_key_vector"),
    } ++ vkConstants();

    /// ControllerKeyEvent.VK_PLAY and the other Annex V codes (Z.5.3.4.1).
    fn vkConstants() [keys.table.len]js.Member {
        var out: [keys.table.len]js.Member = undefined;
        for (keys.table, 0..) |k, i| out[i] = js.constant(k.name[0..k.name.len :0] ++ "", k.code);
        return out;
    }

    pub const key_class: js.Class = .{
        .name = "ControllerKeyEvent",
        .parent = &js_class,
        .finalize = finalize,
        .mark = mark,
        .members = &([_]js.Member{
            js.prop("id", getKeyId, null),
            js.prop("x", getX, null),
            js.prop("y", getY, null),
            js.prop("parentX", getParentX, null),
            js.prop("parentY", getParentY, null),
            js.prop("offsetX", getOffsetX, null),
            js.prop("offsetY", getOffsetY, null),
            js.prop("key", getKey, null),
            js.prop("code", getCode, null),
            js.prop("dx", getDx, null),
            js.prop("dy", getDy, null),
            js.method("initControllerKeyEvent", initControllerKeyEvent),
        } ++ key_constants),
    };
};

pub fn classOf(k: Kind) *const js.Class {
    return switch (k) {
        .app => &Event.app_class,
        .mutation => &Event.mutation_class,
        .key => &Event.key_class,
        .controller => &Event.controller_class,
        .storage => &Event.storage_class,
        .title => &Event.title_class,
        .scheduled => &Event.scheduled_class,
        .chapter => &Event.chapter_class,
        .clip => &Event.clip_class,
        .video_track => &Event.video_track_class,
        .audio_track => &Event.audio_track_class,
        .subtitle_track => &Event.subtitle_track_class,
        .application => &Event.application_class,
        .play_state => &Event.play_state_class,
        .play_speed => &Event.play_speed_class,
        .network_timeout => &Event.network_timeout_class,
        .resource_not_found => &Event.resource_not_found_class,
        .streaming_buffer => &Event.streaming_buffer_class,
        .network_connection => &Event.network_connection_class,
        .stop_request => &Event.stop_request_class,
    };
}

/// DocumentEvent.createEvent(eventType): "MutationEvents"/"MutationEvent" and "ControllerKeyEvent(s)" make
/// those; system event objects cannot be created (Z.6.1: NOT_SUPPORTED_ERR); any other name makes an Application
/// Event (scripts pass the event's own name [disc]). The event is not initialized.
pub fn createEvent(cx: *js.Context, event_type: []const u8, now_ms: f64) js.Error!Value {
    const eq = std.mem.eql;
    const kind: Kind = if (eq(u8, event_type, "MutationEvents") or eq(u8, event_type, "MutationEvent"))
        .mutation
    else if (eq(u8, event_type, "ControllerKeyEvent") or eq(u8, event_type, "ControllerKeyEvents"))
        .key
    else blk: {
        inline for (comptime std.enums.values(Kind)) |k| {
            if (comptime (k.system() or k == .controller or k == .storage)) {
                if (eq(u8, event_type, classOf(k).name)) return throwDom(cx, .not_supported);
            }
        }
        break :blk .app;
    };
    const e = try Event.create(cx.gpa, kind, now_ms);
    return cx.wrapAs(Event, classOf(kind), e) catch |err| {
        e.destroy(cx.rt);
        return err;
    };
}

/// The own enumerable properties of Application Event `v` that carry over to another application (§8.3.5):
/// primitives, and Boolean and Number objects as their values. Names are allocated from `a`; values are
/// owned (free them with JS_FreeValueRT).
pub fn extrasOf(cx: *js.Context, a: std.mem.Allocator, v: Value) ![]Extra {
    var tab: [*c]c.JSPropertyEnum = null;
    var len: u32 = 0;
    if (c.JS_GetOwnPropertyNames(cx.ctx, &tab, &len, v, c.JS_GPN_STRING_MASK | c.JS_GPN_ENUM_ONLY) < 0) return error.Thrown;
    defer c.JS_FreePropertyEnum(cx.ctx, tab, len);
    var out: std.ArrayList(Extra) = .empty;
    for (tab[0..len]) |pe| {
        var n: usize = 0;
        const name = c.JS_AtomToCStringLen(cx.ctx, &n, pe.atom) orelse continue;
        defer c.JS_FreeCString(cx.ctx, name);
        var x = c.JS_GetProperty(cx.ctx, v, pe.atom);
        if (c.JS_IsException(x)) {
            cx.report("event property");
            continue;
        }
        if (c.JS_IsObject(x)) {
            // Boolean and Number objects carry their value; other objects do not carry over.
            if (try instanceOf(cx, x, "Boolean") or try instanceOf(cx, x, "Number")) {
                const vo = try cx.get(x, "valueOf");
                defer cx.free(vo);
                const prim = cx.call(vo, x, &.{}) catch {
                    cx.free(x);
                    cx.report("event property");
                    continue;
                };
                cx.free(x);
                x = prim;
            } else {
                cx.free(x);
                continue;
            }
        }
        try out.append(a, .{ .name = try a.dupe(u8, name[0..n]), .value = x });
    }
    return out.toOwnedSlice(a);
}

fn instanceOf(cx: *js.Context, v: Value, ctor: [:0]const u8) !bool {
    const g = cx.global();
    defer cx.free(g);
    const f = try cx.get(g, ctor);
    defer cx.free(f);
    const r = c.JS_IsInstanceOf(cx.ctx, v, f);
    if (r < 0) return error.Thrown;
    return r != 0;
}

// ---- listeners and dispatch -------------------------------------------------------------------------------------

pub const Listener = struct {
    type: []u8,
    f: Value,
    capture: bool,
};

/// The listeners of one context's event targets, by target identity.
pub const Registry = struct {
    map: std.AutoHashMapUnmanaged(*const anyopaque, std.ArrayList(Listener)) = .empty,

    pub fn deinit(r: *Registry, cx: *js.Context) void {
        var it = r.map.valueIterator();
        while (it.next()) |l| freeList(cx, l);
        r.map.deinit(cx.gpa);
    }

    fn freeList(cx: *js.Context, l: *std.ArrayList(Listener)) void {
        for (l.items) |x| {
            cx.gpa.free(x.type);
            cx.free(x.f);
        }
        l.deinit(cx.gpa);
    }

    /// Drops every listener of `target` (it is gone).
    pub fn drop(r: *Registry, cx: *js.Context, target: *const anyopaque) void {
        if (r.map.fetchRemove(target)) |kv| {
            var l = kv.value;
            freeList(cx, &l);
        }
    }

    /// EventTarget.addEventListener: a listener already registered (same type, function and phase) is not
    /// added again.
    pub fn add(r: *Registry, cx: *js.Context, target: *const anyopaque, type_: []const u8, f: Value, capture: bool) !void {
        const gop = try r.map.getOrPut(cx.gpa, target);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        for (gop.value_ptr.items) |x| if (x.capture == capture and std.mem.eql(u8, x.type, type_) and cx.same(x.f, f)) return;
        const name = try cx.gpa.dupe(u8, type_);
        errdefer cx.gpa.free(name);
        try gop.value_ptr.append(cx.gpa, .{ .type = name, .f = cx.dup(f), .capture = capture });
    }

    pub fn remove(r: *Registry, cx: *js.Context, target: *const anyopaque, type_: []const u8, f: Value, capture: bool) void {
        const l = r.map.getPtr(target) orelse return;
        for (l.items, 0..) |x, i| if (x.capture == capture and std.mem.eql(u8, x.type, type_) and cx.same(x.f, f)) {
            cx.gpa.free(x.type);
            cx.free(x.f);
            _ = l.orderedRemove(i);
            return;
        };
    }

    /// True if `target` has a listener for `type_`.
    pub fn has(r: *const Registry, target: *const anyopaque, type_: []const u8) bool {
        const l = r.map.get(target) orelse return false;
        for (l.items) |x| if (std.mem.eql(u8, x.type, type_)) return true;
        return false;
    }
};

/// One target on an event's path: its identity and its script object (borrowed).
pub const Hop = struct { key: *const anyopaque, obj: Value };

/// Dispatches Event `ev` (its object `ev_obj`) along `path`, from the top (path[0]) to the target (the last).
/// Listener exceptions are reported and do not stop the dispatch.
pub fn dispatch(cx: *js.Context, reg: *Registry, ev: *Event, ev_obj: Value, path: []const Hop) void {
    if (path.len == 0) return;
    const target = path[path.len - 1];
    ev.dispatching = true;
    ev.stopped = false;
    Event.setValue(cx, &ev.target, target.obj);
    defer {
        ev.phase = .none;
        Event.setValue(cx, &ev.current, js.null);
        ev.dispatching = false;
    }
    ev.phase = .capturing;
    for (path[0 .. path.len - 1]) |h| {
        invoke(cx, reg, ev, ev_obj, h, .capture);
        if (ev.stopped) return;
    }
    ev.phase = .at_target;
    invoke(cx, reg, ev, ev_obj, target, .all);
    if (ev.stopped or !ev.bubbles) return;
    ev.phase = .bubbling;
    var i = path.len - 1;
    while (i > 0) {
        i -= 1;
        invoke(cx, reg, ev, ev_obj, path[i], .bubble);
        if (ev.stopped) return;
    }
}

fn invoke(cx: *js.Context, reg: *Registry, ev: *Event, ev_obj: Value, h: Hop, which: enum { capture, bubble, all }) void {
    const l = reg.map.get(h.key) orelse return;
    // The listeners when the event reaches this target: ones added meanwhile do not run (DOM2 §1.2.1).
    var fs: std.ArrayList(Value) = .empty;
    defer {
        for (fs.items) |f| cx.free(f);
        fs.deinit(cx.gpa);
    }
    for (l.items) |x| {
        if (!std.mem.eql(u8, x.type, ev.type)) continue;
        switch (which) {
            .capture => if (!x.capture) continue,
            .bubble => if (x.capture) continue,
            .all => {},
        }
        fs.append(cx.gpa, cx.dup(x.f)) catch return;
    }
    Event.setValue(cx, &ev.current, h.obj);
    for (fs.items) |f| {
        // A listener removed by an earlier one does not run.
        if (!stillListening(cx, reg, h.key, ev.type, f)) continue;
        var args = [_]Value{ev_obj};
        if (cx.isFunction(f)) {
            cx.callReport(f, h.obj, &args, ev.type);
        } else {
            // An object implementing EventListener.
            const he = cx.get(f, "handleEvent") catch {
                cx.report(ev.type);
                continue;
            };
            defer cx.free(he);
            if (cx.isFunction(he)) cx.callReport(he, f, &args, ev.type);
        }
    }
}

fn stillListening(cx: *js.Context, reg: *Registry, key: *const anyopaque, type_: []const u8, f: Value) bool {
    const l = reg.map.get(key) orelse return false;
    for (l.items) |x| if (std.mem.eql(u8, x.type, type_) and cx.same(x.f, f)) return true;
    return false;
}

// ---- exceptions -------------------------------------------------------------------------------------------------

/// DOMException codes (DOM2 Core §1.1.2).
pub const DomCode = enum(u16) {
    index_size = 1,
    domstring_size = 2,
    hierarchy_request = 3,
    wrong_document = 4,
    invalid_character = 5,
    no_data_allowed = 6,
    no_modification_allowed = 7,
    not_found = 8,
    not_supported = 9,
    inuse_attribute = 10,
    invalid_state = 11,
    syntax = 12,
    invalid_modification = 13,
    namespace = 14,
    invalid_access = 15,

    fn constName(comptime code: DomCode) [:0]const u8 {
        const n = @tagName(code);
        var up: [n.len:0]u8 = undefined;
        for (n, 0..) |ch, i| up[i] = std.ascii.toUpper(ch);
        const final = up;
        return &final ++ "_ERR";
    }
};

pub const dom_exception_constants = blk: {
    const vals = std.enums.values(DomCode);
    var out: [vals.len]js.Member = undefined;
    for (vals, 0..) |v, i| out[i] = js.constant(DomCode.constName(v), @backingInt(v));
    break :blk out;
};

/// DOMException and EventException: plain objects whose prototype is an Error object (Table Z.12.5-1).
pub const DomException = struct {
    pub const js_class: js.Class = .{ .name = "DOMException", .members = &dom_exception_constants, .error_proto = true };
};

pub const EventException = struct {
    pub const js_class: js.Class = .{ .name = "EventException", .members = &.{js.constant("UNSPECIFIED_EVENT_TYPE_ERR", 0)}, .error_proto = true };
};

/// Throws a DOMException with `code` (its message is the code's name, NOT_FOUND_ERR…).
pub fn throwDom(cx: *js.Context, code: DomCode) js.Error {
    return switch (code) {
        inline else => |k| throwException(cx, &DomException.js_class, @backingInt(k), comptime DomCode.constName(k)),
    };
}

/// Throws EventException UNSPECIFIED_EVENT_TYPE_ERR; its message names HDDVD_E_UNSPECIFIEDEVENTTYPE (Z.1.3).
pub fn throwUnspecifiedEventType(cx: *js.Context) js.Error {
    return throwException(cx, &EventException.js_class, 0, "HDDVD_E_UNSPECIFIEDEVENTTYPE");
}

fn throwException(cx: *js.Context, class: *const js.Class, code: u16, msg: []const u8) js.Error {
    const p = try cx.protoOf(class);
    const e = c.JS_NewObjectProto(cx.ctx, p);
    if (c.JS_IsException(e)) return error.Thrown;
    fill(cx, e, class, code, msg) catch |err| {
        cx.free(e);
        return err;
    };
    return cx.throwValue(e);
}

fn fill(cx: *js.Context, e: Value, class: *const js.Class, code: u16, msg: []const u8) js.Error!void {
    try cx.defineValue(e, "code", cx.number(@floatFromInt(code)), c.JS_PROP_WRITABLE | c.JS_PROP_CONFIGURABLE | c.JS_PROP_ENUMERABLE);
    try cx.defineValue(e, "message", try cx.string(msg), c.JS_PROP_WRITABLE | c.JS_PROP_CONFIGURABLE);
    try cx.defineValue(e, "name", try cx.string(class.name), c.JS_PROP_WRITABLE | c.JS_PROP_CONFIGURABLE);
}

/// The global constructors of the event API (Z.6, Z.12.6): Event, EventException, DocumentEvent and
/// MutationEvent, which throw EvalError when called.
pub fn exposeConstructors(cx: *js.Context) js.Error!void {
    try cx.exposeConstructor(&Event.js_class, "Event", error.EvalError, &Event.phase_constants);
    try cx.exposeConstructor(&EventException.js_class, "EventException", error.EvalError, EventException.js_class.members);
    try cx.exposeConstructor(&DocumentEventIface.js_class, "DocumentEvent", error.EvalError, &.{});
    try cx.exposeConstructor(&Event.mutation_class, "MutationEvent", error.EvalError, &Event.mutation_constants);
    try cx.exposeConstructor(&DomException.js_class, "DOMException", error.EvalError, &dom_exception_constants);
}

/// The DocumentEvent interface object (its prototype holds nothing: documents and the Application object have
/// createEvent themselves).
const DocumentEventIface = struct {
    pub const js_class: js.Class = .{ .name = "DocumentEvent" };
};

/// Formats frames as a timecode "HH:MM:SS:FF" (§6.2.3.13).
pub fn timecode(buf: []u8, frames: u64, fps: u64) []const u8 {
    const f = frames % fps;
    const s = frames / fps;
    return std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}:{d:0>2}:{d:0>2}", .{ s / 3600, s / 60 % 60, s % 60, f }) catch "";
}

// ---- tests ------------------------------------------------------------------------------------------------------

const t = std.testing;

/// A context with a tree of three targets (app > doc > el) to dispatch on, and `dispatch(type, bubbles)` /
/// `create(name)` for scripts.
const Fixture = struct {
    rt: *js.Runtime,
    cx: *js.Context,
    reg: Registry = .{},
    objs: [3]Value = undefined,
    keys: [3]u8 = .{ 0, 1, 2 },

    pub const js_owner = true;
    pub const js_class: js.Class = .{ .name = "Fixture" };

    fn init(f: *Fixture) !void {
        f.rt = try js.Runtime.create(t.allocator, 32 << 20);
        f.cx = try js.Context.create(f.rt, f);
        f.reg = .{};
        const g = f.cx.global();
        defer f.cx.free(g);
        try exposeConstructors(f.cx);
        try f.cx.defineMembers(g, &.{
            js.method("listen", listen),
            js.method("unlisten", unlisten),
            js.method("fire", fire),
            js.method("create", create),
            js.method("fireSpec", fireSpec),
        });
        for (&f.objs, [_][:0]const u8{ "app", "doc", "el" }) |*o, n| {
            o.* = try f.cx.object();
            try f.cx.set(g, n, f.cx.dup(o.*));
        }
    }

    fn deinit(f: *Fixture) void {
        f.reg.deinit(f.cx);
        for (f.objs) |o| f.cx.free(o);
        f.cx.destroy();
        f.rt.destroy();
    }

    fn keyOf(f: *Fixture, which: u32) *const anyopaque {
        return &f.keys[which];
    }

    fn listen(f: *Fixture, which: u32, type_: []const u8, fun: Value, capture: bool) !void {
        try f.reg.add(f.cx, f.keyOf(which), type_, fun, capture);
    }

    fn unlisten(f: *Fixture, which: u32, type_: []const u8, fun: Value, capture: bool) void {
        f.reg.remove(f.cx, f.keyOf(which), type_, fun, capture);
    }

    /// Dispatches event object `ev` at target `which` (0 app, 1 doc, 2 el); returns !defaultPrevented.
    fn fire(f: *Fixture, ev: Value, which: u32) !bool {
        const e = f.cx.unwrap(Event, ev) orelse return error.TypeError;
        if (!e.initialized or e.type.len == 0) return throwUnspecifiedEventType(f.cx);
        var path: [3]Hop = undefined;
        for (0..which + 1) |i| path[i] = .{ .key = f.keyOf(@intCast(i)), .obj = f.objs[i] };
        dispatch(f.cx, &f.reg, e, ev, path[0 .. which + 1]);
        return !e.prevented;
    }

    fn create(f: *Fixture, name: []const u8) !Value {
        return createEvent(f.cx, name, 1000);
    }

    fn fireSpec(f: *Fixture, kind: []const u8, type_: []const u8) !void {
        const k = std.meta.stringToEnum(Kind, kind) orelse return error.TypeError;
        const ev = try Event.fromSpec(f.cx, .{ .kind = k, .type = type_, .id = "t1", .old = null, .new = 3, .time = "00:00:01:00", .key = .{ .key = 0x0D, .x = 5 } }, 0);
        defer f.cx.free(ev);
        _ = try f.fire(ev, 0);
    }
};

test "DOM2 event flow, cancellation and listeners" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try js.testing.run(f.cx,
        \\var log = [];
        \\function rec(tag) { return function (e) { log.push(tag + ":" + e.eventPhase + ":" + (e.currentTarget === app ? "app" : e.currentTarget === doc ? "doc" : "el")); }; }
        \\listen(0, "go", rec("cap"), true);
        \\listen(1, "go", rec("cap"), true);
        \\listen(2, "go", rec("tgtcap"), true);
        \\listen(2, "go", rec("tgt"), false);
        \\listen(1, "go", rec("bub"), false);
        \\listen(0, "go", rec("bub"), false);
        \\var e = create("go");
        \\assertEq(e.type, "", "not initialized");
        \\assertThrows(function () { fire(e, 2); }, "HDDVD_E_UNSPECIFIEDEVENTTYPE");
        \\try { fire(e, 2); } catch (x) { assert(x instanceof EventException, "EventException"); assert(x instanceof Error, "an Error"); assertEq(x.code, 0); }
        \\e.initEvent("go", true, true);
        \\assert(fire(e, 2), "not prevented");
        \\assertEq(log.join(","), "cap:1:app,cap:1:doc,tgtcap:2:el,tgt:2:el,bub:3:doc,bub:3:app");
        \\assertEq(e.target, el); assertEq(e.currentTarget, null); assertEq(e.eventPhase, 0);
        \\// Not bubbling.
        \\log = []; var nb = create("Events"); nb.initEvent("go", false, false);
        \\fire(nb, 2); assertEq(log.join(","), "cap:1:app,cap:1:doc,tgtcap:2:el,tgt:2:el");
        \\// stopPropagation ends the flow after the current target.
        \\log = []; listen(1, "stop", function (e) { log.push("a"); e.stopPropagation(); }, true);
        \\listen(1, "stop", function (e) { log.push("b"); }, true); listen(2, "stop", function (e) { log.push("c"); }, false);
        \\var s = create("stop"); s.initEvent("stop", true, true); fire(s, 2); assertEq(log.join(","), "a,b");
        \\// preventDefault only if cancelable.
        \\listen(2, "p", function (e) { e.preventDefault(); }, false);
        \\var p1 = create("p"); p1.initEvent("p", true, true); assertEq(fire(p1, 2), false);
        \\var p2 = create("p"); p2.initEvent("p", true, false); assertEq(fire(p2, 2), true);
        \\// Duplicates are ignored; removal; a listener removed meanwhile does not run; exceptions do not stop.
        \\var n = 0; function inc() { n++; } listen(0, "d", inc, false); listen(0, "d", inc, false);
        \\listen(0, "d", function () { throw new Error("listener"); }, false);
        \\var d = create("d"); d.initEvent("d", false, false); fire(d, 0); assertEq(n, 1);
        \\unlisten(0, "d", inc, false); fire(d, 0); assertEq(n, 1);
        \\var ran = false; function second() { ran = true; }
        \\listen(0, "r", function () { unlisten(0, "r", second, false); }, false); listen(0, "r", second, false);
        \\var r = create("r"); r.initEvent("r", false, false); fire(r, 0); assertEq(ran, false);
        \\// An EventListener object.
        \\var obj = { hits: 0, handleEvent: function (e) { this.hits++; } }; listen(0, "o", obj, false);
        \\var o = create("o"); o.initEvent("o", false, false); fire(o, 0); assertEq(obj.hits, 1);
        \\// Application events take properties (§8.2.4).
        \\var a = create("menu_hidden"); a.extra = 5; assertEq(a.extra, 5);
        \\assertEq(a.CAPTURING_PHASE, 1); assertEq(Event.BUBBLING_PHASE, 3);
        \\assertThrows(function () { new Event(); }, EvalError, "constructor");
        \\assertThrows(function () { MutationEvent(); }, EvalError, "constructor");
        \\// Mutation events.
        \\var m = create("MutationEvents"); assert(m instanceof MutationEvent, "MutationEvent"); assert(m instanceof Event, "is an Event");
        \\m.initMutationEvent("DOMAttrModified", true, false, doc, "a", "b", "id", MutationEvent.MODIFICATION);
        \\assertEq(m.relatedNode, doc); assertEq(m.prevValue, "a"); assertEq(m.newValue, "b"); assertEq(m.attrName, "id"); assertEq(m.attrChange, 1);
        \\m.extra = 1; assertEq(m.extra, undefined, "not extensible");
        \\// Key events.
        \\var k = create("ControllerKeyEvent");
        \\k.initControllerKeyEvent(k.DOWN, true, true, 1, 2, 3, 4, 5, 6, 7, k.VK_ENTER, "U+000D", -1, 1);
        \\assertEq(k.type, "controller_key_down"); assertEq(k.key, 13); assertEq(k.offsetY, 7); assertEq(k.dx, -1); assertEq(k.code, "U+000D");
        \\// System events cannot be created.
        \\try { create("TitleEvent"); assert(false, "created"); } catch (x) { assert(x instanceof DOMException, "DOMException"); assertEq(x.code, DOMException.NOT_SUPPORTED_ERR); assertEq(x.message, "NOT_SUPPORTED_ERR"); }
        \\// A system event from the player.
        \\var got; listen(0, "title_begin", function (e) { got = e; }, false);
        \\fireSpec("title", "title_begin");
        \\assertEq(got.type, got.BEGIN); assertEq(got.id, "t1"); assertEq(got.time, "00:00:01:00");
        \\assert(got.bubbles && got.cancelable, "system events bubble and cancel");
        \\var ch; listen(0, "chapter", function (e) { ch = e; }, false); fireSpec("chapter", "chapter");
        \\assertEq(ch.oldValue, NaN); assertEq(ch.newValue, 3); assertEq(ch.id, undefined); assertEq(ch.CHANGE, "chapter");
    , "events.js");
}

test "Application Event properties carry over" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try js.testing.run(f.cx, "var ev = create('x'); ev.s = 'a'; ev.n = 2; ev.b = new Boolean(true); ev.o = {}; ev.u = undefined;", "carry.js");
    const g = f.cx.global();
    defer f.cx.free(g);
    const ev = try f.cx.get(g, "ev");
    defer f.cx.free(ev);
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const xs = try extrasOf(f.cx, arena.allocator(), ev);
    defer for (xs) |x| f.cx.free(x.value);
    try t.expectEqual(4, xs.len);
    try t.expectEqualStrings("b", xs[2].name);
    try t.expect(c.JS_IsBool(xs[2].value));
    const copy = try Event.fromSpec(f.cx, .{ .kind = .app, .type = "x", .extras = xs }, 0);
    defer f.cx.free(copy);
    try f.cx.set(g, "copy", f.cx.dup(copy));
    try js.testing.run(f.cx, "assertEq(copy.s, 'a'); assertEq(copy.n, 2); assertEq(copy.b, true); assertEq(copy.o, undefined); assert('u' in copy);", "carried.js");
}

test "timecodes" {
    var buf: [16]u8 = undefined;
    try t.expectEqualStrings("01:02:03:04", timecode(&buf, ((3600 + 2 * 60 + 3) * 60) + 4, 60));
}
