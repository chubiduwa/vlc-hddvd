//! Minimal read-only UDF 2.50 reader (ECMA-167 + OSTA UDF 2.50), enough for HD DVD discs and images:
//! physical partitions plus the Metadata Partition HD DVD uses for its file entries. No VLC dependency; blocks
//! are read through a callback. All fields are little-endian.

const std = @import("std");

pub const block_size = 2048;

pub const Error = error{ NotUdf, BadUdf, Unsupported, NotFound, ReadFailed, OutOfMemory };

/// Reads `buf.len` bytes at byte offset `offset` of the image; returns the count read.
pub const ReadFn = *const fn (ctx: *anyopaque, offset: u64, buf: []u8) Error!usize;

/// A contiguous run of a file's data in the image.
pub const Extent = struct {
    /// Absolute byte offset in the image.
    offset: u64,
    length: u64,
};

pub const FileInfo = struct {
    size: u64,
    is_dir: bool,
    extents: []Extent,
    /// Data stored inside the file entry itself (small files, "embedded" allocation).
    embedded: ?[]u8 = null,
};

const PartMap = union(enum) {
    physical: u16, // partition number
    metadata: struct { partition: u16, file_lbn: u32 },
};

const LongAd = struct { lbn: u32, part_ref: u16 };

fn le16(b: []const u8, off: usize) Error!u16 {
    if (off + 2 > b.len) return error.BadUdf;
    return std.mem.readInt(u16, b[off..][0..2], .little);
}

fn le32(b: []const u8, off: usize) Error!u32 {
    if (off + 4 > b.len) return error.BadUdf;
    return std.mem.readInt(u32, b[off..][0..4], .little);
}

fn le64(b: []const u8, off: usize) Error!u64 {
    if (off + 8 > b.len) return error.BadUdf;
    return std.mem.readInt(u64, b[off..][0..8], .little);
}

fn tagId(b: []const u8) Error!u16 {
    return le16(b, 0);
}

pub const Volume = struct {
    gpa: std.mem.Allocator,
    ctx: *anyopaque,
    readFn: ReadFn,
    /// Partition number -> start sector (UDF discs normally have one).
    part_start: [4]?u32 = .{ null, null, null, null },
    maps: [4]PartMap = undefined,
    n_maps: usize = 0,
    /// Extents (absolute sectors) of the Metadata File, per partition reference that is a metadata map.
    meta_extents: [4][]Extent = .{ &.{}, &.{}, &.{}, &.{} },
    root: LongAd = undefined,

    pub fn open(gpa: std.mem.Allocator, ctx: *anyopaque, readFn: ReadFn) Error!Volume {
        var v: Volume = .{ .gpa = gpa, .ctx = ctx, .readFn = readFn };
        errdefer v.deinit();
        try v.checkVrs();

        var blk: [block_size]u8 = undefined;
        try v.readBlock(256, &blk);
        if (try tagId(&blk) != 2) return error.NotUdf; // Anchor Volume Descriptor Pointer
        const vds_len = try le32(&blk, 16);
        const vds_loc = try le32(&blk, 20);

        var lvd: [block_size]u8 = undefined;
        var have_lvd = false;
        var i: u32 = 0;
        while (i < vds_len / block_size) : (i += 1) {
            try v.readBlock(vds_loc + i, &blk);
            switch (try tagId(&blk)) {
                5 => { // Partition Descriptor
                    const num = try le16(&blk, 22);
                    if (num < v.part_start.len) v.part_start[num] = try le32(&blk, 188);
                },
                6 => { // Logical Volume Descriptor
                    lvd = blk;
                    have_lvd = true;
                },
                8 => break, // Terminating Descriptor
                else => {},
            }
        }
        if (!have_lvd) return error.BadUdf;
        if (try le32(&lvd, 212) != block_size) return error.Unsupported;
        const fsd = LongAd{ .lbn = try le32(&lvd, 252), .part_ref = try le16(&lvd, 256) };

        // Partition maps.
        const n_maps = try le32(&lvd, 268);
        var off: usize = 440;
        for (0..n_maps) |_| {
            if (v.n_maps == v.maps.len or off + 2 > lvd.len) return error.Unsupported;
            const mtype = lvd[off];
            const mlen = lvd[off + 1];
            switch (mtype) {
                1 => v.maps[v.n_maps] = .{ .physical = try le16(&lvd, off + 4) },
                2 => {
                    const ident = lvd[off + 5 .. off + 28];
                    if (!std.mem.startsWith(u8, ident, "*UDF Metadata Partition")) return error.Unsupported;
                    v.maps[v.n_maps] = .{ .metadata = .{
                        .partition = try le16(&lvd, off + 38),
                        .file_lbn = try le32(&lvd, off + 40),
                    } };
                },
                else => return error.Unsupported,
            }
            v.n_maps += 1;
            off += mlen;
        }

        // Metadata partitions: their blocks map through the Metadata File, a file entry in the physical partition.
        for (v.maps[0..v.n_maps], 0..) |m, ref| {
            if (m != .metadata) continue;
            const phys_ref = v.physicalRef(m.metadata.partition) orelse return error.BadUdf;
            const info = try v.fileEntry(.{ .lbn = m.metadata.file_lbn, .part_ref = phys_ref });
            v.meta_extents[ref] = info.extents;
        }

        // File Set Descriptor -> root directory ICB.
        try v.readBlock(try v.toSector(fsd.part_ref, fsd.lbn), &blk);
        if (try tagId(&blk) != 256) return error.BadUdf;
        v.root = .{ .lbn = try le32(&blk, 404), .part_ref = try le16(&blk, 408) };
        return v;
    }

    pub fn deinit(v: *Volume) void {
        for (v.meta_extents) |e| if (e.len > 0) v.gpa.free(e);
    }

    /// True if the image starts with a UDF Volume Recognition Sequence (BEA01 … NSR02/03).
    pub fn probe(ctx: *anyopaque, readFn: ReadFn) bool {
        var v: Volume = .{ .gpa = undefined, .ctx = ctx, .readFn = readFn };
        v.checkVrs() catch return false;
        return true;
    }

    fn checkVrs(v: *Volume) Error!void {
        var bea = false;
        var nsr = false;
        var id: [6]u8 = undefined;
        var s: u64 = 16;
        while (s < 32) : (s += 1) {
            if (try v.readFn(v.ctx, s * block_size, &id) != id.len) return error.NotUdf;
            if (std.mem.eql(u8, id[1..6], "BEA01")) bea = true;
            if (std.mem.startsWith(u8, id[1..6], "NSR0")) nsr = true;
        }
        if (!bea or !nsr) return error.NotUdf;
    }

    fn readBlock(v: *Volume, sector: u64, buf: *[block_size]u8) Error!void {
        if (try v.readFn(v.ctx, sector * block_size, buf) != block_size) return error.ReadFailed;
    }

    fn physicalRef(v: *const Volume, partition: u16) ?u16 {
        for (v.maps[0..v.n_maps], 0..) |m, ref| {
            if (m == .physical and m.physical == partition) return @intCast(ref);
        }
        return null;
    }

    /// Logical block `lbn` of partition reference `ref` -> absolute image sector.
    fn toSector(v: *const Volume, ref: u16, lbn: u32) Error!u64 {
        if (ref >= v.n_maps) return error.BadUdf;
        switch (v.maps[ref]) {
            .physical => |p| {
                const start = (if (p < v.part_start.len) v.part_start[p] else null) orelse return error.BadUdf;
                return @as(u64, start) + lbn;
            },
            .metadata => {
                var left: u64 = @as(u64, lbn) * block_size;
                for (v.meta_extents[ref]) |e| {
                    if (left < e.length) return (e.offset + left) / block_size;
                    left -= e.length;
                }
                return error.BadUdf;
            },
        }
    }

    /// Reads a File Entry (tag 261) or Extended File Entry (tag 266) and resolves its allocation descriptors.
    fn fileEntry(v: *Volume, icb: LongAd) Error!FileInfo {
        var blk: [block_size]u8 = undefined;
        try v.readBlock(try v.toSector(icb.part_ref, icb.lbn), &blk);
        const tag = try tagId(&blk);
        const file_type = blk[16 + 11];
        const ad_type = (try le16(&blk, 16 + 18)) & 7;
        const size = try le64(&blk, 56);
        const l_ea, const l_ad, const ad_base: usize = switch (tag) {
            261 => .{ try le32(&blk, 168), try le32(&blk, 172), 176 },
            266 => .{ try le32(&blk, 208), try le32(&blk, 212), 216 },
            else => return error.BadUdf,
        };
        var info: FileInfo = .{ .size = size, .is_dir = file_type == 4, .extents = &.{} };
        var ad_off: usize = ad_base + l_ea;
        if (ad_off + l_ad > blk.len) return error.BadUdf;

        if (ad_type == 3) { // embedded data
            info.embedded = try v.gpa.dupe(u8, blk[ad_off..][0..@min(l_ad, size)]);
            return info;
        }
        const step: usize = switch (ad_type) {
            0 => 8, // short_ad
            1 => 16, // long_ad
            else => return error.Unsupported,
        };

        var extents: std.ArrayList(Extent) = .empty;
        errdefer extents.deinit(v.gpa);
        var end = ad_off + l_ad;
        var hops: usize = 0;
        while (ad_off + step <= end) {
            const raw_len = try le32(&blk, ad_off);
            const pos = try le32(&blk, ad_off + 4);
            const ref = if (ad_type == 0) icb.part_ref else try le16(&blk, ad_off + 8);
            const kind = raw_len >> 30;
            const len = raw_len & 0x3fff_ffff;
            if (len == 0) break;
            if (kind == 3) { // next extent of allocation descriptors (Allocation Extent Descriptor, tag 258)
                hops += 1;
                if (hops > 64) return error.BadUdf;
                try v.readBlock(try v.toSector(ref, pos), &blk);
                if (try tagId(&blk) != 258) return error.BadUdf;
                ad_off = 24;
                end = ad_off + try le32(&blk, 20);
                if (end > blk.len) return error.BadUdf;
                continue;
            }
            if (kind == 0) { // recorded and allocated
                try extents.append(v.gpa, .{ .offset = (try v.toSector(ref, pos)) * block_size, .length = len });
            }
            ad_off += step;
        }
        info.extents = try extents.toOwnedSlice(v.gpa);
        return info;
    }

    pub fn freeInfo(v: *Volume, info: FileInfo) void {
        v.gpa.free(info.extents);
        if (info.embedded) |e| v.gpa.free(e);
    }

    /// Reads part of a file through its extents.
    pub fn pread(v: *Volume, info: FileInfo, offset: u64, buf: []u8) Error!usize {
        if (offset >= info.size) return 0;
        const want = @min(buf.len, info.size - offset);
        if (info.embedded) |e| {
            @memcpy(buf[0..want], e[@intCast(offset)..][0..want]);
            return want;
        }
        var done: usize = 0;
        var skip = offset;
        for (info.extents) |e| {
            if (done == want) break;
            if (skip >= e.length) {
                skip -= e.length;
                continue;
            }
            const n = @min(want - done, e.length - skip);
            const got = try v.readFn(v.ctx, e.offset + skip, buf[done..][0..@intCast(n)]);
            done += got;
            if (got != n) break;
            skip = 0;
        }
        return done;
    }

    /// Looks up a '/'-separated path (case-insensitive, as HD DVD names are upper case).
    pub fn lookup(v: *Volume, path: []const u8) Error!FileInfo {
        var icb = v.root;
        var it = std.mem.tokenizeAny(u8, path, "/\\");
        while (it.next()) |part| {
            const dir = try v.fileEntry(icb);
            defer v.freeInfo(dir);
            if (!dir.is_dir) return error.NotFound;
            icb = try v.findInDir(dir, part);
        }
        return v.fileEntry(icb);
    }

    fn findInDir(v: *Volume, dir: FileInfo, name: []const u8) Error!LongAd {
        const data = try v.gpa.alloc(u8, @intCast(dir.size));
        defer v.gpa.free(data);
        if (try v.pread(dir, 0, data) != data.len) return error.ReadFailed;
        var it: DirIterator = .{ .data = data };
        while (try it.next()) |e| if (std.ascii.eqlIgnoreCase(e.name, name)) return e.icb;
        return error.NotFound;
    }

    /// Names of the entries of directory `path` (allocated with gpa; free with freeNames).
    pub fn listDir(v: *Volume, gpa: std.mem.Allocator, path: []const u8) Error![][]u8 {
        const dir = try v.lookup(path);
        defer v.freeInfo(dir);
        if (!dir.is_dir) return error.NotFound;
        const data = try v.gpa.alloc(u8, @intCast(dir.size));
        defer v.gpa.free(data);
        if (try v.pread(dir, 0, data) != data.len) return error.ReadFailed;
        var names: std.ArrayList([]u8) = .empty;
        errdefer freeNames(gpa, names.items);
        var it: DirIterator = .{ .data = data };
        while (try it.next()) |e| try names.append(gpa, try gpa.dupe(u8, e.name));
        return names.toOwnedSlice(gpa);
    }
};

pub fn freeNames(gpa: std.mem.Allocator, names: []const []u8) void {
    for (names) |n| gpa.free(n);
    gpa.free(names);
}

/// File Identifier Descriptors of a directory's data, skipping the parent entry.
const DirIterator = struct {
    data: []const u8,
    p: usize = 0,
    name_buf: [255]u8 = undefined,

    const Entry = struct { name: []const u8, icb: LongAd };

    fn next(it: *DirIterator) Error!?Entry {
        const data = it.data;
        while (it.p + 38 <= data.len) {
            const p = it.p;
            if (try tagId(data[p..]) != 257) return error.BadUdf; // File Identifier Descriptor
            const chars = data[p + 18];
            const l_fi = data[p + 19];
            const icb = LongAd{ .lbn = try le32(data, p + 24), .part_ref = try le16(data, p + 28) };
            const l_iu = try le16(data, p + 36);
            const id_off = p + 38 + l_iu;
            if (id_off + l_fi > data.len) return error.BadUdf;
            it.p += (38 + @as(usize, l_iu) + l_fi + 3) & ~@as(usize, 3);
            if (chars & 8 == 0 and l_fi > 0) // not the parent entry
                return .{ .name = decodeName(data[id_off..][0..l_fi], &it.name_buf), .icb = icb };
        }
        return null;
    }
};

/// OSTA CS0 d-string: compression id 8 = one byte per char, 16 = UTF-16BE. Non-ASCII becomes '?' (HD DVD
/// file names are ASCII).
fn decodeName(raw: []const u8, out: *[255]u8) []const u8 {
    if (raw.len == 0) return out[0..0];
    var n: usize = 0;
    if (raw[0] == 16) {
        var i: usize = 1;
        while (i + 1 < raw.len and n < out.len) : (i += 2) {
            const c = @as(u16, raw[i]) << 8 | raw[i + 1];
            out[n] = if (c < 128) @intCast(c) else '?';
            n += 1;
        }
    } else {
        for (raw[1..]) |c| {
            if (n == out.len) break;
            out[n] = c;
            n += 1;
        }
    }
    return out[0..n];
}

// ---- tests ------------------------------------------------------------------------------------------------

const testing = std.testing;

/// A synthetic UDF image: HVDVD_TS/HV001I01.IFO (5000 bytes in two extents, an Extended File Entry) and
/// HVDVD_TS/TINY (4 bytes embedded in its File Entry). With `meta`, the file entries and directories live in a
/// Metadata Partition (as on HD DVD) and file data is addressed with long_ads into the physical partition.
const TestImage = struct {
    const part_start = 64; // physical partition, in sectors
    const meta_file_lbn = 20; // the Metadata File's entry, in the physical partition
    const meta_start = 30; // the Metadata File's data (= metadata block 0), in the physical partition

    data: []u8,
    meta: bool,

    fn init(meta: bool) !TestImage {
        var img: TestImage = .{ .data = try testing.allocator.alloc(u8, 300 * block_size), .meta = meta };
        @memset(img.data, 0);
        img.build();
        return img;
    }

    fn deinit(img: *TestImage) void {
        testing.allocator.free(img.data);
    }

    fn block(img: *TestImage, sector: usize) *[block_size]u8 {
        return img.data[sector * block_size ..][0..block_size];
    }

    /// Sector of logical block `lbn` of the partition holding file entries and directories.
    fn fsSector(img: *const TestImage, lbn: usize) usize {
        return part_start + (if (img.meta) @as(usize, meta_start) else 0) + lbn;
    }

    fn put16(b: []u8, off: usize, v: u16) void {
        std.mem.writeInt(u16, b[off..][0..2], v, .little);
    }

    fn put32(b: []u8, off: usize, v: u32) void {
        std.mem.writeInt(u32, b[off..][0..4], v, .little);
    }

    /// File Entry (tag 261) or Extended File Entry (tag 266) with allocation descriptors `ads` of type `ad_type`.
    fn fileEntry(b: *[block_size]u8, extended: bool, is_dir: bool, size: u64, ad_type: u16, ads: []const u8) void {
        put16(b, 0, if (extended) 266 else 261);
        b[16 + 11] = if (is_dir) 4 else 5;
        put16(b, 16 + 18, ad_type);
        std.mem.writeInt(u64, b[56..64], size, .little);
        const l_ea: usize = if (extended) 208 else 168;
        put32(b, l_ea, 0);
        put32(b, l_ea + 4, @intCast(ads.len));
        @memcpy(b[l_ea + 8 ..][0..ads.len], ads);
    }

    fn shortAd(len: u32, lbn: u32) [8]u8 {
        var a: [8]u8 = undefined;
        put32(&a, 0, len);
        put32(&a, 4, lbn);
        return a;
    }

    fn longAd(len: u32, lbn: u32, ref: u16) [16]u8 {
        var a: [16]u8 = @splat(0);
        put32(&a, 0, len);
        put32(&a, 4, lbn);
        put16(&a, 8, ref);
        return a;
    }

    /// File Identifier Descriptor; returns its padded length. An empty name is the parent entry.
    fn fid(out: []u8, name: []const u8, is_dir: bool, lbn: u32, ref: u16) usize {
        put16(out, 0, 257);
        out[18] = (if (name.len == 0) @as(u8, 8) else 0) | (if (is_dir) @as(u8, 2) else 0);
        const l_fi: usize = if (name.len == 0) 0 else 1 + name.len;
        out[19] = @intCast(l_fi);
        put32(out, 20, block_size);
        put32(out, 24, lbn);
        put16(out, 28, ref);
        if (l_fi > 0) {
            out[38] = 8; // CS0, one byte per character
            @memcpy(out[39..][0..name.len], name);
        }
        return (38 + l_fi + 3) & ~@as(usize, 3);
    }

    /// One byte of the IFO file's content.
    fn pattern(i: usize) u8 {
        return @intCast(i % 251);
    }

    fn build(img: *TestImage) void {
        // Volume Recognition Sequence, Anchor, Volume Descriptor Sequence.
        img.block(16)[1..6].* = "BEA01".*;
        img.block(17)[1..6].* = "NSR03".*;
        img.block(18)[1..6].* = "TEA01".*;
        const avdp = img.block(256);
        put16(avdp, 0, 2);
        put32(avdp, 16, 3 * block_size);
        put32(avdp, 20, 32);
        const pd = img.block(32);
        put16(pd, 0, 5);
        put16(pd, 22, 0);
        put32(pd, 188, part_start);
        const lvd = img.block(33);
        put16(lvd, 0, 6);
        put32(lvd, 212, block_size);
        const fs_ref: u16 = if (img.meta) 1 else 0; // partition reference of entries and directories
        put32(lvd, 252, 0); // File Set Descriptor at block 0
        put16(lvd, 256, fs_ref);
        put32(lvd, 268, if (img.meta) 2 else 1);
        lvd[440] = 1; // type 1 map: physical partition 0
        lvd[441] = 6;
        put16(lvd, 444, 0);
        if (img.meta) { // type 2 map: Metadata Partition on partition 0
            lvd[446] = 2;
            lvd[447] = 64;
            @memcpy(lvd[446 + 5 ..][0..23], "*UDF Metadata Partition");
            put16(lvd, 446 + 38, 0);
            put32(lvd, 446 + 40, meta_file_lbn);
            const mf = img.block(part_start + meta_file_lbn);
            fileEntry(mf, false, false, 16 * block_size, 0, &shortAd(16 * block_size, meta_start));
        }
        put16(img.block(34), 0, 8); // Terminating Descriptor

        // File Set Descriptor -> root directory (block 1).
        const fsd = img.block(img.fsSector(0));
        put16(fsd, 0, 256);
        put32(fsd, 404, 1);
        put16(fsd, 408, fs_ref);

        // Root directory: data in block 2, one entry HVDVD_TS (entry in block 3).
        var dir = img.block(img.fsSector(2));
        var n = fid(dir, "", true, 1, fs_ref);
        n += fid(dir[n..], "HVDVD_TS", true, 3, fs_ref);
        fileEntry(img.block(img.fsSector(1)), false, true, n, 0, &shortAd(@intCast(n), 2));

        // HVDVD_TS: data in block 4; HV001I01.IFO (entry in block 5) and TINY (entry in block 6).
        dir = img.block(img.fsSector(4));
        n = fid(dir, "", true, 1, fs_ref);
        n += fid(dir[n..], "HV001I01.IFO", false, 5, fs_ref);
        n += fid(dir[n..], "TINY", false, 6, fs_ref);
        fileEntry(img.block(img.fsSector(3)), false, true, n, 0, &shortAd(@intCast(n), 4));

        // HV001I01.IFO: 4096 bytes at physical blocks 100-101, then 904 bytes at block 110.
        var ads: [32]u8 = undefined;
        const ad_len: usize = if (img.meta) 16 else 8;
        if (img.meta) {
            ads[0..16].* = longAd(4096, 100, 0);
            ads[16..32].* = longAd(904, 110, 0);
        } else {
            ads[0..8].* = shortAd(4096, 100);
            ads[8..16].* = shortAd(904, 110);
        }
        fileEntry(img.block(img.fsSector(5)), true, false, 5000, if (img.meta) 1 else 0, ads[0 .. 2 * ad_len]);
        for (0..5000) |i| {
            const at = if (i < 4096) (part_start + 100) * block_size + i else (part_start + 110) * block_size + i - 4096;
            img.data[at] = pattern(i);
        }

        // TINY: embedded data.
        fileEntry(img.block(img.fsSector(6)), false, false, 4, 3, "abcd");
    }

    fn read(ctx: *anyopaque, offset: u64, buf: []u8) Error!usize {
        const img: *TestImage = @ptrCast(@alignCast(ctx));
        if (offset >= img.data.len) return 0;
        const n = @min(buf.len, img.data.len - offset);
        @memcpy(buf[0..n], img.data[@intCast(offset)..][0..n]);
        return n;
    }
};

fn testReadFiles(meta: bool) !void {
    var img = try TestImage.init(meta);
    defer img.deinit();
    try testing.expect(Volume.probe(&img, TestImage.read));
    var v = try Volume.open(testing.allocator, &img, TestImage.read);
    defer v.deinit();

    const ifo = try v.lookup("HVDVD_TS/HV001I01.IFO");
    defer v.freeInfo(ifo);
    try testing.expectEqual(5000, ifo.size);
    try testing.expect(!ifo.is_dir);
    try testing.expectEqual(2, ifo.extents.len);

    const all = try testing.allocator.alloc(u8, 5000);
    defer testing.allocator.free(all);
    try testing.expectEqual(5000, try v.pread(ifo, 0, all));
    for (all, 0..) |c, i| try testing.expectEqual(TestImage.pattern(i), c);

    var across: [20]u8 = undefined; // spans the two extents
    try testing.expectEqual(20, try v.pread(ifo, 4090, &across));
    for (across, 4090..) |c, i| try testing.expectEqual(TestImage.pattern(i), c);
    try testing.expectEqual(10, try v.pread(ifo, 4990, &across)); // clipped at the end of the file
    try testing.expectEqual(0, try v.pread(ifo, 5000, &across));

    const tiny = try v.lookup("hvdvd_ts/tiny"); // names are matched case-insensitively
    defer v.freeInfo(tiny);
    var four: [8]u8 = undefined;
    try testing.expectEqual(4, try v.pread(tiny, 0, &four));
    try testing.expectEqualStrings("abcd", four[0..4]);

    const root = try v.lookup("");
    defer v.freeInfo(root);
    try testing.expect(root.is_dir);
    try testing.expectError(error.NotFound, v.lookup("HVDVD_TS/HV002I01.IFO"));
    try testing.expectError(error.NotFound, v.lookup("HVDVD_TS/TINY/X"));

    const names = try v.listDir(testing.allocator, "HVDVD_TS");
    defer freeNames(testing.allocator, names);
    try testing.expectEqual(2, names.len);
    try testing.expectEqualStrings("HV001I01.IFO", names[0]);
    try testing.expectEqualStrings("TINY", names[1]);
    try testing.expectError(error.NotFound, v.listDir(testing.allocator, "HVDVD_TS/TINY"));
}

test "read files from a UDF image with a physical partition" {
    try testReadFiles(false);
}

test "read files through a Metadata Partition" {
    try testReadFiles(true);
}

test "an image without a Volume Recognition Sequence is not UDF" {
    var img = try TestImage.init(false);
    defer img.deinit();
    @memset(img.block(17), 0); // drop NSR03
    try testing.expect(!Volume.probe(&img, TestImage.read));
    try testing.expectError(error.NotUdf, Volume.open(testing.allocator, &img, TestImage.read));
}

test "CS0 names: 8-bit and 16-bit compression" {
    var out: [255]u8 = undefined;
    try testing.expectEqualStrings("HVDVD_TS", decodeName("\x08HVDVD_TS", &out));
    try testing.expectEqualStrings("AB?", decodeName("\x10\x00A\x00B\x01\x00", &out));
    try testing.expectEqualStrings("", decodeName("", &out));
}
