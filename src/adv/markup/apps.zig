//! The Advanced Applications as an engine scene (HD DVD Vol. 3 §7.2.4, §7.3.1.2, Ch. 8): their lifecycle,
//! scripts, events, markup and graphics.
//!
//! Lifecycle (§8.4): every application of the title exists from its start (a record), with the Playlist
//! Application in every title but the First Play one. An application is Valid in its title time span, Selected
//! by its group or language (§6.2.3.9), Ready when it becomes valid with autorun set or when activated, and
//! Loaded once its manifest, scripts (in order) and first markup page are in: then it is active, with a script
//! context (script/host.zig). One that stops being valid, selected or ready unloads; if it listens for
//! Application End, the title pauses and the event is sent until no listener cancels it.
//!
//! The records' order is the z-order, bottom first (the Playlist Application, then the title's by zOrder);
//! scripts reorder it. Graphics are drawn in that order, each application clipped to its region.
//!
//! Events (§8.3, §8.5): user input, system and application events are delivered to the applications in
//! priority order (the focused one, then the others from the top) as work items, until one consumes them. In
//! each application, user input goes to script first, then to the markup (accessKey, navigation, Enter, Esc);
//! what nothing consumes reaches the default input handler (Annex V). Each tick, every application's work
//! items run (priority order), then its page's timing, style and layout.
//!
//! One element in all applications has the focus. The pointer state follows the cursor, the element on top
//! under its hot spot. No VLC dependency.

const std = @import("std");
const engine = @import("../engine/engine.zig");
const planes = @import("../planes.zig");
const raster = @import("../raster.zig");
const image = @import("../image.zig");
const font_mod = @import("../font.zig");
const xpl = @import("../xpl.zig");
const dom = @import("../dom.zig");
const resman = @import("../resman.zig");
const manifest_mod = @import("../manifest.zig");
const page_mod = @import("page.zig");
const layout = @import("layout.zig");
const paint_mod = @import("paint.zig");
const focus = @import("focus.zig");
const style = @import("style.zig");
const keys = @import("../engine/keys.zig");
const timing = @import("timing.zig");
const host = @import("../script/host.zig");
const events = @import("../script/events.zig");
const sched = @import("../script/sched.zig");
const files_mod = @import("../script/files.zig");
const player_api = @import("../script/player_api.zig");

const Page = page_mod.Page;
const Script = host.Script;

pub const Config = struct {
    pl: *const xpl.Playlist,
    loader: page_mod.Loader,
    /// The Menu Language, to choose the Playlist Application.
    menu_language: []const u8,
    /// Logs a message (optional).
    log: ?*const fn (ctx: *anyopaque, msg: []const u8) void = null,
    log_ctx: *anyopaque = undefined,
    /// Element ids to show whatever their style says (debugging).
    show: []const u8 = "",
    /// Files for the script API (null: scripts cannot reach files).
    files: ?*files_mod.Files = null,
    /// Scripts run (false: markup only, as before Phase 5).
    scripts: bool = true,
    /// The playlist's URI (Player.playlist.location), the disc's Content ID, and whether it has Standard Content.
    playlist_uri: []const u8 = "",
    content_id: []const u8 = "",
    has_standard_content: bool = false,
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
        r.images = .empty;
        r.fonts = .empty;
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

/// One application of the title, or the Playlist Application.
pub const App = struct {
    pub const Kind = union(enum) {
        playlist: *const xpl.PlaylistApp,
        title: *const xpl.AppSegment,
    };

    kind: Kind,
    /// The manifest URI.
    src: []const u8,
    /// The playlist's id for it (what nav* properties name).
    id: []const u8,

    // ---- lifecycle (§8.4) ----
    valid: bool = false,
    selected: bool = true,
    ready: bool = false,
    loaded: bool = false,
    /// AdvancedApplication.autorun: from the playlist, changed by script.
    autorun: bool = true,
    /// Valid interval on the Title Timeline (frames).
    valid_range: [2]?i64 = .{ 0, null },
    /// Unloading, waiting for Application End listeners (§8.4.7).
    ending: bool = false,
    end_sent: bool = false,

    // ---- loaded ----
    manifest: ?manifest_mod.Manifest = null,
    page: ?*Page = null,
    script: ?*Script = null,
    lay: layout.Layout,
    res: Resources,
    region: raster.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    /// A hash of what was last drawn.
    look: u64 = 0,
    /// The elements in paint order, and each one's position in it, as of the last layout.
    order: []u32 = &.{},
    rank: []u32 = &.{},
    /// navIndex values have been generated for the page.
    numbered: bool = false,
    /// computeImplicitNav: number again.
    renumber: bool = false,
    /// Engine ticks when its first page and its current page started.
    app_start: ?u64 = null,
    page_start: u64 = 0,
    /// A link failed or the page is invalid: the application ended (§7.7.5.2).
    terminated: bool = false,
    /// Requests from script, carried out after the work items: link(uri), document.load().
    link_requested: ?[]u8 = null,
    reload_requested: bool = false,
    /// Script changed attributes of the page.
    attrs_dirty: bool = false,

    /// Active: valid, selected, ready and loaded (§8.4.6).
    pub fn active(a: *const App) bool {
        return a.valid and a.selected and a.ready and a.loaded;
    }

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

    fn uid(a: *const App) ?u64 {
        return if (a.script) |s| s.uid else null;
    }
};

pub const Apps = struct {
    gpa: std.mem.Allocator,
    cfg: Config,
    w: u32,
    h: u32,
    world: *host.World,
    /// All applications of the title, bottom of the z-order first.
    records: std.ArrayList(*App) = .empty,
    /// The engine's title count when the records were made.
    title_serial: u32 = 0,
    title: ?u16 = null,
    /// The Selected Application Group (Annex W; Player.applicationGroup).
    app_group: ?u32 = null,
    /// The engine, during a tick or input (for commands).
    eng: ?*engine.Engine = null,
    /// Title time at the last tick.
    last_time: u64 = 0,
    menu_lang_buf: [2]u8 = undefined,
    /// The engine's jump count at the last tick, and the play state last reported (play_state events).
    jump_serial: u32 = 0,
    reported_state: u32 = player_api.PlayState.play,
    engine_state: engine.PlayState = .playing,

    pub fn create(gpa: std.mem.Allocator, cfg: Config, w: u32, h: u32) !engine.Scene {
        const s = try gpa.create(Apps);
        errdefer gpa.destroy(s);
        const world = try host.World.create(gpa);
        s.* = .{ .gpa = gpa, .cfg = cfg, .w = w, .h = h, .world = world };
        world.apps = s;
        world.files = cfg.files;
        world.log = logWorld;
        world.log_ctx = s;
        world.tick_rate = engine.TickRate.of(cfg.pl.tick_base).perSecond();
        world.fps = cfg.pl.time_base.fps();
        world.pl = cfg.pl;
        world.aperture_w = w;
        world.aperture_h = h;
        world.lone_cursor = .init(w, h);
        world.playlist_uri = cfg.playlist_uri;
        world.content_id = cfg.content_id;
        world.has_standard_content = cfg.has_standard_content;
        world.streaming_buffer_kb = cfg.pl.streaming_buffer_kb;
        const pc = cfg.pl.default_color;
        world.model.outer = .{ @intCast(pc >> 16), @intCast((pc >> 8) & 0xff), @intCast(pc & 0xff) };
        if (cfg.menu_language.len >= 2) world.model.menu_language = .{ std.ascii.toLower(cfg.menu_language[0]), std.ascii.toLower(cfg.menu_language[1]) };
        world.model.sprm[0] = (@as(u16, world.model.menu_language[0]) << 8) | world.model.menu_language[1];
        player_api.titleBegins(world);
        return .{ .ctx = s, .vtable = &vtable };
    }

    const vtable: engine.Scene.VTable = .{ .tick = tick, .input = input, .render = render, .deinit = deinit };

    fn deinit(ctx: *anyopaque, gpa: std.mem.Allocator) void {
        const s: *Apps = @ptrCast(@alignCast(ctx));
        while (s.records.pop()) |a| s.destroyRecord(a);
        s.records.deinit(gpa);
        s.world.destroy();
        gpa.destroy(s);
    }

    fn logWorld(ctx: *anyopaque, msg: []const u8) void {
        const s: *Apps = @ptrCast(@alignCast(ctx));
        const f = s.cfg.log orelse return;
        f(s.cfg.log_ctx, msg);
    }

    fn log(s: *Apps, comptime fmt: []const u8, args: anytype) void {
        const f = s.cfg.log orelse return;
        var buf: [512]u8 = undefined;
        f(s.cfg.log_ctx, std.fmt.bufPrint(&buf, fmt, args) catch return);
    }

    // ---- records and the lifecycle ----------------------------------------------------------------------------

    fn newRecord(s: *Apps, kind: App.Kind) !*App {
        const a = try s.gpa.create(App);
        a.* = .{
            .kind = kind,
            .src = switch (kind) {
                .playlist => |p| p.src,
                .title => |t| t.src,
            },
            .id = switch (kind) {
                .playlist => |p| p.id,
                .title => |t| t.id,
            },
            .autorun = switch (kind) {
                .playlist => true,
                .title => |t| t.autorun,
            },
            .lay = .init(s.gpa),
            .res = .{ .gpa = s.gpa, .loader = s.cfg.loader },
        };
        return a;
    }

    fn destroyRecord(s: *Apps, a: *App) void {
        s.unload(a);
        for (s.records.items) |b| if (b.script) |sc| host.forgetApplication(sc, a);
        a.lay.deinit();
        a.res.deinit();
        if (a.link_requested) |l| s.gpa.free(l);
        s.gpa.destroy(a);
    }

    /// The title changed: its applications replace the last title's; the Playlist Application stays
    /// (outside the First Play title). Title End goes to what remains, Title Begin to what is loaded then
    /// (§8.3.1 cases 1 and 2).
    fn titleChanged(s: *Apps, e: *engine.Engine) void {
        var i: usize = 0;
        while (i < s.records.items.len) {
            const a = s.records.items[i];
            if (a.kind == .playlist and e.title != null) {
                i += 1;
                continue;
            }
            _ = s.records.orderedRemove(i);
            s.log("application {s} ends", .{a.src});
            s.destroyRecord(a);
        }
        if (s.title_serial > 0) s.sendSystem(.{ .kind = .title, .type = "title_end", .id = s.titleId() }, null);
        s.title_serial = e.title_serial;
        s.title = e.title;
        const pl = s.cfg.pl;
        if (e.title != null and s.records.items.len == 0) if (resman.Manager.playlistApp(pl, s.cfg.menu_language)) |pa| {
            const a = s.newRecord(.{ .playlist = pa }) catch return;
            s.records.insert(s.gpa, 0, a) catch {
                s.destroyRecord(a);
                return;
            };
            a.valid = true;
            a.ready = true;
            a.valid_range = .{ 0, null };
            s.load(a);
        };
        s.sendSystem(.{ .kind = .title, .type = "title_begin", .id = s.titleId() }, s.loadedUids());
        const title = s.curTitle() orelse return;
        // The title's applications, by their zOrder.
        var segs: std.ArrayList(*const xpl.AppSegment) = .empty;
        defer segs.deinit(s.gpa);
        for (title.apps) |*seg| if (!seg.subtitle) segs.append(s.gpa, seg) catch {};
        std.mem.sort(*const xpl.AppSegment, segs.items, {}, struct {
            fn less(_: void, x: *const xpl.AppSegment, y: *const xpl.AppSegment) bool {
                return x.z_order < y.z_order;
            }
        }.less);
        for (segs.items) |seg| {
            const a = s.newRecord(.{ .title = seg }) catch continue;
            a.valid_range = .{ @intCast(seg.title_begin), if (seg.title_end) |x| @intCast(x) else null };
            s.records.append(s.gpa, a) catch s.destroyRecord(a);
        }
    }

    fn curTitle(s: *const Apps) ?*const xpl.Title {
        const pl = s.cfg.pl;
        if (s.title) |i| return if (i < pl.titles.len) &pl.titles[i] else null;
        return if (pl.first_play) |*fp| fp else null;
    }

    fn titleId(s: *const Apps) ?[]const u8 {
        const t = s.curTitle() orelse return null;
        return if (t.id.len > 0) t.id else null;
    }

    /// Selection (§6.2.3.9): the group must be the selected one; an Application Block member must have the
    /// menu language, or the default language when the block has none in the menu language.
    fn selected(s: *const Apps, seg: *const xpl.AppSegment) bool {
        if (seg.group) |g| return s.app_group == g;
        const block = seg.app_block orelse return true;
        if (seg.language.len == 0) return true;
        if (std.ascii.eqlIgnoreCase(seg.language, s.cfg.menu_language)) return true;
        const title = s.curTitle() orelse return false;
        for (title.apps) |o| if (o.app_block == block and std.ascii.eqlIgnoreCase(o.language, s.cfg.menu_language)) return false;
        return std.ascii.eqlIgnoreCase(seg.language, s.cfg.pl.default_language);
    }

    fn lifecycle(s: *Apps, t: u64) void {
        const title = s.curTitle() orelse return;
        for (s.records.items) |a| {
            const seg = switch (a.kind) {
                .playlist => continue,
                .title => |x| x,
            };
            const end = seg.title_end orelse title.duration;
            const valid = t >= seg.title_begin and t < end;
            if (valid and !a.valid) a.ready = a.autorun;
            if (!valid) a.ready = false;
            a.valid = valid;
            a.selected = s.selected(seg);
            const want = a.valid and a.selected and a.ready and !a.terminated;
            if (want and !a.loaded) s.load(a) else if (!want and a.loaded) s.shutdown(a, !valid);
        }
    }

    /// Player.menuLanguage changed: the Application Blocks' selection follows (Z.10.1.2).
    pub fn setMenuLanguage(s: *Apps, lang: []const u8) void {
        @memcpy(s.menu_lang_buf[0..2], lang[0..2]);
        s.cfg.menu_language = s.menu_lang_buf[0..2];
    }

    /// activate() (Z.1.2.3): only while valid and selected.
    pub fn activate(s: *Apps, a: *App) bool {
        if (!a.valid or !a.selected) return false;
        a.ready = true;
        a.terminated = false;
        if (!a.loaded) s.load(a);
        return true;
    }

    /// inactivate(): not the Playlist Application, and only while running.
    pub fn inactivate(s: *Apps, a: *App) bool {
        if (a.kind == .playlist or !a.active()) return false;
        a.ready = false;
        s.shutdown(a, false);
        return true;
    }

    /// An application stops (§8.4.7): Application End first if it listens for it and is leaving its valid
    /// period; the title is held while listeners cancel it.
    fn shutdown(s: *Apps, a: *App, leaving: bool) void {
        const sc = a.script orelse return s.unload(a);
        if (leaving and !a.ending and sc.listens("application_end")) {
            a.ending = true;
            if (s.eng) |e| e.command(.{ .hold = true });
            s.sendEnd(a);
            return;
        }
        if (a.ending) return; // waiting for the listeners
        s.unload(a);
    }

    fn sendEnd(s: *Apps, a: *App) void {
        const sc = a.script orelse return;
        const d = host.Delivery.create(s.gpa, s.world.rt, .system, .{ .kind = .application, .type = "application_end", .id = if (a.id.len > 0) a.id else null }) catch return;
        d.recipients = d.arena.allocator().dupe(u64, &.{sc.uid}) catch null;
        s.timeOf(d);
        a.end_sent = true;
        sc.post(.{ .delivery = d }, .app, 0, null) catch {};
    }

    /// Application End was delivered: unless cancelled, the application unloads and the title goes on.
    fn endDelivered(s: *Apps, a: *App, prevented: bool) void {
        if (prevented) {
            s.sendEnd(a);
            return;
        }
        a.ending = false;
        s.unload(a);
        var any = false;
        for (s.records.items) |b| any = any or b.ending;
        if (!any) if (s.eng) |e| e.command(.{ .hold = false });
    }

    /// Loads an application: manifest, scripts in order, then the first markup page (§8.4.5).
    fn load(s: *Apps, a: *App) void {
        a.loaded = true;
        a.terminated = false;
        a.app_start = null;
        const bytes = s.cfg.loader.read(s.cfg.loader.ctx, a.src) catch |err| {
            s.log("application {s}: cannot read its manifest ({s})", .{ a.src, @errorName(err) });
            return;
        };
        defer s.gpa.free(bytes);
        a.manifest = manifest_mod.parse(s.gpa, bytes, a.src) catch |err| {
            s.log("application {s}: bad manifest ({s})", .{ a.src, @errorName(err) });
            return;
        };
        const m = &a.manifest.?;
        a.region = .{ .x = @intCast(m.region.x), .y = @intCast(m.region.y), .w = @intCast(m.region.width), .h = @intCast(m.region.height) };
        if (s.cfg.scripts) {
            a.script = Script.create(s.world, a) catch |err| blk: {
                s.log("application {s}: no script context ({s})", .{ a.src, @errorName(err) });
                break :blk null;
            };
            if (a.script) |sc| {
                var failed: usize = 0;
                for (m.scripts) |u| {
                    const code = s.cfg.loader.read(s.cfg.loader.ctx, u) catch |err| {
                        s.log("application {s}: cannot read {s} ({s})", .{ a.src, u, @errorName(err) });
                        failed += 1;
                        continue;
                    };
                    defer s.gpa.free(code);
                    if (!sc.runScript(code, u)) failed += 1;
                }
                s.log("application {s}: {d} scripts run, {d} failed", .{ a.src, m.scripts.len, failed });
            }
        }
        const markup = m.markup orelse {
            s.log("application {s}: no markup", .{a.src});
            return;
        };
        const p = Page.load(s.gpa, s.cfg.loader, markup, s.h) catch |err| {
            s.log("application {s}: cannot load {s} ({s})", .{ a.src, markup, @errorName(err) });
            return;
        };
        a.page = p;
        s.log("application {s}: {s}, {d} elements, region {d},{d} {d}x{d}", .{ a.src, markup, p.elems.items.len, a.region.x, a.region.y, a.region.w, a.region.h });
        s.pageStarted(a, s.world.tick);
        var it = std.mem.tokenizeAny(u8, s.cfg.show, ", ");
        while (it.next()) |shown| {
            const n = p.doc.getElementById(shown) orelse continue;
            const e = Page.elemOf(n) orelse continue;
            var x: ?*page_mod.Elem = e;
            while (x) |el| : (x = el.parent) p.script.put(s.gpa, .{ .elem = el, .prop = .display }, "auto") catch {};
        }
        if (a.script) |sc| sc.pageLoaded(p, markup);
    }

    /// Unloads an application: its script context and page go; the record stays.
    fn unload(s: *Apps, a: *App) void {
        if (a.loaded) s.log("application {s} unloads", .{a.src});
        if (a.script) |sc| {
            sc.pageGone();
            sc.destroy();
        }
        a.script = null;
        s.gpa.free(a.order);
        s.gpa.free(a.rank);
        a.order = &.{};
        a.rank = &.{};
        if (a.page) |p| p.destroy();
        a.page = null;
        if (a.manifest) |*m| m.deinit();
        a.manifest = null;
        a.res.deinit();
        a.loaded = false;
        a.ending = false;
        a.numbered = false;
        a.look = 0;
    }

    fn loadedUids(s: *Apps) ?[]const u64 {
        var list: std.ArrayList(u64) = .empty;
        for (s.records.items) |a| if (a.uid()) |u| list.append(s.gpa, u) catch {};
        // Kept in the delivery's arena by sendSystem.
        return list.toOwnedSlice(s.gpa) catch null;
    }

    // ---- z-order ----------------------------------------------------------------------------------------------

    /// The z-order of `a` among the valid applications (bottom 0), or null if it has none.
    pub fn zOrderOf(s: *const Apps, a: *const App) ?u32 {
        if (!a.valid) return null;
        var z: u32 = 0;
        for (s.records.items) |b| {
            if (b == a) return z;
            if (b.valid) z += 1;
        }
        return null;
    }

    fn indexOf(s: *const Apps, a: *const App) ?usize {
        return std.mem.indexOfScalar(*App, s.records.items, @constCast(a));
    }

    pub fn moveToTop(s: *Apps, a: *App) void {
        const i = s.indexOf(a) orelse return;
        _ = s.records.orderedRemove(i);
        s.records.append(s.gpa, a) catch {};
    }

    pub fn moveToBottom(s: *Apps, a: *App) void {
        const i = s.indexOf(a) orelse return;
        _ = s.records.orderedRemove(i);
        s.records.insert(s.gpa, 0, a) catch {};
    }

    /// moveBefore/moveAfter (Z.1.2.3): just below or just above `target` in the z-order. moveBefore puts it
    /// numerically after (above) the target: "before" in the processing order (Remarks of Z.1.2.3).
    pub fn moveRelative(s: *Apps, a: *App, target: *App, where: enum { before, after }) void {
        if (a == target) return;
        const i = s.indexOf(a) orelse return;
        _ = s.records.orderedRemove(i);
        const j = s.indexOf(target) orelse {
            s.records.insert(s.gpa, i, a) catch {};
            return;
        };
        s.records.insert(s.gpa, if (where == .before) j + 1 else j, a) catch {};
    }

    /// The active applications in priority order (§8.3.6): the focused one first, then the others from the top.
    fn priority(s: *Apps, out: *std.ArrayList(*App)) void {
        const first = s.focusedApp();
        if (first) |f| out.append(s.gpa, f) catch return;
        var i = s.records.items.len;
        while (i > 0) {
            i -= 1;
            const a = s.records.items[i];
            if (a == first or !a.active() or a.script == null) continue;
            out.append(s.gpa, a) catch return;
        }
    }

    // ---- the tick -----------------------------------------------------------------------------------------

    fn tick(ctx: *anyopaque, e: *engine.Engine, c: engine.Clocks) bool {
        const s: *Apps = @ptrCast(@alignCast(ctx));
        const w = s.world;
        s.eng = e;
        w.eng = e;
        defer {
            s.eng = null;
            w.eng = null;
        }
        w.tick = c.app;
        w.now_us = e.rate.us(c.app);
        w.title_time = c.title;
        w.title_running = e.play_state == .playing;
        w.paused = e.play_state == .paused;
        if (!e.in_title) return false;
        var changed = false;
        if (e.title_serial != s.title_serial) {
            w.title_index = e.title;
            player_api.titleBegins(w);
            s.jump_serial = e.jump_serial;
            s.engine_state = e.play_state;
            s.reported_state = player_api.PlayState.play;
            s.titleChanged(e);
            changed = true;
        }
        // The player's own pauses (VLC's pause key) change the play state too.
        if (e.play_state != s.engine_state) {
            s.engine_state = e.play_state;
            w.model.play_state = if (e.play_state == .paused) player_api.PlayState.pause else player_api.PlayState.play;
        }
        s.lifecycle(c.title);
        s.last_time = c.title;
        const jumped = e.jump_serial != s.jump_serial;
        s.jump_serial = e.jump_serial;
        player_api.timelineEvents(w, jumped);
        player_api.advanceLayouts(w);
        if (w.model.play_state != s.reported_state) {
            s.sendSystem(.{ .kind = .play_state, .type = "play_state", .old = s.reported_state, .new = w.model.play_state }, null);
            s.reported_state = w.model.play_state;
        }

        s.endActivations(c.app);
        s.runScripts(c);
        for (s.records.items) |a| s.afterScripts(a, c.app);

        for (s.records.items) |a| s.runTiming(a, c);
        for (s.records.items) |a| {
            const p = a.page orelse continue;
            if (!a.active()) continue;
            // The front-most application is in the foreground (§7.6.3.4.2.1).
            if (p.elems.items.len > 0 and p.elems.items[0].kind == .body) p.setState(p.elems.items[0], .foreground, a == s.topActive());
            if (a.script) |sc| if (sc.overrides.list.items.len > 0 or sc.overrides.applied) sc.overrides.apply(sc, p, sc.appTicks());
            p.cascade();
            a.lay.run(p, a.res.res(), @floatFromInt(a.region.w), @floatFromInt(a.region.h));
            a.reorder(s.gpa);
            a.animate(c.app, s.cfg.pl.tick_base);
            if (!a.numbered or a.renumber) {
                focus.generate(s.gpa, p, a.rank) catch {};
                a.numbered = true;
                a.renumber = false;
            }
            const look = hashLook(p, &a.lay) +% @as(u64, @bitCast(@as(i64, a.region.x) << 32 | @as(i64, a.region.y)));
            if (look != a.look) changed = true;
            a.look = look;
        }
        s.updatePointer(e);
        // What the next tick's expressions see.
        for (s.records.items) |a| if (a.page) |p| p.snapshot();
        return changed;
    }

    fn topActive(s: *Apps) ?*App {
        var i = s.records.items.len;
        while (i > 0) {
            i -= 1;
            if (s.records.items[i].active() and s.records.items[i].page != null) return s.records.items[i];
        }
        return null;
    }

    fn nowFor(s: *Apps, a: *App, c: engine.Clocks) sched.Now {
        _ = s;
        return .{ .title = c.title, .app = c.app -| (a.app_start orelse c.app), .page = c.app -| a.page_start };
    }

    /// Each application's work items, in priority order (§8.3.6, §8.5).
    fn runScripts(s: *Apps, c: engine.Clocks) void {
        var order: std.ArrayList(*App) = .empty;
        defer order.deinit(s.gpa);
        s.priority(&order);
        for (order.items) |a| {
            const sc = a.script orelse continue;
            sc.runTimers();
            const now = s.nowFor(a, c);
            sc.queue.mark(s.gpa, now) catch continue;
            while (true) {
                // The application may unload while its items run.
                if (a.script != sc) break;
                const job = sc.queue.next(now, sc, dropJob) orelse break;
                switch (job) {
                    .delivery => |d| s.processDelivery(a, d),
                    else => sc.run(job),
                }
            }
        }
    }

    fn dropJob(sc: *Script, job: host.Job) void {
        sc.dropJob(job);
    }

    /// After the work items: requested links and reloads, and a DOM the scripts changed.
    fn afterScripts(s: *Apps, a: *App, now: u64) void {
        if (a.link_requested) |u| {
            a.link_requested = null;
            defer s.gpa.free(u);
            s.linkTo(a, u, now);
        }
        const p = a.page orelse return;
        const sc = a.script orelse return;
        if (a.reload_requested) {
            a.reload_requested = false;
            sc.tree_dirty = false;
            p.reload() catch {
                // §7.2.4.2: an invalid DOM ends the application.
                s.log("application {s}: the page is invalid after document.load(); it ends", .{a.src});
                a.terminated = true;
                s.unload(a);
                return;
            };
            s.pageStarted(a, now);
            return;
        }
        if (sc.tree_dirty) {
            sc.tree_dirty = false;
            p.sync() catch {};
            a.numbered = false;
        }
    }

    // ---- deliveries -----------------------------------------------------------------------------------------

    /// Stamps a system event with the title time.
    fn timeOf(s: *Apps, d: *host.Delivery) void {
        var buf: [16]u8 = undefined;
        d.spec.time = d.arena.allocator().dupe(u8, events.timecode(&buf, s.world.title_time, s.world.fps)) catch null;
    }

    /// Sends a system event to the applications (only `recipients` if not null; the list is taken).
    pub fn sendSystem(s: *Apps, spec: events.Spec, recipients: ?[]const u64) void {
        defer if (recipients) |r| s.gpa.free(r);
        const d = host.Delivery.create(s.gpa, s.world.rt, .system, spec) catch return;
        if (recipients) |r| d.recipients = d.arena.allocator().dupe(u64, r) catch null;
        s.timeOf(d);
        s.send(d) catch {};
    }

    /// Sends a delivery to the first application in priority order that may take it.
    pub fn send(s: *Apps, d: *host.Delivery) !void {
        if (s.next(d)) |a| return a.script.?.post(.{ .delivery = d }, .app, 0, null);
        s.finish(d);
    }

    /// The next application for `d`: pointer input goes first to the application under the cursor.
    fn next(s: *Apps, d: *const host.Delivery) ?*App {
        if (d.input) |in| if (in.pointer and d.visited.items.len == 0) if (s.appAt(in.x, in.y)) |a| if (a.uid()) |u| if (d.mayVisit(u)) return a;
        var order: std.ArrayList(*App) = .empty;
        defer order.deinit(s.gpa);
        s.priority(&order);
        for (order.items) |a| if (a.uid()) |u| if (d.mayVisit(u)) return a;
        return null;
    }

    /// Nothing consumed it: the default input handler (Annex V) for user input.
    fn finish(s: *Apps, d: *host.Delivery) void {
        defer d.destroy();
        const in = d.input orelse return;
        if (d.prevented) return;
        // The key's handler runs on key down (VK_MOUSE_1's is markup's, on key up).
        if (in.kind == .key_down and !in.pointer) player_api.defaultKey(s.world, in.key);
    }

    fn processDelivery(s: *Apps, a: *App, d: *host.Delivery) void {
        const sc = a.script orelse return d.destroy();
        d.visited.append(d.arena.allocator(), sc.uid) catch {};
        // The target in this application.
        var target: ?*dom.Node = null;
        if (d.input) |in| {
            if (in.pointer) {
                if (s.elementAt(a, in.x, in.y)) |el| target = el.node;
            } else if (a.page) |p| if (p.focused()) |el| {
                target = el.node;
            };
            s.fillKeyCoords(a, d, target);
        } else if (d.origin == sc.uid) target = d.origin_node;
        const out = sc.deliver(d, target);
        d.prevented = out.prevented;
        if (d.spec.kind == .application and a.ending and d.recipients != null) {
            const prevented = out.prevented;
            d.destroy();
            s.endDelivered(a, prevented);
            return;
        }
        var consumed = out.stopped;
        if (!consumed and !out.prevented) if (d.input) |in| {
            consumed = s.markupDefault(a, in);
        };
        if (d.input) |in| if (in.kind == .key_down) s.log("key {s} in {s}: {s}", .{
            keys.name(in.key) orelse "?",
            if (a.id.len > 0) a.id else a.src,
            if (out.stopped) "stopped by script" else if (out.prevented) "prevented by script" else if (consumed) "used by markup" else "not used",
        });
        if (consumed) return d.destroy();
        if (s.next(d)) |b| {
            b.script.?.post(.{ .delivery = d }, .app, 0, null) catch {};
            return;
        }
        s.finish(d);
    }

    /// The ControllerKeyEvent's coordinates (Z.5.3): canvas, relative to the target, relative to its parent.
    fn fillKeyCoords(s: *Apps, a: *App, d: *host.Delivery, target: ?*dom.Node) void {
        _ = s;
        const in = d.input.?;
        const x: u32 = @intCast(@max(0, in.x));
        const y: u32 = @intCast(@max(0, in.y));
        d.spec.key.x = x;
        d.spec.key.y = y;
        d.spec.key.offset_x = x;
        d.spec.key.offset_y = y;
        d.spec.key.parent_x = x;
        d.spec.key.parent_y = y;
        const n = target orelse return;
        const el = Page.elemOf(n) orelse return;
        const ox = a.region.x + @as(i32, @intFromFloat(el.box.x));
        const oy = a.region.y + @as(i32, @intFromFloat(el.box.y));
        d.spec.key.offset_x = @intCast(@max(0, in.x - ox));
        d.spec.key.offset_y = @intCast(@max(0, in.y - oy));
        if (el.parent) |par| {
            const px = a.region.x + @as(i32, @intFromFloat(par.box.x));
            const py = a.region.y + @as(i32, @intFromFloat(par.box.y));
            d.spec.key.parent_x = @intCast(@max(0, in.x - px));
            d.spec.key.parent_y = @intCast(@max(0, in.y - py));
        }
    }

    /// The markup's own handling of user input in one application (§7.2.7): true if it consumed it.
    fn markupDefault(s: *Apps, a: *App, in: host.Input) bool {
        const tick_no = if (s.eng) |e| e.last_tick orelse 0 else 0;
        switch (in.kind) {
            .key_down => if (in.pointer) {
                // A pointer activation lasts until the button comes up (§7.6.3.4.2.4).
                const p = a.page orelse return false;
                var any = false;
                for (p.elems.items) |el| if (el.state.pointer and el.kind.activatable() and el.state.enabled) {
                    p.setState(el, .actioned, true);
                    el.pressed = true;
                    toggleValue(p, el);
                    any = true;
                };
                return any;
            } else return s.keyIn(a, in.key, a == s.focusedApp(), tick_no),
            .key_up => if (in.pointer) {
                // Focus follows once the activation has ended (§7.6.3.4.2.3).
                const p = a.page orelse return false;
                var any = false;
                for (p.elems.items) |el| if (el.pressed) {
                    el.pressed = false;
                    if (el.key_actioned == null) p.setState(el, .actioned, false);
                    if (focus.focusable(el) and !s.world.focus_locked) s.setFocus(p, el);
                    any = true;
                };
                return any;
            } else return false,
            .cursor_move, .vector => return false,
        }
    }

    // ---- input ----------------------------------------------------------------------------------------------

    fn input(ctx: *anyopaque, e: *engine.Engine, ev: engine.Event) void {
        const s: *Apps = @ptrCast(@alignCast(ctx));
        s.eng = e;
        s.world.eng = e;
        defer {
            s.eng = null;
            s.world.eng = null;
        }
        switch (ev) {
            .key_down, .key_up => |k| s.sendInput(e, .{ .kind = if (ev == .key_down) .key_down else .key_up, .key = k, .x = e.cursor.x, .y = e.cursor.y }),
            .mouse_move => {
                s.updatePointer(e);
                s.sendInput(e, .{ .kind = .cursor_move, .x = e.cursor.x, .y = e.cursor.y, .pointer = true });
            },
            .mouse_down => {
                s.updatePointer(e);
                s.sendInput(e, .{ .kind = .key_down, .key = keys.mouse_1, .x = e.cursor.x, .y = e.cursor.y, .pointer = true });
            },
            .mouse_up => s.sendInput(e, .{ .kind = .key_up, .key = keys.mouse_1, .x = e.cursor.x, .y = e.cursor.y, .pointer = true }),
            else => {},
        }
    }

    fn sendInput(s: *Apps, e: *engine.Engine, in: host.Input) void {
        _ = e;
        const type_: []const u8 = switch (in.kind) {
            .key_down => "controller_key_down",
            .key_up => "controller_key_up",
            .cursor_move => "cursor_move",
            .vector => "controller_key_vector",
        };
        var code_buf: [8]u8 = undefined;
        var key: events.KeyInfo = .{ .id = if (in.pointer) 2 else 1 };
        if (in.kind != .cursor_move) {
            key.key = in.key;
            if (keys.char(in.key)) |ch| key.code = std.fmt.bufPrint(&code_buf, "U+{X:0>4}", .{ch}) catch null;
        }
        const d = host.Delivery.create(s.gpa, s.world.rt, .input, .{ .kind = .key, .type = type_, .key = key }) catch return;
        d.input = in;
        s.send(d) catch {};
    }

    /// Offers key `k` to application `a`'s markup; true if it consumed it.
    fn keyIn(s: *Apps, a: *App, k: keys.Key, focused_app: bool, tick_no: u64) bool {
        const p = a.page orelse return false;
        // accessKeys, in any application.
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
            if (s.world.focus_locked) return cur != null;
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
                    const b = for (s.records.items) |b| {
                        if (b.active() and std.mem.eql(u8, b.id, nav.app)) break b;
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
            if (cur == null or s.world.focus_locked) return false;
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
        for (s.records.items) |a| {
            const p = a.page orelse continue;
            for (p.elems.items) |el| {
                const t = el.key_actioned orelse continue;
                if (t >= now) continue;
                el.key_actioned = null;
                if (!el.pressed) p.setState(el, .actioned, false);
                if (el.focus_after) {
                    el.focus_after = false;
                    if (focus.focusable(el) and !s.world.focus_locked) s.setFocus(p, el);
                }
            }
        }
    }

    /// The application with the focused element, or else the one on top (§7.2.5.1).
    fn focusedApp(s: *Apps) ?*App {
        for (s.records.items) |a| if (a.active()) if (a.page) |p| if (p.focused() != null) return a;
        return s.topActive();
    }

    /// Gives `el` the focus: one element in all applications has it.
    fn setFocus(s: *Apps, p: *Page, el: *page_mod.Elem) void {
        for (s.records.items) |a| if (a.page) |q| for (q.elems.items) |x| if (x != el and x.state.focused) q.setState(x, .focused, false);
        if (!el.state.focused) s.log("focus: {s} {s}", .{ @tagName(el.kind), el.node.attr("id") orelse "(no id)" });
        p.setState(el, .focused, true);
    }

    /// Focus set by script (the Animated Property API), whatever the global state.
    pub fn focusFromScript(s: *Apps, p: *Page, el: *page_mod.Elem) void {
        s.setFocus(p, el);
    }

    fn clearFocus(s: *Apps) void {
        s.log("focus cleared", .{});
        for (s.records.items) |a| if (a.page) |q| for (q.elems.items) |x| if (x.state.focused) q.setState(x, .focused, false);
    }

    /// The application on top whose region holds canvas point (x, y).
    fn appAt(s: *Apps, x: i32, y: i32) ?*App {
        var i = s.records.items.len;
        while (i > 0) {
            i -= 1;
            const a = s.records.items[i];
            if (!a.active() or a.page == null) continue;
            if (s.elementAt(a, x, y) != null) return a;
        }
        return null;
    }

    fn elementAt(s: *Apps, a: *App, x: i32, y: i32) ?*page_mod.Elem {
        _ = s;
        const p = a.page orelse return null;
        if (a.order.len != p.elems.items.len) return null;
        if (!a.region.contains(x, y)) return null;
        return focus.hit(p, a.order, @floatFromInt(x - a.region.x), @floatFromInt(y - a.region.y));
    }

    /// state:pointer on the element under the cursor's hot spot, the application on top first; none while the
    /// cursor is disabled.
    fn updatePointer(s: *Apps, e: *const engine.Engine) void {
        var under: ?*page_mod.Elem = null;
        if (e.cursor.enabled) {
            if (s.appAt(e.cursor.x, e.cursor.y)) |a| under = s.elementAt(a, e.cursor.x, e.cursor.y);
        }
        for (s.records.items) |a| if (a.page) |p| for (p.elems.items) |x| p.setState(x, .pointer, x == under);
    }

    // ---- timing and pages -------------------------------------------------------------------------------------

    /// Runs a page's timesheets, then what they set: states, a link to another page, events.
    fn runTiming(s: *Apps, a: *App, c: engine.Clocks) void {
        if (!a.active()) return;
        const p = a.page orelse return;
        const tm = p.timing orelse return;
        if (tm.empty()) return;
        tm.tick(p, .{
            .title = @intCast(c.title),
            .app = @intCast(c.app -| (a.app_start orelse c.app)),
            .page = @intCast(c.app -| a.page_start),
            .valid = a.valid_range,
        });
        const ov = if (a.script) |sc| &sc.overrides else null;
        for (tm.states.items) |st| switch (st.which) {
            .focused => if (!s.world.focus_locked) {
                if (std.mem.eql(u8, st.value, "true")) {
                    if (focus.focusable(st.elem) or st.elem.kind.activatable()) s.setFocus(p, st.elem);
                } else p.setState(st.elem, .focused, false);
            },
            .enabled => if (ov == null or !ov.?.enabled_locked) p.setState(st.elem, .enabled, !std.mem.eql(u8, st.value, "false")),
            .value => if (ov == null or !ov.?.value_locked) p.setValue(st.elem, st.value) catch {},
        };
        // <event> elements: application events, to every application (§8.3.7).
        for (tm.events.items) |ev| s.raiseEvent(a, ev);
        tm.events.clearRetainingCapacity();
        if (tm.link) |l| {
            tm.link = null;
            const href = l.attr("href") orelse "";
            const u = p.resolve(l, href) catch return;
            defer s.gpa.free(u);
            s.linkTo(a, u, c.app);
        }
    }

    /// A markup <event>: an Application Event named by it, with its <param>s as properties, at the element its
    /// cue selects in this application and at the Application object in the others.
    fn raiseEvent(s: *Apps, a: *App, ev: timing.Fired) void {
        const sc = a.script orelse return;
        const d = host.Delivery.create(s.gpa, s.world.rt, .app, .{ .kind = .app, .type = ev.name }) catch return;
        d.origin = sc.uid;
        // At the element the cue selects; its parameters come from the <event> element.
        d.origin_node = ev.target;
        var extras: std.ArrayList(events.Extra) = .empty;
        const ar = d.arena.allocator();
        var ch = ev.event.firstElement();
        while (ch) |prm| : (ch = prm.nextElement()) {
            if (!prm.is(page_mod.core_ns, "param")) continue;
            const name = prm.attr("name") orelse continue;
            const v = prm.attr("value") orelse "";
            const sv = sc.cx.string(v) catch continue;
            extras.append(ar, .{ .name = ar.dupe(u8, name) catch continue, .value = sv }) catch sc.cx.free(sv);
        }
        d.spec.extras = extras.items;
        s.send(d) catch {};
    }

    /// A link (markup <link> or Application.link): its page replaces the current one once loaded; a page that
    /// cannot be loaded changes nothing for a script link, and ends the application for a markup link
    /// (§7.7.5.2).
    fn linkTo(s: *Apps, a: *App, u: []const u8, now: u64) void {
        const p = a.page orelse return;
        const next_page = Page.load(s.gpa, s.cfg.loader, u, s.h) catch |err| {
            s.log("application {s}: link to {s} failed ({s})", .{ a.src, u, @errorName(err) });
            return;
        };
        s.log("application {s}: link to {s}", .{ a.src, u });
        if (a.script) |sc| sc.pageGone();
        p.destroy();
        a.page = next_page;
        if (a.script) |sc| sc.dropPageItems();
        s.pageStarted(a, now);
        if (a.script) |sc| sc.pageLoaded(next_page, u);
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

    fn render(ctx: *anyopaque, _: *engine.Engine, f: *planes.Frame) void {
        const s: *Apps = @ptrCast(@alignCast(ctx));
        for (s.records.items) |a| {
            if (!a.active()) continue;
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
        hashValue(&h, e.graphic != null);
        hashValue(&h, e.graphic_gen);
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
    const p = s.records.items[0].page.?;
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
    const p = s.records.items[0].page.?;
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

test "scripts: lifecycle, events, input and the Animated Property API" {
    const gpa = testing.allocator;
    var pl = try xpl.parse(gpa,
        \\<Playlist xmlns="http://www.dvdforum.org/2005/HDDVDVideo/Playlist" majorVersion="1" minorVersion="0">
        \\ <Configuration><StreamingBuffer size="0"/><Aperture size="1920x1080"/><MainVideoDefaultColor color="108080"/></Configuration>
        \\ <MediaAttributeList/>
        \\ <TitleSet timeBase="60fps">
        \\  <Title id="t1" titleNumber="1" titleDuration="00:01:00:00">
        \\   <ApplicationSegment id="late" src="file:///dvddisc/ADV_OBJ/b.xmf" titleTimeBegin="00:00:00:30" titleTimeEnd="00:00:01:30" zOrder="0" autorun="false"/>
        \\  </Title>
        \\  <PlaylistApplication id="pa" src="file:///dvddisc/ADV_OBJ/m.xmf"/>
        \\ </TitleSet>
        \\</Playlist>
    );
    defer pl.deinit();
    var files: Files = .{ .files = &.{
        .{
            "file:///dvddisc/ADV_OBJ/m.xmf",
            \\<Application xmlns="http://www.dvdforum.org/2005/HDDVDVideo/Manifest" id="m">
            \\ <Region x="0" y="0" width="400" height="400"/>
            \\ <Script src="m.js"/>
            \\ <Markup src="m.xmu"/>
            \\</Application>
        },
        .{
            "file:///dvddisc/ADV_OBJ/m.js",
            \\var log = [];
            \\setMarkupLoadedHandler(function (u) { log.push("loaded:" + u.substring(u.lastIndexOf("/") + 1)); });
            \\addEventListener("title_begin", function (e) { log.push("title_begin:" + e.id + ":" + e.time); }, false);
            \\addEventListener("controller_key_down", function (e) {
            \\  log.push("key:" + e.key + ":" + (e.target === application ? "app" : e.target.getAttribute("id")));
            \\  if (e.key == e.VK_UP) { e.preventDefault(); }
            \\}, true);
            \\addEventListener("hello", function (e) { log.push("hello:" + e.a + ":" + e.target.getAttribute("id")); }, true);
        },
        .{
            "file:///dvddisc/ADV_OBJ/m.xmu",
            \\<root xmlns="http://www.dvdforum.org/2005/ihd" xmlns:style="http://www.dvdforum.org/2005/ihd#style" xml:lang="en"><head>
            \\<timing clock="page"><par><cue select="id('a')" begin="2f" dur="1s"><event name="hello"><param name="a" value="1"/></event></cue></par></timing>
            \\</head><body>
            \\<button id="a" style:position="absolute" style:x="0px" style:y="0px" style:width="50px" style:height="50px"/>
            \\<button id="b" style:position="absolute" style:x="0px" style:y="100px" style:width="50px" style:height="50px"/>
            \\</body></root>
        },
        .{
            "file:///dvddisc/ADV_OBJ/b.xmf",
            \\<Application xmlns="http://www.dvdforum.org/2005/HDDVDVideo/Manifest" id="b">
            \\ <Region x="0" y="0" width="100" height="100"/>
            \\ <Markup src="b.xmu"/>
            \\</Application>
        },
        .{ "file:///dvddisc/ADV_OBJ/b.xmu", "<root xmlns=\"http://www.dvdforum.org/2005/ihd\"><body/></root>" },
    } };
    var e = engine.Engine.init(gpa, 1920, 1080, 60);
    defer e.deinit();
    e.setScene(try Apps.create(gpa, .{ .pl = &pl, .loader = .{ .ctx = &files, .read = Files.read }, .menu_language = "en" }, 1920, 1080), 0);
    const s: *Apps = @ptrCast(@alignCast(e.scene.?.ctx));
    var now: i64 = 0;
    var t: u64 = 0;
    const step = struct {
        fn f(eng: *engine.Engine, n: *i64, time: *u64) void {
            n.* += 16_700;
            time.* += 1;
            _ = eng.step(n.*, time.*);
        }
    }.f;
    try e.post(.{ .title_begin = .{ .title = 0, .duration = 3600 } });
    _ = e.step(now, 0);
    const pa = s.records.items[0];
    const late = s.records.items[1];
    const sc = pa.script.?;
    try testing.expect(pa.active() and !late.valid);
    for (0..4) |_| step(&e, &now, &t);
    // Up: script cancels the markup's navigation; down: the markup moves the focus to a.
    try e.post(.{ .key_down = keys.up });
    step(&e, &now, &t);
    const p = pa.page.?;
    try testing.expect(p.focused() == null);
    try e.post(.{ .key_down = keys.down });
    step(&e, &now, &t);
    try testing.expect(p.focused() != null);
    try e.post(.{ .key_down = keys.enter });
    step(&e, &now, &t);
    // The late application becomes valid but does not run (autorun false) until activated.
    while (t < 35) step(&e, &now, &t);
    try testing.expect(late.valid and !late.loaded);
    try js_testing.run(sc.cx,
        \\assertEq(log.join(","), "loaded:m.xmu,title_begin:t1:00:00:00:00,hello:1:a,key:38:app,key:40:app,key:13:a");
        \\var apps = advancedApplications; assertEq(apps.length, 2); assertEq(apps[0], thisAdvancedApplication);
        \\assertEq(apps[1].id, "late"); assertEq(apps[1].state, apps[1].STATE_INACTIVE); assertEq(apps[1].type, 2); assertEq(apps[0].type, 1);
        \\assertEq(zOrder, 0); assertEq(apps[1].zOrder, 1); assertEq(apps[1].autorun, false);
        \\assertThrows(function () { apps[0].inactivate(); }, "HDDVD_E_INVALIDOPERATION");
        \\apps[1].activate();
        \\assertEq(apps[1].state, apps[1].STATE_ACTIVE);
        \\moveToTop(); assertEq(zOrder, 1); assertEq(apps[1].zOrder, 0);
        \\apps[1].moveAfter(apps[0]); assertEq(apps[1].zOrder, 0);
        \\apps[1].moveBefore(apps[0]); assertEq(apps[1].zOrder, 1); assertEq(zOrder, 0);
        \\// The Animated Property API.
        \\var b = document.getElementById("b"); assert(b === document.b, "named element");
        \\b.style.setProperty("x", "10px"); assertEq(b.style.x, "10px"); b.style.y = "20px";
        \\assertThrows(function () { b.style.setProperty("x", "nonsense"); }, "HDDVD_E_ARGUMENT");
        \\assertThrows(function () { b.style.setProperty("position", "static"); }, "HDDVD_E_ARGUMENT");
        \\assertThrows(function () { b.style.getProperty("bogus"); }, "HDDVD_E_ARGUMENT");
        \\b.style.animateProperty("opacity", "0;1", 1);
        \\assertEq(b.state.focused, "false"); b.state.focused = "true"; assertEq(b.state.focused, "true");
        \\assertEq(b.core.id, "b"); assertEq(document.getProperties(b, "http://www.dvdforum.org/2005/ihd#style").namespace, "http://www.dvdforum.org/2005/ihd#style");
    , "check.js");
    step(&e, &now, &t);
    const b = Page.elemOf(p.doc.getElementById("b").?).?;
    try testing.expectEqual(@as(f32, 10), b.box.x);
    try testing.expectEqual(@as(f32, 100 + 0) - 80, b.box.y);
    try testing.expect(b.state.focused);
    try testing.expect(b.style.opacity < 0.2);
    try testing.expect(late.active());
    // Navigation is held while the focus is in global state; unsetProperty releases it.
    try e.post(.{ .key_down = keys.down });
    step(&e, &now, &t);
    try testing.expect(b.state.focused);
    try js_testing.run(sc.cx, "document.b.style.unsetProperty('x');", "unset.js");
    step(&e, &now, &t);
    try testing.expectEqual(@as(f32, 0), b.box.x);
}

const js_testing = @import("../script/js.zig").testing;
