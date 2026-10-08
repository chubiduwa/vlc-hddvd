//! HD DVD Advanced Content playback (the demux side): the Playlist drives a Title Timeline whose Primary Audio
//! Video Clips are streamed, like Standard Content cells, to VLC's own "ps" demuxer through our ES output proxy.
//!
//! - Startup (Vol. 1 §4.3.22.2): ADV_OBJ/DISCID.DAT marks the disc; the highest-numbered ADV_OBJ/VPLST###.XPL
//!   is the playlist; HVDVD_TS/HVA00001.VTI names the EVOBs. The FirstPlayTitle plays first, then title 1.
//! - Each clip maps title time to an EVOB through its TMAP (tmap.zig, timeline.zig).
//! - A seamless move to the next clip just continues the stream. Any other move (a gap, another title) waits
//!   until the current clip has been presented, then resets VLC's clock, as hddvd.zig does between cells.
//! - VLC titles are the playlist's titles, chapters its ChapterList; tracks get the TrackNavigationList's
//!   languages and descriptions.

const std = @import("std");
const vlc = @import("vlc");
const vfs = @import("../vfs.zig");
const spudec = @import("../spudec.zig");
const xpl = @import("xpl.zig");
const vti_mod = @import("vti.zig");
const tmap = @import("tmap.zig");
const aca = @import("aca.zig");
const timeline = @import("timeline.zig");
const present = @import("present.zig");
const vdec = @import("vdec.zig");
const adec = @import("adec.zig");
const pipdec = @import("pipdec.zig");
const access_mod = @import("access.zig");

const gpa = std.heap.c_allocator;
const sector_size = 2048;

const HddvdStreamControl = @extern(@FieldType(vlc.stream_t, "pf_control"), .{ .name = "HddvdStreamControl" });
const HddvdDemuxControl = @extern(@FieldType(vlc.demux_t, "pf_control"), .{ .name = "HddvdDemuxControl" });
extern fn hddvd_es_out_control(out: *vlc.es_out_t, query: c_int, ...) callconv(.c) c_int;
extern fn hddvd_stream_delete(s: *vlc.stream_t) void;
extern fn hddvd_set_update(demux: *vlc.demux_t, flags: c_uint, title: c_int, seekpoint: c_int) void;
extern fn hddvd_esout_new(demux: *vlc.demux_t) ?*vlc.es_out_t;
extern fn hddvd_esout_delete(out: ?*vlc.es_out_t) void;
extern fn hddvd_es_select(demux: *vlc.demux_t, es: *vlc.es_out_id_t, on: bool) void;
extern fn hddvd_es_out_empty(demux: *vlc.demux_t) bool;
extern fn hddvd_sleep_ms(ms: c_int) void;
extern fn hddvd_now_us() i64;
extern fn hddvd_input_title_set_flags(t: *vlc.input_title_t, flags: c_int, name: ?[*:0]const u8) void;
extern fn hddvd_seekpoint_set_name(s: *vlc.seekpoint_t, name: ?[*:0]const u8) void;
extern fn hddvd_block_release(b: *vlc.block_t) void;
extern fn hddvd_fmt_set_extra(fmt: *vlc.es_format_t, data: [*]const u8, len: usize) void;
extern fn hddvd_fmt_set_description(fmt: *vlc.es_format_t, desc: ?[*:0]const u8) void;
extern fn hddvd_fmt_set_language_str(fmt: *vlc.es_format_t, lang: [*:0]const u8) void;
extern fn hddvd_es_send(demux: *vlc.demux_t, es: *vlc.es_out_id_t, block: *vlc.block_t) void;
extern fn hddvd_es_selected(demux: *vlc.demux_t, es: *vlc.es_out_id_t) bool;
extern fn hddvd_inherit_string(obj: *vlc.vlc_object_t, name: [*:0]const u8) ?[*:0]u8;
extern fn hddvd_free(p: ?*anyopaque) void;

fn log(obj: *vlc.vlc_object_t, prio: c_int, src: std.builtin.SourceLocation, comptime fmt: [*:0]const u8, args: anytype) void {
    @call(.auto, vlc.vlc_Log, .{ obj, prio, "hddvd", src.file, @as(c_uint, src.line), src.fn_name, fmt } ++ args);
}

/// `s` as a C string in `buf` (truncated to fit).
fn z(buf: []u8, s: []const u8) [*:0]const u8 {
    const n = @min(s.len, buf.len - 1);
    @memcpy(buf[0..n], s[0..n]);
    buf[n] = 0;
    return @ptrCast(buf.ptr);
}

/// The disc path of a "file:///dvddisc/…" URI, or null for another scheme.
pub fn discPath(uri: []const u8) ?[]const u8 {
    const prefix = "file:///dvddisc/";
    if (std.ascii.startsWithIgnoreCase(uri, prefix)) return uri[prefix.len..];
    return null;
}

/// True if the disc has Advanced Content (ADV_OBJ/DISCID.DAT exists).
pub fn detect(fs: *vfs.Fs) bool {
    var f = fs.openFile("ADV_OBJ/DISCID.DAT") catch return false;
    f.close();
    return true;
}

const SpuTrack = struct {
    es: *vlc.es_out_id_t,
    id: c_int,
    buf: std.ArrayList(u8) = .empty,
    pts: i64 = 0,
};

const EsTrack = struct { es: *vlc.es_out_id_t, id: c_int };

/// A stream forwarded into a main ES (sub video into the main video, sub audio into the main audio).
const SubStream = struct { es: ?*vlc.es_out_id_t = null, id: c_int = -1, codec: u32 = 0 };

/// What happens once the current clip has been presented.
const Next = union(enum) {
    none,
    /// Continue the title at this span (after a gap or a non-seamless join).
    span: timeline.Span,
    /// Start this title (null: stop).
    title: ?usize,
};

pub const Player = struct {
    obj: *vlc.vlc_object_t,
    fs: *vfs.Fs,
    pl: xpl.Playlist,
    vti: vti_mod.Vti,
    disc_id: aca.DiscId,
    maps: std.StringHashMapUnmanaged(tmap.Tmap) = .empty,
    /// Data access, the File Cache and the persistent storage.
    access: *access_mod.Access,
    /// When the File Cache was last brought up to the title time (µs).
    res_tick: i64 = 0,

    // Timeline.
    /// Current title (null: the FirstPlayTitle).
    title: ?usize = null,
    span: ?timeline.Span = null,
    evob: ?*const vti_mod.Evob = null,
    tmapi: ?*const tmap.Tmapi = null,
    /// Title time where reading started, and its VLC timestamp, the reference for the playback position.
    ref_time: u64 = 0,
    ref_ts: i64 = 0,
    next: Next = .none,
    stopped: bool = false,
    wait_ticks: u32 = 0,

    // Reader.
    file: ?vfs.File = null,
    file_evob: ?*const vti_mod.Evob = null,
    pos: u64 = 0,
    end: u64 = 0,
    sector: [sector_size]u8 = undefined,
    sector_off: usize = sector_size,

    // VLC objects.
    stream: ?*vlc.stream_t = null,
    ps: ?*vlc.demux_t = null,
    esout: ?*vlc.es_out_t = null,
    tracks: std.ArrayList(EsTrack) = .empty,
    spus: std.ArrayList(SpuTrack) = .empty,
    spu_shared: ?*spudec.Shared = null,
    pres: ?*present.Presentation = null,
    /// The main video ES (our compositor) and the forwarded sub streams.
    main_video: ?*vlc.es_out_id_t = null,
    sub_video: SubStream = .{},
    sub_audio: SubStream = .{},
    cur_title: c_int = -1,
    cur_seekpoint: c_int = -1,

    fn tb(p: *const Player) xpl.TimeBase {
        return p.pl.time_base;
    }

    fn curTitle(p: *const Player) ?*const xpl.Title {
        if (p.title) |i| return &p.pl.titles[i];
        return if (p.pl.first_play) |*fp| fp else null;
    }

    fn closeFile(p: *Player) void {
        if (p.file) |*f| f.close();
        p.file = null;
        p.file_evob = null;
    }

    fn deinit(p: *Player) void {
        p.closeFile();
        var it = p.maps.iterator();
        while (it.next()) |e| {
            gpa.free(e.key_ptr.*);
            e.value_ptr.deinit();
        }
        p.maps.deinit(gpa);
        for (p.spus.items) |*t| t.buf.deinit(gpa);
        p.spus.deinit(gpa);
        p.tracks.deinit(gpa);
        p.vti.deinit();
        p.pl.deinit();
        p.access.destroy();
    }

    fn loadMap(p: *Player, uri: []const u8) !*const tmap.Tmap {
        if (p.maps.getPtr(uri)) |m| return m;
        const path = discPath(uri) orelse return error.NotFound;
        const bytes = (try p.fs.readFile(gpa, path)) orelse return error.NotFound;
        defer gpa.free(bytes);
        var m = try tmap.parse(gpa, bytes);
        errdefer m.deinit();
        const key = try gpa.dupe(u8, uri);
        errdefer gpa.free(key);
        try p.maps.put(gpa, key, m);
        return p.maps.getPtr(uri).?;
    }
};

fn playerOf(demux: *vlc.demux_t) *Player {
    return @ptrCast(@alignCast(demux.p_sys));
}

fn asObj(demux: *vlc.demux_t) *vlc.vlc_object_t {
    return @ptrCast(demux);
}

/// True if `demux` is playing Advanced Content (installed by `open`).
pub fn owns(demux: *vlc.demux_t) bool {
    return demux.pf_demux == demuxOne;
}

// ---- startup ------------------------------------------------------------------------------------------------

/// Reads the startup files of an Advanced Content disc and starts the FirstPlayTitle (or title 1). Takes `fs`.
pub fn open(demux: *vlc.demux_t, fs: *vfs.Fs) c_int {
    const o = asObj(demux);
    var zb: [256]u8 = undefined;
    const p = gpa.create(Player) catch {
        fs.close();
        return vlc.VLC_ENOMEM;
    };
    load(p, o, fs) catch |err| {
        log(o, vlc.VLC_MSG_ERR, @src(), "cannot load the Advanced Content playlist (%s)", .{@errorName(err).ptr});
        gpa.destroy(p);
        fs.close();
        return vlc.VLC_EGENERIC;
    };
    p.spu_shared = spudec.Shared.create();
    if (p.spu_shared) |sh| p.pres = present.Presentation.create(sh);
    if (p.pres) |pr| {
        pr.aperture_w = p.pl.aperture_w;
        pr.aperture_h = p.pl.aperture_h;
        pr.outer = .{ @intCast(p.pl.default_color >> 16), @intCast((p.pl.default_color >> 8) & 0xff), @intCast(p.pl.default_color & 0xff) };
        debugOptions(o, pr);
    }
    demux.p_sys = @ptrCast(p);
    demux.pf_demux = demuxOne;
    demux.pf_control = HddvdDemuxControl;
    log(o, vlc.VLC_MSG_INFO, @src(), "HD DVD Advanced Content: \"%s\", %u titles, %u EVOBs", .{
        z(&zb, p.pl.display_name), @as(c_uint, @intCast(p.pl.titles.len)), @as(c_uint, @intCast(p.vti.evobs.len)),
    });

    p.esout = hddvd_esout_new(demux) orelse {
        close(demux);
        return vlc.VLC_ENOMEM;
    };
    if (p.pl.first_play != null) {
        startTitle(demux, null, 0);
    } else if (timeline.nextTitle(&p.pl, null)) |t| {
        startTitle(demux, t, 0);
    } else p.stopped = true;
    if (p.ps == null and !p.stopped) {
        close(demux);
        return vlc.VLC_EGENERIC;
    }
    _ = hddvd_es_out_control(demux.out, vlc.ES_OUT_SET_ES_CAT_POLICY, @as(c_int, vlc.SPU_ES), @as(c_int, vlc.ES_OUT_ES_POLICY_SIMULTANEOUS));
    return vlc.VLC_SUCCESS;
}

/// --hddvd-pip=x,y,w,h[,alpha] and --hddvd-sub-mix=level: show the sub video and mix the sub audio without the
/// disc's application.
fn debugOptions(o: *vlc.vlc_object_t, pr: *present.Presentation) void {
    if (hddvd_inherit_string(o, "hddvd-pip")) |str| {
        defer hddvd_free(str);
        var v: [5]i32 = .{ 0, 0, 0, 0, 255 };
        var it = std.mem.tokenizeAny(u8, std.mem.span(str), ", ");
        var n: usize = 0;
        while (it.next()) |t| : (n += 1) {
            if (n == v.len) break;
            v[n] = std.fmt.parseInt(i32, t, 10) catch break;
        }
        if (n >= 4) pr.setSubLayout(.{ .x = v[0], .y = v[1], .w = v[2], .h = v[3] }, @intCast(std.math.clamp(v[4], 0, 255)));
    }
    if (hddvd_inherit_string(o, "hddvd-sub-mix")) |str| {
        defer hddvd_free(str);
        pr.sub_gain = std.math.clamp(std.fmt.parseFloat(f32, std.mem.span(str)) catch 0, 0, 1);
    }
}

fn load(p: *Player, o: *vlc.vlc_object_t, fs: *vfs.Fs) !void {
    const id_bytes = (try fs.readFile(gpa, "ADV_OBJ/DISCID.DAT")) orelse return error.NotFound;
    defer gpa.free(id_bytes);
    const disc_id = aca.DiscId.parse(id_bytes) orelse return error.BadDiscId;
    const acc = try access_mod.Access.create(o, fs, disc_id);
    errdefer acc.destroy();

    // The highest-numbered VPLST###.XPL, else APLST### (§4.3.22.2 steps 3–4), on the disc or, unless
    // SEARCH_FLG says otherwise, in this disc's area of the persistent storage.
    const names = try fs.listDir(gpa, "ADV_OBJ");
    defer vfs.freeNames(gpa, names);
    const content = aca.DiscId.guid(disc_id.content_id);
    var pl_bytes: ?[]u8 = null;
    defer if (pl_bytes) |b| gpa.free(b);
    var zb: [256]u8 = undefined;
    for ([_][]const u8{ "VPLST", "APLST" }) |kind| {
        var best: ?[]const u8 = null;
        var best_n: i32 = -1;
        for (names) |n| {
            if (n.len != 12 or !std.ascii.startsWithIgnoreCase(n, kind) or !std.ascii.endsWithIgnoreCase(n, ".XPL")) continue;
            const num = std.fmt.parseInt(i32, n[5..8], 10) catch continue;
            if (num > best_n) {
                best_n = num;
                best = n;
            }
        }
        if (disc_id.search_flag & 1 == 0) if (content) |cid| if (acc.store.findPlaylist(&cid, kind)) |f| if (f.number > best_n) {
            const u = try std.fmt.allocPrint(gpa, "file:///required/{s}/{s}{d:0>3}.XPL", .{ &cid, kind, f.number });
            defer gpa.free(u);
            pl_bytes = acc.read(u) catch null;
            if (pl_bytes != null) log(o, vlc.VLC_MSG_DBG, @src(), "playlist %s", .{z(&zb, u)});
        };
        if (pl_bytes == null) if (best) |n| {
            const path = try std.fmt.allocPrint(gpa, "ADV_OBJ/{s}", .{n});
            defer gpa.free(path);
            pl_bytes = try fs.readFile(gpa, path);
            if (pl_bytes != null) log(o, vlc.VLC_MSG_DBG, @src(), "playlist %s", .{z(&zb, path)});
        };
        if (pl_bytes != null) break;
    }
    var pl = try xpl.parse(gpa, aca.unwrap(pl_bytes orelse return error.NoPlaylist));
    errdefer pl.deinit();

    const vti_bytes = (try fs.readFile(gpa, "HVDVD_TS/HVA00001.VTI")) orelse return error.NoVti;
    defer gpa.free(vti_bytes);
    const v = try vti_mod.parse(gpa, vti_bytes);
    p.* = .{ .obj = o, .fs = fs, .pl = pl, .vti = v, .disc_id = disc_id, .access = acc };
    acc.configure(&p.pl);
}

pub fn close(demux: *vlc.demux_t) void {
    const p = playerOf(demux);
    // demux_Delete also deletes the demuxer's stream.
    if (p.ps) |ps| vlc.demux_Delete(ps) else if (p.stream) |s| hddvd_stream_delete(s);
    if (p.pres) |pr| pr.unref();
    if (p.spu_shared) |sh| sh.unref();
    hddvd_esout_delete(p.esout);
    p.fs.close();
    p.deinit();
    gpa.destroy(p);
    demux.p_sys = null;
}

// ---- the timeline -------------------------------------------------------------------------------------------

/// Starts title `index` (null: First Play) at title time `t`, with fresh ESes (their names depend on the title).
fn startTitle(demux: *vlc.demux_t, index: ?usize, t: u64) void {
    const p = playerOf(demux);
    var zb: [256]u8 = undefined;
    p.title = index;
    p.next = .none;
    const title = p.curTitle() orelse {
        p.stopped = true;
        return;
    };
    log(asObj(demux), vlc.VLC_MSG_DBG, @src(), "title %d \"%s\" at frame %u", .{
        if (index) |i| @as(c_int, @intCast(i)) else -1,
        z(&zb, title.id),
        @as(c_uint, @intCast(t)),
    });
    // The File Cache before the presentation (§4.3.22.2 step 7; a Playlist Application's resources missing
    // at the end of the First Play hold the timeline until loaded, §4.3.19.6.2.2).
    p.access.startTitle(&p.pl, title, index == null, t);
    p.res_tick = hddvd_now_us();
    const span = timeline.spanFrom(title, t) orelse {
        // Nothing to present (an application-only title): move on.
        p.next = .{ .title = timeline.nextTitle(&p.pl, p.title) };
        return;
    };
    if (!positionSpan(demux, span, @max(t, span.begin))) return;
    // A new ps demuxer: the ESes are recreated with this title's track names. It peeks at the stream when it
    // opens, so the reader is positioned first.
    if (p.ps) |ps| {
        vlc.demux_Delete(ps); // and its stream
        p.stream = null;
    }
    p.ps = null;
    p.main_video = null;
    p.sub_video = .{};
    p.sub_audio = .{};
    p.tracks.clearRetainingCapacity();
    for (p.spus.items) |*s| s.buf.deinit(gpa);
    p.spus.clearRetainingCapacity();
    _ = hddvd_es_out_control(demux.out, vlc.ES_OUT_RESET_PCR);
    openPs(demux) catch |err| {
        log(asObj(demux), vlc.VLC_MSG_ERR, @src(), "cannot start the ps demuxer: %s", .{@errorName(err).ptr});
        p.stopped = true;
        return;
    };
    p.stopped = false;
    updateTitleInfo(demux);
}

/// Positions the reader on `span` at title time `t`. False (and stopped) if its files are missing.
fn positionSpan(demux: *vlc.demux_t, span: timeline.Span, t: u64) bool {
    const p = playerOf(demux);
    var zb: [256]u8 = undefined;
    const m = p.loadMap(span.clip.src) catch |err| {
        log(asObj(demux), vlc.VLC_MSG_ERR, @src(), "cannot load the time map %s (%s)", .{ z(&zb, span.clip.src), @errorName(err).ptr });
        p.stopped = true;
        return false;
    };
    if (m.tmapis.len == 0) {
        p.stopped = true;
        return false;
    }
    // Angle n of an interleaved block is TMAPI n.
    const angle: usize = if (span.clip.video.len > 0) span.clip.video[0].angle else 1;
    const mi = &m.tmapis[@min(angle, m.tmapis.len) - 1];
    const evob = p.vti.byIndex(mi.evob_index) orelse {
        log(asObj(demux), vlc.VLC_MSG_ERR, @src(), "EVOB %u is not in the VTI", .{@as(c_uint, mi.evob_index)});
        p.stopped = true;
        return false;
    };
    if (p.file_evob != evob) {
        p.closeFile();
        const path = std.fmt.allocPrint(gpa, "HVDVD_TS/{s}", .{evob.name}) catch return false;
        defer gpa.free(path);
        p.file = p.fs.openFile(path) catch |err| {
            log(asObj(demux), vlc.VLC_MSG_ERR, @src(), "cannot open %s (%s)", .{ z(&zb, path), @errorName(err).ptr });
            p.stopped = true;
            return false;
        };
        p.file_evob = evob;
    }
    const r = timeline.sectorRange(mi, span, t, span.end);
    if (p.pres) |pr| if (p.vti.attrOf(evob)) |a| {
        pr.lockIt();
        pr.luma_key = if (a.luma != 0) .{ @intCast(a.luma >> 8), @intCast(a.luma & 0xff) } else null;
        pr.unlock();
    };
    p.span = span;
    p.evob = evob;
    p.tmapi = mi;
    updateSubVideo(demux);
    p.pos = @as(u64, evob.adr_ofs) * sector_size + r.first * sector_size;
    p.end = @as(u64, evob.adr_ofs) * sector_size + r.end * sector_size;
    p.sector_off = sector_size;
    p.ref_time = t;
    p.ref_ts = tsOf(timeline.pts(span, p.tb(), evob.start_ptm, t));
    log(asObj(demux), vlc.VLC_MSG_DBG, @src(), "clip %s: frames %u-%u, sectors %u-%u", .{
        z(&zb, evob.name),     @as(c_uint, @intCast(t)), @as(c_uint, @intCast(span.end)),
        @as(c_uint, @intCast(r.first)), @as(c_uint, @intCast(r.end)),
    });
    return true;
}

/// VLC timestamp of a 90 kHz PTS, as VLC's ps demuxer produces it (VLC_TICK_0 + µs).
fn tsOf(pts90: u64) i64 {
    return 1 + @as(i64, @intCast(pts90 * 100 / 9));
}

/// Jumps within the current title at once (a user seek): the decoders are flushed.
fn jump(demux: *vlc.demux_t, t: u64) bool {
    const p = playerOf(demux);
    const title = p.curTitle() orelse return false;
    const span = timeline.spanFrom(title, t) orelse return false;
    const at = @max(t, span.begin);
    if (!positionSpan(demux, span, at)) return false;
    p.access.jumped(&p.pl, title, p.title == null, at);
    p.next = .none;
    _ = hddvd_es_out_control(demux.out, vlc.ES_OUT_RESET_PCR);
    // Frames before the target (from the start of its EVOBU) are decoded but not shown.
    _ = hddvd_es_out_control(demux.out, vlc.ES_OUT_SET_NEXT_DISPLAY_TIME, p.ref_ts);
    for (p.spus.items) |*s| s.buf.clearRetainingCapacity();
    updateTitleInfo(demux);
    return true;
}

/// The clip has been read: continue seamlessly, or decide what follows once it is presented.
fn clipRead(demux: *vlc.demux_t) void {
    const p = playerOf(demux);
    const title = p.curTitle() orelse return;
    const span = p.span orelse return;
    if (span.end < title.duration) if (timeline.spanFrom(title, span.end)) |next| {
        if (next.begin == span.end and next.clip.seamless) {
            if (positionSpan(demux, next, next.begin)) return;
        }
        p.next = .{ .span = next };
        return;
    };
    p.next = .{ .title = timeline.nextTitle(&p.pl, p.title) };
}

/// True once the end of the current span is on screen (or everything sent has been presented).
fn spanPresented(demux: *vlc.demux_t) bool {
    const p = playerOf(demux);
    if (hddvd_es_out_empty(demux)) return true;
    const span = p.span orelse return true;
    const evob = p.evob orelse return true;
    const sh = p.spu_shared orelse return false;
    const ts = tsOf(timeline.pts(span, p.tb(), evob.start_ptm, span.end));
    const maybe = sh.displayDate(ts) catch return false; // no clock: wait for the decoders to drain
    const date = maybe orelse return false;
    return date <= hddvd_now_us();
}

/// The title time on screen: from a decoder's clock when there is one, else from the read position.
fn titleNow(p: *Player) u64 {
    const span = p.span orelse return 0;
    if (p.spu_shared) |sh| {
        const maybe = sh.displayDate(p.ref_ts) catch null;
        if (maybe) |date| {
            // The reference may still be ahead of the screen (negative elapsed time) after a seamless join.
            const t_us = p.tb().us(p.ref_time) + (hddvd_now_us() - date);
            return @min(p.tb().frames(t_us), p.curTitle().?.duration);
        }
    }
    const m = p.tmapi orelse return span.begin;
    const evob = p.evob orelse return span.begin;
    const sector = (p.pos / sector_size) -| evob.adr_ofs;
    return span.titleTime(tmap.timeAt(m, sector) / 4);
}

/// VLC title = playlist title index; chapter from the title time on screen.
fn updateTitleInfo(demux: *vlc.demux_t) void {
    const p = playerOf(demux);
    const t: c_int = if (p.title) |i| @intCast(i) else return;
    const title = &p.pl.titles[p.title.?];
    const ch = title.chapterAt(titleNow(p));
    const sp: c_int = if (ch > 0) @intCast(ch - 1) else 0;
    var flags: c_uint = 0;
    if (t != p.cur_title) flags |= vlc.INPUT_UPDATE_TITLE | vlc.INPUT_UPDATE_SEEKPOINT;
    if (sp != p.cur_seekpoint) flags |= vlc.INPUT_UPDATE_SEEKPOINT;
    if (flags == 0) return;
    p.cur_title = t;
    p.cur_seekpoint = sp;
    hddvd_set_update(demux, flags, t, sp);
}

// ---- demux loop ---------------------------------------------------------------------------------------------

fn demuxOne(demux_c: [*c]vlc.demux_t) callconv(.c) c_int {
    const demux: *vlc.demux_t = demux_c;
    const p = playerOf(demux);
    if (p.stopped) return 0;
    switch (p.next) {
        .none => {},
        else => {
            // The clip has been read; move on once it has been presented.
            if (!spanPresented(demux)) {
                if (p.wait_ticks % 100 == 0) log(asObj(demux), vlc.VLC_MSG_DBG, @src(), "end of clip: waiting for presentation (%u)", .{p.wait_ticks});
                p.wait_ticks += 1;
                hddvd_sleep_ms(10);
                return 1;
            }
            p.wait_ticks = 0;
            const next = p.next;
            p.next = .none;
            switch (next) {
                .span => |s| {
                    if (positionSpan(demux, s, s.begin)) {
                        _ = hddvd_es_out_control(demux.out, vlc.ES_OUT_RESET_PCR);
                        for (p.spus.items) |*t| t.buf.clearRetainingCapacity();
                    }
                },
                .title => |t| if (t) |i| startTitle(demux, i, 0) else {
                    log(asObj(demux), vlc.VLC_MSG_DBG, @src(), "playlist ended", .{});
                    p.stopped = true;
                },
                .none => {},
            }
            return if (p.stopped) 0 else 1;
        },
    }
    if (p.pos < p.end or p.sector_off < sector_size) {
        const ps = p.ps orelse return -1;
        if (ps.pf_demux.?(ps) == 0) {
            p.pos = p.end; // read error mid-clip: skip to its end
            p.sector_off = sector_size;
        }
        updateTitleInfo(demux);
        updateResources(demux);
        return 1;
    }
    clipRead(demux);
    return 1;
}

/// Brings the File Cache up to the title time on screen, a few times a second.
fn updateResources(demux: *vlc.demux_t) void {
    const p = playerOf(demux);
    const now = hddvd_now_us();
    if (now - p.res_tick < 200_000) return;
    p.res_tick = now;
    const title = p.curTitle() orelse return;
    p.access.update(&p.pl, title, p.title == null, titleNow(p), false);
}

// ---- the stream that feeds the ps demuxer -------------------------------------------------------------------

fn streamRead(s: [*c]vlc.stream_t, buf: ?*anyopaque, len: usize) callconv(.c) isize {
    const p: *Player = @ptrCast(@alignCast(s.*.p_sys));
    const out: [*]u8 = @ptrCast(buf orelse return -1);
    if (p.sector_off == sector_size) {
        if (p.pos >= p.end) return 0;
        const f = &(p.file orelse return 0);
        const n = f.pread(p.pos, &p.sector) catch return -1;
        if (n != sector_size) {
            p.pos = p.end;
            return 0;
        }
        p.pos += sector_size;
        p.sector_off = 0;
        p.access.sector(&p.sector);
    }
    const n = @min(len, sector_size - p.sector_off);
    @memcpy(out[0..n], p.sector[p.sector_off..][0..n]);
    p.sector_off += n;
    return @intCast(n);
}

fn streamSeek(s: [*c]vlc.stream_t, offset: u64) callconv(.c) c_int {
    _ = s;
    _ = offset;
    return vlc.VLC_EGENERIC;
}

fn streamDestroy(s: [*c]vlc.stream_t) callconv(.c) void {
    _ = s;
}

/// A new stream and ps demuxer on it (a stream keeps the previous demuxer's peek buffer, so it is not reused).
/// The demuxer owns the stream once it opens (demux_Delete deletes it); until then it is ours.
fn openPs(demux: *vlc.demux_t) !void {
    const p = playerOf(demux);
    if (p.stream) |old| hddvd_stream_delete(old);
    p.stream = null;
    const raw = vlc.vlc_stream_CommonNew(asObj(demux), streamDestroy);
    if (raw == null) return error.OutOfMemory;
    const s: *vlc.stream_t = raw;
    s.pf_read = streamRead;
    s.pf_seek = streamSeek;
    s.pf_control = HddvdStreamControl;
    s.p_sys = p;
    p.stream = s;
    const ps = vlc.demux_New(asObj(demux), "ps", demux.psz_location, s, p.esout.?);
    if (ps == null) return error.OpenFailed;
    p.ps = ps;
}

// ---- controls -----------------------------------------------------------------------------------------------

pub fn getLength(demux: *vlc.demux_t, out: *i64) c_int {
    const p = playerOf(demux);
    out.* = if (p.curTitle()) |t| p.tb().us(t.duration) else 0;
    return vlc.VLC_SUCCESS;
}

pub fn getTime(demux: *vlc.demux_t, out: *i64) c_int {
    const p = playerOf(demux);
    out.* = p.tb().us(titleNow(p));
    return vlc.VLC_SUCCESS;
}

pub fn getPosition(demux: *vlc.demux_t, out: *f64) c_int {
    const p = playerOf(demux);
    const t = p.curTitle() orelse return vlc.VLC_EGENERIC;
    out.* = if (t.duration > 0) @as(f64, @floatFromInt(titleNow(p))) / @as(f64, @floatFromInt(t.duration)) else 0;
    return vlc.VLC_SUCCESS;
}

pub fn setTime(demux: *vlc.demux_t, t_us: i64) c_int {
    const p = playerOf(demux);
    if (p.title == null) return vlc.VLC_EGENERIC; // First Play cannot be skipped through
    return if (jump(demux, p.tb().frames(t_us))) vlc.VLC_SUCCESS else vlc.VLC_EGENERIC;
}

pub fn setPosition(demux: *vlc.demux_t, f: f64) c_int {
    const p = playerOf(demux);
    const t = p.curTitle() orelse return vlc.VLC_EGENERIC;
    if (p.title == null) return vlc.VLC_EGENERIC;
    const frame: u64 = @intFromFloat(@as(f64, @floatFromInt(t.duration)) * std.math.clamp(f, 0, 1));
    return if (jump(demux, frame)) vlc.VLC_SUCCESS else vlc.VLC_EGENERIC;
}

/// VLC's title list: the playlist's titles (by index), named, with their chapters.
/// NOTE (Windows): VLC frees these with its own C runtime's free(); fine on macOS/Linux.
pub fn getTitleInfo(demux: *vlc.demux_t, out_titles: *[*c][*c]vlc.input_title_t, out_count: *c_int) c_int {
    const p = playerOf(demux);
    const titles = p.pl.titles;
    const list: [*c][*c]vlc.input_title_t = @ptrCast(@alignCast(std.c.malloc(@max(1, titles.len) * @sizeOf(*vlc.input_title_t)) orelse return vlc.VLC_ENOMEM));
    var name_buf: [256]u8 = undefined;
    for (titles, 0..) |t, i| {
        const it = vlc.vlc_input_title_New();
        it.*.i_length = p.tb().us(t.duration);
        const label = if (t.display_name.len > 0) t.display_name else if (t.description.len > 0) t.description else t.id;
        hddvd_input_title_set_flags(it, 0, z(&name_buf, label));
        const points: [*c][*c]vlc.seekpoint_t = @ptrCast(@alignCast(std.c.malloc(@max(1, t.chapters.len) * @sizeOf(*vlc.seekpoint_t)) orelse return vlc.VLC_ENOMEM));
        for (t.chapters, 0..) |c, k| {
            points[k] = vlc.vlc_seekpoint_New();
            points[k].*.i_time_offset = p.tb().us(c.begin);
            if (c.name.len > 0) hddvd_seekpoint_set_name(points[k], z(&name_buf, c.name));
        }
        it.*.seekpoint = points;
        it.*.i_seekpoint = @intCast(t.chapters.len);
        list[i] = it;
    }
    out_titles.* = list;
    out_count.* = @intCast(titles.len);
    return vlc.VLC_SUCCESS;
}

pub fn setTitle(demux: *vlc.demux_t, i: c_int) c_int {
    const p = playerOf(demux);
    if (i < 0 or i >= p.pl.titles.len) return vlc.VLC_EGENERIC;
    if (!p.pl.titles[@intCast(i)].selectable) return vlc.VLC_EGENERIC;
    startTitle(demux, @intCast(i), 0);
    return if (p.stopped) vlc.VLC_EGENERIC else vlc.VLC_SUCCESS;
}

pub fn setSeekpoint(demux: *vlc.demux_t, i: c_int) c_int {
    const p = playerOf(demux);
    const ti = p.title orelse return vlc.VLC_EGENERIC;
    const t = &p.pl.titles[ti];
    if (i < 0 or i >= t.chapters.len) return vlc.VLC_EGENERIC;
    return if (jump(demux, t.chapters[@intCast(i)].begin)) vlc.VLC_SUCCESS else vlc.VLC_EGENERIC;
}

/// DEMUX_NAV_*: without applications there is no default action for menu keys (Annex V).
pub fn navControl(demux: *vlc.demux_t, action: c_int) c_int {
    _ = demux;
    _ = action;
    return vlc.VLC_EGENERIC;
}

// ---- ES output proxy hooks ----------------------------------------------------------------------------------

/// Stream id of the PES packet the ps demuxer has just read (see hddvd.zig): 0xBDxx for private stream 1,
/// 0xFDxx for extended stream ids (VC-1), else the stream_id.
fn currentPacketId(p: *const Player) c_int {
    const s = &p.sector;
    if (!std.mem.eql(u8, s[0..4], &.{ 0, 0, 1, 0xba })) return -1;
    var q: usize = 14 + @as(usize, s[13] & 7);
    var id: c_int = -1;
    while (q + 6 <= sector_size and q < p.sector_off and std.mem.eql(u8, s[q..][0..3], &.{ 0, 0, 1 })) {
        const len = std.mem.readInt(u16, s[q + 4 ..][0..2], .big);
        id = s[q + 3];
        if (id == 0xbd and q + 9 <= sector_size) {
            const sub = q + 9 + @as(usize, s[q + 8]);
            if (sub < sector_size) id = 0xbd00 | @as(c_int, s[sub]);
        } else if (id == 0xfd) {
            if (extendedId(s[q..@min(sector_size, q + 6 + len)])) |ext| id = 0xfd00 | @as(c_int, ext);
        }
        q += 6 + len;
    }
    return id;
}

/// stream_id_extension of an extended-stream PES header (ISO 13818-1 amendment 2), as VLC's ps demuxer reads it.
fn extendedId(pkt: []const u8) ?u8 {
    if (pkt.len < 9 or pkt[6] & 0xc0 != 0x80 or pkt[7] & 0x01 == 0) return null;
    const flags = pkt[7];
    var i: usize = 9;
    if (flags & 0x80 != 0) i += 5;
    if (flags & 0xc0 == 0xc0) i += 5;
    if (flags & 0x20 != 0) i += 6;
    if (flags & 0x10 != 0) i += 3;
    if (flags & 0x08 != 0) i += 1;
    if (flags & 0x04 != 0) i += 1;
    if (flags & 0x02 != 0) i += 2;
    if (i >= pkt.len or pkt[i] & 0x01 == 0) return null;
    const f2 = pkt[i];
    i += 1;
    if (f2 & 0x80 != 0) i += 16;
    if (f2 & 0x40 != 0 and i < pkt.len) i += 1 + @as(usize, pkt[i]);
    if (f2 & 0x20 != 0) i += 2;
    if (f2 & 0x10 != 0) i += 2;
    if (i + 1 >= pkt.len or pkt[i] & 0x7f == 0) return null;
    if (pkt[i + 1] & 0x80 != 0) return null;
    return pkt[i + 1] & 0x7f;
}

/// Main audio sub_stream_ids (private stream 1): DD+ C0–C7, DTS-HD 88–8F, MLP B0–B7, LPCM A0–A7, AC-3 80–87.
pub fn isMainAudio(sub: u8) bool {
    return (sub & 0xf8) == 0xc0 or (sub & 0xf8) == 0x88 or (sub & 0xf8) == 0xb0 or (sub & 0xf8) == 0xa0 or (sub & 0xf8) == 0x80;
}

/// Sub audio sub_stream_ids: DD+ C8–CF, DTS-HD 98–9F, WMA Pro B8–BF.
pub fn isSubAudio(sub: u8) bool {
    return (sub & 0xf8) == 0xc8 or (sub & 0xf8) == 0x98 or (sub & 0xf8) == 0xb8;
}

pub fn esFixup(demux: *vlc.demux_t, fmt: *vlc.es_format_t) void {
    const p = playerOf(demux);
    if (fmt.i_id < 0) fmt.i_id = currentPacketId(p);
    const id = fmt.i_id;
    const span = p.span orelse return;
    const title = p.curTitle() orelse return;
    const clip = span.clip;
    var name_buf: [256]u8 = undefined;

    if (fmt.i_cat == vlc.SPU_ES and (id & 0xffe0) == 0xbd20) {
        fmt.i_codec = spudec.fourcc;
        fmt.b_packetized = true;
        if (p.spu_shared) |sh| {
            const e = sh.extra();
            hddvd_fmt_set_extra(fmt, &e, e.len);
        }
        fmt.unnamed_0.subs.spu.i_original_frame_width = p.pl.aperture_w;
        fmt.unnamed_0.subs.spu.i_original_frame_height = p.pl.aperture_h;
        // Which subtitle track uses this decoding stream number.
        const attr = if (p.evob) |e| p.vti.attrOf(e) else null;
        for (clip.subtitle) |st| {
            const a = attr orelse break;
            const n = a.hdSubpStream(st.stream -| 1) orelse continue;
            if (n != (id & 0x1f)) continue;
            if (title.subtitleNav(st.track)) |nav| {
                setLang(fmt, nav.langcode);
                const desc = if (nav.description.len > 0) nav.description else st.description;
                setDesc(fmt, &name_buf, desc, st.track);
            } else setDesc(fmt, &name_buf, st.description, st.track);
            return;
        }
        fmt.i_priority = vlc.ES_PRIORITY_NOT_SELECTABLE; // not a subtitle track of this title
    } else if (fmt.i_cat == vlc.AUDIO_ES and (id & 0xff00) == 0xbd00) {
        const sub: u8 = @intCast(id & 0xff);
        if (isSubAudio(sub)) {
            // Forwarded into the main audio ES and mixed by our decoder (adec.zig).
            fmt.i_priority = vlc.ES_PRIORITY_NOT_SELECTABLE;
            p.sub_audio = .{ .id = id, .codec = fmt.i_codec };
            setDesc(fmt, &name_buf, "Sub audio", 0);
            return;
        }
        toOurDecoder(p, fmt, adec.fourcc);
        for (clip.audio) |a| {
            if (a.stream -| 1 != (sub & 7)) continue;
            if (title.audioNav(a.track)) |nav| {
                setLang(fmt, nav.langcode);
                setDesc(fmt, &name_buf, if (nav.description.len > 0) nav.description else a.description, a.track);
            } else setDesc(fmt, &name_buf, a.description, a.track);
            // Track 1 is the default (§4.3.19.4); VLC prefers the highest priority.
            fmt.i_priority = if (a.track == 1) 16 else 1;
            return;
        }
        fmt.i_priority = vlc.ES_PRIORITY_NOT_SELECTABLE;
    } else if (fmt.i_cat == vlc.VIDEO_ES) {
        const main = id == 0xe0 or id == 0xe2 or id == 0xfd55;
        if (main) {
            toOurDecoder(p, fmt, vdec.fourcc);
        } else {
            // The sub video (E1, E3, FD-56…) becomes a sub-picture ES drawn as an overlay (pipdec.zig), selected
            // where the playlist assigns it.
            p.sub_video = .{ .id = id, .codec = fmt.i_codec };
            toOurDecoder(p, fmt, pipdec.fourcc);
            fmt.i_cat = vlc.SPU_ES;
            fmt.i_priority = vlc.ES_PRIORITY_NOT_DEFAULTABLE;
            fmt.unnamed_0.subs = std.mem.zeroes(vlc.subs_format_t);
            fmt.unnamed_0.subs.spu.i_original_frame_width = p.pl.aperture_w;
            fmt.unnamed_0.subs.spu.i_original_frame_height = p.pl.aperture_h;
            setDesc(fmt, &name_buf, "Picture-in-picture", 0);
        }
    }
}

/// Routes an ES to our decoder: private fourcc, the real codec in p_extra, and no VLC packetizer (ours packetize).
fn toOurDecoder(p: *Player, fmt: *vlc.es_format_t, fourcc: u32) void {
    const pr = p.pres orelse return;
    const e = pr.extra(fmt.i_codec);
    hddvd_fmt_set_extra(fmt, &e, e.len);
    fmt.i_codec = fourcc;
    fmt.b_packetized = true;
}

fn setLang(fmt: *vlc.es_format_t, code: []const u8) void {
    if (code.len < 2) return;
    var buf: [8]u8 = undefined;
    hddvd_fmt_set_language_str(fmt, z(&buf, code[0..2]));
}

fn setDesc(fmt: *vlc.es_format_t, buf: *[256]u8, desc: []const u8, track: u8) void {
    if (desc.len > 0) return hddvd_fmt_set_description(fmt, z(buf, desc));
    if (track == 0) return;
    const s = std.fmt.bufPrint(buf[0 .. buf.len - 1], "Track {d}", .{track}) catch return;
    buf[s.len] = 0;
    hddvd_fmt_set_description(fmt, @ptrCast(buf));
}

pub fn esAdded(demux: *vlc.demux_t, id: c_int, es: *vlc.es_out_id_t) void {
    const p = playerOf(demux);
    log(asObj(demux), vlc.VLC_MSG_DBG, @src(), "ES added: id 0x%x", .{@as(c_uint, @bitCast(id))});
    p.tracks.append(gpa, .{ .es = es, .id = id }) catch {};
    if ((id & 0xffe0) == 0xbd20) p.spus.append(gpa, .{ .es = es, .id = id }) catch {};
    if (id == p.sub_video.id) {
        p.sub_video.es = es;
        updateSubVideo(demux);
    }
    if (id == p.sub_audio.id) p.sub_audio.es = es;
    if (id == 0xe0 or id == 0xe2 or id == 0xfd55) p.main_video = es;
}

pub fn esDeleted(demux: *vlc.demux_t, es: *vlc.es_out_id_t) void {
    const p = playerOf(demux);
    for (p.tracks.items, 0..) |t, i| if (t.es == es) {
        _ = p.tracks.swapRemove(i);
        break;
    };
    if (p.main_video == es) p.main_video = null;
    if (p.sub_video.es == es) p.sub_video = .{};
    if (p.sub_audio.es == es) p.sub_audio = .{};
    for (p.spus.items, 0..) |*t, i| if (t.es == es) {
        t.buf.deinit(gpa);
        _ = p.spus.swapRemove(i);
        break;
    };
}

/// Sub-picture units are reassembled and sent whole, with the EVOB's HD palette, to spudec.zig.
pub fn esFilter(demux: *vlc.demux_t, es: *vlc.es_out_id_t, block: *vlc.block_t) ?*vlc.block_t {
    const p = playerOf(demux);
    // The sub audio is decoded only where the playlist assigns it (§6.2.3: SubAudio of the clip).
    const clip = if (p.span) |sp| sp.clip else null;
    if (p.sub_audio.es == es and (clip == null or clip.?.sub_audio.len == 0)) {
        hddvd_block_release(block);
        return null;
    }
    if (p.sub_audio.es == es) {
        // Into the selected main audio track (the one our mixer is decoding).
        for (p.tracks.items) |t| {
            if ((t.id & 0xff00) != 0xbd00 or !isMainAudio(@intCast(t.id & 0xff))) continue;
            if (!hddvd_es_selected(demux, t.es)) continue;
            forward(demux, t.es, block, present.sub_audio_magic, p.sub_audio.codec);
            return null;
        }
        hddvd_block_release(block);
        return null;
    }
    const t = for (p.spus.items) |*t| {
        if (t.es == es) break t;
    } else return block;

    const data = block.p_buffer[0..block.i_buffer];
    if (block.i_pts > 0) {
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

    const out = vlc.block_Alloc(spudec.palette_size + size) orelse return null;
    const buf = out.*.p_buffer[0 .. spudec.palette_size + size];
    const palette: [16]u32 = if (p.evob) |e| (if (p.vti.attrOf(e)) |a| a.hd_palette else @splat(0)) else @splat(0);
    for (palette, 0..) |c, i| std.mem.writeInt(u32, buf[i * 4 ..][0..4], c, .big);
    @memcpy(buf[spudec.palette_size..], t.buf.items[0..size]);
    out.*.i_pts = t.pts;
    out.*.i_dts = t.pts;
    return out;
}

/// Selects the sub video ES where the current clip assigns a sub video, deselects it elsewhere.
fn updateSubVideo(demux: *vlc.demux_t) void {
    const p = playerOf(demux);
    const es = p.sub_video.es orelse return;
    const want = if (p.span) |sp| sp.clip.sub_video != null else false;
    if (want != hddvd_es_selected(demux, es)) hddvd_es_select(demux, es, want);
}

/// Sends `block` to `to`, prefixed with `magic` and the codec, for our decoder to pick out.
fn forward(demux: *vlc.demux_t, to: *vlc.es_out_id_t, block: *vlc.block_t, comptime magic: []const u8, codec: u32) void {
    const len = block.i_buffer;
    const b = vlc.block_Realloc(block, present.sub_prefix_len, len) orelse return;
    @memcpy(b.*.p_buffer[0..8], magic);
    std.mem.writeInt(u32, b.*.p_buffer[8..12], codec, .native);
    hddvd_es_send(demux, to, b);
}

// ---- tests --------------------------------------------------------------------------------------------------

const testing = std.testing;

test "disc URIs" {
    try testing.expectEqualStrings("HVDVD_TS/A.MAP", discPath("file:///dvddisc/HVDVD_TS/A.MAP").?);
    try testing.expectEqual(null, discPath("http://example.com/a.map"));
}

test "audio stream kinds" {
    try testing.expect(isMainAudio(0xc0) and isMainAudio(0xc7) and isMainAudio(0xb1) and isMainAudio(0x8a));
    try testing.expect(!isMainAudio(0xc8) and isSubAudio(0xc8) and isSubAudio(0xcf) and isSubAudio(0x9c));
    try testing.expect(!isSubAudio(0xc0) and !isSubAudio(0x20));
}

test "extended stream ids" {
    // PES header with PTS and an extension carrying stream_id_extension 0x55 (VC-1).
    const pkt = [_]u8{ 0, 0, 1, 0xfd, 0, 20, 0x81, 0x81, 8, 0x21, 0, 1, 0, 1, 0x01, 0x81, 0x55, 0, 0, 0 };
    try testing.expectEqual(@as(?u8, 0x55), extendedId(&pkt));
    var no_ext = pkt;
    no_ext[7] = 0x80;
    try testing.expectEqual(null, extendedId(&no_ext));
}
