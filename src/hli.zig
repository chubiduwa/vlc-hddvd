//! Highlight information (HLI): reassembly from HLI_PCKs, parsing, and button selection/activation logic.
//! Pure logic, no VLC dependency. Reference: HD DVD Vol. 2 §5.1.4, §5.2.8.

const std = @import("std");
const nav = @import("nav.zig");

pub const hli_size = 9780;

pub const Button = struct {
    /// Colour number 1..3 (index into the 2-bit colour table).
    color: u2,
    sx: u16,
    ex: u16,
    sy: u16,
    ey: u16,
    auto_action: bool,
    /// Adjacent buttons: up, down, left, right (1-based; own number = no move).
    adjacent: [4]u8,
    cmds: [8]nav.Cmd,
};

pub const Hli = struct {
    /// 1 = new, 2 = same as previous, 3 = same except commands.
    status: u2,
    start_ptm: u32,
    end_ptm: u32,
    select_end_ptm: u32,
    n_buttons: u8,
    n_numeric: u8,
    offset: u8,
    force_select: u8,
    force_activate: u8,
    /// Per colour number 1..3: selection and action u32 (nibbles bg, pattern, e1, e2 colours, then contrasts).
    colors: [3][2]u32,
    /// BTN_COLIT_8BIT, per colour number: selection then action, each 256 x (Y, Cr, Cb) + 256 contrasts.
    colors8: [3][2048]u8,
    /// SP_USE: b7 = stream k carries buttons, b4..0 = its decoding stream number.
    sp_use: [32]u8,
    buttons: [48]Button,
};

pub const Dir = enum(u2) { up = 0, down = 1, left = 2, right = 3 };

/// Collects the 5 HLI_PCK payloads of one HLI.
pub const Assembler = struct {
    buf: [hli_size]u8 = undefined,
    len: usize = 0,
    packs: u8 = 0,

    /// Feeds the data of one HLI_PCK (after sub_stream_id 0x08). Returns the parsed HLI after the 5th pack.
    pub fn feed(a: *Assembler, data: []const u8) ?Hli {
        // Packs 1-4 carry 2027 bytes, pack 5 the remaining 1672; a full-size pack after a short one starts over.
        if (data.len == 2027 and a.packs == 4) a.reset();
        if (a.len + data.len > hli_size) {
            a.reset();
            if (data.len > hli_size) return null;
        }
        @memcpy(a.buf[a.len..][0..data.len], data);
        a.len += data.len;
        a.packs += 1;
        if (a.len < hli_size) return null;
        defer a.reset();
        return parse(&a.buf);
    }

    pub fn reset(a: *Assembler) void {
        a.len = 0;
        a.packs = 0;
    }
};

fn be16(b: []const u8, off: usize) u16 {
    return std.mem.readInt(u16, b[off..][0..2], .big);
}

fn be32(b: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, b[off..][0..4], .big);
}

pub fn parse(b: *const [hli_size]u8) ?Hli {
    if (b[0] != 'H' or b[1] != 'L') return null;
    var h: Hli = .{
        .status = @intCast(be16(b, 2) & 3),
        .start_ptm = be32(b, 4),
        .end_ptm = be32(b, 8),
        .select_end_ptm = be32(b, 12),
        .n_buttons = b[23] & 0x3f,
        .n_numeric = b[24] & 0x3f,
        .offset = b[22],
        .force_select = b[26] & 0x3f,
        .force_activate = b[27] & 0x3f,
        .colors = undefined,
        .colors8 = undefined,
        .sp_use = b[28..60].*,
        .buttons = undefined,
    };
    for (0..3) |i| {
        h.colors[i][0] = be32(b, 60 + i * 8);
        h.colors[i][1] = be32(b, 60 + i * 8 + 4);
        h.colors8[i] = b[84 + i * 2048 ..][0..2048].*;
    }
    // Only button group 1 is used (DL has one group; multi-group display types are not handled yet).
    for (&h.buttons, 0..) |*btn, i| {
        const e = 6228 + i * 74;
        const pos = (@as(u64, be32(b, e)) << 16) | be16(b, e + 4);
        btn.* = .{
            .color = @intCast(pos >> 46),
            .sx = @intCast((pos >> 35) & 0x7ff),
            .ex = @intCast((pos >> 24) & 0x7ff),
            .auto_action = (pos >> 22) & 3 == 1,
            .sy = @intCast((pos >> 11) & 0x7ff),
            .ey = @intCast(pos & 0x7ff),
            .adjacent = .{ b[e + 6] & 0x3f, b[e + 7] & 0x3f, b[e + 8] & 0x3f, b[e + 9] & 0x3f },
            .cmds = undefined,
        };
        for (&btn.cmds, 0..) |*c, k| c.* = b[e + 10 + k * 8 ..][0..8].*;
    }
    if (h.n_buttons > 48) h.n_buttons = 48;
    return h;
}

/// Sub-picture alpha of a 2-bit contrast k: transparent at 0, otherwise (k+1)/16.
pub fn alpha2(k: u4) u8 {
    return if (k == 0) 0 else @intCast(@min(255, (@as(u16, k) + 1) * 16));
}

/// Sub-picture alpha of an 8-bit contrast (SET_CONTR2): 0x00 = opaque … 0xFF = transparent.
pub fn alpha8(v: u8) u8 {
    return if (v == 0) 255 else 255 - v;
}

/// One button highlight: its rectangle and the colours that replace the SPU's own inside it, as {Y, Cb, Cr, A}
/// per pixel value, for 2-bit and 8-bit SPUs.
pub const Highlight = struct {
    sx: u16,
    ex: u16,
    sy: u16,
    ey: u16,
    lut2: [4][4]u8,
    lut8: [256][4]u8,
};

/// Builds the highlight of button `btn` (1-based) in selection or action colours, with the PGC palette
/// (16 x 0x00YYCrCb). 2-bit HD DVD nibble order: the most significant nibble is the background pixel.
pub fn highlight(h: *const Hli, btn: u8, action: bool, palette: *const [16]u32) ?Highlight {
    if (btn == 0 or btn > h.n_buttons) return null;
    const b = h.buttons[btn - 1];
    if (b.color == 0) return null;
    const coli = h.colors[b.color - 1][@intFromBool(action)];
    var out: Highlight = .{ .sx = b.sx, .ex = b.ex, .sy = b.sy, .ey = b.ey, .lut2 = undefined, .lut8 = undefined };
    for (&out.lut2, 0..) |*e, px| {
        const shift: u5 = @intCast(28 - px * 4);
        const yuv = palette[(coli >> shift) & 0xf];
        e.* = .{ @truncate(yuv >> 16), @truncate(yuv), @truncate(yuv >> 8), alpha2(@intCast((coli >> (shift - 16)) & 0xf)) };
    }
    const c8 = h.colors8[b.color - 1][if (action) 1024 else 0 ..][0..1024];
    for (&out.lut8, 0..) |*e, i| e.* = .{ c8[i * 3], c8[i * 3 + 2], c8[i * 3 + 1], alpha8(c8[768 + i]) };
    return out;
}

/// Button at video coordinates (x, y), or 0.
pub fn hit(h: *const Hli, x: i32, y: i32) u8 {
    for (h.buttons[0..h.n_buttons], 1..) |b, i| {
        if (x >= b.sx and x <= b.ex and y >= b.sy and y <= b.ey) return @intCast(i);
    }
    return 0;
}

// ---- tests ------------------------------------------------------------------------------------------------

const testing = std.testing;

fn testPutButton(b: *[hli_size]u8, i: usize, color: u2, sx: u11, ex: u11, sy: u11, ey: u11, auto: bool, adj: [4]u8, cmd0: nav.Cmd) void {
    const e = 6228 + i * 74;
    const pos: u48 = @as(u48, color) << 46 | @as(u48, sx) << 35 | @as(u48, ex) << 24 |
        @as(u48, @intFromBool(auto)) << 22 | @as(u48, sy) << 11 | ey;
    std.mem.writeInt(u48, b[e..][0..6], pos, .big);
    @memcpy(b[e + 6 ..][0..4], &adj);
    @memcpy(b[e + 10 ..][0..8], &cmd0);
}

/// A 2-button HLI: button 1 (100,200)-(300,250), button 2 (400,200)-(600,250) with auto action.
fn testHli() [hli_size]u8 {
    var b: [hli_size]u8 = @splat(0);
    b[0] = 'H';
    b[1] = 'L';
    std.mem.writeInt(u16, b[2..4], 1, .big);
    std.mem.writeInt(u32, b[4..8], 90_000, .big);
    std.mem.writeInt(u32, b[8..12], 270_000, .big);
    std.mem.writeInt(u32, b[12..16], 180_000, .big);
    b[22] = 0; // BTN_OFN
    b[23] = 2; // BTN_Ns
    b[24] = 2; // NSL_BTN_Ns
    b[26] = 2; // FOSL_BTNN
    b[27] = 63; // FOAC_BTNN: the selected button
    b[28] = 0x80; // SP_USE #0: decoding stream 0x20 carries buttons
    std.mem.writeInt(u32, b[60..64], 0x8c260fff, .big); // colour 1, selection
    std.mem.writeInt(u32, b[64..68], 0xcc210fff, .big); // colour 1, action
    const c8 = b[84..][0..2048]; // 8-bit colour 1: value 1 = Y 0x50, Cr 0x60, Cb 0x70, contrast 0x00 (opaque)
    c8[3..6].* = .{ 0x50, 0x60, 0x70 };
    c8[768] = 0xff;
    c8[769] = 0x00;
    testPutButton(&b, 0, 1, 100, 300, 200, 250, false, .{ 1, 1, 1, 2 }, .{ 0x71, 0, 0, 0, 0, 1, 0, 0 });
    testPutButton(&b, 1, 1, 400, 600, 200, 250, true, .{ 2, 2, 1, 2 }, .{ 0x71, 0, 0, 0, 0, 2, 0, 0 });
    return b;
}

/// Palette entry i = Y 16i, Cr 0x80 + i, Cb 0x40 + i (0x00YYCrCb).
fn testPalette() [16]u32 {
    var p: [16]u32 = undefined;
    for (&p, 0..) |*e, i| e.* = @intCast((i * 16) << 16 | (0x80 + i) << 8 | (0x40 + i));
    return p;
}

test "parse an HLI" {
    const raw = testHli();
    const h = parse(&raw).?;
    try testing.expectEqual(1, h.status);
    try testing.expectEqual(90_000, h.start_ptm);
    try testing.expectEqual(270_000, h.end_ptm);
    try testing.expectEqual(180_000, h.select_end_ptm);
    try testing.expectEqual(2, h.n_buttons);
    try testing.expectEqual(2, h.force_select);
    try testing.expectEqual(63, h.force_activate);
    try testing.expectEqual(0x80, h.sp_use[0]);
    try testing.expectEqual(0x8c260fff, h.colors[0][0]);
    try testing.expectEqual(0xcc210fff, h.colors[0][1]);

    const b1 = h.buttons[0];
    try testing.expectEqual(1, b1.color);
    try testing.expectEqual(.{ 100, 300, 200, 250 }, .{ b1.sx, b1.ex, b1.sy, b1.ey });
    try testing.expect(!b1.auto_action);
    try testing.expectEqualSlices(u8, &.{ 1, 1, 1, 2 }, &b1.adjacent);
    try testing.expectEqualSlices(u8, &.{ 0x71, 0, 0, 0, 0, 1, 0, 0 }, &b1.cmds[0]);
    try testing.expect(h.buttons[1].auto_action);
}

test "parse rejects a buffer without the HL tag" {
    var raw = testHli();
    raw[0] = 'X';
    try testing.expectEqual(null, parse(&raw));
}

test "the assembler joins 5 HLI packs" {
    const raw = testHli();
    var a: Assembler = .{};
    var off: usize = 0;
    for (0..4) |_| {
        try testing.expectEqual(null, a.feed(raw[off..][0..2027]));
        off += 2027;
    }
    const h = a.feed(raw[off..]).?; // the 5th pack holds the remaining 1672 bytes
    try testing.expectEqual(2, h.n_buttons);

    // A full-size pack after 4 others starts a new HLI instead of overflowing.
    for (0..4) |_| _ = a.feed(raw[0..2027]);
    try testing.expectEqual(null, a.feed(raw[0..2027]));
    try testing.expectEqual(1, a.packs);
}

test "contrast to alpha" {
    try testing.expectEqual(0, alpha2(0));
    try testing.expectEqual(32, alpha2(1));
    try testing.expectEqual(240, alpha2(14));
    try testing.expectEqual(255, alpha2(15));
    try testing.expectEqual(255, alpha8(0x00));
    try testing.expectEqual(0, alpha8(0xff));
    try testing.expectEqual(0xef, alpha8(0x10));
}

test "highlight colours: background first, palette as Y Cb Cr" {
    const raw = testHli();
    const h = parse(&raw).?;
    const pal = testPalette();

    // 8c260fff: background 8 (contrast 0), pattern 12, emphasis-1 2, emphasis-2 6 (all contrast 15).
    const sel = highlight(&h, 1, false, &pal).?;
    try testing.expectEqual(.{ 100, 300, 200, 250 }, .{ sel.sx, sel.ex, sel.sy, sel.ey });
    try testing.expectEqual([4]u8{ 8 * 16, 0x48, 0x88, 0 }, sel.lut2[0]);
    try testing.expectEqual([4]u8{ 12 * 16, 0x4c, 0x8c, 255 }, sel.lut2[1]);
    try testing.expectEqual([4]u8{ 2 * 16, 0x42, 0x82, 255 }, sel.lut2[2]);
    try testing.expectEqual([4]u8{ 6 * 16, 0x46, 0x86, 255 }, sel.lut2[3]);
    // 8-bit table: (Y, Cr, Cb) on the disc becomes (Y, Cb, Cr); contrast 0x00 is opaque.
    try testing.expectEqual([4]u8{ 0x50, 0x70, 0x60, 255 }, sel.lut8[1]);
    try testing.expectEqual(0, sel.lut8[0][3]);

    // cc210fff: the action colours.
    const act = highlight(&h, 1, true, &pal).?;
    try testing.expectEqual([4]u8{ 12 * 16, 0x4c, 0x8c, 0 }, act.lut2[0]);
    try testing.expectEqual([4]u8{ 1 * 16, 0x41, 0x81, 255 }, act.lut2[3]);

    try testing.expectEqual(null, highlight(&h, 0, false, &pal));
    try testing.expectEqual(null, highlight(&h, 3, false, &pal));
}

test "hit-testing is inclusive of the rectangle edges" {
    const raw = testHli();
    const h = parse(&raw).?;
    try testing.expectEqual(1, hit(&h, 100, 200));
    try testing.expectEqual(1, hit(&h, 300, 250));
    try testing.expectEqual(2, hit(&h, 500, 225));
    try testing.expectEqual(0, hit(&h, 350, 225));
    try testing.expectEqual(0, hit(&h, 500, 251));
}
