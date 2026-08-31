const std = @import("std");
const context_limits = @import("context_limits.zig");
const io_mod = @import("../shared/io.zig");
const model_provider = @import("model_provider.zig");
const settings_store = @import("settings_store.zig");
const types = @import("../shared/types.zig");
const tool_result_limits = @import("../tooling/tool_result_limits.zig");
const workspace_access = @import("../workspace/workspace_access.zig");

const Allocator = std.mem.Allocator;

pub const schema_version: u32 = 1;
pub const max_config_file_bytes: usize = 64 * 1024;
pub const max_system_prompt_parts: usize = 16;
pub const max_system_prompt_part_bytes: usize = 64 * 1024;
pub const max_system_prompt_total_bytes: usize = 128 * 1024;
const max_integer_json = std.fmt.comptimePrint("{d}", .{std.math.maxInt(usize)});
const max_model_bytes_json = std.fmt.comptimePrint("{d}", .{settings_store.max_model_bytes});
const max_prompt_part_bytes_json = std.fmt.comptimePrint("{d}", .{max_system_prompt_part_bytes});
const max_path_bytes_json = std.fmt.comptimePrint("{d}", .{std.fs.max_path_bytes});
const model_json_schema =
    "{\"type\":\"string\",\"minLength\":1,\"maxLength\":" ++ max_model_bytes_json ++
    ",\"pattern\":\"^[^\\\\u0000-\\\\u0020\\\\u007F](?:[^\\\\u0000-\\\\u001F\\\\u007F]*[^\\\\u0000-\\\\u0020\\\\u007F])?$\",\"x-fx-max-utf8-bytes\":" ++ max_model_bytes_json ++ "}";
const inline_text_json_schema =
    "{\"type\":\"string\",\"maxLength\":" ++ max_prompt_part_bytes_json ++
    ",\"pattern\":\"^[^\\\\u0000]*$\",\"x-fx-max-utf8-bytes\":" ++ max_prompt_part_bytes_json ++ "}";
const path_json_schema =
    "{\"type\":\"string\",\"minLength\":1,\"pattern\":\"^[^\\\\u0000]+$\",\"x-fx-max-utf8-bytes\":" ++ max_path_bytes_json ++ "}";

pub const json_schema =
    "{\"$schema\":\"https://json-schema.org/draft/2020-12/schema\",\"$id\":\"https://fx.sh/schema/launch-config-v1.json\",\"title\":\"fx launch configuration\",\"$comment\":\"x-fx-max-utf8-bytes is a required fx annotation because standard maxLength counts Unicode characters, not encoded bytes.\",\"type\":\"object\",\"additionalProperties\":false,\"required\":[\"schema_version\"],\"$defs\":{\"contextLimit\":{\"oneOf\":[{\"type\":\"integer\",\"minimum\":0,\"maximum\":" ++ max_integer_json ++ "},{\"const\":\"off\"}]}},\"properties\":{" ++
    "\"schema_version\":{\"const\":1}," ++
    "\"agent\":{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{" ++
    "\"provider\":{\"enum\":[\"gateway\",\"codex\",\"grok\"]},\"model\":" ++ model_json_schema ++ ",\"effort\":{\"type\":\"string\",\"minLength\":1,\"maxLength\":64,\"pattern\":\"^[A-Za-z0-9._-]+$\"},\"fast_mode\":{\"type\":\"boolean\"},\"max_steps\":{\"type\":\"integer\",\"minimum\":0,\"maximum\":" ++ max_integer_json ++ "},\"first_call_tool_choice\":{\"enum\":[\"auto\",\"none\",\"required\"]},\"enabled_tools\":{\"type\":\"array\",\"uniqueItems\":true,\"items\":{\"type\":\"string\",\"minLength\":1,\"pattern\":\"^[^\\\\u0000]+$\"}}}}," ++
    "\"prompt\":{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{\"system_parts\":{\"type\":\"array\",\"maxItems\":16,\"items\":{\"oneOf\":[" ++
    "{\"type\":\"object\",\"additionalProperties\":false,\"required\":[\"type\",\"id\"],\"properties\":{\"type\":{\"const\":\"builtin\"},\"id\":{\"const\":\"default\"}}}," ++
    "{\"type\":\"object\",\"additionalProperties\":false,\"required\":[\"type\",\"text\"],\"properties\":{\"type\":{\"const\":\"inline\"},\"text\":" ++ inline_text_json_schema ++ "}}," ++
    "{\"type\":\"object\",\"additionalProperties\":false,\"required\":[\"type\",\"path\"],\"properties\":{\"type\":{\"const\":\"file\"},\"path\":" ++ path_json_schema ++ "}}]}}}}," ++
    "\"runtime\":{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{\"permission_mode\":{\"enum\":[\"ask\",\"auto\",\"yolo\"]},\"max_tool_result_bytes\":{\"type\":\"integer\",\"minimum\":1024,\"maximum\":" ++ max_integer_json ++ "},\"context_enabled\":{\"type\":\"boolean\"},\"context_limits\":{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{" ++
    "\"skill_description_bytes\":{\"$ref\":\"#/$defs/contextLimit\"},\"skill_catalog_bytes\":{\"$ref\":\"#/$defs/contextLimit\"},\"skill_chunk_bytes\":{\"$ref\":\"#/$defs/contextLimit\"},\"skill_file_bytes\":{\"$ref\":\"#/$defs/contextLimit\"},\"mcp_description_bytes\":{\"$ref\":\"#/$defs/contextLimit\"},\"mcp_search_result_bytes\":{\"$ref\":\"#/$defs/contextLimit\"},\"mcp_server_instructions_bytes\":{\"$ref\":\"#/$defs/contextLimit\"},\"mcp_selected_schema_bytes\":{\"$ref\":\"#/$defs/contextLimit\"},\"project_instruction_file_bytes\":{\"$ref\":\"#/$defs/contextLimit\"},\"project_instructions_total_bytes\":{\"$ref\":\"#/$defs/contextLimit\"},\"image_adapter_output_bytes\":{\"$ref\":\"#/$defs/contextLimit\"}}},\"additional_directories\":{\"type\":\"array\",\"maxItems\":16,\"uniqueItems\":true,\"items\":" ++ path_json_schema ++ "}}}}}\n";

pub const InputSource = union(enum) {
    regular_file: []const u8,
    non_file,
};

pub const FilePart = struct {
    path: []u8,
    content: []u8,
};

pub const SystemPart = union(enum) {
    builtin,
    @"inline": []u8,
    file: FilePart,

    pub fn deinit(self: *SystemPart, alloc: Allocator) void {
        switch (self.*) {
            .builtin => {},
            .@"inline" => |text| alloc.free(text),
            .file => |part| {
                alloc.free(part.path);
                alloc.free(part.content);
            },
        }
        self.* = undefined;
    }
};

pub const ParsedDocument = struct {
    provider: ?model_provider.ProviderId = null,
    model: ?[]u8 = null,
    effort: ?types.ReasoningEffort = null,
    fast_mode: ?bool = null,
    max_steps: ?usize = null,
    first_call_tool_choice: ?types.ToolChoice = null,
    enabled_tools: ?[][]u8 = null,
    system_parts: ?[]SystemPart = null,
    permission_mode: ?types.PermissionMode = null,
    max_tool_result_bytes: ?usize = null,
    context_enabled: ?bool = null,
    context_limit_overrides: ?context_limits.Overrides = null,
    additional_directories: ?[][]u8 = null,

    pub fn deinit(self: *ParsedDocument, alloc: Allocator) void {
        if (self.model) |model| alloc.free(model);
        if (self.enabled_tools) |names| freeStrings(alloc, names);
        if (self.system_parts) |parts| {
            for (parts) |*part| part.deinit(alloc);
            alloc.free(parts);
        }
        if (self.additional_directories) |paths| freeStrings(alloc, paths);
        self.* = undefined;
    }

    pub fn validateEnabledTools(
        self: *const ParsedDocument,
        available_tool_names: []const []const u8,
    ) !void {
        const selected = self.enabled_tools orelse return;
        for (selected) |name| {
            if (!containsName(available_tool_names, name)) {
                return error.ToolCapabilityUnavailable;
            }
        }
    }

    pub fn validateSystemPromptTotal(
        self: *const ParsedDocument,
        builtin_prompt: []const u8,
    ) !void {
        const parts = self.system_parts orelse return;
        var total: usize = 0;
        for (parts) |part| {
            const part_len = switch (part) {
                .builtin => builtin_prompt.len,
                .@"inline" => |text| text.len,
                .file => |file| file.content.len,
            };
            total = std.math.add(usize, total, part_len) catch
                return error.SystemPromptTooLarge;
            if (total > max_system_prompt_total_bytes) return error.SystemPromptTooLarge;
        }
    }
};

pub const Field = enum(u8) {
    provider,
    model,
    effort,
    fast_mode,
    max_steps,
    first_call_tool_choice,
    enabled_tools,
    system_parts,
    permission_mode,
    max_tool_result_bytes,
    context_enabled,
    context_limits,
    additional_directories,

    pub fn jsonPointer(self: Field) []const u8 {
        return switch (self) {
            .provider => "/agent/provider",
            .model => "/agent/model",
            .effort => "/agent/effort",
            .fast_mode => "/agent/fast_mode",
            .max_steps => "/agent/max_steps",
            .first_call_tool_choice => "/agent/first_call_tool_choice",
            .enabled_tools => "/agent/enabled_tools",
            .system_parts => "/prompt/system_parts",
            .permission_mode => "/runtime/permission_mode",
            .max_tool_result_bytes => "/runtime/max_tool_result_bytes",
            .context_enabled => "/runtime/context_enabled",
            .context_limits => "/runtime/context_limits",
            .additional_directories => "/runtime/additional_directories",
        };
    }

    pub fn dottedName(self: Field) []const u8 {
        return switch (self) {
            .provider => "agent.provider",
            .model => "agent.model",
            .effort => "agent.effort",
            .fast_mode => "agent.fast_mode",
            .max_steps => "agent.max_steps",
            .first_call_tool_choice => "agent.first_call_tool_choice",
            .enabled_tools => "agent.enabled_tools",
            .system_parts => "prompt.system_parts",
            .permission_mode => "runtime.permission_mode",
            .max_tool_result_bytes => "runtime.max_tool_result_bytes",
            .context_enabled => "runtime.context_enabled",
            .context_limits => "runtime.context_limits",
            .additional_directories => "runtime.additional_directories",
        };
    }
};

pub const field_count = std.meta.fields(Field).len;

pub const FieldMask = struct {
    bits: u16 = 0,

    pub fn set(self: *FieldMask, field: Field) void {
        self.bits |= @as(u16, 1) << @as(u4, @intCast(@intFromEnum(field)));
    }

    pub fn contains(self: FieldMask, field: Field) bool {
        return self.bits & (@as(u16, 1) << @as(u4, @intCast(@intFromEnum(field)))) != 0;
    }
};

pub const Source = union(enum) {
    compiled_default,
    project_file,
    profile_global,
    profile_workspace,
    explicit_file: struct {
        path: []const u8,
        layer: usize,
    },
    stdin,
    environment: struct {
        name: []const u8,
    },
    command: struct {
        argument_index: usize,
    },

    pub fn clone(self: Source, alloc: Allocator) !Source {
        return switch (self) {
            .compiled_default => .compiled_default,
            .project_file => .project_file,
            .profile_global => .profile_global,
            .profile_workspace => .profile_workspace,
            .explicit_file => |value| .{ .explicit_file = .{
                .path = try alloc.dupe(u8, value.path),
                .layer = value.layer,
            } },
            .stdin => .stdin,
            .environment => |value| .{ .environment = .{
                .name = try alloc.dupe(u8, value.name),
            } },
            .command => |value| .{ .command = value },
        };
    }

    pub fn deinit(self: *Source, alloc: Allocator) void {
        switch (self.*) {
            .explicit_file => |value| alloc.free(value.path),
            .environment => |value| alloc.free(value.name),
            else => {},
        }
        self.* = .compiled_default;
    }
};

pub const OwnedLaunchPolicy = struct {
    explicit_fields: FieldMask = .{},
    sources: [field_count]Source = [_]Source{.compiled_default} ** field_count,
    system_parts: ?[]SystemPart = null,
    system_prompt: ?[]u8 = null,
    enabled_tools: ?[][]u8 = null,

    pub fn deinit(self: *OwnedLaunchPolicy, alloc: Allocator) void {
        for (&self.sources) |*item| item.deinit(alloc);
        if (self.system_parts) |parts| {
            for (parts) |*part| part.deinit(alloc);
            alloc.free(parts);
        }
        if (self.system_prompt) |text| alloc.free(text);
        if (self.enabled_tools) |names| freeStrings(alloc, names);
        self.* = .{};
    }

    pub fn take(self: *OwnedLaunchPolicy) OwnedLaunchPolicy {
        const value = self.*;
        self.* = .{};
        return value;
    }

    pub fn source(self: *const OwnedLaunchPolicy, field: Field) Source {
        return self.sources[@intFromEnum(field)];
    }

    pub fn setSource(
        self: *OwnedLaunchPolicy,
        alloc: Allocator,
        field: Field,
        source_value: Source,
        explicit: bool,
    ) !void {
        const index = @intFromEnum(field);
        var replacement = try source_value.clone(alloc);
        errdefer replacement.deinit(alloc);
        self.sources[index].deinit(alloc);
        self.sources[index] = replacement;
        if (explicit) self.explicit_fields.set(field);
    }

    pub fn composeSystemPrompt(
        self: *OwnedLaunchPolicy,
        alloc: Allocator,
        builtin_prompt: []const u8,
    ) !void {
        const parts = self.system_parts orelse return;
        if (self.system_prompt != null) return;
        var output: std.Io.Writer.Allocating = .init(alloc);
        defer output.deinit();
        for (parts) |part| {
            const text = switch (part) {
                .builtin => builtin_prompt,
                .@"inline" => |value| value,
                .file => |value| value.content,
            };
            const next_len = std.math.add(usize, output.written().len, text.len) catch
                return error.SystemPromptTooLarge;
            if (next_len > max_system_prompt_total_bytes) return error.SystemPromptTooLarge;
            output.writer.writeAll(text) catch return error.OutOfMemory;
        }
        const composed = try output.toOwnedSlice();
        if (self.system_prompt) |old| alloc.free(old);
        self.system_prompt = composed;
    }
};

fn containsName(names: []const []const u8, target: []const u8) bool {
    for (names) |name| {
        if (std.mem.eql(u8, name, target)) return true;
    }
    return false;
}

const RawDocument = struct {
    schema_version: u32,
    agent: ?RawAgent = null,
    prompt: ?RawPrompt = null,
    runtime: ?RawRuntime = null,
};

const RawAgent = struct {
    provider: ?[]const u8 = null,
    model: ?[]const u8 = null,
    effort: ?[]const u8 = null,
    fast_mode: ?bool = null,
    max_steps: ?usize = null,
    first_call_tool_choice: ?[]const u8 = null,
    enabled_tools: ?[]const []const u8 = null,
};

const RawPrompt = struct {
    system_parts: ?[]const RawSystemPart = null,
};

const RawSystemPart = struct {
    type: []const u8,
    id: ?[]const u8 = null,
    path: ?[]const u8 = null,
    text: ?[]const u8 = null,
};

const RawRuntime = struct {
    permission_mode: ?[]const u8 = null,
    max_tool_result_bytes: ?usize = null,
    context_enabled: ?bool = null,
    context_limits: ?RawContextLimits = null,
    additional_directories: ?[]const []const u8 = null,
};

const RawContextLimits = struct {
    skill_description_bytes: ?std.json.Value = null,
    skill_catalog_bytes: ?std.json.Value = null,
    skill_chunk_bytes: ?std.json.Value = null,
    skill_file_bytes: ?std.json.Value = null,
    mcp_description_bytes: ?std.json.Value = null,
    mcp_search_result_bytes: ?std.json.Value = null,
    mcp_server_instructions_bytes: ?std.json.Value = null,
    mcp_selected_schema_bytes: ?std.json.Value = null,
    project_instruction_file_bytes: ?std.json.Value = null,
    project_instructions_total_bytes: ?std.json.Value = null,
    image_adapter_output_bytes: ?std.json.Value = null,
};

const max_validation_diagnostics: usize = 64;

pub const DiagnosticCode = enum {
    invalid_json,
    unsupported_schema_version,
    unknown_field,
    duplicate_field,
    invalid_type,
    invalid_value,
    too_large,

    pub fn message(self: DiagnosticCode) []const u8 {
        return switch (self) {
            .invalid_json => "Invalid JSON document",
            .unsupported_schema_version => "Unsupported schema version",
            .unknown_field => "Unknown configuration field",
            .duplicate_field => "Duplicate configuration field",
            .invalid_type => "Value has an invalid type",
            .invalid_value => "Value does not satisfy the field contract",
            .too_large => "Value exceeds a configured limit",
        };
    }
};

pub const ValidationDiagnostic = struct {
    instance_location: []u8,
    code: DiagnosticCode,

    fn deinit(self: *ValidationDiagnostic, alloc: Allocator) void {
        alloc.free(self.instance_location);
        self.* = undefined;
    }
};

pub const ValidationDiagnostics = struct {
    items: []ValidationDiagnostic = &.{},
    truncated: bool = false,

    pub fn deinit(self: *ValidationDiagnostics, alloc: Allocator) void {
        if (self.items.len > 0) {
            for (self.items) |*item| item.deinit(alloc);
            alloc.free(self.items);
        }
        self.* = .{};
    }
};

const ValidationCollector = struct {
    alloc: Allocator,
    items: std.ArrayList(ValidationDiagnostic) = .empty,

    fn deinit(self: *ValidationCollector) void {
        for (self.items.items) |*item| item.deinit(self.alloc);
        self.items.deinit(self.alloc);
        self.* = undefined;
    }

    fn add(self: *ValidationCollector, instance_location: []const u8, code: DiagnosticCode) !void {
        const owned_location = try self.alloc.dupe(u8, instance_location);
        errdefer self.alloc.free(owned_location);
        try self.items.append(self.alloc, .{
            .instance_location = owned_location,
            .code = code,
        });
    }

    fn finish(self: *ValidationCollector) !ValidationDiagnostics {
        std.mem.sort(ValidationDiagnostic, self.items.items, {}, validationDiagnosticLessThan);
        var unique_count: usize = 0;
        for (self.items.items) |item| {
            if (unique_count > 0) {
                const prior = self.items.items[unique_count - 1];
                if (prior.code == item.code and
                    std.mem.eql(u8, prior.instance_location, item.instance_location))
                {
                    var duplicate = item;
                    duplicate.deinit(self.alloc);
                    continue;
                }
            }
            self.items.items[unique_count] = item;
            unique_count += 1;
        }
        self.items.items.len = unique_count;
        const all = try self.items.toOwnedSlice(self.alloc);
        self.items = .empty;
        if (all.len <= max_validation_diagnostics) return .{ .items = all };

        errdefer {
            for (all) |*item| item.deinit(self.alloc);
            self.alloc.free(all);
        }
        const kept = try self.alloc.alloc(ValidationDiagnostic, max_validation_diagnostics);
        @memcpy(kept, all[0..max_validation_diagnostics]);
        for (all[max_validation_diagnostics..]) |*item| item.deinit(self.alloc);
        self.alloc.free(all);
        return .{ .items = kept, .truncated = true };
    }
};

fn validationDiagnosticLessThan(_: void, lhs: ValidationDiagnostic, rhs: ValidationDiagnostic) bool {
    return switch (std.mem.order(u8, lhs.instance_location, rhs.instance_location)) {
        .lt => true,
        .gt => false,
        .eq => @intFromEnum(lhs.code) < @intFromEnum(rhs.code),
    };
}

fn pointerForKey(alloc: Allocator, parent: []const u8, key: []const u8) Allocator.Error![]u8 {
    var escaped_key_len = key.len;
    for (key) |byte| {
        if (byte == '~' or byte == '/') escaped_key_len += 1;
    }
    const output = try alloc.alloc(u8, parent.len + 1 + escaped_key_len);
    @memcpy(output[0..parent.len], parent);
    output[parent.len] = '/';
    var index = parent.len + 1;
    for (key) |byte| switch (byte) {
        '~' => {
            @memcpy(output[index..][0..2], "~0");
            index += 2;
        },
        '/' => {
            @memcpy(output[index..][0..2], "~1");
            index += 2;
        },
        else => {
            output[index] = byte;
            index += 1;
        },
    };
    return output;
}

fn pointerForDottedName(alloc: Allocator, name: []const u8) Allocator.Error![]u8 {
    var output_len = std.math.add(usize, name.len, 1) catch return error.OutOfMemory;
    for (name) |byte| {
        if (byte == '~' or byte == '/') {
            output_len = std.math.add(usize, output_len, 1) catch return error.OutOfMemory;
        }
    }
    const output = try alloc.alloc(u8, output_len);
    output[0] = '/';
    var index: usize = 1;
    for (name) |byte| switch (byte) {
        '.' => {
            output[index] = '/';
            index += 1;
        },
        '~' => {
            @memcpy(output[index..][0..2], "~0");
            index += 2;
        },
        '/' => {
            @memcpy(output[index..][0..2], "~1");
            index += 2;
        },
        else => {
            output[index] = byte;
            index += 1;
        },
    };
    return output;
}

fn pointerForIndex(alloc: Allocator, parent: []const u8, index: usize) Allocator.Error![]u8 {
    var digit_count: usize = 1;
    var remaining = index;
    while (remaining >= 10) : (digit_count += 1) remaining /= 10;
    const output = try alloc.alloc(u8, parent.len + 1 + digit_count);
    @memcpy(output[0..parent.len], parent);
    output[parent.len] = '/';
    remaining = index;
    var cursor = output.len;
    while (cursor > parent.len + 1) {
        cursor -= 1;
        output[cursor] = '0' + @as(u8, @intCast(remaining % 10));
        remaining /= 10;
    }
    return output;
}

fn collectUnknownFields(
    collector: *ValidationCollector,
    object: std.json.ObjectMap,
    parent: []const u8,
    allowed: []const []const u8,
) !void {
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        if (containsName(allowed, entry.key_ptr.*)) continue;
        const location = try pointerForKey(collector.alloc, parent, entry.key_ptr.*);
        defer collector.alloc.free(location);
        try collector.add(location, .unknown_field);
    }
}

fn collectInteger(
    collector: *ValidationCollector,
    value: std.json.Value,
    location: []const u8,
    minimum: usize,
) !void {
    switch (value) {
        .integer => |integer| {
            const converted = std.math.cast(usize, integer) orelse {
                try collector.add(location, .invalid_value);
                return;
            };
            if (converted < minimum) try collector.add(location, .invalid_value);
        },
        .number_string => |text| {
            const converted = std.fmt.parseInt(usize, text, 10) catch {
                try collector.add(location, .invalid_value);
                return;
            };
            if (converted < minimum) try collector.add(location, .invalid_value);
        },
        else => try collector.add(location, .invalid_type),
    }
}

const DuplicateScanError = std.json.Scanner.AllocError;

fn findFirstDuplicatePointer(alloc: Allocator, bytes: []const u8) DuplicateScanError!?[]u8 {
    var scanner = std.json.Scanner.initCompleteInput(alloc, bytes);
    defer scanner.deinit();
    const first = try scanner.nextAllocMax(alloc, .alloc_always, max_config_file_bytes);
    return findDuplicateInValue(alloc, &scanner, first, "");
}

fn findDuplicateInValue(
    alloc: Allocator,
    scanner: *std.json.Scanner,
    token: std.json.Token,
    location: []const u8,
) DuplicateScanError!?[]u8 {
    return switch (token) {
        .object_begin => findDuplicateInObject(alloc, scanner, location),
        .array_begin => findDuplicateInArray(alloc, scanner, location),
        .allocated_number, .allocated_string => |bytes| blk: {
            alloc.free(bytes);
            break :blk null;
        },
        .number, .string, .true, .false, .null => null,
        else => unreachable,
    };
}

fn findDuplicateInObject(
    alloc: Allocator,
    scanner: *std.json.Scanner,
    location: []const u8,
) DuplicateScanError!?[]u8 {
    var keys: std.ArrayList([]u8) = .empty;
    defer {
        for (keys.items) |key| alloc.free(key);
        keys.deinit(alloc);
    }
    while (true) {
        const key_token = try scanner.nextAllocMax(alloc, .alloc_always, max_config_file_bytes);
        const key = switch (key_token) {
            .object_end => return null,
            .allocated_string => |value| value,
            else => unreachable,
        };
        for (keys.items) |prior| {
            if (!std.mem.eql(u8, key, prior)) continue;
            defer alloc.free(key);
            return @as(?[]u8, try pointerForKey(alloc, location, key));
        }
        errdefer alloc.free(key);
        try keys.append(alloc, key);

        const child_location = try pointerForKey(alloc, location, key);
        defer alloc.free(child_location);
        const value_token = try scanner.nextAllocMax(alloc, .alloc_always, max_config_file_bytes);
        if (try findDuplicateInValue(alloc, scanner, value_token, child_location)) |duplicate| {
            return duplicate;
        }
    }
}

fn findDuplicateInArray(
    alloc: Allocator,
    scanner: *std.json.Scanner,
    location: []const u8,
) DuplicateScanError!?[]u8 {
    var index: usize = 0;
    while (true) : (index += 1) {
        const token = try scanner.nextAllocMax(alloc, .alloc_always, max_config_file_bytes);
        if (token == .array_end) return null;
        const child_location = try pointerForIndex(alloc, location, index);
        defer alloc.free(child_location);
        if (try findDuplicateInValue(alloc, scanner, token, child_location)) |duplicate| {
            return duplicate;
        }
    }
}

/// Returns owned diagnostics. The caller deinitializes the result with `alloc`.
pub fn collectValidationDiagnostics(
    alloc: Allocator,
    bytes: []const u8,
) Allocator.Error!ValidationDiagnostics {
    var collector = ValidationCollector{ .alloc = alloc };
    defer collector.deinit();
    if (bytes.len > max_config_file_bytes) {
        try collector.add("", .too_large);
        return collector.finish();
    }

    var parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{
        .duplicate_field_behavior = .@"error",
    }) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        if (err == error.DuplicateField) {
            const location = findFirstDuplicatePointer(alloc, bytes) catch |scan_error| switch (scan_error) {
                error.OutOfMemory => return error.OutOfMemory,
                else => null,
            };
            defer if (location) |owned| alloc.free(owned);
            try collector.add(location orelse "", .duplicate_field);
        } else {
            try collector.add("", .invalid_json);
        }
        return collector.finish();
    };
    defer parsed.deinit();
    try collectRootDiagnostics(&collector, parsed.value);
    return collector.finish();
}

fn collectRootDiagnostics(collector: *ValidationCollector, value: std.json.Value) !void {
    const object = switch (value) {
        .object => |object| object,
        else => {
            try collector.add("", .invalid_type);
            return;
        },
    };
    try collectUnknownFields(collector, object, "", &.{ "schema_version", "agent", "prompt", "runtime" });
    if (object.get("schema_version")) |version| {
        switch (version) {
            .integer => |integer| if (integer != schema_version) {
                try collector.add("/schema_version", .unsupported_schema_version);
            },
            else => try collector.add("/schema_version", .invalid_type),
        }
    } else {
        try collector.add("/schema_version", .invalid_value);
    }
    if (object.get("agent")) |agent| try collectAgentDiagnostics(collector, agent);
    if (object.get("prompt")) |prompt| try collectPromptDiagnostics(collector, prompt);
    if (object.get("runtime")) |runtime| try collectRuntimeDiagnostics(collector, runtime);
}

fn collectAgentDiagnostics(collector: *ValidationCollector, value: std.json.Value) !void {
    const object = switch (value) {
        .object => |object| object,
        else => {
            try collector.add("/agent", .invalid_type);
            return;
        },
    };
    try collectUnknownFields(collector, object, "/agent", &.{
        "provider",
        "model",
        "effort",
        "fast_mode",
        "max_steps",
        "first_call_tool_choice",
        "enabled_tools",
    });
    if (object.get("provider")) |provider| switch (provider) {
        .string => |text| if (std.meta.stringToEnum(model_provider.ProviderId, text) == null) {
            try collector.add("/agent/provider", .invalid_value);
        },
        else => try collector.add("/agent/provider", .invalid_type),
    };
    if (object.get("model")) |model| switch (model) {
        .string => |text| settings_store.validateModel(text) catch
            try collector.add("/agent/model", .invalid_value),
        else => try collector.add("/agent/model", .invalid_type),
    };
    if (object.get("effort")) |effort| switch (effort) {
        .string => |text| if (types.ReasoningEffort.parse(text) == null) {
            try collector.add("/agent/effort", .invalid_value);
        },
        else => try collector.add("/agent/effort", .invalid_type),
    };
    if (object.get("fast_mode")) |fast_mode| if (fast_mode != .bool) {
        try collector.add("/agent/fast_mode", .invalid_type);
    };
    if (object.get("max_steps")) |max_steps| {
        try collectInteger(collector, max_steps, "/agent/max_steps", 0);
    }
    if (object.get("first_call_tool_choice")) |choice| switch (choice) {
        .string => |text| if (std.meta.stringToEnum(types.ToolChoice, text) == null) {
            try collector.add("/agent/first_call_tool_choice", .invalid_value);
        },
        else => try collector.add("/agent/first_call_tool_choice", .invalid_type),
    };
    if (object.get("enabled_tools")) |enabled_tools| {
        try collectUniqueStringArrayDiagnostics(
            collector,
            enabled_tools,
            "/agent/enabled_tools",
            null,
        );
        if (enabled_tools == .array) {
            for (enabled_tools.array.items, 0..) |tool, index| switch (tool) {
                .string => |text| if (text.len == 0 or std.mem.findScalar(u8, text, 0) != null) {
                    const location = try pointerForIndex(
                        collector.alloc,
                        "/agent/enabled_tools",
                        index,
                    );
                    defer collector.alloc.free(location);
                    try collector.add(location, .invalid_value);
                },
                else => {},
            };
        }
    }
}

fn collectUniqueStringArrayDiagnostics(
    collector: *ValidationCollector,
    value: std.json.Value,
    location: []const u8,
    max_items: ?usize,
) !void {
    const array = switch (value) {
        .array => |array| array,
        else => {
            try collector.add(location, .invalid_type);
            return;
        },
    };
    if (max_items) |limit| if (array.items.len > limit) {
        try collector.add(location, .too_large);
    };
    for (array.items, 0..) |item, index| {
        const item_location = try pointerForIndex(collector.alloc, location, index);
        defer collector.alloc.free(item_location);
        const text = switch (item) {
            .string => |text| text,
            else => {
                try collector.add(item_location, .invalid_type);
                continue;
            },
        };
        for (array.items[0..index]) |prior| switch (prior) {
            .string => |prior_text| if (std.mem.eql(u8, text, prior_text)) {
                try collector.add(item_location, .invalid_value);
                break;
            },
            else => {},
        };
    }
}

fn collectPromptDiagnostics(collector: *ValidationCollector, value: std.json.Value) !void {
    const object = switch (value) {
        .object => |object| object,
        else => {
            try collector.add("/prompt", .invalid_type);
            return;
        },
    };
    try collectUnknownFields(collector, object, "/prompt", &.{"system_parts"});
    const system_parts = object.get("system_parts") orelse return;
    const array = switch (system_parts) {
        .array => |array| array,
        else => {
            try collector.add("/prompt/system_parts", .invalid_type);
            return;
        },
    };
    if (array.items.len > max_system_prompt_parts) {
        try collector.add("/prompt/system_parts", .too_large);
    }
    for (array.items, 0..) |part, index| {
        const location = try pointerForIndex(collector.alloc, "/prompt/system_parts", index);
        defer collector.alloc.free(location);
        try collectSystemPartDiagnostics(collector, part, location);
    }
}

fn collectSystemPartDiagnostics(
    collector: *ValidationCollector,
    value: std.json.Value,
    location: []const u8,
) !void {
    const object = switch (value) {
        .object => |object| object,
        else => {
            try collector.add(location, .invalid_type);
            return;
        },
    };
    try collectUnknownFields(collector, object, location, &.{ "type", "id", "path", "text" });
    const type_location = try pointerForKey(collector.alloc, location, "type");
    defer collector.alloc.free(type_location);
    const type_value = object.get("type") orelse {
        try collector.add(type_location, .invalid_value);
        return;
    };
    const part_type = switch (type_value) {
        .string => |text| text,
        else => {
            try collector.add(type_location, .invalid_type);
            return;
        },
    };

    if (std.mem.eql(u8, part_type, "builtin")) {
        try collectRequiredStringValue(collector, object, location, "id", "default");
        try collectForbiddenFields(collector, object, location, &.{ "path", "text" });
        return;
    }
    if (std.mem.eql(u8, part_type, "inline")) {
        try collectRequiredPromptText(collector, object, location);
        try collectForbiddenFields(collector, object, location, &.{ "id", "path" });
        return;
    }
    if (std.mem.eql(u8, part_type, "file")) {
        try collectRequiredPath(collector, object, location);
        try collectForbiddenFields(collector, object, location, &.{ "id", "text" });
        return;
    }
    try collector.add(type_location, .invalid_value);
}

fn collectRequiredStringValue(
    collector: *ValidationCollector,
    object: std.json.ObjectMap,
    parent: []const u8,
    field: []const u8,
    expected: []const u8,
) !void {
    const location = try pointerForKey(collector.alloc, parent, field);
    defer collector.alloc.free(location);
    const value = object.get(field) orelse {
        try collector.add(location, .invalid_value);
        return;
    };
    switch (value) {
        .string => |text| if (!std.mem.eql(u8, text, expected)) {
            try collector.add(location, .invalid_value);
        },
        else => try collector.add(location, .invalid_type),
    }
}

fn collectRequiredPromptText(
    collector: *ValidationCollector,
    object: std.json.ObjectMap,
    parent: []const u8,
) !void {
    const location = try pointerForKey(collector.alloc, parent, "text");
    defer collector.alloc.free(location);
    const value = object.get("text") orelse {
        try collector.add(location, .invalid_value);
        return;
    };
    switch (value) {
        .string => |text| validatePromptText(text) catch |err| try collector.add(
            location,
            if (err == error.SystemPromptPartTooLarge) .too_large else .invalid_value,
        ),
        else => try collector.add(location, .invalid_type),
    }
}

fn collectRequiredPath(
    collector: *ValidationCollector,
    object: std.json.ObjectMap,
    parent: []const u8,
) !void {
    const location = try pointerForKey(collector.alloc, parent, "path");
    defer collector.alloc.free(location);
    const value = object.get("path") orelse {
        try collector.add(location, .invalid_value);
        return;
    };
    switch (value) {
        .string => |path| if (!validPathText(path)) try collector.add(location, .invalid_value),
        else => try collector.add(location, .invalid_type),
    }
}

fn collectForbiddenFields(
    collector: *ValidationCollector,
    object: std.json.ObjectMap,
    parent: []const u8,
    fields: []const []const u8,
) !void {
    for (fields) |field| {
        if (object.get(field) == null) continue;
        const location = try pointerForKey(collector.alloc, parent, field);
        defer collector.alloc.free(location);
        try collector.add(location, .invalid_value);
    }
}

fn collectRuntimeDiagnostics(collector: *ValidationCollector, value: std.json.Value) !void {
    const object = switch (value) {
        .object => |object| object,
        else => {
            try collector.add("/runtime", .invalid_type);
            return;
        },
    };
    try collectUnknownFields(collector, object, "/runtime", &.{
        "permission_mode",
        "max_tool_result_bytes",
        "context_enabled",
        "context_limits",
        "additional_directories",
    });
    if (object.get("permission_mode")) |permission_mode| switch (permission_mode) {
        .string => |text| if (std.meta.stringToEnum(types.PermissionMode, text) == null) {
            try collector.add("/runtime/permission_mode", .invalid_value);
        },
        else => try collector.add("/runtime/permission_mode", .invalid_type),
    };
    if (object.get("max_tool_result_bytes")) |max_tool_result_bytes| {
        try collectInteger(
            collector,
            max_tool_result_bytes,
            "/runtime/max_tool_result_bytes",
            tool_result_limits.min_configured_tool_result_bytes,
        );
    }
    if (object.get("context_enabled")) |context_enabled| if (context_enabled != .bool) {
        try collector.add("/runtime/context_enabled", .invalid_type);
    };
    if (object.get("context_limits")) |limits| try collectContextLimitDiagnostics(collector, limits);
    if (object.get("additional_directories")) |paths| {
        try collectUniqueStringArrayDiagnostics(
            collector,
            paths,
            "/runtime/additional_directories",
            workspace_access.max_additional_directories,
        );
        if (paths == .array) {
            for (paths.array.items, 0..) |path, index| switch (path) {
                .string => |text| if (!validPathText(text)) {
                    const location = try pointerForIndex(
                        collector.alloc,
                        "/runtime/additional_directories",
                        index,
                    );
                    defer collector.alloc.free(location);
                    try collector.add(location, .invalid_value);
                },
                else => {},
            };
        }
    }
}

fn collectContextLimitDiagnostics(collector: *ValidationCollector, value: std.json.Value) !void {
    const object = switch (value) {
        .object => |object| object,
        else => {
            try collector.add("/runtime/context_limits", .invalid_type);
            return;
        },
    };
    try collectUnknownFields(collector, object, "/runtime/context_limits", &.{
        "skill_description_bytes",
        "skill_catalog_bytes",
        "skill_chunk_bytes",
        "skill_file_bytes",
        "mcp_description_bytes",
        "mcp_search_result_bytes",
        "mcp_server_instructions_bytes",
        "mcp_selected_schema_bytes",
        "project_instruction_file_bytes",
        "project_instructions_total_bytes",
        "image_adapter_output_bytes",
    });
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        if (context_limits.Name.parse(entry.key_ptr.*) == null) continue;
        const location = try pointerForKey(
            collector.alloc,
            "/runtime/context_limits",
            entry.key_ptr.*,
        );
        defer collector.alloc.free(location);
        switch (entry.value_ptr.*) {
            .integer => |integer| if (std.math.cast(usize, integer) == null) {
                try collector.add(location, .invalid_value);
            },
            .number_string => |text| if (std.fmt.parseInt(usize, text, 10)) |_| {} else |_| {
                try collector.add(location, .invalid_value);
            },
            .string => |text| if (!std.mem.eql(u8, text, "off")) {
                try collector.add(location, .invalid_value);
            },
            else => try collector.add(location, .invalid_type),
        }
    }
}

pub fn parseDocument(
    alloc: Allocator,
    bytes: []const u8,
    source: InputSource,
) !ParsedDocument {
    if (bytes.len > max_config_file_bytes) return error.ConfigFileTooLarge;
    try rejectNullValues(alloc, bytes);

    var raw = try std.json.parseFromSlice(RawDocument, alloc, bytes, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
        .ignore_unknown_fields = false,
    });
    defer raw.deinit();
    if (raw.value.schema_version != schema_version) return error.UnsupportedSchemaVersion;

    var result = ParsedDocument{};
    errdefer result.deinit(alloc);

    if (raw.value.agent) |agent| try parseAgent(alloc, &result, agent);
    if (raw.value.prompt) |prompt| try parsePrompt(alloc, &result, prompt, source);
    if (raw.value.runtime) |runtime| try parseRuntime(alloc, &result, runtime);
    return result;
}

const OverrideTarget = union(enum) {
    known: Field,
    unknown: []u8,

    fn deinit(self: *OverrideTarget, alloc: Allocator) void {
        switch (self.*) {
            .known => {},
            .unknown => |instance_location| alloc.free(instance_location),
        }
        self.* = undefined;
    }

    fn instanceLocation(self: OverrideTarget) []const u8 {
        return switch (self) {
            .known => |field| field.jsonPointer(),
            .unknown => |instance_location| instance_location,
        };
    }
};

pub const EncodedOverrideDocument = struct {
    bytes: []u8,
    target: OverrideTarget,
    preflight_diagnostic: ?DiagnosticCode = null,

    pub fn deinit(self: *EncodedOverrideDocument, alloc: Allocator) void {
        alloc.free(self.bytes);
        self.target.deinit(alloc);
        self.* = undefined;
    }

    pub fn collectDiagnostics(
        self: EncodedOverrideDocument,
        alloc: Allocator,
    ) Allocator.Error!ValidationDiagnostics {
        if (self.preflight_diagnostic) |code| {
            var collector = ValidationCollector{ .alloc = alloc };
            defer collector.deinit();
            try collector.add(self.target.instanceLocation(), code);
            return collector.finish();
        }
        var diagnostics = try collectValidationDiagnostics(alloc, self.bytes);
        errdefer diagnostics.deinit(alloc);
        for (diagnostics.items) |*diagnostic| {
            if (diagnostic.instance_location.len != 0) continue;
            const replacement = try alloc.dupe(u8, self.target.instanceLocation());
            alloc.free(diagnostic.instance_location);
            diagnostic.instance_location = replacement;
        }
        return diagnostics;
    }
};

pub fn encodeOverrideDocument(
    alloc: Allocator,
    name: []const u8,
    value: []const u8,
) !EncodedOverrideDocument {
    const field = overrideField(name) orelse {
        const instance_location = try pointerForDottedName(alloc, name);
        errdefer alloc.free(instance_location);
        return .{
            .bytes = try alloc.dupe(u8, ""),
            .target = .{ .unknown = instance_location },
            .preflight_diagnostic = .unknown_field,
        };
    };
    if (value.len > max_config_file_bytes) return .{
        .bytes = try alloc.dupe(u8, ""),
        .target = .{ .known = field },
        .preflight_diagnostic = .too_large,
    };
    if (fieldUsesJsonValue(field)) {
        var parsed_value = std.json.parseFromSlice(std.json.Value, alloc, value, .{
            .duplicate_field_behavior = .use_first,
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return .{
                .bytes = try alloc.dupe(u8, ""),
                .target = .{ .known = field },
                .preflight_diagnostic = .invalid_json,
            },
        };
        defer parsed_value.deinit();
    }
    const dotted_name = field.dottedName();
    const separator = std.mem.findScalar(u8, dotted_name, '.') orelse return error.UnknownConfigField;
    var encoded: std.Io.Writer.Allocating = .init(alloc);
    defer encoded.deinit();

    try encoded.writer.print("{{\"schema_version\":1,\"{s}\":{{\"{s}\":", .{
        dotted_name[0..separator],
        dotted_name[separator + 1 ..],
    });
    if (fieldUsesJsonValue(field)) {
        try encoded.writer.writeAll(value);
    } else {
        try std.json.Stringify.value(value, .{}, &encoded.writer);
    }
    try encoded.writer.writeAll("}}");
    return .{
        .bytes = try encoded.toOwnedSlice(),
        .target = .{ .known = field },
    };
}

pub fn parseOverride(alloc: Allocator, name: []const u8, value: []const u8) !ParsedDocument {
    var encoded = try encodeOverrideDocument(alloc, name, value);
    defer encoded.deinit(alloc);
    if (encoded.preflight_diagnostic) |code| return switch (code) {
        .too_large => error.ConfigFileTooLarge,
        .unknown_field => error.UnknownConfigField,
        else => error.SyntaxError,
    };
    return parseDocument(alloc, encoded.bytes, .non_file);
}

fn overrideField(name: []const u8) ?Field {
    inline for (std.meta.tags(Field)) |field| {
        if (std.mem.eql(u8, name, field.dottedName())) return field;
    }
    return null;
}

fn fieldUsesJsonValue(field: Field) bool {
    return switch (field) {
        .provider,
        .model,
        .effort,
        .first_call_tool_choice,
        .permission_mode,
        => false,
        .fast_mode,
        .max_steps,
        .enabled_tools,
        .system_parts,
        .max_tool_result_bytes,
        .context_enabled,
        .context_limits,
        .additional_directories,
        => true,
    };
}

fn rejectNullValues(alloc: Allocator, bytes: []const u8) !void {
    var scanner = std.json.Scanner.initCompleteInput(alloc, bytes);
    defer scanner.deinit();
    while (true) {
        switch (try scanner.next()) {
            .null => return error.NullUnsupported,
            .end_of_document => return,
            else => {},
        }
    }
}

fn parseAgent(alloc: Allocator, result: *ParsedDocument, raw: RawAgent) !void {
    if (raw.provider) |provider| {
        result.provider = std.meta.stringToEnum(model_provider.ProviderId, provider) orelse
            return error.InvalidProvider;
    }
    if (raw.model) |model| {
        settings_store.validateModel(model) catch return error.InvalidModel;
        result.model = try alloc.dupe(u8, model);
    }
    if (raw.effort) |effort| {
        result.effort = types.ReasoningEffort.parse(effort) orelse return error.InvalidEffort;
    }
    result.fast_mode = raw.fast_mode;
    result.max_steps = raw.max_steps;
    if (raw.first_call_tool_choice) |choice| {
        result.first_call_tool_choice = std.meta.stringToEnum(types.ToolChoice, choice) orelse
            return error.InvalidToolChoice;
    }
    if (raw.enabled_tools) |names| {
        result.enabled_tools = try dupeUniqueNames(alloc, names);
    }
}

fn parsePrompt(
    alloc: Allocator,
    result: *ParsedDocument,
    raw: RawPrompt,
    source: InputSource,
) !void {
    const raw_parts = raw.system_parts orelse return;
    if (raw_parts.len > max_system_prompt_parts) return error.TooManySystemPromptParts;

    const parts = try alloc.alloc(SystemPart, raw_parts.len);
    var initialized: usize = 0;
    errdefer {
        for (parts[0..initialized]) |*part| part.deinit(alloc);
        alloc.free(parts);
    }

    var static_bytes: usize = 0;
    for (raw_parts, 0..) |part, index| {
        parts[index] = try parseSystemPart(alloc, part, source);
        initialized += 1;
        static_bytes = std.math.add(usize, static_bytes, switch (parts[index]) {
            .builtin => 0,
            .@"inline" => |text| text.len,
            .file => |file| file.content.len,
        }) catch return error.SystemPromptTooLarge;
        if (static_bytes > max_system_prompt_total_bytes) return error.SystemPromptTooLarge;
    }
    result.system_parts = parts;
}

fn parseSystemPart(alloc: Allocator, raw: RawSystemPart, source: InputSource) !SystemPart {
    if (std.mem.eql(u8, raw.type, "builtin")) {
        if (raw.id == null or !std.mem.eql(u8, raw.id.?, "default") or
            raw.path != null or raw.text != null)
        {
            return error.InvalidSystemPromptPart;
        }
        return .builtin;
    }
    if (std.mem.eql(u8, raw.type, "inline")) {
        if (raw.text == null or raw.id != null or raw.path != null) {
            return error.InvalidSystemPromptPart;
        }
        try validatePromptText(raw.text.?);
        return .{ .@"inline" = try alloc.dupe(u8, raw.text.?) };
    }
    if (std.mem.eql(u8, raw.type, "file")) {
        if (raw.path == null or raw.id != null or raw.text != null) {
            return error.InvalidSystemPromptPart;
        }
        const declaring_file = switch (source) {
            .regular_file => |path| path,
            .non_file => return error.FilePartRequiresRegularConfigSource,
        };
        const content = try readPromptFile(alloc, declaring_file, raw.path.?);
        errdefer alloc.free(content);
        return .{ .file = .{
            .path = try alloc.dupe(u8, raw.path.?),
            .content = content,
        } };
    }
    return error.InvalidSystemPromptPart;
}

fn readPromptFile(alloc: Allocator, declaring_file: []const u8, raw_path: []const u8) ![]u8 {
    if (!validPathText(raw_path)) return error.UnsafePromptFile;
    const base = std.fs.path.dirname(declaring_file) orelse ".";
    const resolved = try std.fs.path.resolve(alloc, &.{ base, raw_path });
    defer alloc.free(resolved);

    var file = io_mod.openExistingRegularFile(std.Io.Dir.cwd(), resolved, .read_only) catch |err| switch (err) {
        error.FileNotFound => return error.PromptFileMissing,
        else => return error.UnsafePromptFile,
    };
    defer file.close(io_mod.getIo());
    const stat = try file.stat(io_mod.getIo());
    if (stat.kind != .file) return error.UnsafePromptFile;
    if (stat.size > max_system_prompt_part_bytes) return error.SystemPromptPartTooLarge;
    const content = io_mod.readFileToEnd(alloc, &file, max_system_prompt_part_bytes + 1) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.SystemPromptPartTooLarge,
    };
    errdefer alloc.free(content);
    if (content.len > max_system_prompt_part_bytes) return error.SystemPromptPartTooLarge;
    try validatePromptText(content);
    return content;
}

fn validatePromptText(text: []const u8) !void {
    if (text.len > max_system_prompt_part_bytes) return error.SystemPromptPartTooLarge;
    if (!std.unicode.utf8ValidateSlice(text) or std.mem.findScalar(u8, text, 0) != null) {
        return error.InvalidSystemPromptText;
    }
}

fn parseRuntime(alloc: Allocator, result: *ParsedDocument, raw: RawRuntime) !void {
    if (raw.permission_mode) |mode| {
        result.permission_mode = std.meta.stringToEnum(types.PermissionMode, mode) orelse
            return error.InvalidPermissionMode;
    }
    if (raw.max_tool_result_bytes) |value| {
        if (value < tool_result_limits.min_configured_tool_result_bytes) {
            return error.InvalidMaxToolResultBytes;
        }
        result.max_tool_result_bytes = value;
    }
    result.context_enabled = raw.context_enabled;
    if (raw.context_limits) |limits| result.context_limit_overrides = try parseContextLimits(limits);
    if (raw.additional_directories) |paths| {
        if (paths.len > workspace_access.max_additional_directories) return error.TooManyAdditionalDirectories;
        for (paths, 0..) |path, index| {
            if (!validPathText(path)) return error.InvalidAdditionalDirectory;
            for (paths[0..index]) |prior| {
                if (std.mem.eql(u8, path, prior)) return error.DuplicateAdditionalDirectory;
            }
        }
        result.additional_directories = try dupeStrings(alloc, paths);
    }
}

fn parseContextLimits(raw: RawContextLimits) !context_limits.Overrides {
    var result = context_limits.Overrides{};
    inline for (std.meta.fields(RawContextLimits)) |field| {
        if (@field(raw, field.name)) |value| {
            const name = context_limits.Name.parse(field.name) orelse unreachable;
            result.set(name, .{
                .value = try parseContextLimitValue(value),
                .source = .compiled_default,
            });
        }
    }
    return result;
}

fn parseContextLimitValue(value: std.json.Value) !context_limits.Value {
    return switch (value) {
        .integer => |integer| .{
            .bytes = std.math.cast(usize, integer) orelse return error.InvalidContextLimit,
        },
        .number_string => |text| .{
            .bytes = std.fmt.parseInt(usize, text, 10) catch return error.InvalidContextLimit,
        },
        .string => |string| if (std.mem.eql(u8, string, "off"))
            .off
        else
            error.InvalidContextLimit,
        else => error.InvalidContextLimit,
    };
}

fn dupeUniqueNames(alloc: Allocator, names: []const []const u8) ![][]u8 {
    for (names, 0..) |name, index| {
        if (name.len == 0 or !std.unicode.utf8ValidateSlice(name) or
            std.mem.findScalar(u8, name, 0) != null)
        {
            return error.InvalidToolName;
        }
        for (names[0..index]) |prior| {
            if (std.mem.eql(u8, name, prior)) return error.DuplicateToolName;
        }
    }
    return dupeStrings(alloc, names);
}

fn validPathText(path: []const u8) bool {
    return path.len > 0 and path.len <= std.fs.max_path_bytes and
        std.unicode.utf8ValidateSlice(path) and std.mem.findScalar(u8, path, 0) == null;
}

fn dupeStrings(alloc: Allocator, values: []const []const u8) ![][]u8 {
    const owned = try alloc.alloc([]u8, values.len);
    var initialized: usize = 0;
    errdefer {
        for (owned[0..initialized]) |value| alloc.free(value);
        alloc.free(owned);
    }
    for (values, 0..) |value, index| {
        owned[index] = try alloc.dupe(u8, value);
        initialized += 1;
    }
    return owned;
}

fn freeStrings(alloc: Allocator, values: [][]u8) void {
    for (values) |value| alloc.free(value);
    alloc.free(values);
}

test "strict explicit document accepts versioned retained fields" {
    var parsed = try parseDocument(
        std.testing.allocator,
        "{\"schema_version\":1,\"agent\":{\"provider\":\"gateway\",\"model\":\"openai/gpt-5.4\",\"fast_mode\":true,\"enabled_tools\":[\"read_file\"]},\"runtime\":{\"permission_mode\":\"auto\",\"context_limits\":{\"skill_chunk_bytes\":4096}}}",
        .non_file,
    );
    defer parsed.deinit(std.testing.allocator);

    try std.testing.expectEqual(model_provider.ProviderId.gateway, parsed.provider.?);
    try std.testing.expectEqualStrings("openai/gpt-5.4", parsed.model.?);
    try std.testing.expectEqual(true, parsed.fast_mode.?);
    try std.testing.expectEqualStrings("read_file", parsed.enabled_tools.?[0]);
    try std.testing.expectEqual(types.PermissionMode.auto, parsed.permission_mode.?);
    try std.testing.expectEqual(
        @as(usize, 4096),
        parsed.context_limit_overrides.?.get(.skill_chunk_bytes).?.effectiveBytes(),
    );
}

test "published schema is valid JSON and describes the strict root" {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json_schema, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
    try std.testing.expectEqual(false, parsed.value.object.get("additionalProperties").?.bool);
    try std.testing.expect(parsed.value.object.get("$defs") != null);
    const effort = parsed.value.object.get("properties").?.object
        .get("agent").?.object.get("properties").?.object.get("effort").?.object;
    try std.testing.expectEqual(@as(i64, 1), effort.get("minLength").?.integer);
    try std.testing.expectEqual(@as(i64, 64), effort.get("maxLength").?.integer);
    try std.testing.expectEqualStrings("^[A-Za-z0-9._-]+$", effort.get("pattern").?.string);
    const agent_properties = parsed.value.object.get("properties").?.object
        .get("agent").?.object.get("properties").?.object;
    const model = agent_properties.get("model").?.object;
    try std.testing.expectEqualStrings(
        "^[^\\u0000-\\u0020\\u007F](?:[^\\u0000-\\u001F\\u007F]*[^\\u0000-\\u0020\\u007F])?$",
        model.get("pattern").?.string,
    );
    try std.testing.expectEqual(
        @as(i64, settings_store.max_model_bytes),
        model.get("x-fx-max-utf8-bytes").?.integer,
    );
    const enabled_tool_items = agent_properties.get("enabled_tools").?.object
        .get("items").?.object;
    try std.testing.expectEqual(@as(i64, 1), enabled_tool_items.get("minLength").?.integer);
    try std.testing.expectEqualStrings("^[^\\u0000]+$", enabled_tool_items.get("pattern").?.string);
    const max_steps = agent_properties.get("max_steps").?.object.get("maximum").?;
    try std.testing.expectEqualStrings(
        std.fmt.comptimePrint("{d}", .{std.math.maxInt(usize)}),
        max_steps.number_string,
    );
    const system_parts = parsed.value.object.get("properties").?.object
        .get("prompt").?.object.get("properties").?.object
        .get("system_parts").?.object.get("items").?.object
        .get("oneOf").?.array.items;
    const inline_text = system_parts[1].object.get("properties").?.object
        .get("text").?.object;
    try std.testing.expectEqualStrings("^[^\\u0000]*$", inline_text.get("pattern").?.string);
    try std.testing.expectEqual(
        @as(i64, max_system_prompt_part_bytes),
        inline_text.get("x-fx-max-utf8-bytes").?.integer,
    );
    const file_path = system_parts[2].object.get("properties").?.object
        .get("path").?.object;
    try std.testing.expectEqual(
        @as(i64, std.fs.max_path_bytes),
        file_path.get("x-fx-max-utf8-bytes").?.integer,
    );
}

test "string validation enforces NUL-free prompt text and UTF-8 byte limits" {
    var nul_prompt = try collectValidationDiagnostics(
        std.testing.allocator,
        "{\"schema_version\":1,\"prompt\":{\"system_parts\":[{\"type\":\"inline\",\"text\":\"\\u0000\"}]}}",
    );
    defer nul_prompt.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), nul_prompt.items.len);
    try std.testing.expectEqualStrings(
        "/prompt/system_parts/0/text",
        nul_prompt.items[0].instance_location,
    );
    try std.testing.expectEqual(DiagnosticCode.invalid_value, nul_prompt.items[0].code);

    var model: std.ArrayList(u8) = .empty;
    defer model.deinit(std.testing.allocator);
    for (0..600) |_| try model.appendSlice(std.testing.allocator, "é");
    try std.testing.expectEqual(@as(usize, 1200), model.items.len);
    var document: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer document.deinit();
    try document.writer.writeAll("{\"schema_version\":1,\"agent\":{\"model\":");
    try std.json.Stringify.value(model.items, .{}, &document.writer);
    try document.writer.writeAll("}}");

    var oversized_model = try collectValidationDiagnostics(
        std.testing.allocator,
        document.written(),
    );
    defer oversized_model.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), oversized_model.items.len);
    try std.testing.expectEqualStrings(
        "/agent/model",
        oversized_model.items[0].instance_location,
    );
    try std.testing.expectEqual(DiagnosticCode.invalid_value, oversized_model.items[0].code);
}

test "validation diagnostics collect independent errors in pointer order" {
    var diagnostics = try collectValidationDiagnostics(
        std.testing.allocator,
        "{\"schema_version\":1,\"agent\":{\"fast_mode\":\"yes\"},\"runtime\":{\"permission_mode\":7}}",
    );
    defer diagnostics.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), diagnostics.items.len);
    try std.testing.expectEqualStrings("/agent/fast_mode", diagnostics.items[0].instance_location);
    try std.testing.expectEqual(DiagnosticCode.invalid_type, diagnostics.items[0].code);
    try std.testing.expectEqualStrings("/runtime/permission_mode", diagnostics.items[1].instance_location);
    try std.testing.expectEqual(DiagnosticCode.invalid_type, diagnostics.items[1].code);
    try std.testing.expect(!diagnostics.truncated);
}

test "validation and typed parsing accept the published integer maximum" {
    const document = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"schema_version\":1,\"agent\":{{\"max_steps\":{d}}},\"runtime\":{{\"context_limits\":{{\"skill_chunk_bytes\":{d}}}}}}}",
        .{ std.math.maxInt(usize), std.math.maxInt(usize) },
    );
    defer std.testing.allocator.free(document);

    var diagnostics = try collectValidationDiagnostics(std.testing.allocator, document);
    defer diagnostics.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), diagnostics.items.len);

    var parsed = try parseDocument(std.testing.allocator, document, .non_file);
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expectEqual(std.math.maxInt(usize), parsed.max_steps.?);
    try std.testing.expectEqual(
        std.math.maxInt(usize),
        parsed.context_limit_overrides.?.get(.skill_chunk_bytes).?.value.bytes,
    );
}

test "validation diagnostics report exact duplicate pointer" {
    var diagnostics = try collectValidationDiagnostics(
        std.testing.allocator,
        "{\"schema_version\":1,\"agent\":{\"fast_mode\":true,\"fast_mode\":false}}",
    );
    defer diagnostics.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), diagnostics.items.len);
    try std.testing.expectEqualStrings("/agent/fast_mode", diagnostics.items[0].instance_location);
    try std.testing.expectEqual(DiagnosticCode.duplicate_field, diagnostics.items[0].code);
    try std.testing.expect(!diagnostics.truncated);
}

test "validation diagnostic output is bounded after pointer ordering" {
    var document: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer document.deinit();
    try document.writer.writeAll("{\"schema_version\":1");
    for (0..max_validation_diagnostics + 1) |index| {
        try document.writer.print(",\"unknown_{d:0>2}\":true", .{index});
    }
    try document.writer.writeByte('}');

    var diagnostics = try collectValidationDiagnostics(std.testing.allocator, document.written());
    defer diagnostics.deinit(std.testing.allocator);
    try std.testing.expectEqual(max_validation_diagnostics, diagnostics.items.len);
    try std.testing.expect(diagnostics.truncated);
    try std.testing.expectEqualStrings("/unknown_00", diagnostics.items[0].instance_location);
    try std.testing.expectEqualStrings("/unknown_63", diagnostics.items[63].instance_location);
}

test "validation diagnostic ownership cleans every allocation failure" {
    const Case = struct {
        fn run(alloc: Allocator) !void {
            var diagnostics = try collectValidationDiagnostics(
                alloc,
                "{\"schema_version\":1,\"agent\":{\"fast_mode\":\"yes\"},\"runtime\":{\"permission_mode\":7}}",
            );
            defer diagnostics.deinit(alloc);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Case.run, .{});
}

test "valid validation diagnostics propagate every allocation failure" {
    const Case = struct {
        fn run(alloc: Allocator) !void {
            var diagnostics = try collectValidationDiagnostics(
                alloc,
                "{\"schema_version\":1,\"agent\":{\"fast_mode\":true}}",
            );
            defer diagnostics.deinit(alloc);
            try std.testing.expectEqual(@as(usize, 0), diagnostics.items.len);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Case.run, .{});
}

test "strict explicit document rejects unknown duplicate null and unsupported version" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(
        error.UnknownField,
        parseDocument(alloc, "{\"schema_version\":1,\"unknown\":true}", .non_file),
    );
    try std.testing.expectError(
        error.DuplicateField,
        parseDocument(alloc, "{\"schema_version\":1,\"schema_version\":1}", .non_file),
    );
    try std.testing.expectError(
        error.NullUnsupported,
        parseDocument(alloc, "{\"schema_version\":1,\"agent\":{\"model\":null}}", .non_file),
    );
    try std.testing.expectError(
        error.UnsupportedSchemaVersion,
        parseDocument(alloc, "{\"schema_version\":2}", .non_file),
    );
}

test "non-file explicit sources reject prompt file parts" {
    try std.testing.expectError(
        error.FilePartRequiresRegularConfigSource,
        parseDocument(
            std.testing.allocator,
            "{\"schema_version\":1,\"prompt\":{\"system_parts\":[{\"type\":\"file\",\"path\":\"prompt.md\"}]}}",
            .non_file,
        ),
    );
}

test "system prompt part shapes and unique arrays are strict" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(
        error.InvalidSystemPromptPart,
        parseDocument(
            alloc,
            "{\"schema_version\":1,\"prompt\":{\"system_parts\":[{\"type\":\"builtin\",\"id\":\"default\",\"text\":\"extra\"}]}}",
            .non_file,
        ),
    );
    try std.testing.expectError(
        error.DuplicateToolName,
        parseDocument(
            alloc,
            "{\"schema_version\":1,\"agent\":{\"enabled_tools\":[\"read_file\",\"read_file\"]}}",
            .non_file,
        ),
    );
}

test "typed overrides share strict document parsing" {
    var scalar = try parseOverride(std.testing.allocator, "agent.fast_mode", "true");
    defer scalar.deinit(std.testing.allocator);
    try std.testing.expectEqual(true, scalar.fast_mode.?);

    var structured = try parseOverride(
        std.testing.allocator,
        "agent.enabled_tools",
        "[\"read_file\",\"grep_files\"]",
    );
    defer structured.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("grep_files", structured.enabled_tools.?[1]);

    try std.testing.expectError(
        error.FilePartRequiresRegularConfigSource,
        parseOverride(
            std.testing.allocator,
            "prompt.system_parts",
            "[{\"type\":\"file\",\"path\":\"prompt.md\"}]",
        ),
    );
    try std.testing.expectError(
        error.UnknownConfigField,
        parseOverride(std.testing.allocator, "agent.unknown", "true"),
    );

    var unknown = try encodeOverrideDocument(
        std.testing.allocator,
        "agent.unknown",
        "true",
    );
    defer unknown.deinit(std.testing.allocator);
    var unknown_diagnostics = try unknown.collectDiagnostics(std.testing.allocator);
    defer unknown_diagnostics.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), unknown_diagnostics.items.len);
    try std.testing.expectEqualStrings(
        "/agent/unknown",
        unknown_diagnostics.items[0].instance_location,
    );
    try std.testing.expectEqual(DiagnosticCode.unknown_field, unknown_diagnostics.items[0].code);

    var wrong_type = try encodeOverrideDocument(
        std.testing.allocator,
        "agent.fast_mode",
        "\"yes\"",
    );
    defer wrong_type.deinit(std.testing.allocator);
    var wrong_type_diagnostics = try wrong_type.collectDiagnostics(std.testing.allocator);
    defer wrong_type_diagnostics.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), wrong_type_diagnostics.items.len);
    try std.testing.expectEqualStrings(
        "/agent/fast_mode",
        wrong_type_diagnostics.items[0].instance_location,
    );
    try std.testing.expectEqual(DiagnosticCode.invalid_type, wrong_type_diagnostics.items[0].code);

    var malformed = try encodeOverrideDocument(
        std.testing.allocator,
        "agent.fast_mode",
        "yes",
    );
    defer malformed.deinit(std.testing.allocator);
    var malformed_diagnostics = try malformed.collectDiagnostics(std.testing.allocator);
    defer malformed_diagnostics.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), malformed_diagnostics.items.len);
    try std.testing.expectEqualStrings(
        "/agent/fast_mode",
        malformed_diagnostics.items[0].instance_location,
    );
    try std.testing.expectEqual(DiagnosticCode.invalid_json, malformed_diagnostics.items[0].code);

    var injected = try encodeOverrideDocument(
        std.testing.allocator,
        "agent.fast_mode",
        "true},\"runtime\":{\"permission_mode\":\"yolo\"",
    );
    defer injected.deinit(std.testing.allocator);
    var injected_diagnostics = try injected.collectDiagnostics(std.testing.allocator);
    defer injected_diagnostics.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), injected_diagnostics.items.len);
    try std.testing.expectEqualStrings(
        "/agent/fast_mode",
        injected_diagnostics.items[0].instance_location,
    );
    try std.testing.expectEqual(DiagnosticCode.invalid_json, injected_diagnostics.items[0].code);

    var duplicate = try encodeOverrideDocument(
        std.testing.allocator,
        "runtime.context_limits",
        "{\"skill_chunk_bytes\":1,\"skill_chunk_bytes\":2}",
    );
    defer duplicate.deinit(std.testing.allocator);
    var duplicate_diagnostics = try duplicate.collectDiagnostics(std.testing.allocator);
    defer duplicate_diagnostics.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), duplicate_diagnostics.items.len);
    try std.testing.expectEqualStrings(
        "/runtime/context_limits/skill_chunk_bytes",
        duplicate_diagnostics.items[0].instance_location,
    );
    try std.testing.expectEqual(DiagnosticCode.duplicate_field, duplicate_diagnostics.items[0].code);
}

test "strict document ownership cleans every allocation failure" {
    const Case = struct {
        fn run(alloc: Allocator) !void {
            var parsed = try parseDocument(
                alloc,
                "{\"schema_version\":1,\"agent\":{\"model\":\"openai/gpt-5.4\",\"enabled_tools\":[\"read_file\",\"grep_files\"]},\"prompt\":{\"system_parts\":[{\"type\":\"inline\",\"text\":\"policy\"}]},\"runtime\":{\"additional_directories\":[\"/tmp/one\",\"/tmp/two\"]}}",
                .non_file,
            );
            defer parsed.deinit(alloc);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Case.run, .{});
}

test "owned launch policy projections clean every allocation failure" {
    const Case = struct {
        fn run(alloc: Allocator) !void {
            var policy = OwnedLaunchPolicy{};
            defer policy.deinit(alloc);
            policy.enabled_tools = try dupeStrings(alloc, &.{"read_file"});
            const text = try alloc.dupe(u8, "policy");
            var text_owned = true;
            errdefer if (text_owned) alloc.free(text);
            const parts = try alloc.alloc(SystemPart, 1);
            var parts_owned = true;
            errdefer if (parts_owned) alloc.free(parts);
            parts[0] = .{ .@"inline" = text };
            policy.system_parts = parts;
            text_owned = false;
            parts_owned = false;
            try policy.composeSystemPrompt(alloc, "builtin");
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Case.run, .{});
}
