//! The Advanced Applications' graphics as an engine scene (HD DVD Vol. 3 §7.2.4, §7.3.1.2): for each
//! application active at the title time (the Playlist Application outside the First Play title, and the
//! title's autorun ApplicationSegments), its manifest and first markup page are loaded from the File Cache;
//! each tick the pages' styles and layout are brought up to date, and the graphics plane is redrawn when
//! anything visible changed, applications in z-order (the Playlist Application below the title's), each
//! clipped to its manifest region.
//!
//! User input (§7.2.6–7.2.8, §8.3.6) goes to the focused application first, then to the others from the top:
//! accessKeys in any of them, navigation, Enter and Esc in the focused one. One element in all applications
//! has the focus. The pointer state follows the cursor, the element on top under its hot spot.
//!
//! Each page's timesheets run on the application's clocks (its application clock starts with its first page,
//! its page clock with each page); their state values, `<link>`s and `<event>`s are applied here.
//!
//! Scripts and the application lifecycle come with the script host.
//! No VLC dependency.

const std = @import("std");
const engine = @import("../engine/engine.zig");
const planes = @import("../planes.zig");
const raster = @import("../raster.zig");
const image = @import("../image.zig");
const font_mod = @import("../font.zig");
const xpl = @import("../xpl.zig");
const resman = @import("../resman.zig");
const manifest_mod = @import("../manifest.zig");
const page_mod = @import("page.zig");
const layout = @import("layout.zig");
const paint_mod = @import("paint.zig");
const focus = @import("focus.zig");
const style = @import("style.zig");
const keys = @import("../engine/keys.zig");
const timing = @import("timing.zig");

const Page = page_mod.Page;

pub const Config = struct {
    pl: *const xpl.Playlist,
    loader: page_mod.Loader,
    /// The Menu Language, to choose the Playlist Application.
    menu_language: []const u8,
    /// Logs a message (optional).
    log: ?*const fn (ctx: *anyopaque, msg: []const u8) void = null,
    log_ctx: *anyopaque = undefined,
    /// Element ids to show whatever their style says (debugging, before scripts run).
    show: []const u8 = "",
};

/// Decoded images and fonts of one application, by absolute URI (null: could not be loaded).
const Resources = struct {
    gpa: std.mem.Allocator,
    loader: page_mod.Loader,
    images: std.StringHashMapUnmanaged(?*image.Image) = .empty,
    fonts: std.StringHashMapUnmanaged(?*font_mod.Font) = .empty,

    fn deinit(r: *Resources) void {
        var it = r.images.iterator();
        while (it.next()) |kv| {
            r.gpa.free(kv.key_ptr.*);
            if (kv.value_ptr.*) |im| {
                im.deinit(r.gpa);
                r.gpa.destroy(im);
            }
        }
        r.images.deinit(r.gpa);
        var f = r.fonts.iterator();
        while (f.next()) |kv| {
            r.gpa.free(kv.key_ptr.*);
            if (kv.value_ptr.*) |x| x.destroy();
        }
        r.fonts.deinit(r.gpa);
    }

    fn getImage(ctx: *anyopaque, u: []const u8) ?*image.Image {
        const r: *Resources = @ptrCast(@alignCast(ctx));
        if (r.images.get(u)) |hit| return hit;
        const c: ?*image.Image = blk: {
            const bytes = r.loader.read(r.loader.ctx, u) catch break :blk null;
            defer r.gpa.free(bytes);
            var decoded = image.Image.load(r.gpa, bytes) catch break :blk null;
            const box = r.gpa.create(image.Image) catch {
                decoded.deinit(r.gpa);
                break :blk null;
            };
            box.* = decoded;
            break :blk box;
        };
        const key = r.gpa.dupe(u8, u) catch return c;
        r.images.put(r.gpa, key, c) catch r.gpa.free(key);
        return c;
    }

    fn getFont(ctx: *anyopaque, page: *Page, e: *page_mod.Elem) ?*font_mod.Font {
        const r: *Resources = @ptrCast(@alignCast(ctx));
        const name = e.style.font.uri;
        if (name.len == 0) return null;
        const u = page.resolve(e.node, name) catch return null;
        defer r.gpa.free(u);
        if (r.fonts.get(u)) |hit| return hit;
        const f: ?*font_mod.Font = blk: {
            const bytes = r.loader.read(r.loader.ctx, u) catch break :blk null;
            defer r.gpa.free(bytes);
            break :blk font_mod.Font.create(r.gpa, bytes) catch null;
        };
        const key = r.gpa.dupe(u8, u) catch return f;
        r.fonts.put(r.gpa, key, f) catch r.gpa.free(key);
        return f;
    }

    fn res(r: *Resources) layout.Res {
        return .{ .ctx = r, .font = getFont, .image = getImage };
    }
};

const Want = struct { src: []const u8, id: []const u8, z: u32, valid: [2]?i64 };

const App = struct {
    /// The manifest URI (what identifies it across ticks).
    src: []const u8,
    /// The playlist's id for it (what nav* properties name).
    id: []const u8,
    z: u32,
    manifest: ?manifest_mod.Manifest = null,
    page: ?*Page = null,
    lay: layout.Layout,
    res: Resources,
    region: raster.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    /// A hash of what was last drawn.
    look: u64 = 0,
    wanted: bool = true,
    /// The elements in paint order, and each one's position in it, as of the last layout.
    order: []u32 = &.{},
    rank: []u32 = &.{},
    /// navIndex values have been generated for the page.
    numbered: bool = false,
    /// The application's valid interval on the Title Timeline (frames).
    valid: [2]?i64 = .{ 0, null },
    /// Engine ticks when its first page and its current page started.
    app_start: ?u64 = null,
    page_start: u64 = 0,
    /// A link failed: the application ended (§7.7.5.2).
    terminated: bool = false,

    fn reorder(a: *App, gpa: std.mem.Allocator) void {
        const p = a.page orelse return;
        const o = paint_mod.order(gpa, p) catch return;
        const r = focus.ranks(gpa, o) catch {
            gpa.free(o);
            return;
        };
        gpa.free(a.order);
        gpa.free(a.rank);
        a.order = o;
        a.rank = r;
    }

    /// MNG objects: each plays from its first frame whenever it becomes displayed (§7.8.3.1), unsynchronised,
    /// on the graphics ticks (Vol. 1 §4.3.19.10.5).
    fn animate(a: *App, now: u64, rate: u32) void {
        const p = a.page orelse return;
        for (p.elems.items) |e| {
            if (e.kind != .object or !std.mem.eql(u8, e.node.attr("type") orelse "", "image/mng")) continue;
            if (!displayed(e)) {
                e.mng_start = null;
                e.mng_frame = null;
                continue;
            }
            const start = e.mng_start orelse now;
            e.mng_start = start;
            e.mng_frame = blk: {
                const u = p.resolve(e.node, e.node.attr("src") orelse break :blk null) catch break :blk null;
                defer p.gpa.free(u);
                const im = Resources.getImage(&a.res, u) orelse break :blk null;
                const m = im.animation() orelse break :blk 0;
                break :blk m.frameAt(now -| start, rate);
            };
        }
    }

    fn displayed(e: *const page_mod.Elem) bool {
        var x: ?*const page_mod.Elem = e;
        while (x) |y| : (x = y.parent) if (!y.box.shown) return false;
        return true;
    }

    fn destroy(a: *App, gpa: std.mem.Allocator) void {
        gpa.free(a.order);
        gpa.free(a.rank);
        gpa.free(a.id);
        if (a.page) |p| p.destroy();
        if (a.manifest) |*m| m.deinit();
        a.lay.deinit();
        a.res.deinit();
        gpa.free(a.src);
        gpa.destroy(a);
    }
};

pub const Apps = struct {
    gpa: std.mem.Allocator,
    cfg: Config,
    w: u32,
    h: u32,
    apps: std.ArrayList(*App) = .empty,

    pub fn create(gpa: std.mem.Allocator, cfg: Config, w: u32, h: u32) !engine.Scene {
        const s = try gpa.create(Apps);
        s.* = .{ .gpa = gpa, .cfg = cfg, .w = w, .h = h };
        return .{ .ctx = s, .vtable = &vtable };
    }

    const vtable: engine.Scene.VTable = .{ .tick = tick, .input = input, .render = render, .deinit = deinit };

    fn deinit(ctx: *anyopaque, gpa: std.mem.Allocator) void {
        const s: *Apps = @ptrCast(@alignCast(ctx));
        for (s.apps.items) |a| a.destroy(gpa);
        s.apps.deinit(gpa);
        gpa.destroy(s);
    }

    fn log(s: *Apps, comptime fmt: []const u8, args: anytype) void {
        const f = s.cfg.log orelse return;
        var buf: [512]u8 = undefined;
        f(s.cfg.log_ctx, std.fmt.bufPrint(&buf, fmt, args) catch return);
    }

    /// Which applications are active now: (manifest URI, z-order).
    fn wanted(s: *Apps, e: *const engine.Engine, t: u64, out: *std.ArrayList(Want)) void {
        if (!e.in_title) return;
        const pl = s.cfg.pl;
        const title: *const xpl.Title = if (e.title) |i| (if (i < pl.titles.len) &pl.titles[i] else return) else if (pl.first_play) |*fp| fp else return;
        // The Playlist Application runs in every title but the First Play one, at the bottom.
        if (e.title != null) if (resman.Manager.playlistApp(pl, s.cfg.menu_language)) |pa| out.append(s.gpa, .{ .src = pa.src, .id = pa.id, .z = 0, .valid = .{ 0, null } }) catch {};
        var states: [64]resman.App = undefined;
        const n = @min(title.apps.len, states.len);
        resman.defaultApps(title, t, states[0..n]);
        for (title.apps[0..n], states[0..n]) |a, st| {
            if (st.state != .active or a.subtitle) continue;
            out.append(s.gpa, .{ .src = a.src, .id = a.id, .z = a.z_order + 1, .valid = .{ @intCast(a.title_begin), if (a.title_end) |x| @intCast(x) else null } }) catch {};
        }
    }

    fn tick(ctx: *anyopaque, e: *engine.Engine, c: engine.Clocks) bool {
        const s: *Apps = @ptrCast(@alignCast(ctx));
        var want: std.ArrayList(Want) = .empty;
        defer want.deinit(s.gpa);
        s.wanted(e, c.title, &want);

        var changed = false;
        for (s.apps.items) |a| a.wanted = false;
        for (want.items) |w| {
            const a = for (s.apps.items) |a| {
                if (std.mem.eql(u8, a.src, w.src)) break a;
            } else s.start(w.src, w.id, w.z, c.app) orelse continue;
            a.wanted = true;
            a.z = w.z;
            a.valid = w.valid;
        }
        var i: usize = 0;
        while (i < s.apps.items.len) {
            const a = s.apps.items[i];
            if (a.wanted) {
                i += 1;
                continue;
            }
            s.log("application {s} ends", .{a.src});
            a.destroy(s.gpa);
            _ = s.apps.orderedRemove(i);
            changed = true;
        }
        std.mem.sort(*App, s.apps.items, {}, struct {
            fn less(_: void, x: *App, y: *App) bool {
                return x.z < y.z;
            }
        }.less);

        s.endActivations(c.app);
        for (s.apps.items) |a| s.runTiming(a, c);
        for (s.apps.items, 0..) |a, k| {
            const p = a.page orelse continue;
            // The front-most application is in the foreground (§7.6.3.4.2.1).
            if (p.elems.items.len > 0 and p.elems.items[0].kind == .body) p.setState(p.elems.items[0], .foreground, k == s.apps.items.len - 1);
            p.cascade();
            a.lay.run(p, a.res.res(), @floatFromInt(a.region.w), @floatFromInt(a.region.h));
            a.reorder(s.gpa);
            a.animate(c.app, s.cfg.pl.tick_base);
            if (!a.numbered) {
                focus.generate(s.gpa, p, a.rank) catch {};
                a.numbered = true;
            }
            const look = hashLook(p, &a.lay);
            if (look != a.look) changed = true;
            a.look = look;
        }
        s.updatePointer(e);
        // What the next tick's expressions see.
        for (s.apps.items) |a| if (a.page) |p| p.snapshot();
        return changed;
    }

    /// Runs a page's timesheets, then what they set: states, a link to another page, events.
    fn runTiming(s: *Apps, a: *App, c: engine.Clocks) void {
        const p = a.page orelse return;
        const tm = p.timing orelse return;
        if (tm.empty()) return;
        tm.tick(p, .{
            .title = @intCast(c.title),
            .app = @intCast(c.app -| (a.app_start orelse c.app)),
            .page = @intCast(c.app -| a.page_start),
            .valid = a.valid,
        });
        for (tm.states.items) |st| switch (st.which) {
            .focused => if (std.mem.eql(u8, st.value, "true")) {
                if (focus.focusable(st.elem) or st.elem.kind.activatable()) s.setFocus(p, st.elem);
            } else p.setState(st.elem, .focused, false),
            .enabled => p.setState(st.elem, .enabled, !std.mem.eql(u8, st.value, "false")),
            .value => p.setValue(st.elem, st.value) catch {},
        };
        // Events go to the script host (Phase 5).
        for (tm.events.items) |ev| s.log("event {s} on {s}", .{ ev.name, ev.target.attr("id") orelse ev.target.local });
        tm.events.clearRetainingCapacity();
        if (tm.link) |l| {
            tm.link = null;
            s.follow(a, p, l, c.app);
        }
    }

    /// A `<link>`: its page replaces the current one; a link to anything else ends the application.
    fn follow(s: *Apps, a: *App, p: *Page, l: *@import("../dom.zig").Node, now: u64) void {
        const href = l.attr("href") orelse "";
        const u = p.resolve(l, href) catch return;
        defer s.gpa.free(u);
        const next = Page.load(s.gpa, s.cfg.loader, u, s.h) catch |err| {
            s.log("application {s}: link to {s} failed ({s}); it ends", .{ a.src, u, @errorName(err) });
            p.destroy();
            a.page = null;
            a.terminated = true;
            return;
        };
        s.log("application {s}: link to {s}", .{ a.src, u });
        p.destroy();
        a.page = next;
        s.pageStarted(a, now);
    }

    /// A page starts: its timesheets, its clock, navIndex numbering after its first layout.
    fn pageStarted(s: *Apps, a: *App, now: u64) void {
        const p = a.page orelse return;
        p.buildTiming(@floatFromInt(s.cfg.pl.time_base.fps()), @floatFromInt(s.cfg.pl.tick_base)) catch |err| s.log("application {s}: timing ({s})", .{ a.src, @errorName(err) });
        if (a.app_start == null) a.app_start = now;
        a.page_start = now;
        a.numbered = false;
        a.look = 0;
        if (p.focused()) |el| s.setFocus(p, el);
    }

    // ---- input --------------------------------------------------------------------------------------------

    fn input(ctx: *anyopaque, e: *engine.Engine, ev: engine.Event) void {
        const s: *Apps = @ptrCast(@alignCast(ctx));
        const tick_no = e.last_tick orelse 0;
        switch (ev) {
            .key_down => |k| {
                // The focused application first, then the others from the top (§8.3.6).
                const first = s.focusedApp();
                if (first) |a| if (s.keyIn(a, k, true, tick_no)) return;
                var i = s.apps.items.len;
                while (i > 0) {
                    i -= 1;
                    const a = s.apps.items[i];
                    if (a == first) continue;
                    if (s.keyIn(a, k, false, tick_no)) return;
                }
                // Not consumed: Annex V's default handler (none for these keys in markup).
            },
            .key_up => {},
            .mouse_move => s.updatePointer(e),
            .mouse_down => {
                s.updatePointer(e);
                // A pointer activation lasts until the button comes up (§7.6.3.4.2.4).
                for (s.apps.items) |a| {
                    const p = a.page orelse continue;
                    for (p.elems.items) |el| if (el.state.pointer and el.kind.activatable() and el.state.enabled) {
                        p.setState(el, .actioned, true);
                        el.pressed = true;
                        toggleValue(p, el);
                    };
                }
            },
            .mouse_up => {
                // Focus follows once the activation has ended (§7.6.3.4.2.3).
                for (s.apps.items) |a| {
                    const p = a.page orelse continue;
                    for (p.elems.items) |el| if (el.pressed) {
                        el.pressed = false;
                        if (el.key_actioned == null) p.setState(el, .actioned, false);
                        if (focus.focusable(el)) s.setFocus(p, el);
                    };
                }
            },
            else => {},
        }
    }

    /// Offers key `k` to application `a`; true if it consumed it.
    fn keyIn(s: *Apps, a: *App, k: keys.Key, focused_app: bool, tick_no: u64) bool {
        const p = a.page orelse return false;
        // Script handlers come first (Phase 5). Then accessKeys, in any application.
        if (focus.accessKey(p, k)) |el| {
            s.activateByKey(p, el, tick_no);
            return true;
        }
        if (!focused_app) return false;
        const dir: ?style.Dir = switch (k) {
            keys.left => .left,
            keys.right => .right,
            keys.up => .up,
            keys.down => .down,
            keys.left_up => .left_up,
            keys.left_down => .left_down,
            keys.right_up => .right_up,
            keys.right_down => .right_down,
            else => null,
        };
        const cur = p.focused();
        if (dir) |d| {
            if (focus.stale(p)) focus.generate(s.gpa, p, a.rank) catch {};
            const to = focus.navigate(p, cur, d, a.id, a.rank);
            s.log("key {s} in {s}: from {s}, to {s}", .{
                @tagName(d),
                a.id,
                if (cur) |x| x.node.attr("id") orelse @tagName(x.kind) else "nothing",
                switch (to) {
                    .none => "nowhere",
                    .elem => |x| x.node.attr("id") orelse @tagName(x.kind),
                    .other => |o| o.elem,
                },
            });
            switch (to) {
                .none => return cur != null,
                .elem => |el| s.setFocus(p, el),
                .other => |nav| {
                    const b = for (s.apps.items) |b| {
                        if (std.mem.eql(u8, b.id, nav.app)) break b;
                    } else return cur != null;
                    const bp = b.page orelse return true;
                    const n = bp.doc.getElementById(nav.elem) orelse return true;
                    const el = Page.elemOf(n) orelse return true;
                    if (focus.focusable(el)) s.setFocus(bp, el);
                },
            }
            return true;
        }
        if (k == keys.enter) {
            const el = cur orelse return false;
            s.activateByKey(p, el, tick_no);
            return true;
        }
        if (k == keys.esc) {
            // Cancel: no element has the focus any more.
            if (cur == null) return false;
            s.clearFocus();
            return true;
        }
        return false;
    }

    /// A key activation (Enter, or an accessKey's Select gesture): actioned for one tick, then focused.
    fn activateByKey(s: *Apps, p: *Page, el: *page_mod.Elem, tick_no: u64) void {
        _ = s;
        if (!el.state.actioned) toggleValue(p, el);
        p.setState(el, .actioned, true);
        el.key_actioned = tick_no;
        if (!el.state.focused) el.focus_after = true;
    }

    /// Ends the key activations made before tick `now`, moving the focus where one is due.
    fn endActivations(s: *Apps, now: u64) void {
        for (s.apps.items) |a| {
            const p = a.page orelse continue;
            for (p.elems.items) |el| {
                const t = el.key_actioned orelse continue;
                if (t >= now) continue;
                el.key_actioned = null;
                if (!el.pressed) p.setState(el, .actioned, false);
                if (el.focus_after) {
                    el.focus_after = false;
                    if (focus.focusable(el)) s.setFocus(p, el);
                }
            }
        }
    }

    /// The application with the focused element, or else the one on top (§7.2.5.1).
    fn focusedApp(s: *Apps) ?*App {
        for (s.apps.items) |a| if (a.page) |p| if (p.focused() != null) return a;
        var i = s.apps.items.len;
        while (i > 0) {
            i -= 1;
            if (s.apps.items[i].page != null) return s.apps.items[i];
        }
        return null;
    }

    /// Gives `el` the focus: one element in all applications has it.
    fn setFocus(s: *Apps, p: *Page, el: *page_mod.Elem) void {
        for (s.apps.items) |a| if (a.page) |q| for (q.elems.items) |x| if (x != el and x.state.focused) q.setState(x, .focused, false);
        if (!el.state.focused) s.log("focus: {s} {s}", .{ @tagName(el.kind), el.node.attr("id") orelse "(no id)" });
        p.setState(el, .focused, true);
    }

    fn clearFocus(s: *Apps) void {
        s.log("focus cleared", .{});
        for (s.apps.items) |a| if (a.page) |q| for (q.elems.items) |x| if (x.state.focused) q.setState(x, .focused, false);
    }

    /// state:pointer on the element under the cursor's hot spot, the application on top first; none while the
    /// cursor is disabled.
    fn updatePointer(s: *Apps, e: *const engine.Engine) void {
        var under: ?*page_mod.Elem = null;
        if (e.cursor.enabled) {
            var i = s.apps.items.len;
            while (i > 0 and under == null) {
                i -= 1;
                const a = s.apps.items[i];
                const p = a.page orelse continue;
                if (a.order.len != p.elems.items.len) continue;
                if (!a.region.contains(e.cursor.x, e.cursor.y)) continue;
                const x: f32 = @floatFromInt(e.cursor.x - a.region.x);
                const y: f32 = @floatFromInt(e.cursor.y - a.region.y);
                under = focus.hit(p, a.order, x, y);
            }
        }
        for (s.apps.items) |a| if (a.page) |p| for (p.elems.items) |x| p.setState(x, .pointer, x == under);
    }

    /// Loads an application's manifest and first page.
    fn start(s: *Apps, src: []const u8, id: []const u8, z: u32, now: u64) ?*App {
        const a = s.gpa.create(App) catch return null;
        const src_copy = s.gpa.dupe(u8, src) catch {
            s.gpa.destroy(a);
            return null;
        };
        a.* = .{
            .src = src_copy,
            .id = s.gpa.dupe(u8, id) catch {
                s.gpa.free(src_copy);
                s.gpa.destroy(a);
                return null;
            },
            .z = z,
            .lay = .init(s.gpa),
            .res = .{ .gpa = s.gpa, .loader = s.cfg.loader },
        };
        s.apps.append(s.gpa, a) catch {
            a.destroy(s.gpa);
            return null;
        };
        const bytes = s.cfg.loader.read(s.cfg.loader.ctx, src) catch |err| {
            s.log("application {s}: cannot read its manifest ({s})", .{ src, @errorName(err) });
            return a;
        };
        defer s.gpa.free(bytes);
        a.manifest = manifest_mod.parse(s.gpa, bytes, src) catch |err| {
            s.log("application {s}: bad manifest ({s})", .{ src, @errorName(err) });
            return a;
        };
        const m = &a.manifest.?;
        a.region = .{ .x = @intCast(m.region.x), .y = @intCast(m.region.y), .w = @intCast(m.region.width), .h = @intCast(m.region.height) };
        const markup = m.markup orelse {
            s.log("application {s}: no markup", .{src});
            return a;
        };
        a.page = Page.load(s.gpa, s.cfg.loader, markup, s.h) catch |err| {
            s.log("application {s}: cannot load {s} ({s})", .{ src, markup, @errorName(err) });
            return a;
        };
        s.log("application {s}: {s}, {d} elements, region {d},{d} {d}x{d}", .{ src, markup, a.page.?.elems.items.len, a.region.x, a.region.y, a.region.w, a.region.h });
        // A page that sets a focus takes it from the other applications (§7.6.3.4.2.3).
        s.pageStarted(a, now);
        var it = std.mem.tokenizeAny(u8, s.cfg.show, ", ");
        while (it.next()) |shown| {
            const n = a.page.?.doc.getElementById(shown) orelse continue;
            const e = Page.elemOf(n) orelse continue;
            // From the element up, so it shows even inside hidden containers.
            var x: ?*page_mod.Elem = e;
            while (x) |el| : (x = el.parent) a.page.?.script.put(s.gpa, .{ .elem = el, .prop = .display }, "auto") catch {};
        }
        return a;
    }

    fn render(ctx: *anyopaque, _: *engine.Engine, f: *planes.Frame) void {
        const s: *Apps = @ptrCast(@alignCast(ctx));
        for (s.apps.items) |a| {
            const p = a.page orelse continue;
            paint_mod.paint(s.gpa, p, &a.lay, a.res.res(), f, a.region);
        }
    }
};

/// Toggles a button's or area's value, at the start of its activation (§7.6.3.4.2.6).
fn toggleValue(p: *Page, el: *page_mod.Elem) void {
    if (el.kind != .button and el.kind != .area) return;
    p.setValue(el, if (std.mem.eql(u8, el.state.value, "true")) "false" else "true") catch {};
}

/// A hash of what a page would draw: its elements' boxes, styles and states, and its glyph runs.
fn hashLook(p: *Page, lay: *const layout.Layout) u64 {
    var h = std.hash.Wyhash.init(0);
    for (p.elems.items) |e| {
        hashValue(&h, e.box);
        hashValue(&h, e.style);
        hashValue(&h, e.mng_frame);
        h.update(e.state.value);
    }
    for (lay.runs.items) |r| {
        hashValue(&h, r.baseline);
        hashValue(&h, r.x);
        hashValue(&h, r.top);
        hashValue(&h, r.glyphs);
    }
    return h.final();
}

/// Hashes a value by its fields (not its bytes, whose padding is undefined), slices by their contents.
fn hashValue(h: *std.hash.Wyhash, v: anytype) void {
    const T = @TypeOf(v);
    switch (@typeInfo(T)) {
        .bool, .int, .@"enum" => h.update(std.mem.asBytes(&v)),
        .float => h.update(std.mem.asBytes(&v)),
        .optional => if (v) |x| {
            h.update("1");
            hashValue(h, x);
        } else h.update("0"),
        .array => for (v) |x| hashValue(h, x),
        .pointer => |ptr| switch (ptr.size) {
            .slice => {
                hashValue(h, v.len);
                for (v) |x| hashValue(h, x);
            },
            else => h.update(std.mem.asBytes(&v)),
        },
        .@"struct" => inline for (comptime std.meta.fieldNames(T)) |name| hashValue(h, @field(v, name)),
        .@"union" => {
            hashValue(h, std.meta.activeTag(v));
            switch (v) {
                inline else => |x| hashValue(h, x),
            }
        },
        .void => {},
        else => @compileError("cannot hash " ++ @typeName(T)),
    }
}

// ---- tests --------------------------------------------------------------------------------------------------

const testing = std.testing;

const Files = struct {
    files: []const struct { []const u8, []const u8 },

    fn read(ctx: *anyopaque, u: []const u8) anyerror![]u8 {
        const self: *Files = @ptrCast(@alignCast(ctx));
        for (self.files) |f| if (std.mem.eql(u8, f[0], u)) return testing.allocator.dupe(u8, f[1]);
        return error.FileNotFound;
    }
};

test "the Playlist Application's page is drawn in its region" {
    const gpa = testing.allocator;
    var pl = try xpl.parse(gpa,
        \\<Playlist xmlns="http://www.dvdforum.org/2005/HDDVDVideo/Playlist" majorVersion="1" minorVersion="0">
        \\ <Configuration><StreamingBuffer size="0"/><Aperture size="1920x1080"/><MainVideoDefaultColor color="108080"/></Configuration>
        \\ <MediaAttributeList/>
        \\ <TitleSet timeBase="60fps">
        \\  <Title id="t1" titleNumber="1" titleDuration="00:01:00:00"/>
        \\  <PlaylistApplication id="pa" src="file:///dvddisc/ADV_OBJ/m.xmf"/>
        \\ </TitleSet>
        \\</Playlist>
    );
    defer pl.deinit();
    var files: Files = .{ .files = &.{
        .{
            "file:///dvddisc/ADV_OBJ/m.xmf",
            \\<Application xmlns="http://www.dvdforum.org/2005/HDDVDVideo/Manifest" id="m">
            \\ <Region x="100" y="200" width="300" height="100"/>
            \\ <Markup src="m.xmu"/>
            \\</Application>
        },
        .{
            "file:///dvddisc/ADV_OBJ/m.xmu",
            \\<root xmlns="http://www.dvdforum.org/2005/ihd" xmlns:style="http://www.dvdforum.org/2005/ihd#style" xml:lang="en"><body>
            \\<div style:position="absolute" style:x="-50px" style:y="0px" style:width="1000px" style:height="10px" style:backgroundColor="red"/>
            \\</body></root>
        },
    } };
    var e = engine.Engine.init(gpa, 1920, 1080, 60);
    defer e.deinit();
    e.setScene(try Apps.create(gpa, .{ .pl = &pl, .loader = .{ .ctx = &files, .read = Files.read }, .menu_language = "en" }, 1920, 1080), 0);
    // Nothing before a title, nothing in the First Play title.
    try e.post(.{ .title_begin = .{ .title = 0, .duration = 3600 } });
    const r = e.step(0, 0);
    try testing.expect(r.redraw);
    const f = try planes.Frame.create(gpa, 1920, 1080);
    defer f.unref();
    e.render(f);
    try testing.expectEqual(raster.Px{ 255, 0, 0, 255 }, f.canvas.at(100, 200)); // clipped at the region's left
    try testing.expectEqual(raster.Px{ 255, 0, 0, 255 }, f.canvas.at(399, 209));
    try testing.expectEqual(@as(u8, 0), f.canvas.at(400, 205)[3]);
    try testing.expectEqual(@as(u8, 0), f.canvas.at(99, 205)[3]);
    // Nothing changed: no redraw.
    try testing.expect(!e.step(20_000, 1).redraw);
}

test "focus, activation and the pointer from user input" {
    const gpa = testing.allocator;
    var pl = try xpl.parse(gpa,
        \\<Playlist xmlns="http://www.dvdforum.org/2005/HDDVDVideo/Playlist" majorVersion="1" minorVersion="0">
        \\ <Configuration><StreamingBuffer size="0"/><Aperture size="1920x1080"/><MainVideoDefaultColor color="108080"/></Configuration>
        \\ <MediaAttributeList/>
        \\ <TitleSet timeBase="60fps">
        \\  <Title id="t1" titleNumber="1" titleDuration="00:01:00:00"/>
        \\  <PlaylistApplication id="pa" src="file:///dvddisc/ADV_OBJ/m.xmf"/>
        \\ </TitleSet>
        \\</Playlist>
    );
    defer pl.deinit();
    var files: Files = .{ .files = &.{
        .{
            "file:///dvddisc/ADV_OBJ/m.xmf",
            \\<Application xmlns="http://www.dvdforum.org/2005/HDDVDVideo/Manifest" id="m">
            \\ <Region x="100" y="100" width="400" height="400"/>
            \\ <Markup src="m.xmu"/>
            \\</Application>
        },
        .{
            "file:///dvddisc/ADV_OBJ/m.xmu",
            \\<root xmlns="http://www.dvdforum.org/2005/ihd" xmlns:style="http://www.dvdforum.org/2005/ihd#style" xml:lang="en"><body>
            \\<button id="a" style:position="absolute" style:x="0px" style:y="0px" style:width="50px" style:height="50px"/>
            \\<button id="b" accessKey="U+0037" style:position="absolute" style:x="100px" style:y="0px" style:width="50px" style:height="50px"/>
            \\</body></root>
        },
    } };
    var e = engine.Engine.init(gpa, 1920, 1080, 50);
    defer e.deinit();
    e.setScene(try Apps.create(gpa, .{ .pl = &pl, .loader = .{ .ctx = &files, .read = Files.read }, .menu_language = "en" }, 1920, 1080), 0);
    try e.post(.{ .title_begin = .{ .title = 0, .duration = 3000 } });
    var now: i64 = 0;
    _ = e.step(now, 0);
    const s: *Apps = @ptrCast(@alignCast(e.scene.?.ctx));
    const p = s.apps.items[0].page.?;
    const a = Page.elemOf(p.doc.getElementById("a").?).?;
    const b = Page.elemOf(p.doc.getElementById("b").?).?;
    try testing.expect(p.elems.items[0].state.foreground);
    const next = struct {
        fn f(eng: *engine.Engine, t: *i64) void {
            t.* += 20_000;
            _ = eng.step(t.*, 0);
        }
    }.f;

    // Right with nothing focused: the lowest navIndex.
    try e.post(.{ .key_down = keys.right });
    next(&e, &now);
    try testing.expect(a.state.focused and !b.state.focused);
    try testing.expectEqualStrings("true", a.node.attrNS(page_mod.state_ns, "focused").?);
    // Enter: actioned for one tick, the value toggles.
    try e.post(.{ .key_down = keys.enter });
    next(&e, &now);
    try testing.expect(a.state.actioned);
    try testing.expectEqualStrings("true", a.state.value);
    next(&e, &now);
    try testing.expect(!a.state.actioned);
    // The accessKey selects b; it takes the focus when its activation ends.
    try e.post(.{ .key_down = 0x37 });
    next(&e, &now);
    try testing.expect(b.state.actioned and !b.state.focused);
    next(&e, &now);
    try testing.expect(!b.state.actioned and b.state.focused and !a.state.focused);
    // Esc: no focus anywhere.
    try e.post(.{ .key_down = keys.esc });
    next(&e, &now);
    try testing.expect(!a.state.focused and !b.state.focused);

    // The mouse does nothing while the cursor is disabled.
    try e.post(.{ .mouse_move = .{ .x = 110, .y = 110 } });
    next(&e, &now);
    try testing.expect(!a.state.pointer);
    e.cursor.enabled = true;
    try e.post(.{ .mouse_move = .{ .x = 110, .y = 110 } });
    next(&e, &now);
    try testing.expect(a.state.pointer and !b.state.pointer);
    // A click: actioned from down to up, then focused.
    try e.post(.{ .mouse_down = .{ .x = 110, .y = 110 } });
    next(&e, &now);
    next(&e, &now);
    try testing.expect(a.state.actioned and !a.state.focused);
    try testing.expectEqualStrings("false", a.state.value);
    try e.post(.{ .mouse_up = .{ .x = 110, .y = 110 } });
    next(&e, &now);
    try testing.expect(!a.state.actioned and a.state.focused);
    // Moving off the buttons clears the pointer.
    try e.post(.{ .mouse_move = .{ .x = 400, .y = 400 } });
    next(&e, &now);
    try testing.expect(!a.state.pointer);
}

test "an MNG object plays from its first frame whenever it is displayed" {
    const gpa = testing.allocator;
    var pl = try xpl.parse(gpa,
        \\<Playlist xmlns="http://www.dvdforum.org/2005/HDDVDVideo/Playlist" majorVersion="1" minorVersion="0">
        \\ <Configuration><StreamingBuffer size="0"/><Aperture size="1920x1080"/><MainVideoDefaultColor color="108080"/></Configuration>
        \\ <MediaAttributeList/>
        \\ <TitleSet timeBase="60fps">
        \\  <Title id="t1" titleNumber="1" titleDuration="00:01:00:00"/>
        \\  <PlaylistApplication id="pa" src="file:///dvddisc/ADV_OBJ/m.xmf"/>
        \\ </TitleSet>
        \\</Playlist>
    );
    defer pl.deinit();
    const red: [4]u8 = .{ 255, 0, 0, 255 };
    const blue: [4]u8 = .{ 0, 0, 255, 255 };
    // 30 frames a second on 60 ticks a second: frame 1 from the third tick, then it stays.
    const mng = try image.testMng(gpa, 30, &.{ .{ red, red }, .{ blue, blue } }, null, null);
    defer gpa.free(mng);
    var files: Files = .{ .files = &.{
        .{
            "file:///dvddisc/ADV_OBJ/m.xmf",
            \\<Application xmlns="http://www.dvdforum.org/2005/HDDVDVideo/Manifest" id="m">
            \\ <Region x="0" y="0" width="100" height="100"/>
            \\ <Markup src="m.xmu"/>
            \\</Application>
        },
        .{
            "file:///dvddisc/ADV_OBJ/m.xmu",
            \\<root xmlns="http://www.dvdforum.org/2005/ihd" xmlns:style="http://www.dvdforum.org/2005/ihd#style" xml:lang="en"><body>
            \\<object id="o" type="image/mng" src="a.mng" style:position="absolute" style:x="0px" style:y="0px" style:width="2px" style:height="1px"/>
            \\</body></root>
        },
        .{ "file:///dvddisc/ADV_OBJ/a.mng", mng },
    } };
    var e = engine.Engine.init(gpa, 1920, 1080, 60);
    defer e.deinit();
    e.setScene(try Apps.create(gpa, .{ .pl = &pl, .loader = .{ .ctx = &files, .read = Files.read }, .menu_language = "en" }, 1920, 1080), 0);
    try e.post(.{ .title_begin = .{ .title = 0, .duration = 3600 } });
    var now: i64 = 0;
    _ = e.step(now, 0);
    const s: *Apps = @ptrCast(@alignCast(e.scene.?.ctx));
    const p = s.apps.items[0].page.?;
    const o = Page.elemOf(p.doc.getElementById("o").?).?;
    try testing.expectEqual(@as(?u32, 0), o.mng_frame);
    const f = try planes.Frame.create(gpa, 1920, 1080);
    defer f.unref();
    e.render(f);
    try testing.expectEqual(raster.Px{ 255, 0, 0, 255 }, f.canvas.at(1, 0));
    var redraw = false;
    for (0..4) |_| {
        now += 16_700;
        redraw = e.step(now, 0).redraw or redraw;
    }
    try testing.expectEqual(@as(?u32, 1), o.mng_frame);
    try testing.expect(redraw);
    // Hidden, then displayed again: from the start.
    try p.script.put(gpa, .{ .elem = o, .prop = .display }, "none");
    now += 16_700;
    _ = e.step(now, 0);
    try testing.expectEqual(@as(?u32, null), o.mng_frame);
    p.script.clearRetainingCapacity();
    now += 16_700;
    _ = e.step(now, 0);
    try testing.expectEqual(@as(?u32, 0), o.mng_frame);
}
