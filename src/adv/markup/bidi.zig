//! The Unicode Bidirectional Algorithm (UAX #9, with isolates and paired brackets), for the text of
//! paragraphs (HD DVD Vol. 3 §7.6.3.3.2.20 `direction`, through XSL §7.27.1): `resolve` gives each
//! character of a paragraph its embedding level (rules X1–I2), `reorder` gives a line's characters in visual
//! order (L1, L2), and `mirror` the glyph a character takes at an odd level (L4). No VLC dependency.

const std = @import("std");
const ucd = @import("ucd.zig");

pub const Class = ucd.BidiClass;

pub fn classOf(cp: u21) Class {
    const t = &ucd.bidi_class;
    var lo: usize = 0;
    var hi: usize = t.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (cp < t[mid].lo) hi = mid else if (cp > t[mid].hi) lo = mid + 1 else return t[mid].c;
    }
    return .L;
}

/// The mirrored character of `cp` (Bidi_Mirroring_Glyph), if any.
pub fn mirror(cp: u21) ?u21 {
    const t = &ucd.mirror;
    var lo: usize = 0;
    var hi: usize = t.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (cp < t[mid].cp) hi = mid else if (cp > t[mid].cp) lo = mid + 1 else return t[mid].to;
    }
    return null;
}

fn bracket(cp_in: u21) ?ucd.Bracket {
    // Canonical equivalents of the angle brackets (BD16).
    const cp: u21 = switch (cp_in) {
        0x2329 => 0x3008,
        0x232A => 0x3009,
        else => cp_in,
    };
    const t = &ucd.brackets;
    var lo: usize = 0;
    var hi: usize = t.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (cp < t[mid].cp) hi = mid else if (cp > t[mid].cp) lo = mid + 1 else return t[mid];
    }
    return null;
}

/// Characters the explicit rules remove (X9): they have no direction and are not shown.
pub fn isRemoved(c: Class) bool {
    return switch (c) {
        .RLE, .LRE, .RLO, .LRO, .PDF, .BN => true,
        else => false,
    };
}

/// Bidi formatting characters (LRM, RLM, ALM and the embedding/isolate controls): zero width, not drawn.
pub fn isControl(cp: u21) bool {
    return switch (cp) {
        0x061C, 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069 => true,
        else => false,
    };
}

fn isIsolateInit(c: Class) bool {
    return c == .LRI or c == .RLI or c == .FSI;
}

/// Neutral and isolate types (N1).
fn isNI(c: Class) bool {
    return switch (c) {
        .B, .S, .WS, .ON, .FSI, .LRI, .RLI, .PDI => true,
        else => false,
    };
}

fn dirOf(level: u8) Class {
    return if (level & 1 == 1) .R else .L;
}

const max_depth = 125;

/// The embedding levels of one paragraph of `cps` at paragraph level `para` (0: left to right, 1: right to
/// left), rules X1–I2. `levels` has one entry per code point; removed characters (X9) get their
/// neighbour's level.
pub fn resolve(gpa: std.mem.Allocator, cps: []const u21, para: u1, levels: []u8) !void {
    const n = cps.len;
    std.debug.assert(levels.len == n);
    if (n == 0) return;
    const orig = try gpa.alloc(Class, n);
    defer gpa.free(orig);
    const cls = try gpa.alloc(Class, n);
    defer gpa.free(cls);
    for (cps, orig) |cp, *c| c.* = classOf(cp);
    @memcpy(cls, orig);
    const match = try gpa.alloc(?usize, n);
    defer gpa.free(match);
    matchIsolates(orig, match);

    // X1–X8: explicit levels and directions.
    const Entry = struct { level: u8, override: ?Class, isolate: bool };
    var stack: [max_depth + 2]Entry = undefined;
    var sp: usize = 1;
    stack[0] = .{ .level = para, .override = null, .isolate = false };
    var overflow_isolate: usize = 0;
    var overflow_embedding: usize = 0;
    var valid_isolate: usize = 0;
    for (orig, 0..) |c, i| {
        const top = stack[sp - 1];
        switch (c) {
            .RLE, .LRE, .RLO, .LRO => {
                levels[i] = top.level;
                const rtl = c == .RLE or c == .RLO;
                const next: u8 = if (rtl) (top.level + 1) | 1 else (top.level + 2) & ~@as(u8, 1);
                if (next <= max_depth and overflow_isolate == 0 and overflow_embedding == 0) {
                    stack[sp] = .{ .level = next, .override = switch (c) {
                        .RLO => .R,
                        .LRO => .L,
                        else => null,
                    }, .isolate = false };
                    sp += 1;
                } else if (overflow_isolate == 0) overflow_embedding += 1;
            },
            .RLI, .LRI, .FSI => {
                levels[i] = top.level;
                if (top.override) |o| cls[i] = o;
                const rtl = if (c == .FSI) firstStrong(orig, i + 1, match[i] orelse n) == 1 else c == .RLI;
                const next: u8 = if (rtl) (top.level + 1) | 1 else (top.level + 2) & ~@as(u8, 1);
                if (next <= max_depth and overflow_isolate == 0 and overflow_embedding == 0) {
                    valid_isolate += 1;
                    stack[sp] = .{ .level = next, .override = null, .isolate = true };
                    sp += 1;
                } else overflow_isolate += 1;
            },
            .PDI => {
                if (overflow_isolate > 0) {
                    overflow_isolate -= 1;
                } else if (valid_isolate > 0) {
                    overflow_embedding = 0;
                    while (!stack[sp - 1].isolate) sp -= 1;
                    sp -= 1;
                    valid_isolate -= 1;
                }
                const t = stack[sp - 1];
                levels[i] = t.level;
                if (t.override) |o| cls[i] = o;
            },
            .PDF => {
                levels[i] = top.level;
                if (overflow_isolate > 0) {} else if (overflow_embedding > 0) {
                    overflow_embedding -= 1;
                } else if (!top.isolate and sp >= 2) sp -= 1;
            },
            .B => levels[i] = para,
            .BN => levels[i] = top.level,
            else => {
                levels[i] = top.level;
                if (top.override) |o| cls[i] = o;
            },
        }
    }

    // X10: isolating run sequences, from the level runs of what X9 keeps.
    const kept = try gpa.alloc(usize, n);
    defer gpa.free(kept);
    var nk: usize = 0;
    for (orig, 0..) |c, i| if (!isRemoved(c)) {
        kept[nk] = i;
        nk += 1;
    };
    // Each kept character's level run (index of its run).
    var runs: std.ArrayList([2]usize) = .empty; // [first, last] positions in `kept`
    defer runs.deinit(gpa);
    var k: usize = 0;
    while (k < nk) {
        var e = k;
        while (e + 1 < nk and levels[kept[e + 1]] == levels[kept[k]]) e += 1;
        try runs.append(gpa, .{ k, e });
        k = e + 1;
    }
    const run_of = try gpa.alloc(usize, n);
    defer gpa.free(run_of);
    for (runs.items, 0..) |r, ri| for (r[0]..r[1] + 1) |x| {
        run_of[kept[x]] = ri;
    };
    var seq: std.ArrayList(usize) = .empty;
    defer seq.deinit(gpa);
    for (runs.items) |r| {
        const first = kept[r[0]];
        // A run that starts with a PDI matching an initiator continues that initiator's sequence.
        if (orig[first] == .PDI and isMatched(match, first)) continue;
        seq.clearRetainingCapacity();
        var cur = r;
        while (true) {
            for (cur[0]..cur[1] + 1) |x| try seq.append(gpa, kept[x]);
            const last = kept[cur[1]];
            if (!isIsolateInit(orig[last])) break;
            const m = match[last] orelse break;
            cur = runs.items[run_of[m]];
        }
        try sequence(gpa, cps, orig, cls, levels, seq.items, para);
    }

    // Removed characters take the level of the character before them (or the paragraph's).
    var prev: u8 = para;
    for (orig, 0..) |c, i| {
        if (isRemoved(c)) levels[i] = prev else prev = levels[i];
    }
}

fn isMatched(match: []const ?usize, pdi: usize) bool {
    for (match) |m| if (m == pdi) return true;
    return false;
}

/// BD9: the PDI matching each isolate initiator.
fn matchIsolates(orig: []const Class, match: []?usize) void {
    @memset(match, null);
    for (orig, 0..) |c, i| {
        if (!isIsolateInit(c)) continue;
        var depth: usize = 1;
        var j = i + 1;
        while (j < orig.len) : (j += 1) {
            switch (orig[j]) {
                .LRI, .RLI, .FSI => depth += 1,
                .PDI => {
                    depth -= 1;
                    if (depth == 0) {
                        match[i] = j;
                        break;
                    }
                },
                .B => break,
                else => {},
            }
        }
    }
}

/// P2–P3 on `orig[from..to]`: 1 if its first strong character is R or AL, else 0 (isolates skipped).
fn firstStrong(orig: []const Class, from: usize, to: usize) u1 {
    var depth: usize = 0;
    var i = from;
    while (i < to) : (i += 1) switch (orig[i]) {
        .LRI, .RLI, .FSI => depth += 1,
        .PDI => depth -|= 1,
        .L => if (depth == 0) return 0,
        .R, .AL => if (depth == 0) return 1,
        .B => break,
        else => {},
    };
    return 0;
}

/// W1–I2 on one isolating run sequence (indices into the paragraph).
fn sequence(gpa: std.mem.Allocator, cps: []const u21, orig: []const Class, cls: []Class, levels: []u8, idx: []const usize, para: u1) !void {
    const level = levels[idx[0]];
    const first = idx[0];
    const last = idx[idx.len - 1];
    // sos and eos: the higher of this level and the neighbouring one, outside removed characters.
    const before: u8 = blk: {
        var j = first;
        while (j > 0) {
            j -= 1;
            if (!isRemoved(orig[j])) break :blk levels[j];
        }
        break :blk para;
    };
    const after: u8 = blk: {
        if (isIsolateInit(orig[last])) break :blk para;
        var j = last + 1;
        while (j < orig.len) : (j += 1) if (!isRemoved(orig[j])) break :blk levels[j];
        break :blk para;
    };
    const sos = dirOf(@max(level, before));
    const eos = dirOf(@max(level, after));
    const m = idx.len;
    const t = try gpa.alloc(Class, m);
    defer gpa.free(t);
    for (idx, t) |i, *c| c.* = cls[i];

    // W1: NSM takes the type before it (ON after an isolate initiator or PDI).
    for (0..m) |x| if (t[x] == .NSM) {
        t[x] = if (x == 0) sos else switch (t[x - 1]) {
            .LRI, .RLI, .FSI, .PDI => .ON,
            else => |p| p,
        };
    };
    // W2: EN after AL is AN. W3: AL is R.
    {
        var strong: Class = sos;
        for (t) |*c| switch (c.*) {
            .L, .R, .AL => strong = c.*,
            .EN => if (strong == .AL) {
                c.* = .AN;
            },
            else => {},
        };
        for (t) |*c| if (c.* == .AL) {
            c.* = .R;
        };
    }
    // W4: a single separator between numbers of the same kind.
    if (m >= 3) for (1..m - 1) |x| {
        if (t[x] == .ES and t[x - 1] == .EN and t[x + 1] == .EN) t[x] = .EN;
        if (t[x] == .CS and t[x - 1] == t[x + 1] and (t[x - 1] == .EN or t[x - 1] == .AN)) t[x] = t[x - 1];
    };
    // W5: terminators next to EN.
    {
        var x: usize = 0;
        while (x < m) {
            if (t[x] != .ET) {
                x += 1;
                continue;
            }
            var e = x;
            while (e < m and t[e] == .ET) e += 1;
            if ((x > 0 and t[x - 1] == .EN) or (e < m and t[e] == .EN)) @memset(t[x..e], .EN);
            x = e;
        }
    }
    // W6: what remains of separators and terminators is ON.
    for (t) |*c| switch (c.*) {
        .ES, .ET, .CS => c.* = .ON,
        else => {},
    };
    // W7: EN after L (or an L sos) is L.
    {
        var strong: Class = sos;
        for (t) |*c| switch (c.*) {
            .L, .R => strong = c.*,
            .EN => if (strong == .L) {
                c.* = .L;
            },
            else => {},
        };
    }

    // N0: paired brackets.
    try brackets(gpa, cps, orig, idx, t, level, sos);

    // N1, N2: neutrals between the same direction take it, others the embedding direction.
    {
        var x: usize = 0;
        while (x < m) {
            if (!isNI(t[x])) {
                x += 1;
                continue;
            }
            var e = x;
            while (e < m and isNI(t[e])) e += 1;
            const l = if (x == 0) sos else strongish(t[x - 1]);
            const r = if (e == m) eos else strongish(t[e]);
            @memset(t[x..e], if (l == r) l else dirOf(level));
            x = e;
        }
    }
    // I1, I2.
    for (idx, t) |i, c| {
        if (level & 1 == 0) {
            if (c == .R) levels[i] = level + 1 else if (c == .AN or c == .EN) levels[i] = level + 2;
        } else if (c == .L or c == .EN or c == .AN) levels[i] = level + 1;
        cls[i] = c;
    }
}

/// The direction a resolved type counts as for N0–N1 (numbers are R).
fn strongish(c: Class) Class {
    return switch (c) {
        .L => .L,
        .R, .EN, .AN => .R,
        else => .ON,
    };
}

/// N0: brackets pairs (BD16) of a sequence take the direction of what they enclose, or of their context.
fn brackets(gpa: std.mem.Allocator, cps: []const u21, orig: []const Class, idx: []const usize, t: []Class, level: u8, sos: Class) !void {
    const Open = struct { pair: u21, pos: usize };
    var stack: [63]Open = undefined;
    var sp: usize = 0;
    var pairs: std.ArrayList([2]usize) = .empty;
    defer pairs.deinit(gpa);
    scan: for (idx, 0..) |i, x| {
        if (t[x] != .ON) continue;
        const b = bracket(cps[i]) orelse continue;
        if (b.open) {
            if (sp == stack.len) break :scan;
            stack[sp] = .{ .pair = b.pair, .pos = x };
            sp += 1;
            continue;
        }
        const cp: u21 = switch (cps[i]) {
            0x232A => 0x3009,
            else => cps[i],
        };
        var s = sp;
        while (s > 0) {
            s -= 1;
            if (stack[s].pair == cp) {
                try pairs.append(gpa, .{ stack[s].pos, x });
                sp = s;
                break;
            }
        }
    }
    std.mem.sort([2]usize, pairs.items, {}, struct {
        fn less(_: void, a: [2]usize, b: [2]usize) bool {
            return a[0] < b[0];
        }
    }.less);
    const e = dirOf(level);
    for (pairs.items) |p| {
        var found_e = false;
        var found_o = false;
        for (t[p[0] + 1 .. p[1]]) |c| {
            const d = strongish(c);
            if (d == e) found_e = true else if (d != .ON) found_o = true;
        }
        const dir: Class = if (found_e) e else if (found_o) ctx: {
            var x = p[0];
            while (x > 0) {
                x -= 1;
                const d = strongish(t[x]);
                if (d != .ON) break :ctx if (d == e) e else d;
            }
            break :ctx if (sos == e) e else sos;
        } else continue;
        for (p) |x| {
            t[x] = dir;
            // NSMs after a bracket follow it.
            var y = x + 1;
            while (y < idx.len and orig[idx[y]] == .NSM) : (y += 1) t[y] = dir;
        }
    }
}

/// A line's characters `line_from..line_to` of a paragraph in visual order (L1, L2), as paragraph indices
/// into `out` (`line_to - line_from` entries). `levels` are the paragraph's (`resolve`); L1 is applied to a
/// copy.
pub fn reorder(gpa: std.mem.Allocator, cps: []const u21, levels: []const u8, para: u1, line_from: usize, line_to: usize, out: []usize) !void {
    const n = line_to - line_from;
    std.debug.assert(out.len == n);
    const lv = try gpa.alloc(u8, n);
    defer gpa.free(lv);
    @memcpy(lv, levels[line_from..line_to]);
    // L1: separators, and white space (and isolate controls) before them or at the line end, at the paragraph level.
    var trailing = true;
    var x = n;
    while (x > 0) {
        x -= 1;
        const c = classOf(cps[line_from + x]);
        switch (c) {
            .S, .B => {
                lv[x] = para;
                trailing = true;
            },
            .WS, .FSI, .LRI, .RLI, .PDI => if (trailing) {
                lv[x] = para;
            },
            else => if (isRemoved(c)) {
                if (trailing) lv[x] = para;
            } else {
                trailing = false;
            },
        }
    }
    for (out, 0..) |*o, i| o.* = line_from + i;
    // L2: from the highest level down to the lowest odd one, reverse every run at that level or above.
    var hi: u8 = 0;
    var lo_odd: u8 = 255;
    for (lv) |l| {
        hi = @max(hi, l);
        if (l & 1 == 1) lo_odd = @min(lo_odd, l);
    }
    if (lo_odd == 255) return;
    var level = hi;
    while (level >= lo_odd) : (level -= 1) {
        var i: usize = 0;
        while (i < n) {
            if (lv[i] < level) {
                i += 1;
                continue;
            }
            var e = i;
            while (e < n and lv[e] >= level) e += 1;
            std.mem.reverse(usize, out[i..e]);
            std.mem.reverse(u8, lv[i..e]);
            i = e;
        }
        if (level == 0) break;
    }
}

// ---- tests --------------------------------------------------------------------------------------------------

const testing = std.testing;

fn cpsOf(s: []const u8, buf: []u21) []u21 {
    var n: usize = 0;
    var it = (std.unicode.Utf8View.init(s) catch unreachable).iterator();
    while (it.nextCodepoint()) |cp| : (n += 1) buf[n] = cp;
    return buf[0..n];
}

fn visual(s: []const u8, para: u1, want_levels: []const u8, want_order: []const usize) !void {
    var buf: [64]u21 = undefined;
    const cps = cpsOf(s, &buf);
    var lv: [64]u8 = undefined;
    try resolve(testing.allocator, cps, para, lv[0..cps.len]);
    try testing.expectEqualSlices(u8, want_levels, lv[0..cps.len]);
    var out: [64]usize = undefined;
    try reorder(testing.allocator, cps, lv[0..cps.len], para, 0, cps.len, out[0..cps.len]);
    try testing.expectEqualSlices(usize, want_order, out[0..cps.len]);
}

test "bidi levels and visual order" {
    // Hebrew in a left-to-right paragraph.
    try visual("ab \u{5D0}\u{5D1} cd", 0, &.{ 0, 0, 0, 1, 1, 0, 0, 0 }, &.{ 0, 1, 2, 4, 3, 5, 6, 7 });
    // A right-to-left paragraph with numbers and Latin: "ab 12 בא" on screen.
    try visual("\u{5D0}\u{5D1} 12 ab", 1, &.{ 1, 1, 1, 2, 2, 1, 2, 2 }, &.{ 6, 7, 5, 3, 4, 2, 1, 0 });
    // Paired brackets take the direction of their Latin content and context (N0): "א a(b)" on screen.
    try visual("a(b)\u{5D0}", 1, &.{ 2, 2, 2, 2, 1 }, &.{ 4, 0, 1, 2, 3 });
    // An embedding (RLE … PDF) in a left-to-right paragraph; the controls take their neighbour's level.
    try visual("a\u{202B}1 2\u{202C}b", 0, &.{ 0, 0, 2, 1, 2, 2, 0 }, &.{ 0, 1, 4, 5, 3, 2, 6 });
    // Trailing white space at the paragraph level (L1).
    try visual("ab  ", 1, &.{ 2, 2, 1, 1 }, &.{ 3, 2, 0, 1 });
    // An isolate: its content does not affect the outside.
    try visual("\u{5D0}\u{2066}a\u{2069}1", 1, &.{ 1, 1, 2, 1, 2 }, &.{ 4, 3, 2, 1, 0 });
    try testing.expectEqual(@as(?u21, ')'), mirror('('));
    try testing.expectEqual(@as(?u21, null), mirror('a'));
    try testing.expectEqual(Class.AL, classOf(0x627));
    try testing.expectEqual(Class.L, classOf('z'));
}
