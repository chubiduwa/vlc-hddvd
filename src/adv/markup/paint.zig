//! Painting a laid-out markup page into the graphics plane (HD DVD Vol. 3 §7.3.1.2–7.3.1.3, §7.6, §7.8):
//!
//! - elements are drawn in z-index order, then document order (§7.3.1.3.1); `auto` (and the z-index of a
//!   non-positioned element) is the parent's level, so children stay with their parent;
//! - each box: background colour on its padding rectangle, then its background image (the frame
//!   `backgroundFrame` picks from the `backgroundImage` list; crop, flip, content size and scaling, position,
//!   repeat), then its intrinsic marks (an image object, a clear rectangle), then its borders, then the text
//!   of its lines;
//! - opacity applies to each element's own marks (the discs fade groups with `opacity="inherit"`);
//!   `visibility: hidden` hides an element's own marks only; everything is clipped to the region.
//!
//! No VLC dependency.

const std = @import("std");
const raster = @import("../raster.zig");
const planes = @import("../planes.zig");
const style = @import("style.zig");
const page_mod = @import("page.zig");
const layout = @import("layout.zig");

const Page = page_mod.Page;
const Elem = page_mod.Elem;
const Rect = raster.Rect;

fn rect(x: f32, y: f32, w: f32, h: f32) Rect {
    const x0 = @round(x);
    const y0 = @round(y);
    return .{ .x = @intFromFloat(x0), .y = @intFromFloat(y0), .w = @intFromFloat(@max(0, @round(x + w) - x0)), .h = @intFromFloat(@max(0, @round(y + h) - y0)) };
}

fn alpha(o: f32) u8 {
    return @intFromFloat(@round(std.math.clamp(o, 0, 1) * 255));
}

fn withOpacity(c: style.Color, o: f32) raster.Color {
    return .{ .r = c[0], .g = c[1], .b = c[2], .a = raster.mul(c[3], alpha(o)) };
}

/// Paints `page` laid out in `lay` into `f`, its region placed at `region` (canvas coordinates).
pub fn paint(gpa: std.mem.Allocator, page: *Page, lay: *const layout.Layout, res: layout.Res, f: *planes.Frame, region: Rect) void {
    const clip = region.intersect(f.canvas.bounds()) orelse return;
    const elems = page.elems.items;
    const ord = order(gpa, page) catch return;
    defer gpa.free(ord);
    var p: Painter = .{ .gpa = gpa, .page = page, .lay = lay, .res = res, .f = f, .clip = clip, .ox = @floatFromInt(region.x), .oy = @floatFromInt(region.y) };
    for (ord) |i| p.elem(elems[i]);
}

/// The page's elements in paint order (indices into `page.elems`), bottom first: (z level, document order).
/// The caller frees the list.
pub fn order(gpa: std.mem.Allocator, page: *const Page) ![]u32 {
    const elems = page.elems.items;
    const Key = struct { z: i64, i: u32 };
    const keys = try gpa.alloc(Key, elems.len);
    defer gpa.free(keys);
    for (elems, 0..) |e, i| {
        const parent_level: i64 = if (e.parent) |q| keys[q.index].z else 0;
        const own = e.style.position != .static and e.style.zIndex != null;
        keys[i] = .{ .z = if (own) e.style.zIndex.? else parent_level, .i = @intCast(i) };
    }
    std.mem.sort(Key, keys, {}, struct {
        fn less(_: void, a: Key, b: Key) bool {
            return a.z < b.z or (a.z == b.z and a.i < b.i);
        }
    }.less);
    const out = try gpa.alloc(u32, elems.len);
    for (keys, out) |k, *o| o.* = k.i;
    return out;
}

const Painter = struct {
    gpa: std.mem.Allocator,
    page: *Page,
    lay: *const layout.Layout,
    res: layout.Res,
    f: *planes.Frame,
    clip: Rect,
    ox: f32,
    oy: f32,

    fn elem(p: *Painter, e: *Elem) void {
        if (!e.box.shown) return;
        // A hidden ancestor (display none) hides the element even if it was laid out earlier.
        var a = e.parent;
        while (a) |x| : (a = x.parent) if (!x.box.shown) return;
        const s = &e.style;
        const cv = p.f.canvas;
        const b = e.box;
        const bw: [4]f32 = .{ edge(s.borders[0]), edge(s.borders[1]), edge(s.borders[2]), edge(s.borders[3]) };
        const outer = rect(p.ox + b.x, p.oy + b.y, b.w, b.h);
        const pad_x = p.ox + b.x + bw[3];
        const pad_y = p.oy + b.y + bw[0];
        const pad_w = b.w - bw[1] - bw[3];
        const pad_h = b.h - bw[0] - bw[2];
        const padding = rect(pad_x, pad_y, pad_w, pad_h);
        if (s.visible and e.kind != .span and e.kind != .br) {
            if (s.backgroundColor[3] > 0) cv.fill(p.clip, padding, withOpacity(s.backgroundColor, s.opacity));
            if (s.backgroundImage.len > 0 and hasBackgroundImage(e.kind)) p.image(e, s.backgroundImage[@intCast(std.math.clamp(s.backgroundFrame, 0, @as(i32, @intCast(s.backgroundImage.len - 1))))], padding);
            if (e.kind == .object) p.object(e, b, bw);
            // Borders.
            const sides = [4]Rect{
                .{ .x = outer.x, .y = outer.y, .w = outer.w, .h = @intFromFloat(@round(bw[0])) },
                .{ .x = outer.right() - @as(i32, @intFromFloat(@round(bw[1]))), .y = outer.y, .w = @intFromFloat(@round(bw[1])), .h = outer.h },
                .{ .x = outer.x, .y = outer.bottom() - @as(i32, @intFromFloat(@round(bw[2]))), .w = outer.w, .h = @intFromFloat(@round(bw[2])) },
                .{ .x = outer.x, .y = outer.y, .w = @intFromFloat(@round(bw[3])), .h = outer.h },
            };
            for (s.borders, sides) |bd, r| if (bd.style == .solid and bd.width > 0) cv.fill(p.clip, r, withOpacity(bd.color orelse s.color, s.opacity));
        }
        // The text of this block's lines (each run in its own element's style).
        for (p.lay.runs.items) |*r| if (r.block == e) p.run(r);
    }

    fn edge(b: style.Border) f32 {
        return if (b.style == .solid) b.width else 0;
    }

    fn hasBackgroundImage(k: page_mod.Kind) bool {
        return switch (k) {
            .area, .body, .div, .button, .input, .object => true,
            else => false,
        };
    }

    fn run(p: *Painter, r: *const layout.Run) void {
        const s = &r.elem.style;
        if (!s.visible) return;
        // A span's background behind its part of the line.
        if (r.elem != r.block and s.backgroundColor[3] > 0) p.f.canvas.fill(p.clip, rect(p.ox + r.x, p.oy + r.top, r.w, r.h), withOpacity(s.backgroundColor, s.opacity));
        if (s.color[3] == 0 or s.opacity == 0) return;
        const color = withOpacity(s.color, s.opacity);
        const baseline: i32 = @intFromFloat(@round(p.oy + r.baseline));
        for (r.glyphs) |g| r.font.draw(p.f.canvas, p.clip, p.ox + r.x + g.x, baseline, g.id, r.sx, r.sy, r.slant, color);
    }

    /// An object's intrinsic marks in its content rectangle.
    fn object(p: *Painter, e: *Elem, b: page_mod.Box, bw: [4]f32) void {
        const s = &e.style;
        const ty = e.node.attr("type") orelse return;
        const pad = s.padding;
        const cx = p.ox + b.x + bw[3] + pad[3].resolve(b.cb_w);
        const cy = p.oy + b.y + bw[0] + pad[0].resolve(b.cb_w);
        const cw = b.w - bw[1] - bw[3] - pad[1].resolve(b.cb_w) - pad[3].resolve(b.cb_w);
        const ch = b.h - bw[0] - bw[2] - pad[0].resolve(b.cb_w) - pad[2].resolve(b.cb_w);
        const content = rect(cx, cy, cw, ch);
        if (std.mem.eql(u8, ty, "application/x-clearrect")) {
            const target: planes.Target = if (std.mem.eql(u8, param(e, "TargetPlane") orelse "main", "sub")) .sub else .main;
            p.f.clearRect(p.clip, content, target) catch {};
            return;
        }
        if (std.mem.startsWith(u8, ty, "image/")) if (e.node.attr("src")) |src| {
            if (!s.visible) return;
            // The object's image follows the backgroundImage rules (§7.3.1.3.1), clipped to its content box.
            p.image(e, src, content);
        };
    }

    /// Draws image `ref` for element `e` in `area` (crop, flip, content size, scaling, position, repeat).
    fn image(p: *Painter, e: *Elem, ref: []const u8, area: Rect) void {
        const s = &e.style;
        if (area.empty() or s.opacity == 0 or !s.visible) return;
        const u = p.page.resolve(e.node, ref) catch return;
        defer p.page.gpa.free(u);
        const im = p.res.image(p.res.ctx, u) orelse return;
        var sr: Rect = im.bounds();
        if (s.crop) |c| sr = (Rect{ .x = @intCast(c[0]), .y = @intCast(c[1]), .w = @intCast(c[2] - c[0]), .h = @intCast(c[3] - c[1]) }).intersect(im.bounds()) orelse return;
        const iw: f32 = @floatFromInt(sr.w);
        const ih: f32 = @floatFromInt(sr.h);
        const aw: f32 = @floatFromInt(area.w);
        const ah: f32 = @floatFromInt(area.h);
        var tw = size(s.contentWidth, iw, aw);
        var th = size(s.contentHeight, ih, ah);
        // Uniform scaling keeps the aspect ratio unless both sizes are given (§7.6.3.3.2.48).
        const both = s.contentWidth != .auto and s.contentHeight != .auto;
        if (s.uniform and !both) {
            if (s.contentWidth == .auto and s.contentHeight != .auto) tw = iw * th / ih;
            if (s.contentHeight == .auto and s.contentWidth != .auto) th = ih * tw / iw;
        } else if (s.uniform and s.contentWidth == .scale_to_fit and s.contentHeight == .scale_to_fit) {
            const k = @min(aw / iw, ah / ih);
            tw = iw * k;
            th = ih * k;
        }
        const px = position(s.backgroundPositionHorizontal, aw, tw);
        const py = position(s.backgroundPositionVertical, ah, th);
        const flip_x = s.flip == .inlineProgression or s.flip == .both;
        const flip_y = s.flip == .blockProgression or s.flip == .both;
        const clip = area.intersect(p.clip) orelse return;
        const a = alpha(s.opacity);
        const w: i32 = @intFromFloat(@max(1, @round(tw)));
        const h: i32 = @intFromFloat(@max(1, @round(th)));
        const x0 = area.x + @as(i32, @intFromFloat(@round(px)));
        const y0 = area.y + @as(i32, @intFromFloat(@round(py)));
        if (!s.backgroundRepeat) {
            raster.drawImage(p.f.canvas, clip, .{ .x = x0, .y = y0, .w = w, .h = h }, im.*, sr, flip_x, flip_y, a);
            return;
        }
        // Tiles from the positioned one outwards, covering the area.
        var ty = y0 - @divFloor(y0 - area.y + h - 1, h) * h;
        while (ty < area.bottom()) : (ty += h) {
            var tx = x0 - @divFloor(x0 - area.x + w - 1, w) * w;
            while (tx < area.right()) : (tx += w) raster.drawImage(p.f.canvas, clip, .{ .x = tx, .y = ty, .w = w, .h = h }, im.*, sr, flip_x, flip_y, a);
        }
    }

    fn size(cs: style.ContentSize, intrinsic: f32, avail: f32) f32 {
        return switch (cs) {
            .auto => intrinsic,
            .scale_to_fit => avail,
            .len => |l| l.resolve(intrinsic),
        };
    }

    /// Lengths offset the image; percentages align the same point of the image and the area (CSS2).
    fn position(l: style.Len, avail: f32, img: f32) f32 {
        return if (l.unit == .pct) (avail - img) * l.v / 100 else l.v;
    }
};

/// The value of an object's `param` (content, else the value attribute; §7.5.3.1.13).
pub fn param(e: *const Elem, name: []const u8) ?[]const u8 {
    var c = e.node.firstElement();
    while (c) |n| : (c = n.nextElement()) {
        if (!n.is(page_mod.core_ns, "param")) continue;
        if (!std.mem.eql(u8, n.attr("name") orelse "", name)) continue;
        if (n.first) |t| if (t.type == .text and std.mem.trim(u8, t.data, " \t\r\n").len > 0) return std.mem.trim(u8, t.data, " \t\r\n");
        return n.attr("value");
    }
    return null;
}

// ---- tests --------------------------------------------------------------------------------------------------

const testing = std.testing;

const TestRes = struct {
    img: raster.Canvas,

    fn font(_: *anyopaque, _: *Page, _: *Elem) ?*@import("../font.zig").Font {
        return null;
    }
    fn image(ctx: *anyopaque, u: []const u8) ?*const raster.Canvas {
        const self: *TestRes = @ptrCast(@alignCast(ctx));
        return if (std.mem.endsWith(u8, u, "a.png")) &self.img else null;
    }
    fn res(self: *TestRes) layout.Res {
        return .{ .ctx = self, .font = font, .image = image };
    }
};

test "backgrounds, images, z order, opacity, clear rectangles" {
    const gpa = testing.allocator;
    var tr: TestRes = .{ .img = try raster.Canvas.init(gpa, 2, 2) };
    defer tr.img.deinit(gpa);
    @memset(tr.img.px, .{ 0, 0, 255, 255 }); // blue
    tr.img.px[0] = .{ 0, 255, 0, 255 }; // green top left

    const p = try Page.fromBytes(gpa, null,
        \\<root xmlns="http://www.dvdforum.org/2005/ihd" xmlns:style="http://www.dvdforum.org/2005/ihd#style" xml:lang="en"><body>
        \\<div id="top" style:position="absolute" style:x="0px" style:y="0px" style:width="10px" style:height="10px" style:zIndex="5" style:backgroundColor="red"/>
        \\<div id="under" style:position="absolute" style:x="5px" style:y="5px" style:width="10px" style:height="10px" style:backgroundColor="white" style:opacity="0.5"/>
        \\<div id="img" style:position="absolute" style:x="20px" style:y="0px" style:width="4px" style:height="4px"
        \\     style:backgroundImage="url('b.png') url('a.png')" style:backgroundFrame="1" style:backgroundRepeat="repeat"
        \\     style:contentWidth="2px" style:contentHeight="2px" style:flip="inlineProgression"
        \\     style:border="1px solid lime"/>
        \\<object type="application/x-clearrect" style:position="absolute" style:x="2px" style:y="2px" style:width="2px" style:height="2px"/>
        \\</body></root>
    , "file:///dvddisc/p.xmu", 1080);
    defer p.destroy();
    var lay = layout.Layout.init(gpa);
    defer lay.deinit();
    lay.run(p, tr.res(), 100, 50);
    const f = try planes.Frame.create(gpa, 64, 64);
    defer f.unref();
    paint(gpa, p, &lay, tr.res(), f, .{ .x = 0, .y = 0, .w = 100, .h = 50 });
    const c = f.canvas;
    // zIndex 5 paints over the later element (its own level).
    try testing.expectEqual(raster.Px{ 255, 0, 0, 255 }, c.at(7, 7));
    // Half-transparent white where only "under" is.
    try testing.expectEqual(raster.Px{ 128, 128, 128, 128 }, c.at(12, 12));
    // The clear rectangle (painted after "top", last in document order at level 0... "top" is above it).
    try testing.expectEqual(1, f.clears.items.len);
    // The border, then the 2×2 frame 1 image, mirrored and tiled in the 2×2 padding box at (21, 1).
    try testing.expectEqual(raster.Px{ 0, 255, 0, 255 }, c.at(20, 0)); // lime border
    try testing.expectEqual(raster.Px{ 0, 0, 255, 255 }, c.at(21, 1)); // mirrored: blue on the left
    try testing.expectEqual(raster.Px{ 0, 255, 0, 255 }, c.at(22, 1)); // green on the right
}
