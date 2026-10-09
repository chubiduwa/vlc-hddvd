//! Diagnostics for script authors (HD DVD Annex Z.4, Vol. 3 §8.6.2): Diagnostics, Trace, TraceListener and
//! TraceListenerCollection.
//!
//! This player has the debugger listener (its output goes to the player's log, VLC's debug messages); file and
//! network listeners are not supported (HDDVD_E_NOTSUPPORTED). Diagnostics are locked unless the player
//! unlocks them: while locked, tracing outputs nothing (and does not throw, so scripts that trace work alike).
//! Messages are buffered per listener until a line ends and the buffer is flushed (flush, or autoFlush).
//! No VLC dependency.

const std = @import("std");
const js = @import("js.zig");
const host = @import("host.zig");

const Value = js.Value;
const Script = host.Script;

pub const Listener = struct {
    kind: []const u8,
    name: std.ArrayList(u8) = .empty,
    indent_level: u32 = 0,
    indent_size: u32 = 4,
    need_indent: bool = true,
    buf: std.ArrayList(u8) = .empty,
    /// In the collection (a removed listener's object stays, inert).
    attached: bool = true,
    obj: ?Value = null,

    fn deinit(l: *Listener, gpa: std.mem.Allocator) void {
        l.name.deinit(gpa);
        l.buf.deinit(gpa);
    }
};

pub const Diag = struct {
    auto_flush: bool = false,
    indent_level: u32 = 0,
    indent_size: u32 = 4,
    /// Trace's indent settings were set (they then override the listeners', Z.4).
    trace_indent: bool = false,
    listeners: std.ArrayList(*Listener) = .empty,

    pub fn deinit(d: *Diag, s: *Script) void {
        for (d.listeners.items) |l| {
            if (l.obj) |o| s.cx.free(o);
            l.deinit(s.gpa);
            s.gpa.destroy(l);
        }
        d.listeners.deinit(s.gpa);
    }
};

fn diagOf(s: *Script) *Diag {
    return &s.apis.diag;
}

fn emit(s: *Script, l: *Listener) void {
    if (!s.world.diagnostics_unlocked) {
        l.buf.clearRetainingCapacity();
        return;
    }
    var it = std.mem.splitScalar(u8, l.buf.items, '\n');
    while (it.next()) |line| {
        if (it.peek() == null) break; // the unfinished line stays (flush sends it)
        s.world.print("trace [{s}] {s}", .{ l.name.items, std.mem.trimEnd(u8, line, "\r") });
    }
    const last = std.mem.lastIndexOfScalar(u8, l.buf.items, '\n');
    if (last) |i| {
        std.mem.copyForwards(u8, l.buf.items, l.buf.items[i + 1 ..]);
        l.buf.shrinkRetainingCapacity(l.buf.items.len - i - 1);
    }
}

fn flushAll(s: *Script, l: *Listener) void {
    emit(s, l);
    if (l.buf.items.len > 0 and s.world.diagnostics_unlocked) s.world.print("trace [{s}] {s}", .{ l.name.items, l.buf.items });
    l.buf.clearRetainingCapacity();
}

/// "[category][: ][message]", indented at the start of a line (§Z.4.3) unless `trace` (Trace.write does not
/// use the listener's indent).
fn put(s: *Script, l: *Listener, message: []const u8, category: []const u8, line: bool, trace: bool) !void {
    const d = diagOf(s);
    const at_line_start = l.buf.items.len == 0 or l.buf.items[l.buf.items.len - 1] == '\n';
    if (at_line_start and l.need_indent and !(trace and !line)) {
        const lvl = if (d.trace_indent) d.indent_level else l.indent_level;
        const size = if (d.trace_indent) d.indent_size else l.indent_size;
        try l.buf.appendNTimes(s.gpa, ' ', lvl * size);
    }
    if (category.len > 0) {
        try l.buf.appendSlice(s.gpa, category);
        try l.buf.appendSlice(s.gpa, ": ");
    }
    try l.buf.appendSlice(s.gpa, message);
    if (line) try l.buf.append(s.gpa, '\n');
    if (d.auto_flush) emit(s, l);
}

pub const Diagnostics = struct {
    pub const js_owner = true;

    fn trace(s: *Script) Value {
        return s.cx.dup(s.kept("Diagnostics.trace"));
    }
    fn listeners(s: *Script) Value {
        return s.cx.dup(s.kept("Diagnostics.listeners"));
    }

    const level_constants = [_]js.Member{
        js.constant("TRACE_LEVEL_ERROR", 1),
        js.constant("TRACE_LEVEL_WARNING", 2),
        js.constant("TRACE_LEVEL_INFO", 3),
    };

    pub const js_class: js.Class = .{
        .name = "Diagnostics",
        .members = &([_]js.Member{
            js.prop("trace", trace, null),
            js.prop("listeners", listeners, null),
        } ++ level_constants),
    };
};

fn checkLevel(level: u32) js.Error!void {
    if (level < 1 or level > 3) return error.Argument;
}

fn checkIndent(v: u32) js.Error!void {
    if (v > 15) return error.Argument;
}

pub const Trace = struct {
    pub const js_owner = true;

    fn getAutoFlush(s: *Script) bool {
        return diagOf(s).auto_flush;
    }
    fn setAutoFlush(s: *Script, v: bool) void {
        diagOf(s).auto_flush = v;
    }
    fn getIndentLevel(s: *Script) u32 {
        return diagOf(s).indent_level;
    }
    fn setIndentLevel(s: *Script, v: u32) js.Error!void {
        try checkIndent(v);
        diagOf(s).indent_level = v;
        diagOf(s).trace_indent = true;
    }
    fn getIndentSize(s: *Script) u32 {
        return diagOf(s).indent_size;
    }
    fn setIndentSize(s: *Script, v: u32) js.Error!void {
        try checkIndent(v);
        diagOf(s).indent_size = v;
        diagOf(s).trace_indent = true;
    }
    fn write(s: *Script, message: []const u8, category: []const u8, level: u32) js.Error!void {
        try checkLevel(level);
        for (diagOf(s).listeners.items) |l| try put(s, l, message, category, false, true);
    }
    fn writeLine(s: *Script, message: []const u8, category: []const u8, level: u32) js.Error!void {
        try checkLevel(level);
        for (diagOf(s).listeners.items) |l| try put(s, l, message, category, true, true);
    }
    fn flush(s: *Script) void {
        for (diagOf(s).listeners.items) |l| flushAll(s, l);
    }

    pub const js_class: js.Class = .{
        .name = "Trace",
        .members = &.{
            js.prop("autoFlush", getAutoFlush, setAutoFlush),
            js.prop("indentLevel", getIndentLevel, setIndentLevel),
            js.prop("indentSize", getIndentSize, setIndentSize),
            js.method("write", write),
            js.method("writeLine", writeLine),
            js.method("flush", flush),
        },
    };
};

pub const TraceListener = struct {
    fn getIndentLevel(l: *Listener) u32 {
        return l.indent_level;
    }
    fn setIndentLevel(l: *Listener, v: u32) js.Error!void {
        try checkIndent(v);
        l.indent_level = v;
    }
    fn getIndentSize(l: *Listener) u32 {
        return l.indent_size;
    }
    fn setIndentSize(l: *Listener, v: u32) js.Error!void {
        try checkIndent(v);
        l.indent_size = v;
    }
    fn getNeedIndent(l: *Listener) bool {
        return l.need_indent;
    }
    fn setNeedIndent(l: *Listener, v: bool) void {
        l.need_indent = v;
    }
    fn getName(l: *Listener) []const u8 {
        return l.name.items;
    }
    fn setName(l: *Listener, cx: *js.Context, v: []const u8) js.Error!void {
        l.name.clearRetainingCapacity();
        try l.name.appendSlice(cx.gpa, v);
    }
    fn write(l: *Listener, cx: *js.Context, message: []const u8, category: []const u8, level: u32) js.Error!void {
        try checkLevel(level);
        if (l.attached) try put(Script.of(cx), l, message, category, false, false);
    }
    fn writeLine(l: *Listener, cx: *js.Context, message: []const u8, category: []const u8, level: u32) js.Error!void {
        try checkLevel(level);
        if (l.attached) try put(Script.of(cx), l, message, category, true, false);
    }
    fn flush(l: *Listener, cx: *js.Context) void {
        flushAll(Script.of(cx), l);
    }

    pub const js_class: js.Class = .{
        .name = "TraceListener",
        .members = &.{
            js.prop("indentLevel", getIndentLevel, setIndentLevel),
            js.prop("indentSize", getIndentSize, setIndentSize),
            js.prop("needIndent", getNeedIndent, setNeedIndent),
            js.prop("name", getName, setName),
            js.method("write", write),
            js.method("writeLine", writeLine),
            js.method("flush", flush),
        },
    };
};

pub const Collection = struct {
    pub const js_owner = true;
    const max = 3;

    fn count(s: *Script) u32 {
        return @intCast(diagOf(s).listeners.items.len);
    }

    fn item(s: *Script, index: u32) js.Error!Value {
        const d = diagOf(s);
        if (index >= d.listeners.items.len) return error.ArgumentOutOfRange;
        return s.cx.dup(d.listeners.items[index].obj.?);
    }

    fn indexOf(s: *Script, v: Value) js.Error!u32 {
        const l = s.cx.unwrap(Listener, v) orelse return error.Argument;
        const i = std.mem.indexOfScalar(*Listener, diagOf(s).listeners.items, l) orelse return error.Argument;
        return @intCast(i);
    }

    fn add(s: *Script, kind: []const u8) js.Error!u32 {
        const d = diagOf(s);
        if (d.listeners.items.len >= max) return error.Overflow;
        const known = [_][]const u8{ "file", "network", "debugger" };
        const k = for (known) |x| {
            if (std.mem.eql(u8, x, kind)) break x;
        } else return error.ArgumentOutOfRange;
        if (!std.mem.eql(u8, k, "debugger")) return error.NotSupported;
        for (d.listeners.items) |l| if (std.mem.eql(u8, l.kind, k)) return error.Overflow;
        const l = try s.gpa.create(Listener);
        l.* = .{ .kind = k };
        errdefer {
            l.deinit(s.gpa);
            s.gpa.destroy(l);
        }
        try l.name.appendSlice(s.gpa, k);
        l.obj = try s.cx.wrapAs(Listener, &TraceListener.js_class, l);
        try d.listeners.append(s.gpa, l);
        return @intCast(d.listeners.items.len - 1);
    }

    fn remove(s: *Script, v: Value) js.Error!void {
        const i = try indexOf(s, v);
        const l = diagOf(s).listeners.orderedRemove(i);
        l.attached = false;
        // The object may still be held by script: the listener is kept until the context goes.
        s.apis.removed_listeners.append(s.gpa, l) catch {};
    }

    fn clear(s: *Script) void {
        const d = diagOf(s);
        while (d.listeners.pop()) |l| {
            l.attached = false;
            s.apis.removed_listeners.append(s.gpa, l) catch {};
        }
    }

    pub const js_class: js.Class = .{
        .name = "TraceListenerCollection",
        .members = &.{
            js.prop("count", count, null),
            js.method("item", item),
            js.method("indexOf", indexOf),
            js.method("add", add),
            js.method("remove", remove),
            js.method("clear", clear),
            js.constant("LISTENER_TYPE_FILE", "file"),
            js.constant("LISTENER_TYPE_NETWORK", "network"),
            js.constant("LISTENER_TYPE_DEBUGGER", "debugger"),
        },
    };
};

// ---- tests --------------------------------------------------------------------------------------------------------

const testenv = @import("testenv.zig");

test "Diagnostics" {
    const e = try testenv.Env.create();
    defer e.destroy();
    try e.run(
        \\var L = Diagnostics.listeners; assertEq(L.count, 0);
        \\assertThrows(function () { L.add("file"); }, "HDDVD_E_NOTSUPPORTED");
        \\assertThrows(function () { L.add("printer"); }, "HDDVD_E_ARGUMENTOUTOFRANGE");
        \\assertEq(L.add(L.LISTENER_TYPE_DEBUGGER), 0); assertEq(L.count, 1);
        \\assertThrows(function () { L.add("debugger"); }, "HDDVD_E_OVERFLOW");
        \\var l = L.item(0); assertEq(l, L.item(0)); assertEq(L.indexOf(l), 0); assertEq(l.name, "debugger");
        \\assertThrows(function () { L.item(1); }, "HDDVD_E_ARGUMENTOUTOFRANGE");
        \\var T = Diagnostics.trace; assertEq(T.indentSize, 4); assertEq(T.autoFlush, false);
        \\assertThrows(function () { T.indentLevel = 16; }, "HDDVD_E_ARGUMENT");
        \\T.indentLevel = 1; T.writeLine("hello", "cat", Diagnostics.TRACE_LEVEL_INFO); T.flush();
        \\assertThrows(function () { T.write("x", "c", 4); }, "HDDVD_E_ARGUMENT");
        \\L.remove(l); assertEq(L.count, 0); l.write("ignored", "", 1);
        \\assertThrows(function () { L.remove(l); }, "HDDVD_E_ARGUMENT");
        \\L.add("debugger"); L.clear(); assertEq(L.count, 0);
    , "diag.js");
}
