//! The HD DVD Standard Content navigation VM: registers, navigation
//! commands, PGC/cell sequencing, Link/Jump/Call and user operations. Pure logic with no VLC dependency:
//! the player asks which cell to present (`cell()`), reports when it has been presented (`cellPresented()`),
//! times stills (`phase`), and forwards user input (button commands, menu calls, title/chapter selection).
//! Reference: HD DVD Vol. 2 §5.1.3 and §5.2.4.

const std = @import("std");
const nav = @import("nav.zig");

pub const Domain = enum { fp, vmgm, vtsm, tt };

pub const Phase = enum {
    /// No PGC running (Exit, end of a PGC with nowhere to go, or nothing to play).
    stopped,
    /// Present cell `celln` of the current PGC.
    play_cell,
    /// After a cell: hold the last picture for `still` seconds (255 = until user input).
    cell_still,
    /// After the last cell of a PGC.
    pgc_still,
};

/// The menus a user can call (Menu_Call), by menu ID.
pub const Menu = enum(u4) { title = 2, root = 3, subpicture = 4, audio = 5, angle = 6, chapter = 7 };

const Link = union(enum) {
    sins: struct { sub: u8 },
    pgcn: u16,
    pttn: u16,
    pgn: u16,
    cn: u16,
    exit,
    jump_tt: u16,
    jump_vts_tt: u16,
    jump_vts_ptt: struct { ttn: u16, ptt: u16 },
    jump_ss: struct { dom: u2, menu: u4, pgcn: u16, vtsn: u16, ttn: u16 },
    call_ss: struct { dom: u2, menu: u4, pgcn: u16, cell: u16 },
};

/// Result of one command.
const Step = union(enum) { next, goto: u16, brk, link: Link };

const Resume = struct {
    vtsn: u16,
    pgcn: u16,
    celln: u16,
    sprm: [5]u16, // SPRM4..8
};

pub const Vm = struct {
    disc: *const nav.Disc,
    gprm: [64]u16 = @splat(0),
    /// Debugging: values the GPRMs take instead of 0 whenever they are reset (bit n of preset_mask = GPRMn).
    preset: [64]u16 = @splat(0),
    preset_mask: u64 = 0,
    gprm_counter: [64]bool = @splat(false),
    sprm: [32]u16 = @splat(0),
    rng: std.Random.DefaultPrng,

    domain: Domain = .fp,
    /// VTS of VTSM_DOM / TT_DOM (1-based).
    vtsn: u16 = 0,
    /// Language unit index of the current menu domain.
    lu: usize = 0,
    pgcn: u16 = 0,
    pgn: u16 = 0,
    celln: u16 = 0,
    phase: Phase = .stopped,
    still: u8 = 0,
    rsm: ?Resume = null,
    /// Incremented every time a cell (re)starts, so the player knows to reposition.
    generation: u32 = 0,
    /// Sector offset into the cell where presentation starts (time search), else 0.
    start_offset: u32 = 0,
    /// Commands executed without presenting anything; stops runaway command loops.
    budget: u32 = 0,

    pub fn init(disc: *const nav.Disc, seed: u64) Vm {
        var vm: Vm = .{ .disc = disc, .rng = .init(seed) };
        vm.resetRegisters();
        return vm;
    }

    fn resetGprms(vm: *Vm) void {
        for (&vm.gprm, 0..) |*g, n| g.* = if ((vm.preset_mask >> @intCast(n)) & 1 != 0) vm.preset[n] else 0;
    }

    /// Debugging: GPRMn takes value v (instead of 0) now and on every later reset.
    pub fn presetGprm(vm: *Vm, n: u6, v: u16) void {
        vm.preset[n] = v;
        vm.preset_mask |= @as(u64, 1) << n;
        vm.gprm[n] = v;
    }

    /// Initial Access values (spec defaults; where the spec leaves a value to the player, a common choice).
    fn resetRegisters(vm: *Vm) void {
        vm.resetGprms();
        vm.gprm_counter = @splat(false);
        vm.sprm = @splat(0);
        const en: u16 = ('e' << 8) | 'n';
        vm.sprm[0] = en; // menu language
        vm.sprm[1] = 15; // audio: none yet (player picks)
        vm.sprm[2] = 62; // sub-picture: none
        vm.sprm[3] = 1; // angle
        vm.sprm[4] = 1;
        vm.sprm[5] = 1;
        vm.sprm[6] = 1;
        vm.sprm[7] = 1;
        vm.sprm[8] = 1 << 10; // highlighted button 1
        vm.sprm[12] = ('U' << 8) | 'S';
        vm.sprm[13] = 15; // parental level: none
        vm.sprm[14] = 0x3000; // 16:9 display, normal mode
        vm.sprm[15] = 0x4000; // DD+ capable
        vm.sprm[16] = en;
        vm.sprm[18] = en;
        vm.sprm[21] = en;
        vm.sprm[26] = 15;
        vm.sprm[27] = 62;
        vm.sprm[28] = 1;
        vm.sprm[29] = 15;
        vm.sprm[30] = 62;
    }

    // ---- state accessors ----------------------------------------------------------------------------

    pub fn vts(vm: *const Vm) ?*const nav.Vts {
        if (vm.vtsn == 0 or vm.vtsn > vm.disc.vts.len) return null;
        return &vm.disc.vts[vm.vtsn - 1];
    }

    fn menuLus(vm: *const Vm, dom: Domain) []const nav.MenuLu {
        return switch (dom) {
            .vmgm => vm.disc.vmgm,
            .vtsm => if (vm.vts()) |v| v.menus else &.{},
            else => &.{},
        };
    }

    /// The PGC list of the current domain (FP_DOM has a single PGC).
    fn pgcList(vm: *const Vm) []const nav.Pgc {
        return switch (vm.domain) {
            .fp => if (vm.disc.fp_pgc) |*p| p[0..1] else &.{},
            .vmgm, .vtsm => blk: {
                const lus = vm.menuLus(vm.domain);
                break :blk if (vm.lu < lus.len) lus[vm.lu].pgcs else &.{};
            },
            .tt => if (vm.vts()) |v| v.title_pgcs else &.{},
        };
    }

    pub fn pgc(vm: *const Vm) ?*const nav.Pgc {
        const list = vm.pgcList();
        if (vm.pgcn == 0 or vm.pgcn > list.len) return null;
        return &list[vm.pgcn - 1];
    }

    pub fn cell(vm: *const Vm) ?nav.Cell {
        if (vm.phase == .stopped) return null;
        const p = vm.pgc() orelse return null;
        if (vm.celln == 0 or vm.celln > p.cells.len) return null;
        return p.cells[vm.celln - 1];
    }

    /// Disc-relative paths of the EVOBS the current cell's sector numbers refer to.
    pub fn evos(vm: *const Vm) []const []u8 {
        return switch (vm.domain) {
            .fp, .vmgm => vm.disc.vmgm_evos,
            .vtsm => if (vm.vts()) |v| v.menu_evos else &.{},
            .tt => if (vm.vts()) |v| v.title_evos else &.{},
        };
    }

    pub fn inMenu(vm: *const Vm) bool {
        return vm.domain != .tt;
    }

    /// Highlighted button number from SPRM8 (b15..10).
    pub fn button(vm: *const Vm) u8 {
        return @intCast(vm.sprm[8] >> 10);
    }

    pub fn setButton(vm: *Vm, n: u8) void {
        vm.sprm[8] = @as(u16, n & 0x3f) << 10;
    }

    /// Audio / sub-picture stream registers of the current space (TT: 1/2, menus: 26/27, FP: 29/30).
    pub fn audioStream(vm: *const Vm) u16 {
        return switch (vm.domain) {
            .tt => vm.sprm[1],
            .vmgm, .vtsm => vm.sprm[26],
            .fp => vm.sprm[29],
        };
    }

    pub fn subpictureStream(vm: *const Vm) u16 {
        return switch (vm.domain) {
            .tt => vm.sprm[2],
            .vmgm, .vtsm => vm.sprm[27],
            .fp => vm.sprm[30],
        };
    }

    /// TT_DOM title number (SPRM4) and chapter (SPRM7), for the player's title/chapter display.
    pub fn titleChapter(vm: *const Vm) struct { u16, u16 } {
        return .{ vm.sprm[4], vm.sprm[7] };
    }

    /// Whether user operation `uop` (Annex J numbering) is permitted by the title and PGC masks; the player
    /// also checks the EVOBU mask from the PCI.
    pub fn uopAllowed(vm: *const Vm, uop: u5, evobu_mask: u32) bool {
        const mask = @as(u32, 1) << uop;
        if (evobu_mask & mask != 0) return false;
        if (vm.pgc()) |p| if (p.uop_mask & mask != 0) return false;
        if (vm.domain == .tt and uop <= 1 and vm.sprm[4] >= 1 and vm.sprm[4] <= vm.disc.titles.len) {
            if (vm.disc.titles[vm.sprm[4] - 1].pb_ty & mask != 0) return false;
        }
        return true;
    }

    // ---- registers --------------------------------------------------------------------------------------

    fn reg(vm: *Vm, byte: u8) u16 {
        return if (byte & 0x80 != 0) vm.sprm[byte & 0x1f] else vm.gprm[byte & 0x3f];
    }

    fn compare(op: u3, a: u16, b: u16) bool {
        return switch (op) {
            0 => true,
            1 => a & b != 0,
            2 => a == b,
            3 => a != b,
            4 => a >= b,
            5 => a > b,
            6 => a <= b,
            7 => a < b,
        };
    }

    /// Set instruction on GPRM `dst` with source value `src` (`src_reg` = source register byte for Swp).
    fn set(vm: *Vm, op: u4, dst: u8, src: u16, src_reg: ?u8) void {
        const d = dst & 0x3f;
        const a: u32 = vm.gprm[d];
        const b: u32 = src;
        const r: u32 = switch (op) {
            1 => b,
            2 => blk: {
                if (src_reg) |sr| if (sr & 0x80 == 0) {
                    vm.gprm[sr & 0x3f] = @intCast(a);
                };
                break :blk b;
            },
            3 => @min(a + b, 0xffff),
            4 => if (a > b) a - b else 0,
            5 => @min(a * b, 0xffff),
            6 => if (b == 0) 0xffff else a / b,
            7 => if (b == 0) 0xffff else a % b,
            8 => if (b == 0) 0 else vm.rng.random().intRangeAtMost(u32, 1, b),
            9 => a & b,
            10 => a | b,
            11 => a ^ b,
            else => a,
        };
        vm.gprm[d] = @intCast(r);
    }

    /// SetSystem (type 2): `op` b59..56, immediate flag b60, operand bits of the whole command `v`.
    fn setSystem(vm: *Vm, op: u4, imm: bool, v: u64) void {
        switch (op) {
            1, 9, 10 => { // SetSTN / SetM_STN / SetFP_STN
                const base: [3]usize = switch (op) {
                    1 => .{ 1, 2, 3 },
                    9 => .{ 26, 27, 28 },
                    else => .{ 29, 30, 0 },
                };
                if (bit(v, 39)) vm.sprm[base[0]] = if (imm) @intCast(bits(v, 35, 4)) else vm.gprm[bits(v, 37, 6)] & 0xf;
                if (bit(v, 31)) vm.sprm[base[1]] = if (imm) @intCast(bits(v, 30, 7)) else vm.gprm[bits(v, 29, 6)] & 0x7f;
                if (op != 10 and bit(v, 23)) vm.sprm[base[2]] = if (imm) @intCast(bits(v, 19, 4)) else vm.gprm[bits(v, 21, 6)] & 0xf;
            },
            2 => { // SetNVTMR
                vm.sprm[9] = if (imm) @intCast(bits(v, 47, 16)) else vm.gprm[bits(v, 37, 6)];
                vm.sprm[10] = @intCast(bits(v, 30, 15));
            },
            3 => { // SetGPRMMD
                const g = bits(v, 21, 6);
                vm.gprm[g] = if (imm) @intCast(bits(v, 47, 16)) else vm.gprm[bits(v, 37, 6)];
                vm.gprm_counter[g] = bit(v, 23);
            },
            6 => { // SetHL_BTNN
                if (imm) {
                    vm.setButton(@intCast(bits(v, 31, 6)));
                } else {
                    const g = vm.gprm[bits(v, 21, 6)];
                    vm.sprm[8] = if (g < 0x400) g << 10 else g & 0xfc00;
                }
            },
            8 => vm.sprm[0] = if (imm) @intCast(bits(v, 31, 16)) else vm.gprm[bits(v, 21, 6)], // SetM_LCD
            else => {},
        }
    }

    fn bits(v: u64, comptime hi: u6, comptime n: u7) u64 {
        const shift = @as(u7, hi) + 1 - n;
        return (v >> @intCast(shift)) & ((@as(u64, 1) << @intCast(n)) - 1);
    }

    fn bit(v: u64, comptime b: u6) bool {
        return (v >> b) & 1 != 0;
    }

    /// Link part (option b51..48, operand b15..0) of types 1-3; sets SPRM8 from the button field.
    fn decodeLink(vm: *Vm, op: u64, v: u64) ?Link {
        const operand = bits(v, 15, 16);
        const btn: u8 = @intCast(operand >> 10);
        if (op != 4 and btn != 0) vm.setButton(btn);
        return switch (op) {
            1 => .{ .sins = .{ .sub = @intCast(operand & 0x1f) } },
            4 => .{ .pgcn = @intCast(operand & 0x7fff) },
            5 => .{ .pttn = @intCast(operand & 0x3ff) },
            6 => .{ .pgn = @intCast(operand & 0x1ff) },
            7 => .{ .cn = @intCast(operand & 0x1ff) },
            0xC => .{ .pgcn = vm.gprm[operand & 0x3f] & 0x7fff },
            0xD => .{ .pttn = vm.gprm[operand & 0x3f] & 0x3ff },
            0xE => .{ .pgn = vm.gprm[operand & 0x3f] & 0x1ff },
            0xF => .{ .cn = vm.gprm[operand & 0x3f] & 0x1ff },
            else => null,
        };
    }

    /// LinkSIns of types 4-6 (operand b15..0).
    fn sinsLink(vm: *Vm, v: u64) Link {
        const operand = bits(v, 15, 16);
        const btn: u8 = @intCast(operand >> 10);
        if (btn != 0) vm.setButton(btn);
        return .{ .sins = .{ .sub = @intCast(operand & 0x1f) } };
    }

    fn decodeJump(op: u64, v: u64) ?Link {
        return switch (op) {
            1 => .exit,
            2 => .{ .jump_tt = @intCast(bits(v, 24, 9)) },
            3 => .{ .jump_vts_tt = @intCast(bits(v, 24, 9)) },
            5 => .{ .jump_vts_ptt = .{ .ttn = @intCast(bits(v, 24, 9)), .ptt = @intCast(bits(v, 41, 10)) } },
            6 => .{ .jump_ss = .{
                .dom = @intCast(bits(v, 21, 2)),
                .menu = @intCast(bits(v, 19, 4)),
                .pgcn = @intCast(bits(v, 46, 15)),
                .vtsn = @intCast(bits(v, 31, 9)),
                .ttn = @intCast(bits(v, 40, 9)),
            } },
            8 => .{ .call_ss = .{
                .dom = @intCast(bits(v, 21, 2)),
                .menu = @intCast(bits(v, 19, 4)),
                .pgcn = @intCast(bits(v, 46, 15)),
                .cell = @intCast(bits(v, 31, 9)),
            } },
            0xF => .exit, // CallAdvancedContentPlayer: not supported, stop
            else => null,
        };
    }

    /// Executes one command (docs §2).
    fn exec(vm: *Vm, c: nav.Cmd) Step {
        const v = std.mem.readInt(u64, &c, .big);
        const typ = bits(v, 63, 3);
        const cmp_op: u3 = @intCast(bits(v, 54, 3));
        const cmp_imm = bit(v, 55);
        const set_op: u4 = @intCast(bits(v, 59, 4));
        const set_imm = bit(v, 60);
        const br = bits(v, 51, 4);

        switch (typ) {
            0 => { // Nop / GoTo / Break / SetTmpPML, optional compare
                const a = vm.gprm[bits(v, 39, 8) & 0x3f];
                const b: u16 = if (cmp_imm) @intCast(bits(v, 31, 16)) else vm.reg(@intCast(bits(v, 23, 8)));
                if (cmp_op != 0 and !compare(cmp_op, a, b)) return .next;
                return switch (br) {
                    1 => .{ .goto = @intCast(bits(v, 9, 10)) },
                    2 => .brk,
                    3 => blk: {
                        vm.sprm[13] = @intCast(bits(v, 15, 4));
                        break :blk .{ .goto = @intCast(bits(v, 9, 10)) };
                    },
                    else => .next,
                };
            },
            1 => {
                if (!set_imm) { // Link
                    const a = vm.gprm[bits(v, 39, 8) & 0x3f];
                    const b: u16 = if (cmp_imm) @intCast(bits(v, 31, 16)) else vm.reg(@intCast(bits(v, 23, 8)));
                    if (cmp_op != 0 and !compare(cmp_op, a, b)) return .next;
                    return if (vm.decodeLink(br, v)) |l| .{ .link = l } else .next;
                }
                // Jump (compare registers only)
                const a = vm.gprm[bits(v, 15, 8) & 0x3f];
                const b = vm.reg(@intCast(bits(v, 7, 8)));
                if (cmp_op != 0 and !compare(cmp_op, a, b)) return .next;
                return if (decodeJump(br, v)) |l| .{ .link = l } else .next;
            },
            2 => { // SetSystem; if (cmp) SetSystem; or SetSystem; Link
                if (cmp_op != 0) {
                    const a = vm.gprm[bits(v, 15, 8) & 0x3f];
                    const b = vm.reg(@intCast(bits(v, 7, 8)));
                    if (!compare(cmp_op, a, b)) return .next;
                    vm.setSystem(set_op, set_imm, v);
                    return .next;
                }
                vm.setSystem(set_op, set_imm, v);
                return if (br != 0) (if (vm.decodeLink(br, v)) |l| .{ .link = l } else .next) else .next;
            },
            3 => { // Set; if (cmp) Set; or Set; Link
                const dst: u8 = @intCast(bits(v, 39, 8));
                const src_reg: u8 = @intCast(bits(v, 23, 8));
                const src: u16 = if (set_imm) @intCast(bits(v, 31, 16)) else vm.reg(src_reg);
                if (cmp_op != 0) {
                    const a = vm.gprm[bits(v, 47, 8) & 0x3f];
                    const b: u16 = if (cmp_imm) @intCast(bits(v, 15, 16)) else vm.reg(@intCast(bits(v, 7, 8)));
                    if (!compare(cmp_op, a, b)) return .next;
                    vm.set(set_op, dst, src, if (set_imm) null else src_reg);
                    return .next;
                }
                vm.set(set_op, dst, src, if (set_imm) null else src_reg);
                return if (br != 0) (if (vm.decodeLink(br, v)) |l| .{ .link = l } else .next) else .next;
            },
            4 => { // Set; if (cmp on the new value) LinkSIns
                const g: u8 = @intCast(br); // SCG, GPRM0..15
                const src_reg: u8 = @intCast(bits(v, 39, 8));
                const src: u16 = if (set_imm) @intCast(bits(v, 47, 16)) else vm.reg(src_reg);
                vm.set(set_op, g, src, if (set_imm) null else src_reg);
                const b: u16 = if (cmp_imm) @intCast(bits(v, 31, 16)) else vm.reg(@intCast(bits(v, 23, 8)));
                if (cmp_op != 0 and !compare(cmp_op, vm.gprm[g], b)) return .next;
                return .{ .link = vm.sinsLink(v) };
            },
            5, 6 => { // if (cmp) { Set; LinkSIns } / if (cmp) Set; LinkSIns
                const g: u8 = @intCast(br); // SDG
                var src: u16 = undefined;
                var src_reg: ?u8 = null;
                var a: u16 = undefined;
                var b: u16 = undefined;
                if (!set_imm) {
                    src_reg = @intCast(bits(v, 47, 8));
                    src = vm.reg(src_reg.?);
                    a = vm.gprm[bits(v, 39, 8) & 0x3f];
                    b = if (cmp_imm) @intCast(bits(v, 31, 16)) else vm.reg(@intCast(bits(v, 23, 8)));
                } else {
                    src = @intCast(bits(v, 47, 16));
                    a = vm.gprm[bits(v, 31, 8) & 0x3f];
                    b = vm.reg(@intCast(bits(v, 23, 8)));
                }
                const ok = cmp_op == 0 or compare(cmp_op, a, b);
                if (ok) vm.set(set_op, g, src, src_reg);
                if (typ == 5 and !ok) return .next;
                return .{ .link = vm.sinsLink(v) };
            },
            else => return .next,
        }
    }

    /// Runs a command area; returns the branch it ends with, if any. GoTo numbers are relative to `area`.
    fn run(vm: *Vm, area: []const nav.Cmd) ?Link {
        var i: usize = 0;
        while (i < area.len) {
            vm.budget += 1;
            if (vm.budget > 100_000) return .exit;
            switch (vm.exec(area[i])) {
                .next => i += 1,
                .goto => |n| {
                    if (n == 0 or n > area.len) return null;
                    i = n - 1;
                },
                .brk => return null,
                .link => |l| return l,
            }
        }
        return null;
    }

    // ---- sequencing -------------------------------------------------------------------------------------

    /// Initial Access: First Play PGC, or stop.
    pub fn start(vm: *Vm) void {
        vm.budget = 0;
        if (vm.disc.fp_pgc == null) {
            vm.phase = .stopped;
            return;
        }
        vm.domain = .fp;
        vm.pgcn = 1;
        vm.playPgc(1, true);
    }

    /// Starts PGC `n` of the current domain: pre-commands (unless `run_pre` is false), then program `pgn`.
    fn playPgc(vm: *Vm, pgn: u16, run_pre: bool) void {
        const p = vm.pgc() orelse return vm.stop();
        if (run_pre) {
            if (vm.run(p.pre)) |l| return vm.link(l);
        }
        if (p.cells.len == 0) return vm.pgcEnd();
        vm.playProgram(pgn);
    }

    fn playProgram(vm: *Vm, pgn: u16) void {
        const p = vm.pgc() orelse return vm.stop();
        if (pgn == 0 or pgn > p.program_cells.len) return vm.pgcEnd();
        vm.pgn = pgn;
        vm.playCell(p.program_cells[pgn - 1]);
    }

    /// Starts cell `n` (1-based) of the current PGC, picking the current angle inside an angle block.
    fn playCell(vm: *Vm, n: u16) void {
        const p = vm.pgc() orelse return vm.stop();
        if (n == 0 or n > p.cells.len) return vm.pgcEnd();
        var target = n;
        const c = p.cells[n - 1];
        if (c.block_type == 1 and c.block_mode == 1) {
            const angle = if (vm.domain == .tt) vm.sprm[3] else vm.sprm[28];
            const want = n + (angle -| 1);
            if (want <= p.cells.len and p.cells[want - 1].block_type == 1) target = want;
        }
        vm.celln = target;
        vm.updatePgn();
        vm.phase = .play_cell;
        vm.start_offset = 0;
        vm.generation +%= 1;
        vm.budget = 0;
    }

    /// Keeps PGN (and SPRM7, the PTT number) in step with the current cell.
    fn updatePgn(vm: *Vm) void {
        const p = vm.pgc() orelse return;
        var pg: u16 = 1;
        for (p.program_cells, 1..) |first, i| {
            if (first <= vm.celln) pg = @intCast(i);
        }
        vm.pgn = pg;
        if (vm.domain != .tt) return;
        const v = vm.vts() orelse return;
        const ttn = vm.sprm[5];
        if (ttn == 0 or ttn > v.ptts.len) return;
        for (v.ptts[ttn - 1], 1..) |ptt, i| {
            if (ptt.pgcn == vm.pgcn and ptt.pgn == pg) vm.sprm[7] = @intCast(i);
        }
    }

    /// The player finished presenting the current cell's data.
    pub fn cellPresented(vm: *Vm) void {
        const c = vm.cell() orelse return vm.stop();
        if (c.still != 0) {
            vm.phase = .cell_still;
            vm.still = c.still;
            return;
        }
        vm.cellPost();
    }

    /// The current still is over (timer expired, or Still_Off by the user).
    pub fn stillDone(vm: *Vm) void {
        switch (vm.phase) {
            .cell_still => vm.cellPost(),
            .pgc_still => vm.pgcPost(),
            else => {},
        }
    }

    /// Cell commands, then the next cell (skipping the other angles of a block).
    fn cellPost(vm: *Vm) void {
        const p = vm.pgc() orelse return vm.stop();
        const c = p.cells[vm.celln - 1];
        if (c.cmd_count != 0 and c.cmd_first != 0) {
            const first: usize = c.cmd_first - 1;
            if (first < p.cell_cmds.len) {
                const group = p.cell_cmds[first..@min(p.cell_cmds.len, first + c.cmd_count)];
                if (vm.run(group)) |l| return vm.link(l);
            }
        }
        var next = vm.celln + 1;
        if (c.block_type == 1 and c.block_mode != 0 and c.block_mode != 3) {
            while (next <= p.cells.len and p.cells[next - 1].block_mode != 0 and p.cells[next - 2].block_mode != 3) next += 1;
        }
        if (next > p.cells.len) return vm.pgcEnd();
        vm.playCell(next);
    }

    fn pgcEnd(vm: *Vm) void {
        const p = vm.pgc() orelse return vm.stop();
        if (p.still != 0) {
            vm.phase = .pgc_still;
            vm.still = p.still;
            return;
        }
        vm.pgcPost();
    }

    fn pgcPost(vm: *Vm) void {
        const p = vm.pgc() orelse return vm.stop();
        if (vm.run(p.post)) |l| return vm.link(l);
        if (p.next_pgcn != 0) {
            vm.pgcn = p.next_pgcn;
            return vm.playPgc(1, true);
        }
        vm.stop();
    }

    fn stop(vm: *Vm) void {
        vm.phase = .stopped;
        vm.generation +%= 1;
    }

    // ---- links ------------------------------------------------------------------------------------------

    fn link(vm: *Vm, l: Link) void {
        const p = vm.pgc();
        switch (l) {
            .sins => |s| switch (s.sub) {
                0 => {}, // LinkNoLink: only the button changed
                1 => vm.playCell(vm.celln), // TopC
                2 => if (p != null and vm.celln < p.?.cells.len) vm.playCell(vm.celln + 1) else vm.pgcEnd(),
                3 => vm.playCell(@max(vm.celln, 2) - 1),
                5 => vm.playProgram(vm.pgn),
                6 => if (p != null and vm.pgn < p.?.program_cells.len) vm.playProgram(vm.pgn + 1) else vm.pgcPost(),
                7 => if (vm.pgn > 1) vm.playProgram(vm.pgn - 1) else if (p != null and p.?.prev_pgcn != 0) vm.toPgc(p.?.prev_pgcn) else vm.playProgram(1),
                9 => vm.toPgc(vm.pgcn),
                0xA => if (p != null and p.?.next_pgcn != 0) vm.toPgc(p.?.next_pgcn),
                0xB => if (p != null and p.?.prev_pgcn != 0) vm.toPgc(p.?.prev_pgcn),
                0xC => if (p) |pp| {
                    if (pp.goup_pgcn == 0xffff) vm.doResume() else if (pp.goup_pgcn != 0) vm.toPgc(pp.goup_pgcn);
                },
                0xD => vm.pgcEnd(),
                0x10 => vm.doResume(),
                else => {},
            },
            .pgcn => |n| vm.toPgc(n),
            .pttn => |n| vm.toPtt(n, false),
            .pgn => |n| vm.playProgram(n),
            .cn => |n| vm.playCell(n),
            .exit => {
                vm.rsm = null;
                vm.stop();
            },
            .jump_tt => |n| vm.jumpTitle(n, 1, true),
            .jump_vts_tt => |n| if (vm.titleOfVtsTtn(n)) |t| vm.jumpTitle(t, 1, true),
            .jump_vts_ptt => |j| if (vm.titleOfVtsTtn(j.ttn)) |t| vm.jumpTitle(t, j.ptt, true),
            .jump_ss => |j| vm.jumpSystem(j.dom, j.menu, j.pgcn, j.vtsn, j.ttn),
            .call_ss => |c| {
                if (vm.domain == .tt) vm.saveResume(c.cell);
                vm.jumpSystem(c.dom, c.menu, c.pgcn, 0, 0);
            },
        }
    }

    fn toPgc(vm: *Vm, n: u16) void {
        vm.pgcn = n;
        vm.playPgc(1, true);
    }

    /// LinkPTTN: chapter `n` of the current title, without the target PGC's pre-commands.
    fn toPtt(vm: *Vm, n: u16, run_pre: bool) void {
        const v = vm.vts() orelse return vm.stop();
        const ttn = vm.sprm[5];
        if (vm.domain != .tt or ttn == 0 or ttn > v.ptts.len or n == 0 or n > v.ptts[ttn - 1].len) return;
        const ptt = v.ptts[ttn - 1][n - 1];
        vm.pgcn = ptt.pgcn;
        vm.sprm[6] = ptt.pgcn;
        vm.sprm[7] = n;
        vm.playPgc(ptt.pgn, run_pre);
    }

    fn titleOfVtsTtn(vm: *const Vm, ttn: u16) ?u16 {
        for (vm.disc.titles, 1..) |t, i| {
            if (t.vtsn == vm.vtsn and t.vts_ttn == ttn) return @intCast(i);
        }
        return null;
    }

    /// JumpTT / JumpVTS_TT / JumpVTS_PTT: enter title `ttn` at chapter `ptt`, running that PGC's pre-commands.
    fn jumpTitle(vm: *Vm, ttn: u16, ptt: u16, run_pre: bool) void {
        if (ttn == 0 or ttn > vm.disc.titles.len) return vm.stop();
        const t = vm.disc.titles[ttn - 1];
        vm.domain = .tt;
        vm.vtsn = t.vtsn;
        vm.sprm[4] = ttn;
        vm.sprm[5] = t.vts_ttn;
        vm.sprm[9] = 0; // navigation timer off
        const v = vm.vts() orelse return vm.stop();
        if (t.vts_ttn > v.ptts.len or v.ptts[t.vts_ttn - 1].len == 0) return vm.stop();
        const list = v.ptts[t.vts_ttn - 1];
        const p = list[@min(ptt, list.len) - 1];
        vm.pgcn = p.pgcn;
        vm.sprm[6] = p.pgcn;
        vm.sprm[7] = @intCast(@min(ptt, list.len));
        vm.playPgc(p.pgn, run_pre);
    }

    fn pickLu(vm: *Vm, dom: Domain) bool {
        const lus = vm.menuLus(dom);
        if (lus.len == 0) return false;
        vm.lu = 0;
        for (lus, 0..) |lu, i| {
            if (lu.lang == vm.sprm[0]) vm.lu = i;
        }
        return true;
    }

    fn menuEntry(vm: *const Vm, menu: u4) ?u16 {
        for (vm.pgcList(), 1..) |pg, i| {
            if (pg.entry and pg.menu_id == menu) return @intCast(i);
        }
        return null;
    }

    /// JumpSS / CallSS targets: 0 First Play, 1 VMGM menu by ID, 2 VTSM menu by ID, 3 VMGM PGC by number.
    fn jumpSystem(vm: *Vm, dom: u2, menu: u4, pgcn: u16, vtsn: u16, ttn: u16) void {
        switch (dom) {
            0 => {
                if (vm.disc.fp_pgc == null) return vm.stop();
                vm.domain = .fp;
                vm.pgcn = 1;
                vm.playPgc(1, true);
            },
            1, 3 => {
                vm.domain = .vmgm;
                if (!vm.pickLu(.vmgm)) return vm.stop();
                vm.pgcn = if (dom == 3) pgcn else vm.menuEntry(menu) orelse return vm.stop();
                vm.playPgc(1, true);
            },
            2 => {
                if (vtsn != 0) vm.vtsn = vtsn;
                if (ttn != 0) vm.sprm[5] = ttn;
                vm.domain = .vtsm;
                if (!vm.pickLu(.vtsm)) return vm.stop();
                vm.pgcn = vm.menuEntry(menu) orelse return vm.stop();
                vm.playPgc(1, true);
            },
        }
    }

    fn saveResume(vm: *Vm, cell_n: u16) void {
        const p = vm.pgc() orelse return;
        if (p.resume_prohibited) return;
        vm.rsm = .{
            .vtsn = vm.vtsn,
            .pgcn = vm.pgcn,
            .celln = if (cell_n != 0) cell_n else vm.celln,
            .sprm = vm.sprm[4..9].*,
        };
    }

    /// RSM / Resume(): back to the saved title position, through the PGC's resume commands.
    fn doResume(vm: *Vm) void {
        const r = vm.rsm orelse {
            vm.stop();
            return;
        };
        vm.domain = .tt;
        vm.vtsn = r.vtsn;
        vm.pgcn = r.pgcn;
        vm.sprm[4..9].* = r.sprm;
        const p = vm.pgc() orelse return vm.stop();
        if (p.resume_cmds.len > 0) {
            if (vm.run(p.resume_cmds)) |l| return vm.link(l);
        }
        vm.playCell(r.celln);
    }

    // ---- user operations --------------------------------------------------------------------------------

    /// Runs a button's 8 commands (Button_Activate).
    pub fn activateButton(vm: *Vm, cmds: []const nav.Cmd) void {
        vm.budget = 0;
        if (vm.run(cmds)) |l| vm.link(l);
    }

    /// Title_Play(n): resets the registers' title state, then JumpTT.
    pub fn titlePlay(vm: *Vm, ttn: u16) void {
        vm.budget = 0;
        vm.resetGprms();
        vm.jumpTitle(ttn, 1, true);
    }

    /// PTT_Play(title, chapter).
    pub fn pttPlay(vm: *Vm, ttn: u16, ptt: u16) void {
        vm.budget = 0;
        if (vm.domain == .tt and vm.sprm[4] == ttn) return vm.toPtt(ptt, false); // PTT_Search within the title
        vm.resetGprms();
        vm.jumpTitle(ttn, ptt, true);
    }

    /// Menu_Call(menu): CallSS from a title (saving the resume point), JumpSS from a menu.
    pub fn menuCall(vm: *Vm, menu: Menu) bool {
        vm.budget = 0;
        const id: u4 = @intFromEnum(menu);
        const dom: u2 = if (menu == .title) 1 else 2;
        // Check the target exists before leaving the current position.
        const lus = if (dom == 1) vm.disc.vmgm else if (vm.vts()) |v| v.menus else &.{};
        var found = false;
        for (lus) |lu| for (lu.pgcs) |pg| {
            if (pg.entry and pg.menu_id == id) found = true;
        };
        if (!found) return false;
        if (vm.domain == .tt) vm.saveResume(0);
        vm.jumpSystem(dom, id, 0, 0, 0);
        return true;
    }

    /// Resume() from a menu.
    pub fn userResume(vm: *Vm) bool {
        if (vm.rsm == null or vm.domain == .tt) return false;
        vm.budget = 0;
        vm.doResume();
        return true;
    }

    /// Next/Prev/TopPG_Search.
    pub fn nextProgram(vm: *Vm) void {
        vm.link(.{ .sins = .{ .sub = 6 } });
    }

    pub fn prevProgram(vm: *Vm) void {
        vm.link(.{ .sins = .{ .sub = 7 } });
    }

    /// Time search within the current PGC: start cell `n` at sector offset `offset`.
    pub fn seekCell(vm: *Vm, n: u16, offset: u32) void {
        vm.playCell(n);
        vm.start_offset = offset;
    }
};
