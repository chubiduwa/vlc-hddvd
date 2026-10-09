//! Advanced VTS information (HVDVD_TS/HVA00001.VTI, HD DVD Vol. 3 §6.3.1): the EVOB table (file names, start
//! PTMs) and the EVOB attributes (streams, sub-picture palettes, sub video luma key). No VLC dependency.

const std = @import("std");

pub const Error = error{ BadVti, OutOfMemory };

pub const lb = 2048;

pub const Evob = struct {
    id: u16,
    /// File name inside HVDVD_TS (case as on disc).
    name: []const u8,
    /// Byte offset of the EVOB in its file (0 for an Advanced EVOB, a sector offset inside a Standard VTS's
    /// VTSTT_EVOBS otherwise).
    adr_ofs: u32,
    /// Index into `Vti.attrs`.
    attr: u16,
    start_ptm: u32,
    end_ptm: u32,
    /// Size in logical blocks.
    size: u32,
    index: u16,
};

pub const Attr = struct {
    /// EVOB_TY: bit flags for sub video (b10?), sub audio, advanced stream, kept raw.
    type: u16,
    main_video: u32,
    sub_video: u32,
    /// Sub video luma key: enable flag and upper limit.
    luma: u16,
    n_audio: u16,
    audio: [8]u32,
    n_sub_audio: u16,
    sub_audio: [8]u32,
    n_subp: u16,
    /// EVOB_SPST_ATR: 5 bytes per sub-picture stream.
    subp: [32][5]u8,
    sd_palette: [16]u32,
    hd_palette: [16]u32,

    /// The decoding sub-picture stream number (the low 5 bits of sub_stream_id) of sub-picture stream `n`
    /// (0-based) for HD display, or null if it has no HD stream.
    pub fn hdSubpStream(a: *const Attr, n: usize) ?u5 {
        if (n >= a.n_subp or n >= 32) return null;
        const b = a.subp[n][1];
        if (b & 0x20 == 0) return null;
        return @intCast(b & 0x1f);
    }

    /// True if the sub-picture stream uses 8-bit run-length coding.
    pub fn subp8bit(a: *const Attr, n: usize) bool {
        return n < 32 and a.subp[n][0] >> 5 == 0b100;
    }

    pub fn hasSubVideo(a: *const Attr) bool {
        return a.sub_video != 0;
    }

    /// The sub video's display aspect ratio (EVOB_VS_ATR b25–b24: 00b 4:3, 11b 16:9), or null.
    pub fn subAspect(a: *const Attr) ?[2]u32 {
        if (a.sub_video == 0) return null;
        return switch ((a.sub_video >> 24) & 3) {
            0 => .{ 4, 3 },
            3 => .{ 16, 9 },
            else => null,
        };
    }
};

pub const Vti = struct {
    gpa: std.mem.Allocator,
    evobs: []Evob,
    attrs: []Attr,
    names: []u8,

    pub fn deinit(v: *Vti) void {
        v.gpa.free(v.evobs);
        v.gpa.free(v.attrs);
        v.gpa.free(v.names);
    }

    pub fn byIndex(v: *const Vti, index: u16) ?*const Evob {
        for (v.evobs) |*e| if (e.index == index) return e;
        return null;
    }

    pub fn attrOf(v: *const Vti, e: *const Evob) ?*const Attr {
        return if (e.attr < v.attrs.len) &v.attrs[e.attr] else null;
    }
};

fn be16(b: []const u8, off: usize) Error!u16 {
    if (off + 2 > b.len) return error.BadVti;
    return std.mem.readInt(u16, b[off..][0..2], .big);
}

fn be32(b: []const u8, off: usize) Error!u32 {
    if (off + 4 > b.len) return error.BadVti;
    return std.mem.readInt(u32, b[off..][0..4], .big);
}

pub fn parse(gpa: std.mem.Allocator, d: []const u8) Error!Vti {
    if (d.len < 192 or !std.mem.eql(u8, d[0..12], "ADVANCED-VTS")) return error.BadVti;
    const atrt = @as(usize, try be32(d, 184)) * lb;
    const evobit = @as(usize, try be32(d, 188)) * lb;

    // Attributes.
    const n_attr = try be16(d, atrt);
    const attrs = try gpa.alloc(Attr, n_attr);
    errdefer gpa.free(attrs);
    for (attrs, 0..) |*a, i| {
        const off = atrt + try be32(d, atrt + 8 + 4 * i);
        if (off + 1024 > d.len) return error.BadVti;
        const r = d[off..][0..1024];
        a.* = .{
            .type = try be16(r, 0),
            .main_video = try be32(r, 2),
            .sub_video = try be32(r, 6),
            .luma = try be16(r, 10),
            .n_audio = try be16(r, 14),
            .audio = undefined,
            .n_sub_audio = try be16(r, 192),
            .sub_audio = undefined,
            .n_subp = try be16(r, 228),
            .subp = undefined,
            .sd_palette = undefined,
            .hd_palette = undefined,
        };
        for (0..8) |k| {
            a.audio[k] = try be32(r, 16 + 4 * k);
            a.sub_audio[k] = try be32(r, 194 + 4 * k);
        }
        for (0..32) |k| a.subp[k] = r[230 + 5 * k ..][0..5].*;
        for (0..16) |k| {
            a.sd_palette[k] = try be32(r, 390 + 4 * k);
            a.hd_palette[k] = try be32(r, 454 + 4 * k);
        }
    }

    // EVOBs.
    const n_evob = try be32(d, evobit);
    if (n_evob > 1998) return error.BadVti;
    const evobs = try gpa.alloc(Evob, n_evob);
    errdefer gpa.free(evobs);
    var names: std.ArrayList(u8) = .empty;
    errdefer names.deinit(gpa);
    var spans = try gpa.alloc([2]usize, n_evob);
    defer gpa.free(spans);
    for (evobs, 0..) |*e, i| {
        const off = evobit + try be32(d, evobit + 8 + 4 * i);
        if (off + 320 > d.len) return error.BadVti;
        const r = d[off..][0..320];
        const name = std.mem.sliceTo(r[2..257], 0);
        spans[i] = .{ names.items.len, name.len };
        try names.appendSlice(gpa, name);
        const atrn = try be32(r, 262);
        e.* = .{
            .id = try be16(r, 0),
            .name = &.{},
            .adr_ofs = try be32(r, 258),
            // EVOB_ATRN numbers the attributes from 1.
            .attr = @intCast(if (atrn > 0) atrn - 1 else 0),
            .start_ptm = try be32(r, 266),
            .end_ptm = try be32(r, 270),
            .size = try be32(r, 274),
            .index = try be16(r, 278),
        };
    }
    const owned = try names.toOwnedSlice(gpa);
    for (evobs, spans) |*e, s| e.name = owned[s[0]..][0..s[1]];
    return .{ .gpa = gpa, .evobs = evobs, .attrs = attrs, .names = owned };
}

// ---- tests --------------------------------------------------------------------------------------------------

const testing = std.testing;

/// A VTI with `n` EVOBs named "E<i>.EVO" sharing one attribute record (two HD 8-bit sub-picture streams).
pub fn testVti(gpa: std.mem.Allocator, n: u16) ![]u8 {
    const d = try gpa.alloc(u8, 4 * lb);
    @memset(d, 0);
    @memcpy(d[0..12], "ADVANCED-VTS");
    std.mem.writeInt(u32, d[184..188], 1, .big); // ATRT at LB 1
    std.mem.writeInt(u32, d[188..192], 2, .big); // EVOBIT at LB 2
    const at = lb;
    std.mem.writeInt(u16, d[at..][0..2], 1, .big);
    std.mem.writeInt(u32, d[at + 8 ..][0..4], 12, .big);
    const r = d[at + 12 ..][0..1024];
    std.mem.writeInt(u16, r[0..2], 0x0500, .big);
    std.mem.writeInt(u32, r[6..10], 0x63105000, .big); // sub video present: VC-1, 16:9
    std.mem.writeInt(u16, r[14..16], 1, .big);
    std.mem.writeInt(u16, r[228..230], 2, .big);
    r[230] = 0x80;
    r[231] = 0x20; // stream 0 → HD 0x20
    r[235] = 0x80;
    r[236] = 0x23; // stream 1 → HD 0x23
    std.mem.writeInt(u32, r[454..458], 0x00eb8080, .big);
    const et = 2 * lb;
    std.mem.writeInt(u32, d[et..][0..4], n, .big);
    for (0..n) |i| {
        const off: u32 = @intCast(8 + 4 * @as(usize, n) + 320 * i);
        std.mem.writeInt(u32, d[et + 8 + 4 * i ..][0..4], off, .big);
        const e = d[et + off ..][0..320];
        std.mem.writeInt(u16, e[0..2], @intCast(i + 1), .big);
        _ = try std.fmt.bufPrint(e[2..], "E{d}.EVO", .{i});
        std.mem.writeInt(u32, e[262..266], 1, .big);
        std.mem.writeInt(u32, e[266..270], 90000 * @as(u32, @intCast(i)), .big);
        std.mem.writeInt(u32, e[274..278], 100, .big);
        std.mem.writeInt(u16, e[278..280], @intCast(i + 1), .big);
    }
    return d;
}

test "parse a VTI" {
    const d = try testVti(testing.allocator, 3);
    defer testing.allocator.free(d);
    var v = try parse(testing.allocator, d);
    defer v.deinit();
    try testing.expectEqual(3, v.evobs.len);
    try testing.expectEqualStrings("E2.EVO", v.evobs[2].name);
    try testing.expectEqual(@as(u32, 180000), v.evobs[2].start_ptm);
    const e = v.byIndex(2).?;
    try testing.expectEqualStrings("E1.EVO", e.name);
    const a = v.attrOf(e).?;
    try testing.expect(a.hasSubVideo());
    try testing.expectEqual(@as(?[2]u32, .{ 16, 9 }), a.subAspect());
    try testing.expectEqual(@as(?u5, 0), a.hdSubpStream(0));
    try testing.expectEqual(@as(?u5, 3), a.hdSubpStream(1));
    try testing.expectEqual(null, a.hdSubpStream(2));
    try testing.expect(a.subp8bit(1));
    try testing.expectEqual(@as(u32, 0xeb8080), a.hd_palette[0]);
}

test "reject non-VTI data" {
    const vmg: [256]u8 = ("HVDVD-VMG100" ++ @as([244]u8, @splat(0))).*;
    try testing.expectError(error.BadVti, parse(testing.allocator, &vmg));
    var d = try testVti(testing.allocator, 1);
    defer testing.allocator.free(d);
    std.mem.writeInt(u32, d[188..192], 9, .big); // EVOBIT past the end
    try testing.expectError(error.BadVti, parse(testing.allocator, d));
}
