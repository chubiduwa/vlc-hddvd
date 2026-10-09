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
//! The results are each element's `box` and a list of glyph runs. `rl-tb` mirrors the inline direction;
//! `tb-rl` (vertical text) is laid out like `lr-tb` for now. No VLC dependency.

const std = @import("std");
const dom = @import("../dom.zig");
const font_mod = @import("../font.zig");
const raster = @import("../raster.zig");
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
    image: *const fn (ctx: *anyopaque, u: []const u8) ?*const raster.Canvas,
};

pub const Glyph = struct { id: u32, x: f32 };

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
    baseline: f32,
    /// The line's extent, for inline backgrounds.
    x: f32,
    w: f32,
    top: f32,
    h: f32,
    glyphs: []Glyph,
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
        _ = lc.block(b, .{ .x = 0, .y = 0, .w = w, .h = h, .ref = region, .rtl = false });
    }
};

/// Where a block is laid: the containing content box's left and width, the flow position, the height left,
/// and the reference rectangle for absolutely positioned descendants.
const Flow = struct {
    x: f32,
    y: f32,
    w: f32,
    /// Height available below `y` (null: unbounded).
    h: ?f32,
    ref: Rect,
    rtl: bool,
};

const Ctx = struct {
    l: *Layout,
    page: *Page,
    res: Res,
    a: std.mem.Allocator,

    fn edges(e: *const Elem, cb_w: f32) [4]f32 {
        // before, end, after, start: border + padding.
        var out: [4]f32 = undefined;
        for (0..4) |i| {
            const b = e.style.borders[i];
            const bw: f32 = if (b.style == .solid) b.width else 0;
            out[i] = bw + e.style.padding[i].resolve(cb_w);
        }
        return out;
    }

    fn hide(c: *Ctx, e: *Elem) void {
        _ = c;
        e.box.shown = false;
    }

    /// Positioned in the sense of §7.6 "positionable": div, button, object in a block context.
    fn positioned(e: *const Elem) bool {
        return e.style.position != .static and (e.kind == .div or e.kind == .button or e.kind == .object or e.kind == .input or e.kind == .body);
    }

    /// Specified content width/height, or null for auto.
    fn specWidth(e: *const Elem, cb_w: f32, vertical: bool) ?f32 {
        const ipd = e.style.inlineProgressionDimension;
        const l = (if (vertical) e.style.height else e.style.width) orelse ipd orelse return null;
        return @max(0, l.resolve(cb_w));
    }

    fn specHeight(e: *const Elem, cb_h: f32) ?f32 {
        const l = e.style.height orelse e.style.blockProgressionDimension orelse return null;
        return @max(0, l.resolve(cb_h));
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
        if (e.style.crop) |cr| {
            w = @floatFromInt(@min(cr[2], im.w) -| cr[0]);
            h = @floatFromInt(@min(cr[3], im.h) -| cr[1]);
        }
        return .{ w, h };
    }

    /// Lays out block-level element `e` in flow `f`; returns the height it takes in the flow.
    fn block(c: *Ctx, e: *Elem, f: Flow) f32 {
        if (!e.style.display) return 0;
        e.box.cb_w = f.w;
        e.box.cb_h = f.h orelse f.ref.h;
        if (e.style.position == .absolute and positioned(e)) {
            c.absolute(e, f.ref, f.rtl);
            return 0;
        }
        const ed = edges(e, f.w);
        const start_i = e.style.startIndent.resolve(f.w);
        const end_i = e.style.endIndent.resolve(f.w);
        const auto_w = @max(0, f.w - start_i - end_i - ed[1] - ed[3]);
        var cw = specWidth(e, f.w, false) orelse auto_w;
        if (specWidth(e, f.w, false) == null) if (c.intrinsic(e)) |sz| {
            cw = sz[0];
        };
        const outer_w = cw + ed[1] + ed[3];
        const x = if (f.rtl) f.x + f.w - start_i - outer_w else f.x + start_i;
        const spec_h = specHeight(e, e.box.cb_h) orelse if (c.intrinsic(e)) |sz| sz[1] else null;
        e.box.x = x;
        e.box.y = f.y;
        e.box.w = outer_w;
        e.box.shown = true;
        const inner: Rect = .{ .x = x + (if (f.rtl) ed[1] else ed[3]), .y = f.y + ed[0], .w = cw, .h = spec_h orelse 0 };
        const ref = if (positioned(e)) inner else f.ref;
        // Text stops at the height the box has, or what is left of its container's (§7.3.2.4).
        const avail = if (spec_h) |sh| sh else if (f.h) |fh| @max(0, fh - ed[0] - ed[2]) else null;
        const ch = c.content(e, inner, avail, ref, f.rtl or e.style.writingMode == .@"rl-tb");
        const h = spec_h orelse ch;
        e.box.h = h + ed[0] + ed[2];
        if (spec_h) |sh| c.alignContent(e, sh - ch);
        if (e.style.position == .relative and positioned(e)) {
            const dx = (e.style.x orelse style.Len.px(0)).resolve(f.w);
            const dy = (e.style.y orelse style.Len.px(0)).resolve(e.box.cb_h);
            c.shift(e, if (f.rtl) -dx else dx, dy);
        }
        return e.box.h;
    }

    /// Absolutely positioned `e` in reference rectangle `ref` (§7.6.3.3.2.1 anchor).
    fn absolute(c: *Ctx, e: *Elem, ref: Rect, rtl: bool) void {
        const ed = edges(e, ref.w);
        const x = (e.style.x orelse style.Len.px(0)).resolve(ref.w);
        const y = (e.style.y orelse style.Len.px(0)).resolve(ref.h);
        const intr = c.intrinsic(e);
        const W = specWidth(e, ref.w, false) orelse if (intr) |sz| sz[0] else @max(0, ref.w - x - ed[1] - ed[3]);
        const spec_h = specHeight(e, ref.h) orelse if (intr) |sz| sz[1] else null;
        e.box.cb_w = ref.w;
        e.box.cb_h = ref.h;
        e.box.shown = true;
        // Lay the content first when the height is not given (the anchor needs it).
        var H = spec_h orelse 0;
        const inner_rtl = rtl or e.style.writingMode == .@"rl-tb";
        if (spec_h == null) {
            e.box.x = 0;
            e.box.y = 0;
            const before = c.l.runs.items.len;
            const ch = c.content(e, .{ .x = 0, .y = 0, .w = W, .h = 0 }, null, .{ .x = 0, .y = 0, .w = W, .h = 0 }, inner_rtl);
            H = ch;
            // Undo: laid again at the right place below.
            c.l.runs.shrinkRetainingCapacity(before);
        }
        const a = e.style.anchor;
        const ix: f32 = switch (a) {
            .startBefore, .startCenter, .startAfter => x,
            .centerBefore, .center, .centerAfter => x - (W / 2 + ed[3]),
            .endBefore, .endCenter, .endAfter => x - (W + ed[1] + ed[3]),
        };
        const iy: f32 = switch (a) {
            .startBefore, .centerBefore, .endBefore => y,
            .startCenter, .center, .endCenter => y - (H / 2 + ed[0]),
            .startAfter, .centerAfter, .endAfter => y - (H + ed[0] + ed[2]),
        };
        const outer_w = W + ed[1] + ed[3];
        e.box.x = if (rtl) ref.x + ref.w - ix - outer_w else ref.x + ix;
        e.box.y = ref.y + iy;
        e.box.w = outer_w;
        e.box.h = H + ed[0] + ed[2];
        const inner: Rect = .{ .x = e.box.x + (if (rtl) ed[1] else ed[3]), .y = e.box.y + ed[0], .w = W, .h = H };
        const ch = c.content(e, inner, spec_h, inner, inner_rtl);
        if (spec_h) |sh| c.alignContent(e, sh - ch);
    }

    /// Lays out the content of `e` in its content rectangle; returns the content height.
    fn content(c: *Ctx, e: *Elem, box: Rect, avail_h: ?f32, ref: Rect, rtl: bool) f32 {
        switch (e.kind) {
            .p, .span => return c.paragraph(e, box, avail_h, rtl, null),
            .input => {
                if (std.mem.eql(u8, e.node.attr("mode") orelse "", "password")) {
                    var dots: std.ArrayList(u8) = .empty;
                    const n = std.unicode.utf8CountCodepoints(e.state.value) catch e.state.value.len;
                    for (0..n) |_| dots.appendSlice(c.a, "\u{2022}") catch break;
                    return c.paragraph(e, box, avail_h, rtl, dots.items);
                }
                return c.paragraph(e, box, avail_h, rtl, e.state.value);
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
                y += c.paragraph(child, .{ .x = box.x, .y = y, .w = box.w, .h = 0 }, null, rtl, null);
                continue;
            }
            const left = if (avail_h) |h| @max(0, h - (y - box.y)) else null;
            y += c.block(child, .{ .x = box.x, .y = y, .w = box.w, .h = left, .ref = ref, .rtl = rtl });
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
        for (c.l.runs.items) |*r| if (r.block == e or isDescendant(r.block, e)) {
            r.x += dx;
            r.baseline += dy;
            r.top += dy;
        };
    }

    /// displayAlign: moves the content of a box with a given height (`slack` left over).
    fn alignContent(c: *Ctx, e: *Elem, slack: f32) void {
        if (slack <= 0) return;
        const dy = switch (e.style.displayAlign) {
            .auto, .before => return,
            .center => slack / 2,
            .after => slack,
        };
        const elems = c.page.elems.items;
        var i: usize = e.index + 1;
        while (i < elems.len and isDescendant(elems[i], e)) : (i += 1) {
            // Absolutely positioned descendants keep their place.
            if (elems[i].style.position != .absolute) elems[i].box.y += dy;
        }
        for (c.l.runs.items) |*r| if (r.block == e or isDescendant(r.block, e)) {
            r.baseline += dy;
            r.top += dy;
        };
    }

    // ---- paragraphs -----------------------------------------------------------------------------------------

    const Item = struct {
        cp: u21,
        /// The element whose style draws it, and its font.
        elem: *Elem,
        font: ?*Font,
        glyph: u32 = 0,
        adv: f32 = 0,
        /// An inline box (button, input, object) instead of a character.
        inline_box: ?*Elem = null,
    };

    /// Lays out inline content as lines: the text of `e` (or `text` instead, for inputs). Returns the height.
    fn paragraph(c: *Ctx, e: *Elem, box: Rect, avail_h: ?f32, rtl_in: bool, text: ?[]const u8) f32 {
        const s = &e.style;
        const rtl = rtl_in or s.rtl;
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

        // Measure.
        for (items.items) |*it| {
            if (it.inline_box) |b| {
                const w = specWidth(b, box.w, false) orelse if (c.intrinsic(b)) |sz| sz[0] else 0;
                const ed = edges(b, box.w);
                it.adv = w + ed[1] + ed[3];
                continue;
            }
            const f = it.font orelse continue;
            it.glyph = f.glyphIndex(it.cp);
            it.adv = f.advance(it.glyph, it.elem.style.fontSize[0]);
        }
        for (items.items, 0..) |*it, i| {
            if (i == 0 or it.inline_box != null) continue;
            const prev = items.items[i - 1];
            const f = it.font orelse continue;
            if (prev.font == f and prev.elem == it.elem) it.adv += 0; // kerning goes on the previous glyph:
            if (prev.font == f and prev.inline_box == null) items.items[i - 1].adv += f.kern(prev.glyph, it.glyph, it.elem.style.fontSize[0]);
        }

        // Fit and stack lines.
        var y = box.y;
        var i: usize = 0;
        var first = true;
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
                w += it.adv;
            }
            // Trailing white space neither shows nor counts for alignment.
            var vis_end = end;
            while (vis_end > i and isSpace(items.items[vis_end - 1].cp)) vis_end -= 1;
            const line = items.items[i..vis_end];
            const m = c.lineMetrics(e, line);
            // §7.3.2.4: a line that does not fit in the height left ends the paragraph.
            if (avail_h) |ah| if (y - box.y + m.h > ah + 0.01) break;
            var lw: f32 = 0;
            for (line) |it| lw += it.adv;
            const slack = @max(0, limit - lw);
            const align_off: f32 = switch (s.textAlign) {
                .start => 0,
                .center => slack / 2,
                .end => slack,
            };
            const x0 = if (rtl) box.x + box.w - indent - align_off - lw else box.x + indent + align_off;
            c.emitLine(e, line, x0, y, m, rtl);
            y += m.h;
            i = next;
            first = false;
        }
        return y - box.y;
    }

    const LineMetrics = struct { h: f32, baseline: f32 };

    fn lineMetrics(c: *Ctx, block_elem: *Elem, line: []const Item) LineMetrics {
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
            asc = @max(asc, b.box.h);
        };
        const natural = asc + desc + gap;
        const h = block_elem.style.lineHeight orelse natural;
        return .{ .h = h, .baseline = (h - (asc + desc)) / 2 + asc };
    }

    fn emitLine(c: *Ctx, block_elem: *Elem, line: []const Item, x0: f32, top: f32, m: LineMetrics, rtl: bool) void {
        _ = rtl;
        var x = x0;
        var k: usize = 0;
        while (k < line.len) {
            const it = line[k];
            if (it.inline_box) |b| {
                c.inlineBox(b, x, top + m.baseline);
                x += it.adv;
                k += 1;
                continue;
            }
            const f = it.font orelse {
                x += it.adv;
                k += 1;
                continue;
            };
            // A run: consecutive glyphs of the same element and font.
            var glyphs: std.ArrayList(Glyph) = .empty;
            const start_x = x;
            while (k < line.len and line[k].inline_box == null and line[k].elem == it.elem and line[k].font == f) : (k += 1) {
                glyphs.append(c.a, .{ .id = line[k].glyph, .x = x - start_x }) catch {};
                x += line[k].adv;
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
                .baseline = top + m.baseline,
                .x = start_x,
                .w = x - start_x,
                .top = top,
                .h = m.h,
                .glyphs = glyphs.items,
            }) catch {};
        }
    }

    /// A button, input or object in a line: its bottom on the baseline.
    fn inlineBox(c: *Ctx, b: *Elem, x: f32, baseline: f32) void {
        b.box.x = x;
        b.box.y = baseline - b.box.h;
        b.box.shown = true;
        const ed = edges(b, b.box.cb_w);
        const content_box: Rect = .{ .x = x + ed[3], .y = b.box.y + ed[0], .w = b.box.w - ed[1] - ed[3], .h = b.box.h - ed[0] - ed[2] };
        const ch = c.content(b, content_box, content_box.h, content_box, false);
        c.alignContent(b, content_box.h - ch);
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
                if (e.style.breakBefore) items.append(c.a, .{ .cp = 0x2028, .elem = e, .font = null }) catch {};
                var ch = e.node.first;
                while (ch) |n| : (ch = n.next) c.collectNode(items, n, e);
                if (e.style.breakAfter) items.append(c.a, .{ .cp = 0x2028, .elem = e, .font = null }) catch {};
            },
            .button, .input, .object => {
                // Its size first (inline boxes are not positioned).
                e.box.cb_w = 0;
                const ed = edges(e, 0);
                const intr = c.intrinsic(e);
                const w = specWidth(e, 0, false) orelse if (intr) |sz| sz[0] else 0;
                const h = specHeight(e, 0) orelse if (intr) |sz| sz[1] else e.style.fontSize[1];
                e.box.w = w + ed[1] + ed[3];
                e.box.h = h + ed[0] + ed[2];
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

const TestRes = struct {
    font: *Font,

    fn getFont(ctx: *anyopaque, _: *Page, _: *Elem) ?*Font {
        const self: *TestRes = @ptrCast(@alignCast(ctx));
        return self.font;
    }
    fn image(_: *anyopaque, _: []const u8) ?*const raster.Canvas {
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
