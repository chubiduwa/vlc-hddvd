//! HD DVD Standard Content IFO parsing (HV000I01.IFO = VMG, HVnnnI01.IFO = VTS) into nav.Disc.
//! Layouts: HD DVD Vol. 2 §5.2.
//! All fields are big-endian; "sector" = 2048 bytes.

const std = @import("std");
const nav = @import("nav.zig");
const vfs = @import("vfs.zig");

const sector = nav.sector_size;

pub const Error = error{ NotHdDvd, BadIfo, OutOfMemory } || vfs.Error;

fn be16(b: []const u8, off: usize) error{BadIfo}!u16 {
    if (off + 2 > b.len) return error.BadIfo;
    return std.mem.readInt(u16, b[off..][0..2], .big);
}

fn be32(b: []const u8, off: usize) error{BadIfo}!u32 {
    if (off + 4 > b.len) return error.BadIfo;
    return std.mem.readInt(u32, b[off..][0..4], .big);
}

fn be64(b: []const u8, off: usize) error{BadIfo}!u64 {
    if (off + 8 > b.len) return error.BadIfo;
    return std.mem.readInt(u64, b[off..][0..8], .big);
}

/// BCD playback time "hh mm ss ff"; the frame rate is the top bit of the minute, second and frame bytes
/// (001 = 25, 011 = 30 (29.97), 101 = 50, 111 = 60 (59.94)).
pub fn bcdTimeUs(t: u32) i64 {
    const h: u8 = @truncate(t >> 24);
    const m: u8 = @truncate(t >> 16);
    const s: u8 = @truncate(t >> 8);
    const f: u8 = @truncate(t);
    const bcd = struct {
        fn v(x: u8) i64 {
            return @as(i64, (x >> 4) & 7) * 10 + (x & 15);
        }
    };
    const rate = (@as(u3, @intCast(m >> 7)) << 2) | (@as(u3, @intCast(s >> 7)) << 1) | @as(u3, @intCast(f >> 7));
    const whole_s = bcd.v(h & 0x3f) * 3600 + bcd.v(m) * 60 + bcd.v(s);
    const frames = bcd.v(f);
    // (fps numerator, denominator) per rate code; NTSC-style rates run 1000/1001 slower than nominal.
    const num: i64, const den: i64 = switch (rate) {
        1 => .{ 25, 1 },
        3 => .{ 30000, 1001 },
        5 => .{ 50, 1 },
        7 => .{ 60000, 1001 },
        else => .{ 30000, 1001 },
    };
    // Nominal time counts frames at the integer rate (30/60), so scale everything by 1001/1000 for NTSC.
    const nominal_fps = @divTrunc(num + den - 1, den);
    const total_frames = whole_s * nominal_fps + frames;
    return @divTrunc(total_frames * den * 1_000_000, num);
}

fn cmds(a: std.mem.Allocator, b: []const u8, off: usize, n: usize) Error![]nav.Cmd {
    if (off + n * 8 > b.len) return error.BadIfo;
    const out = try a.alloc(nav.Cmd, n);
    for (out, 0..) |*c, i| c.* = b[off + i * 8 ..][0..8].*;
    return out;
}

/// Parses a PGCI at byte offset `pgci`, with the category bits from its search pointer.
fn parsePgc(a: std.mem.Allocator, b: []const u8, pgci: usize, cat: u64) Error!nav.Pgc {
    const n_programs = (try be16(b, pgci + 0)) & 0x1ff;
    const n_cells = (try be16(b, pgci + 2)) & 0x1ff;
    if (pgci + 304 > b.len) return error.BadIfo;
    var pgc: nav.Pgc = .{
        .program_cells = try a.alloc(u16, n_programs),
        .cells = try a.alloc(nav.Cell, n_cells),
        .pre = &.{},
        .post = &.{},
        .cell_cmds = &.{},
        .resume_cmds = &.{},
        .next_pgcn = (try be16(b, pgci + 156)) & 0x7fff,
        .prev_pgcn = (try be16(b, pgci + 158)) & 0x7fff,
        .goup_pgcn = try be16(b, pgci + 160),
        .playback_mode = (try be16(b, pgci + 162)) & 0x3ff,
        .still = b[pgci + 164],
        .uop_mask = try be32(b, pgci + 8),
        .audio_ctl = undefined,
        .spst_ctl = undefined,
        .sd_palette = undefined,
        .hd_palette = undefined,
        .duration_us = bcdTimeUs(try be32(b, pgci + 4)),
        .entry = cat >> 63 != 0,
        .resume_prohibited = (cat >> 62) & 1 != 0,
        .hli_off = (cat >> 57) & 1 != 0,
        .vts_ttn = @intCast((cat >> 48) & 0x1ff),
        .menu_id = @intCast((cat >> 52) & 0xf),
    };
    for (&pgc.audio_ctl, 0..) |*v, i| v.* = try be16(b, pgci + 12 + i * 2);
    for (&pgc.spst_ctl, 0..) |*v, i| v.* = try be32(b, pgci + 28 + i * 4);
    for (&pgc.sd_palette, 0..) |*v, i| v.* = try be32(b, pgci + 176 + i * 4);
    for (&pgc.hd_palette, 0..) |*v, i| v.* = try be32(b, pgci + 240 + i * 4);

    const cmdt_off = try be16(b, pgci + 168);
    if (cmdt_off != 0) {
        const t = pgci + cmdt_off;
        const n_pre = try be16(b, t + 0);
        const n_post = try be16(b, t + 2);
        const n_cell = try be16(b, t + 4);
        const n_rsm = try be16(b, t + 6);
        var off = t + 10;
        pgc.pre = try cmds(a, b, off, n_pre);
        off += @as(usize, n_pre) * 8;
        pgc.post = try cmds(a, b, off, n_post);
        off += @as(usize, n_post) * 8;
        pgc.cell_cmds = try cmds(a, b, off, n_cell);
        off += @as(usize, n_cell) * 8;
        pgc.resume_cmds = try cmds(a, b, off, n_rsm);
    }

    if (n_programs > 0) {
        const pgmap = pgci + try be16(b, pgci + 170);
        for (pgc.program_cells, 0..) |*pc, p| pc.* = try be16(b, pgmap + p * 2);
    }

    if (n_cells > 0) {
        const cpbit = pgci + try be16(b, pgci + 172);
        for (pgc.cells, 0..) |*c, i| {
            const e = cpbit + i * 28;
            const ccat = try be32(b, e + 0);
            const seq = try be16(b, e + 24);
            c.* = .{
                .first_sector = try be32(b, e + 8),
                .last_sector = try be32(b, e + 20),
                .duration_us = bcdTimeUs(try be32(b, e + 4)),
                .block_mode = @intCast(ccat >> 30),
                .block_type = @intCast((ccat >> 28) & 3),
                .seamless = (ccat >> 27) & 1 != 0,
                .stc_discontinuity = (ccat >> 25) & 1 != 0,
                .still = @intCast((ccat >> 8) & 0xff),
                .cmd_count = @intCast(seq >> 12),
                .cmd_first = seq & 0xfff,
            };
        }
    }
    return pgc;
}

/// VMGM_PGCI_UT / VTSM_PGCI_UT at byte offset `ut`.
fn parseMenus(a: std.mem.Allocator, b: []const u8, ut: usize) Error![]nav.MenuLu {
    const n_lu = try be16(b, ut);
    const lus = try a.alloc(nav.MenuLu, n_lu);
    for (lus, 0..) |*lu, i| {
        const srp = ut + 8 + i * 8;
        const lu_off = ut + try be32(b, srp + 4);
        const n_pgc = try be16(b, lu_off);
        lu.* = .{ .lang = try be16(b, srp), .pgcs = try a.alloc(nav.Pgc, n_pgc) };
        for (lu.pgcs, 0..) |*pgc, k| {
            const e = lu_off + 8 + k * 12;
            pgc.* = try parsePgc(a, b, lu_off + try be32(b, e + 8), try be64(b, e));
        }
    }
    return lus;
}

/// Lists the EVO files `fmt` (with a trailing {d:0>2} counter) until one is missing.
fn findEvos(a: std.mem.Allocator, fs: *vfs.Fs, comptime fmt: []const u8, args: anytype) Error![][]u8 {
    var paths: std.ArrayList([]u8) = .empty;
    var n: u32 = 1;
    while (n < 100) : (n += 1) {
        const p = try std.fmt.allocPrint(a, fmt, args ++ .{n});
        var f = fs.openFile(p) catch |err| switch (err) {
            error.NotFound => break,
            else => return err,
        };
        f.close();
        try paths.append(a, p);
    }
    return paths.items;
}

fn loadVts(a: std.mem.Allocator, fs: *vfs.Fs, vtsn: u16) Error!nav.Vts {
    const name = try std.fmt.allocPrint(a, "HVDVD_TS/HV{d:0>3}I01.IFO", .{vtsn});
    const b = (try fs.readFile(a, name)) orelse return error.BadIfo;
    if (b.len < 2048 or !std.mem.eql(u8, b[0..12], "STANDARD-VTS")) return error.BadIfo;

    // Title PGCs.
    const pgcit = @as(usize, try be32(b, 204)) * sector;
    const n_pgc = try be16(b, pgcit);
    const pgcs = try a.alloc(nav.Pgc, n_pgc);
    for (pgcs, 0..) |*pgc, i| {
        const e = pgcit + 8 + i * 12;
        pgc.* = try parsePgc(a, b, pgcit + try be32(b, e + 8), try be64(b, e));
    }

    // Chapters.
    const ptt = @as(usize, try be32(b, 200)) * sector;
    const n_ttn = try be16(b, ptt);
    const end = try be32(b, ptt + 4);
    const ptts = try a.alloc([]nav.Ptt, n_ttn);
    for (ptts, 0..) |*list, t| {
        const off = try be32(b, ptt + 8 + t * 4);
        const next = if (t + 1 < n_ttn) try be32(b, ptt + 8 + (t + 1) * 4) else end + 1;
        if (next < off) return error.BadIfo;
        list.* = try a.alloc(nav.Ptt, (next - off) / 4);
        for (list.*, 0..) |*p, k| {
            p.* = .{ .pgcn = try be16(b, ptt + off + k * 4), .pgn = try be16(b, ptt + off + k * 4 + 2) };
        }
    }

    const menu_ut = @as(usize, try be32(b, 208)) * sector;
    var vts: nav.Vts = .{
        .title_pgcs = pgcs,
        .ptts = ptts,
        .menus = if (menu_ut != 0) try parseMenus(a, b, menu_ut) else &.{},
        .title_evos = try findEvos(a, fs, "HVDVD_TS/HV{d:0>3}T{d:0>2}.EVO", .{vtsn}),
        .menu_evos = try findEvos(a, fs, "HVDVD_TS/HV{d:0>3}M{d:0>2}.EVO", .{vtsn}),
    };

    // Stream languages (VTSI_MAT): audio attributes 8 x 8 B at 538, sub-picture 32 x 6 B at 604.
    vts.n_audio = @intCast(@min(8, try be16(b, 536)));
    for (0..vts.n_audio) |i| vts.audio_lang[i] = try be16(b, 538 + i * 8 + 4);
    vts.n_subp = @intCast(@min(32, try be16(b, 602)));
    for (0..vts.n_subp) |i| vts.subp_lang[i] = try be16(b, 604 + i * 6 + 2);
    return vts;
}

/// Duration of the cells before cell `first_cell` (1-based) of a PGC, first angle only.
fn timeBeforeCell(pgc: nav.Pgc, first_cell: u16) i64 {
    var t: i64 = 0;
    for (pgc.cells[0..@min(pgc.cells.len, first_cell -| 1)]) |c| {
        if (c.block_mode <= 1) t += c.duration_us;
    }
    return t;
}

/// Chapter start times of a title and its length, from its PTTs and the cell durations. For multi-PGC titles
/// the PGCs are counted in the order the chapters use them.
fn chapterTimes(a: std.mem.Allocator, vts: nav.Vts, list: []const nav.Ptt) Error!struct { []i64, i64 } {
    const times = try a.alloc(i64, list.len);
    var pgc_start: i64 = 0;
    var cur: u16 = 0;
    for (list, 0..) |p, i| {
        if (p.pgcn == 0 or p.pgcn > vts.title_pgcs.len) return error.BadIfo;
        if (p.pgcn != cur) {
            if (cur != 0) pgc_start += vts.title_pgcs[cur - 1].duration_us;
            cur = p.pgcn;
        }
        const pgc = vts.title_pgcs[p.pgcn - 1];
        const first_cell = if (p.pgn >= 1 and p.pgn <= pgc.program_cells.len) pgc.program_cells[p.pgn - 1] else 1;
        times[i] = pgc_start + timeBeforeCell(pgc, first_cell);
    }
    const total = pgc_start + (if (cur != 0) vts.title_pgcs[cur - 1].duration_us else 0);
    return .{ times, total };
}

/// Loads the Standard Content navigation of the disc in `fs`.
pub fn loadDisc(gpa: std.mem.Allocator, fs: *vfs.Fs) Error!nav.Disc {
    var d: nav.Disc = .{ .arena = .init(gpa), .fp_pgc = null, .vmgm = &.{}, .vmgm_evos = &.{}, .titles = &.{}, .vts = &.{} };
    errdefer d.deinit();
    const a = d.arena.allocator();

    const vmg = (try fs.readFile(a, "HVDVD_TS/HV000I01.IFO")) orelse return error.NotHdDvd;
    if (vmg.len < 2048 or !std.mem.eql(u8, vmg[0..12], "HVDVD-VMG100")) return error.NotHdDvd;

    const fp_off = try be32(vmg, 132);
    if (fp_off != 0) d.fp_pgc = try parsePgc(a, vmg, fp_off, 1 << 63);
    const vmgm_ut = @as(usize, try be32(vmg, 200)) * sector;
    if (vmgm_ut != 0) d.vmgm = try parseMenus(a, vmg, vmgm_ut);
    d.vmgm_evos = try findEvos(a, fs, "HVDVD_TS/HV000M{d:0>2}.EVO", .{});

    const n_vts = (try be16(vmg, 62)) & 0x1ff;
    d.vts = try a.alloc(nav.Vts, n_vts);
    for (d.vts, 0..) |*v, i| v.* = try loadVts(a, fs, @intCast(i + 1));

    const tt_srpt = @as(usize, try be32(vmg, 196)) * sector;
    const n_titles = try be16(vmg, tt_srpt);
    d.titles = try a.alloc(nav.Title, n_titles);
    for (d.titles, 0..) |*t, i| {
        const e = tt_srpt + 8 + i * 16;
        const vtsn = try be16(vmg, e + 8);
        const vts_ttn = try be16(vmg, e + 10);
        if (vtsn == 0 or vtsn > n_vts) return error.BadIfo;
        const vts = d.vts[vtsn - 1];
        if (vts_ttn == 0 or vts_ttn > vts.ptts.len) return error.BadIfo;
        const times, const total = try chapterTimes(a, vts, vts.ptts[vts_ttn - 1]);
        t.* = .{
            .vtsn = vtsn,
            .vts_ttn = vts_ttn,
            .n_ptt = try be16(vmg, e + 4),
            .pb_ty = vmg[e],
            .chapter_us = times,
            .duration_us = total,
        };
    }
    return d;
}

// ---- tests ------------------------------------------------------------------------------------------------

const testing = std.testing;

test "BCD playback time at each frame rate" {
    try testing.expectEqual(10_010_000, bcdTimeUs(0x00_00_90_80)); // 00:00:10:00 at 29.97
    try testing.expectEqual(90_480_000, bcdTimeUs(0x00_01_30_92)); // 00:01:30:12 at 25
    try testing.expectEqual(3_603_600_000, bcdTimeUs(0x01_80_80_80)); // 01:00:00:00 at 59.94
    try testing.expectEqual(2_000_000, bcdTimeUs(0x00_80_02_80)); // 00:00:02:00 at 50
}

fn put16(b: []u8, off: usize, v: u16) void {
    std.mem.writeInt(u16, b[off..][0..2], v, .big);
}

fn put32(b: []u8, off: usize, v: u32) void {
    std.mem.writeInt(u32, b[off..][0..4], v, .big);
}

/// A PGCI with 2 programs, 2 cells and one pre, post and cell command each.
fn testPgci() [400]u8 {
    var b: [400]u8 = @splat(0);
    put16(&b, 0, 2); // programs
    put16(&b, 2, 2); // cells
    put32(&b, 4, 0x00_00_90_80); // 10 s at 29.97
    put32(&b, 8, 0x0000_0024); // UOP mask
    put16(&b, 12, 0x8000); // audio stream control #0
    put32(&b, 28, 0x8000_0000); // sub-picture stream control #0
    put16(&b, 156, 4); // next PGCN
    put16(&b, 158, 2); // previous PGCN
    put16(&b, 160, 0xffff); // go-up: resume
    b[164] = 255; // PGC still: infinite
    put16(&b, 168, 304); // command table
    put16(&b, 170, 338); // program map
    put16(&b, 172, 344); // cell playback information
    put32(&b, 240, 0x00_eb_80_80); // HD palette #0
    // Command table: 1 pre, 1 post, 1 cell command, no resume command.
    put16(&b, 304, 1);
    put16(&b, 306, 1);
    put16(&b, 308, 1);
    @memcpy(b[314..322], &[_]u8{ 0x71, 0, 0, 0, 0, 1, 0, 0 });
    @memcpy(b[322..330], &[_]u8{ 0x30, 2, 0, 0, 0, 2, 0, 0 });
    @memcpy(b[330..338], &[_]u8{ 0x20, 0xb5, 0, 0, 0, 1, 0, 2 });
    put16(&b, 338, 1); // program 1 starts at cell 1
    put16(&b, 340, 2); // program 2 at cell 2
    // Cell 2: first cell of an angle block, seamless, STC discontinuity, infinite still, 1 command from #1.
    put32(&b, 344 + 4, 0x00_00_82_80); // cell 1: 2 s
    put32(&b, 344 + 8, 100);
    put32(&b, 344 + 20, 199);
    put32(&b, 372, 0x5a00_ff00);
    put32(&b, 372 + 4, 0x00_00_88_80); // cell 2: 8 s
    put32(&b, 372 + 8, 200);
    put32(&b, 372 + 20, 299);
    put16(&b, 372 + 24, 0x1001);
    return b;
}

test "parse a PGC" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const b = testPgci();
    const cat: u64 = 1 << 63 | 1 << 57 | 3 << 48; // entry, HLI not available, VTS_TTN 3
    const p = try parsePgc(arena.allocator(), &b, 0, cat);

    try testing.expect(p.entry and p.hli_off and !p.resume_prohibited);
    try testing.expectEqual(3, p.vts_ttn);
    try testing.expectEqual(10_010_000, p.duration_us);
    try testing.expectEqual(0x24, p.uop_mask);
    try testing.expectEqual(.{ 4, 2, 0xffff, 255 }, .{ p.next_pgcn, p.prev_pgcn, p.goup_pgcn, p.still });
    try testing.expectEqual(0x8000, p.audio_ctl[0]);
    try testing.expectEqual(0x8000_0000, p.spst_ctl[0]);
    try testing.expectEqual(0x00eb8080, p.hd_palette[0]);
    try testing.expectEqualSlices(u16, &.{ 1, 2 }, p.program_cells);
    try testing.expectEqual(.{ 1, 1, 1, 0 }, .{ p.pre.len, p.post.len, p.cell_cmds.len, p.resume_cmds.len });
    try testing.expectEqual(0x30, p.post[0][0]);

    const c1 = p.cells[0];
    try testing.expectEqual(.{ 100, 199 }, .{ c1.first_sector, c1.last_sector });
    try testing.expectEqual(.{ 0, 0, 0 }, .{ c1.block_mode, c1.still, c1.cmd_count });
    const c2 = p.cells[1];
    try testing.expectEqual(.{ 1, 1 }, .{ c2.block_mode, c2.block_type });
    try testing.expect(c2.seamless and c2.stc_discontinuity);
    try testing.expectEqual(.{ 255, 1, 1 }, .{ c2.still, c2.cmd_count, c2.cmd_first });
    try testing.expectEqual(8_008_000, c2.duration_us);
}

test "a truncated PGC is rejected" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const b = testPgci();
    try testing.expectError(error.BadIfo, parsePgc(arena.allocator(), b[0..300], 0, 0));
    try testing.expectError(error.BadIfo, parsePgc(arena.allocator(), b[0..350], 0, 0)); // cells cut off
}

test "parse a menu table" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var b: [344]u8 = @splat(0);
    put16(&b, 0, 1); // 1 language unit
    put16(&b, 8, ('e' << 8) | 'n');
    put32(&b, 12, 16); // the unit at 16
    put16(&b, 16, 1); // 1 PGC
    std.mem.writeInt(u64, b[24..32], 1 << 63 | 2 << 52, .big); // entry, title menu
    put32(&b, 32, 24); // its PGCI at 16 + 24, after the 12-byte entry
    const lus = try parseMenus(arena.allocator(), &b, 0);
    try testing.expectEqual(1, lus.len);
    try testing.expectEqual(('e' << 8) | 'n', lus[0].lang);
    try testing.expectEqual(1, lus[0].pgcs.len);
    try testing.expect(lus[0].pgcs[0].entry);
    try testing.expectEqual(2, lus[0].pgcs[0].menu_id);
}

test "chapter times count the first angle only" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cell = struct {
        fn make(secs: i64, mode: u2) nav.Cell {
            return .{ .first_sector = 0, .last_sector = 0, .duration_us = secs * 1_000_000, .block_mode = mode, .block_type = if (mode != 0) 1 else 0, .seamless = false, .stc_discontinuity = false, .still = 0, .cmd_count = 0, .cmd_first = 0 };
        }
    };
    var b = testPgci();
    put16(&b, 0, 0);
    put16(&b, 2, 0);
    const empty = try parsePgc(a, &b, 0, 0);

    // PGC 1: 10 s, then a 2-angle block of 4 s, then 6 s (20 s); chapter 2 starts at cell 4. PGC 2: 5 s.
    var cells1 = [_]nav.Cell{ cell.make(10, 0), cell.make(4, 1), cell.make(4, 3), cell.make(6, 0) };
    var programs1 = [_]u16{ 1, 4 };
    var p1 = empty;
    p1.cells = &cells1;
    p1.program_cells = &programs1;
    p1.duration_us = 20_000_000;
    var programs2 = [_]u16{1};
    var p2 = empty;
    p2.program_cells = &programs2;
    p2.duration_us = 5_000_000;
    var pgcs = [_]nav.Pgc{ p1, p2 };
    const vts: nav.Vts = .{ .title_pgcs = &pgcs, .ptts = &.{}, .menus = &.{}, .title_evos = &.{}, .menu_evos = &.{} };

    const times, const total = try chapterTimes(a, vts, &.{ .{ .pgcn = 1, .pgn = 1 }, .{ .pgcn = 1, .pgn = 2 }, .{ .pgcn = 2, .pgn = 1 } });
    try testing.expectEqualSlices(i64, &.{ 0, 14_000_000, 20_000_000 }, times);
    try testing.expectEqual(25_000_000, total);
    try testing.expectError(error.BadIfo, chapterTimes(a, vts, &.{.{ .pgcn = 3, .pgn = 1 }}));
}
