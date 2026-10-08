//! The application Manifest (*.xmf, HD DVD Vol. 3 §6.2.4): an Advanced Application's layout region, the scripts
//! run at startup (in order), the initial markup page, and the resources that must be in the File Cache before
//! it starts. URIs are resolved against the manifest's own URI or its xml:base (§6.2.2). No VLC dependency.

const std = @import("std");
const dom = @import("dom.zig");
const uri = @import("uri.zig");

pub const ns = "http://www.dvdforum.org/2005/HDDVDVideo/Manifest";

pub const Error = error{ BadManifest, OutOfMemory };

pub const Region = struct { x: u32 = 0, y: u32 = 0, width: u32 = 1920, height: u32 = 1080 };

pub const Manifest = struct {
    arena: std.heap.ArenaAllocator,
    id: []const u8 = "",
    region: Region = .{},
    /// Absolute URIs.
    scripts: []const []const u8 = &.{},
    markup: ?[]const u8 = null,
    resources: []const []const u8 = &.{},

    pub fn deinit(m: *Manifest) void {
        m.arena.deinit();
    }
};

/// Parses a manifest read from `doc_uri`.
pub fn parse(gpa: std.mem.Allocator, bytes: []const u8, doc_uri: []const u8) Error!Manifest {
    const doc = dom.parse(gpa, bytes, null) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.BadManifest,
    };
    defer doc.destroy();
    const root = doc.root() orelse return error.BadManifest;
    if (!root.is(ns, "Application")) return error.BadManifest;
    var m: Manifest = .{ .arena = .init(gpa) };
    errdefer m.deinit();
    const a = m.arena.allocator();
    m.id = try a.dupe(u8, root.attr("id") orelse "");
    const base = if (root.attrNS(dom.xml_ns, "base")) |b|
        uri.xmlBase(a, doc_uri, b) catch return error.BadManifest
    else
        doc_uri;

    var scripts: std.ArrayList([]const u8) = .empty;
    var resources: std.ArrayList([]const u8) = .empty;
    var c = root.firstElement();
    while (c) |e| : (c = e.nextElement()) {
        if (e.is(ns, "Region")) {
            m.region = .{
                .x = num(e.attr("x"), 0),
                .y = num(e.attr("y"), 0),
                .width = num(e.attr("width"), 1920),
                .height = num(e.attr("height"), 1080),
            };
        } else if (e.is(ns, "Script")) {
            try scripts.append(a, try resolve(a, base, e.attr("src")));
        } else if (e.is(ns, "Markup")) {
            m.markup = try resolve(a, base, e.attr("src"));
        } else if (e.is(ns, "Resource")) {
            // Shall be absolute (§6.2.4.2); resolved anyway.
            try resources.append(a, try resolve(a, base, e.attr("src")));
        }
    }
    m.scripts = scripts.items;
    m.resources = resources.items;
    return m;
}

fn num(s: ?[]const u8, default: u32) u32 {
    return std.fmt.parseInt(u32, std.mem.trim(u8, s orelse return default, " \t"), 10) catch default;
}

fn resolve(a: std.mem.Allocator, base: []const u8, src: ?[]const u8) Error![]const u8 {
    const s = std.mem.trim(u8, src orelse return error.BadManifest, " \t\r\n");
    if (s.len == 0) return error.BadManifest;
    return uri.resolve(a, base, s) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.BadManifest,
    };
}

// ---- tests --------------------------------------------------------------------------------------------------

const testing = std.testing;

test "parse a manifest" {
    var m = try parse(testing.allocator,
        \\<?xml version="1.0" encoding="utf-8"?>
        \\<Application xmlns="http://www.dvdforum.org/2005/HDDVDVideo/Manifest" id="menu">
        \\ <Region x="0" y="10" width="1280" height="720"/>
        \\ <Script src="file:///dvddisc/ADV_OBJ/menu.aca/a.js"></Script>
        \\ <Script src="b.js"/>
        \\ <Markup src="menu.xmu"/>
        \\ <Resource src="file:///dvddisc/ADV_OBJ/menu.aca"/>
        \\</Application>
    , "file:///dvddisc/ADV_OBJ/menu.aca/menu.xmf");
    defer m.deinit();
    try testing.expectEqualStrings("menu", m.id);
    try testing.expectEqual(@as(u32, 10), m.region.y);
    try testing.expectEqual(@as(u32, 1280), m.region.width);
    try testing.expectEqual(2, m.scripts.len);
    try testing.expectEqualStrings("file:///dvddisc/ADV_OBJ/menu.aca/b.js", m.scripts[1]);
    try testing.expectEqualStrings("file:///dvddisc/ADV_OBJ/menu.aca/menu.xmu", m.markup.?);
    try testing.expectEqualStrings("file:///dvddisc/ADV_OBJ/menu.aca", m.resources[0]);
}

test "xml:base and errors" {
    var m = try parse(testing.allocator,
        \\<Application xmlns="http://www.dvdforum.org/2005/HDDVDVideo/Manifest" xml:base="file:///dvddisc/ADV_OBJ/x.aca/sub">
        \\ <Markup src="p.xmu"/>
        \\</Application>
    , "file:///dvddisc/ADV_OBJ/a.xmf");
    defer m.deinit();
    try testing.expectEqualStrings("file:///dvddisc/ADV_OBJ/x.aca/p.xmu", m.markup.?);
    try testing.expectEqual(0, m.scripts.len);
    try testing.expectError(error.BadManifest, parse(testing.allocator, "<Application/>", "file:///dvddisc/a.xmf"));
    try testing.expectError(error.BadManifest, parse(testing.allocator,
        \\<Application xmlns="http://www.dvdforum.org/2005/HDDVDVideo/Manifest"><Script/></Application>
    , "file:///dvddisc/a.xmf"));
}
