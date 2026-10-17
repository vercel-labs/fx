//! The settings fx knows, like the kernel's sysctl table: every key it reads
//! from the profile `settings.json`, a workspace override inside it, or a
//! project `.fx.json`. Startup ignores keys missing from this list; `fx doctor`
//! reports them.

const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Where = enum {
    /// Profile `settings.json` and its workspace overrides. A project
    /// `.fx.json` that sets it is ignored with a warning.
    profile,
    /// Also a repo-safe default in a project `.fx.json`.
    project_safe,
    /// No longer used. Read only so it is ignored without being reported.
    retired,
    /// Known in every settings file and never read by fx: `$schema`, which
    /// editors use to check the file.
    editor,
};

/// The JSON value fx accepts for a key, as `fx config schema` describes it.
pub const Kind = enum {
    /// Anything. Only retired keys, which fx ignores, use it.
    any,
    boolean,
    integer,
    string,
    /// A string, or null for the default.
    string_or_null,
    /// An array of strings.
    strings,
    /// An object whose values are strings, such as `models`.
    string_map,
    /// An object of switches, named by `children`.
    switches,
    /// An object that fx checks with its own rules, such as `permission`.
    object,
    /// The `workspaces` map from a workspace path to its overrides.
    workspaces,
    /// A key fx refuses to load, so a file that has it fails.
    refused,
};

pub const Key = struct {
    name: []const u8,
    where: Where,
    kind: Kind,
    description: []const u8,
    /// Fixed child keys of an object setting, such as `statusLine.context`.
    /// Empty for plain values and for maps. Every child is a switch.
    children: []const []const u8 = &.{},
    /// What each of `children` does, in the same order.
    child_descriptions: []const []const u8 = &.{},
    /// The strings fx accepts for a string key with a fixed set. fx ignores
    /// case; the schema lists the spellings fx writes and documents.
    values: []const []const u8 = &.{},
    /// Inclusive bounds of an integer key.
    minimum: ?i64 = null,
    maximum: ?i64 = null,
    /// The most items a `strings` key may hold.
    max_items: ?usize = null,
    /// An object whose keys are free-form, such as `models.codex`.
    map: bool = false,
    /// The current name of a setting that was renamed. fx still reads the
    /// older name, writes only the current one, and the current one wins for
    /// any value both set.
    renamed_to: ?[]const u8 = null,
    /// The key that replaced an older form fx still reads but no longer
    /// writes, such as `models.gateway` for `model`.
    superseded_by: ?[]const u8 = null,
    /// Read only inside a `workspaces` entry, never at the top of the file.
    workspace_only: bool = false,
    /// Read only at the top of the profile, never inside a `workspaces` entry.
    top_level_only: bool = false,

    pub fn hasChild(self: Key, name: []const u8) bool {
        for (self.children) |child| {
            if (std.mem.eql(u8, child, name)) return true;
        }
        return false;
    }

    /// Whether editors should mark the key as old: retired, renamed, or
    /// superseded.
    pub fn deprecated(self: Key) bool {
        return self.where == .retired or self.renamed_to != null or self.superseded_by != null;
    }
};

const sound_children = [_][]const u8{ "attention_required", "max", "turn_end" };
const sound_child_descriptions = [_][]const u8{
    "Play a sound when fx needs your attention",
    "Play extra interaction sounds when sound is on",
    "Play a sound when a turn finishes",
};
const status_line_children = [_][]const u8{ "context", "session", "workspace" };
const status_line_child_descriptions = [_][]const u8{
    "Show context usage in the footer",
    "Show the session title in the footer",
    "Show the workspace path and Git branch in the footer",
};
const retired_description = "No longer used; fx ignores it";

pub const keys = [_]Key{
    .{ .name = "$schema", .where = .editor, .kind = .string, .top_level_only = true, .description = "The JSON Schema editors use to check this file" },
    .{ .name = "additional_directories", .where = .profile, .kind = .strings, .workspace_only = true, .description = "Directories added to this workspace; manage them with fx workspace" },
    .{ .name = "auto_compact_percent", .where = .profile, .kind = .integer, .minimum = 10, .maximum = 80, .description = "Start automatic compaction at this percentage of usable input capacity" },
    .{ .name = "auto_upgrade", .where = .profile, .kind = .boolean, .description = "Download and install updates in the background" },
    .{ .name = "codex_model", .where = .profile, .kind = .string, .superseded_by = "models.codex", .description = "Older form of models.codex" },
    .{ .name = "collapse_tool_calls", .where = .profile, .kind = .boolean, .description = "Show a summary for each group of tool calls" },
    .{ .name = "context", .where = .project_safe, .kind = .boolean, .description = "Load project instructions such as AGENTS.md" },
    .{ .name = "context_limits", .where = .profile, .kind = .object, .map = true, .description = "Context limits by name, in bytes or off, as --context-limit takes them" },
    .{ .name = "credential_source", .where = .profile, .kind = .string, .values = &.{ "vercel_oidc_token", "ai_gateway_api_key", "fx_login", "stored_key", "chatgpt_subscription", "grok_subscription" }, .description = "The saved credential fx uses; fx login sets it" },
    .{ .name = "disabledMcpjsonServers", .where = .profile, .kind = .strings, .workspace_only = true, .description = "Project MCP servers rejected in this workspace; manage them with fx mcp trust" },
    .{ .name = "effort", .where = .profile, .kind = .string_or_null, .description = "Reasoning effort: auto or a name the model supports; null means auto" },
    .{ .name = "enableAllProjectMcpServers", .where = .profile, .kind = .boolean, .workspace_only = true, .description = "Approve every server in this workspace's .mcp.json; manage it with fx mcp trust" },
    .{ .name = "enabledMcpjsonServers", .where = .profile, .kind = .strings, .workspace_only = true, .description = "Project MCP servers approved in this workspace; manage them with fx mcp trust" },
    .{ .name = "experimental", .where = .profile, .kind = .switches, .children = &.{"sessions_v2"}, .child_descriptions = &.{"Use the experimental v2 session store"}, .description = "Experimental features, which may change or go away" },
    .{ .name = "fast_mode", .where = .profile, .kind = .boolean, .description = "Use faster inference when the model supports it" },
    .{ .name = "fast_mode_model_bound", .where = .profile, .kind = .boolean, .description = "Managed by fx alongside fast_mode" },
    .{ .name = "first_call_tool_choice", .where = .profile, .kind = .string, .values = &.{ "auto", "none" }, .description = "Tool choice for the first request of a turn" },
    .{ .name = "grok_model", .where = .profile, .kind = .string, .superseded_by = "models.grok", .description = "Older form of models.grok" },
    .{ .name = "input_appearance", .where = .retired, .kind = .any, .description = retired_description },
    .{ .name = "max_agent_steps", .where = .project_safe, .kind = .integer, .minimum = 0, .description = "Most agent steps per turn; 0 means no limit" },
    .{ .name = "max_tool_result_bytes", .where = .project_safe, .kind = .integer, .minimum = 1024, .description = "Tool output budget in model context, in bytes" },
    .{ .name = "maxxing_mode", .where = .retired, .kind = .any, .description = retired_description },
    .{ .name = "model", .where = .profile, .kind = .string, .superseded_by = "models.gateway", .description = "Older form of models.gateway" },
    .{ .name = "models", .where = .profile, .kind = .string_map, .map = true, .description = "The saved model for each provider or connection, such as {\"gateway\": \"<model id>\"}" },
    .{ .name = "notifications", .where = .profile, .kind = .switches, .children = &sound_children, .child_descriptions = &sound_child_descriptions, .renamed_to = "sound", .description = "Renamed to sound" },
    .{ .name = "permission", .where = .profile, .kind = .object, .map = true, .description = "Permission rules; manage them with /permissions" },
    .{ .name = "permission_mode", .where = .profile, .kind = .string, .values = &.{ "ask", "auto", "full-access", "yolo" }, .description = "How fx handles tool calls that need permission; yolo is an older name for full-access" },
    .{ .name = "prompt_history", .where = .profile, .kind = .switches, .children = &.{"enabled"}, .child_descriptions = &.{"Save prompts and slash commands for input history"}, .description = "Input history" },
    .{ .name = "provider", .where = .profile, .kind = .string, .description = "The service for model requests: gateway, codex, grok, or a name under providers" },
    .{ .name = "provider_order", .where = .project_safe, .kind = .strings, .max_items = 8, .description = "Preferred AI Gateway providers, in order" },
    .{ .name = "provider_strict", .where = .project_safe, .kind = .boolean, .description = "Send AI Gateway requests only to the providers in provider_order" },
    .{ .name = "providers", .where = .profile, .kind = .object, .map = true, .top_level_only = true, .description = "Named custom model connections" },
    .{ .name = "review_model", .where = .profile, .kind = .string, .description = "The AI Gateway model that reviews actions in auto mode" },
    .{ .name = "sandbox", .where = .retired, .kind = .any, .description = retired_description },
    .{ .name = "session_titles", .where = .profile, .kind = .boolean, .description = "Name each session from its first prompt" },
    // Retired, but still read so that fx can explain the migration.
    .{ .name = "skill_match_fuzzy", .where = .profile, .kind = .refused, .description = "No longer supported; fx refuses a file that sets it, so remove it" },
    .{ .name = "skill_symlink_authorities", .where = .profile, .kind = .strings, .description = "Absolute directories that symlinked skills may resolve into" },
    .{ .name = "slash_menu_categories", .where = .profile, .kind = .boolean, .description = "Show command categories and skill sources in slash menu results" },
    .{ .name = "sound", .where = .profile, .kind = .switches, .children = &sound_children, .child_descriptions = &sound_child_descriptions, .description = "Sounds" },
    .{ .name = "startup_scrollback", .where = .profile, .kind = .boolean, .description = "Restore terminal output at startup" },
    .{ .name = "statusLine", .where = .profile, .kind = .switches, .children = &status_line_children, .child_descriptions = &status_line_child_descriptions, .renamed_to = "status_line", .description = "Renamed to status_line" },
    .{ .name = "status_line", .where = .profile, .kind = .switches, .children = &status_line_children, .child_descriptions = &status_line_child_descriptions, .description = "What the footer shows" },
    .{ .name = "theme", .where = .profile, .kind = .string, .description = "light, dark, or the name of a theme file in ~/.fx/themes" },
    .{ .name = "ultrafast_mode", .where = .profile, .kind = .boolean, .description = "Request the higher-priced Ultrafast tier for an eligible AI Gateway model" },
    .{ .name = "update_channel", .where = .profile, .kind = .string, .values = &.{ "stable", "dev" }, .description = "Release channel for updates" },
    .{ .name = "web_fetch_worker_model", .where = .retired, .kind = .any, .description = retired_description },
    .{ .name = "workspaces", .where = .profile, .kind = .workspaces, .map = true, .top_level_only = true, .description = "Overrides for each workspace, by absolute path" },
    .{ .name = "yolo_acknowledged", .where = .profile, .kind = .boolean, .description = "Managed by fx after you first confirm full-access mode" },
};

const names = blk: {
    var list: [keys.len][]const u8 = undefined;
    for (keys, 0..) |key, index| list[index] = key.name;
    break :blk list;
};

pub fn find(name: []const u8) ?Key {
    for (keys) |key| {
        if (std.mem.eql(u8, key.name, name)) return key;
    }
    return null;
}

/// True when a project `.fx.json` that sets `name` is ignored and the user
/// should be told: a known setting that only the profile may set.
pub fn ignoredInProject(name: []const u8) bool {
    const key = find(name) orelse return false;
    return key.where == .profile;
}

/// `path` under a renamed setting's current name, such as
/// `status_line.context` for `statusLine.context`. Any other path comes back
/// unchanged. The result is `path` or a string in the list.
pub fn currentPath(path: []const u8) []const u8 {
    inline for (keys) |key| {
        if (key.renamed_to) |current| {
            if (std.mem.eql(u8, path, key.name)) return current;
            inline for (key.children) |child| {
                if (std.mem.eql(u8, path, key.name ++ "." ++ child)) return current ++ "." ++ child;
            }
        }
    }
    return path;
}

pub const File = enum { profile, project };

pub const OlderName = struct {
    older: []const u8,
    current: []const u8,
    /// Whether the current name is set beside it.
    both: bool = true,
    /// The workspace override holding both, borrowed from the parsed
    /// settings, or null at the top level.
    workspace: ?[]const u8 = null,
};

/// Lists the renamed settings that `root` sets under both their older and
/// their current name, where the current one wins. A profile `settings.json`
/// is also checked inside each `workspaces` override. Caller owns the
/// returned slice; its strings borrow from `root` and the list.
pub fn findOlderNames(alloc: Allocator, root: std.json.Value, file: File) ![]OlderName {
    var found: std.ArrayList(OlderName) = .empty;
    errdefer found.deinit(alloc);
    if (root != .object) return found.toOwnedSlice(alloc);
    try appendOlderNames(alloc, &found, root.object, null);
    if (file == .profile) {
        if (root.object.get("workspaces")) |workspaces| {
            if (workspaces == .object) {
                var iterator = workspaces.object.iterator();
                while (iterator.next()) |entry| {
                    if (entry.value_ptr.* != .object) continue;
                    try appendOlderNames(alloc, &found, entry.value_ptr.object, entry.key_ptr.*);
                }
            }
        }
    }
    return found.toOwnedSlice(alloc);
}

fn appendOlderNames(alloc: Allocator, found: *std.ArrayList(OlderName), object: std.json.ObjectMap, workspace: ?[]const u8) !void {
    for (keys) |key| {
        const current = key.renamed_to orelse continue;
        const older_value = object.get(key.name) orelse continue;
        const current_value = object.get(current) orelse {
            try found.append(alloc, .{ .older = key.name, .current = current, .both = false, .workspace = workspace });
            continue;
        };
        // fx ignores a current group that isn't an object and keeps using the
        // older one, so advising to remove the older one would lose settings.
        if (older_value == .object and current_value != .object) continue;
        try found.append(alloc, .{ .older = key.name, .current = current, .workspace = workspace });
    }
}

pub const UnknownKey = struct {
    /// The key, borrowed from the parsed settings.
    name: []const u8,
    /// The object setting holding the key, such as `statusLine`, or null at
    /// the top level.
    parent: ?[]const u8 = null,
    /// The workspace override holding the key, borrowed from the parsed
    /// settings, or null outside `workspaces`.
    workspace: ?[]const u8 = null,
    /// The known keys at the same level, for a "did you mean" suggestion.
    known: []const []const u8,
};

/// Lists the keys in `root` that fx doesn't know. A profile `settings.json`
/// is also checked inside each `workspaces` override. Values of the wrong
/// type are left to the settings parser. Caller owns the returned slice;
/// its strings borrow from `root`.
pub fn findUnknown(alloc: Allocator, root: std.json.Value, file: File) ![]UnknownKey {
    var found: std.ArrayList(UnknownKey) = .empty;
    errdefer found.deinit(alloc);
    if (root != .object) return found.toOwnedSlice(alloc);

    try appendUnknown(alloc, &found, root.object, null);
    if (file == .profile) {
        if (root.object.get("workspaces")) |workspaces| {
            if (workspaces == .object) {
                var iterator = workspaces.object.iterator();
                while (iterator.next()) |entry| {
                    if (entry.value_ptr.* != .object) continue;
                    try appendUnknown(alloc, &found, entry.value_ptr.object, entry.key_ptr.*);
                }
            }
        }
    }
    return found.toOwnedSlice(alloc);
}

fn appendUnknown(
    alloc: Allocator,
    found: *std.ArrayList(UnknownKey),
    object: std.json.ObjectMap,
    workspace: ?[]const u8,
) !void {
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        const name = entry.key_ptr.*;
        const key = find(name) orelse {
            try found.append(alloc, .{ .name = name, .workspace = workspace, .known = &names });
            continue;
        };
        if (key.children.len == 0 or entry.value_ptr.* != .object) continue;
        var children = entry.value_ptr.object.iterator();
        while (children.next()) |child| {
            if (key.hasChild(child.key_ptr.*)) continue;
            try found.append(alloc, .{
                .name = child.key_ptr.*,
                .parent = key.name,
                .workspace = workspace,
                .known = key.children,
            });
        }
    }
}

pub const UnknownPart = struct {
    /// The part of the path that names no setting.
    name: []const u8,
    /// The setting holding it, such as `statusLine`, or null at the top level.
    parent: ?[]const u8 = null,
    /// The known keys at the same level, for a "did you mean" suggestion.
    known: []const []const u8,
};

/// Null when a dotted `path` names a setting: a listed key, a fixed child
/// such as `statusLine.context`, or any path into a map such as
/// `models.codex`. Otherwise the part that isn't known. Retired keys aren't
/// settings. Slices borrow from `path` and the list.
pub fn unknownPart(path: []const u8) ?UnknownPart {
    const dot = std.mem.findScalar(u8, path, '.');
    const head = path[0 .. dot orelse path.len];
    const key = find(head) orelse return .{ .name = head, .known = &names };
    if (key.where == .retired) return .{ .name = head, .known = &names };
    const at = dot orelse return null;
    if (key.map) return null;
    const rest = path[at + 1 ..];
    const parent = key.renamed_to orelse key.name;
    if (key.children.len == 0) return .{ .name = rest, .parent = parent, .known = &.{} };
    if (std.mem.findScalar(u8, rest, '.') == null and key.hasChild(rest)) return null;
    return .{ .name = rest, .parent = parent, .known = key.children };
}

test "every key says what it holds and what it does" {
    for (keys) |key| {
        errdefer std.debug.print("key {s}\n", .{key.name});
        try std.testing.expect(key.description.len > 0);
        try std.testing.expectEqual(key.children.len, key.child_descriptions.len);
        try std.testing.expectEqual(key.children.len > 0, key.kind == .switches);
        try std.testing.expectEqual(key.where == .retired, key.kind == .any);
        try std.testing.expect(!(key.workspace_only and key.top_level_only));
        if (key.values.len > 0) try std.testing.expectEqual(Kind.string, key.kind);
        if (key.minimum != null or key.maximum != null) try std.testing.expectEqual(Kind.integer, key.kind);
        if (key.max_items != null) try std.testing.expectEqual(Kind.strings, key.kind);
        if (key.superseded_by) |path| {
            const dot = std.mem.findScalar(u8, path, '.') orelse path.len;
            try std.testing.expect(find(path[0..dot]) != null);
        }
    }
}

test "both spellings are reported only when fx would use the current one" {
    const alloc = std.testing.allocator;
    const text =
        \\{"notifications":{"turn_end":true},"sound":false,
        \\ "statusLine":{"context":true},"status_line":{"context":false}}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, text, .{});
    defer parsed.deinit();

    const found = try findOlderNames(alloc, parsed.value, .profile);
    defer alloc.free(found);
    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqualStrings("statusLine", found[0].older);
}

test "keys are unique and sorted so the list stays easy to scan" {
    for (keys[1..], 1..) |key, index| {
        try std.testing.expect(std.mem.order(u8, keys[index - 1].name, key.name) == .lt);
    }
}

test "renamed settings point to a current key with the same children" {
    for (keys) |key| {
        const current = find(key.renamed_to orelse continue).?;
        try std.testing.expect(current.renamed_to == null);
        try std.testing.expectEqual(key.where, current.where);
        try std.testing.expectEqual(key.children.len, current.children.len);
        for (key.children) |child| try std.testing.expect(current.hasChild(child));
    }
}

test "older names map to the current ones, in paths and in files" {
    const alloc = std.testing.allocator;
    const cases = [_]struct { path: []const u8, expected: []const u8 }{
        .{ .path = "statusLine.context", .expected = "status_line.context" },
        .{ .path = "statusLine", .expected = "status_line" },
        .{ .path = "notifications.max", .expected = "sound.max" },
        .{ .path = "status_line.context", .expected = "status_line.context" },
        .{ .path = "statusLine.contxt", .expected = "statusLine.contxt" },
        .{ .path = "fast_mode", .expected = "fast_mode" },
    };
    for (cases) |case| try std.testing.expectEqualStrings(case.expected, currentPath(case.path));
    // A mistyped child of an older name is reported under the current one.
    try std.testing.expectEqualStrings("status_line", unknownPart("statusLine.contxt").?.parent.?);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc,
        \\{"statusLine":{"context":true},"status_line":{"context":false},"notifications":{"max":true},
        \\ "workspaces":{"/w":{"notifications":{},"sound":{}},"/x":{"sound":{}}}}
    , .{});
    defer parsed.deinit();
    const twice = try findOlderNames(alloc, parsed.value, .profile);
    defer alloc.free(twice);
    // A top-level older name is reported alone too, so fx doctor can say when
    // it stops working.
    try std.testing.expectEqual(@as(usize, 3), twice.len);
    try std.testing.expectEqualStrings("notifications", twice[0].older);
    try std.testing.expect(!twice[0].both and twice[0].workspace == null);
    try std.testing.expectEqualStrings("statusLine", twice[1].older);
    try std.testing.expectEqualStrings("status_line", twice[1].current);
    try std.testing.expect(twice[1].both and twice[1].workspace == null);
    try std.testing.expectEqualStrings("notifications", twice[2].older);
    try std.testing.expectEqualStrings("/w", twice[2].workspace.?);
}

test "project files ignore profile keys but not project-safe or retired ones" {
    try std.testing.expect(ignoredInProject("model"));
    try std.testing.expect(ignoredInProject("workspaces"));
    try std.testing.expect(ignoredInProject("enabledMcpjsonServers"));
    try std.testing.expect(!ignoredInProject("max_agent_steps"));
    try std.testing.expect(!ignoredInProject("provider_order"));
    try std.testing.expect(!ignoredInProject("maxxing_mode"));
    try std.testing.expect(!ignoredInProject("not_a_setting"));
}

test "unknown keys are found at the top level, in fixed objects, and in workspace overrides" {
    const alloc = std.testing.allocator;
    const text =
        \\{"fast_mdoe":true,"model":"m","maxxing_mode":1,"sandbox":"os",
        \\ "statusLine":{"context":true,"contxt":false},
        \\ "notifications":"off",
        \\ "models":{"anything":"m"},
        \\ "workspaces":{"/w":{"effort":"high","efort":"low","statusLine":{"sesion":true}},"/bad":3}}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, text, .{});
    defer parsed.deinit();

    const unknown = try findUnknown(alloc, parsed.value, .profile);
    defer alloc.free(unknown);
    try std.testing.expectEqual(@as(usize, 4), unknown.len);

    try std.testing.expectEqualStrings("fast_mdoe", unknown[0].name);
    try std.testing.expect(unknown[0].parent == null and unknown[0].workspace == null);
    try std.testing.expectEqual(@as(usize, keys.len), unknown[0].known.len);

    try std.testing.expectEqualStrings("contxt", unknown[1].name);
    try std.testing.expectEqualStrings("statusLine", unknown[1].parent.?);
    try std.testing.expectEqual(@as(usize, 3), unknown[1].known.len);

    try std.testing.expectEqualStrings("efort", unknown[2].name);
    try std.testing.expectEqualStrings("/w", unknown[2].workspace.?);

    try std.testing.expectEqualStrings("sesion", unknown[3].name);
    try std.testing.expectEqualStrings("statusLine", unknown[3].parent.?);
    try std.testing.expectEqualStrings("/w", unknown[3].workspace.?);
}

test "a project file is checked at its top level only" {
    const alloc = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        \\{"max_agent_step":5,"model":"m","workspaces":{"/w":{"efort":"low"}}}
    ,
        .{},
    );
    defer parsed.deinit();

    const unknown = try findUnknown(alloc, parsed.value, .project);
    defer alloc.free(unknown);
    try std.testing.expectEqual(@as(usize, 1), unknown.len);
    try std.testing.expectEqualStrings("max_agent_step", unknown[0].name);
}

test "dotted paths name listed keys, fixed children, and paths into maps" {
    for ([_][]const u8{ "fast_mode", "status_line", "status_line.context", "statusLine.context", "models", "models.codex", "providers.local.base_url" }) |path| {
        try std.testing.expect(unknownPart(path) == null);
    }

    const top = unknownPart("fast_mdoe").?;
    try std.testing.expectEqualStrings("fast_mdoe", top.name);
    try std.testing.expect(top.parent == null and top.known.len == keys.len);

    const child = unknownPart("status_line.contxt").?;
    try std.testing.expectEqualStrings("contxt", child.name);
    try std.testing.expectEqualStrings("status_line", child.parent.?);
    try std.testing.expectEqual(@as(usize, 3), child.known.len);

    const under_value = unknownPart("fast_mode.on").?;
    try std.testing.expectEqualStrings("on", under_value.name);
    try std.testing.expectEqual(@as(usize, 0), under_value.known.len);

    try std.testing.expect(unknownPart("statusLine.context.x") != null);
    try std.testing.expect(unknownPart("maxxing_mode") != null);
}

test "a non-object file has no unknown keys" {
    const unknown = try findUnknown(std.testing.allocator, .{ .integer = 3 }, .profile);
    defer std.testing.allocator.free(unknown);
    try std.testing.expectEqual(@as(usize, 0), unknown.len);
}
