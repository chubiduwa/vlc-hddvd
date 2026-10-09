//! The script engine for Advanced Applications: QuickJS-ng (patched for the profile by src/qjs_patch.zig) with
//! the HD DVD rules on top (HD DVD Vol. 3 §8.2, Annex Z introduction):
//! - scripts are UTF-16BE with a byte order mark (§8.2.1); UTF-8 is accepted too;
//! - eval() and the Function constructors throw EvalError (§8.2.3); `with` and a missing semicolon are syntax
//!   errors (§8.2.6–7, in the patched parser);
//! - the Global object has a `global` property bound to itself (§8.2.5);
//! - API objects take no new properties and lose none (§8.2.4): they are not extensible and their properties
//!   are not configurable;
//! - arguments are converted by their Annex Z type (Tables Z-1 to Z-5), and API errors are Error objects whose
//!   message names the exception (Z.1.3).
//!
//! API objects are Zig values behind one QuickJS class: each wrapper points to a Box naming its `js.Class`, its
//! native type and the native value. A type describes itself with `pub const js_class: js.Class`, whose members
//! are Zig functions; bindings convert their arguments and results at comptime.
//!
//! One Runtime per engine thread; one Context per application (its own global object). No VLC dependency.

const std = @import("std");
pub const c = @import("quickjs");

pub const Value = c.JSValue;
pub const @"undefined" = mk(c.JS_TAG_UNDEFINED);
pub const @"null" = mk(c.JS_TAG_NULL);
const exception = mk(c.JS_TAG_EXCEPTION);

/// A value without a payload (translate-c cannot evaluate JS_MKVAL at comptime).
fn mk(comptime tg: c_int) Value {
    return .{ .u = .{ .int32 = 0 }, .tag = tg };
}

extern fn JS_ThrowEvalError(ctx: ?*c.JSContext, fmt: [*:0]const u8, ...) Value;

/// Why a binding failed. `Thrown`: an exception is pending in the context already.
pub const Error = error{
    Thrown,
    OutOfMemory,
    TypeError,
    RangeError,
    EvalError,
} || HdError;

/// The HD DVD exceptions (Annex Z.1.3): thrown as Error objects whose message is the exception's name.
pub const HdError = error{
    Argument,
    ArgumentOutOfRange,
    ArgumentNull,
    Format,
    Overflow,
    Io,
    PathTooLong,
    FileNotFound,
    NotSupported,
    InvalidOperation,
    UnspecifiedEventType,
    InvalidCall,
    NotEnoughSpace,
    Timeout,
    ProtocolViolation,
    Web,
};

/// The message of an HD DVD exception: "HDDVD_E_ARGUMENT" for error.Argument.
pub fn hdName(e: HdError) [:0]const u8 {
    return switch (e) {
        inline else => |x| comptime blk: {
            const n = @errorName(x);
            var up: [n.len:0]u8 = undefined;
            for (n, 0..) |ch, i| up[i] = std.ascii.toUpper(ch);
            const final = up;
            break :blk "HDDVD_E_" ++ &final;
        },
    };
}

// ---- types of arguments ----------------------------------------------------------------------------------------

/// "Number" arguments (Table Z-4): ToNumber of anything but undefined, null and booleans.
pub const Number = struct { v: f64 };

/// A nullable string argument (DOM): null and undefined give null, anything else ToString.
pub const NullStr = struct { s: ?[]const u8 };

/// The `this` value of a call, borrowed.
pub const This = struct { v: Value };

/// All the arguments of a call, borrowed.
pub const Args = struct { v: []const Value };

// ---- classes -----------------------------------------------------------------------------------------------------

/// How a Zig type appears in script. Several classes may share a native type (Element and Text are both
/// dom.Node): wrappers record the native type, and `unwrap` checks that.
pub const Class = struct {
    name: [:0]const u8,
    members: []const Member = &.{},
    /// The class whose prototype this one's inherits from (Element from Node).
    parent: ?*const Class = null,
    /// Called when the wrapper is collected (the Box owns the native value), or never (the native value is
    /// owned elsewhere and outlives its wrappers).
    finalize: ?*const fn (ptr: *anyopaque, rt: *Runtime) void = null,
    /// Marks the values the native value holds (the GC's cycle collector needs them).
    mark: ?*const fn (ptr: *anyopaque, rt: *c.JSRuntime, mark: ?*const c.JS_MarkFunc) void = null,
    /// Script may add properties to its objects (only Application Events, §8.2.4).
    extensible: bool = false,
    /// The prototype inherits from Error.prototype (DOMException, EventException: plain objects, not wrappers).
    error_proto: bool = false,
    /// Properties computed when read (NodeList items, document.<id>).
    exotic: ?*const Exotic = null,
};

/// Own properties an object computes: `obj[i]` for i < length (the ECMAScript bindings of NodeList and
/// NamedNodeMap), and named ones that the prototype chain does not have.
pub const Exotic = struct {
    length: ?*const fn (cx: *Context, ptr: *anyopaque) u32 = null,
    item: ?*const fn (cx: *Context, ptr: *anyopaque, i: u32) Error!Value = null,
    /// The value of property `name`, or null if there is none.
    named: ?*const fn (cx: *Context, ptr: *anyopaque, name: []const u8) Error!?Value = null,
};

pub const Member = struct {
    name: [:0]const u8,
    kind: union(enum) {
        method: struct { f: *const c.JSCFunction, length: u8 },
        accessor: struct { get: ?*const c.JSCFunction, set: ?*const c.JSCFunction },
        int: i64,
        float: f64,
        string: [:0]const u8,
    },
};

/// A function property bound to Zig function `f` (see `binding`).
pub fn method(comptime name: [:0]const u8, comptime f: anytype) Member {
    return .{ .name = name, .kind = .{ .method = .{ .f = binding(f), .length = comptime scriptArity(@TypeOf(f)) } } };
}

/// A property with a getter (`get`, no script arguments) and, unless null, a setter (`set`, one argument).
/// Without a setter, assignments are ignored (READONLY).
pub fn prop(comptime name: [:0]const u8, comptime get: anytype, comptime set: anytype) Member {
    return .{ .name = name, .kind = .{ .accessor = .{
        .get = binding(get),
        .set = if (@TypeOf(set) == @TypeOf(null)) null else binding(set),
    } } };
}

/// A "const" value property: DontEnum, DontDelete, ReadOnly.
pub fn constant(comptime name: [:0]const u8, comptime v: anytype) Member {
    return .{ .name = name, .kind = switch (@typeInfo(@TypeOf(v))) {
        .int, .comptime_int => .{ .int = v },
        .float, .comptime_float => .{ .float = v },
        else => .{ .string = v },
    } };
}

/// Identifies a native type (a mutable global, so never merged with another).
pub const Token = struct { name: [*:0]const u8 };

pub fn tokenOf(comptime T: type) *Token {
    return &struct {
        var t: Token = .{ .name = @typeName(T) };
    }.t;
}

const Box = struct {
    class: *const Class,
    token: *const Token,
    /// null once the native value is gone (`kill`).
    ptr: ?*anyopaque,
};

/// Detaches the wrapper object `obj` (a pointer kept with `objectPointer`) from its native value, which is going
/// away: the object stays, but it is no longer an API object of its type (methods throw TypeError) and its
/// finalizer is not called.
pub fn kill(rt: *Runtime, obj: *anyopaque) void {
    const v: Value = .{ .u = .{ .ptr = obj }, .tag = c.JS_TAG_OBJECT };
    const box: *Box = @ptrCast(@alignCast(c.JS_GetOpaque(v, rt.class) orelse c.JS_GetOpaque(v, rt.exotic_class) orelse return));
    box.ptr = null;
}

/// The object behind `v` (to find it again with `fromPointer`, without holding a reference).
pub fn objectPointer(v: Value) *anyopaque {
    return v.u.ptr.?;
}

/// A new reference to the object at `obj` (it must still be alive).
pub fn fromPointer(cx: *Context, obj: *anyopaque) Value {
    return cx.dup(.{ .u = .{ .ptr = obj }, .tag = c.JS_TAG_OBJECT });
}

fn boxOf(rt: *Runtime, v: Value) ?*Box {
    return @ptrCast(@alignCast(c.JS_GetOpaque(v, rt.class) orelse c.JS_GetOpaque(v, rt.exotic_class) orelse return null));
}

// ---- the runtime -------------------------------------------------------------------------------------------------

pub const Runtime = struct {
    rt: *c.JSRuntime,
    gpa: std.mem.Allocator,
    /// The class of API objects, and of those with computed properties.
    class: c.JSClassID = 0,
    exotic_class: c.JSClassID = 0,
    /// Set from another thread to abort the running script (the engine is shutting down, §8.5).
    stop: std.atomic.Value(bool) = .init(false),

    /// QuickJS allocates with the C heap of this module (never VLC's); `memory_limit` bounds it.
    pub fn create(gpa: std.mem.Allocator, memory_limit: usize) Error!*Runtime {
        const r = try gpa.create(Runtime);
        errdefer gpa.destroy(r);
        r.* = .{ .rt = c.JS_NewRuntime() orelse return error.OutOfMemory, .gpa = gpa };
        c.JS_SetRuntimeOpaque(r.rt, r);
        c.JS_SetMemoryLimit(r.rt, memory_limit);
        c.JS_SetInterruptHandler(r.rt, interrupt, r);
        _ = c.JS_NewClassID(r.rt, &r.class);
        _ = c.JS_NewClassID(r.rt, &r.exotic_class);
        const def: c.JSClassDef = .{ .class_name = "Object", .finalizer = finalizeBox, .gc_mark = markBox };
        const def2: c.JSClassDef = .{ .class_name = "Object", .finalizer = finalizeBox, .gc_mark = markBox, .exotic = &exotic_methods };
        if (c.JS_NewClass(r.rt, r.class, &def) != 0 or c.JS_NewClass(r.rt, r.exotic_class, &def2) != 0) {
            c.JS_FreeRuntime(r.rt);
            return error.OutOfMemory;
        }
        return r;
    }

    var exotic_methods: c.JSClassExoticMethods = .{ .get_own_property = exoticOwn, .get_own_property_names = exoticNames };

    fn exoticOwn(ctx: ?*c.JSContext, desc: [*c]c.JSPropertyDescriptor, obj: Value, atom: c.JSAtom) callconv(.c) c_int {
        const cx = Context.of(ctx);
        const box = boxOf(cx.rt, obj) orelse return 0;
        const ptr = box.ptr orelse return 0;
        const ex = box.class.exotic orelse return 0;
        var n: usize = 0;
        const name_c = c.JS_AtomToCStringLen(ctx, &n, atom) orelse return -1;
        defer c.JS_FreeCString(ctx, name_c);
        const name = name_c[0..n];
        const v: Value = blk: {
            if (ex.length) |len| if (indexOf(name)) |i| {
                if (i >= len(cx, ptr)) return 0;
                break :blk ex.item.?(cx, ptr, i) catch |e| {
                    _ = cx.throw(e);
                    return -1;
                };
            };
            const named = ex.named orelse return 0;
            // What the prototype chain has is not shadowed.
            const p = c.JS_GetPrototype(ctx, obj);
            defer cx.free(p);
            const has = c.JS_HasProperty(ctx, p, atom);
            if (has != 0) return if (has < 0) -1 else 0;
            const r = named(cx, ptr, name) catch |e| {
                _ = cx.throw(e);
                return -1;
            };
            break :blk r orelse return 0;
        };
        if (desc != null) {
            desc.* = .{ .flags = c.JS_PROP_ENUMERABLE, .value = v, .getter = @"undefined", .setter = @"undefined" };
        } else cx.free(v);
        return 1;
    }

    fn exoticNames(ctx: ?*c.JSContext, ptab: [*c][*c]c.JSPropertyEnum, plen: [*c]u32, obj: Value) callconv(.c) c_int {
        const cx = Context.of(ctx);
        ptab.* = null;
        plen.* = 0;
        const box = boxOf(cx.rt, obj) orelse return 0;
        const ptr = box.ptr orelse return 0;
        const ex = box.class.exotic orelse return 0;
        const len_f = ex.length orelse return 0;
        const n = len_f(cx, ptr);
        if (n == 0) return 0;
        const tab: [*]c.JSPropertyEnum = @ptrCast(@alignCast(c.js_mallocz(ctx, n * @sizeOf(c.JSPropertyEnum)) orelse return -1));
        for (0..n) |i| tab[i] = .{ .is_enumerable = true, .atom = c.JS_NewAtomUInt32(ctx, @intCast(i)) };
        ptab.* = tab;
        plen.* = n;
        return 0;
    }

    /// A canonical array index ("0", "12"; not "01" or "-1").
    fn indexOf(name: []const u8) ?u32 {
        if (name.len == 0 or name.len > 10) return null;
        if (name.len > 1 and name[0] == '0') return null;
        return std.fmt.parseInt(u32, name, 10) catch null;
    }

    /// All contexts must be destroyed first.
    pub fn destroy(r: *Runtime) void {
        c.JS_FreeRuntime(r.rt);
        r.gpa.destroy(r);
    }

    pub fn of(rt: ?*c.JSRuntime) *Runtime {
        return @ptrCast(@alignCast(c.JS_GetRuntimeOpaque(rt).?));
    }

    fn interrupt(_: ?*c.JSRuntime, data: ?*anyopaque) callconv(.c) c_int {
        const r: *Runtime = @ptrCast(@alignCast(data.?));
        return @intFromBool(r.stop.load(.monotonic));
    }

    fn finalizeBox(rt: ?*c.JSRuntime, v: Value) callconv(.c) void {
        const r = of(rt);
        const box = boxOf(r, v) orelse return;
        if (box.ptr) |p| if (box.class.finalize) |f| f(p, r);
        r.gpa.destroy(box);
    }

    fn markBox(rt: ?*c.JSRuntime, v: Value, mark: ?*const c.JS_MarkFunc) callconv(.c) void {
        const r = of(rt);
        const box = boxOf(r, v) orelse return;
        if (box.ptr) |p| if (box.class.mark) |f| f(p, rt.?, mark);
    }
};

// ---- a context -------------------------------------------------------------------------------------------------

pub const Context = struct {
    rt: *Runtime,
    ctx: *c.JSContext,
    gpa: std.mem.Allocator,
    /// Each API class's prototype in this context.
    protos: std.AutoHashMapUnmanaged(*const Class, Value) = .empty,
    /// What the API objects of this context belong to (the application's script host).
    owner: ?*anyopaque = null,
    /// Where uncaught exceptions are reported (`report`).
    log: ?*const fn (owner: ?*anyopaque, msg: []const u8) void = null,

    pub fn create(rt: *Runtime, owner: ?*anyopaque) Error!*Context {
        const cx = try rt.gpa.create(Context);
        errdefer rt.gpa.destroy(cx);
        cx.* = .{ .rt = rt, .ctx = c.JS_NewContext(rt.rt) orelse return error.OutOfMemory, .gpa = rt.gpa, .owner = owner };
        c.JS_SetContextOpaque(cx.ctx, cx);
        errdefer c.JS_FreeContext(cx.ctx);
        const g = cx.global();
        defer cx.free(g);
        // §8.2.3: the global eval throws EvalError, and nothing else is bound to the built-in one.
        try cx.defineValue(g, "eval", try cx.function("eval", throwEval, 1), c.JS_PROP_WRITABLE | c.JS_PROP_CONFIGURABLE);
        // §8.2.5.
        try cx.defineValue(g, "global", cx.dup(g), c.JS_PROP_WRITABLE | c.JS_PROP_CONFIGURABLE);
        return cx;
    }

    /// The owner must have released every value it holds.
    pub fn destroy(cx: *Context) void {
        var it = cx.protos.valueIterator();
        while (it.next()) |v| cx.free(v.*);
        cx.protos.deinit(cx.gpa);
        c.JS_FreeContext(cx.ctx);
        c.JS_RunGC(cx.rt.rt);
        cx.gpa.destroy(cx);
    }

    pub fn of(ctx: ?*c.JSContext) *Context {
        return @ptrCast(@alignCast(c.JS_GetContextOpaque(ctx).?));
    }

    fn throwEval(ctx: ?*c.JSContext, _: Value, _: c_int, _: [*c]Value) callconv(.c) Value {
        return JS_ThrowEvalError(ctx, "eval is not supported");
    }

    // ---- scripts ----

    /// Runs a script file (§8.2.1: UTF-16BE with a BOM; UTF-8, with or without a BOM, is accepted too).
    /// error.Thrown: it threw, or did not compile (see `takeException`).
    pub fn runScript(cx: *Context, bytes: []const u8, name: [:0]const u8) Error!void {
        const utf8 = try decodeScript(cx.gpa, bytes);
        defer cx.gpa.free(utf8);
        const v = c.JS_Eval(cx.ctx, utf8.ptr, utf8.len, name, c.JS_EVAL_TYPE_GLOBAL);
        if (c.JS_IsException(v)) return error.Thrown;
        cx.free(v);
    }

    /// Takes the pending exception, as text ("TypeError: message", and the stack if there is one).
    pub fn takeException(cx: *Context, gpa: std.mem.Allocator) ![]u8 {
        const e = c.JS_GetException(cx.ctx);
        defer cx.free(e);
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        {
            const s = cx.toStringAlloc(gpa, e) catch try gpa.dupe(u8, "(exception)");
            defer gpa.free(s);
            try out.appendSlice(gpa, s);
        }
        if (c.JS_IsObject(e)) {
            const st = c.JS_GetPropertyStr(cx.ctx, e, "stack");
            defer cx.free(st);
            if (c.JS_IsString(st)) {
                const s = cx.toStringAlloc(gpa, st) catch null;
                if (s) |x| {
                    defer gpa.free(x);
                    if (x.len > 0) {
                        try out.append(gpa, '\n');
                        try out.appendSlice(gpa, std.mem.trimEnd(u8, x, "\n"));
                    }
                }
            }
        }
        return out.toOwnedSlice(gpa);
    }

    /// Reports and clears the pending exception (an uncaught one: the work item ends, §8.5).
    pub fn report(cx: *Context, what: []const u8) void {
        const msg = cx.takeException(cx.gpa) catch return;
        defer cx.gpa.free(msg);
        const f = cx.log orelse return;
        var buf: [1024]u8 = undefined;
        f(cx.owner, std.fmt.bufPrint(&buf, "{s}: {s}", .{ what, msg }) catch msg);
    }

    /// Calls `f` with `this` and `args`; an exception is reported, not returned. The result is freed.
    pub fn callReport(cx: *Context, f: Value, this: Value, args: []const Value, what: []const u8) void {
        const r = cx.call(f, this, args) catch {
            cx.report(what);
            return;
        };
        cx.free(r);
    }

    /// Calls `f` (owned by the caller) with `this` and `args`; the result is the caller's.
    pub fn call(cx: *Context, f: Value, this: Value, args: []const Value) Error!Value {
        const r = c.JS_Call(cx.ctx, f, this, @intCast(args.len), @constCast(args.ptr));
        if (c.JS_IsException(r)) return error.Thrown;
        return r;
    }

    /// Runs pending jobs (promise reactions) of every context in the runtime.
    pub fn runJobs(cx: *Context) void {
        var ctx: ?*c.JSContext = null;
        while (c.JS_ExecutePendingJob(cx.rt.rt, &ctx) > 0) {}
    }

    // ---- values ----

    pub fn free(cx: *Context, v: Value) void {
        c.JS_FreeValue(cx.ctx, v);
    }

    pub fn dup(cx: *Context, v: Value) Value {
        return c.JS_DupValue(cx.ctx, v);
    }

    pub fn global(cx: *Context) Value {
        return c.JS_GetGlobalObject(cx.ctx);
    }

    pub fn string(cx: *Context, s: []const u8) Error!Value {
        return cx.check(c.JS_NewStringLen(cx.ctx, s.ptr, s.len));
    }

    pub fn number(cx: *Context, x: f64) Value {
        return c.JS_NewNumber(cx.ctx, x);
    }

    pub fn boolean(cx: *Context, b: bool) Value {
        return c.JS_NewBool(cx.ctx, b);
    }

    pub fn object(cx: *Context) Error!Value {
        return cx.check(c.JS_NewObject(cx.ctx));
    }

    pub fn array(cx: *Context) Error!Value {
        return cx.check(c.JS_NewArray(cx.ctx));
    }

    /// `a === b`.
    pub fn same(cx: *Context, a: Value, b: Value) bool {
        return c.JS_IsStrictEqual(cx.ctx, a, b);
    }

    pub fn isFunction(cx: *Context, v: Value) bool {
        return c.JS_IsFunction(cx.ctx, v);
    }

    pub fn function(cx: *Context, name: [:0]const u8, f: *const c.JSCFunction, length: u8) Error!Value {
        return cx.check(c.JS_NewCFunction2(cx.ctx, f, name, length, c.JS_CFUNC_generic, 0));
    }

    fn check(cx: *Context, v: Value) Error!Value {
        _ = cx;
        return if (c.JS_IsException(v)) error.Thrown else v;
    }

    /// Defines `obj[name] = v` (v is consumed) with JS_PROP_* `flags`.
    pub fn defineValue(cx: *Context, obj: Value, name: [:0]const u8, v: Value, flags: c_int) Error!void {
        if (c.JS_DefinePropertyValueStr(cx.ctx, obj, name, v, flags | c.JS_PROP_THROW) < 0) return error.Thrown;
    }

    pub fn get(cx: *Context, obj: Value, name: [:0]const u8) Error!Value {
        return cx.check(c.JS_GetPropertyStr(cx.ctx, obj, name));
    }

    /// `obj[name] = v` (v is consumed).
    pub fn set(cx: *Context, obj: Value, name: [:0]const u8, v: Value) Error!void {
        if (c.JS_SetPropertyStr(cx.ctx, obj, name, v) < 0) return error.Thrown;
    }

    pub fn setIndex(cx: *Context, obj: Value, i: u32, v: Value) Error!void {
        if (c.JS_SetPropertyUint32(cx.ctx, obj, i, v) < 0) return error.Thrown;
    }

    /// ToString, into memory from `gpa`.
    pub fn toStringAlloc(cx: *Context, gpa: std.mem.Allocator, v: Value) Error![]u8 {
        var len: usize = 0;
        const p = c.JS_ToCStringLen2(cx.ctx, &len, v, false) orelse return error.Thrown;
        defer c.JS_FreeCString(cx.ctx, p);
        return gpa.dupe(u8, p[0..len]);
    }

    // ---- exceptions ----

    /// Throws the exception for `e` (unless one is pending already: error.Thrown) and returns JS_EXCEPTION.
    pub fn throw(cx: *Context, e: Error) Value {
        return switch (e) {
            error.Thrown => exception,
            error.OutOfMemory => c.JS_ThrowOutOfMemory(cx.ctx),
            error.TypeError => c.JS_ThrowTypeError(cx.ctx, "invalid argument type"),
            error.RangeError => c.JS_ThrowRangeError(cx.ctx, "argument out of range"),
            error.EvalError => JS_ThrowEvalError(cx.ctx, "not supported"),
            inline else => |x| blk: {
                const err = c.JS_NewError(cx.ctx);
                if (c.JS_IsException(err)) break :blk err;
                const msg = c.JS_NewString(cx.ctx, hdName(x));
                _ = c.JS_DefinePropertyValueStr(cx.ctx, err, "message", msg, c.JS_PROP_WRITABLE | c.JS_PROP_CONFIGURABLE);
                break :blk c.JS_Throw(cx.ctx, err);
            },
        };
    }

    /// Throws `v` (consumed).
    pub fn throwValue(cx: *Context, v: Value) Error {
        _ = c.JS_Throw(cx.ctx, v);
        return error.Thrown;
    }

    // ---- API objects ----

    /// The prototype of API type T in this context (borrowed).
    pub fn proto(cx: *Context, comptime T: type) Error!Value {
        return cx.protoOf(&T.js_class);
    }

    /// The prototype of `class` in this context (borrowed), made on first use.
    pub fn protoOf(cx: *Context, class: *const Class) Error!Value {
        if (cx.protos.get(class)) |p| return p;
        const p = if (class.parent) |up|
            try cx.check(c.JS_NewObjectProto(cx.ctx, try cx.protoOf(up)))
        else if (class.error_proto) blk: {
            const g = cx.global();
            defer cx.free(g);
            const ctor = try cx.get(g, "Error");
            defer cx.free(ctor);
            const ep = try cx.get(ctor, "prototype");
            defer cx.free(ep);
            break :blk try cx.check(c.JS_NewObjectProto(cx.ctx, ep));
        } else try cx.object();
        errdefer cx.free(p);
        try cx.defineMembers(p, class.members);
        try cx.protos.put(cx.gpa, class, p);
        return p;
    }

    /// Defines `members` on `obj`: functions and accessors are DontDelete, constants DontEnum, DontDelete and
    /// ReadOnly.
    pub fn defineMembers(cx: *Context, obj: Value, members: []const Member) Error!void {
        for (members) |m| switch (m.kind) {
            .method => |f| try cx.defineValue(obj, m.name, try cx.function(m.name, f.f, f.length), c.JS_PROP_ENUMERABLE),
            .accessor => |a| {
                const g = if (a.get) |f| try cx.function(m.name, f, 0) else @"undefined";
                const s = if (a.set) |f| cx.function(m.name, f, 1) catch |e| {
                    cx.free(g);
                    return e;
                } else @"undefined";
                const atom = c.JS_NewAtom(cx.ctx, m.name);
                defer c.JS_FreeAtom(cx.ctx, atom);
                if (c.JS_DefinePropertyGetSet(cx.ctx, obj, atom, g, s, c.JS_PROP_ENUMERABLE | c.JS_PROP_THROW) < 0) return error.Thrown;
            },
            .int => |x| try cx.defineValue(obj, m.name, cx.number(@floatFromInt(x)), 0),
            .float => |x| try cx.defineValue(obj, m.name, cx.number(x), 0),
            .string => |s| try cx.defineValue(obj, m.name, try cx.string(s), 0),
        };
    }

    /// A new script object for `ptr`, of API type T (class T.js_class). The wrapper owns `ptr` if the class
    /// has a finalizer.
    pub fn wrap(cx: *Context, comptime T: type, ptr: *T) Error!Value {
        return cx.wrapAs(T, &T.js_class, ptr);
    }

    /// A new script object of `class` for native value `ptr` of type T.
    pub fn wrapAs(cx: *Context, comptime T: type, class: *const Class, ptr: *T) Error!Value {
        const p = try cx.protoOf(class);
        const box = try cx.gpa.create(Box);
        box.* = .{ .class = class, .token = tokenOf(T), .ptr = ptr };
        const obj = c.JS_NewObjectProtoClass(cx.ctx, p, if (class.exotic != null) cx.rt.exotic_class else cx.rt.class);
        if (c.JS_IsException(obj)) {
            cx.gpa.destroy(box);
            return error.Thrown;
        }
        _ = c.JS_SetOpaque(obj, box);
        if (!class.extensible) _ = c.JS_PreventExtensions(cx.ctx, obj);
        return obj;
    }

    /// The native value behind `v` if it is an API object of native type T.
    pub fn unwrap(cx: *Context, comptime T: type, v: Value) ?*T {
        const box = boxOf(cx.rt, v) orelse return null;
        if (box.token != tokenOf(T)) return null;
        return @ptrCast(@alignCast(box.ptr orelse return null));
    }

    /// The class of API object `v`, or null.
    pub fn classOf(cx: *Context, v: Value) ?*const Class {
        const box = boxOf(cx.rt, v) orelse return null;
        if (box.ptr == null) return null;
        return box.class;
    }

    /// Binds `name` on the Global object to a constructor function for API type T that throws `err` when
    /// called or constructed (Annex Z: TypeError; the XML API's: EvalError), with T's prototype and T's
    /// constants (`statics`) on it.
    pub fn exposeConstructor(cx: *Context, class: *const Class, comptime name: [:0]const u8, comptime err: Error, statics: []const Member) Error!void {
        const f = try cx.check(c.JS_NewCFunction2(cx.ctx, struct {
            fn call(ctx: ?*c.JSContext, _: Value, _: c_int, _: [*c]Value) callconv(.c) Value {
                return Context.of(ctx).throw(err);
            }
        }.call, name, 0, c.JS_CFUNC_constructor_or_func, 0));
        errdefer cx.free(f);
        const p = try cx.protoOf(class);
        if (c.JS_SetConstructor(cx.ctx, f, p) < 0) return error.Thrown;
        try cx.defineMembers(f, statics);
        const g = cx.global();
        defer cx.free(g);
        try cx.defineValue(g, name, f, 0);
    }
};

/// Decodes a script file to UTF-8 (NUL-terminated, as JS_Eval needs).
pub fn decodeScript(gpa: std.mem.Allocator, bytes: []const u8) Error![:0]u8 {
    if (bytes.len >= 2 and bytes[0] == 0xfe and bytes[1] == 0xff) return utf16beToUtf8(gpa, bytes[2..]);
    if (std.mem.startsWith(u8, bytes, "\xef\xbb\xbf")) return gpa.dupeSentinel(u8, bytes[3..], 0);
    return gpa.dupeSentinel(u8, bytes, 0);
}

/// UTF-16BE to UTF-8; unpaired surrogates become U+FFFD.
fn utf16beToUtf8(gpa: std.mem.Allocator, b: []const u8) Error![:0]u8 {
    var out: std.ArrayList(u8) = try .initCapacity(gpa, b.len);
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i + 1 < b.len) : (i += 2) {
        var cp: u21 = std.mem.readInt(u16, b[i..][0..2], .big);
        if (cp >= 0xd800 and cp < 0xdc00 and i + 3 < b.len) {
            const lo = std.mem.readInt(u16, b[i + 2 ..][0..2], .big);
            if (lo >= 0xdc00 and lo < 0xe000) {
                cp = 0x10000 + ((cp - 0xd800) << 10) + (lo - 0xdc00);
                i += 2;
            } else cp = 0xfffd;
        } else if (cp >= 0xd800 and cp < 0xe000) cp = 0xfffd;
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &buf) catch unreachable;
        try out.appendSlice(gpa, buf[0..n]);
    }
    return out.toOwnedSliceSentinel(gpa, 0);
}

// ---- Annex Z argument types (Tables Z-1 to Z-5) --------------------------------------------------------------

fn tag(v: Value) i64 {
    return c.JS_VALUE_GET_TAG(v);
}

/// The number an int, unsigned int or double argument stands for (Tables Z-1 to Z-3, before the range check):
/// undefined, null and booleans are TypeErrors; strings ToNumber; objects ToPrimitive (hint String), ToNumber.
fn numericArg(cx: *Context, v: Value) Error!f64 {
    if (c.JS_IsUndefined(v) or c.JS_IsNull(v) or c.JS_IsBool(v)) return error.TypeError;
    if (c.JS_IsNumber(v)) {
        var d: f64 = 0;
        _ = c.JS_ToFloat64(cx.ctx, &d, v);
        return d;
    }
    if (c.JS_IsString(v)) return toNumber(cx, v);
    if (c.JS_IsObject(v)) {
        const s = c.JS_ToString(cx.ctx, v);
        if (c.JS_IsException(s)) return error.Thrown;
        defer cx.free(s);
        return toNumber(cx, s);
    }
    return error.TypeError;
}

fn toNumber(cx: *Context, v: Value) Error!f64 {
    var d: f64 = 0;
    if (c.JS_ToFloat64(cx.ctx, &d, v) < 0) return error.Thrown;
    return d;
}

/// "int" (Table Z-1).
pub fn toInt(cx: *Context, v: Value) Error!i32 {
    const d = try numericArg(cx, v);
    if (std.math.isNan(d)) return error.TypeError;
    if (d < -2147483648.0 or d > 2147483647.0) return error.RangeError;
    return @intFromFloat(@trunc(d));
}

/// "unsigned int" (Table Z-2).
pub fn toUint(cx: *Context, v: Value) Error!u32 {
    const d = try numericArg(cx, v);
    if (std.math.isNan(d)) return error.TypeError;
    if (d < 0 or d > 4294967295.0) return error.RangeError;
    return @intFromFloat(@trunc(d));
}

/// "double" (Table Z-3).
pub fn toDouble(cx: *Context, v: Value) Error!f64 {
    const d = try numericArg(cx, v);
    if (std.math.isInf(d)) return error.RangeError;
    if (std.math.isNan(d)) return error.TypeError;
    return d;
}

/// "Number" (Table Z-4).
pub fn toNumberArg(cx: *Context, v: Value) Error!f64 {
    if (c.JS_IsUndefined(v) or c.JS_IsNull(v) or c.JS_IsBool(v)) return error.TypeError;
    return toNumber(cx, v);
}

/// "Boolean" (Table Z-5).
pub fn toBool(cx: *Context, v: Value) Error!bool {
    if (c.JS_IsUndefined(v)) return error.TypeError;
    const r = c.JS_ToBool(cx.ctx, v);
    if (r < 0) return error.Thrown;
    return r != 0;
}

// ---- bindings ------------------------------------------------------------------------------------------------

/// How many script arguments a bound function takes (its `length`).
fn scriptArity(comptime F: type) u8 {
    var n: u8 = 0;
    for (@typeInfo(F).@"fn".param_types, 0..) |p, i| {
        if (i == 0 and p.? != *Context) continue; // self
        if (consumesArg(p.?)) n += 1;
    }
    return n;
}

fn consumesArg(comptime T: type) bool {
    return T != *Context and T != This and T != Args;
}

/// A C function for Zig function `f`. Its first parameter is the object: `*T` for API type T (TypeError if
/// `this` is not one), `*O` for a type with `pub const js_owner = true` (the context's owner, whatever `this`
/// is: the Global/Application object's members), or `*Context`. Further
/// parameters take the script arguments in order, converted by type:
///   i32 int, u32 unsigned int, f64 double, Number, bool Boolean, []const u8 String (ToString; valid during the
///   call), NullStr, Value (borrowed, as is), ?X (X, or null when the argument is absent or undefined);
///   *Context, This and Args take no argument.
/// Results: void, bool, integers, f64, []const u8 (a new string), ?X (null), Value (owned, returned as is);
/// an error throws (see Context.throw).
pub fn binding(comptime f: anytype) *const c.JSCFunction {
    const F = @TypeOf(f);
    const info = @typeInfo(F).@"fn";
    return struct {
        fn call(ctx: ?*c.JSContext, this: Value, argc: c_int, argv: [*c]Value) callconv(.c) Value {
            const cx = Context.of(ctx);
            const given: []const Value = if (argc > 0) argv[0..@intCast(argc)] else &.{};
            var args: std.meta.ArgsTuple(F) = undefined;
            var strings: [info.param_types.len]?[*c]const u8 = @splat(null);
            defer for (strings) |s| if (s) |p| c.JS_FreeCString(ctx, p);
            var next: usize = 0;
            inline for (info.param_types, 0..) |p, i| {
                const P = p.?;
                if (i == 0 and P != *Context) {
                    const Self = @typeInfo(P).pointer.child;
                    if (@hasDecl(Self, "js_owner")) {
                        args[0] = @ptrCast(@alignCast(cx.owner.?));
                    } else {
                        args[0] = cx.unwrap(Self, this) orelse return c.JS_ThrowTypeError(ctx, "not a " ++ comptime shortName(Self));
                    }
                } else if (P == *Context) {
                    args[i] = cx;
                } else if (P == This) {
                    args[i] = .{ .v = this };
                } else if (P == Args) {
                    args[i] = .{ .v = given };
                } else {
                    const v = if (next < given.len) given[next] else @"undefined";
                    next += 1;
                    args[i] = convertArg(cx, P, v, &strings[i]) catch |e| return cx.throw(e);
                }
            }
            const r = @call(.auto, f, args);
            return result(cx, r);
        }
    }.call;
}

/// The name of an API type in messages: its class's, else the last part of the Zig type name.
fn shortName(comptime T: type) [:0]const u8 {
    if (@hasDecl(T, "js_class")) return T.js_class.name;
    const n = @typeName(T);
    const dot = std.mem.lastIndexOfScalar(u8, n, '.') orelse return n;
    return n[dot + 1 ..];
}

fn convertArg(cx: *Context, comptime P: type, v: Value, str: *?[*c]const u8) Error!P {
    if (@typeInfo(P) == .optional) {
        if (c.JS_IsUndefined(v)) return null;
        return try convertArg(cx, @typeInfo(P).optional.child, v, str);
    }
    return switch (P) {
        i32 => toInt(cx, v),
        u32 => toUint(cx, v),
        f64 => toDouble(cx, v),
        Number => .{ .v = try toNumberArg(cx, v) },
        bool => toBool(cx, v),
        Value => v,
        []const u8 => blk: {
            var len: usize = 0;
            const p = c.JS_ToCStringLen2(cx.ctx, &len, v, false) orelse return error.Thrown;
            str.* = p;
            break :blk p[0..len];
        },
        NullStr => if (c.JS_IsNull(v) or c.JS_IsUndefined(v)) .{ .s = null } else .{ .s = try convertArg(cx, []const u8, v, str) },
        else => @compileError("unsupported argument type " ++ @typeName(P)),
    };
}

fn result(cx: *Context, r: anytype) Value {
    const R = @TypeOf(r);
    switch (@typeInfo(R)) {
        .error_union => {
            const x = r catch |e| return cx.throw(e);
            return result(cx, x);
        },
        .optional => return if (r) |x| result(cx, x) else @"null",
        .void => return @"undefined",
        .bool => return cx.boolean(r),
        .int, .comptime_int => return cx.number(@floatFromInt(r)),
        .float, .comptime_float => return cx.number(r),
        else => {},
    }
    if (R == Value) return r;
    if (R == []const u8 or R == []u8 or R == [:0]const u8) return cx.string(r) catch |e| cx.throw(e);
    @compileError("unsupported result type " ++ @typeName(R));
}

// ---- tests ---------------------------------------------------------------------------------------------------

pub const testing = struct {
    /// Assertions for JS tests: assert(cond, msg), assertEq(actual, expected, msg) (=== or both NaN),
    /// assertThrows(fn, check, msg) where check is an error constructor (instanceof) or a message string.
    pub const prelude =
        \\function assert(c, m) { if (!c) { throw new Error("assertion failed: " + (m || "")); } }
        \\function __same(a, b) { return a === b || (a !== a && b !== b); }
        \\function __show(x) { return typeof x === "string" ? "\"" + x + "\"" : String(x); }
        \\function assertEq(a, b, m) {
        \\  if (!__same(a, b)) { throw new Error("expected " + __show(b) + ", got " + __show(a) + (m ? ": " + m : "")); }
        \\}
        \\function assertThrows(f, check, m) {
        \\  try { f(); } catch (e) {
        \\    if (typeof check === "string") { assertEq(e && e.message, check, m); }
        \\    else if (check) { assert(e instanceof check, (m || "") + ": threw " + e); }
        \\    return e;
        \\  }
        \\  throw new Error("did not throw: " + (m || ""));
        \\}
        \\
    ;

    /// Runs `src` after the prelude in `cx`; a failure fails the test with the exception and its stack.
    pub fn run(cx: *Context, src: []const u8, name: [:0]const u8) !void {
        cx.runScript(prelude, "prelude.js") catch return fail(cx, "prelude.js");
        cx.runScript(src, name) catch return fail(cx, name);
        cx.runJobs();
    }

    pub fn fail(cx: *Context, name: []const u8) error{JsTestFailed} {
        const msg = cx.takeException(std.testing.allocator) catch return error.JsTestFailed;
        defer std.testing.allocator.free(msg);
        std.debug.print("{s}: {s}\n", .{ name, msg });
        return error.JsTestFailed;
    }
};

const t = std.testing;

/// An API type for the tests: echoes each Annex Z argument type.
const Probe = struct {
    count: u32 = 0,
    log: std.ArrayList(u8) = .empty,

    pub const js_class: Class = .{
        .name = "Probe",
        .members = &.{
            method("int", int),
            method("uint", uint),
            method("double", double),
            method("number", number),
            method("boolean", boolean),
            method("string", string),
            method("nullable", nullable),
            method("optional", optional),
            method("fail", fail),
            prop("count", getCount, setCount),
            prop("readonly", getCount, null),
            constant("ANSWER", 42),
        },
    };

    fn int(_: *Probe, x: i32) i32 {
        return x;
    }
    fn uint(_: *Probe, x: u32) u32 {
        return x;
    }
    fn double(_: *Probe, x: f64) f64 {
        return x;
    }
    fn number(_: *Probe, x: Number) f64 {
        return x.v;
    }
    fn boolean(_: *Probe, x: bool) bool {
        return x;
    }
    fn string(p: *Probe, cx: *Context, x: []const u8) ![]const u8 {
        p.log.clearRetainingCapacity();
        try p.log.appendSlice(cx.gpa, x);
        return p.log.items;
    }
    fn nullable(_: *Probe, x: NullStr) ?[]const u8 {
        return x.s;
    }
    fn optional(_: *Probe, x: ?i32) i32 {
        return x orelse -1;
    }
    fn fail(_: *Probe, which: u32) Error!void {
        return switch (which) {
            0 => error.Argument,
            1 => error.ArgumentOutOfRange,
            else => error.InvalidOperation,
        };
    }
    fn getCount(p: *Probe) u32 {
        return p.count;
    }
    fn setCount(p: *Probe, x: u32) void {
        p.count = x;
    }
};

fn probeContext() !struct { *Runtime, *Context } {
    const rt = try Runtime.create(t.allocator, 64 << 20);
    errdefer rt.destroy();
    const cx = try Context.create(rt, null);
    return .{ rt, cx };
}

test "the HD DVD script profile" {
    const rt, const cx = try probeContext();
    defer rt.destroy();
    defer cx.destroy();
    try testing.run(cx,
        \\assert(global === this, "global");
        \\assertThrows(function () { eval("1;"); }, EvalError, "eval");
        \\assertThrows(function () { var e = eval; e("1;"); }, EvalError, "indirect eval");
        \\assertThrows(function () { Function("return 1;"); }, EvalError, "Function");
        \\assertThrows(function () { new Function("return 1;"); }, EvalError, "new Function");
        \\assertThrows(function () { (function () {}).constructor("return 1;"); }, EvalError, "constructor");
        \\var f = function () { };
        \\f();
    , "profile.js");
    // §8.2.6–7: syntax errors.
    for ([_][]const u8{ "var a = 1\nvar b = 2;", "var o = {}; with (o) { }", "function f() { return 1 }", "do { } while (false) var x;" }) |src| {
        try t.expectError(error.Thrown, cx.runScript(src, "bad.js"));
        const msg = try cx.takeException(t.allocator);
        defer t.allocator.free(msg);
        try t.expect(std.mem.startsWith(u8, msg, "SyntaxError"));
    }
    try cx.runScript("do { } while (false);", "ok.js");
}

test "scripts are UTF-16BE with a byte order mark" {
    const rt, const cx = try probeContext();
    defer rt.destroy();
    defer cx.destroy();
    // var s = "é😀";
    const src = "\xfe\xff\x00v\x00a\x00r\x00 \x00s\x00 \x00=\x00 \x00\"\x00\xe9\xd8\x3d\xde\x00\x00\"\x00;";
    cx.runScript(src, "utf16.js") catch return testing.fail(cx, "utf16.js");
    try testing.run(cx, "assertEq(s, \"\u{e9}\u{1f600}\"); assertEq(s.length, 3);", "check.js");
}

test "Annex Z argument types, exceptions and API objects" {
    const rt, const cx = try probeContext();
    defer rt.destroy();
    defer cx.destroy();
    var probe: Probe = .{};
    defer probe.log.deinit(t.allocator);
    const g = cx.global();
    defer cx.free(g);
    try cx.defineValue(g, "probe", try cx.wrap(Probe, &probe), 0);
    try cx.exposeConstructor(&Probe.js_class, "Probe", error.TypeError, &.{constant("ANSWER", 42)});
    try testing.run(cx,
        \\// int (Table Z-1)
        \\assertEq(probe.int(3.9), 3); assertEq(probe.int(-3.9), -3); assertEq(probe.int("12"), 12);
        \\assertEq(probe.int({ toString: function () { return "7"; } }), 7);
        \\assertThrows(function () { probe.int(); }, TypeError, "undefined");
        \\assertThrows(function () { probe.int(null); }, TypeError, "null");
        \\assertThrows(function () { probe.int(true); }, TypeError, "boolean");
        \\assertThrows(function () { probe.int(NaN); }, TypeError, "NaN");
        \\assertThrows(function () { probe.int("x"); }, TypeError, "not a number");
        \\assertThrows(function () { probe.int(2147483648); }, RangeError, "too big");
        \\assertThrows(function () { probe.int(-Infinity); }, RangeError, "-Infinity");
        \\assertEq(probe.int(-2147483648), -2147483648);
        \\// unsigned int (Table Z-2)
        \\assertEq(probe.uint(4294967295), 4294967295);
        \\assertThrows(function () { probe.uint(-1); }, RangeError, "negative");
        \\assertThrows(function () { probe.uint(4294967296); }, RangeError, "2^32");
        \\// double (Table Z-3)
        \\assertEq(probe.double("1.5"), 1.5);
        \\assertThrows(function () { probe.double(Infinity); }, RangeError, "Infinity");
        \\assertThrows(function () { probe.double(NaN); }, TypeError, "NaN");
        \\// Number (Table Z-4)
        \\assertEq(probe.number(NaN), NaN); assertEq(probe.number("2"), 2); assertEq(probe.number(Infinity), Infinity);
        \\assertThrows(function () { probe.number(false); }, TypeError, "Number boolean");
        \\// Boolean (Table Z-5)
        \\assertEq(probe.boolean(null), false); assertEq(probe.boolean("x"), true); assertEq(probe.boolean(0), false);
        \\assertThrows(function () { probe.boolean(); }, TypeError, "Boolean undefined");
        \\// String
        \\assertEq(probe.string(12), "12"); assertEq(probe.string(), "undefined"); assertEq(probe.string(null), "null");
        \\assertEq(probe.nullable(null), null); assertEq(probe.nullable("a"), "a");
        \\assertEq(probe.optional(), -1); assertEq(probe.optional(5), 5);
        \\// Exceptions (Z.1.3): Error objects whose message names them.
        \\var e = assertThrows(function () { probe.fail(0); }, "HDDVD_E_ARGUMENT");
        \\assert(e instanceof Error, "an Error");
        \\assertThrows(function () { probe.fail(1); }, "HDDVD_E_ARGUMENTOUTOFRANGE");
        \\assertThrows(function () { probe.fail(2); }, "HDDVD_E_INVALIDOPERATION");
        \\// Properties.
        \\probe.count = 5; assertEq(probe.count, 5); assertEq(probe.readonly, 5);
        \\probe.readonly = 9; assertEq(probe.readonly, 5, "readonly ignores assignments");
        \\assertThrows(function () { probe.count = -1; }, RangeError, "setter types");
        \\assertEq(probe.ANSWER, 42); probe.ANSWER = 1; assertEq(probe.ANSWER, 42, "const");
        \\// §8.2.4: no new properties, none deleted.
        \\probe.extra = 1; assertEq(probe.extra, undefined, "not extensible");
        \\delete probe.count; assertEq(probe.count, 5);
        \\assertEq(delete Object.getPrototypeOf(probe).count, false, "DontDelete"); assertEq(probe.count, 5);
        \\// Annex Z: constructors throw.
        \\assertThrows(function () { Probe(); }, TypeError, "called");
        \\assertThrows(function () { new Probe(); }, TypeError, "constructed");
        \\assert(probe instanceof Probe, "instanceof"); assertEq(Probe.ANSWER, 42);
        \\// A method on the wrong object.
        \\assertThrows(function () { probe.int.call({}, 1); }, TypeError, "this");
    , "types.js");
}
