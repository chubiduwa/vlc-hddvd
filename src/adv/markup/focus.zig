//! Focus, navigation and the pointer within one markup page (HD DVD Vol. 3 §7.2.5–7.2.8, §7.6.3.3.2.32–40,
//! §7.6.3.4): navIndex generation, the navigation gestures, accessKey lookup and pointer hit-testing. What
//! spans applications (one focus for all of them, the event order) is in apps.zig. No VLC dependency.

const std = @import("std");
const style = @import("style.zig");
const page_mod = @import("page.zig");
const layout = @import("layout.zig");
const keys = @import("../engine/keys.zig");

const Page = page_mod.Page;
const Elem = page_mod.Elem;

/// Whether the element generates areas in the current layout (its display and its ancestors' are not none).
pub fn displayed(e: *const Elem) bool {
    return e.box.shown;
}

/// §7.2.5.2: display not none, navIndex not none, enabled. Visibility and opacity do not matter.
pub fn focusable(e: *const Elem) bool {
    return e.kind.activatable() and displayed(e) and e.state.enabled and e.style.navIndex != .none;
}

/// The element's navIndex: explicit, or generated at the page load.
pub fn navValue(e: *const Elem) ?[2]i32 {
    return switch (e.style.navIndex) {
        .none => null,
        .pair => |v| v,
        .auto => e.nav_auto,
    };
}

/// §7.2.5.3: numbers every activatable element whose navIndex is auto, from the laid-out boxes' top-left
/// corners: the first value in rows (y, then x), the second in columns (x, then y), the element on top first
/// on equal positions, skipping the values given explicitly. `rank` is each element's position in paint
/// order (paint.order inverted). Runs at every page load and on the script's request. Elements not displayed
/// have no box to number them by, so they are left out; `stale` tells when one has been displayed since.
pub fn generate(gpa: std.mem.Allocator, page: *Page, rank: []const u32) !void {
    const elems = page.elems.items;
    var autos: std.ArrayList(*Elem) = .empty;
    defer autos.deinit(gpa);
    var used: [2]std.AutoHashMapUnmanaged(i32, void) = .{ .empty, .empty };
    defer for (&used) |*u| u.deinit(gpa);
    for (elems) |e| {
        e.nav_auto = null;
        if (!e.kind.activatable()) continue;
        switch (e.style.navIndex) {
            .none => {},
            .pair => |v| for (&used, v) |*u, x| try u.put(gpa, x, {}),
            .auto => if (displayed(e)) try autos.append(gpa, e),
        }
    }
    const Ctx = struct {
        rank: []const u32,
        axis: u1,
        fn less(c: @This(), a: *Elem, b: *Elem) bool {
            const pa = [2]f32{ a.box.x, a.box.y };
            const pb = [2]f32{ b.box.x, b.box.y };
            const major: u1 = if (c.axis == 0) 1 else 0; // rows: y first; columns: x first
            if (pa[major] != pb[major]) return pa[major] < pb[major];
            if (pa[1 - major] != pb[1 - major]) return pa[1 - major] < pb[1 - major];
            return c.rank[a.index] > c.rank[b.index];
        }
    };
    for ([_]u1{ 0, 1 }) |axis| {
        std.mem.sort(*Elem, autos.items, Ctx{ .rank = rank, .axis = axis }, Ctx.less);
        var n: i32 = 0;
        for (autos.items) |e| {
            n += 1;
            while (used[axis].contains(n)) n += 1;
            if (e.nav_auto == null) e.nav_auto = .{ 0, 0 };
            e.nav_auto.?[axis] = n;
        }
    }
}

/// Whether a focusable element with navIndex auto has no number yet (it was not displayed at the last
/// generation): navigation then numbers the page again first.
pub fn stale(page: *const Page) bool {
    for (page.elems.items) |e| if (e.style.navIndex == .auto and e.nav_auto == null and focusable(e)) return true;
    return false;
}

/// Where a navigation gesture leads.
pub const Target = union(enum) {
    /// Focus does not move.
    none,
    elem: *Elem,
    /// An element of another application (`app#elem` in a nav* property).
    other: style.Nav,
};

/// The navigation gesture `dir` from the focused element `from` (null: nothing focused in this page), for
/// the application whose id is `app_id` (§7.2.8.1, Table 7.2.8-1).
pub fn navigate(page: *Page, from: ?*Elem, dir: style.Dir, app_id: []const u8, rank: []const u32) Target {
    if (from) |f| if (f.style.nav[@backingInt(dir)]) |nav| {
        if (nav.app.len > 0 and !std.mem.eql(u8, nav.app, app_id)) return .{ .other = nav };
        const n = page.doc.getElementById(nav.elem) orelse return .none;
        const e = Page.elemOf(n) orelse return .none;
        return if (focusable(e)) .{ .elem = e } else .none;
    };
    const axis: usize, const forward: bool = switch (dir) {
        .right => .{ 0, true },
        .left => .{ 0, false },
        .down => .{ 1, true },
        .up => .{ 1, false },
        else => return .none, // the diagonals only follow their nav* property
    };
    const cur: ?i32 = if (from) |f| (if (navValue(f)) |v| v[axis] else null) else null;
    var best: ?*Elem = null; // the next value in the direction
    var wrap: ?*Elem = null; // the lowest value going forward, the highest going back
    for (page.elems.items) |e| {
        if (e == from or !focusable(e)) continue;
        const v = (navValue(e) orelse continue)[axis];
        if (cur) |c| if (if (forward) v > c else v < c) {
            if (best == null or better(e, best.?, axis, forward, rank)) best = e;
        };
        if (wrap == null or better(e, wrap.?, axis, forward, rank)) wrap = e;
    }
    if (best) |e| return .{ .elem = e };
    // At the end, or nothing focused: wrap around (focus stays if it is the only candidate).
    return if (wrap) |e| .{ .elem = e } else .none;
}

/// Whether `a` comes before `b` going in a direction: the value closest to where navigation starts, then the
/// element on top.
fn better(a: *const Elem, b: *const Elem, axis: usize, forward: bool, rank: []const u32) bool {
    const va = navValue(a).?[axis];
    const vb = navValue(b).?[axis];
    if (va != vb) return if (forward) va < vb else va > vb;
    return rank[a.index] > rank[b.index];
}

/// The element whose accessKey matches key `k` (§7.2.8.1): displayed, enabled, the first in document order.
pub fn accessKey(page: *Page, k: keys.Key) ?*Elem {
    for (page.elems.items) |e| {
        if (!e.kind.activatable() or !displayed(e) or !e.state.enabled) continue;
        const list = e.node.attr("accessKey") orelse continue;
        if (keys.matches(list, k)) return e;
    }
    return null;
}

/// The element under (x, y), in region coordinates (§7.6.3.4.2.5): the navigable element drawn on top whose
/// extent contains the point, displayed and visible (opacity does not matter). `order` is paint.order.
pub fn hit(page: *Page, order: []const u32, x: f32, y: f32) ?*Elem {
    var i = order.len;
    while (i > 0) {
        i -= 1;
        const e = page.elems.items[order[i]];
        if (!e.kind.navigable() or !displayed(e) or !e.style.visible) continue;
        const b = e.box;
        if (x < b.x or y < b.y or x >= b.x + b.w or y >= b.y + b.h) continue;
        if (e.kind == .area) {
            const obj = e.parent orelse continue;
            if (!layout.inArea(e, x - obj.box.x, y - obj.box.y)) continue;
        }
        return e;
    }
    return null;
}

/// Ranks from a paint order: rank[elem index] = position (higher is drawn later, on top).
pub fn ranks(gpa: std.mem.Allocator, order: []const u32) ![]u32 {
    const r = try gpa.alloc(u32, order.len);
    for (order, 0..) |idx, pos| r[idx] = @intCast(pos);
    return r;
}

// ---- tests --------------------------------------------------------------------------------------------------

const testing = std.testing;
const paint = @import("paint.zig");

fn testPage(src: []const u8) !*Page {
    const p = try Page.fromBytes(testing.allocator, null, src, "file:///a/p.xmu", 1080);
    var lay: layout.Layout = .init(testing.allocator);
    defer lay.deinit();
    lay.run(p, .{ .ctx = undefined, .font = noFont, .image = noImage }, 1920, 1080);
    return p;
}

fn noFont(_: *anyopaque, _: *Page, _: *Elem) ?*@import("../font.zig").Font {
    return null;
}

fn noImage(_: *anyopaque, _: []const u8) ?*@import("../image.zig").Image {
    return null;
}

fn byId(p: *Page, id: []const u8) *Elem {
    return Page.elemOf(p.doc.getElementById(id).?).?;
}

const grid =
    \\<root xmlns="http://www.dvdforum.org/2005/ihd" xmlns:style="http://www.dvdforum.org/2005/ihd#style" xml:lang="en"><body>
    \\ <button id="a" style:position="absolute" style:x="100px" style:y="100px" style:width="10px" style:height="10px"/>
    \\ <button id="b" style:position="absolute" style:x="200px" style:y="100px" style:width="10px" style:height="10px"/>
    \\ <button id="c" style:position="absolute" style:x="100px" style:y="200px" style:width="10px" style:height="10px"/>
    \\ <button id="d" style:position="absolute" style:x="200px" style:y="200px" style:width="10px" style:height="10px"
    \\   style:navUp="a" style:navRightUp="other#x"/>
    \\ <button id="e" style:navIndex="2 1" style:position="absolute" style:x="0px" style:y="0px" style:width="10px" style:height="10px"/>
    \\ <button id="f" style:navIndex="none" style:position="absolute" style:x="0px" style:y="300px" style:width="10px" style:height="10px"/>
    \\ <div id="g" style:position="absolute" style:x="150px" style:y="150px" style:width="100px" style:height="100px" style:zIndex="5"/>
    \\ <button id="h" style:display="none" style:position="absolute" style:x="300px" style:y="300px" style:width="10px" style:height="10px"/>
    \\</body></root>
;

test "navIndex generation and navigation gestures" {
    const p = try testPage(grid);
    defer p.destroy();
    const ord = try paint.order(testing.allocator, p);
    defer testing.allocator.free(ord);
    const rk = try ranks(testing.allocator, ord);
    defer testing.allocator.free(rk);
    try generate(testing.allocator, p, rk);

    // Rows skip the explicit 2 in the first value; columns skip the explicit 1 in the second.
    try testing.expectEqual([2]i32{ 1, 2 }, navValue(byId(p, "a")).?);
    try testing.expectEqual([2]i32{ 3, 4 }, navValue(byId(p, "b")).?);
    try testing.expectEqual([2]i32{ 4, 3 }, navValue(byId(p, "c")).?);
    try testing.expectEqual([2]i32{ 5, 5 }, navValue(byId(p, "d")).?);
    try testing.expectEqual([2]i32{ 2, 1 }, navValue(byId(p, "e")).?);
    try testing.expectEqual(@as(?[2]i32, null), navValue(byId(p, "f")));
    try testing.expect(!focusable(byId(p, "f")) and !focusable(byId(p, "h")));
    try testing.expect(!stale(p));

    const go = struct {
        fn f(pg: *Page, from: ?*Elem, d: style.Dir, r: []const u32) ?[]const u8 {
            return switch (navigate(pg, from, d, "me", r)) {
                .elem => |e| e.node.attr("id"),
                .other => |o| o.app,
                .none => null,
            };
        }
    }.f;
    // Nothing focused: Right/Down go to the lowest, Left/Up to the highest.
    try testing.expectEqualStrings("a", go(p, null, .right, rk).?);
    try testing.expectEqualStrings("e", go(p, null, .down, rk).?);
    try testing.expectEqualStrings("d", go(p, null, .left, rk).?);
    try testing.expectEqual(@as(?[]const u8, null), go(p, null, .right_up, rk));
    // Next value, and wrapping at the end; h (display none) and f (none) are skipped.
    try testing.expectEqualStrings("e", go(p, byId(p, "a"), .right, rk).?);
    try testing.expectEqualStrings("a", go(p, byId(p, "d"), .right, rk).?);
    try testing.expectEqualStrings("c", go(p, byId(p, "a"), .down, rk).?);
    // Explicit properties win, and can name another application.
    try testing.expectEqualStrings("a", go(p, byId(p, "d"), .up, rk).?);
    try testing.expectEqualStrings("other", go(p, byId(p, "d"), .right_up, rk).?);
    // A disabled target does not take focus.
    byId(p, "a").state.enabled = false;
    try testing.expectEqual(@as(?[]const u8, null), go(p, byId(p, "d"), .up, rk));
}

test "pointer hit-testing and access keys" {
    const p = try testPage(
        \\<root xmlns="http://www.dvdforum.org/2005/ihd" xmlns:style="http://www.dvdforum.org/2005/ihd#style" xml:lang="en"><body>
        \\ <div id="under" style:position="absolute" style:x="0px" style:y="0px" style:width="100px" style:height="100px" style:zIndex="2">
        \\  <button id="in" accessKey="U+0035 VK_A_BUTTON" style:position="absolute" style:x="10px" style:y="10px" style:width="20px" style:height="20px"/>
        \\ </div>
        \\ <div id="hidden" style:visibility="hidden" style:position="absolute" style:x="0px" style:y="0px" style:width="50px" style:height="50px" style:zIndex="3"/>
        \\ <object id="o" style:position="absolute" style:x="200px" style:y="0px" style:width="100px" style:height="100px">
        \\  <area id="r" shape="circle" coords="50 50 10"/>
        \\ </object>
        \\</body></root>
    );
    defer p.destroy();
    const ord = try paint.order(testing.allocator, p);
    defer testing.allocator.free(ord);
    try testing.expectEqualStrings("in", hit(p, ord, 15, 15).?.node.attr("id").?);
    try testing.expectEqualStrings("under", hit(p, ord, 60, 60).?.node.attr("id").?);
    try testing.expectEqual(@as(?*Elem, null), hit(p, ord, 500, 500)); // the body is not navigable
    try testing.expectEqualStrings("r", hit(p, ord, 250, 50).?.node.attr("id").?);
    try testing.expectEqual(@as(?*Elem, null), hit(p, ord, 205, 5)); // nor is the object
    try testing.expectEqualStrings("in", accessKey(p, 0x35).?.node.attr("id").?);
    try testing.expectEqualStrings("in", accessKey(p, keys.byName("VK_A_BUTTON").?).?.node.attr("id").?);
    try testing.expectEqual(@as(?*Elem, null), accessKey(p, keys.enter));
}
