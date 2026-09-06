const std = @import("std");
const io_mod = @import("../shared/io.zig");
const model_context_encoding = @import("../shared/model_context_encoding.zig");
const skill_contract = @import("skill_contract.zig");
const skill_runtime = @import("skill_runtime.zig");
const text_utils = @import("../shared/text_utils.zig");
const types = @import("../shared/types.zig");
const tool_result_limits = @import("../tooling/tool_result_limits.zig");
const context_limits = @import("../config/context_limits.zig");
const test_debug_trace = if (@import("builtin").is_test)
    @import("../shared/debug_trace.zig")
else
    struct {};

const Allocator = std.mem.Allocator;
const ambiguous_skill_suffix_fmt = "; {d} additional advertised location{s} omitted by the {d}-byte tool-result limit. Refresh available skills and retry with an advertised name and location.";
const discovery_model_notice = "<skill_discovery_warning details=\"context_notice\" />\n";
const content_name_prefix = "<skill_content name=\"";
const test_workspace_roots = [_]skill_contract.RootSpec{
    .{ .source = .workspace_shared, .path = "skills" },
};
const test_root_policy: skill_contract.RootPolicy = .{
    .workspace_roots = &test_workspace_roots,
    .managed_root_source = .global_fx,
};

/// Returns a name borrowed from buffer for display only, never skill resolution.
pub fn displayNameFromOutput(output: []const u8, buffer: *[skill_contract.max_name_bytes]u8) ?[]const u8 {
    const content = if (std.mem.startsWith(u8, output, discovery_model_notice)) output[discovery_model_notice.len..] else output;
    if (!std.mem.startsWith(u8, content, content_name_prefix)) return null;
    const rest = content[content_name_prefix.len..];
    const end = std.mem.findScalar(u8, rest[0..@min(rest.len, skill_contract.max_name_bytes * 6 + 1)], '"') orelse return null;
    if (!std.mem.startsWith(u8, rest[end..], "\" location=\"") and
        !std.mem.startsWith(u8, rest[end..], "\" resource=\"")) return null;
    const encoded = rest[0..end];
    const entities = [_]struct { encoded: []const u8, decoded: []const u8 }{
        .{ .encoded = "&amp;", .decoded = "&" },
        .{ .encoded = "&lt;", .decoded = "<" },
        .{ .encoded = "&gt;", .decoded = ">" },
        .{ .encoded = "&quot;", .decoded = "\"" },
        .{ .encoded = "&#x85;", .decoded = "\xc2\x85" },
        .{ .encoded = "&#x2028;", .decoded = "\xe2\x80\xa8" },
        .{ .encoded = "&#x2029;", .decoded = "\xe2\x80\xa9" },
    };
    var cursor: usize = 0;
    var written: usize = 0;
    while (cursor < encoded.len) {
        const bytes = if (encoded[cursor] == '&') entity: {
            for (entities) |pair| {
                if (!std.mem.startsWith(u8, encoded[cursor..], pair.encoded)) continue;
                cursor += pair.encoded.len;
                break :entity pair.decoded;
            }
            return null;
        } else literal: {
            if (encoded[cursor] == '<' or encoded[cursor] == '>') return null;
            cursor += 1;
            break :literal encoded[cursor - 1 .. cursor];
        };
        if (bytes.len > buffer.len - written) return null;
        @memcpy(buffer[written..][0..bytes.len], bytes);
        written += bytes.len;
    }
    const name = buffer[0..written];
    return if (skill_contract.invalidSkillNameCause(name) == null) name else null;
}

test "skill display names round trip the generated result header within its preview" {
    const names = [_][]const u8{ "workflow", "quotes\" & <name> ' café", "literal &quot; &amp;", "line\u{0085}\u{2028}\u{2029}break", "\"" ** skill_contract.max_name_bytes };
    for (names) |name| {
        for ([_]bool{ false, true }) |with_notice| {
            var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
            defer out.deinit();
            if (with_notice) try out.writer.writeAll(discovery_model_notice);
            try out.writer.writeAll(content_name_prefix);
            try model_context_encoding.writeScalar(&out.writer, name);
            try out.writer.writeAll("\" location=\"/skills/" ++ ("long-path" ** 600));
            var buffer: [skill_contract.max_name_bytes]u8 = undefined;
            const preview = out.written()[0..@min(out.written().len, @import("../session/result_store.zig").preview_bytes)];
            try std.testing.expectEqualStrings(name, displayNameFromOutput(preview, &buffer).?);
        }
    }
}

test "skill display names reject unrelated malformed and invalid metadata" {
    const invalid = [_][]const u8{
        "A quoted result: <skill_content name=\"workflow\" location=\"/skills/workflow\">",
        "<skill_content>body <skill_content name=\"workflow\" location=\"/skills/workflow\">",
        "<skill_content name=\"unfinished",
        "<skill_content name=\"workflow\">",
        "<skill_content name=\"\" location=\"/skills/workflow\">",
        "<skill_content name=\"bad&unknown;\" location=\"/skills/workflow\">",
        "<skill_content name=\"bad<value\" location=\"/skills/workflow\">",
        "<skill_content name=\"bad&#x0a;value\" location=\"/skills/workflow\">",
        "<skill_content name=\"../escape\" location=\"/skills/workflow\">",
        "<skill_content name=\"\xff\" location=\"/skills/workflow\">",
        "<skill_content name=\"" ++ ("a" ** (skill_contract.max_name_bytes + 1)) ++ "\" location=\"/skills/workflow\">",
    };
    for (invalid) |output| {
        var buffer: [skill_contract.max_name_bytes]u8 = undefined;
        try std.testing.expect(displayNameFromOutput(output, &buffer) == null);
    }
}

test "skill display name parsing stays bounded" {
    try std.testing.fuzz({}, struct {
        fn check(_: void, smith: *std.testing.Smith) !void {
            var input_buffer: [4096]u8 = undefined;
            const input = input_buffer[0..smith.slice(&input_buffer)];
            var buffer: [skill_contract.max_name_bytes]u8 = undefined;
            const name = displayNameFromOutput(input, &buffer) orelse return;
            try std.testing.expect(name.len <= buffer.len);
            try std.testing.expect(skill_contract.invalidSkillNameCause(name) == null);
        }
    }.check, .{ .corpus = &.{
        content_name_prefix ++ "workflow\" location=\"/skills/workflow\">",
        discovery_model_notice ++ content_name_prefix ++ "name&amp;value\" resource=\"SKILL.md\">",
        content_name_prefix ++ "bad&unknown;\" location=\"/skills/workflow\">",
    } });
}

/// Borrows a previously discovered skill inventory for one invocation.
pub const Catalog = struct {
    skills: []const skill_runtime.Skill,
    diagnostics: []const skill_runtime.SkillDiagnostic = &.{},
};

const CandidateCheck = struct {
    skill: *const skill_runtime.Skill,
    validation: CandidateValidation,
};

const CandidateValidation = union(enum) {
    current,
    missing,
    name_mismatch,
    skipped: skill_runtime.SkillDiagnosticCause,
};

const TestLoadHook = struct {
    ctx: *anyopaque,
    check: *const fn (*anyopaque) anyerror!void,
};

const LoadOptions = struct {
    mode: enum { chunk, whole } = .chunk,
    cancel_flag: ?*std.atomic.Value(bool) = null,
    test_after_candidate_validation: if (@import("builtin").is_test) ?TestLoadHook else void =
        if (@import("builtin").is_test) null else {},
};

const ExecuteOutput = skill_contract.ExecuteOutput;

/// Owns every non-null output slice. Release it with `freeExecuteResult`, or
/// transfer the model output with `takeModelOutput`.
pub const ExecuteResult = union(enum) {
    loaded: ExecuteOutput,
    failure: ExecuteOutput,

    pub fn modelOutput(self: ExecuteResult) []const u8 {
        return switch (self) {
            .loaded, .failure => |output| output.model_output,
        };
    }

    pub fn contextNotice(self: ExecuteResult) ?[]const u8 {
        return switch (self) {
            .loaded, .failure => |output| output.notice,
        };
    }

    pub fn diagnosticNotice(self: ExecuteResult) ?[]const u8 {
        return switch (self) {
            .loaded, .failure => |output| output.diagnostic_notice,
        };
    }
};

/// Borrows the identity selected by a caller.
pub const ExplicitBinding = struct {
    name: []const u8,
    path: []const u8,
};

/// Owns `text` and all optional notices.
pub const ExplicitPromptSection = struct {
    text: []u8,
    notice: ?[]u8 = null,
    diagnostic_notice: ?[]u8 = null,
    load_notice: ?types.SemanticNotice = null,
    load_details: ?[]u8 = null,

    pub fn deinit(self: *ExplicitPromptSection, alloc: Allocator) void {
        alloc.free(self.text);
        if (self.notice) |notice| alloc.free(notice);
        if (self.diagnostic_notice) |notice| alloc.free(notice);
        if (self.load_notice) |notice| types.freeSemanticNotice(alloc, notice);
        if (self.load_details) |details| alloc.free(details);
        self.* = .{ .text = &.{} };
    }
};

/// Builds the ordered prompt section for explicit bindings and prompt matches.
/// The returned section owns its output slices.
pub fn buildExplicitPromptSection(
    alloc: Allocator,
    catalog: Catalog,
    prompt: []const u8,
    bindings: []const ExplicitBinding,
    limits: context_limits.Values,
    cancel_flag: ?*std.atomic.Value(bool),
) !ExplicitPromptSection {
    const binding_plan = try buildExplicitBindingPlan(alloc, catalog.skills, prompt, bindings);
    defer alloc.free(binding_plan);
    if (binding_plan.len == 0) {
        return .{ .text = try alloc.dupe(u8, "") };
    }

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    var notices: std.Io.Writer.Allocating = .init(alloc);
    defer notices.deinit();
    var diagnostic_notices: std.Io.Writer.Allocating = .init(alloc);
    defer diagnostic_notices.deinit();
    var load_rows: std.Io.Writer.Allocating = .init(alloc);
    defer load_rows.deinit();
    var load_details: std.Io.Writer.Allocating = .init(alloc);
    defer load_details.deinit();
    var loaded: usize = 0;

    try out.writer.writeAll(
        "Explicitly invoked skill content for this query:\n" ++
            "Use every successfully loaded skill for this query. Report blocked or ambiguous requests.\n" ++
            "Follow each skill's complete instructions and required resources before substantive work.\n" ++
            "If a skill cannot be followed, state the blocker instead of silently substituting another workflow.\n",
    );
    for (binding_plan, 0..) |entry, index| {
        try load_rows.writer.writeAll(if (index + 1 == binding_plan.len) "\n└ " else "\n├ ");
        switch (entry) {
            .bound => |binding| if (try appendExplicitSkill(
                alloc,
                &out.writer,
                &notices.writer,
                &diagnostic_notices,
                &load_rows.writer,
                &load_details.writer,
                catalog,
                binding.name,
                binding.path,
                limits,
                cancel_flag,
                context_limits.emergency_ceiling_bytes -| out.written().len,
            )) {
                loaded += 1;
            },
            .ambiguous => |name| {
                const failure = try formatAmbiguousSkill(alloc, catalog.skills, name, 4096);
                defer alloc.free(failure);
                try out.writer.writeAll(failure);
                try out.writer.writeByte('\n');
                try appendExplicitLoadRow(alloc, &load_rows.writer, name, "ambiguous name");
                try appendExplicitLoadRow(alloc, &load_details.writer, name, failure);
                try load_details.writer.writeByte('\n');
            },
        }
    }

    const failed = binding_plan.len - loaded;
    const summary = if (failed == 0)
        try std.fmt.allocPrint(alloc, "{d} requested skill{s} loaded{s}", .{ loaded, if (loaded == 1) "" else "s", load_rows.written() })
    else
        try std.fmt.allocPrint(alloc, "Requested skills · {d} loaded · {d} failed (ctrl o for details){s}", .{ loaded, failed, load_rows.written() });
    errdefer alloc.free(summary);
    const details = if (load_details.written().len > 0) try load_details.toOwnedSlice() else null;
    errdefer if (details) |value| alloc.free(value);

    const text = try out.toOwnedSlice();
    errdefer alloc.free(text);
    const notice = if (notices.written().len > 0) try notices.toOwnedSlice() else null;
    errdefer if (notice) |value| alloc.free(value);
    const diagnostic_notice = if (diagnostic_notices.written().len > 0) try diagnostic_notices.toOwnedSlice() else null;
    return .{
        .text = text,
        .notice = notice,
        .diagnostic_notice = diagnostic_notice,
        .load_notice = .{ .topic = "", .tone = if (failed == 0) .neutral else .warning, .body = summary },
        .load_details = details,
    };
}

fn appendExplicitLoadRow(alloc: Allocator, out: *std.Io.Writer, name: []const u8, failure: ?[]const u8) !void {
    const row = if (failure) |detail|
        if (detail.len > 0)
            try std.fmt.allocPrint(alloc, "Could not load {s}: {s}", .{ name, detail })
        else
            try std.fmt.allocPrint(alloc, "Could not load {s}", .{name})
    else
        try std.fmt.allocPrint(alloc, "Loaded skill {s}", .{name});
    defer alloc.free(row);
    const redacted = try tool_result_limits.prepareRedactedOutput(alloc, row);
    defer alloc.free(redacted);
    const safe = try text_utils.encodeTerminalSafe(alloc, redacted, context_limits.emergency_ceiling_bytes);
    defer alloc.free(safe.bytes);
    try out.writeAll(safe.bytes);
}

test "explicit skill requests report ambiguous names without selecting a source" {
    const alloc = std.testing.allocator;
    const skills = [_]skill_runtime.Skill{
        .{ .name = "review", .description = "workspace", .path = "/workspace/review", .source = .workspace_fx },
        .{ .name = "review", .description = "global", .path = "/global/review", .source = .global_fx },
    };
    var section = try buildExplicitPromptSection(alloc, .{ .skills = &skills }, "$review this patch", &.{}, .{}, null);
    defer section.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, section.text, "ambiguous") != null);
    try std.testing.expect(std.mem.find(u8, section.text, "already loaded") == null);
    try expectContains(section.load_notice.?.body, "Requested skills · 0 loaded · 1 failed");
    try expectContains(section.load_notice.?.body, "Could not load review:");
    try expectNotContains(section.load_notice.?.body, "Loaded skill review");
    try expectContains(section.load_notice.?.body, "ambiguous name");
    try expectNotContains(section.load_notice.?.body, "/workspace/review");
    try expectNotContains(section.load_notice.?.body, "/global/review");
    try expectContains(section.load_notice.?.body, "ctrl o");
    try expectContains(section.load_details.?, "/workspace/review");
    try expectContains(section.load_details.?, "/global/review");
    try std.testing.expect(section.notice == null);
}

test "explicit skills include complete instructions beyond the default chunk" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workflow");
    var file = try tmp.dir.createFile(io_mod.getIo(), "workflow/SKILL.md", .{});
    defer file.close(io_mod.getIo());
    try file.writeStreamingAll(io_mod.getIo(), "---\nname: workflow\ndescription: helper\n---\nBEGIN INSTRUCTIONS\n" ++ ("required step\n" ** 2000) ++ "COMPLETE TAIL\n");
    const path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workflow");
    defer alloc.free(path);
    const skills = [_]skill_runtime.Skill{.{ .name = "workflow", .description = "helper", .path = path, .source = .global_fx }};
    var section = try buildExplicitPromptSection(alloc, .{ .skills = &skills }, "$workflow", &.{}, .{}, null);
    defer section.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, section.text, "BEGIN INSTRUCTIONS") != null);
    try std.testing.expect(std.mem.find(u8, section.text, "COMPLETE TAIL") != null);
    try std.testing.expectEqualStrings("1 requested skill loaded\n└ Loaded skill workflow", section.load_notice.?.body);
    try std.testing.expect(section.load_details == null);
    const bindings = [_]ExplicitBinding{ .{ .name = "workflow", .path = path }, .{ .name = "workflow", .path = path } };
    var repeated = try buildExplicitPromptSection(alloc, .{ .skills = &skills }, "$workflow $workflow", &bindings, .{}, null);
    defer repeated.deinit(alloc);
    try std.testing.expectEqualStrings(section.text, repeated.text);
    try std.testing.expectEqualStrings(section.load_notice.?.body, repeated.load_notice.?.body);
    var cancelled = std.atomic.Value(bool).init(true);
    try std.testing.expectError(error.Cancelled, buildExplicitPromptSection(alloc, .{ .skills = &skills }, "$workflow", &.{}, .{}, &cancelled));
}

test "explicit load rows keep untrusted names and diagnostics terminal safe" {
    const alloc = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try appendExplicitLoadRow(alloc, &out.writer, "workflow\n\x1b[2J", "Failed\r\nAPI_KEY=private-skill-secret");
    try expectContains(out.written(), "Could not load workflow");
    try std.testing.expect(text_utils.isTerminalSafe(out.written()));
    try expectNotContains(out.written(), "\n");
    try expectNotContains(out.written(), "\x1b");
    try expectNotContains(out.written(), "private-skill-secret");
}

test "explicit load summary reports a missing bound skill without success" {
    const alloc = std.testing.allocator;
    var section = try buildExplicitPromptSection(alloc, .{ .skills = &.{} }, "Use the selected workflow", &.{.{ .name = "missing-workflow", .path = "/unavailable/workflow" }}, .{}, null);
    defer section.deinit(alloc);
    try expectContains(section.load_notice.?.body, "Requested skills · 0 loaded · 1 failed");
    try expectContains(section.load_notice.?.body, "Could not load missing-workflow");
    try expectNotContains(section.load_notice.?.body, "/unavailable/workflow");
    try expectContains(section.load_details.?, "not found at advertised location");
    try expectNotContains(section.text, "<skill_content");
}

test "skill resource defaults preserve whole and legacy reads" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workflow");
    var file = try tmp.dir.createFile(io_mod.getIo(), "workflow/SKILL.md", .{});
    defer file.close(io_mod.getIo());
    try file.writeStreamingAll(io_mod.getIo(), "---\nname: workflow\n---\nMAIN DOCUMENT\n");
    const path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workflow");
    defer alloc.free(path);
    const skills = [_]skill_runtime.Skill{.{ .name = "workflow", .description = "", .path = path, .source = .global_fx }};
    const catalog: Catalog = .{ .skills = &skills };
    const whole = try loadWholeByLocation(alloc, catalog, path, "SKILL.md", .{}, null, null);
    defer freeExecuteResult(alloc, whole);
    try std.testing.expect(whole == .loaded and whole.loaded.complete);
    try expectContains(whole.modelOutput(), "MAIN DOCUMENT");
    for ([_]?[]const u8{ null, "" }) |resource| {
        const result = try loadWholeByLocation(alloc, catalog, path, resource, .{}, null, null);
        defer freeExecuteResult(alloc, result);
        try std.testing.expectEqualStrings(whole.modelOutput(), result.modelOutput());
        for ([_]usize{ 0, 4 }) |offset| {
            const expected = try loadByIdentity(alloc, catalog, "workflow", path, "SKILL.md", offset, .{}, null);
            defer freeExecuteResult(alloc, expected);
            const legacy = try loadByIdentity(alloc, catalog, "workflow", path, resource, offset, .{}, null);
            defer freeExecuteResult(alloc, legacy);
            try std.testing.expectEqualStrings(expected.modelOutput(), legacy.modelOutput());
        }
    }
    for ([_][]const u8{ " ", "../outside.txt", "/outside.txt" }) |resource| {
        try std.testing.expectError(error.InvalidSkillResourcePath, loadWholeByLocation(alloc, catalog, path, resource, .{}, null, null));
    }
    try std.testing.expectError(error.FileNotFound, loadWholeByLocation(alloc, catalog, path, "missing.md", .{}, null, null));
}

test "whole skill reads respect explicit bounds cancellation and recovery" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workflow");
    var file = try tmp.dir.createFile(io_mod.getIo(), "workflow/SKILL.md", .{});
    defer file.close(io_mod.getIo());
    try file.writeStreamingAll(io_mod.getIo(), "---\nname: workflow\n---\n" ++ ("required step\n" ** 2000) ++ "COMPLETE TAIL\n");
    const path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workflow");
    defer alloc.free(path);
    const skills = [_]skill_runtime.Skill{.{ .name = "workflow", .description = "", .path = path, .source = .global_fx }};
    const catalog: Catalog = .{ .skills = &skills };
    var limits = context_limits.Values{};
    limits.skill_file_bytes = .{ .value = .{ .bytes = 128 }, .source = .command_line };
    const file_blocked = try loadWholeByLocation(alloc, catalog, path, null, limits, null, null);
    defer freeExecuteResult(alloc, file_blocked);
    try std.testing.expect(file_blocked == .failure);
    try expectContains(file_blocked.modelOutput(), "skill_file_bytes");
    try expectNotContains(file_blocked.modelOutput(), "required step");

    limits.skill_file_bytes = .{ .value = .off, .source = .command_line };
    limits.skill_chunk_bytes = .{ .value = .{ .bytes = 128 }, .source = .command_line };
    const chunk_blocked = try loadWholeByLocation(alloc, catalog, path, null, limits, null, null);
    defer freeExecuteResult(alloc, chunk_blocked);
    try std.testing.expect(chunk_blocked == .failure);
    try expectContains(chunk_blocked.modelOutput(), "skill_chunk_bytes");
    try expectNotContains(chunk_blocked.modelOutput(), "required step");

    limits.skill_chunk_bytes = .{ .value = .off, .source = .command_line };
    const result_blocked = try loadWholeByLocation(alloc, catalog, path, null, limits, 1024, null);
    defer freeExecuteResult(alloc, result_blocked);
    try std.testing.expect(result_blocked == .failure);
    try std.testing.expect(result_blocked.modelOutput().len <= 1024);
    try expectContains(result_blocked.modelOutput(), "max_tool_result_bytes");
    try expectNotContains(result_blocked.modelOutput(), "required step");

    var cancelled = std.atomic.Value(bool).init(true);
    try std.testing.expectError(error.Cancelled, loadWholeByLocation(alloc, catalog, path, null, limits, null, &cancelled));
    cancelled.store(false, .seq_cst);
    const Cancel = struct {
        fn run(raw: *anyopaque) !void {
            const flag: *std.atomic.Value(bool) = @ptrCast(@alignCast(raw));
            flag.store(true, .seq_cst);
        }
    };
    try std.testing.expectError(error.Cancelled, loadByIdentityWithOptions(alloc, catalog, "workflow", path, null, 0, limits, null, .{
        .mode = .whole,
        .cancel_flag = &cancelled,
        .test_after_candidate_validation = .{ .ctx = &cancelled, .check = Cancel.run },
    }));
    cancelled.store(false, .seq_cst);
    const recovered = try loadWholeByLocation(alloc, catalog, path, null, limits, null, &cancelled);
    defer freeExecuteResult(alloc, recovered);
    try std.testing.expect(recovered == .loaded and recovered.loaded.complete);
    try expectContains(recovered.modelOutput(), "COMPLETE TAIL");
}

test "whole skill reads reject identity changes after candidate validation" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workflow");
    {
        var file = try tmp.dir.createFile(io_mod.getIo(), "workflow/SKILL.md", .{});
        defer file.close(io_mod.getIo());
        try file.writeStreamingAll(io_mod.getIo(), "---\nname: workflow\ndescription: helper\n---\nORIGINAL BODY\n");
    }
    const path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workflow");
    defer alloc.free(path);
    const skills = [_]skill_runtime.Skill{.{ .name = "workflow", .description = "helper", .path = path, .source = .global_fx }};
    const Rewrite = struct {
        fn run(raw: *anyopaque) !void {
            const dir: *std.Io.Dir = @ptrCast(@alignCast(raw));
            var file = try dir.createFile(io_mod.getIo(), "workflow/SKILL.md", .{});
            defer file.close(io_mod.getIo());
            try file.writeStreamingAll(io_mod.getIo(), "---\nname: replaced\ndescription: helper\n---\nREPLACED BODY\n");
        }
    };
    const attempt = loadByIdentityWithOptions(alloc, .{ .skills = &skills }, "workflow", path, null, 0, .{}, null, .{
        .mode = .whole,
        .test_after_candidate_validation = .{ .ctx = &tmp.dir, .check = Rewrite.run },
    });
    if (attempt) |result| {
        defer freeExecuteResult(alloc, result);
        return error.ChangedSkillWasLoaded;
    } else |err| {
        try std.testing.expectEqual(error.SkillResourceChanged, err);
    }
}

test "skill references reject primary identity changes after candidate validation" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workflow");
    var primary = try tmp.dir.createFile(io_mod.getIo(), "workflow/SKILL.md", .{});
    defer primary.close(io_mod.getIo());
    try primary.writeStreamingAll(io_mod.getIo(), "---\nname: workflow\n---\nORIGINAL BODY\n");
    var reference = try tmp.dir.createFile(io_mod.getIo(), "workflow/reference.md", .{});
    defer reference.close(io_mod.getIo());
    try reference.writeStreamingAll(io_mod.getIo(), "REFERENCE BODY\n");
    const path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workflow");
    defer alloc.free(path);
    const skills = [_]skill_runtime.Skill{.{ .name = "workflow", .description = "", .path = path, .source = .global_fx }};
    const Rewrite = struct {
        fn run(raw: *anyopaque) !void {
            const dir: *std.Io.Dir = @ptrCast(@alignCast(raw));
            var file = try dir.createFile(io_mod.getIo(), "workflow/SKILL.md", .{});
            defer file.close(io_mod.getIo());
            try file.writeStreamingAll(io_mod.getIo(), "---\nname: renamed\n---\nCHANGED BODY\n");
        }
    };
    try std.testing.expectError(error.SkillResourceChanged, loadByIdentityWithOptions(alloc, .{ .skills = &skills }, "workflow", path, "reference.md", 0, .{}, null, .{
        .mode = .whole,
        .test_after_candidate_validation = .{ .ctx = &tmp.dir, .check = Rewrite.run },
    }));
}

const PlannedSkill = union(enum) {
    bound: ExplicitBinding,
    ambiguous: []const u8,
};

fn buildExplicitBindingPlan(
    alloc: Allocator,
    skills: []const skill_runtime.Skill,
    prompt: []const u8,
    bindings: []const ExplicitBinding,
) ![]PlannedSkill {
    const selections = try skill_runtime.collectExplicitSkillSelections(alloc, prompt, skills);
    defer alloc.free(selections);

    var plan: std.ArrayList(PlannedSkill) = .empty;
    defer plan.deinit(alloc);
    var loaded_paths = std.StringHashMap(void).init(alloc);
    defer loaded_paths.deinit();

    for (bindings) |binding| {
        if (loaded_paths.contains(binding.path)) continue;
        try loaded_paths.put(binding.path, {});
        try plan.append(alloc, .{ .bound = binding });
    }
    for (selections) |selection| switch (selection) {
        .skill => |index| {
            const skill = skills[index];
            if (loaded_paths.contains(skill.path)) continue;
            try loaded_paths.put(skill.path, {});
            try plan.append(alloc, .{ .bound = .{ .name = skill.name, .path = skill.path } });
        },
        .ambiguous => |name| {
            const explicitly_bound = bound: {
                for (bindings) |binding| {
                    if (std.ascii.eqlIgnoreCase(binding.name, name)) break :bound true;
                }
                break :bound false;
            };
            if (!explicitly_bound) try plan.append(alloc, .{ .ambiguous = name });
        },
    };
    return plan.toOwnedSlice(alloc);
}

fn appendExplicitSkill(
    alloc: Allocator,
    out: *std.Io.Writer,
    notices: *std.Io.Writer,
    diagnostic_notices: *std.Io.Writer.Allocating,
    load_rows: *std.Io.Writer,
    load_details: *std.Io.Writer,
    catalog: Catalog,
    name: []const u8,
    location: []const u8,
    limits: context_limits.Values,
    cancel_flag: ?*std.atomic.Value(bool),
    remaining_bytes: usize,
) !bool {
    const result = try loadByIdentityWithOptions(alloc, catalog, name, location, null, 0, limits, null, .{ .mode = .whole, .cancel_flag = cancel_flag });
    defer freeExecuteResult(alloc, result);
    if (result.modelOutput().len +| 1 > remaining_bytes) return error.SkillContextTooLarge;
    try out.writeAll(result.modelOutput());
    try out.writeByte('\n');
    if (result.contextNotice()) |notice| {
        try notices.writeAll(notice);
        if (!std.mem.endsWith(u8, notice, "\n")) try notices.writeByte('\n');
    }
    if (result.diagnosticNotice()) |notice| {
        if (diagnostic_notices.written().len == 0) {
            try diagnostic_notices.writer.writeAll(notice);
            if (!std.mem.endsWith(u8, notice, "\n")) try diagnostic_notices.writer.writeByte('\n');
        }
    }
    const failure: ?[]const u8 = switch (result) {
        .loaded => |output| if (output.complete) null else "Complete instructions were not loaded.",
        .failure => |output| output.model_output,
    };
    if (failure) |detail| {
        try appendExplicitLoadRow(alloc, load_details, name, detail);
        try load_details.writeByte('\n');
    }
    try appendExplicitLoadRow(alloc, load_rows, name, if (failure != null) "" else null);
    return failure == null;
}

/// Resolves and reads one skill from an already discovered catalog.
/// The returned result owns its output slices.
pub fn loadByIdentity(
    alloc: Allocator,
    catalog: Catalog,
    name: []const u8,
    location: ?[]const u8,
    resource: ?[]const u8,
    offset: usize,
    limits: context_limits.Values,
    max_tool_result_bytes: ?usize,
) !ExecuteResult {
    return loadByIdentityWithOptions(
        alloc,
        catalog,
        name,
        location,
        resource,
        offset,
        limits,
        max_tool_result_bytes,
        .{},
    );
}

pub fn loadWholeByLocation(
    alloc: Allocator,
    catalog: Catalog,
    location: []const u8,
    resource: ?[]const u8,
    limits: context_limits.Values,
    max_tool_result_bytes: ?usize,
    cancel_flag: ?*std.atomic.Value(bool),
) !ExecuteResult {
    for (catalog.skills) |skill| {
        if (!std.mem.eql(u8, skill.path, location)) continue;
        return loadByIdentityWithOptions(alloc, catalog, skill.name, location, resource, 0, limits, max_tool_result_bytes, .{
            .mode = .whole,
            .cancel_flag = cancel_flag,
        });
    }
    return .{ .failure = .{ .model_output = try formatExactSkillNotFound(alloc, "", location, max_tool_result_bytes orelse 4096) } };
}

/// Selects without loading instructions. The caller owns the selected entry or failure.
pub fn prepareIdentity(alloc: Allocator, catalog: Catalog, name: ?[]const u8, location: ?[]const u8, max_tool_result_bytes: usize) !skill_contract.CallPreparation {
    const resolution = if (name) |value|
        skill_runtime.resolveSkill(catalog.skills, value, location)
    else exact: {
        const path = location orelse return error.InvalidSkillLocation;
        for (catalog.skills, 0..) |skill, index| {
            if (std.mem.eql(u8, skill.path, path)) break :exact skill_runtime.SkillResolution{ .found = &catalog.skills[index] };
        }
        break :exact skill_runtime.SkillResolution.not_found;
    };
    if (resolution != .found) {
        var notice = try formatDiscoveryNotice(alloc, catalog.diagnostics, null);
        errdefer if (notice) |value| alloc.free(value);
        const budget = executePrimaryBudget(max_tool_result_bytes, notice != null);
        const output = switch (resolution) {
            .found => unreachable,
            .not_found => if (location) |path|
                try formatExactSkillNotFound(alloc, name orelse "", path, budget)
            else
                try formatMissingSkill(alloc, name.?, budget),
            .ambiguous_name => try formatAmbiguousSkill(alloc, catalog.skills, name.?, budget),
            .name_location_mismatch => try formatSkillLocationMismatch(alloc, name.?, location.?, budget),
        };
        const failure = try attachOwnedDiscoveryNotice(alloc, .{ .failure = .{ .model_output = output } }, &notice, max_tool_result_bytes);
        return .{ .failure = failure.failure };
    }
    const selected = resolution.found.*;
    const owned_name = try alloc.dupe(u8, selected.name);
    errdefer alloc.free(owned_name);
    const description = try alloc.dupe(u8, selected.description);
    errdefer alloc.free(description);
    const path = try alloc.dupe(u8, selected.path);
    errdefer alloc.free(path);
    const read_authority = if (selected.read_authority) |value| try alloc.dupe(u8, value) else null;
    errdefer if (read_authority) |value| alloc.free(value);
    var copied = selected;
    copied.name = owned_name;
    copied.description = description;
    copied.path = path;
    copied.read_authority = read_authority;
    const diagnostics = try alloc.alloc(skill_runtime.SkillDiagnostic, catalog.diagnostics.len);
    var initialized: usize = 0;
    errdefer {
        for (diagnostics[0..initialized]) |diagnostic| alloc.free(diagnostic.path);
        alloc.free(diagnostics);
    }
    for (catalog.diagnostics, diagnostics) |diagnostic, *owned| {
        owned.* = diagnostic;
        owned.path = try alloc.dupe(u8, diagnostic.path);
        initialized += 1;
    }
    return .{ .selected = .{ .skill = copied, .diagnostics = diagnostics } };
}

pub fn freeCallPreparation(alloc: Allocator, preparation: skill_contract.CallPreparation) void {
    switch (preparation) {
        .selected => |selected| {
            skill_runtime.freeSkill(alloc, selected.skill);
            skill_runtime.freeSkillDiagnostics(alloc, selected.diagnostics);
        },
        .failure => |output| freeExecuteResult(alloc, .{ .failure = output }),
    }
}

fn checkPreparedIdentityDiagnostics(alloc: Allocator) !void {
    const skills = [_]skill_runtime.Skill{
        .{ .name = "workflow", .description = "first", .path = "/skills/first", .source = .workspace_agents, .read_authority = "/skills" },
        .{ .name = "workflow", .description = "second", .path = "/skills/second", .source = .global_fx },
    };
    const diagnostics = [_]skill_runtime.SkillDiagnostic{.{
        .path = "/skills/malformed",
        .source = .global_fx,
        .scope = .candidate,
        .cause = .{ .invalid_metadata = .missing_name },
    }};
    const catalog: Catalog = .{ .skills = &skills, .diagnostics = &diagnostics };
    const selected = try prepareIdentity(alloc, catalog, null, skills[0].path, 4096);
    defer freeCallPreparation(alloc, selected);
    try std.testing.expect(selected == .selected);
    try std.testing.expectEqualStrings("workflow", selected.selected.skill.name);
    try std.testing.expectEqual(@as(usize, 1), selected.selected.diagnostics.len);
    try std.testing.expectEqualStrings(diagnostics[0].path, selected.selected.diagnostics[0].path);
    try std.testing.expect(selected.selected.diagnostics[0].path.ptr != diagnostics[0].path.ptr);
    for ([_]struct { name: []const u8, location: ?[]const u8, expected: []const u8 }{
        .{ .name = "missing", .location = null, .expected = "not found" },
        .{ .name = "workflow", .location = null, .expected = "ambiguous" },
        .{ .name = "other", .location = skills[0].path, .expected = "does not match" },
    }) |case| {
        const failure = try prepareIdentity(alloc, catalog, case.name, case.location, 4096);
        defer freeCallPreparation(alloc, failure);
        try std.testing.expect(failure == .failure);
        try expectContains(failure.failure.model_output, case.expected);
        try expectContains(failure.failure.model_output, "skill_discovery_warning");
        try expectContains(failure.failure.diagnostic_notice.?, "metadata is invalid (missing_name)");
        try expectNotContains(failure.failure.model_output, "metadata is invalid");
        if (std.mem.eql(u8, case.expected, "ambiguous")) {
            try expectContains(failure.failure.model_output, skills[0].path);
            try expectContains(failure.failure.model_output, skills[1].path);
        }
    }
}

test "prepared skill identities and selection failures preserve owned diagnostics" {
    try checkPreparedIdentityDiagnostics(std.testing.allocator);
}

test "prepared skill diagnostic ownership survives allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkPreparedIdentityDiagnostics, .{});
}

fn loadByIdentityWithOptions(
    alloc: Allocator,
    catalog: Catalog,
    name: []const u8,
    location: ?[]const u8,
    resource: ?[]const u8,
    offset: usize,
    limits: context_limits.Values,
    max_tool_result_bytes: ?usize,
    options: LoadOptions,
) !ExecuteResult {
    if (options.cancel_flag) |flag| if (flag.load(.seq_cst)) return error.Cancelled;
    const resource_path = skill_contract.resource_path_or_main(resource);
    const resolution = skill_runtime.resolveSkill(catalog.skills, name, location);
    var opened_candidate: ?skill_runtime.OpenedSkillCandidate = null;
    defer if (opened_candidate) |*candidate| candidate.deinit();
    const candidate_check: ?CandidateCheck = switch (resolution) {
        .found => |skill| blk: {
            const validation: CandidateValidation = switch (try skill_runtime.openValidatedSkillCandidate(alloc, skill.*)) {
                .current => |candidate| current: {
                    opened_candidate = candidate;
                    break :current .current;
                },
                .missing => .missing,
                .name_mismatch => .name_mismatch,
                .skipped => |cause| .{ .skipped = cause },
            };
            break :blk .{
                .skill = skill,
                .validation = validation,
            };
        },
        .not_found, .ambiguous_name, .name_location_mismatch => null,
    };
    const current_diagnostic: ?skill_runtime.SkillDiagnostic = if (candidate_check) |check|
        switch (check.validation) {
            .skipped => |cause| .{
                .path = check.skill.path,
                .source = check.skill.source,
                .scope = .candidate,
                .cause = cause,
            },
            .current, .missing, .name_mismatch => null,
        }
    else
        null;
    if (current_diagnostic) |diagnostic| {
        skill_runtime.traceDiagnostics("skill_invocation", &.{diagnostic});
    }

    var discovery_notice = try formatDiscoveryNotice(alloc, catalog.diagnostics, current_diagnostic);
    errdefer if (discovery_notice) |notice| alloc.free(notice);
    const primary_budget = if (max_tool_result_bytes) |limit|
        executePrimaryBudget(limit, discovery_notice != null)
    else
        std.math.maxInt(usize);

    const skill = switch (resolution) {
        .found => |skill| skill,
        .not_found => {
            if (location) |exact_location| {
                return attachOwnedDiscoveryNotice(alloc, .{ .failure = .{ .model_output = try formatExactSkillNotFound(alloc, name, exact_location, primary_budget) } }, &discovery_notice, max_tool_result_bytes);
            }
            return attachOwnedDiscoveryNotice(alloc, .{ .failure = .{ .model_output = try formatMissingSkill(alloc, name, primary_budget) } }, &discovery_notice, max_tool_result_bytes);
        },
        .ambiguous_name => return attachOwnedDiscoveryNotice(alloc, .{ .failure = .{ .model_output = try formatAmbiguousSkill(alloc, catalog.skills, name, primary_budget) } }, &discovery_notice, max_tool_result_bytes),
        .name_location_mismatch => return attachOwnedDiscoveryNotice(alloc, .{ .failure = .{ .model_output = try formatSkillLocationMismatch(alloc, name, location.?, primary_budget) } }, &discovery_notice, max_tool_result_bytes),
    };
    switch (candidate_check.?.validation) {
        .current => {},
        .missing, .skipped => {
            if (location) |exact_location| {
                return attachOwnedDiscoveryNotice(alloc, .{ .failure = .{ .model_output = try formatExactSkillNotFound(alloc, name, exact_location, primary_budget) } }, &discovery_notice, max_tool_result_bytes);
            }
            return attachOwnedDiscoveryNotice(alloc, .{ .failure = .{ .model_output = try formatMissingSkill(alloc, name, primary_budget) } }, &discovery_notice, max_tool_result_bytes);
        },
        .name_mismatch => {
            if (location) |exact_location| {
                return attachOwnedDiscoveryNotice(alloc, .{ .failure = .{ .model_output = try formatSkillLocationMismatch(alloc, name, exact_location, primary_budget) } }, &discovery_notice, max_tool_result_bytes);
            }
            return attachOwnedDiscoveryNotice(alloc, .{ .failure = .{ .model_output = try formatMissingSkill(alloc, name, primary_budget) } }, &discovery_notice, max_tool_result_bytes);
        },
    }
    if (comptime @import("builtin").is_test) {
        if (options.test_after_candidate_validation) |hook| try hook.check(hook.ctx);
    }

    const candidate = if (opened_candidate) |*current| current else unreachable;
    const resource_read = try readSkillResource(alloc, candidate, resource_path, limits.skill_file_bytes, options.cancel_flag);
    defer alloc.free(resource_read.bytes);
    if (options.cancel_flag) |flag| if (flag.load(.seq_cst)) return error.Cancelled;
    if (!skill_runtime.resourceIsSkillFile(resource_path)) {
        try revalidatePrimaryIdentity(alloc, candidate.skillFile(), skill.*);
    }
    if (options.mode == .whole) {
        if (resource_read.observed_bytes > resource_read.bytes.len) {
            return attachOwnedDiscoveryNotice(alloc, try contextLimitFailure(alloc, try formatSkillFileBlocked(
                alloc,
                resource_path,
                resource_read.observed_bytes,
                limits.skill_file_bytes,
            )), &discovery_notice, max_tool_result_bytes);
        }
        if (skill_runtime.resourceIsSkillFile(resource_path)) {
            const metadata = switch (skill_contract.resolveMetadata(skill_contract.parseSkillFile(resource_read.bytes), std.fs.path.basename(skill.path))) {
                .valid => |value| value,
                .invalid => return error.SkillResourceChanged,
            };
            if (!std.mem.eql(u8, metadata.name, skill.name)) return error.SkillResourceChanged;
        }
        if (limits.skill_chunk_bytes.source != .compiled_default and resource_read.bytes.len > limits.skill_chunk_bytes.effectiveBytes()) {
            return attachOwnedDiscoveryNotice(alloc, try contextLimitFailure(alloc, try formatSkillChunkBlocked(
                alloc,
                skill.name,
                resource_path,
                resource_read.bytes.len,
                limits.skill_chunk_bytes,
                0,
            )), &discovery_notice, max_tool_result_bytes);
        }
        var full: std.Io.Writer.Allocating = .init(alloc);
        defer full.deinit();
        full.writer.writeAll(content_name_prefix) catch return error.OutOfMemory;
        model_context_encoding.writeScalar(&full.writer, skill.name) catch return error.OutOfMemory;
        full.writer.writeAll("\" location=\"") catch return error.OutOfMemory;
        model_context_encoding.writeScalar(&full.writer, skill.path) catch return error.OutOfMemory;
        full.writer.writeAll("\" resource=\"") catch return error.OutOfMemory;
        model_context_encoding.writeScalar(&full.writer, resource_path) catch return error.OutOfMemory;
        full.writer.writeAll("\" complete=\"true\">\n") catch return error.OutOfMemory;
        full.writer.writeAll(resource_read.bytes) catch return error.OutOfMemory;
        full.writer.writeAll("\n</skill_content>") catch return error.OutOfMemory;
        const output = try tool_result_limits.prepareRedactedOutput(alloc, full.written());
        if (output.len > primary_budget) {
            defer alloc.free(output);
            const message = try std.fmt.allocPrint(alloc, "Complete skill content exceeds max_tool_result_bytes ({d} bytes). No complete instructions were loaded.", .{primary_budget});
            defer alloc.free(message);
            return attachOwnedDiscoveryNotice(alloc, .{ .failure = .{ .model_output = try boundedSkillError(alloc, message, primary_budget) } }, &discovery_notice, max_tool_result_bytes);
        }
        const notice = if (!std.mem.eql(u8, output, full.written()))
            alloc.dupe(u8, "[context] Skill content was sanitized or secret-masked before delivery.\n") catch |err| {
                alloc.free(output);
                return err;
            }
        else
            null;
        return attachOwnedDiscoveryNotice(alloc, .{ .loaded = .{ .model_output = output, .notice = notice, .complete = true } }, &discovery_notice, max_tool_result_bytes);
    }
    if (offset > resource_read.bytes.len or !std.unicode.utf8ValidateSlice(resource_read.bytes[0..offset])) {
        return attachOwnedDiscoveryNotice(alloc, .{ .failure = .{ .model_output = try alloc.dupe(u8, "skill offset must be at a valid UTF-8 boundary within the selected resource") } }, &discovery_notice, max_tool_result_bytes);
    }
    if (offset == resource_read.bytes.len and resource_read.observed_bytes > resource_read.bytes.len) {
        return attachOwnedDiscoveryNotice(alloc, try contextLimitFailure(alloc, try formatSkillFileBlocked(
            alloc,
            resource_path,
            resource_read.observed_bytes,
            limits.skill_file_bytes,
        )), &discovery_notice, max_tool_result_bytes);
    }

    const remaining = resource_read.bytes[offset..];
    const chunk_limit = limits.skill_chunk_bytes;
    const chunk_len = context_limits.lineSafePrefixLength(remaining, chunk_limit.effectiveBytes());
    if (remaining.len > 0 and chunk_len == 0) {
        return attachOwnedDiscoveryNotice(alloc, try contextLimitFailure(alloc, try formatSkillChunkBlocked(
            alloc,
            skill.name,
            resource_path,
            remaining.len,
            chunk_limit,
            offset,
        )), &discovery_notice, max_tool_result_bytes);
    }
    const next_offset = offset + chunk_len;
    const chunk_truncated = next_offset < resource_read.bytes.len;
    const file_blocked = next_offset == resource_read.bytes.len and resource_read.observed_bytes > resource_read.bytes.len;

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    out.writer.writeAll(content_name_prefix) catch return error.OutOfMemory;
    model_context_encoding.writeScalar(&out.writer, skill.name) catch return error.OutOfMemory;
    out.writer.writeAll("\" resource=\"") catch return error.OutOfMemory;
    model_context_encoding.writeScalar(&out.writer, resource_path) catch return error.OutOfMemory;
    out.writer.print("\" offset=\"{d}\" next_offset=\"{d}\">\n", .{ offset, next_offset }) catch return error.OutOfMemory;
    out.writer.writeAll(remaining[0..chunk_len]) catch return error.OutOfMemory;
    if (chunk_truncated) {
        out.writer.print(
            "\n<context_limit name=\"skill_chunk_bytes\" action=\"truncated\" observed_bytes=\"{d}\" effective_bytes=\"{d}\" source=\"{s}\" next_offset=\"{d}\" override=\"--context-limit skill_chunk_bytes=BYTES|off\" />",
            .{ remaining.len, chunk_limit.effectiveBytes(), chunk_limit.source.label(), next_offset },
        ) catch return error.OutOfMemory;
    } else if (file_blocked) {
        out.writer.writeByte('\n') catch return error.OutOfMemory;
        writeSkillFileBlockedMarker(
            &out.writer,
            resource_path,
            resource_read.observed_bytes,
            limits.skill_file_bytes,
        ) catch return error.OutOfMemory;
    }
    out.writer.writeAll("\n</skill_content>") catch return error.OutOfMemory;

    const model_content = out.toOwnedSlice() catch return error.OutOfMemory;
    const notice = if (chunk_truncated)
        formatSkillChunkNotice(
            alloc,
            skill.name,
            resource_path,
            remaining.len,
            chunk_limit,
            next_offset,
        ) catch |err| {
            alloc.free(model_content);
            return err;
        }
    else if (file_blocked)
        formatSkillFileBlockedNotice(
            alloc,
            skill.name,
            resource_path,
            resource_read.observed_bytes,
            limits.skill_file_bytes,
        ) catch |err| {
            alloc.free(model_content);
            return err;
        }
    else
        null;

    return attachOwnedDiscoveryNotice(alloc, .{ .loaded = .{ .model_output = model_content, .notice = notice } }, &discovery_notice, max_tool_result_bytes);
}

fn formatDiscoveryNotice(
    alloc: Allocator,
    diagnostics: []const skill_runtime.SkillDiagnostic,
    additional: ?skill_runtime.SkillDiagnostic,
) error{OutOfMemory}!?[]u8 {
    if (diagnostics.len == 0 and additional == null) return null;
    var combined = diagnostics;
    var owned_combined: ?[]skill_runtime.SkillDiagnostic = null;
    defer if (owned_combined) |items| alloc.free(items);
    if (additional) |diagnostic| {
        const items = try alloc.alloc(skill_runtime.SkillDiagnostic, diagnostics.len + 1);
        @memcpy(items[0..diagnostics.len], diagnostics);
        items[diagnostics.len] = diagnostic;
        owned_combined = items;
        combined = items;
    }
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    skill_runtime.writeDiagnosticSummary(alloc, &out.writer, combined) catch return error.OutOfMemory;
    return out.toOwnedSlice() catch return error.OutOfMemory;
}

fn attachExecuteNotice(
    alloc: Allocator,
    result: ExecuteResult,
    additional: ?[]u8,
    max_tool_result_bytes: ?usize,
) error{OutOfMemory}!ExecuteResult {
    const notice = additional orelse return result;
    errdefer freeExecuteResult(alloc, result);
    errdefer alloc.free(notice);

    return switch (result) {
        inline .loaded, .failure => |output, tag| blk: {
            var updated = output;
            const model_output = if (max_tool_result_bytes) |limit| bounded: {
                const model_notice_len = @min(discovery_model_notice.len, limit);
                const primary_budget = executePrimaryBudget(limit, true);
                const prepared_primary = @constCast(try tool_result_limits.prepareModelOutput(
                    alloc,
                    "skill",
                    output.model_output,
                    primary_budget,
                ));
                defer alloc.free(prepared_primary);
                const primary_len = context_limits.utf8PrefixLength(prepared_primary, primary_budget);
                break :bounded try std.mem.concat(alloc, u8, &.{
                    discovery_model_notice[0..model_notice_len],
                    prepared_primary[0..primary_len],
                });
            } else try std.mem.concat(alloc, u8, &.{ discovery_model_notice, output.model_output });
            errdefer alloc.free(model_output);
            alloc.free(@constCast(output.model_output));
            updated.model_output = model_output;
            updated.diagnostic_notice = notice;
            break :blk @unionInit(ExecuteResult, @tagName(tag), updated);
        },
    };
}

fn attachOwnedDiscoveryNotice(
    alloc: Allocator,
    result: ExecuteResult,
    additional: *?[]u8,
    max_tool_result_bytes: ?usize,
) error{OutOfMemory}!ExecuteResult {
    const notice = additional.*;
    additional.* = null;
    return attachExecuteNotice(alloc, result, notice, max_tool_result_bytes);
}

fn executePrimaryBudget(max_tool_result_bytes: usize, include_discovery_notice: bool) usize {
    if (!include_discovery_notice) return max_tool_result_bytes;
    return max_tool_result_bytes - @min(discovery_model_notice.len, max_tool_result_bytes);
}

fn contextLimitFailure(alloc: Allocator, model_output: []u8) error{OutOfMemory}!ExecuteResult {
    errdefer alloc.free(model_output);
    return .{ .failure = .{
        .model_output = model_output,
        .notice = try alloc.dupe(u8, model_output),
    } };
}

fn formatSkillChunkBlocked(
    alloc: Allocator,
    skill_name: []const u8,
    resource: []const u8,
    observed_bytes: usize,
    limit: context_limits.Resolved,
    offset: usize,
) error{OutOfMemory}![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    out.writer.writeAll("<context_limit name=\"skill_chunk_bytes\" action=\"blocked\" skill=\"") catch return error.OutOfMemory;
    model_context_encoding.writeScalar(&out.writer, skill_name) catch return error.OutOfMemory;
    out.writer.writeAll("\" resource=\"") catch return error.OutOfMemory;
    model_context_encoding.writeScalar(&out.writer, resource) catch return error.OutOfMemory;
    out.writer.print(
        "\" observed_bytes=\"{d}\" effective_bytes=\"{d}\" source=\"{s}\" offset=\"{d}\" override=\"--context-limit skill_chunk_bytes=BYTES|off\" />",
        .{ observed_bytes, limit.effectiveBytes(), limit.source.label(), offset },
    ) catch return error.OutOfMemory;
    return out.toOwnedSlice() catch return error.OutOfMemory;
}

fn formatMissingSkill(alloc: Allocator, name: []const u8, max_bytes: usize) error{OutOfMemory}![]u8 {
    const prefix = "Skill \"";
    const suffix = "\" not found. Refresh available skills and retry with an advertised name.";
    const fallback = "Skill not found. Refresh available skills and retry with an advertised name.";
    return formatBoundedIdentityError(alloc, prefix, name, suffix, fallback, max_bytes);
}

fn formatBoundedIdentityError(
    alloc: Allocator,
    prefix: []const u8,
    value: []const u8,
    suffix: []const u8,
    fallback: []const u8,
    max_bytes: usize,
) error{OutOfMemory}![]u8 {
    const fixed_len = std.math.add(usize, prefix.len, suffix.len) catch return boundedSkillError(alloc, fallback, max_bytes);
    if (fixed_len +| 3 >= max_bytes) return boundedSkillError(alloc, fallback, max_bytes);

    var encoded: std.Io.Writer.Allocating = .init(alloc);
    defer encoded.deinit();
    model_context_encoding.writeScalar(&encoded.writer, value) catch return error.OutOfMemory;
    const ellipsis_len: usize = if (encoded.written().len > max_bytes - fixed_len) 3 else 0;
    const value_budget = max_bytes - fixed_len - ellipsis_len;
    const prefix_len = boundedEncodedPrefixLength(encoded.written(), value_budget);

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    out.writer.writeAll(prefix) catch return error.OutOfMemory;
    out.writer.writeAll(encoded.written()[0..prefix_len]) catch return error.OutOfMemory;
    if (prefix_len < encoded.written().len) out.writer.writeAll("...") catch return error.OutOfMemory;
    out.writer.writeAll(suffix) catch return error.OutOfMemory;
    return boundedSkillError(alloc, out.written(), max_bytes);
}

fn formatExactSkillNotFound(alloc: Allocator, name: []const u8, location: []const u8, max_bytes: usize) error{OutOfMemory}![]u8 {
    return formatBoundedIdentityPairError(
        alloc,
        "Skill \"",
        name,
        "\" was not found at advertised location \"",
        location,
        "\". Refresh available skills and retry with an advertised name and location.",
        "Skill was not found at the advertised location. Refresh available skills and retry with an advertised name and location.",
        max_bytes,
    );
}

fn formatSkillLocationMismatch(alloc: Allocator, name: []const u8, location: []const u8, max_bytes: usize) error{OutOfMemory}![]u8 {
    return formatBoundedIdentityPairError(
        alloc,
        "Skill \"",
        name,
        "\" does not match the skill advertised at location \"",
        location,
        "\". Refresh available skills and retry with the advertised name and location.",
        "Skill name and location do not match one advertised skill. Refresh available skills and retry with the advertised name and location.",
        max_bytes,
    );
}

fn formatBoundedIdentityPairError(
    alloc: Allocator,
    prefix: []const u8,
    first: []const u8,
    middle: []const u8,
    second: []const u8,
    suffix: []const u8,
    fallback: []const u8,
    max_bytes: usize,
) error{OutOfMemory}![]u8 {
    const fixed_len = std.math.add(usize, prefix.len, middle.len) catch return boundedSkillError(alloc, fallback, max_bytes);
    const complete_fixed_len = std.math.add(usize, fixed_len, suffix.len) catch return boundedSkillError(alloc, fallback, max_bytes);
    if (complete_fixed_len +| 6 >= max_bytes) return boundedSkillError(alloc, fallback, max_bytes);

    var encoded_first: std.Io.Writer.Allocating = .init(alloc);
    defer encoded_first.deinit();
    model_context_encoding.writeScalar(&encoded_first.writer, first) catch return error.OutOfMemory;
    var encoded_second: std.Io.Writer.Allocating = .init(alloc);
    defer encoded_second.deinit();
    model_context_encoding.writeScalar(&encoded_second.writer, second) catch return error.OutOfMemory;

    const available = max_bytes - complete_fixed_len - 6;
    const first_budget = @min(encoded_first.written().len, @min(available, skill_contract.max_name_bytes));
    const second_budget = available - first_budget;
    const first_len = boundedEncodedPrefixLength(encoded_first.written(), first_budget);
    const second_len = boundedEncodedPrefixLength(encoded_second.written(), second_budget);

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    out.writer.writeAll(prefix) catch return error.OutOfMemory;
    out.writer.writeAll(encoded_first.written()[0..first_len]) catch return error.OutOfMemory;
    if (first_len < encoded_first.written().len) out.writer.writeAll("...") catch return error.OutOfMemory;
    out.writer.writeAll(middle) catch return error.OutOfMemory;
    out.writer.writeAll(encoded_second.written()[0..second_len]) catch return error.OutOfMemory;
    if (second_len < encoded_second.written().len) out.writer.writeAll("...") catch return error.OutOfMemory;
    out.writer.writeAll(suffix) catch return error.OutOfMemory;
    return boundedSkillError(alloc, out.written(), max_bytes);
}

fn boundedEncodedPrefixLength(encoded: []const u8, max_bytes: usize) usize {
    var prefix_len = context_limits.utf8PrefixLength(encoded, max_bytes);
    if (std.mem.lastIndexOfScalar(u8, encoded[0..prefix_len], '&')) |amp_index| {
        if (std.mem.indexOfScalar(u8, encoded[amp_index..prefix_len], ';') == null) prefix_len = amp_index;
    }
    return prefix_len;
}

fn formatAmbiguousSkill(alloc: Allocator, skills: []const skill_runtime.Skill, name: []const u8, max_bytes: usize) error{OutOfMemory}![]u8 {
    var match_count: usize = 0;
    for (skills) |skill| {
        if (std.mem.eql(u8, skill.name, name)) match_count += 1;
    }

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    out.writer.writeAll("Skill \"") catch return error.OutOfMemory;
    model_context_encoding.writeScalar(&out.writer, name) catch return error.OutOfMemory;
    out.writer.writeAll("\" is ambiguous. Retry with the name and one advertised location: ") catch return error.OutOfMemory;

    var shown_count: usize = 0;
    for (skills) |skill| {
        if (!std.mem.eql(u8, skill.name, name)) continue;

        var choice: std.Io.Writer.Allocating = .init(alloc);
        defer choice.deinit();
        choice.writer.writeByte('"') catch return error.OutOfMemory;
        model_context_encoding.writeScalar(&choice.writer, skill.path) catch return error.OutOfMemory;
        choice.writer.writeByte('"') catch return error.OutOfMemory;

        const omitted_count = match_count - (shown_count + 1);
        const suffix_len = ambiguousSkillSuffixLen(omitted_count, max_bytes);
        const separator = if (shown_count > 0) ", " else "";
        const choice_with_suffix_len = std.math.add(usize, choice.written().len, suffix_len) catch std.math.maxInt(usize);
        const appended_len = std.math.add(usize, separator.len, choice_with_suffix_len) catch std.math.maxInt(usize);
        const prospective_len = std.math.add(usize, out.written().len, appended_len) catch std.math.maxInt(usize);
        if (prospective_len > max_bytes) break;

        out.writer.writeAll(separator) catch return error.OutOfMemory;
        out.writer.writeAll(choice.written()) catch return error.OutOfMemory;
        shown_count += 1;
    }

    if (shown_count == 0) {
        out.clearRetainingCapacity();
        out.writer.print(
            "Requested skill name is ambiguous; all {d} advertised locations were omitted by the {d}-byte tool-result limit. Refresh available skills and retry with an advertised name and location.",
            .{ match_count, max_bytes },
        ) catch return error.OutOfMemory;
    } else {
        try writeAmbiguousSkillSuffix(&out.writer, match_count - shown_count, max_bytes);
    }
    return boundedSkillError(alloc, out.written(), max_bytes);
}

fn ambiguousSkillSuffixLen(omitted_count: usize, max_bytes: usize) usize {
    if (omitted_count == 0) return 1;
    return std.fmt.count(ambiguous_skill_suffix_fmt, .{ omitted_count, if (omitted_count == 1) "" else "s", max_bytes });
}

fn writeAmbiguousSkillSuffix(writer: *std.Io.Writer, omitted_count: usize, max_bytes: usize) error{OutOfMemory}!void {
    if (omitted_count == 0) return writer.writeByte('.') catch error.OutOfMemory;
    writer.print(
        ambiguous_skill_suffix_fmt,
        .{ omitted_count, if (omitted_count == 1) "" else "s", max_bytes },
    ) catch return error.OutOfMemory;
}

fn boundedSkillError(alloc: Allocator, text: []const u8, max_bytes: usize) error{OutOfMemory}![]u8 {
    return @constCast(try tool_result_limits.prepareModelOutput(alloc, "skill", text, max_bytes));
}

/// Returns the owned model output and releases the result's optional notices.
/// The caller owns the returned slice.
pub fn takeModelOutput(alloc: Allocator, result: ExecuteResult) []u8 {
    return switch (result) {
        .loaded, .failure => |output| blk: {
            if (output.notice) |notice| alloc.free(@constCast(notice));
            if (output.diagnostic_notice) |notice| alloc.free(@constCast(notice));
            break :blk @constCast(output.model_output);
        },
    };
}

pub fn freeExecuteResult(alloc: Allocator, result: ExecuteResult) void {
    switch (result) {
        .loaded, .failure => |output| {
            alloc.free(@constCast(output.model_output));
            if (output.notice) |notice| alloc.free(@constCast(notice));
            if (output.diagnostic_notice) |notice| alloc.free(@constCast(notice));
        },
    }
}

fn loadVisibleSkillsForContext(alloc: Allocator, workspace_root: []const u8, skills_dir: []const u8) !skill_runtime.SkillDiscovery {
    if (io_mod.getenv("HOME") orelse homeFromSkillsDir(skills_dir)) |home| {
        return skill_runtime.loadVisibleSkills(alloc, workspace_root, home, skills_dir, test_root_policy);
    }
    return skill_runtime.loadVisibleSkills(alloc, workspace_root, null, skills_dir, test_root_policy);
}

fn homeFromSkillsDir(skills_dir: []const u8) ?[]const u8 {
    const suffix = "/.fx/skills";
    if (!std.mem.endsWith(u8, skills_dir, suffix)) return null;
    return skills_dir[0 .. skills_dir.len - suffix.len];
}

const SkillResourceRead = struct {
    bytes: []u8,
    observed_bytes: usize,
};

fn revalidatePrimaryIdentity(alloc: Allocator, file: *std.Io.File, skill: skill_runtime.Skill) !void {
    const before = try file.stat(io_mod.getIo());
    const length: usize = @intCast(@min(before.size, skill_contract.max_frontmatter_bytes + 1));
    const bytes = try alloc.alloc(u8, length);
    defer alloc.free(bytes);
    if (try file.readPositionalAll(io_mod.getIo(), bytes, 0) != length) return error.SkillResourceChanged;
    const after = try file.stat(io_mod.getIo());
    if (before.size != after.size or !std.meta.eql(before.mtime, after.mtime)) return error.SkillResourceChanged;
    const metadata = switch (skill_contract.resolveMetadata(skill_contract.parseSkillFile(bytes), std.fs.path.basename(skill.path))) {
        .valid => |value| value,
        .invalid => return error.SkillResourceChanged,
    };
    if (!std.mem.eql(u8, metadata.name, skill.name)) return error.SkillResourceChanged;
}

fn readSkillResource(
    alloc: Allocator,
    candidate: *skill_runtime.OpenedSkillCandidate,
    resource: []const u8,
    limit: context_limits.Resolved,
    cancel_flag: ?*std.atomic.Value(bool),
) !SkillResourceRead {
    return readSkillResourceWithCeiling(
        alloc,
        candidate,
        resource,
        limit,
        context_limits.emergency_ceiling_bytes,
        cancel_flag,
    );
}

fn readSkillResourceWithCeiling(
    alloc: Allocator,
    candidate: *skill_runtime.OpenedSkillCandidate,
    resource: []const u8,
    limit: context_limits.Resolved,
    safety_ceiling: usize,
    cancel_flag: ?*std.atomic.Value(bool),
) !SkillResourceRead {
    if (skill_runtime.resourceIsSkillFile(resource)) {
        return readSkillResourceFile(
            alloc,
            candidate.skillFile(),
            limit,
            safety_ceiling,
            cancel_flag,
        );
    }

    var file = try candidate.openResource(resource);
    defer file.close(io_mod.getIo());
    return readSkillResourceFile(alloc, &file, limit, safety_ceiling, cancel_flag);
}

fn readSkillResourceFile(
    alloc: Allocator,
    file: *std.Io.File,
    limit: context_limits.Resolved,
    safety_ceiling: usize,
    cancel_flag: ?*std.atomic.Value(bool),
) !SkillResourceRead {
    const stat = try file.stat(io_mod.getIo());
    if (stat.kind != .file) return error.InvalidSkillResource;
    const observed_bytes = std.math.cast(usize, stat.size) orelse return error.SkillFileLimitExceeded;
    const effective_limit = limit.effectiveBytes();
    try validateSkillResourceUtf8(file, @min(observed_bytes, safety_ceiling), observed_bytes, cancel_flag);

    const read_len = @min(observed_bytes, @min(effective_limit +| 3, safety_ceiling));
    const bytes = try alloc.alloc(u8, read_len);
    errdefer alloc.free(bytes);
    var bytes_read: usize = 0;
    while (bytes_read < bytes.len) {
        if (cancel_flag) |flag| if (flag.load(.seq_cst)) return error.Cancelled;
        const end = bytes_read + @min(bytes.len - bytes_read, 64 * 1024);
        const count = try file.readPositionalAll(io_mod.getIo(), bytes[bytes_read..end], bytes_read);
        if (count == 0) break;
        bytes_read += count;
    }
    const final_stat = try file.stat(io_mod.getIo());
    if (final_stat.size != stat.size or !std.meta.eql(final_stat.mtime, stat.mtime)) return error.SkillResourceChanged;
    if (bytes_read != read_len) return error.UnexpectedEndOfFile;
    const allowed_len = context_limits.lineSafePrefixLength(bytes, effective_limit);
    if (allowed_len != bytes.len) {
        return .{
            .bytes = try alloc.realloc(bytes, allowed_len),
            .observed_bytes = observed_bytes,
        };
    }
    return .{
        .bytes = bytes,
        .observed_bytes = observed_bytes,
    };
}

fn validateSkillResourceUtf8(file: *std.Io.File, byte_count: usize, observed_bytes: usize, cancel_flag: ?*std.atomic.Value(bool)) !void {
    var read_offset: usize = 0;
    var validator: text_utils.IncrementalUtf8Validator = .{};
    var chunk: [16 * 1024]u8 = undefined;

    while (read_offset < byte_count) {
        if (cancel_flag) |flag| if (flag.load(.seq_cst)) return error.Cancelled;
        const wanted = @min(chunk.len, byte_count - read_offset);
        const bytes_read = try file.readPositionalAll(io_mod.getIo(), chunk[0..wanted], read_offset);
        if (bytes_read != wanted) return error.UnexpectedEndOfFile;
        validator.append(chunk[0..bytes_read]) catch return error.BinarySkillResource;
        read_offset += bytes_read;
    }
    if (validator.pending_len > 0 and byte_count < observed_bytes) {
        const sequence_len = std.unicode.utf8ByteSequenceLength(validator.pending[0]) catch
            return error.BinarySkillResource;
        const lookahead_len = @min(sequence_len - validator.pending_len, observed_bytes - byte_count);
        var lookahead: [3]u8 = undefined;
        const bytes_read = try file.readPositionalAll(io_mod.getIo(), lookahead[0..lookahead_len], byte_count);
        if (bytes_read != lookahead_len) return error.UnexpectedEndOfFile;
        validator.append(lookahead[0..bytes_read]) catch return error.BinarySkillResource;
    }
    validator.finish() catch return error.BinarySkillResource;
}

fn formatSkillFileBlocked(
    alloc: Allocator,
    resource: []const u8,
    observed_bytes: usize,
    limit: context_limits.Resolved,
) error{OutOfMemory}![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try writeSkillFileBlockedMarker(&out.writer, resource, observed_bytes, limit);
    return out.toOwnedSlice() catch return error.OutOfMemory;
}

fn writeSkillFileBlockedMarker(
    writer: *std.Io.Writer,
    resource: []const u8,
    observed_bytes: usize,
    limit: context_limits.Resolved,
) error{OutOfMemory}!void {
    writer.writeAll("<context_limit name=\"skill_file_bytes\" action=\"blocked_remainder\" observed_bytes=\"") catch return error.OutOfMemory;
    writer.print("{d}\" effective_bytes=\"{d}\" source=\"{s}\" resource=\"", .{
        observed_bytes,
        limit.effectiveBytes(),
        limit.source.label(),
    }) catch return error.OutOfMemory;
    model_context_encoding.writeScalar(writer, resource) catch return error.OutOfMemory;
    writer.writeAll("\" override=\"--context-limit skill_file_bytes=BYTES|off\" />") catch return error.OutOfMemory;
}

fn formatSkillFileBlockedNotice(
    alloc: Allocator,
    skill_name: []const u8,
    resource: []const u8,
    observed_bytes: usize,
    limit: context_limits.Resolved,
) error{OutOfMemory}![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    out.writer.writeAll("[context] skill resource \"") catch return error.OutOfMemory;
    model_context_encoding.writeScalar(&out.writer, skill_name) catch return error.OutOfMemory;
    out.writer.writeByte('/') catch return error.OutOfMemory;
    model_context_encoding.writeScalar(&out.writer, resource) catch return error.OutOfMemory;
    out.writer.print(
        "\" remainder blocked: observed={d} bytes effective={d} bytes source={s}; override with --context-limit skill_file_bytes=BYTES|off",
        .{ observed_bytes, limit.effectiveBytes(), limit.source.label() },
    ) catch return error.OutOfMemory;
    return out.toOwnedSlice() catch return error.OutOfMemory;
}

fn formatSkillChunkNotice(
    alloc: Allocator,
    skill_name: []const u8,
    resource: []const u8,
    observed_bytes: usize,
    limit: context_limits.Resolved,
    next_offset: usize,
) error{OutOfMemory}![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    out.writer.writeAll("[context] skill resource \"") catch return error.OutOfMemory;
    model_context_encoding.writeScalar(&out.writer, skill_name) catch return error.OutOfMemory;
    out.writer.writeByte('/') catch return error.OutOfMemory;
    model_context_encoding.writeScalar(&out.writer, resource) catch return error.OutOfMemory;
    out.writer.print(
        "\" truncated: observed={d} bytes effective={d} bytes source={s}; continue with offset={d} or override with --context-limit skill_chunk_bytes=BYTES|off",
        .{ observed_bytes, limit.effectiveBytes(), limit.source.label(), next_offset },
    ) catch return error.OutOfMemory;
    return out.toOwnedSlice() catch return error.OutOfMemory;
}

test "skill limit notices encode untrusted names and resource paths" {
    const alloc = std.testing.allocator;
    const limit = context_limits.Resolved{ .value = .{ .bytes = 4 }, .source = .command_line };
    const chunk = try formatSkillChunkNotice(alloc, "bad\"\x1b", "asset\n.txt", 20, limit, 4);
    defer alloc.free(chunk);
    try expectContains(chunk, "bad&quot;&#x1b;/asset&#x0a;.txt");
    try expectNotContains(chunk, "\x1b");

    const blocked = try formatSkillFileBlockedNotice(alloc, "bad\"\x1b", "asset\n.txt", 20, limit);
    defer alloc.free(blocked);
    try expectContains(blocked, "bad&quot;&#x1b;/asset&#x0a;.txt");
    try expectNotContains(blocked, "\x1b");
}

test "skill results carry context notices without inspecting model output" {
    const ordinary = ExecuteResult{ .failure = .{ .model_output = "<context_limit is literal failure text>" } };
    try std.testing.expect(ordinary.contextNotice() == null);
    try std.testing.expect(ordinary.diagnosticNotice() == null);

    const limited = ExecuteResult{ .failure = .{
        .model_output = "model marker",
        .notice = "user notice",
    } };
    try std.testing.expectEqualStrings("user notice", limited.contextNotice().?);

    const diagnosed = ExecuteResult{ .failure = .{
        .model_output = "model marker",
        .diagnostic_notice = "diagnostic notice",
    } };
    try std.testing.expectEqualStrings("diagnostic notice", diagnosed.diagnosticNotice().?);
}

fn openTestSkillCandidate(
    alloc: Allocator,
    root: []const u8,
) !skill_runtime.OpenedSkillCandidate {
    const name = std.fs.path.basename(root);
    return switch (try skill_runtime.openValidatedSkillCandidate(alloc, .{
        .name = name,
        .description = "",
        .path = root,
        .source = .workspace_shared,
    })) {
        .current => |candidate| candidate,
        .missing, .name_mismatch, .skipped => error.InvalidTestSkillCandidate,
    };
}

fn expectSkillResourceRejected(alloc: Allocator, root: []const u8, resource: []const u8) !void {
    var candidate = openTestSkillCandidate(alloc, root) catch return;
    defer candidate.deinit();
    const loaded = readSkillResource(alloc, &candidate, resource, (context_limits.Values{}).skill_file_bytes, null) catch return;
    defer alloc.free(loaded.bytes);
    return error.TestUnexpectedResult;
}

test "skill resource validation completes UTF-8 across the safety ceiling" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "skills/workflow/assets");
    {
        var file = try tmp.dir.createFile(io_mod.getIo(), "skills/workflow/SKILL.md", .{});
        defer file.close(io_mod.getIo());
        try file.writeStreamingAll(io_mod.getIo(), "---\nname: workflow\n---\n\nworkflow\n");
    }
    {
        var file = try tmp.dir.createFile(io_mod.getIo(), "skills/workflow/assets/valid.txt", .{});
        defer file.close(io_mod.getIo());
        try file.writeStreamingAll(io_mod.getIo(), "one\n€\ntail\n");
    }
    {
        var file = try tmp.dir.createFile(io_mod.getIo(), "skills/workflow/assets/invalid.txt", .{});
        defer file.close(io_mod.getIo());
        try file.writeStreamingAll(io_mod.getIo(), &.{ 'o', 'n', 'e', '\n', 0xe2, 'x', '\n' });
    }

    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "skills/workflow");
    defer alloc.free(root);
    var candidate = try openTestSkillCandidate(alloc, root);
    defer candidate.deinit();
    const limit = context_limits.Resolved{ .value = .{ .bytes = 5 }, .source = .command_line };
    const loaded = try readSkillResourceWithCeiling(alloc, &candidate, "assets/valid.txt", limit, 5, null);
    defer alloc.free(loaded.bytes);
    try std.testing.expectEqualStrings("one\n", loaded.bytes);
    try std.testing.expectEqual(@as(usize, "one\n€\ntail\n".len), loaded.observed_bytes);

    const marker = try formatSkillFileBlocked(alloc, "assets/valid.txt", loaded.observed_bytes, limit);
    defer alloc.free(marker);
    try expectContains(marker, "name=\"skill_file_bytes\" action=\"blocked_remainder\"");
    try expectContains(marker, "effective_bytes=\"5\"");

    try std.testing.expectError(
        error.BinarySkillResource,
        readSkillResourceWithCeiling(alloc, &candidate, "assets/invalid.txt", limit, 5, null),
    );
}

fn createSkillSymlinkOrSkip(
    dir: std.Io.Dir,
    target_path: []const u8,
    link_path: []const u8,
    is_directory: bool,
) !void {
    if (comptime @import("builtin").os.tag == .windows) return error.SkipZigTest;
    dir.symLink(std.testing.io, target_path, link_path, .{ .is_directory = is_directory }) catch |err| {
        if (err == error.AccessDenied or std.mem.eql(u8, @errorName(err), "Permission" ++ "Denied")) {
            return error.SkipZigTest;
        }
        return err;
    };
}

test "skill resource loading rejects symlink components and candidate rebinding" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "root/workflow/real-assets");
    try tmp.dir.createDirPath(io_mod.getIo(), "outside");
    try tmp.dir.createDirPath(io_mod.getIo(), "outside-root/skills/workflow");
    try tmp.dir.createDirPath(io_mod.getIo(), "ancestor-root");
    {
        var file = try tmp.dir.createFile(io_mod.getIo(), "root/workflow/SKILL.md", .{});
        defer file.close(io_mod.getIo());
        try file.writeStreamingAll(io_mod.getIo(), "---\nname: workflow\n---\n\nworkflow\n");
    }
    {
        var file = try tmp.dir.createFile(io_mod.getIo(), "root/workflow/real-assets/data.txt", .{});
        defer file.close(io_mod.getIo());
        try file.writeStreamingAll(io_mod.getIo(), "INTERNAL_SYMLINK_SENTINEL");
    }
    {
        var file = try tmp.dir.createFile(io_mod.getIo(), "root/workflow/real.txt", .{});
        defer file.close(io_mod.getIo());
        try file.writeStreamingAll(io_mod.getIo(), "FINAL_SYMLINK_SENTINEL");
    }
    {
        var file = try tmp.dir.createFile(io_mod.getIo(), "outside/SKILL.md", .{});
        defer file.close(io_mod.getIo());
        try file.writeStreamingAll(io_mod.getIo(), "OUTSIDE_SWAP_SENTINEL");
    }
    {
        var file = try tmp.dir.createFile(io_mod.getIo(), "outside-root/skills/workflow/SKILL.md", .{});
        defer file.close(io_mod.getIo());
        try file.writeStreamingAll(io_mod.getIo(), "ANCESTOR_SYMLINK_SENTINEL");
    }
    try createSkillSymlinkOrSkip(tmp.dir, "real-assets", "root/workflow/assets", true);
    try createSkillSymlinkOrSkip(tmp.dir, "real.txt", "root/workflow/alias.txt", false);
    try createSkillSymlinkOrSkip(tmp.dir, "../outside-root", "ancestor-root/.agents", true);

    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "root/workflow");
    defer alloc.free(root);
    try expectSkillResourceRejected(alloc, root, "assets/data.txt");
    try expectSkillResourceRejected(alloc, root, "alias.txt");

    const tmp_root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(tmp_root);
    const ancestor_root = try std.fs.path.join(alloc, &.{ tmp_root, "ancestor-root/.agents/skills/workflow" });
    defer alloc.free(ancestor_root);
    try expectSkillResourceRejected(alloc, ancestor_root, "SKILL.md");

    try tmp.dir.rename("root/workflow", tmp.dir, "root/original-workflow", io_mod.getIo());
    try createSkillSymlinkOrSkip(tmp.dir, "../outside", "root/workflow", true);
    try expectSkillResourceRejected(alloc, root, "SKILL.md");
}

fn checkSkillErrorFormattingAllocationFailures(alloc: Allocator) !void {
    const missing = try formatMissingSkill(alloc, "workflow", tool_result_limits.default_max_tool_result_bytes);
    alloc.free(missing);
    const exact = try formatExactSkillNotFound(alloc, "workflow", "/tmp/skills/workflow", tool_result_limits.default_max_tool_result_bytes);
    alloc.free(exact);
    const mismatch = try formatSkillLocationMismatch(alloc, "workflow", "/tmp/skills/workflow", tool_result_limits.default_max_tool_result_bytes);
    alloc.free(mismatch);

    const duplicates = [_]skill_runtime.Skill{
        .{ .name = "workflow", .description = "A", .path = "/tmp/a/workflow", .source = .workspace_shared },
        .{ .name = "workflow", .description = "B", .path = "/tmp/b/workflow", .source = .global_fx },
    };
    const ambiguous = try formatAmbiguousSkill(alloc, &duplicates, "workflow", tool_result_limits.default_max_tool_result_bytes);
    alloc.free(ambiguous);
}

fn checkSkillLoadAllocationFailures(
    alloc: Allocator,
    workspace_root: []const u8,
    skills_dir: []const u8,
) !void {
    var discovery = try loadVisibleSkillsForContext(alloc, workspace_root, skills_dir);
    defer discovery.deinit(alloc);
    const result = try loadByIdentity(
        alloc,
        .{ .skills = discovery.skills, .diagnostics = discovery.diagnostics },
        "workflow",
        null,
        null,
        0,
        .{},
        tool_result_limits.default_max_tool_result_bytes,
    );
    freeExecuteResult(alloc, result);
}

fn checkExplicitPromptSectionAllocationFailures(
    alloc: Allocator,
    workspace_root: []const u8,
    skills_dir: []const u8,
    limits: context_limits.Values,
) !void {
    var discovery = try loadVisibleSkillsForContext(alloc, workspace_root, skills_dir);
    defer discovery.deinit(alloc);
    var section = try buildExplicitPromptSection(alloc, .{ .skills = discovery.skills, .diagnostics = discovery.diagnostics }, "$workflow", &.{}, limits, null);
    defer section.deinit(alloc);
    try std.testing.expect(section.notice != null);
    try std.testing.expect(section.diagnostic_notice != null);
}

fn setTestHome(home: ?[]const u8) !void {
    const map = try std.heap.c_allocator.create(std.process.Environ.Map);
    map.* = std.process.Environ.Map.init(std.heap.c_allocator);
    if (home) |value| try map.put("HOME", value);
    io_mod.setEnvironMap(map);
}

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.find(u8, haystack, needle) != null);
}

fn expectNotContains(haystack: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.find(u8, haystack, needle) == null);
}

test "skill invocation preserves hard allocation failures" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkSkillErrorFormattingAllocationFailures,
        .{},
    );

    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home/workspace");
    try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx/skills/workflow");
    {
        var file = try tmp.dir.createFile(io_mod.getIo(), "home/.fx/skills/workflow/SKILL.md", .{});
        defer file.close(io_mod.getIo());
        try file.writeStreamingAll(io_mod.getIo(), "---\nname: workflow\ndescription: workflow helper\n---\n\nuse the workflow skill\n");
    }

    const workspace_root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home/workspace");
    defer alloc.free(workspace_root);
    const skills_dir = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home/.fx/skills");
    defer alloc.free(skills_dir);
    try setTestHome(null);
    defer setTestHome(null) catch {};

    try std.testing.checkAllAllocationFailures(
        alloc,
        checkSkillLoadAllocationFailures,
        .{ workspace_root, skills_dir },
    );
}

test "skill invocation loads installed skill content" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io_mod.getIo(), "home/workspace");
    try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx/skills/workflow/assets");
    {
        var file = try tmp.dir.createFile(io_mod.getIo(), "home/.fx/skills/workflow/SKILL.md", .{});
        defer file.close(io_mod.getIo());
        try file.writeStreamingAll(io_mod.getIo(), "---\nname: workflow\ndescription: workflow helper\n---\n\nuse the workflow skill\n");
    }
    {
        var file = try tmp.dir.createFile(io_mod.getIo(), "home/.fx/skills/workflow/assets/data.txt", .{});
        defer file.close(io_mod.getIo());
        try file.writeStreamingAll(io_mod.getIo(), "hello\n");
    }

    const workspace_root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home/workspace");
    defer alloc.free(workspace_root);
    const skills_dir = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home/.fx/skills");
    defer alloc.free(skills_dir);
    try setTestHome(null);
    defer setTestHome(null) catch {};

    var discovery = try loadVisibleSkillsForContext(alloc, workspace_root, skills_dir);
    defer discovery.deinit(alloc);
    const result = try loadByIdentity(
        alloc,
        .{ .skills = discovery.skills, .diagnostics = discovery.diagnostics },
        "workflow",
        null,
        null,
        0,
        .{},
        tool_result_limits.default_max_tool_result_bytes,
    );
    defer freeExecuteResult(alloc, result);
    const output = result.modelOutput();

    try expectContains(output, "<skill_content name=\"workflow\" resource=\"SKILL.md\" offset=\"0\"");
    try expectContains(output, "use the workflow skill");
    try expectNotContains(output, "assets/data.txt");
}

test "stale skill catalogs reject mutated candidates before loading" {
    const alloc = std.testing.allocator;
    inline for (.{ "deleted", "invalid", "renamed" }) |mutation| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.createDirPath(io_mod.getIo(), "home/workspace");
        try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx/skills/workflow");
        {
            var file = try tmp.dir.createFile(io_mod.getIo(), "home/.fx/skills/workflow/SKILL.md", .{});
            defer file.close(io_mod.getIo());
            try file.writeStreamingAll(
                io_mod.getIo(),
                "---\nname: workflow\ndescription: helper\n---\n\nORIGINAL BODY\n",
            );
        }

        const workspace_root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home/workspace");
        defer alloc.free(workspace_root);
        const skills_dir = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home/.fx/skills");
        defer alloc.free(skills_dir);
        try setTestHome(null);
        defer setTestHome(null) catch {};

        var discovery = try loadVisibleSkillsForContext(alloc, workspace_root, skills_dir);
        defer discovery.deinit(alloc);
        try std.testing.expectEqual(@as(usize, 1), discovery.skills.len);
        const catalog = Catalog{ .skills = discovery.skills, .diagnostics = discovery.diagnostics };

        if (std.mem.eql(u8, mutation, "deleted")) {
            try tmp.dir.deleteFile(io_mod.getIo(), "home/.fx/skills/workflow/SKILL.md");
        } else {
            var file = try tmp.dir.createFile(
                io_mod.getIo(),
                "home/.fx/skills/workflow/SKILL.md",
                .{ .truncate = true },
            );
            defer file.close(io_mod.getIo());
            const replacement = if (std.mem.eql(u8, mutation, "invalid"))
                "---\ndescription: missing name\n---\n\nINVALID BODY\n"
            else
                "---\nname: renamed\ndescription: renamed helper\n---\n\nRENAMED BODY\n";
            try file.writeStreamingAll(io_mod.getIo(), replacement);
        }

        const result = try loadByIdentity(
            alloc,
            catalog,
            "workflow",
            discovery.skills[0].path,
            null,
            0,
            .{},
            tool_result_limits.default_max_tool_result_bytes,
        );
        defer freeExecuteResult(alloc, result);

        switch (result) {
            .failure => |output| {
                if (std.mem.eql(u8, mutation, "renamed")) {
                    try expectContains(output.model_output, "does not match the skill advertised at location");
                } else {
                    try expectContains(output.model_output, "was not found at advertised location");
                }
                if (std.mem.eql(u8, mutation, "invalid")) {
                    try expectContains(output.diagnostic_notice.?, "metadata is invalid (missing_name)");
                }
                try expectNotContains(output.model_output, "ORIGINAL BODY");
                try expectNotContains(output.model_output, "INVALID BODY");
                try expectNotContains(output.model_output, "RENAMED BODY");
            },
            .loaded => return error.TestExpectedSkillFailure,
        }
    }
}

const CandidatePathReplacementHook = struct {
    dir: *std.Io.Dir,

    fn check(raw: *anyopaque) !void {
        const self: *CandidatePathReplacementHook = @ptrCast(@alignCast(raw));
        try self.dir.rename(
            "home/.fx/skills/workflow",
            self.dir.*,
            "home/.fx/skills/workflow-original",
            io_mod.getIo(),
        );
        try self.dir.rename(
            "home/replacement/workflow",
            self.dir.*,
            "home/.fx/skills/workflow",
            io_mod.getIo(),
        );
    }
};

test "skill invocation reads validated candidate resources after path replacement" {
    const alloc = std.testing.allocator;
    inline for (.{
        .{ "SKILL.md", "ORIGINAL SKILL BODY", "REPLACEMENT SKILL BODY" },
        .{ "assets/data.txt", "ORIGINAL ASSET BODY", "REPLACEMENT ASSET BODY" },
    }) |fixture| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.createDirPath(io_mod.getIo(), "home/workspace");
        try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx/skills/workflow/assets");
        try tmp.dir.createDirPath(io_mod.getIo(), "home/replacement/workflow/assets");
        {
            var file = try tmp.dir.createFile(io_mod.getIo(), "home/.fx/skills/workflow/SKILL.md", .{});
            defer file.close(io_mod.getIo());
            try file.writeStreamingAll(
                io_mod.getIo(),
                "---\nname: workflow\ndescription: original helper\n---\n\nORIGINAL SKILL BODY\n",
            );
        }
        {
            var file = try tmp.dir.createFile(io_mod.getIo(), "home/.fx/skills/workflow/assets/data.txt", .{});
            defer file.close(io_mod.getIo());
            try file.writeStreamingAll(io_mod.getIo(), "ORIGINAL ASSET BODY\n");
        }
        {
            var file = try tmp.dir.createFile(io_mod.getIo(), "home/replacement/workflow/SKILL.md", .{});
            defer file.close(io_mod.getIo());
            try file.writeStreamingAll(
                io_mod.getIo(),
                "---\nname: workflow\ndescription: replacement helper\n---\n\nREPLACEMENT SKILL BODY\n",
            );
        }
        {
            var file = try tmp.dir.createFile(io_mod.getIo(), "home/replacement/workflow/assets/data.txt", .{});
            defer file.close(io_mod.getIo());
            try file.writeStreamingAll(io_mod.getIo(), "REPLACEMENT ASSET BODY\n");
        }

        const workspace_root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home/workspace");
        defer alloc.free(workspace_root);
        const skills_dir = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home/.fx/skills");
        defer alloc.free(skills_dir);
        try setTestHome(null);
        defer setTestHome(null) catch {};

        var discovery = try loadVisibleSkillsForContext(alloc, workspace_root, skills_dir);
        defer discovery.deinit(alloc);
        try std.testing.expectEqual(@as(usize, 1), discovery.skills.len);
        var hook = CandidatePathReplacementHook{ .dir = &tmp.dir };
        const result = try loadByIdentityWithOptions(
            alloc,
            .{ .skills = discovery.skills, .diagnostics = discovery.diagnostics },
            "workflow",
            discovery.skills[0].path,
            fixture[0],
            0,
            .{},
            tool_result_limits.default_max_tool_result_bytes,
            .{ .test_after_candidate_validation = .{
                .ctx = &hook,
                .check = CandidatePathReplacementHook.check,
            } },
        );
        defer freeExecuteResult(alloc, result);

        switch (result) {
            .loaded => |output| {
                try expectContains(output.model_output, fixture[1]);
                try expectNotContains(output.model_output, fixture[2]);
            },
            .failure => return error.TestExpectedLoadedSkill,
        }
    }
}

test "large skills stay discoverable and explicit overrides can continue past default file bounds" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home/workspace");
    try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx/skills/large");

    const body = try alloc.alloc(u8, 1024 * 1024 + 128);
    defer alloc.free(body);
    @memset(body, 'x');
    const header = "---\nname: large\ndescription: large but discoverable\n---\n\n";
    const tail = "LARGE_SKILL_TAIL_SENTINEL\n";
    @memcpy(body[0..header.len], header);
    @memcpy(body[body.len - tail.len ..], tail);
    {
        var file = try tmp.dir.createFile(io_mod.getIo(), "home/.fx/skills/large/SKILL.md", .{});
        defer file.close(io_mod.getIo());
        try file.writeStreamingAll(io_mod.getIo(), body);
    }

    const workspace_root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home/workspace");
    defer alloc.free(workspace_root);
    const skills_dir = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home/.fx/skills");
    defer alloc.free(skills_dir);
    try setTestHome(null);
    defer setTestHome(null) catch {};

    var discovery = try loadVisibleSkillsForContext(alloc, workspace_root, skills_dir);
    defer discovery.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), discovery.skills.len);
    try std.testing.expectEqualStrings("large", discovery.skills[0].name);
    const catalog = Catalog{ .skills = discovery.skills, .diagnostics = discovery.diagnostics };

    const bounded = try loadByIdentity(alloc, catalog, "large", null, null, 0, .{}, tool_result_limits.default_max_tool_result_bytes);
    defer freeExecuteResult(alloc, bounded);
    try expectContains(bounded.modelOutput(), "name=\"skill_file_bytes\" action=\"blocked_remainder\"");
    try expectNotContains(bounded.modelOutput(), tail);

    var limits = context_limits.Values{};
    limits.skill_file_bytes = .{ .value = .off, .source = .command_line };
    limits.skill_chunk_bytes = .{ .value = .off, .source = .command_line };
    const unbounded = try loadByIdentity(alloc, catalog, "large", null, null, 0, limits, tool_result_limits.default_max_tool_result_bytes);
    defer freeExecuteResult(alloc, unbounded);
    try expectContains(unbounded.modelOutput(), tail);
}

test "explicit invocation reports user byte ceilings without partial success" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home/workspace");
    try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx/skills/workflow");
    {
        var file = try tmp.dir.createFile(io_mod.getIo(), "home/.fx/skills/workflow/SKILL.md", .{});
        defer file.close(io_mod.getIo());
        try file.writeStreamingAll(
            io_mod.getIo(),
            "---\nname: workflow\ndescription: helper\n---\n\nFIRST INSTRUCTIONS\nSECOND INSTRUCTIONS\nTAIL MUST WAIT\n",
        );
    }

    const workspace_root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home/workspace");
    defer alloc.free(workspace_root);
    const skills_dir = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home/.fx/skills");
    defer alloc.free(skills_dir);
    try setTestHome(null);
    defer setTestHome(null) catch {};
    var discovery = try loadVisibleSkillsForContext(alloc, workspace_root, skills_dir);
    defer discovery.deinit(alloc);
    const catalog = Catalog{ .skills = discovery.skills, .diagnostics = discovery.diagnostics };

    var limits = context_limits.Values{};
    limits.skill_chunk_bytes = .{ .value = .{ .bytes = 64 }, .source = .command_line };
    var explicit = try buildExplicitPromptSection(alloc, catalog, "$workflow apply these instructions", &.{}, limits, null);
    defer explicit.deinit(alloc);

    try expectNotContains(explicit.text, "already loaded");
    try expectContains(explicit.text, "Follow each skill's complete instructions and required resources before substantive work.");
    try expectContains(explicit.text, "If a skill cannot be followed, state the blocker instead of silently substituting another workflow.");
    try expectNotContains(explicit.text, "<skill_content");
    try expectContains(explicit.text, "name=\"skill_chunk_bytes\" action=\"blocked\"");
    try expectNotContains(explicit.text, "TAIL MUST WAIT");
    try std.testing.expect(explicit.notice != null);
    try expectContains(explicit.load_notice.?.body, "0 loaded · 1 failed");
    try expectContains(explicit.load_notice.?.body, "Could not load workflow");
    try expectContains(explicit.load_details.?, "skill_chunk_bytes");
    try expectNotContains(explicit.load_notice.?.body, "Loaded skill workflow");

    var fuzzy = try buildExplicitPromptSection(alloc, catalog, "please improve this workflow", &.{}, limits, null);
    defer fuzzy.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), fuzzy.text.len);
    try std.testing.expect(fuzzy.load_notice == null);

    limits.skill_chunk_bytes = .{ .value = .{ .bytes = 0 }, .source = .command_line };
    var zero_chunk = try buildExplicitPromptSection(alloc, catalog, "$workflow", &.{}, limits, null);
    defer zero_chunk.deinit(alloc);
    try expectContains(zero_chunk.text, "name=\"skill_chunk_bytes\" action=\"blocked\"");
    try std.testing.expect(zero_chunk.notice != null);

    limits.skill_chunk_bytes = (context_limits.Values{}).skill_chunk_bytes;
    limits.skill_file_bytes = .{ .value = .{ .bytes = 0 }, .source = .command_line };
    var zero_file = try buildExplicitPromptSection(alloc, catalog, "$workflow", &.{}, limits, null);
    defer zero_file.deinit(alloc);
    try expectContains(zero_file.text, "name=\"skill_file_bytes\" action=\"blocked_remainder\"");
    try std.testing.expect(zero_file.notice != null);
}

test "explicit binding plan preserves supplied order and adds prompt matches once" {
    const alloc = std.testing.allocator;
    const skills = [_]skill_runtime.Skill{
        .{ .name = "review", .description = "Review changes", .path = "/skills/review", .source = .workspace_shared },
        .{ .name = "release", .description = "Prepare a release", .path = "/skills/release", .source = .global_fx },
    };
    const bindings = [_]ExplicitBinding{
        .{ .name = "release", .path = "/skills/release" },
        .{ .name = "release duplicate", .path = "/skills/release" },
    };

    const plan = try buildExplicitBindingPlan(alloc, &skills, "$review these changes", &bindings);
    defer alloc.free(plan);

    try std.testing.expectEqual(@as(usize, 2), plan.len);
    try std.testing.expect(plan[0] == .bound and plan[1] == .bound);
    try std.testing.expectEqualStrings("release", plan[0].bound.name);
    try std.testing.expectEqualStrings("/skills/release", plan[0].bound.path);
    try std.testing.expectEqualStrings("review", plan[1].bound.name);
    try std.testing.expectEqualStrings("/skills/review", plan[1].bound.path);
}

test "explicit invocation preserves configured skill content when discovery is incomplete" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home/workspace");
    try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx/skills/large");
    try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx/skills/malformed");

    const body = try alloc.alloc(u8, 80 * 1024);
    defer alloc.free(body);
    @memset(body, 'x');
    const header = "---\nname: large\ndescription: large explicit skill\n---\n\n";
    const tail = "EXPLICIT_SKILL_TAIL_SENTINEL\n";
    @memcpy(body[0..header.len], header);
    @memcpy(body[body.len - tail.len ..], tail);
    {
        var file = try tmp.dir.createFile(io_mod.getIo(), "home/.fx/skills/large/SKILL.md", .{});
        defer file.close(io_mod.getIo());
        try file.writeStreamingAll(io_mod.getIo(), body);
    }
    {
        var file = try tmp.dir.createFile(io_mod.getIo(), "home/.fx/skills/malformed/SKILL.md", .{});
        defer file.close(io_mod.getIo());
        try file.writeStreamingAll(io_mod.getIo(), "---\ndescription: missing name\n---\nMALFORMED BODY");
    }

    const workspace_root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home/workspace");
    defer alloc.free(workspace_root);
    const skills_dir = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home/.fx/skills");
    defer alloc.free(skills_dir);
    try setTestHome(null);
    defer setTestHome(null) catch {};

    var discovery = try loadVisibleSkillsForContext(alloc, workspace_root, skills_dir);
    defer discovery.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), discovery.skills.len);
    try std.testing.expectEqual(@as(usize, 1), discovery.diagnostics.len);
    const catalog = Catalog{ .skills = discovery.skills, .diagnostics = discovery.diagnostics };

    var limits = context_limits.Values{};
    limits.skill_file_bytes = .{ .value = .off, .source = .command_line };
    limits.skill_chunk_bytes = .{ .value = .off, .source = .command_line };
    var explicit = try buildExplicitPromptSection(alloc, catalog, "$large", &.{}, limits, null);
    defer explicit.deinit(alloc);

    try expectContains(explicit.text, "skill_discovery_warning");
    try expectContains(explicit.text, tail);
    try expectContains(explicit.text, "</skill_content>");
    try expectNotContains(explicit.text, "tool result truncated");
    try std.testing.expect(explicit.notice == null);
    try std.testing.expect(explicit.diagnostic_notice != null);

    limits.skill_chunk_bytes = .{ .value = .{ .bytes = 64 }, .source = .command_line };
    var limited = try buildExplicitPromptSection(alloc, catalog, "$large", &.{}, limits, null);
    defer limited.deinit(alloc);

    const limit_notice = limited.notice orelse return error.TestExpectedEqual;
    const diagnostic_notice = limited.diagnostic_notice orelse return error.TestExpectedEqual;
    try expectContains(limit_notice, "skill_chunk_bytes");
    try expectNotContains(limit_notice, "skill discovery warning:");
    try expectContains(diagnostic_notice, "skill discovery warning:");
    try expectNotContains(diagnostic_notice, "skill_chunk_bytes");
}

test "explicit prompt section cleans up every allocation failure with both notices" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home/workspace");
    try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx/skills/workflow");
    try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx/skills/malformed");
    {
        var file = try tmp.dir.createFile(io_mod.getIo(), "home/.fx/skills/workflow/SKILL.md", .{});
        defer file.close(io_mod.getIo());
        try file.writeStreamingAll(
            io_mod.getIo(),
            "---\nname: workflow\ndescription: helper\n---\n\n" ++ ("workflow instructions\n" ** 16),
        );
    }
    {
        var file = try tmp.dir.createFile(io_mod.getIo(), "home/.fx/skills/malformed/SKILL.md", .{});
        defer file.close(io_mod.getIo());
        try file.writeStreamingAll(io_mod.getIo(), "---\ndescription: missing name\n---\nMALFORMED BODY");
    }

    const workspace_root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home/workspace");
    defer alloc.free(workspace_root);
    const skills_dir = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home/.fx/skills");
    defer alloc.free(skills_dir);
    try setTestHome(null);
    defer setTestHome(null) catch {};

    var limits = context_limits.Values{};
    limits.skill_chunk_bytes = .{ .value = .{ .bytes = 64 }, .source = .command_line };
    var probe = std.testing.FailingAllocator.init(alloc, .{ .resize_fail_index = 0 });
    try checkExplicitPromptSectionAllocationFailures(
        probe.allocator(),
        workspace_root,
        skills_dir,
        limits,
    );
    try std.testing.expectEqual(probe.allocated_bytes, probe.freed_bytes);

    for (0..probe.alloc_index) |fail_index| {
        var failing = std.testing.FailingAllocator.init(alloc, .{
            .fail_index = fail_index,
            .resize_fail_index = 0,
        });
        if (checkExplicitPromptSectionAllocationFailures(
            failing.allocator(),
            workspace_root,
            skills_dir,
            limits,
        )) |_| {
            if (failing.has_induced_failure) return error.SwallowedOutOfMemoryError;
        } else |err| switch (err) {
            error.OutOfMemory, error.WriteFailed => {},
            else => return err,
        }
        try std.testing.expect(failing.has_induced_failure);
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    }
}

test "skill resources continue on line-safe UTF-8 boundaries and reject unsafe inputs" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home/workspace");
    try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx/skills/workflow/assets");
    {
        var file = try tmp.dir.createFile(io_mod.getIo(), "home/.fx/skills/workflow/SKILL.md", .{});
        defer file.close(io_mod.getIo());
        try file.writeStreamingAll(io_mod.getIo(), "---\nname: workflow\ndescription: helper\n---\n\nbody\n");
    }
    {
        var file = try tmp.dir.createFile(io_mod.getIo(), "home/.fx/skills/workflow/assets/data.txt", .{});
        defer file.close(io_mod.getIo());
        try file.writeStreamingAll(io_mod.getIo(), "one\n二\nthree\n");
    }
    {
        var file = try tmp.dir.createFile(io_mod.getIo(), "home/.fx/skills/workflow/assets/binary.bin", .{});
        defer file.close(io_mod.getIo());
        try file.writeStreamingAll(io_mod.getIo(), &.{ 0xff, 0xfe });
    }
    inline for (.{
        .{ "invalid-before-limit.bin", &[_]u8{ 'a', 'b', 'c', 0xff, 'z' } },
        .{ "invalid-at-limit.bin", &[_]u8{ 'a', 'b', 'c', 'd', 0xff } },
        .{ "invalid-after-limit.bin", &[_]u8{ 'a', 'b', 'c', 'd', 'e', 0xff } },
    }) |fixture| {
        var file = try tmp.dir.createFile(io_mod.getIo(), "home/.fx/skills/workflow/assets/" ++ fixture[0], .{});
        defer file.close(io_mod.getIo());
        try file.writeStreamingAll(io_mod.getIo(), fixture[1]);
    }
    {
        var file = try tmp.dir.createFile(io_mod.getIo(), "home/.fx/skills/workflow/assets/cross-chunk.txt", .{});
        defer file.close(io_mod.getIo());
        const prefix = "a" ** (16 * 1024 - 1);
        try file.writeStreamingAll(io_mod.getIo(), prefix ++ "€\n");
    }

    const workspace_root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home/workspace");
    defer alloc.free(workspace_root);
    const skills_dir = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home/.fx/skills");
    defer alloc.free(skills_dir);
    try setTestHome(null);
    defer setTestHome(null) catch {};
    var discovery = try loadVisibleSkillsForContext(alloc, workspace_root, skills_dir);
    defer discovery.deinit(alloc);
    const catalog = Catalog{ .skills = discovery.skills, .diagnostics = discovery.diagnostics };

    var limits = context_limits.Values{};
    limits.skill_chunk_bytes = .{ .value = .{ .bytes = 7 }, .source = .command_line };
    limits.skill_file_bytes = .{ .value = .{ .bytes = 100 }, .source = .command_line };
    const first = try loadByIdentity(alloc, catalog, "workflow", null, "assets/data.txt", 0, limits, tool_result_limits.default_max_tool_result_bytes);
    defer freeExecuteResult(alloc, first);
    const first_output = first.modelOutput();
    try expectContains(first_output, "resource=\"assets/data.txt\" offset=\"0\" next_offset=\"4\"");
    try expectContains(first_output, "one\n");
    try expectContains(first_output, "name=\"skill_chunk_bytes\" action=\"truncated\"");

    const second = try loadByIdentity(alloc, catalog, "workflow", null, "assets/data.txt", 4, limits, tool_result_limits.default_max_tool_result_bytes);
    defer freeExecuteResult(alloc, second);
    try expectContains(second.modelOutput(), "offset=\"4\" next_offset=\"8\"");
    try expectContains(second.modelOutput(), "二\n");

    try std.testing.expectError(
        error.InvalidSkillResourcePath,
        loadByIdentity(alloc, catalog, "workflow", null, "../outside.txt", 0, limits, tool_result_limits.default_max_tool_result_bytes),
    );
    try std.testing.expectError(
        error.BinarySkillResource,
        loadByIdentity(alloc, catalog, "workflow", null, "assets/binary.bin", 0, limits, tool_result_limits.default_max_tool_result_bytes),
    );

    limits.skill_file_bytes = .{ .value = .{ .bytes = 4 }, .source = .user_workspace };
    inline for (.{ "assets/invalid-before-limit.bin", "assets/invalid-at-limit.bin", "assets/invalid-after-limit.bin" }) |resource| {
        try std.testing.expectError(
            error.BinarySkillResource,
            loadByIdentity(alloc, catalog, "workflow", null, resource, 0, limits, tool_result_limits.default_max_tool_result_bytes),
        );
    }
    const capped = try loadByIdentity(alloc, catalog, "workflow", null, "assets/data.txt", 0, limits, tool_result_limits.default_max_tool_result_bytes);
    defer freeExecuteResult(alloc, capped);
    try expectContains(capped.modelOutput(), "one\n");
    try expectContains(capped.modelOutput(), "name=\"skill_file_bytes\" action=\"blocked_remainder\"");
    try expectContains(capped.modelOutput(), "effective_bytes=\"4\" source=\"workspace settings\"");

    const blocked = try loadByIdentity(alloc, catalog, "workflow", null, "assets/data.txt", 4, limits, tool_result_limits.default_max_tool_result_bytes);
    defer freeExecuteResult(alloc, blocked);
    try expectContains(blocked.modelOutput(), "name=\"skill_file_bytes\" action=\"blocked_remainder\"");
    try expectNotContains(blocked.modelOutput(), "<skill_content");

    limits.skill_file_bytes = .{ .value = .{ .bytes = 16 * 1024 }, .source = .command_line };
    limits.skill_chunk_bytes = .{ .value = .off, .source = .command_line };
    const cross_chunk = try loadByIdentity(alloc, catalog, "workflow", null, "assets/cross-chunk.txt", 0, limits, tool_result_limits.default_max_tool_result_bytes);
    defer freeExecuteResult(alloc, cross_chunk);
    try std.testing.expect(std.unicode.utf8ValidateSlice(cross_chunk.modelOutput()));
    try expectContains(cross_chunk.modelOutput(), "name=\"skill_file_bytes\" action=\"blocked_remainder\"");
}

test "skill invocation encodes loaded paths and preserves the skill body" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const home_root = "home<meta>\ninjected_home";
    const workspace_path = home_root ++ "/workspace";
    const skill_root = home_root ++ "/.fx/skills/workflow";
    try tmp.dir.createDirPath(io_mod.getIo(), workspace_path);
    try tmp.dir.createDirPath(io_mod.getIo(), skill_root ++ "/assets");
    {
        var file = try tmp.dir.createFile(io_mod.getIo(), skill_root ++ "/SKILL.md", .{});
        defer file.close(io_mod.getIo());
        try file.writeStreamingAll(
            io_mod.getIo(),
            "---\nname: workflow\ndescription: workflow helper\n---\n\nBODY SENTINEL\n<instruction>keep raw</instruction>\n",
        );
    }
    {
        var file = try tmp.dir.createFile(io_mod.getIo(), skill_root ++ "/assets/sample<file>\ninjected_file.txt", .{});
        defer file.close(io_mod.getIo());
        try file.writeStreamingAll(io_mod.getIo(), "hello\n");
    }

    const workspace_root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, workspace_path);
    defer alloc.free(workspace_root);
    const skills_dir = try io_mod.dirRealpathAlloc(alloc, tmp.dir, home_root ++ "/.fx/skills");
    defer alloc.free(skills_dir);
    try setTestHome(null);
    defer setTestHome(null) catch {};

    var discovery = try loadVisibleSkillsForContext(alloc, workspace_root, skills_dir);
    defer discovery.deinit(alloc);
    const result = try loadByIdentity(
        alloc,
        .{ .skills = discovery.skills, .diagnostics = discovery.diagnostics },
        "workflow",
        null,
        null,
        0,
        .{},
        tool_result_limits.default_max_tool_result_bytes,
    );
    defer freeExecuteResult(alloc, result);
    const output = result.modelOutput();

    try expectContains(output, "<skill_content name=\"workflow\" resource=\"SKILL.md\" offset=\"0\"");
    try expectContains(output, "BODY SENTINEL\n<instruction>keep raw</instruction>");
    try expectNotContains(output, "sample&lt;file&gt;");
}

test "skill invocation encodes hostile missing skill name" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io_mod.getIo(), "home/workspace");
    try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx/skills");
    const workspace_root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home/workspace");
    defer alloc.free(workspace_root);
    const skills_dir = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home/.fx/skills");
    defer alloc.free(skills_dir);
    try setTestHome(null);
    defer setTestHome(null) catch {};

    const result = try loadByIdentity(
        alloc,
        .{ .skills = &.{} },
        "missing\"</skill><injected>yes</injected>",
        null,
        null,
        0,
        .{},
        tool_result_limits.default_max_tool_result_bytes,
    );
    defer freeExecuteResult(alloc, result);
    switch (result) {
        .failure => |output| {
            try expectContains(output.model_output, "Skill \"missing&quot;&lt;/skill&gt;&lt;injected&gt;yes&lt;/injected&gt;\" not found.");
            try expectContains(output.model_output, "Refresh available skills");
        },
        .loaded => return error.TestExpectedSkillFailure,
    }
}

test "skill invocation preserves strict discovery diagnostics without a profile home" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(tmp_root);
    const trace_path = try std.fs.path.join(alloc, &.{ tmp_root, "skill-tool-trace.log" });
    defer alloc.free(trace_path);
    test_debug_trace.resetForTest();
    defer test_debug_trace.resetForTest();
    try test_debug_trace.configureForTestWithScopes(alloc, trace_path, "skills");

    try tmp.dir.createDirPath(io_mod.getIo(), "custom-skills/invalid");
    {
        var file = try tmp.dir.createFile(io_mod.getIo(), "custom-skills/invalid/SKILL.md", .{});
        defer file.close(io_mod.getIo());
        try file.writeStreamingAll(io_mod.getIo(), "---\nname: bad/name\ndescription: invalid name\n---\n\nINVALID BODY SENTINEL\n");
    }

    const canonical_tmp = try io_mod.realpathAlloc(alloc, "/tmp");
    defer alloc.free(canonical_tmp);
    const workspace_root = try std.fs.path.join(alloc, &.{ canonical_tmp, "fx-skill-tool-strict-workspace" });
    defer alloc.free(workspace_root);
    const skills_dir = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "custom-skills");
    defer alloc.free(skills_dir);
    try setTestHome(null);
    defer setTestHome(null) catch {};

    var discovery = try loadVisibleSkillsForContext(alloc, workspace_root, skills_dir);
    defer discovery.deinit(alloc);
    skill_runtime.traceDiagnostics("skill_tool", discovery.diagnostics);
    const result = try loadByIdentity(
        alloc,
        .{ .skills = discovery.skills, .diagnostics = discovery.diagnostics },
        "bad/name",
        null,
        null,
        0,
        .{},
        tool_result_limits.default_max_tool_result_bytes,
    );
    defer freeExecuteResult(alloc, result);
    test_debug_trace.shutdown();

    var trace_file = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), trace_path, .{});
    defer trace_file.close(io_mod.getIo());
    const trace = try io_mod.readFileToEnd(alloc, &trace_file, 64 * 1024);
    defer alloc.free(trace);

    try expectContains(trace, "discovery_diagnostic surface=skill_tool");
    try expectContains(trace, "kind=invalid_metadata cause=invalid_name");
    switch (result) {
        .failure => |output| {
            try expectContains(output.model_output, "skill_discovery_warning");
            try expectContains(output.model_output, "Skill \"bad/name\" not found.");
            try expectNotContains(output.model_output, "metadata is invalid (invalid_name)");
            try expectContains(output.diagnostic_notice.?, "metadata is invalid (invalid_name)");
            try expectNotContains(output.model_output, "INVALID BODY SENTINEL");
        },
        .loaded => return error.TestExpectedSkillFailure,
    }
}

test "discovery diagnostics cannot hide a loaded skill at the minimum tool-result budget" {
    const alloc = std.testing.allocator;
    const detailed_notice = "skill discovery warning: " ++ (("candidate \"/very/long/" ++ ("x" ** 2048) ++ "\" was skipped; ") ** 4);
    const notice = try alloc.dupe(u8, detailed_notice);
    const model_output = try alloc.dupe(u8, "<skill_content name=\"requested\">\nREQUESTED SKILL BODY\n</skill_content>");
    const result = try attachExecuteNotice(
        alloc,
        .{ .loaded = .{ .model_output = model_output } },
        notice,
        tool_result_limits.min_configured_tool_result_bytes,
    );
    defer freeExecuteResult(alloc, result);

    switch (result) {
        .loaded => |output| {
            try std.testing.expect(output.model_output.len <= tool_result_limits.min_configured_tool_result_bytes);
            try expectContains(output.model_output, "REQUESTED SKILL BODY");
            try expectContains(output.model_output, "skill_discovery_warning");
            try expectNotContains(output.model_output, "/very/long/");
            try std.testing.expectEqualStrings(detailed_notice, output.diagnostic_notice.?);
        },
        .failure => return error.TestExpectedLoadedSkill,
    }
}

test "discovery diagnostics cannot hide a skill failure at the minimum tool-result budget" {
    const alloc = std.testing.allocator;
    const detailed_notice = "skill discovery warning: " ++ (("candidate \"/very/long/" ++ ("y" ** 2048) ++ "\" was skipped; ") ** 4);
    const notice = try alloc.dupe(u8, detailed_notice);
    const model_output = try alloc.dupe(u8, "Skill \"requested\" not found. Refresh available skills and retry with an advertised name.");
    const result = try attachExecuteNotice(
        alloc,
        .{ .failure = .{ .model_output = model_output } },
        notice,
        tool_result_limits.min_configured_tool_result_bytes,
    );
    defer freeExecuteResult(alloc, result);

    switch (result) {
        .failure => |output| {
            try std.testing.expect(output.model_output.len <= tool_result_limits.min_configured_tool_result_bytes);
            try expectContains(output.model_output, "Skill \"requested\" not found.");
            try expectContains(output.model_output, "Refresh available skills");
            try expectContains(output.model_output, "skill_discovery_warning");
            try expectNotContains(output.model_output, "/very/long/");
            try std.testing.expectEqualStrings(detailed_notice, output.diagnostic_notice.?);
        },
        .loaded => return error.TestExpectedSkillFailure,
    }
}

test "long identity failures retain their reason and recovery with discovery diagnostics" {
    const alloc = std.testing.allocator;
    const long_value = try alloc.alloc(u8, 64 * 1024);
    defer alloc.free(long_value);
    @memset(long_value, 'x');
    const detailed_notice = "skill discovery warning: candidate \"/tmp/bad/SKILL.md\" was skipped";

    const missing = try attachExecuteNotice(
        alloc,
        .{ .failure = .{ .model_output = try formatMissingSkill(alloc, long_value, executePrimaryBudget(tool_result_limits.min_configured_tool_result_bytes, true)) } },
        try alloc.dupe(u8, detailed_notice),
        tool_result_limits.min_configured_tool_result_bytes,
    );
    defer freeExecuteResult(alloc, missing);
    try expectContains(missing.modelOutput(), "not found");
    try expectContains(missing.modelOutput(), "Refresh available skills and retry with an advertised name.");

    const exact = try attachExecuteNotice(
        alloc,
        .{ .failure = .{ .model_output = try formatExactSkillNotFound(alloc, "workflow", long_value, executePrimaryBudget(tool_result_limits.min_configured_tool_result_bytes, true)) } },
        try alloc.dupe(u8, detailed_notice),
        tool_result_limits.min_configured_tool_result_bytes,
    );
    defer freeExecuteResult(alloc, exact);
    try expectContains(exact.modelOutput(), "was not found at advertised location");
    try expectContains(exact.modelOutput(), "Refresh available skills and retry with an advertised name and location.");

    const mismatch = try attachExecuteNotice(
        alloc,
        .{ .failure = .{ .model_output = try formatSkillLocationMismatch(alloc, "workflow", long_value, executePrimaryBudget(tool_result_limits.min_configured_tool_result_bytes, true)) } },
        try alloc.dupe(u8, detailed_notice),
        tool_result_limits.min_configured_tool_result_bytes,
    );
    defer freeExecuteResult(alloc, mismatch);
    try expectContains(mismatch.modelOutput(), "does not match the skill advertised at location");
    try expectContains(mismatch.modelOutput(), "Refresh available skills and retry with the advertised name and location.");

    try std.testing.expect(missing.modelOutput().len <= tool_result_limits.min_configured_tool_result_bytes);
    try std.testing.expect(exact.modelOutput().len <= tool_result_limits.min_configured_tool_result_bytes);
    try std.testing.expect(mismatch.modelOutput().len <= tool_result_limits.min_configured_tool_result_bytes);
}

test "exact skill failure bounds a caller-supplied location" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    try tmp.dir.createDirPath(io_mod.getIo(), "custom-skills");
    const workspace_root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace_root);
    const skills_dir = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "custom-skills");
    defer alloc.free(skills_dir);
    try setTestHome(null);
    defer setTestHome(null) catch {};
    var discovery = try loadVisibleSkillsForContext(alloc, workspace_root, skills_dir);
    defer discovery.deinit(alloc);

    const tail = "TAIL_LOCATION_SENTINEL";
    const long_location = try alloc.alloc(u8, 64 * 1024);
    defer alloc.free(long_location);
    @memset(long_location, 'x');
    @memcpy(long_location[0..9], "/outside/");
    @memcpy(long_location[511..514], "\xe2\x82\xac");
    @memcpy(long_location[long_location.len - tail.len ..], tail);

    const result = try loadByIdentity(
        alloc,
        .{ .skills = discovery.skills, .diagnostics = discovery.diagnostics },
        "workflow",
        long_location,
        null,
        0,
        .{},
        1024,
    );
    defer freeExecuteResult(alloc, result);
    const output = result.modelOutput();

    try std.testing.expectEqual(@min(output.len, 1024), output.len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(output));
    try expectContains(output, "was not found at advertised location");
    try expectContains(output, "Refresh available skills and retry with an advertised name and location.");
    try expectContains(output, "...");
    try std.testing.expect(std.mem.find(u8, output, tail) == null);
}

test "ambiguous skill failure uses configured bound and exact omitted count" {
    const alloc = std.testing.allocator;
    const tail = "TAIL_DISCOVERED_LOCATION_SENTINEL";
    const long_location = try alloc.alloc(u8, 64 * 1024);
    defer alloc.free(long_location);
    @memset(long_location, 'x');
    @memcpy(long_location[0..9], "/visible/");
    @memcpy(long_location[long_location.len - tail.len ..], tail);

    const duplicates = [_]skill_runtime.Skill{
        .{ .name = "workflow", .description = "A", .path = long_location, .source = .workspace_shared },
        .{ .name = "workflow", .description = "B", .path = long_location, .source = .global_fx },
    };
    const output = try formatAmbiguousSkill(alloc, &duplicates, "workflow", 1024);
    defer alloc.free(output);

    try std.testing.expect(output.len <= 1024);
    try expectContains(output, "all 2 advertised locations were omitted by the 1024-byte tool-result limit");
    try expectContains(output, "Refresh available skills");
    try std.testing.expect(std.mem.find(u8, output, tail) == null);
}
