//! The Network API (HD DVD Annex Z.8, Vol. 3 Ch. 9): Network, HTTPClient and HTTPHeader.
//!
//! The servers HD DVD discs talked to are gone, and this player has no network connection (the Network
//! Connection parameter is false): a request goes to STATE_LOADING, then STATE_ERROR with status 10 "No
//! connection could be made to the server", as Z.8.2.3 defines for a player that is not connected. Everything
//! else (headers and their limits, the states, open/abort, the exceptions) follows Z.8. No VLC dependency.

const std = @import("std");
const js = @import("js.zig");
const host = @import("host.zig");
const dom_api = @import("dom_api.zig");

const c = js.c;
const Value = js.Value;
const Script = host.Script;

pub const State = struct {
    clients: std.ArrayList(*Client) = .empty,

    pub fn deinit(st: *State, s: *Script) void {
        for (st.clients.items) |cl| {
            if (cl.obj) |o| js.kill(s.cx.rt, o);
            cl.free(s);
        }
        st.clients.deinit(s.gpa);
    }
};

/// Headers Script may not set or read (Table 9.2.3.2-1).
const protected = [_][]const u8{ "Date", "Authorization", "User-Agent", "Content-Length", "HDDVD-Disc-ID", "HDDVD-Throughput", "Cookie" };

fn isProtected(name: []const u8) bool {
    for (protected) |p| if (std.ascii.eqlIgnoreCase(p, name)) return true;
    return false;
}

fn validName(name: []const u8) bool {
    for (name) |ch| if (ch <= 32 or ch >= 127 or std.mem.indexOfScalar(u8, "()<>@,;:\\\"/[]?={}", ch) != null) return false;
    return true;
}

pub const Headers = struct {
    gpa: std.mem.Allocator,
    fields: std.ArrayList(struct { name: []u8, value: []u8 }) = .empty,
    /// Response headers are read-only.
    response: bool = false,

    const max_fields = 64;
    const max_size = 256;

    fn deinit(h: *Headers) void {
        for (h.fields.items) |f| {
            h.gpa.free(f.name);
            h.gpa.free(f.value);
        }
        h.fields.deinit(h.gpa);
    }

    fn clear(h: *Headers) void {
        for (h.fields.items) |f| {
            h.gpa.free(f.name);
            h.gpa.free(f.value);
        }
        h.fields.clearRetainingCapacity();
    }

    fn find(h: *const Headers, name: []const u8) ?usize {
        for (h.fields.items, 0..) |f, i| if (std.ascii.eqlIgnoreCase(f.name, name)) return i;
        return null;
    }

    /// The headers' total size ("name:value" strings).
    fn size(h: *const Headers) usize {
        var n: usize = 0;
        for (h.fields.items) |f| n += f.name.len + 1 + f.value.len;
        return n;
    }

    fn put(h: *Headers, name: []const u8, value: []const u8) !void {
        if (h.find(name)) |i| {
            const v = try h.gpa.dupe(u8, value);
            h.gpa.free(h.fields.items[i].value);
            h.fields.items[i].value = v;
            return;
        }
        const n = try h.gpa.dupe(u8, name);
        errdefer h.gpa.free(n);
        const v = try h.gpa.dupe(u8, value);
        errdefer h.gpa.free(v);
        try h.fields.append(h.gpa, .{ .name = n, .value = v });
    }

    fn count(h: *Headers) u32 {
        return @intCast(h.fields.items.len);
    }

    fn getHeader(h: *Headers, cx: *js.Context, name: []const u8) js.Error!Value {
        if (isProtected(name)) return error.Argument;
        const i = h.find(name) orelse return js.null;
        return cx.string(h.fields.items[i].value);
    }

    fn setHeader(h: *Headers, name: js.NullStr, header: js.NullStr) js.Error!void {
        const n = name.s orelse return error.ArgumentNull;
        if (n.len == 0) return error.ArgumentNull;
        const v = header.s orelse return error.ArgumentNull;
        if (h.response or !validName(n) or isProtected(n)) return error.Argument;
        if (h.find(n)) |i| {
            if (h.size() - h.fields.items[i].value.len + v.len > max_size) return error.Overflow;
        } else {
            if (h.fields.items.len >= max_fields) return error.Overflow;
            if (h.size() + n.len + 1 + v.len > max_size) return error.Overflow;
        }
        try h.put(n, v);
    }

    fn removeHeader(h: *Headers, name: js.NullStr) js.Error!void {
        const n = name.s orelse return error.ArgumentNull;
        if (n.len == 0) return error.ArgumentNull;
        if (h.response) return error.Argument;
        const i = h.find(n) orelse return error.Argument;
        const f = h.fields.orderedRemove(i);
        h.gpa.free(f.name);
        h.gpa.free(f.value);
    }

    fn getHeaderNameByIndex(h: *Headers, i: u32) js.Error![]const u8 {
        if (i >= h.fields.items.len) return error.Argument;
        return h.fields.items[i].name;
    }

    fn getHeaderValueByIndex(h: *Headers, i: u32) js.Error![]const u8 {
        if (i >= h.fields.items.len) return error.Argument;
        return h.fields.items[i].value;
    }

    pub const js_class: js.Class = .{
        .name = "HTTPHeader",
        .members = &.{
            js.prop("count", count, null),
            js.method("getHeader", getHeader),
            js.method("setHeader", setHeader),
            js.method("removeHeader", removeHeader),
            js.method("getHeaderNamebyIndex", getHeaderNameByIndex),
            js.method("getHeaderValuebyIndex", getHeaderValueByIndex),
        },
    };
};

pub const ClientState = struct {
    pub const uninitialized = 1;
    pub const loading = 2;
    pub const request_progress = 3;
    pub const request_sent = 4;
    pub const header_received = 5;
    pub const response_progress = 6;
    pub const completed = 7;
    pub const err = 8;
    pub const abort = 9;
};

pub const Method = struct {
    pub const get = 1;
    pub const head = 2;
    pub const post = 3;
    pub const put = 4;
    pub const trace = 5;
    pub const options = 6;
    pub const delete = 7;
};

pub const Client = struct {
    uri: []u8,
    method: u32,
    timeout: i32,
    state: u32 = ClientState.uninitialized,
    on_state_change: Value = js.null,
    uploaded: u32 = 0,
    downloaded: u32 = 0,
    download_location: ?[]u8 = null,
    status_code: u32 = 0,
    status_description: []const u8 = "",
    auth: u32 = 1,
    aborted: bool = false,
    request: Headers,
    response: Headers,
    obj: ?*anyopaque = null,
    request_obj: Value = js.null,
    response_obj: Value = js.null,

    fn free(cl: *Client, s: *Script) void {
        s.cx.free(cl.on_state_change);
        s.cx.free(cl.request_obj);
        s.cx.free(cl.response_obj);
        cl.request.deinit();
        cl.response.deinit();
        s.gpa.free(cl.uri);
        if (cl.download_location) |d| s.gpa.free(d);
        s.gpa.destroy(cl);
    }

    fn finalize(ptr: *anyopaque, _: *js.Runtime) void {
        const cl: *Client = @ptrCast(@alignCast(ptr));
        cl.obj = null;
        // Freed with the context (the State's list keeps it).
    }

    fn mark(ptr: *anyopaque, rt: *c.JSRuntime, m: ?*const c.JS_MarkFunc) void {
        const cl: *Client = @ptrCast(@alignCast(ptr));
        c.JS_MarkValue(rt, cl.on_state_change, m);
    }

    fn setState(cl: *Client, s: *Script, state: u32) void {
        cl.state = state;
        if (s.cx.isFunction(cl.on_state_change)) s.postCall(cl.on_state_change, &.{s.cx.number(@floatFromInt(state))}, "HTTPClient.onStateChange") catch {};
    }

    /// The request sequence: without a network, loading then the "no connection" error (Z.8.2.3 step 5).
    fn start(cl: *Client, s: *Script) js.Error!void {
        if (cl.state != ClientState.uninitialized) return error.InvalidOperation;
        if (cl.aborted) return error.Web;
        cl.setState(s, ClientState.loading);
        if (!s.world.network_allowed) {
            cl.status_code = 10;
            cl.status_description = "No connection could be made to the server";
            cl.setState(s, ClientState.err);
        }
    }

    fn checkUpload(cl: *Client) js.Error!void {
        if (cl.method != Method.post and cl.method != Method.put) return error.ProtocolViolation;
    }

    fn send(cl: *Client, cx: *js.Context) js.Error!void {
        return cl.start(Script.of(cx));
    }
    fn sendString(cl: *Client, cx: *js.Context, _: []const u8) js.Error!void {
        try cl.checkUpload();
        return cl.start(Script.of(cx));
    }
    fn sendFile(cl: *Client, cx: *js.Context, _: []const u8) js.Error!void {
        try cl.checkUpload();
        return cl.start(Script.of(cx));
    }
    fn sendXML(cl: *Client, cx: *js.Context, doc: Value) js.Error!void {
        try cl.checkUpload();
        const n = dom_api.nodeOf(cx, doc) orelse return error.Argument;
        if (n.type != .document) return error.Argument;
        return cl.start(Script.of(cx));
    }
    /// Nothing was received: there is no String body.
    fn getResponseString(cl: *Client) js.Error!Value {
        _ = cl;
        return error.InvalidOperation;
    }
    fn getResponseXML(cl: *Client) js.Error!Value {
        _ = cl;
        return error.InvalidOperation;
    }
    fn abort(cl: *Client, cx: *js.Context, cb: ?Value) void {
        const s = Script.of(cx);
        cl.aborted = true;
        cl.state = ClientState.abort;
        if (cb) |f| if (cx.isFunction(f)) s.postCall(f, &.{}, "HTTPClient.abort") catch {};
    }

    /// open(uri, method, timeout, name, password).
    fn open(cl: *Client, cx: *js.Context, u: []const u8, method: u32, timeout: u32, name: js.NullStr, password: js.NullStr) js.Error!void {
        const s = Script.of(cx);
        switch (cl.state) {
            ClientState.uninitialized, ClientState.completed, ClientState.err, ClientState.abort => {},
            else => return error.InvalidOperation,
        }
        const host_name = try parseUri(u);
        if (method < 1 or method > 7) return error.Argument;
        if (name.s != null and password.s != null) {
            if (!std.mem.eql(u8, u, cl.uri) or cl.response.find("WWW-Authenticate") == null) return error.InvalidOperation;
        }
        const copy = try s.gpa.dupe(u8, u);
        s.gpa.free(cl.uri);
        cl.uri = copy;
        cl.method = method;
        cl.timeout = @intCast(@min(timeout, std.math.maxInt(i32)));
        cl.state = ClientState.uninitialized;
        cl.aborted = false;
        cl.request.clear();
        try cl.request.put("Host", host_name);
        cl.uploaded = 0;
        cl.downloaded = 0;
        if (cl.download_location) |d| s.gpa.free(d);
        cl.download_location = null;
        cl.response.clear();
        cl.status_code = 0;
        cl.status_description = "";
        cl.auth = 1;
    }

    fn requestHeaders(cl: *Client, cx: *js.Context) Value {
        return cx.dup(cl.request_obj);
    }
    fn responseHeaders(cl: *Client, cx: *js.Context) Value {
        return cx.dup(cl.response_obj);
    }
    fn requestUri(cl: *Client) []const u8 {
        return cl.uri;
    }
    fn getTimeout(cl: *Client) i32 {
        return cl.timeout;
    }
    fn getState(cl: *Client) u32 {
        return cl.state;
    }
    fn getOnStateChange(cl: *Client, cx: *js.Context) Value {
        return cx.dup(cl.on_state_change);
    }
    fn setOnStateChange(cl: *Client, cx: *js.Context, f: Value) void {
        cx.free(cl.on_state_change);
        cl.on_state_change = cx.dup(f);
    }
    fn dataUploaded(cl: *Client) u32 {
        return cl.uploaded;
    }
    fn dataDownloaded(cl: *Client) u32 {
        return cl.downloaded;
    }
    fn getDownloadLocation(cl: *Client, cx: *js.Context) js.Error!Value {
        return if (cl.download_location) |d| cx.string(d) else js.null;
    }
    fn setDownloadLocation(cl: *Client, cx: *js.Context, v: js.NullStr) js.Error!void {
        const copy = if (v.s) |x| try cx.gpa.dupe(u8, x) else null;
        if (cl.download_location) |d| cx.gpa.free(d);
        cl.download_location = copy;
    }
    fn statusCode(cl: *Client) u32 {
        return cl.status_code;
    }
    fn statusDescription(cl: *Client) []const u8 {
        return cl.status_description;
    }
    fn requestMethod(cl: *Client) u32 {
        return cl.method;
    }
    fn requestedAuth(cl: *Client) u32 {
        return cl.auth;
    }

    pub const js_class: js.Class = .{
        .name = "HTTPClient",
        .finalize = finalize,
        .mark = mark,
        .members = &.{
            js.prop("requestHeaders", requestHeaders, null),
            js.prop("requestUri", requestUri, null),
            js.prop("timeout", getTimeout, null),
            js.prop("state", getState, null),
            js.prop("onStateChange", getOnStateChange, setOnStateChange),
            js.prop("dataUploaded", dataUploaded, null),
            js.prop("dataDownloaded", dataDownloaded, null),
            js.prop("downloadFileLocation", getDownloadLocation, setDownloadLocation),
            js.prop("responseHeaders", responseHeaders, null),
            js.prop("statusCode", statusCode, null),
            js.prop("statusDescription", statusDescription, null),
            js.prop("requestMethod", requestMethod, null),
            js.prop("requestedAuth", requestedAuth, null),
            js.method("send", send),
            js.method("sendString", sendString),
            js.method("sendFile", sendFile),
            js.method("sendXML", sendXML),
            js.method("getResponseString", getResponseString),
            js.method("getResponseXML", getResponseXML),
            js.method("abort", abort),
            js.method("open", open),
            js.constant("STATE_UNINITIALIZED", ClientState.uninitialized),
            js.constant("STATE_LOADING", ClientState.loading),
            js.constant("STATE_REQUESTPROGRESS", ClientState.request_progress),
            js.constant("STATE_REQUESTSENT", ClientState.request_sent),
            js.constant("STATE_HEADERRECEIVED", ClientState.header_received),
            js.constant("STATE_RESPONSEPROGRESS", ClientState.response_progress),
            js.constant("STATE_COMPLETED", ClientState.completed),
            js.constant("STATE_ERROR", ClientState.err),
            js.constant("STATE_ABORT", ClientState.abort),
            js.constant("AUTHENTICATION_NONE", 1),
            js.constant("AUTHENTICATION_BASIC", 2),
            js.constant("AUTHENTICATION_DIGEST", 3),
        },
    };
};

/// An http(s) URI with port 80 or 443 (Z.8.3.2): its Host header value.
fn parseUri(u: []const u8) js.Error![]const u8 {
    const https = std.ascii.startsWithIgnoreCase(u, "https://");
    if (!https and !std.ascii.startsWithIgnoreCase(u, "http://")) return error.Argument;
    const rest = u[if (https) 8 else 7..];
    const end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
    const authority = rest[0..end];
    if (authority.len == 0) return error.Argument;
    if (std.mem.lastIndexOfScalar(u8, authority, ':')) |colon| {
        const port = std.fmt.parseInt(u16, authority[colon + 1 ..], 10) catch return error.Argument;
        if (port != 80 and port != 443) return error.Argument;
        if (colon == 0) return error.Argument;
        // The default port is not written in the Host header.
        if ((port == 80 and !https) or (port == 443 and https)) return authority[0..colon];
    }
    return authority;
}

pub const Network = struct {
    pub const js_owner = true;

    /// createHTTPClient(uri, requestMethod, timeout): timeout -1 is no limit.
    fn createHTTPClient(s: *Script, u: []const u8, method: u32, timeout: i32) js.Error!Value {
        const host_name = try parseUri(u);
        if (method < 1 or method > 7) return error.Argument;
        const cl = try s.gpa.create(Client);
        cl.* = .{ .uri = try s.gpa.dupe(u8, u), .method = method, .timeout = timeout, .request = .{ .gpa = s.gpa }, .response = .{ .gpa = s.gpa, .response = true } };
        cl.request.put("Host", host_name) catch {
            cl.free(s);
            return error.OutOfMemory;
        };
        cl.request_obj = s.cx.wrap(Headers, &cl.request) catch |e| {
            cl.free(s);
            return e;
        };
        cl.response_obj = s.cx.wrap(Headers, &cl.response) catch |e| {
            cl.free(s);
            return e;
        };
        try s.apis.net.clients.append(s.gpa, cl);
        const v = try s.cx.wrap(Client, cl);
        cl.obj = js.objectPointer(v);
        return v;
    }

    pub const js_class: js.Class = .{
        .name = "Network",
        .members = &.{
            js.method("createHTTPClient", createHTTPClient),
            js.constant("HTTP_GET", Method.get),
            js.constant("HTTP_HEAD", Method.head),
            js.constant("HTTP_POST", Method.post),
            js.constant("HTTP_PUT", Method.put),
            js.constant("HTTP_TRACE", Method.trace),
            js.constant("HTTP_OPTIONS", Method.options),
            js.constant("HTTP_DELETE", Method.delete),
        },
    };
};

pub fn exposeConstructors(_: *js.Context) js.Error!void {}

// ---- tests --------------------------------------------------------------------------------------------------------

const testenv = @import("testenv.zig");

test "HTTPClient without a network" {
    const e = try testenv.Env.create();
    defer e.destroy();
    try e.run(
        \\assertThrows(function () { Network.createHTTPClient("ftp://x/", 1, 30); }, "HDDVD_E_ARGUMENT");
        \\assertThrows(function () { Network.createHTTPClient("http://x:8080/", 1, 30); }, "HDDVD_E_ARGUMENT");
        \\var c = Network.createHTTPClient("http://example.com:80/a", Network.HTTP_GET, 30);
        \\assertEq(c.state, c.STATE_UNINITIALIZED); assertEq(c.requestHeaders.getHeader("Host"), "example.com");
        \\assertThrows(function () { c.requestHeaders.setHeader("Cookie", "x"); }, "HDDVD_E_ARGUMENT");
        \\assertThrows(function () { c.requestHeaders.setHeader(null, "x"); }, "HDDVD_E_ARGUMENTNULL");
        \\c.requestHeaders.setHeader("Accept", "text/xml"); assertEq(c.requestHeaders.count, 2);
        \\assertEq(c.requestHeaders.getHeaderNamebyIndex(1), "Accept");
        \\assertThrows(function () { c.requestHeaders.setHeader("X-Long", new Array(260).join("a")); }, "HDDVD_E_OVERFLOW");
        \\assertThrows(function () { c.sendString("x"); }, "HDDVD_E_PROTOCOLVIOLATION");
        \\var states = []; c.onStateChange = cb(function (st) { states.push(st); });
        \\c.send(); assertEq(c.state, c.STATE_ERROR); assertEq(c.statusCode, 10);
        \\assertThrows(function () { c.send(); }, "HDDVD_E_INVALIDOPERATION");
        \\assertThrows(function () { c.getResponseString(); }, "HDDVD_E_INVALIDOPERATION");
        \\c.open("https://example.com/b", Network.HTTP_POST, 10, null, null); assertEq(c.state, 1); assertEq(c.requestHeaders.count, 1);
        \\c.abort(); assertEq(c.state, c.STATE_ABORT);
    , "net1.js");
    try e.run("assertEq(states.join(','), '2,8');", "net2.js");
}
