//! The Player API (HD DVD Annex Z.10) and the system parameters behind it (Annex W), shared by every
//! application of an engine (`Model`, in the World).
//!
//! Script calls change the model at once, as their definitions say ("assign PLAYSTATE_PAUSE to the playState
//! property"), and ask the demux to follow with an engine command. The demux tells the engine what it does on
//! its own (title begins, pauses from VLC). Each tick the engine compares the Title Timeline with the last
//! tick's to raise the timeline's system events (Table 8.3.1-1: scheduled, chapter, clip begin, track changes,
//! clip end) and to reselect the current tracks (Vol. 1 §4.3.19.4.2, Algorithm A1).
//!
//! This player has no trick play speeds (the speed arrays are empty), no slow or step playback, no capture of
//! the main video (Main Video layout and capture come with the compositor: Phase 6) and no Standard Content
//! transitions (Phase 7). Layout and mixing values are kept and sent to the demux.
//! No VLC dependency.

const std = @import("std");
const js = @import("js.zig");
const host = @import("host.zig");
const events = @import("events.zig");
const sched = @import("sched.zig");
const xpl = @import("../xpl.zig");
const xpath = @import("../xpath.zig");
const uri_mod = @import("../uri.zig");
const files_mod = @import("files.zig");
const keys = @import("../engine/keys.zig");
const engine = @import("../engine/engine.zig");

const c = js.c;
const Value = js.Value;
const Script = host.Script;
const World = host.World;

pub const PlayState = struct {
    pub const play = 1;
    pub const pause = 2;
    pub const fast_fwd = 3;
    pub const fast_rev = 4;
    pub const slow_fwd = 5;
    pub const slow_rev = 6;
};

pub const Result = struct {
    pub const succeeded = 1;
    pub const argument = 2;
    pub const file_not_found = 3;
    pub const not_enough_space = 4;
    pub const wrong_format = 5;
    pub const network_problem = 6;
    pub const failed = 7;
    pub const finished = 8;
    pub const invalid_call = 9;
};

/// Track selection (Z.10.2): the Player's is the current presentation's, a Bookmark's its own copy.
pub const Tracks = struct {
    cur_video: ?u8 = null,
    cur_audio: ?u8 = null,
    cur_sub: ?u8 = null,
    sel_video: ?u8 = null,
    sel_audio: ?u8 = null,
    sel_sub: ?u8 = null,
    sel_audio_lang: ?[2]u8 = null,
    sel_audio_ext: ?u8 = null,
    sel_sub_lang: ?[2]u8 = null,
    sel_sub_ext: ?u8 = null,
};

pub const Layout = struct {
    x: i32 = 0,
    y: i32 = 0,
    /// numerator/denominator; null: full screen (NaN parameters).
    scale: ?[2]u8 = null,
    crop_x: u32 = 0,
    crop_y: u32 = 0,
    crop_w: u32 = 1920,
    crop_h: u32 = 1080,
    changing: bool = false,
    /// The change in progress: done at this application tick.
    done_at: ?u64 = null,
    target: ?Target = null,

    pub const Target = struct { x: i32, y: i32, scale: ?[2]u8, crop: [4]u32 };
};

/// Annex W parameters and the Player API's state.
pub const Model = struct {
    // Player parameters (Table W-1).
    major: u32 = 1,
    minor: u32 = 0,
    display_mode: u32 = 5,
    performance_level: u32 = 1,
    accessibility: u32 = 0,
    // SPRM-based parameters (Table W-7, Z.10.1.2): country "US", no parental level, 16:9.
    country: u32 = ('U' << 8) | 'S',
    parental_level: u32 = 0,
    display_aspect: u32 = 2,
    menu_language: [2]u8 = "en".*,
    // Presentation parameters (Table W-3).
    play_state: u32 = PlayState.play,
    play_speed: ?u32 = null,
    tracks: Tracks = .{},
    effect_playing: bool = false,
    effect_serial: u64 = 0,
    // Audio parameters (Table W-4): main volumes, sub and effect mix-downs (left/right channel to 8 outputs).
    main_volume: [8]u8 = @splat(255),
    sub_mix: [2][8]u8 = @splat(@splat(0)),
    effect_mix: [2][8]u8 = @splat(@splat(0)),
    // Layout parameters (Table W-5).
    outer: [3]u8 = .{ 16, 128, 128 },
    capturing: bool = false,
    main: Layout = .{},
    sub: Layout = .{ .scale = .{ 16, 16 } },
    sub_alpha: u8 = 0,
    subtitle_visible: bool = true,
    // Secondary Video Player (Z.10.31).
    svp_state: u32 = 3,
    // Bookmark (Z.10.3).
    bm_title: ?u16 = null,
    bm_time: ?u64 = null,
    bm_tracks: ?Tracks = null,
    // GeneralParameters (Z.10.32): shared by all applications, kept across soft resets.
    general: std.StringArrayHashMapUnmanaged([]u8) = .empty,
    // Standard Content registers (Z.10.30).
    gprm: [64]u16 = @splat(0),
    sprm: [32]u16 = @splat(0),
    // Track selectability changed by script (Z.10.15.2), by title, kind and track.
    selectable: std.AutoHashMapUnmanaged(struct { title: u16, kind: u8, track: u8 }, bool) = .empty,
    /// The timeline at the last tick (for its system events), and the current clips.
    last_title: ?u16 = null,
    last_time: ?u64 = null,
    last_chapter: ?u32 = null,
    playing_clips: std.ArrayList(usize) = .empty,

    pub fn deinit(m: *Model, gpa: std.mem.Allocator) void {
        var it = m.general.iterator();
        while (it.next()) |kv| {
            gpa.free(kv.key_ptr.*);
            gpa.free(kv.value_ptr.*);
        }
        m.general.deinit(gpa);
        m.selectable.deinit(gpa);
        m.playing_clips.deinit(gpa);
    }
};

/// Per-context objects with identity (Title, Chapter).
pub const State = struct {
    titles: std.AutoHashMapUnmanaged(u16, Value) = .empty,
    chapters: std.AutoHashMapUnmanaged(u32, Value) = .empty,

    pub fn deinit(st: *State, s: *Script) void {
        var it = st.titles.valueIterator();
        while (it.next()) |v| s.cx.free(v.*);
        st.titles.deinit(s.gpa);
        var ic = st.chapters.valueIterator();
        while (ic.next()) |v| s.cx.free(v.*);
        st.chapters.deinit(s.gpa);
    }
};

fn modelOf(s: *Script) *Model {
    return &s.world.model;
}

fn plOf(s: *Script) ?*const xpl.Playlist {
    return s.world.pl;
}

fn command(s: *Script, cmd: engine.Command) void {
    if (s.world.eng) |e| return e.command(cmd);
    switch (cmd) {
        .effect_play => |p| s.gpa.free(p.data),
        .load_playlist => |u| s.gpa.free(u),
        else => {},
    }
}

fn fps(s: *Script) u64 {
    return s.world.fps;
}

/// The current title (null: none, or the First Play title has no Title object).
fn curTitle(w: *World) ?*const xpl.Title {
    const pl = w.pl orelse return null;
    const i = w.title_index orelse return if (pl.first_play) |*fp| fp else null;
    return if (i < pl.titles.len) &pl.titles[i] else null;
}

fn timecodeValue(cx: *js.Context, frames: u64, rate: u64) js.Error!Value {
    var buf: [16]u8 = undefined;
    return cx.string(events.timecode(&buf, frames, rate));
}

fn nanOr(x: ?u8) f64 {
    return if (x) |v| @floatFromInt(v) else std.math.nan(f64);
}

// ---- the Player object (Z.10.1) --------------------------------------------------------------------------------------

/// The Player object and everything reachable from it: one per context.
pub fn make(s: *Script) js.Error!Value {
    const cx = s.cx;
    const p = try cx.wrapAs(Script, &player_class, s);
    errdefer cx.free(p);
    const children = [_]struct { [:0]const u8, *const js.Class }{
        .{ "Player.bookmark", &bookmark_class },
        .{ "Player.capabilities", &capabilities_class },
        .{ "Player.capabilities.audio", &audio_caps_class },
        .{ "Player.capabilities.video", &video_caps_class },
        .{ "Player.capabilities.network", &network_caps_class },
        .{ "Player.capabilities.font", &font_caps_class },
        .{ "Player.capabilities.playback", &playback_caps_class },
        .{ "Player.playlist", &playlist_class },
        .{ "Player.video", &video_class },
        .{ "Player.video.main", &main_video_class },
        .{ "Player.video.sub", &sub_video_class },
        .{ "Player.audio", &audio_class },
        .{ "Player.audio.main", &main_audio_class },
        .{ "Player.audio.sub", &sub_audio_class },
        .{ "Player.audio.effect", &effect_audio_class },
        .{ "Player.subtitle", &subtitle_class },
        .{ "Player.secondaryVideoPlayer", &svp_class },
        .{ "Player.standardContentPlayer", &scp_class },
        .{ "Player.generalParameters", &general_class },
    };
    for (children) |ch| try s.keep(ch[0], try cx.wrapAs(Script, ch[1], s));
    try s.keep("Player.track", try cx.wrapAs(TrackSel, &track_selection_class, &s.world.player_tracks));
    // Decode and digital interface capabilities, channel objects.
    try s.keep("caps.main", try cx.wrapAs(DecodeCaps, &decode_caps_class, @constCast(&main_decode)));
    try s.keep("caps.sub", try cx.wrapAs(DecodeCaps, &decode_caps_class, @constCast(&sub_decode)));
    try s.keep("caps.spdif", try cx.wrapAs(DigitalCaps, &digital_caps_class, @constCast(&spdif_caps)));
    try s.keep("caps.hdmi", try cx.wrapAs(DigitalCaps, &digital_caps_class, @constCast(&hdmi_caps)));
    for (&channel_sets, 0..) |*cs, i| {
        var buf: [32]u8 = undefined;
        const k = std.fmt.bufPrint(&buf, "out{d}", .{i}) catch unreachable;
        try s.keep(k, try cx.wrapAs(OutChannels, &output_channels_class, cs));
    }
    for (&audio_outputs, 0..) |*ao, i| {
        var buf: [32]u8 = undefined;
        const k = std.fmt.bufPrint(&buf, "ao{d}", .{i}) catch unreachable;
        try s.keep(k, try cx.wrapAs(AudioOut, &audio_output_class, ao));
    }
    for (&channels_objs, 0..) |*co, i| {
        var buf: [32]u8 = undefined;
        const k = std.fmt.bufPrint(&buf, "ch{d}", .{i}) catch unreachable;
        try s.keep(k, try cx.wrapAs(Channels, &channels_class, co));
    }
    return p;
}

fn kept(comptime key: []const u8) fn (*Script) Value {
    return struct {
        fn get(s: *Script) Value {
            return s.cx.dup(s.kept(key));
        }
    }.get;
}

const P = struct {
    fn major(s: *Script) u32 {
        return modelOf(s).major;
    }
    fn minor(s: *Script) u32 {
        return modelOf(s).minor;
    }
    fn performance(s: *Script) u32 {
        return modelOf(s).performance_level;
    }
    fn country(s: *Script) u32 {
        return modelOf(s).country;
    }
    fn aspect(s: *Script) u32 {
        return modelOf(s).display_aspect;
    }
    fn displayMode(s: *Script) u32 {
        return modelOf(s).display_mode;
    }
    fn accessibility(s: *Script) u32 {
        return modelOf(s).accessibility;
    }
    fn parental(s: *Script) u32 {
        return modelOf(s).parental_level;
    }
    fn getMenuLanguage(s: *Script) js.Error!Value {
        return s.cx.string(&modelOf(s).menu_language);
    }
    /// menuLanguage: the Application Blocks' selection follows (Z.10.1.2, §6.2.3.9).
    fn setMenuLanguage(s: *Script, v: []const u8) js.Error!void {
        if (v.len != 2 or !std.ascii.isLower(v[0]) or !std.ascii.isLower(v[1])) return error.Argument;
        modelOf(s).menu_language = v[0..2].*;
        modelOf(s).sprm[0] = (@as(u16, v[0]) << 8) | v[1];
        if (s.world.apps) |a| a.setMenuLanguage(v);
    }
    fn getGroup(s: *Script) f64 {
        const w = s.world.apps orelse return std.math.nan(f64);
        return if (w.app_group) |g| @floatFromInt(g) else std.math.nan(f64);
    }
    fn setGroup(s: *Script, v: u32) void {
        if (s.world.apps) |a| a.app_group = v;
    }
    fn createVideoScale(s: *Script, num: u32, den: u32) js.Error!Value {
        if (num < 1 or num > 16 or den < 1 or den > 16) return error.Argument;
        return VideoScale.make(s, @intCast(num), @intCast(den));
    }
};

const player_class: js.Class = .{
    .name = "Player",
    .members = &.{
        js.prop("majorVersion", P.major, null),
        js.prop("minorVersion", P.minor, null),
        js.prop("performanceLevel", P.performance, null),
        js.prop("countryCode", P.country, null),
        js.prop("displayAspectRatio", P.aspect, null),
        js.prop("currentDisplayMode", P.displayMode, null),
        js.prop("accessibility", P.accessibility, null),
        js.prop("parentalLevel", P.parental, null),
        js.prop("menuLanguage", P.getMenuLanguage, P.setMenuLanguage),
        js.prop("applicationGroup", P.getGroup, P.setGroup),
        js.prop("track", kept("Player.track"), null),
        js.prop("bookmark", kept("Player.bookmark"), null),
        js.prop("capabilities", kept("Player.capabilities"), null),
        js.prop("playlist", kept("Player.playlist"), null),
        js.prop("video", kept("Player.video"), null),
        js.prop("audio", kept("Player.audio"), null),
        js.prop("subtitle", kept("Player.subtitle"), null),
        js.prop("secondaryVideoPlayer", kept("Player.secondaryVideoPlayer"), null),
        js.prop("standardContentPlayer", kept("Player.standardContentPlayer"), null),
        js.prop("generalParameters", kept("Player.generalParameters"), null),
        js.method("createVideoScale", P.createVideoScale),
        js.constant("DISPLAY_ASPECT_RATIO_4_3", 1),
        js.constant("DISPLAY_ASPECT_RATIO_16_9", 2),
        js.constant("DISPLAY_ASPECT_RATIO_NOT_SPECIFIED", 3),
        js.constant("DISPLAY_NONE", 1),
        js.constant("DISPLAY_NORMAL_WIDE", 2),
        js.constant("DISPLAY_PANSCAN", 3),
        js.constant("DISPLAY_LETTERBOX", 4),
        js.constant("DISPLAY_HD", 5),
        js.constant("PARENTAL_NONE", 0),
        js.constant("PARENTAL_1", 1),
        js.constant("PARENTAL_2", 2),
        js.constant("PARENTAL_3", 3),
        js.constant("PARENTAL_4", 4),
        js.constant("PARENTAL_5", 5),
        js.constant("PARENTAL_6", 6),
        js.constant("PARENTAL_7", 7),
        js.constant("PARENTAL_8", 8),
        js.constant("ACCESSIBILITY_CLOSED_CAPTION", 1),
        js.constant("ACCESSIBILITY_SIMPLIFIED_CAPTION", 2),
        js.constant("ACCESSIBILITY_LARGE_FONT", 4),
        js.constant("ACCESSIBILITY_CONTRAST_DISPLAY", 8),
        js.constant("ACCESSIBILITY_DESCRIPTIVE_AUDIO", 16),
        js.constant("ACCESSIBILITY_EXTENDED_INTERACTION_TIMES", 32),
        js.constant("SUCCEEDED", Result.succeeded),
        js.constant("FINISHED", Result.finished),
        js.constant("FAILED", Result.failed),
        js.constant("FILE_NOT_FOUND", Result.file_not_found),
        js.constant("NOT_ENOUGH_SPACE", Result.not_enough_space),
        js.constant("WRONG_FORMAT", Result.wrong_format),
        js.constant("ARGUMENT", Result.argument),
        js.constant("NETWORK_PROBLEM", Result.network_problem),
        js.constant("INVALID_CALL", Result.invalid_call),
    },
};

// ---- TrackSelection (Z.10.2) ----------------------------------------------------------------------------------------

/// A TrackSelection: the Player's (its tracks are the model's) or a Bookmark's (`own`).
pub const TrackSel = struct {
    player: bool,
    own: Tracks = .{},
    /// The Bookmark's title, for its tracks (referenceTitle).
    fn tracksOf(t: *TrackSel, s: *Script) *Tracks {
        return if (t.player) &modelOf(s).tracks else &t.own;
    }

    fn finalize(ptr: *anyopaque, rt: *js.Runtime) void {
        const t: *TrackSel = @ptrCast(@alignCast(ptr));
        if (!t.player) rt.gpa.destroy(t);
    }

    fn refTitle(t: *TrackSel, s: *Script) ?*const xpl.Title {
        if (t.player) return curTitle(s.world);
        const pl = plOf(s) orelse return null;
        const i = modelOf(s).bm_title orelse return null;
        return if (i < pl.titles.len) &pl.titles[i] else null;
    }

    fn get(comptime name: []const u8) fn (*TrackSel, *js.Context) f64 {
        return struct {
            fn f(t: *TrackSel, cx: *js.Context) f64 {
                return nanOr(@field(t.tracksOf(Script.of(cx)).*, name));
            }
        }.f;
    }

    fn lang(comptime name: []const u8) fn (*TrackSel, *js.Context) js.Error!Value {
        return struct {
            fn f(t: *TrackSel, cx: *js.Context) js.Error!Value {
                const l = @field(t.tracksOf(Script.of(cx)).*, name) orelse return js.undefined;
                return cx.string(&l);
            }
        }.f;
    }

    fn selectVideoTrackNumber(t: *TrackSel, cx: *js.Context, track: u32) js.Error!void {
        const s = Script.of(cx);
        const title = t.refTitle(s) orelse return error.Argument;
        if (track < 1 or track > 9 or !hasTrack(title, .video, @intCast(track))) return error.Argument;
        const tr = t.tracksOf(s);
        tr.sel_video = @intCast(track);
        if (t.player) reselect(s.world, true) else tr.cur_video = tr.sel_video;
    }

    fn selectAudioTrackNumber(t: *TrackSel, cx: *js.Context, track: u32) js.Error!void {
        return t.selectNumber(cx, .audio, track, 8);
    }

    fn selectSubtitleTrackNumber(t: *TrackSel, cx: *js.Context, track: u32) js.Error!void {
        return t.selectNumber(cx, .subtitle, track, 32);
    }

    fn selectNumber(t: *TrackSel, cx: *js.Context, kind: Kind, track: u32, max: u32) js.Error!void {
        const s = Script.of(cx);
        const title = t.refTitle(s) orelse return error.Argument;
        if (track < 1 or track > max or !hasTrack(title, kind, @intCast(track))) return error.Argument;
        const tr = t.tracksOf(s);
        const nav = navOf(title, kind, @intCast(track));
        const lc = if (nav) |n| langCode(n.langcode) else null;
        const ext = if (nav) |n| langExt(n.langcode) else null;
        switch (kind) {
            .audio => {
                tr.sel_audio = @intCast(track);
                if (lc) |l| tr.sel_audio_lang = l;
                if (ext) |e| tr.sel_audio_ext = e;
            },
            .subtitle => {
                tr.sel_sub = @intCast(track);
                if (lc) |l| tr.sel_sub_lang = l;
                if (ext) |e| tr.sel_sub_ext = e;
            },
            .video => unreachable,
        }
        if (t.player) reselect(s.world, true) else {
            tr.cur_audio = tr.sel_audio;
            tr.cur_sub = tr.sel_sub;
        }
    }

    fn selectAudioLanguage(t: *TrackSel, cx: *js.Context, code: []const u8, ext: u32) js.Error!void {
        return t.selectLanguage(cx, .audio, code, ext);
    }

    fn selectSubtitleLanguage(t: *TrackSel, cx: *js.Context, code: []const u8, ext: u32) js.Error!void {
        return t.selectLanguage(cx, .subtitle, code, ext);
    }

    fn selectLanguage(t: *TrackSel, cx: *js.Context, kind: Kind, code: []const u8, ext: u32) js.Error!void {
        const s = Script.of(cx);
        if (code.len != 2 or !std.ascii.isAlphabetic(code[0]) or !std.ascii.isAlphabetic(code[1]) or ext > 0xff) return error.Argument;
        const tr = t.tracksOf(s);
        const l: [2]u8 = .{ std.ascii.toLower(code[0]), std.ascii.toLower(code[1]) };
        switch (kind) {
            .audio => {
                tr.sel_audio_lang = l;
                tr.sel_audio_ext = @intCast(ext);
                tr.sel_audio = null;
            },
            .subtitle => {
                tr.sel_sub_lang = l;
                tr.sel_sub_ext = @intCast(ext);
                tr.sel_sub = null;
            },
            .video => unreachable,
        }
        if (t.player) {
            reselect(s.world, true);
        } else if (t.refTitle(s)) |title| {
            const cur = selectA1(s.world, title, kind, tr, null);
            if (kind == .audio) tr.cur_audio = cur else tr.cur_sub = cur;
        }
        // The current track becomes the selected one (step 7).
        switch (kind) {
            .audio => tr.sel_audio = tr.cur_audio,
            .subtitle => tr.sel_sub = tr.cur_sub,
            .video => {},
        }
    }

    pub const js_class = track_selection_class;
};

const track_selection_class: js.Class = .{
    .name = "TrackSelection",
    .finalize = TrackSel.finalize,
    .members = &.{
        js.prop("currentVideoTrackNumber", TrackSel.get("cur_video"), null),
        js.prop("selectedVideoTrackNumber", TrackSel.get("sel_video"), null),
        js.prop("currentAudioTrackNumber", TrackSel.get("cur_audio"), null),
        js.prop("selectedAudioTrackNumber", TrackSel.get("sel_audio"), null),
        js.prop("selectedAudioLanguageCode", TrackSel.lang("sel_audio_lang"), null),
        js.prop("selectedAudioLanguageCodeExtension", TrackSel.get("sel_audio_ext"), null),
        js.prop("currentSubtitleTrackNumber", TrackSel.get("cur_sub"), null),
        js.prop("selectedSubtitleTrackNumber", TrackSel.get("sel_sub"), null),
        js.prop("selectedSubtitleLanguageCode", TrackSel.lang("sel_sub_lang"), null),
        js.prop("selectedSubtitleLanguageCodeExtension", TrackSel.get("sel_sub_ext"), null),
        js.method("selectVideoTrackNumber", TrackSel.selectVideoTrackNumber),
        js.method("selectAudioTrackNumber", TrackSel.selectAudioTrackNumber),
        js.method("selectAudioLanguage", TrackSel.selectAudioLanguage),
        js.method("selectSubtitleTrackNumber", TrackSel.selectSubtitleTrackNumber),
        js.method("selectSubtitleLanguage", TrackSel.selectSubtitleLanguage),
    },
};

pub const Kind = enum(u8) { video = 0, audio = 1, subtitle = 2 };

fn navList(title: *const xpl.Title, kind: Kind) []const xpl.NavTrack {
    return switch (kind) {
        .video => title.video_nav,
        .audio => title.audio_nav,
        .subtitle => title.subtitle_nav,
    };
}

fn navOf(title: *const xpl.Title, kind: Kind, track: u8) ?xpl.NavTrack {
    for (navList(title, kind)) |n| if (n.track == track) return n;
    return null;
}

/// A track number the title assigns anywhere (Track Navigation or a clip).
fn hasTrack(title: *const xpl.Title, kind: Kind, track: u8) bool {
    if (navOf(title, kind, track) != null) return true;
    for (title.clips) |cl| {
        if (cl.kind != .primary) continue;
        switch (kind) {
            .video => for (cl.video) |v| if (v.track == track) return true,
            .audio => for (cl.audio) |v| if (v.track == track) return true,
            .subtitle => for (cl.subtitle) |v| if (v.track == track) return true,
        }
    }
    return false;
}

/// "ja:01" → "ja"; "*" or nothing: null.
fn langCode(langcode: []const u8) ?[2]u8 {
    if (langcode.len < 2 or langcode[0] == '*') return null;
    return .{ std.ascii.toLower(langcode[0]), std.ascii.toLower(langcode[1]) };
}

/// "ja:01" → 1.
fn langExt(langcode: []const u8) ?u8 {
    const colon = std.mem.indexOfScalar(u8, langcode, ':') orelse return null;
    return std.fmt.parseInt(u8, langcode[colon + 1 ..], 16) catch null;
}

fn isSelectable(w: *World, title: *const xpl.Title, kind: Kind, nav: xpl.NavTrack) bool {
    const ti: u16 = if (w.title_index) |i| i else 0xffff;
    _ = title;
    return w.model.selectable.get(.{ .title = ti, .kind = @backingInt(kind), .track = nav.track }) orelse nav.selectable;
}

/// Algorithm A1 (Vol. 1 §4.3.19.4.2): the current audio or subtitle track among the clip's tracks.
fn selectA1(w: *World, title: *const xpl.Title, kind: Kind, tr: *const Tracks, clip: ?*const xpl.Clip) ?u8 {
    var avail: [64]u8 = undefined;
    var n: usize = 0;
    if (clip) |cl| {
        switch (kind) {
            .audio => for (cl.audio) |a| if (n < avail.len) {
                avail[n] = a.track;
                n += 1;
            },
            .subtitle => for (cl.subtitle) |a| if (n < avail.len) {
                avail[n] = a.track;
                n += 1;
            },
            .video => for (cl.video) |a| if (n < avail.len) {
                avail[n] = a.track;
                n += 1;
            },
        }
    } else for (navList(title, kind)) |nv| if (n < avail.len) {
        avail[n] = nv.track;
        n += 1;
    };
    const tracks = avail[0..n];
    std.mem.sort(u8, tracks, {}, std.sort.asc(u8));
    const enabled = struct {
        fn f(ww: *World, t: *const xpl.Title, k: Kind, track: u8) bool {
            const nav = navOf(t, k, track) orelse return true;
            return isSelectable(ww, t, k, nav);
        }
    }.f;
    if (kind == .subtitle) for (tracks) |t| if (navOf(title, kind, t)) |nv| if (nv.forced) return t;
    const sel = if (kind == .audio) tr.sel_audio else tr.sel_sub;
    if (sel) |s| for (tracks) |t| if (t == s) return t;
    const want_lang = if (kind == .audio) tr.sel_audio_lang else tr.sel_sub_lang;
    const want_ext = if (kind == .audio) tr.sel_audio_ext else tr.sel_sub_ext;
    const Match = enum { both, lang, ext };
    for ([_]Match{ .both, .lang, .ext }) |m| {
        for (tracks) |t| {
            if (!enabled(w, title, kind, t)) continue;
            const nav = navOf(title, kind, t) orelse continue;
            const l = langCode(nav.langcode);
            const e = langExt(nav.langcode);
            const lang_ok = want_lang != null and l != null and std.mem.eql(u8, &want_lang.?, &l.?);
            const ext_ok = want_ext != null and e != null and want_ext.? == e.?;
            const ok = switch (m) {
                .both => lang_ok and ext_ok,
                .lang => lang_ok,
                .ext => ext_ok,
            };
            if (ok) return t;
        }
    }
    for (tracks) |t| if (enabled(w, title, kind, t)) return t;
    return null;
}

/// The current tracks again (§4.3.19.4.2, 4.3.19.4.4) for the clip at the title time; changes raise track
/// events (unless `quiet`) and tell the demux.
pub fn reselect(w: *World, from_api: bool) void {
    _ = from_api;
    const title = curTitle(w) orelse return;
    const clip = title.clipAt(.primary, w.title_time);
    const tr = &w.model.tracks;
    const old = tr.*;
    const v_sel = tr.sel_video;
    tr.cur_video = blk: {
        const cl = clip orelse break :blk null;
        if (v_sel) |v| for (cl.video) |x| if (x.track == v) break :blk v;
        var lo: ?u8 = null;
        for (cl.video) |x| lo = if (lo) |l| @min(l, x.track) else x.track;
        break :blk lo;
    };
    tr.cur_audio = selectA1(w, title, .audio, tr, clip);
    tr.cur_sub = selectA1(w, title, .subtitle, tr, clip);
    if (old.cur_video != tr.cur_video) trackEvent(w, .video_track, "video_track", old.cur_video, tr.cur_video);
    if (old.cur_audio != tr.cur_audio) trackEvent(w, .audio_track, "audio_track", old.cur_audio, tr.cur_audio);
    if (old.cur_sub != tr.cur_sub) trackEvent(w, .subtitle_track, "subtitle_track", old.cur_sub, tr.cur_sub);
    if (old.cur_video != tr.cur_video or old.cur_audio != tr.cur_audio or old.cur_sub != tr.cur_sub)
        if (w.eng) |e| e.command(.{ .tracks = .{ .video = tr.cur_video, .audio = tr.cur_audio, .subtitle = tr.cur_sub } });
}

fn trackEvent(w: *World, kind: events.Kind, type_: []const u8, old: ?u8, new: ?u8) void {
    const a = w.apps orelse return;
    a.sendSystem(.{ .kind = kind, .type = type_, .old = if (old) |o| o else null, .new = if (new) |n| n else null }, null);
}

// ---- Bookmark (Z.10.3) --------------------------------------------------------------------------------------------

const Bm = struct {
    fn getElapsed(s: *Script) js.Error!Value {
        const t = modelOf(s).bm_time orelse return js.undefined;
        return timecodeValue(s.cx, t, fps(s));
    }
    fn setElapsed(s: *Script, v: []const u8) js.Error!void {
        const f = host.parseTimecode(v, fps(s)) orelse return error.Argument;
        const m = modelOf(s);
        if (m.bm_title) |ti| if (plOf(s)) |pl| if (ti < pl.titles.len and f >= pl.titles[ti].duration) return error.Argument;
        m.bm_time = f;
    }
    fn getTitle(s: *Script) js.Error!Value {
        const t = modelOf(s).bm_title orelse return js.null;
        return titleObject(s, t);
    }
    fn setTitle(s: *Script, v: Value) js.Error!void {
        const m = modelOf(s);
        if (c.JS_IsNull(v)) {
            m.bm_title = null;
            return;
        }
        const t = s.cx.unwrap(TitleRef, v) orelse return error.Argument;
        m.bm_title = t.index;
        if (plOf(s)) |pl| if (m.bm_time) |bt| if (bt >= pl.titles[t.index].duration) {
            m.bm_time = 0;
        };
    }
    fn getTrack(s: *Script) js.Error!Value {
        const tr = modelOf(s).bm_tracks orelse return js.null;
        const ts = try s.gpa.create(TrackSel);
        ts.* = .{ .player = false, .own = tr };
        return s.cx.wrapAs(TrackSel, &track_selection_class, ts) catch |e| {
            s.gpa.destroy(ts);
            return e;
        };
    }
    fn setTrack(s: *Script, v: Value) js.Error!void {
        if (c.JS_IsNull(v)) {
            modelOf(s).bm_tracks = null;
            return;
        }
        const t = s.cx.unwrap(TrackSel, v) orelse return error.Argument;
        modelOf(s).bm_tracks = t.tracksOf(s).*;
    }
    fn save(s: *Script) void {
        const m = modelOf(s);
        const ti = s.world.title_index orelse return;
        m.bm_tracks = m.tracks;
        m.bm_title = ti;
        m.bm_time = s.world.title_time;
    }
    fn jump(s: *Script) js.Error!void {
        const m = modelOf(s);
        if (m.capturing or m.main.changing or m.sub.changing) return error.InvalidCall;
        const ti = m.bm_title orelse return error.InvalidCall;
        const t = m.bm_time orelse return error.InvalidCall;
        const tr = m.bm_tracks orelse return error.InvalidCall;
        const keep_cur = m.tracks;
        m.tracks = tr;
        m.tracks.cur_audio = keep_cur.cur_audio;
        m.tracks.cur_sub = keep_cur.cur_sub;
        m.tracks.cur_video = keep_cur.cur_video;
        try jumpTitle(s, ti, t, false);
    }
};

const bookmark_class: js.Class = .{
    .name = "Bookmark",
    .members = &.{
        js.prop("elapsedTime", Bm.getElapsed, Bm.setElapsed),
        js.prop("title", Bm.getTitle, Bm.setTitle),
        js.prop("track", Bm.getTrack, Bm.setTrack),
        js.method("save", Bm.save),
        js.method("jump", Bm.jump),
    },
};

// ---- Capabilities (Z.10.4–Z.10.11) ----------------------------------------------------------------------------------

pub const DecodeCaps = struct { lpcm: u32, ddplus: u32, mpeg: u32, dts_hd: u32, mlp: u32, aac_v2: u32, mp3: u32, wma_pro: u32 };
/// FFmpeg decodes all of them; the mixer outputs what VLC's output takes (5.1 assumed).
const main_decode: DecodeCaps = .{ .lpcm = 2, .ddplus = 2, .mpeg = 2, .dts_hd = 2, .mlp = 2, .aac_v2 = 0, .mp3 = 0, .wma_pro = 0 };
const sub_decode: DecodeCaps = .{ .lpcm = 0, .ddplus = 1, .mpeg = 0, .dts_hd = 1, .mlp = 0, .aac_v2 = 1, .mp3 = 1, .wma_pro = 0 };

pub const DigitalCaps = struct { encoded: bool, main: u32, channel: u32, connected: bool };
const spdif_caps: DigitalCaps = .{ .encoded = false, .main = 0, .channel = 1, .connected = true };
const hdmi_caps: DigitalCaps = .{ .encoded = false, .main = 0, .channel = 2, .connected = false };

fn fieldOf(comptime T: type, comptime name: []const u8) fn (*T) @FieldType(T, name) {
    return struct {
        fn f(x: *T) @FieldType(T, name) {
            return @field(x.*, name);
        }
    }.f;
}

const channel_constants = [_]js.Member{
    js.constant("CHANNEL_2", 1),
    js.constant("CHANNEL_5_1", 2),
    js.constant("CHANNEL_7_1", 3),
};

const decode_caps_class: js.Class = .{
    .name = "DecodeCapabilities",
    .members = &([_]js.Member{
        js.prop("lpcm", fieldOf(DecodeCaps, "lpcm"), null),
        js.prop("ddplus", fieldOf(DecodeCaps, "ddplus"), null),
        js.prop("mpeg", fieldOf(DecodeCaps, "mpeg"), null),
        js.prop("dts_hd", fieldOf(DecodeCaps, "dts_hd"), null),
        js.prop("mlp", fieldOf(DecodeCaps, "mlp"), null),
        js.prop("aac_v2", fieldOf(DecodeCaps, "aac_v2"), null),
        js.prop("mp3", fieldOf(DecodeCaps, "mp3"), null),
        js.prop("wma_pro", fieldOf(DecodeCaps, "wma_pro"), null),
        js.constant("NOT_SUPPORT", 0),
    } ++ channel_constants),
};

const digital_caps_class: js.Class = .{
    .name = "DigitalInterfaceCapabilities",
    .members = &([_]js.Member{
        js.prop("encoded", fieldOf(DigitalCaps, "encoded"), null),
        js.prop("main", fieldOf(DigitalCaps, "main"), null),
        js.prop("channel", fieldOf(DigitalCaps, "channel"), null),
        js.prop("connected", fieldOf(DigitalCaps, "connected"), null),
        js.constant("CODEC_DD", 1),
        js.constant("CODEC_DTS", 2),
    } ++ channel_constants),
};

const Caps = struct {
    fn analog(_: *Script) u32 {
        return 2;
    }
    fn hdmi(s: *Script) Value {
        _ = s;
        return js.null; // no HDMI output of its own
    }
    fn subVideo(_: *Script) u32 {
        return 2;
    }
    fn connected(s: *Script) bool {
        return s.world.network_allowed;
    }
    fn throughput(s: *Script) u32 {
        return s.world.network_kbps;
    }
    fn openType(_: *Script) u32 {
        return 1;
    }
    fn no(_: *Script) bool {
        return false;
    }
};

const capabilities_class: js.Class = .{
    .name = "Capabilities",
    .members = &.{
        js.prop("audio", kept("Player.capabilities.audio"), null),
        js.prop("video", kept("Player.capabilities.video"), null),
        js.prop("network", kept("Player.capabilities.network"), null),
        js.prop("font", kept("Player.capabilities.font"), null),
        js.prop("playback", kept("Player.capabilities.playback"), null),
    },
};

const audio_caps_class: js.Class = .{
    .name = "AudioCapabilities",
    .members = &([_]js.Member{
        js.prop("main", kept("caps.main"), null),
        js.prop("sub", kept("caps.sub"), null),
        js.prop("analog", Caps.analog, null),
        js.prop("spdif", kept("caps.spdif"), null),
        js.prop("hdmi", Caps.hdmi, null),
    } ++ channel_constants),
};

const video_caps_class: js.Class = .{ .name = "VideoCapabilities", .members = &.{ js.prop("sub", Caps.subVideo, null), js.constant("SD", 1), js.constant("HD", 2) } };
const network_caps_class: js.Class = .{ .name = "NetworkCapabilities", .members = &.{ js.prop("connected", Caps.connected, null), js.prop("throughput", Caps.throughput, null) } };
const font_caps_class: js.Class = .{ .name = "FontCapabilities", .members = &.{ js.prop("openType", Caps.openType, null), js.constant("CLASS_1", 1), js.constant("CLASS_2", 2) } };
const playback_caps_class: js.Class = .{
    .name = "PlaybackCapabilities",
    .members = &.{ js.prop("slowForward", Caps.no, null), js.prop("slowReverse", Caps.no, null), js.prop("stepForward", Caps.no, null), js.prop("stepReverse", Caps.no, null) },
};

// ---- Playlist (Z.10.12), Title (Z.10.13), Chapter (Z.10.14) ---------------------------------------------------------

fn titleObject(s: *Script, index: u16) js.Error!Value {
    const st = &s.apis.player;
    if (st.titles.get(index)) |v| return s.cx.dup(v);
    const t = try s.gpa.create(TitleRef);
    t.* = .{ .index = index };
    const v = s.cx.wrapAs(TitleRef, &title_class, t) catch |e| {
        s.gpa.destroy(t);
        return e;
    };
    try st.titles.put(s.gpa, index, s.cx.dup(v));
    return v;
}

fn chapterObject(s: *Script, title: u16, index: u16) js.Error!Value {
    const st = &s.apis.player;
    const key = (@as(u32, title) << 16) | index;
    if (st.chapters.get(key)) |v| return s.cx.dup(v);
    const ch = try s.gpa.create(ChapterRef);
    ch.* = .{ .title = title, .index = index };
    const v = s.cx.wrapAs(ChapterRef, &chapter_class, ch) catch |e| {
        s.gpa.destroy(ch);
        return e;
    };
    try st.chapters.put(s.gpa, key, s.cx.dup(v));
    return v;
}

/// Title.jump's checks and effect (Z.10.13.3).
fn jumpTitle(s: *Script, index: u16, time: u64, bookmark: bool) js.Error!void {
    const m = modelOf(s);
    if (m.capturing or m.main.changing) return error.InvalidCall;
    if (m.sub.changing) return error.InvalidCall;
    const pl = plOf(s) orelse return error.Argument;
    if (index >= pl.titles.len or time >= pl.titles[index].duration) return error.Argument;
    if (bookmark) Bm.save(s);
    const same = s.world.title_index != null and s.world.title_index.? == index;
    if (!same) {
        // Another title plays (step 10): from a pause, VLC resumes too. The demux, which carries out the jump,
        // is not called while VLC is paused.
        if (m.play_state == PlayState.pause) command(s, .{ .pause = false });
        m.play_state = PlayState.play;
        m.play_speed = null;
    }
    command(s, .{ .jump_title = .{ .title = index, .time = time } });
}

const PL = struct {
    fn location(s: *Script) js.Error!Value {
        return s.cx.string(s.world.playlist_uri);
    }
    fn titles(s: *Script) js.Error!Value {
        const o = try s.cx.object();
        errdefer s.cx.free(o);
        const pl = plOf(s) orelse return o;
        for (pl.titles, 0..) |t, i| {
            if (t.id.len == 0) continue;
            var buf: [256]u8 = undefined;
            const k = std.fmt.bufPrintSentinel(&buf, "{s}", .{t.id}, 0) catch continue;
            try s.cx.set(o, k, try titleObject(s, @intCast(i)));
        }
        _ = c.JS_FreezeObject(s.cx.ctx, o);
        return o;
    }
    fn currentTitle(s: *Script) js.Error!Value {
        const i = s.world.title_index orelse return js.null;
        return titleObject(s, i);
    }
    fn currentChapter(s: *Script) js.Error!Value {
        const i = s.world.title_index orelse return js.null;
        const t = curTitle(s.world) orelse return js.null;
        const n = t.chapterAt(s.world.title_time);
        if (n == 0) return js.null;
        return chapterObject(s, i, @intCast(n - 1));
    }
    fn playState(s: *Script) u32 {
        return modelOf(s).play_state;
    }
    fn playSpeed(s: *Script) f64 {
        return if (modelOf(s).play_speed) |x| @floatFromInt(x) else std.math.nan(f64);
    }
    fn speeds(s: *Script) js.Error!Value {
        return s.cx.array();
    }
    fn load(s: *Script, u: []const u8) js.Error!void {
        if (!uri_mod.valid(u) or uri_mod.locate(u) == null) return error.Argument;
        const f = s.world.files orelse return error.FileNotFound;
        if (!f.exists(u)) return error.FileNotFound;
        command(s, .{ .load_playlist = s.gpa.dupe(u8, u) catch return error.OutOfMemory });
    }
    fn play(s: *Script) js.Error!void {
        const m = modelOf(s);
        if (m.capturing) return error.InvalidCall;
        m.play_state = PlayState.play;
        m.play_speed = null;
        command(s, .{ .pause = false });
    }
    fn pause(s: *Script) js.Error!void {
        const m = modelOf(s);
        if (m.main.changing or m.sub.changing) return error.InvalidCall;
        m.play_state = PlayState.pause;
        m.play_speed = null;
        command(s, .{ .pause = true });
    }
    fn stop(s: *Script) void {
        command(s, .stop);
    }
    /// No fast speeds (the arrays are empty): any index is outside them.
    fn fast(s: *Script, speed: u32) js.Error!void {
        _ = speed;
        const m = modelOf(s);
        if (m.capturing or m.main.changing or m.sub.changing) return error.InvalidCall;
        return error.Argument;
    }
    fn slow(_: *Script, _: u32) js.Error!void {
        return error.NotSupported;
    }
    fn step(_: *Script) js.Error!void {
        return error.NotSupported;
    }
};

const playlist_class: js.Class = .{
    .name = "Playlist",
    .members = &.{
        js.prop("location", PL.location, null),
        js.prop("titles", PL.titles, null),
        js.prop("currentTitle", PL.currentTitle, null),
        js.prop("currentChapter", PL.currentChapter, null),
        js.prop("playState", PL.playState, null),
        js.prop("playSpeed", PL.playSpeed, null),
        js.prop("fastForwardSpeed", PL.speeds, null),
        js.prop("fastReverseSpeed", PL.speeds, null),
        js.prop("slowForwardSpeed", PL.speeds, null),
        js.prop("slowReverseSpeed", PL.speeds, null),
        js.method("load", PL.load),
        js.method("play", PL.play),
        js.method("pause", PL.pause),
        js.method("stop", PL.stop),
        js.method("fastForward", PL.fast),
        js.method("fastReverse", PL.fast),
        js.method("slowForward", PL.slow),
        js.method("slowReverse", PL.slow),
        js.method("stepForward", PL.step),
        js.method("stepBackward", PL.step),
        js.constant("PLAYSTATE_PLAY", PlayState.play),
        js.constant("PLAYSTATE_PAUSE", PlayState.pause),
        js.constant("PLAYSTATE_FAST_FWD", PlayState.fast_fwd),
        js.constant("PLAYSTATE_FAST_REV", PlayState.fast_rev),
        js.constant("PLAYSTATE_SLOW_FWD", PlayState.slow_fwd),
        js.constant("PLAYSTATE_SLOW_REV", PlayState.slow_rev),
    },
};

pub const TitleRef = struct {
    index: u16,

    fn title(t: *TitleRef, cx: *js.Context) js.Error!*const xpl.Title {
        const pl = plOf(Script.of(cx)) orelse return error.InvalidCall;
        if (t.index >= pl.titles.len) return error.InvalidCall;
        return &pl.titles[t.index];
    }

    fn finalize(ptr: *anyopaque, rt: *js.Runtime) void {
        rt.gpa.destroy(@as(*TitleRef, @ptrCast(@alignCast(ptr))));
    }

    fn playing(t: *TitleRef, cx: *js.Context) bool {
        const w = Script.of(cx).world;
        return w.title_index != null and w.title_index.? == t.index;
    }

    fn elapsedTime(t: *TitleRef, cx: *js.Context) js.Error!Value {
        if (!t.playing(cx)) return js.undefined;
        const s = Script.of(cx);
        return timecodeValue(cx, s.world.title_time, fps(s));
    }

    fn chapters(t: *TitleRef, cx: *js.Context) js.Error!Value {
        const s = Script.of(cx);
        const ti = try t.title(cx);
        const arr = try cx.array();
        errdefer cx.free(arr);
        for (ti.chapters, 0..) |_, i| try cx.setIndex(arr, @intCast(i), try chapterObject(s, t.index, @intCast(i)));
        return arr;
    }

    fn tracks(t: *TitleRef, cx: *js.Context, kind: Kind) js.Error!Value {
        const s = Script.of(cx);
        const ti = try t.title(cx);
        const arr = try cx.array();
        errdefer cx.free(arr);
        for (navList(ti, kind), 0..) |n, i| {
            const tr = try s.gpa.create(TrackRef);
            tr.* = .{ .title = t.index, .kind = kind, .track = n.track };
            const v = cx.wrapAs(TrackRef, switch (kind) {
                .video => &video_track_class,
                .audio => &audio_track_class,
                .subtitle => &subtitle_track_class,
            }, tr) catch |e| {
                s.gpa.destroy(tr);
                return e;
            };
            try cx.setIndex(arr, @intCast(i), v);
        }
        return arr;
    }

    fn videoTracks(t: *TitleRef, cx: *js.Context) js.Error!Value {
        return t.tracks(cx, .video);
    }
    fn audioTracks(t: *TitleRef, cx: *js.Context) js.Error!Value {
        return t.tracks(cx, .audio);
    }
    fn subtitleTracks(t: *TitleRef, cx: *js.Context) js.Error!Value {
        return t.tracks(cx, .subtitle);
    }

    /// The Title element's attributes as strings (Z.10.13.2).
    fn attributes(t: *TitleRef, cx: *js.Context) js.Error!Value {
        const s = Script.of(cx);
        const ti = try t.title(cx);
        const o = try cx.object();
        errdefer cx.free(o);
        var buf: [32]u8 = undefined;
        if (ti.id.len > 0) try cx.set(o, "id", try cx.string(ti.id));
        try cx.set(o, "titleNumber", try cx.string(std.fmt.bufPrint(&buf, "{d}", .{ti.number}) catch ""));
        try cx.set(o, "type", try cx.string(switch (ti.type) {
            .advanced => "Advanced",
            .original => "Original",
            .user_defined => "User",
        }));
        try cx.set(o, "selectable", try cx.string(if (ti.selectable) "true" else "false"));
        try cx.set(o, "titleDuration", try cx.string(events.timecode(&buf, ti.duration, fps(s))));
        if (ti.parental_level.len > 0) try cx.set(o, "parentalLevel", try cx.string(ti.parental_level));
        try cx.set(o, "tickBaseDivisor", try cx.string(std.fmt.bufPrint(&buf, "{d}", .{ti.tick_divisor}) catch ""));
        if (ti.on_end.len > 0) try cx.set(o, "onEnd", try cx.string(ti.on_end));
        if (ti.display_name.len > 0) try cx.set(o, "displayName", try cx.string(ti.display_name));
        if (ti.description.len > 0) try cx.set(o, "description", try cx.string(ti.description));
        _ = c.JS_FreezeObject(cx.ctx, o);
        return o;
    }

    fn jump(t: *TitleRef, cx: *js.Context, time: []const u8, bookmark: bool) js.Error!void {
        const s = Script.of(cx);
        const f = host.parseTimecode(time, fps(s)) orelse return error.Argument;
        try jumpTitle(s, t.index, f, bookmark);
    }

    pub const js_class = title_class;
};

const title_class: js.Class = .{
    .name = "Title",
    .finalize = TitleRef.finalize,
    .members = &.{
        js.prop("elapsedTime", TitleRef.elapsedTime, null),
        js.prop("chapters", TitleRef.chapters, null),
        js.prop("videoTracks", TitleRef.videoTracks, null),
        js.prop("audioTracks", TitleRef.audioTracks, null),
        js.prop("subtitleTracks", TitleRef.subtitleTracks, null),
        js.prop("attributes", TitleRef.attributes, null),
        js.method("jump", TitleRef.jump),
    },
};

pub const ChapterRef = struct {
    title: u16,
    index: u16,

    fn finalize(ptr: *anyopaque, rt: *js.Runtime) void {
        rt.gpa.destroy(@as(*ChapterRef, @ptrCast(@alignCast(ptr))));
    }

    fn get(ch: *ChapterRef, cx: *js.Context) js.Error!struct { *const xpl.Title, xpl.Chapter } {
        const pl = plOf(Script.of(cx)) orelse return error.InvalidCall;
        if (ch.title >= pl.titles.len) return error.InvalidCall;
        const t = &pl.titles[ch.title];
        if (ch.index >= t.chapters.len) return error.InvalidCall;
        return .{ t, t.chapters[ch.index] };
    }

    /// The chapter's index in its title, from 0 (Annex Z only says "the number of the chapter"). Discs depend on
    /// it: a scene menu marks `currentChapter.number + 1` as current, and its next-chapter command
    /// jumps to `chapters[number + 1]`.
    fn number(ch: *ChapterRef) u32 {
        return ch.index;
    }

    fn elapsedTime(ch: *ChapterRef, cx: *js.Context) js.Error!Value {
        const s = Script.of(cx);
        const t, const chap = try ch.get(cx);
        if (s.world.title_index == null or s.world.title_index.? != ch.title) return js.undefined;
        if (t.chapterAt(s.world.title_time) != ch.index + 1) return js.undefined;
        return timecodeValue(cx, s.world.title_time - chap.begin, fps(s));
    }

    fn attributes(ch: *ChapterRef, cx: *js.Context) js.Error!Value {
        const s = Script.of(cx);
        _, const chap = try ch.get(cx);
        const o = try cx.object();
        errdefer cx.free(o);
        var buf: [16]u8 = undefined;
        try cx.set(o, "titleTimeBegin", try cx.string(events.timecode(&buf, chap.begin, fps(s))));
        if (chap.name.len > 0) try cx.set(o, "displayName", try cx.string(chap.name));
        _ = c.JS_FreezeObject(cx.ctx, o);
        return o;
    }

    /// jump(time, bookmark): `time` within the chapter.
    fn jump(ch: *ChapterRef, cx: *js.Context, time: []const u8, bookmark: bool) js.Error!void {
        const s = Script.of(cx);
        const t, const chap = try ch.get(cx);
        const f = host.parseTimecode(time, fps(s)) orelse return error.Argument;
        const at = chap.begin + f;
        const end = if (ch.index + 1 < t.chapters.len) t.chapters[ch.index + 1].begin else t.duration;
        if (at >= end) return error.Argument;
        try jumpTitle(s, ch.title, at, bookmark);
    }

    /// top(): the chapter's start, or the previous chapter's when within its first second (the player's
    /// choice, Z.10.14.3).
    fn top(ch: *ChapterRef, cx: *js.Context) js.Error!void {
        const s = Script.of(cx);
        const t, const chap = try ch.get(cx);
        var index = ch.index;
        if (s.world.title_index != null and s.world.title_index.? == ch.title and s.world.title_time -| chap.begin < fps(s) and index > 0) index -= 1;
        try jumpTitle(s, ch.title, t.chapters[index].begin, false);
    }

    pub const js_class = chapter_class;
};

const chapter_class: js.Class = .{
    .name = "Chapter",
    .finalize = ChapterRef.finalize,
    .members = &.{
        js.prop("number", ChapterRef.number, null),
        js.prop("elapsedTime", ChapterRef.elapsedTime, null),
        js.prop("attributes", ChapterRef.attributes, null),
        js.method("jump", ChapterRef.jump),
        js.method("top", ChapterRef.top),
    },
};

// ---- tracks (Z.10.15–Z.10.17) ---------------------------------------------------------------------------------------

pub const TrackRef = struct {
    title: u16,
    kind: Kind,
    track: u8,

    fn finalize(ptr: *anyopaque, rt: *js.Runtime) void {
        rt.gpa.destroy(@as(*TrackRef, @ptrCast(@alignCast(ptr))));
    }

    fn nav(t: *TrackRef, cx: *js.Context) js.Error!struct { *const xpl.Title, xpl.NavTrack } {
        const pl = plOf(Script.of(cx)) orelse return error.InvalidCall;
        if (t.title >= pl.titles.len) return error.InvalidCall;
        const ti = &pl.titles[t.title];
        return .{ ti, navOf(ti, t.kind, t.track) orelse return error.InvalidCall };
    }

    fn number(t: *TrackRef) u32 {
        return t.track;
    }
    fn getSelectable(t: *TrackRef, cx: *js.Context) js.Error!bool {
        const s = Script.of(cx);
        _, const n = try t.nav(cx);
        return s.world.model.selectable.get(.{ .title = t.title, .kind = @backingInt(t.kind), .track = t.track }) orelse n.selectable;
    }
    fn setSelectable(t: *TrackRef, cx: *js.Context, v: bool) js.Error!void {
        const s = Script.of(cx);
        try s.world.model.selectable.put(s.gpa, .{ .title = t.title, .kind = @backingInt(t.kind), .track = t.track }, v);
    }
    fn languageCode(t: *TrackRef, cx: *js.Context) js.Error!Value {
        _, const n = try t.nav(cx);
        const l = langCode(n.langcode) orelse return js.undefined;
        return cx.string(&l);
    }
    fn languageCodeExtension(t: *TrackRef, cx: *js.Context) js.Error!f64 {
        _, const n = try t.nav(cx);
        return nanOr(langExt(n.langcode));
    }
    fn forced(t: *TrackRef, cx: *js.Context) js.Error!bool {
        _, const n = try t.nav(cx);
        return n.forced;
    }

    /// getMediaAttribute(time, name): an attribute of the track's Media Attribute Item at that title time.
    fn getMediaAttribute(t: *TrackRef, cx: *js.Context, time: []const u8, name: []const u8) js.Error!Value {
        const s = Script.of(cx);
        const ti, _ = try t.nav(cx);
        const f = host.parseTimecode(time, fps(s)) orelse return error.Argument;
        if (f >= ti.duration) return error.Argument;
        const clip = ti.clipAt(.primary, f) orelse return error.InvalidCall;
        const pl = plOf(s).?;
        const attr: u8 = switch (t.kind) {
            .video => for (clip.video) |v| {
                if (v.track == t.track) break v.media_attr;
            } else return error.InvalidCall,
            .audio => for (clip.audio) |v| {
                if (v.track == t.track) break v.media_attr;
            } else return error.InvalidCall,
            .subtitle => for (clip.subtitle) |v| {
                if (v.track == t.track) break v.media_attr;
            } else return error.InvalidCall,
        };
        const list = switch (t.kind) {
            .video => pl.video_attrs,
            .audio => pl.audio_attrs,
            .subtitle => pl.subpicture_attrs,
        };
        for (list) |*m| if (m.index == attr) {
            const v = m.get(name) orelse return error.Argument;
            return cx.string(v);
        };
        return error.InvalidCall;
    }

    pub const js_class = audio_track_class;
};

const audio_track_class: js.Class = .{
    .name = "AudioTrack",
    .finalize = TrackRef.finalize,
    .members = &.{
        js.prop("number", TrackRef.number, null),
        js.prop("selectable", TrackRef.getSelectable, TrackRef.setSelectable),
        js.prop("languageCode", TrackRef.languageCode, null),
        js.prop("languageCodeExtension", TrackRef.languageCodeExtension, null),
        js.method("getMediaAttribute", TrackRef.getMediaAttribute),
    },
};

const video_track_class: js.Class = .{
    .name = "VideoTrack",
    .finalize = TrackRef.finalize,
    .members = &.{
        js.prop("number", TrackRef.number, null),
        js.prop("selectable", TrackRef.getSelectable, TrackRef.setSelectable),
        js.method("getMediaAttribute", TrackRef.getMediaAttribute),
    },
};

const subtitle_track_class: js.Class = .{
    .name = "SubtitleTrack",
    .finalize = TrackRef.finalize,
    .members = &.{
        js.prop("number", TrackRef.number, null),
        js.prop("selectable", TrackRef.getSelectable, TrackRef.setSelectable),
        js.prop("forced", TrackRef.forced, null),
        js.prop("languageCode", TrackRef.languageCode, null),
        js.prop("languageCodeExtension", TrackRef.languageCodeExtension, null),
        js.method("getMediaAttribute", TrackRef.getMediaAttribute),
    },
};

// ---- video (Z.10.18–Z.10.22) ----------------------------------------------------------------------------------------

pub const VideoScale = struct {
    num: u8,
    den: u8,

    fn make(s: *Script, num: u8, den: u8) js.Error!Value {
        const v = try s.gpa.create(VideoScale);
        v.* = .{ .num = num, .den = den };
        return s.cx.wrap(VideoScale, v) catch |e| {
            s.gpa.destroy(v);
            return e;
        };
    }
    fn finalize(ptr: *anyopaque, rt: *js.Runtime) void {
        rt.gpa.destroy(@as(*VideoScale, @ptrCast(@alignCast(ptr))));
    }
    fn numerator(v: *VideoScale) u32 {
        return v.num;
    }
    fn denominator(v: *VideoScale) u32 {
        return v.den;
    }

    pub const js_class: js.Class = .{
        .name = "VideoScale",
        .finalize = finalize,
        .members = &.{ js.prop("numerator", numerator, null), js.prop("denominator", denominator, null) },
    };
};

fn layoutOf(s: *Script, main: bool) *Layout {
    return if (main) &modelOf(s).main else &modelOf(s).sub;
}

fn L(comptime main: bool) type {
    return struct {
        fn changing(s: *Script) bool {
            return layoutOf(s, main).changing;
        }
        fn x(s: *Script) i32 {
            return layoutOf(s, main).x;
        }
        fn y(s: *Script) i32 {
            return layoutOf(s, main).y;
        }
        fn scale(s: *Script) js.Error!Value {
            const sc = layoutOf(s, main).scale orelse return js.null;
            return VideoScale.make(s, sc[0], sc[1]);
        }
        fn cropX(s: *Script) u32 {
            return layoutOf(s, main).crop_x;
        }
        fn cropY(s: *Script) u32 {
            return layoutOf(s, main).crop_y;
        }
        fn cropW(s: *Script) u32 {
            return layoutOf(s, main).crop_w;
        }
        fn cropH(s: *Script) u32 {
            return layoutOf(s, main).crop_h;
        }

        /// changeLayout(x, y, scale, cropX, cropY, cropWidth, cropHeight, duration) (Z.10.19.3, Z.10.20.3).
        fn changeLayout(s: *Script, px: i32, py: i32, scale_v: Value, cx_: u32, cy_: u32, cw: u32, ch: u32, duration: []const u8) js.Error!void {
            const m = modelOf(s);
            const lay = layoutOf(s, main);
            if (lay.changing) return error.InvalidCall;
            const dur = host.parseTimecode(duration, fps(s)) orelse return error.Argument;
            if (dur > 3 * fps(s)) return error.Argument;
            const playing = m.play_state == PlayState.play;
            const paused = m.play_state == PlayState.pause;
            if (!(playing or (paused and dur == 0))) return error.InvalidCall;
            const new_scale: ?[2]u8 = if (c.JS_IsNull(scale_v) or c.JS_IsUndefined(scale_v)) null else blk: {
                const vs = s.cx.unwrap(VideoScale, scale_v) orelse return error.Argument;
                break :blk .{ vs.num, vs.den };
            };
            if ((lay.scale == null or new_scale == null) and dur != 0) return error.InvalidCall;
            if (@mod(px, 2) != 0 or @mod(py, 2) != 0 or cx_ % 2 != 0 or cy_ % 2 != 0 or cw % 2 != 0 or ch % 2 != 0) return error.Argument;
            const target: Layout.Target = .{ .x = px, .y = py, .scale = new_scale, .crop = .{ cx_, cy_, cw, ch } };
            const ticks: u64 = @intFromFloat(@round(@as(f64, @floatFromInt(dur)) / @as(f64, @floatFromInt(fps(s))) * s.world.tick_rate));
            lay.changing = true;
            lay.target = target;
            lay.done_at = s.world.tick + ticks;
            command(s, .{ .layout = .{ .main = main, .x = px, .y = py, .scale = new_scale, .crop = target.crop, .ticks = @intCast(ticks) } });
            if (ticks == 0 and playing) finishLayout(lay);
        }
    };
}

fn finishLayout(lay: *Layout) void {
    const t = lay.target orelse return;
    lay.x = t.x;
    lay.y = t.y;
    lay.scale = t.scale;
    lay.crop_x = t.crop[0];
    lay.crop_y = t.crop[1];
    lay.crop_w = t.crop[2];
    lay.crop_h = t.crop[3];
    lay.changing = false;
    lay.target = null;
    lay.done_at = null;
}

/// Layout changes in progress end at their tick (a change made while paused waits for playback).
pub fn advanceLayouts(w: *World) void {
    const playing = w.model.play_state == PlayState.play;
    for ([_]*Layout{ &w.model.main, &w.model.sub }) |lay| {
        const at = lay.done_at orelse continue;
        if (!playing) {
            lay.done_at = at + 1;
            continue;
        }
        if (w.tick >= at) finishLayout(lay);
    }
}

const MV = struct {
    fn capturing(s: *Script) bool {
        return modelOf(s).capturing;
    }
    fn outerY(s: *Script) u32 {
        return modelOf(s).outer[0];
    }
    fn outerCr(s: *Script) u32 {
        return modelOf(s).outer[1];
    }
    fn outerCb(s: *Script) u32 {
        return modelOf(s).outer[2];
    }
    fn setOuterFrameColor(s: *Script, y: u32, cr: u32, cb: u32) js.Error!void {
        if (y < 16 or y > 235 or cr < 16 or cr > 240 or cb < 16 or cb > 240) return error.Argument;
        modelOf(s).outer = .{ @intCast(y), @intCast(cr), @intCast(cb) };
        command(s, .{ .outer_color = modelOf(s).outer });
    }
    /// capture(uri, callback): only while paused, into the API Managed Area. This player cannot read the main
    /// video back (the compositor is VLC's): the capture fails (callback FAILED) once its checks pass.
    fn capture(s: *Script, u: []const u8, cb: Value) js.Error!void {
        const m = modelOf(s);
        const f = s.world.files orelse return error.InvalidCall;
        if (f.free("file:///filecache/") < 1920 * 1080 * 3) return error.NotEnoughSpace;
        if (m.play_state != PlayState.pause or m.capturing) return error.InvalidCall;
        const status: u32 = if ((files_mod.Files.where(u) catch .disc) != .temp or f.exists(u)) Result.argument else Result.failed;
        s.postCall(cb, &.{ s.cx.number(@floatFromInt(status)), try s.cx.string(u) }, "capture") catch {};
    }
    /// changeImageSize(src, dst, n, d, callback): the files are Capture Image Format (§6.5.1.4.1) files.
    fn changeImageSize(s: *Script, src: []const u8, dst: []const u8, num: u32, den: u32, cb: Value) js.Error!void {
        if (num < 1 or num > 16 or den < 1 or den > 16 or num > den) return error.Argument;
        if (std.mem.eql(u8, src, dst)) return error.Argument;
        const f = s.world.files orelse return error.InvalidCall;
        const in_cache = (files_mod.Files.where(src) catch .disc) == .temp;
        // Captures are never made (see capture), so an existing source is not a capture file.
        const status: u32, const which = if (!in_cache or !f.exists(src)) .{ Result.file_not_found, src } else .{ Result.wrong_format, src };
        s.postCall(cb, &.{ s.cx.number(@floatFromInt(status)), try s.cx.string(which) }, "changeImageSize") catch {};
    }
};

const layout_members = [_]js.Member{
    js.prop("changing", L(true).changing, null),
};

const main_video_class: js.Class = .{
    .name = "MainVideo",
    .members = &.{
        js.prop("capturing", MV.capturing, null),
        js.prop("changing", L(true).changing, null),
        js.prop("outerFrameColorY", MV.outerY, null),
        js.prop("outerFrameColorCr", MV.outerCr, null),
        js.prop("outerFrameColorCb", MV.outerCb, null),
        js.prop("x", L(true).x, null),
        js.prop("y", L(true).y, null),
        js.prop("scale", L(true).scale, null),
        js.prop("cropX", L(true).cropX, null),
        js.prop("cropY", L(true).cropY, null),
        js.prop("cropWidth", L(true).cropW, null),
        js.prop("cropHeight", L(true).cropH, null),
        js.method("capture", MV.capture),
        js.method("changeImageSize", MV.changeImageSize),
        js.method("setOuterFrameColor", MV.setOuterFrameColor),
        js.method("changeLayout", L(true).changeLayout),
    },
};

const SV = struct {
    fn getAlpha(s: *Script) u32 {
        return modelOf(s).sub_alpha;
    }
    fn setAlpha(s: *Script, v: u32) js.Error!void {
        if (v > 255) return error.Argument;
        modelOf(s).sub_alpha = @intCast(v);
        command(s, .{ .sub_alpha = @intCast(v) });
    }
};

const sub_video_class: js.Class = .{
    .name = "SubVideo",
    .members = &.{
        js.prop("changing", L(false).changing, null),
        js.prop("x", L(false).x, null),
        js.prop("y", L(false).y, null),
        js.prop("scale", L(false).scale, null),
        js.prop("cropX", L(false).cropX, null),
        js.prop("cropY", L(false).cropY, null),
        js.prop("cropWidth", L(false).cropW, null),
        js.prop("cropHeight", L(false).cropH, null),
        js.prop("alpha", SV.getAlpha, SV.setAlpha),
        js.method("changeLayout", L(false).changeLayout),
    },
};

const video_class: js.Class = .{ .name = "Video", .members = &.{ js.prop("main", kept("Player.video.main"), null), js.prop("sub", kept("Player.video.sub"), null) } };

const ST = struct {
    fn getVisible(s: *Script) bool {
        return modelOf(s).subtitle_visible;
    }
    fn setVisible(s: *Script, v: bool) void {
        modelOf(s).subtitle_visible = v;
        command(s, .{ .subtitle_visible = v });
    }
};

const subtitle_class: js.Class = .{ .name = "Subtitle", .members = &.{js.prop("visible", ST.getVisible, ST.setVisible)} };

// ---- audio (Z.10.23–Z.10.29) ----------------------------------------------------------------------------------------

/// Which volumes an OutputChannels shows: the main audio's, or a channel's mix-down (sub/effect × left/right).
pub const OutChannels = struct { which: u8 };
var channel_sets = [_]OutChannels{ .{ .which = 0 }, .{ .which = 1 }, .{ .which = 2 }, .{ .which = 3 }, .{ .which = 4 } };
/// AudioOutput: sub left/right, effect left/right (its `mix` is channel_sets[1 + i]).
pub const AudioOut = struct { which: u8 };
var audio_outputs = [_]AudioOut{ .{ .which = 0 }, .{ .which = 1 }, .{ .which = 2 }, .{ .which = 3 } };
/// Channels: sub (0) or effect (1).
pub const Channels = struct { which: u8 };
var channels_objs = [_]Channels{ .{ .which = 0 }, .{ .which = 1 } };

fn volumes(m: *Model, which: u8) *[8]u8 {
    return switch (which) {
        0 => &m.main_volume,
        1 => &m.sub_mix[0],
        2 => &m.sub_mix[1],
        3 => &m.effect_mix[0],
        else => &m.effect_mix[1],
    };
}

fn outChannel(comptime i: usize) fn (*OutChannels, *js.Context) u32 {
    return struct {
        fn f(o: *OutChannels, cx: *js.Context) u32 {
            return volumes(&Script.of(cx).world.model, o.which)[i];
        }
    }.f;
}

const output_channels_class: js.Class = .{
    .name = "OutputChannels",
    .members = &.{
        js.prop("left", outChannel(0), null),
        js.prop("right", outChannel(1), null),
        js.prop("center", outChannel(2), null),
        js.prop("leftS", outChannel(3), null),
        js.prop("rightS", outChannel(4), null),
        js.prop("leftB", outChannel(5), null),
        js.prop("rightB", outChannel(6), null),
        js.prop("lfe", outChannel(7), null),
    },
};

fn aoMix(o: *AudioOut, cx: *js.Context) Value {
    var buf: [8]u8 = undefined;
    const k = std.fmt.bufPrint(&buf, "out{d}", .{o.which + 1}) catch unreachable;
    return cx.dup(Script.of(cx).kept(k));
}

const audio_output_class: js.Class = .{ .name = "AudioOutput", .members = &.{js.prop("mix", aoMix, null)} };

fn chLeft(ch: *Channels, cx: *js.Context) Value {
    var buf: [8]u8 = undefined;
    return cx.dup(Script.of(cx).kept(std.fmt.bufPrint(&buf, "ao{d}", .{ch.which * 2}) catch unreachable));
}

fn chRight(ch: *Channels, cx: *js.Context) Value {
    var buf: [8]u8 = undefined;
    return cx.dup(Script.of(cx).kept(std.fmt.bufPrint(&buf, "ao{d}", .{ch.which * 2 + 1}) catch unreachable));
}

const channels_class: js.Class = .{ .name = "Channels", .members = &.{ js.prop("left", chLeft, null), js.prop("right", chRight, null) } };

/// The Total Volume Condition (Z.10.23): for each output, the volumes into it add up to at most 100 %.
fn totalVolumeOk(m: *const Model) bool {
    for (0..8) |out| {
        var sum: f64 = 0;
        const all = [_]u8{ m.main_volume[out], m.sub_mix[0][out], m.sub_mix[1][out], m.effect_mix[0][out], m.effect_mix[1][out] };
        for (all) |p| if (p > 0) {
            sum += 100 * std.math.pow(f64, 10, (@as(f64, @floatFromInt(p)) - 255) / 40);
        };
        if (sum > 100.0001) return false;
    }
    return true;
}

fn mixingCommand(s: *Script) void {
    const m = modelOf(s);
    command(s, .{ .mixing = .{ .main = m.main_volume, .sub = m.sub_mix, .effect = m.effect_mix } });
}

const AU = struct {
    fn setVolumes(s: *Script, a: Args8) js.Error!void {
        const m = modelOf(s);
        const old = m.main_volume;
        for (a.v, 0..) |x, i| {
            if (x > 255) return error.Argument;
            m.main_volume[i] = @intCast(x);
        }
        if (!totalVolumeOk(m)) {
            m.main_volume = old;
            return error.Argument;
        }
        mixingCommand(s);
    }

    fn setMix(s: *Script, target: *[2][8]u8, a: [16]u32) js.Error!void {
        const m = modelOf(s);
        const old = target.*;
        for (a, 0..) |x, i| {
            if (x > 255) return error.Argument;
            target[i / 8][i % 8] = @intCast(x);
        }
        if (!totalVolumeOk(m)) {
            target.* = old;
            return error.Argument;
        }
        mixingCommand(s);
    }

    fn subSetMixing(s: *Script, a0: u32, a1: u32, a2: u32, a3: u32, a4: u32, a5: u32, a6: u32, a7: u32, a8: u32, a9: u32, a10: u32, a11: u32, a12: u32, a13: u32, a14: u32, a15: u32) js.Error!void {
        return setMix(s, &modelOf(s).sub_mix, .{ a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15 });
    }

    fn effectSetMixing(s: *Script, a0: u32, a1: u32, a2: u32, a3: u32, a4: u32, a5: u32, a6: u32, a7: u32, a8: u32, a9: u32, a10: u32, a11: u32, a12: u32, a13: u32, a14: u32, a15: u32) js.Error!void {
        return setMix(s, &modelOf(s).effect_mix, .{ a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15 });
    }

    fn mainSetVolumes(s: *Script, l: u32, r: u32, cc: u32, ls: u32, rs: u32, lb: u32, rb: u32, lfe: u32) js.Error!void {
        return setVolumes(s, .{ .v = .{ l, r, cc, ls, rs, lb, rb, lfe } });
    }

    fn effectPlaying(s: *Script) bool {
        return modelOf(s).effect_playing;
    }

    /// play(uri, repeat, callback): a WAV file from the File Cache, `repeat` times (Z.10.26.3).
    fn effectPlay(s: *Script, u: []const u8, repeat: u32, cb: Value) js.Error!void {
        if (!uri_mod.valid(u) or uri_mod.locate(u) == null) return error.Argument;
        if (repeat < 1 or repeat > 99) return error.Argument;
        const m = modelOf(s);
        if (m.effect_playing) command(s, .effect_stop);
        m.effect_playing = true;
        m.effect_serial += 1;
        const serial = m.effect_serial;
        const f = s.world.files orelse return effectDone(s, cb, Result.file_not_found, serial);
        const data = f.read(s.gpa, u) catch return effectDone(s, cb, Result.file_not_found, serial);
        const ms = wavDurationMs(data) orelse {
            s.gpa.free(data);
            return effectDone(s, cb, Result.wrong_format, serial);
        };
        command(s, .{ .effect_play = .{ .data = data, .repeat = repeat } });
        // FINISHED when the sound has played (it is timed here; the mixer plays it).
        const ticks: u64 = @intFromFloat(@ceil(@as(f64, @floatFromInt(ms * repeat)) / 1000 * s.world.tick_rate));
        const done = try EffectDone.make(s, cb, serial);
        s.post(.{ .call = .{ .f = done, .args = &.{}, .what = "effect audio" } }, .app, s.appTicks() + ticks, null) catch {};
    }

    fn effectDone(s: *Script, cb: Value, status: u32, serial: u64) js.Error!void {
        _ = serial;
        modelOf(s).effect_playing = false;
        s.postCall(cb, &.{s.cx.number(@floatFromInt(status))}, "effect audio") catch {};
    }

    fn effectStop(s: *Script) js.Error!void {
        const m = modelOf(s);
        if (!m.effect_playing) return error.InvalidCall;
        m.effect_playing = false;
        m.effect_serial += 1;
        command(s, .effect_stop);
    }
};

const Args8 = struct { v: [8]u32 };

/// The end of an effect sound: callback(FINISHED) unless another sound or stop() came since.
const EffectDone = struct {
    fn make(s: *Script, cb: Value, serial: u64) js.Error!Value {
        var data = [_]Value{ s.cx.dup(cb), s.cx.number(@floatFromInt(serial)) };
        const f = c.JS_NewCFunctionData(s.cx.ctx, run, 0, 0, 2, &data);
        s.cx.free(data[0]);
        if (c.JS_IsException(f)) return error.Thrown;
        return f;
    }

    fn run(ctx: ?*c.JSContext, _: Value, _: c_int, _: [*c]Value, _: c_int, data: [*c]Value) callconv(.c) Value {
        const cx = js.Context.of(ctx);
        const s = Script.of(cx);
        var serial: f64 = 0;
        _ = c.JS_ToFloat64(ctx, &serial, data[1]);
        const m = modelOf(s);
        if (@as(u64, @intFromFloat(serial)) != m.effect_serial or !m.effect_playing) return js.undefined;
        m.effect_playing = false;
        if (cx.isFunction(data[0])) {
            var args = [_]Value{cx.number(Result.finished)};
            cx.callReport(data[0], s.app_obj, &args, "effect audio");
        }
        return js.undefined;
    }
};

/// The length of a WAV file (RIFF/WAVE with fmt and data chunks), in ms; null if it is not one.
pub fn wavDurationMs(data: []const u8) ?u64 {
    if (data.len < 12 or !std.mem.eql(u8, data[0..4], "RIFF") or !std.mem.eql(u8, data[8..12], "WAVE")) return null;
    var i: usize = 12;
    var byte_rate: ?u32 = null;
    while (i + 8 <= data.len) {
        const id = data[i..][0..4];
        const len = std.mem.readInt(u32, data[i + 4 ..][0..4], .little);
        const body = i + 8;
        if (std.mem.eql(u8, id, "fmt ") and body + 16 <= data.len) byte_rate = std.mem.readInt(u32, data[body + 8 ..][0..4], .little);
        if (std.mem.eql(u8, id, "data")) {
            const rate = byte_rate orelse return null;
            if (rate == 0) return null;
            const n = @min(len, data.len - body);
            return @as(u64, n) * 1000 / rate;
        }
        i = body + len + (len & 1);
    }
    return null;
}

const audio_class: js.Class = .{
    .name = "Audio",
    .members = &.{ js.prop("main", kept("Player.audio.main"), null), js.prop("sub", kept("Player.audio.sub"), null), js.prop("effect", kept("Player.audio.effect"), null) },
};

const main_audio_class: js.Class = .{ .name = "MainAudio", .members = &.{ js.prop("channels", kept("out0"), null), js.method("setVolumes", AU.mainSetVolumes) } };
const sub_audio_class: js.Class = .{ .name = "SubAudio", .members = &.{ js.prop("channels", kept("ch0"), null), js.method("setMixing", AU.subSetMixing) } };
const effect_audio_class: js.Class = .{
    .name = "EffectAudio",
    .members = &.{
        js.prop("playing", AU.effectPlaying, null),
        js.prop("channels", kept("ch1"), null),
        js.method("play", AU.effectPlay),
        js.method("stop", AU.effectStop),
        js.method("setMixing", AU.effectSetMixing),
    },
};

// ---- StandardContentPlayer (Z.10.30), SecondaryVideoPlayer (Z.10.31), GeneralParameters (Z.10.32) -------------------

const SCP = struct {
    fn getGPRM(s: *Script, i: u32) js.Error!u32 {
        if (i > 63) return error.Argument;
        return modelOf(s).gprm[i];
    }
    fn setGPRM(s: *Script, i: u32, v: u32) js.Error!void {
        if (i > 63 or v > 65535) return error.Argument;
        modelOf(s).gprm[i] = @intCast(v);
    }
    fn getSPRM(s: *Script, i: u32) js.Error!u32 {
        if (i > 31) return error.Argument;
        return modelOf(s).sprm[i];
    }
    /// SPRMs holding Player parameters (menu language, country, parental level, aspect, accessibility…) cannot
    /// be set (Z.10.30.2).
    fn setSPRM(s: *Script, i: u32, v: u32) js.Error!void {
        if (i > 31 or v > 65535) return error.Argument;
        const player_params = [_]u32{ 0, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22 };
        if (std.mem.indexOfScalar(u32, &player_params, i) != null) return error.Argument;
        modelOf(s).sprm[i] = @intCast(v);
    }
    fn play(s: *Script, vtsn: u32, domain: u32) js.Error!void {
        if (vtsn < 1 or vtsn > 511 or domain < 1 or domain > 2) return error.Argument;
        if (modelOf(s).play_state != PlayState.pause) return error.InvalidCall;
        if (!s.world.has_standard_content) return error.InvalidCall;
        command(s, .{ .standard_content = .{ .vtsn = @intCast(vtsn), .menu = domain == 2 } });
    }
};

const scp_class: js.Class = .{
    .name = "StandardContentPlayer",
    .members = &.{
        js.method("getGPRM", SCP.getGPRM),
        js.method("setGPRM", SCP.setGPRM),
        js.method("getSPRM", SCP.getSPRM),
        js.method("setSPRM", SCP.setSPRM),
        js.method("play", SCP.play),
        js.constant("DOMAIN_TITLE", 1),
        js.constant("DOMAIN_MENU", 2),
    },
};

const SVP = struct {
    pub const init = 5;
    pub const play = 1;
    pub const pause = 2;
    pub const stop = 3;
    pub const sync = 4;
    pub const preload = 6;
    pub const streaming_play = 7;
    pub const streaming_pause = 8;

    fn playState(s: *Script) u32 {
        return modelOf(s).svp_state;
    }
    fn elapsedTime(_: *Script) Value {
        return js.undefined;
    }
    /// play(uri, start, offset, stop, callback): the Secondary Video Player plays Secondary Audio Video from a
    /// file or a stream. This player plays secondary video only as the playlist schedules it (Phase 7): the
    /// call is checked, then the callback says it cannot (INVALID_CALL for files, NETWORK_PROBLEM for streams).
    fn playFn(s: *Script, u: []const u8, start: []const u8, offset: []const u8, stop_t: Value, cb: Value) js.Error!void {
        const m = modelOf(s);
        if (m.svp_state != stop) return error.InvalidCall;
        _ = start;
        _ = offset;
        _ = stop_t;
        m.svp_state = init;
        if (!uri_mod.valid(u)) {
            m.svp_state = stop;
            return error.Argument;
        }
        const loc = uri_mod.locate(u) orelse {
            m.svp_state = stop;
            return error.Argument;
        };
        m.svp_state = stop;
        const status: u32 = if (loc.area == .network) Result.network_problem else blk: {
            const f = s.world.files orelse break :blk Result.file_not_found;
            break :blk if (f.exists(u)) Result.invalid_call else Result.file_not_found;
        };
        s.postCall(cb, &.{s.cx.number(@floatFromInt(status))}, "SecondaryVideoPlayer") catch {};
    }
    fn pauseOn(s: *Script) js.Error!void {
        const m = modelOf(s);
        switch (m.svp_state) {
            play, init => m.svp_state = pause,
            streaming_play, preload => m.svp_state = streaming_pause,
            else => return error.InvalidCall,
        }
    }
    fn pauseOff(s: *Script) js.Error!void {
        const m = modelOf(s);
        if (m.capturing) return error.InvalidCall;
        switch (m.svp_state) {
            pause => m.svp_state = play,
            streaming_pause => m.svp_state = streaming_play,
            else => return error.InvalidCall,
        }
    }
    fn stopFn(s: *Script) js.Error!void {
        const m = modelOf(s);
        switch (m.svp_state) {
            play, init, pause, preload, streaming_play, streaming_pause => m.svp_state = stop,
            else => return error.InvalidCall,
        }
    }
};

const svp_class: js.Class = .{
    .name = "SecondaryVideoPlayer",
    .members = &.{
        js.prop("playState", SVP.playState, null),
        js.prop("elapsedTime", SVP.elapsedTime, null),
        js.method("play", SVP.playFn),
        js.method("pauseOn", SVP.pauseOn),
        js.method("pauseOff", SVP.pauseOff),
        js.method("stop", SVP.stopFn),
        js.constant("PLAYSTATE_INIT", SVP.init),
        js.constant("PLAYSTATE_PLAY", SVP.play),
        js.constant("PLAYSTATE_PAUSE", SVP.pause),
        js.constant("PLAYSTATE_STOP", SVP.stop),
        js.constant("PLAYSTATE_SYNC", SVP.sync),
        js.constant("PLAYSTATE_STREAMING_PRELOAD", SVP.preload),
        js.constant("PLAYSTATE_STREAMING_PLAY", SVP.streaming_play),
        js.constant("PLAYSTATE_STREAMING_PAUSE", SVP.streaming_pause),
    },
};

const GP = struct {
    const max = 64;

    fn availableNumber(s: *Script) u32 {
        return @intCast(max - modelOf(s).general.count());
    }
    fn getValue(s: *Script, key: []const u8) js.Error!Value {
        if (key.len > 127) return error.Argument;
        const v = modelOf(s).general.get(key) orelse return js.undefined;
        return s.cx.string(v);
    }
    /// setValue(key, value): undefined removes the key.
    fn setValue(s: *Script, key: []const u8, v: Value) js.Error!void {
        const m = modelOf(s);
        if (key.len > 127) return error.Argument;
        if (c.JS_IsUndefined(v)) {
            if (m.general.fetchSwapRemove(key)) |kv| {
                s.gpa.free(kv.key);
                s.gpa.free(kv.value);
            }
            return;
        }
        const value = try s.cx.toStringAlloc(s.gpa, v);
        errdefer s.gpa.free(value);
        if (value.len > 255) return error.Argument;
        if (m.general.getPtr(key)) |slot| {
            s.gpa.free(slot.*);
            slot.* = value;
            return;
        }
        if (m.general.count() >= max) return error.NotEnoughSpace;
        const k = try s.gpa.dupe(u8, key);
        errdefer s.gpa.free(k);
        try m.general.put(s.gpa, k, value);
    }
};

const general_class: js.Class = .{
    .name = "GeneralParameters",
    .members = &.{
        js.prop("availableNumber", GP.availableNumber, null),
        js.method("getValue", GP.getValue),
        js.method("setValue", GP.setValue),
    },
};

// ---- the timeline's system events ---------------------------------------------------------------------------------

/// Raises the system events of the Title Timeline's progress since the last tick (Table 8.3.1-1): scheduled
/// events, the chapter, clips beginning, the tracks they bring, clips ending. A jump (or a new title) counts as
/// the clips of the old position ending and those of the new one beginning. No events in trick play
/// (marked N), which this player does not have.
pub fn timelineEvents(w: *World, jumped: bool) void {
    const apps = w.apps orelse return;
    const title = curTitle(w) orelse return;
    const m = &w.model;
    const now = w.title_time;
    const same_title = m.last_title == w.title_index and m.last_time != null;
    const prev = if (same_title) m.last_time.? else null;
    defer {
        m.last_title = w.title_index;
        m.last_time = now;
    }
    if (w.model.play_state != PlayState.play and prev != null and now == prev.?) return;
    // Scheduled events passed (forward, without a jump).
    if (prev) |p| if (!jumped and now > p) for (title.scheduled) |sc| {
        if (sc.kind == .event and sc.time > p and sc.time <= now) apps.sendSystem(.{ .kind = .scheduled, .type = "scheduled_event", .id = if (sc.id.len > 0) sc.id else null }, null);
        if (sc.kind == .pause_at and sc.time > p and sc.time <= now) {
            m.play_state = PlayState.pause;
            if (w.eng) |e| e.command(.{ .pause = true });
        }
    };
    // The chapter.
    const ch: ?u32 = if (title.chapterAt(now) > 0) @intCast(title.chapterAt(now)) else null;
    if (ch != m.last_chapter or !same_title) {
        // Chapter numbers from 0, as Chapter.number: `newValue` indexes `Title.chapters`.
        if (ch) |n| apps.sendSystem(.{ .kind = .chapter, .type = "chapter", .old = if (same_title) if (m.last_chapter) |o| @intCast(o - 1) else null else null, .new = @intCast(n - 1) }, null);
        m.last_chapter = ch;
    }
    // Clips.
    var now_clips: std.ArrayList(usize) = .empty;
    defer now_clips.deinit(w.gpa);
    for (title.clips, 0..) |cl, i| if (now >= cl.title_begin and now < cl.title_end) now_clips.append(w.gpa, i) catch {};
    var ended: std.ArrayList(usize) = .empty;
    defer ended.deinit(w.gpa);
    for (m.playing_clips.items) |i| {
        const still = !jumped and same_title and std.mem.indexOfScalar(usize, now_clips.items, i) != null;
        if (!still) ended.append(w.gpa, i) catch {};
    }
    const old_title: ?*const xpl.Title = if (same_title) title else null;
    for (now_clips.items) |i| {
        const was = !jumped and same_title and std.mem.indexOfScalar(usize, m.playing_clips.items, i) != null;
        if (!was) {
            const cl = title.clips[i];
            apps.sendSystem(.{ .kind = .clip, .type = "clip_begin", .id = if (cl.id.len > 0) cl.id else null }, null);
        }
    }
    reselect(w, false);
    for (ended.items) |i| {
        const t = old_title orelse break;
        if (i >= t.clips.len) continue;
        const cl = t.clips[i];
        apps.sendSystem(.{ .kind = .clip, .type = "clip_end", .id = if (cl.id.len > 0) cl.id else null }, null);
    }
    m.playing_clips.clearRetainingCapacity();
    m.playing_clips.appendSlice(w.gpa, now_clips.items) catch {};
}

/// A new title: the timeline's state starts over (the presentation parameters marked I in Table W-3).
pub fn titleBegins(w: *World) void {
    const m = &w.model;
    m.last_title = null;
    m.last_time = null;
    m.last_chapter = null;
    m.playing_clips.clearRetainingCapacity();
    m.play_state = PlayState.play;
    m.play_speed = null;
    m.main = .{ .crop_w = w.aperture_w, .crop_h = w.aperture_h };
    m.sub = .{ .scale = .{ 16, 16 }, .crop_w = w.aperture_w, .crop_h = w.aperture_h };
    m.sub_alpha = 0;
    m.subtitle_visible = true;
    m.effect_playing = false;
    m.capturing = false;
}

// ---- the default input handler (Annex V) ----------------------------------------------------------------------------

/// What a key nobody consumed does (Annex V, the handlers V.1–V.15).
pub fn defaultKey(w: *World, key: u8) void {
    const m = &w.model;
    const e = w.eng orelse return;
    const title = curTitle(w);
    switch (key) {
        0xFA => { // VK_PLAY
            m.play_state = PlayState.play;
            m.play_speed = null;
            e.command(.{ .pause = false });
        },
        0xB3 => { // VK_PAUSE
            const pause = m.play_state != PlayState.pause;
            m.play_state = if (pause) PlayState.pause else PlayState.play;
            m.play_speed = null;
            e.command(.{ .pause = pause });
        },
        0xC8 => { // VK_SKIP_PREV: currentChapter.top()
            const t = title orelse return;
            const i = w.title_index orelse return;
            const n = t.chapterAt(w.title_time);
            if (n == 0) return;
            var idx = n - 1;
            if (w.title_time -| t.chapters[idx].begin < w.fps and idx > 0) idx -= 1;
            e.command(.{ .jump_title = .{ .title = i, .time = t.chapters[idx].begin } });
        },
        0xC7 => { // VK_SKIP_NEXT: the next chapter, else onEnd's title, else stop
            const t = title orelse return;
            const i = w.title_index orelse return;
            const n = t.chapterAt(w.title_time);
            if (n < t.chapters.len) {
                e.command(.{ .jump_title = .{ .title = i, .time = t.chapters[n].begin } });
            } else if (w.pl) |pl| {
                if (t.on_end.len > 0) if (pl.titleById(t.on_end)) |next| {
                    if (next != i) {
                        if (m.play_state == PlayState.pause) e.command(.{ .pause = false }); // as Title.jump
                        m.play_state = PlayState.play;
                        m.play_speed = null;
                    }
                    e.command(.{ .jump_title = .{ .title = @intCast(next), .time = 0 } });
                    return;
                };
                e.command(.stop);
            }
        },
        0xC9 => { // VK_SUBTITLE_SWITCH
            m.subtitle_visible = !m.subtitle_visible;
            e.command(.{ .subtitle_visible = m.subtitle_visible });
        },
        0xCA => cycleTrack(w, .subtitle, false), // VK_SUBTITLE
        0xCB => cycleTrack(w, .subtitle, true), // VK_CC
        0xCC => cycleTrack(w, .video, false), // VK_ANGLE
        0xCD => cycleTrack(w, .audio, false), // VK_AUDIO
        else => {},
    }
}

/// The next selectable track after the current one (V.10–V.13); `cc`: closed caption tracks (extensions 5–7)
/// only, else (subtitles) only the others.
fn cycleTrack(w: *World, kind: Kind, cc: bool) void {
    const title = curTitle(w) orelse return;
    const list = navList(title, kind);
    if (list.len == 0) return;
    const tr = &w.model.tracks;
    const cur = switch (kind) {
        .video => tr.cur_video,
        .audio => tr.cur_audio,
        .subtitle => tr.cur_sub,
    } orelse return;
    const i = for (list, 0..) |n, k| {
        if (n.track == cur) break k;
    } else return;
    for (1..list.len) |j| {
        const n = list[(i + j) % list.len];
        if (!isSelectable(w, title, kind, n)) continue;
        if (kind == .subtitle) {
            const ext = langExt(n.langcode) orelse 0;
            const is_cc = ext >= 5 and ext <= 7;
            if (is_cc != cc) continue;
        }
        switch (kind) {
            .video => tr.sel_video = n.track,
            .audio => tr.sel_audio = n.track,
            .subtitle => tr.sel_sub = n.track,
        }
        reselect(w, true);
        return;
    }
}

// ---- XPath variables (Annex W.2) ------------------------------------------------------------------------------------

/// The value of system parameter variable `name`, or null.
pub fn systemVariable(w: *World, name: []const u8) ?xpath.Value {
    const m = &w.model;
    const eq = std.mem.eql;
    const num = struct {
        fn f(x: anytype) xpath.Value {
            return .{ .number = @floatFromInt(x) };
        }
        fn opt(x: anytype) xpath.Value {
            return .{ .number = if (x) |v| @floatFromInt(v) else std.math.nan(f64) };
        }
    };
    // Player parameters (W.2-1).
    if (eq(u8, name, "majorVersion")) return num.f(m.major);
    if (eq(u8, name, "minorVersion")) return num.f(m.minor);
    if (eq(u8, name, "currentDisplayMode")) return num.f(m.display_mode);
    if (eq(u8, name, "dataCacheSize")) return num.f(@as(u32, 64 * 1024));
    if (eq(u8, name, "performanceLevel")) return num.f(m.performance_level);
    const access = [_][]const u8{ "closedCaption", "simplifiedCaption", "largeFont", "contrastDisplay", "descriptiveAudio", "extendedInteractionTimes" };
    for (access, 0..) |a, i| if (eq(u8, name, a)) return .{ .boolean = m.accessibility & (@as(u32, 1) << @intCast(i)) != 0 };
    // Capability parameters (W.2-2).
    if (eq(u8, name, "mainAudioCapabilityLPCM")) return num.f(main_decode.lpcm);
    if (eq(u8, name, "mainAudioCapabilityDDP")) return num.f(main_decode.ddplus);
    if (eq(u8, name, "mainAudioCapabilityMPEG")) return num.f(main_decode.mpeg);
    if (eq(u8, name, "mainAudioCapabilityDTSHD")) return num.f(main_decode.dts_hd);
    if (eq(u8, name, "mainAudioCapabilityMLP")) return num.f(main_decode.mlp);
    if (eq(u8, name, "subAudioCapabilityDDP")) return num.f(sub_decode.ddplus);
    if (eq(u8, name, "subAudioCapabilityDTSHD")) return num.f(sub_decode.dts_hd);
    if (eq(u8, name, "subAudioCapabilityAACV2")) return num.f(sub_decode.aac_v2);
    if (eq(u8, name, "subAudioCapabilityMP3")) return num.f(sub_decode.mp3);
    if (eq(u8, name, "subAudioCapabilityWMAPro")) return num.f(sub_decode.wma_pro);
    if (eq(u8, name, "enableHDMIOutput")) return .{ .boolean = hdmi_caps.connected };
    if (eq(u8, name, "audioCapabilityAnalogOutput")) return num.f(@as(u32, 2));
    if (eq(u8, name, "audioCapabilityHDMI")) return .{ .number = std.math.nan(f64) };
    if (eq(u8, name, "audioCapabilitySPDIF")) return num.f(spdif_caps.channel);
    if (eq(u8, name, "spdifCapabilityEncoded")) return .{ .boolean = spdif_caps.encoded };
    if (eq(u8, name, "spdifCapabilityDirectOutputOfDD")) return .{ .boolean = spdif_caps.main & 1 != 0 };
    if (eq(u8, name, "spdifCapabilityDirectOutputOfDTS")) return .{ .boolean = spdif_caps.main & 2 != 0 };
    if (eq(u8, name, "subVideoResolution")) return num.f(@as(u32, 2));
    if (eq(u8, name, "networkConnection")) return .{ .boolean = w.network_allowed };
    if (eq(u8, name, "networkThroughput")) return num.f(w.network_kbps);
    if (eq(u8, name, "supportedOpenTypeFontTables")) return .{ .boolean = false };
    if (eq(u8, name, "supportOfSlowForward") or eq(u8, name, "supportOfSlowReverse") or eq(u8, name, "supportOfStepForward") or eq(u8, name, "supportOfStepReverse")) return .{ .boolean = false };
    // Presentation parameters (W.2-3).
    if (eq(u8, name, "playlistLocation")) return .{ .string = w.playlist_uri };
    if (eq(u8, name, "titleId")) return .{ .string = if (curTitle(w)) |t| t.id else "" };
    if (eq(u8, name, "titleNumber")) return if (w.title_index != null) num.f(curTitle(w).?.number) else .{ .number = std.math.nan(f64) };
    if (eq(u8, name, "timeOnTitleTime")) {
        var buf: [16]u8 = undefined;
        const s = events.timecode(&buf, w.title_time, w.fps);
        @memcpy(w.var_buf[0..s.len], s);
        return .{ .string = w.var_buf[0..s.len] };
    }
    if (eq(u8, name, "playState")) return num.f(m.play_state);
    if (eq(u8, name, "playSpeed")) return num.opt(m.play_speed);
    if (eq(u8, name, "playStateOfSecondaryVideoPlayer")) return num.f(m.svp_state);
    if (eq(u8, name, "elapsedTimeOfSecondaryVideoPlayer")) return .{ .string = "" };
    if (eq(u8, name, "currentVideoTrackNumber")) return num.opt(m.tracks.cur_video);
    if (eq(u8, name, "currentAudioTrackNumber")) return num.opt(m.tracks.cur_audio);
    if (eq(u8, name, "currentSubtitleTrackNumber")) return num.opt(m.tracks.cur_sub);
    if (eq(u8, name, "selectedVideoTrackNumber")) return num.opt(m.tracks.sel_video);
    if (eq(u8, name, "selectedAudioTrackNumber")) return num.opt(m.tracks.sel_audio);
    if (eq(u8, name, "selectedSubtitleTrackNumber")) return num.opt(m.tracks.sel_sub);
    if (eq(u8, name, "selectedAudioLanguageCode")) return .{ .string = if (m.tracks.sel_audio_lang) |*l| l else "" };
    if (eq(u8, name, "selectedAudioLanguageCodeExtension")) return num.opt(m.tracks.sel_audio_ext);
    if (eq(u8, name, "selectedSubtitleLanguageCode")) return .{ .string = if (m.tracks.sel_sub_lang) |*l| l else "" };
    if (eq(u8, name, "selectedSubtitleLanguageCodeExtension")) return num.opt(m.tracks.sel_sub_ext);
    if (eq(u8, name, "selectedApplicationGroup")) return num.opt(if (w.apps) |a| a.app_group else null);
    if (eq(u8, name, "effectAudioPlaying")) return .{ .boolean = m.effect_playing };
    if (eq(u8, name, "streamBufferSize")) return num.f(w.streaming_buffer_kb);
    // Audio parameters (W.2-4).
    const outs = [_][]const u8{ "Left", "Right", "Center", "LeftS", "RightS", "LeftB", "RightB", "Lfe" };
    if (std.mem.startsWith(u8, name, "mainAudioVolumeTo")) for (outs, 0..) |o, i| if (eq(u8, name["mainAudioVolumeTo".len..], o)) return num.f(m.main_volume[i]);
    const mixes = [_]struct { []const u8, *const [8]u8 }{
        .{ "subAudioLeftChannelGainTo", &m.sub_mix[0] },
        .{ "subAudioRightChannelGainTo", &m.sub_mix[1] },
        .{ "effectAudioLeftChannelGainTo", &m.effect_mix[0] },
        .{ "effectAudioRightChannelGainTo", &m.effect_mix[1] },
    };
    for (mixes) |mx| if (std.mem.startsWith(u8, name, mx[0])) for (outs, 0..) |o, i| if (eq(u8, name[mx[0].len..], o)) return num.f(mx[1][i]);
    // Layout parameters (W.2-5).
    if (eq(u8, name, "mainVideoOuterFrameColorY")) return num.f(m.outer[0]);
    if (eq(u8, name, "mainVideoOuterFrameColorCr")) return num.f(m.outer[1]);
    if (eq(u8, name, "mainVideoOuterFrameColorCb")) return num.f(m.outer[2]);
    if (eq(u8, name, "mainVideoChanging")) return .{ .boolean = m.main.changing };
    if (eq(u8, name, "mainVideoCapturing")) return .{ .boolean = m.capturing };
    if (eq(u8, name, "subVideoChanging")) return .{ .boolean = m.sub.changing };
    if (eq(u8, name, "subVideoAlpha")) return num.f(m.sub_alpha);
    if (eq(u8, name, "subtitleVisibility")) return .{ .boolean = m.subtitle_visible };
    for ([_]struct { []const u8, *const Layout }{ .{ "mainVideo", &m.main }, .{ "subVideo", &m.sub } }) |lv| {
        if (!std.mem.startsWith(u8, name, lv[0])) continue;
        const rest = name[lv[0].len..];
        const l = lv[1];
        if (eq(u8, rest, "X")) return num.f(l.x);
        if (eq(u8, rest, "Y")) return num.f(l.y);
        if (eq(u8, rest, "ScaleNumerator")) return num.opt(if (l.scale) |sc| sc[0] else null);
        if (eq(u8, rest, "ScaleDenominator")) return num.opt(if (l.scale) |sc| sc[1] else null);
        if (eq(u8, rest, "CropX")) return num.f(l.crop_x);
        if (eq(u8, rest, "CropY")) return num.f(l.crop_y);
        if (eq(u8, rest, "CropWidth")) return num.f(l.crop_w);
        if (eq(u8, rest, "CropHeight")) return num.f(l.crop_h);
    }
    // Cursor parameters (W.2-6).
    if (std.mem.startsWith(u8, name, "cursor")) {
        const cur = if (w.eng) |e| e.cursor else w.lone_cursor;
        const rest = name[6..];
        if (eq(u8, rest, "X")) return num.f(cur.x);
        if (eq(u8, rest, "Y")) return num.f(cur.y);
        if (eq(u8, rest, "Image")) return .{ .string = w.cursor.image_uri orelse "" };
        if (eq(u8, rest, "HotSpotX")) return num.f(cur.hot_x);
        if (eq(u8, rest, "HotSpotY")) return num.f(cur.hot_y);
        if (eq(u8, rest, "RegionX")) return num.f(cur.region.x);
        if (eq(u8, rest, "RegionY")) return num.f(cur.region.y);
        if (eq(u8, rest, "RegionWidth")) return num.f(cur.region.w);
        if (eq(u8, rest, "RegionHeight")) return num.f(cur.region.h);
        if (eq(u8, rest, "Enable")) return .{ .boolean = cur.enabled };
        if (eq(u8, rest, "Visible")) return .{ .boolean = cur.visible };
    }
    return null;
}

// ---- tests --------------------------------------------------------------------------------------------------------

const apps_mod = @import("../markup/apps.zig");
const memfs = @import("../memfs.zig");
const pstore = @import("../pstore.zig");

const Mem = struct {
    files: []const struct { []const u8, []const u8 },

    fn read(ctx: *anyopaque, u: []const u8) anyerror![]u8 {
        const self: *Mem = @ptrCast(@alignCast(ctx));
        for (self.files) |f| if (std.mem.eql(u8, f[0], u)) return std.testing.allocator.dupe(u8, f[1]);
        return error.FileNotFound;
    }
};

test "the Player API on a title" {
    const gpa = std.testing.allocator;
    var pl = try xpl.parse(gpa,
        \\<Playlist xmlns="http://www.dvdforum.org/2005/HDDVDVideo/Playlist" majorVersion="1" minorVersion="0">
        \\ <Configuration><StreamingBuffer size="0"/><Aperture size="1920x1080"/><MainVideoDefaultColor color="108080"/></Configuration>
        \\ <MediaAttributeList><AudioAttributeItem index="1" codec="DD+" channels="6" sampleFrequency="48"/></MediaAttributeList>
        \\ <TitleSet timeBase="60fps" defaultLanguage="en">
        \\  <Title id="t1" titleNumber="1" titleDuration="00:01:00:00" displayName="Main" onEnd="t2">
        \\   <PrimaryAudioVideoClip id="c1" titleTimeBegin="00:00:00:00" titleTimeEnd="00:00:30:00" src="file:///dvddisc/HVDVD_TS/A.MAP">
        \\    <Video track="1"/><Audio track="1" streamNumber="1" mediaAttr="1"/><Audio track="2" streamNumber="2"/><Subtitle track="1" streamNumber="1"/>
        \\   </PrimaryAudioVideoClip>
        \\   <PrimaryAudioVideoClip id="c2" titleTimeBegin="00:00:30:00" titleTimeEnd="00:01:00:00" src="file:///dvddisc/HVDVD_TS/B.MAP"><Video track="1"/><Audio track="2" streamNumber="1"/></PrimaryAudioVideoClip>
        \\   <ScheduledControlList><Event id="ev" titleTime="00:00:00:20"/></ScheduledControlList>
        \\   <ChapterList><Chapter titleTimeBegin="00:00:00:00" displayName="One"/><Chapter titleTimeBegin="00:00:01:00" displayName="Two"/></ChapterList>
        \\   <TrackNavigationList><AudioTrack track="1" langcode="en"/><AudioTrack track="2" langcode="ja:01"/><SubtitleTrack track="1" langcode="fr"/></TrackNavigationList>
        \\  </Title>
        \\  <Title id="t2" titleNumber="2" titleDuration="00:00:10:00"/>
        \\  <PlaylistApplication id="pa" src="file:///dvddisc/ADV_OBJ/m.xmf"/>
        \\ </TitleSet>
        \\</Playlist>
    );
    defer pl.deinit();
    var mem: Mem = .{ .files = &.{
        .{ "file:///dvddisc/ADV_OBJ/m.xmf", "<Application xmlns=\"http://www.dvdforum.org/2005/HDDVDVideo/Manifest\"><Region x=\"0\" y=\"0\" width=\"100\" height=\"100\"/><Script src=\"m.js\"/><Markup src=\"m.xmu\"/></Application>" },
        .{ "file:///dvddisc/ADV_OBJ/m.xmu", "<root xmlns=\"http://www.dvdforum.org/2005/ihd\"><body/></root>" },
        .{
            "file:///dvddisc/ADV_OBJ/m.js",
            \\var log = [];
            \\function rec(e) { log.push(e.type + (e.id !== undefined ? ":" + e.id : "") + (e.newValue === e.newValue && e.newValue !== undefined ? ":" + e.oldValue + ">" + e.newValue : "")); }
            \\var types = ["title_begin", "scheduled_event", "chapter", "clip_begin", "clip_end", "audio_track", "subtitle_track", "video_track", "play_state"];
            \\for (var i = 0; i < types.length; i++) { addEventListener(types[i], rec, false); }
        },
    } };
    var backend: files_mod.TestBackend = .init(gpa);
    defer backend.deinit();
    var temp: memfs.Fs = .init(gpa);
    defer temp.deinit();
    var store = try pstore.Store.init(gpa, "11111111-2222-3333-4444-555555555555".*, 3);
    defer store.deinit();
    var files: files_mod.Files = .{ .gpa = gpa, .temp = &temp, .store = &store, .backend = backend.backend() };
    // A WAV of 0.1 s.
    var wav: [44 + 9600]u8 = @splat(0);
    @memcpy(wav[0..4], "RIFF");
    @memcpy(wav[8..16], "WAVEfmt ");
    std.mem.writeInt(u32, wav[16..20], 16, .little);
    std.mem.writeInt(u32, wav[28..32], 96000, .little);
    @memcpy(wav[36..40], "data");
    std.mem.writeInt(u32, wav[40..44], 9600, .little);
    try temp.write("click.wav", &wav, 0, true);

    var e = engine.Engine.init(gpa, 1920, 1080, 60);
    defer {
        for (e.outbox.items) |cmd| switch (cmd) {
            .effect_play => |p| gpa.free(p.data),
            .load_playlist => |u| gpa.free(u),
            else => {},
        };
        e.deinit();
    }
    e.setScene(try apps_mod.Apps.create(gpa, .{ .pl = &pl, .loader = .{ .ctx = &mem, .read = Mem.read }, .menu_language = "en", .files = &files, .playlist_uri = "file:///dvddisc/ADV_OBJ/VPLST000.XPL" }, 1920, 1080), 0);
    const s: *apps_mod.Apps = @ptrCast(@alignCast(e.scene.?.ctx));
    try e.post(.{ .title_begin = .{ .title = 0, .duration = 3600 } });
    var now: i64 = 0;
    var t: u64 = 0;
    _ = e.step(now, t);
    while (t < 70) {
        now += 16_700;
        t += 1;
        _ = e.step(now, t);
    }
    const cx = s.records.items[0].script.?.cx;
    // The scripts below run outside a tick: their commands still go to the engine.
    s.world.eng = &e;
    defer s.world.eng = null;
    try js.testing.run(cx,
        \\assertEq(log.join(","), "title_begin:t1,chapter:NaN>0,clip_begin:c1,video_track:NaN>1,audio_track:NaN>1,subtitle_track:NaN>1,scheduled_event:ev,chapter:0>1");
        \\assertEq(Player.majorVersion, 1); assertEq(Player.menuLanguage, "en"); assertEq(Player.playlist.location, "file:///dvddisc/ADV_OBJ/VPLST000.XPL");
        \\var pl = Player.playlist; var t1 = pl.titles.t1;
        \\assertEq(pl.currentTitle, t1, "same object"); assertEq(t1.attributes.displayName, "Main"); assertEq(t1.attributes.onEnd, "t2");
        \\assertEq(t1.chapters.length, 2); assertEq(pl.currentChapter.number, 1, "from 0"); assertEq(pl.titles.t2.chapters.length, 1, "no ChapterList: one chapter"); assertEq(pl.titles.t2.chapters[0].number, 0); assertEq(pl.currentChapter.attributes.displayName, "Two");
        \\assertEq(t1.elapsedTime, "00:00:01:10"); assertEq(pl.titles.t2.elapsedTime, undefined);
        \\assertEq(t1.audioTracks.length, 2); assertEq(t1.audioTracks[1].languageCode, "ja"); assertEq(t1.audioTracks[1].languageCodeExtension, 1);
        \\assertEq(t1.audioTracks[0].getMediaAttribute("00:00:00:00", "sampleFrequency"), "48");
        \\assertThrows(function () { t1.audioTracks[0].getMediaAttribute("00:00:00:00", "nothing"); }, "HDDVD_E_ARGUMENT");
        \\// Track selection (Algorithm A1).
        \\var tr = Player.track; assertEq(tr.currentAudioTrackNumber, 1);
        \\tr.selectAudioTrackNumber(2); assertEq(tr.currentAudioTrackNumber, 2); assertEq(tr.selectedAudioLanguageCode, "ja");
        \\assertThrows(function () { tr.selectAudioTrackNumber(5); }, "HDDVD_E_ARGUMENT");
        \\tr.selectAudioLanguage("en", 0); assertEq(tr.currentAudioTrackNumber, 1); assertEq(tr.selectedAudioTrackNumber, 1);
        \\// The play state.
        \\pl.pause(); assertEq(pl.playState, pl.PLAYSTATE_PAUSE); assertEq(pl.playSpeed, NaN);
        \\assertThrows(function () { pl.fastForward(0); }, "HDDVD_E_ARGUMENT"); assertEq(pl.fastForwardSpeed.length, 0);
        \\assertThrows(function () { pl.slowForward(0); }, "HDDVD_E_NOTSUPPORTED");
        \\assertThrows(function () { pl.stepForward(); }, "HDDVD_E_NOTSUPPORTED");
        \\// Jumps and the bookmark.
        \\assertThrows(function () { t1.jump("00:02:00:00", false); }, "HDDVD_E_ARGUMENT");
        \\t1.jump("00:00:10:00", true); assertEq(Player.bookmark.title, t1); assertEq(Player.bookmark.elapsedTime, "00:00:01:10");
        \\assertThrows(function () { Player.bookmark.elapsedTime = "00:05:00:00"; }, "HDDVD_E_ARGUMENT");
        \\// Video and audio.
        \\var sc = Player.createVideoScale(1, 2); assertEq(sc.denominator, 2);
        \\assertThrows(function () { Player.createVideoScale(0, 2); }, "HDDVD_E_ARGUMENT");
        \\assertThrows(function () { Player.video.sub.changeLayout(0, 0, sc, 0, 0, 960, 540, "00:00:01:00"); }, "HDDVD_E_INVALIDCALL");
        \\pl.play(); Player.video.sub.changeLayout(10, 20, sc, 0, 0, 960, 540, "00:00:00:30"); assert(Player.video.sub.changing);
        \\assertThrows(function () { Player.video.sub.changeLayout(1, 0, sc, 0, 0, 960, 540, "00:00:00:00"); }, "HDDVD_E_INVALIDCALL");
        \\Player.video.sub.alpha = 128; assertEq(Player.video.sub.alpha, 128);
        \\Player.video.main.setOuterFrameColor(16, 128, 128); assertThrows(function () { Player.video.main.setOuterFrameColor(0, 0, 0); }, "HDDVD_E_ARGUMENT");
        \\assertThrows(function () { Player.audio.sub.setMixing(0, 0, 255, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0); }, "HDDVD_E_ARGUMENT");
        \\Player.audio.main.setVolumes(255, 255, 0, 255, 255, 255, 255, 255); assertEq(Player.audio.main.channels.center, 0);
        \\Player.audio.sub.setMixing(0, 0, 255, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
        \\assertEq(Player.audio.sub.channels.left.mix.center, 255); assertEq(Player.audio.main.channels.left, 255);
        \\assertThrows(function () { Player.audio.main.setVolumes(255, 255, 255, 255, 255, 255, 255, 255); }, "HDDVD_E_ARGUMENT");
        \\var fx; Player.audio.effect.play("file:///filecache/click.wav", 1, function (st) { fx = st; });
        \\assert(Player.audio.effect.playing); assertThrows(function () { Player.audio.effect.play("x", 0, null); }, "HDDVD_E_ARGUMENT");
        \\var gp = Player.generalParameters; assertEq(gp.availableNumber, 64); gp.setValue("k", "v"); assertEq(gp.getValue("k"), "v"); assertEq(gp.availableNumber, 63);
        \\gp.setValue("k", undefined); assertEq(gp.getValue("k"), undefined);
        \\var scp = Player.standardContentPlayer; scp.setGPRM(3, 7); assertEq(scp.getGPRM(3), 7); assertThrows(function () { scp.setSPRM(0, 1); }, "HDDVD_E_ARGUMENT");
        \\assertThrows(function () { pl.pause(); scp.play(1, 1); }, "HDDVD_E_INVALIDCALL"); pl.play();
        \\assertEq(Player.capabilities.audio.main.ddplus, 2); assertEq(Player.capabilities.playback.slowForward, false); assertEq(Player.capabilities.audio.hdmi, null);
        \\assertEq(Player.secondaryVideoPlayer.playState, 3);
        \\Player.subtitle.visible = false; assertEq(Player.subtitle.visible, false);
        \\Player.menuLanguage = "ja"; assertEq(Player.menuLanguage, "ja");
    , "player.js");
    while (t < 110) {
        now += 16_700;
        t += 1;
        _ = e.step(now, t);
    }
    s.world.eng = &e;
    try js.testing.run(cx,
        \\assertEq(fx, Player.FINISHED); assert(!Player.audio.effect.playing); assert(!Player.video.sub.changing); assertEq(Player.video.sub.x, 10);
        \\assertEq(log.slice(8).join(","), "audio_track:1>2,audio_track:2>1");
        \\Player.playlist.pause();
    , "player2.js");
    // A pause and a play in the same tick change nothing; across ticks, each is a play_state event.
    for (0..2) |_| {
        now += 16_700;
        t += 1;
        _ = e.step(now, t);
    }
    s.world.eng = &e;
    try js.testing.run(cx, "Player.playlist.play();", "player3.js");
    for (0..2) |_| {
        now += 16_700;
        t += 1;
        _ = e.step(now, t);
    }
    s.world.eng = &e;
    try js.testing.run(cx,
        \\assertEq(log.slice(10).join(","), "play_state:1>2,play_state:2>1");
    , "player4.js");
    // What the demux was asked to do.
    var jumps: u32 = 0;
    var pauses: u32 = 0;
    for (e.outbox.items) |cmd| switch (cmd) {
        .jump_title => |j| {
            jumps += 1;
            try std.testing.expectEqual(@as(u64, 600), j.time);
        },
        .pause => pauses += 1,
        else => {},
    };
    try std.testing.expectEqual(@as(u32, 1), jumps);
    try std.testing.expect(pauses >= 2);
    // A jump to another title from a pause plays it (Z.10.13.3 step 10): VLC is resumed before the jump.
    for (e.outbox.items) |cmd| switch (cmd) {
        .effect_play => |p| gpa.free(p.data),
        .load_playlist => |u| gpa.free(u),
        else => {},
    };
    e.outbox.clearRetainingCapacity();
    s.world.eng = &e;
    try js.testing.run(cx,
        \\var pl = Player.playlist; pl.pause(); pl.titles.t1.jump("00:00:02:00", false); assertEq(pl.playState, pl.PLAYSTATE_PAUSE, "same title");
        \\pl.titles.t2.jump("00:00:00:00", false); assertEq(pl.playState, pl.PLAYSTATE_PLAY);
    , "player5.js");
    const out = e.outbox.items;
    try std.testing.expectEqual(@as(usize, 4), out.len);
    try std.testing.expectEqual(true, out[0].pause);
    try std.testing.expectEqual(@as(u16, 0), out[1].jump_title.title);
    try std.testing.expectEqual(false, out[2].pause);
    try std.testing.expectEqual(@as(u16, 1), out[3].jump_title.title);
}
