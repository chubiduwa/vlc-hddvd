//! The Data Access Manager (HD DVD Vol. 1 §4.3.8) and the File Cache Manager's player side: reading URIs from
//! the disc, the File Cache, the persistent storage (in memory) and network servers (through VLC's own
//! access modules), the File Cache resources (resman.zig) and the archives multiplexed in the P-EVOB
//! (advpck.zig).

const std = @import("std");
const vlc = @import("vlc");
const vfs = @import("../vfs.zig");
const vlcio = @import("../vlcio.zig");
const xpl = @import("xpl.zig");
const aca = @import("aca.zig");
const uri = @import("uri.zig");
const advpck = @import("advpck.zig");
const resman = @import("resman.zig");
const pstore = @import("pstore.zig");
const manifest = @import("manifest.zig");

const gpa = std.heap.c_allocator;

extern fn hddvd_now_us() i64;
extern fn hddvd_inherit_string(obj: *vlc.vlc_object_t, name: [*:0]const u8) ?[*:0]u8;
extern fn hddvd_free(p: ?*anyopaque) void;

/// Largest file read from a network server.
const max_network_file = 64 * 1024 * 1024;

fn log(obj: *vlc.vlc_object_t, prio: c_int, src: std.builtin.SourceLocation, comptime fmt: [*:0]const u8, args: anytype) void {
    @call(.auto, vlc.vlc_Log, .{ obj, prio, "hddvd", src.file, @as(c_uint, src.line), src.fn_name, fmt } ++ args);
}

fn z(buf: []u8, s: []const u8) [*:0]const u8 {
    const n = @min(s.len, buf.len - 1);
    @memcpy(buf[0..n], s[0..n]);
    buf[n] = 0;
    return @ptrCast(buf.ptr);
}

pub const Access = struct {
    obj: *vlc.vlc_object_t,
    fs: *vfs.Fs,
    store: pstore.Store,
    res: resman.Manager,
    collector: advpck.Collector,
    /// The system parameter Menu Language (VLC's --menu-language), else the playlist's default language.
    menu_language: []u8,
    /// Applications of the current title already checked (debug), and the Playlist Application.
    checked: std.DynamicBitSetUnmanaged = .{},
    checked_playlist: bool = false,
    /// The demux thread updates the File Cache while the engine thread reads it.
    lock: vlc.vlc_mutex_t = undefined,

    pub fn create(obj: *vlc.vlc_object_t, fs: *vfs.Fs, disc: aca.DiscId) !*Access {
        const a = try gpa.create(Access);
        errdefer gpa.destroy(a);
        var lang: []u8 = &.{};
        if (hddvd_inherit_string(obj, "menu-language")) |s| {
            defer hddvd_free(s);
            lang = try gpa.dupe(u8, std.mem.span(s));
        }
        a.* = .{
            .obj = obj,
            .fs = fs,
            .store = try pstore.Store.init(gpa, aca.DiscId.guid(disc.provider_id), @bitCast(hddvd_now_us())),
            .res = resman.Manager.init(gpa),
            .collector = .{ .gpa = gpa },
            .menu_language = lang,
        };
        vlc.vlc_mutex_init(&a.lock);
        return a;
    }

    pub fn destroy(a: *Access) void {
        vlc.vlc_mutex_destroy(&a.lock);
        a.collector.deinit();
        a.res.deinit();
        a.store.deinit();
        a.checked.deinit(gpa);
        gpa.free(a.menu_language);
        gpa.destroy(a);
    }

    pub fn source(a: *Access) resman.Source {
        return .{ .ctx = a, .fetch = fetchCb, .event = eventCb };
    }

    fn fetchCb(ctx: *anyopaque, u: []const u8) anyerror![]u8 {
        const a: *Access = @ptrCast(@alignCast(ctx));
        return a.fetch(u);
    }

    /// Reads a file from where its URI points (not from the File Cache's Resource Area).
    pub fn fetch(a: *Access, u: []const u8) ![]u8 {
        if (!uri.valid(u)) return error.BadUri;
        const loc = uri.locate(u) orelse return error.UnsupportedUri;
        switch (loc.area) {
            .disc => {
                const path = try uri.percentDecode(gpa, loc.path);
                defer gpa.free(path);
                return (try a.fs.readFile(gpa, path)) orelse error.FileNotFound;
            },
            .filecache => {
                const path = try uri.percentDecode(gpa, std.mem.trimEnd(u8, loc.path, "/"));
                defer gpa.free(path);
                return gpa.dupe(u8, try a.res.cache.temp.read(path));
            },
            .required, .additional, .common_required, .common_additional => return gpa.dupe(u8, try a.store.read(u)),
            .network => {
                const url = try gpa.dupeSentinel(u8, u, 0);
                defer gpa.free(url);
                var f = try vlcio.File.open(a.obj, url);
                defer f.close();
                if (f.size > max_network_file) return error.FileTooBig;
                return f.readAll(gpa);
            },
        }
    }

    fn eventCb(ctx: *anyopaque, e: resman.Event) void {
        const a: *Access = @ptrCast(@alignCast(ctx));
        var b: [1024]u8 = undefined;
        switch (e) {
            .loaded => |l| log(a.obj, vlc.VLC_MSG_DBG, @src(), "File Cache: %s loaded (%u bytes%s)", .{
                z(&b, l.uri), @as(c_uint, @intCast(l.bytes)), if (l.pushed) " from the Advanced stream".ptr else "".ptr,
            }),
            .failed => |f| log(a.obj, vlc.VLC_MSG_ERR, @src(), "File Cache: cannot load %s (%s)", .{ z(&b, f.uri), @errorName(f.err).ptr }),
            .unusable => |x| log(a.obj, vlc.VLC_MSG_DBG, @src(), "File Cache: the multiplexed %s is encrypted; reading %s", .{
                z(b[0..256], x.name), z(b[256..], x.uri),
            }),
        }
    }

    /// Reads a file as an application does: from the File Cache's Resource Area under its original URI if it
    /// is there, else from the URI's own location (Annex Z.3). Archive members are only in the File Cache.
    /// Caller frees.
    pub fn read(a: *Access, u: []const u8) ![]u8 {
        vlc.vlc_mutex_lock(&a.lock);
        defer vlc.vlc_mutex_unlock(&a.lock);
        if (a.res.lookup(u)) |d| return gpa.dupe(u8, d);
        if (uri.archiveMember(u) != null) return error.FileNotFound;
        const d = try a.fetch(u);
        defer gpa.free(d);
        return gpa.dupe(u8, aca.unwrap(d));
    }

    // ---- the player's hooks -------------------------------------------------------------------------------

    /// Startup (§4.3.22.2 step 5): the Data Cache is configured for this playlist.
    pub fn configure(a: *Access, pl: *const xpl.Playlist) void {
        vlc.vlc_mutex_lock(&a.lock);
        defer vlc.vlc_mutex_unlock(&a.lock);
        a.res.configure(pl);
        a.checked_playlist = false;
    }

    fn language(a: *const Access, pl: *const xpl.Playlist) []const u8 {
        return if (a.menu_language.len > 0) a.menu_language else pl.default_language;
    }

    /// A title starts (null: the FirstPlayTitle) at title time `t`.
    pub fn startTitle(a: *Access, pl: *const xpl.Playlist, title: *const xpl.Title, first_play: bool, t: u64) void {
        vlc.vlc_mutex_lock(&a.lock);
        defer vlc.vlc_mutex_unlock(&a.lock);
        a.collector.reset();
        a.res.setTitle(pl, title, first_play, a.language(pl)) catch {};
        a.checked.resize(gpa, title.apps.len, false) catch {};
        a.checked.unsetAll();
        a.updateLocked(pl, title, first_play, t, t > 0);
    }

    /// The timeline jumped within the title.
    pub fn jumped(a: *Access, pl: *const xpl.Playlist, title: *const xpl.Title, first_play: bool, t: u64) void {
        vlc.vlc_mutex_lock(&a.lock);
        defer vlc.vlc_mutex_unlock(&a.lock);
        a.collector.reset();
        a.updateLocked(pl, title, first_play, t, true);
    }

    /// The title time on screen moved on.
    pub fn update(a: *Access, pl: *const xpl.Playlist, title: *const xpl.Title, first_play: bool, t: u64, jump: bool) void {
        vlc.vlc_mutex_lock(&a.lock);
        defer vlc.vlc_mutex_unlock(&a.lock);
        a.updateLocked(pl, title, first_play, t, jump);
    }

    fn updateLocked(a: *Access, pl: *const xpl.Playlist, title: *const xpl.Title, first_play: bool, t: u64, jump: bool) void {
        var apps_buf: [64]resman.App = undefined;
        const apps = apps_buf[0..@min(title.apps.len, apps_buf.len)];
        resman.defaultApps(title, t, apps);
        a.res.update(t, apps, jump, a.source());
        a.checkApps(pl, title, first_play, apps);
    }

    /// A sector read from the P-EVOB: Advanced packs are collected into archives for the File Cache.
    pub fn sector(a: *Access, s: []const u8) void {
        vlc.vlc_mutex_lock(&a.lock);
        defer vlc.vlc_mutex_unlock(&a.lock);
        const file = (a.collector.feed(s) catch null) orelse return;
        log(a.obj, vlc.VLC_MSG_DBG, @src(), "Advanced stream: %.*s complete (id %u, %u bytes)", .{
            @as(c_int, @intCast(file.name.len)), file.name.ptr, @as(c_uint, file.id), @as(c_uint, @intCast(file.data.len)),
        });
        a.res.pushed(file, a.source());
    }

    // ---- debug check: what each application needs resolves ------------------------------------------------

    fn checkApps(a: *Access, pl: *const xpl.Playlist, title: *const xpl.Title, first_play: bool, apps: []const resman.App) void {
        if (!first_play and !a.checked_playlist) if (resman.Manager.playlistApp(pl, a.language(pl))) |app| {
            a.checked_playlist = true;
            a.checkManifest(app.src, "Playlist Application");
        };
        for (title.apps, 0..) |app, i| {
            if (i >= apps.len or i >= a.checked.bit_length or a.checked.isSet(i)) continue;
            if (apps[i].state == .invalid) continue;
            a.checked.set(i);
            a.checkManifest(app.src, if (app.subtitle) "Advanced Subtitle" else "Application");
        }
    }

    /// Logs whether a manifest and everything it names can be read from the File Cache.
    fn checkManifest(a: *Access, src: []const u8, kind: [*:0]const u8) void {
        var b: [1024]u8 = undefined;
        const bytes = a.res.lookup(src) orelse {
            log(a.obj, vlc.VLC_MSG_WARN, @src(), "%s %s: manifest not in the File Cache", .{ kind, z(&b, src) });
            return;
        };
        var m = manifest.parse(gpa, bytes, src) catch |err| {
            log(a.obj, vlc.VLC_MSG_WARN, @src(), "%s %s: bad manifest (%s)", .{ kind, z(&b, src), @errorName(err).ptr });
            return;
        };
        defer m.deinit();
        var missing: u32 = 0;
        for (m.scripts) |s| missing += a.expect(s);
        if (m.markup) |s| missing += a.expect(s);
        for (m.resources) |s| if (a.res.cache.find(s) == null or !a.res.cache.find(s).?.loaded()) {
            log(a.obj, vlc.VLC_MSG_WARN, @src(), "  resource %s not loaded", .{z(&b, s)});
            missing += 1;
        };
        log(a.obj, vlc.VLC_MSG_DBG, @src(), "%s %s: %u scripts, %s markup, %u resources, %u missing", .{
            kind,                                         z(&b, src),
            @as(c_uint, @intCast(m.scripts.len)),         if (m.markup != null) "a".ptr else "no".ptr,
            @as(c_uint, @intCast(m.resources.len)),       missing,
        });
    }

    fn expect(a: *Access, u: []const u8) u32 {
        if (a.res.lookup(u) != null) return 0;
        var b: [1024]u8 = undefined;
        log(a.obj, vlc.VLC_MSG_WARN, @src(), "  %s not in the File Cache", .{z(&b, u)});
        return 1;
    }
};
