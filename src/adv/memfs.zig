//! A small in-memory file system: the File Cache's API Managed Area and the persistent storage devices (kept in
//! memory only, nothing is written to disk). Paths are relative, "/"-separated and case-sensitive. No VLC
//! dependency.

const std = @import("std");

pub const Error = error{ NotFound, NotADirectory, IsADirectory, Exists, NotEmpty, BadPath, OutOfMemory };

pub const Node = struct {
    dir: bool,
    data: std.ArrayList(u8) = .empty,
    /// Milliseconds since the Unix epoch.
    created: i64 = 0,
    modified: i64 = 0,
    /// An opaque owner tag (the File Cache records the application that wrote a file).
    owner: u32 = 0,
};

pub const Fs = struct {
    gpa: std.mem.Allocator,
    /// Every file and directory by full path; the root ("") is implicit.
    nodes: std.StringArrayHashMapUnmanaged(Node) = .empty,

    pub fn init(gpa: std.mem.Allocator) Fs {
        return .{ .gpa = gpa };
    }

    pub fn deinit(fs: *Fs) void {
        var it = fs.nodes.iterator();
        while (it.next()) |e| {
            fs.gpa.free(e.key_ptr.*);
            e.value_ptr.data.deinit(fs.gpa);
        }
        fs.nodes.deinit(fs.gpa);
    }

    /// Checks a path: no empty, "." or ".." segment, no leading or trailing "/". "" is the root.
    pub fn validPath(path: []const u8) bool {
        if (path.len == 0) return true;
        var it = std.mem.splitScalar(u8, path, '/');
        while (it.next()) |s| {
            if (s.len == 0 or std.mem.eql(u8, s, ".") or std.mem.eql(u8, s, "..")) return false;
        }
        return true;
    }

    fn parent(path: []const u8) []const u8 {
        return path[0 .. std.mem.lastIndexOfScalar(u8, path, '/') orelse 0];
    }

    pub fn get(fs: *const Fs, path: []const u8) ?*Node {
        return fs.nodes.getPtr(path);
    }

    pub fn isDir(fs: *const Fs, path: []const u8) bool {
        if (path.len == 0) return true;
        const n = fs.get(path) orelse return false;
        return n.dir;
    }

    pub fn exists(fs: *const Fs, path: []const u8) bool {
        return path.len == 0 or fs.nodes.contains(path);
    }

    /// A file's contents.
    pub fn read(fs: *const Fs, path: []const u8) Error![]const u8 {
        const n = fs.get(path) orelse return error.NotFound;
        if (n.dir) return error.IsADirectory;
        return n.data.items;
    }

    /// Creates a directory and any missing parents (like mkdir -p).
    pub fn makeDir(fs: *Fs, path: []const u8, now: i64) Error!void {
        if (!validPath(path)) return error.BadPath;
        if (path.len == 0) return;
        if (fs.get(path)) |n| {
            if (!n.dir) return error.Exists;
            return;
        }
        try fs.makeDir(parent(path), now);
        const key = try fs.gpa.dupe(u8, path);
        errdefer fs.gpa.free(key);
        try fs.nodes.put(fs.gpa, key, .{ .dir = true, .created = now, .modified = now });
    }

    /// Writes (creates or replaces) a file; its directory must exist unless `make_parents`.
    pub fn write(fs: *Fs, path: []const u8, data: []const u8, now: i64, make_parents: bool) Error!void {
        if (!validPath(path) or path.len == 0) return error.BadPath;
        if (make_parents) try fs.makeDir(parent(path), now) else if (!fs.isDir(parent(path))) return error.NotFound;
        if (fs.get(path)) |n| {
            if (n.dir) return error.IsADirectory;
            n.data.clearRetainingCapacity();
            try n.data.appendSlice(fs.gpa, data);
            n.modified = now;
            return;
        }
        var node: Node = .{ .dir = false, .created = now, .modified = now };
        try node.data.appendSlice(fs.gpa, data);
        errdefer node.data.deinit(fs.gpa);
        const key = try fs.gpa.dupe(u8, path);
        errdefer fs.gpa.free(key);
        try fs.nodes.put(fs.gpa, key, node);
    }

    /// Appends to a file, creating it if needed.
    pub fn append(fs: *Fs, path: []const u8, data: []const u8, now: i64) Error!void {
        if (fs.get(path)) |n| {
            if (n.dir) return error.IsADirectory;
            try n.data.appendSlice(fs.gpa, data);
            n.modified = now;
            return;
        }
        return fs.write(path, data, now, false);
    }

    fn isUnder(path: []const u8, dir: []const u8) bool {
        if (dir.len == 0) return path.len > 0;
        return path.len > dir.len and std.mem.startsWith(u8, path, dir) and path[dir.len] == '/';
    }

    /// Removes a file, or a directory (with its contents only if `recursive`).
    pub fn remove(fs: *Fs, path: []const u8, recursive: bool) Error!void {
        if (path.len == 0) return error.BadPath;
        const n = fs.get(path) orelse return error.NotFound;
        if (n.dir) {
            var has = false;
            for (fs.nodes.keys()) |k| if (isUnder(k, path)) {
                has = true;
                break;
            };
            if (has and !recursive) return error.NotEmpty;
            var i: usize = 0;
            while (i < fs.nodes.count()) {
                const k = fs.nodes.keys()[i];
                if (isUnder(k, path)) fs.removeAt(i) else i += 1;
            }
        }
        fs.removeAt(fs.nodes.getIndex(path).?);
    }

    fn removeAt(fs: *Fs, i: usize) void {
        const k = fs.nodes.keys()[i];
        fs.nodes.values()[i].data.deinit(fs.gpa);
        fs.nodes.orderedRemoveAt(i);
        fs.gpa.free(k);
    }

    /// Moves a file or directory (with its contents) to `to`, whose directory must exist.
    pub fn rename(fs: *Fs, from: []const u8, to: []const u8) Error!void {
        if (!validPath(to) or to.len == 0) return error.BadPath;
        if (fs.get(from) == null) return error.NotFound;
        if (fs.exists(to)) return error.Exists;
        if (!fs.isDir(parent(to))) return error.NotFound;
        if (isUnder(to, from)) return error.BadPath;
        for (fs.nodes.keys(), 0..) |k, i| {
            if (!std.mem.eql(u8, k, from) and !isUnder(k, from)) continue;
            const nk = try std.mem.concat(fs.gpa, u8, &.{ to, k[from.len..] });
            fs.gpa.free(k);
            fs.nodes.keys()[i] = nk;
        }
        try fs.nodes.reIndex(fs.gpa);
    }

    /// Names of the direct children of `dir` that are files (`dirs` false) or directories. Caller frees the list
    /// (not the names, which belong to the file system).
    pub fn list(fs: *const Fs, gpa: std.mem.Allocator, dir: []const u8, dirs: bool) Error![][]const u8 {
        if (!fs.isDir(dir)) return if (fs.exists(dir)) error.NotADirectory else error.NotFound;
        var out: std.ArrayList([]const u8) = .empty;
        errdefer out.deinit(gpa);
        for (fs.nodes.keys(), fs.nodes.values()) |k, v| {
            if (!isUnder(k, dir) or v.dir != dirs) continue;
            const rest = k[if (dir.len == 0) 0 else dir.len + 1..];
            if (std.mem.indexOfScalar(u8, rest, '/') != null) continue;
            try out.append(gpa, rest);
        }
        return out.toOwnedSlice(gpa);
    }

    /// Bytes stored under `dir` (all of the file system for "").
    pub fn usedBytes(fs: *const Fs, dir: []const u8) u64 {
        var n: u64 = 0;
        for (fs.nodes.keys(), fs.nodes.values()) |k, v| {
            if (dir.len == 0 or isUnder(k, dir)) n += v.data.items.len;
        }
        return n;
    }

    /// Sum over the files of `f(size)` (e.g. a block count).
    pub fn sumFiles(fs: *const Fs, f: *const fn (u64) u64) u64 {
        var n: u64 = 0;
        for (fs.nodes.values()) |v| if (!v.dir) {
            n += f(v.data.items.len);
        };
        return n;
    }
};

// ---- tests --------------------------------------------------------------------------------------------------

const testing = std.testing;

test "files and directories" {
    var fs = Fs.init(testing.allocator);
    defer fs.deinit();
    try testing.expectError(error.NotFound, fs.write("a/b.txt", "x", 1, false));
    try fs.write("a/b.txt", "hello", 1, true);
    try testing.expect(fs.isDir("a"));
    try testing.expectEqualStrings("hello", try fs.read("a/b.txt"));
    try fs.append("a/b.txt", " world", 2);
    try testing.expectEqualStrings("hello world", try fs.read("a/b.txt"));
    try testing.expectEqual(@as(i64, 2), fs.get("a/b.txt").?.modified);
    try testing.expectEqual(@as(i64, 1), fs.get("a/b.txt").?.created);
    try fs.makeDir("a/c/d", 3);
    try fs.write("a/c/e.txt", "e", 3, false);

    const files = try fs.list(testing.allocator, "a", false);
    defer testing.allocator.free(files);
    try testing.expectEqual(1, files.len);
    try testing.expectEqualStrings("b.txt", files[0]);
    const dirs = try fs.list(testing.allocator, "a", true);
    defer testing.allocator.free(dirs);
    try testing.expectEqual(1, dirs.len);
    try testing.expectEqualStrings("c", dirs[0]);
    try testing.expectEqual(@as(u64, 12), fs.usedBytes(""));

    try testing.expectError(error.NotEmpty, fs.remove("a/c", false));
    try fs.rename("a/c", "a/moved");
    try testing.expectEqualStrings("e", try fs.read("a/moved/e.txt"));
    try testing.expect(fs.isDir("a/moved/d"));
    try fs.remove("a/moved", true);
    try testing.expect(!fs.exists("a/moved/d"));
    try testing.expectError(error.IsADirectory, fs.read("a"));
    try testing.expectError(error.BadPath, fs.write("a/../x", "", 0, true));
    try testing.expectError(error.Exists, fs.makeDir("a/b.txt", 0));
}
