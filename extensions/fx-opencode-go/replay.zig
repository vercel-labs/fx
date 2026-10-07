//! Family tags prevent opaque reasoning from becoming cross-provider input injection.
const std = @import("std");
const wire = @import("wire.zig");
const routes = @import("routes.zig");
const max_items = 128;
const reasoning_type = "reasoning";
const summary_type = "summary_text";
const completed_status = "completed";
const reasoning_fields = [_][]const u8{ "type", "id", "encrypted_content", "summary", "status" };

/// The caller's arena owns parsed storage; foreign families leave canonical history intact.
pub fn items(alloc: wire.Allocator, state: wire.Value, api: routes.Api) !?wire.Value {
    const json = try wire.text(state);
    if (json.len > wire.max_frame_bytes) return error.InvalidReplayState;
    const saved = try std.json.parseFromSliceLeaky(wire.Value, alloc, json, .{ .allocate = .alloc_always });
    if (saved != .array) return error.InvalidReplayState;
    // One tagged object preserves the host's array contract and distinguishes legacy Chat replay.
    var tagged_present = false;
    for (saved.array.items) |item| if (item == .object and item.object.get("api") != null) {
        tagged_present = true;
        break;
    };
    if (!tagged_present) return if (api == .chat_completions) saved else null;
    if (saved.array.items.len != 1 or saved.array.items[0] != .object) return error.InvalidReplayState;
    const tagged = saved.array.items[0];
    const family = try wire.text(try wire.field(tagged, "api"));
    if (!std.mem.eql(u8, family, @tagName(api))) return null;
    const values = try wire.field(tagged, "items");
    if (values != .array or values.array.items.len > max_items) return error.InvalidReplayState;
    return values;
}

/// The same envelope supports independent codecs without interpreting another family's payload.
pub fn envelope(alloc: wire.Allocator, api: routes.Api, values: wire.Value) ![]const u8 {
    var saved = wire.object();
    try wire.put(alloc, &saved, "api", wire.string(@tagName(api)));
    try wire.put(alloc, &saved, "items", values);
    var outer: std.json.Array = .init(alloc);
    try outer.append(saved);
    return std.json.Stringify.valueAlloc(alloc, wire.Value{ .array = outer }, .{});
}

/// Only encrypted reasoning is replayable; arbitrary input items cannot gain provider authority.
pub fn responses_item(item: wire.Value) !void {
    if (item != .object) return error.InvalidReplayState;
    var fields = item.object.iterator();
    while (fields.next()) |entry| {
        var allowed = false;
        for (reasoning_fields) |field| if (std.mem.eql(u8, entry.key_ptr.*, field)) {
            allowed = true;
            break;
        };
        if (!allowed) return error.InvalidReplayState;
    }
    if (!std.mem.eql(u8, try wire.text(try wire.field(item, "type")), reasoning_type)) return error.InvalidReplayState;
    const encrypted = try wire.text(try wire.field(item, "encrypted_content"));
    if (encrypted.len == 0) return error.InvalidReplayState;
    if (item.object.get("id")) |id| if ((try wire.text(id)).len == 0) return error.InvalidReplayState;
    if (item.object.get("status")) |status| if (!std.mem.eql(u8, try wire.text(status), completed_status)) return error.InvalidReplayState;
    const summary = try wire.field(item, "summary");
    if (summary != .array or summary.array.items.len > max_items) return error.InvalidReplayState;
    for (summary.array.items) |part| {
        if (part != .object or part.object.count() != 2) return error.InvalidReplayState;
        if (!std.mem.eql(u8, try wire.text(try wire.field(part, "type")), summary_type)) return error.InvalidReplayState;
        _ = try wire.text(try wire.field(part, "text"));
    }
}
