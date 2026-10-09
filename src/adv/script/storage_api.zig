//! The Data Cache and the persistent storage for scripts (HD DVD Annex Z.9, Z.11, Vol. 3 §10):
//! DataCache, PersistentStorageManager and PersistentStorageDevice (its Information Files, §10.4, and Base
//! Path, §10.6). Files on the devices are reached through FileIO. No VLC dependency.

const std = @import("std");
const js = @import("js.zig");
const host = @import("host.zig");
const pstore = @import("../pstore.zig");
const filecache = @import("../filecache.zig");
const files_mod = @import("files.zig");
const uri_mod = @import("../uri.zig");

const Value = js.Value;
const Script = host.Script;

// ---- DataCache (Z.9) --------------------------------------------------------------------------------------------------

pub const DataCache = struct {
    pub const js_owner = true;

    fn dataCacheSize(_: *Script) u32 {
        return filecache.data_cache_size / 1024;
    }
    fn availableFileCacheSize(s: *Script) u32 {
        const f = s.world.files orelse return 0;
        const avail = if (f.backend.cache_available) |a| a(f.backend.ctx) else f.free("file:///filecache/");
        return @intCast(@min(avail / 1024, std.math.maxInt(u32)));
    }
    fn streamingBufferSize(s: *Script) u32 {
        return s.world.streaming_buffer_kb;
    }

    pub const js_class: js.Class = .{
        .name = "DataCache",
        .members = &.{
            js.prop("dataCacheSize", dataCacheSize, null),
            js.prop("availableFileCacheSize", availableFileCacheSize, null),
            js.prop("streamingBufferSize", streamingBufferSize, null),
        },
    };
};

// ---- PersistentStorageManager (Z.11.1) ------------------------------------------------------------------------------

pub const Result = struct {
    pub const succeeded = 1;
    pub const argument = 2;
    pub const file_not_found = 3;
    pub const not_enough_space = 4;
};

const device_constants = [_]js.Member{
    js.constant("STORAGE_ALL", 0),
    js.constant("STORAGE_REQUIRED", 1),
    js.constant("STORAGE_ADDITIONAL", 2),
    js.constant("STORAGE_NETWORK", 3),
    js.constant("STATE_SLOT", 1),
    js.constant("STATE_MEDIA_SLOT", 2),
    js.constant("STATE_NON_SLOT", 3),
    js.constant("SUCCEEDED", Result.succeeded),
    js.constant("ARGUMENT", Result.argument),
    js.constant("FILE_NOT_FOUND", Result.file_not_found),
    js.constant("NOT_ENOUGH_SPACE", Result.not_enough_space),
};

fn storeOf(s: *Script) ?*pstore.Store {
    const f = s.world.files orelse return null;
    return f.store;
}

/// The per-context Device objects (one per device, Z.11.1.3).
pub const Devices = struct {
    objs: std.ArrayList(Value) = .empty,
    natives: std.ArrayList(*Device) = .empty,

    pub fn deinit(d: *Devices, s: *Script) void {
        for (d.objs.items) |v| s.cx.free(v);
        d.objs.deinit(s.gpa);
        for (d.natives.items) |n| s.gpa.destroy(n);
        d.natives.deinit(s.gpa);
    }
};

pub const Manager = struct {
    pub const js_owner = true;

    fn contentId(s: *Script) js.Error!Value {
        if (s.world.content_id.len == 0) return js.undefined;
        return s.cx.string(s.world.content_id);
    }

    fn getPersistentStorageDevices(s: *Script, kind: u32) js.Error!Value {
        const arr = try s.cx.array();
        errdefer s.cx.free(arr);
        const st = storeOf(s) orelse return arr;
        var n: u32 = 0;
        for (st.devices.items, 0..) |d, i| {
            const t: u32 = if (d.category == .required) 1 else 2;
            if (kind != 0 and kind != t) continue;
            try s.cx.setIndex(arr, n, try deviceObject(s, i));
            n += 1;
        }
        return arr;
    }

    fn deviceObject(s: *Script, i: usize) js.Error!Value {
        const d = &s.apis.devices;
        for (d.natives.items, d.objs.items) |n, v| if (n.index == i) return s.cx.dup(v);
        const n = try s.gpa.create(Device);
        errdefer s.gpa.destroy(n);
        n.* = .{ .index = i };
        try d.natives.append(s.gpa, n);
        errdefer _ = d.natives.pop();
        const v = try s.cx.wrap(Device, n);
        try d.objs.append(s.gpa, s.cx.dup(v));
        return v;
    }

    /// callManagementMenu (Z.11.1.3): only while paused. The player has no management menu of its own (the
    /// storage is in memory): it returns at once.
    fn callManagementMenu(s: *Script) js.Error!void {
        if (!s.world.paused) return error.InvalidCall;
    }

    /// saveBasePath(uri): the Assignment Information File next to that playlist (§10.6).
    fn saveBasePath(s: *Script, u: []const u8) js.Error!void {
        const f = s.world.files orelse return error.FileNotFound;
        if ((files_mod.Files.where(u) catch return error.Argument) != .store) return error.Argument;
        const name = std.fs.path.basenamePosix(u);
        if (name.len != 12 or !std.ascii.endsWithIgnoreCase(name, ".XPL")) return error.Argument;
        const kind: []const u8 = if (std.ascii.startsWithIgnoreCase(name, "VPLST")) "VPSAI" else if (std.ascii.startsWithIgnoreCase(name, "APLST")) "APSAI" else return error.Argument;
        if (!f.exists(u)) return error.FileNotFound;
        const st = f.store;
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(s.gpa);
        for (st.devices.items) |*d| {
            if (d.category != .additional or d.base_path.items.len == 0) continue;
            const id = (st.infoGet(d, "HD_DVD/info.txt", "device-id") catch null) orelse continue;
            defer s.gpa.free(id);
            try text.print(s.gpa, "[{s}]\"{s}\"\n", .{ d.base_path.items, id });
        }
        const out = try pstore.utf16be(s.gpa, text.items);
        defer s.gpa.free(out);
        const target = try std.fmt.allocPrint(s.gpa, "{s}{s}{s}.TXT", .{ u[0 .. u.len - name.len], kind, name[5..8] });
        defer s.gpa.free(target);
        f.write(target, out) catch return error.Argument;
    }

    pub const js_class: js.Class = .{
        .name = "PersistentStorageManager",
        .members = &([_]js.Member{
            js.prop("contentId", contentId, null),
            js.method("getPersistentStorageDevices", getPersistentStorageDevices),
            js.method("callManagementMenu", callManagementMenu),
            js.method("saveBasePath", saveBasePath),
        } ++ device_constants),
    };
};

// ---- PersistentStorageDevice (Z.11.2) -------------------------------------------------------------------------------

pub const Device = struct {
    index: usize,

    fn dev(d: *Device, cx: *js.Context) js.Error!*pstore.Device {
        const st = storeOf(Script.of(cx)) orelse return error.InvalidCall;
        if (d.index >= st.devices.items.len) return error.InvalidCall;
        return &st.devices.items[d.index];
    }

    fn deviceName(d: *Device, cx: *js.Context) js.Error!Value {
        return cx.string((try d.dev(cx)).name);
    }
    fn slot(d: *Device, cx: *js.Context) js.Error!Value {
        return cx.string((try d.dev(cx)).slot);
    }
    fn size(d: *Device, cx: *js.Context) js.Error!u32 {
        return @intCast((try d.dev(cx)).capacity / 1024);
    }
    fn availableSize(d: *Device, cx: *js.Context) js.Error!u32 {
        const x = try d.dev(cx);
        return @intCast((x.capacity -| pstore.Store.usedBytes(x)) / 1024);
    }
    /// A memory-backed device: as fast as anything (a nominal 100 Mbps).
    fn bitrate(d: *Device, cx: *js.Context) js.Error!u32 {
        _ = try d.dev(cx);
        return 100_000_000;
    }
    fn getType(d: *Device, cx: *js.Context) js.Error!u32 {
        return if ((try d.dev(cx)).category == .required) 1 else 2;
    }
    fn state(d: *Device, cx: *js.Context) js.Error!u32 {
        return if ((try d.dev(cx)).category == .required) 3 else 2;
    }
    fn getBasePath(d: *Device, cx: *js.Context) js.Error!Value {
        const x = try d.dev(cx);
        if (x.base_path.items.len == 0) return js.undefined;
        return cx.string(x.base_path.items);
    }
    /// basePath: at most 255 characters, not another device's (HDDVD_E_ARGUMENT).
    fn setBasePath(d: *Device, cx: *js.Context, v: []const u8) js.Error!void {
        const st = storeOf(Script.of(cx)) orelse return error.InvalidCall;
        const x = try d.dev(cx);
        if (v.len > 255) return error.Argument;
        if (st.byBasePath(v)) |o| if (o != x) return error.Argument;
        st.assignBasePath(x, v) catch return error.Argument;
    }

    fn checkKey(k: []const u8) js.Error!void {
        if (k.len == 0 or k.len > pstore.max_info_len) return error.Argument;
    }

    /// Reads key `k` of an Information File; the result comes in callback(result, key, value).
    fn get(cx: *js.Context, x: *pstore.Device, path: ?[]const u8, k: []const u8, cb: Value) js.Error!void {
        const s = Script.of(cx);
        const st = storeOf(s) orelse return error.InvalidCall;
        const key = try cx.string(k);
        const p = path orelse return post(s, cb, &.{ cx.number(Result.argument), key, js.null });
        if (x.fs.get(p) == null) return post(s, cb, &.{ cx.number(Result.file_not_found), key, js.null });
        const v = st.infoGet(x, p, k) catch null orelse return post(s, cb, &.{ cx.number(Result.argument), key, js.null });
        defer s.gpa.free(v);
        const vs = cx.string(v) catch |e| {
            cx.free(key);
            return e;
        };
        post(s, cb, &.{ cx.number(Result.succeeded), key, vs });
    }

    fn set(cx: *js.Context, x: *pstore.Device, path: []const u8, k: []const u8, value: ?[]const u8, cb: Value) js.Error!void {
        const s = Script.of(cx);
        const st = storeOf(s) orelse return error.InvalidCall;
        const key = try cx.string(k);
        const r: u32 = blk: {
            if (value) |v| {
                st.infoSet(x, path, k, v) catch |e| break :blk if (e == error.OutOfSpace) Result.file_not_found else Result.file_not_found;
            } else st.infoRemove(x, path, k) catch break :blk Result.file_not_found;
            break :blk Result.succeeded;
        };
        post(s, cb, &.{ cx.number(@floatFromInt(r)), key });
    }

    fn post(s: *Script, cb: Value, args: []const Value) void {
        if (!s.cx.isFunction(cb)) {
            for (args) |a| s.cx.free(a);
            return;
        }
        s.postCall(cb, args, "PersistentStorageDevice") catch {};
    }

    fn getInformation(d: *Device, cx: *js.Context, k: []const u8, cb: Value) js.Error!void {
        try checkKey(k);
        return get(cx, try d.dev(cx), "HD_DVD/info.txt", k, cb);
    }

    fn getProviderInformation(d: *Device, cx: *js.Context, k: []const u8, cb: Value) js.Error!void {
        try checkKey(k);
        const st = storeOf(Script.of(cx)) orelse return error.InvalidCall;
        var buf: [128]u8 = undefined;
        return get(cx, try d.dev(cx), st.infoPath(&buf, .provider, "") catch null, k, cb);
    }

    fn setProviderInformation(d: *Device, cx: *js.Context, k: []const u8, v: Value, cb: Value) js.Error!void {
        try checkKey(k);
        const st = storeOf(Script.of(cx)) orelse return error.InvalidCall;
        var buf: [128]u8 = undefined;
        const path = st.infoPath(&buf, .provider, "") catch return error.Argument;
        return setValue(d, cx, path, k, v, cb);
    }

    fn setValue(d: *Device, cx: *js.Context, path: []const u8, k: []const u8, v: Value, cb: Value) js.Error!void {
        if (js.c.JS_IsUndefined(v)) return set(cx, try d.dev(cx), path, k, null, cb);
        const value = try cx.toStringAlloc(cx.gpa, v);
        defer cx.gpa.free(value);
        if (value.len > pstore.max_info_len) return error.Argument;
        return set(cx, try d.dev(cx), path, k, value, cb);
    }

    fn getContentInformation(d: *Device, cx: *js.Context, cid: []const u8, k: []const u8, cb: Value) js.Error!void {
        if (!pstore.isGuid(cid)) return error.Argument;
        try checkKey(k);
        const st = storeOf(Script.of(cx)) orelse return error.InvalidCall;
        const x = try d.dev(cx);
        var buf: [128]u8 = undefined;
        const path = st.infoPath(&buf, .content, cid) catch return error.Argument;
        // No Content ID directory: ARGUMENT.
        const dir = std.fs.path.dirnamePosix(path) orelse return error.Argument;
        if (!x.fs.isDir(dir)) return get(cx, x, null, k, cb);
        return get(cx, x, path, k, cb);
    }

    fn setContentInformation(d: *Device, cx: *js.Context, cid: []const u8, k: []const u8, v: Value, cb: Value) js.Error!void {
        if (!pstore.isGuid(cid)) return error.Argument;
        try checkKey(k);
        const st = storeOf(Script.of(cx)) orelse return error.InvalidCall;
        var buf: [128]u8 = undefined;
        const path = st.infoPath(&buf, .content, cid) catch return error.Argument;
        return setValue(d, cx, path, k, v, cb);
    }

    pub const js_class: js.Class = .{
        .name = "PersistentStorageDevice",
        .members = &([_]js.Member{
            js.prop("deviceName", deviceName, null),
            js.prop("slot", slot, null),
            js.prop("size", size, null),
            js.prop("availableSize", availableSize, null),
            js.prop("bitrate", bitrate, null),
            js.prop("type", getType, null),
            js.prop("state", state, null),
            js.prop("basePath", getBasePath, setBasePath),
            js.method("getInformation", getInformation),
            js.method("getProviderInformation", getProviderInformation),
            js.method("setProviderInformation", setProviderInformation),
            js.method("getContentInformation", getContentInformation),
            js.method("setContentInformation", setContentInformation),
        } ++ device_constants),
    };
};

/// PersistentStorageDevice's constructor, with the constants scripts read from it (Z.11.1.1: "value properties of
/// constructor function").
pub fn exposeConstructors(cx: *js.Context) js.Error!void {
    try cx.exposeConstructor(&Device.js_class, "PersistentStorageDevice", error.TypeError, &device_constants);
}

// ---- tests --------------------------------------------------------------------------------------------------------

const testenv = @import("testenv.zig");

test "DataCache and the persistent storage" {
    const e = try testenv.Env.create();
    defer e.destroy();
    _ = try e.store.addDevice(.additional, "SD Card", "slot1", 1 << 20);
    try e.run(
        \\assertEq(DataCache.dataCacheSize, 65536); assert(DataCache.availableFileCacheSize > 0); assertEq(DataCache.streamingBufferSize, 0);
        \\var all = PersistentStorageManager.getPersistentStorageDevices(PersistentStorageDevice.STORAGE_ALL);
        \\assertEq(all.length, 2); assertEq(all[0], PersistentStorageManager.getPersistentStorageDevices(1)[0], "same object");
        \\var req = all[0], sd = all[1];
        \\assertEq(req.type, 1); assertEq(req.state, 3); assertEq(sd.type, 2); assertEq(sd.state, 2); assertEq(sd.size, 1024);
        \\assertEq(sd.deviceName, "SD Card"); assertEq(sd.basePath, undefined);
        \\sd.basePath = "sd"; assertEq(sd.basePath, "sd");
        \\assertThrows(function () { req.basePath = "sd"; }, "HDDVD_E_ARGUMENT");
        \\assertThrows(function () { PersistentStorageManager.callManagementMenu(); }, "HDDVD_E_INVALIDCALL");
        \\assertThrows(function () { new PersistentStorageDevice(); }, TypeError);
        \\var r = {};
        \\req.getInformation("device-id", cb(function (res, key, value) { r.id = res + ":" + key + ":" + value.length; }));
        \\req.getInformation("nothing", cb(function (res, key, value) { r.none = res + ":" + value; }));
        \\req.setProviderInformation("score", "42", cb(function (res, key) { r.set = res + ":" + key; }));
        \\assertThrows(function () { req.getContentInformation("not-a-guid", "k", function () {}); }, "HDDVD_E_ARGUMENT");
        \\req.getContentInformation("00000000-0000-0000-0000-000000000001", "k", cb(function (res) { r.noDir = res; }));
        \\req.setContentInformation("00000000-0000-0000-0000-000000000001", "k", "v", cb(function (res) { r.setC = res; }));
    , "storage1.js");
    try e.run(
        \\assertEq(r.id, "1:device-id:36"); assertEq(r.none, "2:null"); assertEq(r.set, "1:score"); assertEq(r.noDir, 2); assertEq(r.setC, 1);
        \\var req = PersistentStorageManager.getPersistentStorageDevices(1)[0];
        \\req.getProviderInformation("score", cb(function (res, key, value) { r.score = value; }));
        \\req.getContentInformation("00000000-0000-0000-0000-000000000001", "k", cb(function (res, key, value) { r.k = value; }));
        \\req.setProviderInformation("score", undefined, cb(function (res) { r.removed = res; }));
    , "storage2.js");
    try e.run(
        \\assertEq(r.score, "42"); assertEq(r.k, "v"); assertEq(r.removed, 1);
        \\req.getProviderInformation("score", cb(function (res, key, value) { r.gone = res; }));
    , "storage3.js");
    try e.run("assertEq(r.gone, 2);", "storage4.js");
}
