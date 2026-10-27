//! `tab.observe()`: the page's interactive elements from Chrome's
//! accessibility tree, numbered for `tab.id(n)`, as proto's observation
//! returns them (D195).
const std = @import("std");
const cdp = @import("../../core/browser/cdp.zig");
const page_mod = @import("page.zig");

const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const Page = page_mod.Page;

/// The most elements one observation lists.
const max_elements = 400;

const interactive_roles = [_][]const u8{
    "button",   "link",          "textbox",        "combobox",         "listbox",       "option", "checkbox",   "radio",
    "switch",   "tab",           "menuitem",       "menuitemcheckbox", "menuitemradio", "slider", "spinbutton", "searchbox",
    "treeitem", "ListBoxOption", "MenuListOption",
};

const state_properties = [_][]const u8{ "disabled", "checked", "pressed", "selected", "expanded", "required", "readonly", "multiselectable", "multiline", "modal", "focused" };

pub const Options = struct { include_all: bool = false, viewport_only: bool = false };

pub const Entry = struct {
    id: usize,
    role: []const u8,
    name: ?[]const u8 = null,
    value: ?[]const u8 = null,
    description: ?[]const u8 = null,
    states: []const []const u8,
};

fn axString(node: Value, field: []const u8) ?[]const u8 {
    if (node != .object) return null;
    const wrapper = node.object.get(field) orelse return null;
    if (wrapper != .object) return null;
    const value = wrapper.object.get("value") orelse return null;
    return switch (value) {
        .string => |s| if (s.len > 0) s else null,
        else => null,
    };
}

/// A property's value as text, or null when the node lacks it.
fn property(node: Value, name: []const u8, buf: []u8) ?[]const u8 {
    if (node != .object) return null;
    const properties = node.object.get("properties") orelse return null;
    if (properties != .array) return null;
    for (properties.array.items) |item| {
        if (!std.mem.eql(u8, cdp.stringField(item, "name") orelse "", name)) continue;
        const wrapper = if (item == .object) item.object.get("value") else null;
        const value = (if (wrapper) |w| if (w == .object) w.object.get("value") else null else null) orelse return "";
        return switch (value) {
            .bool => |b| if (b) "true" else "false",
            .string => |s| s,
            .integer => |n| std.mem.print(buf, "{d}", .{n}) catch "",
            else => "",
        };
    }
    return null;
}

/// Whether a node counts as interactive the way proto's observation does.
pub fn isInteractive(node: Value) bool {
    const role = axString(node, "role") orelse return false;
    for (interactive_roles) |candidate| if (std.mem.eql(u8, candidate, role)) return true;
    var buf: [32]u8 = undefined;
    for ([_][]const u8{ "checked", "pressed", "selected", "expanded" }) |name| {
        if (property(node, name, &buf) != null) return true;
    }
    if (property(node, "focused", &buf)) |focused| return std.mem.eql(u8, focused, "true");
    return false;
}

/// Roles whose descendants puppeteer's interesting-only snapshot hides
/// unless they are focusable, such as a closed select's options.
const control_roles = [_][]const u8{
    "button",    "checkbox",  "combobox", "listbox",    "menu",   "menubar", "menuitem", "menuitemcheckbox", "menuitemradio", "radio",
    "scrollbar", "searchbox", "slider",   "spinbutton", "switch", "tab",     "textbox",  "tree",             "treeitem",
};

fn isControl(node: Value) bool {
    const role = axString(node, "role") orelse return false;
    for (control_roles) |candidate| if (std.mem.eql(u8, candidate, role)) return true;
    return false;
}

fn isFocusable(node: Value) bool {
    var buf: [8]u8 = undefined;
    const value = property(node, "focusable", &buf) orelse return false;
    return std.mem.eql(u8, value, "true");
}

const Walk = struct {
    arena: Allocator,
    gpa: Allocator,
    nodes: []const Value,
    by_id: std.StringHashMapUnmanaged(usize) = .empty,
    options: Options,
    list: std.ArrayList(Entry) = .empty,
    backend_ids: *std.ArrayList(i64),
    truncated: bool = false,

    fn visit(self: *Walk, index: usize, inside_control: bool, depth: usize) !void {
        if (depth > 512 or self.truncated) return;
        const node = self.nodes[index];
        var child_inside = inside_control;
        const ignored = if (node.object.get("ignored")) |i| i == .bool and i.bool else false;
        if (!ignored) if (cdp.intField(node, "backendDOMNodeId")) |backend| if (axString(node, "role")) |role| {
            const wanted = if (self.options.include_all)
                !std.mem.eql(u8, role, "none") and !std.mem.eql(u8, role, "InlineTextBox") and !std.mem.eql(u8, role, "RootWebArea")
            else
                !std.mem.eql(u8, role, "RootWebArea") and isInteractive(node) and (!inside_control or isFocusable(node));
            if (wanted) try self.add(node, backend, role);
            if (isControl(node)) child_inside = true;
        };
        const children = node.object.get("childIds") orelse return;
        if (children != .array) return;
        for (children.array.items) |child| {
            const id = switch (child) {
                .string => |text| text,
                else => continue,
            };
            const child_index = self.by_id.get(id) orelse continue;
            try self.visit(child_index, child_inside and !self.options.include_all, depth + 1);
        }
    }

    fn add(self: *Walk, node: Value, backend: i64, role: []const u8) !void {
        if (self.list.items.len == max_elements) {
            self.truncated = true;
            return;
        }
        var states: std.ArrayList([]const u8) = .empty;
        for (state_properties) |name| {
            var buf: [32]u8 = undefined;
            const value = property(node, name, &buf) orelse continue;
            const is_flag = std.mem.eql(u8, name, "disabled") or std.mem.eql(u8, name, "required") or std.mem.eql(u8, name, "readonly") or
                std.mem.eql(u8, name, "multiselectable") or std.mem.eql(u8, name, "multiline") or std.mem.eql(u8, name, "modal") or std.mem.eql(u8, name, "focused");
            if (is_flag) {
                if (std.mem.eql(u8, value, "true")) try states.append(self.arena, name);
            } else try states.append(self.arena, try self.arena.print("{s}={s}", .{ name, value }));
        }
        try self.backend_ids.append(self.gpa, backend);
        try self.list.append(self.arena, .{
            .id = self.list.items.len + 1,
            .role = role,
            .name = trimmed(axString(node, "name")),
            .value = trimmed(axString(node, "value")),
            .description = trimmed(axString(node, "description")),
            .states = states.items,
        });
    }
};

fn trimmed(text: ?[]const u8) ?[]const u8 {
    const value = std.mem.trim(u8, text orelse return null, " \t\r\n");
    return if (value.len > 0) value else null;
}

/// Builds the entries of an accessibility tree in document order, walking
/// from the root through `childIds`. `backend_ids` receives each entry's
/// backend DOM node id, in id order.
pub fn entries(arena: Allocator, nodes: []const Value, options: Options, backend_ids: *std.ArrayList(i64), gpa: Allocator) !struct { list: []Entry, truncated: bool } {
    var walk: Walk = .{ .arena = arena, .gpa = gpa, .nodes = nodes, .options = options, .backend_ids = backend_ids };
    var root: ?usize = null;
    for (nodes, 0..) |node, index| {
        if (node != .object) continue;
        const id = cdp.stringField(node, "nodeId") orelse continue;
        try walk.by_id.put(arena, id, index);
        if (root == null and node.object.get("parentId") == null) root = index;
    }
    if (root) |index| try walk.visit(index, false, 0);
    return .{ .list = walk.list.items, .truncated = walk.truncated };
}

const scroll_expression =
    \\({ x: scrollX, y: scrollY, width: innerWidth, height: innerHeight, scrollWidth: document.documentElement.scrollWidth, scrollHeight: document.documentElement.scrollHeight, url: location.href, title: document.title })
;

/// Collects an observation as JSON text, owned by `arena`.
pub fn collect(arena: Allocator, page: *Page, options: Options) page_mod.Failure![]const u8 {
    const browser = page.browser;
    page.tab.elements.clearRetainingCapacity();
    var tree = browser.call(page.tab.session_id, "Accessibility.getFullAXTree", .{}) catch |err| return page.protocolFailure(err, "tab.observe");
    defer tree.deinit(browser.alloc);
    const nodes = if (tree.value() == .object) tree.value().object.get("nodes") else null;
    if (nodes == null or nodes.? != .array) return page.fail("accessibility tree unavailable", .{});
    const built = entries(arena, nodes.?.array.items, options, &page.tab.elements, browser.alloc) catch return page.fail("out of memory", .{});
    var list = built.list;
    if (options.viewport_only) list = try keepInViewport(arena, page, list);
    const scroll_json = try page.evaluateJson(scroll_expression, false);
    const scroll = std.json.parseFromSliceLeaky(Value, arena, scroll_json, .{}) catch Value.null;
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    writeObservation(w, scroll, list, built.truncated) catch return page.fail("out of memory", .{});
    return out.toOwnedSlice() catch page.fail("out of memory", .{});
}

fn writeObservation(w: *std.Io.Writer, scroll: Value, list: []const Entry, truncated: bool) !void {
    try w.writeAll("{\"url\":");
    try std.json.Stringify.value(cdp.stringField(scroll, "url") orelse "", .{}, w);
    try w.writeAll(",\"title\":");
    try std.json.Stringify.value(cdp.stringField(scroll, "title") orelse "", .{}, w);
    try w.print(",\"viewport\":{{\"width\":{d},\"height\":{d}}}", .{ cdp.intField(scroll, "width") orelse 0, cdp.intField(scroll, "height") orelse 0 });
    try w.print(",\"scroll\":{{\"x\":{d},\"y\":{d},\"scrollWidth\":{d},\"scrollHeight\":{d}}}", .{
        cdp.intField(scroll, "x") orelse 0,
        cdp.intField(scroll, "y") orelse 0,
        cdp.intField(scroll, "scrollWidth") orelse 0,
        cdp.intField(scroll, "scrollHeight") orelse 0,
    });
    try w.writeAll(",\"elements\":");
    try std.json.Stringify.value(list, .{ .emit_null_optional_fields = false }, w);
    if (truncated) try w.print(",\"truncated\":\"only the first {d} elements; scroll or use tab.ariaSnapshot(selector)\"", .{max_elements});
    try w.writeByte('}');
}

/// Drops entries whose box lies outside the viewport. An element whose box
/// cannot be read stays, marked `viewport-unknown`.
fn keepInViewport(arena: Allocator, page: *Page, list: []Entry) page_mod.Failure![]Entry {
    const size_json = try page.evaluateJson("[innerWidth, innerHeight]", false);
    const size = std.json.parseFromSliceLeaky([2]f64, arena, size_json, .{}) catch return list;
    var kept: std.ArrayList(Entry) = .empty;
    for (list) |entry| {
        const backend = page.tab.elements.items[entry.id - 1];
        var model = page.browser.call(page.tab.session_id, "DOM.getBoxModel", .{ .backendNodeId = backend }) catch {
            var copy = entry;
            const states = arena.alloc([]const u8, entry.states.len + 1) catch return page.fail("out of memory", .{});
            @memcpy(states[0..entry.states.len], entry.states);
            states[entry.states.len] = "viewport-unknown";
            copy.states = states;
            kept.append(arena, copy) catch return page.fail("out of memory", .{});
            continue;
        };
        defer model.deinit(page.browser.alloc);
        const box = if (model.value() == .object) model.value().object.get("model") else null;
        const quad = if (box) |b| if (b == .object) b.object.get("border") else null else null;
        if (quad == null or quad.? != .array or quad.?.array.items.len < 8) continue;
        const q = quad.?.array.items;
        const x = num(q[0]);
        const y = num(q[1]);
        const right = num(q[4]);
        const bottom = num(q[5]);
        if (right < 0 or bottom < 0 or x > size[0] or y > size[1]) continue;
        kept.append(arena, entry) catch return page.fail("out of memory", .{});
    }
    return kept.items;
}

fn num(value: Value) f64 {
    return switch (value) {
        .integer => |n| @floatFromInt(n),
        .float => |f| f,
        else => 0,
    };
}

test "browser observation keeps interactive nodes with states and numbers them in tree order" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const tree =
        \\[{"nodeId":"1","ignored":false,"role":{"value":"RootWebArea"},"name":{"value":"Form"},"properties":[{"name":"focused","value":{"type":"boolean","value":true}}],"childIds":["2","6","3","4","5"],"backendDOMNodeId":1},
        \\ {"nodeId":"2","parentId":"1","ignored":false,"role":{"value":"heading"},"name":{"value":"Sign up"},"backendDOMNodeId":5},
        \\ {"nodeId":"3","parentId":"1","ignored":false,"role":{"value":"textbox"},"name":{"value":"Email "},"value":{"value":"a@b.c"},"properties":[{"name":"required","value":{"type":"boolean","value":true}},{"name":"focused","value":{"type":"boolean","value":true}}],"backendDOMNodeId":7},
        \\ {"nodeId":"4","parentId":"1","ignored":true,"role":{"value":"button"},"backendDOMNodeId":8},
        \\ {"nodeId":"5","parentId":"1","ignored":false,"role":{"value":"combobox"},"properties":[{"name":"expanded","value":{"type":"boolean","value":false}}],"childIds":["7"],"backendDOMNodeId":9},
        \\ {"nodeId":"7","parentId":"5","ignored":false,"role":{"value":"option"},"name":{"value":"Free"},"backendDOMNodeId":10},
        \\ {"nodeId":"6","parentId":"1","ignored":false,"role":{"value":"checkbox"},"name":{"value":"Terms"},"properties":[{"name":"checked","value":{"type":"tristate","value":"false"}}],"backendDOMNodeId":11}]
    ;
    const nodes = try std.json.parseFromSliceLeaky(Value, arena, tree, .{});
    var ids: std.ArrayList(i64) = .empty;
    defer ids.deinit(alloc);
    const built = try entries(arena, nodes.array.items, .{}, &ids, alloc);
    // Document order follows childIds; the root and a closed select's options are left out.
    try std.testing.expectEqual(@as(usize, 3), built.list.len);
    try std.testing.expectEqualSlices(i64, &.{ 11, 7, 9 }, ids.items);
    try std.testing.expectEqualStrings("checkbox", built.list[0].role);
    try std.testing.expectEqualStrings("checked=false", built.list[0].states[0]);
    try std.testing.expectEqualStrings("Email", built.list[1].name.?);
    try std.testing.expectEqualStrings("a@b.c", built.list[1].value.?);
    try std.testing.expectEqualStrings("required", built.list[1].states[0]);
    try std.testing.expectEqualStrings("focused", built.list[1].states[1]);
    try std.testing.expectEqualStrings("expanded=false", built.list[2].states[0]);
    try std.testing.expectEqual(@as(usize, 3), built.list[2].id);

    var all_ids: std.ArrayList(i64) = .empty;
    defer all_ids.deinit(alloc);
    const all = try entries(arena, nodes.array.items, .{ .include_all = true }, &all_ids, alloc);
    try std.testing.expectEqual(@as(usize, 5), all.list.len);
}
