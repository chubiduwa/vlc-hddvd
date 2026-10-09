//! Drawing for scripts (HD DVD Annex Z.7, Vol. 3 §7.8.2): the Drawing object's constructors (Color, Rectangle,
//! Point, Brush, Pen) and the DrawingArea of each graphic object (<object type="application/x-graphic">), an
//! offscreen canvas of its width × height <param>s that the markup scales into the object's box.
//!
//! Shapes are filled with the non-zero rule, sampling pixel centres (no anti-aliasing). A pen is a square
//! footprint (Z.7.4: its corners from the width, then the pen's rotations and scalings); a line is the convex
//! hull of the footprint at both ends. Fill comes before outline. Texture brushes tile their image from the
//! shape's top-left corner. No VLC dependency.

const std = @import("std");
const js = @import("js.zig");
const host = @import("host.zig");
const dom = @import("../dom.zig");
const raster = @import("../raster.zig");
const image = @import("../image.zig");
const page_mod = @import("../markup/page.zig");
const files_mod = @import("files.zig");
const uri_mod = @import("../uri.zig");

const c = js.c;
const Value = js.Value;
const Script = host.Script;
const Canvas = raster.Canvas;
const Px = raster.Px;

/// The DrawingAreas of the current page, by graphic object.
pub const State = struct {
    areas: std.ArrayList(*Area) = .empty,

    pub fn deinit(st: *State, s: *Script) void {
        st.release(s);
        st.areas.deinit(s.gpa);
    }

    /// The page goes: its areas stop working.
    pub fn release(st: *State, s: *Script) void {
        for (st.areas.items) |a| {
            if (a.obj) |o| js.kill(s.cx.rt, o);
            if (a.node.view) |v| {
                const el: *page_mod.Elem = @ptrCast(@alignCast(v));
                el.graphic = null;
            }
            a.canvas.deinit(s.gpa);
            s.gpa.destroy(a);
        }
        st.areas.clearRetainingCapacity();
    }
};

pub fn isGraphic(n: *const dom.Node) bool {
    const ty = n.attr("type") orelse return false;
    return std.mem.eql(u8, ty, "application/x-graphic") or std.mem.eql(u8, ty, "x-application/graphic");
}

/// A <param>'s integer value (§7.8.2: width and height, default 1).
fn param(n: *const dom.Node, name: []const u8) u32 {
    var ch = n.firstElement();
    while (ch) |p| : (ch = p.nextElement()) {
        if (!p.is(page_mod.core_ns, "param")) continue;
        if (!std.mem.eql(u8, p.attr("name") orelse "", name)) continue;
        const v = std.mem.trimEnd(u8, std.mem.trim(u8, p.attr("value") orelse "", " "), "px");
        return std.math.clamp(std.fmt.parseInt(u32, v, 10) catch 1, 1, 1920);
    }
    return 1;
}

/// AnimatableElement.drawingArea (Z.13.1.4.2): the graphic object's DrawingArea, else null.
pub fn drawingAreaOf(s: *Script, n: *dom.Node) js.Error!Value {
    if (n.type != .element or !n.is(page_mod.core_ns, "object") or !isGraphic(n)) return js.null;
    if (!s.isPageDoc(n.doc)) return js.null;
    const st = &s.apis.draw;
    for (st.areas.items) |a| if (a.node == n) {
        if (a.obj) |o| return js.fromPointer(s.cx, o);
        const v = try s.cx.wrap(Area, a);
        a.obj = js.objectPointer(v);
        return v;
    };
    const a = try s.gpa.create(Area);
    errdefer s.gpa.destroy(a);
    a.* = .{ .node = n, .canvas = try Canvas.init(s.gpa, param(n, "width"), param(n, "height")) };
    errdefer a.canvas.deinit(s.gpa);
    try st.areas.append(s.gpa, a);
    const v = try s.cx.wrap(Area, a);
    a.obj = js.objectPointer(v);
    a.attach();
    return v;
}

// ---- value objects -----------------------------------------------------------------------------------------------

pub const Color = struct {
    rgba: [4]u8,

    fn make(cx: *js.Context, rgba: [4]u8) js.Error!Value {
        const p = try cx.gpa.create(Color);
        p.* = .{ .rgba = rgba };
        return cx.wrap(Color, p) catch |e| {
            cx.gpa.destroy(p);
            return e;
        };
    }
    fn finalize(ptr: *anyopaque, rt: *js.Runtime) void {
        rt.gpa.destroy(@as(*Color, @ptrCast(@alignCast(ptr))));
    }
    fn get(comptime i: usize) fn (*Color) u32 {
        return struct {
            fn f(p: *Color) u32 {
                return p.rgba[i];
            }
        }.f;
    }
    fn set(comptime i: usize) fn (*Color, u32) js.Error!void {
        return struct {
            fn f(p: *Color, v: u32) js.Error!void {
                if (v > 255) return error.ArgumentOutOfRange;
                p.rgba[i] = @intCast(v);
            }
        }.f;
    }
    fn setRGBA(p: *Color, r: u32, g: u32, b: u32, a: u32) js.Error!void {
        if (r > 255 or g > 255 or b > 255 or a > 255) return error.ArgumentOutOfRange;
        p.rgba = .{ @intCast(r), @intCast(g), @intCast(b), @intCast(a) };
    }
    fn equal(p: *Color, cx: *js.Context, other: Value) bool {
        const o = cx.unwrap(Color, other) orelse return false;
        return std.mem.eql(u8, &p.rgba, &o.rgba);
    }
    fn px(p: *const Color) Px {
        return (raster.Color{ .r = p.rgba[0], .g = p.rgba[1], .b = p.rgba[2], .a = p.rgba[3] }).premultiplied();
    }

    pub const js_class: js.Class = .{
        .name = "Color",
        .finalize = finalize,
        .members = &.{
            js.prop("red", get(0), set(0)),
            js.prop("green", get(1), set(1)),
            js.prop("blue", get(2), set(2)),
            js.prop("alpha", get(3), set(3)),
            js.method("setRGBA", setRGBA),
            js.method("equal", equal),
        },
    };
};

pub const Rect = struct {
    x: i32,
    y: i32,
    w: u32,
    h: u32,

    fn make(cx: *js.Context, r: Rect) js.Error!Value {
        const p = try cx.gpa.create(Rect);
        p.* = r;
        return cx.wrap(Rect, p) catch |e| {
            cx.gpa.destroy(p);
            return e;
        };
    }
    fn finalize(ptr: *anyopaque, rt: *js.Runtime) void {
        rt.gpa.destroy(@as(*Rect, @ptrCast(@alignCast(ptr))));
    }
    fn getX(r: *Rect) i32 {
        return r.x;
    }
    fn setX(r: *Rect, v: i32) void {
        r.x = v;
    }
    fn getY(r: *Rect) i32 {
        return r.y;
    }
    fn setY(r: *Rect, v: i32) void {
        r.y = v;
    }
    fn getW(r: *Rect) u32 {
        return r.w;
    }
    fn setW(r: *Rect, v: u32) void {
        r.w = v;
    }
    fn getH(r: *Rect) u32 {
        return r.h;
    }
    fn setH(r: *Rect, v: u32) void {
        r.h = v;
    }
    /// contains(x, y): the edges count (Z.7.3.3).
    fn contains(r: *Rect, x: i32, y: i32) bool {
        const rx: i64 = r.x;
        const ry: i64 = r.y;
        return rx <= x and x <= rx + r.w and ry <= y and y <= ry + r.h;
    }
    fn equal(r: *Rect, cx: *js.Context, other: Value) bool {
        const o = cx.unwrap(Rect, other) orelse return false;
        return r.x == o.x and r.y == o.y and r.w == o.w and r.h == o.h;
    }

    pub const js_class: js.Class = .{
        .name = "Rectangle",
        .finalize = finalize,
        .members = &.{
            js.prop("x", getX, setX),
            js.prop("y", getY, setY),
            js.prop("width", getW, setW),
            js.prop("height", getH, setH),
            js.method("contains", contains),
            js.method("equal", equal),
        },
    };
};

pub const Point = struct {
    x: i32,
    y: i32,

    fn finalize(ptr: *anyopaque, rt: *js.Runtime) void {
        rt.gpa.destroy(@as(*Point, @ptrCast(@alignCast(ptr))));
    }
    fn getX(p: *Point) i32 {
        return p.x;
    }
    fn setX(p: *Point, v: i32) void {
        p.x = v;
    }
    fn getY(p: *Point) i32 {
        return p.y;
    }
    fn setY(p: *Point, v: i32) void {
        p.y = v;
    }

    pub const js_class: js.Class = .{
        .name = "Point",
        .finalize = finalize,
        .members = &.{ js.prop("x", getX, setX), js.prop("y", getY, setY) },
    };
};

pub const Brush = struct {
    color: ?[4]u8,
    texture: ?[]u8,
    color_obj: Value = js.null,

    fn finalize(ptr: *anyopaque, rt: *js.Runtime) void {
        const b: *Brush = @ptrCast(@alignCast(ptr));
        c.JS_FreeValueRT(rt.rt, b.color_obj);
        if (b.texture) |t| rt.gpa.free(t);
        rt.gpa.destroy(b);
    }
    fn mark(ptr: *anyopaque, rt: *c.JSRuntime, m: ?*const c.JS_MarkFunc) void {
        const b: *Brush = @ptrCast(@alignCast(ptr));
        c.JS_MarkValue(rt, b.color_obj, m);
    }
    fn getColor(b: *Brush, cx: *js.Context) Value {
        return cx.dup(b.color_obj);
    }
    fn getTexture(b: *Brush, cx: *js.Context) js.Error!Value {
        return if (b.texture) |t| cx.string(t) else js.null;
    }

    pub const js_class: js.Class = .{
        .name = "Brush",
        .finalize = finalize,
        .mark = mark,
        .members = &.{ js.prop("color", getColor, null), js.prop("texture", getTexture, null) },
    };
};

pub const Pen = struct {
    color: [4]u8,
    color_obj: Value,
    /// The footprint's corners (pixels, relative to the point).
    corners: [4][2]f64,

    fn init(width: u32) [4][2]f64 {
        const w: f64 = @floatFromInt(width);
        const h = if (width % 2 == 0) w / 2 - 1 else (w - 1) / 2;
        // Z.7.4: an even width spans width/2-1 each way; at least the point itself.
        const r = @max(h, 0);
        return .{ .{ r, r }, .{ r, -r }, .{ -r, -r }, .{ -r, r } };
    }

    fn finalize(ptr: *anyopaque, rt: *js.Runtime) void {
        const p: *Pen = @ptrCast(@alignCast(ptr));
        c.JS_FreeValueRT(rt.rt, p.color_obj);
        rt.gpa.destroy(p);
    }
    fn mark(ptr: *anyopaque, rt: *c.JSRuntime, m: ?*const c.JS_MarkFunc) void {
        const p: *Pen = @ptrCast(@alignCast(ptr));
        c.JS_MarkValue(rt, p.color_obj, m);
    }
    fn getColor(p: *Pen, cx: *js.Context) Value {
        return cx.dup(p.color_obj);
    }
    fn rotateTransform(p: *Pen, angle: f64) void {
        const a = angle * std.math.pi / 180;
        for (&p.corners) |*k| {
            const x = k[0];
            const y = k[1];
            k.* = .{ x * @cos(a) - y * @sin(a), x * @sin(a) + y * @cos(a) };
        }
    }
    fn scaleTransform(p: *Pen, sx: f64, sy: f64) void {
        for (&p.corners) |*k| k.* = .{ k[0] * sx, k[1] * sy };
    }

    pub const js_class: js.Class = .{
        .name = "Pen",
        .finalize = finalize,
        .mark = mark,
        .members = &.{
            js.prop("color", getColor, null),
            js.method("rotateTransform", rotateTransform),
            js.method("scaleTransform", scaleTransform),
        },
    };
};

// ---- the Drawing object (Z.7.1) ---------------------------------------------------------------------------------------

pub const Drawing = struct {
    pub const js_owner = true;

    fn createColor(s: *Script, r: u32, g: u32, b: u32, a: u32) js.Error!Value {
        if (r > 255 or g > 255 or b > 255 or a > 255) return error.ArgumentOutOfRange;
        return Color.make(s.cx, .{ @intCast(r), @intCast(g), @intCast(b), @intCast(a) });
    }
    fn createRectangle(s: *Script, x: i32, y: i32, w: u32, h: u32) js.Error!Value {
        return Rect.make(s.cx, .{ .x = x, .y = y, .w = w, .h = h });
    }
    fn createPoint(s: *Script, x: i32, y: i32) js.Error!Value {
        const p = try s.gpa.create(Point);
        p.* = .{ .x = x, .y = y };
        return s.cx.wrap(Point, p) catch |e| {
            s.gpa.destroy(p);
            return e;
        };
    }
    fn createSolidBrush(s: *Script, color_v: Value) js.Error!Value {
        const col = s.cx.unwrap(Color, color_v) orelse return error.Argument;
        const b = try s.gpa.create(Brush);
        b.* = .{ .color = col.rgba, .texture = null, .color_obj = s.cx.dup(color_v) };
        return s.cx.wrap(Brush, b) catch |e| {
            s.cx.free(b.color_obj);
            s.gpa.destroy(b);
            return e;
        };
    }
    /// createTextureBrush(image): an image in the File Cache (not MNG).
    fn createTextureBrush(s: *Script, u: []const u8) js.Error!Value {
        const b = try s.gpa.create(Brush);
        b.* = .{ .color = null, .texture = s.gpa.dupe(u8, u) catch {
            s.gpa.destroy(b);
            return error.OutOfMemory;
        } };
        return s.cx.wrap(Brush, b) catch |e| {
            s.gpa.free(b.texture.?);
            s.gpa.destroy(b);
            return e;
        };
    }
    fn createPen(s: *Script, color_v: Value, width: u32) js.Error!Value {
        const col = s.cx.unwrap(Color, color_v) orelse return error.Argument;
        const p = try s.gpa.create(Pen);
        p.* = .{ .color = col.rgba, .color_obj = s.cx.dup(color_v), .corners = Pen.init(width) };
        return s.cx.wrap(Pen, p) catch |e| {
            s.cx.free(p.color_obj);
            s.gpa.destroy(p);
            return e;
        };
    }

    pub const js_class: js.Class = .{
        .name = "Drawing",
        .members = &.{
            js.method("createColor", createColor),
            js.method("createRectangle", createRectangle),
            js.method("createPoint", createPoint),
            js.method("createSolidBrush", createSolidBrush),
            js.method("createTextureBrush", createTextureBrush),
            js.method("createPen", createPen),
        },
    };
};

// ---- rasterization ------------------------------------------------------------------------------------------------

const Vec = [2]f64;

/// What fills a shape: a colour, or an image tiled from `origin`.
const Paint = union(enum) {
    color: Px,
    texture: struct { img: *const Canvas, origin: [2]i32 },

    fn at(p: Paint, x: i32, y: i32) Px {
        return switch (p) {
            .color => |col| col,
            .texture => |t| blk: {
                const w: i32 = @intCast(t.img.w);
                const h: i32 = @intCast(t.img.h);
                if (w == 0 or h == 0) break :blk .{ 0, 0, 0, 0 };
                break :blk t.img.at(@mod(x - t.origin[0], w), @mod(y - t.origin[1], h));
            },
        };
    }
};

/// Fills polygon `pts` with the non-zero rule, sampling pixel centres.
fn fillPolygon(cv: *Canvas, pts: []const Vec, paint: Paint) void {
    if (pts.len < 3) return;
    var min_y: f64 = std.math.inf(f64);
    var max_y: f64 = -std.math.inf(f64);
    for (pts) |p| {
        min_y = @min(min_y, p[1]);
        max_y = @max(max_y, p[1]);
    }
    const y0: i32 = @max(0, @as(i32, @intFromFloat(@floor(min_y))));
    const y1: i32 = @min(@as(i32, @intCast(cv.h)) - 1, @as(i32, @intFromFloat(@ceil(max_y))));
    var xs: [256]struct { x: f64, dir: i8 } = undefined;
    var y = y0;
    while (y <= y1) : (y += 1) {
        const sy = @as(f64, @floatFromInt(y)) + 0.5;
        var n: usize = 0;
        for (pts, 0..) |a, i| {
            const b = pts[(i + 1) % pts.len];
            if ((a[1] <= sy and b[1] > sy) or (b[1] <= sy and a[1] > sy)) {
                if (n == xs.len) break;
                const t = (sy - a[1]) / (b[1] - a[1]);
                xs[n] = .{ .x = a[0] + t * (b[0] - a[0]), .dir = if (b[1] > a[1]) 1 else -1 };
                n += 1;
            }
        }
        std.mem.sort(@TypeOf(xs[0]), xs[0..n], {}, struct {
            fn lt(_: void, p: @TypeOf(xs[0]), q: @TypeOf(xs[0])) bool {
                return p.x < q.x;
            }
        }.lt);
        // Spans where the winding number is non-zero.
        var wind: i32 = 0;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            wind += xs[i].dir;
            if (wind == 0 or i + 1 >= n) continue;
            const xa: i32 = @max(0, @as(i32, @intFromFloat(@ceil(xs[i].x - 0.5))));
            const xb: i32 = @min(@as(i32, @intCast(cv.w)) - 1, @as(i32, @intFromFloat(@ceil(xs[i + 1].x - 0.5))) - 1);
            var x = xa;
            const row = cv.row(@intCast(y));
            while (x <= xb) : (x += 1) row[@intCast(x)] = raster.over(row[@intCast(x)], paint.at(x, y));
        }
    }
}

/// The convex hull of the pen's footprint at both ends of a segment.
fn strokeSegment(cv: *Canvas, pen: *const Pen, a: Vec, b: Vec) void {
    // The footprint's corners are pixel centres: a hair larger so its edge pixels are inside.
    var pts: [8]Vec = undefined;
    for (pen.corners, 0..) |k, i| {
        const e: Vec = .{ k[0] + hair(k[0]), k[1] + hair(k[1]) };
        pts[i] = .{ a[0] + e[0] + 0.5, a[1] + e[1] + 0.5 };
        pts[i + 4] = .{ b[0] + e[0] + 0.5, b[1] + e[1] + 0.5 };
    }
    var hull: [9]Vec = undefined;
    const n = convexHull(&pts, &hull);
    // A footprint of no area still marks the pixels its centre passes.
    const col = (Color{ .rgba = pen.color }).px();
    if (n < 3) {
        const steps: usize = @intFromFloat(@max(@abs(b[0] - a[0]), @abs(b[1] - a[1])) + 1);
        for (0..steps + 1) |i| {
            const t = if (steps == 0) 0 else @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(steps));
            const x: i32 = @intFromFloat(@round(a[0] + (b[0] - a[0]) * t));
            const y: i32 = @intFromFloat(@round(a[1] + (b[1] - a[1]) * t));
            if (x < 0 or y < 0 or x >= cv.w or y >= cv.h) continue;
            const row = cv.row(@intCast(y));
            row[@intCast(x)] = raster.over(row[@intCast(x)], col);
        }
        return;
    }
    fillPolygon(cv, hull[0..n], .{ .color = col });
}

fn hair(v: f64) f64 {
    return if (v > 0) 0.01 else if (v < 0) -0.01 else 0;
}

/// Monotone chain; returns the hull's size in `out` (counter-clockwise).
fn convexHull(pts: []Vec, out: []Vec) usize {
    std.mem.sort(Vec, pts, {}, struct {
        fn lt(_: void, p: Vec, q: Vec) bool {
            return p[0] < q[0] or (p[0] == q[0] and p[1] < q[1]);
        }
    }.lt);
    const cross = struct {
        fn f(o: Vec, a: Vec, b: Vec) f64 {
            return (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0]);
        }
    }.f;
    var k: usize = 0;
    for (pts) |p| {
        while (k >= 2 and cross(out[k - 2], out[k - 1], p) <= 1e-9) k -= 1;
        out[k] = p;
        k += 1;
    }
    const lower = k + 1;
    var i = pts.len - 1;
    while (i > 0) {
        i -= 1;
        const p = pts[i];
        while (k >= lower and cross(out[k - 2], out[k - 1], p) <= 1e-9) k -= 1;
        out[k] = p;
        k += 1;
    }
    return k - 1;
}

fn ellipsePoints(x: i32, y: i32, w: u32, h: u32, out: []Vec) []Vec {
    const cx = @as(f64, @floatFromInt(x)) + @as(f64, @floatFromInt(w)) / 2;
    const cy = @as(f64, @floatFromInt(y)) + @as(f64, @floatFromInt(h)) / 2;
    const rx = @as(f64, @floatFromInt(w)) / 2;
    const ry = @as(f64, @floatFromInt(h)) / 2;
    for (out, 0..) |*p, i| {
        const a = @as(f64, @floatFromInt(i)) * 2 * std.math.pi / @as(f64, @floatFromInt(out.len));
        p.* = .{ cx + rx * @cos(a), cy + ry * @sin(a) };
    }
    return out;
}

// ---- DrawingArea (Z.7.5) --------------------------------------------------------------------------------------------

pub const Area = struct {
    node: *dom.Node,
    canvas: Canvas,
    /// Bumped at every change, so the page redraws.
    gen: u32 = 0,
    obj: ?*anyopaque = null,

    /// The page element shows this canvas.
    fn attach(a: *Area) void {
        const v = a.node.view orelse return;
        const el: *page_mod.Elem = @ptrCast(@alignCast(v));
        el.graphic = &a.canvas;
        el.graphic_gen = a.gen;
    }

    fn changed(a: *Area) void {
        a.gen +%= 1;
        a.attach();
    }

    /// The object's wrapper went; the canvas stays with the page (its contents are kept).
    fn finalize(ptr: *anyopaque, _: *js.Runtime) void {
        const a: *Area = @ptrCast(@alignCast(ptr));
        a.obj = null;
    }

    fn penOf(cx: *js.Context, v: Value) js.Error!?*Pen {
        if (c.JS_IsNull(v) or c.JS_IsUndefined(v)) return null;
        return cx.unwrap(Pen, v) orelse error.Argument;
    }

    fn paintOf(a: *Area, cx: *js.Context, v: Value, origin: [2]i32, tex: *?Canvas) js.Error!?Paint {
        _ = a;
        if (c.JS_IsNull(v) or c.JS_IsUndefined(v)) return null;
        const b = cx.unwrap(Brush, v) orelse return error.Argument;
        if (b.texture) |u| {
            const s = Script.of(cx);
            const f = s.world.files orelse return null;
            const bytes = f.read(s.gpa, u) catch return null;
            defer s.gpa.free(bytes);
            tex.* = image.decode(s.gpa, bytes) catch return null;
            return .{ .texture = .{ .img = &tex.*.?, .origin = origin } };
        }
        return .{ .color = (Color{ .rgba = b.color.? }).px() };
    }

    fn pointOf(cx: *js.Context, v: Value) js.Error!Vec {
        const p = cx.unwrap(Point, v) orelse return error.Argument;
        return .{ @floatFromInt(p.x), @floatFromInt(p.y) };
    }

    /// The Points of a script Array.
    fn points(cx: *js.Context, arr: Value, out: *std.ArrayList(Vec)) js.Error!void {
        var len: i64 = 0;
        if (c.JS_GetLength(cx.ctx, arr, &len) < 0) return error.Thrown;
        for (0..@intCast(@max(0, len))) |i| {
            const v = c.JS_GetPropertyUint32(cx.ctx, arr, @intCast(i));
            defer cx.free(v);
            try out.append(cx.gpa, try pointOf(cx, v));
        }
    }

    fn clear(a: *Area) void {
        @memset(a.canvas.px, .{ 0, 0, 0, 0 });
        a.changed();
    }

    fn drawLine(a: *Area, cx: *js.Context, pen_v: Value, p1: Value, p2: Value) js.Error!void {
        const pen = try penOf(cx, pen_v) orelse return error.Argument;
        strokeSegment(&a.canvas, pen, try pointOf(cx, p1), try pointOf(cx, p2));
        a.changed();
    }

    fn drawLineCoord(a: *Area, cx: *js.Context, pen_v: Value, x1: i32, y1: i32, x2: i32, y2: i32) js.Error!void {
        const pen = try penOf(cx, pen_v) orelse return error.Argument;
        strokeSegment(&a.canvas, pen, .{ @floatFromInt(x1), @floatFromInt(y1) }, .{ @floatFromInt(x2), @floatFromInt(y2) });
        a.changed();
    }

    fn drawLines(a: *Area, cx: *js.Context, pen_v: Value, arr: Value) js.Error!void {
        const pen = try penOf(cx, pen_v) orelse return error.Argument;
        var pts: std.ArrayList(Vec) = .empty;
        defer pts.deinit(cx.gpa);
        try points(cx, arr, &pts);
        if (pts.items.len >= 2) for (pts.items[0 .. pts.items.len - 1], pts.items[1..]) |p, q| strokeSegment(&a.canvas, pen, p, q);
        a.changed();
    }

    fn shape(a: *Area, cx: *js.Context, pen_v: Value, brush_v: Value, outline: []const Vec, origin: [2]i32) js.Error!void {
        const pen = try penOf(cx, pen_v);
        var tex: ?Canvas = null;
        defer if (tex) |*t| t.deinit(cx.gpa);
        if (try a.paintOf(cx, brush_v, origin, &tex)) |p| fillPolygon(&a.canvas, outline, p);
        if (pen) |pn| for (outline, 0..) |p, i| strokeSegment(&a.canvas, pn, p, outline[(i + 1) % outline.len]);
        a.changed();
    }

    fn rectOutline(x: i32, y: i32, w: u32, h: u32) [4]Vec {
        const fx: f64 = @floatFromInt(x);
        const fy: f64 = @floatFromInt(y);
        const fw: f64 = @floatFromInt(w);
        const fh: f64 = @floatFromInt(h);
        return .{ .{ fx, fy }, .{ fx + fw, fy }, .{ fx + fw, fy + fh }, .{ fx, fy + fh } };
    }

    fn drawRectangleCoord(a: *Area, cx: *js.Context, pen_v: Value, brush_v: Value, x: i32, y: i32, w: u32, h: u32) js.Error!void {
        // The outline goes through the corner pixels' centres; the fill covers the w × h pixels.
        const pen = try penOf(cx, pen_v);
        var tex: ?Canvas = null;
        defer if (tex) |*t| t.deinit(cx.gpa);
        if (try a.paintOf(cx, brush_v, .{ x, y }, &tex)) |p| {
            const o = rectOutline(x, y, w, h);
            fillPolygon(&a.canvas, &o, p);
        }
        if (pen) |pn| if (w > 0 and h > 0) {
            const x2: f64 = @floatFromInt(x + @as(i32, @intCast(w)) - 1);
            const y2: f64 = @floatFromInt(y + @as(i32, @intCast(h)) - 1);
            const fx: f64 = @floatFromInt(x);
            const fy: f64 = @floatFromInt(y);
            const corners = [_]Vec{ .{ fx, fy }, .{ x2, fy }, .{ x2, y2 }, .{ fx, y2 } };
            for (corners, 0..) |p, i| strokeSegment(&a.canvas, pn, p, corners[(i + 1) % 4]);
        };
        a.changed();
    }

    fn drawRectangle(a: *Area, cx: *js.Context, pen_v: Value, brush_v: Value, r_v: Value) js.Error!void {
        const r = cx.unwrap(Rect, r_v) orelse return error.Argument;
        return a.drawRectangleCoord(cx, pen_v, brush_v, r.x, r.y, r.w, r.h);
    }

    fn drawRectangles(a: *Area, cx: *js.Context, pen_v: Value, brush_v: Value, arr: Value) js.Error!void {
        var len: i64 = 0;
        if (c.JS_GetLength(cx.ctx, arr, &len) < 0) return error.Thrown;
        for (0..@intCast(@max(0, len))) |i| {
            const v = c.JS_GetPropertyUint32(cx.ctx, arr, @intCast(i));
            defer cx.free(v);
            try a.drawRectangle(cx, pen_v, brush_v, v);
        }
    }

    fn drawEllipseCoord(a: *Area, cx: *js.Context, pen_v: Value, brush_v: Value, x: i32, y: i32, w: u32, h: u32) js.Error!void {
        var buf: [96]Vec = undefined;
        return a.shape(cx, pen_v, brush_v, ellipsePoints(x, y, w, h, &buf), .{ x, y });
    }

    fn drawEllipse(a: *Area, cx: *js.Context, pen_v: Value, brush_v: Value, r_v: Value) js.Error!void {
        const r = cx.unwrap(Rect, r_v) orelse return error.Argument;
        return a.drawEllipseCoord(cx, pen_v, brush_v, r.x, r.y, r.w, r.h);
    }

    fn drawPolygon(a: *Area, cx: *js.Context, pen_v: Value, brush_v: Value, arr: Value) js.Error!void {
        var pts: std.ArrayList(Vec) = .empty;
        defer pts.deinit(cx.gpa);
        try points(cx, arr, &pts);
        if (pts.items.len == 0) return;
        var min: [2]i32 = .{ std.math.maxInt(i32), std.math.maxInt(i32) };
        for (pts.items) |p| min = .{ @min(min[0], @as(i32, @intFromFloat(p[0]))), @min(min[1], @as(i32, @intFromFloat(p[1]))) };
        return a.shape(cx, pen_v, brush_v, pts.items, min);
    }

    /// drawImage(uri, srcRect, destRect): the source part scaled into the destination (Z.7.5.2).
    fn drawImage(a: *Area, cx: *js.Context, u: []const u8, src_v: Value, dst_v: Value) js.Error!void {
        const s = Script.of(cx);
        const f = s.world.files orelse return error.FileNotFound;
        const bytes = f.read(s.gpa, u) catch return error.FileNotFound;
        defer s.gpa.free(bytes);
        if (image.kindOf(bytes) == .mng) return error.FileNotFound;
        var img = image.decode(s.gpa, bytes) catch return error.FileNotFound;
        defer img.deinit(s.gpa);
        const dst = cx.unwrap(Rect, dst_v) orelse return error.Argument;
        const sr: raster.Rect = if (c.JS_IsNull(src_v) or c.JS_IsUndefined(src_v)) img.bounds() else blk: {
            const r = cx.unwrap(Rect, src_v) orelse return error.Argument;
            break :blk .{ .x = r.x, .y = r.y, .w = @intCast(r.w), .h = @intCast(r.h) };
        };
        const to: raster.Rect = .{ .x = dst.x, .y = dst.y, .w = @intCast(dst.w), .h = @intCast(dst.h) };
        // Parts of the source outside the image are transparent: the crop maps onto its share of `to`.
        const inside = sr.intersect(img.bounds()) orelse return a.changed();
        const sx = @as(f64, @floatFromInt(to.w)) / @as(f64, @floatFromInt(@max(1, sr.w)));
        const sy = @as(f64, @floatFromInt(to.h)) / @as(f64, @floatFromInt(@max(1, sr.h)));
        const sub: raster.Rect = .{
            .x = to.x + @as(i32, @intFromFloat(@round(@as(f64, @floatFromInt(inside.x - sr.x)) * sx))),
            .y = to.y + @as(i32, @intFromFloat(@round(@as(f64, @floatFromInt(inside.y - sr.y)) * sy))),
            .w = @intFromFloat(@round(@as(f64, @floatFromInt(inside.w)) * sx)),
            .h = @intFromFloat(@round(@as(f64, @floatFromInt(inside.h)) * sy)),
        };
        raster.drawImage(a.canvas, a.canvas.bounds(), sub, img, inside, false, false, 255);
        a.changed();
    }

    /// capture(uri): the canvas as a Capture Drawing Format file (§6.5.1.4.2) in the API Managed Area.
    fn capture(a: *Area, cx: *js.Context, u: []const u8) js.Error!void {
        const s = Script.of(cx);
        const f = s.world.files orelse return error.Argument;
        if ((files_mod.Files.where(u) catch return error.Argument) != .temp or f.exists(u)) return error.Argument;
        const data = try captureDrawing(s.gpa, a.canvas);
        defer s.gpa.free(data);
        f.write(u, data) catch |e| return if (e == error.NoSpace) error.NotEnoughSpace else error.Argument;
    }

    pub const js_class: js.Class = .{
        .name = "DrawingArea",
        .finalize = finalize,
        .members = &.{
            js.method("clear", clear),
            js.method("drawLine", drawLine),
            js.method("drawLineCoord", drawLineCoord),
            js.method("drawLines", drawLines),
            js.method("drawRectangle", drawRectangle),
            js.method("drawRectangleCoord", drawRectangleCoord),
            js.method("drawRectangles", drawRectangles),
            js.method("drawEllipse", drawEllipse),
            js.method("drawEllipseCoord", drawEllipseCoord),
            js.method("drawPolygon", drawPolygon),
            js.method("drawImage", drawImage),
            js.method("capture", capture),
        },
    };
};

/// The Capture Drawing Format: the header of §6.5.1.4.1 (FILE_ID "HDDVDCIF", VERN, ENC_TY 02h, WIDTH,
/// HEIGHT, 49 reserved bytes; big-endian), then straight RGBA rows.
pub fn captureDrawing(gpa: std.mem.Allocator, cv: Canvas) ![]u8 {
    const head = 8 + 2 + 1 + 2 + 2 + 49;
    const out = try gpa.alloc(u8, head + cv.px.len * 4);
    @memset(out[0..head], 0);
    @memcpy(out[0..8], "HDDVDCIF");
    std.mem.writeInt(u16, out[8..10], 0x0010, .big);
    out[10] = 0x02;
    std.mem.writeInt(u16, out[11..13], @intCast(cv.w), .big);
    std.mem.writeInt(u16, out[13..15], @intCast(cv.h), .big);
    for (cv.px, 0..) |p, i| {
        const q = raster.unpremultiply(p);
        @memcpy(out[head + i * 4 ..][0..4], &q);
    }
    return out;
}

// ---- tests --------------------------------------------------------------------------------------------------------

const tt = std.testing;

test "fills and strokes" {
    var cv = try Canvas.init(tt.allocator, 10, 10);
    defer cv.deinit(tt.allocator);
    const red: Px = .{ 255, 0, 0, 255 };
    const sq = [_]Vec{ .{ 1, 1 }, .{ 4, 1 }, .{ 4, 4 }, .{ 1, 4 } };
    fillPolygon(&cv, &sq, .{ .color = red });
    try tt.expectEqual(red, cv.at(1, 1));
    try tt.expectEqual(red, cv.at(3, 3));
    try tt.expectEqual(@as(u8, 0), cv.at(4, 4)[3]);
    // A 1-pixel pen draws the pixels it passes.
    var cv2 = try Canvas.init(tt.allocator, 10, 10);
    defer cv2.deinit(tt.allocator);
    const pen: Pen = .{ .color = .{ 0, 255, 0, 255 }, .color_obj = js.null, .corners = Pen.init(1) };
    strokeSegment(&cv2, &pen, .{ 0, 5 }, .{ 9, 5 });
    try tt.expectEqual(@as(u8, 255), cv2.at(0, 5)[1]);
    try tt.expectEqual(@as(u8, 255), cv2.at(9, 5)[1]);
    try tt.expectEqual(@as(u8, 0), cv2.at(5, 4)[3]);
    // A 3-pixel pen covers one more each side.
    const pen3: Pen = .{ .color = .{ 0, 0, 255, 255 }, .color_obj = js.null, .corners = Pen.init(3) };
    strokeSegment(&cv2, &pen3, .{ 5, 1 }, .{ 5, 1 });
    try tt.expectEqual(@as(u8, 255), cv2.at(4, 0)[2]);
    try tt.expectEqual(@as(u8, 255), cv2.at(6, 2)[2]);
    const cap = try captureDrawing(tt.allocator, cv);
    defer tt.allocator.free(cap);
    try tt.expectEqualStrings("HDDVDCIF", cap[0..8]);
    try tt.expectEqual(@as(usize, 64 + 400), cap.len);
}
