//! File input/output for scripts (HD DVD Annex Z.3): the FileIO object, TextStream, File and Directory.
//!
//! The operations are asynchronous for script: their result comes in a callback, a work item after the call
//! (§8.5). The file operation itself is done at the call (files.zig), which nothing can observe differently.
//! Text files are UTF-16BE with a BOM; a TextStream works on a copy in the API Managed Area (opened files of
//! other areas are copied there under a name of the player's, deleted when the stream goes), and LF alone ends
//! a line (Z.3). Positions count UTF-16 units, as script strings do. No VLC dependency.

const std = @import("std");
const js = @import("js.zig");
const host = @import("host.zig");
const files_mod = @import("files.zig");
const uri_mod = @import("../uri.zig");

const c = js.c;
const Value = js.Value;
const Script = host.Script;
const Files = files_mod.Files;

pub const Info = struct {
    pub const succeeded = 1;
    pub const argument = 2;
    pub const file_not_found = 3;
    pub const not_enough_space = 4;
    pub const io = 5;
    pub const not_permitted = 6;
    pub const failed = 7;
    pub const directory_not_found = 8;
};

pub const Mode = struct {
    pub const read = 1;
    pub const write = 2;
    pub const read_write = 3;
};

/// Longest URI and file name (Vol. 3 §6.2.2, Vol. 1 §3.3.2).
const max_uri = 1024;
const max_name = 255;

/// The argument checks every FileIO function makes, in their order: HDDVD_E_ARGUMENTNULL, HDDVD_E_ARGUMENT
/// (empty, blank or with characters not allowed in names), HDDVD_E_PATHTOOLONG.
fn checkUri(u: js.NullStr) js.Error![]const u8 {
    const s = u.s orelse return error.ArgumentNull;
    if (std.mem.trim(u8, s, " \t\r\n").len == 0) return error.Argument;
    for (s) |ch| if (ch < 0x20 or std.mem.indexOfScalar(u8, "\\*?\"<>|", ch) != null) return error.Argument;
    if (!uri_mod.valid(s) and s.len < max_uri) return error.Argument;
    if (s.len >= max_uri) return error.PathTooLong;
    var it = std.mem.splitScalar(u8, s, '/');
    while (it.next()) |seg| if (seg.len > max_name) return error.PathTooLong;
    _ = Files.where(s) catch return error.Argument;
    return s;
}

fn filesOf(s: *Script) js.Error!*Files {
    return s.world.files orelse error.InvalidCall;
}

fn isDisc(u: []const u8) bool {
    return (Files.where(u) catch return false) == .disc;
}

fn callback(s: *Script, f: Value, args: []const Value) void {
    if (!s.cx.isFunction(f)) {
        for (args) |a| s.cx.free(a);
        return;
    }
    s.postCall(f, args, "FileIO") catch {};
}

fn num(cx: *js.Context, n: u32) Value {
    return cx.number(@floatFromInt(n));
}

fn infoOf(e: files_mod.Error) u32 {
    return switch (e) {
        error.NotFound => Info.file_not_found,
        error.NotPermitted => Info.not_permitted,
        error.NoSpace => Info.not_enough_space,
        error.Exists => Info.io,
        else => Info.failed,
    };
}

fn lastName(u: []const u8) []const u8 {
    const t = std.mem.trimEnd(u8, u, "/");
    const i = std.mem.lastIndexOfScalar(u8, t, '/') orelse return t;
    return t[i + 1 ..];
}

// ---- FileIO ---------------------------------------------------------------------------------------------------------

pub const FileIO = struct {
    pub const js_owner = true;

    /// createDirectory(uri, callback): in the persistent storage only.
    fn createDirectory(s: *Script, u: js.NullStr, cb: Value) js.Error!void {
        const p = try checkUri(u);
        if ((Files.where(p) catch .temp) != .store) return error.InvalidCall;
        const f = try filesOf(s);
        const r: u32 = if (f.makeDir(p)) Info.succeeded else |_| Info.failed;
        callback(s, cb, &.{num(s.cx, r)});
    }

    /// openTextFile(uri, mode, overwrite, createNew, callback): Table Z.3.1.2-1.
    fn openTextFile(s: *Script, u: js.NullStr, mode: u32, overwrite: bool, create_new: bool, cb: Value) js.Error!void {
        const p = try checkUri(u);
        const f = try filesOf(s);
        if (mode < 1 or mode > 3) return error.Argument;
        if (isDisc(p)) {
            if (mode != Mode.read) return error.InvalidCall;
            if (f.discBusy()) return error.InvalidCall;
        }
        if (TextStream.isOpen(s, p)) return error.Io;
        const in_cache = (Files.where(p) catch .temp) == .temp;
        const st = f.stat(p) catch null;
        const exists = st != null and !st.?.dir;
        if (uri_mod.archiveMember(p) != null and mode != Mode.read) return callback(s, cb, &.{ js.null, num(s.cx, Info.not_permitted) });
        // A: the file; B: a copy of it; C: failure; D: emptied; E: a new empty file.
        const Behavior = enum { a, b, c, d, e };
        const b: Behavior = if (mode == Mode.read)
            (if (!exists) .c else if (in_cache) .a else .b)
        else if (overwrite)
            (if (create_new)
                (if (in_cache) (if (exists) .d else .e) else .e)
            else
                (if (in_cache) (if (exists) .d else .c) else (if (exists) .e else .c)))
        else if (create_new)
            (if (in_cache) (if (exists) .a else .e) else (if (exists) .b else .e))
        else
            (if (in_cache) (if (exists) .a else .c) else (if (exists) .b else .c));
        if (b == .c) return callback(s, cb, &.{ js.null, num(s.cx, Info.failed) });
        var text: []u16 = &.{};
        defer s.gpa.free(text);
        if (b == .a or b == .b) {
            const bytes = f.read(s.gpa, p) catch |e| return callback(s, cb, &.{ js.null, num(s.cx, infoOf(e)) });
            defer s.gpa.free(bytes);
            text = try decodeText(s.gpa, bytes);
        }
        const ts = TextStream.open(s, p, if (b == .a or b == .d or (b == .e and in_cache)) null else p, mode, text) catch |e| switch (e) {
            error.NoSpace => return callback(s, cb, &.{ js.null, num(s.cx, Info.not_enough_space) }),
            error.OutOfMemory => return error.OutOfMemory,
            else => return callback(s, cb, &.{ js.null, num(s.cx, Info.failed) }),
        };
        callback(s, cb, &.{ ts, num(s.cx, Info.succeeded) });
    }

    /// saveTextFile(stream, callback): the API Managed Area copy goes back to its source; the stream closes.
    fn saveTextFile(s: *Script, stream: Value, cb: Value) js.Error!void {
        const ts = s.cx.unwrap(TextStream, stream) orelse return error.Argument;
        if (ts.closed) return error.InvalidOperation;
        const src = ts.source orelse return error.InvalidOperation;
        const f = try filesOf(s);
        const data = try encodeText(s.gpa, ts.text.items);
        defer s.gpa.free(data);
        const r: u32 = if (f.write(src, data)) Info.succeeded else |e| (if (e == error.NoSpace) Info.not_enough_space else Info.failed);
        ts.close(s);
        callback(s, cb, &.{num(s.cx, r)});
    }

    fn copyFile(s: *Script, from: []const u8, to: []const u8, overwrite: bool) u32 {
        const f = s.world.files orelse return Info.failed;
        if (uri_mod.archiveMember(to) != null) return Info.not_permitted;
        const st = f.stat(from) catch return Info.file_not_found;
        if (st.dir) return Info.file_not_found;
        if (f.exists(to) and !overwrite) return Info.io;
        const data = f.read(s.gpa, from) catch |e| return infoOf(e);
        defer s.gpa.free(data);
        f.write(to, data) catch |e| return infoOf(e);
        // The last modified time is kept.
        f.setModified(to, st.modified) catch {};
        return Info.succeeded;
    }

    /// copy(uri, destinationUri, overwrite, callback): files only.
    fn copy(s: *Script, u: js.NullStr, dest: js.NullStr, overwrite: bool, cb: Value) js.Error!void {
        const p = try checkUri(u);
        const d = try checkUri(dest);
        const f = try filesOf(s);
        if (isDisc(d)) return error.InvalidCall;
        if (isDisc(p) and f.discBusy()) return error.InvalidCall;
        callback(s, cb, &.{num(s.cx, copyFile(s, p, d, overwrite))});
    }

    /// move(uri, destinationUri, callback): a copy without overwriting, then the source is removed.
    fn move(s: *Script, u: js.NullStr, dest: js.NullStr, cb: Value) js.Error!void {
        const p = try checkUri(u);
        const d = try checkUri(dest);
        const f = try filesOf(s);
        if (isDisc(p) or isDisc(d)) return error.InvalidCall;
        if (uri_mod.archiveMember(p) != null) return callback(s, cb, &.{num(s.cx, Info.not_permitted)});
        var r = copyFile(s, p, d, false);
        if (r == Info.succeeded) f.remove(p, false) catch {
            f.remove(d, false) catch {};
            r = Info.failed;
        };
        callback(s, cb, &.{num(s.cx, r)});
    }

    /// remove(uri, removeDirectoryContents, callback).
    fn remove(s: *Script, u: js.NullStr, contents: bool, cb: Value) js.Error!void {
        const p = try checkUri(u);
        if (isDisc(p)) return error.InvalidCall;
        const f = try filesOf(s);
        const r: u32 = blk: {
            const st = f.stat(p) catch break :blk Info.file_not_found;
            if (uri_mod.archiveMember(p) != null) break :blk Info.not_permitted;
            f.remove(p, st.dir and contents) catch |e| break :blk switch (e) {
                error.NotEmpty => Info.io,
                error.NotPermitted => Info.not_permitted,
                error.NotFound => Info.file_not_found,
                else => Info.failed,
            };
            break :blk Info.succeeded;
        };
        callback(s, cb, &.{num(s.cx, r)});
    }

    fn list(s: *Script, u: js.NullStr, cb: Value, dirs: bool) js.Error!void {
        const p = try checkUri(u);
        const f = try filesOf(s);
        if (isDisc(p) and f.discBusy()) return error.InvalidCall;
        const names = f.list(s.gpa, p, dirs) catch return callback(s, cb, &.{ js.null, num(s.cx, Info.directory_not_found) });
        defer {
            for (names) |n| s.gpa.free(n);
            s.gpa.free(names);
        }
        var uris: std.ArrayList([]const u8) = .empty;
        defer {
            for (uris.items) |x| s.gpa.free(x);
            uris.deinit(s.gpa);
        }
        const base = std.mem.trimEnd(u8, p, "/");
        for (names) |n| try uris.append(s.gpa, try std.mem.concat(s.gpa, u8, &.{ base, "/", n }));
        const arr = try host.StringArray.of(s, uris.items);
        callback(s, cb, &.{ arr, num(s.cx, Info.succeeded) });
    }

    fn getFiles(s: *Script, u: js.NullStr, cb: Value) js.Error!void {
        return list(s, u, cb, false);
    }

    fn getDirectories(s: *Script, u: js.NullStr, cb: Value) js.Error!void {
        return list(s, u, cb, true);
    }

    fn getFileInfo(s: *Script, u: js.NullStr, cb: Value) js.Error!void {
        const p = try checkUri(u);
        const f = try filesOf(s);
        if (isDisc(p) and f.discBusy()) return error.InvalidCall;
        const st = f.stat(p) catch return callback(s, cb, &.{ js.null, num(s.cx, Info.file_not_found) });
        if (st.dir) return callback(s, cb, &.{ js.null, num(s.cx, Info.file_not_found) });
        const obj = try Entry.make(s, &Entry.file_class, p, st);
        callback(s, cb, &.{ obj, num(s.cx, Info.succeeded) });
    }

    fn getDirectoryInfo(s: *Script, u: js.NullStr, cb: Value) js.Error!void {
        const p = try checkUri(u);
        const f = try filesOf(s);
        if (isDisc(p) and f.discBusy()) return error.InvalidCall;
        const st = f.stat(p) catch return callback(s, cb, &.{ js.null, num(s.cx, Info.directory_not_found) });
        if (!st.dir) return callback(s, cb, &.{ js.null, num(s.cx, Info.directory_not_found) });
        const obj = try Entry.make(s, &Entry.directory_class, p, st);
        callback(s, cb, &.{ obj, num(s.cx, Info.succeeded) });
    }

    /// setLastModifiedDate(uri, date, callback).
    fn setLastModifiedDate(s: *Script, u: js.NullStr, date: Value, cb: Value) js.Error!void {
        const p = try checkUri(u);
        if (isDisc(p)) return error.InvalidCall;
        const f = try filesOf(s);
        var ms: f64 = 0;
        if (c.JS_ToFloat64(s.cx.ctx, &ms, date) < 0) return error.Thrown;
        if (std.math.isNan(ms)) return error.Argument;
        const r: u32 = blk: {
            const st = f.stat(p) catch break :blk Info.file_not_found;
            if (st.dir) break :blk Info.argument;
            f.setModified(p, @intFromFloat(ms)) catch |e| break :blk if (e == error.NotPermitted) Info.not_permitted else Info.failed;
            break :blk Info.succeeded;
        };
        callback(s, cb, &.{num(s.cx, r)});
    }

    pub const js_class: js.Class = .{
        .name = "FileIO",
        .members = &.{
            js.method("saveTextFile", saveTextFile),
            js.method("createDirectory", createDirectory),
            js.method("openTextFile", openTextFile),
            js.method("copy", copy),
            js.method("remove", remove),
            js.method("move", move),
            js.method("getFiles", getFiles),
            js.method("getFileInfo", getFileInfo),
            js.method("getDirectories", getDirectories),
            js.method("getDirectoryInfo", getDirectoryInfo),
            js.method("setLastModifiedDate", setLastModifiedDate),
            js.constant("FILE_IOMODE_READ", Mode.read),
            js.constant("FILE_IOMODE_WRITE", Mode.write),
            js.constant("FILE_IOMODE_READWRITE", Mode.read_write),
            js.constant("SUCCEEDED", Info.succeeded),
            js.constant("FAILED", Info.failed),
            js.constant("FILE_NOT_FOUND", Info.file_not_found),
            js.constant("IO", Info.io),
            js.constant("NOT_PERMITTED", Info.not_permitted),
            js.constant("DIRECTORY_NOT_FOUND", Info.directory_not_found),
            js.constant("ARGUMENT", Info.argument),
            js.constant("NOT_ENOUGH_SPACE", Info.not_enough_space),
        },
    };
};

// ---- File, Directory (Z.3.2, Z.3.3) -------------------------------------------------------------------------------

pub const Entry = struct {
    gpa: std.mem.Allocator,
    uri: []u8,
    size: u64,
    modified: i64,

    fn make(s: *Script, class: *const js.Class, u: []const u8, st: files_mod.Stat) js.Error!Value {
        const e = try s.gpa.create(Entry);
        errdefer s.gpa.destroy(e);
        e.* = .{ .gpa = s.gpa, .uri = try s.gpa.dupe(u8, u), .size = st.size, .modified = st.modified };
        return s.cx.wrapAs(Entry, class, e) catch |err| {
            s.gpa.free(e.uri);
            return err;
        };
    }

    fn finalize(ptr: *anyopaque, _: *js.Runtime) void {
        const e: *Entry = @ptrCast(@alignCast(ptr));
        e.gpa.free(e.uri);
        e.gpa.destroy(e);
    }

    fn lastModifiedTime(e: *Entry, cx: *js.Context) Value {
        return c.JS_NewDate(cx.ctx, @floatFromInt(e.modified));
    }
    fn name(e: *Entry) []const u8 {
        return lastName(e.uri);
    }
    fn getUri(e: *Entry) []const u8 {
        return e.uri;
    }
    fn getSize(e: *Entry) f64 {
        return @floatFromInt(e.size);
    }

    const members = [_]js.Member{
        js.prop("lastModifiedTime", lastModifiedTime, null),
        js.prop("name", name, null),
        js.prop("uri", getUri, null),
        js.prop("size", getSize, null),
    };

    const file_class: js.Class = .{ .name = "File", .finalize = finalize, .members = &members };
    const directory_class: js.Class = .{ .name = "Directory", .finalize = finalize, .members = &members };
    pub const js_class = file_class;
};

// ---- TextStream (Z.3.4) ---------------------------------------------------------------------------------------------

/// UTF-16BE with a BOM (a missing BOM, or UTF-8, read as best it can be) to UTF-16 units.
fn decodeText(gpa: std.mem.Allocator, bytes: []const u8) ![]u16 {
    if (bytes.len >= 2 and bytes[0] == 0xfe and bytes[1] == 0xff) {
        const n = (bytes.len - 2) / 2;
        const out = try gpa.alloc(u16, n);
        for (out, 0..) |*u, i| u.* = std.mem.readInt(u16, bytes[2 + i * 2 ..][0..2], .big);
        return out;
    }
    const s = if (std.mem.startsWith(u8, bytes, "\xef\xbb\xbf")) bytes[3..] else bytes;
    return std.unicode.utf8ToUtf16LeAlloc(gpa, s) catch {
        const out = try gpa.alloc(u16, s.len);
        for (out, s) |*u, b| u.* = b;
        return out;
    };
}

/// UTF-16 units to UTF-16BE with a BOM.
fn encodeText(gpa: std.mem.Allocator, units: []const u16) ![]u8 {
    const out = try gpa.alloc(u8, 2 + units.len * 2);
    out[0] = 0xfe;
    out[1] = 0xff;
    for (units, 0..) |u, i| std.mem.writeInt(u16, out[2 + i * 2 ..][0..2], u, .big);
    return out;
}

pub const TextStream = struct {
    gpa: std.mem.Allocator,
    script: *Script,
    /// The file's URI (what openTextFile was given), and where saveTextFile writes (null: the stream's file is
    /// that file, in the API Managed Area).
    uri: []u8,
    source: ?[]u8,
    /// The associated file in the API Managed Area.
    temp: []u8,
    mode: u32,
    text: std.ArrayList(u16) = .empty,
    /// Read pointer (units), and its line and column (1-based).
    pos: usize = 0,
    line: u32 = 1,
    column: u32 = 1,
    closed: bool = false,
    obj: ?*anyopaque = null,

    var serial: u32 = 0;

    fn open(s: *Script, u: []const u8, source: ?[]const u8, mode: u32, text: []const u16) !Value {
        const f = s.world.files orelse return error.Failed;
        const ts = try s.gpa.create(TextStream);
        errdefer s.gpa.destroy(ts);
        const temp = if (source == null) try s.gpa.dupe(u8, u) else blk: {
            serial += 1;
            break :blk try std.fmt.allocPrint(s.gpa, "file:///filecache/~textstream{d}.txt", .{serial});
        };
        errdefer s.gpa.free(temp);
        ts.* = .{ .gpa = s.gpa, .script = s, .uri = try s.gpa.dupe(u8, u), .source = if (source) |x| try s.gpa.dupe(u8, x) else null, .temp = temp, .mode = mode };
        try ts.text.appendSlice(s.gpa, text);
        ts.store(f) catch |e| {
            ts.free();
            return e;
        };
        try s.text_streams.append(s.gpa, ts);
        const v = s.cx.wrap(TextStream, ts) catch |e| {
            _ = s.text_streams.pop();
            ts.free();
            return e;
        };
        ts.obj = js.objectPointer(v);
        return v;
    }

    fn free(ts: *TextStream) void {
        ts.text.deinit(ts.gpa);
        ts.gpa.free(ts.uri);
        if (ts.source) |x| ts.gpa.free(x);
        ts.gpa.free(ts.temp);
        ts.gpa.destroy(ts);
    }

    /// Writes the text to the associated file.
    fn store(ts: *TextStream, f: *Files) !void {
        const data = try encodeText(ts.gpa, ts.text.items);
        defer ts.gpa.free(data);
        try f.write(ts.temp, data);
    }

    fn isOpen(s: *Script, u: []const u8) bool {
        for (s.text_streams.items) |ts| if (!ts.closed and std.mem.eql(u8, ts.uri, u)) return true;
        return false;
    }

    /// Released or saved: a copy in the API Managed Area is deleted.
    fn close(ts: *TextStream, s: *Script) void {
        if (ts.closed) return;
        ts.closed = true;
        if (ts.source != null) if (s.world.files) |f| f.remove(ts.temp, false) catch {};
    }

    /// The stream's object is gone, or its context is (`release`).
    fn finalize(ptr: *anyopaque, _: *js.Runtime) void {
        const ts: *TextStream = @ptrCast(@alignCast(ptr));
        ts.obj = null;
        const s = ts.script;
        ts.close(s);
        if (std.mem.indexOfScalar(*TextStream, s.text_streams.items, ts)) |i| _ = s.text_streams.swapRemove(i);
        ts.free();
    }

    /// The context goes: every stream closes.
    pub fn releaseAll(s: *Script) void {
        while (s.text_streams.pop()) |ts| {
            if (ts.obj) |o| js.kill(s.cx.rt, o);
            ts.close(s);
            ts.free();
        }
    }

    fn checkRead(ts: *TextStream) js.Error!void {
        if (ts.closed) return error.InvalidOperation;
        if (ts.mode == Mode.write) return error.Io;
    }

    fn checkWrite(ts: *TextStream) js.Error!void {
        if (ts.closed) return error.InvalidOperation;
        if (ts.mode == Mode.read) return error.Io;
    }

    fn advance(ts: *TextStream, n: usize) void {
        var i: usize = 0;
        while (i < n and ts.pos < ts.text.items.len) : (i += 1) {
            if (ts.text.items[ts.pos] == '\n') {
                ts.line += 1;
                ts.column = 1;
            } else ts.column += 1;
            ts.pos += 1;
        }
    }

    fn unitsString(cx: *js.Context, units: []const u16) js.Error!Value {
        const utf8 = std.unicode.utf16LeToUtf8Alloc(cx.gpa, units) catch blk: {
            // Unpaired surrogates: replaced.
            var out: std.ArrayList(u8) = .empty;
            defer out.deinit(cx.gpa);
            var it = std.unicode.Utf16LeIterator.init(units);
            while (true) {
                const cp = it.nextCodepoint() catch 0xfffd orelse break;
                var buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(cp, &buf) catch 3;
                try out.appendSlice(cx.gpa, buf[0..n]);
            }
            break :blk try out.toOwnedSlice(cx.gpa);
        };
        defer cx.gpa.free(utf8);
        return cx.string(utf8);
    }

    fn getLine(ts: *TextStream) u32 {
        return ts.line;
    }
    fn getColumn(ts: *TextStream) u32 {
        return ts.column;
    }
    fn atEndOfLine(ts: *TextStream) bool {
        return ts.pos >= ts.text.items.len or ts.text.items[ts.pos] == '\n';
    }
    fn atEndOfStream(ts: *TextStream) bool {
        return ts.pos >= ts.text.items.len;
    }
    fn getUri(ts: *TextStream) []const u8 {
        return ts.uri;
    }

    fn read(ts: *TextStream, cx: *js.Context, n: i32) js.Error!Value {
        try ts.checkRead();
        if (n < 0) return error.Argument;
        const start = ts.pos;
        ts.advance(@intCast(n));
        return unitsString(cx, ts.text.items[start..ts.pos]);
    }

    fn readAll(ts: *TextStream, cx: *js.Context) js.Error!Value {
        try ts.checkRead();
        const start = ts.pos;
        ts.advance(ts.text.items.len);
        return unitsString(cx, ts.text.items[start..]);
    }

    fn readLine(ts: *TextStream, cx: *js.Context) js.Error!Value {
        try ts.checkRead();
        const start = ts.pos;
        const end = std.mem.indexOfScalarPos(u16, ts.text.items, start, '\n') orelse ts.text.items.len;
        ts.advance(end - start);
        const v = try unitsString(cx, ts.text.items[start..end]);
        ts.advance(1);
        return v;
    }

    fn skip(ts: *TextStream, n: i32) js.Error!void {
        try ts.checkRead();
        if (n < 0) return error.Argument;
        ts.advance(@intCast(n));
    }

    fn skipLine(ts: *TextStream) js.Error!void {
        try ts.checkRead();
        const end = std.mem.indexOfScalarPos(u16, ts.text.items, ts.pos, '\n') orelse ts.text.items.len;
        ts.advance(end - ts.pos + 1);
    }

    fn append(ts: *TextStream, cx: *js.Context, s: []const u8, lines: u32) js.Error!void {
        try ts.checkWrite();
        const f = scriptFiles(cx) orelse return error.Io;
        const units = std.unicode.utf8ToUtf16LeAlloc(ts.gpa, s) catch return error.Argument;
        defer ts.gpa.free(units);
        const before = ts.text.items.len;
        try ts.text.appendSlice(ts.gpa, units);
        try ts.text.appendNTimes(ts.gpa, '\n', lines);
        ts.store(f) catch |e| {
            ts.text.shrinkRetainingCapacity(before);
            return if (e == error.NoSpace) error.NotEnoughSpace else error.Io;
        };
    }

    fn scriptFiles(cx: *js.Context) ?*Files {
        return Script.of(cx).world.files;
    }

    fn write(ts: *TextStream, cx: *js.Context, s: []const u8) js.Error!void {
        return ts.append(cx, s, 0);
    }

    fn writeLine(ts: *TextStream, cx: *js.Context, s: []const u8) js.Error!void {
        return ts.append(cx, s, 1);
    }

    fn writeBlankLines(ts: *TextStream, cx: *js.Context, n: u32) js.Error!void {
        return ts.append(cx, "", n);
    }

    /// deleteLine(lineNumber), 1-based.
    fn deleteLine(ts: *TextStream, cx: *js.Context, n: u32) js.Error!void {
        var lines: u32 = 1;
        for (ts.text.items) |u| lines += @intFromBool(u == '\n');
        if (n == 0 or n > lines) return error.Argument;
        if (ts.closed) return error.InvalidOperation;
        if (ts.mode == Mode.read) return error.Io;
        var start: usize = 0;
        var k: u32 = 1;
        while (k < n) : (k += 1) start = std.mem.indexOfScalarPos(u16, ts.text.items, start, '\n').? + 1;
        const nl = std.mem.indexOfScalarPos(u16, ts.text.items, start, '\n');
        // With its newline, or the one before it for the last line.
        const a = if (nl == null and start > 0) start - 1 else start;
        const b = if (nl) |x| x + 1 else ts.text.items.len;
        ts.text.replaceRange(ts.gpa, a, b - a, &.{}) catch return error.OutOfMemory;
        if (ts.pos > a) {
            ts.pos = a;
            ts.line = 1;
            ts.column = 1;
            const p = ts.pos;
            ts.pos = 0;
            ts.advance(p);
        }
        const f = scriptFiles(cx) orelse return error.Io;
        ts.store(f) catch return error.Io;
    }

    pub const js_class: js.Class = .{
        .name = "TextStream",
        .finalize = finalize,
        .members = &.{
            js.prop("line", getLine, null),
            js.prop("atEndOfLine", atEndOfLine, null),
            js.prop("atEndOfStream", atEndOfStream, null),
            js.prop("column", getColumn, null),
            js.prop("uri", getUri, null),
            js.method("deleteLine", deleteLine),
            js.method("read", read),
            js.method("readAll", readAll),
            js.method("readLine", readLine),
            js.method("skip", skip),
            js.method("skipLine", skipLine),
            js.method("write", write),
            js.method("writeLine", writeLine),
            js.method("writeBlankLines", writeBlankLines),
        },
    };
};

// ---- tests --------------------------------------------------------------------------------------------------------

const testenv = @import("testenv.zig");

test "FileIO and TextStream" {
    const e = try testenv.Env.create();
    defer e.destroy();
    try e.backend.disc.write("ADV_OBJ/t.txt", "\xfe\xff\x00a\x00\n\x00b\x00c", 0, true);
    try e.run(
        \\var r = {};
        \\assertThrows(function () { FileIO.copy(null, "file:///filecache/x", false, function () {}); }, "HDDVD_E_ARGUMENTNULL");
        \\assertThrows(function () { FileIO.copy("  ", "file:///filecache/x", false, function () {}); }, "HDDVD_E_ARGUMENT");
        \\assertThrows(function () { FileIO.copy("file:///filecache/a", "file:///dvddisc/x", false, function () {}); }, "HDDVD_E_INVALIDCALL");
        \\assertThrows(function () { FileIO.createDirectory("file:///filecache/d", function () {}); }, "HDDVD_E_INVALIDCALL");
        \\assertThrows(function () { FileIO.remove("file:///dvddisc/ADV_OBJ/t.txt", false, function () {}); }, "HDDVD_E_INVALIDCALL");
        \\FileIO.openTextFile("file:///dvddisc/ADV_OBJ/t.txt", FileIO.FILE_IOMODE_READ, false, false, cb(function (ts, info) {
        \\  assertEq(info, FileIO.SUCCEEDED); assertEq(ts.uri, "file:///dvddisc/ADV_OBJ/t.txt");
        \\  assertEq(ts.line, 1); assertEq(ts.readLine(), "a"); assertEq(ts.line, 2); assertEq(ts.column, 1);
        \\  assertEq(ts.read(1), "b"); assertEq(ts.column, 2); assert(!ts.atEndOfStream); assertEq(ts.readAll(), "c"); assert(ts.atEndOfStream);
        \\  assertThrows(function () { ts.write("x"); }, "HDDVD_E_IO");
        \\  r.read = true;
        \\}));
        \\FileIO.openTextFile("file:///dvddisc/ADV_OBJ/none.txt", 1, false, false, cb(function (ts, info) { r.none = info; }));
        \\FileIO.openTextFile("file:///required/notes.txt", FileIO.FILE_IOMODE_READWRITE, false, true, cb(function (ts, info) {
        \\  assertEq(info, FileIO.SUCCEEDED);
        \\  ts.writeLine("one"); ts.write("two"); ts.writeBlankLines(2); ts.writeLine("three");
        \\  assertEq(ts.readAll(), "one\ntwo\n\nthree\n");
        \\  ts.deleteLine(3); assertThrows(function () { ts.deleteLine(9); }, "HDDVD_E_ARGUMENT");
        \\  FileIO.saveTextFile(ts, cb(function (i) { r.saved = i; }));
        \\  assertThrows(function () { ts.read(1); }, "HDDVD_E_INVALIDOPERATION");
        \\}));
    , "fileio1.js");
    try e.run(
        \\assert(r.read); assertEq(r.none, FileIO.FAILED); assertEq(r.saved, FileIO.SUCCEEDED);
        \\FileIO.createDirectory("file:///required/sub", cb(function (i) { r.mkdirBad = i; }));
        \\FileIO.createDirectory("file:///common/required/sub", cb(function (i) { r.mkdir = i; }));
        \\FileIO.copy("file:///required/notes.txt", "file:///filecache/n.txt", false, cb(function (i) { r.copy = i; }));
        \\FileIO.copy("file:///required/notes.txt", "file:///filecache/n.txt", false, cb(function (i) { r.copy2 = i; }));
        \\FileIO.move("file:///filecache/n.txt", "file:///filecache/m.txt", cb(function (i) { r.move = i; }));
        \\FileIO.getFiles("file:///filecache", cb(function (a, i) { r.files = a.size + ":" + a.get(0) + ":" + i; }));
        \\FileIO.getFileInfo("file:///filecache/m.txt", cb(function (f, i) { r.info = f.name + ":" + f.size + ":" + (f.lastModifiedTime instanceof Date); }));
        \\FileIO.getDirectoryInfo("file:///required", cb(function (d, i) { r.dir = d.name + ":" + i; }));
        \\FileIO.getDirectories("file:///common/required", cb(function (a, i) { r.dirs = a.size + ":" + a.get(0); }));
        \\FileIO.setLastModifiedDate("file:///filecache/m.txt", new Date(5000), cb(function (i) { r.date = i; }));
        \\FileIO.remove("file:///filecache/none", false, cb(function (i) { r.remove = i; }));
    , "fileio2.js");
    try e.run(
        \\assertEq(r.mkdir, 1); assertEq(r.mkdirBad, FileIO.FAILED, "only GUID directories under the provider area"); assertEq(r.copy, 1); assertEq(r.copy2, FileIO.IO); assertEq(r.move, 1);
        \\assertEq(r.files, "1:file:///filecache/m.txt:1"); assertEq(r.info, "m.txt:30:true"); assertEq(r.dir, "required:1");
        \\assertEq(r.dirs, "1:file:///common/required/sub"); assertEq(r.date, 1); assertEq(r.remove, FileIO.FILE_NOT_FOUND);
        \\FileIO.getFileInfo("file:///filecache/m.txt", cb(function (f, i) { r.time = f.lastModifiedTime.getTime(); }));
    , "fileio3.js");
    try e.run("assertEq(r.time, 5000);", "fileio4.js");
    // The saved file is UTF-16BE with its BOM: "one\ntwo\nthree\n" after the third line went.
    const saved = try e.store.read("file:///required/notes.txt");
    try std.testing.expectEqual(@as(usize, 2 + 14 * 2), saved.len);
}
