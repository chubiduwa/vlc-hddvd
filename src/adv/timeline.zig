//! The Title Timeline of the primary video (HD DVD Vol. 1 §4.3.19, Vol. 3 §6.2.3): which Primary Audio Video Clip
//! covers a title time, which part of its EVOB to read, the presentation timestamps, and what follows a clip or
//! a title. No VLC dependency.

const std = @import("std");
const xpl = @import("xpl.zig");
const tmap = @import("tmap.zig");

/// The stretch of a title covered by one clip, clipped to the title's duration.
pub const Span = struct {
    clip: *const xpl.Clip,
    index: usize,
    /// Title times (frames).
    begin: u64,
    end: u64,

    /// Clip time (frames from the start of the EVOB) of title time `t`.
    pub fn clipTime(s: Span, t: u64) u64 {
        return s.clip.clip_begin + (t -| s.clip.title_begin);
    }

    /// Title time of clip time `c`.
    pub fn titleTime(s: Span, c: u64) u64 {
        return s.clip.title_begin + (c -| s.clip.clip_begin);
    }
};

/// The primary clip covering title time `t`, or null (a gap, or past the end).
pub fn spanAt(title: *const xpl.Title, t: u64) ?Span {
    for (title.clips, 0..) |*c, i| {
        if (c.kind != .primary) continue;
        const end = @min(c.title_end, title.duration);
        if (t >= c.title_begin and t < end) return .{ .clip = c, .index = i, .begin = c.title_begin, .end = end };
    }
    return null;
}

/// The first primary clip starting at or after title time `t` (to skip a gap), or null.
pub fn spanFrom(title: *const xpl.Title, t: u64) ?Span {
    if (spanAt(title, t)) |s| return s;
    var best: ?Span = null;
    for (title.clips, 0..) |*c, i| {
        if (c.kind != .primary or c.title_begin < t or c.title_begin >= title.duration) continue;
        if (best == null or c.title_begin < best.?.begin) best = .{ .clip = c, .index = i, .begin = c.title_begin, .end = @min(c.title_end, title.duration) };
    }
    return best;
}

/// The title that follows `index` (its onEnd), or null to stop. The First Play Title (index null) is followed
/// by the title numbered 1, or the first one.
pub fn nextTitle(pl: *const xpl.Playlist, index: ?usize) ?usize {
    const i = index orelse return pl.titleByNumber(1) orelse if (pl.titles.len > 0) 0 else null;
    const on_end = pl.titles[i].on_end;
    if (on_end.len == 0) return null;
    return pl.titleById(on_end);
}

/// Sectors of the EVOB to read for title times [from, to) of a span: from the EVOBU containing `from` to the
/// end of the EVOBU containing the last frame before `to`.
pub fn sectorRange(m: *const tmap.Tmapi, s: Span, from: u64, to: u64) struct { first: u64, end: u64 } {
    const a = tmap.seek(m, s.clipTime(from) * 4);
    const last_q = (s.clipTime(to) * 4) -| 1;
    const b = tmap.seek(m, last_q);
    const end = b.sector + if (b.evobu < m.entries.len) m.entries[b.evobu].size else 0;
    return .{ .first = a.sector, .end = @max(end, a.sector) };
}

/// The 90 kHz presentation time of title time `t` in an EVOB that starts at `start_ptm`.
pub fn pts(s: Span, tb: xpl.TimeBase, start_ptm: u32, t: u64) u64 {
    return @as(u64, start_ptm) + tb.ticks90k(s.clipTime(t));
}

/// Title time (frames) of a 90 kHz timestamp in the span's EVOB.
pub fn titleTimeOfPts(s: Span, tb: xpl.TimeBase, start_ptm: u32, p: u64) u64 {
    const rel = p -| start_ptm;
    const frames = switch (tb) {
        .fps60 => rel * 2 / 3003,
        .fps50 => rel / 1800,
    };
    return s.titleTime(frames);
}

// ---- tests --------------------------------------------------------------------------------------------------

const testing = std.testing;

fn testTitle(clips: []xpl.Clip, duration: u64) xpl.Title {
    return .{ .duration = duration, .clips = clips };
}

test "clip lookup, gaps and the title duration" {
    var clips = [_]xpl.Clip{
        .{ .kind = .primary, .src = "a", .title_begin = 0, .title_end = 100 },
        .{ .kind = .secondary_av, .src = "s", .title_begin = 0, .title_end = 500 },
        .{ .kind = .primary, .src = "b", .title_begin = 150, .title_end = 400, .clip_begin = 30 },
    };
    const t = testTitle(&clips, 300);
    try testing.expectEqual(0, spanAt(&t, 0).?.index);
    try testing.expectEqual(null, spanAt(&t, 120)); // gap
    try testing.expectEqual(2, spanFrom(&t, 120).?.index);
    const s = spanAt(&t, 200).?;
    try testing.expectEqual(2, s.index);
    try testing.expectEqual(@as(u64, 300), s.end); // cut by the title duration
    try testing.expectEqual(@as(u64, 80), s.clipTime(200));
    try testing.expectEqual(@as(u64, 200), s.titleTime(80));
    try testing.expectEqual(null, spanAt(&t, 300));
    try testing.expectEqual(null, spanFrom(&t, 301));
}

test "what follows a title" {
    var titles = [_]xpl.Title{
        .{ .id = "b", .number = 2, .duration = 1, .on_end = "" },
        .{ .id = "a", .number = 1, .duration = 1, .on_end = "b" },
        .{ .id = "c", .number = 3, .duration = 1, .on_end = "missing" },
    };
    var pl: xpl.Playlist = .{ .arena = undefined, .titles = &titles };
    try testing.expectEqual(@as(?usize, 1), nextTitle(&pl, null)); // after First Play: title 1
    try testing.expectEqual(@as(?usize, 0), nextTitle(&pl, 1));
    try testing.expectEqual(null, nextTitle(&pl, 0));
    try testing.expectEqual(null, nextTitle(&pl, 2));
}

test "sector ranges and timestamps" {
    // 4 EVOBUs of 14 frames (56 quarter frames), sizes 100..103.
    var entries: [4]tmap.Entry = undefined;
    for (&entries, 0..) |*e, i| e.* = .{ .size = @intCast(100 + i), .pb_tm = 56, .first_ref = 0 };
    const m: tmap.Tmapi = .{ .evob_index = 1, .entries = &entries };
    var clip: xpl.Clip = .{ .kind = .primary, .src = "a", .title_begin = 10, .title_end = 50, .clip_begin = 5 };
    const s: Span = .{ .clip = &clip, .index = 0, .begin = 10, .end = 50 };
    // Title 10..50 = clip 5..45: EVOBUs 0 (0..14) to 3 (42..56).
    const r = sectorRange(&m, s, 10, 50);
    try testing.expectEqual(@as(u64, 0), r.first);
    try testing.expectEqual(@as(u64, 100 + 101 + 102 + 103), r.end);
    const r2 = sectorRange(&m, s, 30, 33); // clip 25..28: EVOBU 1 (14..28)
    try testing.expectEqual(@as(u64, 100), r2.first);
    try testing.expectEqual(@as(u64, 201), r2.end);

    try testing.expectEqual(@as(u64, 1000 + 5 * 3003 / 2), pts(s, .fps60, 1000, 10)); // clip time 5
    try testing.expectEqual(@as(u64, 10), titleTimeOfPts(s, .fps60, 1000, pts(s, .fps60, 1000, 10)));
    try testing.expectEqual(@as(u64, 37), titleTimeOfPts(s, .fps50, 0, pts(s, .fps50, 0, 37)));
}
