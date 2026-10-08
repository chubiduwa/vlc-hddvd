//! The Advanced stream (HD DVD Vol. 3 §6.3.5.2.8, §6.3.5.3.5): archive files multiplexed in a P-EVOB as
//! Advanced packs, reassembled here for the File Cache (Vol. 1 §4.3.20.1, the push model). No VLC dependency.
//!
//! An ADV_PCK is a pack header and one private_stream_2 packet with sub_stream_id 80h. Its private data area
//! gives the scrambling state, the packet's position in its file (first, last, both or neither), the
//! advanced_identifier that tells the files apart, the file name (first packet only), and up to 7 stuffing
//! bytes. The rest of the packet is the file's data. The last pack of a file may end with a padding packet.

const std = @import("std");

pub const sector_size = 2048;

pub const Packet = struct {
    /// PES_scrambling_control 01b: the data is protected (AACS).
    scrambled: bool,
    first: bool,
    last: bool,
    id: u12,
    /// The archive's file name (ISO 8859-1), on the first packet.
    name: []const u8 = "",
    data: []const u8,
};

/// The Advanced packet of a pack, or null if it is another kind of pack.
pub fn parse(pack: []const u8) ?Packet {
    if (pack.len < 14 or !std.mem.eql(u8, pack[0..4], &.{ 0, 0, 1, 0xba })) return null;
    var q: usize = 14 + @as(usize, pack[13] & 7);
    while (q + 6 <= pack.len and std.mem.eql(u8, pack[q..][0..3], &.{ 0, 0, 1 })) {
        const len = std.mem.readInt(u16, pack[q + 4 ..][0..2], .big);
        const end = q + 6 + len;
        if (end > pack.len) return null;
        if (pack[q + 3] == 0xbf and len >= 4 and pack[q + 6] == 0x80) return parsePacket(pack[q + 7 .. end]);
        q = end;
    }
    return null;
}

fn parsePacket(b: []const u8) ?Packet {
    const w = std.mem.readInt(u16, b[0..2], .big);
    const status: u2 = @intCast((w >> 12) & 3);
    var p: Packet = .{
        .scrambled = (w >> 14) == 1,
        .first = status & 1 != 0,
        .last = status & 2 != 0,
        .id = @intCast(w & 0xfff),
        .data = "",
    };
    var i: usize = 2;
    if (p.first) {
        if (i + 255 > b.len) return null;
        p.name = std.mem.sliceTo(b[i..][0..255], 0);
        i += 255;
    }
    if (i >= b.len) return null;
    const stuffing = b[i] & 7;
    i += 1 + stuffing;
    if (i > b.len) return null;
    p.data = b[i..];
    return p;
}

/// A file reassembled from the stream.
pub const File = struct {
    id: u12,
    name: []u8,
    data: []u8,
    /// Some of its packs were scrambled.
    scrambled: bool,

    pub fn deinit(f: File, gpa: std.mem.Allocator) void {
        gpa.free(f.name);
        gpa.free(f.data);
    }
};

/// Collects Advanced packets per advanced_identifier until a file is complete.
pub const Collector = struct {
    gpa: std.mem.Allocator,
    open: std.AutoHashMapUnmanaged(u12, Partial) = .empty,

    const Partial = struct {
        name: []u8,
        data: std.ArrayList(u8) = .empty,
        scrambled: bool = false,
    };

    pub fn deinit(c: *Collector) void {
        c.reset();
        c.open.deinit(c.gpa);
    }

    /// Drops the files in progress (after a jump the packs that follow are not their continuation).
    pub fn reset(c: *Collector) void {
        var it = c.open.valueIterator();
        while (it.next()) |p| {
            c.gpa.free(p.name);
            p.data.deinit(c.gpa);
        }
        c.open.clearRetainingCapacity();
    }

    /// Feeds one pack. Returns a completed file (the caller owns it), or null.
    pub fn feed(c: *Collector, pack: []const u8) !?File {
        const pkt = parse(pack) orelse return null;
        if (pkt.first) {
            if (c.open.fetchRemove(pkt.id)) |old| {
                c.gpa.free(old.value.name);
                var d = old.value.data;
                d.deinit(c.gpa);
            }
            const name = try c.gpa.dupe(u8, pkt.name);
            errdefer c.gpa.free(name);
            try c.open.put(c.gpa, pkt.id, .{ .name = name });
        }
        // A continuation without its first packet (reading started mid-file) cannot be used.
        const part = c.open.getPtr(pkt.id) orelse return null;
        try part.data.appendSlice(c.gpa, pkt.data);
        part.scrambled = part.scrambled or pkt.scrambled;
        if (!pkt.last) return null;
        const done = c.open.fetchRemove(pkt.id).?.value;
        var data = done.data;
        return .{
            .id = pkt.id,
            .name = done.name,
            .data = data.toOwnedSlice(c.gpa) catch |err| {
                c.gpa.free(done.name);
                data.deinit(c.gpa);
                return err;
            },
            .scrambled = done.scrambled,
        };
    }
};

// ---- tests --------------------------------------------------------------------------------------------------

const testing = std.testing;

/// A 2048-byte ADV_PCK carrying `data` (stuffed or padded to fill the pack, as §6.3.5.2.8 requires).
fn testPack(status: u2, id: u12, name: ?[]const u8, data: []const u8) [sector_size]u8 {
    var s: [sector_size]u8 = @splat(0);
    @memcpy(s[0..4], &[_]u8{ 0, 0, 1, 0xba });
    s[13] = 0xf8; // no pack stuffing
    var q: usize = 14;
    const hdr: usize = 1 + 2 + (if (name != null) @as(usize, 255) else 0) + 1;
    const room = sector_size - q - 6;
    const free = room - hdr - data.len;
    const stuffing: usize = if (free <= 7) free else 0;
    const pes_len = hdr + stuffing + data.len;
    @memcpy(s[q..][0..4], &[_]u8{ 0, 0, 1, 0xbf });
    std.mem.writeInt(u16, s[q + 4 ..][0..2], @intCast(pes_len), .big);
    q += 6;
    s[q] = 0x80;
    std.mem.writeInt(u16, s[q + 1 ..][0..2], (@as(u16, status) << 12) | id, .big);
    q += 3;
    if (name) |n| {
        @memcpy(s[q..][0..n.len], n);
        q += 255;
    }
    s[q] = @intCast(stuffing);
    q += 1;
    @memset(s[q..][0..stuffing], 0xff);
    q += stuffing;
    @memcpy(s[q..][0..data.len], data);
    q += data.len;
    if (q < sector_size) {
        // padding packet
        @memcpy(s[q..][0..4], &[_]u8{ 0, 0, 1, 0xbe });
        std.mem.writeInt(u16, s[q + 4 ..][0..2], @intCast(sector_size - q - 6), .big);
    }
    return s;
}

test "parse an Advanced pack" {
    const s = testPack(0b11, 0x123, "menu.aca", "HDDVDACA");
    const p = parse(&s).?;
    try testing.expect(p.first and p.last and !p.scrambled);
    try testing.expectEqual(@as(u12, 0x123), p.id);
    try testing.expectEqualStrings("menu.aca", p.name);
    try testing.expectEqualStrings("HDDVDACA", p.data);
    var other = s;
    other[14 + 6] = 0x00; // another private_stream_2 sub stream (e.g. GCI/DSI)
    try testing.expectEqual(null, parse(&other));
}

test "reassemble interleaved files" {
    var c: Collector = .{ .gpa = testing.allocator };
    defer c.deinit();
    const full = sector_size - 14 - 6 - 3 - 1;
    var big: [full]u8 = undefined;
    for (&big, 0..) |*b, i| b.* = @truncate(i);
    try testing.expectEqual(null, try c.feed(&testPack(0b01, 1, "a.aca", big[0 .. full - 255])));
    try testing.expectEqual(null, try c.feed(&testPack(0b01, 2, "b.aca", "B1")));
    try testing.expectEqual(null, try c.feed(&testPack(0b00, 1, null, &big)));
    // A continuation of an id never started is ignored.
    try testing.expectEqual(null, try c.feed(&testPack(0b10, 9, null, "x")));
    const b = (try c.feed(&testPack(0b10, 2, null, "B2"))).?;
    defer b.deinit(testing.allocator);
    try testing.expectEqualStrings("b.aca", b.name);
    try testing.expectEqualStrings("B1B2", b.data);
    const a = (try c.feed(&testPack(0b10, 1, null, "end"))).?;
    defer a.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, full - 255 + full + 3), a.data.len);
    try testing.expectEqualSlices(u8, &big, a.data[full - 255 ..][0..full]);

    // A jump drops what was in progress.
    try testing.expectEqual(null, try c.feed(&testPack(0b01, 3, "c.aca", "C")));
    c.reset();
    try testing.expectEqual(null, try c.feed(&testPack(0b10, 3, null, "D")));
}
