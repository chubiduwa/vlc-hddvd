//! XPath 1.0 for Advanced Content (HD DVD Vol. 3 §7.5.2.4): the expressions in markup timing and styling
//! (`begin`, `end`, `select`), `include` conditions, and the script API's evaluateXPath. The spec's
//! pathExpression is a one-step subset (`//name[...]`, `@name[...]`, primary expressions with predicates);
//! this implements the whole abbreviated XPath 1.0 syntax, which contains it, plus the spec's extensions:
//! - the name test `*:local` (any non-empty namespace);
//! - `class(object)`, `GPRM(n)`, `SPRM(n)`, `defaultNode()`;
//! - property functions `prefix:name(node?)`: an element's current property value, from the host;
//! - variables, from the host.
//! No VLC dependency.

const std = @import("std");
const dom = @import("dom.zig");

pub const Error = error{ BadXPath, OutOfMemory };

/// A node in a node-set: an element (or text, document…) or one of its attributes.
pub const Item = struct {
    node: *dom.Node,
    attr: ?u32 = null,

    pub fn eql(a: Item, b: Item) bool {
        return a.node == b.node and a.attr == b.attr;
    }
};

pub const Value = union(enum) {
    nodes: []Item,
    string: []const u8,
    number: f64,
    boolean: bool,
};

/// What the host provides: variables, property functions and the extension functions' data.
pub const Host = struct {
    ctx: ?*anyopaque = null,
    /// `$name` (namespace URI and local name), or null if unbound.
    variable: ?*const fn (ctx: ?*anyopaque, ns: []const u8, local: []const u8) ?Value = null,
    /// A property function `ns:local(node)`: the current value of that property of `node`, or null if the
    /// element does not support it (the empty string).
    property: ?*const fn (ctx: ?*anyopaque, node: *dom.Node, ns: []const u8, local: []const u8, a: std.mem.Allocator) ?Value = null,
    gprm: ?*const fn (ctx: ?*anyopaque, i: u32) i64 = null,
    sprm: ?*const fn (ctx: ?*anyopaque, i: u32) i64 = null,
    /// The nodes selected by the closest timing interval begun by a path expression (defaultNode()).
    default_nodes: []const *dom.Node = &.{},
    /// defaultNode() returns a node only in `end` attributes.
    in_end: bool = false,
};

pub const Context = struct {
    node: *dom.Node,
    /// The element whose namespace declarations resolve prefixes (the one carrying the expression).
    scope: *const dom.Node,
    host: *const Host,
    position: usize = 1,
    size: usize = 1,
};

// ---- the syntax tree --------------------------------------------------------------------------------------

const Axis = enum { child, descendant, descendant_or_self, attribute, self, parent, ancestor, ancestor_or_self, following_sibling, preceding_sibling, following, preceding, namespace };

const NodeTest = union(enum) {
    /// `*`, `prefix:*`, `*:local`, `prefix:local` or `local` (prefix/local "" = any).
    name: struct { prefix: ?[]const u8, local: ?[]const u8, any_ns: bool = false },
    node,
    text,
    comment,
    pi: ?[]const u8,
};

const Step = struct {
    axis: Axis,
    test_: NodeTest,
    preds: []*Expr,
};

const Op = enum { @"or", @"and", eq, ne, lt, le, gt, ge, add, sub, mul, div, mod, @"union" };

pub const Expr = union(enum) {
    binary: struct { op: Op, a: *Expr, b: *Expr },
    neg: *Expr,
    literal: []const u8,
    number: f64,
    variable: struct { prefix: []const u8, local: []const u8 },
    call: struct { prefix: []const u8, name: []const u8, args: []*Expr },
    /// A location path, absolute or relative to the context node.
    path: struct { absolute: bool, steps: []Step },
    /// A primary expression with predicates, then optional location steps.
    filter: struct { primary: *Expr, preds: []*Expr, steps: []Step },
};

/// A compiled expression; owns its memory.
pub const XPath = struct {
    arena: std.heap.ArenaAllocator,
    root: *Expr,

    pub fn deinit(x: *XPath) void {
        x.arena.deinit();
    }

    /// Evaluates in `ctx`; strings and node-sets of the result live in `a`.
    pub fn eval(x: *const XPath, a: std.mem.Allocator, ctx: Context) Error!Value {
        var e: Eval = .{ .a = a };
        return e.expr(x.root, ctx);
    }

    /// Evaluates and converts with boolean() (begin/end and include conditions).
    pub fn evalBool(x: *const XPath, a: std.mem.Allocator, ctx: Context) Error!bool {
        return toBool(try x.eval(a, ctx));
    }
};

pub fn compile(gpa: std.mem.Allocator, src: []const u8) Error!XPath {
    var x: XPath = .{ .arena = .init(gpa), .root = undefined };
    errdefer x.arena.deinit();
    var p: Parser = .{ .a = x.arena.allocator(), .lex = .{ .s = src } };
    try p.lex.next();
    x.root = try p.orExpr();
    if (p.lex.tok != .end) return error.BadXPath;
    return x;
}

// ---- lexer ------------------------------------------------------------------------------------------------

const Tok = union(enum) {
    end,
    slash,
    dslash,
    dot,
    ddot,
    at,
    comma,
    lparen,
    rparen,
    lbracket,
    rbracket,
    pipe,
    plus,
    minus,
    eq,
    ne,
    lt,
    le,
    gt,
    ge,
    star,
    dcolon,
    dollar,
    literal: []const u8,
    number: f64,
    /// NCName, or a QName with a prefix ("p:l"), or "p:*", or "*:l".
    name: []const u8,
};

const Lexer = struct {
    s: []const u8,
    i: usize = 0,
    tok: Tok = .end,
    /// The previous token, for the disambiguation rules of XPath §3.7.
    prev: Tok = .end,

    fn isNameStart(c: u8) bool {
        return std.ascii.isAlphabetic(c) or c == '_' or c >= 0x80;
    }

    fn isNameChar(c: u8) bool {
        return isNameStart(c) or std.ascii.isDigit(c) or c == '-' or c == '.';
    }

    /// After these tokens a `*` or a name is an operator/operand rule as in XPath §3.7.
    fn operandBefore(t: Tok) bool {
        return switch (t) {
            .end, .at, .dcolon, .lparen, .lbracket, .comma, .slash, .dslash, .pipe, .plus, .minus, .eq, .ne, .lt, .le, .gt, .ge, .star, .dollar => false,
            .name => |n| !(std.mem.eql(u8, n, "and") or std.mem.eql(u8, n, "or") or std.mem.eql(u8, n, "div") or std.mem.eql(u8, n, "mod")) or true,
            else => true,
        };
    }

    fn next(l: *Lexer) Error!void {
        l.prev = l.tok;
        while (l.i < l.s.len and std.ascii.isWhitespace(l.s[l.i])) l.i += 1;
        if (l.i >= l.s.len) {
            l.tok = .end;
            return;
        }
        const c = l.s[l.i];
        const nx: u8 = if (l.i + 1 < l.s.len) l.s[l.i + 1] else 0;
        l.i += 1;
        l.tok = switch (c) {
            '/' => if (nx == '/') blk: {
                l.i += 1;
                break :blk .dslash;
            } else .slash,
            '.' => if (nx == '.') blk: {
                l.i += 1;
                break :blk .ddot;
            } else if (std.ascii.isDigit(nx)) blk: {
                l.i -= 1;
                break :blk .{ .number = l.num() };
            } else .dot,
            '@' => .at,
            ',' => .comma,
            '(' => .lparen,
            ')' => .rparen,
            '[' => .lbracket,
            ']' => .rbracket,
            '|' => .pipe,
            '+' => .plus,
            '-' => .minus,
            '=' => .eq,
            '!' => if (nx == '=') blk: {
                l.i += 1;
                break :blk .ne;
            } else return error.BadXPath,
            '<' => if (nx == '=') blk: {
                l.i += 1;
                break :blk .le;
            } else .lt,
            '>' => if (nx == '=') blk: {
                l.i += 1;
                break :blk .ge;
            } else .gt,
            '$' => .dollar,
            ':' => if (nx == ':') blk: {
                l.i += 1;
                break :blk .dcolon;
            } else return error.BadXPath,
            '"', '\'' => blk: {
                const end = std.mem.indexOfScalarPos(u8, l.s, l.i, c) orelse return error.BadXPath;
                const lit = l.s[l.i..end];
                l.i = end + 1;
                break :blk .{ .literal = lit };
            },
            '*' => blk: {
                // "*:local" is a name test (the spec's extension); otherwise a star.
                if (nx == ':' and l.i + 1 < l.s.len and isNameStart(l.s[l.i + 1]) and !operandBefore(l.prev)) {
                    const start = l.i - 1;
                    l.i += 1;
                    while (l.i < l.s.len and isNameChar(l.s[l.i])) l.i += 1;
                    break :blk .{ .name = l.s[start..l.i] };
                }
                break :blk .star;
            },
            else => blk: {
                if (std.ascii.isDigit(c)) {
                    l.i -= 1;
                    break :blk .{ .number = l.num() };
                }
                if (!isNameStart(c)) return error.BadXPath;
                const start = l.i - 1;
                while (l.i < l.s.len and isNameChar(l.s[l.i])) l.i += 1;
                // prefix:local or prefix:*
                if (l.i + 1 < l.s.len and l.s[l.i] == ':' and l.s[l.i + 1] != ':') {
                    if (l.s[l.i + 1] == '*') {
                        l.i += 2;
                    } else if (isNameStart(l.s[l.i + 1])) {
                        l.i += 1;
                        while (l.i < l.s.len and isNameChar(l.s[l.i])) l.i += 1;
                    }
                }
                break :blk .{ .name = l.s[start..l.i] };
            },
        };
    }

    fn num(l: *Lexer) f64 {
        const start = l.i;
        while (l.i < l.s.len and (std.ascii.isDigit(l.s[l.i]) or l.s[l.i] == '.')) l.i += 1;
        return std.fmt.parseFloat(f64, l.s[start..l.i]) catch std.math.nan(f64);
    }

    /// The next character that is not white space (to tell a function call from a name test).
    fn peekChar(l: *const Lexer) u8 {
        var i = l.i;
        while (i < l.s.len and std.ascii.isWhitespace(l.s[i])) i += 1;
        return if (i < l.s.len) l.s[i] else 0;
    }
};

// ---- parser -----------------------------------------------------------------------------------------------

const Parser = struct {
    a: std.mem.Allocator,
    lex: Lexer,

    fn new(p: *Parser, e: Expr) Error!*Expr {
        const x = try p.a.create(Expr);
        x.* = e;
        return x;
    }

    fn bin(p: *Parser, op: Op, a: *Expr, b: *Expr) Error!*Expr {
        return p.new(.{ .binary = .{ .op = op, .a = a, .b = b } });
    }

    /// The current token as an operator name (`and`, `or`, `div`, `mod`) where one is expected.
    fn isOp(p: *const Parser, name: []const u8) bool {
        return switch (p.lex.tok) {
            .name => |n| std.mem.eql(u8, n, name),
            else => false,
        };
    }

    fn orExpr(p: *Parser) Error!*Expr {
        var a = try p.andExpr();
        while (p.isOp("or")) {
            try p.lex.next();
            a = try p.bin(.@"or", a, try p.andExpr());
        }
        return a;
    }

    fn andExpr(p: *Parser) Error!*Expr {
        var a = try p.eqExpr();
        while (p.isOp("and")) {
            try p.lex.next();
            a = try p.bin(.@"and", a, try p.eqExpr());
        }
        return a;
    }

    fn eqExpr(p: *Parser) Error!*Expr {
        var a = try p.relExpr();
        while (true) {
            const op: Op = switch (p.lex.tok) {
                .eq => .eq,
                .ne => .ne,
                else => return a,
            };
            try p.lex.next();
            a = try p.bin(op, a, try p.relExpr());
        }
    }

    fn relExpr(p: *Parser) Error!*Expr {
        var a = try p.addExpr();
        while (true) {
            const op: Op = switch (p.lex.tok) {
                .lt => .lt,
                .le => .le,
                .gt => .gt,
                .ge => .ge,
                else => return a,
            };
            try p.lex.next();
            a = try p.bin(op, a, try p.addExpr());
        }
    }

    fn addExpr(p: *Parser) Error!*Expr {
        var a = try p.mulExpr();
        while (true) {
            const op: Op = switch (p.lex.tok) {
                .plus => .add,
                .minus => .sub,
                else => return a,
            };
            try p.lex.next();
            a = try p.bin(op, a, try p.mulExpr());
        }
    }

    fn mulExpr(p: *Parser) Error!*Expr {
        var a = try p.unaryExpr();
        while (true) {
            const op: Op = if (p.lex.tok == .star) .mul else if (p.isOp("div")) .div else if (p.isOp("mod")) .mod else return a;
            try p.lex.next();
            a = try p.bin(op, a, try p.unaryExpr());
        }
    }

    fn unaryExpr(p: *Parser) Error!*Expr {
        if (p.lex.tok == .minus) {
            try p.lex.next();
            return p.new(.{ .neg = try p.unaryExpr() });
        }
        var a = try p.pathExpr();
        while (p.lex.tok == .pipe) {
            try p.lex.next();
            a = try p.bin(.@"union", a, try p.pathExpr());
        }
        return a;
    }

    fn startsPrimary(p: *const Parser) bool {
        return switch (p.lex.tok) {
            .dollar, .lparen, .literal, .number => true,
            // A function call: a name followed by "(" that is not a node type test.
            .name => |n| p.lex.peekChar() == '(' and !isNodeType(n),
            else => false,
        };
    }

    fn pathExpr(p: *Parser) Error!*Expr {
        if (p.startsPrimary()) {
            const prim = try p.primary();
            var preds: std.ArrayList(*Expr) = .empty;
            while (p.lex.tok == .lbracket) try preds.append(p.a, try p.predicate());
            var steps: std.ArrayList(Step) = .empty;
            if (p.lex.tok == .slash or p.lex.tok == .dslash) try p.relPath(&steps);
            if (preds.items.len == 0 and steps.items.len == 0) return prim;
            return p.new(.{ .filter = .{ .primary = prim, .preds = preds.items, .steps = steps.items } });
        }
        var steps: std.ArrayList(Step) = .empty;
        var absolute = false;
        switch (p.lex.tok) {
            .slash => {
                absolute = true;
                try p.lex.next();
                // "/" alone selects the root.
                if (!p.startsStep()) return p.new(.{ .path = .{ .absolute = true, .steps = &.{} } });
                try steps.append(p.a, try p.step());
            },
            .dslash => {
                absolute = true;
                try p.lex.next();
                try steps.append(p.a, .{ .axis = .descendant_or_self, .test_ = .node, .preds = &.{} });
                try steps.append(p.a, try p.step());
            },
            else => {
                const st = try p.step();
                // "*:local" stands for //*[namespace-uri()!='' and local-name()='local'] (§7.5.2.4, Note 1).
                if (st.axis == .child and st.test_ == .name and st.test_.name.any_ns) {
                    absolute = true;
                    try steps.append(p.a, .{ .axis = .descendant_or_self, .test_ = .node, .preds = &.{} });
                }
                try steps.append(p.a, st);
            },
        }
        if (p.lex.tok == .slash or p.lex.tok == .dslash) try p.relPath(&steps);
        return p.new(.{ .path = .{ .absolute = absolute, .steps = steps.items } });
    }

    fn startsStep(p: *const Parser) bool {
        return switch (p.lex.tok) {
            .dot, .ddot, .at, .star, .name => true,
            else => false,
        };
    }

    /// Further steps after "/" or "//".
    fn relPath(p: *Parser, steps: *std.ArrayList(Step)) Error!void {
        while (true) {
            switch (p.lex.tok) {
                .slash => try p.lex.next(),
                .dslash => {
                    try p.lex.next();
                    try steps.append(p.a, .{ .axis = .descendant_or_self, .test_ = .node, .preds = &.{} });
                },
                else => return,
            }
            try steps.append(p.a, try p.step());
        }
    }

    fn step(p: *Parser) Error!Step {
        switch (p.lex.tok) {
            .dot => {
                try p.lex.next();
                return .{ .axis = .self, .test_ = .node, .preds = &.{} };
            },
            .ddot => {
                try p.lex.next();
                return .{ .axis = .parent, .test_ = .node, .preds = &.{} };
            },
            else => {},
        }
        var axis: Axis = .child;
        if (p.lex.tok == .at) {
            axis = .attribute;
            try p.lex.next();
        } else if (p.lex.tok == .name and p.lex.peekChar() == ':' and p.lex.i + 1 < p.lex.s.len) {
            // axis::
            const n = p.lex.tok.name;
            if (axisOf(n)) |ax| {
                try p.lex.next();
                if (p.lex.tok != .dcolon) return error.BadXPath;
                axis = ax;
                try p.lex.next();
            }
        }
        const t = try p.nodeTest();
        var preds: std.ArrayList(*Expr) = .empty;
        while (p.lex.tok == .lbracket) try preds.append(p.a, try p.predicate());
        return .{ .axis = axis, .test_ = t, .preds = preds.items };
    }

    fn nodeTest(p: *Parser) Error!NodeTest {
        switch (p.lex.tok) {
            .star => {
                try p.lex.next();
                return .{ .name = .{ .prefix = null, .local = null } };
            },
            .name => |n| {
                try p.lex.next();
                if (isNodeType(n) and p.lex.tok == .lparen) {
                    try p.lex.next();
                    var target: ?[]const u8 = null;
                    if (p.lex.tok == .literal) {
                        target = p.lex.tok.literal;
                        try p.lex.next();
                    }
                    if (p.lex.tok != .rparen) return error.BadXPath;
                    try p.lex.next();
                    if (std.mem.eql(u8, n, "node")) return .node;
                    if (std.mem.eql(u8, n, "text")) return .text;
                    if (std.mem.eql(u8, n, "comment")) return .comment;
                    return .{ .pi = target };
                }
                if (std.mem.startsWith(u8, n, "*:")) return .{ .name = .{ .prefix = null, .local = n[2..], .any_ns = true } };
                if (std.mem.indexOfScalar(u8, n, ':')) |c| {
                    const local = n[c + 1 ..];
                    return .{ .name = .{ .prefix = n[0..c], .local = if (std.mem.eql(u8, local, "*")) null else local } };
                }
                return .{ .name = .{ .prefix = "", .local = n } };
            },
            else => return error.BadXPath,
        }
    }

    fn predicate(p: *Parser) Error!*Expr {
        try p.lex.next(); // [
        const e = try p.orExpr();
        if (p.lex.tok != .rbracket) return error.BadXPath;
        try p.lex.next();
        return e;
    }

    fn primary(p: *Parser) Error!*Expr {
        switch (p.lex.tok) {
            .dollar => {
                try p.lex.next();
                const n = switch (p.lex.tok) {
                    .name => |n| n,
                    else => return error.BadXPath,
                };
                try p.lex.next();
                const c = std.mem.indexOfScalar(u8, n, ':');
                return p.new(.{ .variable = .{ .prefix = if (c) |i| n[0..i] else "", .local = if (c) |i| n[i + 1 ..] else n } });
            },
            .lparen => {
                try p.lex.next();
                const e = try p.orExpr();
                if (p.lex.tok != .rparen) return error.BadXPath;
                try p.lex.next();
                return e;
            },
            .literal => |s| {
                try p.lex.next();
                return p.new(.{ .literal = s });
            },
            .number => |v| {
                try p.lex.next();
                return p.new(.{ .number = v });
            },
            .name => |n| {
                try p.lex.next();
                try p.lex.next(); // (
                var args: std.ArrayList(*Expr) = .empty;
                if (p.lex.tok != .rparen) {
                    while (true) {
                        try args.append(p.a, try p.orExpr());
                        if (p.lex.tok == .comma) {
                            try p.lex.next();
                            continue;
                        }
                        break;
                    }
                }
                if (p.lex.tok != .rparen) return error.BadXPath;
                try p.lex.next();
                const c = std.mem.indexOfScalar(u8, n, ':');
                return p.new(.{ .call = .{ .prefix = if (c) |i| n[0..i] else "", .name = if (c) |i| n[i + 1 ..] else n, .args = args.items } });
            },
            else => return error.BadXPath,
        }
    }
};

fn isNodeType(n: []const u8) bool {
    return std.mem.eql(u8, n, "node") or std.mem.eql(u8, n, "text") or std.mem.eql(u8, n, "comment") or std.mem.eql(u8, n, "processing-instruction");
}

fn axisOf(n: []const u8) ?Axis {
    const table = .{
        .{ "child", Axis.child },                           .{ "descendant", Axis.descendant },
        .{ "descendant-or-self", Axis.descendant_or_self }, .{ "attribute", Axis.attribute },
        .{ "self", Axis.self },                             .{ "parent", Axis.parent },
        .{ "ancestor", Axis.ancestor },                     .{ "ancestor-or-self", Axis.ancestor_or_self },
        .{ "following-sibling", Axis.following_sibling },   .{ "preceding-sibling", Axis.preceding_sibling },
        .{ "following", Axis.following },                   .{ "preceding", Axis.preceding },
        .{ "namespace", Axis.namespace },
    };
    inline for (table) |e| if (std.mem.eql(u8, n, e[0])) return e[1];
    return null;
}

// ---- conversions (XPath §4) -------------------------------------------------------------------------------

pub fn itemString(a: std.mem.Allocator, it: Item) Error![]const u8 {
    if (it.attr) |i| return it.node.attrs.items[i].value;
    return switch (it.node.type) {
        .text, .cdata, .comment, .pi => it.node.data,
        else => it.node.text(a) catch return error.OutOfMemory,
    };
}

pub fn toBool(v: Value) bool {
    return switch (v) {
        .boolean => |b| b,
        .number => |n| n != 0 and !std.math.isNan(n),
        .string => |s| s.len > 0,
        .nodes => |ns| ns.len > 0,
    };
}

pub fn strToNum(s: []const u8) f64 {
    const t = std.mem.trim(u8, s, " \t\r\n");
    if (t.len == 0) return std.math.nan(f64);
    // XPath Number: digits with an optional fraction, optionally negative; nothing else (no exponent).
    var i: usize = 0;
    if (t[0] == '-') i = 1;
    var digits = false;
    while (i < t.len and std.ascii.isDigit(t[i])) : (i += 1) digits = true;
    if (i < t.len and t[i] == '.') {
        i += 1;
        while (i < t.len and std.ascii.isDigit(t[i])) : (i += 1) digits = true;
    }
    if (i != t.len or !digits) return std.math.nan(f64);
    return std.fmt.parseFloat(f64, t) catch std.math.nan(f64);
}

pub fn toNum(a: std.mem.Allocator, v: Value) Error!f64 {
    return switch (v) {
        .number => |n| n,
        .boolean => |b| if (b) 1 else 0,
        .string => |s| strToNum(s),
        .nodes => |ns| if (ns.len == 0) std.math.nan(f64) else strToNum(try itemString(a, ns[0])),
    };
}

/// A number as XPath's string() writes it: integers without a decimal point, NaN, Infinity.
pub fn numString(a: std.mem.Allocator, n: f64) Error![]const u8 {
    if (std.math.isNan(n)) return "NaN";
    if (std.math.isInf(n)) return if (n > 0) "Infinity" else "-Infinity";
    if (n == @trunc(n) and @abs(n) < 1e18) return std.fmt.allocPrint(a, "{d}", .{@as(i64, @intFromFloat(n))});
    return std.fmt.allocPrint(a, "{d}", .{n});
}

pub fn toStr(a: std.mem.Allocator, v: Value) Error![]const u8 {
    return switch (v) {
        .string => |s| s,
        .boolean => |b| if (b) "true" else "false",
        .number => |n| numString(a, n),
        .nodes => |ns| if (ns.len == 0) "" else itemString(a, ns[0]),
    };
}

// ---- evaluation -------------------------------------------------------------------------------------------

const Eval = struct {
    a: std.mem.Allocator,

    fn expr(e: *Eval, x: *const Expr, ctx: Context) Error!Value {
        return switch (x.*) {
            .literal => |s| .{ .string = s },
            .number => |n| .{ .number = n },
            .neg => |a| .{ .number = -(try toNum(e.a, try e.expr(a, ctx))) },
            .variable => |v| blk: {
                const ns = if (v.prefix.len == 0) "" else ctx.scope.lookupNamespace(v.prefix) orelse return error.BadXPath;
                const f = ctx.host.variable orelse return error.BadXPath;
                break :blk f(ctx.host.ctx, ns, v.local) orelse error.BadXPath;
            },
            .call => |c| e.call(c.prefix, c.name, c.args, ctx),
            .binary => |b| e.binary(b.op, b.a, b.b, ctx),
            .path => |p| blk: {
                var start: [1]Item = .{.{ .node = if (p.absolute) docRoot(ctx.node) else ctx.node }};
                break :blk .{ .nodes = try e.steps(&start, p.steps, ctx) };
            },
            .filter => |f| blk: {
                var v = try e.expr(f.primary, ctx);
                if (f.preds.len == 0 and f.steps.len == 0) break :blk v;
                const ns = switch (v) {
                    .nodes => |n| n,
                    else => return error.BadXPath,
                };
                var cur = ns;
                for (f.preds) |pr| cur = try e.filterPred(cur, pr, ctx);
                v = .{ .nodes = try e.steps(cur, f.steps, ctx) };
                break :blk v;
            },
        };
    }

    fn binary(e: *Eval, op: Op, xa: *const Expr, xb: *const Expr, ctx: Context) Error!Value {
        switch (op) {
            .@"or" => return .{ .boolean = toBool(try e.expr(xa, ctx)) or toBool(try e.expr(xb, ctx)) },
            .@"and" => return .{ .boolean = toBool(try e.expr(xa, ctx)) and toBool(try e.expr(xb, ctx)) },
            .@"union" => {
                const a = try e.expr(xa, ctx);
                const b = try e.expr(xb, ctx);
                if (a != .nodes or b != .nodes) return error.BadXPath;
                var all: std.ArrayList(Item) = .empty;
                try all.appendSlice(e.a, a.nodes);
                try all.appendSlice(e.a, b.nodes);
                return .{ .nodes = try e.docOrder(all.items) };
            },
            .eq, .ne, .lt, .le, .gt, .ge => return .{ .boolean = try e.compare(op, try e.expr(xa, ctx), try e.expr(xb, ctx)) },
            .add, .sub, .mul, .div, .mod => {
                const a = try toNum(e.a, try e.expr(xa, ctx));
                const b = try toNum(e.a, try e.expr(xb, ctx));
                return .{ .number = switch (op) {
                    .add => a + b,
                    .sub => a - b,
                    .mul => a * b,
                    .div => a / b,
                    else => if (b == 0) std.math.nan(f64) else @rem(a, b),
                } };
            },
        }
    }

    /// Comparisons with XPath's node-set rules (§3.4).
    fn compare(e: *Eval, op: Op, a: Value, b: Value) Error!bool {
        if (a == .nodes and b == .nodes) {
            for (a.nodes) |x| {
                const sx = try itemString(e.a, x);
                for (b.nodes) |y| if (try e.compare(op, .{ .string = sx }, .{ .string = try itemString(e.a, y) })) return true;
            }
            return false;
        }
        if (a == .nodes or b == .nodes) {
            const ns = if (a == .nodes) a.nodes else b.nodes;
            const other = if (a == .nodes) b else a;
            if (other == .boolean) {
                const nb = ns.len > 0;
                return e.compare(op, if (a == .nodes) .{ .boolean = nb } else other, if (a == .nodes) other else .{ .boolean = nb });
            }
            for (ns) |it| {
                const s = try itemString(e.a, it);
                const conv: Value = if (other == .number) .{ .number = strToNum(s) } else .{ .string = s };
                if (try e.compare(op, if (a == .nodes) conv else other, if (a == .nodes) other else conv)) return true;
            }
            return false;
        }
        switch (op) {
            .eq, .ne => {
                const eq = if (a == .boolean or b == .boolean)
                    toBool(a) == toBool(b)
                else if (a == .number or b == .number)
                    (try toNum(e.a, a)) == (try toNum(e.a, b))
                else
                    std.mem.eql(u8, try toStr(e.a, a), try toStr(e.a, b));
                return if (op == .eq) eq else !eq;
            },
            else => {
                const x = try toNum(e.a, a);
                const y = try toNum(e.a, b);
                return switch (op) {
                    .lt => x < y,
                    .le => x <= y,
                    .gt => x > y,
                    else => x >= y,
                };
            },
        }
    }

    fn steps(e: *Eval, start: []Item, ss: []const Step, ctx: Context) Error![]Item {
        var cur = start;
        for (ss) |st| {
            var out: std.ArrayList(Item) = .empty;
            for (cur) |it| {
                var found: std.ArrayList(Item) = .empty;
                try e.axis(it, st, ctx, &found);
                var sel = found.items;
                for (st.preds) |pr| sel = try e.filterPred(sel, pr, ctx);
                try out.appendSlice(e.a, sel);
            }
            cur = if (ss.len > 1 or cur.len > 1) try e.docOrder(out.items) else out.items;
        }
        return cur;
    }

    /// Keeps the items for which the predicate holds (a number: the position).
    fn filterPred(e: *Eval, items: []Item, pred: *const Expr, ctx: Context) Error![]Item {
        var out: std.ArrayList(Item) = .empty;
        for (items, 1..) |it, pos| {
            var c = ctx;
            c.node = it.node;
            c.position = pos;
            c.size = items.len;
            const v = try e.expr(pred, c);
            const keep = switch (v) {
                .number => |n| n == @as(f64, @floatFromInt(pos)),
                else => toBool(v),
            };
            if (keep) try out.append(e.a, it);
        }
        return out.items;
    }

    fn matches(t: NodeTest, n: *const dom.Node, ctx: Context, attr: ?*const dom.Attr) bool {
        switch (t) {
            .node => return true,
            .text => return attr == null and (n.type == .text or n.type == .cdata),
            .comment => return attr == null and n.type == .comment,
            .pi => |target| return attr == null and n.type == .pi and (target == null or std.mem.eql(u8, n.local, target.?)),
            .name => |nt| {
                const ns: []const u8 = if (attr) |a| a.ns else n.ns;
                const local: []const u8 = if (attr) |a| a.local else n.local;
                if (attr == null and n.type != .element) return false;
                if (nt.any_ns) return ns.len > 0 and std.mem.eql(u8, local, nt.local.?);
                if (nt.local) |l| if (!std.mem.eql(u8, l, local)) return false;
                const prefix = nt.prefix orelse return true; // "*"
                if (prefix.len == 0) {
                    // An unprefixed name test matches no namespace; leniently, for elements, the default one too
                    // (markup pages put their elements in the default namespace and test them unprefixed).
                    if (attr != null) return ns.len == 0;
                    return ns.len == 0 or std.mem.eql(u8, ns, ctx.scope.lookupNamespace("") orelse "");
                }
                const want = ctx.scope.lookupNamespace(prefix) orelse return false;
                return std.mem.eql(u8, ns, want);
            },
        }
    }

    fn axis(e: *Eval, it: Item, st: Step, ctx: Context, out: *std.ArrayList(Item)) Error!void {
        const n = it.node;
        if (it.attr != null) {
            // An attribute's only axes are self, parent and ancestors.
            switch (st.axis) {
                .self => if (matches(st.test_, n, ctx, &n.attrs.items[it.attr.?])) try out.append(e.a, it),
                .parent, .ancestor, .ancestor_or_self => {
                    if (st.axis == .ancestor_or_self and matches(st.test_, n, ctx, &n.attrs.items[it.attr.?])) try out.append(e.a, it);
                    var p: ?*dom.Node = n;
                    while (p) |x| : (p = if (st.axis == .parent) null else x.parent) if (matches(st.test_, x, ctx, null)) try out.append(e.a, .{ .node = x });
                },
                else => {},
            }
            return;
        }
        switch (st.axis) {
            .self => if (matches(st.test_, n, ctx, null)) try out.append(e.a, it),
            .child => {
                var c = n.first;
                while (c) |x| : (c = x.next) if (matches(st.test_, x, ctx, null)) try out.append(e.a, .{ .node = x });
            },
            .descendant, .descendant_or_self => {
                if (st.axis == .descendant_or_self and matches(st.test_, n, ctx, null)) try out.append(e.a, it);
                var c = n.first;
                while (c) |x| {
                    if (matches(st.test_, x, ctx, null)) try out.append(e.a, .{ .node = x });
                    c = nextInTree(x, n);
                }
            },
            .attribute => for (n.attrs.items, 0..) |*a, i| {
                if (std.mem.eql(u8, a.ns, dom.xmlns_ns)) continue;
                if (matches(st.test_, n, ctx, a)) try out.append(e.a, .{ .node = n, .attr = @intCast(i) });
            },
            .parent => if (n.parent) |p| if (matches(st.test_, p, ctx, null)) try out.append(e.a, .{ .node = p }),
            .ancestor, .ancestor_or_self => {
                var p: ?*dom.Node = if (st.axis == .ancestor) n.parent else n;
                while (p) |x| : (p = x.parent) if (matches(st.test_, x, ctx, null)) try out.append(e.a, .{ .node = x });
            },
            .following_sibling => {
                var c = n.next;
                while (c) |x| : (c = x.next) if (matches(st.test_, x, ctx, null)) try out.append(e.a, .{ .node = x });
            },
            .preceding_sibling => {
                var c = n.prev;
                while (c) |x| : (c = x.prev) if (matches(st.test_, x, ctx, null)) try out.append(e.a, .{ .node = x });
            },
            .following => {
                var c: ?*dom.Node = n;
                while (c) |x| {
                    if (x.next) |s| {
                        var d: ?*dom.Node = s;
                        while (d) |y| {
                            if (matches(st.test_, y, ctx, null)) try out.append(e.a, .{ .node = y });
                            d = nextInTree(y, x.parent orelse y);
                        }
                        break;
                    }
                    c = x.parent;
                }
            },
            .preceding => {
                const root = docRoot(n);
                var c: ?*dom.Node = root.first;
                while (c) |x| : (c = nextInTree(x, root)) {
                    if (x == n) break;
                    if (!x.contains(n) and matches(st.test_, x, ctx, null)) try out.append(e.a, .{ .node = x });
                }
            },
            .namespace => {},
        }
    }

    /// Sorts into document order and removes duplicates.
    fn docOrder(e: *Eval, items: []Item) Error![]Item {
        if (items.len < 2) return items;
        const root = docRoot(items[0].node);
        var order: std.AutoHashMapUnmanaged(*dom.Node, u32) = .empty;
        var i: u32 = 0;
        var c: ?*dom.Node = root;
        while (c) |x| : (c = nextInTree(x, root)) {
            try order.put(e.a, x, i);
            i += 1;
        }
        const Ctx = struct {
            o: *const std.AutoHashMapUnmanaged(*dom.Node, u32),
            fn key(s: @This(), it: Item) u64 {
                const pos: u64 = s.o.get(it.node) orelse std.math.maxInt(u32);
                return pos << 16 | (if (it.attr) |a| @as(u64, a) + 1 else 0);
            }
            fn less(s: @This(), a: Item, b: Item) bool {
                return s.key(a) < s.key(b);
            }
        };
        const cx: Ctx = .{ .o = &order };
        std.mem.sort(Item, items, cx, Ctx.less);
        var n: usize = 0;
        for (items) |it| {
            if (n > 0 and items[n - 1].eql(it)) continue;
            items[n] = it;
            n += 1;
        }
        return items[0..n];
    }

    fn arg(e: *Eval, args: []*Expr, i: usize, ctx: Context) Error!Value {
        if (i >= args.len) return error.BadXPath;
        return e.expr(args[i], ctx);
    }

    fn argStr(e: *Eval, args: []*Expr, i: usize, ctx: Context) Error![]const u8 {
        return toStr(e.a, try e.arg(args, i, ctx));
    }

    fn argNum(e: *Eval, args: []*Expr, i: usize, ctx: Context) Error!f64 {
        return toNum(e.a, try e.arg(args, i, ctx));
    }

    /// The node-set argument `i`, or the context node when it is absent.
    fn argNodeOrSelf(e: *Eval, args: []*Expr, i: usize, ctx: Context) Error!?Item {
        if (i >= args.len) return .{ .node = ctx.node };
        const v = try e.expr(args[i], ctx);
        if (v != .nodes) return error.BadXPath;
        return if (v.nodes.len > 0) v.nodes[0] else null;
    }

    fn call(e: *Eval, prefix: []const u8, name: []const u8, args: []*Expr, ctx: Context) Error!Value {
        if (prefix.len > 0) {
            // A property function: prefix:name(node?).
            const ns = ctx.scope.lookupNamespace(prefix) orelse return error.BadXPath;
            const node = (try e.argNodeOrSelf(args, 0, ctx)) orelse return .{ .string = "" };
            const f = ctx.host.property orelse return .{ .string = "" };
            return f(ctx.host.ctx, node.node, ns, name, e.a) orelse .{ .string = "" };
        }
        const eq = std.mem.eql;
        // Node-set functions.
        if (eq(u8, name, "last")) return .{ .number = @floatFromInt(ctx.size) };
        if (eq(u8, name, "position")) return .{ .number = @floatFromInt(ctx.position) };
        if (eq(u8, name, "count")) {
            const v = try e.arg(args, 0, ctx);
            if (v != .nodes) return error.BadXPath;
            return .{ .number = @floatFromInt(v.nodes.len) };
        }
        if (eq(u8, name, "id")) return .{ .nodes = try e.ids(try e.arg(args, 0, ctx), ctx) };
        if (eq(u8, name, "local-name") or eq(u8, name, "namespace-uri") or eq(u8, name, "name")) {
            const it = (try e.argNodeOrSelf(args, 0, ctx)) orelse return .{ .string = "" };
            if (it.attr) |i| {
                const a = it.node.attrs.items[i];
                return .{ .string = if (eq(u8, name, "local-name")) a.local else if (eq(u8, name, "namespace-uri")) a.ns else if (a.prefix.len > 0) try std.fmt.allocPrint(e.a, "{s}:{s}", .{ a.prefix, a.local }) else a.local };
            }
            const n = it.node;
            if (n.type != .element and n.type != .pi) return .{ .string = "" };
            return .{ .string = if (eq(u8, name, "local-name")) n.local else if (eq(u8, name, "namespace-uri")) n.ns else n.qname() };
        }
        // String functions.
        if (eq(u8, name, "string")) return .{ .string = if (args.len == 0) try itemString(e.a, .{ .node = ctx.node }) else try e.argStr(args, 0, ctx) };
        if (eq(u8, name, "concat")) {
            var out: std.ArrayList(u8) = .empty;
            for (args, 0..) |_, i| try out.appendSlice(e.a, try e.argStr(args, i, ctx));
            return .{ .string = out.items };
        }
        if (eq(u8, name, "starts-with")) return .{ .boolean = std.mem.startsWith(u8, try e.argStr(args, 0, ctx), try e.argStr(args, 1, ctx)) };
        if (eq(u8, name, "contains")) return .{ .boolean = std.mem.indexOf(u8, try e.argStr(args, 0, ctx), try e.argStr(args, 1, ctx)) != null };
        if (eq(u8, name, "substring-before") or eq(u8, name, "substring-after")) {
            const s = try e.argStr(args, 0, ctx);
            const t = try e.argStr(args, 1, ctx);
            const i = std.mem.indexOf(u8, s, t) orelse return .{ .string = "" };
            return .{ .string = if (eq(u8, name, "substring-before")) s[0..i] else s[i + t.len ..] };
        }
        if (eq(u8, name, "substring")) {
            const s = try e.argStr(args, 0, ctx);
            const cps = try codepoints(e.a, s);
            const start = @round(try e.argNum(args, 1, ctx));
            const len = if (args.len > 2) @round(try e.argNum(args, 2, ctx)) else std.math.inf(f64);
            var out: std.ArrayList(u8) = .empty;
            for (cps, 1..) |cp, pos| {
                const p: f64 = @floatFromInt(pos);
                if (p >= start and p < start + len) try appendCp(e.a, &out, cp);
            }
            return .{ .string = out.items };
        }
        if (eq(u8, name, "string-length")) {
            const s = if (args.len == 0) try itemString(e.a, .{ .node = ctx.node }) else try e.argStr(args, 0, ctx);
            return .{ .number = @floatFromInt(std.unicode.utf8CountCodepoints(s) catch s.len) };
        }
        if (eq(u8, name, "normalize-space")) {
            const s = if (args.len == 0) try itemString(e.a, .{ .node = ctx.node }) else try e.argStr(args, 0, ctx);
            var out: std.ArrayList(u8) = .empty;
            var it = std.mem.tokenizeAny(u8, s, " \t\r\n");
            while (it.next()) |w| {
                if (out.items.len > 0) try out.append(e.a, ' ');
                try out.appendSlice(e.a, w);
            }
            return .{ .string = out.items };
        }
        if (eq(u8, name, "translate")) {
            const s = try codepoints(e.a, try e.argStr(args, 0, ctx));
            const from = try codepoints(e.a, try e.argStr(args, 1, ctx));
            const to = try codepoints(e.a, try e.argStr(args, 2, ctx));
            var out: std.ArrayList(u8) = .empty;
            for (s) |cp| {
                if (std.mem.indexOfScalar(u21, from, cp)) |i| {
                    if (i < to.len) try appendCp(e.a, &out, to[i]);
                } else try appendCp(e.a, &out, cp);
            }
            return .{ .string = out.items };
        }
        // Boolean functions.
        if (eq(u8, name, "boolean")) return .{ .boolean = toBool(try e.arg(args, 0, ctx)) };
        if (eq(u8, name, "not")) return .{ .boolean = !toBool(try e.arg(args, 0, ctx)) };
        if (eq(u8, name, "true")) return .{ .boolean = true };
        if (eq(u8, name, "false")) return .{ .boolean = false };
        if (eq(u8, name, "lang")) {
            const want = try e.argStr(args, 0, ctx);
            var p: ?*dom.Node = ctx.node;
            while (p) |x| : (p = x.parent) {
                const l = x.attrNS(dom.xml_ns, "lang") orelse continue;
                return .{ .boolean = std.ascii.eqlIgnoreCase(l, want) or (l.len > want.len and l[want.len] == '-' and std.ascii.eqlIgnoreCase(l[0..want.len], want)) };
            }
            return .{ .boolean = false };
        }
        // Number functions.
        if (eq(u8, name, "number")) return .{ .number = if (args.len == 0) strToNum(try itemString(e.a, .{ .node = ctx.node })) else try e.argNum(args, 0, ctx) };
        if (eq(u8, name, "sum")) {
            const v = try e.arg(args, 0, ctx);
            if (v != .nodes) return error.BadXPath;
            var s: f64 = 0;
            for (v.nodes) |it| s += strToNum(try itemString(e.a, it));
            return .{ .number = s };
        }
        if (eq(u8, name, "floor")) return .{ .number = @floor(try e.argNum(args, 0, ctx)) };
        if (eq(u8, name, "ceiling")) return .{ .number = @ceil(try e.argNum(args, 0, ctx)) };
        if (eq(u8, name, "round")) return .{ .number = @floor(try e.argNum(args, 0, ctx) + 0.5) };
        // Extensions (§7.5.2.4.2).
        if (eq(u8, name, "class")) return .{ .nodes = try e.classes(try e.argStr(args, 0, ctx), ctx) };
        if (eq(u8, name, "GPRM") or eq(u8, name, "SPRM")) {
            const n = try e.argNum(args, 0, ctx);
            const max: f64 = if (eq(u8, name, "GPRM")) 63 else 31;
            if (std.math.isNan(n) or n < 0 or n > max) return .{ .number = -1 };
            const f = (if (eq(u8, name, "GPRM")) ctx.host.gprm else ctx.host.sprm) orelse return .{ .number = 0 };
            return .{ .number = @floatFromInt(f(ctx.host.ctx, @intFromFloat(n))) };
        }
        if (eq(u8, name, "defaultNode")) {
            if (!ctx.host.in_end or ctx.host.default_nodes.len == 0) return .{ .nodes = &.{} };
            const out = try e.a.alloc(Item, 1);
            out[0] = .{ .node = ctx.host.default_nodes[0] };
            return .{ .nodes = out };
        }
        return error.BadXPath;
    }

    /// id(): elements whose id is one of the tokens (from a string, or each node's string value).
    fn ids(e: *Eval, v: Value, ctx: Context) Error![]Item {
        var tokens: std.ArrayList([]const u8) = .empty;
        switch (v) {
            .nodes => |ns| for (ns) |it| try tokens.append(e.a, try itemString(e.a, it)),
            else => try tokens.append(e.a, try toStr(e.a, v)),
        }
        const doc = ctx.node.doc;
        if (!idAllowed(doc.uri)) return &.{};
        var out: std.ArrayList(Item) = .empty;
        for (tokens.items) |t| {
            var it = std.mem.tokenizeAny(u8, t, " \t\r\n");
            while (it.next()) |id| if (doc.getElementById(id)) |n| try out.append(e.a, .{ .node = n });
        }
        return e.docOrder(out.items);
    }

    /// class(): the elements of the context document whose class attribute has one of the tokens.
    fn classes(e: *Eval, s: []const u8, ctx: Context) Error![]Item {
        var out: std.ArrayList(Item) = .empty;
        const root = docRoot(ctx.node);
        var c: ?*dom.Node = root;
        while (c) |x| : (c = nextInTree(x, root)) {
            if (x.type != .element) continue;
            const cls = x.attr("class") orelse continue;
            var want = std.mem.tokenizeAny(u8, s, " \t\r\n");
            const hit = while (want.next()) |w| {
                var have = std.mem.tokenizeAny(u8, cls, " \t\r\n");
                if (while (have.next()) |h| {
                    if (std.mem.eql(u8, h, w)) break true;
                } else false) break true;
            } else false;
            if (hit) try out.append(e.a, .{ .node = x });
        }
        return out.items;
    }
};

/// id() works only in documents with these suffixes, all lower or all upper case (§7.5.2.4.2). A document
/// with no URI (built in memory) allows it.
fn idAllowed(uri: []const u8) bool {
    if (uri.len == 0) return true;
    const dot = std.mem.lastIndexOfScalar(u8, uri, '.') orelse return false;
    const ext = uri[dot + 1 ..];
    for ([_][]const u8{ "xpl", "xmf", "xmu", "xas", "xss", "xts" }) |x| {
        if (std.mem.eql(u8, ext, x)) return true;
        var up: [3]u8 = undefined;
        if (ext.len == 3 and std.mem.eql(u8, ext, std.ascii.upperString(&up, x))) return true;
    }
    return false;
}

fn docRoot(n: *dom.Node) *dom.Node {
    var r = n;
    while (r.parent) |p| r = p;
    return r;
}

/// The next node after `n` in document order within `root`'s subtree, or null.
fn nextInTree(n: *dom.Node, root: *const dom.Node) ?*dom.Node {
    if (n.first) |c| return c;
    var x = n;
    while (x != root) {
        if (x.next) |s| return s;
        x = x.parent orelse return null;
    }
    return null;
}

fn codepoints(a: std.mem.Allocator, s: []const u8) Error![]u21 {
    var out: std.ArrayList(u21) = .empty;
    var it = (std.unicode.Utf8View.init(s) catch return error.BadXPath).iterator();
    while (it.nextCodepoint()) |cp| try out.append(a, cp);
    return out.items;
}

fn appendCp(a: std.mem.Allocator, out: *std.ArrayList(u8), cp: u21) Error!void {
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &buf) catch return error.BadXPath;
    try out.appendSlice(a, buf[0..n]);
}

// ---- tests --------------------------------------------------------------------------------------------------

const testing = std.testing;

const test_page =
    \\<root xmlns="http://www.dvdforum.org/2005/ihd" xmlns:style="http://www.dvdforum.org/2005/ihd#style"
    \\      xmlns:state="http://www.dvdforum.org/2005/ihd#state" xml:lang="en">
    \\ <body id="b">
    \\  <div id="d1" class="menu big" style:x="10px">
    \\   <button id="b1" state:focused="true"/>
    \\   <button id="b2" class="big"/>
    \\  </div>
    \\  <div id="d2"><p>Hello <span>world</span></p></div>
    \\ </body>
    \\</root>
;

fn run(src: []const u8, doc: *dom.Document, host: *const Host) !Value {
    var x = try compile(testing.allocator, src);
    defer x.deinit();
    const body = doc.getElementById("b").?;
    return x.eval(test_arena.allocator(), .{ .node = body, .scope = body, .host = host });
}

var test_arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);

fn ids_of(v: Value) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (v.nodes) |it| {
        if (out.items.len > 0) try out.append(test_arena.allocator(), ',');
        try out.appendSlice(test_arena.allocator(), it.node.attr("id") orelse "?");
    }
    return out.items;
}

test "paths, predicates and the spec's forms" {
    defer _ = test_arena.reset(.free_all);
    const doc = try dom.parse(testing.allocator, test_page, null);
    defer doc.destroy();
    const h: Host = .{};
    try testing.expectEqualStrings("b1,b2", try ids_of(try run("//button", doc, &h)));
    try testing.expectEqualStrings("d1,b2", try ids_of(try run("class('big')", doc, &h)));
    try testing.expectEqualStrings("b2", try ids_of(try run("class('big')[2]", doc, &h)));
    try testing.expectEqualStrings("b1,b2", try ids_of(try run("*:button", doc, &h)));
    try testing.expectEqualStrings("d1", try ids_of(try run("//div[@style:x='10px']", doc, &h)));
    try testing.expectEqualStrings("b1", try ids_of(try run("//button[@state:focused='true']", doc, &h)));
    try testing.expectEqualStrings("d2", try ids_of(try run("//div[last()]", doc, &h)));
    try testing.expectEqualStrings("d1,d2", try ids_of(try run("div", doc, &h)));
    try testing.expectEqualStrings("b1,b2,d2", try ids_of(try run("//div[2] | //button", doc, &h)));
    try testing.expectEqualStrings("b2", try ids_of(try run("id('b2')", doc, &h)));
    try testing.expectEqualStrings("d1", try ids_of(try run("//button/..", doc, &h)));
    try testing.expectEqual(@as(f64, 3), (try run("count(div/*)", doc, &h)).number);
    try testing.expectEqualStrings("Hello world", (try run("string(//p)", doc, &h)).string);
}

test "values, comparisons and functions" {
    defer _ = test_arena.reset(.free_all);
    const doc = try dom.parse(testing.allocator, test_page, null);
    defer doc.destroy();
    const h: Host = .{};
    try testing.expectEqual(@as(f64, 7), (try run("1 + 2 * 3", doc, &h)).number);
    try testing.expectEqual(@as(f64, 1), (try run("7 mod 3", doc, &h)).number);
    try testing.expectEqual(@as(f64, -2.5), (try run("-5 div 2", doc, &h)).number);
    try testing.expect((try run("2 > 1 and not(false())", doc, &h)).boolean);
    try testing.expect((try run("'10' = 10.0", doc, &h)).boolean);
    try testing.expect((try run("//button/@id = 'b2'", doc, &h)).boolean); // node-set = string: any
    try testing.expect(!(try run("//button/@id != 'b2' and false()", doc, &h)).boolean);
    try testing.expectEqualStrings("ell", (try run("substring('Hello', 2, 3)", doc, &h)).string);
    try testing.expectEqualStrings("a b", (try run("normalize-space('  a   b ')", doc, &h)).string);
    try testing.expectEqualStrings("BAr", (try run("translate('bar', 'ab', 'AB')", doc, &h)).string);
    try testing.expectEqualStrings("1", try toStr(test_arena.allocator(), try run("round(0.5)", doc, &h)));
    try testing.expectEqualStrings("NaN", try toStr(test_arena.allocator(), try run("number('x')", doc, &h)));
    try testing.expectEqualStrings("0.5", try toStr(test_arena.allocator(), try run("1 div 2", doc, &h)));
    try testing.expect((try run("lang('EN')", doc, &h)).boolean);
    try testing.expectError(error.BadXPath, compile(testing.allocator, "//button["));
    try testing.expectError(error.BadXPath, run("nosuch()", doc, &h));
}

const TestHost = struct {
    fn variable(_: ?*anyopaque, ns: []const u8, local: []const u8) ?Value {
        _ = ns;
        if (std.mem.eql(u8, local, "menuLanguage")) return .{ .string = "en" };
        return null;
    }
    fn property(_: ?*anyopaque, node: *dom.Node, ns: []const u8, local: []const u8, _: std.mem.Allocator) ?Value {
        if (!std.mem.eql(u8, ns, "http://www.dvdforum.org/2005/ihd#state")) return null;
        if (std.mem.eql(u8, local, "focused")) return .{ .boolean = std.mem.eql(u8, node.attr("id") orelse "", "b1") };
        return null;
    }
    fn gprm(_: ?*anyopaque, i: u32) i64 {
        return @as(i64, i) * 10;
    }
};

test "host: variables, property functions, GPRM, defaultNode" {
    defer _ = test_arena.reset(.free_all);
    const doc = try dom.parse(testing.allocator, test_page, null);
    defer doc.destroy();
    var h: Host = .{ .variable = TestHost.variable, .property = TestHost.property, .gprm = TestHost.gprm };
    try testing.expect((try run("$menuLanguage = 'en'", doc, &h)).boolean);
    try testing.expectError(error.BadXPath, run("$nope", doc, &h));
    try testing.expectEqualStrings("b1", try ids_of(try run("//button[state:focused()=true()]", doc, &h)));
    try testing.expectEqualStrings("", (try run("style:color()", doc, &h)).string);
    try testing.expectEqual(@as(f64, 30), (try run("GPRM(3)", doc, &h)).number);
    try testing.expectEqual(@as(f64, -1), (try run("GPRM(64)", doc, &h)).number);
    try testing.expectEqual(0, (try run("defaultNode()", doc, &h)).nodes.len);
    const b2 = doc.getElementById("b2").?;
    h.default_nodes = &.{b2};
    h.in_end = true;
    try testing.expectEqualStrings("b2", try ids_of(try run("defaultNode()[state:focused()=false()]", doc, &h)));
}
