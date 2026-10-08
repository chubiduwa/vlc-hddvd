//! Persistent Storage (HD DVD Vol. 3 §10), kept in memory: what applications save lasts until the disc is
//! closed. No VLC dependency.
//!
//! Each device has a physical tree under "HD_DVD/": the Device Information File, the "common" area, and one
//! Provider ID directory per content provider holding Content ID directories. Applications reach their own
//! provider's area and the common area through logical URIs (uri.zig), with these limits (§10.3.1):
//! - directly under the provider area only files, or directories named by a GUID (Content IDs);
//! - at most one directory level under a Content ID directory and under "common";
//! - Information Files ("info.txt") only through the Persistent Storage Manager, never as files.

const std = @import("std");
const uri = @import("uri.zig");
const memfs = @import("memfs.zig");
const dom = @import("dom.zig");

pub const Error = error{ NotPermitted, NoDevice, NotFound, OutOfSpace, OutOfMemory, BadPath };

/// The minimum Required Persistent Storage (Vol. 1 §4.3.6.4).
pub const required_capacity = 128 * 1024 * 1024;
pub const max_info_keys = 1024;
pub const max_info_len = 1024;
pub const max_base_path = 256;

pub const Category = enum { required, additional };

pub const Device = struct {
    category: Category,
    /// Shown to applications ("SD Card"…).
    name: []const u8,
    /// Slot identifier ("slot0", "usb0"…).
    slot: []const u8,
    /// Base Path of an Additional device (assigned by applications), "" while undefined.
    base_path: std.ArrayList(u8) = .empty,
    capacity: u64,
    fs: memfs.Fs,
};

/// "XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX" with hex digits.
pub fn isGuid(s: []const u8) bool {
    if (s.len != 36) return false;
    for (s, 0..) |c, i| {
        if (i == 8 or i == 13 or i == 18 or i == 23) {
            if (c != '-') return false;
        } else if (!std.ascii.isHex(c)) return false;
    }
    return true;
}

/// Which part of a device a logical path addresses.
pub const InfoLevel = enum { device, provider, content };

pub const Store = struct {
    gpa: std.mem.Allocator,
    /// Provider ID from DISCID.DAT, or null if the disc uses none (then only the common areas exist).
    provider: ?[36]u8,
    devices: std.ArrayList(Device) = .empty,
    /// Milliseconds since the epoch, for file dates (set by the player).
    now: i64 = 0,
    /// For Device ID generation.
    prng: std.Random.DefaultPrng,

    pub fn init(gpa: std.mem.Allocator, provider: ?[36]u8, seed: u64) !Store {
        var s: Store = .{ .gpa = gpa, .provider = provider, .prng = .init(seed) };
        errdefer s.deinit();
        _ = try s.addDevice(.required, "Internal memory", "internal", required_capacity);
        return s;
    }

    pub fn deinit(s: *Store) void {
        for (s.devices.items) |*d| {
            d.fs.deinit();
            d.base_path.deinit(s.gpa);
        }
        s.devices.deinit(s.gpa);
    }

    /// Attaches a device; its Device Information File gets a device-id (§10.4).
    pub fn addDevice(s: *Store, category: Category, name: []const u8, slot: []const u8, capacity: u64) !*Device {
        try s.devices.append(s.gpa, .{ .category = category, .name = name, .slot = slot, .capacity = capacity, .fs = memfs.Fs.init(s.gpa) });
        const d = &s.devices.items[s.devices.items.len - 1];
        try d.fs.makeDir("HD_DVD/common", s.now);
        if (s.provider) |p| {
            const dir = try std.mem.concat(s.gpa, u8, &.{ "HD_DVD/", &p });
            defer s.gpa.free(dir);
            try d.fs.makeDir(dir, s.now);
        }
        var id: [16]u8 = undefined;
        s.prng.random().bytes(&id);
        id[6] = (id[6] & 0x0f) | 0x40; // version 4
        id[8] = (id[8] & 0x3f) | 0x80;
        const g = guidOf(id);
        try s.infoSet(d, "HD_DVD/info.txt", "device-id", &g);
        return d;
    }

    pub fn required(s: *Store) *Device {
        return &s.devices.items[0];
    }

    /// The Additional device with Base Path `bp`.
    pub fn byBasePath(s: *Store, bp: []const u8) ?*Device {
        for (s.devices.items) |*d| {
            if (d.category == .additional and std.mem.eql(u8, d.base_path.items, bp)) return d;
        }
        return null;
    }

    /// Assigns a Base Path to an Additional device (§10.6): a new one replaces the old; one already used by
    /// another device fails.
    pub fn assignBasePath(s: *Store, d: *Device, bp: []const u8) Error!void {
        if (d.category != .additional or bp.len == 0 or bp.len > max_base_path or std.mem.indexOfScalar(u8, bp, '/') != null) return error.NotPermitted;
        if (s.byBasePath(bp)) |o| if (o != d) return error.NotPermitted;
        d.base_path.clearRetainingCapacity();
        try d.base_path.appendSlice(s.gpa, bp);
    }

    pub fn usedBytes(d: *const Device) u64 {
        return d.fs.usedBytes("");
    }

    // ---- logical URIs -------------------------------------------------------------------------------------

    pub const Target = struct {
        dev: *Device,
        /// Physical path on the device (caller frees).
        path: []u8,
    };

    /// The device and physical path of a persistent storage URI, if applications may reach it.
    pub fn resolve(s: *Store, u: []const u8) Error!Target {
        const loc = uri.locate(u) orelse return error.BadPath;
        const dec = try uri.percentDecode(s.gpa, std.mem.trimEnd(u8, loc.path, "/"));
        defer s.gpa.free(dec);
        if (!memfs.Fs.validPath(dec)) return error.BadPath;
        const dev: *Device = switch (loc.area) {
            .required, .common_required => s.required(),
            .additional, .common_additional => s.byBasePath(loc.base_path) orelse return error.NoDevice,
            else => return error.NotPermitted,
        };
        var segs: [8][]const u8 = undefined;
        var n: usize = 0;
        var it = std.mem.splitScalar(u8, dec, '/');
        while (it.next()) |seg| {
            if (seg.len == 0) continue;
            if (n == segs.len) return error.NotPermitted;
            segs[n] = seg;
            n += 1;
        }
        const common = loc.area == .common_required or loc.area == .common_additional;
        if (common) {
            // common/<file>, common/<dir>/<file>.
            if (n > 2) return error.NotPermitted;
        } else {
            if (s.provider == null) return error.NotPermitted;
            if (n >= 1 and std.mem.eql(u8, segs[0], "info.txt")) return error.NotPermitted;
            if (n >= 2 and !isGuid(segs[0])) return error.NotPermitted;
            if (n >= 2 and n == 2 and std.mem.eql(u8, segs[1], "info.txt")) return error.NotPermitted;
            if (n > 3) return error.NotPermitted;
        }
        const root: []const u8 = if (common) "HD_DVD/common" else "HD_DVD/";
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(s.gpa);
        try out.appendSlice(s.gpa, root);
        if (!common) try out.appendSlice(s.gpa, &s.provider.?);
        for (segs[0..n]) |seg| {
            try out.append(s.gpa, '/');
            try out.appendSlice(s.gpa, seg);
        }
        return .{ .dev = dev, .path = try out.toOwnedSlice(s.gpa) };
    }

    pub fn read(s: *Store, u: []const u8) Error![]const u8 {
        const t = try s.resolve(u);
        defer s.gpa.free(t.path);
        return t.dev.fs.read(t.path) catch error.NotFound;
    }

    /// Writes a file; missing directories are created where the rules allow them.
    pub fn write(s: *Store, u: []const u8, data: []const u8) Error!void {
        const t = try s.resolve(u);
        defer s.gpa.free(t.path);
        const old: u64 = if (t.dev.fs.get(t.path)) |n| n.data.items.len else 0;
        if (usedBytes(t.dev) - old + data.len > t.dev.capacity) return error.OutOfSpace;
        t.dev.fs.write(t.path, data, s.now, true) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.BadPath,
        };
    }

    pub fn makeDir(s: *Store, u: []const u8) Error!void {
        const t = try s.resolve(u);
        defer s.gpa.free(t.path);
        t.dev.fs.makeDir(t.path, s.now) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.BadPath,
        };
    }

    pub fn remove(s: *Store, u: []const u8, recursive: bool) (Error || memfs.Error)!void {
        const t = try s.resolve(u);
        defer s.gpa.free(t.path);
        // The storage roots themselves stay.
        if (std.mem.eql(u8, t.path, "HD_DVD/common") or t.path.len == 7 + 36) return error.NotPermitted;
        try t.dev.fs.remove(t.path, recursive);
    }

    /// Files (`dirs` false) or directories in a directory, as applications see them (no Information Files, no
    /// directories they cannot reach). Caller frees the list.
    pub fn list(s: *Store, u: []const u8, dirs: bool) (Error || memfs.Error)![][]const u8 {
        const t = try s.resolve(u);
        defer s.gpa.free(t.path);
        const names = try t.dev.fs.list(s.gpa, t.path, dirs);
        const at_provider = !std.mem.startsWith(u8, t.path, "HD_DVD/common") and t.path.len == 7 + 36;
        const at_content = !std.mem.startsWith(u8, t.path, "HD_DVD/common") and t.path.len == 7 + 36 + 1 + 36;
        var n: usize = 0;
        for (names) |name| {
            if (!dirs and (at_provider or at_content) and std.mem.eql(u8, name, "info.txt")) continue;
            if (dirs and at_provider and !isGuid(name)) continue;
            names[n] = name;
            n += 1;
        }
        return s.gpa.realloc(names, n) catch names[0..n];
    }

    // ---- Information Files (§10.4) --------------------------------------------------------------------------

    /// The physical path of an Information File.
    pub fn infoPath(s: *const Store, buf: []u8, level: InfoLevel, content_id: []const u8) Error![]const u8 {
        return switch (level) {
            .device => "HD_DVD/info.txt",
            .provider => std.fmt.bufPrint(buf, "HD_DVD/{s}/info.txt", .{&(s.provider orelse return error.NotPermitted)}) catch error.BadPath,
            .content => if (!isGuid(content_id)) error.BadPath else std.fmt.bufPrint(buf, "HD_DVD/{s}/{s}/info.txt", .{ &(s.provider orelse return error.NotPermitted), content_id }) catch error.BadPath,
        };
    }

    /// A value from an Information File (caller frees), or null.
    pub fn infoGet(s: *Store, d: *Device, path: []const u8, key: []const u8) Error!?[]u8 {
        const bytes = d.fs.read(path) catch return null;
        var kv = try parseInfo(s.gpa, bytes);
        defer kv.deinit(s.gpa);
        for (kv.keys.items, kv.values.items) |k, v| if (std.mem.eql(u8, k, key)) return try s.gpa.dupe(u8, v);
        return null;
    }

    /// Sets a key (the file is created if needed). Applications may not write the Device Information File.
    pub fn infoSet(s: *Store, d: *Device, path: []const u8, key: []const u8, value: []const u8) Error!void {
        if (key.len > max_info_len or value.len > max_info_len) return error.BadPath;
        if (std.mem.indexOfAny(u8, key, "[]\n") != null or std.mem.indexOfAny(u8, value, "\"\n") != null) return error.BadPath;
        var kv = if (d.fs.read(path)) |bytes| try parseInfo(s.gpa, bytes) else |_| Info{};
        defer kv.deinit(s.gpa);
        const found = for (kv.keys.items, 0..) |k, i| {
            if (std.mem.eql(u8, k, key)) break i;
        } else null;
        if (found) |i| {
            kv.values.items[i] = value;
        } else {
            if (kv.keys.items.len >= max_info_keys - 1) return error.OutOfSpace;
            try kv.keys.append(s.gpa, key);
            try kv.values.append(s.gpa, value);
        }
        const text = try kv.serialize(s.gpa);
        defer s.gpa.free(text);
        d.fs.write(path, text, s.now, true) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.BadPath,
        };
    }

    // ---- startup (Vol. 1 §4.3.22.2, §10.3.2) ----------------------------------------------------------------

    pub const Found = struct { dev: *Device, number: u16 };

    /// The highest-numbered "<prefix>###.XPL" (VPLST or APLST) in this disc's Content ID directory on any
    /// device.
    pub fn findPlaylist(s: *Store, content_id: []const u8, prefix: []const u8) ?Found {
        const p = s.provider orelse return null;
        var buf: [128]u8 = undefined;
        const dir = std.fmt.bufPrint(&buf, "HD_DVD/{s}/{s}", .{ &p, content_id }) catch return null;
        var best: ?Found = null;
        for (s.devices.items) |*d| {
            const names = d.fs.list(s.gpa, dir, false) catch continue;
            defer s.gpa.free(names);
            for (names) |n| {
                if (n.len != 12 or !std.ascii.startsWithIgnoreCase(n, prefix) or !std.ascii.endsWithIgnoreCase(n, ".XPL")) continue;
                const num = std.fmt.parseInt(u16, n[5..8], 10) catch continue;
                if (best == null or num > best.?.number) best = .{ .dev = d, .number = num };
            }
        }
        return best;
    }
};

pub fn guidOf(id: [16]u8) [36]u8 {
    var out: [36]u8 = undefined;
    const hex = "0123456789ABCDEF";
    var o: usize = 0;
    for (id, 0..) |b, i| {
        if (i == 4 or i == 6 or i == 8 or i == 10) {
            out[o] = '-';
            o += 1;
        }
        out[o] = hex[b >> 4];
        out[o + 1] = hex[b & 15];
        o += 2;
    }
    return out;
}

/// The key/value pairs of an Information File or an Assignment Information File ("[key]"value"" lines, UTF-16
/// big-endian with a BOM). Slices point into `text`.
pub const Info = struct {
    text: []u8 = &.{},
    keys: std.ArrayList([]const u8) = .empty,
    values: std.ArrayList([]const u8) = .empty,

    pub fn deinit(i: *Info, gpa: std.mem.Allocator) void {
        gpa.free(i.text);
        i.keys.deinit(gpa);
        i.values.deinit(gpa);
    }

    pub fn get(i: *const Info, key: []const u8) ?[]const u8 {
        for (i.keys.items, i.values.items) |k, v| if (std.mem.eql(u8, k, key)) return v;
        return null;
    }

    /// UTF-16BE with a BOM.
    pub fn serialize(i: *const Info, gpa: std.mem.Allocator) ![]u8 {
        var utf8: std.ArrayList(u8) = .empty;
        defer utf8.deinit(gpa);
        for (i.keys.items, i.values.items) |k, v| {
            try utf8.append(gpa, '[');
            try utf8.appendSlice(gpa, k);
            try utf8.appendSlice(gpa, "]\"");
            try utf8.appendSlice(gpa, v);
            try utf8.appendSlice(gpa, "\"\r\n");
        }
        return utf16be(gpa, utf8.items);
    }
};

pub fn parseInfo(gpa: std.mem.Allocator, bytes: []const u8) !Info {
    var info: Info = .{};
    errdefer info.deinit(gpa);
    info.text = if (bytes.len >= 2 and bytes[0] == 0xfe and bytes[1] == 0xff)
        dom.utf16ToUtf8(gpa, bytes[2..], true) catch return error.OutOfMemory
    else
        try gpa.dupe(u8, bytes);
    var lines = std.mem.splitScalar(u8, info.text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len < 4 or line[0] != '[') continue;
        const close = std.mem.indexOfScalar(u8, line, ']') orelse continue;
        const rest = std.mem.trim(u8, line[close + 1 ..], " \t");
        if (rest.len < 2 or rest[0] != '"' or rest[rest.len - 1] != '"') continue;
        const key = line[1..close];
        const value = rest[1 .. rest.len - 1];
        if (key.len > max_info_len or value.len > max_info_len) continue;
        if (info.get(key) != null) continue; // the first one counts
        if (info.keys.items.len >= max_info_keys - 1) break;
        try info.keys.append(gpa, key);
        try info.values.append(gpa, value);
    }
    return info;
}

/// UTF-8 to UTF-16BE with a BOM (the persistent storage text format).
pub fn utf16be(gpa: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, &.{ 0xfe, 0xff });
    var it = (std.unicode.Utf8View.init(s) catch return error.OutOfMemory).iterator();
    while (it.nextCodepoint()) |cp| {
        if (cp >= 0x10000) {
            const v = cp - 0x10000;
            const hi: u16 = @intCast(0xd800 + (v >> 10));
            const lo: u16 = @intCast(0xdc00 + (v & 0x3ff));
            try out.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToBig(u16, hi)));
            try out.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToBig(u16, lo)));
        } else {
            try out.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToBig(u16, @intCast(cp))));
        }
    }
    return out.toOwnedSlice(gpa);
}

// ---- tests --------------------------------------------------------------------------------------------------

const testing = std.testing;
const provider_id = "67452301-AB89-EFCD-0123-456789ABCDEF".*;
const content = "BE209997-0C6C-11D3-97CF-00C04F8EEC55";

test "logical URIs and access rules" {
    var s = try Store.init(testing.allocator, provider_id, 1);
    defer s.deinit();
    try s.write("file:///required/" ++ content ++ "/data.txt", "save");
    try testing.expectEqualStrings("save", try s.read("file:///required/" ++ content ++ "/data.txt"));
    try testing.expectEqualStrings("save", try s.required().fs.read("HD_DVD/" ++ provider_id ++ "/" ++ content ++ "/data.txt"));
    try s.write("file:///required/top.txt", "t");
    try s.write("file:///required/" ++ content ++ "/savedata/data1.txt", "1");
    try s.write("file:///common/required/foo/bar.txt", "c");
    try testing.expectEqualStrings("c", try s.required().fs.read("HD_DVD/common/foo/bar.txt"));

    // Forbidden: Information Files, non-GUID directories under the provider, deeper directories.
    try testing.expectError(error.NotPermitted, s.read("file:///required/info.txt"));
    try testing.expectError(error.NotPermitted, s.read("file:///required/" ++ content ++ "/info.txt"));
    try testing.expectError(error.NotPermitted, s.write("file:///required/foo/bar.txt", "x"));
    try testing.expectError(error.NotPermitted, s.write("file:///required/" ++ content ++ "/a/b/c.txt", "x"));
    try testing.expectError(error.NotPermitted, s.write("file:///common/required/one/two/x.txt", "x"));
    try testing.expectError(error.NoDevice, s.write("file:///additional/usb1/x.txt", "x"));
    try testing.expectError(error.NotPermitted, s.read("file:///dvddisc/x"));

    const dirs = try s.list("file:///required/", true);
    defer testing.allocator.free(dirs);
    try testing.expectEqual(1, dirs.len);
    const files = try s.list("file:///required/" ++ content, false);
    defer testing.allocator.free(files);
    try testing.expectEqual(1, files.len);

    // An Additional device is reachable once it has a Base Path.
    const usb = try s.addDevice(.additional, "USB memory", "usb0", 1000);
    try s.assignBasePath(usb, "usb1");
    try s.write("file:///additional/usb1/" ++ content ++ "/x.txt", "u");
    try testing.expectError(error.OutOfSpace, s.write("file:///additional/usb1/big.txt", &(@as([1000]u8, @splat(0)))));
    const usb2 = try s.addDevice(.additional, "SD", "slot0", 1000);
    try testing.expectError(error.NotPermitted, s.assignBasePath(usb2, "usb1"));

    // A disc with no Provider ID has only the common areas.
    var none = try Store.init(testing.allocator, null, 2);
    defer none.deinit();
    try testing.expectError(error.NotPermitted, none.write("file:///required/x.txt", "x"));
    try none.write("file:///common/required/x.txt", "x");
}

test "Information Files and playlist search" {
    const gpa = testing.allocator;
    var s = try Store.init(gpa, provider_id, 3);
    defer s.deinit();
    const id = (try s.infoGet(s.required(), "HD_DVD/info.txt", "device-id")).?;
    defer gpa.free(id);
    try testing.expect(isGuid(id));

    var buf: [128]u8 = undefined;
    const p = try s.infoPath(&buf, .content, content);
    try s.infoSet(s.required(), p, "en-explanation", "Saved games");
    try s.infoSet(s.required(), p, "ja-icon", "icon_ja.png");
    try s.infoSet(s.required(), p, "en-explanation", "Bookmarks");
    const v = (try s.infoGet(s.required(), p, "en-explanation")).?;
    defer gpa.free(v);
    try testing.expectEqualStrings("Bookmarks", v);
    const raw = try s.required().fs.read(p);
    try testing.expectEqualSlices(u8, &.{ 0xfe, 0xff, 0, '[' }, raw[0..4]);

    var dup = try parseInfo(gpa, "[a]\"1\"\n[a]\"2\"\nbad line\n[usb1]\"103E8D2C-8230-42E1-9597-46F84CCE28C0\"");
    defer dup.deinit(gpa);
    try testing.expectEqualStrings("1", dup.get("a").?);
    try testing.expectEqualStrings("103E8D2C-8230-42E1-9597-46F84CCE28C0", dup.get("usb1").?);

    try testing.expectEqual(null, s.findPlaylist(content, "VPLST"));
    try s.write("file:///required/" ++ content ++ "/VPLST003.XPL", "<Playlist/>");
    try s.write("file:///required/" ++ content ++ "/VPLST001.XPL", "<Playlist/>");
    try testing.expectEqual(@as(u16, 3), s.findPlaylist(content, "VPLST").?.number);
    try testing.expectEqual(null, s.findPlaylist(content, "APLST"));
}
