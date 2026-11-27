//! Turns a bash program's skill and agent bridge request into the tool call it
//! runs as, and formats the skill list and the failures of a skill read. The
//! functions are pure: they take data and an allocator, and read no context, I/O,
//! clock, or shared state.
const std = @import("std");
const types = @import("../shared/types.zig");
const text_utils = @import("../shared/text_utils.zig");
const tool_bridge = @import("../tool_bridge/tool_bridge.zig");
const skill_contract = @import("../skills/skill_contract.zig");
const subagent_reports = @import("../subagent/reports.zig");

const Allocator = std.mem.Allocator;
const capability = tool_bridge.capability;
const ToolCall = types.ToolCall;

// capability.AgentReport mirrors reports.Rule, since the bridge module may not
// import subagent code. This file imports both, so it checks them.
comptime {
    const mirror = @typeInfo(capability.AgentReport).@"enum".field_names;
    const source = @typeInfo(subagent_reports.Rule).@"enum".field_names;
    for (0..@max(mirror.len, source.len)) |index| {
        const mirror_name = if (index < mirror.len) mirror[index] else "(no field)";
        const source_name = if (index < source.len) source[index] else "(no field)";
        if (!std.mem.eql(u8, mirror_name, source_name)) {
            @compileError("capability.AgentReport must mirror reports.Rule field for field: AgentReport has " ++ mirror_name ++ " where reports.Rule has " ++ source_name);
        }
    }
}

/// The tool call a bash program's skill or agent request runs as. `skill_target`
/// is the permission target of a skill open, which the caller resolves from the
/// session's skill locations. Other requests do not read it.
pub fn toolCall(
    arena: Allocator,
    request_id: []const u8,
    operation: capability.BashToolRequest,
    skill_target: []const u8,
) !ToolCall {
    var out: std.Io.Writer.Allocating = .init(arena);
    switch (operation) {
        .skill_list => return .{
            .id = request_id,
            .name = "toolbox",
            .arguments_json = "{\"search\":\"\"}",
            .toolbox_lookup = .{ .permission = "capability_search", .target = "*" },
        },
        .skill_open => |req| {
            try out.writer.writeAll("{\"open\":");
            try std.json.Stringify.value(req.name, .{}, &out.writer);
            try out.writer.writeAll(",\"kind\":\"skill\"");
            if (req.resource) |resource| {
                try out.writer.writeAll(",\"resource\":");
                try std.json.Stringify.value(resource, .{}, &out.writer);
            }
            try out.writer.writeByte('}');
            return .{
                .id = request_id,
                .name = "toolbox",
                .arguments_json = out.written(),
                .toolbox_lookup = .{ .permission = "skill", .target = skill_target },
            };
        },
        .agent_message => |req| {
            try out.writer.writeAll("{\"action\":\"message\",\"agent\":");
            try std.json.Stringify.value(req.agent, .{}, &out.writer);
            try out.writer.writeAll(",\"message\":");
            try std.json.Stringify.value(req.message, .{}, &out.writer);
            if (req.instructions) |instructions| {
                try out.writer.writeAll(",\"instructions\":");
                try std.json.Stringify.value(instructions, .{}, &out.writer);
            }
            if (req.model) |model| {
                try out.writer.writeAll(",\"model\":");
                try std.json.Stringify.value(model, .{}, &out.writer);
            }
            if (req.effort) |effort| {
                try out.writer.writeAll(",\"effort\":");
                try std.json.Stringify.value(effort, .{}, &out.writer);
            }
            if (req.profile) |profile| {
                try out.writer.writeAll(",\"profile\":");
                try std.json.Stringify.value(profile, .{}, &out.writer);
            }
            if (req.report) |report| {
                try out.writer.writeAll(",\"report\":");
                try std.json.Stringify.value(report.name(), .{}, &out.writer);
            }
            try out.writer.writeByte('}');
            return .{ .id = request_id, .name = "subagent", .arguments_json = out.written() };
        },
        .agent_wait => return .{ .id = request_id, .name = "subagent", .arguments_json = "{\"action\":\"wait\"}" },
        .agent_status => |maybe_agent| {
            try out.writer.writeAll("{\"action\":\"status\"");
            if (maybe_agent) |agent| {
                try out.writer.writeAll(",\"agent\":");
                try std.json.Stringify.value(agent, .{}, &out.writer);
            }
            try out.writer.writeByte('}');
            return .{ .id = request_id, .name = "subagent", .arguments_json = out.written() };
        },
        .agent_stop => |agent| {
            try out.writer.writeAll("{\"action\":\"stop\",\"agent\":");
            try std.json.Stringify.value(agent, .{}, &out.writer);
            try out.writer.writeByte('}');
            return .{ .id = request_id, .name = "subagent", .arguments_json = out.written() };
        },
        .agent_close => |agent| {
            try out.writer.writeAll("{\"action\":\"close\",\"agent\":");
            try std.json.Stringify.value(agent, .{}, &out.writer);
            try out.writer.writeByte('}');
            return .{ .id = request_id, .name = "subagent", .arguments_json = out.written() };
        },
    }
}

const truncated_fmt = "[skill list truncated at {d}-byte limit; {d} more omitted]\n";

/// The skill list a bash program reads: one `NAME<TAB>DESCRIPTION` line per skill,
/// kept within `cap` bytes. A description longer than `description_bytes` is cut.
/// Skills that do not fit are left out, and the last line counts them.
pub fn skillListText(arena: Allocator, skills: []const skill_contract.Skill, cap: usize, description_bytes: usize) ![]const u8 {
    // Reserve room for the worst-case truncation line so total bytes never exceed `cap`.
    const max_notice = std.fmt.comptimePrint(truncated_fmt, .{ std.math.maxInt(usize), std.math.maxInt(usize) });
    var out: std.Io.Writer.Allocating = .init(arena);
    var written_count: usize = 0;
    var truncated = false;
    for (skills) |skill| {
        var line: std.Io.Writer.Allocating = .init(arena);
        try line.writer.writeAll((try text_utils.encodeTerminalSafeInline(arena, skill.name, skill_contract.max_name_bytes)).bytes);
        try line.writer.writeByte('\t');
        try line.writer.writeAll((try text_utils.encodeTerminalSafeInline(arena, skill.description, description_bytes)).bytes);
        try line.writer.writeByte('\n');
        const line_bytes = line.written();
        if (out.written().len + line_bytes.len + max_notice.len > cap) {
            truncated = true;
            break;
        }
        try out.writer.writeAll(line_bytes);
        written_count += 1;
    }
    if (truncated) {
        const omitted = skills.len - written_count;
        try out.writer.print(truncated_fmt, .{ cap, omitted });
    }
    return out.written();
}

/// The longest encoded skill name or resource that a failure text shows. A
/// longer one is cut on a token boundary and ends with "...".
const skill_open_field_bytes: usize = 200;

/// A skill name or resource from a program, as text fit to draw and to send
/// to the model: terminal-safe, and at most `skill_open_field_bytes` bytes.
fn skillOpenField(arena: Allocator, raw: []const u8) Allocator.Error![]const u8 {
    return (try text_utils.encodeTerminalSafe(arena, raw, skill_open_field_bytes)).bytes;
}

pub fn skillOpenFailureText(arena: Allocator, raw_name: []const u8, raw_resource: ?[]const u8, err: anyerror) Allocator.Error![]const u8 {
    const name = try skillOpenField(arena, raw_name);
    const resource = if (raw_resource) |raw| try skillOpenField(arena, raw) else null;
    const shown = resource orelse "SKILL.md";
    return switch (err) {
        error.FileNotFound => if (resource) |path|
            arena.print("resource {s} was not found in skill {s}; check the path, which is relative to the skill folder.", .{ path, name })
        else
            arena.print("no skill named {s}; run skill list to see the names.", .{name}),
        error.InvalidSkillResourcePath => arena.print("resource {s} is not a valid path in skill {s}; use a relative path inside the skill folder with no .. parts.", .{ shown, name }),
        error.IsDir => arena.print("resource {s} is a folder, not a file, in skill {s}; name a file inside it.", .{ shown, name }),
        error.SkillResourceNotRegularFile => arena.print("resource {s} in skill {s} is not a regular file (a folder, a link, a pipe, or a device); name a regular file inside the skill folder.", .{ shown, name }),
        error.InvalidSkillLocation, error.StaleSkillLocation => arena.print("{s} is not a skill location fx can read; use a name from skill list.", .{name}),
        error.AccessDenied => arena.print("resource {s} in skill {s} cannot be read: permission denied; check the file's permissions.", .{ shown, name }),
        error.SkillFileLimitExceeded => arena.print("resource {s} in skill {s} is larger than the skill_file_bytes limit; raise skill_file_bytes to read it.", .{ shown, name }),
        error.SkillResourceChanged, error.ChangedSkillWasLoaded => arena.print("resource {s} in skill {s} changed while fx read it; open it again.", .{ shown, name }),
        else => arena.print("could not read {s} in skill {s} ({s}); open it again, and report it if this repeats.", .{ shown, name, @errorName(err) }),
    };
}

test "bridged skill open names a missing skill and the command that lists names" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const text = try skillOpenFailureText(arena_state.allocator(), "alpha", null, error.FileNotFound);
    try std.testing.expectEqualStrings("no skill named alpha; run skill list to see the names.", text);
}

test "bridged skill open read failures name the file, what is wrong, and the next step" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cases = [_]struct { err: anyerror, resource: ?[]const u8, expected: []const u8 }{
        .{
            .err = error.AccessDenied,
            .resource = null,
            .expected = "resource SKILL.md in skill alpha cannot be read: permission denied; check the file's permissions.",
        },
        .{
            .err = error.SkillFileLimitExceeded,
            .resource = "big.txt",
            .expected = "resource big.txt in skill alpha is larger than the skill_file_bytes limit; raise skill_file_bytes to read it.",
        },
        .{
            .err = error.SkillResourceChanged,
            .resource = "big.txt",
            .expected = "resource big.txt in skill alpha changed while fx read it; open it again.",
        },
        .{
            .err = error.NoSpaceLeft,
            .resource = null,
            .expected = "could not read SKILL.md in skill alpha (NoSpaceLeft); open it again, and report it if this repeats.",
        },
    };
    for (cases) |case| {
        const text = try skillOpenFailureText(arena, "alpha", case.resource, case.err);
        try std.testing.expectEqualStrings(case.expected, text);
    }
}

test "bridged skill open shows a program's name and resource terminal-safe and cut to 200 bytes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var hostile_buf: [5 + 300]u8 = undefined;
    @memcpy(hostile_buf[0..5], "\x1b[31m");
    @memset(hostile_buf[5..], 'a');
    const hostile: []const u8 = &hostile_buf;

    const missing = try skillOpenFailureText(arena, hostile, null, error.FileNotFound);
    const missing_prefix = "no skill named ";
    const missing_suffix = "; run skill list to see the names.";
    try std.testing.expect(std.mem.startsWith(u8, missing, missing_prefix));
    try std.testing.expect(std.mem.endsWith(u8, missing, missing_suffix));
    const shown_name = missing[missing_prefix.len .. missing.len - missing_suffix.len];
    try std.testing.expect(shown_name.len <= 200);
    try std.testing.expect(std.mem.endsWith(u8, shown_name, "..."));
    try std.testing.expect(std.mem.findScalar(u8, shown_name, 0x1b) == null);

    const resource_text = try skillOpenFailureText(arena, "alpha", hostile, error.FileNotFound);
    const resource_prefix = "resource ";
    const resource_end = " was not found in skill alpha";
    try std.testing.expect(std.mem.startsWith(u8, resource_text, resource_prefix));
    const end = std.mem.find(u8, resource_text, resource_end) orelse return error.TestUnexpectedResult;
    const shown_resource = resource_text[resource_prefix.len..end];
    try std.testing.expect(shown_resource.len <= 200);
    try std.testing.expect(std.mem.findScalar(u8, shown_resource, 0x1b) == null);
}

test "bridged skill open names a skill location fx cannot read, with the next step" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const expected = "skill:x is not a skill location fx can read; use a name from skill list.";
    try std.testing.expectEqualStrings(expected, try skillOpenFailureText(arena, "skill:x", null, error.InvalidSkillLocation));
    try std.testing.expectEqualStrings(expected, try skillOpenFailureText(arena, "skill:x", null, error.StaleSkillLocation));
}

test "bridged skill list cuts a description longer than the context limit, with an ellipsis" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var long_buf: [300]u8 = undefined;
    @memset(&long_buf, 'd');
    const skills = [_]skill_contract.Skill{.{ .name = "alpha", .description = &long_buf, .path = "/workspace/.fx/skills/alpha/SKILL.md", .source = .workspace_fx }};
    const out = try skillListText(arena, &skills, 32 * 1024, 64);
    const tab = std.mem.findScalar(u8, out, '\t') orelse return error.TestUnexpectedResult;
    const description = out[tab + 1 .. out.len - 1];
    try std.testing.expect(description.len <= 64);
    try std.testing.expect(std.mem.endsWith(u8, description, "..."));
}

test "bridged skill open names a resource that is not a regular file, with the next step" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const text = try skillOpenFailureText(arena_state.allocator(), "demo", "pipe", error.SkillResourceNotRegularFile);
    try std.testing.expectEqualStrings(
        "resource pipe in skill demo is not a regular file (a folder, a link, a pipe, or a device); name a regular file inside the skill folder.",
        text,
    );
}
