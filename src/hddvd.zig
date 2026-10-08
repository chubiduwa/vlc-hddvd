//! HD DVD input for VLC 3.0 with menus and interactivity (an access_demux): Standard Content here, Advanced
//! Content in adv/player.zig (chosen at open; every control and ES hook dispatches on adv.owns()).
//!
//! - vfs.zig opens the disc (a folder or a UDF image); ifo.zig loads its navigation data (nav.zig).
//! - vm.zig, the navigation VM, decides which cell to present; this module streams that cell's sectors to
//!   VLC's own "ps" demuxer (created with demux_New on a custom stream), inspecting each sector on the way:
//!   NV_PCKs (EVOBU user-operation mask) and HLI_PCKs (buttons, hli.zig).
//! - The ps demuxer's ES output goes through a proxy (nav_glue.c): sub-picture units are reassembled and sent,
//!   with the PGC palette, to our own sub-picture decoder (spudec.zig), which also draws the button highlights.
//! - User input (DEMUX_NAV_*, mouse, VLC title/chapter menus) becomes button selection/activation and VM user
//!   operations.

const std = @import("std");
const vlc = @import("vlc");
const nav = @import("nav.zig");
const ifo = @import("ifo.zig");
const vfs = @import("vfs.zig");
const vm_mod = @import("vm.zig");
const hli = @import("hli.zig");
const spudec = @import("spudec.zig");
const adv = @import("adv/player.zig");

const Vm = vm_mod.Vm;
const sector_size = nav.sector_size;
const gpa = std.heap.c_allocator;

// C side (module.c, nav_glue.c).
// The va_list controls take their types from the callback fields: on x86-64 System V, va_list is an array, and a
// parameter declared with it here would not decay to a pointer as it does in the translated field types.
const HddvdDemuxControl = @extern(@FieldType(vlc.demux_t, "pf_control"), .{ .name = "HddvdDemuxControl" });
const HddvdStreamControl = @extern(@FieldType(vlc.stream_t, "pf_control"), .{ .name = "HddvdStreamControl" });
extern fn hddvd_es_out_control(out: *vlc.es_out_t, query: c_int, ...) callconv(.c) c_int;
extern fn hddvd_stream_delete(s: *vlc.stream_t) void;
extern fn hddvd_inherit_string(obj: *vlc.vlc_object_t, name: [*:0]const u8) ?[*:0]u8;
extern fn hddvd_free(p: ?*anyopaque) void;
extern fn hddvd_set_update(demux: *vlc.demux_t, flags: c_uint, title: c_int, seekpoint: c_int) void;
extern fn hddvd_mouse_new(demux: *vlc.demux_t) ?*anyopaque;
extern fn hddvd_mouse_delete(demux: *vlc.demux_t, m: ?*anyopaque) void;
extern fn hddvd_mouse_poll(m: ?*anyopaque, x: *c_int, y: *c_int) c_int;
extern fn hddvd_esout_new(demux: *vlc.demux_t) ?*vlc.es_out_t;
extern fn hddvd_esout_delete(out: ?*vlc.es_out_t) void;
extern fn hddvd_es_select(demux: *vlc.demux_t, es: *vlc.es_out_id_t, on: bool) void;
extern fn hddvd_es_selected(demux: *vlc.demux_t, es: *vlc.es_out_id_t) bool;
extern fn hddvd_es_send(demux: *vlc.demux_t, es: *vlc.es_out_id_t, block: *vlc.block_t) void;
extern fn hddvd_es_out_empty(demux: *vlc.demux_t) bool;
extern fn hddvd_sleep_ms(ms: c_int) void;
extern fn hddvd_now_us() i64;
extern fn hddvd_input_title_set_flags(t: *vlc.input_title_t, flags: c_int, name: ?[*:0]const u8) void;
extern fn hddvd_seekpoint_set_name(s: *vlc.seekpoint_t, name: ?[*:0]const u8) void;
extern fn hddvd_block_release(b: *vlc.block_t) void;
extern fn hddvd_fmt_set_language(fmt: *vlc.es_format_t, code: u16) void;
extern fn hddvd_fmt_set_extra(fmt: *vlc.es_format_t, data: [*]const u8, len: usize) void;

pub fn log(obj: *vlc.vlc_object_t, prio: c_int, src: std.builtin.SourceLocation, comptime fmt: [*:0]const u8, args: anytype) void {
    @call(.auto, vlc.vlc_Log, .{ obj, prio, "hddvd", src.file, @as(c_uint, src.line), src.fn_name, fmt } ++ args);
}

/// User operation numbers (Annex J) checked before acting on user input.
const Uop = struct {
    const time_play = 0;
    const ptt_play = 1;
    const title_play = 2;
    const time_ptt_search = 5;
    const prev_pg = 6;
    const next_pg = 7;
    const menu_title = 10;
    const menu_root = 11;
    const resume_op = 16;
    const button = 17;
    const still_off = 18;
};

/// MPEG-2 video "sequence end" PES: makes the decoder output the last picture of a still.
const still_flush = [_]u8{ 0x00, 0x00, 0x01, 0xe0, 0x00, 0x07, 0x80, 0x00, 0x00, 0x00, 0x00, 0x01, 0xb7 };

const SpuTrack = struct {
    es: *vlc.es_out_id_t,
    id: c_int,
    buf: std.ArrayList(u8) = .empty,
    pts: i64 = 0,
    /// The last complete block (palette + unit) and its PTS. A menu's button SPU is often sent once, before the HLI
    /// that tells us to select its stream; VLC drops blocks of unselected streams, so it is resent on selection.
    last: []u8 = &.{},
    last_pts: i64 = 0,

    fn deinit(t: *SpuTrack) void {
        t.buf.deinit(gpa);
        gpa.free(t.last);
        t.last = &.{};
    }
};

const EsTrack = struct { es: *vlc.es_out_id_t, id: c_int };

const Sys = struct {
    obj: *vlc.vlc_object_t,
    fs: *vfs.Fs,
    disc: nav.Disc,
    vm: Vm,

    // Cell reader.
    gen: u32 = 0,
    evos: []const []u8 = &.{},
    files: []?vfs.File = &.{},
    pos: u64 = 0,
    end: u64 = 0,
    sector: [sector_size]u8 = undefined,
    sector_off: usize = sector_size,
    inject: []const u8 = &.{},
    /// Where the previous cell ended (domain, EVOBS, byte), to detect jumps that need a clock reset.
    last_domain: vm_mod.Domain = .fp,
    last_evos: []const []u8 = &.{},
    last_end: u64 = std.math.maxInt(u64),

    // Presentation state.
    still_init: bool = false,
    still_until: i64 = 0,
    evobu_uop: u32 = 0,
    hli_asm: hli.Assembler = .{},
    /// HLIs read but not yet on screen (in stream order); the current one is `hli`.
    pending: [4]hli.Hli = undefined,
    n_pending: usize = 0,
    hli: ?hli.Hli = null,
    /// The current HLI's button-selection period is over (BTN_SL_E_PTM).
    selection_ended: bool = false,
    /// After moving on to the next cell before the previous one finished presenting, its highlight stays until
    /// this HLI_E_PTM is on screen.
    linger_end: ?u32 = null,
    /// The VM moved to a cell that needs a clock reset, waiting for the previous cell to finish presenting.
    reset_wait: bool = false,
    activated: u8 = 0,
    wait_ticks: u32 = 0,
    /// VLC selects a menu as "title 0" followed by a seekpoint of title 0 (its disc-menu key sends title 0,
    /// seekpoint 2). The seekpoint belongs to that menu request even if the menu already jumped into a title.
    menu_requested: bool = false,

    // VLC objects.
    stream: ?*vlc.stream_t = null,
    ps: ?*vlc.demux_t = null,
    esout: ?*vlc.es_out_t = null,
    mouse: ?*anyopaque = null,
    tracks: std.ArrayList(EsTrack) = .empty,
    spus: std.ArrayList(SpuTrack) = .empty,
    cur_title: c_int = -1,
    cur_seekpoint: c_int = -1,
    /// Highlight state shared with the sub-picture decoders.
    spu_shared: ?*spudec.Shared = null,

    fn closeFiles(s: *Sys) void {
        for (s.files) |*f| if (f.*) |*file| file.close();
        gpa.free(s.files);
        s.files = &.{};
    }
};

fn sysOf(demux: *vlc.demux_t) *Sys {
    return @ptrCast(@alignCast(demux.p_sys));
}

fn asObj(demux: *vlc.demux_t) *vlc.vlc_object_t {
    return @ptrCast(demux);
}

// ---- reading the current cell ---------------------------------------------------------------------------

fn openEvo(sys: *Sys, i: usize) !*vfs.File {
    if (sys.files[i] == null) sys.files[i] = try sys.fs.openFile(sys.evos[i]);
    return &sys.files[i].?;
}

/// Reads one sector of the current EVOBS at byte offset `off`.
fn readSector(sys: *Sys, off: u64) !void {
    var rel = off;
    for (0..sys.evos.len) |i| {
        const f = try openEvo(sys, i);
        if (rel < f.size) {
            if (try f.pread(rel, &sys.sector) != sector_size) return error.ReadFailed;
            return;
        }
        rel -= f.size;
    }
    return error.ReadFailed;
}

/// Looks at a sector before the ps demuxer gets it: NV_PCK (PCI user-operation mask) and HLI_PCK.
fn inspectSector(sys: *Sys) void {
    const p = &sys.sector;
    if (!std.mem.eql(u8, p[0..4], &.{ 0, 0, 1, 0xba })) return;
    var q: usize = 14 + @as(usize, p[13] & 7);
    while (q + 7 <= sector_size and std.mem.eql(u8, p[q..][0..3], &.{ 0, 0, 1 })) {
        const len = std.mem.readInt(u16, p[q + 4 ..][0..2], .big);
        const end = @min(sector_size, q + 6 + len);
        if (p[q + 3] == 0xbf and q + 7 <= end) {
            const data = p[q + 7 .. end];
            switch (p[q + 6]) {
                0x00 => if (data.len >= 12) { // PCI: PCI_GI +8 = EVOBU_UOP_CTL
                    sys.evobu_uop = std.mem.readInt(u32, data[8..12], .big);
                },
                0x08 => if (sys.hli_asm.feed(data)) |h| newHli(sys, h),
                else => {},
            }
        }
        q += 6 + len;
    }
}

fn streamRead(s: [*c]vlc.stream_t, buf: ?*anyopaque, len: usize) callconv(.c) isize {
    const sys: *Sys = @ptrCast(@alignCast(s.*.p_sys));
    const out: [*]u8 = @ptrCast(buf orelse return -1);
    if (sys.inject.len > 0) {
        const n = @min(len, sys.inject.len);
        @memcpy(out[0..n], sys.inject[0..n]);
        sys.inject = sys.inject[n..];
        return @intCast(n);
    }
    if (sys.vm.phase != .play_cell) return 0;
    if (sys.sector_off == sector_size) {
        if (sys.pos >= sys.end) return 0;
        readSector(sys, sys.pos) catch return -1;
        sys.pos += sector_size;
        sys.sector_off = 0;
        inspectSector(sys);
    }
    const n = @min(len, sector_size - sys.sector_off);
    @memcpy(out[0..n], sys.sector[sys.sector_off..][0..n]);
    sys.sector_off += n;
    return @intCast(n);
}

fn streamSeek(s: [*c]vlc.stream_t, offset: u64) callconv(.c) c_int {
    _ = s;
    _ = offset;
    return vlc.VLC_EGENERIC; // the stream is driven by the VM; the ps demuxer never needs to seek it
}

fn streamDestroy(s: [*c]vlc.stream_t) callconv(.c) void {
    _ = s; // vlc_stream_Delete() always calls this (a NULL callback crashes); the state is owned by Sys.
}

fn streamSize(s: *vlc.stream_t) callconv(.c) u64 {
    _ = s;
    return 0;
}

/// Why the VM moved: playback reaching it (the previous cell keeps presenting) or a user operation (cut now).
const Move = enum { natural, user };

/// True if starting cell `c` needs VLC's clock reset: a jump (another domain or EVOBS, or not where the previous
/// cell ended) or a timestamp discontinuity.
fn needsClockReset(sys: *Sys, c: nav.Cell) bool {
    const start = (@as(u64, c.first_sector) + sys.vm.start_offset) * sector_size;
    return sys.vm.domain != sys.last_domain or sys.vm.evos().ptr != sys.last_evos.ptr or start != sys.last_end or
        c.stc_discontinuity;
}

/// Follows the VM to its current cell: reopens the EVOBS if needed, positions the reader, resets VLC's clock
/// when needed, drops the previous cell's HLI and updates VLC's title/chapter.
///
/// A clock reset (ES_OUT_RESET_PCR) flushes the decoders, so on a natural move it waits until the previous cell
/// has been presented (reset_wait). When the decoders ran dry, the clock is reset even on a contiguous cell:
/// otherwise VLC sees the next PCR as late and raises its PTS delay for good ("PCR is called too late").
fn syncCell(demux: *vlc.demux_t, move: Move) void {
    const sys = sysOf(demux);
    if (sys.vm.generation == sys.gen) return;
    const empty = hddvd_es_out_empty(demux);
    if (move == .natural and !empty) if (sys.vm.cell()) |next| if (needsClockReset(sys, next)) {
        if (sys.wait_ticks % 100 == 0) log(asObj(demux), vlc.VLC_MSG_DBG, @src(), "jump: waiting for the decoders (%u)", .{sys.wait_ticks});
        sys.wait_ticks += 1;
        sys.reset_wait = true;
        return;
    };
    sys.reset_wait = false;
    sys.wait_ticks = 0;
    sys.gen = sys.vm.generation;
    sys.still_init = false;
    clearHli(demux, move == .natural and !empty);
    const c = sys.vm.cell() orelse {
        log(asObj(demux), vlc.VLC_MSG_DBG, @src(), "VM stopped", .{});
        return;
    };
    log(asObj(demux), vlc.VLC_MSG_DBG, @src(), "cell: %s VTS %u PGC %u PG %u cell %u (LB %u-%u, still %u, %u cmds)", .{
        @tagName(sys.vm.domain).ptr,                     @as(c_uint, sys.vm.vtsn),
        @as(c_uint, sys.vm.pgcn),                        @as(c_uint, sys.vm.pgn),
        @as(c_uint, sys.vm.celln),                       @as(c_uint, c.first_sector),
        @as(c_uint, c.last_sector),                      @as(c_uint, c.still),
        @as(c_uint, c.cmd_count),
    });

    const evos = sys.vm.evos();
    if (evos.ptr != sys.evos.ptr or evos.len != sys.evos.len) {
        sys.closeFiles();
        sys.evos = evos;
        sys.files = gpa.alloc(?vfs.File, evos.len) catch &.{};
        @memset(sys.files, null);
    }
    const start = (@as(u64, c.first_sector) + sys.vm.start_offset) * sector_size;
    if (needsClockReset(sys, c) or (empty and move == .natural)) {
        _ = hddvd_es_out_control(demux.out, vlc.ES_OUT_RESET_PCR);
        for (sys.spus.items) |*t| { // their timestamps belong to the old clock
            gpa.free(t.last);
            t.last = &.{};
        }
    }
    sys.pos = start;
    sys.end = (@as(u64, c.last_sector) + 1) * sector_size;
    sys.sector_off = sector_size;
    sys.last_domain = sys.vm.domain;
    sys.last_evos = evos;
    sys.last_end = sys.end;
    updateTitleInfo(demux);
}

/// VLC title 0 is the menu pseudo-title, titles 1..N the disc's titles; chapter = SPRM7.
fn updateTitleInfo(demux: *vlc.demux_t) void {
    const sys = sysOf(demux);
    var t: c_int = 0;
    var sp: c_int = 0;
    if (!sys.vm.inMenu()) {
        const ttn, const ptt = sys.vm.titleChapter();
        t = ttn;
        sp = @as(c_int, ptt) - 1;
    }
    var flags: c_uint = 0;
    if (t != sys.cur_title) flags |= vlc.INPUT_UPDATE_TITLE | vlc.INPUT_UPDATE_SEEKPOINT;
    if (sp != sys.cur_seekpoint) flags |= vlc.INPUT_UPDATE_SEEKPOINT;
    if (flags == 0) return;
    sys.cur_title = t;
    sys.cur_seekpoint = sp;
    hddvd_set_update(demux, flags, t, @max(sp, 0));
}

// ---- buttons ------------------------------------------------------------------------------------------

var current_demux: ?*vlc.demux_t = null; // set around inspectSector calls (newHli needs the demux)

/// An HLI was read. It takes effect when its start (HLI_S_PTM) is on screen (tickHli); the packs are read ahead of
/// presentation by VLC's buffering, and in a game each move window has its own HLI.
fn newHli(sys: *Sys, h: hli.Hli) void {
    const p = sys.vm.pgc() orelse return;
    if (p.hli_off) return;
    if (h.n_buttons == 0) return;
    const demux = current_demux orelse return;
    log(asObj(demux), vlc.VLC_MSG_DBG, @src(), "HLI read: %u buttons, %u..%u", .{ @as(c_uint, h.n_buttons), h.start_ptm, h.end_ptm });
    if (sys.n_pending == sys.pending.len) { // should not happen: take the oldest now
        promoteHli(demux, sys.pending[0]);
        std.mem.copyForwards(hli.Hli, sys.pending[0 .. sys.pending.len - 1], sys.pending[1..]);
        sys.n_pending -= 1;
    }
    sys.pending[sys.n_pending] = h;
    sys.n_pending += 1;
    // Button sub-pictures use forced display: select their stream even if the user has subtitles off. Done now,
    // before the HLI starts, so the button SPU (which comes first) is decoded and the clock can be read.
    for (h.sp_use) |u| {
        if (u & 0x80 == 0) continue;
        const id: c_int = 0xbd20 + @as(c_int, u & 0x1f);
        for (sys.spus.items) |*t| if (t.id == id and !hddvd_es_selected(demux, t.es)) {
            log(asObj(demux), vlc.VLC_MSG_DBG, @src(), "selecting button sub-picture 0x%x", .{@as(c_uint, @bitCast(id))});
            hddvd_es_select(demux, t.es, true);
            if (t.last.len > 0) if (spuBlock(t.last, t.last_pts)) |b| hddvd_es_send(demux, t.es, b);
        };
    }
}

/// The HLI's start is on screen: it becomes the current one (5.1.4.1.2).
fn promoteHli(demux: *vlc.demux_t, h: hli.Hli) void {
    const sys = sysOf(demux);
    sys.hli = h;
    sys.activated = 0;
    sys.selection_ended = false;
    sys.linger_end = null;
    log(asObj(demux), vlc.VLC_MSG_DBG, @src(), "HLI: %u buttons, select %u", .{ @as(c_uint, h.n_buttons), @as(c_uint, h.force_select) });
    if (h.force_select != 0) {
        sys.vm.setButton(h.force_select);
    } else if (sys.vm.button() == 0 or sys.vm.button() > h.n_buttons) {
        sys.vm.setButton(@max(1, @min(sys.vm.button(), h.n_buttons)));
    }
    showHighlight(demux);
}

/// True once a 90 kHz presentation time of the current cell is (or was) on screen. With `all`, everything sent
/// has been presented (the decoders are empty at the end of a cell). Without a clock, the time counts as reached
/// (the HLI applies when read, as before).
fn reached(demux: *vlc.demux_t, ptm: u32, all: bool) bool {
    if (all) return true;
    const sh = sysOf(demux).spu_shared orelse return true;
    // The ps demuxer's timestamps: VLC_TICK_0 + 90 kHz → µs.
    const ts: i64 = 1 + @divTrunc(@as(i64, ptm) * 100, 9);
    const maybe = sh.displayDate(ts) catch return true; // no decoder
    const date = maybe orelse return false; // clock not ready
    return date <= hddvd_now_us();
}

/// Applies the HLI timeline (5.1.4.1): start of pending HLIs, end of the selection period (forced activation),
/// end of the HLI. Returns true if a button activation moved the VM.
fn tickHli(demux: *vlc.demux_t, all: bool) bool {
    const sys = sysOf(demux);
    const no_end = std.math.maxInt(u32); // FFFFFFFF: through a still
    if (sys.linger_end) |e| if (reached(demux, e, all)) {
        sys.linger_end = null;
        if (sys.hli == null) if (sys.spu_shared) |sh| sh.set(0, null);
    };
    while (sys.n_pending > 0 and reached(demux, sys.pending[0].start_ptm, all)) {
        const h = sys.pending[0];
        std.mem.copyForwards(hli.Hli, sys.pending[0 .. sys.n_pending - 1], sys.pending[1..sys.n_pending]);
        sys.n_pending -= 1;
        promoteHli(demux, h);
    }
    const h = &(sys.hli orelse return false);
    if (!sys.selection_ended and h.select_end_ptm != no_end and reached(demux, h.select_end_ptm, all)) {
        sys.selection_ended = true;
        if (sys.activated == 0) {
            if (h.force_activate != 0) {
                const gen = sys.vm.generation;
                activateButton(demux, if (h.force_activate == 63) sys.vm.button() else h.force_activate);
                if (sys.vm.generation != gen) return true;
            } else if (sys.spu_shared) |sh| sh.set(0, null); // the selection colour is cleared
        }
    }
    if (sys.hli) |cur| if (cur.end_ptm != no_end and reached(demux, cur.end_ptm, all)) {
        sys.hli = null;
        sys.activated = 0;
        if (sys.spu_shared) |sh| sh.set(0, null);
    };
    return false;
}

/// Drops the HLIs. With `linger`, the highlight on screen stays until the HLI's end is presented (the reader moved
/// on to the next cell before the screen did).
fn clearHli(demux: *vlc.demux_t, linger: bool) void {
    const sys = sysOf(demux);
    sys.n_pending = 0;
    sys.hli_asm.reset();
    sys.selection_ended = false;
    if (sys.hli) |h| {
        if (linger and h.end_ptm != std.math.maxInt(u32)) {
            sys.linger_end = h.end_ptm;
        } else {
            sys.linger_end = null;
            if (sys.spu_shared) |sh| sh.set(0, null);
        }
    } else if (!linger and sys.linger_end != null) {
        sys.linger_end = null;
        if (sys.spu_shared) |sh| sh.set(0, null);
    }
    sys.hli = null;
    sys.activated = 0;
}

fn showHighlight(demux: *vlc.demux_t) void {
    const sys = sysOf(demux);
    const h = &(sys.hli orelse return);
    const p = sys.vm.pgc() orelse return;
    const sh = sys.spu_shared orelse return;
    const btn = if (sys.activated != 0) sys.activated else sys.vm.button();
    var streams: u32 = 0;
    for (h.sp_use) |u| if (u & 0x80 != 0) {
        streams |= @as(u32, 1) << @intCast(u & 0x1f);
    };
    if (hli.highlight(h, btn, sys.activated != 0, &p.hd_palette)) |hl| {
        sh.set(streams, &hl);
    } else sh.set(streams, null);
}

/// The buttons read so far may still change what the cell commands see.
fn hliUnsettled(sys: *Sys) bool {
    if (sys.n_pending > 0) return true;
    return sys.hli != null and sys.activated == 0 and !sys.selection_ended;
}

fn buttonsUsable(sys: *Sys) bool {
    return sys.hli != null and sys.activated == 0 and !sys.selection_ended and sys.vm.uopAllowed(Uop.button, sys.evobu_uop);
}

fn activateButton(demux: *vlc.demux_t, btn: u8) void {
    const sys = sysOf(demux);
    const h = &(sys.hli orelse return);
    if (btn == 0 or btn > h.n_buttons) return;
    sys.vm.setButton(btn);
    sys.activated = btn;
    showHighlight(demux);
    log(asObj(demux), vlc.VLC_MSG_DBG, @src(), "button %u activated (GPRM0 was %u)", .{ @as(c_uint, btn), @as(c_uint, sys.vm.gprm[0]) });
    const cmds = h.buttons[btn - 1].cmds;
    sys.vm.activateButton(&cmds);
    // A still holding a menu ends when a button branches (handled by syncCell on the new generation).
    syncCell(demux, .user);
}

fn selectButton(demux: *vlc.demux_t, btn: u8, allow_auto: bool) void {
    const sys = sysOf(demux);
    const h = &(sys.hli orelse return);
    if (btn == 0 or btn > h.n_buttons) return;
    if (allow_auto and h.buttons[btn - 1].auto_action) return activateButton(demux, btn);
    sys.vm.setButton(btn);
    showHighlight(demux);
}

fn navigate(demux: *vlc.demux_t, dir: hli.Dir) void {
    const sys = sysOf(demux);
    if (!buttonsUsable(sys)) return;
    const h = &sys.hli.?;
    const cur = sys.vm.button();
    if (cur == 0 or cur > h.n_buttons) return;
    const target = h.buttons[cur - 1].adjacent[@intFromEnum(dir)];
    if (target != 0 and target != cur) selectButton(demux, target, true);
}

fn pollMouse(demux: *vlc.demux_t) void {
    const sys = sysOf(demux);
    var x: c_int = 0;
    var y: c_int = 0;
    const ev = hddvd_mouse_poll(sys.mouse, &x, &y);
    if (ev == 0 or !buttonsUsable(sys)) return;
    const btn = hli.hit(&sys.hli.?, x, y);
    if (btn == 0) return;
    if (ev == 2) return activateButton(demux, btn);
    if (btn != sys.vm.button()) selectButton(demux, btn, false);
}

// ---- demux loop ---------------------------------------------------------------------------------------

/// pf_demux: 1 = continue, 0 = end (the VM stopped), -1 = error.
fn demuxOne(demux_c: [*c]vlc.demux_t) callconv(.c) c_int {
    const demux: *vlc.demux_t = demux_c;
    const sys = sysOf(demux);
    current_demux = demux;
    sys.menu_requested = false;
    if (tickHli(demux, false)) syncCell(demux, .user);
    pollMouse(demux);
    syncCell(demux, .natural);
    if (sys.reset_wait) {
        hddvd_sleep_ms(10);
        return 1;
    }

    switch (sys.vm.phase) {
        .stopped => return 0,
        .play_cell => {
            if (sys.pos < sys.end or sys.sector_off < sector_size or sys.inject.len > 0) {
                const ps = sys.ps orelse return -1;
                if (ps.pf_demux.?(ps) == 0) {
                    // The ps demuxer saw the end of our data mid-cell (read error): skip to the cell's end.
                    sys.pos = sys.end;
                    sys.sector_off = sector_size;
                }
                return 1;
            }
            // Cell data fully demuxed; its cell commands run next. Before a still, and while the user can still
            // change the outcome with this cell's buttons (an HLI not yet started, or neither activated nor past its
            // selection end), let VLC catch up. Otherwise the next cell follows on without a gap.
            const c = sys.vm.cell() orelse return 1;
            if (c.still != 0 or hliUnsettled(sys)) {
                if (!hddvd_es_out_empty(demux)) {
                    if (sys.wait_ticks % 100 == 0) log(asObj(demux), vlc.VLC_MSG_DBG, @src(), "end of cell: waiting for the decoders (%u)", .{sys.wait_ticks});
                    sys.wait_ticks += 1;
                    hddvd_sleep_ms(10);
                    return 1;
                }
                sys.wait_ticks = 0;
                // Everything is on screen: finish the HLI timeline (pending starts, forced activation, ends).
                if (tickHli(demux, true)) return 1;
            }
            sys.vm.cellPresented();
            return 1;
        },
        .cell_still, .pgc_still => {
            if (!sys.still_init) {
                sys.still_init = true;
                sys.still_until = if (sys.vm.still == 255) -1 else hddvd_now_us() + @as(i64, sys.vm.still) * 1_000_000;
                sys.inject = &still_flush;
                if (sys.ps) |ps| _ = ps.pf_demux.?(ps);
                return 1;
            }
            if (sys.still_until >= 0 and hddvd_now_us() >= sys.still_until) {
                sys.vm.stillDone();
                _ = hddvd_es_out_control(demux.out, vlc.ES_OUT_RESET_PCR);
                sys.last_end = std.math.maxInt(u64);
                return 1;
            }
            hddvd_sleep_ms(40);
            return 1;
        },
    }
}

// ---- open / close -------------------------------------------------------------------------------------

fn open(o: *vlc.vlc_object_t) callconv(.c) c_int {
    const demux: *vlc.demux_t = @ptrCast(o);
    const path: []const u8 = std.mem.span(demux.psz_file orelse return vlc.VLC_EGENERIC);

    const fs = vfs.Fs.open(gpa, o, path) catch |err| {
        log(o, vlc.VLC_MSG_ERR, @src(), "cannot open %s (%s)", .{ demux.psz_file, @errorName(err).ptr });
        return vlc.VLC_EGENERIC;
    };
    // ADV_OBJ/DISCID.DAT marks Advanced Content, which a player plays even if Standard VTSs exist (Vol. 1 §4.1.1).
    if (adv.detect(fs)) return adv.open(demux, fs);
    const d = ifo.loadDisc(gpa, fs) catch |err| {
        log(o, vlc.VLC_MSG_ERR, @src(), "not an HD DVD Standard Content disc: %s (%s)", .{ demux.psz_file, @errorName(err).ptr });
        fs.close();
        return vlc.VLC_EGENERIC;
    };

    const sys = gpa.create(Sys) catch {
        var dd = d;
        dd.deinit();
        fs.close();
        return vlc.VLC_ENOMEM;
    };
    sys.* = .{ .obj = o, .fs = fs, .disc = d, .vm = undefined, .spu_shared = spudec.Shared.create() };
    sys.vm = Vm.init(&sys.disc, @bitCast(hddvd_now_us()));
    demux.p_sys = @ptrCast(sys);
    demux.pf_demux = demuxOne;
    demux.pf_control = HddvdDemuxControl;

    log(o, vlc.VLC_MSG_INFO, @src(), "HD DVD: %u titles, %u title sets, first play %s", .{
        @as(c_uint, @intCast(sys.disc.titles.len)),
        @as(c_uint, @intCast(sys.disc.vts.len)),
        @as([*:0]const u8, if (sys.disc.fp_pgc != null) "yes" else "no"),
    });

    presetGprms(o, &sys.vm);
    // Start the VM first: the ps demuxer peeks at the stream when it opens.
    sys.vm.start();
    if (sys.vm.phase == .stopped) sys.vm.titlePlay(1); // no First Play PGC: start the first title
    current_demux = demux;
    syncCell(demux, .natural);

    if (openPs(demux)) |_| {} else |err| {
        log(o, vlc.VLC_MSG_ERR, @src(), "cannot start the ps demuxer: %s", .{@errorName(err).ptr});
        close(o);
        return vlc.VLC_EGENERIC;
    }
    sys.mouse = hddvd_mouse_new(demux);
    // Button sub-pictures play alongside the subtitle stream, and a game HLI may name two button streams: allow
    // several sub-picture ESes at once (VLC's default selects one per category).
    _ = hddvd_es_out_control(demux.out, vlc.ES_OUT_SET_ES_CAT_POLICY, @as(c_int, vlc.SPU_ES), @as(c_int, vlc.ES_OUT_ES_POLICY_SIMULTANEOUS));
    _ = hddvd_es_out_control(demux.out, vlc.ES_OUT_RESET_PCR);
    return vlc.VLC_SUCCESS;
}

/// --hddvd-gprm=n=value,…: GPRM values for debugging, applied at start and whenever a user Title_Play/PTT_Play
/// resets the registers (e.g. to start a game title directly).
fn presetGprms(o: *vlc.vlc_object_t, vm: *Vm) void {
    const str = hddvd_inherit_string(o, "hddvd-gprm") orelse return;
    defer hddvd_free(str);
    var it = std.mem.tokenizeAny(u8, std.mem.span(str), ", ");
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        const n = std.fmt.parseInt(u6, pair[0..eq], 10) catch continue;
        const v = std.fmt.parseInt(u16, pair[eq + 1 ..], 10) catch continue;
        vm.presetGprm(n, v);
        log(o, vlc.VLC_MSG_DBG, @src(), "GPRM%u = %u (preset)", .{ @as(c_uint, n), @as(c_uint, v) });
    }
}

/// The custom stream and VLC's ps demuxer on top of it, writing to our ES output proxy.
fn openPs(demux: *vlc.demux_t) !void {
    const sys = sysOf(demux);
    sys.esout = hddvd_esout_new(demux) orelse return error.OutOfMemory;
    const raw = vlc.vlc_stream_CommonNew(asObj(demux), streamDestroy);
    if (raw == null) return error.OutOfMemory;
    const s: *vlc.stream_t = raw;
    s.pf_read = streamRead;
    s.pf_seek = streamSeek;
    s.pf_control = HddvdStreamControl;
    s.p_sys = sys;
    sys.stream = s;
    const ps = vlc.demux_New(asObj(demux), "ps", demux.psz_location, s, sys.esout);
    if (ps == null) return error.OpenFailed;
    sys.ps = ps;
}

fn close(o: *vlc.vlc_object_t) callconv(.c) void {
    const demux: *vlc.demux_t = @ptrCast(o);
    if (adv.owns(demux)) return adv.close(demux);
    const sys = sysOf(demux);
    hddvd_mouse_delete(demux, sys.mouse);
    if (sys.ps) |ps| vlc.demux_Delete(ps); // deletes its ESes and so their decoders
    if (sys.spu_shared) |sh| sh.unref(); // decoders and pending subpictures hold their own references
    if (sys.stream) |s| hddvd_stream_delete(s);
    hddvd_esout_delete(sys.esout);
    sys.closeFiles();
    for (sys.spus.items) |*t| t.deinit();
    sys.spus.deinit(gpa);
    sys.tracks.deinit(gpa);
    sys.disc.deinit();
    sys.fs.close();
    gpa.destroy(sys);
    demux.p_sys = null;
    current_demux = null;
}

// ---- controls (called from module.c) ------------------------------------------------------------------

/// Current position inside the PGC: elapsed first-angle cells plus a byte-proportional part of this one.
fn pgcTime(sys: *Sys) i64 {
    const p = sys.vm.pgc() orelse return 0;
    const c = sys.vm.cell() orelse return 0;
    var t: i64 = 0;
    for (p.cells[0 .. sys.vm.celln - 1]) |cc| {
        if (cc.block_mode <= 1) t += cc.duration_us;
    }
    // The reader may still be on the previous cell (the VM moves first): only count bytes inside this cell.
    const first = @as(u64, c.first_sector) * sector_size;
    const last = first + c.bytes();
    const done = if (sys.gen == sys.vm.generation and sys.pos > first) @min(sys.pos, last) - first else 0;
    t += @intFromFloat(@as(f64, @floatFromInt(c.duration_us)) * @as(f64, @floatFromInt(done)) / @as(f64, @floatFromInt(c.bytes())));
    return t;
}

fn getLength(demux: *vlc.demux_t, out: *i64) callconv(.c) c_int {
    if (adv.owns(demux)) return adv.getLength(demux, out);
    const sys = sysOf(demux);
    out.* = if (sys.vm.inMenu()) 0 else if (sys.vm.pgc()) |p| p.duration_us else 0;
    return vlc.VLC_SUCCESS;
}

fn getTime(demux: *vlc.demux_t, out: *i64) callconv(.c) c_int {
    if (adv.owns(demux)) return adv.getTime(demux, out);
    out.* = pgcTime(sysOf(demux));
    return vlc.VLC_SUCCESS;
}

fn getPosition(demux: *vlc.demux_t, out: *f64) callconv(.c) c_int {
    if (adv.owns(demux)) return adv.getPosition(demux, out);
    const sys = sysOf(demux);
    const p = sys.vm.pgc() orelse return vlc.VLC_EGENERIC;
    out.* = if (p.duration_us > 0) @as(f64, @floatFromInt(pgcTime(sys))) / @as(f64, @floatFromInt(p.duration_us)) else 0;
    return vlc.VLC_SUCCESS;
}

/// Time_Search within the current title PGC.
fn setTime(demux: *vlc.demux_t, t: i64) callconv(.c) c_int {
    if (adv.owns(demux)) return adv.setTime(demux, t);
    const sys = sysOf(demux);
    if (sys.vm.inMenu() or !sys.vm.uopAllowed(Uop.time_ptt_search, sys.evobu_uop)) return vlc.VLC_EGENERIC;
    const p = sys.vm.pgc() orelse return vlc.VLC_EGENERIC;
    var left = t;
    for (p.cells, 1..) |c, n| {
        if (c.block_mode > 1) continue;
        if (left < c.duration_us or n == p.cells.len) {
            const frac: f64 = if (c.duration_us > 0) std.math.clamp(@as(f64, @floatFromInt(left)) / @as(f64, @floatFromInt(c.duration_us)), 0, 1) else 0;
            const sectors: u32 = @intFromFloat(@as(f64, @floatFromInt(c.last_sector - c.first_sector)) * frac);
            sys.vm.seekCell(@intCast(n), sectors);
            sys.last_end = std.math.maxInt(u64); // force a clock reset
            clearHli(demux, false);
            return vlc.VLC_SUCCESS;
        }
        left -= c.duration_us;
    }
    return vlc.VLC_EGENERIC;
}

fn setPosition(demux: *vlc.demux_t, f: f64) callconv(.c) c_int {
    if (adv.owns(demux)) return adv.setPosition(demux, f);
    const sys = sysOf(demux);
    const p = sys.vm.pgc() orelse return vlc.VLC_EGENERIC;
    return setTime(demux, @intFromFloat(@as(f64, @floatFromInt(p.duration_us)) * std.math.clamp(f, 0, 1)));
}

const menu_points = [_][*:0]const u8{ "Resume", "Title", "Root", "Sub-picture", "Audio", "Angle", "Chapter" };

/// VLC's title list: "HD DVD Menu" (interactive, one entry per menu) then the disc's titles and chapters.
/// NOTE (Windows): VLC frees these with its own C runtime's free(); fine on macOS/Linux.
fn getTitleInfo(demux: *vlc.demux_t, out_titles: *[*c][*c]vlc.input_title_t, out_count: *c_int) callconv(.c) c_int {
    if (adv.owns(demux)) return adv.getTitleInfo(demux, out_titles, out_count);
    const sys = sysOf(demux);
    const titles = sys.disc.titles;
    const n = titles.len + 1;
    const list: [*c][*c]vlc.input_title_t = @ptrCast(@alignCast(std.c.malloc(n * @sizeOf(*vlc.input_title_t)) orelse return vlc.VLC_ENOMEM));

    const menu = vlc.vlc_input_title_New();
    hddvd_input_title_set_flags(menu, vlc.INPUT_TITLE_MENU | vlc.INPUT_TITLE_INTERACTIVE, "HD DVD Menu");
    const mp: [*c][*c]vlc.seekpoint_t = @ptrCast(@alignCast(std.c.malloc(menu_points.len * @sizeOf(*vlc.seekpoint_t)) orelse return vlc.VLC_ENOMEM));
    for (menu_points, 0..) |name, k| {
        mp[k] = vlc.vlc_seekpoint_New();
        hddvd_seekpoint_set_name(mp[k], name);
    }
    menu.*.seekpoint = mp;
    menu.*.i_seekpoint = menu_points.len;
    list[0] = menu;

    for (titles, 1..) |t, i| {
        const it = vlc.vlc_input_title_New();
        it.*.i_length = t.duration_us;
        const points: [*c][*c]vlc.seekpoint_t = @ptrCast(@alignCast(std.c.malloc(@max(1, t.chapter_us.len) * @sizeOf(*vlc.seekpoint_t)) orelse return vlc.VLC_ENOMEM));
        for (t.chapter_us, 0..) |start, k| {
            points[k] = vlc.vlc_seekpoint_New();
            points[k].*.i_time_offset = start;
        }
        it.*.seekpoint = points;
        it.*.i_seekpoint = @intCast(t.chapter_us.len);
        list[i] = it;
    }
    out_titles.* = list;
    out_count.* = @intCast(n);
    return vlc.VLC_SUCCESS;
}

fn afterUserJump(demux: *vlc.demux_t) void {
    const sys = sysOf(demux);
    clearHli(demux, false);
    sys.last_end = std.math.maxInt(u64);
    syncCell(demux, .user);
}

fn callMenu(demux: *vlc.demux_t, which: vm_mod.Menu) bool {
    const sys = sysOf(demux);
    const uop: u5 = if (which == .title) Uop.menu_title else Uop.menu_root;
    if (!sys.vm.uopAllowed(uop, sys.evobu_uop)) return false;
    if (!sys.vm.menuCall(which)) return false;
    afterUserJump(demux);
    return true;
}

fn setTitle(demux: *vlc.demux_t, i: c_int) callconv(.c) c_int {
    if (adv.owns(demux)) return adv.setTitle(demux, i);
    const sys = sysOf(demux);
    if (i == 0) {
        if (callMenu(demux, .title) or callMenu(demux, .root)) {
            sys.menu_requested = true;
            return vlc.VLC_SUCCESS;
        }
        return vlc.VLC_EGENERIC;
    }
    if (i < 0 or i > sys.disc.titles.len) return vlc.VLC_EGENERIC;
    if (!sys.vm.uopAllowed(Uop.title_play, sys.evobu_uop)) return vlc.VLC_EGENERIC;
    sys.vm.titlePlay(@intCast(i));
    afterUserJump(demux);
    return vlc.VLC_SUCCESS;
}

fn setSeekpoint(demux: *vlc.demux_t, i: c_int) callconv(.c) c_int {
    if (adv.owns(demux)) return adv.setSeekpoint(demux, i);
    const sys = sysOf(demux);
    if (sys.menu_requested) {
        // Part of a "title 0" menu request just served (title or root menu); other entries pick that menu.
        sys.menu_requested = false;
        if (i <= 2) return vlc.VLC_SUCCESS;
    }
    if (sys.vm.inMenu() or sys.cur_title == 0) {
        const ok = switch (i) {
            0 => sys.vm.uopAllowed(Uop.resume_op, sys.evobu_uop) and sys.vm.userResume(),
            1 => callMenu(demux, .title),
            2 => callMenu(demux, .root),
            3 => callMenu(demux, .subpicture),
            4 => callMenu(demux, .audio),
            5 => callMenu(demux, .angle),
            6 => callMenu(demux, .chapter),
            else => false,
        };
        if (ok) afterUserJump(demux);
        return if (ok) vlc.VLC_SUCCESS else vlc.VLC_EGENERIC;
    }
    const ttn, _ = sys.vm.titleChapter();
    if (i < 0 or ttn == 0 or ttn > sys.disc.titles.len or i >= sys.disc.titles[ttn - 1].chapter_us.len) return vlc.VLC_EGENERIC;
    if (!sys.vm.uopAllowed(Uop.ptt_play, sys.evobu_uop) or !sys.vm.uopAllowed(Uop.time_ptt_search, sys.evobu_uop)) return vlc.VLC_EGENERIC;
    sys.vm.pttPlay(ttn, @intCast(i + 1));
    afterUserJump(demux);
    return vlc.VLC_SUCCESS;
}

/// DEMUX_NAV_*: 0 activate, 1 up, 2 down, 3 left, 4 right, 5 popup, 6 menu.
fn navControl(demux: *vlc.demux_t, action: c_int) callconv(.c) c_int {
    if (adv.owns(demux)) return adv.navControl(demux, action);
    const sys = sysOf(demux);
    log(asObj(demux), vlc.VLC_MSG_DBG, @src(), "nav %d: phase %s, button %u%s", .{
        action, @tagName(sys.vm.phase).ptr, @as(c_uint, sys.vm.button()), @as([*:0]const u8, if (sys.hli != null) ", HLI" else ""),
    });
    switch (action) {
        0 => {
            if (buttonsUsable(sys)) {
                activateButton(demux, sys.vm.button());
            } else if ((sys.vm.phase == .cell_still or sys.vm.phase == .pgc_still) and sys.hli == null and
                sys.vm.uopAllowed(Uop.still_off, sys.evobu_uop))
            {
                sys.vm.stillDone(); // Still_Off
            } else return vlc.VLC_EGENERIC;
        },
        1 => navigate(demux, .up),
        2 => navigate(demux, .down),
        3 => navigate(demux, .left),
        4 => navigate(demux, .right),
        5, 6 => {
            if (!(callMenu(demux, .title) or callMenu(demux, .root))) return vlc.VLC_EGENERIC;
        },
        else => return vlc.VLC_EGENERIC,
    }
    return vlc.VLC_SUCCESS;
}

// ---- ES output proxy hooks (nav_glue.c) -----------------------------------------------------------------

/// Stream id (0xE0, 0xBD20, 0xBDC0…) of the PES packet the ps demuxer has just read: the one in the current
/// sector that ends at the read position. VLC 3's ps demuxer does not set es_format_t.i_id, and it creates an
/// ES synchronously while handling that packet, so this identifies the new stream.
fn currentPacketId(sys: *const Sys) c_int {
    const p = &sys.sector;
    if (!std.mem.eql(u8, p[0..4], &.{ 0, 0, 1, 0xba })) return -1;
    var q: usize = 14 + @as(usize, p[13] & 7);
    var id: c_int = -1;
    while (q + 6 <= sector_size and q < sys.sector_off and std.mem.eql(u8, p[q..][0..3], &.{ 0, 0, 1 })) {
        const len = std.mem.readInt(u16, p[q + 4 ..][0..2], .big);
        id = p[q + 3];
        if (id == 0xbd and q + 9 <= sector_size) {
            const sub = q + 9 + @as(usize, p[q + 8]);
            if (sub < sector_size) id = 0xbd00 | @as(c_int, p[sub]);
        }
        q += 6 + len;
    }
    return id;
}

/// Gives each ES its stream id, sub-picture streams the PGC palette and HD frame size, and audio/sub-picture
/// streams their language.
fn esFixup(demux: *vlc.demux_t, fmt: *vlc.es_format_t) callconv(.c) void {
    if (adv.owns(demux)) return adv.esFixup(demux, fmt);
    const sys = sysOf(demux);
    if (fmt.i_id < 0) fmt.i_id = currentPacketId(sys);
    const id = fmt.i_id;
    if (fmt.i_cat == vlc.SPU_ES and (id & 0xffe0) == 0xbd20) {
        // Our decoder (spudec.zig): whole units from esFilter, so no packetizer.
        fmt.i_codec = spudec.fourcc;
        fmt.b_packetized = true;
        if (sys.spu_shared) |sh| {
            const e = sh.extra();
            hddvd_fmt_set_extra(fmt, &e, e.len);
        }
        fmt.unnamed_0.subs.spu.i_original_frame_width = 1920;
        fmt.unnamed_0.subs.spu.i_original_frame_height = 1080;
        if (sys.vm.vts()) |v| {
            const n: usize = @intCast(id & 0x1f);
            if (n < v.n_subp and v.subp_lang[n] != 0) hddvd_fmt_set_language(fmt, v.subp_lang[n]);
        }
    } else if (fmt.i_cat == vlc.AUDIO_ES and (id & 0xff00) == 0xbd00) {
        if (sys.vm.vts()) |v| {
            const n: usize = @intCast(id & 7);
            if (n < v.n_audio and v.audio_lang[n] != 0) hddvd_fmt_set_language(fmt, v.audio_lang[n]);
        }
    }
}

fn esAdded(demux: *vlc.demux_t, id: c_int, es: *vlc.es_out_id_t) callconv(.c) void {
    if (adv.owns(demux)) return adv.esAdded(demux, id, es);
    const sys = sysOf(demux);
    log(asObj(demux), vlc.VLC_MSG_DBG, @src(), "ES added: id 0x%x", .{@as(c_uint, @bitCast(id))});
    sys.tracks.append(gpa, .{ .es = es, .id = id }) catch {};
    if ((id & 0xffe0) == 0xbd20) sys.spus.append(gpa, .{ .es = es, .id = id }) catch {};
}

fn esDeleted(demux: *vlc.demux_t, es: *vlc.es_out_id_t) callconv(.c) void {
    if (adv.owns(demux)) return adv.esDeleted(demux, es);
    const sys = sysOf(demux);
    for (sys.tracks.items, 0..) |t, i| if (t.es == es) {
        _ = sys.tracks.swapRemove(i);
        break;
    };
    for (sys.spus.items, 0..) |*t, i| if (t.es == es) {
        t.deinit();
        _ = sys.spus.swapRemove(i);
        break;
    };
}

/// Reassembles sub-picture units and sends each whole unit, prefixed with the current PGC palette, to our
/// sub-picture decoder (spudec.zig). Returns the block to send on, or null if it was consumed.
fn esFilter(demux: *vlc.demux_t, es: *vlc.es_out_id_t, block: *vlc.block_t) callconv(.c) ?*vlc.block_t {
    if (adv.owns(demux)) return adv.esFilter(demux, es, block);
    const sys = sysOf(demux);
    const t = for (sys.spus.items) |*t| {
        if (t.es == es) break t;
    } else return block;

    const data = block.p_buffer[0..block.i_buffer];
    if (block.i_pts > 0) { // the packet carrying a unit's first byte has the PTS
        t.buf.clearRetainingCapacity();
        t.pts = block.i_pts;
    }
    if (t.buf.items.len == 0 and block.i_pts <= 0) {
        hddvd_block_release(block);
        return null;
    }
    t.buf.appendSlice(gpa, data) catch {};
    hddvd_block_release(block);

    const size = spudec.unitSize(t.buf.items) orelse return null;
    if (t.buf.items.len < size) return null;
    defer t.buf.clearRetainingCapacity();
    if (size < 4) return null;

    // Block for spudec.zig: the current PGC palette, then the unit.
    const out = gpa.alloc(u8, spudec.palette_size + size) catch return null;
    const palette: [16]u32 = if (sys.vm.pgc()) |p| p.hd_palette else @splat(0);
    for (palette, 0..) |c, i| std.mem.writeInt(u32, out[i * 4 ..][0..4], c, .big);
    @memcpy(out[spudec.palette_size..], t.buf.items[0..size]);
    log(asObj(demux), vlc.VLC_MSG_DBG, @src(), "sub-picture unit 0x%x: %u bytes", .{ @as(c_uint, @bitCast(t.id)), @as(c_uint, @intCast(size)) });
    gpa.free(t.last);
    t.last = out;
    t.last_pts = t.pts;
    return spuBlock(out, t.pts);
}

fn spuBlock(data: []const u8, pts: i64) ?*vlc.block_t {
    const out = vlc.block_Alloc(data.len) orelse return null;
    @memcpy(out.*.p_buffer[0..data.len], data);
    out.*.i_pts = pts;
    out.*.i_dts = pts;
    return out;
}

// Linked from C but kept out of the DLL/dylib export table: VLC only needs vlc_entry*.
comptime {
    const hidden: std.builtin.SymbolVisibility = .hidden;
    @export(&open, .{ .name = "HddvdOpen", .visibility = hidden });
    @export(&close, .{ .name = "HddvdClose", .visibility = hidden });
    @export(&getPosition, .{ .name = "hddvd_get_position", .visibility = hidden });
    @export(&setPosition, .{ .name = "hddvd_set_position", .visibility = hidden });
    @export(&getLength, .{ .name = "hddvd_get_length", .visibility = hidden });
    @export(&getTime, .{ .name = "hddvd_get_time", .visibility = hidden });
    @export(&setTime, .{ .name = "hddvd_set_time", .visibility = hidden });
    @export(&getTitleInfo, .{ .name = "hddvd_get_title_info", .visibility = hidden });
    @export(&setTitle, .{ .name = "hddvd_set_title", .visibility = hidden });
    @export(&setSeekpoint, .{ .name = "hddvd_set_seekpoint", .visibility = hidden });
    @export(&navControl, .{ .name = "hddvd_nav", .visibility = hidden });
    @export(&streamSize, .{ .name = "hddvd_stream_size", .visibility = hidden });
    @export(&esFixup, .{ .name = "hddvd_es_fixup", .visibility = hidden });
    @export(&esAdded, .{ .name = "hddvd_es_added", .visibility = hidden });
    @export(&esDeleted, .{ .name = "hddvd_es_deleted", .visibility = hidden });
    @export(&esFilter, .{ .name = "hddvd_es_filter", .visibility = hidden });
}
