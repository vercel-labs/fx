//! Provider-neutral JSON Schema prevents extensions from interpreting fx's internal property descriptors.
const std = @import("std");
const streams = @import("../agent/stream_provider.zig");
const schema = @import("../tooling/model_tool_schema.zig");
const Allocator = std.mem.Allocator;

/// Caller owns parsed schema arrays until the prepare envelope has been serialized.
pub fn render(alloc: Allocator, selection: streams.ToolSelection) !std.json.Parsed(std.json.Value) {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll("{\"functions\":[");
    try write_functions(alloc, &out.writer, selection.advertised_functions);
    try out.writer.writeAll("],\"additional_functions\":[");
    try write_functions(alloc, &out.writer, selection.additional_functions);
    try out.writer.writeAll("],\"dynamic_functions\":[");
    for (selection.selected_dynamic, 0..) |function, index| {
        if (index > 0) try out.writer.writeByte(',');
        const input = try std.json.Stringify.valueAlloc(alloc, function.input_schema, .{});
        defer alloc.free(input);
        const encoded = try schema.dynamicFunctionSchemaJsonAlloc(alloc, function.name, function.description, input);
        defer alloc.free(encoded);
        try out.writer.writeAll(encoded);
    }
    try out.writer.writeAll("]}");
    return std.json.parseFromSlice(std.json.Value, alloc, out.written(), .{ .allocate = .alloc_always });
}

/// Central schema rendering preserves bounds, unions, required fields and description limits.
fn write_functions(alloc: Allocator, writer: *std.Io.Writer, functions: []const schema.FunctionSchema) !void {
    for (functions, 0..) |function, index| {
        if (index > 0) try writer.writeByte(',');
        try schema.writeBuiltinFunctionSchema(alloc, writer, function);
    }
}
