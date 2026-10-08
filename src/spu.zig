//! HD DVD sub-picture units (SPUs): display control sequences, 2-bit and 8-bit run-length pixel data, and the
//! SPU's own colours (HD DVD Vol. 2 §5.5.3, §5.5.4). Pure logic, no VLC dependency; the VLC decoder
//! is spudec.zig.

const std = @import("std");
const hli = @import("hli.zig");

const gpa = std.heap.c_allocator;

pub const Error = error{ BadSpu, OutOfMemory };

fn be16(b: []const u8, off: usize) Error!u16 {
    if (off + 2 > b.len) return error.BadSpu;
    return std.mem.readInt(u16, b[off..][0..2], .big);
}

fn be32(b: []const u8, off: usize) Error!u32 {
    if (off + 4 > b.len) return error.BadSpu;
    return std.mem.readInt(u32, b[off..][0..4], .big);
}

fn slice(b: []const u8, off: usize, n: usize) Error![]const u8 {
    if (off + n > b.len) return error.BadSpu;
    return b[off..][0..n];
}

/// Total unit size from its first bytes (either header form), or null if not enough bytes yet.
pub fn unitSize(head: []const u8) ?usize {
    if (head.len < 2) return null;
    if (head[0] != 0 or head[1] != 0) return std.mem.readInt(u16, head[0..2], .big);
    if (head.len < 6) return null;
    return std.mem.readInt(u32, head[2..6], .big);
}

/// Display state after a display control sequence (DCSQ).
pub const State = struct {
    on: bool = false,
    forced: bool = false,
    depth8: bool = false,
    color: u16 = 0,
    contr: u16 = 0,
    color2: ?*const [768]u8 = null,
    contr2: ?*const [256]u8 = null,
    /// sx, ex, sy, ey (SET_DAREA).
    area: ?[4]u16 = null,
    /// Top and bottom field pixel data addresses (SET_DSPXA / SET_DSPXA2).
    pxa: ?[2]u32 = null,
};

pub const Event = struct {
    /// Delay after the unit's PTS, in microseconds.
    delay_us: i64,
    st: State,
};

pub const max_events = 32;

/// Runs the unit's DCSQs and returns the state after each one.
pub fn parse(s: []const u8, out: *[max_events]Event) Error![]Event {
    if (s.len < 4) return error.BadSpu;
    const long = s[0] == 0 and s[1] == 0;
    const dcsqt: usize = if (long) try be32(s, 6) else try be16(s, 2);
    const link_len: usize = if (long) 4 else 2;
    var st: State = .{};
    var n: usize = 0;
    var off = dcsqt;
    while (n < max_events) {
        const stm = try be16(s, off);
        const next: usize = if (long) try be32(s, off + 2) else try be16(s, off + 2);
        var q = off + 2 + link_len;
        while (true) {
            const c = (try slice(s, q, 1))[0];
            q += 1;
            switch (c) {
                0xff => break,
                0x00 => {
                    st.on = true;
                    st.forced = true;
                },
                0x01 => {
                    st.on = true;
                    st.forced = false;
                },
                0x02 => st.on = false,
                0x03 => {
                    st.color = try be16(s, q);
                    q += 2;
                },
                0x04 => {
                    st.contr = try be16(s, q);
                    q += 2;
                },
                0x05, 0x85 => {
                    const a = try slice(s, q, 6);
                    const v = std.mem.readInt(u48, a[0..6], .big);
                    st.area = .{
                        @intCast((v >> 36) & 0x7ff), @intCast((v >> 24) & 0x7ff),
                        @intCast((v >> 12) & 0x7ff), @intCast(v & 0x7ff),
                    };
                    if (c == 0x85) st.depth8 = true;
                    q += 6;
                },
                0x06 => {
                    st.pxa = .{ try be16(s, q), try be16(s, q + 2) };
                    q += 4;
                },
                0x86 => {
                    st.pxa = .{ try be32(s, q), try be32(s, q + 4) };
                    q += 8;
                },
                0x83 => {
                    st.color2 = (try slice(s, q, 768))[0..768];
                    st.depth8 = true;
                    q += 768;
                },
                0x84 => {
                    st.contr2 = (try slice(s, q, 256))[0..256];
                    st.depth8 = true;
                    q += 256;
                },
                // CHG_COLCON(2): colour/contrast changes by area. Not supported (and forbidden while an HLI is
                // in use); skipped using its size field.
                0x07, 0x87 => q += @max(2, try be16(s, q)),
                else => return error.BadSpu,
            }
        }
        // SP_DCSQ_STM is in units of 1024/90000 s.
        out[n] = .{ .delay_us = @divTrunc(@as(i64, stm) * 1024 * 1_000_000, 90_000), .st = st };
        n += 1;
        if (next == off or next < dcsqt or next >= s.len) break;
        off = next;
    }
    return out[0..n];
}

const Bits = struct {
    s: []const u8,
    pos: usize, // in bits

    fn get(b: *Bits, n: u4) u16 {
        var v: u16 = 0;
        for (0..n) |_| {
            const byte = if (b.pos >> 3 < b.s.len) b.s[b.pos >> 3] else 0;
            v = (v << 1) | ((byte >> @intCast(7 - (b.pos & 7))) & 1);
            b.pos += 1;
        }
        return v;
    }

    fn alignByte(b: *Bits) void {
        b.pos = (b.pos + 7) & ~@as(usize, 7);
    }
};

/// 2-bit run-length line (as DVD-Video): 4, 8, 12 or 16-bit codes `run << 2 | pixel`; run 0 = to end of line.
fn line2(b: *Bits, out: []u8) void {
    var x: usize = 0;
    while (x < out.len) {
        var code = b.get(4);
        if (code < 0x4) {
            code = (code << 4) | b.get(4);
            if (code < 0x10) {
                code = (code << 4) | b.get(4);
                if (code < 0x40) code = (code << 4) | b.get(4);
            }
        }
        const run: usize = if (code >> 2 == 0) out.len - x else @min(code >> 2, out.len - x);
        @memset(out[x..][0..run], @intCast(code & 3));
        x += run;
    }
    b.alignByte();
}

/// 8-bit run-length line (5.5.4.2): Comp(1), then 0+PIX(2) or 1+PIX(8), then if Comp: LEXT(1)=0 RUN(3)+2 or
/// LEXT(1)=1 RUN(7)+9 (RUN 0 = to end of line).
fn line8(b: *Bits, out: []u8) void {
    var x: usize = 0;
    while (x < out.len) {
        const comp = b.get(1) == 1;
        const px: u8 = @intCast(if (b.get(1) == 1) b.get(8) else b.get(2));
        var run: usize = 1;
        if (comp) {
            if (b.get(1) == 1) {
                const r = b.get(7);
                run = if (r == 0) out.len - x else r + 9;
            } else run = b.get(3) + 2;
        }
        run = @min(run, out.len - x);
        @memset(out[x..][0..run], px);
        x += run;
    }
    b.alignByte();
}

/// Pixel values of the display area, top-field lines from pxa[0], bottom-field lines from pxa[1].
pub const Bitmap = struct {
    refs: std.atomic.Value(u32) = .init(1),
    x: u16,
    y: u16,
    w: u16,
    h: u16,
    px: []u8,

    pub fn decode(s: []const u8, st: State) Error!*Bitmap {
        const a = st.area orelse return error.BadSpu;
        const pxa = st.pxa orelse return error.BadSpu;
        if (a[1] < a[0] or a[3] < a[2]) return error.BadSpu;
        const w: usize = @as(usize, a[1]) - a[0] + 1;
        const h: usize = @as(usize, a[3]) - a[2] + 1;
        const px = try gpa.alloc(u8, w * h);
        errdefer gpa.free(px);
        var fields = [2]Bits{ .{ .s = s, .pos = @as(usize, pxa[0]) * 8 }, .{ .s = s, .pos = @as(usize, pxa[1]) * 8 } };
        for (0..h) |y| {
            const line = px[y * w ..][0..w];
            if (st.depth8) line8(&fields[y & 1], line) else line2(&fields[y & 1], line);
        }
        const bm = try gpa.create(Bitmap);
        bm.* = .{ .x = a[0], .y = a[2], .w = @intCast(w), .h = @intCast(h), .px = px };
        return bm;
    }

    pub fn ref(bm: *Bitmap) void {
        _ = bm.refs.fetchAdd(1, .monotonic);
    }

    pub fn unref(bm: *Bitmap) void {
        if (bm.refs.fetchSub(1, .acq_rel) != 1) return;
        gpa.free(bm.px);
        gpa.destroy(bm);
    }
};

pub const Lut = [256][4]u8;

/// The SPU's own colours, as {Y, Cb, Cr, A} per pixel value. 2-bit: SET_COLOR / SET_CONTR nibbles (most
/// significant = emphasis 2, least = background) into the PGC palette; 8-bit: SET_COLOR2 / SET_CONTR2.
pub fn ownColors(st: State, palette: *const [16]u32) Lut {
    var lut: Lut = @splat(.{ 16, 128, 128, 0 });
    if (st.depth8) {
        const c = st.color2 orelse return lut;
        const k = st.contr2 orelse return lut;
        for (&lut, 0..) |*e, i| e.* = .{ c[i * 3], c[i * 3 + 2], c[i * 3 + 1], hli.alpha8(k[i]) };
    } else {
        for (lut[0..4], 0..) |*e, px| {
            const shift: u4 = @intCast(px * 4);
            const yuv = palette[(st.color >> shift) & 0xf];
            e.* = .{ @truncate(yuv >> 16), @truncate(yuv), @truncate(yuv >> 8), hli.alpha2(@intCast((st.contr >> shift) & 0xf)) };
        }
    }
    return lut;
}

// ---- tests ------------------------------------------------------------------------------------------------

const testing = std.testing;

/// SET_DAREA operand: sx, ex, sy, ey packed into 6 bytes.
fn testArea(sx: u48, ex: u48, sy: u48, ey: u48) [6]u8 {
    var a: [6]u8 = undefined;
    std.mem.writeInt(u48, &a, sx << 36 | ex << 24 | sy << 12 | ey, .big);
    return a;
}

/// A 4x2 2-bit unit with the long header: top line 1,1,2,3 and bottom line 0,0,0,0 at (10,20). DCSQ 0 starts a
/// forced display; DCSQ 1, 10 ticks later, stops it.
fn testLongUnit() [52]u8 {
    var u: [52]u8 = @splat(0);
    std.mem.writeInt(u32, u[2..6], 52, .big); // SPU_SZ
    std.mem.writeInt(u32, u[6..10], 14, .big); // SP_DCSQT_SA
    u[10..14].* = .{ 0x96, 0x70, 0x00, 0x00 }; // top: run 2 of 1, 1 of 2, 1 of 3; bottom: rest of line in 0
    std.mem.writeInt(u32, u[16..20], 44, .big); // DCSQ 0: STM 0, next at 44
    u[20] = 0x00; // FSTA_DSP
    u[21..24].* = .{ 0x03, 0x32, 0x10 }; // SET_COLOR: e2 3, e1 2, pattern 1, background 0
    u[24..27].* = .{ 0x04, 0xff, 0x00 }; // SET_CONTR: emphasis opaque, pattern and background transparent
    u[27] = 0x05; // SET_DAREA
    u[28..34].* = testArea(10, 13, 20, 21);
    u[34] = 0x86; // SET_DSPXA2
    std.mem.writeInt(u32, u[35..39], 10, .big);
    std.mem.writeInt(u32, u[39..43], 12, .big);
    u[43] = 0xff;
    std.mem.writeInt(u16, u[44..46], 10, .big); // DCSQ 1: STM 10, last (points to itself)
    std.mem.writeInt(u32, u[46..50], 44, .big);
    u[50..52].* = .{ 0x02, 0xff }; // STP_DSP
    return u;
}

/// The same picture as a DVD-style unit (2-byte header), with a single non-forced DCSQ.
fn testShortUnit() [32]u8 {
    var u: [32]u8 = @splat(0);
    std.mem.writeInt(u16, u[0..2], 32, .big);
    std.mem.writeInt(u16, u[2..4], 8, .big);
    u[4..8].* = .{ 0x96, 0x70, 0x00, 0x00 };
    std.mem.writeInt(u16, u[10..12], 8, .big); // DCSQ 0: STM 0, last
    u[12] = 0x01; // STA_DSP
    u[13..16].* = .{ 0x03, 0x32, 0x10 };
    u[16..19].* = .{ 0x04, 0xff, 0x00 };
    u[19] = 0x05;
    u[20..26].* = testArea(10, 13, 20, 21);
    u[26] = 0x06; // SET_DSPXA
    std.mem.writeInt(u16, u[27..29], 4, .big);
    std.mem.writeInt(u16, u[29..31], 6, .big);
    u[31] = 0xff;
    return u;
}

test "unit size from either header" {
    try testing.expectEqual(0x1234, unitSize(&.{ 0x12, 0x34 }));
    try testing.expectEqual(52, unitSize(&.{ 0, 0, 0, 0, 0, 52 }));
    try testing.expectEqual(null, unitSize(&.{0}));
    try testing.expectEqual(null, unitSize(&.{ 0, 0, 0, 0 }));
}

test "long header: display control sequences and their timing" {
    const u = testLongUnit();
    var buf: [max_events]Event = undefined;
    const evs = try parse(&u, &buf);
    try testing.expectEqual(2, evs.len);

    const st = evs[0].st;
    try testing.expectEqual(0, evs[0].delay_us);
    try testing.expect(st.on and st.forced and !st.depth8);
    try testing.expectEqual(0x3210, st.color);
    try testing.expectEqual(0xff00, st.contr);
    try testing.expectEqual([4]u16{ 10, 13, 20, 21 }, st.area.?);
    try testing.expectEqual([2]u32{ 10, 12 }, st.pxa.?);

    // SP_DCSQ_STM is in units of 1024/90000 s.
    try testing.expectEqual(@divTrunc(10 * 1024 * 1_000_000, 90_000), evs[1].delay_us);
    try testing.expect(!evs[1].st.on);
}

test "fields: top lines from one address, bottom lines from the other" {
    const u = testLongUnit();
    var buf: [max_events]Event = undefined;
    const evs = try parse(&u, &buf);
    const bm = try Bitmap.decode(&u, evs[0].st);
    defer bm.unref();
    try testing.expectEqual(.{ 10, 20, 4, 2 }, .{ bm.x, bm.y, bm.w, bm.h });
    try testing.expectEqualSlices(u8, &.{ 1, 1, 2, 3, 0, 0, 0, 0 }, bm.px);
}

test "short (DVD-style) header" {
    const u = testShortUnit();
    var buf: [max_events]Event = undefined;
    const evs = try parse(&u, &buf);
    try testing.expectEqual(1, evs.len);
    try testing.expect(evs[0].st.on and !evs[0].st.forced);
    const bm = try Bitmap.decode(&u, evs[0].st);
    defer bm.unref();
    try testing.expectEqualSlices(u8, &.{ 1, 1, 2, 3, 0, 0, 0, 0 }, bm.px);
}

test "2-bit run lengths of every code size" {
    // 4-bit run 2 of 3; 8-bit run 5 of 1; 12-bit run 20 of 2; 16-bit run 70 of 0; then rest of line in 3.
    const data = [_]u8{ 0xb1, 0x50, 0x52, 0x01, 0x18, 0x00, 0x03 };
    var b: Bits = .{ .s = &data, .pos = 0 };
    var out: [100]u8 = undefined;
    line2(&b, &out);
    var want: [100]u8 = undefined;
    @memset(want[0..2], 3);
    @memset(want[2..7], 1);
    @memset(want[7..27], 2);
    @memset(want[27..97], 0);
    @memset(want[97..], 3);
    try testing.expectEqualSlices(u8, &want, &out);
    try testing.expectEqual(data.len * 8, b.pos); // byte-aligned at the end of the line
}

test "8-bit run lengths" {
    // Pixel 2 once (4 bits), then pixel 200 five times (Comp, 8-bit, LEXT 0, RUN 3 → 3 + 2).
    const data = [_]u8{ 0x2f, 0x20, 0xc0 };
    var b: Bits = .{ .s = &data, .pos = 0 };
    var out: [6]u8 = undefined;
    line8(&b, &out);
    try testing.expectEqualSlices(u8, &.{ 2, 200, 200, 200, 200, 200 }, &out);

    // Comp, 2-bit pixel 1, LEXT 1, RUN 0: to the end of the line.
    const rest = [_]u8{ 0x98, 0x00 };
    b = .{ .s = &rest, .pos = 0 };
    var out2: [7]u8 = undefined;
    line8(&b, &out2);
    try testing.expectEqualSlices(u8, &.{ 1, 1, 1, 1, 1, 1, 1 }, &out2);
}

test "own colours: 2-bit nibbles into the palette, 8-bit tables" {
    var pal: [16]u32 = undefined;
    for (&pal, 0..) |*e, i| e.* = @intCast((i * 16) << 16 | (0x80 + i) << 8 | (0x40 + i));
    const st: State = .{ .color = 0x3210, .contr = 0xf800 };
    const lut = ownColors(st, &pal);
    try testing.expectEqual([4]u8{ 0, 0x40, 0x80, 0 }, lut[0]);
    try testing.expectEqual([4]u8{ 16, 0x41, 0x81, 0 }, lut[1]);
    try testing.expectEqual([4]u8{ 32, 0x42, 0x82, 144 }, lut[2]); // contrast 8 → 9/16
    try testing.expectEqual([4]u8{ 48, 0x43, 0x83, 255 }, lut[3]);

    var color2: [768]u8 = @splat(0);
    var contr2: [256]u8 = @splat(0xff);
    color2[5 * 3 ..][0..3].* = .{ 0x50, 0x60, 0x70 }; // Y, Cr, Cb
    contr2[5] = 0;
    const lut8 = ownColors(.{ .depth8 = true, .color2 = &color2, .contr2 = &contr2 }, &pal);
    try testing.expectEqual([4]u8{ 0x50, 0x70, 0x60, 255 }, lut8[5]);
    try testing.expectEqual(0, lut8[6][3]);
}

test "malformed units are rejected" {
    const u = testLongUnit();
    var buf: [max_events]Event = undefined;
    try testing.expectError(error.BadSpu, parse(u[0..30], &buf)); // commands run past the end
    var bad = u;
    bad[21] = 0x99; // unknown command
    try testing.expectError(error.BadSpu, parse(&bad, &buf));
    try testing.expectError(error.BadSpu, Bitmap.decode(&u, .{ .on = true })); // no display area
}
