//! Navigation data of a Standard Content disc, as the VM needs it (filled by ifo.zig).
//! Layouts: HD DVD Vol. 2 §5.2; semantics: §5.1.3.

const std = @import("std");

pub const sector_size = 2048;

/// One 8-byte navigation command (big-endian, b63 = MSB of byte 0).
pub const Cmd = [8]u8;

pub const Cell = struct {
    /// Sector range in the cell's EVOBS (title EVOs for TT_DOM, menu EVOs for menus), inclusive.
    first_sector: u32,
    last_sector: u32,
    duration_us: i64,
    /// C_CAT b31..30: 00 not in a block, 01 first, 10 middle, 11 last cell of a block.
    block_mode: u2,
    /// C_CAT b29..28: 01 = angle block.
    block_type: u2,
    seamless: bool,
    /// First cell of an EVOB: timestamps restart, VLC's clock must be reset.
    stc_discontinuity: bool,
    /// Cell still: 0 none, 1..254 s, 255 infinite.
    still: u8,
    /// Cell command group: `cmd_count` commands starting at cell command `cmd_first` (1-based); 0 = none.
    cmd_count: u8,
    cmd_first: u16,

    pub fn bytes(c: Cell) u64 {
        return (@as(u64, c.last_sector) - c.first_sector + 1) * sector_size;
    }
};

pub const Pgc = struct {
    /// Entry cell number (1-based) of each program.
    program_cells: []u16,
    cells: []Cell,
    pre: []Cmd,
    post: []Cmd,
    cell_cmds: []Cmd,
    resume_cmds: []Cmd,
    next_pgcn: u16,
    prev_pgcn: u16,
    /// 0xFFFF = resume (menus).
    goup_pgcn: u16,
    /// 0 sequential, 0x001-0x1FF random, 0x201-0x3FF shuffle.
    playback_mode: u16,
    still: u8,
    uop_mask: u32,
    audio_ctl: [8]u16,
    spst_ctl: [32]u32,
    /// 16 x 0x00YYCrCb.
    sd_palette: [16]u32,
    hd_palette: [16]u32,
    duration_us: i64,
    // From the PGC category (PGCI search pointer):
    entry: bool,
    resume_prohibited: bool,
    /// b57 = 1: ignore HLI and button sub-pictures in this PGC.
    hli_off: bool,
    /// Title PGCs: the VTS title number they belong to.
    vts_ttn: u16,
    /// Menu PGCs: 2 title, 3 root, 4 sub-picture, 5 audio, 6 angle, 7 PTT.
    menu_id: u4,
};

pub const MenuLu = struct {
    lang: u16,
    pgcs: []Pgc,
};

/// A chapter (Part_of_Title): program `pgn` of PGC `pgcn` of the title's VTS.
pub const Ptt = struct { pgcn: u16, pgn: u16 };

pub const Vts = struct {
    /// VTS_PGCIT, indexed by PGCN - 1.
    title_pgcs: []Pgc,
    /// VTS_PTT_SRPT, indexed by VTS_TTN - 1.
    ptts: [][]Ptt,
    menus: []MenuLu,
    /// Disc-relative paths of HVnnnT01.EVO… and HVnnnM01.EVO… (their concatenations are the EVOBS).
    title_evos: [][]u8,
    menu_evos: [][]u8,
    audio_lang: [8]u16 = @splat(0),
    n_audio: u8 = 0,
    subp_lang: [32]u16 = @splat(0),
    n_subp: u8 = 0,
};

pub const Title = struct {
    vtsn: u16,
    vts_ttn: u16,
    n_ptt: u16,
    /// TT_PB_TY: b6 = 1 multi-PGC; b1..0 = UOP1/UOP0 prohibited.
    pb_ty: u8,
    /// Start time of each chapter and total length, approximated by the PGC/cell durations.
    chapter_us: []i64,
    duration_us: i64,
};

pub const Disc = struct {
    arena: std.heap.ArenaAllocator,
    fp_pgc: ?Pgc,
    vmgm: []MenuLu,
    vmgm_evos: [][]u8,
    titles: []Title,
    /// Indexed by VTSN - 1.
    vts: []Vts,

    pub fn deinit(d: *Disc) void {
        d.arena.deinit();
    }
};
