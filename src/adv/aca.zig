//! Advanced Content archives (.aca, HD DVD Vol. 3 §6.5.4), the configuration file (ADV_OBJ/DISCID.DAT, §6.6) and
//! the AACS file wrapper found around ACA entries and playlists. No VLC dependency.
//!
//! On the discs each ACA entry (and the playlist of an AACS-protected disc) is wrapped: a 283-byte header
//! ("AACS", a type byte, a 24-bit plaintext size at offset 8, the file name + ".AACS" from offset 11), the data,
//! then a 4-byte trailer. Rips may rewrite an entry's offset and size to point at the data inside the wrapper,
//! which breaks its CRC; the CRC is therefore not checked.

const std = @import("std");

pub const Error = error{ BadAca, OutOfMemory };

pub const wrapper_header = 283;

/// The payload of an AACS-wrapped file, or `d` itself if it is not wrapped.
pub fn unwrap(d: []const u8) []const u8 {
    if (d.len < wrapper_header or !std.mem.eql(u8, d[0..4], "AACS")) return d;
    const size = std.mem.readInt(u24, d[8..11], .big);
    const name = std.mem.sliceTo(d[11..wrapper_header], 0);
    if (!std.mem.endsWith(u8, name, ".AACS")) return d;
    return d[wrapper_header..][0..@min(size, d.len - wrapper_header)];
}

pub const Entry = struct {
    name: []const u8,
    offset: u32,
    size: u32,
    mime: u8,
};

/// A parsed archive. Entry names point into the archive bytes.
pub const Archive = struct {
    gpa: std.mem.Allocator,
    data: []const u8,
    entries: []Entry,

    pub fn deinit(a: *Archive) void {
        a.gpa.free(a.entries);
    }

    /// An entry by name (case-sensitive, as URIs are), unwrapped.
    pub fn get(a: *const Archive, name: []const u8) ?[]const u8 {
        for (a.entries) |e| if (std.mem.eql(u8, e.name, name)) return a.content(e);
        return null;
    }

    pub fn content(a: *const Archive, e: Entry) []const u8 {
        const end = @min(a.data.len, @as(usize, e.offset) + e.size);
        const raw = a.data[@min(e.offset, end)..end];
        if (raw.len > 0 and raw[0] == 'A') return unwrap(raw);
        // An entry pointing past a wrapper header (rewritten offsets) is already the payload.
        return raw;
    }
};

pub fn parse(gpa: std.mem.Allocator, d: []const u8) Error!Archive {
    if (d.len < 32 or !std.mem.eql(u8, d[0..8], "HDDVDACA")) return error.BadAca;
    const n = std.mem.readInt(u16, d[12..14], .big);
    const entries = try gpa.alloc(Entry, n);
    errdefer gpa.free(entries);
    var p: usize = 32;
    for (entries) |*e| {
        if (p + 14 > d.len) return error.BadAca;
        const nl = d[p + 13];
        if (p + 14 + nl + 32 > d.len) return error.BadAca;
        e.* = .{
            .offset = std.mem.readInt(u32, d[p..][0..4], .big),
            .size = std.mem.readInt(u32, d[p + 4 ..][0..4], .big),
            .mime = d[p + 12],
            .name = d[p + 14 ..][0..nl],
        };
        p += 14 + @as(usize, nl) + 32;
    }
    return .{ .gpa = gpa, .data = d, .entries = entries };
}

/// ADV_OBJ/DISCID.DAT.
pub const DiscId = struct {
    disc_id: [16]u8,
    provider_id: [16]u8,
    content_id: [16]u8,
    /// SEARCH_FLG: 0 = also search persistent storage for a newer playlist.
    search_flag: u8,

    pub fn parse(d: []const u8) ?DiscId {
        if (d.len < 61 or !std.mem.eql(u8, d[0..12], "HDDVD-V_CONF")) return null;
        // CONFIG_ID (12 bytes), then the three 16-byte IDs and SEARCH_FLG.
        return .{
            .disc_id = d[12..28].*,
            .provider_id = d[28..44].*,
            .content_id = d[44..60].*,
            .search_flag = d[60],
        };
    }
};

// ---- tests --------------------------------------------------------------------------------------------------

const testing = std.testing;

fn wrap(gpa: std.mem.Allocator, name: []const u8, payload: []const u8) ![]u8 {
    const d = try gpa.alloc(u8, wrapper_header + payload.len + 4);
    @memset(d, 0);
    @memcpy(d[0..4], "AACS");
    d[4] = 0x12;
    std.mem.writeInt(u24, d[8..11], @intCast(payload.len), .big);
    @memcpy(d[11..][0..name.len], name);
    @memcpy(d[11 + name.len ..][0..5], ".AACS");
    @memcpy(d[wrapper_header..][0..payload.len], payload);
    @memcpy(d[d.len - 4 ..], "\x00\x00\x00\x07");
    return d;
}

test "AACS file wrapper" {
    const w = try wrap(testing.allocator, "a.xml", "<a/>");
    defer testing.allocator.free(w);
    try testing.expectEqualStrings("<a/>", unwrap(w));
    try testing.expectEqualStrings("<a/>", unwrap("<a/>"));
    var not = w[0..wrapper_header].*; // header without the ".AACS" name
    @memset(not[11..], 0);
    try testing.expectEqual(@as(usize, wrapper_header), unwrap(&not).len);
}

test "archives with wrapped and plain entries" {
    const gpa = testing.allocator;
    const w = try wrap(gpa, "s.js", "var x;");
    defer gpa.free(w);
    var d: std.ArrayList(u8) = .empty;
    defer d.deinit(gpa);
    try d.appendSlice(gpa, "HDDVDACA\x00\x10\x00\x01\x00\x02\x00\x00\x00\x00");
    try d.appendNTimes(gpa, 0, 32 - d.items.len);
    const table = d.items.len;
    const names = [_][]const u8{ "s.js", "p.png" };
    for (names) |nm| {
        try d.appendNTimes(gpa, 0, 14);
        d.items[d.items.len - 1] = @intCast(nm.len);
        d.items[d.items.len - 2] = 0xff;
        try d.appendSlice(gpa, nm);
        try d.appendNTimes(gpa, 0, 32);
    }
    const off0 = d.items.len;
    try d.appendSlice(gpa, w);
    const off1 = d.items.len;
    try d.appendSlice(gpa, "PNG!");
    std.mem.writeInt(u32, d.items[table..][0..4], @intCast(off0), .big);
    std.mem.writeInt(u32, d.items[table + 4 ..][0..4], @intCast(w.len), .big);
    const t1 = table + 14 + 4 + 32;
    std.mem.writeInt(u32, d.items[t1..][0..4], @intCast(off1), .big);
    std.mem.writeInt(u32, d.items[t1 + 4 ..][0..4], 4, .big);

    var a = try parse(gpa, d.items);
    defer a.deinit();
    try testing.expectEqual(2, a.entries.len);
    try testing.expectEqualStrings("var x;", a.get("s.js").?);
    try testing.expectEqualStrings("PNG!", a.get("p.png").?);
    try testing.expectEqual(null, a.get("S.JS"));
    try testing.expectError(error.BadAca, parse(gpa, d.items[0..40]));
}

test "DISCID.DAT" {
    var d: [128]u8 = @splat(0);
    @memcpy(d[0..12], "HDDVD-V_CONF");
    @memset(d[12..28], 0xff);
    @memcpy(d[28..44], "PROVIDER_ID_TEST");
    d[44] = 7;
    const id = DiscId.parse(&d).?;
    try testing.expectEqual(@as(u8, 0xff), id.disc_id[0]);
    try testing.expectEqualStrings("PROVIDER_ID_TEST", &id.provider_id);
    try testing.expectEqual(@as(u8, 7), id.content_id[0]);
    @memcpy(d[0..12], "HDDVD-V_CONX");
    try testing.expectEqual(null, DiscId.parse(&d));
}
