//! Animated values (HD DVD Vol. 3 §7.7.3, §7.8.1): sampling a `;` value list at a point of its simple
//! duration (linear or discrete, key times evenly spread), and adding values for `additive="sum"`.
//!
//! Values are strings in the property's syntax. Two values interpolate when they have the same shape: the
//! same text around the same count of numbers ("10px" and "-4px", "rgba(…)" and "rgba(…)"); colour
//! keywords and #hex are first written as rgba(). Anything else falls back to discrete. No VLC dependency.

const std = @import("std");
const style = @import("style.zig");

/// The value of a `;`-separated list at fraction `f` (0–1) of the simple duration.
pub fn sample(a: std.mem.Allocator, prop: ?style.Prop, values: []const []const u8, f: f64, linear: bool) []const u8 {
    const n = values.len;
    if (n == 0) return "";
    if (n == 1) return values[0];
    const pos = std.math.clamp(f, 0, 1) * @as(f64, @floatFromInt(n - 1));
    const i: usize = @min(n - 1, @as(usize, @intFromFloat(@floor(pos))));
    if (i == n - 1 or !linear) return values[i];
    return lerp(a, prop, values[i], values[i + 1], pos - @as(f64, @floatFromInt(i))) orelse values[i];
}

/// `base` + `delta` (additive sum), or null if they cannot be added.
pub fn add(a: std.mem.Allocator, prop: ?style.Prop, base: []const u8, delta: []const u8) ?[]const u8 {
    return combine(a, prop, base, delta, 1, .sum);
}

/// Linear interpolation from `x` to `y` at `t` (0–1), or null if they do not interpolate.
pub fn lerp(a: std.mem.Allocator, prop: ?style.Prop, x: []const u8, y: []const u8, t: f64) ?[]const u8 {
    return combine(a, prop, x, y, t, .lerp);
}

fn combine(a: std.mem.Allocator, prop: ?style.Prop, x_in: []const u8, y_in: []const u8, t: f64, op: enum { lerp, sum }) ?[]const u8 {
    var bx: [32]u8 = undefined;
    var by: [32]u8 = undefined;
    const x = normalize(prop, x_in, &bx);
    const y = normalize(prop, y_in, &by);
    var sx: Shape = .{};
    var sy: Shape = .{};
    if (!sx.parse(x) or !sy.parse(y) or !sx.sameAs(&sy, x, y) or sx.n == 0) return null;
    const integer = if (prop) |p| isInteger(p) else false;
    var w: std.Io.Writer.Allocating = .init(a);
    var last: usize = 0;
    for (0..sx.n) |k| {
        w.writer.writeAll(x[last..sx.at[k][0]]) catch return null;
        const vx = sx.v[k];
        const vy = sy.v[k];
        var v = switch (op) {
            .lerp => vx + (vy - vx) * t,
            .sum => vx + vy,
        };
        if (integer) v = @round(v);
        writeNum(&w.writer, v) catch return null;
        last = sx.at[k][1];
    }
    w.writer.writeAll(x[last..]) catch return null;
    return w.written();
}

/// Properties whose values are whole numbers: interpolated values are rounded (§7.7.3.4).
fn isInteger(p: style.Prop) bool {
    return switch (p) {
        .backgroundFrame, .zIndex, .color, .backgroundColor, .crop => true,
        else => false,
    };
}

/// Colours as rgba() so that keywords, #hex and rgb() interpolate together.
fn normalize(prop: ?style.Prop, v_in: []const u8, buf: *[32]u8) []const u8 {
    const v = std.mem.trim(u8, v_in, " \t\r\n");
    const p = prop orelse return v;
    if (p != .color and p != .backgroundColor) return v;
    const c = style.parseColor(v) catch return v;
    return std.fmt.bufPrint(buf, "rgba({d},{d},{d},{d})", .{ c[0], c[1], c[2], c[3] }) catch v;
}

fn writeNum(w: *std.Io.Writer, v: f64) !void {
    if (v == @round(v) and @abs(v) < 1e15) return w.print("{d}", .{@as(i64, @intFromFloat(v))});
    // Three decimals are below a pixel's or an opacity step's precision.
    var buf: [64]u8 = undefined;
    var s = try std.fmt.bufPrint(&buf, "{d:.3}", .{v});
    while (s.len > 0 and s[s.len - 1] == '0') s = s[0 .. s.len - 1];
    if (s.len > 0 and s[s.len - 1] == '.') s = s[0 .. s.len - 1];
    try w.writeAll(s);
}

/// The numbers in a value and where they are.
const Shape = struct {
    n: usize = 0,
    at: [16][2]usize = undefined,
    v: [16]f64 = undefined,

    fn parse(s: *Shape, x: []const u8) bool {
        var i: usize = 0;
        while (i < x.len) {
            const c = x[i];
            const starts = std.ascii.isDigit(c) or ((c == '-' or c == '+' or c == '.') and i + 1 < x.len and (std.ascii.isDigit(x[i + 1]) or x[i + 1] == '.'));
            // A number starts a token: not inside a name such as "rgba" or "#ff0".
            const inside = i > 0 and (std.ascii.isAlphabetic(x[i - 1]) or x[i - 1] == '#' or x[i - 1] == '_');
            if (!starts or inside) {
                if (std.ascii.isAlphanumeric(c) or c == '#' or c == '_') {
                    while (i < x.len and (std.ascii.isAlphanumeric(x[i]) or x[i] == '#' or x[i] == '_' or x[i] == '-')) i += 1;
                } else i += 1;
                continue;
            }
            var j = i + 1;
            while (j < x.len and (std.ascii.isDigit(x[j]) or x[j] == '.')) j += 1;
            if (s.n == s.at.len) return false;
            s.v[s.n] = std.fmt.parseFloat(f64, x[i..j]) catch return false;
            s.at[s.n] = .{ i, j };
            s.n += 1;
            i = j;
        }
        return true;
    }

    /// The same text around the same count of numbers.
    fn sameAs(s: *const Shape, o: *const Shape, x: []const u8, y: []const u8) bool {
        if (s.n != o.n) return false;
        var lx: usize = 0;
        var ly: usize = 0;
        for (0..s.n) |k| {
            if (!std.mem.eql(u8, x[lx..s.at[k][0]], y[ly..o.at[k][0]])) return false;
            lx = s.at[k][1];
            ly = o.at[k][1];
        }
        return std.mem.eql(u8, x[lx..], y[ly..]);
    }
};

/// Splits a `;` list (items trimmed, empty items dropped) into `out`.
pub fn split(a: std.mem.Allocator, raw: []const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, raw, ';');
    while (it.next()) |item| {
        const v = std.mem.trim(u8, item, " \t\r\n");
        if (v.len > 0) try list.append(a, v);
    }
    return list.toOwnedSlice(a);
}

const testing = std.testing;

test "sampling and adding values" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const xs = [_][]const u8{ "0px", "10px", "-10px" };
    try testing.expectEqualStrings("0px", sample(a, .x, &xs, 0, true));
    try testing.expectEqualStrings("5px", sample(a, .x, &xs, 0.25, true));
    try testing.expectEqualStrings("10px", sample(a, .x, &xs, 0.5, true));
    try testing.expectEqualStrings("-5px", sample(a, .x, &xs, 0.875, true));
    try testing.expectEqualStrings("-10px", sample(a, .x, &xs, 1, true));
    // Discrete: the earlier key until the next one.
    try testing.expectEqualStrings("10px", sample(a, .x, &xs, 0.9, false));
    // Colours of any syntax interpolate, rounded.
    const cs = [_][]const u8{ "red", "#0000ff" };
    try testing.expectEqualStrings("rgba(128,0,128,255)", sample(a, .color, &cs, 0.5, true));
    // Different shapes fall back to discrete.
    const mixed = [_][]const u8{ "10px", "50%" };
    try testing.expectEqualStrings("10px", sample(a, .width, &mixed, 0.5, true));
    try testing.expectEqualStrings("0.75", add(a, .opacity, "0.5", "0.25").?);
    try testing.expectEqualStrings("3", sample(a, .backgroundFrame, &.{ "1", "4" }, 0.5, true));
    try testing.expectEqual(@as(?[]const u8, null), add(a, .display, "auto", "none"));
    const l = try split(a, " 1px ; 2px;;");
    try testing.expectEqual(@as(usize, 2), l.len);
}
