//! Files as Advanced Applications see them (HD DVD Annex Z.3, Vol. 1 §4.3.20.4, Vol. 3 §10): the File Cache's
//! API Managed Area ("file:///filecache/", read-write), its Resource Area (read-only, by original URI), the disc
//! (read-only) and the persistent storage (the provider's area and the common area). Reads of a URI outside
//! the API Managed Area look in the Resource Area first. Files inside .aca archives are reached only through the
//! Resource Area and cannot be written.
//!
//! The player supplies the disc and the Resource Area (`Backend`); the API Managed Area and the persistent
//! storage are memfs trees it owns, used under its lock. No VLC dependency.

const std = @import("std");
const uri = @import("../uri.zig");
const memfs = @import("../memfs.zig");
const pstore = @import("../pstore.zig");
const aca = @import("../aca.zig");

pub const Error = error{ NotFound, NotPermitted, NoSpace, IsDirectory, NotDirectory, Exists, NotEmpty, BadPath, OutOfMemory };

pub const Stat = struct {
    dir: bool,
    size: u64,
    /// ms since the epoch.
    modified: i64,
};

/// The API Managed Area's size: what is left of the File Cache (Vol. 1 §4.3.20.4).
pub const default_temp_capacity = 64 * 1024 * 1024;

pub const Backend = struct {
    ctx: *anyopaque,
    /// A file of the Resource Area by its original URI (the bytes, borrowed while locked), or null.
    resource: *const fn (ctx: *anyopaque, u: []const u8) ?[]const u8,
    /// A file on the disc by path ("ADV_OBJ/x"), or null (allocated with `gpa`).
    disc_read: *const fn (ctx: *anyopaque, gpa: std.mem.Allocator, path: []const u8) anyerror!?[]u8,
    /// Names in a disc directory (files or directories), or error.NotFound.
    disc_list: *const fn (ctx: *anyopaque, gpa: std.mem.Allocator, path: []const u8, dirs: bool) anyerror![][]u8,
    disc_stat: *const fn (ctx: *anyopaque, path: []const u8) ?Stat,
    lock: ?*const fn (ctx: *anyopaque) void = null,
    unlock: ?*const fn (ctx: *anyopaque) void = null,
    /// Video is being read from the disc (and not paused): disc files cannot be accessed (Z.3).
    disc_busy: *const fn (ctx: *anyopaque) bool,
    now_ms: *const fn (ctx: *anyopaque) i64,
    /// Free File Cache bytes (DataCache.availableFileCacheSize): unused blocks and available resources.
    cache_available: ?*const fn (ctx: *anyopaque) u64 = null,
};

pub const Files = struct {
    gpa: std.mem.Allocator,
    temp: *memfs.Fs,
    temp_capacity: u64 = default_temp_capacity,
    store: *pstore.Store,
    backend: Backend,

    pub fn lock(f: *Files) void {
        if (f.backend.lock) |l| l(f.backend.ctx);
    }

    pub fn unlock(f: *Files) void {
        if (f.backend.unlock) |u| u(f.backend.ctx);
    }

    pub fn discBusy(f: *Files) bool {
        return f.backend.disc_busy(f.backend.ctx);
    }

    pub fn now(f: *Files) i64 {
        return f.backend.now_ms(f.backend.ctx);
    }

    pub const Where = enum { temp, disc, store, network, resource_only };

    /// Which area a URI is in (error.BadPath if it is not a file URI applications may use).
    pub fn where(u: []const u8) Error!Where {
        if (!uri.valid(u)) return error.BadPath;
        const loc = uri.locate(u) orelse return error.BadPath;
        return switch (loc.area) {
            .filecache => .temp,
            .disc => .disc,
            .required, .additional, .common_required, .common_additional => .store,
            .network => .network,
        };
    }

    /// The memfs path of an API Managed Area URI.
    fn tempPath(f: *Files, u: []const u8) Error![]u8 {
        const loc = uri.locate(u) orelse return error.BadPath;
        const p = try uri.percentDecode(f.gpa, std.mem.trim(u8, loc.path, "/"));
        if (!memfs.Fs.validPath(p)) {
            f.gpa.free(p);
            return error.BadPath;
        }
        return p;
    }

    fn discPath(f: *Files, u: []const u8) Error![]u8 {
        const loc = uri.locate(u) orelse return error.BadPath;
        return uri.percentDecode(f.gpa, std.mem.trim(u8, loc.path, "/"));
    }

    /// Reads a file as an application does: the Resource Area by original URI first, then its location
    /// (archived files only from the Resource Area). Caller frees.
    pub fn read(f: *Files, gpa: std.mem.Allocator, u: []const u8) Error![]u8 {
        const w = try where(u);
        f.lock();
        defer f.unlock();
        if (w != .temp) if (f.backend.resource(f.backend.ctx, u)) |d| return gpa.dupe(u8, d);
        if (uri.archiveMember(u) != null and w != .temp) return error.NotFound;
        return f.readAt(gpa, u, w);
    }

    /// Reads a file where its URI points (no Resource Area).
    fn readAt(f: *Files, gpa: std.mem.Allocator, u: []const u8, w: Where) Error![]u8 {
        switch (w) {
            .temp => {
                const p = try f.tempPath(u);
                defer f.gpa.free(p);
                const d = f.temp.read(p) catch |e| return mapFs(e);
                return gpa.dupe(u8, d);
            },
            .disc => {
                const p = try f.discPath(u);
                defer f.gpa.free(p);
                const d = (f.backend.disc_read(f.backend.ctx, gpa, p) catch return error.NotFound) orelse return error.NotFound;
                // Disc files may be AACS-wrapped archives.
                const inner = aca.unwrap(d);
                if (inner.len == d.len) return d;
                defer gpa.free(d);
                return gpa.dupe(u8, inner);
            },
            .store => {
                const d = f.store.read(u) catch |e| return mapStore(e);
                return gpa.dupe(u8, d);
            },
            .network, .resource_only => return error.NotPermitted,
        }
    }

    pub fn stat(f: *Files, u: []const u8) Error!Stat {
        const w = try where(u);
        f.lock();
        defer f.unlock();
        if (w != .temp) if (f.backend.resource(f.backend.ctx, u)) |d| return .{ .dir = false, .size = d.len, .modified = 0 };
        switch (w) {
            .temp => {
                const p = try f.tempPath(u);
                defer f.gpa.free(p);
                if (p.len == 0) return .{ .dir = true, .size = f.temp.usedBytes(""), .modified = 0 };
                const n = f.temp.get(p) orelse return error.NotFound;
                return .{ .dir = n.dir, .size = if (n.dir) f.temp.usedBytes(p) else n.data.items.len, .modified = n.modified };
            },
            .disc => {
                const p = try f.discPath(u);
                defer f.gpa.free(p);
                return f.backend.disc_stat(f.backend.ctx, p) orelse error.NotFound;
            },
            .store => {
                const t = f.store.resolve(u) catch |e| return mapStore(e);
                defer f.gpa.free(t.path);
                const n = t.dev.fs.get(t.path) orelse return if (t.dev.fs.isDir(t.path)) .{ .dir = true, .size = 0, .modified = 0 } else error.NotFound;
                return .{ .dir = n.dir, .size = if (n.dir) t.dev.fs.usedBytes(t.path) else n.data.items.len, .modified = n.modified };
            },
            .network, .resource_only => return error.NotPermitted,
        }
    }

    /// Files or directories in a directory, by name. Caller frees each name and the list.
    pub fn list(f: *Files, gpa: std.mem.Allocator, u: []const u8, dirs: bool) Error![][]u8 {
        const w = try where(u);
        f.lock();
        defer f.unlock();
        switch (w) {
            .temp => {
                const p = try f.tempPath(u);
                defer f.gpa.free(p);
                if (!f.temp.isDir(p)) return error.NotFound;
                const names = f.temp.list(f.gpa, p, dirs) catch |e| return mapFs(e);
                return dupNames(gpa, f.gpa, names);
            },
            .disc => {
                const p = try f.discPath(u);
                defer f.gpa.free(p);
                return f.backend.disc_list(f.backend.ctx, gpa, p, dirs) catch error.NotFound;
            },
            .store => {
                const names = f.store.list(u, dirs) catch |e| return switch (e) {
                    error.NotFound, error.NotADirectory => error.NotFound,
                    else => mapStoreAny(e),
                };
                return dupNames(gpa, f.store.gpa, names);
            },
            .network, .resource_only => return error.NotPermitted,
        }
    }

    fn dupNames(gpa: std.mem.Allocator, owner: std.mem.Allocator, names: [][]const u8) Error![][]u8 {
        defer owner.free(names);
        const out = try gpa.alloc([]u8, names.len);
        var n: usize = 0;
        errdefer {
            for (out[0..n]) |x| gpa.free(x);
            gpa.free(out);
        }
        for (names) |name| {
            out[n] = try gpa.dupe(u8, name);
            n += 1;
        }
        return out;
    }

    /// Writes a whole file (API Managed Area or persistent storage), creating its directory where allowed.
    pub fn write(f: *Files, u: []const u8, data: []const u8) Error!void {
        if (uri.archiveMember(u) != null) return error.NotPermitted;
        const w = try where(u);
        f.lock();
        defer f.unlock();
        switch (w) {
            .temp => {
                const p = try f.tempPath(u);
                defer f.gpa.free(p);
                if (p.len == 0) return error.IsDirectory;
                const old: u64 = if (f.temp.get(p)) |n| n.data.items.len else 0;
                if (f.temp.usedBytes("") - old + data.len > f.temp_capacity) return error.NoSpace;
                f.temp.write(p, data, f.now(), true) catch |e| return mapFs(e);
            },
            .store => {
                f.store.now = f.now();
                f.store.write(u, data) catch |e| return mapStore(e);
            },
            else => return error.NotPermitted,
        }
    }

    pub fn makeDir(f: *Files, u: []const u8) Error!void {
        const w = try where(u);
        f.lock();
        defer f.unlock();
        switch (w) {
            .store => {
                f.store.now = f.now();
                f.store.makeDir(u) catch |e| return mapStore(e);
            },
            .temp => {
                const p = try f.tempPath(u);
                defer f.gpa.free(p);
                f.temp.makeDir(p, f.now()) catch |e| return mapFs(e);
            },
            else => return error.NotPermitted,
        }
    }

    pub fn remove(f: *Files, u: []const u8, recursive: bool) Error!void {
        if (uri.archiveMember(u) != null) return error.NotPermitted;
        const w = try where(u);
        f.lock();
        defer f.unlock();
        switch (w) {
            .temp => {
                const p = try f.tempPath(u);
                defer f.gpa.free(p);
                if (p.len == 0) return error.NotPermitted;
                f.temp.remove(p, recursive) catch |e| return mapFs(e);
            },
            .store => f.store.remove(u, recursive) catch |e| return mapStoreAny(e),
            else => return error.NotPermitted,
        }
    }

    pub fn setModified(f: *Files, u: []const u8, ms: i64) Error!void {
        if (uri.archiveMember(u) != null) return error.NotPermitted;
        const w = try where(u);
        f.lock();
        defer f.unlock();
        const n: *memfs.Node = switch (w) {
            .temp => blk: {
                const p = try f.tempPath(u);
                defer f.gpa.free(p);
                break :blk f.temp.get(p) orelse return error.NotFound;
            },
            .store => blk: {
                const t = f.store.resolve(u) catch |e| return mapStore(e);
                defer f.gpa.free(t.path);
                break :blk t.dev.fs.get(t.path) orelse return error.NotFound;
            },
            else => return error.NotPermitted,
        };
        if (n.dir) return error.IsDirectory;
        n.modified = ms;
    }

    /// Whether a file exists where its URI points (or in the Resource Area).
    pub fn exists(f: *Files, u: []const u8) bool {
        const s = f.stat(u) catch return false;
        return !s.dir;
    }

    /// Free bytes in the area of `u` (API Managed Area or the device of a persistent storage URI).
    pub fn free(f: *Files, u: []const u8) u64 {
        const w = where(u) catch return 0;
        f.lock();
        defer f.unlock();
        switch (w) {
            .temp => return f.temp_capacity -| f.temp.usedBytes(""),
            .store => {
                const t = f.store.resolve(u) catch return 0;
                defer f.gpa.free(t.path);
                return t.dev.capacity -| pstore.Store.usedBytes(t.dev);
            },
            else => return 0,
        }
    }
};

fn mapFs(e: memfs.Error) Error {
    return switch (e) {
        error.NotFound => error.NotFound,
        error.NotADirectory => error.NotDirectory,
        error.IsADirectory => error.IsDirectory,
        error.Exists => error.Exists,
        error.NotEmpty => error.NotEmpty,
        error.BadPath => error.BadPath,
        error.OutOfMemory => error.OutOfMemory,
    };
}

fn mapStore(e: pstore.Error) Error {
    return switch (e) {
        error.NotPermitted => error.NotPermitted,
        error.NoDevice, error.NotFound => error.NotFound,
        error.OutOfSpace => error.NoSpace,
        error.OutOfMemory => error.OutOfMemory,
        error.BadPath => error.BadPath,
    };
}

fn mapStoreAny(e: (pstore.Error || memfs.Error)) Error {
    return switch (e) {
        error.NotPermitted => error.NotPermitted,
        error.NoDevice, error.NotFound => error.NotFound,
        error.OutOfSpace => error.NoSpace,
        error.OutOfMemory => error.OutOfMemory,
        error.BadPath => error.BadPath,
        error.NotADirectory => error.NotDirectory,
        error.IsADirectory => error.IsDirectory,
        error.Exists => error.Exists,
        error.NotEmpty => error.NotEmpty,
    };
}

// ---- a test backend ---------------------------------------------------------------------------------------------

/// An in-memory disc and Resource Area for tests.
pub const TestBackend = struct {
    disc: memfs.Fs,
    resources: std.StringHashMapUnmanaged([]const u8) = .empty,
    busy: bool = false,
    time: i64 = 1_000_000,

    pub fn init(gpa: std.mem.Allocator) TestBackend {
        return .{ .disc = .init(gpa) };
    }

    pub fn deinit(b: *TestBackend) void {
        b.resources.deinit(b.disc.gpa);
        b.disc.deinit();
    }

    pub fn backend(b: *TestBackend) Backend {
        return .{ .ctx = b, .resource = resource, .disc_read = discRead, .disc_list = discList, .disc_stat = discStat, .disc_busy = discBusy, .now_ms = nowMs };
    }

    fn self(ctx: *anyopaque) *TestBackend {
        return @ptrCast(@alignCast(ctx));
    }
    fn resource(ctx: *anyopaque, u: []const u8) ?[]const u8 {
        return self(ctx).resources.get(u);
    }
    fn discRead(ctx: *anyopaque, gpa: std.mem.Allocator, p: []const u8) anyerror!?[]u8 {
        const d = self(ctx).disc.read(p) catch return null;
        return try gpa.dupe(u8, d);
    }
    fn discList(ctx: *anyopaque, gpa: std.mem.Allocator, p: []const u8, dirs: bool) anyerror![][]u8 {
        const b = self(ctx);
        if (!b.disc.isDir(p)) return error.NotFound;
        const names = try b.disc.list(b.disc.gpa, p, dirs);
        return Files.dupNames(gpa, b.disc.gpa, names);
    }
    fn discStat(ctx: *anyopaque, p: []const u8) ?Stat {
        const b = self(ctx);
        if (p.len == 0) return .{ .dir = true, .size = 0, .modified = 0 };
        const n = b.disc.get(p) orelse return null;
        return .{ .dir = n.dir, .size = n.data.items.len, .modified = n.modified };
    }
    fn discBusy(ctx: *anyopaque) bool {
        return self(ctx).busy;
    }
    fn nowMs(ctx: *anyopaque) i64 {
        return self(ctx).time;
    }
};

const tt = std.testing;

test "areas, the Resource Area first, permissions" {
    var b: TestBackend = .init(tt.allocator);
    defer b.deinit();
    var temp: memfs.Fs = .init(tt.allocator);
    defer temp.deinit();
    var store = try pstore.Store.init(tt.allocator, "11111111-2222-3333-4444-555555555555".*, 1);
    defer store.deinit();
    var f: Files = .{ .gpa = tt.allocator, .temp = &temp, .store = &store, .backend = b.backend() };

    try b.disc.write("ADV_OBJ/a.txt", "disc", 0, true);
    try b.resources.put(tt.allocator, "file:///dvddisc/ADV_OBJ/r.aca/x.xml", "member");
    const d = try f.read(tt.allocator, "file:///dvddisc/ADV_OBJ/a.txt");
    defer tt.allocator.free(d);
    try tt.expectEqualStrings("disc", d);
    const m = try f.read(tt.allocator, "file:///dvddisc/ADV_OBJ/r.aca/x.xml");
    defer tt.allocator.free(m);
    try tt.expectEqualStrings("member", m);
    try tt.expectError(error.NotFound, f.read(tt.allocator, "file:///dvddisc/ADV_OBJ/r.aca/y.xml"));
    try tt.expectError(error.NotPermitted, f.write("file:///dvddisc/ADV_OBJ/a.txt", "x"));

    try f.write("file:///filecache/dir/n.txt", "hello");
    const s = try f.stat("file:///filecache/dir/n.txt");
    try tt.expectEqual(@as(u64, 5), s.size);
    try tt.expectEqual(@as(i64, 1_000_000), s.modified);
    try tt.expect((try f.stat("file:///filecache/dir")).dir);
    const names = try f.list(tt.allocator, "file:///filecache/dir", false);
    defer {
        for (names) |n| tt.allocator.free(n);
        tt.allocator.free(names);
    }
    try tt.expectEqualStrings("n.txt", names[0]);
    try f.setModified("file:///filecache/dir/n.txt", 5);
    try tt.expectEqual(@as(i64, 5), (try f.stat("file:///filecache/dir/n.txt")).modified);
    try tt.expectError(error.NotEmpty, f.remove("file:///filecache/dir", false));
    try f.remove("file:///filecache/dir", true);
    try tt.expect(!f.exists("file:///filecache/dir/n.txt"));

    try f.write("file:///required/save.xml", "<a/>");
    const p = try f.read(tt.allocator, "file:///required/save.xml");
    defer tt.allocator.free(p);
    try tt.expectEqualStrings("<a/>", p);
    try tt.expect(f.free("file:///required/x") < pstore.required_capacity);
    try tt.expectError(error.BadPath, f.read(tt.allocator, "nonsense"));
}
