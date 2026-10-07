//! File access through VLC's own streams (vlc_stream_NewURL), so the plugin never mixes its C runtime's
//! file handles with VLC's (they differ on Windows) and a future UDF/ISO reader can sit behind the same API.

const std = @import("std");
const vlc = @import("vlc");

extern fn hddvd_stream_get_size(s: *vlc.stream_t, size: *u64) c_int;
extern fn hddvd_stream_delete(s: *vlc.stream_t) void;

pub const Error = error{ OpenFailed, ReadFailed, SeekFailed, OutOfMemory };

/// Builds a file:// URL for a local path (percent-encoding everything outside the URL-safe set).
pub fn pathToUrl(gpa: std.mem.Allocator, path: []const u8) Error![:0]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "file://");
    // Windows drive paths ("C:\x") become file:///C:/x.
    if (path.len >= 2 and path[1] == ':') try out.append(gpa, '/');
    for (path) |c| {
        switch (c) {
            'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~', '/', ':' => try out.append(gpa, c),
            '\\' => try out.append(gpa, '/'),
            else => {
                const hex = "0123456789ABCDEF";
                try out.appendSlice(gpa, &.{ '%', hex[c >> 4], hex[c & 15] });
            },
        }
    }
    return out.toOwnedSliceSentinel(gpa, 0);
}

/// An open VLC stream with positional reads.
pub const File = struct {
    s: *vlc.stream_t,
    size: u64,
    pos: u64 = 0,

    pub fn open(obj: *vlc.vlc_object_t, url: [:0]const u8) Error!File {
        const s = vlc.vlc_stream_NewURL(obj, url.ptr) orelse return error.OpenFailed;
        var size: u64 = 0;
        if (hddvd_stream_get_size(s, &size) != vlc.VLC_SUCCESS) {
            hddvd_stream_delete(s);
            return error.OpenFailed;
        }
        return .{ .s = s, .size = size };
    }

    pub fn close(f: *File) void {
        hddvd_stream_delete(f.s);
    }

    /// Reads up to buf.len bytes at offset; returns the number read (short only at end of file).
    pub fn pread(f: *File, offset: u64, buf: []u8) Error!usize {
        if (offset != f.pos) {
            if (vlc.vlc_stream_Seek(f.s, offset) != vlc.VLC_SUCCESS) return error.SeekFailed;
            f.pos = offset;
        }
        var done: usize = 0;
        while (done < buf.len) {
            const n = vlc.vlc_stream_Read(f.s, buf[done..].ptr, buf.len - done);
            if (n < 0) return error.ReadFailed;
            if (n == 0) break;
            done += @intCast(n);
        }
        f.pos += done;
        return done;
    }

    /// Reads the whole file into memory.
    pub fn readAll(f: *File, gpa: std.mem.Allocator) Error![]u8 {
        const buf = try gpa.alloc(u8, @intCast(f.size));
        errdefer gpa.free(buf);
        if (try f.pread(0, buf) != buf.len) return error.ReadFailed;
        return buf;
    }
};

/// Opens url and returns its whole content, or null if it cannot be opened.
pub fn readFile(gpa: std.mem.Allocator, obj: *vlc.vlc_object_t, url: [:0]const u8) Error!?[]u8 {
    var f = File.open(obj, url) catch return null;
    defer f.close();
    return try f.readAll(gpa);
}
