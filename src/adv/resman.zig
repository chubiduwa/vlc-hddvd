//! File Cache resource management (HD DVD Vol. 1 §4.3.20, Vol. 3 §6.2.3.6): the Resource Information of the
//! playlist decides, along the Title Timeline, which resources are loaded into the File Cache and when.
//! No VLC dependency; the player supplies the data sources and the applications' states.
//!
//! - Title Associated resources (TitleResource) are valid in their own period; Application Associated ones
//!   (ApplicationResource, also under AdvancedSubtitleSegment) in their segment's; Playlist Application ones
//!   in every title but the First Play, which is their loading period (§4.3.19.6.2.2).
//! - A resource starts loading at loadingBegin (else at the start of its valid period). One multiplexed in the
//!   P-EVOB (multiplexed = an advanced_identifier) arrives through ADV_PCKs (the push model); otherwise, or if
//!   it is still missing when needed or after a jump, it is read from its source (the pull model).
//! - Several entries for one resource combine: used > ready > available > loading > non-exist.
//! - Network sources are chosen by the player's network throughput (§6.2.3.6).

const std = @import("std");
const xpl = @import("xpl.zig");
const aca = @import("aca.zig");
const uri = @import("uri.zig");
const advpck = @import("advpck.zig");
const filecache = @import("filecache.zig");

const State = filecache.State;
const Level = filecache.Level;

pub const Owner = union(enum) {
    title,
    /// An ApplicationSegment or AdvancedSubtitleSegment of the title, by index.
    app: u16,
    playlist,
};

/// One Resource Information entry of the current title, with its times resolved.
pub const Need = struct {
    /// The resource's URI (its name in the File Cache).
    uri: []const u8,
    /// Where to read it from (a network source may replace `uri`).
    fetch: []const u8,
    size: u64,
    priority: u32,
    level: Level,
    owner: Owner,
    /// Valid period on the Title Timeline (frames).
    begin: u64,
    end: u64,
    /// Start of loading.
    load_from: u64,
    multiplexed: ?u32,
};

pub const AppState = enum { invalid, valid, active };

/// What the application manager says about one application segment.
pub const App = struct {
    state: AppState = .invalid,
    /// Its resources may be loaded: autorun, or selected (§4.3.20.3.2).
    eligible: bool = true,
};

/// The applications' states before scripts can change them: valid in the segment's period, active there when
/// autorun; only autorun segments load their resources.
pub fn defaultApps(title: *const xpl.Title, t: u64, out: []App) void {
    for (title.apps, out) |a, *o| {
        const end = a.title_end orelse title.duration;
        const valid = t >= a.title_begin and t < end;
        o.* = .{ .state = if (!valid) .invalid else if (a.autorun) .active else .valid, .eligible = a.autorun };
    }
}

pub const Event = union(enum) {
    loaded: struct { uri: []const u8, bytes: usize, pushed: bool },
    failed: struct { uri: []const u8, err: anyerror },
    /// A multiplexed archive could not be used (still AACS-encrypted, or not an archive): read from the source.
    unusable: struct { uri: []const u8, name: []const u8 },
};

/// The player's side: reading a URI (disc, persistent storage, network) and hearing about loads.
pub const Source = struct {
    ctx: *anyopaque,
    /// The whole file, allocated with the manager's allocator.
    fetch: *const fn (ctx: *anyopaque, u: []const u8) anyerror![]u8,
    event: *const fn (ctx: *anyopaque, e: Event) void,
};

pub const Manager = struct {
    gpa: std.mem.Allocator,
    cache: filecache.FileCache,
    needs: std.ArrayList(Need) = .empty,
    first_play: bool = false,
    /// The player's network throughput (kbps) for NetworkSource selection.
    throughput_kbps: u32 = 0,
    /// Resources whose loading failed in this title (not retried until the title changes).
    failed: std.StringHashMapUnmanaged(void) = .empty,

    pub fn init(gpa: std.mem.Allocator) Manager {
        return .{ .gpa = gpa, .cache = filecache.FileCache.init(gpa, filecache.data_cache_size) };
    }

    pub fn deinit(m: *Manager) void {
        m.clearFailed();
        m.failed.deinit(m.gpa);
        m.needs.deinit(m.gpa);
        m.cache.deinit();
    }

    fn clearFailed(m: *Manager) void {
        var it = m.failed.keyIterator();
        while (it.next()) |k| m.gpa.free(k.*);
        m.failed.clearRetainingCapacity();
    }

    /// Change System Configuration (§4.3.22.2 step 5): the Streaming Buffer is taken from the Data Cache and
    /// everything cached is withdrawn.
    pub fn configure(m: *Manager, pl: *const xpl.Playlist) void {
        const sb = @as(u64, pl.streaming_buffer_kb) * 1024;
        m.cache.reset(filecache.data_cache_size -| sb);
        m.needs.clearRetainingCapacity();
        m.clearFailed();
    }

    /// The Playlist Application for the menu language (else the playlist's default language, else the first).
    pub fn playlistApp(pl: *const xpl.Playlist, menu_language: []const u8) ?*const xpl.PlaylistApp {
        for (pl.apps) |*a| if (std.ascii.eqlIgnoreCase(a.language, menu_language)) return a;
        for (pl.apps) |*a| if (std.ascii.eqlIgnoreCase(a.language, pl.default_language)) return a;
        return if (pl.apps.len > 0) &pl.apps[0] else null;
    }

    /// The resources of a new title (`first_play` for the FirstPlayTitle). What it does not use becomes
    /// available, with the new title's priorities (§4.3.20.3.1).
    pub fn setTitle(m: *Manager, pl: *const xpl.Playlist, title: *const xpl.Title, first_play: bool, menu_language: []const u8) !void {
        m.needs.clearRetainingCapacity();
        m.clearFailed();
        m.first_play = first_play;
        const dur = title.duration;
        if (playlistApp(pl, menu_language)) |app| for (app.resources) |r| {
            try m.add(r, .app, .playlist, 0, dur, 0);
        };
        for (title.resources) |r| {
            try m.add(r, .title, .title, r.title_begin, r.title_end orelse dur, r.loading_begin orelse r.title_begin);
        }
        for (title.apps, 0..) |a, i| {
            const end = a.title_end orelse dur;
            for (a.resources) |r| {
                try m.add(r, .app, .{ .app = @intCast(i) }, a.title_begin, end, r.loading_begin orelse a.title_begin);
            }
        }
        for (m.cache.resources.items) |r| {
            if (m.needOf(r.uri) == null) r.state = .available;
        }
    }

    fn add(m: *Manager, r: xpl.Resource, level: Level, owner: Owner, begin: u64, end: u64, load_from: u64) !void {
        if (r.src.len == 0) return;
        try m.needs.append(m.gpa, .{
            .uri = r.src,
            .fetch = xpl.selectSource(r.src, r.network_sources, m.throughput_kbps),
            .size = r.size,
            .priority = r.priority,
            .level = level,
            .owner = owner,
            .begin = begin,
            .end = @max(end, begin),
            .load_from = @min(load_from, begin),
            .multiplexed = r.multiplexed,
        });
    }

    fn needOf(m: *const Manager, u: []const u8) ?*const Need {
        for (m.needs.items) |*n| if (uri.eql(n.uri, u)) return n;
        return null;
    }

    /// What one entry asks for at title time `t`.
    fn want(m: *const Manager, n: *const Need, t: u64, apps: []const App) State {
        const in_period = t >= n.begin and t < n.end;
        const loading = t >= n.load_from and t < n.begin;
        switch (n.owner) {
            .playlist => return if (m.first_play) .loading else .used,
            .title => {
                if (in_period) {
                    for (apps) |a| if (a.state == .active) return .used;
                    return .ready;
                }
                return if (loading) .loading else .available;
            },
            .app => |i| {
                const a: App = if (i < apps.len) apps[i] else .{};
                if (!a.eligible and a.state != .active) return .available;
                if (in_period) return if (a.state == .active) .used else .ready;
                return if (loading) .loading else .available;
            },
        }
    }

    /// Brings the File Cache to what title time `t` needs: states, reservations and loads from the sources.
    /// `jumped`: the timeline has just jumped here, so multiplexed resources cannot be waited for.
    pub fn update(m: *Manager, t: u64, apps: []const App, jumped: bool, src: Source) void {
        for (m.needs.items, 0..) |*n, i| {
            // Each resource once, combining all its entries.
            if (for (m.needs.items[0..i]) |*p| {
                if (uri.eql(p.uri, n.uri)) break true;
            } else false) continue;
            var st: State = .non_exist;
            var pull = false;
            var level: Level = .app;
            var prio: u32 = std.math.maxInt(u32);
            var size: u64 = 0;
            for (m.needs.items[i..]) |*o| {
                if (!uri.eql(o.uri, n.uri)) continue;
                const w = m.want(o, t, apps);
                st = st.max(w);
                // Wait for a multiplexed copy only while loading in sequence.
                if (w != .available and w != .non_exist and (o.multiplexed == null or jumped or w != .loading)) pull = true;
                if (o.level == .title) level = .title;
                prio = @min(prio, o.priority);
                size = @max(size, o.size);
            }
            const existing = m.cache.find(n.uri);
            if (st == .available or st == .non_exist) {
                if (existing) |r| {
                    if (r.loaded()) r.state = .available else m.cache.discard(r);
                }
                continue;
            }
            if (m.failed.contains(n.uri)) continue;
            const r = existing orelse m.cache.reserve(n.uri, size, level, prio) catch |err| {
                m.fail(n.uri, err, src);
                continue;
            };
            r.level = level;
            r.priority = prio;
            if (r.loaded()) {
                r.state = if (st == .loading) .ready else st;
                continue;
            }
            r.state = .loading;
            if (pull) {
                m.pullInto(r, n.fetch, src);
                if (r.loaded()) r.state = if (st == .loading) .ready else st;
            }
        }
        // Resources no entry of this title names.
        var i: usize = 0;
        while (i < m.cache.resources.items.len) {
            const r = m.cache.resources.items[i];
            if (m.needOf(r.uri) == null) {
                if (!r.loaded()) {
                    m.cache.discard(r);
                    continue;
                }
                r.state = .available;
            }
            i += 1;
        }
    }

    fn fail(m: *Manager, u: []const u8, err: anyerror, src: Source) void {
        src.event(src.ctx, .{ .failed = .{ .uri = u, .err = err } });
        if (m.failed.contains(u)) return;
        const k = m.gpa.dupe(u8, u) catch return;
        m.failed.put(m.gpa, k, {}) catch m.gpa.free(k);
    }

    fn pullInto(m: *Manager, r: *filecache.Resource, from: []const u8, src: Source) void {
        const data = src.fetch(src.ctx, from) catch |err| return m.fail(r.uri, err, src);
        const n = data.len;
        m.cache.store(r, data) catch |err| return m.fail(r.uri, err, src);
        src.event(src.ctx, .{ .loaded = .{ .uri = r.uri, .bytes = n, .pushed = false } });
    }

    /// An archive reassembled from the Advanced stream (takes ownership). It fills the resource multiplexed
    /// under its advanced_identifier, unless that is already loaded or not wanted in this title.
    pub fn pushed(m: *Manager, file: advpck.File, src: Source) void {
        var keep = false;
        defer if (!keep) file.deinit(m.gpa);
        var match: ?*const Need = null;
        for (m.needs.items) |*n| {
            if (n.multiplexed != @as(?u32, file.id)) continue;
            if (match == null or std.ascii.eqlIgnoreCase(uri.fileName(n.uri), file.name)) match = n;
        }
        const n = match orelse return;
        const r = m.cache.find(n.uri) orelse return; // not reserved: not in its loading period
        if (r.loaded()) return;
        // A copy still under AACS (rips decrypt the files on the disc, not the packs) cannot be used; the same
        // file is on the disc (§6.5.4), so it is read from there.
        var a = aca.parse(m.gpa, file.data) catch null;
        const bad = if (a) |*x| blk: {
            defer x.deinit();
            break :blk x.encrypted();
        } else true;
        if (bad or file.scrambled) {
            src.event(src.ctx, .{ .unusable = .{ .uri = n.uri, .name = file.name } });
            m.pullInto(r, n.fetch, src);
            if (r.loaded()) r.state = .ready;
            return;
        }
        keep = true;
        const len = file.data.len;
        m.gpa.free(file.name);
        m.cache.store(r, file.data) catch |err| return m.fail(n.uri, err, src);
        r.state = .ready;
        src.event(src.ctx, .{ .loaded = .{ .uri = n.uri, .bytes = len, .pushed = true } });
    }

    /// A file of the Resource Area by its original URI (a resource, or a file in a resource archive).
    pub fn lookup(m: *const Manager, u: []const u8) ?[]const u8 {
        return m.cache.lookup(u);
    }

    /// True once every URI in `uris` is in the File Cache (a manifest's Resource list, §6.2.4.2).
    pub fn allLoaded(m: *const Manager, uris: []const []const u8) bool {
        for (uris) |u| {
            const r = m.cache.find(u) orelse return false;
            if (!r.loaded()) return false;
        }
        return true;
    }
};

// ---- tests --------------------------------------------------------------------------------------------------

const testing = std.testing;

const FakeSource = struct {
    files: []const struct { []const u8, []const u8 },
    fetched: std.ArrayList([]const u8) = .empty,
    events: std.ArrayList(std.meta.Tag(Event)) = .empty,

    fn source(f: *FakeSource) Source {
        return .{ .ctx = f, .fetch = fetch, .event = event };
    }

    fn fetch(ctx: *anyopaque, u: []const u8) anyerror![]u8 {
        const f: *FakeSource = @ptrCast(@alignCast(ctx));
        try f.fetched.append(testing.allocator, u);
        for (f.files) |e| if (std.mem.eql(u8, e[0], u)) return testing.allocator.dupe(u8, e[1]);
        return error.FileNotFound;
    }

    fn event(ctx: *anyopaque, e: Event) void {
        const f: *FakeSource = @ptrCast(@alignCast(ctx));
        f.events.append(testing.allocator, e) catch {};
    }

    fn deinit(f: *FakeSource) void {
        f.fetched.deinit(testing.allocator);
        f.events.deinit(testing.allocator);
    }
};

/// A minimal valid archive with one plain file.
fn testAca(name: []const u8, content: []const u8) ![]u8 {
    const gpa = testing.allocator;
    var d: std.ArrayList(u8) = .empty;
    errdefer d.deinit(gpa);
    try d.appendSlice(gpa, "HDDVDACA\x00\x10\x00\x01\x00\x01");
    try d.appendNTimes(gpa, 0, 32 - d.items.len);
    try d.appendNTimes(gpa, 0, 14);
    d.items[d.items.len - 1] = @intCast(name.len);
    try d.appendSlice(gpa, name);
    try d.appendNTimes(gpa, 0, 32);
    std.mem.writeInt(u32, d.items[32..36], @intCast(d.items.len), .big);
    std.mem.writeInt(u32, d.items[36..40], @intCast(content.len), .big);
    try d.appendSlice(gpa, content);
    return d.toOwnedSlice(gpa);
}

const test_xpl =
    \\<Playlist xmlns="http://www.dvdforum.org/2005/HDDVDVideo/Playlist">
    \\ <TitleSet timeBase="60fps" defaultLanguage="en">
    \\  <FirstPlayTitle titleDuration="00:00:10:00"/>
    \\  <Title titleNumber="1" titleDuration="00:10:00:00">
    \\   <ApplicationSegment src="file:///dvddisc/ADV_OBJ/a.aca/a.xmf" titleTimeBegin="00:01:00:00" titleTimeEnd="00:02:00:00">
    \\    <ApplicationResource src="file:///dvddisc/ADV_OBJ/a.aca" size="100" priority="2" loadingBegin="00:00:30:00" multiplexed="5"/>
    \\   </ApplicationSegment>
    \\   <ApplicationSegment src="file:///dvddisc/ADV_OBJ/b.aca/b.xmf" titleTimeBegin="00:03:00:00" titleTimeEnd="00:04:00:00" autorun="false">
    \\    <ApplicationResource src="file:///dvddisc/ADV_OBJ/b.aca" size="100" priority="1" multiplexed="false"/>
    \\   </ApplicationSegment>
    \\   <TitleResource src="file:///dvddisc/ADV_OBJ/t.png" size="10" priority="1" titleTimeBegin="00:05:00:00" titleTimeEnd="00:06:00:00" multiplexed="false"/>
    \\  </Title>
    \\  <PlaylistApplication src="file:///dvddisc/ADV_OBJ/m.aca/m.xmf" language="fr">
    \\   <PlaylistApplicationResource src="file:///dvddisc/ADV_OBJ/m-fr.aca" multiplexed="false"/>
    \\  </PlaylistApplication>
    \\  <PlaylistApplication src="file:///dvddisc/ADV_OBJ/m.aca/m.xmf" language="en">
    \\   <PlaylistApplicationResource src="file:///dvddisc/ADV_OBJ/m.aca" size="50" multiplexed="1"/>
    \\  </PlaylistApplication>
    \\ </TitleSet>
    \\</Playlist>
;

test "resources follow the Title Timeline" {
    const gpa = testing.allocator;
    var pl = try xpl.parse(gpa, test_xpl);
    defer pl.deinit();
    const a_aca = try testAca("a.xmf", "<A/>");
    defer gpa.free(a_aca);
    const m_aca = try testAca("m.xmf", "<M/>");
    defer gpa.free(m_aca);
    var fs: FakeSource = .{ .files = &.{
        .{ "file:///dvddisc/ADV_OBJ/a.aca", a_aca },
        .{ "file:///dvddisc/ADV_OBJ/m.aca", m_aca },
        .{ "file:///dvddisc/ADV_OBJ/t.png", "PNG" },
    } };
    defer fs.deinit();
    const src = fs.source();
    var m = Manager.init(gpa);
    defer m.deinit();
    m.configure(&pl);
    var apps: [2]App = undefined;

    // First Play: the English Playlist Application's archive is multiplexed: reserved, waited for.
    try m.setTitle(&pl, &pl.first_play.?, true, "en");
    m.update(0, &.{}, false, src);
    const mr = m.cache.find("file:///dvddisc/ADV_OBJ/m.aca").?;
    try testing.expectEqual(State.loading, mr.state);
    try testing.expectEqual(null, m.cache.find("file:///dvddisc/ADV_OBJ/m-fr.aca"));
    try testing.expectEqual(0, fs.fetched.items.len);

    // Title 1: the Playlist Application is due, so it is read from its source.
    const t1 = &pl.titles[0];
    try m.setTitle(&pl, t1, false, "en");
    defaultApps(t1, 0, &apps);
    m.update(0, &apps, false, src);
    try testing.expectEqual(State.used, m.cache.find("file:///dvddisc/ADV_OBJ/m.aca").?.state);
    try testing.expectEqualStrings("<M/>", m.lookup("file:///dvddisc/ADV_OBJ/m.aca/m.xmf").?);

    // 00:00:30: a.aca starts loading (multiplexed, so it waits for its packs) …
    defaultApps(t1, 30 * 60, &apps);
    m.update(30 * 60, &apps, false, src);
    try testing.expectEqual(State.loading, m.cache.find("file:///dvddisc/ADV_OBJ/a.aca").?.state);
    try testing.expectEqual(1, fs.fetched.items.len);
    // … which arrive: ready before its application starts, used while it runs.
    m.pushed(.{ .id = 5, .name = try gpa.dupe(u8, "a.aca"), .data = try gpa.dupe(u8, a_aca), .scrambled = false }, src);
    try testing.expectEqual(State.ready, m.cache.find("file:///dvddisc/ADV_OBJ/a.aca").?.state);
    try testing.expectEqualStrings("<A/>", m.lookup("file:///dvddisc/ADV_OBJ/a.aca/a.xmf").?);
    defaultApps(t1, 90 * 60, &apps);
    m.update(90 * 60, &apps, false, src);
    try testing.expectEqual(State.used, m.cache.find("file:///dvddisc/ADV_OBJ/a.aca").?.state);
    try testing.expectEqual(1, fs.fetched.items.len);

    // After its period it is available (kept until the room is needed); b.aca never loads (not autorun).
    defaultApps(t1, 3 * 60 * 60 + 10, &apps);
    m.update(3 * 60 * 60 + 10, &apps, false, src);
    try testing.expectEqual(State.available, m.cache.find("file:///dvddisc/ADV_OBJ/a.aca").?.state);
    try testing.expectEqual(null, m.cache.find("file:///dvddisc/ADV_OBJ/b.aca"));

    // A jump into t.png's period loads it at once.
    defaultApps(t1, 5 * 60 * 60 + 1, &apps);
    m.update(5 * 60 * 60 + 1, &apps, true, src);
    try testing.expectEqual(State.ready, m.cache.find("file:///dvddisc/ADV_OBJ/t.png").?.state);
    try testing.expectEqualStrings("PNG", m.lookup("file:///dvddisc/ADV_OBJ/t.png").?);
    try testing.expect(m.allLoaded(&.{ "file:///dvddisc/ADV_OBJ/m.aca", "file:///dvddisc/ADV_OBJ/t.png" }));
    try testing.expect(!m.allLoaded(&.{"file:///dvddisc/ADV_OBJ/b.aca"}));
}

test "multiplexed copies that cannot be used, and failures" {
    const gpa = testing.allocator;
    var pl = try xpl.parse(gpa, test_xpl);
    defer pl.deinit();
    const a_aca = try testAca("a.xmf", "<A/>");
    defer gpa.free(a_aca);
    var fs: FakeSource = .{ .files = &.{.{ "file:///dvddisc/ADV_OBJ/a.aca", a_aca }} };
    defer fs.deinit();
    const src = fs.source();
    var m = Manager.init(gpa);
    defer m.deinit();
    m.configure(&pl);
    var apps: [2]App = undefined;
    const t1 = &pl.titles[0];
    try m.setTitle(&pl, t1, false, "en");
    defaultApps(t1, 30 * 60, &apps);
    m.update(30 * 60, &apps, false, src);
    // m.aca is missing on the "disc": failed once, not retried.
    try testing.expectEqual(1, fs.fetched.items.len);
    m.update(30 * 60, &apps, false, src);
    try testing.expectEqual(1, fs.fetched.items.len);

    // An encrypted multiplexed copy: the disc copy is read instead.
    m.pushed(.{ .id = 5, .name = try gpa.dupe(u8, "a.aca"), .data = try gpa.dupe(u8, a_aca), .scrambled = true }, src);
    try testing.expectEqualStrings("<A/>", m.lookup("file:///dvddisc/ADV_OBJ/a.aca/a.xmf").?);
    try testing.expectEqual(2, fs.fetched.items.len);
    var unusable = false;
    for (fs.events.items) |e| unusable = unusable or e == .unusable;
    try testing.expect(unusable);
    // An archive for an id this title does not use is dropped.
    m.pushed(.{ .id = 77, .name = try gpa.dupe(u8, "z.aca"), .data = try gpa.dupe(u8, a_aca), .scrambled = false }, src);
}
