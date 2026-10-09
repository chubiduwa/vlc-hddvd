//! XML documents for Advanced Content: a namespace-aware parser and a mutable DOM (Level 2 Core subset), shared
//! by the playlist and manifest loaders, the markup engine and the script API (HD DVD Vol. 3 §6.2.1, Annex Z.12).
//! No VLC dependency.
//!
//! Every node belongs to its Document and lives until the Document is destroyed, even once removed from the
//! tree (scripts may keep references and re-insert it). Strings that change (attribute values, text) are owned
//! by their node and freed when replaced.

const std = @import("std");

pub const xmlns_ns = "http://www.w3.org/2000/xmlns/";
pub const xml_ns = "http://www.w3.org/XML/1998/namespace";

pub const NodeType = enum(u8) {
    element = 1,
    text = 3,
    cdata = 4,
    pi = 7,
    comment = 8,
    document = 9,
    fragment = 11,
};

pub const Attr = struct {
    ns: []const u8,
    prefix: []const u8,
    local: []const u8,
    value: []u8,
};

pub const Node = struct {
    type: NodeType,
    doc: *Document,
    parent: ?*Node = null,
    first: ?*Node = null,
    last: ?*Node = null,
    prev: ?*Node = null,
    next: ?*Node = null,
    /// Element: namespace URI, prefix and local name. PI: local = target.
    ns: []const u8 = "",
    prefix: []const u8 = "",
    local: []const u8 = "",
    attrs: std.ArrayList(Attr) = .empty,
    /// Text, CDATA, comment and PI data.
    data: []u8 = &.{},
    /// Owner-defined data: the script wrapper and the markup engine's state for this node.
    host: ?*anyopaque = null,
    view: ?*anyopaque = null,

    pub fn is(n: *const Node, ns: []const u8, local: []const u8) bool {
        return n.type == .element and std.mem.eql(u8, n.local, local) and std.mem.eql(u8, n.ns, ns);
    }

    /// The qualified name ("prefix:local" or "local"), allocated in the document's string pool.
    pub fn qname(n: *const Node) []const u8 {
        if (n.prefix.len == 0) return n.local;
        return n.doc.joinName(n.prefix, n.local);
    }

    // ---- attributes ----

    pub fn attrIndex(n: *const Node, ns: []const u8, local: []const u8) ?usize {
        for (n.attrs.items, 0..) |a, i| if (std.mem.eql(u8, a.local, local) and std.mem.eql(u8, a.ns, ns)) return i;
        return null;
    }

    /// The value of the attribute in no namespace (what unprefixed attributes are), or null.
    pub fn attr(n: *const Node, local: []const u8) ?[]const u8 {
        return n.attrNS("", local);
    }

    pub fn attrNS(n: *const Node, ns: []const u8, local: []const u8) ?[]const u8 {
        const i = n.attrIndex(ns, local) orelse return null;
        return n.attrs.items[i].value;
    }

    /// Attribute by qualified name as written (getAttribute semantics).
    pub fn attrQ(n: *const Node, name: []const u8) ?[]const u8 {
        const i = n.attrIndexQ(name) orelse return null;
        return n.attrs.items[i].value;
    }

    pub fn attrIndexQ(n: *const Node, name: []const u8) ?usize {
        const colon = std.mem.indexOfScalar(u8, name, ':');
        for (n.attrs.items, 0..) |a, i| {
            if (colon) |c| {
                if (std.mem.eql(u8, a.prefix, name[0..c]) and std.mem.eql(u8, a.local, name[c + 1 ..])) return i;
            } else if (a.prefix.len == 0 and std.mem.eql(u8, a.local, name)) return i;
        }
        return null;
    }

    pub fn setAttrNS(n: *Node, ns: []const u8, prefix: []const u8, local: []const u8, value: []const u8) !void {
        const d = n.doc;
        const v = try d.gpa.dupe(u8, value);
        if (n.attrIndex(ns, local)) |i| {
            d.gpa.free(n.attrs.items[i].value);
            n.attrs.items[i].value = v;
            return;
        }
        errdefer d.gpa.free(v);
        try n.attrs.append(d.gpa, .{ .ns = try d.intern(ns), .prefix = try d.intern(prefix), .local = try d.intern(local), .value = v });
    }

    /// setAttribute: by qualified name; a prefix is resolved against the element's in-scope namespaces.
    pub fn setAttrQ(n: *Node, name: []const u8, value: []const u8) !void {
        if (n.attrIndexQ(name)) |i| {
            const v = try n.doc.gpa.dupe(u8, value);
            n.doc.gpa.free(n.attrs.items[i].value);
            n.attrs.items[i].value = v;
            return;
        }
        if (std.mem.indexOfScalar(u8, name, ':')) |c| {
            const ns = n.lookupNamespace(name[0..c]) orelse "";
            return n.setAttrNS(ns, name[0..c], name[c + 1 ..], value);
        }
        return n.setAttrNS("", "", name, value);
    }

    pub fn removeAttrAt(n: *Node, i: usize) void {
        n.doc.gpa.free(n.attrs.items[i].value);
        _ = n.attrs.orderedRemove(i);
    }

    /// The namespace URI bound to `prefix` on this element or an ancestor ("" = the default namespace).
    pub fn lookupNamespace(n: *const Node, prefix: []const u8) ?[]const u8 {
        if (std.mem.eql(u8, prefix, "xml")) return xml_ns;
        var cur: ?*const Node = n;
        while (cur) |e| : (cur = e.parent) {
            if (e.type != .element) continue;
            if (prefix.len == 0 and e.prefix.len == 0) {
                if (e.attrNS(xmlns_ns, "xmlns")) |v| return v;
            }
            if (e.attrNS(xmlns_ns, prefix)) |v| if (prefix.len > 0) return v;
        }
        return if (prefix.len == 0) "" else null;
    }

    // ---- tree ----

    pub fn appendChild(parent: *Node, c: *Node) void {
        parent.insertBefore(c, null);
    }

    /// Inserts `child` (detached first) before `ref`, or at the end. A fragment inserts its children.
    pub fn insertBefore(parent: *Node, c: *Node, ref: ?*Node) void {
        if (c.type == .fragment) {
            while (c.first) |x| parent.insertBefore(x, ref);
            return;
        }
        c.detach();
        c.parent = parent;
        c.next = ref;
        c.prev = if (ref) |r| r.prev else parent.last;
        if (c.prev) |p| p.next = c else parent.first = c;
        if (ref) |r| r.prev = c else parent.last = c;
    }

    pub fn detach(n: *Node) void {
        const p = n.parent orelse return;
        if (n.prev) |pr| pr.next = n.next else p.first = n.next;
        if (n.next) |nx| nx.prev = n.prev else p.last = n.prev;
        n.parent = null;
        n.prev = null;
        n.next = null;
    }

    pub fn contains(n: *const Node, other: *const Node) bool {
        var cur: ?*const Node = other;
        while (cur) |c| : (cur = c.parent) if (c == n) return true;
        return false;
    }

    /// The first child element with this namespace and local name.
    pub fn child(n: *const Node, ns: []const u8, local: []const u8) ?*Node {
        var c = n.first;
        while (c) |e| : (c = e.next) if (e.is(ns, local)) return e;
        return null;
    }

    pub fn firstElement(n: *const Node) ?*Node {
        var c = n.first;
        while (c) |e| : (c = e.next) if (e.type == .element) return e;
        return null;
    }

    pub fn nextElement(n: *const Node) ?*Node {
        var c = n.next;
        while (c) |e| : (c = e.next) if (e.type == .element) return e;
        return null;
    }

    /// Depth-first successor within `root` (pre-order), or null.
    pub fn following(n: *const Node, root: *const Node) ?*Node {
        if (n.first) |f| return f;
        var cur: *const Node = n;
        while (cur != root) {
            if (cur.next) |nx| return nx;
            cur = cur.parent orelse return null;
        }
        return null;
    }

    pub fn setData(n: *Node, data: []const u8) !void {
        const v = try n.doc.gpa.dupe(u8, data);
        n.doc.gpa.free(n.data);
        n.data = v;
    }

    /// Concatenated text of all descendant text and CDATA nodes (textContent).
    pub fn text(n: *const Node, gpa: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        if (n.type == .text or n.type == .cdata or n.type == .comment or n.type == .pi) {
            try out.appendSlice(gpa, n.data);
            return out.toOwnedSlice(gpa);
        }
        var cur = n.first;
        while (cur) |c| : (cur = c.following(n)) {
            if (c.type == .text or c.type == .cdata) try out.appendSlice(gpa, c.data);
        }
        return out.toOwnedSlice(gpa);
    }

    /// Deep or shallow copy into the same document (detached).
    pub fn clone(n: *const Node, deep: bool) !*Node {
        const d = n.doc;
        const c = try d.newNode(n.type);
        c.ns = n.ns;
        c.prefix = n.prefix;
        c.local = n.local;
        c.data = try d.gpa.dupe(u8, n.data);
        for (n.attrs.items) |a| try c.attrs.append(d.gpa, .{ .ns = a.ns, .prefix = a.prefix, .local = a.local, .value = try d.gpa.dupe(u8, a.value) });
        if (deep) {
            var ch = n.first;
            while (ch) |x| : (ch = x.next) c.appendChild(try x.clone(true));
        }
        return c;
    }

    pub fn documentElement(n: *const Node) ?*Node {
        return n.doc.node.firstElement();
    }
};

pub const Document = struct {
    gpa: std.mem.Allocator,
    node: Node,
    /// Every node ever created for this document.
    all: std.ArrayList(*Node) = .empty,
    /// Interned names and namespace URIs.
    names: std.StringHashMapUnmanaged(void) = .empty,
    /// Where the document was loaded from (for relative URIs), owned.
    uri: []u8 = &.{},
    host: ?*anyopaque = null,

    pub fn create(gpa: std.mem.Allocator) !*Document {
        const d = try gpa.create(Document);
        d.* = .{ .gpa = gpa, .node = .{ .type = .document, .doc = undefined } };
        d.node.doc = d;
        return d;
    }

    pub fn destroy(d: *Document) void {
        const gpa = d.gpa;
        for (d.all.items) |n| freeNode(gpa, n);
        d.all.deinit(gpa);
        freeNodeData(gpa, &d.node);
        var it = d.names.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        d.names.deinit(gpa);
        gpa.free(d.uri);
        gpa.destroy(d);
    }

    fn freeNodeData(gpa: std.mem.Allocator, n: *Node) void {
        for (n.attrs.items) |a| gpa.free(a.value);
        n.attrs.deinit(gpa);
        gpa.free(n.data);
    }

    fn freeNode(gpa: std.mem.Allocator, n: *Node) void {
        freeNodeData(gpa, n);
        gpa.destroy(n);
    }

    pub fn newNode(d: *Document, t: NodeType) !*Node {
        const n = try d.gpa.create(Node);
        errdefer d.gpa.destroy(n);
        n.* = .{ .type = t, .doc = d };
        try d.all.append(d.gpa, n);
        return n;
    }

    pub fn intern(d: *Document, s: []const u8) ![]const u8 {
        if (s.len == 0) return "";
        if (d.names.getKey(s)) |k| return k;
        const k = try d.gpa.dupe(u8, s);
        errdefer d.gpa.free(k);
        try d.names.put(d.gpa, k, {});
        return k;
    }

    fn joinName(d: *Document, prefix: []const u8, local: []const u8) []const u8 {
        var buf: [512]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{s}:{s}", .{ prefix, local }) catch return local;
        return d.intern(s) catch local;
    }

    pub fn createElementNS(d: *Document, ns: []const u8, qname: []const u8) !*Node {
        const n = try d.newNode(.element);
        if (std.mem.indexOfScalar(u8, qname, ':')) |c| {
            n.prefix = try d.intern(qname[0..c]);
            n.local = try d.intern(qname[c + 1 ..]);
        } else n.local = try d.intern(qname);
        n.ns = try d.intern(ns);
        return n;
    }

    pub fn createText(d: *Document, t: NodeType, data: []const u8) !*Node {
        const n = try d.newNode(t);
        n.data = try d.gpa.dupe(u8, data);
        return n;
    }

    pub fn root(d: *Document) ?*Node {
        return d.node.firstElement();
    }

    /// A copy of `n` (from any document) owned by this one, detached (DOM importNode).
    pub fn importNode(d: *Document, n: *const Node, deep: bool) !*Node {
        const c = try d.newNode(n.type);
        c.ns = try d.intern(n.ns);
        c.prefix = try d.intern(n.prefix);
        c.local = try d.intern(n.local);
        c.data = try d.gpa.dupe(u8, n.data);
        for (n.attrs.items) |a| {
            const v = try d.gpa.dupe(u8, a.value);
            errdefer d.gpa.free(v);
            try c.attrs.append(d.gpa, .{ .ns = try d.intern(a.ns), .prefix = try d.intern(a.prefix), .local = try d.intern(a.local), .value = v });
        }
        if (deep) {
            var ch = n.first;
            while (ch) |x| : (ch = x.next) c.appendChild(try d.importNode(x, true));
        }
        return c;
    }

    /// The element whose "id" attribute (in no namespace, or xml:id) is `id`.
    pub fn getElementById(d: *Document, id: []const u8) ?*Node {
        var cur = d.node.first;
        while (cur) |n| : (cur = n.following(&d.node)) {
            if (n.type != .element) continue;
            if (n.attr("id")) |v| if (std.mem.eql(u8, v, id)) return n;
            if (n.attrNS(xml_ns, "id")) |v| if (std.mem.eql(u8, v, id)) return n;
        }
        return null;
    }
};

// ---- parser -------------------------------------------------------------------------------------------------

pub const ParseError = error{ BadXml, OutOfMemory };

pub const Diag = struct {
    line: u32 = 0,
    msg: []const u8 = "",
};

/// Parses an XML document (UTF-8, or UTF-16 with a BOM). DOCTYPE declarations are skipped.
pub fn parse(gpa: std.mem.Allocator, bytes: []const u8, diag: ?*Diag) ParseError!*Document {
    var utf8_buf: ?[]u8 = null;
    defer if (utf8_buf) |b| gpa.free(b);
    var src = bytes;
    if (src.len >= 2 and ((src[0] == 0xfe and src[1] == 0xff) or (src[0] == 0xff and src[1] == 0xfe))) {
        utf8_buf = utf16ToUtf8(gpa, src[2..], src[0] == 0xfe) catch return error.BadXml;
        src = utf8_buf.?;
    } else if (src.len >= 3 and std.mem.eql(u8, src[0..3], "\xef\xbb\xbf")) src = src[3..];

    const d = try Document.create(gpa);
    errdefer d.destroy();
    var p: Parser = .{ .gpa = gpa, .s = src, .doc = d };
    defer p.scopes.deinit(gpa);
    p.run() catch |err| {
        if (diag) |dg| dg.* = .{ .line = p.line(), .msg = p.msg };
        return err;
    };
    return d;
}

/// UTF-16 (big- or little-endian) to UTF-8.
pub fn utf16ToUtf8(gpa: std.mem.Allocator, b: []const u8, big: bool) ![]u8 {
    const n = b.len / 2;
    const units = try gpa.alloc(u16, n);
    defer gpa.free(units);
    for (units, 0..) |*u, i| u.* = if (big) std.mem.readInt(u16, b[i * 2 ..][0..2], .big) else std.mem.readInt(u16, b[i * 2 ..][0..2], .little);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        var cp: u21 = units[i];
        if (cp >= 0xd800 and cp < 0xdc00 and i + 1 < n and units[i + 1] >= 0xdc00 and units[i + 1] < 0xe000) {
            cp = 0x10000 + ((cp - 0xd800) << 10) + (units[i + 1] - 0xdc00);
            i += 1;
        } else if (cp >= 0xd800 and cp < 0xe000) cp = 0xfffd;
        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(cp, &buf) catch continue;
        try out.appendSlice(gpa, buf[0..len]);
    }
    return out.toOwnedSlice(gpa);
}

const Binding = struct { prefix: []const u8, uri: []const u8, depth: u32 };

const Parser = struct {
    gpa: std.mem.Allocator,
    s: []const u8,
    i: usize = 0,
    doc: *Document,
    scopes: std.ArrayList(Binding) = .empty,
    msg: []const u8 = "",

    fn fail(p: *Parser, msg: []const u8) ParseError {
        p.msg = msg;
        return error.BadXml;
    }

    fn line(p: *const Parser) u32 {
        var n: u32 = 1;
        for (p.s[0..@min(p.i, p.s.len)]) |c| if (c == '\n') {
            n += 1;
        };
        return n;
    }

    fn startsWith(p: *const Parser, lit: []const u8) bool {
        return std.mem.startsWith(u8, p.s[p.i..], lit);
    }

    fn skipWs(p: *Parser) void {
        while (p.i < p.s.len and isWs(p.s[p.i])) p.i += 1;
    }

    fn skipPast(p: *Parser, lit: []const u8) ParseError!void {
        const j = std.mem.indexOfPos(u8, p.s, p.i, lit) orelse return p.fail("unterminated construct");
        p.i = j + lit.len;
    }

    fn name(p: *Parser) ParseError![]const u8 {
        const start = p.i;
        while (p.i < p.s.len and isNameChar(p.s[p.i])) p.i += 1;
        if (p.i == start) return p.fail("name expected");
        return p.s[start..p.i];
    }

    fn resolve(p: *Parser, prefix: []const u8) ?[]const u8 {
        if (std.mem.eql(u8, prefix, "xml")) return xml_ns;
        var k = p.scopes.items.len;
        while (k > 0) {
            k -= 1;
            if (std.mem.eql(u8, p.scopes.items[k].prefix, prefix)) return p.scopes.items[k].uri;
        }
        return if (prefix.len == 0) "" else null;
    }

    fn run(p: *Parser) ParseError!void {
        var cur: *Node = &p.doc.node;
        var depth: u32 = 0;
        var text_start: usize = 0;
        var pending_text: std.ArrayList(u8) = .empty;
        defer pending_text.deinit(p.gpa);
        while (p.i < p.s.len) {
            if (p.s[p.i] != '<') {
                text_start = p.i;
                const j = std.mem.indexOfScalarPos(u8, p.s, p.i, '<') orelse p.s.len;
                p.i = j;
                if (cur.type != .document) {
                    pending_text.clearRetainingCapacity();
                    try decodeText(p.gpa, p.s[text_start..j], &pending_text);
                    const t = try p.doc.createText(.text, pending_text.items);
                    cur.appendChild(t);
                }
                continue;
            }
            if (p.startsWith("<!--")) {
                const start = p.i + 4;
                try p.skipPast("-->");
                if (cur.type != .document or true) {
                    const c = try p.doc.createText(.comment, p.s[start .. p.i - 3]);
                    cur.appendChild(c);
                }
            } else if (p.startsWith("<![CDATA[")) {
                const start = p.i + 9;
                try p.skipPast("]]>");
                const c = try p.doc.createText(.cdata, p.s[start .. p.i - 3]);
                cur.appendChild(c);
            } else if (p.startsWith("<?")) {
                p.i += 2;
                const target = try p.name();
                const start = p.i;
                try p.skipPast("?>");
                if (!std.ascii.eqlIgnoreCase(target, "xml")) {
                    const pi = try p.doc.newNode(.pi);
                    pi.local = try p.doc.intern(target);
                    pi.data = try p.gpa.dupe(u8, std.mem.trim(u8, p.s[start .. p.i - 2], " \t\r\n"));
                    cur.appendChild(pi);
                }
            } else if (p.startsWith("<!")) {
                // DOCTYPE (with an optional internal subset in brackets): skipped.
                var level: u32 = 0;
                while (p.i < p.s.len) : (p.i += 1) {
                    const c = p.s[p.i];
                    if (c == '[') level += 1;
                    if (c == ']' and level > 0) level -= 1;
                    if (c == '>' and level == 0) break;
                }
                p.i += 1;
            } else if (p.startsWith("</")) {
                p.i += 2;
                const qn = try p.name();
                p.skipWs();
                if (p.i >= p.s.len or p.s[p.i] != '>') return p.fail("'>' expected");
                p.i += 1;
                if (cur.type != .element) return p.fail("unexpected end tag");
                const want = cur.qname();
                if (!std.mem.eql(u8, want, qn)) return p.fail("mismatched end tag");
                while (p.scopes.items.len > 0 and p.scopes.items[p.scopes.items.len - 1].depth == depth) _ = p.scopes.pop();
                depth -= 1;
                cur = cur.parent.?;
            } else {
                p.i += 1;
                const el = try p.startTag(depth + 1);
                cur.appendChild(el.node);
                if (el.empty) {
                    while (p.scopes.items.len > 0 and p.scopes.items[p.scopes.items.len - 1].depth == depth + 1) _ = p.scopes.pop();
                } else {
                    depth += 1;
                    cur = el.node;
                }
            }
        }
        if (cur.type != .document) return p.fail("unclosed element");
        if (p.doc.root() == null) return p.fail("no root element");
    }

    const RawAttr = struct { qn: []const u8, value: []u8 };

    fn startTag(p: *Parser, depth: u32) ParseError!struct { node: *Node, empty: bool } {
        const qn = try p.name();
        var raw: std.ArrayList(RawAttr) = .empty;
        defer {
            for (raw.items) |a| p.gpa.free(a.value);
            raw.deinit(p.gpa);
        }
        var empty = false;
        while (true) {
            p.skipWs();
            if (p.i >= p.s.len) return p.fail("unterminated start tag");
            if (p.s[p.i] == '>') {
                p.i += 1;
                break;
            }
            if (p.startsWith("/>")) {
                p.i += 2;
                empty = true;
                break;
            }
            const an = try p.name();
            p.skipWs();
            if (p.i >= p.s.len or p.s[p.i] != '=') return p.fail("'=' expected");
            p.i += 1;
            p.skipWs();
            if (p.i >= p.s.len or (p.s[p.i] != '"' and p.s[p.i] != '\'')) return p.fail("quoted value expected");
            const q = p.s[p.i];
            p.i += 1;
            const end = std.mem.indexOfScalarPos(u8, p.s, p.i, q) orelse return p.fail("unterminated value");
            var v: std.ArrayList(u8) = .empty;
            errdefer v.deinit(p.gpa);
            try decodeText(p.gpa, p.s[p.i..end], &v);
            // Attribute-value normalisation: whitespace characters become spaces.
            for (v.items) |*c| if (c.* == '\t' or c.* == '\n' or c.* == '\r') {
                c.* = ' ';
            };
            p.i = end + 1;
            try raw.append(p.gpa, .{ .qn = an, .value = try v.toOwnedSlice(p.gpa) });
        }
        // Namespace declarations first.
        for (raw.items) |a| {
            if (std.mem.eql(u8, a.qn, "xmlns")) {
                try p.scopes.append(p.gpa, .{ .prefix = "", .uri = try p.doc.intern(a.value), .depth = depth });
            } else if (std.mem.startsWith(u8, a.qn, "xmlns:")) {
                try p.scopes.append(p.gpa, .{ .prefix = try p.doc.intern(a.qn[6..]), .uri = try p.doc.intern(a.value), .depth = depth });
            }
        }
        const d = p.doc;
        const n = try d.newNode(.element);
        if (std.mem.indexOfScalar(u8, qn, ':')) |c| {
            n.prefix = try d.intern(qn[0..c]);
            n.local = try d.intern(qn[c + 1 ..]);
            n.ns = p.resolve(n.prefix) orelse return p.fail("undeclared prefix");
        } else {
            n.local = try d.intern(qn);
            n.ns = p.resolve("").?;
        }
        for (raw.items) |*a| {
            var ns: []const u8 = "";
            var prefix: []const u8 = "";
            var local: []const u8 = a.qn;
            if (std.mem.eql(u8, a.qn, "xmlns")) {
                ns = xmlns_ns;
            } else if (std.mem.indexOfScalar(u8, a.qn, ':')) |c| {
                prefix = a.qn[0..c];
                local = a.qn[c + 1 ..];
                ns = if (std.mem.eql(u8, prefix, "xmlns")) xmlns_ns else p.resolve(prefix) orelse return p.fail("undeclared attribute prefix");
            }
            try n.attrs.append(p.gpa, .{ .ns = try d.intern(ns), .prefix = try d.intern(prefix), .local = try d.intern(local), .value = a.value });
            a.value = &.{};
        }
        return .{ .node = n, .empty = empty };
    }
};

fn isWs(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == '\n';
}

fn isNameChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == ':' or c == '-' or c == '.' or c >= 0x80;
}

/// Character data with entity and character references resolved.
fn decodeText(gpa: std.mem.Allocator, raw: []const u8, out: *std.ArrayList(u8)) !void {
    var i: usize = 0;
    while (i < raw.len) {
        const c = raw[i];
        if (c == '\r') { // line-end normalisation
            try out.append(gpa, '\n');
            i += if (i + 1 < raw.len and raw[i + 1] == '\n') 2 else 1;
            continue;
        }
        if (c != '&') {
            try out.append(gpa, c);
            i += 1;
            continue;
        }
        const semi = std.mem.indexOfScalarPos(u8, raw, i, ';') orelse {
            try out.append(gpa, c);
            i += 1;
            continue;
        };
        const ent = raw[i + 1 .. semi];
        const named = [_]struct { []const u8, u8 }{ .{ "lt", '<' }, .{ "gt", '>' }, .{ "amp", '&' }, .{ "quot", '"' }, .{ "apos", '\'' } };
        var done = false;
        for (named) |e| if (std.mem.eql(u8, ent, e[0])) {
            try out.append(gpa, e[1]);
            done = true;
        };
        if (!done and ent.len > 1 and ent[0] == '#') {
            const cp = if (ent[1] == 'x' or ent[1] == 'X')
                std.fmt.parseInt(u21, ent[2..], 16) catch null
            else
                std.fmt.parseInt(u21, ent[1..], 10) catch null;
            if (cp) |v| {
                var buf: [4]u8 = undefined;
                if (std.unicode.utf8Encode(v, &buf)) |len| {
                    try out.appendSlice(gpa, buf[0..len]);
                    done = true;
                } else |_| {}
            }
        }
        if (!done) try out.appendSlice(gpa, raw[i .. semi + 1]);
        i = semi + 1;
    }
}

// ---- serializer ----------------------------------------------------------------------------------------------

/// Writes `n` and its descendants as XML (UTF-8), with an XML declaration for a document.
pub fn serialize(gpa: std.mem.Allocator, n: *const Node, out: *std.ArrayList(u8)) !void {
    switch (n.type) {
        .document, .fragment => {
            if (n.type == .document) try out.appendSlice(gpa, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n");
            var c = n.first;
            while (c) |x| : (c = x.next) try serialize(gpa, x, out);
        },
        .element => {
            try out.append(gpa, '<');
            try out.appendSlice(gpa, n.qname());
            for (n.attrs.items) |a| {
                try out.append(gpa, ' ');
                if (a.prefix.len > 0) {
                    try out.appendSlice(gpa, a.prefix);
                    try out.append(gpa, ':');
                }
                try out.appendSlice(gpa, a.local);
                try out.appendSlice(gpa, "=\"");
                try escape(gpa, a.value, true, out);
                try out.append(gpa, '"');
            }
            if (n.first == null) {
                try out.appendSlice(gpa, "/>");
                return;
            }
            try out.append(gpa, '>');
            var c = n.first;
            while (c) |x| : (c = x.next) try serialize(gpa, x, out);
            try out.appendSlice(gpa, "</");
            try out.appendSlice(gpa, n.qname());
            try out.append(gpa, '>');
        },
        .text => try escape(gpa, n.data, false, out),
        .cdata => {
            try out.appendSlice(gpa, "<![CDATA[");
            try out.appendSlice(gpa, n.data);
            try out.appendSlice(gpa, "]]>");
        },
        .comment => {
            try out.appendSlice(gpa, "<!--");
            try out.appendSlice(gpa, n.data);
            try out.appendSlice(gpa, "-->");
        },
        .pi => {
            try out.appendSlice(gpa, "<?");
            try out.appendSlice(gpa, n.local);
            try out.append(gpa, ' ');
            try out.appendSlice(gpa, n.data);
            try out.appendSlice(gpa, "?>");
        },
    }
}

fn escape(gpa: std.mem.Allocator, s: []const u8, in_attr: bool, out: *std.ArrayList(u8)) !void {
    for (s) |c| switch (c) {
        '<' => try out.appendSlice(gpa, "&lt;"),
        '>' => try out.appendSlice(gpa, "&gt;"),
        '&' => try out.appendSlice(gpa, "&amp;"),
        '"' => try out.appendSlice(gpa, if (in_attr) "&quot;" else "\""),
        else => try out.append(gpa, c),
    };
}

// ---- tests --------------------------------------------------------------------------------------------------

const testing = std.testing;

test "parse namespaces, attributes, entities and mixed content" {
    const src =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE root [ <!ENTITY x "y"> ]>
        \\<root xmlns="urn:a" xmlns:s="urn:s" id="r">
        \\  <!-- c -->
        \\  <p s:color="#ff0000" title="a &amp; b&#x21;">x &lt; y<![CDATA[<raw>]]></p>
        \\  <s:q/>
        \\</root>
    ;
    var diag: Diag = .{};
    const d = try parse(testing.allocator, src, &diag);
    defer d.destroy();
    const root = d.root().?;
    try testing.expect(root.is("urn:a", "root"));
    try testing.expectEqualStrings("r", root.attr("id").?);
    const p = root.child("urn:a", "p").?;
    try testing.expectEqualStrings("#ff0000", p.attrNS("urn:s", "color").?);
    try testing.expectEqualStrings("#ff0000", p.attrQ("s:color").?);
    try testing.expectEqualStrings("a & b!", p.attr("title").?);
    const t = try p.text(testing.allocator);
    defer testing.allocator.free(t);
    try testing.expectEqualStrings("x < y<raw>", t);
    try testing.expect(root.child("urn:s", "q") != null);
    try testing.expectEqual(d.getElementById("r"), root);
}

test "malformed documents are rejected with a line number" {
    var diag: Diag = .{};
    try testing.expectError(error.BadXml, parse(testing.allocator, "<a>\n<b></a>", &diag));
    try testing.expectEqual(2, diag.line);
    try testing.expectError(error.BadXml, parse(testing.allocator, "<a><x:b/></a>", null));
    try testing.expectError(error.BadXml, parse(testing.allocator, "", null));
}

test "UTF-16 documents with a BOM" {
    const src = "\xfe\xff\x00<\x00a\x00>\x00\xe9\x00<\x00/\x00a\x00>";
    const d = try parse(testing.allocator, src, null);
    defer d.destroy();
    const t = try d.root().?.text(testing.allocator);
    defer testing.allocator.free(t);
    try testing.expectEqualStrings("é", t);
}

test "tree mutation, attributes and serialisation" {
    const d = try parse(testing.allocator, "<a xmlns:s=\"urn:s\"><b/><c/></a>", null);
    defer d.destroy();
    const a = d.root().?;
    const b = a.firstElement().?;
    const c = b.nextElement().?;
    a.insertBefore(c, b); // move c first
    try testing.expectEqual(c, a.first);
    const e = try d.createElementNS("", "e");
    try e.setAttrQ("k", "1 < 2");
    try e.setAttrQ("s:v", "x");
    try testing.expectEqualStrings("", e.attrs.items[1].ns); // not in the tree yet
    b.appendChild(e);
    try e.setAttrQ("k", "2");
    b.appendChild(try d.createText(.text, "t&"));
    const copy = try b.clone(true);
    a.appendChild(copy);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try serialize(testing.allocator, a, &out);
    try testing.expectEqualStrings("<a xmlns:s=\"urn:s\"><c/><b><e k=\"2\" s:v=\"x\"/>t&amp;</b><b><e k=\"2\" s:v=\"x\"/>t&amp;</b></a>", out.items);
    e.detach();
    try testing.expect(!a.contains(e));
    try testing.expectEqualStrings("urn:s", b.lookupNamespace("s").?);
}
