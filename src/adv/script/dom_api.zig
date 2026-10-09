//! The DOM for scripts (HD DVD Annex Z.12.5–Z.12.7, Z.13.1): DOM Level 2 Core with its ECMAScript binding
//! (Appendix E) over dom.zig, the EventTarget and DocumentEvent interfaces, and the XPath interfaces of
//! documents. The page's document is an AnimatableDocument and its elements AnimatableElements (anim_api.zig).
//!
//! Wrappers keep their identity: a node's wrapper is found again through `dom.Node.host` while it lives (the
//! reference is weak; its finalizer clears it). A document parsed or created by script lives as long as any
//! wrapper of its nodes (they count in its DocState); the page's document is the page's, and when the page goes
//! its wrappers are detached (`releaseDocument`) and stop working.
//!
//! Script changes to the page's DOM apply at the next tick (the cascade and the timing read the DOM); a change
//! of the tree resyncs the page. Mutation events are queued like every other event (§8.5), with the path
//! they had when the change happened. No VLC dependency.

const std = @import("std");
const js = @import("js.zig");
const events = @import("events.zig");
const dom = @import("../dom.zig");
const xpath = @import("../xpath.zig");
const host = @import("host.zig");

const c = js.c;
const Value = js.Value;
const Node = dom.Node;
const Script = host.Script;

// ---- document state -----------------------------------------------------------------------------------------------

/// What scripts attach to a document (dom.Document.host).
pub const DocState = struct {
    script: *Script,
    doc: *dom.Document,
    /// Live wrappers of its nodes and of objects depending on it (attributes, node lists…).
    refs: u32 = 0,
    /// The document belongs to its wrappers (parsed or created by script): destroyed with the last one.
    owned: bool,
    /// The page's (AnimatableDocument).
    page: bool = false,
    /// Wrappers of objects that are not nodes (Attr, NodeList…), detached with the document.
    others: std.ArrayList(*anyopaque) = .empty,
    /// setXPathVariable values (Z.12.7.2).
    vars: std.StringHashMapUnmanaged([]u8) = .empty,

    fn deinit(st: *DocState) void {
        const gpa = st.script.gpa;
        st.others.deinit(gpa);
        var it = st.vars.iterator();
        while (it.next()) |kv| {
            gpa.free(kv.key_ptr.*);
            gpa.free(kv.value_ptr.*);
        }
        st.vars.deinit(gpa);
        gpa.destroy(st);
    }

    fn unref(st: *DocState) void {
        st.refs -= 1;
        if (st.refs > 0 or !st.owned) return;
        const s = st.script;
        const doc = st.doc;
        for (doc.all.items) |n| s.reg.drop(s.cx, n);
        s.reg.drop(s.cx, &doc.node);
        doc.host = null;
        st.deinit();
        doc.destroy();
    }
};

fn stateOf(s: *Script, doc: *dom.Document) !*DocState {
    if (doc.host) |p| return @ptrCast(@alignCast(p));
    const st = try s.gpa.create(DocState);
    st.* = .{ .script = s, .doc = doc, .owned = !s.isPageDoc(doc), .page = s.isPageDoc(doc) };
    doc.host = st;
    return st;
}

fn existingState(doc: *dom.Document) ?*DocState {
    return @ptrCast(@alignCast(doc.host orelse return null));
}

/// A document made by script: it belongs to its wrappers from now on.
pub fn adoptDocument(s: *Script, doc: *dom.Document) !Value {
    const st = try stateOf(s, doc);
    st.owned = true;
    return wrap(s, &doc.node);
}

/// The page's document is going away: its wrappers stop working, its listeners go.
pub fn releaseDocument(s: *Script, doc: *dom.Document) void {
    const st = existingState(doc) orelse return;
    for (doc.all.items) |n| detachNode(s, n);
    detachNode(s, &doc.node);
    for (st.others.items) |o| js.kill(s.cx.rt, o);
    doc.host = null;
    st.deinit();
}

fn detachNode(s: *Script, n: *Node) void {
    s.reg.drop(s.cx, n);
    if (n.host) |o| js.kill(s.cx.rt, o);
    n.host = null;
}

// ---- wrapping -----------------------------------------------------------------------------------------------------

/// The script object for node `n` (a new reference).
pub fn wrap(s: *Script, n: *Node) js.Error!Value {
    if (n.host) |o| return js.fromPointer(s.cx, o);
    const st = try stateOf(s, n.doc);
    const class: *const js.Class = switch (n.type) {
        .element => if (st.page) &animatable_element_class else &element_class,
        .text => &text_class,
        .cdata => &cdata_class,
        .comment => &comment_class,
        .pi => &pi_class,
        .document => if (st.page) &animatable_document_class else &document_class,
        .fragment => &fragment_class,
    };
    const v = try s.cx.wrapAs(Node, class, n);
    n.host = js.objectPointer(v);
    st.refs += 1;
    return v;
}

fn wrapOrNull(s: *Script, n: ?*Node) js.Error!Value {
    return if (n) |x| wrap(s, x) else js.null;
}

fn finalizeNode(ptr: *anyopaque, _: *js.Runtime) void {
    const n: *Node = @ptrCast(@alignCast(ptr));
    n.host = null;
    if (existingState(n.doc)) |st| st.unref();
}

/// A wrapper for a non-node object that depends on `doc` (it keeps the document alive).
pub fn wrapDependent(s: *Script, comptime T: type, class: *const js.Class, ptr: *T, doc: *dom.Document) js.Error!Value {
    const st = try stateOf(s, doc);
    const v = try s.cx.wrapAs(T, class, ptr);
    st.others.append(s.gpa, js.objectPointer(v)) catch {
        s.cx.free(v);
        return error.OutOfMemory;
    };
    st.refs += 1;
    ptr.obj = js.objectPointer(v);
    return v;
}

pub fn dropDependent(doc: *dom.Document, obj: *anyopaque) void {
    const st = existingState(doc) orelse return;
    if (std.mem.indexOfScalar(*anyopaque, st.others.items, obj)) |i| _ = st.others.swapRemove(i);
    st.unref();
}

/// The node behind `v`, or null (null and undefined too).
pub fn nodeOf(cx: *js.Context, v: Value) ?*Node {
    return cx.unwrap(Node, v);
}

fn scriptOf(cx: *js.Context) *Script {
    return @ptrCast(@alignCast(cx.owner.?));
}

// ---- Node ---------------------------------------------------------------------------------------------------------

const NodeType = struct {
    const element = 1;
    const attribute = 2;
    const text = 3;
    const cdata = 4;
    const entity_reference = 5;
    const entity = 6;
    const pi = 7;
    const comment = 8;
    const document = 9;
    const document_type = 10;
    const fragment = 11;
    const notation = 12;
};

pub const node_constants = [_]js.Member{
    js.constant("ELEMENT_NODE", NodeType.element),
    js.constant("ATTRIBUTE_NODE", NodeType.attribute),
    js.constant("TEXT_NODE", NodeType.text),
    js.constant("CDATA_SECTION_NODE", NodeType.cdata),
    js.constant("ENTITY_REFERENCE_NODE", NodeType.entity_reference),
    js.constant("ENTITY_NODE", NodeType.entity),
    js.constant("PROCESSING_INSTRUCTION_NODE", NodeType.pi),
    js.constant("COMMENT_NODE", NodeType.comment),
    js.constant("DOCUMENT_NODE", NodeType.document),
    js.constant("DOCUMENT_TYPE_NODE", NodeType.document_type),
    js.constant("DOCUMENT_FRAGMENT_NODE", NodeType.fragment),
    js.constant("NOTATION_NODE", NodeType.notation),
};

fn nodeName(n: *Node) []const u8 {
    return switch (n.type) {
        .element => n.qname(),
        .text => "#text",
        .cdata => "#cdata-section",
        .comment => "#comment",
        .pi => n.local,
        .document => "#document",
        .fragment => "#document-fragment",
    };
}

fn getNodeValue(n: *Node, cx: *js.Context) js.Error!Value {
    return switch (n.type) {
        .text, .cdata, .comment, .pi => cx.string(n.data),
        else => js.null,
    };
}

fn setNodeValue(n: *Node, cx: *js.Context, v: js.NullStr) js.Error!void {
    switch (n.type) {
        .text, .cdata, .comment, .pi => try setData(cx, n, v.s orelse ""),
        else => {},
    }
}

fn getNodeType(n: *Node) u32 {
    return @backingInt(n.type);
}

fn getParent(n: *Node, cx: *js.Context) js.Error!Value {
    return wrapOrNull(scriptOf(cx), n.parent);
}

fn getChildNodes(n: *Node, cx: *js.Context) js.Error!Value {
    return NodeList.make(scriptOf(cx), n.doc, .{ .children = n });
}

fn getFirst(n: *Node, cx: *js.Context) js.Error!Value {
    return wrapOrNull(scriptOf(cx), n.first);
}

fn getLast(n: *Node, cx: *js.Context) js.Error!Value {
    return wrapOrNull(scriptOf(cx), n.last);
}

fn getPrev(n: *Node, cx: *js.Context) js.Error!Value {
    return wrapOrNull(scriptOf(cx), n.prev);
}

fn getNext(n: *Node, cx: *js.Context) js.Error!Value {
    return wrapOrNull(scriptOf(cx), n.next);
}

fn getAttributes(n: *Node, cx: *js.Context) js.Error!Value {
    if (n.type != .element) return js.null;
    return AttrMap.make(scriptOf(cx), n);
}

fn getOwnerDocument(n: *Node, cx: *js.Context) js.Error!Value {
    if (n.type == .document) return js.null;
    return wrap(scriptOf(cx), &n.doc.node);
}

fn getNamespaceURI(n: *Node, cx: *js.Context) js.Error!Value {
    if (n.type != .element or n.ns.len == 0) return js.null;
    return cx.string(n.ns);
}

fn getPrefix(n: *Node, cx: *js.Context) js.Error!Value {
    if (n.type != .element or n.prefix.len == 0) return js.null;
    return cx.string(n.prefix);
}

fn setPrefix(n: *Node, cx: *js.Context, p: js.NullStr) js.Error!void {
    if (n.type != .element) return;
    const prefix = p.s orelse "";
    if (prefix.len > 0) {
        if (!isNcName(prefix)) return events.throwDom(cx, .invalid_character);
        if (n.ns.len == 0) return events.throwDom(cx, .namespace);
        if (std.mem.eql(u8, prefix, "xml") and !std.mem.eql(u8, n.ns, dom.xml_ns)) return events.throwDom(cx, .namespace);
    }
    n.prefix = try n.doc.intern(prefix);
}

fn getLocalName(n: *Node, cx: *js.Context) js.Error!Value {
    if (n.type != .element) return js.null;
    return cx.string(n.local);
}

fn hasChildNodes(n: *Node) bool {
    return n.first != null;
}

fn hasAttributes(n: *Node) bool {
    return n.type == .element and n.attrs.items.len > 0;
}

/// Whether `child` may go under `parent` (DOM2 Core §1.1.1).
fn allowedChild(parent: *Node, child: *Node) bool {
    return switch (parent.type) {
        .document => switch (child.type) {
            .element => parent.firstElement() == null or parent.firstElement() == child,
            .pi, .comment => true,
            .fragment => true,
            else => false,
        },
        .element, .fragment => switch (child.type) {
            .element, .text, .comment, .pi, .cdata, .fragment => true,
            .document => false,
        },
        else => false,
    };
}

fn checkInsert(cx: *js.Context, parent: *Node, child: *Node) js.Error!void {
    if (child.doc != parent.doc) return events.throwDom(cx, .wrong_document);
    if (child.contains(parent)) return events.throwDom(cx, .hierarchy_request);
    if (child.type == .fragment) {
        var x = child.first;
        while (x) |k| : (x = k.next) if (!allowedChild(parent, k)) return events.throwDom(cx, .hierarchy_request);
        return;
    }
    if (!allowedChild(parent, child)) return events.throwDom(cx, .hierarchy_request);
}

fn insertBefore(n: *Node, cx: *js.Context, new_v: Value, ref_v: Value) js.Error!Value {
    const s = scriptOf(cx);
    const child = nodeOf(cx, new_v) orelse return error.TypeError;
    const ref: ?*Node = if (c.JS_IsNull(ref_v) or c.JS_IsUndefined(ref_v)) null else nodeOf(cx, ref_v) orelse return error.TypeError;
    try checkInsert(cx, n, child);
    if (ref) |r| if (r.parent != n) return events.throwDom(cx, .not_found);
    if (ref == child) return cx.dup(new_v);
    try s.beforeRemoval(child);
    var inserted: std.ArrayList(*Node) = .empty;
    defer inserted.deinit(s.gpa);
    if (child.type == .fragment) {
        var x = child.first;
        while (x) |k| : (x = k.next) try inserted.append(s.gpa, k);
    } else try inserted.append(s.gpa, child);
    n.insertBefore(child, ref);
    for (inserted.items) |k| try s.afterInsertion(k);
    return cx.dup(new_v);
}

fn appendChild(n: *Node, cx: *js.Context, new_v: Value) js.Error!Value {
    return insertBefore(n, cx, new_v, js.null);
}

fn replaceChild(n: *Node, cx: *js.Context, new_v: Value, old_v: Value) js.Error!Value {
    const s = scriptOf(cx);
    const child = nodeOf(cx, new_v) orelse return error.TypeError;
    const old = nodeOf(cx, old_v) orelse return error.TypeError;
    if (old.parent != n) return events.throwDom(cx, .not_found);
    if (child == old) return cx.dup(old_v);
    // The document's element may be replaced by another element.
    if (!(n.type == .document and child.type == .element and old.type == .element)) try checkInsert(cx, n, child) else {
        if (child.doc != n.doc) return events.throwDom(cx, .wrong_document);
    }
    const next = if (old.next == child) child.next else old.next;
    try s.beforeRemoval(old);
    old.detach();
    const ref = if (next) |x| try wrap(s, x) else js.null;
    defer cx.free(ref);
    cx.free(try insertBefore(n, cx, new_v, ref));
    return cx.dup(old_v);
}

fn removeChild(n: *Node, cx: *js.Context, old_v: Value) js.Error!Value {
    const s = scriptOf(cx);
    const old = nodeOf(cx, old_v) orelse return error.TypeError;
    if (old.parent != n) return events.throwDom(cx, .not_found);
    try s.beforeRemoval(old);
    old.detach();
    s.treeChanged(n.doc);
    return cx.dup(old_v);
}

fn cloneNode(n: *Node, cx: *js.Context, deep: bool) js.Error!Value {
    if (n.type == .document) return events.throwDom(cx, .not_supported);
    return wrap(scriptOf(cx), try n.clone(deep));
}

fn normalize(n: *Node, cx: *js.Context) js.Error!void {
    var cur = n.first;
    while (cur) |k| {
        const next = k.next;
        if (k.type == .text) {
            if (k.data.len == 0) {
                k.detach();
            } else while (k.next) |m| {
                if (m.type != .text) break;
                const joined = try std.mem.concat(n.doc.gpa, u8, &.{ k.data, m.data });
                n.doc.gpa.free(k.data);
                k.data = joined;
                m.detach();
            }
        } else if (k.type == .element) try normalize(k, cx);
        cur = if (k.parent == n) k.next else next;
    }
    scriptOf(cx).treeChanged(n.doc);
}

fn isSupported(_: *Node, feature: []const u8, version: js.NullStr) bool {
    return hasFeatureImpl(feature, version.s);
}

fn hasFeatureImpl(feature: []const u8, version: ?[]const u8) bool {
    const known = [_][]const u8{ "Core", "XML", "Events", "MutationEvents" };
    for (known) |k| if (std.ascii.eqlIgnoreCase(k, feature)) {
        const v = version orelse return true;
        return v.len == 0 or std.mem.eql(u8, v, "2.0") or (std.mem.eql(u8, v, "1.0") and (std.ascii.eqlIgnoreCase(k, "Core") or std.ascii.eqlIgnoreCase(k, "XML")));
    };
    return false;
}

// EventTarget (DOM2 Events §1.3.1).

fn addEventListener(n: *Node, cx: *js.Context, type_: []const u8, f: Value, capture: bool) js.Error!void {
    if (c.JS_IsNull(f) or c.JS_IsUndefined(f)) return;
    try scriptOf(cx).reg.add(cx, n, type_, f, capture);
}

fn removeEventListener(n: *Node, cx: *js.Context, type_: []const u8, f: Value, capture: bool) void {
    scriptOf(cx).reg.remove(cx, n, type_, f, capture);
}

fn dispatchEvent(n: *Node, cx: *js.Context, ev_v: Value) js.Error!bool {
    const e = cx.unwrap(events.Event, ev_v) orelse return error.TypeError;
    if (!e.initialized or e.type.len == 0) return events.throwUnspecifiedEventType(cx);
    try scriptOf(cx).queueEvent(.{ .node = n }, ev_v);
    return true;
}

const event_target_members = [_]js.Member{
    js.method("addEventListener", addEventListener),
    js.method("removeEventListener", removeEventListener),
    js.method("dispatchEvent", dispatchEvent),
};

const node_class: js.Class = .{
    .name = "Node",
    .finalize = finalizeNode,
    .members = &([_]js.Member{
        js.prop("nodeName", nodeName, null),
        js.prop("nodeValue", getNodeValue, setNodeValue),
        js.prop("nodeType", getNodeType, null),
        js.prop("parentNode", getParent, null),
        js.prop("childNodes", getChildNodes, null),
        js.prop("firstChild", getFirst, null),
        js.prop("lastChild", getLast, null),
        js.prop("previousSibling", getPrev, null),
        js.prop("nextSibling", getNext, null),
        js.prop("attributes", getAttributes, null),
        js.prop("ownerDocument", getOwnerDocument, null),
        js.prop("namespaceURI", getNamespaceURI, null),
        js.prop("prefix", getPrefix, setPrefix),
        js.prop("localName", getLocalName, null),
        js.method("insertBefore", insertBefore),
        js.method("replaceChild", replaceChild),
        js.method("removeChild", removeChild),
        js.method("appendChild", appendChild),
        js.method("hasChildNodes", hasChildNodes),
        js.method("cloneNode", cloneNode),
        js.method("normalize", normalize),
        js.method("isSupported", isSupported),
        js.method("hasAttributes", hasAttributes),
    } ++ event_target_members ++ node_constants),
};

// ---- Element ------------------------------------------------------------------------------------------------------

fn tagName(n: *Node) []const u8 {
    return n.qname();
}

fn getAttribute(n: *Node, name: []const u8) []const u8 {
    return n.attrQ(name) orelse "";
}

fn setAttribute(n: *Node, cx: *js.Context, name: []const u8, value: []const u8) js.Error!void {
    if (!isXmlName(name)) return events.throwDom(cx, .invalid_character);
    const prev = n.attrQ(name);
    const s = scriptOf(cx);
    const old = if (prev) |p| try s.gpa.dupe(u8, p) else null;
    defer if (old) |o| s.gpa.free(o);
    try n.setAttrQ(name, value);
    try s.attrChanged(n, name, old, value);
}

fn removeAttribute(n: *Node, cx: *js.Context, name: []const u8) js.Error!void {
    const i = n.attrIndexQ(name) orelse return;
    const s = scriptOf(cx);
    const old = try s.gpa.dupe(u8, n.attrs.items[i].value);
    defer s.gpa.free(old);
    n.removeAttrAt(i);
    try s.attrChanged(n, name, old, null);
}

fn getAttributeNode(n: *Node, cx: *js.Context, name: []const u8) js.Error!Value {
    const i = n.attrIndexQ(name) orelse return js.null;
    return Attr.ofElement(scriptOf(cx), n, i);
}

fn setAttributeNode(n: *Node, cx: *js.Context, v: Value) js.Error!Value {
    return setAttrNode(n, cx, v, false);
}

fn setAttributeNodeNS(n: *Node, cx: *js.Context, v: Value) js.Error!Value {
    return setAttrNode(n, cx, v, true);
}

fn setAttrNode(n: *Node, cx: *js.Context, v: Value, by_ns: bool) js.Error!Value {
    const s = scriptOf(cx);
    const a = cx.unwrap(Attr, v) orelse return error.TypeError;
    if (a.doc != n.doc) return events.throwDom(cx, .wrong_document);
    if (a.owner) |o| {
        if (o == n) return cx.dup(v);
        return events.throwDom(cx, .inuse_attribute);
    }
    // The attribute it replaces, now detached.
    const idx = if (by_ns) n.attrIndex(a.ns, a.local) else n.attrIndexQ(a.name());
    const replaced: Value = if (idx) |i| blk: {
        const r = try Attr.ofElement(s, n, i);
        if (cx.unwrap(Attr, r)) |ra| try ra.detachFrom();
        break :blk r;
    } else js.null;
    errdefer cx.free(replaced);
    const old = if (idx) |i| try s.gpa.dupe(u8, n.attrs.items[i].value) else null;
    defer if (old) |o| s.gpa.free(o);
    try n.setAttrNS(a.ns, a.prefix, a.local, a.value);
    a.attachTo(n);
    try s.attrChanged(n, a.name(), old, a.value);
    return replaced;
}

fn removeAttributeNode(n: *Node, cx: *js.Context, v: Value) js.Error!Value {
    const s = scriptOf(cx);
    const a = cx.unwrap(Attr, v) orelse return error.TypeError;
    if (a.owner != n) return events.throwDom(cx, .not_found);
    const i = n.attrIndex(a.ns, a.local) orelse return events.throwDom(cx, .not_found);
    try a.detachFrom();
    const old = try s.gpa.dupe(u8, n.attrs.items[i].value);
    defer s.gpa.free(old);
    n.removeAttrAt(i);
    try s.attrChanged(n, a.name(), old, null);
    return cx.dup(v);
}

fn getElementsByTagName(n: *Node, cx: *js.Context, name: []const u8) js.Error!Value {
    return NodeList.make(scriptOf(cx), n.doc, .{ .tag = .{ .root = n, .ns = null, .name = try n.doc.intern(name) } });
}

fn getElementsByTagNameNS(n: *Node, cx: *js.Context, ns: js.NullStr, local: []const u8) js.Error!Value {
    return NodeList.make(scriptOf(cx), n.doc, .{ .tag = .{ .root = n, .ns = try n.doc.intern(ns.s orelse ""), .name = try n.doc.intern(local), .by_ns = true } });
}

fn getAttributeNS(n: *Node, ns: js.NullStr, local: []const u8) []const u8 {
    return n.attrNS(ns.s orelse "", local) orelse "";
}

fn setAttributeNS(n: *Node, cx: *js.Context, ns_v: js.NullStr, qname: []const u8, value: []const u8) js.Error!void {
    const ns = ns_v.s orelse "";
    const split = try checkQName(cx, ns, qname);
    if (std.mem.eql(u8, qname, "xmlns") and !std.mem.eql(u8, ns, dom.xmlns_ns)) return events.throwDom(cx, .namespace);
    if (std.mem.eql(u8, split.prefix, "xmlns") and !std.mem.eql(u8, ns, dom.xmlns_ns)) return events.throwDom(cx, .namespace);
    const s = scriptOf(cx);
    const prev = n.attrNS(ns, split.local);
    const old = if (prev) |p| try s.gpa.dupe(u8, p) else null;
    defer if (old) |o| s.gpa.free(o);
    if (n.attrIndex(ns, split.local)) |i| n.attrs.items[i].prefix = try n.doc.intern(split.prefix);
    try n.setAttrNS(ns, split.prefix, split.local, value);
    try s.attrChanged(n, qname, old, value);
}

fn removeAttributeNS(n: *Node, cx: *js.Context, ns: js.NullStr, local: []const u8) js.Error!void {
    const i = n.attrIndex(ns.s orelse "", local) orelse return;
    const s = scriptOf(cx);
    const old = try s.gpa.dupe(u8, n.attrs.items[i].value);
    defer s.gpa.free(old);
    n.removeAttrAt(i);
    try s.attrChanged(n, local, old, null);
}

fn getAttributeNodeNS(n: *Node, cx: *js.Context, ns: js.NullStr, local: []const u8) js.Error!Value {
    const i = n.attrIndex(ns.s orelse "", local) orelse return js.null;
    return Attr.ofElement(scriptOf(cx), n, i);
}

fn hasAttribute(n: *Node, name: []const u8) bool {
    return n.attrIndexQ(name) != null;
}

fn hasAttributeNS(n: *Node, ns: js.NullStr, local: []const u8) bool {
    return n.attrIndex(ns.s orelse "", local) != null;
}

const element_members = [_]js.Member{
    js.prop("tagName", tagName, null),
    js.method("getAttribute", getAttribute),
    js.method("setAttribute", setAttribute),
    js.method("removeAttribute", removeAttribute),
    js.method("getAttributeNode", getAttributeNode),
    js.method("setAttributeNode", setAttributeNode),
    js.method("removeAttributeNode", removeAttributeNode),
    js.method("getElementsByTagName", getElementsByTagName),
    js.method("getAttributeNS", getAttributeNS),
    js.method("setAttributeNS", setAttributeNS),
    js.method("removeAttributeNS", removeAttributeNS),
    js.method("getAttributeNodeNS", getAttributeNodeNS),
    js.method("setAttributeNodeNS", setAttributeNodeNS),
    js.method("getElementsByTagNameNS", getElementsByTagNameNS),
    js.method("hasAttribute", hasAttribute),
    js.method("hasAttributeNS", hasAttributeNS),
};

const element_class: js.Class = .{ .name = "Element", .parent = &node_class, .finalize = finalizeNode, .members = &element_members };

/// AnimatableElement (Z.13.1.4): the page's elements.
pub const animatable_element_class: js.Class = .{
    .name = "AnimatableElement",
    .parent = &element_class,
    .finalize = finalizeNode,
    .members = &@import("anim_api.zig").element_members,
};

// ---- CharacterData, Text, Comment, CDATASection, ProcessingInstruction, DocumentFragment ------------------------

/// The byte offset of UTF-16 offset `units` in UTF-8 `s`, or null past its end.
fn byteOffset(s: []const u8, units: u32) ?usize {
    var u: u32 = 0;
    var i: usize = 0;
    while (u < units) {
        if (i >= s.len) return null;
        const len = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        u += if (len == 4) 2 else 1;
        i += len;
        if (u > units) return i; // the middle of a surrogate pair: after it
    }
    return @min(i, s.len);
}

fn utf16Len(s: []const u8) u32 {
    var u: u32 = 0;
    var i: usize = 0;
    while (i < s.len) {
        const len = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        u += if (len == 4) 2 else 1;
        i += len;
    }
    return u;
}

fn setData(cx: *js.Context, n: *Node, data: []const u8) js.Error!void {
    const s = scriptOf(cx);
    const old = try s.gpa.dupe(u8, n.data);
    defer s.gpa.free(old);
    try n.setData(data);
    try s.dataChanged(n, old);
}

fn getData(n: *Node) []const u8 {
    return n.data;
}

fn setDataProp(n: *Node, cx: *js.Context, v: []const u8) js.Error!void {
    try setData(cx, n, v);
}

fn getLength(n: *Node) u32 {
    return utf16Len(n.data);
}

fn range(cx: *js.Context, n: *Node, offset: u32, count: u32) js.Error![2]usize {
    const a = byteOffset(n.data, offset) orelse return events.throwDom(cx, .index_size);
    const end = byteOffset(n.data, offset +| count) orelse n.data.len;
    return .{ a, end };
}

fn substringData(n: *Node, cx: *js.Context, offset: u32, count: u32) js.Error![]const u8 {
    const r = try range(cx, n, offset, count);
    return n.data[r[0]..r[1]];
}

fn appendData(n: *Node, cx: *js.Context, arg: []const u8) js.Error!void {
    const joined = try std.mem.concat(cx.gpa, u8, &.{ n.data, arg });
    defer cx.gpa.free(joined);
    try setData(cx, n, joined);
}

fn insertData(n: *Node, cx: *js.Context, offset: u32, arg: []const u8) js.Error!void {
    const at = byteOffset(n.data, offset) orelse return events.throwDom(cx, .index_size);
    const joined = try std.mem.concat(cx.gpa, u8, &.{ n.data[0..at], arg, n.data[at..] });
    defer cx.gpa.free(joined);
    try setData(cx, n, joined);
}

fn deleteData(n: *Node, cx: *js.Context, offset: u32, count: u32) js.Error!void {
    const r = try range(cx, n, offset, count);
    const joined = try std.mem.concat(cx.gpa, u8, &.{ n.data[0..r[0]], n.data[r[1]..] });
    defer cx.gpa.free(joined);
    try setData(cx, n, joined);
}

fn replaceData(n: *Node, cx: *js.Context, offset: u32, count: u32, arg: []const u8) js.Error!void {
    const r = try range(cx, n, offset, count);
    const joined = try std.mem.concat(cx.gpa, u8, &.{ n.data[0..r[0]], arg, n.data[r[1]..] });
    defer cx.gpa.free(joined);
    try setData(cx, n, joined);
}

fn splitText(n: *Node, cx: *js.Context, offset: u32) js.Error!Value {
    const at = byteOffset(n.data, offset) orelse return events.throwDom(cx, .index_size);
    const rest = try n.doc.createText(n.type, n.data[at..]);
    try setData(cx, n, n.data[0..at]);
    if (n.parent) |p| {
        p.insertBefore(rest, n.next);
        try scriptOf(cx).afterInsertion(rest);
    }
    return wrap(scriptOf(cx), rest);
}

const character_data_class: js.Class = .{
    .name = "CharacterData",
    .parent = &node_class,
    .finalize = finalizeNode,
    .members = &.{
        js.prop("data", getData, setDataProp),
        js.prop("length", getLength, null),
        js.method("substringData", substringData),
        js.method("appendData", appendData),
        js.method("insertData", insertData),
        js.method("deleteData", deleteData),
        js.method("replaceData", replaceData),
    },
};

const text_class: js.Class = .{ .name = "Text", .parent = &character_data_class, .finalize = finalizeNode, .members = &.{js.method("splitText", splitText)} };
const comment_class: js.Class = .{ .name = "Comment", .parent = &character_data_class, .finalize = finalizeNode };
const cdata_class: js.Class = .{ .name = "CDATASection", .parent = &text_class, .finalize = finalizeNode };

fn piTarget(n: *Node) []const u8 {
    return n.local;
}

const pi_class: js.Class = .{
    .name = "ProcessingInstruction",
    .parent = &node_class,
    .finalize = finalizeNode,
    .members = &.{ js.prop("target", piTarget, null), js.prop("data", getData, setDataProp) },
};

const fragment_class: js.Class = .{ .name = "DocumentFragment", .parent = &node_class, .finalize = finalizeNode };

// ---- Document -----------------------------------------------------------------------------------------------------

fn getDoctype(_: *Node) Value {
    return js.null;
}

fn getImplementation(_: *Node, cx: *js.Context) Value {
    return cx.dup(scriptOf(cx).parser_obj);
}

fn getDocumentElement(n: *Node, cx: *js.Context) js.Error!Value {
    return wrapOrNull(scriptOf(cx), n.firstElement());
}

fn createElement(n: *Node, cx: *js.Context, name: []const u8) js.Error!Value {
    if (!isXmlName(name)) return events.throwDom(cx, .invalid_character);
    const e = try n.doc.createElementNS("", name);
    return wrap(scriptOf(cx), e);
}

fn createElementNS(n: *Node, cx: *js.Context, ns_v: js.NullStr, qname: []const u8) js.Error!Value {
    const ns = ns_v.s orelse "";
    _ = try checkQName(cx, ns, qname);
    const e = try n.doc.createElementNS(ns, qname);
    return wrap(scriptOf(cx), e);
}

fn createDocumentFragment(n: *Node, cx: *js.Context) js.Error!Value {
    return wrap(scriptOf(cx), try n.doc.newNode(.fragment));
}

fn createTextNode(n: *Node, cx: *js.Context, data: []const u8) js.Error!Value {
    return wrap(scriptOf(cx), try n.doc.createText(.text, data));
}

fn createComment(n: *Node, cx: *js.Context, data: []const u8) js.Error!Value {
    return wrap(scriptOf(cx), try n.doc.createText(.comment, data));
}

fn createCDATASection(n: *Node, cx: *js.Context, data: []const u8) js.Error!Value {
    return wrap(scriptOf(cx), try n.doc.createText(.cdata, data));
}

fn createProcessingInstruction(n: *Node, cx: *js.Context, target: []const u8, data: []const u8) js.Error!Value {
    if (!isXmlName(target)) return events.throwDom(cx, .invalid_character);
    const pi = try n.doc.createText(.pi, data);
    pi.local = try n.doc.intern(target);
    return wrap(scriptOf(cx), pi);
}

fn createAttribute(n: *Node, cx: *js.Context, name: []const u8) js.Error!Value {
    if (!isXmlName(name)) return events.throwDom(cx, .invalid_character);
    return Attr.detached(scriptOf(cx), n.doc, "", "", name);
}

fn createAttributeNS(n: *Node, cx: *js.Context, ns_v: js.NullStr, qname: []const u8) js.Error!Value {
    const ns = ns_v.s orelse "";
    const split = try checkQName(cx, ns, qname);
    if (std.mem.eql(u8, qname, "xmlns") and !std.mem.eql(u8, ns, dom.xmlns_ns)) return events.throwDom(cx, .namespace);
    return Attr.detached(scriptOf(cx), n.doc, ns, split.prefix, split.local);
}

fn createEntityReference(_: *Node, cx: *js.Context, _: []const u8) js.Error!Value {
    return events.throwDom(cx, .not_supported);
}

fn importNode(n: *Node, cx: *js.Context, v: Value, deep: bool) js.Error!Value {
    if (cx.unwrap(Attr, v)) |a| return Attr.detached(scriptOf(cx), n.doc, a.ns, a.prefix, a.local) catch |e| e;
    const src = nodeOf(cx, v) orelse return error.TypeError;
    if (src.type == .document) return events.throwDom(cx, .not_supported);
    return wrap(scriptOf(cx), try n.doc.importNode(src, deep));
}

/// getElementById only for markup and navigation files (Table Z.12.5-1): by the document's suffix.
fn idAllowed(doc: *const dom.Document) bool {
    const u = doc.uri;
    const dot = std.mem.lastIndexOfScalar(u8, u, '.') orelse return false;
    const ext = u[dot + 1 ..];
    for ([_][]const u8{ "xpl", "xmf", "xmu", "xas", "xss", "xts" }) |x| if (std.ascii.eqlIgnoreCase(ext, x)) return true;
    return false;
}

fn getElementById(n: *Node, cx: *js.Context, id: []const u8) js.Error!Value {
    if (!idAllowed(n.doc)) return js.null;
    return wrapOrNull(scriptOf(cx), n.doc.getElementById(id));
}

fn createEventDoc(_: *Node, cx: *js.Context, event_type: []const u8) js.Error!Value {
    return events.createEvent(cx, event_type, scriptOf(cx).nowMs());
}

// XPath interfaces (Z.12.7).

fn evaluateXPath(n: *Node, cx: *js.Context, expr: []const u8, ctx_v: Value) js.Error!Value {
    const s = scriptOf(cx);
    const ctx_node = nodeOf(cx, ctx_v) orelse return error.TypeError;
    if (ctx_node.doc != n.doc) return error.TypeError;
    var x = xpath.compile(s.gpa, expr) catch return error.EvalError;
    defer x.deinit();
    var arena: std.heap.ArenaAllocator = .init(s.gpa);
    defer arena.deinit();
    const st = try stateOf(s, n.doc);
    var h = if (st.page) s.pageXPathHost() else xpath.Host{};
    var vh: VarHost = .{ .st = st, .next = h };
    h.ctx = &vh;
    h.variable = VarHost.lookup;
    const scope: *const Node = if (ctx_node.type == .element) ctx_node else n.firstElement() orelse ctx_node;
    const r = x.eval(arena.allocator(), .{ .node = ctx_node, .scope = scope, .host = &h }) catch return error.EvalError;
    if (r != .nodes) return js.null;
    var list: std.ArrayList(*Node) = .empty;
    defer list.deinit(s.gpa);
    for (r.nodes) |it| if (it.attr == null) try list.append(s.gpa, it.node);
    return NodeList.make(s, n.doc, .{ .fixed = try s.gpa.dupe(*Node, list.items) });
}

/// Script variables first, then the presentation engine's (the page's host).
const VarHost = struct {
    st: *DocState,
    next: xpath.Host,

    fn lookup(ctx: ?*anyopaque, ns: []const u8, local: []const u8) ?xpath.Value {
        const self: *VarHost = @ptrCast(@alignCast(ctx.?));
        if (ns.len == 0) if (self.st.vars.get(local)) |v| return .{ .string = v };
        const f = self.next.variable orelse return null;
        return f(self.next.ctx, ns, local);
    }
};

fn isVarName(name: []const u8) bool {
    return isXmlName(name);
}

fn setXPathVariable(n: *Node, cx: *js.Context, name: []const u8, value: js.NullStr) js.Error!void {
    const s = scriptOf(cx);
    if (!isVarName(name)) return error.TypeError;
    if (s.systemVariable(name) != null) return error.TypeError;
    const st = try stateOf(s, n.doc);
    if (value.s) |v| {
        const copy = try s.gpa.dupe(u8, v);
        errdefer s.gpa.free(copy);
        const gop = try st.vars.getOrPut(s.gpa, name);
        if (gop.found_existing) s.gpa.free(gop.value_ptr.*) else gop.key_ptr.* = s.gpa.dupe(u8, name) catch |e| {
            _ = st.vars.remove(name);
            return e;
        };
        gop.value_ptr.* = copy;
    } else if (st.vars.fetchRemove(name)) |kv| {
        s.gpa.free(kv.key);
        s.gpa.free(kv.value);
    }
}

fn getXPathVariable(n: *Node, cx: *js.Context, name: []const u8) js.Error!Value {
    const s = scriptOf(cx);
    if (!isVarName(name)) return error.TypeError;
    if (s.systemVariable(name)) |v| return switch (v) {
        .string => |x| cx.string(x),
        .number => |x| cx.number(x),
        .boolean => |x| cx.boolean(x),
        .nodes => js.null,
    };
    const st = try stateOf(s, n.doc);
    return if (st.vars.get(name)) |v| cx.string(v) else js.null;
}

const document_members = [_]js.Member{
    js.prop("doctype", getDoctype, null),
    js.prop("implementation", getImplementation, null),
    js.prop("documentElement", getDocumentElement, null),
    js.method("createElement", createElement),
    js.method("createDocumentFragment", createDocumentFragment),
    js.method("createTextNode", createTextNode),
    js.method("createComment", createComment),
    js.method("createCDATASection", createCDATASection),
    js.method("createProcessingInstruction", createProcessingInstruction),
    js.method("createAttribute", createAttribute),
    js.method("createEntityReference", createEntityReference),
    js.method("getElementsByTagName", getElementsByTagName),
    js.method("importNode", importNode),
    js.method("createElementNS", createElementNS),
    js.method("createAttributeNS", createAttributeNS),
    js.method("getElementsByTagNameNS", getElementsByTagNameNS),
    js.method("getElementById", getElementById),
    js.method("createEvent", createEventDoc),
    js.method("evaluateXPath", evaluateXPath),
    js.method("setXPathVariable", setXPathVariable),
    js.method("getXPathVariable", getXPathVariable),
};

const document_class: js.Class = .{ .name = "Document", .parent = &node_class, .finalize = finalizeNode, .members = &document_members };

/// `document.foo` is the element with id "foo" (Z.13.1.1), unless Document has a property of that name.
fn namedElement(cx: *js.Context, ptr: *anyopaque, name: []const u8) js.Error!?Value {
    const n: *Node = @ptrCast(@alignCast(ptr));
    const el = n.doc.getElementById(name) orelse return null;
    return try wrap(scriptOf(cx), el);
}

const animatable_document_exotic: js.Exotic = .{ .named = namedElement };

/// AnimatableDocument (Z.13.1.1): the page's document.
pub const animatable_document_class: js.Class = .{
    .name = "AnimatableDocument",
    .parent = &document_class,
    .finalize = finalizeNode,
    .exotic = &animatable_document_exotic,
    .members = &@import("anim_api.zig").document_members,
};

// ---- Attr ---------------------------------------------------------------------------------------------------------

/// An attribute node (dom.zig keeps attributes inside their element): its element and name, or, detached, its
/// own value.
pub const Attr = struct {
    doc: *dom.Document,
    owner: ?*Node,
    ns: []const u8,
    prefix: []const u8,
    local: []const u8,
    /// Detached: its value (owned); attached: unused.
    value: []u8,
    obj: *anyopaque = undefined,

    fn ofElement(s: *Script, el: *Node, i: usize) js.Error!Value {
        const at = el.attrs.items[i];
        const a = try s.gpa.create(Attr);
        a.* = .{ .doc = el.doc, .owner = el, .ns = at.ns, .prefix = at.prefix, .local = at.local, .value = &.{} };
        return wrapDependent(s, Attr, &attr_class, a, el.doc) catch |e| {
            s.gpa.destroy(a);
            return e;
        };
    }

    fn detached(s: *Script, doc: *dom.Document, ns: []const u8, prefix: []const u8, local: []const u8) js.Error!Value {
        const a = try s.gpa.create(Attr);
        a.* = .{ .doc = doc, .owner = null, .ns = try doc.intern(ns), .prefix = try doc.intern(prefix), .local = try doc.intern(local), .value = &.{} };
        return wrapDependent(s, Attr, &attr_class, a, doc) catch |e| {
            s.gpa.destroy(a);
            return e;
        };
    }

    fn name(a: *const Attr) []const u8 {
        if (a.prefix.len == 0) return a.local;
        var buf: [512]u8 = undefined;
        const full = std.fmt.bufPrint(&buf, "{s}:{s}", .{ a.prefix, a.local }) catch return a.local;
        return a.doc.intern(full) catch a.local;
    }

    fn current(a: *const Attr) []const u8 {
        if (a.owner) |o| return o.attrNS(a.ns, a.local) orelse "";
        return a.value;
    }

    /// Keeps the value it has now, and leaves its element.
    fn detachFrom(a: *Attr) !void {
        const v = try a.doc.gpa.dupe(u8, a.current());
        a.doc.gpa.free(a.value);
        a.value = v;
        a.owner = null;
    }

    fn attachTo(a: *Attr, el: *Node) void {
        a.doc.gpa.free(a.value);
        a.value = &.{};
        a.owner = el;
    }

    fn finalize(ptr: *anyopaque, _: *js.Runtime) void {
        const a: *Attr = @ptrCast(@alignCast(ptr));
        const doc = a.doc;
        doc.gpa.free(a.value);
        const obj = a.obj;
        doc.gpa.destroy(a);
        dropDependent(doc, obj);
    }

    fn getName(a: *Attr) []const u8 {
        return a.name();
    }
    fn getSpecified(_: *Attr) bool {
        return true;
    }
    fn getValue(a: *Attr) []const u8 {
        return a.current();
    }
    fn setValue(a: *Attr, cx: *js.Context, v: []const u8) js.Error!void {
        if (a.owner) |o| {
            const s = scriptOf(cx);
            const old = try s.gpa.dupe(u8, a.current());
            defer s.gpa.free(old);
            try o.setAttrNS(a.ns, a.prefix, a.local, v);
            try s.attrChanged(o, a.name(), old, v);
        } else {
            const copy = try a.doc.gpa.dupe(u8, v);
            a.doc.gpa.free(a.value);
            a.value = copy;
        }
    }
    fn getOwnerElement(a: *Attr, cx: *js.Context) js.Error!Value {
        return wrapOrNull(scriptOf(cx), a.owner);
    }
    fn nodeType(_: *Attr) u32 {
        return NodeType.attribute;
    }
    fn getNs(a: *Attr, cx: *js.Context) js.Error!Value {
        return if (a.ns.len == 0) js.null else cx.string(a.ns);
    }
    fn getPrefixA(a: *Attr, cx: *js.Context) js.Error!Value {
        return if (a.prefix.len == 0) js.null else cx.string(a.prefix);
    }
    fn getLocal(a: *Attr) []const u8 {
        return a.local;
    }
    fn getOwnerDoc(a: *Attr, cx: *js.Context) js.Error!Value {
        return wrap(scriptOf(cx), &a.doc.node);
    }
    fn nullValue(_: *Attr) Value {
        return js.null;
    }
    fn falseValue(_: *Attr) bool {
        return false;
    }
    fn childNodes(a: *Attr, cx: *js.Context) js.Error!Value {
        return NodeList.make(scriptOf(cx), a.doc, .{ .fixed = &.{} });
    }
    fn cloneAttr(a: *Attr, cx: *js.Context, _: bool) js.Error!Value {
        const v = try detached(scriptOf(cx), a.doc, a.ns, a.prefix, a.local);
        if (cx.unwrap(Attr, v)) |b| b.value = try a.doc.gpa.dupe(u8, a.current());
        return v;
    }

    pub const js_class = attr_class;
};

const attr_class: js.Class = .{
    .name = "Attr",
    .finalize = Attr.finalize,
    .members = &([_]js.Member{
        js.prop("name", Attr.getName, null),
        js.prop("specified", Attr.getSpecified, null),
        js.prop("value", Attr.getValue, Attr.setValue),
        js.prop("ownerElement", Attr.getOwnerElement, null),
        js.prop("nodeName", Attr.getName, null),
        js.prop("nodeValue", Attr.getValue, Attr.setValue),
        js.prop("nodeType", Attr.nodeType, null),
        js.prop("namespaceURI", Attr.getNs, null),
        js.prop("prefix", Attr.getPrefixA, null),
        js.prop("localName", Attr.getLocal, null),
        js.prop("ownerDocument", Attr.getOwnerDoc, null),
        js.prop("parentNode", Attr.nullValue, null),
        js.prop("firstChild", Attr.nullValue, null),
        js.prop("lastChild", Attr.nullValue, null),
        js.prop("previousSibling", Attr.nullValue, null),
        js.prop("nextSibling", Attr.nullValue, null),
        js.prop("attributes", Attr.nullValue, null),
        js.prop("childNodes", Attr.childNodes, null),
        js.method("hasChildNodes", Attr.falseValue),
        js.method("hasAttributes", Attr.falseValue),
        js.method("cloneNode", Attr.cloneAttr),
    } ++ node_constants),
};

// ---- NodeList, NamedNodeMap ---------------------------------------------------------------------------------------

pub const NodeList = struct {
    doc: *dom.Document,
    src: Source,
    obj: *anyopaque = undefined,

    const Source = union(enum) {
        /// Live: a node's children.
        children: *Node,
        /// Live: elements by name under a node, in document order.
        tag: struct { root: *Node, ns: ?[]const u8, name: []const u8, by_ns: bool = false },
        /// A snapshot (owned).
        fixed: []*Node,
    };

    fn make(s: *Script, doc: *dom.Document, src: Source) js.Error!Value {
        const l = try s.gpa.create(NodeList);
        l.* = .{ .doc = doc, .src = src };
        return wrapDependent(s, NodeList, &node_list_class, l, doc) catch |e| {
            if (src == .fixed) s.gpa.free(src.fixed);
            s.gpa.destroy(l);
            return e;
        };
    }

    fn finalize(ptr: *anyopaque, _: *js.Runtime) void {
        const l: *NodeList = @ptrCast(@alignCast(ptr));
        const doc = l.doc;
        if (l.src == .fixed) doc.gpa.free(l.src.fixed);
        const obj = l.obj;
        doc.gpa.destroy(l);
        dropDependent(doc, obj);
    }

    fn matches(l: *const NodeList, n: *const Node) bool {
        const t = l.src.tag;
        if (n.type != .element) return false;
        if (t.by_ns) {
            const ns = t.ns.?;
            if (!std.mem.eql(u8, ns, "*") and !std.mem.eql(u8, n.ns, ns)) return false;
            return std.mem.eql(u8, t.name, "*") or std.mem.eql(u8, n.local, t.name);
        }
        return std.mem.eql(u8, t.name, "*") or std.mem.eql(u8, n.qname(), t.name);
    }

    fn at(l: *const NodeList, index: u32) ?*Node {
        var i: u32 = 0;
        switch (l.src) {
            .children => |p| {
                var x = p.first;
                while (x) |k| : (x = k.next) {
                    if (i == index) return k;
                    i += 1;
                }
            },
            .tag => |t| {
                var x = t.root.first;
                while (x) |k| : (x = k.following(t.root)) if (l.matches(k)) {
                    if (i == index) return k;
                    i += 1;
                };
            },
            .fixed => |f| return if (index < f.len) f[index] else null,
        }
        return null;
    }

    fn count(l: *const NodeList) u32 {
        var i: u32 = 0;
        switch (l.src) {
            .children => |p| {
                var x = p.first;
                while (x) |k| : (x = k.next) i += 1;
            },
            .tag => |t| {
                var x = t.root.first;
                while (x) |k| : (x = k.following(t.root)) if (l.matches(k)) {
                    i += 1;
                };
            },
            .fixed => |f| i = @intCast(f.len),
        }
        return i;
    }

    fn item(l: *NodeList, cx: *js.Context, index: u32) js.Error!Value {
        return wrapOrNull(scriptOf(cx), l.at(index));
    }

    fn getLength(l: *NodeList) u32 {
        return l.count();
    }

    fn exLength(_: *js.Context, ptr: *anyopaque) u32 {
        const l: *NodeList = @ptrCast(@alignCast(ptr));
        return l.count();
    }

    fn exItem(cx: *js.Context, ptr: *anyopaque, i: u32) js.Error!Value {
        const l: *NodeList = @ptrCast(@alignCast(ptr));
        return l.item(cx, i);
    }

    pub const js_class = node_list_class;
};

const node_list_exotic: js.Exotic = .{ .length = NodeList.exLength, .item = NodeList.exItem };

const node_list_class: js.Class = .{
    .name = "NodeList",
    .finalize = NodeList.finalize,
    .exotic = &node_list_exotic,
    .members = &.{ js.prop("length", NodeList.getLength, null), js.method("item", NodeList.item) },
};

/// An element's attributes (NamedNodeMap).
pub const AttrMap = struct {
    el: *Node,
    obj: *anyopaque = undefined,

    fn make(s: *Script, el: *Node) js.Error!Value {
        const m = try s.gpa.create(AttrMap);
        m.* = .{ .el = el };
        return wrapDependent(s, AttrMap, &attr_map_class, m, el.doc) catch |e| {
            s.gpa.destroy(m);
            return e;
        };
    }

    fn finalize(ptr: *anyopaque, _: *js.Runtime) void {
        const m: *AttrMap = @ptrCast(@alignCast(ptr));
        const doc = m.el.doc;
        const obj = m.obj;
        doc.gpa.destroy(m);
        dropDependent(doc, obj);
    }

    fn getLength(m: *AttrMap) u32 {
        return @intCast(m.el.attrs.items.len);
    }
    fn item(m: *AttrMap, cx: *js.Context, i: u32) js.Error!Value {
        if (i >= m.el.attrs.items.len) return js.null;
        return Attr.ofElement(scriptOf(cx), m.el, i);
    }
    fn getNamedItem(m: *AttrMap, cx: *js.Context, name: []const u8) js.Error!Value {
        return getAttributeNode(m.el, cx, name);
    }
    fn setNamedItem(m: *AttrMap, cx: *js.Context, v: Value) js.Error!Value {
        return setAttributeNode(m.el, cx, v);
    }
    fn removeNamedItem(m: *AttrMap, cx: *js.Context, name: []const u8) js.Error!Value {
        const i = m.el.attrIndexQ(name) orelse return events.throwDom(cx, .not_found);
        const v = try Attr.ofElement(scriptOf(cx), m.el, i);
        errdefer cx.free(v);
        const r = try removeAttributeNode(m.el, cx, v);
        cx.free(r);
        return v;
    }
    fn getNamedItemNS(m: *AttrMap, cx: *js.Context, ns: js.NullStr, local: []const u8) js.Error!Value {
        return getAttributeNodeNS(m.el, cx, ns, local);
    }
    fn setNamedItemNS(m: *AttrMap, cx: *js.Context, v: Value) js.Error!Value {
        return setAttributeNodeNS(m.el, cx, v);
    }
    fn removeNamedItemNS(m: *AttrMap, cx: *js.Context, ns: js.NullStr, local: []const u8) js.Error!Value {
        const i = m.el.attrIndex(ns.s orelse "", local) orelse return events.throwDom(cx, .not_found);
        const v = try Attr.ofElement(scriptOf(cx), m.el, i);
        errdefer cx.free(v);
        const r = try removeAttributeNode(m.el, cx, v);
        cx.free(r);
        return v;
    }

    fn exLength(_: *js.Context, ptr: *anyopaque) u32 {
        const m: *AttrMap = @ptrCast(@alignCast(ptr));
        return @intCast(m.el.attrs.items.len);
    }
    fn exItem(cx: *js.Context, ptr: *anyopaque, i: u32) js.Error!Value {
        const m: *AttrMap = @ptrCast(@alignCast(ptr));
        return m.item(cx, i);
    }

    pub const js_class = attr_map_class;
};

const attr_map_exotic: js.Exotic = .{ .length = AttrMap.exLength, .item = AttrMap.exItem };

const attr_map_class: js.Class = .{
    .name = "NamedNodeMap",
    .finalize = AttrMap.finalize,
    .exotic = &attr_map_exotic,
    .members = &.{
        js.prop("length", AttrMap.getLength, null),
        js.method("item", AttrMap.item),
        js.method("getNamedItem", AttrMap.getNamedItem),
        js.method("setNamedItem", AttrMap.setNamedItem),
        js.method("removeNamedItem", AttrMap.removeNamedItem),
        js.method("getNamedItemNS", AttrMap.getNamedItemNS),
        js.method("setNamedItemNS", AttrMap.setNamedItemNS),
        js.method("removeNamedItemNS", AttrMap.removeNamedItemNS),
    },
};

// ---- names --------------------------------------------------------------------------------------------------------

fn isNameStart(ch: u8) bool {
    return std.ascii.isAlphabetic(ch) or ch == '_' or ch == ':' or ch >= 0x80;
}

fn isNameChar(ch: u8) bool {
    return isNameStart(ch) or std.ascii.isDigit(ch) or ch == '-' or ch == '.';
}

/// An XML Name (non-ASCII characters are all accepted).
pub fn isXmlName(s: []const u8) bool {
    if (s.len == 0 or !isNameStart(s[0])) return false;
    for (s[1..]) |ch| if (!isNameChar(ch)) return false;
    return true;
}

fn isNcName(s: []const u8) bool {
    return isXmlName(s) and std.mem.indexOfScalar(u8, s, ':') == null;
}

const QName = struct { prefix: []const u8, local: []const u8 };

/// DOM2's checks of a qualified name and its namespace: INVALID_CHARACTER_ERR, NAMESPACE_ERR.
fn checkQName(cx: *js.Context, ns: []const u8, qname: []const u8) js.Error!QName {
    if (!isXmlName(qname)) return events.throwDom(cx, .invalid_character);
    const colon = std.mem.indexOfScalar(u8, qname, ':');
    const q: QName = if (colon) |i| .{ .prefix = qname[0..i], .local = qname[i + 1 ..] } else .{ .prefix = "", .local = qname };
    if (colon != null and (!isNcName(q.prefix) or !isNcName(q.local))) return events.throwDom(cx, .namespace);
    if (q.prefix.len > 0 and ns.len == 0) return events.throwDom(cx, .namespace);
    if (std.mem.eql(u8, q.prefix, "xml") and !std.mem.eql(u8, ns, dom.xml_ns)) return events.throwDom(cx, .namespace);
    return q;
}

// ---- DOMImplementation (the XMLParser object implements it, Z.12.9.1) ---------------------------------------------

pub fn hasFeature(_: *Script, feature: []const u8, version: js.NullStr) bool {
    return hasFeatureImpl(feature, version.s);
}

pub fn createDocumentType(_: *Script, cx: *js.Context, _: []const u8, _: []const u8, _: []const u8) js.Error!Value {
    return events.throwDom(cx, .not_supported); // Table Z.12.5-1: shall not be used
}

/// DOMImplementation.createDocument(namespaceURI, qualifiedName, doctype): doctype is always null.
pub fn createDocument(s: *Script, cx: *js.Context, ns_v: js.NullStr, qname: js.NullStr, doctype: Value) js.Error!Value {
    if (!c.JS_IsNull(doctype) and !c.JS_IsUndefined(doctype)) return events.throwDom(cx, .wrong_document);
    const doc = try dom.Document.create(s.gpa);
    errdefer doc.destroy();
    if (qname.s) |q| {
        const ns = ns_v.s orelse "";
        _ = try checkQName(cx, ns, q);
        const root = try doc.createElementNS(ns, q);
        doc.node.appendChild(root);
    }
    return adoptDocument(s, doc);
}

/// The global constructors of the DOM (Z.12.5): Node only (DOMException is with the events).
pub fn exposeConstructors(cx: *js.Context) js.Error!void {
    try cx.exposeConstructor(&node_class, "Node", error.EvalError, &node_constants);
}

// ---- tests --------------------------------------------------------------------------------------------------------

const testenv = @import("testenv.zig");

test "DOM Level 2 Core" {
    const e = try testenv.Env.create();
    defer e.destroy();
    try e.run(
        \\var doc = XMLParser.parseString('<?xml version="1.0"?><r xmlns:a="urn:a"><x id="1" a:k="v">t<!--c--><y/></x><z/></r>');
        \\assert(doc instanceof Node, "a Node"); assertEq(doc.nodeType, Node.DOCUMENT_NODE); assertEq(doc.nodeName, "#document");
        \\assertEq(doc.doctype, null); assertEq(doc.implementation, XMLParser);
        \\var r = doc.documentElement; assertEq(r.tagName, "r"); assertEq(r.parentNode, doc); assertEq(r.ownerDocument, doc);
        \\var x = r.firstChild; assertEq(x, r.childNodes.item(0), "identity"); assertEq(x, r.childNodes[0], "index");
        \\assertEq(r.childNodes.length, 2); assertEq(r.childNodes[2], undefined);
        \\assertEq(x.getAttribute("id"), "1"); assertEq(x.getAttribute("none"), "");
        \\assertEq(x.getAttributeNS("urn:a", "k"), "v"); assert(x.hasAttributeNS("urn:a", "k"));
        \\assertEq(x.attributes.length, 2); assertEq(x.attributes.getNamedItem("id").value, "1");
        \\var t = x.firstChild; assertEq(t.nodeType, 3); assertEq(t.data, "t"); assertEq(t.nextSibling.nodeType, 8);
        \\// getElementById only for markup files (Table Z.12.5-1).
        \\assertEq(doc.getElementById("1"), null);
        \\// Live lists.
        \\var all = doc.getElementsByTagName("*"); assertEq(all.length, 4);
        \\var e2 = doc.createElement("w"); r.appendChild(e2); assertEq(all.length, 5); assertEq(r.lastChild, e2);
        \\r.insertBefore(e2, x); assertEq(r.firstChild, e2);
        \\assertEq(r.removeChild(e2), e2); assertEq(e2.parentNode, null);
        \\var old = r.replaceChild(e2, r.lastChild); assertEq(old.tagName, "z"); assertEq(r.lastChild, e2);
        \\// Errors.
        \\try { r.removeChild(old); assert(false); } catch (ex) { assert(ex instanceof DOMException); assertEq(ex.code, DOMException.NOT_FOUND_ERR); }
        \\try { x.appendChild(r); assert(false); } catch (ex) { assertEq(ex.code, DOMException.HIERARCHY_REQUEST_ERR); }
        \\try { doc.createElement("1x"); assert(false); } catch (ex) { assertEq(ex.code, DOMException.INVALID_CHARACTER_ERR); }
        \\var other = XMLParser.parseString("<o/>");
        \\try { r.appendChild(other.documentElement); assert(false); } catch (ex) { assertEq(ex.code, DOMException.WRONG_DOCUMENT_ERR); }
        \\var imp = doc.importNode(other.documentElement, true); assertEq(imp.ownerDocument, doc); assertEq(imp.tagName, "o");
        \\try { doc.createEntityReference("e"); assert(false); } catch (ex) { assertEq(ex.code, DOMException.NOT_SUPPORTED_ERR); }
        \\// CharacterData in UTF-16 units.
        \\t.appendData("é😀z"); assertEq(t.length, 5); assertEq(t.substringData(1, 3), "é😀"); t.deleteData(0, 1); assertEq(t.data, "é😀z");
        \\var rest = t.splitText(1); assertEq(t.data, "é"); assertEq(rest.data, "😀z"); assertEq(t.nextSibling, rest);
        \\x.normalize(); assertEq(x.firstChild.data, "é😀z");
        \\try { t.substringData(99, 1); assert(false); } catch (ex) { assertEq(ex.code, DOMException.INDEX_SIZE_ERR); }
        \\// Attributes as nodes.
        \\var at = doc.createAttribute("n"); at.value = "5"; assertEq(x.setAttributeNode(at), null); assertEq(x.getAttribute("n"), "5");
        \\assertEq(at.ownerElement, x); at.value = "6"; assertEq(x.getAttribute("n"), "6");
        \\assertEq(x.removeAttributeNode(at), at); assertEq(at.ownerElement, null); assertEq(at.value, "6"); assert(!x.hasAttribute("n"));
        \\var ns = doc.createElementNS("urn:b", "b:q"); assertEq(ns.namespaceURI, "urn:b"); assertEq(ns.prefix, "b"); assertEq(ns.localName, "q");
        \\try { doc.createElementNS(null, "b:q"); assert(false); } catch (ex) { assertEq(ex.code, DOMException.NAMESPACE_ERR); }
        \\var cl = x.cloneNode(true); assertEq(cl.parentNode, null); assertEq(cl.getAttribute("id"), "1"); assert(cl !== x);
        \\var frag = doc.createDocumentFragment(); frag.appendChild(doc.createElement("f1")); frag.appendChild(doc.createElement("f2"));
        \\r.appendChild(frag); assertEq(r.lastChild.tagName, "f2"); assertEq(frag.childNodes.length, 0);
        \\var created = XMLParser.createDocument("urn:c", "c:root", null); assertEq(created.documentElement.namespaceURI, "urn:c");
        \\assert(XMLParser.hasFeature("Core", "2.0")); assert(!XMLParser.hasFeature("HTML", "2.0"));
        \\// XPath interfaces (Z.12.7).
        \\var found = doc.evaluateXPath("//x[@id='1']", doc); assertEq(found.length, 1); assertEq(found[0], x);
        \\assertEq(doc.evaluateXPath("count(//x)", doc), null);
        \\assertThrows(function () { doc.evaluateXPath("//[", doc); }, EvalError);
        \\assertThrows(function () { doc.evaluateXPath("//x", other); }, TypeError);
        \\doc.setXPathVariable("v", "1"); assertEq(doc.getXPathVariable("v"), "1");
        \\assertEq(doc.evaluateXPath("//x[@id=$v]", doc).length, 1);
        \\doc.setXPathVariable("v", null); assertEq(doc.getXPathVariable("v"), null);
        \\assertThrows(function () { doc.setXPathVariable("1bad", "x"); }, TypeError);
        \\// Constructors cannot be called (Z.12.3).
        \\assertThrows(function () { Node(); }, EvalError); assertThrows(function () { new DOMException(); }, EvalError);
        \\assertEq(Node.ELEMENT_NODE, 1); assertEq(x.TEXT_NODE, 3);
        \\// Host objects are not extensible.
        \\x.extra = 1; assertEq(x.extra, undefined);
    , "dom.js");
}

test "mutation events are queued with the path of the change" {
    const e = try testenv.Env.create();
    defer e.destroy();
    try e.run(
        \\var doc = XMLParser.parseString("<r><a/></r>"); var r = doc.documentElement; var log = [];
        \\r.addEventListener("DOMNodeInserted", cb(function (ev) { log.push("ins:" + ev.target.tagName + ":" + ev.relatedNode.tagName + ":" + ev.eventPhase); }), false);
        \\r.addEventListener("DOMAttrModified", cb(function (ev) { log.push("attr:" + ev.attrName + ":" + ev.prevValue + ">" + ev.newValue + ":" + ev.attrChange); }), true);
        \\doc.addEventListener("DOMNodeRemoved", cb(function (ev) { log.push("rem:" + ev.target.tagName + ":" + (ev.target.parentNode === null)); }), true);
        \\var b = doc.createElement("b"); r.firstChild.appendChild(b);
        \\r.firstChild.setAttribute("k", "1"); r.firstChild.setAttribute("k", "2"); r.firstChild.removeAttribute("k");
        \\r.firstChild.removeChild(b);
        \\assertEq(log.length, 0, "queued");
        \\var ev = doc.createEvent("Events"); ev.initEvent("custom", true, false); var got = 0;
        \\r.addEventListener("custom", function () { got++; }, false); assertEq(b.dispatchEvent(ev), true);
    , "mutation.js");
    try e.run(
        \\assertEq(log.join(","), "ins:b:a:3,attr:k:>1:2,attr:k:1>2:1,attr:k:2>:3,rem:b:true");
        \\assertEq(got, 0, "b was detached when dispatched: not under r");
    , "mutation2.js");
}

test "documents live as long as their wrappers" {
    const e = try testenv.Env.create();
    defer e.destroy();
    try e.run(
        \\var el = XMLParser.parseString("<r><a>x</a></r>").documentElement.firstChild;
        \\for (var i = 0; i < 50; i++) { XMLParser.parseString("<junk/>"); }
        \\assertEq(el.ownerDocument.documentElement.tagName, "r"); assertEq(el.firstChild.data, "x");
        \\var list = XMLParser.parseString("<r><a/><a/></r>").getElementsByTagName("a"); assertEq(list.length, 2);
    , "life.js");
}
