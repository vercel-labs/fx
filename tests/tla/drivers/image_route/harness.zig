//! A JSON-lines shell around the real image route core, for the Bun drivers.
//!
//! Built from `src/core/images/image_route.zig` (or a planted-bug copy of it)
//! as the `image_route` module. On start it prints the core's zero state. Then
//! it reads one event per line and prints one line per event:
//!
//!   in:  {"event":"turn_started","view":{"kind":"listed","vision":true,"file_input":false}}
//!        {"event":"request_ready","req":{"user_images":false,"earlier_images":true,...}}
//!        {"event":"capabilities_resolved","view":{"kind":"down","vision":false,"file_input":false}}
//!   out: {"state":{"support":"unknown","resolved":false,"notified":false,"pending":[]},"out":[...]}
//!
//! `state` is `image_route.abstract`, and `out` is the effects `step`
//! returned, in the spec's record shapes. The harness is a shell: it turns a
//! catalog view into a support value with the core's own
//! `supportFromCatalog`, exactly as `model_capabilities.mergeCapabilities`
//! does, and holds the state between lines. A crash is the driver killing
//! this process.
const std = @import("std");
const image_route = @import("image_route");

const ViewJson = struct {
    kind: []const u8,
    vision: bool = false,
    file_input: bool = false,
};

const Input = struct {
    event: []const u8,
    view: ?ViewJson = null,
    req: ?image_route.Request = null,
};

const EffectJson = struct {
    kind: []const u8,
    route: ?image_route.Route = null,
    mode: ?image_route.VisionMode = null,
    tool_images: ?image_route.ToolImages = null,
    earlier_images: ?image_route.ToolImages = null,
    reason: ?image_route.FailReason = null,
};

const Line = struct {
    state: image_route.Abstract,
    out: []const EffectJson,
};

fn catalogView(view: ViewJson) error{InvalidView}!image_route.CatalogView {
    if (std.mem.eql(u8, view.kind, "down")) return .down;
    if (std.mem.eql(u8, view.kind, "missing")) return .missing;
    if (std.mem.eql(u8, view.kind, "listed")) return .{ .listed = .{ .vision = view.vision, .file_input = view.file_input } };
    return error.InvalidView;
}

fn event(input: Input) error{ InvalidView, InvalidEvent }!image_route.Event {
    if (std.mem.eql(u8, input.event, "turn_started")) {
        return .{ .turn_started = image_route.supportFromCatalog(try catalogView(input.view orelse return error.InvalidEvent)) };
    }
    if (std.mem.eql(u8, input.event, "capabilities_resolved")) {
        return .{ .capabilities_resolved = image_route.supportFromCatalog(try catalogView(input.view orelse return error.InvalidEvent)) };
    }
    if (std.mem.eql(u8, input.event, "request_ready")) {
        return .{ .request_ready = input.req orelse return error.InvalidEvent };
    }
    return error.InvalidEvent;
}

fn effectJson(effect: image_route.Effect) EffectJson {
    return switch (effect) {
        .resolve_capabilities => .{ .kind = "resolve" },
        .notify_catalog_down => .{ .kind = "notify" },
        .send => |chosen| .{ .kind = "send", .route = chosen.route, .mode = chosen.mode, .tool_images = chosen.tool_images, .earlier_images = chosen.earlier_images },
        .fail => |reason| .{ .kind = "fail", .reason = reason },
    };
}

fn writeLine(writer: *std.Io.Writer, state: *const image_route.State, effects: []const image_route.Effect) !void {
    var buffer: [image_route.max_effects]EffectJson = undefined;
    for (effects, 0..) |effect, index| buffer[index] = effectJson(effect);
    try std.json.Stringify.value(Line{ .state = image_route.abstract(state), .out = buffer[0..effects.len] }, .{ .emit_null_optional_fields = false }, writer);
    try writer.writeByte('\n');
    try writer.flush();
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const alloc = init.gpa;

    var in_buffer: [64 * 1024]u8 = undefined;
    var stdin = std.Io.File.stdin().reader(io, &in_buffer);
    var out_buffer: [64 * 1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &out_buffer);

    var state: image_route.State = .{};
    try writeLine(&stdout.interface, &state, &.{});
    while (try stdin.interface.takeDelimiter('\n')) |raw| {
        const text = std.mem.trim(u8, raw, " \r\t");
        if (text.len == 0) continue;
        const parsed = try std.json.parseFromSlice(Input, alloc, text, .{});
        defer parsed.deinit();
        const out = image_route.step(state, try event(parsed.value));
        state = out.state;
        try writeLine(&stdout.interface, &state, out.effects());
    }
}
