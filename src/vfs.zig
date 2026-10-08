//! The disc's file system, whatever holds it: a folder (mounted disc, or a copy of one) or a UDF disc image
//! (.iso), read directly with udf.zig so no OS mount is needed. Paths are relative to the disc root, e.g.
//! "HVDVD_TS/HV000I01.IFO".

const std = @import("std");
const vlc = @import("vlc");
const vlcio = @import("vlcio.zig");
const udf = @import("udf.zig");

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

    pub fn isImage(fs: *const Fs) bool {
        return fs.backend == .image;
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
                return .{ .fs = fs, .size = f.size, .impl = .{ .stream = f } };
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
                return .{ .fs = fs, .size = info.size, .impl = .{ .image = info } };
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

    /// Reads a whole file, or returns null if it does not exist.
    pub fn readFile(fs: *Fs, gpa: std.mem.Allocator, rel: []const u8) Error!?[]u8 {
        var f = fs.openFile(rel) catch |err| switch (err) {
            error.NotFound => return null,
            else => return err,
        };
        defer f.close();
        const buf = try gpa.alloc(u8, @intCast(f.size));
        errdefer gpa.free(buf);
        if (try f.pread(0, buf) != buf.len) return error.ReadFailed;
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

    pub fn close(f: *File) void {
        switch (f.impl) {
            .stream => |*s| s.close(),
            .image => |info| f.fs.backend.image.volume.freeInfo(info),
        }
    }

    /// Reads up to buf.len bytes at offset (short only at end of file).
    pub fn pread(f: *File, offset: u64, buf: []u8) Error!usize {
        return switch (f.impl) {
            .stream => |*s| try s.pread(offset, buf),
            .image => |info| try f.fs.backend.image.volume.pread(info, offset, buf),
        };
    }
};
