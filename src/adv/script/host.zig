//! The script host of one Advanced Application (HD DVD Vol. 3 Ch. 8, Annex Z.1, Z.2): its script context, whose
//! Global object merges the Application object and the XML object (Annex Z introduction), its event listeners,
//! its work-item queue (§8.5), its timers, and the bridge between the DOM bindings and the markup page.
//!
//! The engine (markup/apps.zig) owns the applications and their lifecycle; it creates a Script when an
//! application loads, delivers events to it in priority order (`Delivery`, §8.3.6) and runs its work items each
//! tick. Everything here runs on the engine thread. A `World` is shared by all applications of one engine.
//! No VLC dependency.

const std = @import("std");
const js = @import("js.zig");
const events = @import("events.zig");
const sched = @import("sched.zig");
const dom = @import("../dom.zig");
const xpath = @import("../xpath.zig");
const uri = @import("../uri.zig");
const xpl = @import("../xpl.zig");
const page_mod = @import("../markup/page.zig");
const dom_api = @import("dom_api.zig");
const anim_api = @import("anim_api.zig");
const xml_api = @import("xml_api.zig");
const files_mod = @import("files.zig");
const apps = @import("../markup/apps.zig");
const api = @import("api.zig");
const engine = @import("../engine/engine.zig");
const planes = @import("../planes.zig");
const controller_api = @import("controller_api.zig");
const player_api = @import("player_api.zig");
const fileio_api = @import("fileio_api.zig");

const c = js.c;
const Value = js.Value;
const Page = page_mod.Page;

/// What all applications of an engine share.
pub const World = struct {
    gpa: std.mem.Allocator,
    rt: *js.Runtime,
    /// Engine time at the current tick (µs), application ticks since the engine started, and their rate.
    now_us: i64 = 0,
    tick: u64 = 0,
    tick_rate: f64 = 60000.0 / 1001.0,
    /// Frames per second of the title time base, and the title time on screen (frames).
    fps: u64 = 60,
    title_time: u64 = 0,
    /// The Title Timeline progresses at normal speed (title timers count).
    title_running: bool = true,
    /// state:focused is in global state (§7.6.3.4.1): one for all applications.
    focus_locked: bool = false,
    files: ?*files_mod.Files = null,
    /// The engine's applications (null in tests of a lone script).
    apps: ?*apps.Apps = null,
    log: ?*const fn (ctx: *anyopaque, msg: []const u8) void = null,
    log_ctx: *anyopaque = undefined,
    next_uid: u64 = 1,
    /// Diagnostics are locked unless the player unlocks them (§8.6.2); this player unlocks them (its
    /// debugger listener writes to the log).
    diagnostics_unlocked: bool = true,
    /// The engine, during a tick (its cursor, its commands to the demux).
    eng: ?*engine.Engine = null,
    /// The cursor when there is no engine (a lone script in tests).
    lone_cursor: planes.Cursor = .init(1920, 1080),
    cursor: controller_api.CursorState = .{},
    aperture_w: u32 = 1920,
    aperture_h: u32 = 1080,
    /// The playlist, its URI, the current title (null: the First Play title or none).
    pl: ?*const xpl.Playlist = null,
    playlist_uri: []const u8 = "",
    title_index: ?u16 = null,
    content_id: []const u8 = "",
    streaming_buffer_kb: u32 = 0,
    /// The Title Timeline is paused (by script or VLC).
    paused: bool = false,
    /// The disc has Standard Content too (Category 3).
    has_standard_content: bool = false,
    /// Network access (Vol. 3 Ch. 9): off.
    network_allowed: bool = false,
    network_kbps: u32 = 0,
    /// The Player API's state and system parameters, shared by all applications.
    model: player_api.Model = .{},
    player_tracks: player_api.TrackSel = .{ .player = true },
    /// Room for a system variable's text.
    var_buf: [16]u8 = undefined,

    pub fn create(gpa: std.mem.Allocator) !*World {
        const w = try gpa.create(World);
        errdefer gpa.destroy(w);
        w.* = .{ .gpa = gpa, .rt = try js.Runtime.create(gpa, 256 << 20) };
        return w;
    }

    pub fn destroy(w: *World) void {
        w.model.deinit(w.gpa);
        w.cursor.deinit(w.gpa);
        w.rt.destroy();
        w.gpa.destroy(w);
    }

    pub fn print(w: *World, comptime fmt: []const u8, args: anytype) void {
        const f = w.log orelse return;
        var buf: [1024]u8 = undefined;
        f(w.log_ctx, std.fmt.bufPrint(&buf, fmt, args) catch return);
    }

    pub fn nowMs(w: *const World) f64 {
        return @as(f64, @floatFromInt(w.now_us)) / 1000.0;
    }
};

// ---- events between applications ------------------------------------------------------------------------------------

pub const Flow = enum {
    /// User input: script first, then the markup's defaults, in each application.
    input,
    /// System events: to the Application object.
    system,
    /// Application events (createEvent + Application.dispatchEvent, markup <event>).
    app,
};

pub const Input = struct {
    kind: enum { key_down, key_up, cursor_move, vector },
    key: u8 = 0,
    /// The cursor position (canvas coordinates) for pointer events.
    x: i32 = 0,
    y: i32 = 0,
    pointer: bool = false,
};

/// An event on its way through the applications (§8.3.6), owned by the queue it is in.
pub const Delivery = struct {
    arena: std.heap.ArenaAllocator,
    rt: *js.Runtime,
    flow: Flow,
    spec: events.Spec,
    /// Applications it went through (Script uids), and the ones it may go to (null: all).
    visited: std.ArrayList(u64) = .empty,
    recipients: ?[]const u64 = null,
    prevented: bool = false,
    /// A markup <event>: the application that raised it and its element (the target there).
    origin: ?u64 = null,
    origin_node: ?*dom.Node = null,
    input: ?Input = null,

    pub fn create(gpa: std.mem.Allocator, rt: *js.Runtime, flow: Flow, spec: events.Spec) !*Delivery {
        const d = try gpa.create(Delivery);
        d.* = .{ .arena = .init(gpa), .rt = rt, .flow = flow, .spec = spec };
        errdefer d.destroy();
        const a = d.arena.allocator();
        d.spec.type = try a.dupe(u8, spec.type);
        if (spec.id) |s| d.spec.id = try a.dupe(u8, s);
        if (spec.uri) |s| d.spec.uri = try a.dupe(u8, s);
        if (spec.time) |s| d.spec.time = try a.dupe(u8, s);
        if (spec.elapsed) |s| d.spec.elapsed = try a.dupe(u8, s);
        if (spec.key.code) |s| d.spec.key.code = try a.dupe(u8, s);
        return d;
    }

    pub fn destroy(d: *Delivery) void {
        for (d.spec.extras) |x| c.JS_FreeValueRT(d.rt.rt, x.value);
        const gpa = d.arena.child_allocator;
        d.arena.deinit();
        gpa.destroy(d);
    }

    pub fn wasVisited(d: *const Delivery, uid: u64) bool {
        return std.mem.indexOfScalar(u64, d.visited.items, uid) != null;
    }

    pub fn mayVisit(d: *const Delivery, uid: u64) bool {
        if (d.wasVisited(uid)) return false;
        const r = d.recipients orelse return true;
        return std.mem.indexOfScalar(u64, r, uid) != null;
    }
};

/// How an event went in one application.
pub const Outcome = struct { stopped: bool, prevented: bool };

pub const Job = union(enum) {
    /// An Event object of this context, dispatched on a path fixed when it was queued (DOM dispatchEvent,
    /// mutation events): the nodes from the top down to the target, under the Application object if
    /// `app_top`. `hold` keeps the target's document alive.
    local: struct { ev: Value, path: []*dom.Node, app_top: bool, hold: Value },
    delivery: *Delivery,
    timer: *Timer,
    /// A callback with its arguments (owned), e.g. an asynchronous API's result.
    call: struct { f: Value, args: []Value, what: []const u8 },
};

// ---- the script host --------------------------------------------------------------------------------------------

pub const Script = struct {
    /// Members of the Global/Application object take the Script as `self`.
    pub const js_owner = true;
    pub const js_class: js.Class = application_class;

    gpa: std.mem.Allocator,
    world: *World,
    /// Its application in the engine (null for a lone script in tests).
    app: ?*apps.App,
    uid: u64,
    cx: *js.Context,
    reg: events.Registry = .{},
    queue: sched.Queue(Job) = .{},
    /// The Application object, and the XMLParser object.
    app_obj: Value = js.null,
    parser_obj: Value = js.null,
    parser: xml_api.Parser = .{},
    /// Objects of the API (FileIO, Player…) made once per context, released with it.
    singletons: std.ArrayList(Value) = .empty,
    named: std.StringHashMapUnmanaged(Value) = .empty,
    markup_loaded: Value = js.null,
    timers: std.ArrayList(*Timer) = .empty,
    overrides: anim_api.Overrides,
    /// The current page's document (the AnimatableDocument).
    page_doc: ?*dom.Document = null,
    /// The page's tree changed: it is resynced before the next layout.
    tree_dirty: bool = false,
    /// AdvancedApplication objects, by application.
    app_objs: std.AutoHashMapUnmanaged(*apps.App, Value) = .empty,
    /// Being destroyed: nothing is queued any more.
    closing: bool = false,
    /// The API objects' per-context state (api.zig).
    apis: api.State = .{},
    text_streams: std.ArrayList(*fileio_api.TextStream) = .empty,

    pub fn create(world: *World, app: ?*apps.App) !*Script {
        const gpa = world.gpa;
        const s = try gpa.create(Script);
        s.* = .{ .gpa = gpa, .world = world, .app = app, .uid = world.next_uid, .cx = undefined, .overrides = .init(gpa) };
        world.next_uid += 1;
        s.cx = js.Context.create(world.rt, s) catch |e| {
            s.overrides.deinit(gpa);
            gpa.destroy(s);
            return e;
        };
        s.cx.log = logException;
        errdefer s.destroy();
        s.setupGlobal() catch |e| {
            if (e == error.Thrown) s.cx.report("setup");
            return e;
        };
        return s;
    }

    pub fn destroy(s: *Script) void {
        s.closing = true;
        const gpa = s.gpa;
        if (s.page_doc) |d| dom_api.releaseDocument(s, d);
        s.page_doc = null;
        s.dropJobs();
        s.queue.deinit(gpa);
        for (s.timers.items) |tm| tm.destroy(s);
        s.timers.deinit(gpa);
        s.apis.deinit(s);
        s.text_streams.deinit(gpa);
        s.reg.deinit(s.cx);
        s.reg = .{};
        var it = s.app_objs.iterator();
        while (it.next()) |kv| s.cx.free(kv.value_ptr.*);
        s.app_objs.deinit(gpa);
        for (s.singletons.items) |v| s.cx.free(v);
        s.singletons.deinit(gpa);
        var keys = s.named.keyIterator();
        while (keys.next()) |k| gpa.free(k.*);
        s.named.deinit(gpa);
        s.cx.free(s.markup_loaded);
        s.cx.free(s.parser_obj);
        s.cx.free(s.app_obj);
        s.overrides.deinit(gpa);
        s.cx.destroy();
        s.parser.deinit(gpa);
        gpa.destroy(s);
    }

    pub fn of(cx: *js.Context) *Script {
        return @ptrCast(@alignCast(cx.owner.?));
    }

    fn logException(owner: ?*anyopaque, msg: []const u8) void {
        const s: *Script = @ptrCast(@alignCast(owner.?));
        s.world.print("script {s}: {s}", .{ s.name(), msg });
    }

    pub fn name(s: *const Script) []const u8 {
        if (s.app) |a| return if (a.id.len > 0) a.id else a.src;
        return "(script)";
    }

    pub fn nowMs(s: *const Script) f64 {
        return s.world.nowMs();
    }

    /// Application ticks since this application started (its application clock).
    pub fn appTicks(s: *const Script) u64 {
        if (s.app) |a| return s.world.tick -| (a.app_start orelse s.world.tick);
        return s.world.tick;
    }

    pub fn tickRate(s: *const Script) f64 {
        return s.world.tick_rate;
    }

    pub fn page(s: *const Script) ?*Page {
        const a = s.app orelse return null;
        return a.page;
    }

    pub fn isPageDoc(s: *const Script, doc: *const dom.Document) bool {
        return s.page_doc == doc;
    }

    /// The Global object: the Application object's members merged in, `application`, the XML objects and the
    /// named API objects (Annex Z introduction).
    fn setupGlobal(s: *Script) !void {
        const cx = s.cx;
        const g = cx.global();
        defer cx.free(g);
        try events.exposeConstructors(cx);
        try dom_api.exposeConstructors(cx);
        s.app_obj = try cx.wrap(Script, s);
        // The Application object's members, `application` among them.
        try cx.defineMembers(g, &application_members);
        s.parser_obj = try cx.wrapAs(xml_api.Parser, &xml_api.Parser.js_class, &s.parser);
        try cx.defineValue(g, "XMLParser", cx.dup(s.parser_obj), 0);
        try api.setup(s, g);
    }

    /// Adds a named API object (made once per context): kept until the context goes.
    pub fn keep(s: *Script, key: []const u8, v: Value) !void {
        try s.singletons.append(s.gpa, v);
        const k = try s.gpa.dupe(u8, key);
        errdefer s.gpa.free(k);
        try s.named.put(s.gpa, k, v);
    }

    /// A kept API object (borrowed).
    pub fn kept(s: *Script, key: []const u8) Value {
        return s.named.get(key) orelse js.undefined;
    }

    // ---- scripts and pages ----

    pub const Source = struct { name: []const u8, bytes: []const u8 };

    /// Runs the application's script files in order, as one program. Vol. 3 §6.2.4 has each file "executed as
    /// global code", but players compile an application's scripts together and discs rely on it: a script may
    /// read a `var` that a later file declares (hoisted, it is undefined rather than a ReferenceError). An
    /// exception is reported with the file and line it comes from. False if it threw.
    pub fn runScripts(s: *Script, files: []const Source, program: []const u8) bool {
        var all: std.ArrayList(u8) = .empty;
        defer all.deinit(s.gpa);
        var starts: std.ArrayList(u32) = .empty; // first line of each file in the program
        defer starts.deinit(s.gpa);
        var line: u32 = 1;
        for (files) |f| {
            const u = js.decodeScript(s.gpa, f.bytes) catch return false;
            defer s.gpa.free(u);
            starts.append(s.gpa, line) catch return false;
            all.appendSlice(s.gpa, u) catch return false;
            all.append(s.gpa, '\n') catch return false;
            line += @intCast(std.mem.count(u8, u, "\n") + 1);
        }
        var buf: [512]u8 = undefined;
        const n = std.fmt.bufPrintSentinel(&buf, "{s}", .{program}, 0) catch "scripts";
        defer s.cx.runJobs();
        s.cx.runScript(all.items, n) catch {
            const msg = s.cx.takeException(s.gpa) catch return false;
            defer s.gpa.free(msg);
            const mapped = mapLines(s.gpa, msg, n, files, starts.items) catch return false;
            defer s.gpa.free(mapped);
            if (s.cx.log) |f| f(s.cx.owner, mapped);
            return false;
        };
        return true;
    }

    /// Rewrites "<name>:<line>" in `msg` (a position in the joined program) to "<file>:<line in it>".
    fn mapLines(gpa: std.mem.Allocator, msg: []const u8, program: []const u8, files: []const Source, starts: []const u32) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        var i: usize = 0;
        while (std.mem.indexOfPos(u8, msg, i, program)) |at| {
            try out.appendSlice(gpa, msg[i..at]);
            var j = at + program.len;
            if (j < msg.len and msg[j] == ':') {
                var k = j + 1;
                while (k < msg.len and std.ascii.isDigit(msg[k])) k += 1;
                const l = std.fmt.parseInt(u32, msg[j + 1 .. k], 10) catch 0;
                if (l > 0) {
                    var fi: usize = 0;
                    for (starts, 0..) |st, idx| if (st <= l) {
                        fi = idx;
                    };
                    try out.print(gpa, "{s}:{d}", .{ files[fi].name, l - starts[fi] + 1 });
                    i = k;
                    continue;
                }
                j = at + program.len;
            }
            try out.appendSlice(gpa, program);
            i = j;
        }
        try out.appendSlice(gpa, msg[i..]);
        return out.toOwnedSlice(gpa);
    }

    /// Runs a script of the application; false if it threw (the exception is reported).
    pub fn runScript(s: *Script, bytes: []const u8, file: []const u8) bool {
        var buf: [512]u8 = undefined;
        const n = std.fmt.bufPrintSentinel(&buf, "{s}", .{file}, 0) catch "script";
        defer s.cx.runJobs();
        s.cx.runScript(bytes, n) catch {
            s.cx.report(n);
            return false;
        };
        return true;
    }

    /// A new page is current (its document becomes `document`); the markup loaded handler is called before its
    /// first tick (Z.1.1.3).
    pub fn pageLoaded(s: *Script, p: ?*Page, page_uri: []const u8) void {
        s.apis.draw.release(s);
        if (s.page_doc) |d| {
            s.dropJobsOf(d);
            dom_api.releaseDocument(s, d);
        }
        s.page_doc = if (p) |x| x.doc else null;
        if (p) |x| x.xpath_host = s.xpathHost();
        s.overrides.clear(s.gpa);
        s.tree_dirty = false;
        if (c.JS_IsNull(s.markup_loaded) or p == null) return;
        const u = s.cx.string(page_uri) catch return;
        var args = [_]Value{u};
        defer s.cx.free(u);
        s.cx.callReport(s.markup_loaded, s.app_obj, &args, "markup loaded handler");
        s.cx.runJobs();
    }

    /// The page goes (the application unloads): its document stops working in script.
    pub fn pageGone(s: *Script) void {
        s.apis.draw.release(s);
        if (s.page_doc) |d| {
            s.dropJobsOf(d);
            dom_api.releaseDocument(s, d);
        }
        s.page_doc = null;
    }

    /// document.load() (Z.13.1.1.3): the page is rebuilt from its DOM, without the property blocks.
    pub fn reloadPage(s: *Script, doc: *dom.Document) js.Error!void {
        if (!s.isPageDoc(doc)) return;
        s.overrides.clear(s.gpa);
        const a = s.app orelse return;
        a.reload_requested = true;
    }

    /// The XPath host of the page (variables, property functions), for evaluateXPath on the page.
    pub fn pageXPathHost(s: *Script) xpath.Host {
        const p = s.page() orelse return .{};
        return p.hostForXPath();
    }

    /// A system parameter variable (Annex W.2), or null.
    pub fn systemVariable(s: *Script, var_name: []const u8) ?xpath.Value {
        return api.systemVariable(s, var_name);
    }

    /// The XPath host of the application's page (its markup's timing, include conditions): the variables the
    /// script set on the page document (setXPathVariable, Z.12.7.2), then the system parameters (Annex W.2),
    /// and GPRM()/SPRM() (Z.10.30).
    fn xpathHost(s: *Script) xpath.Host {
        return .{ .ctx = s, .variable = pageVariable, .gprm = gprmOf, .sprm = sprmOf };
    }

    fn pageVariable(ctx: ?*anyopaque, ns: []const u8, local: []const u8) ?xpath.Value {
        const s: *Script = @ptrCast(@alignCast(ctx.?));
        if (ns.len > 0) return null;
        if (s.page_doc) |d| if (dom_api.xpathVariable(d, local)) |v| return .{ .string = v };
        return api.systemVariable(s, local);
    }

    fn gprmOf(ctx: ?*anyopaque, i: u32) i64 {
        const s: *Script = @ptrCast(@alignCast(ctx.?));
        return if (i < s.world.model.gprm.len) s.world.model.gprm[i] else 0;
    }

    fn sprmOf(ctx: ?*anyopaque, i: u32) i64 {
        const s: *Script = @ptrCast(@alignCast(ctx.?));
        return if (i < s.world.model.sprm.len) s.world.model.sprm[i] else 0;
    }

    // ---- DOM changes ----

    pub fn treeChanged(s: *Script, doc: *dom.Document) void {
        if (s.isPageDoc(doc)) s.tree_dirty = true;
    }

    fn wants(s: *Script, type_: []const u8) bool {
        var it = s.reg.map.valueIterator();
        while (it.next()) |l| for (l.items) |x| if (std.mem.eql(u8, x.type, type_)) return true;
        return false;
    }

    /// The path of node `n`: its ancestors from the top, then itself (borrowed into `out`).
    fn pathOf(n: *dom.Node, out: *std.ArrayList(*dom.Node), gpa: std.mem.Allocator) !void {
        var x: ?*dom.Node = n;
        while (x) |k| : (x = k.parent) try out.append(gpa, k);
        std.mem.reverse(*dom.Node, out.items);
    }

    /// Queues mutation event `type_` at `target` with its path as it is now.
    fn mutation(s: *Script, type_: []const u8, target: *dom.Node, bubbles: bool, related: ?*dom.Node, prev: []const u8, new: []const u8, attr: []const u8, change: u16) !void {
        if (s.closing or !s.wants(type_)) return;
        const e = try events.Event.create(s.gpa, .mutation, s.nowMs());
        const ev = s.cx.wrapAs(events.Event, &events.Event.mutation_class, e) catch |err| {
            s.gpa.destroy(e);
            return err;
        };
        defer s.cx.free(ev);
        const a = e.arena.allocator();
        e.type = try a.dupe(u8, type_);
        e.initialized = true;
        e.bubbles = bubbles;
        e.cancelable = false;
        if (related) |r| {
            const rv = try dom_api.wrap(s, r);
            defer s.cx.free(rv);
            e.related = s.cx.dup(rv);
        }
        e.prev_value = try a.dupe(u8, prev);
        e.new_value = try a.dupe(u8, new);
        e.attr_name = try a.dupe(u8, attr);
        e.attr_change = change;
        try s.queueEvent(.{ .node = target }, ev);
    }

    fn inDocument(n: *dom.Node) bool {
        var x: ?*dom.Node = n;
        while (x) |k| : (x = k.parent) if (k.type == .document) return true;
        return false;
    }

    /// Before `n` leaves its parent: DOMNodeRemoved, DOMNodeRemovedFromDocument (DOM2 Events §1.6.4).
    pub fn beforeRemoval(s: *Script, n: *dom.Node) !void {
        const parent = n.parent orelse return;
        try s.mutation("DOMNodeRemoved", n, true, parent, "", "", "", 0);
        if (inDocument(n)) {
            var x: ?*dom.Node = n;
            while (x) |k| : (x = k.following(n)) try s.mutation("DOMNodeRemovedFromDocument", k, false, null, "", "", "", 0);
        }
        try s.mutation("DOMSubtreeModified", parent, true, null, "", "", "", 0);
        s.treeChanged(n.doc);
    }

    /// After `n` was inserted: DOMNodeInserted, DOMNodeInsertedIntoDocument, DOMSubtreeModified.
    pub fn afterInsertion(s: *Script, n: *dom.Node) !void {
        const parent = n.parent orelse return;
        try s.mutation("DOMNodeInserted", n, true, parent, "", "", "", 0);
        if (inDocument(n)) {
            var x: ?*dom.Node = n;
            while (x) |k| : (x = k.following(n)) try s.mutation("DOMNodeInsertedIntoDocument", k, false, null, "", "", "", 0);
        }
        try s.mutation("DOMSubtreeModified", parent, true, null, "", "", "", 0);
        s.treeChanged(n.doc);
    }

    /// An attribute changed (old/new null: added/removed): DOMAttrModified.
    pub fn attrChanged(s: *Script, el: *dom.Node, attr: []const u8, old: ?[]const u8, new: ?[]const u8) !void {
        const change: u16 = if (old == null) 2 else if (new == null) 3 else 1;
        try s.mutation("DOMAttrModified", el, true, null, old orelse "", new orelse "", attr, change);
        try s.mutation("DOMSubtreeModified", el, true, null, "", "", "", 0);
        if (s.isPageDoc(el.doc)) if (s.app) |a| {
            a.attrs_dirty = true;
        };
    }

    pub fn dataChanged(s: *Script, n: *dom.Node, old: []const u8) !void {
        try s.mutation("DOMCharacterDataModified", n, true, null, old, n.data, "", 0);
        if (n.parent) |p| try s.mutation("DOMSubtreeModified", p, true, null, "", "", "", 0);
        s.treeChanged(n.doc);
    }

    // ---- state (Z.13, §7.6.3.4) ----

    /// Puts a state kind in global state.
    pub fn lockState(s: *Script, which: anim_api.StateName) void {
        switch (which) {
            .focused => s.world.focus_locked = true,
            .enabled => s.overrides.enabled_locked = true,
            .value => s.overrides.value_locked = true,
            else => {},
        }
    }

    /// Any unsetProperty ends the global states.
    pub fn unlockStates(s: *Script) void {
        s.world.focus_locked = false;
        s.overrides.enabled_locked = false;
        s.overrides.value_locked = false;
    }

    /// A state value from script, applied to the element and its DOM attribute.
    pub fn applyState(s: *Script, p: *Page, el: *page_mod.Elem, which: anim_api.StateName, v: []const u8) void {
        const on = std.mem.eql(u8, v, "true");
        switch (which) {
            .focused => if (s.world.apps) |w| {
                if (on) w.focusFromScript(p, el) else if (el.state.focused) p.setState(el, .focused, false);
            } else p.setState(el, .focused, on),
            .enabled => p.setState(el, .enabled, on),
            .value => p.setValue(el, v) catch {},
            else => {},
        }
    }

    pub fn drawingAreaOf(s: *Script, n: *dom.Node) js.Error!Value {
        return api.drawingAreaOf(s, n);
    }

    // ---- queueing ----

    pub const Target = union(enum) { app, node: *dom.Node };

    /// Queues the dispatch of Event object `ev` (of this context) at `target`, with the path it has now.
    pub fn queueEvent(s: *Script, target: Target, ev: Value) !void {
        if (s.closing) return;
        var path: std.ArrayList(*dom.Node) = .empty;
        errdefer path.deinit(s.gpa);
        var app_top = true;
        var hold = js.null;
        switch (target) {
            .app => {},
            .node => |n| {
                try pathOf(n, &path, s.gpa);
                // Only the page's DOM sits under the Application object (§8.3.6).
                app_top = s.isPageDoc(n.doc) and path.items[0].type == .document;
                hold = try dom_api.wrap(s, n);
            },
        }
        errdefer s.cx.free(hold);
        try s.post(.{ .local = .{ .ev = s.cx.dup(ev), .path = try path.toOwnedSlice(s.gpa), .app_top = app_top, .hold = hold } }, .app, s.world.tick, null);
    }

    /// Queues a work item (§8.5) on `clock` from `begin` until `end` (null: never dropped).
    pub fn post(s: *Script, job: Job, clock: sched.Clock, begin: u64, end: ?u64) !void {
        if (s.closing) {
            s.dropJob(job);
            return;
        }
        s.queue.push(s.gpa, .{ .job = job, .clock = clock, .begin = begin, .end = end }) catch |e| {
            s.dropJob(job);
            return e;
        };
    }

    /// Queues `f(args…)` (args are consumed) to run at the next work-item pass.
    pub fn postCall(s: *Script, f: Value, args: []const Value, what: []const u8) !void {
        const copy = s.gpa.dupe(Value, args) catch |e| {
            for (args) |a| s.cx.free(a);
            return e;
        };
        try s.post(.{ .call = .{ .f = s.cx.dup(f), .args = copy, .what = what } }, .app, 0, null);
    }

    pub fn dropJob(s: *Script, job: Job) void {
        switch (job) {
            .local => |l| {
                s.cx.free(l.ev);
                s.cx.free(l.hold);
                s.gpa.free(l.path);
            },
            .delivery => |d| d.destroy(),
            .timer => |tm| tm.queued = false,
            .call => |cl| {
                s.cx.free(cl.f);
                for (cl.args) |a| s.cx.free(a);
                s.gpa.free(cl.args);
            },
        }
    }

    fn dropJobCb(s: *Script, job: Job) void {
        s.dropJob(job);
    }

    fn dropJobs(s: *Script) void {
        s.queue.removeIf(s, struct {
            fn all(_: *Script, _: *const sched.Queue(Job).Item) bool {
                return true;
            }
        }.all, dropJobCb);
    }

    /// Drops the queued items that reach into `doc` (it is going away).
    fn dropJobsOf(s: *Script, doc: *dom.Document) void {
        const Ctx = struct { s: *Script, doc: *dom.Document };
        var x: Ctx = .{ .s = s, .doc = doc };
        s.queue.removeIf(&x, struct {
            fn f(cx: *Ctx, it: *const sched.Queue(Job).Item) bool {
                return switch (it.job) {
                    .local => |l| l.path.len > 0 and l.path[0].doc == cx.doc,
                    .delivery => |d| d.origin_node != null and d.origin_node.?.doc == cx.doc,
                    else => false,
                };
            }
        }.f, struct {
            fn d(cx: *Ctx, job: Job) void {
                cx.s.dropJob(job);
            }
        }.d);
    }

    /// Drops the work items on the page clock (a new page starts, §8.5).
    pub fn dropPageItems(s: *Script) void {
        s.queue.removeIf(s, struct {
            fn f(_: *Script, it: *const sched.Queue(Job).Item) bool {
                return it.clock == .page;
            }
        }.f, dropJobCb);
    }

    /// Runs a work item that is not a delivery (the engine runs those, see apps.zig).
    pub fn run(s: *Script, job: Job) void {
        switch (job) {
            .local => |l| {
                defer s.dropJob(job);
                s.dispatchLocal(l.ev, l.path, l.app_top);
            },
            .delivery => |d| d.destroy(),
            .timer => |tm| tm.fire(s),
            .call => |cl| {
                defer s.dropJob(job);
                s.cx.callReport(cl.f, s.app_obj, cl.args, cl.what);
            },
        }
        s.cx.runJobs();
    }

    fn dispatchLocal(s: *Script, ev_v: Value, path: []*dom.Node, app_top: bool) void {
        const ev = s.cx.unwrap(events.Event, ev_v) orelse return;
        var hops: std.ArrayList(events.Hop) = .empty;
        defer {
            for (hops.items) |h| s.cx.free(h.obj);
            hops.deinit(s.gpa);
        }
        if (app_top) hops.append(s.gpa, .{ .key = s, .obj = s.cx.dup(s.app_obj) }) catch return;
        for (path) |n| {
            const v = dom_api.wrap(s, n) catch return;
            hops.append(s.gpa, .{ .key = n, .obj = v }) catch {
                s.cx.free(v);
                return;
            };
        }
        if (hops.items.len == 0) hops.append(s.gpa, .{ .key = s, .obj = s.cx.dup(s.app_obj) }) catch return;
        events.dispatch(s.cx, &s.reg, ev, ev_v, hops.items);
    }

    /// Delivers `d` in this application: a new Event object at its target here (the focused element for keys,
    /// the element under the cursor for pointer keys, the <event> element where it was raised, else the
    /// Application object).
    pub fn deliver(s: *Script, d: *Delivery, target: ?*dom.Node) Outcome {
        const ev_v = events.Event.fromSpec(s.cx, d.spec, s.nowMs()) catch {
            s.cx.report(d.spec.type);
            return .{ .stopped = false, .prevented = false };
        };
        defer s.cx.free(ev_v);
        const ev = s.cx.unwrap(events.Event, ev_v).?;
        ev.prevented = d.prevented;
        var path: std.ArrayList(*dom.Node) = .empty;
        defer path.deinit(s.gpa);
        if (target) |n| pathOf(n, &path, s.gpa) catch {};
        s.dispatchLocal(ev_v, path.items, true);
        s.cx.runJobs();
        return .{ .stopped = ev.stopped, .prevented = ev.prevented };
    }

    /// True if this application listens for `type_` on its Application object.
    pub fn listens(s: *const Script, type_: []const u8) bool {
        return s.reg.has(s, type_);
    }

    // ---- timers (Z.2.2) ----

    /// Counts the timers' time to this tick and queues the ones due.
    pub fn runTimers(s: *Script) void {
        var i: usize = 0;
        while (i < s.timers.items.len) {
            const tm = s.timers.items[i];
            if (tm.discard) {
                _ = s.timers.swapRemove(i);
                tm.destroy(s);
                continue;
            }
            tm.advance(s);
            i += 1;
        }
    }
};

// ---- the Application object (Z.1.1) -----------------------------------------------------------------------------------

fn getSingleton(comptime key: []const u8) fn (*Script) Value {
    return struct {
        fn get(s: *Script) Value {
            return s.cx.dup(s.kept(key));
        }
    }.get;
}

fn getAttributes(s: *Script) js.Error!Value {
    const o = try s.cx.object();
    errdefer s.cx.free(o);
    const a = s.app orelse return o;
    var buf: [32]u8 = undefined;
    switch (a.kind) {
        .playlist => |pa| {
            if (pa.id.len > 0) try s.cx.set(o, "id", try s.cx.string(pa.id));
            try s.cx.set(o, "src", try s.cx.string(pa.src));
            if (pa.language.len > 0) try s.cx.set(o, "language", try s.cx.string(pa.language));
            if (pa.description.len > 0) try s.cx.set(o, "description", try s.cx.string(pa.description));
        },
        .title => |seg| {
            if (seg.id.len > 0) try s.cx.set(o, "id", try s.cx.string(seg.id));
            try s.cx.set(o, "src", try s.cx.string(seg.src));
            try s.cx.set(o, "titleTimeBegin", try s.cx.string(events.timecode(&buf, seg.title_begin, s.world.fps)));
            if (seg.title_end) |e| try s.cx.set(o, "titleTimeEnd", try s.cx.string(events.timecode(&buf, e, s.world.fps)));
            try s.cx.set(o, "sync", try s.cx.string(@tagName(seg.sync)));
            try s.cx.set(o, "zOrder", try s.cx.string(std.fmt.bufPrint(&buf, "{d}", .{seg.z_order}) catch ""));
            if (seg.language.len > 0) try s.cx.set(o, "language", try s.cx.string(seg.language));
            if (seg.app_block) |b| try s.cx.set(o, "appBlock", try s.cx.string(std.fmt.bufPrint(&buf, "{d}", .{b}) catch ""));
            if (seg.group) |g| try s.cx.set(o, "group", try s.cx.string(std.fmt.bufPrint(&buf, "{d}", .{g}) catch ""));
            try s.cx.set(o, "autorun", try s.cx.string(if (seg.autorun) "true" else "false"));
            if (seg.description.len > 0) try s.cx.set(o, "description", try s.cx.string(seg.description));
        },
    }
    // Read only: the values cannot change.
    _ = c.JS_FreezeObject(s.cx.ctx, o);
    return o;
}

fn getZOrder(s: *Script) f64 {
    const a = s.app orelse return 0;
    const w = s.world.apps orelse return 0;
    return if (w.zOrderOf(a)) |z| @floatFromInt(z) else std.math.nan(f64);
}

fn getLocation(s: *Script) js.Error!Value {
    const p = s.page() orelse return js.undefined;
    return s.cx.string(p.doc.uri);
}

fn getAdvancedApplications(s: *Script) js.Error!Value {
    const arr = try s.cx.array();
    errdefer s.cx.free(arr);
    const w = s.world.apps orelse return arr;
    var i: u32 = 0;
    for (w.records.items) |a| {
        try s.cx.setIndex(arr, i, try advancedApplication(s, a));
        i += 1;
    }
    return arr;
}

fn getThisAdvancedApplication(s: *Script) js.Error!Value {
    const a = s.app orelse return js.null;
    return advancedApplication(s, a);
}

fn getDocument(s: *Script) js.Error!Value {
    const d = s.page_doc orelse return js.null;
    return dom_api.wrap(s, &d.node);
}

fn getApplication(s: *Script) Value {
    return s.cx.dup(s.app_obj);
}

fn getCoordX(s: *Script) i32 {
    const a = s.app orelse return 0;
    return a.region.x;
}

fn getCoordY(s: *Script) i32 {
    const a = s.app orelse return 0;
    return a.region.y;
}

fn setCoordX(s: *Script, v: i32) void {
    const a = s.app orelse return;
    a.region.x = v;
    a.look = 0;
}

fn setCoordY(s: *Script, v: i32) void {
    const a = s.app orelse return;
    a.region.y = v;
    a.look = 0;
}

fn moveToTop(s: *Script) void {
    const a = s.app orelse return;
    if (s.world.apps) |w| w.moveToTop(a);
}

fn moveToBottom(s: *Script) void {
    const a = s.app orelse return;
    if (s.world.apps) |w| w.moveToBottom(a);
}

/// link(uri) (Z.1.1.3): the page is replaced once the new one has loaded; a malformed page changes nothing.
fn link(s: *Script, u: []const u8) js.Error!void {
    if (u.len == 0 or !uri.valid(u) or uri.locate(u) == null) return error.Argument;
    const a = s.app orelse return;
    const copy = try s.gpa.dupe(u8, u);
    if (a.link_requested) |old| s.gpa.free(old);
    a.link_requested = copy;
}

fn setMarkupLoadedHandler(s: *Script, f: Value) void {
    s.cx.free(s.markup_loaded);
    s.markup_loaded = if (s.cx.isFunction(f)) s.cx.dup(f) else js.null;
}

fn createStringArray(s: *Script, size: u32) js.Error!Value {
    return StringArray.make(s, size);
}

fn createTimer(s: *Script, ticks: []const u8, type_: u32, f: Value) js.Error!Value {
    if (type_ != 1 and type_ != 2) return error.Argument;
    if (type_ == 2) if (s.app) |a| if (a.kind == .playlist) return error.Argument;
    if (!s.cx.isFunction(f)) return error.Argument;
    const interval = parseTimecode(ticks, s.world.fps) orelse return error.Argument;
    return Timer.make(s, if (type_ == 1) .app else .title, ticks, interval, f);
}

fn computeImplicitNav(s: *Script) js.Error!void {
    const a = s.app orelse return error.InvalidOperation;
    if (a.page == null) return error.InvalidOperation;
    a.renumber = true;
}

fn addEventListener(s: *Script, type_: []const u8, f: Value, capture: bool) js.Error!void {
    if (c.JS_IsNull(f) or c.JS_IsUndefined(f)) return;
    try s.reg.add(s.cx, s, type_, f, capture);
}

fn removeEventListener(s: *Script, type_: []const u8, f: Value, capture: bool) void {
    s.reg.remove(s.cx, s, type_, f, capture);
}

/// Application.dispatchEvent: an application event goes to every application in priority order (§8.3.5,
/// §8.3.6), as a work item (§8.5: script is never called directly). Returns true: the outcome is not known yet.
fn dispatchEvent(s: *Script, ev_v: Value) js.Error!bool {
    const e = s.cx.unwrap(events.Event, ev_v) orelse return error.TypeError;
    if (!e.initialized or e.type.len == 0) return events.throwUnspecifiedEventType(s.cx);
    const d = try Delivery.create(s.gpa, s.cx.rt, .app, .{ .kind = .app, .type = e.type, .bubbles = e.bubbles, .cancelable = e.cancelable });
    errdefer d.destroy();
    d.spec.extras = try events.extrasOf(s.cx, d.arena.allocator(), ev_v);
    if (s.world.apps) |w| {
        try w.send(d);
    } else {
        // A lone script: to itself.
        try s.post(.{ .delivery = d }, .app, 0, null);
    }
    return true;
}

fn createEvent(s: *Script, event_type: []const u8) js.Error!Value {
    return events.createEvent(s.cx, event_type, s.nowMs());
}

pub const application_members = [_]js.Member{
    js.prop("FileIO", getSingleton("FileIO"), null),
    js.prop("Diagnostics", getSingleton("Diagnostics"), null),
    js.prop("ControllerManager", getSingleton("ControllerManager"), null),
    js.prop("Drawing", getSingleton("Drawing"), null),
    js.prop("Network", getSingleton("Network"), null),
    js.prop("attributes", getAttributes, null),
    js.prop("zOrder", getZOrder, null),
    js.prop("location", getLocation, null),
    js.prop("advancedApplications", getAdvancedApplications, null),
    js.prop("thisAdvancedApplication", getThisAdvancedApplication, null),
    js.prop("document", getDocument, null),
    js.prop("application", getApplication, null),
    js.prop("coordX", getCoordX, setCoordX),
    js.prop("coordY", getCoordY, setCoordY),
    js.method("moveToTop", moveToTop),
    js.method("moveToBottom", moveToBottom),
    js.method("link", link),
    js.method("setMarkupLoadedHandler", setMarkupLoadedHandler),
    js.method("createStringArray", createStringArray),
    js.method("createTimer", createTimer),
    js.method("computeImplicitNav", computeImplicitNav),
    js.constant("TIMER_APPLICATION", 1),
    js.constant("TIMER_TITLE", 2),
    js.method("addEventListener", addEventListener),
    js.method("removeEventListener", removeEventListener),
    js.method("dispatchEvent", dispatchEvent),
    js.method("createEvent", createEvent),
};

const application_class: js.Class = .{ .name = "Application", .members = &application_members };

/// "HH:MM:SS:FF" (§6.2.3.13; FF below the frame rate) to frames.
pub fn parseTimecode(s: []const u8, fps: u64) ?u64 {
    var parts: [4]u64 = undefined;
    var it = std.mem.splitScalar(u8, std.mem.trim(u8, s, " \t"), ':');
    var n: usize = 0;
    while (it.next()) |p| {
        if (n == 4 or p.len == 0 or p.len > 2) return null;
        parts[n] = std.fmt.parseInt(u64, p, 10) catch return null;
        n += 1;
    }
    if (n != 4 or parts[1] >= 60 or parts[2] >= 60 or parts[3] >= fps) return null;
    return ((parts[0] * 60 + parts[1]) * 60 + parts[2]) * fps + parts[3];
}

// ---- AdvancedApplication (Z.1.2) ------------------------------------------------------------------------------

/// The AdvancedApplication object of `a` in this context (one per application).
pub fn advancedApplication(s: *Script, a: *apps.App) js.Error!Value {
    if (s.app_objs.get(a)) |v| return s.cx.dup(v);
    const v = try s.cx.wrapAs(apps.App, &advanced_application_class, a);
    errdefer s.cx.free(v);
    try s.app_objs.put(s.gpa, a, s.cx.dup(v));
    return v;
}

/// Application `a` is gone (its title ended): its objects stop working.
pub fn forgetApplication(s: *Script, a: *apps.App) void {
    if (s.app_objs.fetchRemove(a)) |kv| {
        js.kill(s.cx.rt, js.objectPointer(kv.value));
        s.cx.free(kv.value);
    }
}

const AA = struct {
    fn id(a: *apps.App, cx: *js.Context) js.Error!Value {
        return if (a.id.len > 0) cx.string(a.id) else js.undefined;
    }
    fn state(a: *apps.App) u32 {
        return if (!a.valid) 3 else if (a.active()) 1 else 2;
    }
    fn zOrder(a: *apps.App, cx: *js.Context) f64 {
        const w = Script.of(cx).world.apps orelse return std.math.nan(f64);
        return if (w.zOrderOf(a)) |z| @floatFromInt(z) else std.math.nan(f64);
    }
    fn type_(a: *apps.App) u32 {
        return if (a.kind == .playlist) 1 else 2;
    }
    fn getAutorun(a: *apps.App) bool {
        return a.autorun;
    }
    fn setAutorun(a: *apps.App, v: bool) void {
        a.autorun = v;
    }
    fn activate(a: *apps.App, cx: *js.Context) js.Error!void {
        const w = Script.of(cx).world.apps orelse return error.InvalidOperation;
        if (!w.activate(a)) return error.InvalidOperation;
    }
    fn inactivate(a: *apps.App, cx: *js.Context) js.Error!void {
        const w = Script.of(cx).world.apps orelse return error.InvalidOperation;
        if (!w.inactivate(a)) return error.InvalidOperation;
    }
    fn target(cx: *js.Context, v: Value) js.Error!*apps.App {
        return cx.unwrap(apps.App, v) orelse error.Argument;
    }
    fn moveBefore(a: *apps.App, cx: *js.Context, t_v: Value) js.Error!void {
        const tg = try target(cx, t_v);
        const w = Script.of(cx).world.apps orelse return error.InvalidOperation;
        if (w.zOrderOf(tg) == null) return error.InvalidOperation;
        w.moveRelative(a, tg, .before);
    }
    fn moveAfter(a: *apps.App, cx: *js.Context, t_v: Value) js.Error!void {
        const tg = try target(cx, t_v);
        const w = Script.of(cx).world.apps orelse return error.InvalidOperation;
        if (w.zOrderOf(tg) == null) return error.InvalidOperation;
        w.moveRelative(a, tg, .after);
    }
};

const advanced_application_class: js.Class = .{
    .name = "AdvancedApplication",
    .members = &.{
        js.prop("id", AA.id, null),
        js.prop("state", AA.state, null),
        js.prop("zOrder", AA.zOrder, null),
        js.prop("type", AA.type_, null),
        js.prop("autorun", AA.getAutorun, AA.setAutorun),
        js.method("activate", AA.activate),
        js.method("inactivate", AA.inactivate),
        js.method("moveBefore", AA.moveBefore),
        js.method("moveAfter", AA.moveAfter),
        js.constant("APPLICATION_PLAYLIST", 1),
        js.constant("APPLICATION_TITLE", 2),
        js.constant("STATE_ACTIVE", 1),
        js.constant("STATE_INACTIVE", 2),
        js.constant("STATE_INVALID", 3),
    },
};

// ---- StringArray (Z.2.1) --------------------------------------------------------------------------------------------

pub const StringArray = struct {
    gpa: std.mem.Allocator,
    /// null: undefined.
    items: []?[]u8,

    pub fn make(s: *Script, n: u32) js.Error!Value {
        const sa = try s.gpa.create(StringArray);
        errdefer s.gpa.destroy(sa);
        const items = try s.gpa.alloc(?[]u8, n);
        @memset(items, null);
        sa.* = .{ .gpa = s.gpa, .items = items };
        return s.cx.wrap(StringArray, sa) catch |e| {
            s.gpa.free(items);
            return e;
        };
    }

    /// A StringArray holding copies of `strings`.
    pub fn of(s: *Script, strings: []const []const u8) js.Error!Value {
        const v = try make(s, @intCast(strings.len));
        const sa = s.cx.unwrap(StringArray, v).?;
        for (strings, 0..) |x, i| sa.items[i] = s.gpa.dupe(u8, x) catch {
            s.cx.free(v);
            return error.OutOfMemory;
        };
        return v;
    }

    fn finalize(ptr: *anyopaque, _: *js.Runtime) void {
        const sa: *StringArray = @ptrCast(@alignCast(ptr));
        for (sa.items) |x| if (x) |y| sa.gpa.free(y);
        sa.gpa.free(sa.items);
        sa.gpa.destroy(sa);
    }

    fn size(sa: *StringArray) u32 {
        return @intCast(sa.items.len);
    }

    fn equals(sa: *StringArray, cx: *js.Context, other_v: Value) js.Error!bool {
        const o = cx.unwrap(StringArray, other_v) orelse return error.Argument;
        if (o.items.len != sa.items.len) return false;
        for (sa.items, o.items) |x, y| {
            if ((x == null) != (y == null)) return false;
            if (x) |a| if (!std.mem.eql(u8, a, y.?)) return false;
        }
        return true;
    }

    fn get(sa: *StringArray, cx: *js.Context, offset: u32) js.Error!Value {
        if (offset >= sa.items.len) return error.ArgumentOutOfRange;
        return if (sa.items[offset]) |x| cx.string(x) else js.undefined;
    }

    fn set(sa: *StringArray, offset: u32, v: []const u8) js.Error!void {
        if (offset >= sa.items.len) return error.ArgumentOutOfRange;
        const copy = try sa.gpa.dupe(u8, v);
        if (sa.items[offset]) |old| sa.gpa.free(old);
        sa.items[offset] = copy;
    }

    pub const js_class: js.Class = .{
        .name = "StringArray",
        .finalize = finalize,
        .members = &.{
            js.prop("size", size, null),
            js.method("equals", equals),
            js.method("get", get),
            js.method("set", set),
        },
    };
};

// ---- Timer (Z.2.2) -------------------------------------------------------------------------------------------------

pub const Timer = struct {
    kind: enum { app, title },
    callback: Value,
    /// The interval as set (a timecode), and in its clock's units (application ticks or title frames).
    interval_str: []u8,
    interval: u64,
    auto_reset: bool = true,
    enabled: bool = false,
    /// Time counted towards the interval while enabled, and the clock when last counted.
    count: u64 = 0,
    last: ?u64 = null,
    /// The script object, while it exists (weak).
    obj: ?*anyopaque = null,
    referenced: bool = true,
    queued: bool = false,
    discard: bool = false,
    /// The Title Timeline was not at normal speed at the last count (trick play resets the count).
    was_trick: bool = false,
    owner: *Script,

    fn make(s: *Script, kind: @FieldType(Timer, "kind"), interval_str: []const u8, interval_frames: u64, f: Value) js.Error!Value {
        const tm = try s.gpa.create(Timer);
        errdefer s.gpa.destroy(tm);
        const str = try s.gpa.dupe(u8, interval_str);
        errdefer s.gpa.free(str);
        tm.* = .{ .kind = kind, .callback = s.cx.dup(f), .interval_str = str, .interval = tm.unitsOf(s, interval_frames), .owner = s };
        errdefer s.cx.free(tm.callback);
        try s.timers.append(s.gpa, tm);
        const v = s.cx.wrap(Timer, tm) catch |e| {
            _ = s.timers.pop();
            return e;
        };
        tm.obj = js.objectPointer(v);
        return v;
    }

    /// Frames to this timer's units.
    fn unitsOf(tm: *const Timer, s: *Script, frames: u64) u64 {
        if (tm.kind == .title) return @max(1, frames);
        const sec = @as(f64, @floatFromInt(frames)) / @as(f64, @floatFromInt(s.world.fps));
        return @max(1, @as(u64, @intFromFloat(@round(sec * s.world.tick_rate))));
    }

    fn clock(tm: *const Timer, s: *Script) u64 {
        return switch (tm.kind) {
            .app => s.world.tick,
            .title => s.world.title_time,
        };
    }

    fn destroy(tm: *Timer, s: *Script) void {
        if (tm.obj) |o| js.kill(s.cx.rt, o);
        s.cx.free(tm.callback);
        s.gpa.free(tm.interval_str);
        s.gpa.destroy(tm);
    }

    /// The wrapper is collected: the timer goes unless it must still fire (enabled, autoReset false).
    fn finalize(ptr: *anyopaque, _: *js.Runtime) void {
        const tm: *Timer = @ptrCast(@alignCast(ptr));
        tm.referenced = false;
        tm.obj = null;
        if (!tm.enabled or tm.owner.closing) tm.discard = true;
    }

    fn advance(tm: *Timer, s: *Script) void {
        const now = tm.clock(s);
        defer tm.last = now;
        if (!tm.enabled) return;
        if (tm.kind == .title) {
            // Title timers stop while the title is held and do not fire in trick play; the count restarts
            // when playback resumes.
            if (!s.world.title_running) {
                tm.was_trick = true;
                return;
            }
            if (tm.was_trick) {
                tm.was_trick = false;
                tm.count = 0;
                return;
            }
        }
        const last = tm.last orelse now;
        tm.count += now -| last;
        if (tm.count < tm.interval or tm.queued) return;
        tm.count = 0;
        tm.queued = true;
        // A periodic item: dropped if it cannot run before the next one is due (§8.5).
        const clk: sched.Clock = if (tm.kind == .app) .app else .title;
        const begin = if (clk == .app) s.appTicks() else now;
        s.post(.{ .timer = tm }, clk, begin, begin + tm.interval) catch {
            tm.queued = false;
        };
    }

    fn fire(tm: *Timer, s: *Script) void {
        tm.queued = false;
        if (!tm.enabled) return;
        if (!tm.auto_reset) tm.enabled = false;
        if (!tm.referenced and tm.auto_reset) tm.enabled = false;
        s.cx.callReport(tm.callback, s.app_obj, &.{}, "timer");
        if (!tm.referenced and !tm.enabled) tm.discard = true;
    }

    fn getAutoReset(tm: *Timer) bool {
        return tm.auto_reset;
    }
    fn setAutoReset(tm: *Timer, v: bool) void {
        tm.auto_reset = v;
    }
    fn getEnabled(tm: *Timer) bool {
        return tm.enabled;
    }
    /// Enabling restarts the count from zero. Z.2.2.2 says disabling only stops the count and enabling counts on
    /// from there, but discs rely on a restart: a menu bar resets its auto-close timer on every key with
    /// `enabled = false` then `true`, and would otherwise close 15 s after opening however busy the user is.
    fn setEnabled(tm: *Timer, v: bool) void {
        if (v and !tm.enabled) {
            tm.last = null;
            tm.count = 0;
        }
        tm.enabled = v;
    }
    fn getInterval(tm: *Timer) []const u8 {
        return tm.interval_str;
    }
    /// A new interval resets the count.
    fn setInterval(tm: *Timer, cx: *js.Context, v: []const u8) js.Error!void {
        const s = Script.of(cx);
        const frames = parseTimecode(v, s.world.fps) orelse return error.Argument;
        const str = try s.gpa.dupe(u8, v);
        s.gpa.free(tm.interval_str);
        tm.interval_str = str;
        tm.interval = tm.unitsOf(s, frames);
        tm.count = 0;
        tm.last = null;
    }
    fn getType(tm: *Timer) u32 {
        return if (tm.kind == .app) 1 else 2;
    }

    pub const js_class: js.Class = .{
        .name = "Timer",
        .finalize = finalize,
        .members = &.{
            js.prop("autoReset", getAutoReset, setAutoReset),
            js.prop("enabled", getEnabled, setEnabled),
            js.prop("interval", getInterval, setInterval),
            js.prop("type", getType, null),
        },
    };
};

// ---- tests --------------------------------------------------------------------------------------------------------

const testenv = @import("testenv.zig");

test "the Application object, StringArray and timers" {
    const e = try testenv.Env.create();
    defer e.destroy();
    try e.run(
        \\// The Application object's members are on the Global object too.
        \\assertEq(application, global.application); assertEq(TIMER_APPLICATION, 1); assertEq(application.TIMER_TITLE, 2);
        \\assertEq(typeof createTimer, "function"); assertEq(document, null);
        \\assertThrows(function () { link(""); }, "HDDVD_E_ARGUMENT");
        \\// StringArray.
        \\var a = createStringArray(3); assertEq(a.size, 3); assertEq(a.get(0), undefined);
        \\a.set(1, "x"); assertEq(a.get(1), "x"); assertThrows(function () { a.get(3); }, "HDDVD_E_ARGUMENTOUTOFRANGE");
        \\var b = createStringArray(3); b.set(1, "x"); assert(a.equals(b)); b.set(2, "y"); assert(!a.equals(b));
        \\assertThrows(function () { a.equals({}); }, "HDDVD_E_ARGUMENT"); a.size = 9; assertEq(a.size, 3);
        \\// Timers.
        \\assertThrows(function () { createTimer("00:00:01:00", 3, function () {}); }, "HDDVD_E_ARGUMENT");
        \\assertThrows(function () { createTimer("bad", 1, function () {}); }, "HDDVD_E_ARGUMENT");
        \\var fired = 0; var once = 0;
        \\var t = createTimer("00:00:00:30", TIMER_APPLICATION, cb(function () { fired++; }));
        \\assertEq(t.enabled, false); assertEq(t.autoReset, true); assertEq(t.interval, "00:00:00:30"); assertEq(t.type, 1);
        \\t.enabled = true;
        \\var t2 = createTimer("00:00:00:10", 1, cb(function () { once++; })); t2.autoReset = false; t2.enabled = true;
        \\// Application events go through the queue to the listeners.
        \\var got;
        \\addEventListener("my_event", cb(function (ev) { got = ev.payload + ":" + ev.type; }), false);
        \\var ev = createEvent("my_event"); ev.initEvent("my_event", true, true); ev.payload = 7;
        \\assert(dispatchEvent(ev)); assertEq(got, undefined, "queued");
    , "app.js");
    try e.ticks(70);
    try e.run(
        \\assertEq(got, "7:my_event");
        \\assertEq(fired, 2, "every 30 ticks"); assertEq(once, 1); assertEq(t2.enabled, false);
        \\t.enabled = false;
    , "app2.js");
    try e.ticks(40);
    try e.run(
        \\assertEq(fired, 2, 'disabled');
        \\var reset = 0; var t3 = createTimer("00:00:00:30", TIMER_APPLICATION, cb(function () { reset++; }));
        \\t3.autoReset = false; t3.enabled = true;
    , "app3.js");
    // Re-enabling restarts the count: 20 + 20 ticks do not reach 30.
    try e.ticks(20);
    try e.run("t3.enabled = false; t3.enabled = true;", "app4.js");
    try e.ticks(20);
    try e.run("assertEq(reset, 0, 'restarted');", "app5.js");
    try e.ticks(15);
    try e.run("assertEq(reset, 1, 'fired 30 ticks after the restart');", "app6.js");
}

test "XMLParser: parse, write and statuses" {
    const e = try testenv.Env.create();
    defer e.destroy();
    try e.backend.disc.write("ADV_OBJ/a.xml", "<?xml version='1.0'?><bookmarks><b n='1'/></bookmarks>", 0, true);
    try e.run(
        \\assertEq(XMLParser.status(), XMLParser.READY);
        \\var res = [];
        \\XMLParser.parse("file:///dvddisc/ADV_OBJ/a.xml", cb(function (st, doc) { res.push(st); res.push(doc.documentElement.firstChild.getAttribute("n")); }));
        \\assertEq(XMLParser.status(), XMLParser.PARSING);
        \\assertThrows(function () { XMLParser.parse("file:///dvddisc/ADV_OBJ/a.xml", function () {}); }, "HDDVD_E_INVALIDOPERATION");
        \\assertThrows(function () { XMLParser.parseString("<a/>"); }, "HDDVD_E_INVALIDOPERATION");
    , "xml1.js");
    try e.run(
        \\assertEq(res.join(","), "5,1"); assertEq(XMLParser.status(), XMLParser.READY);
        \\assertEq(XMLParser.parseString("<a><b></a>"), null);
        \\assertThrows(function () { XMLParser.parseString(null); }, "HDDVD_E_ARGUMENT");
        \\var nf; XMLParser.parse("file:///dvddisc/ADV_OBJ/none.xml", cb(function (st, doc) { nf = st + ":" + doc; }));
    , "xml2.js");
    try e.run(
        \\assertEq(nf, XMLParser.FILE_NOT_FOUND + ":null");
        \\var doc = XMLParser.parseString("<s><x>\u00e9</x></s>");
        \\var w1, w2;
        \\XMLParser.write(doc, "file:///required/save.xml", XMLParser.UTF16_BE, cb(function (st) { w1 = st; }));
        \\assertEq(XMLParser.status(), XMLParser.WRITING);
    , "xml3.js");
    try e.run(
        \\assertEq(w1, XMLParser.OK);
        \\XMLParser.write(doc, "file:///required/save.xml", XMLParser.UTF8, cb(function (st) { w2 = st; }));
    , "xml4.js");
    try e.run(
        \\assertEq(w2, XMLParser.FILE_OVERWRITE_ERR);
        \\var back; XMLParser.parse("file:///required/save.xml", cb(function (st, d) { back = d.documentElement.firstChild.firstChild.data; }));
        \\assertThrows(function () { XMLParser.write(doc, "file:///required/x.xml", 9, function () {}); }, "HDDVD_E_ARGUMENT");
    , "xml5.js");
    try e.run("assertEq(back, '\\u00e9');", "xml6.js");
    const saved = try e.store.read("file:///required/save.xml");
    try std.testing.expect(std.mem.startsWith(u8, saved, "\xfe\xff\x00<\x00?\x00x"));
}

test "an application's scripts are one program" {
    const e = try testenv.Env.create();
    defer e.destroy();
    // The first file reads a var and calls a function that only the second declares.
    try std.testing.expect(e.script.runScripts(&.{
        .{ .name = "a.js", .bytes = "var early = late;\nvar called = lateFn();" },
        .{ .name = "b.js", .bytes = "var late = 5;\nfunction lateFn() { return 7; }" },
    }, "app.xmf"));
    try e.run("assertEq(early, undefined); assertEq(called, 7); assertEq(late, 5);", "check.js");
    // Positions in the joined program name the file and its own line.
    const files = [_]Script.Source{ .{ .name = "a.js", .bytes = "" }, .{ .name = "b.js", .bytes = "" } };
    const m = try Script.mapLines(std.testing.allocator, "TypeError: x\n    at f (app.xmf:5:3)\n    at <eval> (app.xmf:2:1)", "app.xmf", &files, &.{ 1, 4 });
    defer std.testing.allocator.free(m);
    try std.testing.expectEqualStrings("TypeError: x\n    at f (b.js:2:3)\n    at <eval> (a.js:2:1)", m);
}
