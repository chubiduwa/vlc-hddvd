//! Time maps (HVDVD_TS/*.MAP, HD DVD Vol. 3 §6.3.2): per EVOBU its playback time and size, which turn a clip
//! time into a position in the EVOB. No VLC dependency.
//!
//! EVOBU_ENT (u32): 1STREF_SZ b31–20, EVOBU_PB_TM b19–11, EVOBU_SZ b10–0 (packs). On the discs, PB_TM counts
//! quarter frames of the Title Timeline's timeBase: its sum over a TMAP equals the clip's title duration × 4.

const std = @import("std");

pub const Error = error{ BadTmap, OutOfMemory };

pub const Entry = packed struct(u32) {
    size: u11,
    pb_tm: u9,
    first_ref: u12,
};

pub const Tmapi = struct {
    evob_index: u16,
    entries: []Entry,
};

pub const Tmap = struct {
    gpa: std.mem.Allocator,
    /// Secondary Video Set (S-EVOB) map rather than Primary.
    svs: bool,
    /// The VTSI this map belongs to (PVS), e.g. "HVA00001.VTI".
    vtsi: []u8,
    /// One per EVOB; several for the angles of an interleaved block.
    tmapis: []Tmapi,
    /// ILVU entries (interleaved blocks): address (RLBN) and size in EVOBUs.
    ilvus: [][2]u32,

    pub fn deinit(t: *Tmap) void {
        for (t.tmapis) |m| t.gpa.free(m.entries);
        t.gpa.free(t.tmapis);
        t.gpa.free(t.vtsi);
        t.gpa.free(t.ilvus);
    }
};

/// A position in an EVOB.
pub const Pos = struct {
    /// EVOBU number in the TMAPI.
    evobu: usize,
    /// First sector of that EVOBU, relative to the EVOB.
    sector: u64,
    /// Start of that EVOBU in quarter frames from the EVOB's start.
    time_q: u64,
};

/// The EVOBU containing `time_q` (quarter frames from the start of the EVOB). Past the end: the last EVOBU.
pub fn seek(m: *const Tmapi, time_q: u64) Pos {
    var t: u64 = 0;
    var s: u64 = 0;
    for (m.entries, 0..) |e, i| {
        if (time_q < t + e.pb_tm or i + 1 == m.entries.len) return .{ .evobu = i, .sector = s, .time_q = t };
        t += e.pb_tm;
        s += e.size;
    }
    return .{ .evobu = 0, .sector = 0, .time_q = 0 };
}

/// The time (quarter frames) of the EVOBU containing `sector`, for reporting the playback position.
pub fn timeAt(m: *const Tmapi, sector: u64) u64 {
    var t: u64 = 0;
    var s: u64 = 0;
    for (m.entries) |e| {
        if (sector < s + e.size) {
            // Interpolate inside the EVOBU.
            return t + (sector - s) * e.pb_tm / @max(1, e.size);
        }
        t += e.pb_tm;
        s += e.size;
    }
    return t;
}

/// Total sectors and duration (quarter frames) of a TMAPI.
pub fn totals(m: *const Tmapi) struct { sectors: u64, time_q: u64 } {
    var t: u64 = 0;
    var s: u64 = 0;
    for (m.entries) |e| {
        t += e.pb_tm;
        s += e.size;
    }
    return .{ .sectors = s, .time_q = t };
}

fn be16(b: []const u8, off: usize) Error!u16 {
    if (off + 2 > b.len) return error.BadTmap;
    return std.mem.readInt(u16, b[off..][0..2], .big);
}

fn be32(b: []const u8, off: usize) Error!u32 {
    if (off + 4 > b.len) return error.BadTmap;
    return std.mem.readInt(u32, b[off..][0..4], .big);
}

pub fn parse(gpa: std.mem.Allocator, d: []const u8) Error!Tmap {
    if (d.len < 384 or !std.mem.eql(u8, d[0..12], "HDDVD_TMAP00")) return error.BadTmap;
    const ty = try be16(d, 20);
    const n = try be16(d, 55);
    const ilvui_sa = try be32(d, 57);
    const vtsi = try gpa.dupe(u8, std.mem.sliceTo(d[114..][0..255], 0));
    errdefer gpa.free(vtsi);
    const tmapis = try gpa.alloc(Tmapi, n);
    var done: usize = 0;
    errdefer {
        for (tmapis[0..done]) |m| gpa.free(m.entries);
        gpa.free(tmapis);
    }
    for (tmapis, 0..) |*m, i| {
        const srp = 384 + 32 * i;
        const sa = try be32(d, srp);
        const count = try be16(d, srp + 6);
        if (sa + @as(usize, count) * 4 > d.len) return error.BadTmap;
        const entries = try gpa.alloc(Entry, count);
        for (entries, 0..) |*e, k| e.* = @bitCast(std.mem.readInt(u32, d[sa + 4 * k ..][0..4], .big));
        m.* = .{ .evob_index = try be16(d, srp + 4), .entries = entries };
        done += 1;
    }
    var ilvus: std.ArrayList([2]u32) = .empty;
    errdefer ilvus.deinit(gpa);
    if (ilvui_sa != 0xffff_ffff and ilvui_sa != 0) {
        const count = try be32(d, 370);
        for (0..count) |k| try ilvus.append(gpa, .{ try be32(d, ilvui_sa + 8 * k), try be32(d, ilvui_sa + 8 * k + 4) });
    }
    return .{
        .gpa = gpa,
        .svs = ty & 0x0400 != 0, // ATR flag
        .vtsi = vtsi,
        .tmapis = tmapis,
        .ilvus = try ilvus.toOwnedSlice(gpa),
    };
}

// ---- tests --------------------------------------------------------------------------------------------------

const testing = std.testing;

/// A one-TMAPI map of EVOB index `index`: `n` EVOBUs of 14 frames (56 quarter frames) and 100 + i packs each.
pub fn testMap(gpa: std.mem.Allocator, index: u16, n: u16) ![]u8 {
    const d = try gpa.alloc(u8, 416 + 4 * @as(usize, n));
    @memset(d, 0);
    @memcpy(d[0..12], "HDDVD_TMAP00");
    std.mem.writeInt(u16, d[18..20], 0x10, .big);
    std.mem.writeInt(u16, d[20..22], 0x2000, .big);
    std.mem.writeInt(u16, d[55..57], 1, .big);
    std.mem.writeInt(u32, d[57..61], 0xffff_ffff, .big);
    @memcpy(d[114..][0..12], "HVA00001.VTI");
    std.mem.writeInt(u32, d[384..388], 416, .big);
    std.mem.writeInt(u16, d[388..390], index, .big);
    std.mem.writeInt(u16, d[390..392], n, .big);
    for (0..n) |i| {
        const e: Entry = .{ .size = @intCast(100 + i), .pb_tm = 56, .first_ref = 20 };
        std.mem.writeInt(u32, d[416 + 4 * i ..][0..4], @bitCast(e), .big);
    }
    return d;
}

test "parse a time map and seek in it" {
    const d = try testMap(testing.allocator, 7, 4);
    defer testing.allocator.free(d);
    var t = try parse(testing.allocator, d);
    defer t.deinit();
    try testing.expect(!t.svs);
    try testing.expectEqualStrings("HVA00001.VTI", t.vtsi);
    try testing.expectEqual(1, t.tmapis.len);
    const m = &t.tmapis[0];
    try testing.expectEqual(@as(u16, 7), m.evob_index);
    try testing.expectEqual(4, m.entries.len);
    try testing.expectEqual(@as(u11, 101), m.entries[1].size);
    try testing.expectEqual(@as(u12, 20), m.entries[1].first_ref);

    const tot = totals(m);
    try testing.expectEqual(@as(u64, 100 + 101 + 102 + 103), tot.sectors);
    try testing.expectEqual(@as(u64, 4 * 56), tot.time_q);

    const p = seek(m, 60); // inside the second EVOBU
    try testing.expectEqual(1, p.evobu);
    try testing.expectEqual(@as(u64, 100), p.sector);
    try testing.expectEqual(@as(u64, 56), p.time_q);
    try testing.expectEqual(3, seek(m, 10_000).evobu); // clamped to the last
    try testing.expectEqual(0, seek(m, 0).evobu);

    try testing.expectEqual(@as(u64, 56), timeAt(m, 100));
    try testing.expectEqual(@as(u64, 56 + 27), timeAt(m, 100 + 50)); // 50 of EVOBU 1’s 101 packs: 56 × 50 / 101 = 27
}

test "reject damaged time maps" {
    try testing.expectError(error.BadTmap, parse(testing.allocator, "HDDVD_TMAP00"));
    const d = try testMap(testing.allocator, 1, 2);
    defer testing.allocator.free(d);
    std.mem.writeInt(u16, d[390..392], 500, .big); // more entries than the file holds
    try testing.expectError(error.BadTmap, parse(testing.allocator, d));
}
