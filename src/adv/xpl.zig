//! The Advanced Content Playlist (ADV_OBJ/VPLST###.XPL, HD DVD Vol. 3 §6.2.3): titles on the Title Timeline,
//! their clips and track assignments, chapters, scheduled controls, applications and resources.
//! No VLC dependency.
//!
//! Times are kept in frames of the TitleSet's timeBase. "60fps" counts 60 non-drop frames per second at
//! 60000/1001 Hz; "50fps" is 50 Hz exactly.

const std = @import("std");
const dom = @import("dom.zig");

pub const ns = "http://www.dvdforum.org/2005/HDDVDVideo/Playlist";

pub const Error = error{ BadPlaylist, OutOfMemory };

pub const TimeBase = enum(u8) {
    fps60 = 60,
    fps50 = 50,

    pub fn fps(t: TimeBase) u64 {
        return @intFromEnum(t);
    }

    /// Frames to microseconds.
    pub fn us(t: TimeBase, f: u64) i64 {
        return @intCast(switch (t) {
            .fps60 => f * 50050 / 3, // 1001/60 ms per frame
            .fps50 => f * 20000,
        });
    }

    /// Microseconds to frames (rounded down).
    pub fn frames(t: TimeBase, t_us: i64) u64 {
        const u: u64 = @intCast(@max(t_us, 0));
        return switch (t) {
            .fps60 => u * 3 / 50050,
            .fps50 => u / 20000,
        };
    }

    /// Frames to 90 kHz ticks.
    pub fn ticks90k(t: TimeBase, f: u64) u64 {
        return switch (t) {
            .fps60 => f * 3003 / 2,
            .fps50 => f * 1800,
        };
    }
};

/// Parses "HH:MM:SS:FF" into frames.
pub fn parseTime(s: []const u8, tb: TimeBase) ?u64 {
    var parts: [4]u64 = undefined;
    var it = std.mem.splitScalar(u8, std.mem.trim(u8, s, " \t\r\n"), ':');
    var n: usize = 0;
    while (it.next()) |p| {
        if (n == 4) return null;
        parts[n] = std.fmt.parseInt(u64, p, 10) catch return null;
        n += 1;
    }
    if (n != 4 or parts[1] >= 60 or parts[2] >= 60 or parts[3] >= tb.fps()) return null;
    return ((parts[0] * 60 + parts[1]) * 60 + parts[2]) * tb.fps() + parts[3];
}

pub const DataSource = enum { disc, p_storage, network, file_cache };

pub const ClipKind = enum { primary, substitute_av, substitute_audio, secondary_av };

pub const VideoTrack = struct { track: u8, angle: u8 = 1, media_attr: u8 = 1 };
pub const AudioTrack = struct { track: u8, stream: u8 = 1, media_attr: u8 = 1, description: []const u8 = "" };
pub const SubtitleTrack = struct { track: u8, stream: u8 = 1, media_attr: u8 = 1, description: []const u8 = "" };
pub const SubVideo = struct { track: u8 = 1, media_attr: u8 = 1 };
pub const SubAudio = struct { track: u8, stream: u8 = 1, media_attr: u8 = 1 };

pub const Clip = struct {
    kind: ClipKind,
    id: []const u8 = "",
    /// The TMAP's URI.
    src: []const u8,
    data_source: DataSource = .disc,
    title_begin: u64,
    title_end: u64,
    clip_begin: u64 = 0,
    seamless: bool = false,
    /// Sync of Secondary/Substitute clips: hard, soft or none.
    sync: Sync = .hard,
    preload: ?u64 = null,
    no_cache: bool = false,
    description: []const u8 = "",
    video: []VideoTrack = &.{},
    audio: []AudioTrack = &.{},
    subtitle: []SubtitleTrack = &.{},
    sub_video: ?SubVideo = null,
    sub_audio: []SubAudio = &.{},
    network_sources: [][]const u8 = &.{},

    pub fn duration(c: Clip) u64 {
        return c.title_end -| c.title_begin;
    }
};

pub const Sync = enum { hard, soft, none };

pub const Resource = struct {
    src: []const u8,
    size: u64 = 0,
    priority: u32 = 0,
    /// ADV_PCK id it is multiplexed under, or null if loaded from its source.
    multiplexed: ?u32 = null,
    loading_begin: ?u64 = null,
    no_cache: bool = false,
    description: []const u8 = "",
};

pub const AppSegment = struct {
    id: []const u8 = "",
    /// The manifest's URI.
    src: []const u8,
    title_begin: u64 = 0,
    title_end: ?u64 = null,
    sync: Sync = .hard,
    z_order: u32 = 0,
    language: []const u8 = "",
    app_block: ?u32 = null,
    group: ?u32 = null,
    autorun: bool = true,
    description: []const u8 = "",
    resources: []Resource = &.{},
    /// An AdvancedSubtitleSegment (renders to the sub-picture plane) rather than an ApplicationSegment.
    subtitle: bool = false,
    subtitle_tracks: []SubtitleTrack = &.{},
};

pub const PlaylistApp = struct {
    id: []const u8 = "",
    src: []const u8,
    language: []const u8 = "",
    description: []const u8 = "",
    resources: []Resource = &.{},
};

pub const Scheduled = struct {
    kind: enum { pause_at, event },
    id: []const u8 = "",
    time: u64,
};

pub const Chapter = struct { begin: u64, name: []const u8 = "" };

pub const NavTrack = struct {
    track: u8,
    langcode: []const u8 = "",
    description: []const u8 = "",
    selectable: bool = true,
    forced: bool = false,
};

pub const TitleType = enum { advanced, original, user_defined };

pub const Title = struct {
    id: []const u8 = "",
    number: u32 = 0,
    type: TitleType = .advanced,
    selectable: bool = true,
    tick_divisor: u32 = 1,
    duration: u64,
    parental_level: []const u8 = "",
    /// id of the Title to play after this one, or "" (stop).
    on_end: []const u8 = "",
    display_name: []const u8 = "",
    description: []const u8 = "",
    clips: []Clip = &.{},
    apps: []AppSegment = &.{},
    resources: []Resource = &.{},
    scheduled: []Scheduled = &.{},
    chapters: []Chapter = &.{},
    video_nav: []NavTrack = &.{},
    audio_nav: []NavTrack = &.{},
    subtitle_nav: []NavTrack = &.{},

    /// The clip of `kind` covering title time `t` (the last one if `t` is at or past the end).
    pub fn clipAt(t: *const Title, kind: ClipKind, time: u64) ?*const Clip {
        for (t.clips) |*c| if (c.kind == kind and time >= c.title_begin and time < c.title_end) return c;
        return null;
    }

    pub fn audioNav(t: *const Title, track: u8) ?NavTrack {
        for (t.audio_nav) |n| if (n.track == track) return n;
        return null;
    }

    pub fn subtitleNav(t: *const Title, track: u8) ?NavTrack {
        for (t.subtitle_nav) |n| if (n.track == track) return n;
        return null;
    }

    /// Chapter number (1-based) at `time`, or 0 when the title has none.
    pub fn chapterAt(t: *const Title, time: u64) usize {
        var n: usize = 0;
        for (t.chapters, 1..) |c, i| {
            if (c.begin <= time) n = i;
        }
        return n;
    }
};

pub const MediaAttr = struct { index: u8, codec: []const u8 = "", channels: u8 = 0 };

pub const Playlist = struct {
    arena: std.heap.ArenaAllocator,
    display_name: []const u8 = "",
    interoperable: bool = false,
    aperture_w: u16 = 1920,
    aperture_h: u16 = 1080,
    /// MainVideoDefaultColor: 0xYYCbCr.
    default_color: u24 = 0x108080,
    streaming_buffer_kb: u32 = 0,
    network_timeout_ms: ?u32 = null,
    time_base: TimeBase = .fps60,
    tick_base: u8 = 60,
    default_language: []const u8 = "",
    first_play: ?Title = null,
    titles: []Title = &.{},
    apps: []PlaylistApp = &.{},
    audio_attrs: []MediaAttr = &.{},
    video_attrs: []MediaAttr = &.{},
    subpicture_attrs: []MediaAttr = &.{},

    pub fn deinit(p: *Playlist) void {
        p.arena.deinit();
    }

    pub fn titleById(p: *const Playlist, id: []const u8) ?usize {
        for (p.titles, 0..) |t, i| if (std.mem.eql(u8, t.id, id)) return i;
        return null;
    }

    pub fn titleByNumber(p: *const Playlist, n: u32) ?usize {
        for (p.titles, 0..) |t, i| if (t.number == n) return i;
        return null;
    }
};

pub fn parse(gpa: std.mem.Allocator, bytes: []const u8) Error!Playlist {
    const doc = dom.parse(gpa, bytes, null) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.BadPlaylist,
    };
    defer doc.destroy();
    return fromDom(gpa, doc.root().?);
}

pub fn fromDom(gpa: std.mem.Allocator, root: *const dom.Node) Error!Playlist {
    if (!root.is(ns, "Playlist")) return error.BadPlaylist;
    var pl: Playlist = .{ .arena = .init(gpa) };
    errdefer pl.deinit();
    var b: Builder = .{ .a = pl.arena.allocator() };
    const a = b.a;
    pl.display_name = try b.str(root.attr("displayName"));
    pl.interoperable = eq(root.attr("type"), "Interoperable");

    if (root.child(ns, "Configuration")) |cfg| {
        if (cfg.child(ns, "StreamingBuffer")) |e| pl.streaming_buffer_kb = int(u32, e.attr("size")) orelse 0;
        if (cfg.child(ns, "Aperture")) |e| if (e.attr("size")) |s| {
            if (std.mem.eql(u8, s, "1280x720")) {
                pl.aperture_w = 1280;
                pl.aperture_h = 720;
            }
        };
        if (cfg.child(ns, "MainVideoDefaultColor")) |e| if (e.attr("color")) |s| {
            pl.default_color = std.fmt.parseInt(u24, s, 16) catch 0x108080;
        };
        if (cfg.child(ns, "NetworkTimeout")) |e| pl.network_timeout_ms = int(u32, e.attr("timeout"));
    }
    if (root.child(ns, "MediaAttributeList")) |list| {
        var audio: std.ArrayList(MediaAttr) = .empty;
        var video: std.ArrayList(MediaAttr) = .empty;
        var sp: std.ArrayList(MediaAttr) = .empty;
        var c = list.firstElement();
        while (c) |e| : (c = e.nextElement()) {
            const m: MediaAttr = .{ .index = int(u8, e.attr("index")) orelse 1, .codec = try b.str(e.attr("codec")), .channels = int(u8, e.attr("channels")) orelse 0 };
            if (e.is(ns, "AudioAttributeItem")) try audio.append(a, m);
            if (e.is(ns, "VideoAttributeItem")) try video.append(a, m);
            if (e.is(ns, "SubpictureAttributeItem")) try sp.append(a, m);
        }
        pl.audio_attrs = audio.items;
        pl.video_attrs = video.items;
        pl.subpicture_attrs = sp.items;
    }
    const set = root.child(ns, "TitleSet") orelse return error.BadPlaylist;
    if (eq(set.attr("timeBase"), "50fps")) pl.time_base = .fps50;
    b.tb = pl.time_base;
    if (set.attr("tickBase")) |s| pl.tick_base = if (std.mem.eql(u8, s, "24fps")) 24 else if (std.mem.eql(u8, s, "50fps")) 50 else 60;
    pl.default_language = try b.str(set.attr("defaultLanguage"));

    var titles: std.ArrayList(Title) = .empty;
    var apps: std.ArrayList(PlaylistApp) = .empty;
    var c = set.firstElement();
    while (c) |e| : (c = e.nextElement()) {
        if (e.is(ns, "FirstPlayTitle")) {
            pl.first_play = try b.title(e);
        } else if (e.is(ns, "Title")) {
            try titles.append(a, try b.title(e));
        } else if (e.is(ns, "PlaylistApplication")) {
            try apps.append(a, .{
                .id = try b.str(e.attr("id")),
                .src = try b.str(e.attr("src")),
                .language = try b.str(e.attr("language")),
                .description = try b.str(e.attr("description")),
                .resources = try b.resources(e, "PlaylistApplicationResource"),
            });
        }
    }
    pl.titles = titles.items;
    pl.apps = apps.items;
    return pl;
}

fn eq(a: ?[]const u8, b: []const u8) bool {
    return if (a) |s| std.mem.eql(u8, s, b) else false;
}

fn int(comptime T: type, s: ?[]const u8) ?T {
    return std.fmt.parseInt(T, std.mem.trim(u8, s orelse return null, " \t"), 10) catch null;
}

/// "true"/"false"; authored discs also write "1"/"0".
fn boolean(s: ?[]const u8, default: bool) bool {
    const v = s orelse return default;
    if (std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "1")) return true;
    if (std.mem.eql(u8, v, "false") or std.mem.eql(u8, v, "0")) return false;
    return default;
}

fn sync(s: ?[]const u8, default: Sync) Sync {
    const v = s orelse return default;
    if (std.mem.eql(u8, v, "hard")) return .hard;
    if (std.mem.eql(u8, v, "soft")) return .soft;
    if (std.mem.eql(u8, v, "none")) return .none;
    return default;
}

const Builder = struct {
    a: std.mem.Allocator,
    tb: TimeBase = .fps60,

    fn str(b: *Builder, s: ?[]const u8) ![]const u8 {
        return b.a.dupe(u8, s orelse return "");
    }

    fn time(b: *Builder, s: ?[]const u8) ?u64 {
        return parseTime(s orelse return null, b.tb);
    }

    fn title(b: *Builder, e: *const dom.Node) Error!Title {
        const a = b.a;
        var t: Title = .{
            .id = try b.str(e.attr("id")),
            .number = int(u32, e.attr("titleNumber")) orelse 0,
            .selectable = boolean(e.attr("selectable"), true),
            .tick_divisor = @max(1, int(u32, e.attr("tickBaseDivisor")) orelse 1),
            .duration = b.time(e.attr("titleDuration")) orelse return error.BadPlaylist,
            .parental_level = try b.str(e.attr("parentalLevel")),
            .on_end = try b.str(e.attr("onEnd")),
            .display_name = try b.str(e.attr("displayName")),
            .description = try b.str(e.attr("description")),
        };
        if (e.attr("type")) |ty| {
            if (std.mem.eql(u8, ty, "Original")) t.type = .original;
            if (std.mem.eql(u8, ty, "UserDefined")) t.type = .user_defined;
        }
        var clips: std.ArrayList(Clip) = .empty;
        var apps: std.ArrayList(AppSegment) = .empty;
        var c = e.firstElement();
        while (c) |x| : (c = x.nextElement()) {
            const kind: ?ClipKind = if (x.is(ns, "PrimaryAudioVideoClip")) .primary else if (x.is(ns, "SubstituteAudioVideoClip"))
                .substitute_av
            else if (x.is(ns, "SubstituteAudioClip"))
                .substitute_audio
            else if (x.is(ns, "SecondaryAudioVideoClip"))
                .secondary_av
            else
                null;
            if (kind) |k| {
                try clips.append(a, try b.clip(x, k));
            } else if (x.is(ns, "ApplicationSegment") or x.is(ns, "AdvancedSubtitleSegment")) {
                const is_sub = x.is(ns, "AdvancedSubtitleSegment");
                try apps.append(a, .{
                    .id = try b.str(x.attr("id")),
                    .src = try b.str(x.attr("src")),
                    .title_begin = b.time(x.attr("titleTimeBegin")) orelse 0,
                    .title_end = b.time(x.attr("titleTimeEnd")),
                    .sync = sync(x.attr("sync"), .hard),
                    .z_order = int(u32, x.attr("zOrder")) orelse 0,
                    .language = try b.str(x.attr("language")),
                    .app_block = int(u32, x.attr("appBlock")),
                    .group = int(u32, x.attr("group")),
                    .autorun = boolean(x.attr("autorun"), true),
                    .description = try b.str(x.attr("description")),
                    .resources = try b.resources(x, "ApplicationResource"),
                    .subtitle = is_sub,
                    .subtitle_tracks = if (is_sub) try b.subtitles(x) else &.{},
                });
            } else if (x.is(ns, "TitleResource")) {
                // gathered below
            } else if (x.is(ns, "ScheduledControlList")) {
                var list: std.ArrayList(Scheduled) = .empty;
                var s = x.firstElement();
                while (s) |y| : (s = y.nextElement()) {
                    const at = b.time(y.attr("titleTime")) orelse continue;
                    if (y.is(ns, "PauseAt")) try list.append(a, .{ .kind = .pause_at, .id = try b.str(y.attr("id")), .time = at });
                    if (y.is(ns, "Event")) try list.append(a, .{ .kind = .event, .id = try b.str(y.attr("id")), .time = at });
                }
                t.scheduled = list.items;
            } else if (x.is(ns, "ChapterList")) {
                var list: std.ArrayList(Chapter) = .empty;
                var s = x.firstElement();
                while (s) |y| : (s = y.nextElement()) {
                    if (!y.is(ns, "Chapter")) continue;
                    try list.append(a, .{ .begin = b.time(y.attr("titleTimeBegin")) orelse continue, .name = try b.str(y.attr("displayName")) });
                }
                std.mem.sort(Chapter, list.items, {}, struct {
                    fn lt(_: void, l: Chapter, r: Chapter) bool {
                        return l.begin < r.begin;
                    }
                }.lt);
                t.chapters = list.items;
            } else if (x.is(ns, "TrackNavigationList")) {
                var v: std.ArrayList(NavTrack) = .empty;
                var au: std.ArrayList(NavTrack) = .empty;
                var st: std.ArrayList(NavTrack) = .empty;
                var s = x.firstElement();
                while (s) |y| : (s = y.nextElement()) {
                    const n: NavTrack = .{
                        .track = int(u8, y.attr("track")) orelse continue,
                        .langcode = try b.str(y.attr("langcode")),
                        .description = try b.str(y.attr("description")),
                        .selectable = boolean(y.attr("selectable"), true),
                        .forced = boolean(y.attr("forced"), false),
                    };
                    if (y.is(ns, "VideoTrack")) try v.append(a, n);
                    if (y.is(ns, "AudioTrack")) try au.append(a, n);
                    if (y.is(ns, "SubtitleTrack")) try st.append(a, n);
                }
                t.video_nav = v.items;
                t.audio_nav = au.items;
                t.subtitle_nav = st.items;
            }
        }
        t.clips = clips.items;
        t.apps = apps.items;
        t.resources = try b.resources(e, "TitleResource");
        return t;
    }

    fn clip(b: *Builder, x: *const dom.Node, kind: ClipKind) Error!Clip {
        const a = b.a;
        var c: Clip = .{
            .kind = kind,
            .id = try b.str(x.attr("id")),
            .src = try b.str(x.attr("src")),
            .title_begin = b.time(x.attr("titleTimeBegin")) orelse return error.BadPlaylist,
            .title_end = b.time(x.attr("titleTimeEnd")) orelse return error.BadPlaylist,
            .clip_begin = b.time(x.attr("clipTimeBegin")) orelse 0,
            .seamless = boolean(x.attr("seamless"), false),
            .sync = sync(x.attr("sync"), .hard),
            .preload = b.time(x.attr("preload")),
            .no_cache = boolean(x.attr("noCache"), false),
            .description = try b.str(x.attr("description")),
        };
        if (x.attr("dataSource")) |s| {
            if (std.mem.eql(u8, s, "P-Storage")) c.data_source = .p_storage;
            if (std.mem.eql(u8, s, "Network")) c.data_source = .network;
            if (std.mem.eql(u8, s, "FileCache")) c.data_source = .file_cache;
        }
        var video: std.ArrayList(VideoTrack) = .empty;
        var audio: std.ArrayList(AudioTrack) = .empty;
        var sub_audio: std.ArrayList(SubAudio) = .empty;
        var nets: std.ArrayList([]const u8) = .empty;
        var y = x.firstElement();
        while (y) |e| : (y = e.nextElement()) {
            if (e.is(ns, "Video")) try video.append(a, .{
                .track = int(u8, e.attr("track")) orelse 1,
                .angle = int(u8, e.attr("angleNumber")) orelse 1,
                .media_attr = int(u8, e.attr("mediaAttr")) orelse 1,
            });
            if (e.is(ns, "Audio")) try audio.append(a, .{
                .track = int(u8, e.attr("track")) orelse 1,
                .stream = int(u8, e.attr("streamNumber")) orelse 1,
                .media_attr = int(u8, e.attr("mediaAttr")) orelse 1,
                .description = try b.str(e.attr("description")),
            });
            if (e.is(ns, "SubVideo")) c.sub_video = .{ .track = int(u8, e.attr("track")) orelse 1, .media_attr = int(u8, e.attr("mediaAttr")) orelse 1 };
            if (e.is(ns, "SubAudio")) try sub_audio.append(a, .{
                .track = int(u8, e.attr("track")) orelse 1,
                .stream = int(u8, e.attr("streamNumber")) orelse 1,
                .media_attr = int(u8, e.attr("mediaAttr")) orelse 1,
            });
            if (e.is(ns, "NetworkSource")) try nets.append(a, try b.str(e.attr("src")));
        }
        c.video = video.items;
        c.audio = audio.items;
        c.subtitle = try b.subtitles(x);
        c.sub_audio = sub_audio.items;
        c.network_sources = nets.items;
        return c;
    }

    fn subtitles(b: *Builder, x: *const dom.Node) Error![]SubtitleTrack {
        var list: std.ArrayList(SubtitleTrack) = .empty;
        var y = x.firstElement();
        while (y) |e| : (y = e.nextElement()) {
            if (!e.is(ns, "Subtitle")) continue;
            try list.append(b.a, .{
                .track = int(u8, e.attr("track")) orelse 1,
                .stream = int(u8, e.attr("streamNumber")) orelse 1,
                .media_attr = int(u8, e.attr("mediaAttr")) orelse 1,
                .description = try b.str(e.attr("description")),
            });
        }
        return list.items;
    }

    fn resources(b: *Builder, x: *const dom.Node, local: []const u8) Error![]Resource {
        var list: std.ArrayList(Resource) = .empty;
        var y = x.firstElement();
        while (y) |e| : (y = e.nextElement()) {
            if (!e.is(ns, local)) continue;
            const m = e.attr("multiplexed");
            try list.append(b.a, .{
                .src = try b.str(e.attr("src")),
                .size = int(u64, e.attr("size")) orelse 0,
                .priority = int(u32, e.attr("priority")) orelse 0,
                // A boolean in the spec; discs write the ADV_PCK id instead ("1", "2"…).
                .multiplexed = if (m) |v| (if (std.mem.eql(u8, v, "false")) null else if (std.mem.eql(u8, v, "true")) 0 else int(u32, v)) else null,
                .loading_begin = b.time(e.attr("loadingBegin")),
                .no_cache = boolean(e.attr("noCache"), false),
                .description = try b.str(e.attr("description")),
            });
        }
        return list.items;
    }
};

// ---- tests --------------------------------------------------------------------------------------------------

const testing = std.testing;

test "timecodes and time bases" {
    try testing.expectEqual(@as(?u64, (3600 + 7 * 60 + 42) * 60 + 40), parseTime("01:07:42:40", .fps60));
    try testing.expectEqual(null, parseTime("00:00:00:60", .fps60));
    try testing.expectEqual(@as(?u64, 49), parseTime("00:00:00:49", .fps50));
    try testing.expectEqual(null, parseTime("00:00:00", .fps60));
    try testing.expectEqual(null, parseTime("00:61:00:00", .fps60));
    // 60 "frames" at 60000/1001 Hz last 1.001 s; 90 kHz ticks match.
    try testing.expectEqual(@as(i64, 1_001_000), TimeBase.fps60.us(60));
    try testing.expectEqual(@as(u64, 90090), TimeBase.fps60.ticks90k(60));
    try testing.expectEqual(@as(u64, 60), TimeBase.fps60.frames(1_001_000));
    try testing.expectEqual(@as(i64, 1_000_000), TimeBase.fps50.us(50));
}

const test_xpl =
    \\<?xml version="1.0" encoding="utf-8"?>
    \\<Playlist xmlns="http://www.dvdforum.org/2005/HDDVDVideo/Playlist" majorVersion="1" minorVersion="0" displayName="Test">
    \\ <Configuration><StreamingBuffer size="0"/><Aperture size="1920x1080"/><MainVideoDefaultColor color="EB8080"/></Configuration>
    \\ <MediaAttributeList><AudioAttributeItem index="1" codec="DD+" channels="6"/></MediaAttributeList>
    \\ <TitleSet timeBase="60fps" tickBase="60fps" defaultLanguage="en">
    \\  <FirstPlayTitle titleDuration="00:00:10:00">
    \\   <PrimaryAudioVideoClip titleTimeBegin="00:00:00:00" titleTimeEnd="00:00:10:00" src="file:///dvddisc/HVDVD_TS/LOGO.MAP"><Video track="1"/></PrimaryAudioVideoClip>
    \\  </FirstPlayTitle>
    \\  <Title titleNumber="1" id="feature" onEnd="black" titleDuration="01:00:00:00" displayName="Feature">
    \\   <PrimaryAudioVideoClip titleTimeBegin="00:00:00:00" titleTimeEnd="00:30:00:00" src="file:///dvddisc/HVDVD_TS/A.MAP" seamless="false">
    \\    <Video track="1"/><Audio track="1" streamNumber="1"/><Audio track="2" streamNumber="3"/>
    \\    <Subtitle track="1" streamNumber="2"/><SubVideo track="1" mediaAttr="1"/><SubAudio track="1" streamNumber="1"/>
    \\   </PrimaryAudioVideoClip>
    \\   <PrimaryAudioVideoClip titleTimeBegin="00:30:00:00" clipTimeBegin="00:00:05:00" titleTimeEnd="01:00:00:00" src="file:///dvddisc/HVDVD_TS/B.MAP" seamless="true"><Video track="1"/></PrimaryAudioVideoClip>
    \\   <ApplicationSegment src="file:///dvddisc/ADV_OBJ/app.aca/app.xmf" zOrder="2" autorun="false" sync="hard">
    \\    <ApplicationResource src="file:///dvddisc/ADV_OBJ/app.aca" size="1000" priority="1" multiplexed="2"/>
    \\   </ApplicationSegment>
    \\   <ScheduledControlList><Event id="e1" titleTime="00:00:14:00"/><PauseAt titleTime="00:10:00:00"/></ScheduledControlList>
    \\   <ChapterList><Chapter titleTimeBegin="00:30:00:00" displayName="Two"/><Chapter titleTimeBegin="00:00:00:00" displayName="One"/></ChapterList>
    \\   <TrackNavigationList><AudioTrack track="1" langcode="en" description="English 5.1"/><SubtitleTrack track="1" langcode="fr" forced="true"/></TrackNavigationList>
    \\  </Title>
    \\  <Title titleNumber="2" id="black" onEnd="black" titleDuration="00:00:10:00"><PrimaryAudioVideoClip titleTimeBegin="00:00:00:00" titleTimeEnd="00:00:10:00" src="file:///dvddisc/HVDVD_TS/BLACK.MAP"/></Title>
    \\  <PlaylistApplication src="file:///dvddisc/ADV_OBJ/menu.aca/menu.xmf" language="en">
    \\   <PlaylistApplicationResource src="file:///dvddisc/ADV_OBJ/menu.aca" multiplexed="false"/>
    \\  </PlaylistApplication>
    \\ </TitleSet>
    \\</Playlist>
;

test "parse a playlist" {
    var pl = try parse(testing.allocator, test_xpl);
    defer pl.deinit();
    try testing.expectEqualStrings("Test", pl.display_name);
    try testing.expectEqual(@as(u24, 0xeb8080), pl.default_color);
    try testing.expectEqual(1, pl.audio_attrs.len);
    try testing.expectEqual(6, pl.audio_attrs[0].channels);
    try testing.expectEqual(@as(u64, 600), pl.first_play.?.duration);
    try testing.expectEqual(2, pl.titles.len);

    const t = &pl.titles[0];
    try testing.expectEqualStrings("feature", t.id);
    try testing.expectEqualStrings("black", t.on_end);
    try testing.expectEqual(2, t.clips.len);
    const c0 = t.clips[0];
    try testing.expectEqual(ClipKind.primary, c0.kind);
    try testing.expectEqual(2, c0.audio.len);
    try testing.expectEqual(3, c0.audio[1].stream);
    try testing.expectEqual(2, c0.subtitle[0].stream);
    try testing.expect(c0.sub_video != null);
    try testing.expectEqual(1, c0.sub_audio.len);
    try testing.expectEqual(@as(u64, 300), t.clips[1].clip_begin);
    try testing.expect(t.clips[1].seamless);
    try testing.expectEqual(t.clipAt(.primary, 30 * 60 * 60).?, &t.clips[1]);
    try testing.expectEqual(null, t.clipAt(.primary, t.duration));

    try testing.expectEqual(1, t.apps.len);
    try testing.expectEqual(false, t.apps[0].autorun);
    try testing.expectEqual(@as(?u32, 2), t.apps[0].resources[0].multiplexed);
    try testing.expectEqual(2, t.scheduled.len);
    try testing.expectEqual(@as(u64, 14 * 60), t.scheduled[0].time);
    try testing.expectEqualStrings("One", t.chapters[0].name); // sorted
    try testing.expectEqual(2, t.chapterAt(30 * 60 * 60));
    try testing.expectEqualStrings("English 5.1", t.audioNav(1).?.description);
    try testing.expect(t.subtitleNav(1).?.forced);

    try testing.expectEqual(@as(?usize, 1), pl.titleById("black"));
    try testing.expectEqual(@as(?usize, 0), pl.titleByNumber(1));
    try testing.expectEqual(1, pl.apps.len);
    try testing.expectEqual(null, pl.apps[0].resources[0].multiplexed);
}

test "reject documents that are not playlists" {
    try testing.expectError(error.BadPlaylist, parse(testing.allocator, "<Playlist/>"));
    try testing.expectError(error.BadPlaylist, parse(testing.allocator, "not xml"));
    try testing.expectError(error.BadPlaylist, parse(testing.allocator,
        \\<Playlist xmlns="http://www.dvdforum.org/2005/HDDVDVideo/Playlist"><TitleSet><Title/></TitleSet></Playlist>
    ));
}
