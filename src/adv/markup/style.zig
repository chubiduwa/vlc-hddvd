//! Style properties of Advanced Content markup (HD DVD Vol. 3 §7.6.3.3): the 63 `style:` attributes, their
//! value grammars, initial values and inheritance, computed values (`Style`), and the normalized strings that
//! the XPath property functions and the script API's getProperty() return (§7.5.2.4.3.2). The cascade that
//! decides which specified value applies is in page.zig. No VLC dependency.

const std = @import("std");

pub const ns = "http://www.dvdforum.org/2005/ihd#style";

pub const Prop = enum(u8) {
    anchor,
    backgroundColor,
    backgroundFrame,
    backgroundImage,
    backgroundPositionHorizontal,
    backgroundPositionVertical,
    backgroundRepeat,
    blockProgressionDimension,
    border,
    borderAfter,
    borderBefore,
    borderEnd,
    borderStart,
    breakAfter,
    breakBefore,
    color,
    contentWidth,
    contentHeight,
    crop,
    direction,
    display,
    displayAlign,
    endIndent,
    flip,
    font,
    fontSize,
    fontStyle,
    height,
    inlineProgressionDimension,
    linefeedTreatment,
    lineHeight,
    navDown,
    navIndex,
    navLeft,
    navLeftDown,
    navLeftUp,
    navRight,
    navRightDown,
    navRightUp,
    navUp,
    opacity,
    padding,
    paddingAfter,
    paddingBefore,
    paddingEnd,
    paddingStart,
    position,
    scaling,
    startIndent,
    suppressAtLineBreak,
    textAlign,
    textAltitude,
    textDepth,
    textIndent,
    visibility,
    whiteSpaceCollapse,
    whiteSpaceTreatment,
    width,
    wrapOption,
    writingMode,
    x,
    y,
    zIndex,

    pub fn byName(local: []const u8) ?Prop {
        return std.meta.stringToEnum(Prop, local);
    }

    /// Inherited properties take the parent's computed value when nothing sets them (Table 7.6.3.3.2).
    pub fn inherited(p: Prop) bool {
        return switch (p) {
            .color, .crop, .direction, .displayAlign, .endIndent, .font, .fontSize, .fontStyle, .linefeedTreatment, .lineHeight, .startIndent, .textAlign, .textIndent, .visibility, .whiteSpaceCollapse, .whiteSpaceTreatment, .wrapOption, .writingMode => true,
            else => false,
        };
    }

    pub const Anim = enum { none, discrete, linear };

    /// How the property can be animated (§7.6.3.3.1).
    pub fn anim(p: Prop) Anim {
        return switch (p) {
            .backgroundRepeat, .breakAfter, .breakBefore, .direction, .linefeedTreatment, .position, .scaling, .suppressAtLineBreak, .whiteSpaceCollapse, .whiteSpaceTreatment, .writingMode => .none,
            .anchor, .backgroundImage, .border, .borderAfter, .borderBefore, .borderEnd, .borderStart, .display, .displayAlign, .flip, .font, .fontStyle, .navDown, .navIndex, .navLeft, .navLeftDown, .navLeftUp, .navRight, .navRightDown, .navRightUp, .navUp, .textAlign, .visibility, .wrapOption => .discrete,
            else => .linear,
        };
    }

    /// The longhands a shorthand sets.
    pub fn longhands(p: Prop) []const Prop {
        return switch (p) {
            .border => &.{ .borderBefore, .borderEnd, .borderAfter, .borderStart },
            .padding => &.{ .paddingBefore, .paddingEnd, .paddingAfter, .paddingStart },
            else => &.{},
        };
    }
};

pub const count = std.enums.values(Prop).len;

// ---- value types ------------------------------------------------------------------------------------------

/// Straight-alpha RGBA.
pub const Color = [4]u8;

pub const Unit = enum { px, pct };

/// A length after `em` resolution: pixels or a percentage of something the layout knows.
pub const Len = struct {
    v: f32,
    unit: Unit = .px,

    pub fn px(v: f32) Len {
        return .{ .v = v };
    }

    /// The value in pixels, percentages of `base`.
    pub fn resolve(l: Len, base: f32) f32 {
        return if (l.unit == .pct) l.v * base / 100 else l.v;
    }
};

pub const Anchor = enum { startBefore, centerBefore, endBefore, startCenter, center, endCenter, startAfter, centerAfter, endAfter };
pub const BorderStyle = enum { none, hidden, solid };
pub const Border = struct {
    width: f32 = 3,
    style: BorderStyle = .none,
    /// null: the element's computed color.
    color: ?Color = null,
};
pub const ContentSize = union(enum) { auto, scale_to_fit, len: Len };
pub const Flip = enum { none, inlineProgression, blockProgression, both };
pub const Font = struct { uri: []const u8 = "", name: []const u8 = "" };
pub const FontStyle = enum { normal, italic, oblique, backslant, @"reverse-oblique" };
pub const LinefeedTreatment = enum { ignore, preserve, @"treat-as-space", @"treat-as-zero-width-space" };
pub const Nav = struct { app: []const u8 = "", elem: []const u8 };
pub const NavIndex = union(enum) { auto, none, pair: [2]i32 };
pub const Position = enum { static, relative, absolute };
pub const Suppress = enum { auto, suppress, retain };
pub const TextAlign = enum { start, center, end };
pub const WhiteSpaceTreatment = enum { ignore, preserve, @"ignore-before", @"ignore-after", @"ignore-around" };
pub const WritingMode = enum { @"lr-tb", @"rl-tb", @"tb-rl" };
pub const DisplayAlign = enum { auto, before, center, after };

/// Directions of the nav* properties.
pub const Dir = enum { up, down, left, right, left_up, left_down, right_up, right_down };

pub fn navProp(d: Dir) Prop {
    return switch (d) {
        .up => .navUp,
        .down => .navDown,
        .left => .navLeft,
        .right => .navRight,
        .left_up => .navLeftUp,
        .left_down => .navLeftDown,
        .right_up => .navRightUp,
        .right_down => .navRightDown,
    };
}

/// Computed values of every property of one element. Strings and lists point into the page's style arena or
/// into attribute values of the DOM, valid until the next style computation.
pub const Style = struct {
    anchor: Anchor = .startBefore,
    backgroundColor: Color = .{ 0, 0, 0, 0 },
    backgroundFrame: i32 = 0,
    backgroundImage: []const []const u8 = &.{},
    backgroundPositionHorizontal: Len = .{ .v = 0, .unit = .pct },
    backgroundPositionVertical: Len = .{ .v = 0, .unit = .pct },
    backgroundRepeat: bool = false,
    blockProgressionDimension: ?Len = null,
    /// Before, end, after, start (top, right, bottom, left in lr-tb).
    borders: [4]Border = @splat(.{}),
    breakAfter: bool = false,
    breakBefore: bool = false,
    color: Color = .{ 255, 255, 255, 255 },
    contentWidth: ContentSize = .auto,
    contentHeight: ContentSize = .auto,
    /// left-x, top-y, right-x, bottom-y in source pixels; null: the whole image.
    crop: ?[4]u32 = null,
    rtl: bool = false,
    display: bool = true,
    displayAlign: DisplayAlign = .auto,
    endIndent: Len = .{ .v = 0 },
    flip: Flip = .none,
    font: Font = .{},
    /// Inline and block font size, in pixels.
    fontSize: [2]f32 = .{ 64, 64 },
    fontStyle: FontStyle = .normal,
    height: ?Len = null,
    inlineProgressionDimension: ?Len = null,
    linefeedTreatment: LinefeedTreatment = .@"treat-as-space",
    /// Pixels; null: auto.
    lineHeight: ?f32 = null,
    nav: [8]?Nav = @splat(null),
    navIndex: NavIndex = .auto,
    opacity: f32 = 1,
    /// Before, end, after, start.
    padding: [4]Len = @splat(.{ .v = 0 }),
    position: Position = .static,
    uniform: bool = false,
    startIndent: Len = .{ .v = 0 },
    suppressAtLineBreak: Suppress = .auto,
    textAlign: TextAlign = .start,
    textAltitude: ?Len = null,
    textDepth: ?Len = null,
    textIndent: Len = .{ .v = 0 },
    visible: bool = true,
    whiteSpaceCollapse: bool = true,
    whiteSpaceTreatment: WhiteSpaceTreatment = .@"ignore-around",
    width: ?Len = null,
    wrap: bool = true,
    writingMode: WritingMode = .@"lr-tb",
    x: ?Len = .{ .v = 0 },
    y: ?Len = .{ .v = 0 },
    zIndex: ?i32 = null,

    /// The initial values for an aperture `aperture_h` lines high (fontSize medium depends on it).
    pub fn initial(aperture_h: u32) Style {
        const m = keywordSize(aperture_h, "medium").?;
        return .{ .fontSize = .{ m, m } };
    }

    /// Copies the inherited properties from `parent`.
    pub fn inherit(s: *Style, parent: *const Style) void {
        inline for (comptime std.enums.values(Prop)) |p| {
            if (comptime p.inherited()) copyProp(s, parent, p);
        }
    }
};

/// Copies one property's computed value (shorthands copy their longhands).
pub fn copyProp(s: *Style, from: *const Style, p: Prop) void {
    switch (p) {
        .anchor => s.anchor = from.anchor,
        .backgroundColor => s.backgroundColor = from.backgroundColor,
        .backgroundFrame => s.backgroundFrame = from.backgroundFrame,
        .backgroundImage => s.backgroundImage = from.backgroundImage,
        .backgroundPositionHorizontal => s.backgroundPositionHorizontal = from.backgroundPositionHorizontal,
        .backgroundPositionVertical => s.backgroundPositionVertical = from.backgroundPositionVertical,
        .backgroundRepeat => s.backgroundRepeat = from.backgroundRepeat,
        .blockProgressionDimension => s.blockProgressionDimension = from.blockProgressionDimension,
        .border => s.borders = from.borders,
        .borderBefore => s.borders[0] = from.borders[0],
        .borderEnd => s.borders[1] = from.borders[1],
        .borderAfter => s.borders[2] = from.borders[2],
        .borderStart => s.borders[3] = from.borders[3],
        .breakAfter => s.breakAfter = from.breakAfter,
        .breakBefore => s.breakBefore = from.breakBefore,
        .color => s.color = from.color,
        .contentWidth => s.contentWidth = from.contentWidth,
        .contentHeight => s.contentHeight = from.contentHeight,
        .crop => s.crop = from.crop,
        .direction => s.rtl = from.rtl,
        .display => s.display = from.display,
        .displayAlign => s.displayAlign = from.displayAlign,
        .endIndent => s.endIndent = from.endIndent,
        .flip => s.flip = from.flip,
        .font => s.font = from.font,
        .fontSize => s.fontSize = from.fontSize,
        .fontStyle => s.fontStyle = from.fontStyle,
        .height => s.height = from.height,
        .inlineProgressionDimension => s.inlineProgressionDimension = from.inlineProgressionDimension,
        .linefeedTreatment => s.linefeedTreatment = from.linefeedTreatment,
        .lineHeight => s.lineHeight = from.lineHeight,
        .navDown, .navLeft, .navLeftDown, .navLeftUp, .navRight, .navRightDown, .navRightUp, .navUp => {
            const i = @backingInt(navDir(p).?);
            s.nav[i] = from.nav[i];
        },
        .navIndex => s.navIndex = from.navIndex,
        .opacity => s.opacity = from.opacity,
        .padding => s.padding = from.padding,
        .paddingBefore => s.padding[0] = from.padding[0],
        .paddingEnd => s.padding[1] = from.padding[1],
        .paddingAfter => s.padding[2] = from.padding[2],
        .paddingStart => s.padding[3] = from.padding[3],
        .position => s.position = from.position,
        .scaling => s.uniform = from.uniform,
        .startIndent => s.startIndent = from.startIndent,
        .suppressAtLineBreak => s.suppressAtLineBreak = from.suppressAtLineBreak,
        .textAlign => s.textAlign = from.textAlign,
        .textAltitude => s.textAltitude = from.textAltitude,
        .textDepth => s.textDepth = from.textDepth,
        .textIndent => s.textIndent = from.textIndent,
        .visibility => s.visible = from.visible,
        .whiteSpaceCollapse => s.whiteSpaceCollapse = from.whiteSpaceCollapse,
        .whiteSpaceTreatment => s.whiteSpaceTreatment = from.whiteSpaceTreatment,
        .width => s.width = from.width,
        .wrapOption => s.wrap = from.wrap,
        .writingMode => s.writingMode = from.writingMode,
        .x => s.x = from.x,
        .y => s.y = from.y,
        .zIndex => s.zIndex = from.zIndex,
    }
}

pub fn navDir(p: Prop) ?Dir {
    return switch (p) {
        .navUp => .up,
        .navDown => .down,
        .navLeft => .left,
        .navRight => .right,
        .navLeftUp => .left_up,
        .navLeftDown => .left_down,
        .navRightUp => .right_up,
        .navRightDown => .right_down,
        else => null,
    };
}

/// fontSize keywords in pixels, by aperture (Table 7.6.3.3.2.26-2).
pub fn keywordSize(aperture_h: u32, word: []const u8) ?f32 {
    const names = [_][]const u8{ "xx-small", "x-small", "small", "medium", "large", "x-large", "xx-large" };
    const hd = [_]f32{ 26, 38, 51, 64, 77, 90, 102 };
    const sd = [_]f32{ 17, 26, 34, 43, 51, 60, 68 };
    for (names, 0..) |n, i| if (std.mem.eql(u8, n, word)) return if (aperture_h <= 720) sd[i] else hd[i];
    return null;
}

// ---- parsing specified values into computed ones --------------------------------------------------------------

/// What resolving a value needs besides the text.
pub const Env = struct {
    parent: *const Style,
    aperture_h: u32,
    /// Lists (backgroundImage) are allocated here.
    arena: std.mem.Allocator,
};

/// The first value of a `;`-separated value list (single-value contexts, §7.6.3.3.1).
pub fn firstValue(raw: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, raw, ';') orelse raw.len;
    return std.mem.trim(u8, raw[0..end], " \t\r\n");
}

/// Applies the specified value `raw` of `p` to `s`. `inherit` copies the parent's value; an invalid value is
/// ignored (false).
pub fn apply(s: *Style, p: Prop, raw_in: []const u8, env: Env) bool {
    const raw = firstValue(raw_in);
    if (std.mem.eql(u8, raw, "inherit") and p != .crop and p != .navIndex) {
        copyProp(s, env.parent, p);
        return true;
    }
    return parseInto(s, p, raw, env) catch false;
}

const ParseError = error{ Bad, OutOfMemory };

fn kw(comptime E: type, raw: []const u8) ParseError!E {
    return std.meta.stringToEnum(E, raw) orelse error.Bad;
}

fn parseInto(s: *Style, p: Prop, raw: []const u8, env: Env) ParseError!bool {
    // `em` resolves against this element's font size: fontSize itself first (see `order`).
    const em = s.fontSize[1];
    switch (p) {
        .anchor => s.anchor = try kw(Anchor, raw),
        .backgroundColor => s.backgroundColor = try parseColor(raw),
        .backgroundFrame => s.backgroundFrame = try parseInt(raw),
        .backgroundImage => s.backgroundImage = try parseUris(raw, env.arena),
        .backgroundPositionHorizontal => s.backgroundPositionHorizontal = try parsePosition(raw, "left", "center", "right", em),
        .backgroundPositionVertical => s.backgroundPositionVertical = try parsePosition(raw, "top", "center", "bottom", em),
        .backgroundRepeat => s.backgroundRepeat = if (std.mem.eql(u8, raw, "repeat")) true else if (std.mem.eql(u8, raw, "no-repeat")) false else return error.Bad,
        .blockProgressionDimension => s.blockProgressionDimension = try parseAutoLen(raw, em),
        .border => {
            const b = try parseBorder(raw, em);
            s.borders = @splat(b);
        },
        .borderBefore => s.borders[0] = try parseBorder(raw, em),
        .borderEnd => s.borders[1] = try parseBorder(raw, em),
        .borderAfter => s.borders[2] = try parseBorder(raw, em),
        .borderStart => s.borders[3] = try parseBorder(raw, em),
        .breakAfter => s.breakAfter = try parseBreak(raw),
        .breakBefore => s.breakBefore = try parseBreak(raw),
        .color => s.color = try parseColor(raw),
        .contentWidth => s.contentWidth = try parseContentSize(raw, em),
        .contentHeight => s.contentHeight = try parseContentSize(raw, em),
        .crop => s.crop = if (std.mem.eql(u8, raw, "auto")) null else try parseCrop(raw),
        .direction => s.rtl = if (std.mem.eql(u8, raw, "rtl")) true else if (std.mem.eql(u8, raw, "ltr")) false else return error.Bad,
        .display => s.display = if (std.mem.eql(u8, raw, "none")) false else if (std.mem.eql(u8, raw, "auto")) true else return error.Bad,
        .displayAlign => s.displayAlign = try kw(DisplayAlign, raw),
        .endIndent => s.endIndent = try parseLen(raw, em, true),
        .flip => s.flip = try kw(Flip, raw),
        .font => s.font = try parseFont(raw),
        .fontSize => s.fontSize = try parseFontSize(raw, env),
        .fontStyle => s.fontStyle = try kw(FontStyle, raw),
        .height => s.height = try parseAutoLen(raw, em),
        .inlineProgressionDimension => s.inlineProgressionDimension = try parseAutoLen(raw, em),
        .linefeedTreatment => s.linefeedTreatment = try kw(LinefeedTreatment, raw),
        .lineHeight => s.lineHeight = if (std.mem.eql(u8, raw, "auto")) null else (try parseLen(raw, em, true)).resolve(s.fontSize[1]),
        .navDown, .navLeft, .navLeftDown, .navLeftUp, .navRight, .navRightDown, .navRightUp, .navUp => s.nav[@backingInt(navDir(p).?)] = try parseNav(raw),
        .navIndex => s.navIndex = try parseNavIndex(raw),
        .opacity => {
            const v = std.fmt.parseFloat(f32, raw) catch return error.Bad;
            if (std.math.isNan(v)) return error.Bad;
            s.opacity = std.math.clamp(v, 0, 1);
        },
        .padding => s.padding = try parsePadding(raw, em),
        .paddingBefore => s.padding[0] = try parsePaddingWidth(raw, em),
        .paddingEnd => s.padding[1] = try parsePaddingWidth(raw, em),
        .paddingAfter => s.padding[2] = try parsePaddingWidth(raw, em),
        .paddingStart => s.padding[3] = try parsePaddingWidth(raw, em),
        .position => s.position = try kw(Position, raw),
        .scaling => s.uniform = if (std.mem.eql(u8, raw, "uniform")) true else if (std.mem.eql(u8, raw, "non-uniform")) false else return error.Bad,
        .startIndent => s.startIndent = try parseLen(raw, em, true),
        .suppressAtLineBreak => s.suppressAtLineBreak = try kw(Suppress, raw),
        .textAlign => s.textAlign = try kw(TextAlign, raw),
        .textAltitude => s.textAltitude = try parseAutoLen(raw, em),
        .textDepth => s.textDepth = try parseAutoLen(raw, em),
        .textIndent => s.textIndent = try parseLen(raw, em, true),
        .visibility => s.visible = if (std.mem.eql(u8, raw, "hidden")) false else if (std.mem.eql(u8, raw, "visible")) true else return error.Bad,
        .whiteSpaceCollapse => s.whiteSpaceCollapse = if (std.mem.eql(u8, raw, "true")) true else if (std.mem.eql(u8, raw, "false")) false else return error.Bad,
        .whiteSpaceTreatment => s.whiteSpaceTreatment = try kw(WhiteSpaceTreatment, raw),
        .width => s.width = try parseAutoLen(raw, em),
        .wrapOption => s.wrap = if (std.mem.eql(u8, raw, "wrap")) true else if (std.mem.eql(u8, raw, "no-wrap")) false else return error.Bad,
        .writingMode => s.writingMode = try kw(WritingMode, raw),
        .x => s.x = try parseAutoLen(raw, em),
        .y => s.y = try parseAutoLen(raw, em),
        .zIndex => s.zIndex = if (std.mem.eql(u8, raw, "auto")) null else try parseInt(raw),
    }
    return true;
}

/// The order to apply one element's properties in: fontSize first (other `em` lengths depend on it), then
/// color (the default border colour), shorthands before their longhands.
pub const order: [count]Prop = blk: {
    var out: [count]Prop = undefined;
    var n: usize = 0;
    out[n] = .fontSize;
    n += 1;
    out[n] = .color;
    n += 1;
    out[n] = .border;
    n += 1;
    out[n] = .padding;
    n += 1;
    for (std.enums.values(Prop)) |p| {
        if (p == .fontSize or p == .color or p == .border or p == .padding) continue;
        out[n] = p;
        n += 1;
    }
    break :blk out;
};

pub fn parseInt(raw: []const u8) ParseError!i32 {
    return std.fmt.parseInt(i32, std.mem.trim(u8, raw, " \t"), 10) catch error.Bad;
}

/// `<integer>px`, `<integer>em` (resolved with `em`), or `<integer>%` when `pct` is allowed. Fractions are
/// accepted (discs and animations produce them).
pub fn parseLen(raw: []const u8, em: f32, pct: bool) ParseError!Len {
    const t = std.mem.trim(u8, raw, " \t\r\n");
    if (std.mem.endsWith(u8, t, "px")) return .{ .v = try num(t[0 .. t.len - 2]) };
    if (std.mem.endsWith(u8, t, "em")) return .{ .v = try num(t[0 .. t.len - 2]) * em };
    if (pct and std.mem.endsWith(u8, t, "%")) return .{ .v = try num(t[0 .. t.len - 1]), .unit = .pct };
    // A bare 0 (and, leniently, any bare number) is pixels.
    return .{ .v = try num(t) };
}

fn num(s: []const u8) ParseError!f32 {
    const v = std.fmt.parseFloat(f32, std.mem.trim(u8, s, " \t")) catch return error.Bad;
    if (std.math.isNan(v) or std.math.isInf(v)) return error.Bad;
    return v;
}

fn parseAutoLen(raw: []const u8, em: f32) ParseError!?Len {
    if (std.mem.eql(u8, raw, "auto")) return null;
    return try parseLen(raw, em, true);
}

fn parsePosition(raw: []const u8, lo: []const u8, mid: []const u8, hi: []const u8, em: f32) ParseError!Len {
    if (std.mem.eql(u8, raw, lo)) return .{ .v = 0, .unit = .pct };
    if (std.mem.eql(u8, raw, mid)) return .{ .v = 50, .unit = .pct };
    if (std.mem.eql(u8, raw, hi)) return .{ .v = 100, .unit = .pct };
    return parseLen(raw, em, true);
}

fn parseBreak(raw: []const u8) ParseError!bool {
    if (std.mem.eql(u8, raw, "line")) return true;
    if (std.mem.eql(u8, raw, "auto")) return false;
    return error.Bad;
}

fn parseContentSize(raw: []const u8, em: f32) ParseError!ContentSize {
    if (std.mem.eql(u8, raw, "auto")) return .auto;
    if (std.mem.eql(u8, raw, "scale-to-fit")) return .scale_to_fit;
    return .{ .len = try parseLen(raw, em, true) };
}

fn parseCrop(raw: []const u8) ParseError![4]u32 {
    var out: [4]u32 = undefined;
    var it = std.mem.tokenizeAny(u8, raw, " \t,");
    for (&out) |*v| v.* = std.fmt.parseInt(u32, it.next() orelse return error.Bad, 10) catch return error.Bad;
    if (out[2] < out[0] or out[3] < out[1]) return error.Bad;
    return out;
}

fn parseFont(raw: []const u8) ParseError!Font {
    // <URI> ['full name']
    if (std.mem.indexOfScalar(u8, raw, '\'')) |q| {
        const end = std.mem.lastIndexOfScalar(u8, raw, '\'') orelse return error.Bad;
        if (end <= q) return error.Bad;
        return .{ .uri = std.mem.trim(u8, raw[0..q], " \t"), .name = raw[q + 1 .. end] };
    }
    return .{ .uri = raw };
}

fn parseFontSize(raw: []const u8, env: Env) ParseError![2]f32 {
    const parent = env.parent.fontSize;
    if (keywordSize(env.aperture_h, raw)) |v| return .{ v, v };
    if (std.mem.eql(u8, raw, "smaller")) return .{ parent[0] * 0.9, parent[1] * 0.9 };
    if (std.mem.eql(u8, raw, "larger")) return .{ parent[0] * 1.1, parent[1] * 1.1 };
    var it = std.mem.tokenizeAny(u8, raw, " \t");
    const a = try parseLen(it.next() orelse return error.Bad, parent[1], true);
    const b = if (it.next()) |t| try parseLen(t, parent[1], true) else a;
    if (it.next() != null) return error.Bad;
    const out: [2]f32 = .{ a.resolve(parent[0]), b.resolve(parent[1]) };
    if (out[0] < 0 or out[1] < 0) return error.Bad;
    return out;
}

/// A nav* value. An explicit `none` is kept (an empty target: focus does not move that way), apart from the
/// property not being set (null: navIndex decides). §7.2.5.3 makes `none` the initial value, which would make
/// the two the same, but discs set `none` to block a direction: a game's letter pickers set navUp/navDown to
/// `none` and take Up/Down in a script.
fn parseNav(raw: []const u8) ParseError!?Nav {
    if (std.mem.eql(u8, raw, "none")) return .{ .elem = "" };
    if (raw.len == 0 or std.mem.indexOfAny(u8, raw, " \t") != null) return error.Bad;
    if (std.mem.indexOfScalar(u8, raw, '#')) |h| return .{ .app = raw[0..h], .elem = raw[h + 1 ..] };
    return .{ .elem = raw };
}

fn parseNavIndex(raw: []const u8) ParseError!NavIndex {
    if (std.mem.eql(u8, raw, "auto")) return .auto;
    if (std.mem.eql(u8, raw, "none")) return .none;
    var it = std.mem.tokenizeAny(u8, raw, " \t");
    const a = try parseInt(it.next() orelse return error.Bad);
    const b = try parseInt(it.next() orelse return error.Bad);
    if (it.next() != null) return error.Bad;
    return .{ .pair = .{ a, b } };
}

fn parsePaddingWidth(raw: []const u8, em: f32) ParseError!Len {
    const l = try parseLen(raw, em, true);
    if (l.v < 0) return error.Bad;
    return l;
}

/// 1 value: all; 2: before/after, start/end; 3: before, start/end, after; 4: before, end, after, start.
fn parsePadding(raw: []const u8, em: f32) ParseError![4]Len {
    var v: [4]Len = undefined;
    var n: usize = 0;
    var it = std.mem.tokenizeAny(u8, raw, " \t");
    while (it.next()) |t| {
        if (n == 4) return error.Bad;
        v[n] = try parsePaddingWidth(t, em);
        n += 1;
    }
    return switch (n) {
        1 => .{ v[0], v[0], v[0], v[0] },
        2 => .{ v[0], v[1], v[0], v[1] },
        3 => .{ v[0], v[1], v[2], v[1] },
        4 => v,
        else => error.Bad,
    };
}

/// `[<width>] [<style>] [<color>]`, in any order.
fn parseBorder(raw: []const u8, em: f32) ParseError!Border {
    var b: Border = .{};
    // rgb(...)/rgba(...) may contain spaces: split them as one token.
    var i: usize = 0;
    const t = raw;
    var any = false;
    while (i < t.len) {
        while (i < t.len and std.ascii.isWhitespace(t[i])) i += 1;
        if (i >= t.len) break;
        var j = i;
        if (std.mem.startsWith(u8, t[i..], "rgb")) {
            j = (std.mem.indexOfScalarPos(u8, t, i, ')') orelse return error.Bad) + 1;
        } else {
            while (j < t.len and !std.ascii.isWhitespace(t[j])) j += 1;
        }
        const tok = t[i..j];
        i = j;
        any = true;
        if (std.meta.stringToEnum(BorderStyle, tok)) |st| {
            b.style = st;
        } else if (std.ascii.isDigit(tok[0]) or tok[0] == '.') {
            const l = try parseLen(tok, em, false);
            if (l.v < 0) return error.Bad;
            b.width = l.v;
        } else if (std.mem.eql(u8, tok, "inherit")) {
            b.color = null;
        } else b.color = try parseColor(tok);
    }
    if (!any) return error.Bad;
    return b;
}

/// `url(…)`+ (quoted or not), or `none`.
fn parseUris(raw: []const u8, a: std.mem.Allocator) ParseError![]const []const u8 {
    if (std.mem.eql(u8, raw, "none")) return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (true) {
        while (i < raw.len and std.ascii.isWhitespace(raw[i])) i += 1;
        if (i >= raw.len) break;
        if (!std.mem.startsWith(u8, raw[i..], "url(")) return error.Bad;
        const close = std.mem.indexOfScalarPos(u8, raw, i, ')') orelse return error.Bad;
        var u = std.mem.trim(u8, raw[i + 4 .. close], " \t\r\n");
        if (u.len >= 2 and (u[0] == '\'' or u[0] == '"') and u[u.len - 1] == u[0]) u = u[1 .. u.len - 1];
        // Whitespace inside the URI is removed (the normalized form, §7.5.2.4.3.2).
        if (std.mem.indexOfAny(u8, u, " \t\r\n") != null) {
            var clean: std.ArrayList(u8) = .empty;
            for (u) |c| if (!std.ascii.isWhitespace(c)) try clean.append(a, c);
            u = clean.items;
        }
        try out.append(a, u);
        i = close + 1;
    }
    if (out.items.len == 0) return error.Bad;
    return out.items;
}

const named_colors = [_]struct { []const u8, Color }{
    .{ "aqua", .{ 0, 255, 255, 255 } },     .{ "black", .{ 0, 0, 0, 255 } },      .{ "blue", .{ 0, 0, 255, 255 } },
    .{ "fuchsia", .{ 255, 0, 255, 255 } },  .{ "gray", .{ 128, 128, 128, 255 } }, .{ "green", .{ 0, 128, 0, 255 } },
    .{ "lime", .{ 0, 255, 0, 255 } },       .{ "maroon", .{ 128, 0, 0, 255 } },   .{ "navy", .{ 0, 0, 128, 255 } },
    .{ "olive", .{ 128, 128, 0, 255 } },    .{ "purple", .{ 128, 0, 128, 255 } }, .{ "red", .{ 255, 0, 0, 255 } },
    .{ "silver", .{ 192, 192, 192, 255 } }, .{ "teal", .{ 0, 128, 128, 255 } },   .{ "white", .{ 255, 255, 255, 255 } },
    .{ "yellow", .{ 255, 255, 0, 255 } },   .{ "transparent", .{ 0, 0, 0, 0 } },
};

/// CSS2 colours (keywords, #rgb, #rrggbb, rgb()) and `rgba(r,g,b,a)` with each component 0–255 or 0%–100%
/// (§7.6.2: the alpha is 0–255, not 0–1).
pub fn parseColor(raw: []const u8) ParseError!Color {
    const t = std.mem.trim(u8, raw, " \t\r\n");
    for (named_colors) |c| if (std.ascii.eqlIgnoreCase(t, c[0])) return c[1];
    if (t.len > 0 and t[0] == '#') {
        const h = t[1..];
        const hex = struct {
            fn d(c: u8) ParseError!u8 {
                return std.fmt.charToDigit(c, 16) catch error.Bad;
            }
        };
        if (h.len == 3) return .{ try hex.d(h[0]) * 17, try hex.d(h[1]) * 17, try hex.d(h[2]) * 17, 255 };
        if (h.len == 6) return .{ try hex.d(h[0]) * 16 + try hex.d(h[1]), try hex.d(h[2]) * 16 + try hex.d(h[3]), try hex.d(h[4]) * 16 + try hex.d(h[5]), 255 };
        return error.Bad;
    }
    const rgba = std.ascii.startsWithIgnoreCase(t, "rgba(");
    if (!rgba and !std.ascii.startsWithIgnoreCase(t, "rgb(")) return error.Bad;
    if (t[t.len - 1] != ')') return error.Bad;
    var out: Color = .{ 0, 0, 0, 255 };
    var it = std.mem.splitScalar(u8, t[(if (rgba) 5 else 4) .. t.len - 1], ',');
    const n: usize = if (rgba) 4 else 3;
    for (0..n) |i| {
        const c = std.mem.trim(u8, it.next() orelse return error.Bad, " \t");
        const v: f32 = if (std.mem.endsWith(u8, c, "%")) try num(c[0 .. c.len - 1]) * 255 / 100 else try num(c);
        out[i] = @intFromFloat(@round(std.math.clamp(v, 0, 255)));
    }
    if (it.next() != null) return error.Bad;
    return out;
}

// ---- normalized values (§7.5.2.4.3.2) -----------------------------------------------------------------------

fn fmtLen(w: *std.Io.Writer, l: Len, base: f32) !void {
    try w.print("{d}px", .{@as(i64, @intFromFloat(@round(l.resolve(base))))});
}

fn fmtColor(w: *std.Io.Writer, c: Color) !void {
    try w.print("rgba({d},{d},{d},{d})", .{ c[0], c[1], c[2], c[3] });
}

fn fmtBorder(w: *std.Io.Writer, b: Border, color: Color) !void {
    try fmtColor(w, b.color orelse color);
    try w.print(" {s} {d}px", .{ @tagName(b.style), @as(i64, @intFromFloat(@round(b.width))) });
}

/// The normalized string of property `p` (lengths in percent resolved against `pct_base` where known, else
/// written as specified).
pub fn format(w: *std.Io.Writer, s: *const Style, p: Prop, pct_base: f32) !void {
    switch (p) {
        .anchor => try w.writeAll(@tagName(s.anchor)),
        .backgroundColor => try fmtColor(w, s.backgroundColor),
        .color => try fmtColor(w, s.color),
        .backgroundFrame => try w.print("{d}", .{s.backgroundFrame}),
        .backgroundImage => for (s.backgroundImage, 0..) |u, i| {
            if (i > 0) try w.writeByte(' ');
            try w.print("url('{s}')", .{u});
        },
        .backgroundPositionHorizontal => try fmtLen(w, s.backgroundPositionHorizontal, pct_base),
        .backgroundPositionVertical => try fmtLen(w, s.backgroundPositionVertical, pct_base),
        .backgroundRepeat => try w.writeAll(if (s.backgroundRepeat) "repeat" else "no-repeat"),
        .blockProgressionDimension, .height, .inlineProgressionDimension, .width, .x, .y, .textAltitude, .textDepth => {
            const l: ?Len = switch (p) {
                .blockProgressionDimension => s.blockProgressionDimension,
                .height => s.height,
                .inlineProgressionDimension => s.inlineProgressionDimension,
                .width => s.width,
                .x => s.x,
                .y => s.y,
                .textAltitude => s.textAltitude,
                else => s.textDepth,
            };
            if (l) |v| try fmtLen(w, v, pct_base) else try w.writeAll("auto");
        },
        .border => {
            for (s.borders[1..]) |b| if (!std.meta.eql(b, s.borders[0])) return;
            try fmtBorder(w, s.borders[0], s.color);
        },
        .borderBefore => try fmtBorder(w, s.borders[0], s.color),
        .borderEnd => try fmtBorder(w, s.borders[1], s.color),
        .borderAfter => try fmtBorder(w, s.borders[2], s.color),
        .borderStart => try fmtBorder(w, s.borders[3], s.color),
        .breakAfter => try w.writeAll(if (s.breakAfter) "line" else "auto"),
        .breakBefore => try w.writeAll(if (s.breakBefore) "line" else "auto"),
        .contentWidth, .contentHeight => switch (if (p == .contentWidth) s.contentWidth else s.contentHeight) {
            .auto => try w.writeAll("auto"),
            .scale_to_fit => try w.writeAll("scale-to-fit"),
            .len => |l| try fmtLen(w, l, pct_base),
        },
        .crop => if (s.crop) |c| try w.print("{d} {d} {d} {d}", .{ c[0], c[1], c[2], c[3] }) else try w.writeAll("auto"),
        .direction => try w.writeAll(if (s.rtl) "rtl" else "ltr"),
        .display => try w.writeAll(if (s.display) "auto" else "none"),
        .displayAlign => try w.writeAll(@tagName(s.displayAlign)),
        .endIndent => try fmtLen(w, s.endIndent, pct_base),
        .startIndent => try fmtLen(w, s.startIndent, pct_base),
        .textIndent => try fmtLen(w, s.textIndent, pct_base),
        .flip => try w.writeAll(@tagName(s.flip)),
        .font => {
            try w.writeAll(s.font.uri);
            if (s.font.name.len > 0) try w.print(" '{s}'", .{s.font.name});
        },
        .fontSize => if (s.fontSize[0] == s.fontSize[1])
            try w.print("{d}px", .{@as(i64, @intFromFloat(@round(s.fontSize[0])))})
        else
            try w.print("{d}px {d}px", .{ @as(i64, @intFromFloat(@round(s.fontSize[0]))), @as(i64, @intFromFloat(@round(s.fontSize[1]))) }),
        .fontStyle => try w.writeAll(@tagName(s.fontStyle)),
        .linefeedTreatment => try w.writeAll(@tagName(s.linefeedTreatment)),
        .lineHeight => if (s.lineHeight) |v| try w.print("{d}px", .{@as(i64, @intFromFloat(@round(v)))}) else try w.writeAll("auto"),
        .navDown, .navLeft, .navLeftDown, .navLeftUp, .navRight, .navRightDown, .navRightUp, .navUp => {
            if (s.nav[@backingInt(navDir(p).?)]) |n| {
                if (n.elem.len == 0) return w.writeAll("none");
                if (n.app.len > 0) try w.print("{s}#", .{n.app});
                try w.writeAll(n.elem);
            } else try w.writeAll("none");
        },
        .navIndex => switch (s.navIndex) {
            .auto => try w.writeAll("auto"),
            .none => try w.writeAll("none"),
            .pair => |v| try w.print("{d} {d}", .{ v[0], v[1] }),
        },
        .opacity => try w.print("{d}", .{s.opacity}),
        .padding => for (s.padding, 0..) |l, i| {
            if (i > 0) try w.writeByte(' ');
            try fmtLen(w, l, pct_base);
        },
        .paddingBefore => try fmtLen(w, s.padding[0], pct_base),
        .paddingEnd => try fmtLen(w, s.padding[1], pct_base),
        .paddingAfter => try fmtLen(w, s.padding[2], pct_base),
        .paddingStart => try fmtLen(w, s.padding[3], pct_base),
        .position => try w.writeAll(@tagName(s.position)),
        .scaling => try w.writeAll(if (s.uniform) "uniform" else "non-uniform"),
        .suppressAtLineBreak => try w.writeAll(@tagName(s.suppressAtLineBreak)),
        .textAlign => try w.writeAll(@tagName(s.textAlign)),
        .visibility => try w.writeAll(if (s.visible) "visible" else "hidden"),
        .whiteSpaceCollapse => try w.writeAll(if (s.whiteSpaceCollapse) "true" else "false"),
        .whiteSpaceTreatment => try w.writeAll(@tagName(s.whiteSpaceTreatment)),
        .wrapOption => try w.writeAll(if (s.wrap) "wrap" else "no-wrap"),
        .writingMode => try w.writeAll(@tagName(s.writingMode)),
        .zIndex => if (s.zIndex) |z| try w.print("{d}", .{z}) else try w.writeAll("0"),
    }
}

// ---- tests --------------------------------------------------------------------------------------------------

const testing = std.testing;

fn fmtTest(s: *const Style, p: Prop) ![]u8 {
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    errdefer buf.deinit();
    try format(&buf.writer, s, p, 100);
    return buf.toOwnedSlice();
}

test "colours" {
    try testing.expectEqual(Color{ 255, 0, 0, 255 }, try parseColor("red"));
    try testing.expectEqual(Color{ 255, 255, 255, 255 }, try parseColor("White"));
    try testing.expectEqual(Color{ 0x11, 0x22, 0x33, 255 }, try parseColor("#123"));
    try testing.expectEqual(Color{ 0xab, 0xcd, 0xef, 255 }, try parseColor("#ABCDEF"));
    try testing.expectEqual(Color{ 10, 20, 30, 255 }, try parseColor("rgb(10, 20,30)"));
    try testing.expectEqual(Color{ 255, 128, 0, 128 }, try parseColor("rgba(100%,128,0,128)"));
    try testing.expectEqual(Color{ 0, 0, 0, 0 }, try parseColor("transparent"));
    try testing.expectError(error.Bad, parseColor("rgba(1,2,3)"));
    try testing.expectError(error.Bad, parseColor("#12"));
}

test "applying, inheriting, normalized values" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const root = Style.initial(1080);
    var parent = root;
    const env0: Env = .{ .parent = &root, .aperture_h = 1080, .arena = arena.allocator() };
    try testing.expect(apply(&parent, .fontSize, "32px 48px", env0));
    try testing.expect(apply(&parent, .color, "red", env0));
    try testing.expect(apply(&parent, .backgroundColor, "blue", env0));

    var s = Style.initial(1080);
    s.inherit(&parent);
    const env: Env = .{ .parent = &parent, .aperture_h = 1080, .arena = arena.allocator() };
    try testing.expectEqual(Color{ 255, 0, 0, 255 }, s.color); // inherited
    try testing.expectEqual(Color{ 0, 0, 0, 0 }, s.backgroundColor); // not inherited
    try testing.expect(apply(&s, .backgroundColor, "inherit", env));
    try testing.expectEqual(Color{ 0, 0, 255, 255 }, s.backgroundColor);
    // em is the block font size.
    try testing.expect(apply(&s, .width, "2em", env));
    try testing.expectEqual(@as(f32, 96), s.width.?.v);
    try testing.expect(apply(&s, .x, "50%", env));
    try testing.expectEqual(Unit.pct, s.x.?.unit);
    try testing.expect(apply(&s, .fontSize, "150%", env));
    try testing.expectEqual([2]f32{ 48, 72 }, s.fontSize);
    try testing.expect(apply(&s, .fontSize, "small", env));
    try testing.expectEqual([2]f32{ 51, 51 }, s.fontSize);
    try testing.expect(!apply(&s, .opacity, "half", env));
    try testing.expect(apply(&s, .opacity, "0.5; 1", env)); // a value list: the first one
    try testing.expectEqual(@as(f32, 0.5), s.opacity);
    try testing.expect(apply(&s, .display, "none", env));
    try testing.expect(!s.display);

    try testing.expect(apply(&s, .border, "2px solid white", env));
    try testing.expect(apply(&s, .borderAfter, "solid", env));
    const b = try fmtTest(&s, .border);
    defer testing.allocator.free(b);
    try testing.expectEqualStrings("", b); // the sides differ now
    const ba = try fmtTest(&s, .borderAfter);
    defer testing.allocator.free(ba);
    try testing.expectEqualStrings("rgba(255,0,0,255) solid 3px", ba); // default width, colour from color

    try testing.expect(apply(&s, .padding, "1px 2px 3px 4px", env));
    try testing.expectEqual(@as(f32, 4), s.padding[3].v);
    try testing.expect(apply(&s, .backgroundImage, "url('a.png') url(b.png)  url(\"c d.png\")", env));
    const bi = try fmtTest(&s, .backgroundImage);
    defer testing.allocator.free(bi);
    try testing.expectEqualStrings("url('a.png') url('b.png') url('cd.png')", bi);
    try testing.expect(apply(&s, .navRight, "menu#ok", env));
    try testing.expectEqualStrings("menu", s.nav[@backingInt(Dir.right)].?.app);
    try testing.expect(apply(&s, .navIndex, "3 4", env));
    const ni = try fmtTest(&s, .navIndex);
    defer testing.allocator.free(ni);
    try testing.expectEqualStrings("3 4", ni);
    try testing.expect(apply(&s, .crop, "0 0 10 20", env));
    try testing.expect(!apply(&s, .crop, "10 0 0 20", env));
    const x = try fmtTest(&s, .x);
    defer testing.allocator.free(x);
    try testing.expectEqualStrings("50px", x); // 50% of 100
    try testing.expectEqual(@as(?i32, null), s.zIndex);
}
