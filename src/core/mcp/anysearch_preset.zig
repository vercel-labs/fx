const std = @import("std");

const Allocator = std.mem.Allocator;

pub const name = "anysearch";
pub const endpoint = "https://api.anysearch.com/mcp";
pub const api_key_env = "ANYSEARCH_API_KEY";
pub const search_tool_name = "mcp_anysearch_search";

pub const SearchInput = struct {
    query: []const u8,
    max_results: u8 = 3,
};

pub fn parseSearchInput(tokens: []const []const u8) error{InvalidSearchArguments}!SearchInput {
    if (tokens.len != 1 and tokens.len != 3) return error.InvalidSearchArguments;
    if (std.mem.trim(u8, tokens[0], " \t\r\n").len < 2) return error.InvalidSearchArguments;
    if (tokens.len == 1) return .{ .query = tokens[0] };
    if (!std.mem.eql(u8, tokens[1], "--max-results")) return error.InvalidSearchArguments;
    const max_results = std.fmt.parseInt(u8, tokens[2], 10) catch return error.InvalidSearchArguments;
    if (max_results < 1 or max_results > 10) return error.InvalidSearchArguments;
    return .{ .query = tokens[0], .max_results = max_results };
}

pub fn searchArgumentsJson(alloc: Allocator, input: SearchInput) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.writeAll("{\"query\":");
    try std.json.Stringify.value(input.query, .{}, &out.writer);
    try out.writer.print(",\"max_results\":{d}}}", .{input.max_results});
    return out.toOwnedSlice();
}

test "AnySearch CLI search maps query and result count to MCP arguments" {
    const alloc = std.testing.allocator;
    const input = try parseSearchInput(&.{ "fx Zig MCP", "--max-results", "4" });
    try std.testing.expectEqual(@as(u8, 4), input.max_results);
    const json = try searchArgumentsJson(alloc, input);
    defer alloc.free(json);
    try std.testing.expectEqualStrings("{\"query\":\"fx Zig MCP\",\"max_results\":4}", json);
    const escaped = try searchArgumentsJson(alloc, .{ .query = "a \"quoted\" query" });
    defer alloc.free(escaped);
    try std.testing.expect(std.mem.find(u8, escaped, "\\\"quoted\\\"") != null);
}

test "AnySearch CLI search rejects invalid arguments" {
    try std.testing.expectError(error.InvalidSearchArguments, parseSearchInput(&.{}));
    try std.testing.expectError(error.InvalidSearchArguments, parseSearchInput(&.{"x"}));
    try std.testing.expectError(error.InvalidSearchArguments, parseSearchInput(&.{ "query", "--max-results", "0" }));
    try std.testing.expectError(error.InvalidSearchArguments, parseSearchInput(&.{ "query", "--max-results", "11" }));
    try std.testing.expectError(error.InvalidSearchArguments, parseSearchInput(&.{ "query", "--other", "3" }));
}
