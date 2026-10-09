//! Layout of a markup page (HD DVD Vol. 3 §7.3.1.3, §7.3.2, with the XSL 1.0 semantics the spec refers to):
//!
//! - the page is laid out in its application's region; `body`, `div`, `p` are blocks stacked in the block
//!   direction, `span` and text are inline; `button`, `input` and `object` are blocks in a block context and
//!   inline boxes in a line;
//! - `position: absolute` boxes leave the flow and are placed by `x`, `y` and the 9-point `anchor` in the
//!   content rectangle of their nearest positioned ancestor (or the region); `relative` boxes are shifted by
//!   `x`, `y` from where the flow put them;
//! - padding, borders, start/end indents, width/height (or inline/block progression dimensions), and
//!   `displayAlign` for the content of a box with a known height;
//! - text: white space handling (`linefeedTreatment`, `whiteSpaceTreatment`, `whiteSpaceCollapse`), then line
//!   fitting as in §7.3.2.3 (greedy, breaking before the last break opportunity; leading white space on a line
//!   is dropped), and line stacking as in §7.3.2.4 (a line that does not fit in the remaining height ends the
//!   paragraph); `textAlign`, `textIndent`, `lineHeight`, `textAltitude`/`textDepth`;
//! - `input` shows its `state:value` (dots for `password`), `button` and `object` do not show their
//!   alternative-text `p`.
//!
//! - writing modes (XSL §7.27.7): each flow is laid out along its inline and block progressions, and a `div`
//!   with a writing mode of its own starts a new flow on its content rectangle: `rl-tb` lines run right to
//!   left, `tb-rl` lines are columns from the right, their characters upright or turned by their
//!   Vertical_Orientation (UAX #50). An orthogonal flow's auto block extent is what its container has left.
//!   `x`, `y`, `width` and `height` stay region-oriented; `anchor` and the edges are writing-mode relative;
//! - bidi (UAX #9): a paragraph's base direction is its `direction`, or right to left in `rl-tb`; a `span`
//!   changing the direction is an embedding; lines are fitted in logical order and drawn in visual order,
//!   mirrored characters at right-to-left levels.
//!
//! The results are each element's `box` and a list of glyph runs. No VLC dependency.

const std = @import("std");
const dom = @import("../dom.zig");
const font_mod = @import("../font.zig");
const raster = @import("../raster.zig");
const image_mod = @import("../image.zig");
const bidi = @import("bidi.zig");
const ucd = @import("ucd.zig");
const style = @import("style.zig");
const page_mod = @import("page.zig");

const Page = page_mod.Page;
const Elem = page_mod.Elem;
const Font = font_mod.Font;

/// Fonts and images for layout and painting, cached by the application.
pub const Res = struct {
    ctx: *anyopaque,
    /// The font an element's style names (null: none could be loaded; its text is not drawn).
    font: *const fn (ctx: *anyopaque, page: *Page, e: *Elem) ?*Font,
    /// A decoded image by absolute URI.
    image: *const fn (ctx: *anyopaque, u: []const u8) ?*image_mod.Image,
};

pub const Glyph = struct {
    id: u32,
    /// Its pen position along the run, from the run's start.
    x: f32,
    /// Vertical text: set upright (else turned 90° clockwise, its baseline along the column).
    upright: bool = false,
};

/// Glyphs on one line drawn with one element's style.
pub const Run = struct {
    /// The element whose style draws it (p, span or input).
    elem: *Elem,
    /// The block whose content it is (painted with it).
    block: *Elem,
    font: *Font,
    sx: f32,
    sy: f32,
    slant: f32,
    /// Horizontal text: the baseline's y. Vertical text: the column's centre line's x.
    baseline: f32,
    /// The run's rectangle, for inline backgrounds. Glyphs go right from `x`, or down from `top` when
    /// `vertical`.
    x: f32,
    w: f32,
    top: f32,
    h: f32,
    vertical: bool = false,
    glyphs: []Glyph,

    fn move(r: *Run, dx: f32, dy: f32) void {
        r.x += dx;
        r.top += dy;
        r.baseline += if (r.vertical) dx else dy;
    }
};

const Rect = struct { x: f32, y: f32, w: f32, h: f32 };

pub const Layout = struct {
    arena: std.heap.ArenaAllocator,
    runs: std.ArrayList(Run) = .empty,

    pub fn init(gpa: std.mem.Allocator) Layout {
        return .{ .arena = .init(gpa) };
    }

    pub fn deinit(l: *Layout) void {
        l.arena.deinit();
    }

    /// Lays out `page` in a region of `w`×`h`.
    pub fn run(l: *Layout, page: *Page, res: Res, w: f32, h: f32) void {
        _ = l.arena.reset(.retain_capacity);
        l.runs = .empty;
        for (page.elems.items) |e| e.box = .{};
        const body = if (page.body) |b| Page.elemOf(b) else null;
        const b = body orelse return;
        var lc: Ctx = .{ .l = l, .page = page, .res = res, .a = l.arena.allocator() };
        const region: Rect = .{ .x = 0, .y = 0, .w = w, .h = h };
        _ = lc.block(b, .{ .x = 0, .y = 0, .w = w, .h = h, .cb = h, .ref = region, .fr = .of(region, .@"lr-tb") });
    }
};

/// The coordinates of a flow (XSL §7.27.7): `x` along the inline progression and `y` along the block
/// progression, from the start-before corner of the content rectangle whose writing mode set them.
const Frame = struct {
    /// That corner, in region coordinates.
    ox: f32,
    oy: f32,
    mode: style.WritingMode,

    fn vertical(f: Frame) bool {
        return f.mode == .@"tb-rl";
    }

    /// The frame of content rectangle `r` (region coordinates) in writing mode `mode`.
    fn of(r: Rect, mode: style.WritingMode) Frame {
        return .{ .ox = if (mode == .@"lr-tb") r.x else r.x + r.w, .oy = r.y, .mode = mode };
    }

    /// Rectangle `r` of the frame in region coordinates.
    fn box(f: Frame, r: Rect) Rect {
        return switch (f.mode) {
            .@"lr-tb" => .{ .x = f.ox + r.x, .y = f.oy + r.y, .w = r.w, .h = r.h },
            .@"rl-tb" => .{ .x = f.ox - r.x - r.w, .y = f.oy + r.y, .w = r.w, .h = r.h },
            .@"tb-rl" => .{ .x = f.ox - r.y - r.h, .y = f.oy + r.x, .w = r.h, .h = r.w },
        };
    }

    /// Region offset of `d` along the block progression.
    fn blockStep(f: Frame, d: f32) [2]f32 {
        return if (f.vertical()) .{ -d, 0 } else .{ 0, d };
    }
};

/// Which edge (0 before, 1 end, 2 after, 3 start: the order of the border and padding properties) is on each
/// side (top, right, bottom, left) in writing mode `mode`.
pub fn sides(mode: style.WritingMode) [4]usize {
    return switch (mode) {
        .@"lr-tb" => .{ 0, 1, 2, 3 },
        .@"rl-tb" => .{ 0, 3, 2, 1 },
        .@"tb-rl" => .{ 3, 0, 1, 2 },
    };
}

/// Border plus padding on each edge (before, end, after, start); percentages of `base`.
fn edges(e: *const Elem, base: f32) [4]f32 {
    var out: [4]f32 = undefined;
    for (0..4) |i| {
        const b = e.style.borders[i];
        const bw: f32 = if (b.style == .solid) b.width else 0;
        out[i] = bw + e.style.padding[i].resolve(base);
    }
    return out;
}

/// Border plus padding on each side (top, right, bottom, left) of a laid-out element. Padding percentages are
/// of the containing block's inline progression dimension.
pub fn physEdges(e: *const Elem) [4]f32 {
    const sd = sides(e.style.writingMode);
    const ed = edges(e, if (e.style.writingMode == .@"tb-rl") e.box.cb_h else e.box.cb_w);
    return .{ ed[sd[0]], ed[sd[1]], ed[sd[2]], ed[sd[3]] };
}

/// Side widths (top, right, bottom, left) as a frame's (before, end, after, start).
fn toFrame(p: [4]f32, mode: style.WritingMode) [4]f32 {
    const sd = sides(mode);
    var out: [4]f32 = undefined;
    for (0..4) |j| out[sd[j]] = p[j];
    return out;
}

/// The specified width and height (null: auto), percentages of the containing block's `cb_w`×`cb_h`. The
/// inline and block progression dimensions are the element's own writing mode's.
fn specSize(e: *const Elem, cb_w: f32, cb_h: f32) [2]?f32 {
    const s = &e.style;
    const v = s.writingMode == .@"tb-rl";
    const w = s.width orelse (if (v) s.blockProgressionDimension else s.inlineProgressionDimension);
    const h = s.height orelse (if (v) s.inlineProgressionDimension else s.blockProgressionDimension);
    return .{ if (w) |l| @max(0, l.resolve(cb_w)) else null, if (h) |l| @max(0, l.resolve(cb_h)) else null };
}

/// Where a block is laid, in frame coordinates: the containing content box's inline start and extent, the
/// flow position, and the block extent left; the containing block's block extent (percentages); the
/// reference rectangle for absolutely positioned descendants (region coordinates).
const Flow = struct {
    x: f32,
    y: f32,
    w: f32,
    /// Block extent available from `y` (null: unbounded).
    h: ?f32,
    cb: f32,
    ref: Rect,
    fr: Frame,
};

const Ctx = struct {
    l: *Layout,
    page: *Page,
    res: Res,
    a: std.mem.Allocator,

    /// Positioned in the sense of §7.6 "positionable": div, button, object in a block context.
    fn positioned(e: *const Elem) bool {
        return e.style.position != .static and (e.kind == .div or e.kind == .button or e.kind == .object or e.kind == .input or e.kind == .body);
    }

    /// The intrinsic size of an object's image (null if none).
    fn intrinsic(c: *Ctx, e: *Elem) ?[2]f32 {
        if (e.kind != .object) return null;
        const src = e.node.attr("src") orelse return null;
        const t = e.node.attr("type") orelse "";
        if (!std.mem.startsWith(u8, t, "image/")) return null;
        const u = c.page.resolve(e.node, src) catch return null;
        defer c.page.gpa.free(u);
        const im = c.res.image(c.res.ctx, u) orelse return null;
        var w: f32 = @floatFromInt(im.w);
        var h: f32 = @floatFromInt(im.h);
        // Crop does not apply to an MNG object (§7.6.3.3.2.19).
        if (e.style.crop) |cr| if (!std.mem.eql(u8, t, "image/mng")) {
            w = @floatFromInt(@min(cr[2], im.w) -| cr[0]);
            h = @floatFromInt(@min(cr[3], im.h) -| cr[1]);
        };
        return .{ w, h };
    }

    /// Lays out block-level element `e` in flow `f`; returns the block extent it takes in the flow.
    fn block(c: *Ctx, e: *Elem, f: Flow) f32 {
        if (!e.style.display) return 0;
        const fv = f.fr.vertical();
        e.box.cb_w = if (fv) f.cb else f.w;
        e.box.cb_h = if (fv) f.w else f.cb;
        if (e.style.position == .absolute and positioned(e)) {
            c.absolute(e, f.ref);
            return 0;
        }
        const mode = e.style.writingMode;
        const ed = toFrame(physEdges(e), f.fr.mode);
        const start_i = e.style.startIndent.resolve(f.w);
        const end_i = e.style.endIndent.resolve(f.w);
        // Sizes along the frame's inline (lw) and block (lh) progressions.
        const sz = specSize(e, e.box.cb_w, e.box.cb_h);
        const intr: ?[2]f32 = if (c.intrinsic(e)) |s| (if (fv) .{ s[1], s[0] } else s) else null;
        const lw = (if (fv) sz[1] else sz[0]) orelse if (intr) |s| s[0] else @max(0, f.w - start_i - end_i - ed[1] - ed[3]);
        var spec_lh = (if (fv) sz[0] else sz[1]) orelse if (intr) |s| s[1] else null;
        const orth = (mode == .@"tb-rl") != fv;
        // A flow orthogonal to its container's takes the block extent left (XSL leaves it to the processor).
        if (orth and spec_lh == null) spec_lh = @max(0, (f.h orelse f.cb) - ed[0] - ed[2]);
        const u = f.x + start_i;
        const outer_w = lw + ed[1] + ed[3];
        e.box.shown = true;
        c.place(e, f.fr.box(.{ .x = u, .y = f.y, .w = outer_w, .h = (spec_lh orelse 0) + ed[0] + ed[2] }));
        const inner: Rect = .{ .x = u + ed[3], .y = f.y + ed[0], .w = lw, .h = spec_lh orelse 0 };
        const phys_inner = f.fr.box(inner);
        const ref = if (positioned(e)) phys_inner else f.ref;
        // Text stops at the extent the box has, or what is left of its container's (§7.3.2.4).
        const avail = spec_lh orelse if (f.h) |fh| @max(0, fh - ed[0] - ed[2]) else null;
        var ch: f32 = undefined;
        var slack: f32 = 0;
        var content_fr = f.fr;
        if (mode == f.fr.mode) {
            ch = c.content(e, inner, avail, ref, f.fr);
            if (spec_lh) |sh| slack = sh - ch;
        } else {
            // A writing mode of its own: a frame on its content rectangle.
            content_fr = .of(phys_inner, mode);
            const v2 = mode == .@"tb-rl";
            const lw2 = if (v2) phys_inner.h else phys_inner.w;
            const lh2: ?f32 = if (orth) (if (v2) phys_inner.w else phys_inner.h) else avail;
            const ch2 = c.content(e, .{ .x = 0, .y = 0, .w = lw2, .h = lh2 orelse 0 }, lh2, ref, content_fr);
            ch = if (orth) spec_lh.? else ch2;
            if (orth) slack = lh2.? - ch2 else if (spec_lh) |sh| slack = sh - ch2;
        }
        const h = (spec_lh orelse ch) + ed[0] + ed[2];
        c.place(e, f.fr.box(.{ .x = u, .y = f.y, .w = outer_w, .h = h }));
        c.alignContent(e, slack, content_fr);
        if (e.style.position == .relative and positioned(e)) {
            // x and y are region-oriented (left and top, §7.6.3.3.2.61–62).
            const dx = (e.style.x orelse style.Len.px(0)).resolve(e.box.cb_w);
            const dy = (e.style.y orelse style.Len.px(0)).resolve(e.box.cb_h);
            c.shift(e, dx, dy);
        }
        return h;
    }

    fn place(_: *Ctx, e: *Elem, r: Rect) void {
        e.box.x = r.x;
        e.box.y = r.y;
        e.box.w = r.w;
        e.box.h = r.h;
    }

    /// Absolutely positioned `e` in reference rectangle `ref` (§7.6.3.3.2.1): (x, y) is a point of the
    /// reference rectangle, and `anchor` names the point of the element put there, relative to its
    /// container's writing mode (start/end along the inline progression, before/after along the block
    /// progression). Its content is laid out in its own writing mode.
    fn absolute(c: *Ctx, e: *Elem, ref: Rect) void {
        const s = &e.style;
        const mode = s.writingMode;
        const v = mode == .@"tb-rl";
        e.box.cb_w = ref.w;
        e.box.cb_h = ref.h;
        e.box.shown = true;
        const pe = physEdges(e);
        const x = (s.x orelse style.Len.px(0)).resolve(ref.w);
        const y = (s.y orelse style.Len.px(0)).resolve(ref.h);
        const sz = specSize(e, ref.w, ref.h);
        const intr = c.intrinsic(e);
        var W: ?f32 = sz[0] orelse if (intr) |i| i[0] else null;
        var H: ?f32 = sz[1] orelse if (intr) |i| i[1] else null;
        const f = anchorFactors(s.anchor, if (e.parent) |q| q.style.writingMode else .@"lr-tb");
        // An auto inline extent: the room the reference rectangle has where the anchor makes the box extend.
        if (!v and W == null) W = @max(0, room(f[0], x, ref.w) - pe[1] - pe[3]);
        if (v and H == null) H = @max(0, room(f[1], y, ref.h) - pe[0] - pe[2]);
        const lw = if (v) H.? else W.?;
        const given_lh = if (v) W else H;
        // An auto block extent is the content's: laid out once to measure it.
        const lh = given_lh orelse blk: {
            const before = c.l.runs.items.len;
            const zero: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
            const ch = c.content(e, .{ .x = 0, .y = 0, .w = lw, .h = 0 }, null, zero, .of(zero, mode));
            c.l.runs.shrinkRetainingCapacity(before);
            break :blk ch;
        };
        if (v) W = lh else H = lh;
        e.box.x = ref.x + x - offset(f[0], W.?, pe[3], pe[1]);
        e.box.y = ref.y + y - offset(f[1], H.?, pe[0], pe[2]);
        e.box.w = W.? + pe[1] + pe[3];
        e.box.h = H.? + pe[0] + pe[2];
        const inner: Rect = .{ .x = e.box.x + pe[3], .y = e.box.y + pe[0], .w = W.?, .h = H.? };
        const fr: Frame = .of(inner, mode);
        const ch = c.content(e, .{ .x = 0, .y = 0, .w = lw, .h = lh }, given_lh, inner, fr);
        if (given_lh) |g| c.alignContent(e, g - ch, fr);
    }

    fn room(f: f32, at: f32, size: f32) f32 {
        return if (f == 0) size - at else if (f == 1) at else 2 * @min(at, size - at);
    }

    /// Where along a side the anchor point is: 0 the left/top outer edge, 1 the right/bottom one, ½ the
    /// content's centre (Table 7.6.3.3.2.1-1).
    fn offset(f: f32, size: f32, e0: f32, e1: f32) f32 {
        return if (f == 0) 0 else if (f == 1) size + e0 + e1 else size / 2 + e0;
    }

    /// The anchor as fractions across (x) and down (y) in writing mode `mode`.
    fn anchorFactors(a: style.Anchor, mode: style.WritingMode) [2]f32 {
        const s: f32 = switch (a) {
            .startBefore, .startCenter, .startAfter => 0,
            .centerBefore, .center, .centerAfter => 0.5,
            .endBefore, .endCenter, .endAfter => 1,
        };
        const b: f32 = switch (a) {
            .startBefore, .centerBefore, .endBefore => 0,
            .startCenter, .center, .endCenter => 0.5,
            .startAfter, .centerAfter, .endAfter => 1,
        };
        return switch (mode) {
            .@"lr-tb" => .{ s, b },
            .@"rl-tb" => .{ 1 - s, b },
            .@"tb-rl" => .{ 1 - b, s },
        };
    }

    /// Lays out the content of `e` in its content rectangle `box` (frame coordinates); returns the content's
    /// block extent. `ref` is for absolutely positioned descendants.
    fn content(c: *Ctx, e: *Elem, box: Rect, avail_h: ?f32, ref: Rect, fr: Frame) f32 {
        switch (e.kind) {
            .p, .span => return c.paragraph(e, box, avail_h, fr, null),
            .input => {
                if (std.mem.eql(u8, e.node.attr("mode") orelse "", "password")) {
                    var dots: std.ArrayList(u8) = .empty;
                    const n = std.unicode.utf8CountCodepoints(e.state.value) catch e.state.value.len;
                    for (0..n) |_| dots.appendSlice(c.a, "\u{2022}") catch break;
                    return c.paragraph(e, box, avail_h, fr, dots.items);
                }
                return c.paragraph(e, box, avail_h, fr, e.state.value);
            },
            .button, .br => return 0, // a button's p is alternative text
            .object => {
                c.areas(e);
                return box.h;
            },
            .area => return 0,
            .body, .div => {},
        }
        // Children: blocks in the flow; inline runs (text, span, br) in anonymous paragraphs.
        var y = box.y;
        var ch = e.node.first;
        while (ch) |n| : (ch = n.next) {
            const k = page_mod.Kind.of(n);
            if (k == null) continue; // text in a div is not allowed; foreign elements are skipped
            const child = Page.elemOf(n) orelse continue;
            if (k == .span or k == .br) {
                y += c.paragraph(child, .{ .x = box.x, .y = y, .w = box.w, .h = 0 }, null, fr, null);
                continue;
            }
            const left = if (avail_h) |h| @max(0, h - (y - box.y)) else null;
            const cb = left orelse if (fr.vertical()) ref.w else ref.h;
            y += c.block(child, .{ .x = box.x, .y = y, .w = box.w, .h = left, .cb = cb, .ref = ref, .fr = fr });
        }
        return y - box.y;
    }

    /// `area` children of an object: their boxes are their shapes' bounding rectangles in the object's box.
    fn areas(c: *Ctx, obj: *Elem) void {
        _ = c;
        var ch = obj.node.first;
        while (ch) |n| : (ch = n.next) {
            const e = Page.elemOf(n) orelse continue;
            if (e.kind != .area or !e.style.display) continue;
            const r = areaRect(e) orelse Rect{ .x = 0, .y = 0, .w = obj.box.w, .h = obj.box.h };
            e.box = .{ .x = obj.box.x + r.x, .y = obj.box.y + r.y, .w = r.w, .h = r.h, .cb_w = obj.box.w, .cb_h = obj.box.h, .shown = true };
        }
    }

    /// Shifts a laid-out subtree: its boxes and its runs.
    fn shift(c: *Ctx, e: *Elem, dx: f32, dy: f32) void {
        if (dx == 0 and dy == 0) return;
        const elems = c.page.elems.items;
        var i: usize = e.index;
        while (i < elems.len and (i == e.index or isDescendant(elems[i], e))) : (i += 1) {
            elems[i].box.x += dx;
            elems[i].box.y += dy;
        }
        for (c.l.runs.items) |*r| if (r.block == e or isDescendant(r.block, e)) r.move(dx, dy);
    }

    /// displayAlign: moves the content of a box with a given block extent (`slack` left over) along the
    /// block progression of frame `fr`.
    fn alignContent(c: *Ctx, e: *Elem, slack: f32, fr: Frame) void {
        if (slack <= 0) return;
        const d = fr.blockStep(switch (e.style.displayAlign) {
            .auto, .before => return,
            .center => slack / 2,
            .after => slack,
        });
        const elems = c.page.elems.items;
        var i: usize = e.index + 1;
        while (i < elems.len and isDescendant(elems[i], e)) : (i += 1) {
            // Absolutely positioned descendants keep their place.
            if (elems[i].style.position != .absolute) {
                elems[i].box.x += d[0];
                elems[i].box.y += d[1];
            }
        }
        for (c.l.runs.items) |*r| if (r.block == e or isDescendant(r.block, e)) r.move(d[0], d[1]);
    }

    // ---- paragraphs -----------------------------------------------------------------------------------------

    const Item = struct {
        cp: u21,
        /// The element whose style draws it, and its font.
        elem: *Elem,
        font: ?*Font,
        glyph: u32 = 0,
        /// Advance along the line, and kerning before the next item when they are side by side.
        adv: f32 = 0,
        kern: f32 = 0,
        /// Bidi embedding level.
        level: u8 = 0,
        /// Vertical text: set upright.
        upright: bool = false,
        /// An inline box (button, input, object) instead of a character.
        inline_box: ?*Elem = null,
    };

    /// Lays out inline content as lines: the text of `e` (or `text` instead, for inputs). Returns the block
    /// extent.
    fn paragraph(c: *Ctx, e: *Elem, box: Rect, avail_h: ?f32, fr: Frame, text: ?[]const u8) f32 {
        const s = &e.style;
        const vertical = fr.vertical();
        // The base direction: `direction`, or right to left in rl-tb (XSL §7.27.1, §7.27.7).
        const para: u1 = if (s.rtl or s.writingMode == .@"rl-tb") 1 else 0;
        var items: std.ArrayList(Item) = .empty;
        if (text) |t| {
            c.addText(&items, e, t, true);
        } else if (e.kind == .span or e.kind == .br) {
            c.collect(&items, e);
        } else {
            var ch = e.node.first;
            while (ch) |n| : (ch = n.next) c.collectNode(&items, n, e);
        }
        const single = text != null and !std.mem.eql(u8, e.node.attr("mode") orelse "singleline", "multiline");
        const wrap = s.wrap and !single;
        c.bidiLevels(items.items, para);

        // Measure.
        for (items.items) |*it| {
            if (it.inline_box) |b| {
                it.adv = if (vertical) b.box.h else b.box.w;
                continue;
            }
            if (bidi.isControl(it.cp)) {
                it.font = null;
                continue;
            }
            const f = it.font orelse continue;
            // Mirrored characters at right-to-left levels (UAX #9 L4), if the font has the mirror.
            var cp = it.cp;
            if (it.level & 1 == 1) if (bidi.mirror(cp)) |m| if (f.glyphIndex(m) != 0) {
                cp = m;
            };
            it.glyph = f.glyphIndex(cp);
            it.upright = vertical and isUpright(it.cp);
            const st = &it.elem.style;
            it.adv = if (it.upright) blk: {
                const vm = f.vmetrics(st.fontSize[1]);
                break :blk vm.ascent + vm.descent;
            } else f.advance(it.glyph, st.fontSize[0]);
        }
        // Kerning (the 'kern' pairs are in visual order).
        if (items.items.len > 1) for (items.items[1..], 1..) |it, i| {
            const prev = &items.items[i - 1];
            const f = it.font orelse continue;
            if (prev.font != f or prev.inline_box != null or prev.level != it.level or prev.upright or it.upright) continue;
            const size = it.elem.style.fontSize[0];
            prev.kern = if (it.level & 1 == 0) f.kern(prev.glyph, it.glyph, size) else f.kern(it.glyph, prev.glyph, size);
        };

        // Fit and stack lines.
        var y = box.y;
        var i: usize = 0;
        var first = true;
        // Lines start on the other side of the frame when the paragraph's direction is the opposite one.
        const flip = (para == 1) != (fr.mode == .@"rl-tb");
        while (i < items.items.len) {
            // 1. Leading white space is dropped on every line.
            while (i < items.items.len and isSpace(items.items[i].cp) and !isMandatory(items.items[i].cp)) i += 1;
            if (i >= items.items.len) break;
            const indent = if (first) s.textIndent.resolve(box.w) else 0;
            const limit = box.w - indent;
            var w: f32 = 0;
            var j = i;
            var last_break: ?usize = null;
            var end = items.items.len;
            var next = items.items.len;
            while (j < items.items.len) : (j += 1) {
                const it = items.items[j];
                if (isMandatory(it.cp)) {
                    end = j;
                    next = j + 1;
                    break;
                }
                if (j > i and (isBreak(it.cp) or (j > 0 and items.items[j - 1].cp == 0xFFFC))) last_break = j;
                if (wrap and w + it.adv > limit and j > i) {
                    if (last_break) |b| {
                        end = b;
                        next = b;
                    } else {
                        end = j; // no opportunity: break at the last glyph that fits
                        next = j;
                    }
                    break;
                }
                w += it.adv + it.kern;
            }
            // Trailing white space neither shows nor counts for alignment.
            var vis_end = end;
            while (vis_end > i and isSpace(items.items[vis_end - 1].cp)) vis_end -= 1;
            const line = items.items[i..vis_end];
            const m = c.lineMetrics(e, line, vertical);
            // §7.3.2.4: a line that does not fit in the extent left ends the paragraph.
            if (avail_h) |ah| if (y - box.y + m.h > ah + 0.01) break;
            var lw: f32 = 0;
            for (line, 0..) |it, k| lw += it.adv + (if (k + 1 < line.len) it.kern else 0);
            const slack = @max(0, limit - lw);
            const align_off: f32 = switch (s.textAlign) {
                .start => 0,
                .center => slack / 2,
                .end => slack,
            };
            const start_u = if (flip) box.x + box.w - indent - align_off - lw else box.x + indent + align_off;
            c.emitLine(e, line, fr.box(.{ .x = start_u, .y = y, .w = lw, .h = m.h }), m, vertical, para);
            y += m.h;
            i = next;
            first = false;
        }
        return y - box.y;
    }

    /// The bidi levels of a paragraph's items (UAX #9; a U+2029 ends a bidi paragraph).
    fn bidiLevels(c: *Ctx, items: []Item, para: u1) void {
        const n = items.len;
        const cps = c.a.alloc(u21, n) catch return;
        const lv = c.a.alloc(u8, n) catch return;
        for (items, cps) |it, *cp| cp.* = it.cp;
        var start: usize = 0;
        for (0..n + 1) |i| {
            if (i < n and cps[i] != 0x2029) continue;
            const end = if (i < n) i + 1 else n;
            bidi.resolve(c.a, cps[start..end], para, lv[start..end]) catch @memset(lv[start..end], para);
            start = end;
        }
        for (items, lv) |*it, l| it.level = l;
    }

    const LineMetrics = struct { h: f32, baseline: f32 };

    /// A line's extent along the block progression, and its baseline from its before edge (horizontal text).
    fn lineMetrics(c: *Ctx, block_elem: *Elem, line: []const Item, vertical: bool) LineMetrics {
        _ = c;
        var asc: f32 = 0;
        var desc: f32 = 0;
        var gap: f32 = 0;
        var any = false;
        for (line) |it| {
            const f = it.font orelse continue;
            const st = &it.elem.style;
            const vm = f.vmetrics(st.fontSize[1]);
            const a = if (st.textAltitude) |l| l.resolve(st.fontSize[1]) else vm.ascent;
            const d = if (st.textDepth) |l| l.resolve(st.fontSize[1]) else vm.descent;
            asc = @max(asc, a);
            desc = @max(desc, d);
            gap = @max(gap, vm.line_gap);
            any = true;
        }
        if (!any) {
            // An empty line (or only boxes): the block's own font size.
            asc = block_elem.style.fontSize[1] * 0.8;
            desc = block_elem.style.fontSize[1] * 0.2;
        }
        for (line) |it| if (it.inline_box) |b| {
            asc = @max(asc, if (vertical) b.box.w else b.box.h);
        };
        const natural = asc + desc + gap;
        const h = block_elem.style.lineHeight orelse natural;
        return .{ .h = h, .baseline = (h - (asc + desc)) / 2 + asc };
    }

    /// Emits a line's runs in visual order (UAX #9 L2) in its rectangle `r` (region coordinates): from the left,
    /// or from the top in vertical text, where each column is centred on its middle.
    fn emitLine(c: *Ctx, block_elem: *Elem, line: []const Item, r: Rect, m: LineMetrics, vertical: bool, para: u1) void {
        const n = line.len;
        const order = c.a.alloc(usize, n) catch return;
        const cps = c.a.alloc(u21, n) catch return;
        const lv = c.a.alloc(u8, n) catch return;
        for (line, cps, lv) |it, *cp, *l| {
            cp.* = it.cp;
            l.* = it.level;
        }
        bidi.reorder(c.a, cps, lv, para, 0, n, order) catch for (order, 0..) |*o, k| {
            o.* = k;
        };
        const kernAfter = struct {
            fn f(ln: []const Item, ord: []const usize, k: usize) f32 {
                if (k + 1 >= ord.len) return 0;
                const a = ord[k];
                const b = ord[k + 1];
                return if (b == a + 1) ln[a].kern else if (a == b + 1) ln[b].kern else 0;
            }
        }.f;
        var pen: f32 = 0;
        var k: usize = 0;
        while (k < n) {
            const it = line[order[k]];
            if (it.inline_box) |b| {
                if (vertical) c.inlineBox(b, r.x + (r.w - b.box.w) / 2, r.y + pen) else c.inlineBox(b, r.x + pen, r.y + m.baseline - b.box.h);
                pen += it.adv + kernAfter(line, order, k);
                k += 1;
                continue;
            }
            const f = it.font orelse {
                pen += it.adv;
                k += 1;
                continue;
            };
            // A run: glyphs side by side of the same element and font.
            var glyphs: std.ArrayList(Glyph) = .empty;
            const start = pen;
            while (k < n) : (k += 1) {
                const x = line[order[k]];
                if (x.inline_box != null or x.elem != it.elem or x.font != f) break;
                glyphs.append(c.a, .{ .id = x.glyph, .x = pen - start, .upright = x.upright }) catch {};
                pen += x.adv + kernAfter(line, order, k);
            }
            const st = &it.elem.style;
            const slant: f32 = switch (st.fontStyle) {
                .normal => 0,
                .italic, .oblique => 0.2,
                .backslant, .@"reverse-oblique" => -0.2,
            };
            c.l.runs.append(c.a, .{
                .elem = it.elem,
                .block = block_elem,
                .font = f,
                .sx = st.fontSize[0],
                .sy = st.fontSize[1],
                .slant = slant,
                .baseline = if (vertical) r.x + r.w / 2 else r.y + m.baseline,
                .x = if (vertical) r.x else r.x + start,
                .w = if (vertical) r.w else pen - start,
                .top = if (vertical) r.y + start else r.y,
                .h = if (vertical) pen - start else r.h,
                .vertical = vertical,
                .glyphs = glyphs.items,
            }) catch {};
        }
    }

    /// A button, input or object in a line, its border rectangle's top left at (x, y).
    fn inlineBox(c: *Ctx, b: *Elem, x: f32, y: f32) void {
        b.box.x = x;
        b.box.y = y;
        b.box.shown = true;
        const pe = physEdges(b);
        const inner: Rect = .{ .x = x + pe[3], .y = y + pe[0], .w = b.box.w - pe[1] - pe[3], .h = b.box.h - pe[0] - pe[2] };
        const fr: Frame = .of(inner, b.style.writingMode);
        const lw = if (fr.vertical()) inner.h else inner.w;
        const lh = if (fr.vertical()) inner.w else inner.h;
        const ch = c.content(b, .{ .x = 0, .y = 0, .w = lw, .h = lh }, lh, inner, fr);
        c.alignContent(b, lh - ch, fr);
    }

    /// Inline items of a node inside paragraph `p`.
    fn collectNode(c: *Ctx, items: *std.ArrayList(Item), n: *dom.Node, p: *Elem) void {
        switch (n.type) {
            .text, .cdata => c.addText(items, p, n.data, false),
            .element => if (Page.elemOf(n)) |e| c.collect(items, e),
            else => {},
        }
    }

    fn collect(c: *Ctx, items: *std.ArrayList(Item), e: *Elem) void {
        if (!e.style.display) return;
        switch (e.kind) {
            .br => items.append(c.a, .{ .cp = 0x2028, .elem = e, .font = null }) catch {},
            .span => {
                // A span changing the direction is an embedding (as XSL's fo:bidi-override with unicode-bidi embed).
                const embed = if (e.parent) |q| q.style.rtl != e.style.rtl else false;
                if (embed) items.append(c.a, .{ .cp = if (e.style.rtl) 0x202B else 0x202A, .elem = e, .font = null }) catch {};
                if (e.style.breakBefore) items.append(c.a, .{ .cp = 0x2028, .elem = e, .font = null }) catch {};
                var ch = e.node.first;
                while (ch) |n| : (ch = n.next) c.collectNode(items, n, e);
                if (e.style.breakAfter) items.append(c.a, .{ .cp = 0x2028, .elem = e, .font = null }) catch {};
                if (embed) items.append(c.a, .{ .cp = 0x202C, .elem = e, .font = null }) catch {};
            },
            .button, .input, .object => {
                // Its size first (inline boxes are not positioned).
                e.box.cb_w = 0;
                e.box.cb_h = 0;
                const pe = physEdges(e);
                const intr = c.intrinsic(e);
                const sz = specSize(e, 0, 0);
                const w = sz[0] orelse if (intr) |i| i[0] else 0;
                const h = sz[1] orelse if (intr) |i| i[1] else e.style.fontSize[1];
                e.box.w = w + pe[1] + pe[3];
                e.box.h = h + pe[0] + pe[2];
                items.append(c.a, .{ .cp = 0xFFFC, .elem = e, .font = null, .inline_box = e }) catch {};
            },
            else => {},
        }
    }

    /// Text of element `e` after white space handling (XSL §7.15, §7.16). `preserve`: as `xml:space="preserve"`
    /// (input values).
    fn addText(c: *Ctx, items: *std.ArrayList(Item), e: *Elem, raw: []const u8, preserve: bool) void {
        const s = &e.style;
        const lf: style.LinefeedTreatment = if (preserve) .preserve else s.linefeedTreatment;
        const wst: style.WhiteSpaceTreatment = if (preserve) .preserve else s.whiteSpaceTreatment;
        const collapse = if (preserve) false else s.whiteSpaceCollapse;
        const f = c.res.font(c.res.ctx, c.page, e);
        var cps: std.ArrayList(u21) = .empty;
        var it = (std.unicode.Utf8View.init(raw) catch return).iterator();
        while (it.nextCodepoint()) |cp0| {
            var cp = cp0;
            if (cp == '\r') continue;
            if (cp == '\n') {
                switch (lf) {
                    .ignore => continue,
                    .preserve => cp = 0x2028,
                    .@"treat-as-space" => cp = ' ',
                    .@"treat-as-zero-width-space" => cp = 0x200B,
                }
            } else if (cp == '\t') cp = ' ';
            cps.append(c.a, cp) catch return;
        }
        // White space around preserved line feeds.
        var out: std.ArrayList(u21) = .empty;
        for (cps.items, 0..) |cp, i| {
            if (cp == ' ') {
                const before_lf = blk: {
                    var j = i + 1;
                    while (j < cps.items.len and cps.items[j] == ' ') j += 1;
                    break :blk j < cps.items.len and cps.items[j] == 0x2028;
                };
                const after_lf = blk: {
                    var j = i;
                    while (j > 0 and cps.items[j - 1] == ' ') j -= 1;
                    break :blk j > 0 and cps.items[j - 1] == 0x2028;
                };
                switch (wst) {
                    .ignore => continue,
                    .preserve => {},
                    .@"ignore-before" => if (before_lf) continue,
                    .@"ignore-after" => if (after_lf) continue,
                    .@"ignore-around" => if (before_lf or after_lf) continue,
                }
                if (collapse and (before_lf or after_lf)) continue;
                // Collapse runs (also across elements: the previous item).
                if (collapse) {
                    const prev: ?u21 = if (out.items.len > 0) out.items[out.items.len - 1] else if (items.items.len > 0) items.items[items.items.len - 1].cp else null;
                    if (prev) |pc| if (pc == ' ') continue;
                }
            }
            out.append(c.a, cp) catch return;
        }
        for (out.items) |cp| items.append(c.a, .{ .cp = cp, .elem = e, .font = f }) catch return;
    }
};

fn isDescendant(e: *const Elem, of: *const Elem) bool {
    var p = e.parent;
    while (p) |x| : (p = x.parent) if (x == of) return true;
    return false;
}

/// White space for line fitting (§7.3.2.3).
fn isSpace(cp: u21) bool {
    return switch (cp) {
        0x09, 0x0A, 0x0D, 0x20, 0x2000...0x200B, 0x3000 => true,
        else => false,
    };
}

fn isMandatory(cp: u21) bool {
    return cp == 0x2028 or cp == 0x2029;
}

/// Set upright in vertical text (Vertical_Orientation U or Tu, UAX #50; the XSL `auto` glyph orientation).
fn isUpright(cp: u21) bool {
    const t = &ucd.upright;
    var lo: usize = 0;
    var hi: usize = t.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (cp < t[mid].lo) hi = mid else if (cp > t[mid].hi) lo = mid + 1 else return true;
    }
    return false;
}

/// Break opportunities (§7.3.2.3.1.2): white space, CJK, object replacement.
fn isBreak(cp: u21) bool {
    return isSpace(cp) or (cp >= 0x2E80 and cp <= 0xA4CF) or cp == 0xFFFC;
}

/// An area's bounding rectangle in its object's box (§7.5.3.1.1), or null for the whole object.
pub fn areaRect(e: *const Elem) ?Rect {
    const shape = e.node.attr("shape") orelse "default";
    var v: [64]f32 = undefined;
    var n: usize = 0;
    var it = std.mem.tokenizeAny(u8, e.node.attr("coords") orelse "", " ,\t");
    while (it.next()) |t| {
        if (n == v.len) break;
        v[n] = std.fmt.parseFloat(f32, t) catch break;
        n += 1;
    }
    if (std.mem.eql(u8, shape, "rect") and n >= 4) return .{ .x = v[0], .y = v[1], .w = @max(0, v[2] - v[0]), .h = @max(0, v[3] - v[1]) };
    if (std.mem.eql(u8, shape, "circle") and n >= 3) return .{ .x = v[0] - v[2], .y = v[1] - v[2], .w = 2 * v[2], .h = 2 * v[2] };
    if (std.mem.eql(u8, shape, "poly") and n >= 6) {
        var x0 = v[0];
        var y0 = v[1];
        var x1 = v[0];
        var y1 = v[1];
        var k: usize = 2;
        while (k + 1 < n) : (k += 2) {
            x0 = @min(x0, v[k]);
            x1 = @max(x1, v[k]);
            y0 = @min(y0, v[k + 1]);
            y1 = @max(y1, v[k + 1]);
        }
        return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
    }
    return null;
}

/// Whether (px, py), relative to the object's box, is inside the area's shape (polygons auto-closed).
pub fn inArea(e: *const Elem, px: f32, py: f32) bool {
    const shape = e.node.attr("shape") orelse "default";
    var v: [64]f32 = undefined;
    var n: usize = 0;
    var it = std.mem.tokenizeAny(u8, e.node.attr("coords") orelse "", " ,\t");
    while (it.next()) |t| {
        if (n == v.len) break;
        v[n] = std.fmt.parseFloat(f32, t) catch break;
        n += 1;
    }
    if (std.mem.eql(u8, shape, "rect") and n >= 4) return px >= v[0] and px < v[2] and py >= v[1] and py < v[3];
    if (std.mem.eql(u8, shape, "circle") and n >= 3) return (px - v[0]) * (px - v[0]) + (py - v[1]) * (py - v[1]) <= v[2] * v[2];
    if (std.mem.eql(u8, shape, "poly") and n >= 6) {
        // Even-odd rule over the closed polygon.
        var inside = false;
        const pts = n / 2;
        var j = pts - 1;
        for (0..pts) |k| {
            const xi = v[2 * k];
            const yi = v[2 * k + 1];
            const xj = v[2 * j];
            const yj = v[2 * j + 1];
            if ((yi > py) != (yj > py) and px < (xj - xi) * (py - yi) / (yj - yi) + xi) inside = !inside;
            j = k;
        }
        return inside;
    }
    return true; // default: the whole object
}

// ---- tests --------------------------------------------------------------------------------------------------

const testing = std.testing;
const planes = @import("../planes.zig");
const paint_mod = @import("paint.zig");

const TestRes = struct {
    font: *Font,

    fn getFont(ctx: *anyopaque, _: *Page, _: *Elem) ?*Font {
        const self: *TestRes = @ptrCast(@alignCast(ctx));
        return self.font;
    }
    fn image(_: *anyopaque, _: []const u8) ?*image_mod.Image {
        return null;
    }
    fn res(self: *TestRes) Res {
        return .{ .ctx = self, .font = getFont, .image = image };
    }
};

fn testPage(src: []const u8) !*Page {
    return Page.fromBytes(testing.allocator, null, src, "file:///dvddisc/a.xmu", 1080);
}

fn el(p: *Page, id: []const u8) *Elem {
    return Page.elemOf(p.doc.getElementById(id).?).?;
}

const head =
    \\<root xmlns="http://www.dvdforum.org/2005/ihd" xmlns:style="http://www.dvdforum.org/2005/ihd#style" xml:lang="en"><body>
;

test "absolute positioning, anchors and nesting" {
    const p = try testPage(head ++
        \\<div id="a" style:position="absolute" style:x="100px" style:y="50px" style:width="400px" style:height="300px"
        \\     style:padding="10px" style:border="2px solid red">
        \\ <div id="b" style:position="absolute" style:x="20px" style:y="30px" style:width="40px" style:height="10px"/>
        \\ <div id="c" style:position="absolute" style:x="200px" style:y="150px" style:width="40px" style:height="20px" style:anchor="center"/>
        \\ <div id="d" style:position="absolute" style:x="100%" style:y="100%" style:width="40px" style:height="20px" style:anchor="endAfter"/>
        \\ <div id="e" style:display="none" style:position="absolute" style:width="1px" style:height="1px"/>
        \\</div></body></root>
    );
    defer p.destroy();
    var lay = Layout.init(testing.allocator);
    defer lay.deinit();
    var tr: TestRes = .{ .font = undefined };
    lay.run(p, tr.res(), 1920, 1080);
    const a = el(p, "a");
    try testing.expectEqual(@as(f32, 100), a.box.x);
    try testing.expectEqual(@as(f32, 424), a.box.w); // 400 + 2×(10 + 2)
    // b: in a's content box at (112, 62).
    try testing.expectEqual(@as(f32, 132), el(p, "b").box.x);
    try testing.expectEqual(@as(f32, 92), el(p, "b").box.y);
    // c: its centre at (200, 150) in a's content box.
    try testing.expectEqual(@as(f32, 112 + 200 - 20), el(p, "c").box.x);
    try testing.expectEqual(@as(f32, 62 + 150 - 10), el(p, "c").box.y);
    // d: its bottom right at the content box's bottom right.
    try testing.expectEqual(@as(f32, 112 + 400 - 40), el(p, "d").box.x);
    try testing.expectEqual(@as(f32, 62 + 300 - 20), el(p, "d").box.y);
    try testing.expect(!el(p, "e").box.shown);
}

test "flow, indents, relative, displayAlign" {
    const p = try testPage(head ++
        \\<div id="a" style:position="absolute" style:width="200px" style:height="100px" style:displayAlign="after">
        \\ <div id="b" style:height="10px" style:startIndent="5px" style:endIndent="15px"/>
        \\ <div id="c" style:height="20px" style:width="50px" style:position="relative" style:x="3px" style:y="4px"/>
        \\</div></body></root>
    );
    defer p.destroy();
    var lay = Layout.init(testing.allocator);
    defer lay.deinit();
    var tr: TestRes = .{ .font = undefined };
    lay.run(p, tr.res(), 1920, 1080);
    const b = el(p, "b");
    const c = el(p, "c");
    // The content (30px high) is at the bottom of the 100px box.
    try testing.expectEqual(@as(f32, 70), b.box.y);
    try testing.expectEqual(@as(f32, 5), b.box.x);
    try testing.expectEqual(@as(f32, 180), b.box.w);
    try testing.expectEqual(@as(f32, 80 + 4), c.box.y);
    try testing.expectEqual(@as(f32, 3), c.box.x);
}

test "text: white space, wrapping, alignment, stacking" {
    const gpa = testing.allocator;
    const bytes = try font_mod.testFont(gpa);
    defer gpa.free(bytes);
    const f = try Font.create(gpa, bytes);
    defer f.destroy();
    var tr: TestRes = .{ .font = f };
    // 'A' advances 60px and space 25px at 100px; the box is 400px wide and 250px high.
    const p = try testPage(head ++
        \\<div id="d" style:position="absolute" style:width="400px" style:height="250px">
        \\ <p id="p" style:fontSize="100px" style:textAlign="end">  AAA   AAAA
        \\ AA AAAAAAAAAAAAAA</p>
        \\</div></body></root>
    );
    defer p.destroy();
    var lay = Layout.init(gpa);
    defer lay.deinit();
    lay.run(p, tr.res(), 1920, 1080);
    // Lines: "AAA AAAA" (180 + 25 + 240 = 445 > 400, so "AAA" then "AAAA AA"), then the long word, which
    // does not fit in the height left (2 lines of 100px each, 250px) and is dropped.
    const runs = lay.runs.items;
    try testing.expectEqual(2, runs.len);
    try testing.expectEqual(3, runs[0].glyphs.len);
    try testing.expectEqual(@as(f32, 400 - 180), runs[0].x); // end-aligned
    try testing.expectEqual(@as(f32, 80), runs[0].baseline); // ascent 80
    try testing.expectEqual(7, runs[1].glyphs.len); // AAAA, space, AA
    try testing.expectEqual(@as(f32, 400 - 385), runs[1].x);
    try testing.expectEqual(@as(f32, 180), runs[1].baseline);
}

test "input values, preserved space, br and spans" {
    const gpa = testing.allocator;
    const bytes = try font_mod.testFont(gpa);
    defer gpa.free(bytes);
    const f = try Font.create(gpa, bytes);
    defer f.destroy();
    var tr: TestRes = .{ .font = f };
    const p = try testPage(
        \\<root xmlns="http://www.dvdforum.org/2005/ihd" xmlns:style="http://www.dvdforum.org/2005/ihd#style"
        \\      xmlns:state="http://www.dvdforum.org/2005/ihd#state" xml:lang="en"><body>
        \\<div style:position="absolute" style:width="1000px" style:height="500px">
        \\ <input id="i" style:width="1000px" style:height="100px" style:fontSize="100px" state:value="A  A"/>
        \\ <p id="p" style:fontSize="100px">A<br/>A<span id="s" style:fontSize="50px">AA</span></p>
        \\ <input id="empty" style:width="1000px" style:height="100px" style:fontSize="100px" state:value=""/>
        \\ <p style:fontSize="100px"></p>
        \\</div></body></root>
    );
    defer p.destroy();
    var lay = Layout.init(gpa);
    defer lay.deinit();
    lay.run(p, tr.res(), 1920, 1080);
    const runs = lay.runs.items;
    try testing.expectEqual(4, runs.len);
    try testing.expectEqual(4, runs[0].glyphs.len); // the input keeps both spaces
    try testing.expectEqual(@as(f32, 110), runs[0].glyphs[3].x);
    try testing.expectEqual(1, runs[1].glyphs.len); // "A", then the br
    try testing.expect(runs[2].baseline > runs[1].baseline);
    try testing.expectEqual(el(p, "s"), runs[3].elem); // the span's run, at its size
    try testing.expectEqual(@as(f32, 50), runs[3].sy);
    try testing.expectEqual(@as(f32, 60), runs[3].x);
}

test "writing modes: rl-tb flow, anchors and edges" {
    const p = try testPage(head ++
        \\<div id="r" style:position="absolute" style:x="100px" style:y="0px" style:width="200px" style:height="100px" style:writingMode="rl-tb">
        \\ <div id="b" style:height="10px" style:width="50px" style:startIndent="5px" style:borderStart="1px solid red"/>
        \\ <div id="c" style:position="absolute" style:x="150px" style:y="20px" style:width="40px" style:height="10px"/>
        \\ <div id="d" style:position="relative" style:x="3px" style:height="10px" style:width="10px"/>
        \\</div></body></root>
    );
    defer p.destroy();
    var lay = Layout.init(testing.allocator);
    defer lay.deinit();
    var tr: TestRes = .{ .font = undefined };
    lay.run(p, tr.res(), 1920, 1080);
    // Placed by the body's (lr-tb) anchor; its own content runs right to left.
    try testing.expectEqual(@as(f32, 100), el(p, "r").box.x);
    // b: 5px from the right, its start border on the right.
    try testing.expectEqual(@as(f32, 300 - 5 - 51), el(p, "b").box.x);
    try testing.expectEqual(@as(f32, 0), physEdges(el(p, "b"))[3]);
    try testing.expectEqual(@as(f32, 1), physEdges(el(p, "b"))[1]);
    // c: startBefore in rl-tb is its top right corner, at (150, 20).
    try testing.expectEqual(@as(f32, 100 + 150 - 40), el(p, "c").box.x);
    try testing.expectEqual(@as(f32, 20), el(p, "c").box.y);
    // d: at the start (right), then shifted 3px right (x is region-oriented).
    try testing.expectEqual(@as(f32, 300 - 10 + 3), el(p, "d").box.x);
    try testing.expectEqual(@as(f32, 10), el(p, "d").box.y);
}

test "writing modes: tb-rl columns, upright and turned glyphs" {
    const gpa = testing.allocator;
    const bytes = try font_mod.testFont(gpa);
    defer gpa.free(bytes);
    const f = try Font.create(gpa, bytes);
    defer f.destroy();
    var tr: TestRes = .{ .font = f };
    const p = try testPage(head ++
        \\<div id="v" style:position="absolute" style:x="0px" style:y="0px" style:width="300px" style:height="400px" style:writingMode="tb-rl">
        \\ <p id="p" style:fontSize="100px">AA あ</p>
        \\ <div id="d" style:width="20px" style:height="30px"/>
        \\ <div id="e" style:width="20px" style:height="30px" style:displayAlign="after" style:writingMode="lr-tb"/>
        \\</div></body></root>
    );
    defer p.destroy();
    var lay = Layout.init(gpa);
    defer lay.deinit();
    lay.run(p, tr.res(), 1920, 1080);
    // The paragraph is the first column, on the right: 100px wide (ascent + descent).
    const pp = el(p, "p");
    try testing.expectEqual(@as(f32, 200), pp.box.x);
    try testing.expectEqual(@as(f32, 100), pp.box.w);
    const runs = lay.runs.items;
    try testing.expectEqual(1, runs.len);
    const r = runs[0];
    try testing.expect(r.vertical);
    try testing.expectEqual(@as(f32, 250), r.baseline); // the column's centre line
    try testing.expectEqual(@as(f32, 0), r.top);
    // A, A turned (60px each), the space (25px), then the hiragana upright (100px).
    try testing.expectEqual(4, r.glyphs.len);
    try testing.expect(!r.glyphs[0].upright and r.glyphs[3].upright);
    try testing.expectEqual(@as(f32, 145), r.glyphs[3].x);
    try testing.expectEqual(@as(f32, 245), r.h);
    // The next block is the next column to the left: width is its block extent, height its inline one.
    const d = el(p, "d");
    try testing.expectEqual(@as(f32, 180), d.box.x);
    try testing.expectEqual(@as(f32, 0), d.box.y);
    try testing.expectEqual(@as(f32, 20), d.box.w);
    try testing.expectEqual(@as(f32, 30), d.box.h);
    try testing.expectEqual(@as(f32, 160), el(p, "e").box.x);

    // Painted: the turned A's ink is right of the baseline line (its ascent), below the column's top.
    const fr = try planes.Frame.create(gpa, 320, 420);
    defer fr.unref();
    paint_mod.paint(gpa, p, &lay, tr.res(), fr, .{ .x = 0, .y = 0, .w = 320, .h = 420 });
    // The baseline is at x = 250 - (80 - 20)/2 = 220; the A's 500×700 box (50×70 px) goes to x = 290, y 0–50.
    try testing.expect(fr.canvas.at(250, 25)[3] > 0);
    try testing.expect(fr.canvas.at(215, 25)[3] == 0);
}

test "bidi: visual order and alignment" {
    const gpa = testing.allocator;
    const bytes = try font_mod.testFont(gpa);
    defer gpa.free(bytes);
    const f = try Font.create(gpa, bytes);
    defer f.destroy();
    var tr: TestRes = .{ .font = f };
    const p = try testPage(head ++
        \\<div style:position="absolute" style:width="400px" style:height="400px">
        \\ <p id="a" style:fontSize="100px" style:direction="rtl">א A</p>
        \\ <p id="b" style:fontSize="100px">A <span style:direction="rtl">A A</span></p>
        \\</div>
        \\<div style:position="absolute" style:y="500px" style:width="400px" style:height="400px" style:writingMode="rl-tb">
        \\ <p id="c" style:fontSize="100px">AA</p>
        \\</div></body></root>
    );
    defer p.destroy();
    var lay = Layout.init(gpa);
    defer lay.deinit();
    lay.run(p, tr.res(), 1920, 1080);
    const runs = lay.runs.items;
    // "א A" right to left: A, space, א on screen, aligned right (start).
    try testing.expectEqual(@as(f32, 400 - 135), runs[0].x);
    try testing.expectEqual(3, runs[0].glyphs.len);
    try testing.expectEqual(@as(u32, 1), runs[0].glyphs[0].id);
    try testing.expectEqual(@as(u32, 0), runs[0].glyphs[2].id);
    // The rtl span is an embedding: its Latin keeps its order; the line stays left-aligned.
    try testing.expectEqual(@as(f32, 0), runs[1].x);
    // rl-tb: lines start on the right.
    const last = runs[runs.len - 1];
    try testing.expectEqual(@as(f32, 400 - 120), last.x);
    try testing.expectEqual(@as(f32, 580), last.baseline);
}

test "area shapes" {
    const p = try testPage(head ++
        \\<object id="o" type="image/png" src="x.png">
        \\ <area id="r" shape="rect" coords="10 10 20 30"/>
        \\ <area id="c" shape="circle" coords="50 50 10"/>
        \\ <area id="t" shape="poly" coords="0 0 100 0 0 100"/>
        \\</object></body></root>
    );
    defer p.destroy();
    try testing.expect(inArea(el(p, "r"), 15, 29) and !inArea(el(p, "r"), 15, 31));
    try testing.expect(inArea(el(p, "c"), 55, 55) and !inArea(el(p, "c"), 59, 59));
    try testing.expect(inArea(el(p, "t"), 10, 10) and !inArea(el(p, "t"), 60, 60));
    try testing.expectEqual(@as(f32, 20), areaRect(el(p, "r")).?.h);
}
