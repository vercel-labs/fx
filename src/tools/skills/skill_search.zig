const std = @import("std");
const testing_allocator = @import("../../core/shared/testing_allocator.zig");
const builtin_skills = @import("../../builtins/skills.zig");
const context_limits = @import("../../core/config/context_limits.zig");
const lexical_relevance = @import("../../core/shared/lexical_relevance.zig");
const capability_retrieval = @import("../../core/tooling/capability_retrieval.zig");
const skill_runtime = @import("../../core/skills/skill_runtime.zig");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");
const tool_result_limits = @import("../../core/tooling/tool_result_limits.zig");
const text_utils = @import("../../core/shared/text_utils.zig");

const Allocator = std.mem.Allocator;

pub const SearchResult = struct {
    model_output: []u8,
    items_start: usize,
    items_end: usize,
    count: usize,
    total_matches: usize,

    pub fn deinit(self: *SearchResult, alloc: Allocator) void {
        alloc.free(self.model_output);
        self.* = undefined;
    }

    pub fn itemsJson(self: *const SearchResult) []const u8 {
        return self.model_output[self.items_start..self.items_end];
    }
};

const RenderedSearch = struct {
    bytes: []u8,
    items_start: usize,
    items_end: usize,
};

pub fn searchRequest(
    ctx: tool_dispatch.DispatchContext,
    request: capability_retrieval.Request,
    max_bytes: usize,
) !SearchResult {
    var discovery = try builtin_skills.loadVisibleSkillsForTool(
        ctx.allocator,
        ctx.workspace_root,
        ctx.skills_dir,
    );
    defer discovery.deinit(ctx.allocator);
    skill_runtime.traceDiagnostics("capability_search", discovery.diagnostics);
    try reportDiagnostics(ctx, discovery.diagnostics);

    return renderProjectedSearch(
        ctx.allocator,
        request,
        discovery.skills,
        ctx.context_limits.skill_description_bytes,
        max_bytes,
    );
}

fn reportDiagnostics(
    ctx: tool_dispatch.DispatchContext,
    diagnostics: []const skill_runtime.SkillDiagnostic,
) error{OutOfMemory}!void {
    if (diagnostics.len == 0) return;
    var notice: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer notice.deinit();
    skill_runtime.writeDiagnosticSummary(ctx.allocator, &notice.writer, diagnostics) catch
        return error.OutOfMemory;
    if (notice.written().len > 0) {
        try tool_dispatch.reportContextNotice(ctx, notice.written());
    }
}

fn renderProjectedSearch(
    alloc: Allocator,
    request: capability_retrieval.Request,
    skills: []const skill_runtime.Skill,
    description_limit: context_limits.Resolved,
    max_bytes: usize,
) !SearchResult {
    const documents = try alloc.alloc(capability_retrieval.Document, skills.len);
    defer alloc.free(documents);
    const document_skills = try alloc.alloc(*const skill_runtime.Skill, skills.len);
    defer alloc.free(document_skills);
    var identity_scratch_state = std.heap.ArenaAllocator.init(alloc);
    defer identity_scratch_state.deinit();
    const identity_scratch = identity_scratch_state.allocator();
    var document_count: usize = 0;
    for (skills) |*skill| {
        if (!try tool_result_limits.modelProjectionPreservesText(identity_scratch, skill.name) or
            !try tool_result_limits.modelProjectionPreservesText(identity_scratch, skill.path))
        {
            continue;
        }
        documents[document_count] = .{
            .identities = .{ skill.name, "" },
            .stable_key = skill.path,
            .primary = .{ skill.name, "", "", "" },
            .secondary = .{ skill.description, "", "" },
        };
        document_skills[document_count] = skill;
        document_count += 1;
    }
    var page = try capability_retrieval.retrieve(
        alloc,
        request,
        .skill,
        documents[0..document_count],
    );
    defer page.deinit(alloc);
    var retained_count = page.matches.len;

    while (true) {
        const next_cursor = try page.cursorAfter(alloc, retained_count);
        defer if (next_cursor) |cursor| alloc.free(cursor);
        const raw = renderRawSearch(
            alloc,
            page.matches[0..retained_count],
            document_skills[0..document_count],
            description_limit.effectiveBytes(),
            page.total_matches,
            next_cursor,
        ) catch |err| switch (err) {
            error.WriteFailed => return error.OutOfMemory,
            else => return err,
        };
        defer alloc.free(raw.bytes);

        const projected = @constCast(try tool_result_limits.prepareModelOutput(
            alloc,
            "capability_search",
            raw.bytes,
            max_bytes,
        ));
        errdefer alloc.free(projected);
        if (std.mem.eql(u8, raw.bytes, projected)) return .{
            .model_output = projected,
            .items_start = raw.items_start,
            .items_end = raw.items_end,
            .count = retained_count,
            .total_matches = page.total_matches,
        };
        alloc.free(projected);
        if (retained_count == 0) return error.SkillSearchResultLimitTooSmall;
        retained_count -= 1;
    }
}

fn renderRawSearch(
    alloc: Allocator,
    matches: []const capability_retrieval.Match,
    skills: []const *const skill_runtime.Skill,
    description_limit: usize,
    total_matches: usize,
    next_cursor: ?[]const u8,
) !RenderedSearch {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll("{\"skills\":[");
    const items_start = out.written().len;
    for (matches, 0..) |match, index| {
        if (index > 0) try out.writer.writeByte(',');
        const skill = skills[match.document_index];
        const description_end = context_limits.utf8PrefixLength(
            skill.description,
            description_limit,
        );
        try out.writer.writeAll("{\"name\":");
        try std.json.Stringify.value(skill.name, .{}, &out.writer);
        try out.writer.writeAll(",\"description\":");
        try std.json.Stringify.value(skill.description[0..description_end], .{}, &out.writer);
        try out.writer.writeAll(",\"location\":");
        try std.json.Stringify.value(skill.path, .{}, &out.writer);
        try out.writer.writeByte('}');
    }
    const items_end = out.written().len;
    try out.writer.print("],\"count\":{d},\"total_matches\":{d},\"more_available\":{s},\"next_cursor\":", .{
        matches.len,
        total_matches,
        if (next_cursor != null) "true" else "false",
    });
    try std.json.Stringify.value(next_cursor, .{}, &out.writer);
    try out.writer.writeByte('}');
    return .{
        .bytes = try out.toOwnedSlice(),
        .items_start = items_start,
        .items_end = items_end,
    };
}

test "skill search ranks metadata and returns final-projection-stable JSON" {
    const alloc = std.testing.allocator;
    const skills = [_]skill_runtime.Skill{
        .{ .name = "general", .description = "Review ordinary text", .path = "/skills/general/SKILL.md", .source = .workspace_fx },
        .{ .name = "fx-review", .description = "Review fx runtime changes", .path = "/skills/fx-review/SKILL.md", .source = .workspace_fx },
    };
    const query = try lexical_relevance.prepare("review fx runtime public");
    var result = try renderProjectedSearch(
        alloc,
        .{ .query = &query, .kind = .skill, .limit = capability_retrieval.default_limit },
        &skills,
        (context_limits.Values{}).skill_description_bytes,
        4096,
    );
    defer result.deinit(alloc);
    const output = result.model_output;
    try std.testing.expect(std.mem.find(u8, output, "\"name\":\"fx-review\"") != null);
    try std.testing.expect(std.mem.find(u8, output, "\"count\":1") != null);

    const projected_again = try tool_result_limits.prepareModelOutput(alloc, "capability_search", output, 4096);
    defer alloc.free(@constCast(projected_again));
    try std.testing.expectEqualStrings(output, projected_again);
}

test "skill search preserves projected identities and verbatim descriptions" {
    const alloc = std.testing.allocator;
    const skills = [_]skill_runtime.Skill{
        .{ .name = "unsafe-location", .description = "Review files", .path = "/skills/TOKEN=path-secret-value", .source = .workspace_fx },
        .{ .name = "safe", .description = "API_KEY=description-secret-value", .path = "/skills/safe/SKILL.md", .source = .workspace_fx },
    };
    const query = try lexical_relevance.prepare("");
    var result = try renderProjectedSearch(
        alloc,
        .{ .query = &query, .kind = .skill, .limit = capability_retrieval.default_limit },
        &skills,
        (context_limits.Values{}).skill_description_bytes,
        4096,
    );
    defer result.deinit(alloc);
    const output = result.model_output;
    try std.testing.expect(std.mem.find(u8, output, "unsafe-location") != null);
    try std.testing.expect(std.mem.find(u8, output, "\"name\":\"safe\"") != null);
    try std.testing.expect(std.mem.find(u8, output, "API_KEY=description-secret-value") != null);
    try std.testing.expect(std.mem.find(u8, output, "\"count\":2") != null);
    try std.testing.expect(std.mem.find(u8, output, "\"more_available\":false") != null);
}

test "skill search caps ranked entries and atomically omits byte overflow" {
    const alloc = std.testing.allocator;
    const skills = [_]skill_runtime.Skill{
        .{ .name = "one", .description = text_utils.repeat("x", 700), .path = "/skills/one/SKILL.md", .source = .workspace_fx },
        .{ .name = "two", .description = "two", .path = "/skills/two/SKILL.md", .source = .workspace_fx },
        .{ .name = "three", .description = "three", .path = "/skills/three/SKILL.md", .source = .workspace_fx },
        .{ .name = "four", .description = "four", .path = "/skills/four/SKILL.md", .source = .workspace_fx },
        .{ .name = "five", .description = "five", .path = "/skills/five/SKILL.md", .source = .workspace_fx },
        .{ .name = "six", .description = "six", .path = "/skills/six/SKILL.md", .source = .workspace_fx },
        .{ .name = "seven", .description = "seven", .path = "/skills/seven/SKILL.md", .source = .workspace_fx },
        .{ .name = "eight", .description = "eight", .path = "/skills/eight/SKILL.md", .source = .workspace_fx },
        .{ .name = "nine", .description = "nine", .path = "/skills/nine/SKILL.md", .source = .workspace_fx },
    };
    const query = try lexical_relevance.prepare("");
    var result = try renderProjectedSearch(
        alloc,
        .{ .query = &query, .kind = .skill, .limit = capability_retrieval.default_limit },
        &skills,
        (context_limits.Values{}).skill_description_bytes,
        1024,
    );
    defer result.deinit(alloc);
    const output = result.model_output;

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, output, .{});
    defer parsed.deinit();
    const entries = parsed.value.object.get("skills").?.array.items;
    try std.testing.expect(entries.len < capability_retrieval.default_limit);
    try std.testing.expect(entries.len > 0);
    try std.testing.expect(parsed.value.object.get("more_available").?.bool);
    try std.testing.expectEqual(@as(usize, @intCast(parsed.value.object.get("count").?.integer)), entries.len);
}

test "skill search projection releases every allocation failure" {
    const Case = struct {
        fn run(alloc: Allocator) !void {
            const skills = [_]skill_runtime.Skill{
                .{ .name = "unsafe", .description = "unsafe", .path = "/skills/TOKEN=runtime-location-secret/SKILL.md", .source = .workspace_fx },
                .{ .name = "oversized", .description = text_utils.repeat("x", 700), .path = "/skills/oversized/SKILL.md", .source = .workspace_fx },
                .{ .name = "three", .description = "three", .path = "/skills/three/SKILL.md", .source = .workspace_fx },
                .{ .name = "four", .description = "four", .path = "/skills/four/SKILL.md", .source = .workspace_fx },
                .{ .name = "five", .description = "five", .path = "/skills/five/SKILL.md", .source = .workspace_fx },
                .{ .name = "six", .description = "six", .path = "/skills/six/SKILL.md", .source = .workspace_fx },
                .{ .name = "seven", .description = "seven", .path = "/skills/seven/SKILL.md", .source = .workspace_fx },
                .{ .name = "eight", .description = "eight", .path = "/skills/eight/SKILL.md", .source = .workspace_fx },
                .{ .name = "nine", .description = "nine", .path = "/skills/nine/SKILL.md", .source = .workspace_fx },
            };
            const query = try lexical_relevance.prepare("");
            var result = try renderProjectedSearch(
                alloc,
                .{ .query = &query, .kind = .skill, .limit = capability_retrieval.default_limit },
                &skills,
                (context_limits.Values{}).skill_description_bytes,
                1024,
            );
            result.deinit(alloc);
        }
    };
    try std.testing.checkAllAllocationFailures(testing_allocator.no_resize, Case.run, .{});
}
