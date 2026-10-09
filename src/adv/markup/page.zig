//! A markup page of an Advanced Application (an .xmu file, HD DVD Vol. 3 §7.4–7.6): loading with `include`
//! processing, the content elements with their kinds and `state:` attributes, and the style cascade that
//! computes every element's style each tick (§7.6.1):
//!
//! a. applicative: `<style select="…">` in document order, applied to the selected elements;
//! b. referential: an element's `style="id …"`, left to right, each style's own references first;
//! c. inline `style:` attributes;
//! d. timing overrides (`<set>`, `<animate>`);
//! e. script overrides (the Animated Property API).
//!
//! Later wins; inheritance and `inherit` then work top-down. XPath `select`s read the values at the start of
//! the tick: the styles computed at the previous tick and the states of the last `snapshot` (§7.2.8.2: a
//! gesture's state change shows in timing and style at the next tick). No VLC dependency.

const std = @import("std");
const dom = @import("../dom.zig");
const xpath = @import("../xpath.zig");
const uri = @import("../uri.zig");
const style = @import("style.zig");
const timing_mod = @import("timing.zig");

pub const core_ns = "http://www.dvdforum.org/2005/ihd";
pub const state_ns = "http://www.dvdforum.org/2005/ihd#state";

pub const Error = error{ BadPage, OutOfMemory };

/// Reads a file by URI (from the File Cache); the caller frees the bytes with the page's allocator.
pub const Loader = struct {
    ctx: *anyopaque,
    read: *const fn (ctx: *anyopaque, u: []const u8) anyerror![]u8,
};

pub const Kind = enum {
    body,
    div,
    p,
    span,
    br,
    button,
    input,
    area,
    object,

    pub fn of(n: *const dom.Node) ?Kind {
        if (n.type != .element or !std.mem.eql(u8, n.ns, core_ns)) return null;
        return std.meta.stringToEnum(Kind, n.local);
    }

    /// area, button, input: can take focus and be actioned (§7.5.1).
    pub fn activatable(k: Kind) bool {
        return k == .area or k == .button or k == .input;
    }

    /// Navigable elements know about the cursor (state:pointer).
    pub fn navigable(k: Kind) bool {
        return k.activatable() or k == .div or k == .p or k == .span;
    }
};

pub const State = struct {
    enabled: bool = true,
    focused: bool = false,
    actioned: bool = false,
    pointer: bool = false,
    /// button/area: "true"/"false"; input: its text. Owned by the page.
    value: []u8 = &.{},
    /// body only: the application is in the foreground.
    foreground: bool = false,
};

/// Layout results the rest of the engine reads (set by layout.zig), in region coordinates.
pub const Box = struct {
    /// The border rectangle; empty when the element generates no areas.
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,
    /// The containing block's size (percentages of normalized values).
    cb_w: f32 = 0,
    cb_h: f32 = 0,
    shown: bool = false,
};

pub const Elem = struct {
    node: *dom.Node,
    kind: Kind,
    parent: ?*Elem,
    /// Document order.
    index: u32,
    spec: [style.count]?[]const u8 = @splat(null),
    style: style.Style,
    state: State = .{},
    /// The state at the start of the tick, which XPath reads (its value is owned too).
    seen: State = .{},
    box: Box = .{},
    /// The navIndex generated for `auto` at the page load (focus.zig); null if it was not auto then.
    nav_auto: ?[2]i32 = null,
    /// Input in progress (focus.zig): a key activation ends after this tick; a pointer activation is held
    /// until the button is released; focus follows when the activation ends.
    key_actioned: ?u64 = null,
    pressed: bool = false,
    focus_after: bool = false,
    /// Kept across syncs: false once the node left the page.
    live: bool = true,
};

const Rule = struct { node: *dom.Node, select: ?xpath.XPath };

/// Property overrides above timing (script): element and property → value.
pub const Overrides = std.AutoHashMapUnmanaged(struct { elem: *Elem, prop: style.Prop }, []const u8);

pub const Page = struct {
    gpa: std.mem.Allocator,
    doc: *dom.Document,
    body: ?*dom.Node = null,
    elems: std.ArrayList(*Elem) = .empty,
    rules: std.ArrayList(Rule) = .empty,
    /// Scratch for one style computation.
    arena: std.heap.ArenaAllocator,
    aperture_h: u32,
    /// The timesheets (buildTiming).
    timing: ?*timing_mod.Timing = null,
    script: Overrides = .empty,
    /// Variables, GPRM/SPRM: the host the application sets (property functions are the page's own).
    xpath_host: xpath.Host = .{},

    /// Loads the page at `doc_uri`, processing its includes.
    pub fn load(gpa: std.mem.Allocator, loader: Loader, doc_uri: []const u8, aperture_h: u32) Error!*Page {
        const bytes = loader.read(loader.ctx, doc_uri) catch return error.BadPage;
        defer gpa.free(bytes);
        return fromBytes(gpa, loader, bytes, doc_uri, aperture_h);
    }

    pub fn fromBytes(gpa: std.mem.Allocator, loader: ?Loader, bytes: []const u8, doc_uri: []const u8, aperture_h: u32) Error!*Page {
        const doc = dom.parse(gpa, bytes, null) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else error.BadPage;
        errdefer doc.destroy();
        doc.uri = try gpa.dupe(u8, doc_uri);
        const root = doc.root() orelse return error.BadPage;
        if (!root.is(core_ns, "root")) return error.BadPage;
        const p = try gpa.create(Page);
        errdefer gpa.destroy(p);
        p.* = .{ .gpa = gpa, .doc = doc, .arena = .init(gpa), .aperture_h = aperture_h };
        errdefer p.arena.deinit();
        p.body = root.child(core_ns, "body");
        try p.includes(loader);
        p.body = root.child(core_ns, "body");
        try p.loadRules();
        try p.sync();
        try p.initialState();
        p.snapshot();
        p.cascade();
        return p;
    }

    pub fn destroy(p: *Page) void {
        for (p.rules.items) |*r| if (r.select) |*x| x.deinit();
        p.rules.deinit(p.gpa);
        for (p.elems.items) |e| p.freeElem(e);
        p.elems.deinit(p.gpa);
        if (p.timing) |t| t.destroy();
        p.script.deinit(p.gpa);
        p.arena.deinit();
        p.doc.destroy();
        p.gpa.destroy(p);
    }

    fn freeElem(p: *Page, e: *Elem) void {
        e.node.view = null;
        p.gpa.free(e.state.value);
        p.gpa.free(e.seen.value);
        p.gpa.destroy(e);
    }

    pub fn elemOf(n: *const dom.Node) ?*Elem {
        return @ptrCast(@alignCast(n.view));
    }

    // ---- loading ------------------------------------------------------------------------------------------

    /// §7.5.3.1.7: every condition is evaluated on the document before any include is merged; a missing file
    /// is skipped, a malformed one makes the page invalid.
    fn includes(p: *Page, loader: ?Loader) Error!void {
        const root = p.doc.root().?;
        var list: std.ArrayList(*dom.Node) = .empty;
        defer list.deinit(p.gpa);
        for ([_][]const u8{ "head", "body" }) |where| {
            const parent = root.child(core_ns, where) orelse continue;
            var c = parent.firstElement();
            while (c) |e| : (c = e.nextElement()) {
                if (!e.is(core_ns, "include")) continue;
                if (!(p.condition(e) catch false)) continue;
                try list.append(p.gpa, e);
            }
        }
        // Includes whose condition is false, or that are not processed, just go away.
        for ([_][]const u8{ "head", "body" }) |where| {
            const parent = root.child(core_ns, where) orelse continue;
            var c = parent.firstElement();
            while (c) |e| {
                c = e.nextElement();
                if (e.is(core_ns, "include") and std.mem.indexOfScalar(*dom.Node, list.items, e) == null) e.detach();
            }
        }
        for (list.items) |inc| {
            defer inc.detach();
            const l = loader orelse continue;
            const href = inc.attr("href") orelse continue;
            const target = p.resolve(inc, href) catch continue;
            defer p.gpa.free(target);
            const bytes = l.read(l.ctx, target) catch continue; // not found: as if absent
            defer p.gpa.free(bytes);
            const sub = dom.parse(p.gpa, bytes, null) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else error.BadPage;
            defer sub.destroy();
            const top = sub.root() orelse return error.BadPage;
            if (!(top.is(core_ns, "div") or top.is(core_ns, "styling") or top.is(core_ns, "timing"))) return error.BadPage;
            const copy = try p.doc.importNode(top, true);
            // Relative URIs inside resolve against the included file.
            if (copy.attrNS(dom.xml_ns, "base") == null) try copy.setAttrNS(dom.xml_ns, "xml", "base", target);
            inc.parent.?.insertBefore(copy, inc);
        }
    }

    /// An include's condition, with the body as context (true when absent).
    fn condition(p: *Page, inc: *dom.Node) !bool {
        const src = inc.attr("condition") orelse return true;
        var x = try xpath.compile(p.gpa, src);
        defer x.deinit();
        const ctx_node = p.body orelse return false;
        _ = p.arena.reset(.retain_capacity);
        var host = p.xpath_host;
        host.property = null; // nothing is animated yet
        return x.evalBool(p.arena.allocator(), .{ .node = ctx_node, .scope = inc, .host = &host });
    }

    fn loadRules(p: *Page) Error!void {
        const head = p.doc.root().?.child(core_ns, "head") orelse return;
        var c: ?*dom.Node = head.first;
        while (c) |n| : (c = n.following(head)) {
            if (!n.is(core_ns, "style")) continue;
            var r: Rule = .{ .node = n, .select = null };
            if (n.attr("select")) |sel| r.select = xpath.compile(p.gpa, sel) catch null;
            try p.rules.append(p.gpa, r);
        }
    }

    /// Brings the element list up to the DOM (after loading, and whenever scripts change the tree).
    pub fn sync(p: *Page) Error!void {
        for (p.elems.items) |e| e.live = false;
        var list: std.ArrayList(*Elem) = .empty;
        errdefer list.deinit(p.gpa);
        if (p.body) |body| {
            var c: ?*dom.Node = body;
            while (c) |n| {
                const kind = Kind.of(n);
                var skip = kind == null and n != body;
                if (kind) |k| {
                    const e = elemOf(n) orelse blk: {
                        const x = try p.gpa.create(Elem);
                        x.* = .{ .node = n, .kind = k, .parent = null, .index = 0, .style = .initial(p.aperture_h) };
                        n.view = x;
                        break :blk x;
                    };
                    e.live = true;
                    e.index = @intCast(list.items.len);
                    e.parent = if (n == body) null else parentElem(n);
                    try list.append(p.gpa, e);
                }
                // Text belongs to its element; foreign and non-display elements are not walked into.
                if (n.type != .element) skip = true;
                c = if (!skip and n.first != null) n.first else nextSkipping(n, body);
            }
        }
        for (p.elems.items) |e| if (!e.live) p.freeElem(e);
        p.elems.deinit(p.gpa);
        p.elems = list;
    }

    fn parentElem(n: *dom.Node) ?*Elem {
        var q = n.parent;
        while (q) |x| : (q = x.parent) if (elemOf(x)) |e| return e;
        return null;
    }

    fn nextSkipping(n: *dom.Node, root: *dom.Node) ?*dom.Node {
        var x = n;
        while (x != root) {
            if (x.next) |s| return s;
            x = x.parent orelse return null;
        }
        return null;
    }

    /// state: attributes given in markup (§7.6.3.4): enabled, value, and focused (the last one wins).
    fn initialState(p: *Page) Error!void {
        var focus: ?*Elem = null;
        for (p.elems.items) |e| {
            if (e.node.attrNS(state_ns, "enabled")) |v| e.state.enabled = !std.mem.eql(u8, std.mem.trim(u8, v, " "), "false");
            const v = e.node.attrNS(state_ns, "value") orelse if (e.kind == .button or e.kind == .area) "false" else "";
            e.state.value = try p.gpa.dupe(u8, v);
            if (e.kind.activatable()) if (e.node.attrNS(state_ns, "focused")) |f| if (std.mem.eql(u8, std.mem.trim(u8, f, " "), "true")) {
                focus = e;
            };
        }
        if (focus) |e| e.state.focused = true;
    }

    // ---- URIs ---------------------------------------------------------------------------------------------

    /// The base URI of node `n`: the document's, changed by xml:base attributes from the top down.
    pub fn baseOf(p: *Page, n: *const dom.Node) ![]u8 {
        var chain: [32]*const dom.Node = undefined;
        var k: usize = 0;
        var q: ?*const dom.Node = n;
        while (q) |x| : (q = x.parent) {
            if (x.type == .element and x.attrNS(dom.xml_ns, "base") != null and k < chain.len) {
                chain[k] = x;
                k += 1;
            }
        }
        var base = try p.gpa.dupe(u8, p.doc.uri);
        while (k > 0) {
            k -= 1;
            const nb = uri.xmlBase(p.gpa, base, chain[k].attrNS(dom.xml_ns, "base").?) catch continue;
            p.gpa.free(base);
            base = nb;
        }
        return base;
    }

    /// `ref` resolved in the context of node `n` (caller frees).
    pub fn resolve(p: *Page, n: *const dom.Node, ref: []const u8) ![]u8 {
        const base = try p.baseOf(n);
        defer p.gpa.free(base);
        return uri.resolve(p.gpa, base, ref);
    }

    // ---- the cascade --------------------------------------------------------------------------------------

    /// Computes every element's style for this tick.
    pub fn cascade(p: *Page) void {
        _ = p.arena.reset(.retain_capacity);
        const a = p.arena.allocator();
        for (p.elems.items) |e| e.spec = @splat(null);

        // a. Applicative, with the values at the start of the tick.
        if (p.body) |body| {
            const host = p.hostForXPath();
            for (p.rules.items) |r| {
                const sel = r.select orelse continue;
                const v = sel.eval(a, .{ .node = body, .scope = r.node, .host = &host }) catch continue;
                if (v != .nodes) continue;
                for (v.nodes) |it| {
                    if (it.attr != null) continue;
                    const e = elemOf(it.node) orelse continue;
                    p.applyStyleElem(e, r.node, 0);
                }
            }
        }
        // b. Referential, c. inline.
        for (p.elems.items) |e| {
            if (e.node.attr("style")) |refs| p.applyRefs(e, refs, 0);
            applyAttrs(e, e.node);
        }
        // d. Timing: per element and property, by priority; e. script.
        const anims: []const timing_mod.Anim = if (p.timing) |t| t.anims(a) else &.{};
        var ai: usize = 0;

        // Computed values, parents first (document order).
        const root_style: style.Style = .initial(p.aperture_h);
        for (p.elems.items) |e| {
            const parent = if (e.parent) |x| &x.style else &root_style;
            const env: style.Env = .{ .parent = parent, .aperture_h = p.aperture_h, .arena = a };
            var s = compute(&e.spec, parent, env);
            const first = ai;
            while (ai < anims.len and anims[ai].elem == e) ai += 1;
            const mine = anims[first..ai];
            const scripted = p.script.count() > 0 and p.hasScript(e);
            if (mine.len > 0 or scripted) {
                // The animated values fold over the value below them (the cascade's so far).
                var spec = e.spec;
                var k: usize = 0;
                while (k < mine.len) {
                    const prop = mine[k].target.style;
                    var end = k;
                    while (end < mine.len and mine[end].target.style == prop) end += 1;
                    var under: []const u8 = blk: {
                        var w: std.Io.Writer.Allocating = .init(a);
                        style.format(&w.writer, &s, prop, pctBase(e, prop)) catch break :blk "";
                        break :blk w.written();
                    };
                    for (mine[k..end]) |*x| under = x.value(a, under);
                    if (prop.longhands().len > 0) setSpecIn(&spec, prop, under) else spec[@intFromEnum(prop)] = under;
                    k = end;
                }
                if (scripted) {
                    var it = p.script.iterator();
                    while (it.next()) |kv| if (kv.key_ptr.elem == e) setSpecIn(&spec, kv.key_ptr.prop, kv.value_ptr.*);
                }
                s = compute(&spec, parent, env);
            }
            e.style = s;
        }
    }

    fn compute(spec: *const [style.count]?[]const u8, parent: *const style.Style, env: style.Env) style.Style {
        var s: style.Style = .initial(env.aperture_h);
        s.inherit(parent);
        for (style.order) |prop| if (spec[@intFromEnum(prop)]) |raw| {
            _ = style.apply(&s, prop, raw, env);
        };
        return s;
    }

    fn hasScript(p: *Page, e: *Elem) bool {
        var it = p.script.keyIterator();
        while (it.next()) |k| if (k.elem == e) return true;
        return false;
    }

    /// What percentages of property `prop` of `e` are of (for normalized values).
    fn pctBase(e: *const Elem, prop: style.Prop) f32 {
        return switch (prop) {
            .y, .height, .blockProgressionDimension, .backgroundPositionVertical => e.box.cb_h,
            else => e.box.cb_w,
        };
    }

    /// Takes the state at the start of a tick: what XPath sees until the next snapshot.
    pub fn snapshot(p: *Page) void {
        for (p.elems.items) |e| {
            const v = e.seen.value;
            e.seen = e.state;
            e.seen.value = v;
            if (!std.mem.eql(u8, v, e.state.value)) {
                const copy = p.gpa.dupe(u8, e.state.value) catch continue;
                p.gpa.free(v);
                e.seen.value = copy;
            }
        }
    }

    /// Builds the timesheets (once the page is loaded); seconds are `title_fps` title frames and `tick_rate`
    /// ticks.
    pub fn buildTiming(p: *Page, title_fps: f64, tick_rate: f64) !void {
        if (p.timing) |t| t.destroy();
        p.timing = null;
        p.timing = try timing_mod.Timing.build(p.gpa, p, title_fps, tick_rate);
    }

    fn applyRefs(p: *Page, e: *Elem, refs: []const u8, depth: u32) void {
        if (depth > 16) return; // a reference cycle
        var it = std.mem.tokenizeAny(u8, refs, " \t\r\n");
        while (it.next()) |id| {
            const n = p.doc.getElementById(id) orelse continue;
            if (!n.is(core_ns, "style")) continue;
            p.applyStyleElem(e, n, depth + 1);
        }
    }

    /// A `<style>` on element `e`: its referenced styles first, then its own attributes.
    fn applyStyleElem(p: *Page, e: *Elem, s: *dom.Node, depth: u32) void {
        if (s.attr("style")) |refs| p.applyRefs(e, refs, depth);
        applyAttrs(e, s);
    }

    /// The style: attributes of `n` onto `e`: shorthands first, so longhands on the same element win.
    fn applyAttrs(e: *Elem, n: *const dom.Node) void {
        for ([_]bool{ true, false }) |shorthands| {
            for (n.attrs.items) |at| {
                if (!std.mem.eql(u8, at.ns, style.ns)) continue;
                const prop = style.Prop.byName(at.local) orelse continue;
                if ((prop.longhands().len > 0) != shorthands) continue;
                setSpec(e, prop, at.value);
            }
        }
    }

    /// Sets a specified value; shorthands set their longhands.
    pub fn setSpec(e: *Elem, prop: style.Prop, raw: []const u8) void {
        setSpecIn(&e.spec, prop, raw);
    }

    fn setSpecIn(spec: *[style.count]?[]const u8, prop: style.Prop, raw: []const u8) void {
        switch (prop) {
            .border => for (prop.longhands()) |l| {
                spec[@intFromEnum(l)] = raw;
            },
            .padding => {
                // 1–4 widths: before end after start, as parsed in style.zig (the sides are slices of `raw`).
                const v = style.firstValue(raw);
                if (std.mem.eql(u8, v, "inherit")) {
                    for (prop.longhands()) |l| spec[@intFromEnum(l)] = v;
                    return;
                }
                var t: [4][]const u8 = undefined;
                var n: usize = 0;
                var it = std.mem.tokenizeAny(u8, v, " \t");
                while (it.next()) |x| {
                    if (n == 4) return;
                    t[n] = x;
                    n += 1;
                }
                const sides: [4][]const u8 = switch (n) {
                    1 => .{ t[0], t[0], t[0], t[0] },
                    2 => .{ t[0], t[1], t[0], t[1] },
                    3 => .{ t[0], t[1], t[2], t[1] },
                    4 => t,
                    else => return,
                };
                for (prop.longhands(), sides) |l, side| spec[@intFromEnum(l)] = side;
            },
            else => spec[@intFromEnum(prop)] = raw,
        }
    }

    // ---- XPath --------------------------------------------------------------------------------------------

    /// The XPath host for this page: the application's variables, plus property functions on its elements.
    pub fn hostForXPath(p: *Page) xpath.Host {
        var h = p.xpath_host;
        h.ctx = p;
        h.property = property;
        return h;
    }

    fn property(ctx: ?*anyopaque, node: *dom.Node, ns: []const u8, local: []const u8, a: std.mem.Allocator) ?xpath.Value {
        _ = ctx;
        const e = elemOf(node) orelse return null;
        if (std.mem.eql(u8, ns, state_ns)) {
            const st = e.seen;
            if (std.mem.eql(u8, local, "focused")) return if (e.kind.activatable()) .{ .boolean = st.focused } else null;
            if (std.mem.eql(u8, local, "actioned")) return if (e.kind.activatable()) .{ .boolean = st.actioned } else null;
            if (std.mem.eql(u8, local, "pointer")) return if (e.kind.navigable()) .{ .boolean = st.pointer } else null;
            if (std.mem.eql(u8, local, "enabled")) return .{ .boolean = st.enabled };
            if (std.mem.eql(u8, local, "foreground")) return if (e.kind == .body) .{ .boolean = st.foreground } else null;
            if (std.mem.eql(u8, local, "value")) return if (e.kind == .button or e.kind == .area or e.kind == .input or e.kind == .object) .{ .string = st.value } else null;
            return null;
        }
        if (std.mem.eql(u8, ns, style.ns)) {
            const prop = style.Prop.byName(local) orelse return null;
            switch (prop) {
                .opacity => return .{ .number = e.style.opacity },
                .backgroundFrame => return .{ .number = @floatFromInt(e.style.backgroundFrame) },
                .zIndex => return .{ .number = @floatFromInt(e.style.zIndex orelse 0) },
                .whiteSpaceCollapse => return .{ .boolean = e.style.whiteSpaceCollapse },
                else => {},
            }
            var w: std.Io.Writer.Allocating = .init(a);
            style.format(&w.writer, &e.style, prop, pctBase(e, prop)) catch return null;
            return .{ .string = w.written() };
        }
        return null;
    }

    // ---- state --------------------------------------------------------------------------------------------

    pub const StateAttr = enum { enabled, focused, actioned, pointer, foreground };

    /// Sets a boolean state and reflects it in the DOM attribute.
    pub fn setState(p: *Page, e: *Elem, which: StateAttr, on: bool) void {
        const field = switch (which) {
            .enabled => &e.state.enabled,
            .focused => &e.state.focused,
            .actioned => &e.state.actioned,
            .pointer => &e.state.pointer,
            .foreground => &e.state.foreground,
        };
        if (field.* == on) return;
        field.* = on;
        e.node.setAttrNS(state_ns, "state", @tagName(which), if (on) "true" else "false") catch {};
        _ = p;
    }

    pub fn setValue(p: *Page, e: *Elem, v: []const u8) !void {
        const copy = try p.gpa.dupe(u8, v);
        p.gpa.free(e.state.value);
        e.state.value = copy;
        e.node.setAttrNS(state_ns, "state", "value", v) catch {};
    }

    /// The focused element of the page, if any.
    pub fn focused(p: *const Page) ?*Elem {
        for (p.elems.items) |e| if (e.state.focused) return e;
        return null;
    }
};

// ---- tests --------------------------------------------------------------------------------------------------

const testing = std.testing;

const MemLoader = struct {
    files: []const struct { []const u8, []const u8 },

    fn read(ctx: *anyopaque, u: []const u8) anyerror![]u8 {
        const self: *MemLoader = @ptrCast(@alignCast(ctx));
        for (self.files) |f| if (std.mem.eql(u8, f[0], u)) return testing.allocator.dupe(u8, f[1]);
        return error.FileNotFound;
    }

    fn loader(self: *MemLoader) Loader {
        return .{ .ctx = self, .read = read };
    }
};

const page_src =
    \\<root xmlns="http://www.dvdforum.org/2005/ihd" xmlns:style="http://www.dvdforum.org/2005/ihd#style"
    \\      xmlns:state="http://www.dvdforum.org/2005/ihd#state" xml:lang="en">
    \\ <head>
    \\  <include href="styles.xmu"/>
    \\  <include href="nothere.xmu"/>
    \\  <include href="never.xmu" condition="1 = 2"/>
    \\  <styling>
    \\   <style id="a" style:x="1px" style:y="1px"/>
    \\   <style id="b" style:x="2px" style:y="2px"/>
    \\   <style id="c" style="a b" style:y="3px"/>
    \\   <style id="d" style:x="3px" style:y="4px"/>
    \\   <style id="e" style:x="4px" style:y="5px"/>
    \\   <style id="f" style="d e" style:y="6px"/>
    \\   <style select="//button[state:focused()=true()]" style:opacity="0.5"/>
    \\  </styling>
    \\ </head>
    \\ <body style:color="yellow">
    \\  <div id="d1" style:width="100px" style:border="2px solid" style:borderAfter="red">
    \\   <p id="p1" style="c f">Hi</p>
    \\   <button id="b1" style:color="inherit" state:focused="true"/>
    \\   <button id="b2" class="big" state:value="true"/>
    \\  </div>
    \\  <include href="part.xmu"/>
    \\ </body>
    \\</root>
;

test "load, includes, cascade" {
    var files: MemLoader = .{ .files = &.{
        .{ "file:///dvddisc/ADV_OBJ/m/page.xmu", page_src },
        .{ "file:///dvddisc/ADV_OBJ/m/styles.xmu",
        \\<styling xmlns="http://www.dvdforum.org/2005/ihd" xmlns:style="http://www.dvdforum.org/2005/ihd#style">
        \\ <style select="class('big')" style:padding="1px 2px"/>
        \\</styling>
        },
        .{ "file:///dvddisc/ADV_OBJ/m/part.xmu",
        \\<div xmlns="http://www.dvdforum.org/2005/ihd" id="inc" xml:base="sub/"><span id="s"/></div>
        },
    } };
    const p = try Page.load(testing.allocator, files.loader(), "file:///dvddisc/ADV_OBJ/m/page.xmu", 1080);
    defer p.destroy();

    const el = struct {
        fn get(pg: *Page, id: []const u8) *Elem {
            return Page.elemOf(pg.doc.getElementById(id).?).?;
        }
    }.get;
    // The spec's referential example: style="c f" gives x 4px, y 6px.
    try testing.expectEqual(@as(f32, 4), el(p, "p1").style.x.?.v);
    try testing.expectEqual(@as(f32, 6), el(p, "p1").style.y.?.v);
    // Inherited color through the div (color does not apply to it, but passes through).
    try testing.expectEqual(style.Color{ 255, 255, 0, 255 }, el(p, "p1").style.color);
    try testing.expectEqual(style.Color{ 255, 255, 0, 255 }, el(p, "b1").style.color);
    // The border shorthand, then a longhand on the same element; the default border colour is `color`.
    const d1 = el(p, "d1");
    try testing.expectEqual(style.BorderStyle.solid, d1.style.borders[0].style);
    try testing.expectEqual(@as(f32, 2), d1.style.borders[0].width);
    try testing.expectEqual(style.BorderStyle.none, d1.style.borders[2].style);
    try testing.expectEqual(style.Color{ 255, 0, 0, 255 }, d1.style.borders[2].color.?);
    // The included stylesheet applies (class('big')); padding 2 values: before/after, start/end.
    const b2 = el(p, "b2");
    try testing.expectEqual(@as(f32, 1), b2.style.padding[0].v);
    try testing.expectEqual(@as(f32, 2), b2.style.padding[3].v);
    try testing.expectEqualStrings("true", b2.state.value);
    // A select on state: applies from the start (initial state is known at the first cascade).
    try testing.expectEqual(@as(f32, 0.5), el(p, "b1").style.opacity);
    try testing.expectEqual(@as(f32, 1), b2.style.opacity);
    // The included div is in the body, with its base.
    const inc = p.doc.getElementById("inc").?;
    const s = Page.elemOf(p.doc.getElementById("s").?).?;
    try testing.expect(s.parent.?.node == inc);
    const r = try p.resolve(s.node, "x.png");
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("file:///dvddisc/ADV_OBJ/m/sub/x.png", r);
    // No include elements remain.
    var c: ?*dom.Node = p.doc.root();
    while (c) |n| : (c = n.following(&p.doc.node)) try testing.expect(!n.is(core_ns, "include"));

    // State changes are reflected in the DOM, and selects see them at the next cascade.
    p.setState(el(p, "b1"), .focused, false);
    p.setState(b2, .focused, true);
    try testing.expectEqualStrings("true", b2.node.attrNS(state_ns, "focused").?);
    p.cascade(); // not seen before the next tick
    try testing.expectEqual(@as(f32, 0.5), el(p, "b1").style.opacity);
    p.snapshot();
    p.cascade();
    try testing.expectEqual(@as(f32, 0.5), b2.style.opacity);
    try testing.expectEqual(@as(f32, 1), el(p, "b1").style.opacity);

    // Overrides beat inline style; removing them restores it.
    try p.script.put(testing.allocator, .{ .elem = d1, .prop = .width }, "50px");
    p.cascade();
    try testing.expectEqual(@as(f32, 50), d1.style.width.?.v);
    p.script.clearRetainingCapacity();
    p.cascade();
    try testing.expectEqual(@as(f32, 100), d1.style.width.?.v);

    // XPath property functions give normalized values.
    const host = p.hostForXPath();
    var x = try xpath.compile(testing.allocator, "//div[style:width()='100px' and style:color()='rgba(255,255,0,255)']");
    defer x.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expect(try x.evalBool(arena.allocator(), .{ .node = p.body.?, .scope = p.body.?, .host = &host }));
}

test "a malformed include makes the page invalid" {
    var files: MemLoader = .{ .files = &.{
        .{ "file:///a/p.xmu",
        \\<root xmlns="http://www.dvdforum.org/2005/ihd" xml:lang="en"><body><include href="bad.xmu"/></body></root>
        },
        .{ "file:///a/bad.xmu", "<div" },
    } };
    try testing.expectError(error.BadPage, Page.load(testing.allocator, files.loader(), "file:///a/p.xmu", 1080));
    try testing.expectError(error.BadPage, Page.fromBytes(testing.allocator, null, "<root/>", "file:///a/q.xmu", 1080));
}
