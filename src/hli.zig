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
