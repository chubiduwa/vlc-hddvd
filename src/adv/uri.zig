//! Content referencing (HD DVD Vol. 3 §6.2.2): URIs, their resolution against a base (RFC 3986 §5, with the
//! xml:base rule of §6.2.2), and where a "file:" URI points. No VLC dependency.
//!
//! - file:///dvddisc/…                       the disc
//! - file:///filecache/…                     the File Cache's API Managed Area ("temp", Vol. 1 §4.3.20.4)
//! - file:///required/…                      this provider's area of the Required Persistent Storage (§10.3.1)
//! - file:///additional/<base path>/…        this provider's area of an Additional Persistent Storage
//! - file:///common/required/…, file:///common/additional/<base path>/…   the common areas
//! - http://…, https://…                     a network server
//!
//! A file inside an archive is named by the archive's URI followed by the file name:
//! "file:///dvddisc/ADV_OBJ/app.aca/app.xmu" (Vol. 1 §4.3.20.4).

const std = @import("std");

/// URIs shall be shorter than this (§6.2.2).
pub const max_len = 1024;

pub const Error = error{ BadUri, OutOfMemory };

/// The components of a URI reference (RFC 3986 §3). Slices of the input.
pub const Parts = struct {
    scheme: ?[]const u8 = null,
    authority: ?[]const u8 = null,
    path: []const u8 = "",
    query: ?[]const u8 = null,
    fragment: ?[]const u8 = null,

    pub fn parse(s: []const u8) Parts {
        var p: Parts = .{};
        var rest = s;
        if (std.mem.indexOfScalar(u8, rest, '#')) |i| {
            p.fragment = rest[i + 1 ..];
            rest = rest[0..i];
        }
        if (std.mem.indexOfScalar(u8, rest, '?')) |i| {
            p.query = rest[i + 1 ..];
            rest = rest[0..i];
        }
        // A scheme is letters, digits, "+", "-", "." before the first ":", starting with a letter.
        if (std.mem.indexOfScalar(u8, rest, ':')) |i| {
            const sch = rest[0..i];
            if (i > 0 and std.ascii.isAlphabetic(sch[0]) and for (sch) |c| {
                if (!std.ascii.isAlphanumeric(c) and c != '+' and c != '-' and c != '.') break false;
            } else true) {
                p.scheme = sch;
                rest = rest[i + 1 ..];
            }
        }
        if (std.mem.startsWith(u8, rest, "//")) {
            const end = std.mem.indexOfScalarPos(u8, rest, 2, '/') orelse rest.len;
            p.authority = rest[2..end];
            rest = rest[end..];
        }
        p.path = rest;
        return p;
    }

    fn write(p: Parts, gpa: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
        if (p.scheme) |s| {
            try out.appendSlice(gpa, s);
            try out.append(gpa, ':');
        }
        if (p.authority) |a| {
            try out.appendSlice(gpa, "//");
            try out.appendSlice(gpa, a);
        }
        try out.appendSlice(gpa, p.path);
        if (p.query) |q| {
            try out.append(gpa, '?');
            try out.appendSlice(gpa, q);
        }
        if (p.fragment) |f| {
            try out.append(gpa, '#');
            try out.appendSlice(gpa, f);
        }
    }
};

pub fn isAbsolute(s: []const u8) bool {
    return Parts.parse(s).scheme != null;
}

/// RFC 3986 §5.2.4: removes "." and ".." segments.
fn removeDots(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var in = path;
    while (in.len > 0) {
        if (std.mem.startsWith(u8, in, "../")) {
            in = in[3..];
        } else if (std.mem.startsWith(u8, in, "./")) {
            in = in[2..];
        } else if (std.mem.startsWith(u8, in, "/./")) {
            in = in[2..];
        } else if (std.mem.eql(u8, in, "/.")) {
            in = "/";
        } else if (std.mem.startsWith(u8, in, "/../") or std.mem.eql(u8, in, "/..")) {
            in = if (in.len == 3) "/" else in[3..];
            const cut = std.mem.lastIndexOfScalar(u8, out.items, '/') orelse 0;
            out.shrinkRetainingCapacity(cut);
        } else if (std.mem.eql(u8, in, ".") or std.mem.eql(u8, in, "..")) {
            in = "";
        } else {
            const start: usize = if (in[0] == '/') 1 else 0;
            const end = std.mem.indexOfScalarPos(u8, in, start, '/') orelse in.len;
            try out.appendSlice(gpa, in[0..end]);
            in = in[end..];
        }
    }
    return out.toOwnedSlice(gpa);
}

/// Resolves `ref` against the absolute URI `base` (RFC 3986 §5.2.2). Caller frees.
pub fn resolve(gpa: std.mem.Allocator, base: []const u8, ref: []const u8) Error![]u8 {
    const r = Parts.parse(ref);
    const b = Parts.parse(base);
    var t: Parts = .{ .fragment = r.fragment };
    var owned: ?[]u8 = null;
    defer if (owned) |o| gpa.free(o);
    if (r.scheme != null) {
        t.scheme = r.scheme;
        t.authority = r.authority;
        owned = try removeDots(gpa, r.path);
        t.path = owned.?;
        t.query = r.query;
    } else {
        if (b.scheme == null) return error.BadUri;
        t.scheme = b.scheme;
        if (r.authority != null) {
            t.authority = r.authority;
            owned = try removeDots(gpa, r.path);
            t.path = owned.?;
            t.query = r.query;
        } else {
            t.authority = b.authority;
            if (r.path.len == 0) {
                t.path = b.path;
                t.query = r.query orelse b.query;
            } else {
                const merged = if (r.path[0] == '/')
                    try gpa.dupe(u8, r.path)
                else if (b.authority != null and b.path.len == 0)
                    try std.mem.concat(gpa, u8, &.{ "/", r.path })
                else blk: {
                    const cut = if (std.mem.lastIndexOfScalar(u8, b.path, '/')) |i| i + 1 else 0;
                    break :blk try std.mem.concat(gpa, u8, &.{ b.path[0..cut], r.path });
                };
                defer gpa.free(merged);
                owned = try removeDots(gpa, merged);
                t.path = owned.?;
                t.query = r.query;
            }
        }
    }
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try t.write(gpa, &out);
    return out.toOwnedSlice(gpa);
}

/// The base URI an xml:base value gives (§6.2.2): resolved against the document's own base, with everything after
/// its last "/" ignored. Caller frees.
pub fn xmlBase(gpa: std.mem.Allocator, doc_base: []const u8, value: []const u8) Error![]u8 {
    const abs = try resolve(gpa, doc_base, value);
    const p = Parts.parse(abs);
    if (p.query != null or p.fragment != null or std.mem.endsWith(u8, abs, "/")) return abs;
    defer gpa.free(abs);
    const cut = (std.mem.lastIndexOfScalar(u8, abs, '/') orelse return error.BadUri) + 1;
    return gpa.dupe(u8, abs[0..cut]);
}

/// Checks the content rules of §6.2.2: shorter than 1024 and no ".." segment.
pub fn valid(s: []const u8) bool {
    if (s.len >= max_len) return false;
    var it = std.mem.splitScalar(u8, Parts.parse(s).path, '/');
    while (it.next()) |seg| if (std.mem.eql(u8, seg, "..")) return false;
    return true;
}

/// Decodes %XX escapes (RFC 3986 §2.1). Caller frees.
pub fn percentDecode(gpa: std.mem.Allocator, s: []const u8) error{OutOfMemory}![]u8 {
    const out = try gpa.alloc(u8, s.len);
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (n += 1) {
        if (s[i] == '%' and i + 2 < s.len) {
            if (std.fmt.parseInt(u8, s[i + 1 .. i + 3], 16)) |v| {
                out[n] = v;
                i += 3;
                continue;
            } else |_| {}
        }
        out[n] = s[i];
        i += 1;
    }
    return gpa.realloc(out, n) catch out[0..n];
}

// ---- where a URI points -------------------------------------------------------------------------------------

pub const Area = enum {
    disc,
    /// The File Cache's API Managed Area.
    filecache,
    required,
    additional,
    common_required,
    common_additional,
    network,
};

/// What a URI designates. `path` is relative to the area's root, still percent-encoded, without a leading "/".
pub const Location = struct {
    area: Area,
    /// The Base Path of an Additional Persistent Storage device.
    base_path: []const u8 = "",
    path: []const u8 = "",
};

/// Where `s` points, or null for an unsupported scheme or area.
pub fn locate(s: []const u8) ?Location {
    const p = Parts.parse(s);
    const scheme = p.scheme orelse return null;
    if (std.ascii.eqlIgnoreCase(scheme, "http") or std.ascii.eqlIgnoreCase(scheme, "https")) return .{ .area = .network, .path = s };
    if (!std.ascii.eqlIgnoreCase(scheme, "file")) return null;
    // "file:///dvddisc/x": empty authority. Accept "file:/dvddisc/x" too.
    if (p.authority) |a| if (a.len > 0 and !std.ascii.eqlIgnoreCase(a, "localhost")) return null;
    const path = std.mem.trimStart(u8, p.path, "/");
    const first, const rest = split1(path);
    if (std.mem.eql(u8, first, "dvddisc")) return .{ .area = .disc, .path = rest };
    if (std.mem.eql(u8, first, "filecache")) return .{ .area = .filecache, .path = rest };
    if (std.mem.eql(u8, first, "required")) return .{ .area = .required, .path = rest };
    if (std.mem.eql(u8, first, "additional")) {
        const bp, const r2 = split1(rest);
        if (bp.len == 0) return null;
        return .{ .area = .additional, .base_path = bp, .path = r2 };
    }
    if (std.mem.eql(u8, first, "common")) {
        const second, const r2 = split1(rest);
        if (std.mem.eql(u8, second, "required")) return .{ .area = .common_required, .path = r2 };
        if (std.mem.eql(u8, second, "additional")) {
            const bp, const r3 = split1(r2);
            if (bp.len == 0) return null;
            return .{ .area = .common_additional, .base_path = bp, .path = r3 };
        }
    }
    return null;
}

/// The first segment of `path` and what follows its "/".
fn split1(path: []const u8) struct { []const u8, []const u8 } {
    const i = std.mem.indexOfScalar(u8, path, '/') orelse return .{ path, "" };
    return .{ path[0..i], path[i + 1 ..] };
}

/// A URI inside an archive: the archive's URI and the file name in it.
pub const Member = struct { archive: []const u8, name: []const u8 };

/// Splits "…/x.aca/name" at the first path segment ending in ".aca" (case-insensitive) that is followed by more
/// path. Null if `s` names no archive member.
pub fn archiveMember(s: []const u8) ?Member {
    const p = Parts.parse(s);
    const off = @intFromPtr(p.path.ptr) - @intFromPtr(s.ptr);
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, p.path, i, '/')) |slash| : (i = slash + 1) {
        if (slash >= 4 and std.ascii.endsWithIgnoreCase(p.path[0..slash], ".aca") and slash + 1 < p.path.len) {
            return .{ .archive = s[0 .. off + slash], .name = p.path[slash + 1 ..] };
        }
    }
    return null;
}

/// The last path segment.
pub fn fileName(s: []const u8) []const u8 {
    const path = Parts.parse(s).path;
    return path[if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| i + 1 else 0..];
}

/// Equality as the player compares URIs: scheme and host ignore case, the rest is exact.
pub fn eql(a: []const u8, b: []const u8) bool {
    const pa = Parts.parse(a);
    const pb = Parts.parse(b);
    if ((pa.scheme == null) != (pb.scheme == null)) return false;
    if (pa.scheme) |s| if (!std.ascii.eqlIgnoreCase(s, pb.scheme.?)) return false;
    if ((pa.authority == null) != (pb.authority == null)) return false;
    if (pa.authority) |s| if (!std.ascii.eqlIgnoreCase(s, pb.authority.?)) return false;
    return std.mem.eql(u8, a[a.len - pa.path.len - tailLen(pa) ..], b[b.len - pb.path.len - tailLen(pb) ..]);
}

fn tailLen(p: Parts) usize {
    return (if (p.query) |q| q.len + 1 else 0) + (if (p.fragment) |f| f.len + 1 else 0);
}

// ---- tests --------------------------------------------------------------------------------------------------

const testing = std.testing;

fn expectResolve(base: []const u8, ref: []const u8, want: []const u8) !void {
    const got = try resolve(testing.allocator, base, ref);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(want, got);
}

test "RFC 3986 reference resolution" {
    // RFC 3986 §5.4 examples.
    const b = "http://a/b/c/d;p?q";
    try expectResolve(b, "g:h", "g:h");
    try expectResolve(b, "g", "http://a/b/c/g");
    try expectResolve(b, "./g", "http://a/b/c/g");
    try expectResolve(b, "g/", "http://a/b/c/g/");
    try expectResolve(b, "/g", "http://a/g");
    try expectResolve(b, "//g", "http://g");
    try expectResolve(b, "?y", "http://a/b/c/d;p?y");
    try expectResolve(b, "g?y", "http://a/b/c/g?y");
    try expectResolve(b, "#s", "http://a/b/c/d;p?q#s");
    try expectResolve(b, "", "http://a/b/c/d;p?q");
    try expectResolve(b, ".", "http://a/b/c/");
    try expectResolve(b, "..", "http://a/b/");
    try expectResolve(b, "../g", "http://a/b/g");
    try expectResolve(b, "../../../g", "http://a/g");
    try expectResolve(b, "g;x=1/../y", "http://a/b/c/y");
    // Disc URIs: relative to a manifest inside an archive.
    try expectResolve("file:///dvddisc/ADV_OBJ/menu.aca/menu.xmf", "menu.xmu", "file:///dvddisc/ADV_OBJ/menu.aca/menu.xmu");
    try expectResolve("file:///dvddisc/ADV_OBJ/a.xmf", "/x.png", "file:///x.png");
}

test "xml:base keeps everything up to the last slash" {
    const gpa = testing.allocator;
    const a = try xmlBase(gpa, "file:///dvddisc/ADV_OBJ/a.xmf", "http://www.foo.org/folder");
    defer gpa.free(a);
    try testing.expectEqualStrings("http://www.foo.org/", a);
    const c = try xmlBase(gpa, "file:///dvddisc/ADV_OBJ/a.xmf", "sub/");
    defer gpa.free(c);
    try testing.expectEqualStrings("file:///dvddisc/ADV_OBJ/sub/", c);
}

test "locations" {
    const d = locate("file:///dvddisc/ADV_OBJ/menu.aca").?;
    try testing.expectEqual(Area.disc, d.area);
    try testing.expectEqualStrings("ADV_OBJ/menu.aca", d.path);
    try testing.expectEqual(Area.filecache, locate("file:///filecache/x/y.xml").?.area);
    try testing.expectEqualStrings("x/y.xml", locate("FILE:///filecache/x/y.xml").?.path);
    const ad = locate("file:///additional/usb1/BE209997-0C6C-11D3-97CF-00C04F8EEC55/data.txt").?;
    try testing.expectEqual(Area.additional, ad.area);
    try testing.expectEqualStrings("usb1", ad.base_path);
    try testing.expectEqualStrings("BE209997-0C6C-11D3-97CF-00C04F8EEC55/data.txt", ad.path);
    try testing.expectEqual(Area.common_required, locate("file:///common/required/foo/bar.txt").?.area);
    const ca = locate("file:///common/additional/usb1/foo/bar.txt").?;
    try testing.expectEqual(Area.common_additional, ca.area);
    try testing.expectEqualStrings("foo/bar.txt", ca.path);
    try testing.expectEqual(Area.network, locate("https://example.com/a.aca").?.area);
    try testing.expectEqual(null, locate("file:///elsewhere/a"));
    try testing.expectEqual(null, locate("file://host/dvddisc/a"));
    try testing.expectEqual(null, locate("ftp://x/y"));
}

test "archive members and validity" {
    const m = archiveMember("file:///dvddisc/ADV_OBJ/menu.aca/MenubarACA.xmf").?;
    try testing.expectEqualStrings("file:///dvddisc/ADV_OBJ/menu.aca", m.archive);
    try testing.expectEqualStrings("MenubarACA.xmf", m.name);
    try testing.expectEqual(null, archiveMember("file:///dvddisc/ADV_OBJ/menu.aca"));
    try testing.expectEqual(null, archiveMember("file:///dvddisc/ADV_OBJ/menu.acab/x"));
    try testing.expectEqualStrings("app.ACA", archiveMember("http://h/app.ACA/x.js").?.archive[9..]);
    try testing.expectEqualStrings("menu.aca", fileName("file:///dvddisc/ADV_OBJ/menu.aca"));
    try testing.expect(valid("file:///dvddisc/a/b"));
    try testing.expect(!valid("file:///dvddisc/a/../b"));
    try testing.expect(eql("FILE:///dvddisc/A", "file:///dvddisc/A"));
    try testing.expect(!eql("file:///dvddisc/A", "file:///dvddisc/a"));
    const dec = try percentDecode(testing.allocator, "a%20b%zz%4");
    defer testing.allocator.free(dec);
    try testing.expectEqualStrings("a b%zz%4", dec);
}
