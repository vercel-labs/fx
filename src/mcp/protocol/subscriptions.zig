//! Subscriptions (2026): the `subscriptions/listen` request, and what
//! the server sends on one: the acknowledgment's filter, the
//! `subscriptionId` in every message's `_meta`, which list changed, and the
//! request a server's `notifications/cancelled` names. Pure.

const std = @import("std");
const wire = @import("wire.zig");
const core = @import("../core/subscription.zig");

const id_key = "io.modelcontextprotocol/subscriptionId";
/// The filter's list-changed fields, in `core.Kind` order.
const filter_fields = [_][]const u8{ "toolsListChanged", "promptsListChanged", "resourcesListChanged" };

/// A `subscriptions/listen` request asking for `filter`.
pub fn writeListen(out: *std.Io.Writer, id: wire.RequestId, meta: wire.Meta, filter: core.Filter) wire.EncodeError!void {
    var w: wire.Writer = try .request(out, id, "subscriptions/listen", meta);
    try w.field("notifications");
    var buffer: [96]u8 = undefined;
    var object: std.Io.Writer = .fixed(&buffer);
    object.writeByte('{') catch unreachable;
    var first = true;
    for (filter_fields, 0..) |name, i| if (filter & (@as(core.Filter, 1) << @intCast(i)) != 0) {
        object.print("{s}\"{s}\":true", .{ if (first) "" else ",", name }) catch unreachable;
        first = false;
    };
    object.writeByte('}') catch unreachable;
    try w.raw(object.buffered());
    try w.end();
}

/// The `subscriptionId` in `params._meta`, or null. The client's
/// listens have integer ids, so any other value names none of them.
pub fn subscriptionId(params: ?[]const u8) ?wire.RequestId {
    var meta: [1]?[]const u8 = undefined;
    wire.objectFields(params orelse return null, &.{"_meta"}, &meta) catch return null;
    var id: [1]?[]const u8 = undefined;
    wire.objectFields(meta[0] orelse return null, &.{id_key}, &id) catch return null;
    return wire.decimal(id[0] orelse return null);
}

/// What a notification on a subscription says.
pub const Notice = union(enum) {
    /// `notifications/subscriptions/acknowledged`, with the filter the server
    /// agreed to: the list-changed fields that are `true`.
    acknowledged: core.Filter,
    changed: core.Kind,
    other,
};

pub fn notice(method: []const u8, params: ?[]const u8) Notice {
    if (std.mem.eql(u8, method, "notifications/subscriptions/acknowledged")) return .{ .acknowledged = ackFilter(params) };
    const changed = [_]struct { []const u8, core.Kind }{
        .{ "notifications/tools/list_changed", .tools },
        .{ "notifications/prompts/list_changed", .prompts },
        .{ "notifications/resources/list_changed", .resources },
    };
    for (changed) |c| if (std.mem.eql(u8, method, c[0])) return .{ .changed = c[1] };
    return .other;
}

fn ackFilter(params: ?[]const u8) core.Filter {
    var notifications: [1]?[]const u8 = undefined;
    wire.objectFields(params orelse return 0, &.{"notifications"}, &notifications) catch return 0;
    var flags: [filter_fields.len]?[]const u8 = undefined;
    wire.objectFields(notifications[0] orelse return 0, &filter_fields, &flags) catch return 0;
    var filter: core.Filter = 0;
    for (flags, 0..) |flag, i| if (flag) |v| if (std.mem.eql(u8, v, "true")) {
        filter |= @as(core.Filter, 1) << @intCast(i);
    };
    return filter;
}

/// The request a `notifications/cancelled` names, or null.
pub fn cancelledId(params: ?[]const u8) ?wire.RequestId {
    var found: [1]?[]const u8 = undefined;
    wire.objectFields(params orelse return null, &.{"requestId"}, &found) catch return null;
    return wire.decimal(found[0] orelse return null);
}

const testing = std.testing;

test "writes a listen asking for what the filter names" {
    var buffer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer.deinit();
    try writeListen(&buffer.writer, 1, .{}, core.bit(.tools) | core.bit(.resources));
    const written = buffer.written();
    var found: [2]?[]const u8 = undefined;
    try wire.objectFields(written, &.{ "method", "params" }, &found);
    try testing.expectEqualStrings("\"subscriptions/listen\"", found[0].?);
    var notifications: [1]?[]const u8 = undefined;
    try wire.objectFields(found[1].?, &.{"notifications"}, &notifications);
    try testing.expectEqualStrings("{\"toolsListChanged\":true,\"resourcesListChanged\":true}", notifications[0].?);
}

test "reads the spec's acknowledgment, notification, and graceful end" {
    const ack =
        \\{"_meta":{"io.modelcontextprotocol/subscriptionId":1},"notifications":{"toolsListChanged":true,"resourceSubscriptions":["file:///project/config.json"]}}
    ;
    try testing.expectEqual(@as(?wire.RequestId, 1), subscriptionId(ack));
    try testing.expectEqual(Notice{ .acknowledged = core.bit(.tools) }, notice("notifications/subscriptions/acknowledged", ack));
    const updated =
        \\{"_meta":{"io.modelcontextprotocol/subscriptionId":1},"uri":"file:///project/config.json"}
    ;
    try testing.expectEqual(Notice.other, notice("notifications/resources/updated", updated));
    try testing.expectEqual(Notice{ .changed = .tools }, notice("notifications/tools/list_changed", "{\"_meta\":{\"io.modelcontextprotocol/subscriptionId\":3}}"));
    try testing.expectEqual(Notice{ .changed = .prompts }, notice("notifications/prompts/list_changed", null));
    try testing.expectEqual(Notice{ .changed = .resources }, notice("notifications/resources/list_changed", null));
    const end =
        \\{"resultType":"complete","_meta":{"io.modelcontextprotocol/subscriptionId":1}}
    ;
    try testing.expectEqual(@as(?wire.RequestId, 1), subscriptionId(end));
}

test "an id that isn't an integer, a missing filter, and a false flag name nothing" {
    try testing.expectEqual(@as(?wire.RequestId, null), subscriptionId("{\"_meta\":{\"io.modelcontextprotocol/subscriptionId\":\"1\"}}"));
    try testing.expectEqual(@as(?wire.RequestId, null), subscriptionId("{}"));
    try testing.expectEqual(@as(?wire.RequestId, null), subscriptionId(null));
    try testing.expectEqual(Notice{ .acknowledged = 0 }, notice("notifications/subscriptions/acknowledged", "{}"));
    try testing.expectEqual(Notice{ .acknowledged = core.bit(.prompts) }, notice("notifications/subscriptions/acknowledged", "{\"notifications\":{\"toolsListChanged\":false,\"promptsListChanged\":true}}"));
    try testing.expectEqual(@as(?wire.RequestId, 4), cancelledId("{\"requestId\":4,\"reason\":\"shutting down\"}"));
    try testing.expectEqual(@as(?wire.RequestId, null), cancelledId("{\"reason\":\"no id\"}"));
}
