//! Timing markup (HD DVD Vol. 3 §7.7): a page's timesheets (`<timing>` elements, or the inline timing of a
//! page without any), their intervals on their clock (title, application or page), and what their active
//! cues do: `animate`/`set` values for the cascade's timing layer, `state:` values, `<event>`s for scripts
//! and `<link>`s to other pages.
//!
//! Each tick (§7.2.4.2.2, §7.7.2):
//! - `par` children start at the parent's start plus their `begin`; `seq` children one after the other; a
//!   path `begin` starts an interval at the first tick it is true, and can start another once that interval
//!   has finished and the path has been false (§7.7.2.4). Path times are allowed only off the title clock and
//!   under a `par`.
//! - The simple duration comes from `dur`, an offset `end` (from the syncbase) or the children (§7.7.2.1); an
//!   interval finishes at the earliest of start + SD, the parent's finish and its `end` path.
//! - A cue targets its `select` (evaluated when it starts) or else the nodes of the closest path `begin`
//!   above it. `fill="hold"` keeps its last values until its parent finishes (not on the title clock).
//! - Animations of one property are applied by priority: clock (page, then application, then title), then
//!   start, then document order; `replace` overrides what is below, `sum` adds to it.
//! - `clockDivisor` n: the timesheet is evaluated when its clock reaches a new multiple of n, and its values
//!   are kept in between.
//!
//! Path expressions read the properties at the start of the tick (the elements' snapshots and the previous
//! tick's computed styles). No VLC dependency.

const std = @import("std");
const dom = @import("../dom.zig");
const xpath = @import("../xpath.zig");
const style = @import("style.zig");
const page_mod = @import("page.zig");
const anim = @import("anim.zig");

const Page = page_mod.Page;
const Elem = page_mod.Elem;

pub const timing_ns = page_mod.core_ns; // timing elements are in the core namespace (Table 7.4.2-1)

/// Ranked low to high: title-clocked animations win over application-clocked ones, which win over
/// page-clocked ones (§7.7.2.3).
pub const Clock = enum(u2) { page, application, title };

/// The state attributes timing can set (§7.6.3.4.1); the others belong to the presentation engine.
pub const StateProp = enum { enabled, focused, value };

/// What a timesheet animates: a style property or a state attribute.
pub const Target = union(enum) {
    style: style.Prop,
    state: StateProp,
};

/// The clocks at this tick, in their units: title frames, application and page ticks.
pub const Clocks = struct {
    title: i64,
    app: i64,
    page: i64,
    /// The application's valid interval on the Title Timeline (frames); null end: the title's end.
    valid: [2]?i64 = .{ 0, null },
};

/// An animation that applies at this tick.
pub const Anim = struct {
    elem: *Elem,
    target: Target,
    values: []const []const u8,
    /// Fraction of the simple duration; null for `set` (the first value).
    f: ?f64,
    sum: bool,
    linear: bool,
    rank: Rank,

    pub const Rank = struct {
        clock: Clock,
        start: i64,
        order: u32,

        pub fn less(a: Rank, b: Rank) bool {
            if (a.clock != b.clock) return @backingInt(a.clock) < @backingInt(b.clock);
            if (a.start != b.start) return a.start < b.start;
            return a.order < b.order;
        }
    };

    /// The animated value given what is below it.
    pub fn value(x: *const Anim, a: std.mem.Allocator, under: []const u8) []const u8 {
        const prop: ?style.Prop = if (x.target == .style) x.target.style else null;
        const v = if (x.f) |f| anim.sample(a, prop, x.values, f, x.linear) else x.values[0];
        if (x.sum) if (anim.add(a, prop, under, v)) |s| return s;
        return v;
    }
};

/// An `<event>` raised by a cue that started: one per target node (for the script host).
pub const Fired = struct { name: []const u8, target: *dom.Node, event: *dom.Node };

const When = union(enum) {
    none,
    offset: i64,
    path: xpath.XPath,
};

const Kind = enum { timing, par, seq, cue, inline_el };

const Op = struct {
    kind: enum { animate, set, event, link },
    node: *dom.Node,
    sum: bool = false,
    linear: bool = true,
    props: []const PropValues = &.{},
};

const PropValues = struct { target: Target, values: []const []const u8 };

const Node = struct {
    kind: Kind,
    dom: *dom.Node,
    order: u32,
    children: []*Node = &.{},
    begin: When = .none,
    end: When = .none,
    dur: ?i64 = null,
    seq: bool = false,
    hold: bool = false,
    select: ?xpath.XPath = null,
    ops: []const Op = &.{},
    /// A root (`timing`, or the body of inline timing): without dur or end it lasts the application's valid
    /// interval (§7.7.2).
    root: bool = false,
    rt: Runtime = .{},

    fn pathTimed(n: *const Node) bool {
        return n.begin == .path or n.end == .path;
    }
};

const Runtime = struct {
    /// An interval has been placed (offset begins: for the syncbase in `sync`).
    placed: bool = false,
    sync: i64 = 0,
    active: bool = false,
    start: i64 = 0,
    /// Scheduled or resolved finish; null: indefinite.
    finish: ?i64 = null,
    sd: ?i64 = null,
    /// Path begins: may start another interval; the path has been false since the last start.
    armed: bool = true,
    seen_false: bool = false,
    /// The interval was entered (for `fill`, events and links once per interval).
    entered: bool = false,
    path_nodes: std.ArrayList(*dom.Node) = .empty,
    targets: std.ArrayList(*dom.Node) = .empty,
};

const Sheet = struct {
    root: *Node,
    clock: Clock,
    divisor: u32,
    last: ?i64 = null,
    out: std.ArrayList(Anim) = .empty,
};

pub const Timing = struct {
    gpa: std.mem.Allocator,
    /// The timesheet trees.
    arena: std.heap.ArenaAllocator,
    sheets: std.ArrayList(Sheet) = .empty,
    nodes: std.ArrayList(*Node) = .empty,
    /// Per-tick scratch (XPath values, sampled strings).
    scratch: std.heap.ArenaAllocator,
    /// Events raised since the script host last took them.
    events: std.ArrayList(Fired) = .empty,
    /// A `<link>` that fired: the page to load next.
    link: ?*dom.Node = null,
    /// State values set by animations this tick.
    states: std.ArrayList(StateSet) = .empty,

    pub const StateSet = struct { elem: *Elem, which: StateProp, value: []const u8 };

    /// Builds the timesheets of `page` (an empty set for a page without timing). Times in seconds count
    /// `title_fps` frames on the title clock and `tick_rate` ticks on the others (nominal rates).
    pub fn build(gpa: std.mem.Allocator, page: *Page, title_fps: f64, tick_rate: f64) !*Timing {
        const tm = try gpa.create(Timing);
        tm.* = .{ .gpa = gpa, .arena = .init(gpa), .scratch = .init(gpa) };
        errdefer tm.destroy();
        var b: Builder = .{ .tm = tm, .page = page, .a = tm.arena.allocator(), .title_fps = title_fps, .tick_rate = tick_rate };
        const root = page.doc.root() orelse return tm;
        if (root.child(page_mod.core_ns, "head")) |head| {
            var c: ?*dom.Node = head.first;
            while (c) |n| : (c = n.following(head)) {
                if (!n.is(timing_ns, "timing")) continue;
                try b.sheet(n);
            }
        }
        if (tm.sheets.items.len == 0) if (page.body) |body| try b.inlineSheet(body);
        return tm;
    }

    pub fn destroy(tm: *Timing) void {
        for (tm.nodes.items) |n| {
            n.rt.path_nodes.deinit(tm.gpa);
            n.rt.targets.deinit(tm.gpa);
            if (n.select) |*x| x.deinit();
            if (n.begin == .path) n.begin.path.deinit();
            if (n.end == .path) n.end.path.deinit();
        }
        for (tm.sheets.items) |*s| s.out.deinit(tm.gpa);
        tm.sheets.deinit(tm.gpa);
        tm.nodes.deinit(tm.gpa);
        tm.events.deinit(tm.gpa);
        tm.states.deinit(tm.gpa);
        tm.scratch.deinit();
        tm.arena.deinit();
        tm.gpa.destroy(tm);
    }

    pub fn empty(tm: *const Timing) bool {
        return tm.sheets.items.len == 0;
    }

    /// Evaluates the timesheets at clocks `c`. Animations are in `anims()`, state values in `states`.
    pub fn tick(tm: *Timing, page: *Page, c: Clocks) void {
        _ = tm.scratch.reset(.retain_capacity);
        tm.states.clearRetainingCapacity();
        var ev: Eval = .{ .tm = tm, .page = page, .c = c, .host = page.hostForXPath(), .a = tm.scratch.allocator() };
        for (tm.sheets.items) |*sh| {
            const raw = switch (sh.clock) {
                .title => c.title,
                .application => c.app,
                .page => c.page,
            };
            const div: i64 = sh.divisor;
            const t = @divFloor(raw, div) * div;
            if (sh.last) |l| {
                if (t == l) continue; // between derived ticks: values repeat
                // The title clock jumps back on seeks: title timing is a function of the title time.
                if (t < l) resetTree(tm, sh.root);
            }
            sh.last = t;
            sh.out.clearRetainingCapacity();
            ev.sheet = sh;
            ev.t = t;
            const lo: i64 = if (sh.clock == .title) c.valid[0] orelse 0 else 0;
            const hi: ?i64 = if (sh.clock == .title) c.valid[1] else null;
            ev.update(sh.root, lo, hi, lo, true, &.{});
            if (tm.link != null) break; // nothing else runs in an interval that causes a link
        }
        // State animations: the last value by priority, now.
        var list: std.ArrayList(*const Anim) = .empty;
        for (tm.sheets.items) |*sh| for (sh.out.items) |*x| if (x.target == .state) list.append(ev.a, x) catch {};
        std.mem.sort(*const Anim, list.items, {}, struct {
            fn less(_: void, x: *const Anim, y: *const Anim) bool {
                return x.rank.less(y.rank);
            }
        }.less);
        for (list.items) |x| {
            const v = x.value(ev.a, "");
            tm.states.append(tm.gpa, .{ .elem = x.elem, .which = x.target.state, .value = v }) catch {};
        }
    }

    /// The style animations of this tick, sorted by element, property and priority (allocated in `a`).
    pub fn anims(tm: *Timing, a: std.mem.Allocator) []const Anim {
        var list: std.ArrayList(Anim) = .empty;
        for (tm.sheets.items) |*sh| for (sh.out.items) |x| if (x.target == .style and x.elem.live) list.append(a, x) catch {};
        std.mem.sort(Anim, list.items, {}, struct {
            fn less(_: void, x: Anim, y: Anim) bool {
                if (x.elem.index != y.elem.index) return x.elem.index < y.elem.index;
                const px = @backingInt(x.target.style);
                const py = @backingInt(y.target.style);
                if (px != py) return px < py;
                return x.rank.less(y.rank);
            }
        }.less);
        return list.items;
    }
};

fn resetTree(tm: *Timing, n: *Node) void {
    n.rt.path_nodes.deinit(tm.gpa);
    n.rt.targets.deinit(tm.gpa);
    n.rt = .{};
    for (n.children) |c| resetTree(tm, c);
}

// ---- building -------------------------------------------------------------------------------------------------

const Builder = struct {
    tm: *Timing,
    page: *Page,
    a: std.mem.Allocator,
    clock: Clock = .title,
    units: f64 = 60,
    title_fps: f64,
    tick_rate: f64,
    order: u32 = 0,
    defs: ?*dom.Node = null,

    fn sheet(b: *Builder, t: *dom.Node) !void {
        const clock_attr = t.attr("clock") orelse t.attr("syncbase") orelse "title";
        b.clock = std.meta.stringToEnum(Clock, std.mem.trim(u8, clock_attr, " ")) orelse .title;
        b.units = if (b.clock == .title) b.title_fps else b.tick_rate;
        b.defs = t.child(timing_ns, "defs");
        const div = std.fmt.parseInt(u32, std.mem.trim(u8, t.attr("clockDivisor") orelse "1", " "), 10) catch 1;
        const root = try b.node(t, .timing, true);
        root.root = true;
        try b.tm.sheets.append(b.tm.gpa, .{ .root = root, .clock = b.clock, .divisor = @max(1, div) });
    }

    /// A timed element and its timed descendants; `in_par`: its parent is a parallel container.
    fn node(b: *Builder, d: *dom.Node, kind: Kind, in_par: bool) error{OutOfMemory}!*Node {
        const n = try b.a.create(Node);
        n.* = .{ .kind = kind, .dom = d, .order = b.order };
        b.order += 1;
        try b.tm.nodes.append(b.tm.gpa, n);
        n.dur = if (d.attr("dur")) |v| b.offset(v) else null;
        n.begin = try b.when(d.attr("begin"), in_par);
        n.end = try b.when(d.attr("end"), in_par);
        n.seq = if (d.attr("timeContainer")) |tc| std.mem.eql(u8, std.mem.trim(u8, tc, " "), "seq") else kind == .seq;
        if (kind == .cue) {
            n.hold = b.clock != .title and std.mem.eql(u8, std.mem.trim(u8, d.attr("fill") orelse "remove", " "), "hold");
            if (d.attr("select")) |sel| n.select = xpath.compile(b.tm.gpa, sel) catch null;
            var ops: std.ArrayList(Op) = .empty;
            var c = d.firstElement();
            while (c) |x| : (c = x.nextElement()) try b.op(x, &ops, 0);
            if (d.attr("use")) |use| {
                var it = std.mem.tokenizeAny(u8, use, " \t\r\n");
                while (it.next()) |id| if (b.defined(id)) |x| try b.op(x, &ops, 0);
            }
            n.ops = ops.items;
            return n;
        }
        var kids: std.ArrayList(*Node) = .empty;
        var c = d.firstElement();
        while (c) |x| : (c = x.nextElement()) {
            if (!std.mem.eql(u8, x.ns, timing_ns)) continue;
            const k: Kind = if (std.mem.eql(u8, x.local, "par")) .par else if (std.mem.eql(u8, x.local, "seq")) .seq else if (std.mem.eql(u8, x.local, "cue")) .cue else continue;
            try kids.append(b.a, try b.node(x, k, !n.seq));
        }
        n.children = kids.items;
        return n;
    }

    /// A `defs` entry by id (only those of this timesheet).
    fn defined(b: *Builder, id: []const u8) ?*dom.Node {
        const defs = b.defs orelse return null;
        var c: ?*dom.Node = defs.first;
        while (c) |x| : (c = x.following(defs)) if (x.type == .element) if (x.attr("id")) |xid| if (std.mem.eql(u8, xid, id)) return x;
        return null;
    }

    /// An operation of a cue: animate, set, event, link, or a group of them.
    fn op(b: *Builder, x: *dom.Node, out: *std.ArrayList(Op), depth: u32) error{OutOfMemory}!void {
        if (!std.mem.eql(u8, x.ns, timing_ns) or depth > 16) return;
        if (std.mem.eql(u8, x.local, "g")) {
            var c = x.firstElement();
            while (c) |y| : (c = y.nextElement()) try b.op(y, out, depth + 1);
            return;
        }
        if (std.mem.eql(u8, x.local, "event")) return out.append(b.a, .{ .kind = .event, .node = x });
        if (std.mem.eql(u8, x.local, "link")) return out.append(b.a, .{ .kind = .link, .node = x });
        const is_set = std.mem.eql(u8, x.local, "set");
        if (!is_set and !std.mem.eql(u8, x.local, "animate")) return;
        var props: std.ArrayList(PropValues) = .empty;
        for (x.attrs.items) |at| {
            const target: Target = if (std.mem.eql(u8, at.ns, style.ns)) blk: {
                const p = style.Prop.byName(at.local) orelse continue;
                if (p.anim() == .none) continue;
                break :blk .{ .style = p };
            } else if (std.mem.eql(u8, at.ns, page_mod.state_ns)) blk: {
                const w = std.meta.stringToEnum(StateProp, at.local) orelse continue;
                break :blk .{ .state = w };
            } else continue;
            const values = try anim.split(b.a, at.value);
            if (values.len == 0) continue;
            try props.append(b.a, .{ .target = target, .values = values });
        }
        const calc = std.mem.trim(u8, x.attr("calcMode") orelse "linear", " ");
        const additive = std.mem.trim(u8, x.attr("additive") orelse "replace", " ");
        try out.append(b.a, .{
            .kind = if (is_set) .set else .animate,
            .node = x,
            .sum = !is_set and std.mem.eql(u8, additive, "sum"),
            .linear = !std.mem.eql(u8, calc, "discrete"),
            .props = props.items,
        });
    }

    fn offset(b: *Builder, v: []const u8) ?i64 {
        const d = parseTime(v) orelse return null;
        // Frames count at the title frame rate on the title clock, as ticks on the others.
        return @as(i64, @intFromFloat(@round(d.secs * b.units))) + @as(i64, @intCast(@min(d.frames, 1 << 40)));
    }

    /// A begin or end: a time, or a path expression (only off the title clock, under a par: otherwise a
    /// well-formedness error, and the time never resolves).
    fn when(b: *Builder, v_opt: ?[]const u8, in_par: bool) !When {
        const v = std.mem.trim(u8, v_opt orelse return .none, " \t\r\n");
        if (v.len == 0) return .none;
        if (b.offset(v)) |o| return .{ .offset = o };
        if (b.clock == .title or !in_par) return .{ .offset = std.math.maxInt(i64) / 4 };
        const x = xpath.compile(b.tm.gpa, v) catch return .{ .offset = std.math.maxInt(i64) / 4 };
        return .{ .path = x };
    }

    /// Inline timing (§7.7.4): body (a seq unless said otherwise), and div, p and span (pars) with timing
    /// attributes; an element outside its interval is not displayed.
    fn inlineSheet(b: *Builder, body: *dom.Node) !void {
        var any = false;
        var c: ?*dom.Node = body;
        while (c) |n| : (c = n.following(body)) {
            if (n.type != .element) continue;
            for ([_][]const u8{ "begin", "dur", "end", "timeContainer" }) |name| {
                if (n.attr(name) != null) any = true;
            }
        }
        if (!any) return;
        b.clock = .title;
        b.units = b.title_fps;
        const root = try b.inlineNode(body, true);
        root.root = true;
        if (body.attr("timeContainer") == null) root.seq = true;
        try b.tm.sheets.append(b.tm.gpa, .{ .root = root, .clock = .title, .divisor = 1 });
    }

    fn inlineNode(b: *Builder, d: *dom.Node, in_par: bool) error{OutOfMemory}!*Node {
        const n = try b.node(d, .inline_el, in_par);
        var kids: std.ArrayList(*Node) = .empty;
        try b.inlineKids(d, n, &kids);
        n.children = kids.items;
        return n;
    }

    /// The timed elements under `d` (through untimed ones).
    fn inlineKids(b: *Builder, d: *dom.Node, n: *Node, kids: *std.ArrayList(*Node)) error{OutOfMemory}!void {
        var c = d.firstElement();
        while (c) |x| : (c = x.nextElement()) {
            const k = page_mod.Kind.of(x) orelse continue;
            if (k != .div and k != .p and k != .span) continue;
            const timed = x.attr("begin") != null or x.attr("dur") != null or x.attr("end") != null or x.attr("timeContainer") != null;
            if (timed) try kids.append(b.a, try b.inlineNode(x, !n.seq)) else try b.inlineKids(x, n, kids);
        }
    }
};

/// A timeExpression (§7.5.2.3): `HH:MM:SS[:FF]`, or a count with h, m, s, ms or f: seconds plus frames.
pub const Duration = struct { secs: f64 = 0, frames: u64 = 0 };

pub fn parseTime(v_in: []const u8) ?Duration {
    const v = std.mem.trim(u8, v_in, " \t\r\n");
    if (std.mem.indexOfScalar(u8, v, ':') != null) {
        var parts: [4]u64 = undefined;
        var n: usize = 0;
        var it = std.mem.splitScalar(u8, v, ':');
        while (it.next()) |p| {
            if (n == 4 or p.len < 2) return null;
            parts[n] = std.fmt.parseInt(u64, p, 10) catch return null;
            n += 1;
        }
        if (n < 3) return null;
        const secs = parts[0] * 3600 + parts[1] * 60 + parts[2];
        return .{ .secs = @floatFromInt(secs), .frames = if (n == 4) parts[3] else 0 };
    }
    const metrics = [_]struct { []const u8, f64 }{ .{ "ms", 0.001 }, .{ "h", 3600 }, .{ "m", 60 }, .{ "s", 1 } };
    if (std.mem.endsWith(u8, v, "f")) {
        const f = std.fmt.parseInt(u64, v[0 .. v.len - 1], 10) catch return null;
        return .{ .frames = f };
    }
    for (metrics) |m| if (std.mem.endsWith(u8, v, m[0])) {
        const num = v[0 .. v.len - m[0].len];
        if (num.len == 0 or !std.ascii.isDigit(num[0])) return null;
        const x = std.fmt.parseFloat(f64, num) catch return null;
        return .{ .secs = x * m[1] };
    };
    return null;
}

// ---- evaluation -----------------------------------------------------------------------------------------------

const Eval = struct {
    tm: *Timing,
    page: *Page,
    c: Clocks,
    host: xpath.Host,
    a: std.mem.Allocator,
    sheet: *Sheet = undefined,
    t: i64 = 0,

    /// Updates node `n` whose parent is active over [ps, pf), placing it from syncbase `sync`. `defaults`:
    /// the nodes of the closest path begin above.
    fn update(ev: *Eval, n: *Node, ps: i64, pf: ?i64, sync: i64, in_par: bool, defaults: []const *dom.Node) void {
        const t = ev.t;
        if (n.begin == .path and in_par) {
            ev.pathBegin(n, ps, pf, defaults);
        } else {
            const b: i64 = if (n.begin == .offset) n.begin.offset else 0;
            const start = @max(sync + b, ps);
            if (!n.rt.placed or n.rt.sync != sync or n.rt.start != start) {
                resetTree(ev.tm, n);
                n.rt.placed = true;
                n.rt.sync = sync;
                n.rt.start = start;
                n.rt.sd = sdOf(n, start, sync);
                n.rt.finish = minOpt(if (n.rt.sd) |d| start + d else null, pf);
            }
            n.rt.active = t >= n.rt.start and (n.rt.finish == null or t < n.rt.finish.?);
            // An end path finishes the interval at the first tick after its start where it is true.
            if (n.rt.active and n.end == .path and t > n.rt.start and ev.endTrue(n, defaults)) {
                n.rt.finish = t;
                n.rt.active = false;
            }
        }
        const own = if (n.rt.path_nodes.items.len > 0 or n.begin == .path) n.rt.path_nodes.items else defaults;
        if (n.rt.active) {
            if (!n.rt.entered) ev.enter(n, own);
            if (n.kind == .cue) {
                ev.emit(n, own, if (n.rt.sd) |d| frac(t - n.rt.start, d) else null);
            } else ev.children(n, own);
            if (n.kind == .inline_el) ev.inlineDisplay(n, true);
            return;
        }
        // Not active: before its start, or finished.
        const finished = n.rt.entered and n.rt.finish != null and t >= n.rt.finish.?;
        if (n.kind == .cue and n.hold and finished and (pf == null or t < pf.?)) {
            // fill="hold": the last values applied, until the parent finishes.
            ev.emit(n, own, if (n.rt.sd) |d| frac(n.rt.finish.? - 1 - n.rt.start, d) else null);
        } else if (n.kind != .cue) {
            for (n.children) |c| if (c.rt.placed or c.rt.entered) resetTree(ev.tm, c);
        }
        if (n.kind == .inline_el) ev.inlineDisplay(n, false);
    }

    /// The children of an active container.
    fn children(ev: *Eval, n: *Node, defaults: []const *dom.Node) void {
        const ps = n.rt.start;
        const pf = n.rt.finish;
        if (!n.seq) {
            for (n.children) |c| ev.update(c, ps, pf, ps, true, defaults);
            return;
        }
        // seq: each child from the previous one's finish; an indefinite one holds the rest back.
        var sync: i64 = ps;
        for (n.children) |c| {
            ev.update(c, ps, pf, sync, false, defaults);
            const f = c.rt.finish orelse {
                for (n.children[std.mem.indexOfScalar(*Node, n.children, c).? + 1 ..]) |rest| resetTree(ev.tm, rest);
                return;
            };
            if (pf != null and f >= pf.?) {
                for (n.children[std.mem.indexOfScalar(*Node, n.children, c).? + 1 ..]) |rest| resetTree(ev.tm, rest);
                return;
            }
            sync = f;
        }
    }

    /// A path begin (§7.7.2.4): resolves at the first tick where it is true; resolves again once its interval
    /// has finished and the path has been false.
    fn pathBegin(ev: *Eval, n: *Node, ps: i64, pf: ?i64, defaults: []const *dom.Node) void {
        const t = ev.t;
        const v = ev.eval(n.begin.path, n.dom, false, defaults);
        const truth = toBool(v);
        if (!truth) n.rt.seen_false = true;
        if (n.rt.active) {
            var finish = n.rt.finish;
            if (n.end == .path and t > n.rt.start and ev.endTrue(n, defaults)) finish = minOpt(finish, t);
            n.rt.finish = finish;
            if (finish) |f| if (t >= f) {
                n.rt.active = false;
            };
            if (n.rt.active) return;
        }
        if (!n.rt.armed and n.rt.seen_false and !(n.rt.active)) n.rt.armed = true;
        if (!n.rt.armed or !truth or t < ps or (pf != null and t >= pf.?)) return;
        // A new interval: its descendants start afresh.
        for (n.children) |c| resetTree(ev.tm, c);
        n.rt.armed = false;
        n.rt.seen_false = false;
        n.rt.entered = false;
        n.rt.placed = true;
        n.rt.start = t;
        n.rt.sync = ps;
        n.rt.sd = sdOf(n, t, ps);
        n.rt.finish = minOpt(if (n.rt.sd) |d| t + d else null, pf);
        n.rt.active = n.rt.finish == null or t < n.rt.finish.?;
        n.rt.path_nodes.clearRetainingCapacity();
        if (v == .nodes) for (v.nodes) |it| if (it.attr == null) n.rt.path_nodes.append(ev.tm.gpa, it.node) catch {};
        if (!n.rt.active) n.rt.entered = true; // an empty interval: it happened, nothing to show
    }

    fn endTrue(ev: *Eval, n: *Node, defaults: []const *dom.Node) bool {
        const nodes = if (n.begin == .path) n.rt.path_nodes.items else defaults;
        return toBool(ev.eval(n.end.path, n.dom, true, nodes));
    }

    fn eval(ev: *Eval, x: xpath.XPath, scope: *dom.Node, in_end: bool, defaults: []const *dom.Node) xpath.Value {
        const body = ev.page.body orelse return .{ .boolean = false };
        var host = ev.host;
        host.default_nodes = defaults;
        host.in_end = in_end;
        return x.eval(ev.a, .{ .node = body, .scope = scope, .host = &host }) catch .{ .boolean = false };
    }

    /// The interval starts: a cue evaluates its select, raises its events and follows its link.
    fn enter(ev: *Eval, n: *Node, defaults: []const *dom.Node) void {
        n.rt.entered = true;
        if (n.kind != .cue) return;
        n.rt.targets.clearRetainingCapacity();
        if (n.select) |sel| {
            const v = ev.eval(sel, n.dom, false, defaults);
            if (v == .nodes) for (v.nodes) |it| if (it.attr == null) n.rt.targets.append(ev.tm.gpa, it.node) catch {};
        } else n.rt.targets.appendSlice(ev.tm.gpa, defaults) catch {};
        if (n.rt.targets.items.len == 0) return;
        for (n.ops) |o| switch (o.kind) {
            .event => for (n.rt.targets.items) |target| {
                ev.tm.events.append(ev.tm.gpa, .{ .name = o.node.attr("name") orelse "", .target = target, .event = o.node }) catch {};
            },
            .link => if (ev.tm.link == null) {
                ev.tm.link = o.node;
            },
            else => {},
        };
    }

    /// A cue's animations at fraction `f` of its simple duration (null: none, so only `set`s apply).
    fn emit(ev: *Eval, n: *Node, defaults: []const *dom.Node, f: ?f64) void {
        _ = defaults;
        for (n.ops) |o| {
            if (o.kind != .animate and o.kind != .set) continue;
            // An animate needs a finite, non-zero simple duration (§7.7.3.4).
            if (o.kind == .animate and f == null) continue;
            for (n.rt.targets.items) |target| {
                const e = Page.elemOf(target) orelse continue;
                for (o.props) |pv| {
                    const linear = o.linear and switch (pv.target) {
                        .style => |p| p.anim() == .linear,
                        .state => false,
                    };
                    ev.sheet.out.append(ev.tm.gpa, .{
                        .elem = e,
                        .target = pv.target,
                        .values = pv.values,
                        .f = if (o.kind == .set) null else f,
                        .sum = o.sum,
                        .linear = linear,
                        .rank = .{ .clock = ev.sheet.clock, .start = n.rt.start, .order = n.order },
                    }) catch {};
                }
            }
        }
    }

    /// Inline timing: an element is not displayed outside its interval.
    fn inlineDisplay(ev: *Eval, n: *Node, active: bool) void {
        if (active) return;
        const e = Page.elemOf(n.dom) orelse return;
        ev.sheet.out.append(ev.tm.gpa, .{
            .elem = e,
            .target = .{ .style = .display },
            .values = &.{"none"},
            .f = null,
            .sum = false,
            .linear = false,
            .rank = .{ .clock = .title, .start = std.math.maxInt(i64), .order = n.order },
        }) catch {};
    }
};

/// Where tick `elapsed` of an interval is on its simple duration `sd` (ticks). Intervals are half open, so
/// the last tick of the duration shows the last key value (§7.7.3.4: the last value applies at the end of
/// the simple duration; the spec's focus-fade example relies on it).
fn frac(elapsed: i64, sd: i64) ?f64 {
    if (sd <= 0) return null;
    if (sd == 1) return 1;
    return std.math.clamp(@as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(sd - 1)), 0, 1);
}

fn minOpt(a: ?i64, b: ?i64) ?i64 {
    if (a) |x| return if (b) |y| @min(x, y) else x;
    return b;
}

fn toBool(v: xpath.Value) bool {
    return switch (v) {
        .boolean => |b| b,
        .number => |x| x != 0 and !std.math.isNan(x),
        .string => |s| s.len > 0,
        .nodes => |ns| ns.len > 0,
    };
}

/// The simple duration of `n` starting at `start` from syncbase `sync` (§7.7.2.1); null: indefinite.
fn sdOf(n: *const Node, start: i64, sync: i64) ?i64 {
    var have = false;
    var d: ?i64 = null;
    if (n.dur) |x| {
        d = x;
        have = true;
    }
    switch (n.end) {
        .offset => |e| {
            const v = @max(0, sync + e - start);
            d = if (d) |x| @min(x, v) else v;
            have = true;
        },
        .path => have = true, // indefinite unless dur says otherwise; the path cuts it short
        .none => {},
    }
    if (have) return d;
    if (n.root) return null;
    if (n.kind == .cue or n.children.len == 0) return 0;
    for (n.children) |c| if (c.pathTimed()) return null;
    if (!n.seq) {
        var finish: i64 = start;
        for (n.children) |c| {
            const cs = start + (if (c.begin == .offset) c.begin.offset else 0);
            const cd = sdOf(c, cs, start) orelse return null;
            finish = @max(finish, cs + cd);
        }
        return finish - start;
    }
    var s = start;
    for (n.children) |c| {
        const cs = s + (if (c.begin == .offset) c.begin.offset else 0);
        s = cs + (sdOf(c, cs, s) orelse return null);
    }
    return s - start;
}

// ---- tests --------------------------------------------------------------------------------------------------

const testing = std.testing;

const Harness = struct {
    p: *Page,
    tm: *Timing,

    fn init(src: []const u8) !Harness {
        const p = try Page.fromBytes(testing.allocator, null, src, "file:///a/p.xmu", 1080);
        errdefer p.destroy();
        try p.buildTiming(60, 60);
        return .{ .p = p, .tm = p.timing.? };
    }

    fn deinit(h: *Harness) void {
        h.p.destroy();
    }

    /// One tick at clock value `t` on every clock: timing, the cascade, the snapshot.
    fn tick(h: *Harness, t: i64) void {
        h.tm.tick(h.p, .{ .title = t, .app = t, .page = t });
        h.p.cascade();
        h.p.snapshot();
    }

    fn el(h: *Harness, id: []const u8) *Elem {
        return Page.elemOf(h.p.doc.getElementById(id).?).?;
    }
};

const test_head =
    \\<root xmlns="http://www.dvdforum.org/2005/ihd" xmlns:style="http://www.dvdforum.org/2005/ihd#style"
    \\ xmlns:state="http://www.dvdforum.org/2005/ihd#state" xml:lang="en"><head>
;

test "the spec's focus fade: path begins and ends, sum, hold" {
    var h = try Harness.init(test_head ++
        \\<styling><style select="//button" style:opacity="0.5"/></styling>
        \\<timing clock="page">
        \\ <par begin="//button[state:focused()=true()]" end="//button[state:focused()=false() and style:opacity()=0.5]">
        \\  <cue dur="0.5s" end="//button[state:focused()=false()]" fill="hold">
        \\   <animate additive="sum" style:opacity="0; 0.5"/>
        \\  </cue>
        \\  <cue begin="//button[state:focused()=false()]" dur="0.5s" end="//button[style:opacity()=0.5]">
        \\   <animate additive="sum" style:opacity="0; -0.5"/>
        \\  </cue>
        \\ </par>
        \\</timing></head><body><button id="b"/></body></root>
    );
    defer h.deinit();
    const b = h.el("b");
    var t: i64 = 0;
    while (t < 10) : (t += 1) h.tick(t);
    try testing.expectEqual(@as(f32, 0.5), b.style.opacity);
    // Focus comes at tick 10 (an input event); timing sees it at 11.
    h.p.setState(b, .focused, true);
    h.tick(10);
    try testing.expectEqual(@as(f32, 0.5), b.style.opacity);
    h.tick(11); // the par and the first cue start: +0
    try testing.expectEqual(@as(f32, 0.5), b.style.opacity);
    while (t < 40) : (t += 1) h.tick(t);
    h.tick(40); // the last tick of 0.5 s: +0.5
    try testing.expectApproxEqAbs(@as(f32, 1.0), b.style.opacity, 1e-4);
    var k: i64 = 41;
    while (k < 50) : (k += 1) h.tick(k);
    try testing.expectApproxEqAbs(@as(f32, 1.0), b.style.opacity, 1e-4); // held
    // Focus leaves: the second cue fades back down to 0.5, then the par ends.
    h.p.setState(b, .focused, false);
    while (k < 66) : (k += 1) h.tick(k);
    try testing.expect(b.style.opacity < 0.9 and b.style.opacity > 0.6);
    while (k < 81) : (k += 1) h.tick(k);
    try testing.expectApproxEqAbs(@as(f32, 0.5), b.style.opacity, 1e-4);
    while (k < 90) : (k += 1) h.tick(k);
    try testing.expectApproxEqAbs(@as(f32, 0.5), b.style.opacity, 1e-4);
    try testing.expect(!h.tm.sheets.items[0].root.children[0].rt.active);
    // Focus again: a new interval.
    h.p.setState(b, .focused, true);
    h.tick(90);
    h.tick(91);
    try testing.expect(h.tm.sheets.items[0].root.children[0].rt.active);
}

test "title clock: par, seq, set and animate, priorities, seeks" {
    var h = try Harness.init(test_head ++
        \\<timing clock="title">
        \\ <seq>
        \\  <cue select="//div[@id='a']" dur="1s"><set style:display="none"/></cue>
        \\  <cue select="//div[@id='a']" begin="10f" dur="1s" fill="hold"><animate style:x="0px;100px"/></cue>
        \\ </seq>
        \\ <par begin="00:00:01:00">
        \\  <cue select="id('a')" dur="61f"><set style:y="7px"/></cue>
        \\  <cue select="id('a')" begin="30f" end="60f"><set style:y="9px;1px"/></cue>
        \\ </par>
        \\</timing></head><body><div id="a" style:x="5px"/></body></root>
    );
    defer h.deinit();
    const a = h.el("a");
    h.tick(0);
    try testing.expect(!a.style.display);
    h.tick(59);
    try testing.expect(!a.style.display);
    h.tick(60); // the first cue ended; the second starts 10 frames later
    try testing.expect(a.style.display);
    try testing.expectEqual(@as(f32, 5), a.style.x.?.v);
    try testing.expectEqual(@as(f32, 7), a.style.y.?.v);
    h.tick(70);
    try testing.expectEqual(@as(f32, 0), a.style.x.?.v);
    h.tick(100); // 30 of 59 steps
    try testing.expectApproxEqAbs(@as(f32, 50.85), a.style.x.?.v, 0.01);
    // The later start wins over the earlier one: y 9px from frame 90 to 119.
    try testing.expectEqual(@as(f32, 9), a.style.y.?.v);
    h.tick(120);
    try testing.expectEqual(@as(f32, 7), a.style.y.?.v);
    h.tick(129);
    try testing.expectEqual(@as(f32, 100), a.style.x.?.v);
    // No hold on the title clock.
    h.tick(130);
    try testing.expectEqual(@as(f32, 5), a.style.x.?.v);
    // A seek back replays.
    h.tick(30);
    try testing.expect(!a.style.display);
}

test "inline timing, clockDivisor, events and links" {
    {
        var h = try Harness.init(test_head ++
            \\</head><body>
            \\<p id="p1" dur="1s">one</p><div><p id="p2" dur="2s">two</p></div><p id="p3">three</p>
            \\</body></root>
        );
        defer h.deinit();
        h.tick(0);
        try testing.expect(h.el("p1").style.display and !h.el("p2").style.display);
        h.tick(60);
        try testing.expect(!h.el("p1").style.display and h.el("p2").style.display);
        h.tick(180);
        try testing.expect(!h.el("p2").style.display and h.el("p3").style.display); // untimed: always shown
    }
    {
        var h = try Harness.init(test_head ++
            \\<timing clock="application" clockDivisor="4"><par>
            \\ <cue select="id('d')" dur="20f"><animate style:x="0px;19px"/></cue>
            \\ <cue select="id('d')" begin="2s" dur="1s"><event name="hello"><param name="a" value="1"/></event></cue>
            \\ <cue select="id('d')" begin="2s"><event name="never"/></cue>
            \\ <cue select="id('d')" begin="3s" dur="1s"><link href="next.xmu"/></cue>
            \\</par></timing></head><body><div id="d"/></body></root>
        );
        defer h.deinit();
        h.tick(5); // evaluated at 4
        try testing.expectEqual(@as(f32, 4), h.el("d").style.x.?.v);
        h.tick(7); // repeats
        try testing.expectEqual(@as(f32, 4), h.el("d").style.x.?.v);
        h.tick(8);
        try testing.expectEqual(@as(f32, 8), h.el("d").style.x.?.v);
        // An event fires once when its cue starts; a cue without dur or end does nothing.
        h.tick(120);
        h.tick(124);
        try testing.expectEqual(@as(usize, 1), h.tm.events.items.len);
        try testing.expectEqualStrings("hello", h.tm.events.items[0].name);
        try testing.expectEqual(@as(?*dom.Node, null), h.tm.link);
        h.tick(180);
        try testing.expectEqualStrings("next.xmu", h.tm.link.?.attr("href").?);
    }
}
