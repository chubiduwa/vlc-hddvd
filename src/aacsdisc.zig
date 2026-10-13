//! The AACS keys of a disc (the disc-side half of aacs.zig): the AACS folder (found by content: the first
//! root folder holding MKBROM.AACS, the *_BAK mirrors behind), its title key files, and the volume unique
//! key (VUK) of each, looked up by disc ID in a KEYDB.cfg (libaacs's syntax and locations, or
//! --hddvd-keydb=<file>). The keys go to `vfs.Fs.setKeys`, which decrypts from then on.
//!
//! A disc without an AACS folder, or a decrypted copy that kept one, plays as it is. An encrypted disc
//! whose keys cannot be found is reported to the user (`report`), and does not open.

const std = @import("std");
const builtin = @import("builtin");
const vlc = @import("vlc");
const vfs = @import("vfs.zig");
const aacs = @import("aacs.zig");

const gpa = std.heap.c_allocator;

extern fn hddvd_inherit_string(obj: *vlc.vlc_object_t, name: [*:0]const u8) ?[*:0]u8;
extern fn hddvd_free(p: ?*anyopaque) void;
extern fn hddvd_dialog_error(obj: *vlc.vlc_object_t, title: [*:0]const u8, text: [*:0]const u8) void;

fn log(obj: *vlc.vlc_object_t, prio: c_int, src: std.builtin.SourceLocation, comptime fmt: [*:0]const u8, args: anytype) void {
    @call(.auto, vlc.vlc_Log, .{ obj, prio, "hddvd", src.file, @as(c_uint, src.line), src.fn_name, fmt } ++ args);
}

/// Where the README explains how to play encrypted discs.
const help_url = "https://github.com/chubiduwa/vlc-hddvd#encrypted-discs";

/// Why an encrypted disc has no keys.
pub const Missing = union(enum) {
    /// No KEYDB.cfg was found.
    no_keydb,
    /// The KEYDB.cfg set in the preferences (--hddvd-keydb) cannot be read.
    unreadable_keydb,
    /// The database has no entry for the disc (its first title key file's disc ID).
    unknown_disc: [20]u8,
    /// The database's VUK for the disc does not open its title key file.
    wrong_key: [20]u8,
};

pub const Result = union(enum) {
    /// Nothing to decrypt: no AACS folder, or a copy whose content is already decrypted.
    none,
    /// The disc's keys (`gpa.create`d), for `vfs.Fs.setKeys`.
    keys: *aacs.Keys,
    /// The disc is encrypted and cannot be played.
    missing: Missing,
};

/// Probes the disc (read as stored: call it before `setKeys`).
pub fn load(obj: *vlc.vlc_object_t, fs: *vfs.Fs) Result {
    const dir = findDir(fs) orelse return .none;
    defer gpa.free(dir);

    const names = fs.listDir(gpa, dir) catch return .none;
    defer vfs.freeNames(gpa, names);

    const db = loadDbText(obj);
    const text = switch (db) {
        .text => |t| t,
        else => null,
    };
    defer if (text) |t| gpa.free(t);
    if (text) |t| log(obj, vlc.VLC_MSG_DBG, @src(), "AACS: the key database has %u disc entries", .{@as(c_uint, @intCast(aacs.countDb(t)))});

    var keys: aacs.Keys = .{};
    var missing: ?Missing = switch (db) {
        .text => null,
        .none => .no_keydb,
        .unreadable => .unreadable_keydb,
    };
    for (names) |name| {
        if (!std.ascii.startsWithIgnoreCase(name, "VTKF") or !std.ascii.endsWithIgnoreCase(name, ".AACS")) continue;
        const rel = std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir, name }) catch continue;
        defer gpa.free(rel);
        const bytes = (fs.readFile(gpa, rel) catch null) orelse continue;
        defer gpa.free(bytes);
        if (bytes.len != aacs.tkf_len) continue;
        const tkf_bytes: *const [aacs.tkf_len]u8 = bytes[0..aacs.tkf_len];

        const id = aacs.discId(bytes);
        const vuk = aacs.findVuk(text orelse continue, id) orelse {
            if (missing == null) missing = .{ .unknown_disc = id };
            continue;
        };
        const tkf = aacs.parseTkf(tkf_bytes, vuk) catch |err| {
            if (err == error.BadMac) missing = .{ .wrong_key = id };
            continue;
        };
        _ = keys.add(tkf, std.mem.sliceTo(tkf_bytes[0x10..][0..12], 0));
    }

    if (keys.n > 0) {
        log(obj, vlc.VLC_MSG_INFO, @src(), "AACS: %u title key file(s) known", .{@as(c_uint, @intCast(keys.n))});
        const k = gpa.create(aacs.Keys) catch return .{ .missing = .no_keydb };
        k.* = keys;
        return .{ .keys = k };
    }
    if (!contentEncrypted(fs)) {
        log(obj, vlc.VLC_MSG_DBG, @src(), "AACS: the content is not encrypted (a decrypted copy)", .{});
        return .none;
    }
    return .{ .missing = missing orelse .no_keydb };
}

/// The AACS folder: the first root folder holding MKBROM.AACS, preferring those not named *_BAK.
fn findDir(fs: *vfs.Fs) ?[]u8 {
    const dirs = fs.listDir(gpa, "") catch return null;
    defer vfs.freeNames(gpa, dirs);
    for ([2]bool{ true, false }) |skip_bak| {
        for (dirs) |name| {
            if (skip_bak and std.ascii.endsWithIgnoreCase(name, "_BAK")) continue;
            const rel = std.fmt.allocPrint(gpa, "{s}/MKBROM.AACS", .{name}) catch return null;
            defer gpa.free(rel);
            if (fs.exists(rel)) return gpa.dupe(u8, name) catch null;
        }
    }
    return null;
}

/// Whether the disc's content is still encrypted: an Advanced Content playlist still wrapped, or
/// scrambled packs at the start of the first EVOBs (a decrypted copy keeps the AACS folder, but clears
/// both).
fn contentEncrypted(fs: *vfs.Fs) bool {
    if (fs.listDir(gpa, "ADV_OBJ")) |names| {
        defer vfs.freeNames(gpa, names);
        for (names) |name| {
            if (!std.ascii.endsWithIgnoreCase(name, ".XPL")) continue;
            const rel = std.fmt.allocPrint(gpa, "ADV_OBJ/{s}", .{name}) catch continue;
            defer gpa.free(rel);
            const d = (fs.readFile(gpa, rel) catch null) orelse continue;
            defer gpa.free(d);
            if (aacs.fileEncrypted(d)) return true;
        }
    } else |_| {}

    const names = fs.listDir(gpa, "HVDVD_TS") catch return false;
    defer vfs.freeNames(gpa, names);
    var evobs: usize = 0;
    for (names) |name| {
        if (!std.ascii.endsWithIgnoreCase(name, ".EVO")) continue;
        if (evobs == 4) break;
        evobs += 1;
        const rel = std.fmt.allocPrint(gpa, "HVDVD_TS/{s}", .{name}) catch continue;
        defer gpa.free(rel);
        var f = fs.openFile(rel) catch continue;
        defer f.close();
        var pack: [aacs.pack_len]u8 = undefined;
        for (0..512) |k| {
            if ((f.pread(k * aacs.pack_len, &pack) catch break) != pack.len) break;
            if (aacs.classifyPack(&pack) == .scrambled) return true;
        }
    }
    return false;
}

/// Tells the user why an encrypted disc cannot play (a VLC error dialog, and the log).
pub fn report(obj: *vlc.vlc_object_t, why: Missing) void {
    var buf: [1024]u8 = undefined;
    var hex: [40]u8 = undefined;
    const text = switch (why) {
        .no_keydb => std.fmt.bufPrintSentinel(&buf,
            \\This HD DVD is encrypted (AACS). Playing it needs a key database, KEYDB.cfg, with the disc's key, and none was found.
            \\
            \\Put KEYDB.cfg in {s}, or set its path in Preferences (All > Input / Codecs > Access modules > HD DVD).
            \\
            \\See {s}
        , .{ default_hint, help_url }, 0),
        .unreadable_keydb => std.fmt.bufPrintSentinel(&buf,
            \\This HD DVD is encrypted (AACS). Playing it needs a key database, KEYDB.cfg, with the disc's key, and the one set in Preferences cannot be read.
            \\
            \\Check its path (All > Input / Codecs > Access modules > HD DVD).
            \\
            \\See {s}
        , .{help_url}, 0),
        .unknown_disc => |id| std.fmt.bufPrintSentinel(&buf,
            \\This HD DVD is encrypted (AACS), and the key database has no key for it (disc ID {s}).
            \\
            \\Add the disc's entry to KEYDB.cfg.
            \\
            \\See {s}
        , .{ idHex(&hex, &id), help_url }, 0),
        .wrong_key => |id| std.fmt.bufPrintSentinel(&buf,
            \\This HD DVD is encrypted (AACS), and the key database's key for it is wrong (disc ID {s}).
            \\
            \\Correct the disc's entry in KEYDB.cfg.
            \\
            \\See {s}
        , .{ idHex(&hex, &id), help_url }, 0),
    } catch return;
    log(obj, vlc.VLC_MSG_ERR, @src(), "%s", .{text.ptr});
    hddvd_dialog_error(obj, "Encrypted HD DVD", text.ptr);
}

fn idHex(buf: *[40]u8, id: *const [20]u8) []const u8 {
    const hex = "0123456789ABCDEF";
    for (id, 0..) |b, i| {
        buf[i * 2] = hex[b >> 4];
        buf[i * 2 + 1] = hex[b & 15];
    }
    return buf;
}

// ---- the key database ---------------------------------------------------------------------------------------

/// Where libaacs looks for KEYDB.cfg: its configuration folder under an environment variable.
const default_paths: []const struct { env: []const u8, rel: []const u8 } = switch (builtin.os.tag) {
    .windows => &.{.{ .env = "APPDATA", .rel = "\\aacs\\KEYDB.cfg" }},
    .macos => &.{
        .{ .env = "HOME", .rel = "/Library/Preferences/aacs/KEYDB.cfg" },
        .{ .env = "HOME", .rel = "/.config/aacs/KEYDB.cfg" },
    },
    else => &.{
        .{ .env = "XDG_CONFIG_HOME", .rel = "/aacs/KEYDB.cfg" },
        .{ .env = "HOME", .rel = "/.config/aacs/KEYDB.cfg" },
    },
};

/// The same, for the user.
const default_hint = switch (builtin.os.tag) {
    .windows => "%APPDATA%\\aacs\\",
    .macos => "~/Library/Preferences/aacs/ or ~/.config/aacs/",
    else => "~/.config/aacs/",
};

const DbText = union(enum) { text: []u8, none, unreadable };

/// The KEYDB.cfg text (owned): --hddvd-keydb=<file> if set, else the first of libaacs's locations that
/// exists.
fn loadDbText(obj: *vlc.vlc_object_t) DbText {
    if (hddvd_inherit_string(obj, "hddvd-keydb")) |s| {
        defer hddvd_free(s);
        if (readPath(std.mem.span(s))) |t| {
            log(obj, vlc.VLC_MSG_DBG, @src(), "AACS: key database %s", .{s});
            return .{ .text = t };
        }
        log(obj, vlc.VLC_MSG_ERR, @src(), "AACS: cannot read the key database %s", .{s});
        return .unreadable;
    }
    for (default_paths) |d| {
        const base = env(d.env) orelse continue;
        defer gpa.free(base);
        const path = std.fmt.allocPrintSentinel(gpa, "{s}{s}", .{ base, d.rel }, 0) catch return .none;
        defer gpa.free(path);
        if (readPath(path)) |t| {
            log(obj, vlc.VLC_MSG_DBG, @src(), "AACS: key database %s", .{path.ptr});
            return .{ .text = t };
        }
    }
    log(obj, vlc.VLC_MSG_DBG, @src(), "AACS: no key database", .{});
    return .none;
}

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]u8;

/// An environment variable (owned): from the process environment on Windows (UTF-16, so any user name
/// works), from the C library elsewhere (the same one VLC uses).
fn env(name: []const u8) ?[]u8 {
    if (builtin.os.tag == .windows) {
        const e: std.process.Environ = .{ .block = .global };
        return e.getAlloc(gpa, name) catch null;
    }
    var z: [64]u8 = undefined;
    const nz = std.fmt.bufPrintSentinel(&z, "{s}", .{name}, 0) catch return null;
    const v = getenv(nz.ptr) orelse return null;
    return gpa.dupe(u8, std.mem.span(v)) catch null;
}

/// Reads a local file straight from the OS. Not through VLC: a stream would run VLC's stream filters and
/// playlist probes over it. Zig's own file API uses no C runtime, so nothing crosses VLC's on Windows.
fn readPath(path: []const u8) ?[]u8 {
    var t: std.Io.Threaded = .init_single_threaded;
    return std.Io.Dir.cwd().readFileAlloc(t.io(), path, gpa, .limited(64 << 20)) catch null;
}
