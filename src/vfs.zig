//! The disc's file system, whatever holds it: a folder (mounted disc, or a copy of one) or a UDF disc image
//! (.iso), read directly with udf.zig so no OS mount is needed. Paths are relative to the disc root, e.g.
//! "HVDVD_TS/HV000I01.IFO".
//!
//! On an AACS-encrypted disc the file system also decrypts (`setKeys`): files read whole come back with
//! their wrapped entries decrypted, and EVOB files decrypt their packs as they are read, so the rest of
//! the plugin only ever sees plain data.

const std = @import("std");
const vlc = @import("vlc");
const vlcio = @import("vlcio.zig");
const udf = @import("udf.zig");
const aacs = @import("aacs.zig");

pub const Error = error{NotFound} || vlcio.Error || udf.Error;

extern fn hddvd_list_dir(obj: *vlc.vlc_object_t, url: [*:0]const u8, cb: *const fn (?*anyopaque, [*:0]const u8) callconv(.c) void, ctx: ?*anyopaque) c_int;

pub const Fs = struct {
    gpa: std.mem.Allocator,
    obj: *vlc.vlc_object_t,
    backend: union(enum) {
        /// Disc root folder (the folder that contains HVDVD_TS).
        dir: []u8,
        image: struct { file: vlcio.File, volume: udf.Volume },
    },
    /// The disc's AACS keys (owned; null: nothing to decrypt). Set once, before any reader thread starts.
    keys: ?*aacs.Keys = null,
    /// Totals over the closed EVOB files, for the log (files are closed on several threads).
    decrypted: std.atomic.Value(u64) = .init(0),
    no_key: std.atomic.Value(u64) = .init(0),
    bad: std.atomic.Value(u64) = .init(0),

    /// `path` is a disc image, the disc root folder, or its HVDVD_TS subfolder.
    pub fn open(gpa: std.mem.Allocator, obj: *vlc.vlc_object_t, path: []const u8) Error!*Fs {
        const fs = try gpa.create(Fs);
        errdefer gpa.destroy(fs);
        fs.* = .{ .gpa = gpa, .obj = obj, .backend = undefined };

        // A regular file with a UDF signature is an image; anything else is treated as a folder.
        const url = try vlcio.pathToUrl(gpa, path);
        defer gpa.free(url);
        if (vlcio.File.open(obj, url)) |file| {
            fs.backend = .{ .image = .{ .file = file, .volume = undefined } };
            const img = &fs.backend.image;
            if (!udf.Volume.probe(img, imageRead)) {
                img.file.close();
                return error.NotFound;
            }
            img.volume = udf.Volume.open(gpa, img, imageRead) catch |err| {
                img.file.close();
                return err;
            };
            return fs;
        } else |_| {}

        const trimmed = std.mem.trimEnd(u8, path, "/\\");
        const root = if (std.ascii.endsWithIgnoreCase(trimmed, "HVDVD_TS"))
            trimmed[0 .. trimmed.len - "HVDVD_TS".len]
        else
            trimmed;
        fs.backend = .{ .dir = try gpa.dupe(u8, std.mem.trimEnd(u8, root, "/\\")) };
        return fs;
    }

    pub fn close(fs: *Fs) void {
        if (fs.keys) |k| {
            vlc.vlc_Log(fs.obj, vlc.VLC_MSG_DBG, "hddvd", @src().file, @src().line, @src().fn_name, "AACS: %llu packs decrypted, %llu without a key, %llu failing the check", fs.decrypted.load(.monotonic), fs.no_key.load(.monotonic), fs.bad.load(.monotonic));
            fs.gpa.destroy(k);
        }
        switch (fs.backend) {
            .dir => |d| fs.gpa.free(d),
            .image => |*img| {
                img.volume.deinit();
                img.file.close();
            },
        }
        fs.gpa.destroy(fs);
    }

    fn imageRead(ctx: *anyopaque, offset: u64, buf: []u8) udf.Error!usize {
        const img: *@FieldType(@FieldType(Fs, "backend"), "image") = @ptrCast(@alignCast(ctx));
        return img.file.pread(offset, buf) catch error.ReadFailed;
    }

    /// The disc's label: an image's UDF volume identifier; empty for a folder.
    pub fn label(fs: *const Fs) []const u8 {
        return switch (fs.backend) {
            .image => |*img| img.volume.label(),
            .dir => "",
        };
    }

    pub fn isImage(fs: *const Fs) bool {
        return fs.backend == .image;
    }

    /// Decrypt with these keys from now on (takes them; `gpa.create`d).
    pub fn setKeys(fs: *Fs, keys: *aacs.Keys) void {
        keys.setPlaylist(null);
        fs.keys = keys;
    }

    /// The playlist now loaded ("VPLST000.XPL"…; null: Standard Content), whose key file packs are tried
    /// with first. Any thread may call it.
    pub fn setPlaylist(fs: *Fs, name: ?[]const u8) void {
        if (fs.keys) |k| k.setPlaylist(name);
    }

    /// Decrypts data of the disc that did not come through `readFile` (an archive multiplexed in an EVOB's
    /// packs).
    pub fn decrypt(fs: *const Fs, d: []u8) void {
        if (fs.keys) |k| aacs.decryptFile(d, k);
    }

    fn isEvob(rel: []const u8) bool {
        return std.ascii.endsWithIgnoreCase(rel, ".EVO");
    }

    /// Opens a file by disc-relative path; error.NotFound if it does not exist.
    pub fn openFile(fs: *Fs, rel: []const u8) Error!File {
        switch (fs.backend) {
            .dir => |root| {
                const p = try std.fmt.allocPrint(fs.gpa, "{s}/{s}", .{ root, rel });
                defer fs.gpa.free(p);
                const url = try vlcio.pathToUrl(fs.gpa, p);
                defer fs.gpa.free(url);
                const f = vlcio.File.open(fs.obj, url) catch return error.NotFound;
                return .{ .fs = fs, .size = f.size, .impl = .{ .stream = f }, .crypt = fs.streamFor(rel) };
            },
            .image => |*img| {
                const info = img.volume.lookup(rel) catch |err| switch (err) {
                    error.NotFound => return error.NotFound,
                    else => return err,
                };
                if (info.is_dir) {
                    img.volume.freeInfo(info);
                    return error.NotFound;
                }
                return .{ .fs = fs, .size = info.size, .impl = .{ .image = info }, .crypt = fs.streamFor(rel) };
            },
        }
    }

    fn streamFor(fs: *const Fs, rel: []const u8) ?aacs.Stream {
        return if (fs.keys != null and isEvob(rel)) .{} else null;
    }

    /// Whether a disc-relative file exists. A folder is listed rather than the file opened, so that a missing file
    /// logs no error from VLC's file access.
    pub fn exists(fs: *Fs, rel: []const u8) bool {
        switch (fs.backend) {
            .image => |*img| {
                const info = img.volume.lookup(rel) catch return false;
                defer img.volume.freeInfo(info);
                return !info.is_dir;
            },
            .dir => {
                const slash = std.mem.lastIndexOfScalar(u8, rel, '/');
                const parent = if (slash) |i| rel[0..i] else "";
                const name = if (slash) |i| rel[i + 1 ..] else rel;
                const names = fs.listDir(fs.gpa, parent) catch return false;
                defer freeNames(fs.gpa, names);
                for (names) |n| if (std.mem.eql(u8, n, name)) return true;
                return false;
            },
        }
    }

    /// Names of the entries of a disc-relative folder (free with freeNames).
    pub fn listDir(fs: *Fs, gpa: std.mem.Allocator, rel: []const u8) Error![][]u8 {
        switch (fs.backend) {
            .image => |*img| return img.volume.listDir(gpa, rel) catch |err| switch (err) {
                error.NotFound => error.NotFound,
                else => err,
            },
            .dir => |root| {
                const p = try std.fmt.allocPrint(fs.gpa, "{s}/{s}", .{ root, rel });
                defer fs.gpa.free(p);
                const url = try vlcio.pathToUrl(fs.gpa, p);
                defer fs.gpa.free(url);
                var ctx: ListCtx = .{ .gpa = gpa };
                errdefer freeNames(gpa, ctx.names.items);
                if (hddvd_list_dir(fs.obj, url.ptr, ListCtx.add, &ctx) != vlc.VLC_SUCCESS) return error.NotFound;
                if (ctx.failed) return error.OutOfMemory;
                return ctx.names.toOwnedSlice(gpa);
            },
        }
    }

    const ListCtx = struct {
        gpa: std.mem.Allocator,
        names: std.ArrayList([]u8) = .empty,
        failed: bool = false,

        fn add(p: ?*anyopaque, name: [*:0]const u8) callconv(.c) void {
            const ctx: *ListCtx = @ptrCast(@alignCast(p));
            const n = ctx.gpa.dupe(u8, std.mem.span(name)) catch return {
                ctx.failed = true;
            };
            ctx.names.append(ctx.gpa, n) catch {
                ctx.gpa.free(n);
                ctx.failed = true;
            };
        }
    };

    /// Reads a whole file (decrypted), or returns null if it does not exist.
    pub fn readFile(fs: *Fs, gpa: std.mem.Allocator, rel: []const u8) Error!?[]u8 {
        var f = fs.openFile(rel) catch |err| switch (err) {
            error.NotFound => return null,
            else => return err,
        };
        defer f.close();
        const buf = try gpa.alloc(u8, @intCast(f.size));
        errdefer gpa.free(buf);
        if (try f.pread(0, buf) != buf.len) return error.ReadFailed;
        if (fs.keys) |k| if (f.crypt == null) aacs.decryptFile(buf, k);
        return buf;
    }
};

pub const freeNames = udf.freeNames;

pub const File = struct {
    fs: *Fs,
    size: u64,
    impl: union(enum) {
        stream: vlcio.File,
        image: udf.FileInfo,
    },
    /// An EVOB of an encrypted disc: its packs are decrypted as they are read.
    crypt: ?aacs.Stream = null,

    pub fn close(f: *File) void {
        if (f.crypt) |c| {
            _ = f.fs.decrypted.fetchAdd(c.decrypted, .monotonic);
            _ = f.fs.no_key.fetchAdd(c.no_key, .monotonic);
            _ = f.fs.bad.fetchAdd(c.bad, .monotonic);
        }
        switch (f.impl) {
            .stream => |*s| s.close(),
            .image => |info| f.fs.backend.image.volume.freeInfo(info),
        }
    }

    /// Reads up to buf.len bytes at offset (short only at end of file), decrypted.
    pub fn pread(f: *File, offset: u64, buf: []u8) Error!usize {
        const n = try f.preadRaw(offset, buf);
        if (f.crypt != null) f.decryptPacks(offset, buf[0..n]);
        return n;
    }

    /// Reads as stored on the disc.
    fn preadRaw(f: *File, offset: u64, buf: []u8) Error!usize {
        return switch (f.impl) {
            .stream => |*s| try s.pread(offset, buf),
            .image => |info| try f.fs.backend.image.volume.pread(info, offset, buf),
        };
    }

    /// Decrypts `data`, just read at `offset`, pack by pack. A pack only partly in it is read whole on its
    /// own (the stream sees it as a jump, which costs a read-back to its navigation pack).
    fn decryptPacks(f: *File, offset: u64, data: []u8) void {
        const st = &f.crypt.?;
        const keys = f.fs.keys orelse return;
        const reader: aacs.Stream.Reader = .{ .ctx = f, .read = readPack };
        var i: usize = 0;
        while (i < data.len) {
            const pos = offset + i;
            const start = pos - pos % aacs.pack_len;
            const within: usize = @intCast(pos - start);
            const take = @min(aacs.pack_len - within, data.len - i);
            if (take == aacs.pack_len) {
                st.pack(data[i..][0..aacs.pack_len], start, keys, reader);
            } else {
                var tmp: [aacs.pack_len]u8 = undefined;
                if (!readPack(f, start, &tmp)) return; // the file's last, partial pack: not a pack
                st.pack(&tmp, start, keys, reader);
                @memcpy(data[i..][0..take], tmp[within..][0..take]);
            }
            i += take;
        }
    }

    fn readPack(ctx: *anyopaque, off: u64, buf: *[aacs.pack_len]u8) bool {
        const f: *File = @ptrCast(@alignCast(ctx));
        return (f.preadRaw(off, buf) catch return false) == buf.len;
    }

    /// `f` is the file after `prev` in an EVOB split over several files, and is read from its start right
    /// after `prev`'s end: the EVOBU in progress continues into it.
    pub fn continueFrom(f: *File, prev: *const File) void {
        const c = if (f.crypt) |*x| x else return;
        const p = prev.crypt orelse return;
        if (p.next != prev.size or c.next != 0) return;
        c.cpi = p.cpi;
        c.scrambled = p.scrambled;
    }
};
