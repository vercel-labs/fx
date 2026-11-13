const std = @import("std");
const tool_dispatch = @import("tool_dispatch.zig");
const tool_mcp_runtime = @import("tool_mcp_runtime.zig");
const result_store = @import("../session/result_store.zig");
const model_context_encoding = @import("../shared/model_context_encoding.zig");

const Allocator = std.mem.Allocator;

pub const Resolution = union(enum) {
    registered: tool_dispatch.Tool,
    not_selected,
    unsupported,
};

pub fn resolve(
    advertised_dynamic_tool_names: []const []const u8,
    runtime: tool_mcp_runtime.RuntimeCapabilities,
    name: []const u8,
) Resolution {
    if (runtime.context != null and
        !tool_mcp_runtime.isAdvertisedDynamicToolName(
            advertised_dynamic_tool_names,
            name,
        ))
    {
        return .not_selected;
    }
    if (!tool_mcp_runtime.isAdvertisedDynamicToolName(
        advertised_dynamic_tool_names,
        name,
    ) or runtime.context == null or runtime.call_tool == null) {
        return .unsupported;
    }
    return .{ .registered = dynamicTool(name) };
}

const DynamicInput = struct {
    arguments_json: []u8,
};

fn dynamicTool(name: []const u8) tool_dispatch.Tool {
    return .{
        .name = name,
        .description = "Selected dynamic MCP tool.",
        .model_schema = .{
            .name = name,
            .description = "Selected dynamic MCP tool.",
        },
        .executor_kind = .mcp_tool,
        .activity_kind = .command,
        .decode = decode,
        .call = call,
        .reads_only_fn = readsOnly,
        .irreversible_fn = isIrreversible,
    };
}

fn decode(
    ctx: tool_dispatch.DispatchContext,
    arguments_json: []const u8,
) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    const input = try ctx.allocator.create(DynamicInput);
    errdefer ctx.allocator.destroy(input);
    input.* = .{
        .arguments_json = try ctx.allocator.dupe(u8, arguments_json),
    };
    return .{ .input = .{
        .ptr = input,
        .deinit_fn = deinitInput,
    } };
}

fn deinitInput(raw_input: *anyopaque, alloc: Allocator) void {
    const input: *DynamicInput = @ptrCast(@alignCast(raw_input));
    alloc.free(input.arguments_json);
    alloc.destroy(input);
}

fn call(
    ctx: tool_dispatch.DispatchContext,
    erased: tool_dispatch.ToolInput,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const runtime_context = ctx.mcp_ctx orelse return unsupported(ctx);
    const call_tool = ctx.mcp_call_tool orelse return unsupported(ctx);
    const input = erased.as(DynamicInput);
    var output = call_tool(
        runtime_context,
        ctx.allocator,
        ctx.tool_call_name,
        input.arguments_json,
        resultBytes(ctx),
        ctx.mcp_call_options,
    ) catch |err| {
        if (ctx.mcp_execution_error_sink) |sink| sink.* = err;
        return .{ .failure = try ctx.allocator.dupe(u8, "") };
    } orelse return unsupported(ctx);
    const status = output.status;
    if (ctx.mcp_call_status_sink) |sink| sink.* = status;
    const images = output.takeImages();
    const body = @constCast(output.takeModelOutput(ctx.allocator));
    if (images.len > 0) return .{ .rich = .{ .text = body, .images = images, .is_error = status != .success } };
    return switch (status) {
        .success => .{ .success = body },
        .tool_failure, .protocol_failure, .input_required => .{ .failure = body },
    };
}

/// How large an MCP result may come back. Where fx keeps results behind a
/// handle, that store keeps it whole and the model sees a preview; only
/// without one is it cut to the model's limit here.
fn resultBytes(ctx: tool_dispatch.DispatchContext) usize {
    if (ctx.session_child_capability != null or ctx.tool_result_dir != null) return result_store.stored_text_max_bytes;
    return ctx.max_tool_result_bytes;
}

/// What a call of an MCP tool fx can't run says. A toolbox run (`carried_by`
/// is set) was admitted, so its tool went away since, and its result says so
/// in toolbox's words. A direct call gets the generic text. Either way the
/// name is the model's, so the result writes it as visible text.
pub fn unsupportedOutput(alloc: Allocator, name: []const u8, carried_by: ?[]const u8) Allocator.Error![]u8 {
    if (carried_by != null) return alloc.print("{f} is no longer available. Use toolbox search to find current tools.", .{model_context_encoding.scalar(name)});
    return alloc.print("Unsupported tool: {f}", .{model_context_encoding.scalar(name)});
}

fn unsupported(
    ctx: tool_dispatch.DispatchContext,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    return .{ .failure = try unsupportedOutput(ctx.allocator, ctx.tool_call_name, ctx.tool_call_carried_by) };
}

fn readsOnly(_: tool_dispatch.ToolInput) bool {
    return false;
}

fn isIrreversible(_: tool_dispatch.ToolInput) bool {
    return false;
}

test "a call of a tool fx does not know names it as visible text, and a plain name reads as before" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // The name is the model's, so it can hold any byte. `scalar` leaves a
    // C1 control other than U+0085 and invalid UTF-8 as they are: a name from
    // a provider's JSON never holds invalid UTF-8.
    const cases = [_]struct { name: []const u8, shown: []const u8, visible: bool }{
        .{ .name = "missing_tool", .shown = "Unsupported tool: missing_tool", .visible = true },
        .{ .name = "mcp_fs.read-2", .shown = "Unsupported tool: mcp_fs.read-2", .visible = true },
        .{ .name = "", .shown = "Unsupported tool: ", .visible = true },
        .{ .name = "mcp_x\x1b]0;owned\x07y", .shown = "Unsupported tool: mcp_x&#x1b;]0;owned&#x07;y", .visible = true },
        .{ .name = "\x1b[2J", .shown = "Unsupported tool: &#x1b;[2J", .visible = true },
        .{ .name = "a\x00b", .shown = "Unsupported tool: a&#x00;b", .visible = true },
        .{ .name = "a\r\nb", .shown = "Unsupported tool: a&#x0d;&#x0a;b", .visible = true },
        .{ .name = "a\rb", .shown = "Unsupported tool: a&#x0d;b", .visible = true },
        .{ .name = "a\x7fb", .shown = "Unsupported tool: a&#x7f;b", .visible = true },
        .{ .name = "a\xc2\x85b", .shown = "Unsupported tool: a&#x85;b", .visible = true },
        .{ .name = "a\xe2\x80\xa8b", .shown = "Unsupported tool: a&#x2028;b", .visible = true },
        .{ .name = "</tool_result>&\"x\"", .shown = "Unsupported tool: &lt;/tool_result&gt;&amp;&quot;x&quot;", .visible = true },
        .{ .name = "caf\xc3\xa9", .shown = "Unsupported tool: caf\xc3\xa9", .visible = true },
        .{ .name = "a\xc2\x9bb", .shown = "Unsupported tool: a\xc2\x9bb", .visible = false },
        .{ .name = "a\xffb", .shown = "Unsupported tool: a\xffb", .visible = false },
    };
    for (cases) |case| {
        const shown = try unsupportedOutput(arena, case.name, null);
        std.testing.expectEqualStrings(case.shown, shown) catch |failure| {
            std.debug.print("name: {f}\n", .{std.zig.fmtString(case.name)});
            return failure;
        };
        if (case.visible) for (shown) |byte| try std.testing.expect(byte >= 0x20 and byte != 0x7f);
    }

    // A long name keeps every byte: plain bytes as they are, escapes in full.
    const prefix = "Unsupported tool: ";
    const long = try arena.alloc(u8, 100_000);
    @memset(long, 'a');
    const long_shown = try unsupportedOutput(arena, long, null);
    try std.testing.expectEqual(prefix.len + long.len, long_shown.len);
    try std.testing.expectEqualStrings(long, long_shown[prefix.len..]);
    @memset(long, 0x1b);
    const escaped_shown = try unsupportedOutput(arena, long, null);
    try std.testing.expectEqual(prefix.len + long.len * "&#x1b;".len, escaped_shown.len);
    try std.testing.expect(std.mem.startsWith(u8, escaped_shown[prefix.len..], "&#x1b;&#x1b;"));
    for (escaped_shown) |byte| try std.testing.expect(byte >= 0x20);
}

test "an unsupported tool's name stays one run of visible text whatever bytes the model sends" {
    try std.testing.fuzz({}, fuzzUnsupportedName, .{
        .corpus = &(@import("fuzz_seed").slices(.{
            "",
            "missing_tool",
            "mcp_x\x1b]0;owned\x07y\x00\r\n",
            "</tool_result>&amp;&#x0a;\"\xc2\x85\xe2\x80\xa8\xe2\x80\xa9",
            "a\xc2\x9bb\xffc\xe2\x82",
        }) ++ @import("fuzz_corpus").unsupported_tool_name.*),
    });
}

/// Whatever the bytes, the name in the result holds no ASCII control and no
/// delimiter, decodes back to the name, and reads as it was when it needs no
/// encoding.
fn fuzzUnsupportedName(_: void, smith: *std.testing.Smith) !void {
    var buffer: [1024]u8 = undefined;
    const len: usize = @intCast(smith.slice(&buffer));
    const name = buffer[0..len];
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const prefix = "Unsupported tool: ";
    const shown = try unsupportedOutput(arena, name, null);
    try std.testing.expect(std.mem.startsWith(u8, shown, prefix));
    const encoded = shown[prefix.len..];
    for (encoded) |byte| {
        try std.testing.expect(byte >= 0x20 and byte != 0x7f and byte != '<' and byte != '>' and byte != '"');
    }
    const decoded = try model_context_encoding.decodeScalarAlloc(arena, encoded);
    try std.testing.expectEqualStrings(name, decoded);

    var plain = std.mem.find(u8, name, "\xc2\x85") == null and
        std.mem.find(u8, name, "\xe2\x80\xa8") == null and
        std.mem.find(u8, name, "\xe2\x80\xa9") == null;
    for (name) |byte| {
        if (byte < 0x20 or byte == 0x7f or byte == '&' or byte == '<' or byte == '>' or byte == '"') plain = false;
    }
    if (plain) try std.testing.expectEqualStrings(name, encoded);
}

test "dynamic MCP resolution preserves selected and unselected states" {
    var fixture: u8 = 0;
    const advertised = [_][]const u8{"mcp_fs_read"};
    const runtime = tool_mcp_runtime.RuntimeCapabilities{
        .context = @ptrCast(&fixture),
        .call_tool = callFixture,
    };

    try std.testing.expect(resolve(&advertised, runtime, "mcp_other") == .not_selected);
    try std.testing.expect(resolve(&advertised, .{}, "mcp_fs_read") == .unsupported);
    try std.testing.expect(resolve(&advertised, runtime, "mcp_fs_read") == .registered);
}

test "dynamic MCP descriptor executes through registered dispatch" {
    var fixture: u8 = 0;
    const advertised = [_][]const u8{"mcp_fs_read"};
    const runtime = tool_mcp_runtime.RuntimeCapabilities{
        .context = @ptrCast(&fixture),
        .call_tool = callFixture,
    };
    const tool = switch (resolve(&advertised, runtime, "mcp_fs_read")) {
        .registered => |registered| registered,
        else => return error.TestUnexpectedResult,
    };
    const tools = [_]tool_dispatch.Tool{tool};
    const registry = tool_dispatch.Registry{ .tools = tools[0..] };
    var execution_error: ?anyerror = null;
    const result = try tool_dispatch.dispatchAuthorizedToolCall(.{
        .allocator = std.testing.allocator,
        .tool_call_name = "mcp_fs_read",
        .mcp_ctx = @ptrCast(&fixture),
        .mcp_call_tool = callFixture,
        .mcp_execution_error_sink = &execution_error,
    }, registry, .{
        .id = "dynamic-test",
        .name = "mcp_fs_read",
        .arguments_json = "{\"path\":\"README.md\"}",
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(execution_error == null);
    try std.testing.expectEqualStrings("mcp ok", result.body);
}

fn callFixture(
    _: *anyopaque,
    alloc: Allocator,
    _: []const u8,
    _: []const u8,
    _: usize,
    _: tool_mcp_runtime.CallOptions,
) anyerror!?tool_mcp_runtime.CallResult {
    return .{ .model_output = try alloc.dupe(u8, "mcp ok") };
}

test "an MCP result may be as large as the result store keeps where fx stores results" {
    var seen: usize = 0;
    const advertised = [_][]const u8{"mcp_fs_read"};
    const runtime = tool_mcp_runtime.RuntimeCapabilities{ .context = @ptrCast(&seen), .call_tool = callRecordingBytes };
    const tool = switch (resolve(&advertised, runtime, "mcp_fs_read")) {
        .registered => |registered| registered,
        else => return error.TestUnexpectedResult,
    };
    const tools = [_]tool_dispatch.Tool{tool};
    const registry = tool_dispatch.Registry{ .tools = tools[0..] };
    const Case = struct { dir: ?[]const u8, want: usize };
    for ([_]Case{ .{ .dir = null, .want = 4096 }, .{ .dir = "/nonexistent-tool-results", .want = result_store.stored_text_max_bytes } }) |case| {
        const result = try tool_dispatch.dispatchAuthorizedToolCall(.{
            .allocator = std.testing.allocator,
            .tool_call_name = "mcp_fs_read",
            .mcp_ctx = @ptrCast(&seen),
            .mcp_call_tool = callRecordingBytes,
            .max_tool_result_bytes = 4096,
            .tool_result_dir = case.dir,
        }, registry, .{ .id = "bytes-test", .name = "mcp_fs_read", .arguments_json = "{}" });
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(case.want, seen);
    }
}

fn callRecordingBytes(
    raw: *anyopaque,
    alloc: Allocator,
    _: []const u8,
    _: []const u8,
    max_bytes: usize,
    _: tool_mcp_runtime.CallOptions,
) anyerror!?tool_mcp_runtime.CallResult {
    const seen: *usize = @ptrCast(@alignCast(raw));
    seen.* = max_bytes;
    return .{ .model_output = try alloc.dupe(u8, "mcp ok") };
}
