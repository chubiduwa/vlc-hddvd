//! The XMLParser object (HD DVD Annex Z.12.9): loading XML documents asynchronously from a file
//! (parse), synchronously from a string (parseString), and writing them to a file asynchronously (write). It
//! is also the DOMImplementation (Z.12.9.1). One document at a time: parse and write throw
//! HDDVD_E_INVALIDOPERATION while one is in progress.
//!
//! The asynchronous work is done at the next work-item pass, and the callback is a work item after it (§8.5).
//! Files are read as applications read them (files.zig: the Resource Area first). Writing goes to the API
//! Managed Area or the persistent storage; an existing file is never overwritten (FILE_OVERWRITE_ERR).
//! No VLC dependency.

const std = @import("std");
const js = @import("js.zig");
const dom = @import("../dom.zig");
const dom_api = @import("dom_api.zig");
const files_mod = @import("files.zig");
const host = @import("host.zig");

const c = js.c;
const Value = js.Value;
const Script = host.Script;

pub const Status = struct {
    pub const ready = 1;
    pub const parsing = 2;
    pub const writing = 4;
};

pub const Result = struct {
    pub const ok = 5;
    pub const parse_err = 6;
    pub const file_not_found = 3;
    pub const file_overwrite_err = 7;
    pub const filecache_err = 8;
    pub const serialize_err = 9;
    pub const file_write_err = 10;
};

pub const Encoding = enum(u32) { utf8 = 1, utf16_be = 2, utf16_le = 3 };

pub const Parser = struct {
    status: u32 = Status.ready,
    /// The operation in progress.
    job: ?Job = null,

    const Job = union(enum) {
        parse: struct { uri: []u8, callback: Value },
        write: struct { doc: Value, uri: []u8, encoding: Encoding, callback: Value },
    };

    pub fn deinit(p: *Parser, gpa: std.mem.Allocator) void {
        if (p.job) |j| switch (j) {
            .parse => |x| gpa.free(x.uri),
            .write => |x| gpa.free(x.uri),
        };
        p.job = null;
    }

    fn scriptOf(cx: *js.Context) *Script {
        return Script.of(cx);
    }

    fn validUri(u: []const u8) bool {
        _ = files_mod.Files.where(u) catch return false;
        return true;
    }

    /// parse(uri, callback): the document is read and parsed later, then callback(status, document).
    fn parse(p: *Parser, cx: *js.Context, u: js.NullStr, callback: Value) js.Error!void {
        const s = scriptOf(cx);
        const path = u.s orelse return error.Argument;
        if (!validUri(path) or !cx.isFunction(callback)) return error.Argument;
        if (p.status != Status.ready) return error.InvalidOperation;
        p.status = Status.parsing;
        p.job = .{ .parse = .{ .uri = try s.gpa.dupe(u8, path), .callback = cx.dup(callback) } };
        try s.post(.{ .call = .{ .f = try cx.function("XMLParser", runJob, 0), .args = &.{}, .what = "XMLParser" } }, .app, 0, null);
    }

    /// The deferred part of parse/write (a work item).
    fn runJob(ctx: ?*c.JSContext, _: Value, _: c_int, _: [*c]Value) callconv(.c) Value {
        const cx = js.Context.of(ctx);
        const s = scriptOf(cx);
        const p = &s.parser;
        const job = p.job orelse return js.undefined;
        p.job = null;
        switch (job) {
            .parse => |x| {
                defer s.gpa.free(x.uri);
                const status, const doc: Value = parseFile(s, x.uri);
                p.status = Status.ready;
                s.postCall(x.callback, &.{ cx.number(@floatFromInt(status)), doc }, "XMLParser.parse") catch {};
                cx.free(x.callback);
            },
            .write => |x| {
                defer s.gpa.free(x.uri);
                const status = writeFile(s, x.doc, x.uri, x.encoding);
                cx.free(x.doc);
                p.status = Status.ready;
                s.postCall(x.callback, &.{cx.number(@floatFromInt(status))}, "XMLParser.write") catch {};
                cx.free(x.callback);
            },
        }
        return js.undefined;
    }

    fn parseFile(s: *Script, u: []const u8) struct { u32, Value } {
        const f = s.world.files orelse return .{ Result.file_not_found, js.null };
        const bytes = f.read(s.gpa, u) catch |e| return .{ switch (e) {
            error.NoSpace => Result.filecache_err,
            else => Result.file_not_found,
        }, js.null };
        defer s.gpa.free(bytes);
        const doc = dom.parse(s.gpa, bytes, null) catch return .{ Result.parse_err, js.null };
        doc.uri = s.gpa.dupe(u8, u) catch {
            doc.destroy();
            return .{ Result.parse_err, js.null };
        };
        const v = dom_api.adoptDocument(s, doc) catch {
            doc.destroy();
            return .{ Result.parse_err, js.null };
        };
        return .{ Result.ok, v };
    }

    fn writeFile(s: *Script, doc_v: Value, u: []const u8, enc: Encoding) u32 {
        const f = s.world.files orelse return Result.file_write_err;
        const n = dom_api.nodeOf(s.cx, doc_v) orelse return Result.serialize_err;
        if (f.exists(u)) return Result.file_overwrite_err;
        const data = serialize(s.gpa, n, enc) catch return Result.serialize_err;
        defer s.gpa.free(data);
        f.write(u, data) catch |e| return switch (e) {
            error.NoSpace => if ((files_mod.Files.where(u) catch .temp) == .temp) Result.filecache_err else Result.file_write_err,
            else => Result.file_write_err,
        };
        return Result.ok;
    }

    /// parseString(xmlString): the document, or null if it is not well-formed. The encoding declaration is
    /// ignored (the string is already characters).
    fn parseString(p: *Parser, cx: *js.Context, xml: js.NullStr) js.Error!Value {
        const s = scriptOf(cx);
        const text = xml.s orelse return error.Argument;
        if (p.status != Status.ready) return error.InvalidOperation;
        const doc = dom.parse(s.gpa, text, null) catch |e| return if (e == error.OutOfMemory) error.OutOfMemory else js.null;
        return dom_api.adoptDocument(s, doc) catch |e| {
            doc.destroy();
            return e;
        };
    }

    /// write(document, uri, encoding, callback).
    fn write(p: *Parser, cx: *js.Context, doc_v: Value, u: js.NullStr, encoding: i32, callback: Value) js.Error!void {
        const s = scriptOf(cx);
        const n = dom_api.nodeOf(cx, doc_v) orelse return error.Argument;
        if (n.type != .document) return error.Argument;
        const path = u.s orelse return error.Argument;
        if (!validUri(path) or !cx.isFunction(callback)) return error.Argument;
        const enc: Encoding = switch (encoding) {
            1 => .utf8,
            2 => .utf16_be,
            3 => .utf16_le,
            else => return error.Argument,
        };
        if (p.status != Status.ready) return error.InvalidOperation;
        p.status = Status.writing;
        p.job = .{ .write = .{ .doc = cx.dup(doc_v), .uri = try s.gpa.dupe(u8, path), .encoding = enc, .callback = cx.dup(callback) } };
        try s.post(.{ .call = .{ .f = try cx.function("XMLParser", runJob, 0), .args = &.{}, .what = "XMLParser" } }, .app, 0, null);
    }

    fn getStatus(p: *Parser) u32 {
        return p.status;
    }

    fn hasFeature(_: *Parser, cx: *js.Context, feature: []const u8, version: js.NullStr) bool {
        return dom_api.hasFeature(scriptOf(cx), feature, version);
    }

    fn createDocumentType(_: *Parser, cx: *js.Context, a: []const u8, b: []const u8, d: []const u8) js.Error!Value {
        return dom_api.createDocumentType(scriptOf(cx), cx, a, b, d);
    }

    fn createDocument(_: *Parser, cx: *js.Context, ns: js.NullStr, q: js.NullStr, doctype: Value) js.Error!Value {
        return dom_api.createDocument(scriptOf(cx), cx, ns, q, doctype);
    }

    pub const js_class: js.Class = .{
        .name = "XMLParser",
        .members = &.{
            js.method("parse", parse),
            js.method("parseString", parseString),
            js.method("write", write),
            js.method("status", getStatus),
            js.method("hasFeature", hasFeature),
            js.method("createDocumentType", createDocumentType),
            js.method("createDocument", createDocument),
            js.constant("UTF8", 1),
            js.constant("UTF16_BE", 2),
            js.constant("UTF16_LE", 3),
            js.constant("UTF16", 2),
            js.constant("READY", Status.ready),
            js.constant("PARSING", Status.parsing),
            js.constant("WRITING", Status.writing),
            js.constant("OK", Result.ok),
            js.constant("PARSE_ERR", Result.parse_err),
            js.constant("FILE_NOT_FOUND", Result.file_not_found),
            js.constant("FILE_OVERWRITE_ERR", Result.file_overwrite_err),
            js.constant("FILECACHE_ERR", Result.filecache_err),
            js.constant("SERIALIZE_ERR", Result.serialize_err),
            js.constant("FILE_WRITE_ERR", Result.file_write_err),
        },
    };
};

/// The document as XML with an encoding declaration, nothing added or removed between nodes (Z.12.9.3 write).
pub fn serialize(gpa: std.mem.Allocator, n: *const dom.Node, enc: Encoding) ![]u8 {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    try text.appendSlice(gpa, switch (enc) {
        .utf8 => "<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
        .utf16_be, .utf16_le => "<?xml version=\"1.0\" encoding=\"UTF-16\"?>",
    });
    var ch = n.first;
    while (ch) |k| : (ch = k.next) try dom.serialize(gpa, k, &text);
    switch (enc) {
        .utf8 => return text.toOwnedSlice(gpa),
        .utf16_be, .utf16_le => {
            var out: std.ArrayList(u8) = .empty;
            errdefer out.deinit(gpa);
            try out.appendSlice(gpa, if (enc == .utf16_be) "\xfe\xff" else "\xff\xfe");
            const view = std.unicode.Utf8View.init(text.items) catch return error.BadText;
            var it = view.iterator();
            while (it.nextCodepoint()) |cp| {
                var units: [2]u16 = undefined;
                const nu: usize = if (cp >= 0x10000) blk: {
                    const v = cp - 0x10000;
                    units = .{ @intCast(0xd800 + (v >> 10)), @intCast(0xdc00 + (v & 0x3ff)) };
                    break :blk 2;
                } else blk: {
                    units[0] = @intCast(cp);
                    break :blk 1;
                };
                for (units[0..nu]) |u| {
                    var b: [2]u8 = undefined;
                    std.mem.writeInt(u16, &b, u, if (enc == .utf16_be) .big else .little);
                    try out.appendSlice(gpa, &b);
                }
            }
            return out.toOwnedSlice(gpa);
        },
    }
}
