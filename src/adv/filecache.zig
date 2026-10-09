//! The File Cache (HD DVD Vol. 1 §4.3.9.2, §4.3.20): the Resource Area, where resources named in the playlist
//! are kept under their original URIs, and the API Managed Area ("temp", file:///filecache/), where scripts read
//! and write files. No VLC dependency.
//!
//! Memory is counted in 512-byte blocks (§4.3.20.5). The capacity is the Data Cache (64 MB minimum) less the
//! Streaming Buffer. An archive is stored whole, as one resource, and its files are reached through it
//! ("…/menu.aca/menu.xmu"). Room is made by discarding resources in the available state: Application
//! Associated ones before Title Associated ones, the lowest priority (highest number) first (§4.3.20.3.3).
//! Resources that are used, ready or loading are never discarded.

const std = @import("std");
const aca = @import("aca.zig");
const uri = @import("uri.zig");
const memfs = @import("memfs.zig");

pub const block_size = 512;
/// The minimum Data Cache (§4.3.9).
pub const data_cache_size = 64 * 1024 * 1024;
pub const max_resources = 2048;
pub const max_name = 255;

pub const Error = error{ CacheFull, TooManyResources, NameTooLong, OutOfMemory };

pub fn blocks(size: u64) u64 {
    return (size + block_size - 1) / block_size;
}

/// Resource states (§4.3.20.3.1), in the order "used > ready > available > loading > non-exist".
pub const State = enum(u3) {
    non_exist = 0,
    loading = 1,
    available = 2,
    ready = 3,
    used = 4,

    pub fn max(a: State, b: State) State {
        return if (@backingInt(a) >= @backingInt(b)) a else b;
    }
};

/// Title Associated resources are kept in preference to Application Associated ones (Playlist Application
/// resources count as Application Associated, §4.3.19.6.2.2).
pub const Level = enum(u1) { title = 0, app = 1 };

pub const Resource = struct {
    uri: []u8,
    /// Bytes reserved: the declared size while loading, the actual size once stored.
    reserved: u64,
    data: ?[]u8 = null,
    archive: ?aca.Archive = null,
    state: State = .loading,
    level: Level,
    priority: u32,
    /// Insertion order, to discard older resources first among equals.
    stamp: u64 = 0,

    pub fn loaded(r: *const Resource) bool {
        return r.data != null;
    }
};

pub const FileCache = struct {
    gpa: std.mem.Allocator,
    capacity_blocks: u64,
    resources: std.ArrayList(*Resource) = .empty,
    /// The API Managed Area. A file's owner is the application that wrote it.
    temp: memfs.Fs,
    clock: u64 = 0,

    pub fn init(gpa: std.mem.Allocator, capacity_bytes: u64) FileCache {
        return .{ .gpa = gpa, .capacity_blocks = capacity_bytes / block_size, .temp = memfs.Fs.init(gpa) };
    }

    pub fn deinit(c: *FileCache) void {
        c.clear();
        c.resources.deinit(c.gpa);
        c.temp.deinit();
    }

    /// Withdraws everything (Change System Configuration, §4.3.22.2 step 5) and sets the capacity.
    pub fn reset(c: *FileCache, capacity_bytes: u64) void {
        c.clear();
        c.temp.deinit();
        c.temp = memfs.Fs.init(c.gpa);
        c.capacity_blocks = capacity_bytes / block_size;
    }

    fn clear(c: *FileCache) void {
        for (c.resources.items) |r| c.free(r);
        c.resources.clearRetainingCapacity();
    }

    fn free(c: *FileCache, r: *Resource) void {
        if (r.archive) |*a| a.deinit();
        if (r.data) |d| c.gpa.free(d);
        c.gpa.free(r.uri);
        c.gpa.destroy(r);
    }

    pub fn usedBlocks(c: *const FileCache) u64 {
        var n: u64 = 0;
        for (c.resources.items) |r| n += blocks(r.reserved);
        return n + c.temp.sumFiles(blocks);
    }

    pub fn freeBlocks(c: *const FileCache) u64 {
        return c.capacity_blocks -| c.usedBlocks();
    }

    /// The resource stored under `u`, in any state.
    pub fn find(c: *const FileCache, u: []const u8) ?*Resource {
        for (c.resources.items) |r| if (uri.eql(r.uri, u)) return r;
        return null;
    }

    /// Discards available resources until `need` blocks are free. False if that is impossible.
    pub fn makeRoom(c: *FileCache, need: u64) bool {
        while (c.freeBlocks() < need) {
            var victim: ?usize = null;
            for (c.resources.items, 0..) |r, i| {
                if (r.state != .available and r.state != .non_exist) continue;
                const v = c.resources.items[
                    victim orelse {
                        victim = i;
                        continue;
                    }
                ];
                // App level before title level; then the highest priority number; then the oldest.
                const better = if (r.level != v.level)
                    @backingInt(r.level) > @backingInt(v.level)
                else if (r.priority != v.priority)
                    r.priority > v.priority
                else
                    r.stamp < v.stamp;
                if (better) victim = i;
            }
            c.discard(c.resources.items[victim orelse return false]);
        }
        return true;
    }

    /// Reserves room for a resource about to be loaded (§4.3.20.3.1 B: the room is guaranteed before loading).
    pub fn reserve(c: *FileCache, u: []const u8, size: u64, level: Level, priority: u32) Error!*Resource {
        if (c.find(u)) |r| return r;
        if (uri.fileName(u).len > max_name) return error.NameTooLong;
        if (c.resources.items.len >= max_resources) return error.TooManyResources;
        if (!c.makeRoom(blocks(size))) return error.CacheFull;
        const r = try c.gpa.create(Resource);
        errdefer c.gpa.destroy(r);
        r.* = .{ .uri = try c.gpa.dupe(u8, u), .reserved = size, .level = level, .priority = priority, .stamp = c.clock };
        errdefer c.gpa.free(r.uri);
        c.clock += 1;
        try c.resources.append(c.gpa, r);
        return r;
    }

    /// Stores a resource's data (taking ownership of `data`). An archive is parsed so its files can be found.
    pub fn store(c: *FileCache, r: *Resource, data: []u8) Error!void {
        const extra = blocks(data.len) -| blocks(r.reserved);
        if (extra > 0) {
            // Not discarding `r` itself while making room.
            const st = r.state;
            r.state = .used;
            defer r.state = st;
            if (!c.makeRoom(extra)) {
                c.gpa.free(data);
                return error.CacheFull;
            }
        }
        if (r.archive) |*a| a.deinit();
        r.archive = null;
        if (r.data) |d| c.gpa.free(d);
        r.data = data;
        r.reserved = data.len;
        if (std.ascii.endsWithIgnoreCase(r.uri, ".aca")) {
            r.archive = aca.parse(c.gpa, data) catch null;
        }
    }

    pub fn discard(c: *FileCache, r: *Resource) void {
        for (c.resources.items, 0..) |x, i| if (x == r) {
            _ = c.resources.orderedRemove(i);
            break;
        };
        c.free(r);
    }

    /// A file of the Resource Area by its original URI: a stored resource, or a file in a stored archive.
    pub fn lookup(c: *const FileCache, u: []const u8) ?[]const u8 {
        if (c.find(u)) |r| if (r.data) |d| return aca.unwrap(d);
        const m = uri.archiveMember(u) orelse return null;
        const r = c.find(m.archive) orelse return null;
        const a = &(r.archive orelse return null);
        return a.get(m.name);
    }

    // ---- the API Managed Area -------------------------------------------------------------------------------

    /// Writes a file in the API Managed Area (the path is relative to file:///filecache/). Error.CacheFull if
    /// the File Cache cannot hold it.
    pub fn tempWrite(c: *FileCache, path: []const u8, data: []const u8, owner: u32, now: i64) (Error || memfs.Error)!void {
        const old: u64 = if (c.temp.get(path)) |n| (if (n.dir) 0 else blocks(n.data.items.len)) else 0;
        if (!c.makeRoom(blocks(data.len) -| old)) return error.CacheFull;
        try c.temp.write(path, data, now, false);
        c.temp.get(path).?.owner = owner;
    }

    /// Discards the API Managed data an application wrote (it has become inactive, §4.3.20.4).
    pub fn discardOwner(c: *FileCache, owner: u32) void {
        var i: usize = 0;
        while (i < c.temp.nodes.count()) {
            const v = c.temp.nodes.values()[i];
            if (!v.dir and v.owner == owner) {
                c.temp.remove(c.temp.nodes.keys()[i], false) catch unreachable;
            } else i += 1;
        }
    }
};

// ---- tests --------------------------------------------------------------------------------------------------

const testing = std.testing;

fn fill(c: *FileCache, u: []const u8, size: usize, level: Level, prio: u32, state: State) !*Resource {
    const r = try c.reserve(u, size, level, prio);
    const d = try testing.allocator.alloc(u8, size);
    @memset(d, 'x');
    try c.store(r, d);
    r.state = state;
    return r;
}

test "block accounting and discard order" {
    var c = FileCache.init(testing.allocator, 10 * block_size);
    defer c.deinit();
    try testing.expectEqual(@as(u64, 1), blocks(1));
    try testing.expectEqual(@as(u64, 1), blocks(512));
    try testing.expectEqual(@as(u64, 2), blocks(513));

    _ = try fill(&c, "file:///dvddisc/t1", 2 * block_size, .title, 5, .available);
    _ = try fill(&c, "file:///dvddisc/a1", 2 * block_size, .app, 1, .available);
    _ = try fill(&c, "file:///dvddisc/a9", 2 * block_size, .app, 9, .available);
    _ = try fill(&c, "file:///dvddisc/used", 3 * block_size, .app, 99, .used);
    try testing.expectEqual(@as(u64, 1), c.freeBlocks());

    // 4 blocks: the app-level resource with the lowest priority goes first, then the next app-level one.
    _ = try fill(&c, "file:///dvddisc/new", 4 * block_size, .title, 0, .used);
    try testing.expect(c.find("file:///dvddisc/a9") == null);
    try testing.expect(c.find("file:///dvddisc/a1") == null);
    try testing.expect(c.find("file:///dvddisc/t1") != null);
    // Nothing available can make room for this: used resources stay.
    _ = c.find("file:///dvddisc/t1").?;
    try testing.expectError(error.CacheFull, c.reserve("file:///dvddisc/big", 5 * block_size, .title, 0));
    try testing.expect(c.find("file:///dvddisc/used") != null);
}

test "archive members and the API Managed Area" {
    const gpa = testing.allocator;
    var c = FileCache.init(gpa, data_cache_size);
    defer c.deinit();
    // A one-file archive.
    var d: std.ArrayList(u8) = .empty;
    defer d.deinit(gpa);
    try d.appendSlice(gpa, "HDDVDACA\x00\x10\x00\x01\x00\x01");
    try d.appendNTimes(gpa, 0, 32 - d.items.len);
    try d.appendNTimes(gpa, 0, 14);
    d.items[d.items.len - 1] = 5;
    try d.appendSlice(gpa, "a.xmu");
    try d.appendNTimes(gpa, 0, 32);
    std.mem.writeInt(u32, d.items[32..36], @intCast(d.items.len), .big);
    std.mem.writeInt(u32, d.items[36..40], 4, .big);
    try d.appendSlice(gpa, "<a/>");
    const r = try c.reserve("file:///dvddisc/ADV_OBJ/x.aca", d.items.len, .app, 0);
    try c.store(r, try gpa.dupe(u8, d.items));
    try testing.expectEqualStrings("<a/>", c.lookup("file:///dvddisc/ADV_OBJ/x.aca/a.xmu").?);
    try testing.expectEqual(null, c.lookup("file:///dvddisc/ADV_OBJ/x.aca/b.xmu"));
    try testing.expectEqual(null, c.lookup("file:///dvddisc/ADV_OBJ/y.aca/a.xmu"));

    try c.temp.makeDir("saves", 0);
    try c.tempWrite("saves/s.txt", "data", 7, 0);
    try c.tempWrite("other.txt", "x", 8, 0);
    try testing.expectEqual(@as(u64, blocks(d.items.len) + 2), c.usedBlocks());
    c.discardOwner(7);
    try testing.expect(!c.temp.exists("saves/s.txt"));
    try testing.expect(c.temp.exists("other.txt"));

    var small = FileCache.init(gpa, block_size);
    defer small.deinit();
    try testing.expectError(error.CacheFull, small.tempWrite("big", &(@as([600]u8, @splat(0))), 1, 0));
}
