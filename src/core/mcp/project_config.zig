//! Pure project-scoped MCP parsing and policy.
//!
//! Callers own filesystem, settings, diagnostics presentation, and runtime
//! effects. Values returned here own their allocations until deinitialized or
//! moved into `McpRuntime`.

const std = @import("std");
const mcp_auth = @import("mcp_auth.zig");
const mcp_contract = @import("mcp_contract.zig");
const startup_admission = @import("startup_admission.zig");
const streamable_http = @import("streamable_http.zig");
const text_utils = @import("../shared/text_utils.zig");

const Allocator = std.mem.Allocator;
const McpAuthConfig = mcp_contract.McpAuthConfig;
const McpEnvVar = mcp_contract.McpEnvVar;
const McpHttpHeader = mcp_contract.McpHttpHeader;
const McpHttpHeaderEnv = mcp_contract.McpHttpHeaderEnv;
const McpServerConfig = mcp_contract.McpServerConfig;
const McpTransport = mcp_contract.McpTransport;

pub const enabled_servers_key = "enabledMcpjsonServers";
pub const disabled_servers_key = "disabledMcpjsonServers";
pub const enable_all_key = "enableAllProjectMcpServers";

pub const ProjectMcpChoices = struct {
    enable_all: bool = false,
    approved: [][]u8 = &.{},
    rejected: [][]u8 = &.{},

    pub fn deinit(self: *ProjectMcpChoices, alloc: Allocator) void {
        freeOwnedStrings(alloc, self.approved);
        freeOwnedStrings(alloc, self.rejected);
        self.* = undefined;
    }
};

pub const ProjectMcpAction = union(enum) {
    approve: []const u8,
    reject: []const u8,
    approve_all,
    reset,
};

pub const ProjectMcpTransition = struct {
    choices: ProjectMcpChoices,
    authority_reduced: bool,
};

const ParsePolicy = struct {
    source: mcp_contract.ConfigSource,
    scope: mcp_contract.ConfigScope,
    force_optional: bool = false,
    allow_stored_credentials: bool = false,
    allow_authorization_header: bool = false,
    workspace_admission: ?mcp_contract.WorkspaceAdmission = null,
};

const ParsedTimeouts = struct {
    startup_ms: u32,
    operation_ms: u32,
};

pub const WorkspaceDiagnosticCause = enum {
    invalid_json,
    root_must_be_object,
    servers_must_be_object,
    invalid_entry,
    missing_environment_variable,
    environment_expansion_limit_exceeded,
    approved_rejected_overlap,
};

pub const WorkspaceEnvironmentField = enum {
    command,
    argument,
    environment,
    http_header,
};

pub const WorkspaceDiagnostic = struct {
    server_name: ?[]u8 = null,
    environment_variable: ?[]u8 = null,
    environment_field: ?WorkspaceEnvironmentField = null,
    cause: WorkspaceDiagnosticCause,

    pub fn deinit(self: *WorkspaceDiagnostic, alloc: Allocator) void {
        if (self.server_name) |name| alloc.free(name);
        if (self.environment_variable) |name| alloc.free(name);
        self.* = undefined;
    }
};

pub fn renderWorkspaceDiagnostic(
    alloc: Allocator,
    diagnostic: WorkspaceDiagnostic,
) ![]u8 {
    var encoded_server = try text_utils.encodeTerminalSafe(
        alloc,
        diagnostic.server_name orelse "unknown",
        160,
    );
    defer encoded_server.deinit(alloc);
    if (diagnostic.cause == .missing_environment_variable) {
        var encoded_variable = try text_utils.encodeTerminalSafe(
            alloc,
            diagnostic.environment_variable orelse "unknown",
            max_rendered_environment_name_bytes,
        );
        defer encoded_variable.deinit(alloc);
        const field = if (diagnostic.environment_field) |value|
            @tagName(value)
        else
            "value";
        return std.fmt.allocPrint(
            alloc,
            ".mcp.json server '{s}' field {s} requires environment variable '{s}'; set it or use ${{{s}:-default}}.",
            .{
                encoded_server.bytes,
                field,
                encoded_variable.bytes,
                encoded_variable.bytes,
            },
        );
    }
    return std.fmt.allocPrint(
        alloc,
        ".mcp.json server '{s}' was skipped: {s}.",
        .{ encoded_server.bytes, @tagName(diagnostic.cause) },
    );
}

pub const WorkspaceParseResult = struct {
    configs: std.ArrayList(McpServerConfig) = .empty,
    diagnostics: std.ArrayList(WorkspaceDiagnostic) = .empty,

    pub fn deinit(self: *WorkspaceParseResult, alloc: Allocator) void {
        for (self.configs.items) |*config| config.deinit(alloc);
        self.configs.deinit(alloc);
        for (self.diagnostics.items) |*diagnostic| diagnostic.deinit(alloc);
        self.diagnostics.deinit(alloc);
        self.* = undefined;
    }
};

const ProfileDiagnosticCause = mcp_contract.ProfileConfigWarningCause;
pub const ProfileDiagnostic = mcp_contract.ProfileConfigWarning;

pub const ProfileParseResult = struct {
    configs: std.ArrayList(McpServerConfig) = .empty,
    diagnostic: ?ProfileDiagnostic = null,
    mutation_allowed: bool = true,

    pub fn deinit(self: *ProfileParseResult, alloc: Allocator) void {
        deinitConfigs(alloc, &self.configs);
        self.* = undefined;
    }
};

const max_profile_root_scan_entries: usize = 64;
const max_profile_child_scan_entries: usize = 64;
const max_profile_key_bytes: usize = mcp_contract.max_profile_config_warning_key_bytes;

const SuspiciousKeyScan = union(enum) {
    clear,
    found: struct {
        key: []const u8,
        additional_matches: usize,
    },
    indeterminate,
};

pub fn parseProfileJson(alloc: Allocator, json_text: []const u8) !std.ArrayList(McpServerConfig) {
    var result = try parseProfileDocument(alloc, json_text);
    defer result.deinit(alloc);
    const configs = result.configs;
    result.configs = .empty;
    return configs;
}

inline fn failProfileParse(err: anytype) @TypeOf(err)!ProfileParseResult {
    return @errorCast(failProfileParseDynamic(err));
}

noinline fn failProfileParseDynamic(err: anyerror) anyerror!ProfileParseResult {
    return err;
}

pub fn parseProfileDocument(alloc: Allocator, json_text: []const u8) !ProfileParseResult {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, json_text, .{}) catch |err| switch (err) {
        error.OutOfMemory => return failProfileParse(error.OutOfMemory),
        else => return failProfileParse(error.McpConfigInvalidJson),
    };
    defer parsed.deinit();
    if (parsed.value != .object) return failProfileParse(error.McpConfigRootMustBeObject);

    const object = parsed.value.object;
    const canonical = object.get("mcp");
    const alias = object.get("mcpServers");
    if (canonical orelse alias) |servers| {
        var result = ProfileParseResult{ .configs = try parseProfileServerMap(alloc, servers) };
        errdefer result.deinit(alloc);
        switch (scanSuspiciousProfileKeys(object)) {
            .clear => if (canonical != null and alias != null and profileAliasIsNonEmpty(alias.?)) {
                result.diagnostic = ProfileDiagnostic.init(
                    .ignored_mcp_servers_alias,
                    "mcpServers",
                    0,
                );
            },
            .found => |found| {
                result.diagnostic = ProfileDiagnostic.init(
                    .suspicious_server_key,
                    found.key,
                    found.additional_matches,
                );
                result.mutation_allowed = false;
            },
            .indeterminate => {
                result.diagnostic = ProfileDiagnostic.init(
                    .suspicious_key_scan_indeterminate,
                    null,
                    0,
                );
                result.mutation_allowed = false;
            },
        }
        return result;
    }

    return switch (scanSuspiciousProfileKeys(object)) {
        .clear => .{},
        .found => |found| blk: {
            break :blk .{
                .diagnostic = ProfileDiagnostic.init(
                    .suspicious_server_key,
                    found.key,
                    found.additional_matches,
                ),
                .mutation_allowed = false,
            };
        },
        .indeterminate => .{
            .diagnostic = ProfileDiagnostic.init(
                .suspicious_key_scan_indeterminate,
                null,
                0,
            ),
            .mutation_allowed = false,
        },
    };
}

fn parseProfileServerMap(
    alloc: Allocator,
    servers: std.json.Value,
) !std.ArrayList(McpServerConfig) {
    if (servers != .object) return error.McpConfigServersMustBeObject;

    var configs: std.ArrayList(McpServerConfig) = .empty;
    errdefer deinitConfigs(alloc, &configs);
    var it = servers.object.iterator();
    while (it.next()) |entry| {
        const config = try parseServerEntry(alloc, entry.key_ptr.*, entry.value_ptr.*, .{
            .source = .profile,
            .scope = .profile,
            .allow_stored_credentials = true,
        });
        configs.append(alloc, config) catch |err| {
            var mutable = config;
            mutable.deinit(alloc);
            return err;
        };
    }
    return configs;
}

fn profileAliasIsNonEmpty(value: std.json.Value) bool {
    return switch (value) {
        .object => value.object.count() > 0,
        .array => value.array.items.len > 0,
        .string => value.string.len > 0,
        .null => false,
        else => true,
    };
}

fn scanSuspiciousProfileKeys(object: std.json.ObjectMap) SuspiciousKeyScan {
    if (object.count() > max_profile_root_scan_entries) return .indeterminate;

    var first: ?[]const u8 = null;
    var additional_matches: usize = 0;
    var it = object.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const value = entry.value_ptr.*;
        if (std.mem.eql(u8, key, "mcp") or std.mem.eql(u8, key, "mcpServers")) continue;
        if (key.len > max_profile_key_bytes) {
            if (serverMapShape(value) != .clear) return .indeterminate;
            continue;
        }
        if (!isSuspiciousNormalizedKey(key)) continue;
        switch (serverMapShape(value)) {
            .clear => {},
            .match => {
                if (first == null) {
                    first = key;
                } else {
                    additional_matches += 1;
                }
            },
            .indeterminate => return .indeterminate,
        }
    }
    if (first) |key| return .{ .found = .{
        .key = key,
        .additional_matches = additional_matches,
    } };
    return .clear;
}

const ServerMapShape = enum { clear, match, indeterminate };

fn serverMapShape(value: std.json.Value) ServerMapShape {
    if (value != .object) return .clear;
    var inspected: usize = 0;
    var it = value.object.iterator();
    while (it.next()) |entry| {
        if (inspected == max_profile_child_scan_entries) return .indeterminate;
        inspected += 1;
        if (serverEntryShape(entry.value_ptr.*)) return .match;
    }
    return .clear;
}

fn serverEntryShape(value: std.json.Value) bool {
    if (value != .object) return false;
    if (value.object.get("command")) |command| {
        if (command == .string or command == .array) return true;
    }
    if (value.object.get("url")) |url| if (url == .string) return true;
    if (value.object.get("type")) |kind| {
        if (kind != .string) return false;
        return std.mem.eql(u8, kind.string, "local") or
            std.mem.eql(u8, kind.string, "stdio") or
            std.mem.eql(u8, kind.string, "http") or
            std.mem.eql(u8, kind.string, "sse");
    }
    return false;
}

fn isSuspiciousNormalizedKey(raw: []const u8) bool {
    var normalized: [max_profile_key_bytes]u8 = undefined;
    var len: usize = 0;
    for (raw) |byte| {
        if (!std.ascii.isAlphanumeric(byte)) continue;
        normalized[len] = std.ascii.toLower(byte);
        len += 1;
    }
    const key = normalized[0..len];
    return std.mem.eql(u8, key, "mcpserver") or
        std.mem.eql(u8, key, "mcpservers") or
        std.mem.eql(u8, key, "modelcontextprotocol") or
        std.mem.eql(u8, key, "modelcontextprotocolserver") or
        std.mem.eql(u8, key, "modelcontextprotocolservers") or
        std.mem.eql(u8, key, "servers");
}

pub fn parseWorkspaceJson(
    alloc: Allocator,
    json_text: []const u8,
    scope: mcp_contract.ConfigScope,
    choices: ProjectMcpChoices,
) Allocator.Error!WorkspaceParseResult {
    return parseWorkspaceJsonInternal(alloc, json_text, scope, choices);
}

pub fn parseWorkspaceJsonWithEnvironment(
    alloc: Allocator,
    json_text: []const u8,
    scope: mcp_contract.ConfigScope,
    choices: ProjectMcpChoices,
    environment: *const std.process.Environ.Map,
) Allocator.Error!WorkspaceParseResult {
    var result = try parseWorkspaceJsonInternal(alloc, json_text, scope, choices);
    errdefer result.deinit(alloc);
    try expandApprovedWorkspaceConfigs(alloc, &result, environment);
    return result;
}

fn parseWorkspaceJsonInternal(
    alloc: Allocator,
    json_text: []const u8,
    scope: mcp_contract.ConfigScope,
    choices: ProjectMcpChoices,
) Allocator.Error!WorkspaceParseResult {
    var result: WorkspaceParseResult = .{};
    errdefer result.deinit(alloc);

    var parsed = std.json.parseFromSlice(std.json.Value, alloc, json_text, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            try result.diagnostics.append(alloc, .{ .cause = .invalid_json });
            return result;
        },
    };
    defer parsed.deinit();
    if (parsed.value != .object) {
        try result.diagnostics.append(alloc, .{ .cause = .root_must_be_object });
        return result;
    }
    const servers = parsed.value.object.get("mcpServers") orelse return result;
    if (servers != .object) {
        try result.diagnostics.append(alloc, .{ .cause = .servers_must_be_object });
        return result;
    }

    var it = servers.object.iterator();
    while (it.next()) |entry| {
        const admission = resolveAdmission(entry.key_ptr.*, choices);
        const config = parseServerEntry(alloc, entry.key_ptr.*, entry.value_ptr.*, .{
            .source = .workspace,
            .scope = scope,
            .force_optional = true,
            .allow_stored_credentials = false,
            .allow_authorization_header = true,
            .workspace_admission = admission,
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                const server_name = try alloc.dupe(u8, entry.key_ptr.*);
                errdefer alloc.free(server_name);
                try result.diagnostics.append(alloc, .{
                    .server_name = server_name,
                    .cause = .invalid_entry,
                });
                continue;
            },
        };
        result.configs.append(alloc, config) catch |err| {
            var mutable = config;
            mutable.deinit(alloc);
            return err;
        };
    }
    return result;
}

pub fn expandApprovedWorkspaceConfigs(
    alloc: Allocator,
    result: *WorkspaceParseResult,
    environment: *const std.process.Environ.Map,
) Allocator.Error!void {
    var expansion_budget = WorkspaceExpansionBudget.init();
    var index: usize = 0;
    while (index < result.configs.items.len) {
        const config = &result.configs.items[index];
        if (config.workspace_admission != .approved) {
            index += 1;
            continue;
        }
        const failure = try expandWorkspaceConfig(
            alloc,
            config,
            environment,
            &expansion_budget,
        ) orelse {
            index += 1;
            continue;
        };
        const server_name = try alloc.dupe(u8, config.name);
        errdefer alloc.free(server_name);
        switch (failure) {
            .missing => |missing| {
                errdefer alloc.free(missing.variable_name);
                try result.diagnostics.append(alloc, .{
                    .server_name = server_name,
                    .environment_variable = missing.variable_name,
                    .environment_field = missing.field,
                    .cause = .missing_environment_variable,
                });
            },
            .invalid => try result.diagnostics.append(alloc, .{
                .server_name = server_name,
                .cause = .invalid_entry,
            }),
            .limit_exceeded => try result.diagnostics.append(alloc, .{
                .server_name = server_name,
                .cause = .environment_expansion_limit_exceeded,
            }),
        }
        var removed = result.configs.orderedRemove(index);
        removed.deinit(alloc);
    }
}

const max_rendered_environment_name_bytes: usize = 128;
const max_expanded_workspace_value_bytes: usize = 1024 * 1024;
const max_expanded_workspace_total_bytes: usize = 1024 * 1024;

const WorkspaceExpansionBudget = struct {
    remaining: usize,

    fn init() WorkspaceExpansionBudget {
        return .{ .remaining = max_expanded_workspace_total_bytes };
    }

    fn consume(self: *WorkspaceExpansionBudget, byte_count: usize) bool {
        if (byte_count > self.remaining) {
            self.remaining = 0;
            return false;
        }
        self.remaining -= byte_count;
        return true;
    }
};

const WorkspaceTemplateExpansion = union(enum) {
    expanded: []u8,
    missing: []u8,
    invalid,
    limit_exceeded,

    pub fn deinit(self: *WorkspaceTemplateExpansion, alloc: Allocator) void {
        switch (self.*) {
            .expanded, .missing => |value| alloc.free(value),
            .invalid, .limit_exceeded => {},
        }
        self.* = undefined;
    }
};

fn expandWorkspaceTemplate(
    alloc: Allocator,
    input: []const u8,
    environment: *const std.process.Environ.Map,
    budget: *WorkspaceExpansionBudget,
) Allocator.Error!WorkspaceTemplateExpansion {
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(alloc);

    var cursor: usize = 0;
    while (cursor < input.len) {
        const relative_start = std.mem.find(u8, input[cursor..], "${") orelse {
            if (!try appendExpandedBytes(alloc, &output, input[cursor..], budget)) return .limit_exceeded;
            return .{ .expanded = try output.toOwnedSlice(alloc) };
        };
        const start = cursor + relative_start;
        if (!try appendExpandedBytes(alloc, &output, input[cursor..start], budget)) return .limit_exceeded;
        const expression_start = start + 2;
        const relative_end = std.mem.findScalar(u8, input[expression_start..], '}') orelse
            return .invalid;
        const end = expression_start + relative_end;
        const expression = input[expression_start..end];
        const default_marker = std.mem.find(u8, expression, ":-");
        const variable_name = if (default_marker) |index| expression[0..index] else expression;
        const default_value = if (default_marker) |index| expression[index + 2 ..] else null;
        if (!isValidEnvName(variable_name)) {
            return .invalid;
        }
        const replacement = environment.get(variable_name) orelse default_value orelse {
            return .{ .missing = try alloc.dupe(u8, variable_name) };
        };
        if (!try appendExpandedBytes(alloc, &output, replacement, budget)) return .limit_exceeded;
        cursor = end + 1;
    }
    return .{ .expanded = try output.toOwnedSlice(alloc) };
}

fn appendExpandedBytes(
    alloc: Allocator,
    output: *std.ArrayList(u8),
    bytes: []const u8,
    budget: *WorkspaceExpansionBudget,
) Allocator.Error!bool {
    if (output.items.len > max_expanded_workspace_value_bytes or
        bytes.len > max_expanded_workspace_value_bytes - output.items.len)
    {
        return false;
    }
    if (!budget.consume(bytes.len)) return false;
    try output.appendSlice(alloc, bytes);
    return true;
}

const WorkspaceExpansionFailure = union(enum) {
    missing: struct {
        field: WorkspaceEnvironmentField,
        variable_name: []u8,
    },
    invalid,
    limit_exceeded,
};

fn expandWorkspaceConfig(
    alloc: Allocator,
    config: *McpServerConfig,
    environment: *const std.process.Environ.Map,
    budget: *WorkspaceExpansionBudget,
) Allocator.Error!?WorkspaceExpansionFailure {
    if (config.command) |*command| {
        if (try expandOwnedConstWorkspaceValue(alloc, command, environment, .command, budget)) |failure| {
            return failure;
        }
    }
    for (@constCast(config.args)) |*argument| {
        if (try expandOwnedConstWorkspaceValue(alloc, argument, environment, .argument, budget)) |failure| {
            return failure;
        }
    }
    for (config.env) |*entry| {
        if (try expandOwnedMutableWorkspaceValue(alloc, &entry.value, environment, .environment, budget)) |failure| {
            return failure;
        }
    }
    for (config.headers) |*header| {
        if (try expandOwnedMutableWorkspaceValue(alloc, &header.value, environment, .http_header, budget)) |failure| {
            return failure;
        }
    }
    streamable_http.validateStaticHeaders(config.headers) catch return .invalid;
    return null;
}

fn expandOwnedConstWorkspaceValue(
    alloc: Allocator,
    value: *[]const u8,
    environment: *const std.process.Environ.Map,
    field: WorkspaceEnvironmentField,
    budget: *WorkspaceExpansionBudget,
) Allocator.Error!?WorkspaceExpansionFailure {
    var expansion = try expandWorkspaceTemplate(alloc, value.*, environment, budget);
    switch (expansion) {
        .expanded => |expanded| {
            alloc.free(value.*);
            value.* = expanded;
            expansion = undefined;
            return null;
        },
        .missing => |variable_name| {
            expansion = undefined;
            return .{ .missing = .{
                .field = field,
                .variable_name = variable_name,
            } };
        },
        .invalid => return .invalid,
        .limit_exceeded => return .limit_exceeded,
    }
}

fn expandOwnedMutableWorkspaceValue(
    alloc: Allocator,
    value: *[]u8,
    environment: *const std.process.Environ.Map,
    field: WorkspaceEnvironmentField,
    budget: *WorkspaceExpansionBudget,
) Allocator.Error!?WorkspaceExpansionFailure {
    var borrowed: []const u8 = value.*;
    const failure = try expandOwnedConstWorkspaceValue(
        alloc,
        &borrowed,
        environment,
        field,
        budget,
    );
    value.* = @constCast(borrowed);
    return failure;
}

pub fn parseChoices(
    alloc: Allocator,
    workspace_value: ?std.json.Value,
    diagnostics: *std.ArrayList(WorkspaceDiagnostic),
) !ProjectMcpChoices {
    const value = workspace_value orelse return .{};
    if (value != .object) return error.InvalidProjectMcpChoices;
    const object = value.object;
    const approved: [][]u8 = if (object.get(enabled_servers_key)) |field|
        try parseUniqueStringArray(alloc, field)
    else
        @constCast(&.{});
    var approved_owned = true;
    errdefer if (approved_owned) freeOwnedStrings(alloc, approved);
    const rejected: [][]u8 = if (object.get(disabled_servers_key)) |field|
        try parseUniqueStringArray(alloc, field)
    else
        @constCast(&.{});
    var rejected_owned = true;
    errdefer if (rejected_owned) freeOwnedStrings(alloc, rejected);
    const enable_all = if (object.get(enable_all_key)) |field| blk: {
        if (field != .bool) return error.InvalidProjectMcpChoices;
        break :blk field.bool;
    } else false;

    var normalized_approved: std.ArrayList([]u8) = .empty;
    errdefer freeOwnedList(alloc, &normalized_approved);
    try normalized_approved.ensureTotalCapacity(alloc, approved.len);
    for (approved) |name| {
        if (containsName(rejected, name)) {
            const server_name = try alloc.dupe(u8, name);
            errdefer alloc.free(server_name);
            try diagnostics.append(alloc, .{
                .server_name = server_name,
                .cause = .approved_rejected_overlap,
            });
            continue;
        }
        normalized_approved.appendAssumeCapacity(try alloc.dupe(u8, name));
    }
    freeOwnedStrings(alloc, approved);
    approved_owned = false;
    const normalized = try normalized_approved.toOwnedSlice(alloc);
    errdefer freeOwnedStrings(alloc, normalized);
    rejected_owned = false;
    return .{
        .enable_all = enable_all,
        .approved = normalized,
        .rejected = rejected,
    };
}

pub fn applyAction(
    alloc: Allocator,
    current: ProjectMcpChoices,
    action: ProjectMcpAction,
) !ProjectMcpTransition {
    var approved: std.ArrayList([]u8) = .empty;
    errdefer freeOwnedList(alloc, &approved);
    var rejected: std.ArrayList([]u8) = .empty;
    errdefer freeOwnedList(alloc, &rejected);

    switch (action) {
        .approve => |name| {
            try appendNamesExcept(alloc, &approved, current.approved, null);
            if (!containsName(approved.items, name)) try appendOwnedName(alloc, &approved, name);
            try appendNamesExcept(alloc, &rejected, current.rejected, name);
        },
        .reject => |name| {
            try appendNamesExcept(alloc, &approved, current.approved, name);
            try appendNamesExcept(alloc, &rejected, current.rejected, null);
            if (!containsName(rejected.items, name)) try appendOwnedName(alloc, &rejected, name);
        },
        .approve_all => {
            try appendNamesExcept(alloc, &approved, current.approved, null);
            try appendNamesExcept(alloc, &rejected, current.rejected, null);
        },
        .reset => {},
    }

    const authority_reduced = switch (action) {
        .approve, .approve_all => false,
        .reject => |name| current.enable_all or containsName(current.approved, name),
        .reset => current.enable_all or current.approved.len > 0,
    };
    const approved_slice = try approved.toOwnedSlice(alloc);
    errdefer freeOwnedStrings(alloc, approved_slice);
    const rejected_slice = try rejected.toOwnedSlice(alloc);
    return .{
        .choices = .{
            .enable_all = switch (action) {
                .approve_all => true,
                .reset => false,
                else => current.enable_all,
            },
            .approved = approved_slice,
            .rejected = rejected_slice,
        },
        .authority_reduced = authority_reduced,
    };
}

fn resolveAdmission(
    name: []const u8,
    choices: ProjectMcpChoices,
) mcp_contract.WorkspaceAdmission {
    if (containsName(choices.rejected, name)) return .rejected;
    if (choices.enable_all or containsName(choices.approved, name)) return .approved;
    return .pending;
}

pub fn mergeNative(
    alloc: Allocator,
    primary: *std.ArrayList(McpServerConfig),
    workspace: *std.ArrayList(McpServerConfig),
) !std.ArrayList(McpServerConfig) {
    var merged: std.ArrayList(McpServerConfig) = .empty;
    errdefer deinitConfigs(alloc, &merged);
    try merged.ensureTotalCapacity(alloc, primary.items.len + workspace.items.len);
    while (primary.items.len > 0) merged.appendAssumeCapacity(primary.orderedRemove(0));
    while (workspace.items.len > 0) {
        var candidate = workspace.orderedRemove(0);
        if (configNamePresent(merged.items, candidate.name)) {
            candidate.deinit(alloc);
            continue;
        }
        merged.appendAssumeCapacity(candidate);
    }
    return merged;
}

pub fn appendWorkspaceAfterAcpPrimary(
    alloc: Allocator,
    output: *std.ArrayList(McpServerConfig),
    workspace: *std.ArrayList(McpServerConfig),
) !void {
    const primary_len = output.items.len;
    try output.ensureUnusedCapacity(alloc, workspace.items.len);
    while (workspace.items.len > 0) {
        var candidate = workspace.orderedRemove(0);
        if (configNamePresent(output.items[0..primary_len], candidate.name)) {
            candidate.deinit(alloc);
            continue;
        }
        output.appendAssumeCapacity(candidate);
    }
}

pub fn authorityNames(
    alloc: Allocator,
    configs: []const McpServerConfig,
    phase: startup_admission.Phase,
) ![][]u8 {
    var names: std.ArrayList([]u8) = .empty;
    errdefer freeOwnedList(alloc, &names);
    for (configs) |config| {
        if (config.source != .workspace) continue;
        if (startup_admission.decide(
            config.enabled,
            config.required,
            config.workspace_admission,
            phase,
        ) != .connect) continue;
        if (!containsName(names.items, config.name)) {
            try appendOwnedName(alloc, &names, config.name);
        }
    }
    return names.toOwnedSlice(alloc);
}

pub fn configRetainsWorkspaceAuthority(
    current: McpServerConfig,
    next: []const McpServerConfig,
    phase: startup_admission.Phase,
) bool {
    if (current.source != .workspace or
        startup_admission.decide(
            current.enabled,
            current.required,
            current.workspace_admission,
            phase,
        ) != .connect) return true;
    for (next) |candidate| {
        if (candidate.source != .workspace or
            !std.mem.eql(u8, current.name, candidate.name)) continue;
        if (startup_admission.decide(
            candidate.enabled,
            candidate.required,
            candidate.workspace_admission,
            phase,
        ) == .connect) return true;
    }
    return false;
}

inline fn failServerConfig(err: anytype) @TypeOf(err)!McpServerConfig {
    return @errorCast(failServerConfigDynamic(err));
}

noinline fn failServerConfigDynamic(err: anyerror) anyerror!McpServerConfig {
    return err;
}

test "project config failures preserve exact error types and identities" {
    const invalid = failServerConfig(error.McpConfigInvalidType);
    try std.testing.expect(
        @TypeOf(invalid) == error{McpConfigInvalidType}!McpServerConfig,
    );
    try std.testing.expectError(error.McpConfigInvalidType, invalid);
    try std.testing.expectError(
        error.McpConfigServerMustBeObject,
        failServerConfig(error.McpConfigServerMustBeObject),
    );
    try std.testing.expectError(error.OutOfMemory, failServerConfig(error.OutOfMemory));

    const invalid_profile = failProfileParse(error.McpConfigInvalidJson);
    try std.testing.expect(
        @TypeOf(invalid_profile) == error{McpConfigInvalidJson}!ProfileParseResult,
    );
    try std.testing.expectError(error.McpConfigInvalidJson, invalid_profile);
}

fn parseServerEntry(
    alloc: Allocator,
    name: []const u8,
    value: std.json.Value,
    policy: ParsePolicy,
) !McpServerConfig {
    if (value != .object) return failServerConfig(error.McpConfigServerMustBeObject);
    if (!mcp_contract.sourceAllowsScope(policy.source, policy.scope) or
        !mcp_contract.sourceAllowsWorkspaceAdmission(policy.source, policy.workspace_admission))
    {
        return failServerConfig(error.McpConfigPolicyInvalid);
    }
    const object = value.object;
    const type_string = if (object.get("type")) |kind_value|
        (if (kind_value == .string) kind_value.string else return failServerConfig(error.McpConfigInvalidType))
    else
        "local";
    const transport: McpTransport = if (std.mem.eql(u8, type_string, "sse"))
        .sse
    else if (std.mem.eql(u8, type_string, "http"))
        .http
    else
        .stdio;
    if (transport == .stdio and
        !std.mem.eql(u8, type_string, "local") and
        !std.mem.eql(u8, type_string, "stdio")) return failServerConfig(error.McpConfigInvalidType);

    const enabled = if (object.get("enabled")) |field|
        if (field == .bool) field.bool else return failServerConfig(error.McpConfigInvalidEnabled)
    else
        true;
    const configured_required = if (object.get("required")) |field|
        if (field == .bool) field.bool else return failServerConfig(error.McpConfigInvalidRequired)
    else
        false;
    const required = if (policy.force_optional) false else configured_required;

    if (transport != .stdio) {
        const url_value = object.get("url") orelse return failServerConfig(error.McpConfigMissingUrl);
        if (url_value != .string) return failServerConfig(error.McpConfigInvalidUrl);
        streamable_http.validateEndpoint(url_value.string) catch return failServerConfig(error.McpConfigInvalidUrl);
        const timeouts = try parseTimeouts(object);
        const env = try parseSelectedEnvironment(alloc, object);
        errdefer freeEnvVars(alloc, env);
        const headers = try parseRemoteHeaders(
            alloc,
            object,
            policy.allow_authorization_header,
        );
        errdefer freeHttpHeaders(alloc, headers);
        const header_env = try parseRemoteHeaderEnv(alloc, object);
        errdefer freeHttpHeaderEnv(alloc, header_env);
        const bearer_token_env = try parseOptionalOwnedString(alloc, object, "bearer_token_env");
        errdefer if (bearer_token_env) |field| alloc.free(field);
        if (bearer_token_env) |field| if (!isValidEnvName(field)) return failServerConfig(error.McpConfigInvalidBearerEnvironment);
        var auth = parseProfileAuth(alloc, object) catch |err| switch (err) {
            error.OutOfMemory => return failServerConfig(error.OutOfMemory),
            else => return failServerConfig(error.McpConfigInvalidOAuth),
        };
        errdefer if (auth) |*field| field.deinit(alloc);
        const owned_name = try alloc.dupe(u8, name);
        errdefer alloc.free(owned_name);
        const owned_url = try alloc.dupe(u8, url_value.string);
        return .{
            .name = owned_name,
            .source = policy.source,
            .scope = policy.scope,
            .required = required,
            .transport = transport,
            .url = owned_url,
            .env = env,
            .headers = headers,
            .header_env = header_env,
            .bearer_token_env = bearer_token_env,
            .auth = auth,
            .allow_stored_credentials = policy.allow_stored_credentials,
            .enabled = enabled,
            .workspace_admission = policy.workspace_admission,
            .startup_timeout_ms = timeouts.startup_ms,
            .operation_timeout_ms = timeouts.operation_ms,
        };
    }

    const timeouts = try parseTimeouts(object);
    const restart_limit = parseUnsignedPolicy(
        object,
        "restart_limit",
        mcp_contract.default_restart_limit,
        0,
        std.math.maxInt(u8),
    ) catch return failServerConfig(error.McpConfigInvalidRestartLimit);
    const command = parseCommandSpec(alloc, object) catch |err| switch (err) {
        error.OutOfMemory => return failServerConfig(error.OutOfMemory),
        else => return failServerConfig(error.McpConfigInvalidCommand),
    };
    errdefer freeParsedCommandSpec(alloc, command);
    const env = try parseSelectedEnvironment(alloc, object);
    errdefer freeEnvVars(alloc, env);
    return .{
        .name = try alloc.dupe(u8, name),
        .source = policy.source,
        .scope = policy.scope,
        .required = required,
        .transport = .stdio,
        .command = command.command,
        .args = command.args,
        .env = env,
        .enabled = enabled,
        .workspace_admission = policy.workspace_admission,
        .startup_timeout_ms = timeouts.startup_ms,
        .operation_timeout_ms = timeouts.operation_ms,
        .restart_limit = @intCast(restart_limit),
    };
}

fn parseTimeouts(object: std.json.ObjectMap) error{
    McpConfigInvalidStartupTimeout,
    McpConfigInvalidOperationTimeout,
}!ParsedTimeouts {
    const startup_ms = parseUnsignedPolicy(
        object,
        "startup_timeout_ms",
        mcp_contract.default_startup_timeout_ms,
        1,
        std.math.maxInt(u32),
    ) catch return error.McpConfigInvalidStartupTimeout;
    const operation_ms = parseUnsignedPolicy(
        object,
        "operation_timeout_ms",
        mcp_contract.default_operation_timeout_ms,
        1,
        std.math.maxInt(u32),
    ) catch return error.McpConfigInvalidOperationTimeout;
    return .{
        .startup_ms = @intCast(startup_ms),
        .operation_ms = @intCast(operation_ms),
    };
}

fn parseRemoteHeaders(
    alloc: Allocator,
    object: std.json.ObjectMap,
    allow_authorization: bool,
) ![]McpHttpHeader {
    const value = object.get("headers") orelse return @constCast(&.{});
    if (value != .object) return error.McpConfigInvalidHeaders;
    var headers: std.ArrayList(McpHttpHeader) = .empty;
    errdefer freeHttpHeaderList(alloc, &headers);
    try headers.ensureTotalCapacity(alloc, value.object.count());
    var it = value.object.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* != .string or
            (!allow_authorization and std.ascii.eqlIgnoreCase(entry.key_ptr.*, "authorization")))
        {
            return error.McpConfigInvalidHeaders;
        }
        const owned_name = try alloc.dupe(u8, entry.key_ptr.*);
        errdefer alloc.free(owned_name);
        const owned_value = try alloc.dupe(u8, entry.value_ptr.*.string);
        headers.appendAssumeCapacity(.{ .name = owned_name, .value = owned_value });
    }
    streamable_http.validateStaticHeaders(headers.items) catch return error.McpConfigInvalidHeaders;
    return headers.toOwnedSlice(alloc);
}

fn parseRemoteHeaderEnv(alloc: Allocator, object: std.json.ObjectMap) ![]McpHttpHeaderEnv {
    const value = object.get("header_env") orelse return @constCast(&.{});
    if (value != .object) return error.McpConfigInvalidHeaders;
    var refs: std.ArrayList(McpHttpHeaderEnv) = .empty;
    errdefer freeHttpHeaderEnvList(alloc, &refs);
    var it = value.object.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* != .string or
            !isValidEnvName(entry.value_ptr.*.string) or
            std.ascii.eqlIgnoreCase(entry.key_ptr.*, "authorization")) return error.McpConfigInvalidHeaders;
        for (refs.items) |previous| {
            if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, previous.name)) return error.McpConfigInvalidHeaders;
        }
        const owned_name = try alloc.dupe(u8, entry.key_ptr.*);
        errdefer alloc.free(owned_name);
        const owned_env = try alloc.dupe(u8, entry.value_ptr.*.string);
        errdefer alloc.free(owned_env);
        try refs.append(alloc, .{
            .name = owned_name,
            .env = owned_env,
        });
    }
    const validation = try alloc.alloc(McpHttpHeader, refs.items.len);
    defer alloc.free(validation);
    for (refs.items, 0..) |ref, index| validation[index] = .{ .name = ref.name, .value = @constCast("value") };
    streamable_http.validateStaticHeaders(validation) catch return error.McpConfigInvalidHeaders;
    return refs.toOwnedSlice(alloc);
}

fn parseProfileAuth(alloc: Allocator, object: std.json.ObjectMap) !?McpAuthConfig {
    const value = object.get("oauth") orelse return null;
    if (value != .object) return error.McpConfigInvalidOAuth;
    const auth_object = value.object;
    var auth: McpAuthConfig = .{};
    errdefer auth.deinit(alloc);
    auth.resource = try parseOptionalOwnedString(alloc, auth_object, "resource");
    auth.issuer = try parseOptionalOwnedString(alloc, auth_object, "issuer");
    auth.client_id = try parseOptionalOwnedString(alloc, auth_object, "client_id");
    auth.client_secret_env = try parseOptionalOwnedString(alloc, auth_object, "client_secret_env");
    auth.client_metadata_url = try parseOptionalOwnedString(alloc, auth_object, "client_metadata_url");
    if (auth_object.get("scopes")) |field| auth.scopes = try parseStringArray(alloc, field);
    if (auth.client_secret_env) |field| {
        if (!isValidEnvName(field) or auth.client_id == null) return error.McpConfigInvalidOAuth;
    }
    if (auth.resource) |field| {
        const canonical = mcp_auth.canonicalResource(alloc, field) catch return error.McpConfigInvalidOAuth;
        alloc.free(canonical);
    }
    if (auth.client_metadata_url) |field| mcp_auth.validateClientMetadataUrl(field) catch return error.McpConfigInvalidOAuth;
    return auth;
}

fn parseOptionalOwnedString(alloc: Allocator, object: std.json.ObjectMap, key: []const u8) !?[]u8 {
    const value = object.get(key) orelse return null;
    if (value == .null) return null;
    if (value != .string or std.mem.trim(u8, value.string, " \t\r\n").len == 0) return error.McpConfigInvalidOAuth;
    return @as(?[]u8, try alloc.dupe(u8, value.string));
}

fn isValidEnvName(value: []const u8) bool {
    if (value.len == 0 or !(std.ascii.isAlphabetic(value[0]) or value[0] == '_')) return false;
    for (value[1..]) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '_') return false;
    return true;
}

fn parseUnsignedPolicy(
    object: std.json.ObjectMap,
    key: []const u8,
    default_value: anytype,
    min_value: u64,
    max_value: u64,
) !u64 {
    const value = object.get(key) orelse return @intCast(default_value);
    if (value != .integer or value.integer < 0) return error.McpConfigInvalidPolicy;
    const parsed = std.math.cast(u64, value.integer) orelse return error.McpConfigInvalidPolicy;
    if (parsed < min_value or parsed > max_value) return error.McpConfigInvalidPolicy;
    return parsed;
}

fn parseSelectedEnvironment(alloc: Allocator, object: std.json.ObjectMap) ![]McpEnvVar {
    const value = if (object.get("environment")) |environment|
        environment
    else
        object.get("env") orelse return @constCast(&.{});
    return parseEnvironment(alloc, value);
}

const ParsedCommandSpec = struct { command: []u8, args: [][]u8 };

fn parseCommandSpec(alloc: Allocator, object: std.json.ObjectMap) !ParsedCommandSpec {
    const command_value = object.get("command") orelse return error.McpMissingCommand;
    switch (command_value) {
        .string => {
            const args: [][]u8 = if (object.get("args")) |field|
                try parseStringArray(alloc, field)
            else
                @constCast(&.{});
            errdefer freeOwnedStrings(alloc, args);
            return .{
                .command = try alloc.dupe(u8, command_value.string),
                .args = args,
            };
        },
        .array => {
            if (command_value.array.items.len == 0 or command_value.array.items[0] != .string) {
                return error.McpMissingCommand;
            }
            const command = try alloc.dupe(u8, command_value.array.items[0].string);
            errdefer alloc.free(command);
            const args = try alloc.alloc([]u8, command_value.array.items.len - 1);
            errdefer alloc.free(args);
            var initialized: usize = 0;
            errdefer for (args[0..initialized]) |arg| alloc.free(arg);
            for (command_value.array.items[1..], 0..) |field, index| {
                if (field != .string) return error.McpMissingCommand;
                args[index] = try alloc.dupe(u8, field.string);
                initialized += 1;
            }
            return .{ .command = command, .args = args };
        },
        else => return error.McpMissingCommand,
    }
}

fn freeParsedCommandSpec(alloc: Allocator, spec: ParsedCommandSpec) void {
    alloc.free(spec.command);
    freeOwnedStrings(alloc, spec.args);
}

fn parseEnvironment(alloc: Allocator, value: std.json.Value) ![]McpEnvVar {
    if (value != .object) return error.McpConfigInvalidEnvironment;
    var vars: std.ArrayList(McpEnvVar) = .empty;
    errdefer {
        for (vars.items) |entry| {
            alloc.free(entry.key);
            alloc.free(entry.value);
        }
        vars.deinit(alloc);
    }
    var it = value.object.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* != .string) return error.McpConfigInvalidEnvironment;
        const key = try alloc.dupe(u8, entry.key_ptr.*);
        errdefer alloc.free(key);
        const entry_value = try alloc.dupe(u8, entry.value_ptr.*.string);
        errdefer alloc.free(entry_value);
        try vars.append(alloc, .{
            .key = key,
            .value = entry_value,
        });
    }
    return vars.toOwnedSlice(alloc);
}

fn parseStringArray(alloc: Allocator, value: std.json.Value) ![][]u8 {
    if (value != .array) return error.McpConfigInvalidStringArray;
    const items = try alloc.alloc([]u8, value.array.items.len);
    errdefer alloc.free(items);
    var initialized: usize = 0;
    errdefer for (items[0..initialized]) |item| alloc.free(item);
    for (value.array.items, 0..) |field, index| {
        if (field != .string) return error.McpConfigInvalidStringArray;
        items[index] = try alloc.dupe(u8, field.string);
        initialized += 1;
    }
    return items;
}

fn parseUniqueStringArray(alloc: Allocator, value: std.json.Value) ![][]u8 {
    const parsed = try parseStringArray(alloc, value);
    var parsed_owned = true;
    errdefer if (parsed_owned) freeOwnedStrings(alloc, parsed);
    var unique: std.ArrayList([]u8) = .empty;
    errdefer freeOwnedList(alloc, &unique);
    for (parsed) |name| {
        if (name.len == 0) return error.InvalidProjectMcpChoices;
        if (!containsName(unique.items, name)) try appendOwnedName(alloc, &unique, name);
    }
    freeOwnedStrings(alloc, parsed);
    parsed_owned = false;
    return unique.toOwnedSlice(alloc);
}

fn appendNamesExcept(
    alloc: Allocator,
    output: *std.ArrayList([]u8),
    input: []const []const u8,
    excluded: ?[]const u8,
) !void {
    for (input) |name| {
        if (excluded) |value| if (std.mem.eql(u8, name, value)) continue;
        if (!containsName(output.items, name)) try appendOwnedName(alloc, output, name);
    }
}

fn appendOwnedName(
    alloc: Allocator,
    output: *std.ArrayList([]u8),
    name: []const u8,
) !void {
    const owned = try alloc.dupe(u8, name);
    errdefer alloc.free(owned);
    try output.append(alloc, owned);
}

fn cloneStrings(alloc: Allocator, values: []const []const u8) ![][]u8 {
    const result = try alloc.alloc([]u8, values.len);
    errdefer alloc.free(result);
    var initialized: usize = 0;
    errdefer for (result[0..initialized]) |value| alloc.free(value);
    for (values, 0..) |value, index| {
        result[index] = try alloc.dupe(u8, value);
        initialized += 1;
    }
    return result;
}

fn containsName(values: []const []const u8, name: []const u8) bool {
    for (values) |value| if (std.mem.eql(u8, value, name)) return true;
    return false;
}

fn configNamePresent(configs: []const McpServerConfig, name: []const u8) bool {
    for (configs) |config| if (std.mem.eql(u8, config.name, name)) return true;
    return false;
}

fn deinitConfigs(alloc: Allocator, configs: *std.ArrayList(McpServerConfig)) void {
    for (configs.items) |*config| config.deinit(alloc);
    configs.deinit(alloc);
}

fn freeOwnedStrings(alloc: Allocator, values: []const []const u8) void {
    if (values.len == 0) return;
    for (values) |value| alloc.free(value);
    alloc.free(values);
}

fn freeOwnedList(alloc: Allocator, values: *std.ArrayList([]u8)) void {
    for (values.items) |value| alloc.free(value);
    values.deinit(alloc);
}

fn freeEnvVars(alloc: Allocator, vars: []const McpEnvVar) void {
    mcp_contract.freeEnvVars(alloc, vars);
}

fn freeHttpHeaders(alloc: Allocator, headers: []const McpHttpHeader) void {
    if (headers.len == 0) return;
    for (headers) |header| {
        alloc.free(header.name);
        alloc.free(header.value);
    }
    alloc.free(headers);
}

fn freeHttpHeaderEnv(alloc: Allocator, headers: []const McpHttpHeaderEnv) void {
    mcp_contract.freeHttpHeaderEnv(alloc, headers);
}

fn freeHttpHeaderList(alloc: Allocator, headers: *std.ArrayList(McpHttpHeader)) void {
    for (headers.items) |header| {
        alloc.free(header.name);
        alloc.free(header.value);
    }
    headers.deinit(alloc);
}

fn freeHttpHeaderEnvList(alloc: Allocator, headers: *std.ArrayList(McpHttpHeaderEnv)) void {
    for (headers.items) |header| {
        alloc.free(header.name);
        alloc.free(header.env);
    }
    headers.deinit(alloc);
}

test "profile document accepts mcpServers alias and preserves strict entry parsing" {
    const alloc = std.testing.allocator;
    var result = try parseProfileDocument(
        alloc,
        "{\"mcpServers\":{\"local\":{\"command\":\"node\",\"args\":[\"server.js\"]}}}",
    );
    defer result.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 1), result.configs.items.len);
    try std.testing.expectEqualStrings("local", result.configs.items[0].name);
    try std.testing.expectEqualStrings("node", result.configs.items[0].command.?);
    try std.testing.expect(result.diagnostic == null);
    try std.testing.expect(result.mutation_allowed);
}

test "profile document keeps canonical mcp and reports ignored nonempty alias" {
    const alloc = std.testing.allocator;
    var result = try parseProfileDocument(
        alloc,
        "{\"mcp\":{\"canonical\":{\"command\":\"one\"}},\"mcpServers\":{\"ignored\":{\"command\":\"two\"}}}",
    );
    defer result.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 1), result.configs.items.len);
    try std.testing.expectEqualStrings("canonical", result.configs.items[0].name);
    try std.testing.expectEqual(ProfileDiagnosticCause.ignored_mcp_servers_alias, result.diagnostic.?.cause);
    try std.testing.expect(result.mutation_allowed);
}

test "profile document blocks suspicious sibling keys beside canonical mcp" {
    const alloc = std.testing.allocator;
    var result = try parseProfileDocument(
        alloc,
        "{\"mcp\":{\"canonical\":{\"command\":\"one\"}},\"MCP-Servers\":{\"shadow\":{\"command\":\"two\"}},\"metadata\":{\"owner\":\"team\"}}",
    );
    defer result.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 1), result.configs.items.len);
    try std.testing.expectEqualStrings("canonical", result.configs.items[0].name);
    try std.testing.expect(result.diagnostic != null);
    try std.testing.expectEqual(ProfileDiagnosticCause.suspicious_server_key, result.diagnostic.?.cause);
    try std.testing.expectEqualStrings("MCP-Servers", result.diagnostic.?.key().?);
    try std.testing.expect(!result.mutation_allowed);
}

test "profile document reports the first exact server-like unsupported key" {
    const alloc = std.testing.allocator;
    var result = try parseProfileDocument(
        alloc,
        "{\"metadata\":{\"entry\":{\"command\":\"ignored\"}},\"MCP-Servers\":{\"one\":{\"command\":\"node\"}},\"servers\":{\"two\":{\"url\":\"https://example.test/mcp\"}}}",
    );
    defer result.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 0), result.configs.items.len);
    try std.testing.expectEqual(ProfileDiagnosticCause.suspicious_server_key, result.diagnostic.?.cause);
    try std.testing.expectEqualStrings("MCP-Servers", result.diagnostic.?.key().?);
    try std.testing.expectEqual(@as(usize, 1), result.diagnostic.?.additional_matches);
    try std.testing.expect(!result.mutation_allowed);
}

test "profile document bounds suspicious-key scans" {
    const alloc = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeByte('{');
    for (0..65) |index| {
        if (index > 0) try out.writer.writeByte(',');
        try out.writer.print("\"metadata{d}\":{{}}", .{index});
    }
    try out.writer.writeByte('}');
    const json = try out.toOwnedSlice();
    defer alloc.free(json);

    var result = try parseProfileDocument(alloc, json);
    defer result.deinit(alloc);
    try std.testing.expectEqual(ProfileDiagnosticCause.suspicious_key_scan_indeterminate, result.diagnostic.?.cause);
    try std.testing.expect(!result.mutation_allowed);
}

test "profile parser preserves validation precedence for multiply invalid entries" {
    const cases = .{
        .{
            .json = "{\"mcp\":{\"bad\":{\"type\":\"http\",\"startup_timeout_ms\":0,\"env\":3}}}",
            .expected = error.McpConfigMissingUrl,
        },
        .{
            .json = "{\"mcp\":{\"bad\":{\"type\":\"http\",\"url\":\"https://example.test/mcp\",\"startup_timeout_ms\":0,\"env\":3}}}",
            .expected = error.McpConfigInvalidStartupTimeout,
        },
        .{
            .json = "{\"mcp\":{\"bad\":{\"startup_timeout_ms\":0,\"restart_limit\":999,\"command\":3,\"env\":3}}}",
            .expected = error.McpConfigInvalidStartupTimeout,
        },
        .{
            .json = "{\"mcp\":{\"bad\":{\"restart_limit\":999,\"command\":3,\"env\":3}}}",
            .expected = error.McpConfigInvalidRestartLimit,
        },
        .{
            .json = "{\"mcp\":{\"bad\":{\"command\":3,\"env\":3}}}",
            .expected = error.McpConfigInvalidCommand,
        },
    };
    inline for (cases) |case| {
        try std.testing.expectError(
            case.expected,
            parseProfileJson(std.testing.allocator, case.json),
        );
    }
}

test "workspace parsing stamps optional credential-isolated configs" {
    const alloc = std.testing.allocator;
    const json =
        \\{"mcpServers":{"local":{"command":"node","args":["server.js"],"required":true},"remote":{"type":"http","url":"https://example.test/mcp"}}}
    ;
    var result = try parseWorkspaceJson(alloc, json, .workspace, .{});
    defer result.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), result.configs.items.len);
    for (result.configs.items) |config| {
        try std.testing.expectEqual(mcp_contract.ConfigSource.workspace, config.source);
        try std.testing.expectEqual(mcp_contract.ConfigScope.workspace, config.scope);
        try std.testing.expect(!config.required);
        try std.testing.expect(!config.allow_stored_credentials);
        try std.testing.expectEqual(mcp_contract.WorkspaceAdmission.pending, config.workspace_admission.?);
    }
}

test "workspace template expansion is explicit bounded and deterministic" {
    const alloc = std.testing.allocator;
    var environment = std.process.Environ.Map.init(alloc);
    defer environment.deinit();
    try environment.put("SET", "value");
    try environment.put("EMPTY", "");

    const cases = [_]struct {
        input: []const u8,
        expected: []const u8,
    }{
        .{ .input = "plain", .expected = "plain" },
        .{ .input = "before-${SET}-after", .expected = "before-value-after" },
        .{ .input = "${MISSING:-fallback}", .expected = "fallback" },
        .{ .input = "${EMPTY:-fallback}", .expected = "" },
        .{ .input = "${SET}/${SET}", .expected = "value/value" },
    };
    for (cases) |case| {
        var budget = WorkspaceExpansionBudget.init();
        var expansion = try expandWorkspaceTemplate(alloc, case.input, &environment, &budget);
        defer expansion.deinit(alloc);
        switch (expansion) {
            .expanded => |value| try std.testing.expectEqualStrings(case.expected, value),
            .missing, .invalid, .limit_exceeded => return error.TestUnexpectedResult,
        }
    }

    var missing_budget = WorkspaceExpansionBudget.init();
    var missing = try expandWorkspaceTemplate(alloc, "Bearer ${REQUIRED}", &environment, &missing_budget);
    defer missing.deinit(alloc);
    switch (missing) {
        .missing => |name| try std.testing.expectEqualStrings("REQUIRED", name),
        .expanded, .invalid, .limit_exceeded => return error.TestUnexpectedResult,
    }

    var malformed_budget = WorkspaceExpansionBudget.init();
    var malformed = try expandWorkspaceTemplate(alloc, "${NOT-CLOSED", &environment, &malformed_budget);
    defer malformed.deinit(alloc);
    try std.testing.expect(malformed == .invalid);

    var long_name: [129]u8 = undefined;
    long_name[0] = 'A';
    @memset(long_name[1..], 'B');
    try environment.put(&long_name, "long-name-value");
    const long_template = try std.fmt.allocPrint(alloc, "${{{s}}}", .{long_name});
    defer alloc.free(long_template);
    var long_budget = WorkspaceExpansionBudget.init();
    var long_expansion = try expandWorkspaceTemplate(
        alloc,
        long_template,
        &environment,
        &long_budget,
    );
    defer long_expansion.deinit(alloc);
    switch (long_expansion) {
        .expanded => |value| try std.testing.expectEqualStrings("long-name-value", value),
        .missing, .invalid, .limit_exceeded => return error.TestUnexpectedResult,
    }
}

test "workspace environment diagnostics isolate entries and profile values stay literal" {
    const alloc = std.testing.allocator;
    var environment = std.process.Environ.Map.init(alloc);
    defer environment.deinit();
    try environment.put("COMMAND", "node");
    var approved_names = [_][]u8{ @constCast("good"), @constCast("bad") };

    var workspace = try parseWorkspaceJsonWithEnvironment(
        alloc,
        "{\"mcpServers\":{\"good\":{\"command\":\"${COMMAND}\"},\"bad\":{\"command\":\"${REQUIRED}\"}}}",
        .workspace,
        .{ .approved = &approved_names },
        &environment,
    );
    defer workspace.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), workspace.configs.items.len);
    try std.testing.expectEqualStrings("node", workspace.configs.items[0].command.?);
    try std.testing.expectEqual(@as(usize, 1), workspace.diagnostics.items.len);
    const diagnostic = workspace.diagnostics.items[0];
    try std.testing.expectEqual(WorkspaceDiagnosticCause.missing_environment_variable, diagnostic.cause);
    try std.testing.expectEqual(WorkspaceEnvironmentField.command, diagnostic.environment_field.?);
    try std.testing.expectEqualStrings("REQUIRED", diagnostic.environment_variable.?);

    var profile = try parseProfileDocument(
        alloc,
        "{\"mcp\":{\"literal\":{\"command\":\"${COMMAND}\"}}}",
    );
    defer profile.deinit(alloc);
    try std.testing.expectEqualStrings("${COMMAND}", profile.configs.items[0].command.?);
}

test "workspace environment expansion requires approved admission" {
    const alloc = std.testing.allocator;
    var environment = std.process.Environ.Map.init(alloc);
    defer environment.deinit();
    try environment.put("COMMAND", "node");
    try environment.put("VALUE", "expanded");

    var workspace = try parseWorkspaceJsonWithEnvironment(
        alloc,
        "{\"mcpServers\":{\"local\":{\"command\":\"${COMMAND}\",\"args\":[\"${VALUE}\"],\"env\":{\"TOKEN\":\"${VALUE}\"}},\"remote\":{\"type\":\"http\",\"url\":\"https://example.test/mcp\",\"headers\":{\"Authorization\":\"Bearer ${VALUE}\"}}}}",
        .workspace,
        .{},
        &environment,
    );
    defer workspace.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 2), workspace.configs.items.len);
    try std.testing.expectEqualStrings("${COMMAND}", workspace.configs.items[0].command.?);
    try std.testing.expectEqualStrings("${VALUE}", workspace.configs.items[0].args[0]);
    try std.testing.expectEqualStrings("${VALUE}", workspace.configs.items[0].env[0].value);
    try std.testing.expectEqualStrings("Bearer ${VALUE}", workspace.configs.items[1].headers[0].value);
    try std.testing.expectEqual(@as(usize, 0), workspace.diagnostics.items.len);
}

test "workspace environment expansion enforces one aggregate file budget" {
    const alloc = std.testing.allocator;
    var environment = std.process.Environ.Map.init(alloc);
    defer environment.deinit();
    const large = try alloc.alloc(u8, 600 * 1024);
    defer alloc.free(large);
    @memset(large, 'x');
    try environment.put("LARGE", large);
    var approved_names = [_][]u8{ @constCast("first"), @constCast("second") };

    var workspace = try parseWorkspaceJsonWithEnvironment(
        alloc,
        "{\"mcpServers\":{\"first\":{\"command\":\"${LARGE}\"},\"second\":{\"command\":\"${LARGE}\"}}}",
        .workspace,
        .{ .approved = &approved_names },
        &environment,
    );
    defer workspace.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 1), workspace.configs.items.len);
    try std.testing.expectEqualStrings("first", workspace.configs.items[0].name);
    try std.testing.expectEqual(@as(usize, 1), workspace.diagnostics.items.len);
    try std.testing.expectEqual(
        WorkspaceDiagnosticCause.environment_expansion_limit_exceeded,
        workspace.diagnostics.items[0].cause,
    );
    try std.testing.expectEqualStrings("second", workspace.diagnostics.items[0].server_name.?);
}

test "workspace environment expansion never refunds rejected entry work" {
    const alloc = std.testing.allocator;
    var environment = std.process.Environ.Map.init(alloc);
    defer environment.deinit();
    const large = try alloc.alloc(u8, 600 * 1024);
    defer alloc.free(large);
    @memset(large, 'x');
    try environment.put("LARGE", large);
    var approved_names = [_][]u8{ @constCast("rejected_late"), @constCast("later") };

    var workspace = try parseWorkspaceJsonWithEnvironment(
        alloc,
        "{\"mcpServers\":{\"rejected_late\":{\"command\":\"${LARGE}\",\"args\":[\"${MISSING}\"]},\"later\":{\"command\":\"${LARGE}\"}}}",
        .workspace,
        .{ .approved = &approved_names },
        &environment,
    );
    defer workspace.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 0), workspace.configs.items.len);
    try std.testing.expectEqual(@as(usize, 2), workspace.diagnostics.items.len);
    try std.testing.expectEqual(
        WorkspaceDiagnosticCause.missing_environment_variable,
        workspace.diagnostics.items[0].cause,
    );
    try std.testing.expectEqual(
        WorkspaceDiagnosticCause.environment_expansion_limit_exceeded,
        workspace.diagnostics.items[1].cause,
    );
}

test "workspace environment expansion rejects exhausted budget before allocation" {
    const alloc = std.testing.allocator;
    var environment = std.process.Environ.Map.init(alloc);
    defer environment.deinit();
    try environment.put("TOKEN", "secret");

    var failing = std.testing.FailingAllocator.init(alloc, .{ .fail_index = 0 });
    var value: []const u8 = "${TOKEN}";
    var budget = WorkspaceExpansionBudget{ .remaining = 0 };
    const failure = expandOwnedConstWorkspaceValue(
        failing.allocator(),
        &value,
        &environment,
        .command,
        &budget,
    ) catch |err| {
        try std.testing.expect(err != error.OutOfMemory);
        return;
    };
    try std.testing.expect(failure != null);
    try std.testing.expect(failure.? == .limit_exceeded);
}

test "workspace Authorization header expansion does not broaden profile headers" {
    const alloc = std.testing.allocator;
    var environment = std.process.Environ.Map.init(alloc);
    defer environment.deinit();
    try environment.put("TOKEN", "secret");
    var approved_names = [_][]u8{@constCast("remote")};

    var workspace = try parseWorkspaceJsonWithEnvironment(
        alloc,
        "{\"mcpServers\":{\"remote\":{\"type\":\"http\",\"url\":\"https://example.test/mcp\",\"headers\":{\"Authorization\":\"Bearer ${TOKEN}\"}}}}",
        .workspace,
        .{ .approved = &approved_names },
        &environment,
    );
    defer workspace.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), workspace.configs.items.len);
    try std.testing.expectEqualStrings("Bearer secret", workspace.configs.items[0].headers[0].value);

    try std.testing.expectError(
        error.McpConfigInvalidHeaders,
        parseProfileJson(
            alloc,
            "{\"mcp\":{\"remote\":{\"type\":\"http\",\"url\":\"https://example.test/mcp\",\"headers\":{\"Authorization\":\"Bearer ${TOKEN}\"}}}}",
        ),
    );
}

test "workspace parsing isolates invalid entries" {
    const alloc = std.testing.allocator;
    const json =
        \\{"mcpServers":{"good":{"command":["node","server.js"]},"bad":{"command":3}}}
    ;
    var result = try parseWorkspaceJson(alloc, json, .workspace, .{});
    defer result.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), result.configs.items.len);
    try std.testing.expectEqualStrings("good", result.configs.items[0].name);
    try std.testing.expectEqual(@as(usize, 1), result.diagnostics.items.len);
    try std.testing.expectEqualStrings("bad", result.diagnostics.items[0].server_name.?);
}

test "choice transitions are normalized and reject precedence is stable" {
    const alloc = std.testing.allocator;
    var current = ProjectMcpChoices{
        .enable_all = true,
        .approved = try cloneStrings(alloc, &.{ "alpha", "beta" }),
        .rejected = try cloneStrings(alloc, &.{"gamma"}),
    };
    defer current.deinit(alloc);
    var rejected = try applyAction(alloc, current, .{ .reject = "alpha" });
    defer rejected.choices.deinit(alloc);
    try std.testing.expect(rejected.authority_reduced);
    try std.testing.expectEqual(mcp_contract.WorkspaceAdmission.rejected, resolveAdmission("alpha", rejected.choices));
    try std.testing.expectEqual(mcp_contract.WorkspaceAdmission.approved, resolveAdmission("beta", rejected.choices));

    var approved = try applyAction(alloc, rejected.choices, .{ .approve = "alpha" });
    defer approved.choices.deinit(alloc);
    try std.testing.expect(!approved.authority_reduced);
    try std.testing.expectEqual(mcp_contract.WorkspaceAdmission.approved, resolveAdmission("alpha", approved.choices));
}

test "native merge keeps the primary whole entry" {
    const alloc = std.testing.allocator;
    var primary: std.ArrayList(McpServerConfig) = .empty;
    defer deinitConfigs(alloc, &primary);
    try primary.append(alloc, .{ .name = try alloc.dupe(u8, "same"), .command = try alloc.dupe(u8, "profile") });
    var workspace: std.ArrayList(McpServerConfig) = .empty;
    defer deinitConfigs(alloc, &workspace);
    try workspace.append(alloc, .{
        .name = try alloc.dupe(u8, "same"),
        .source = .workspace,
        .scope = .workspace,
        .command = try alloc.dupe(u8, "workspace"),
        .workspace_admission = .approved,
    });
    try workspace.append(alloc, .{
        .name = try alloc.dupe(u8, "only"),
        .source = .workspace,
        .scope = .workspace,
        .command = try alloc.dupe(u8, "workspace"),
        .workspace_admission = .approved,
    });
    var merged = try mergeNative(alloc, &primary, &workspace);
    defer deinitConfigs(alloc, &merged);
    try std.testing.expectEqual(@as(usize, 2), merged.items.len);
    try std.testing.expectEqualStrings("profile", merged.items[0].command.?);
    try std.testing.expectEqualStrings("only", merged.items[1].name);
}

test "ACP primary duplicates remain ordered while workspace collisions are excluded" {
    const alloc = std.testing.allocator;
    var output: std.ArrayList(McpServerConfig) = .empty;
    defer deinitConfigs(alloc, &output);
    try output.append(alloc, .{
        .name = try alloc.dupe(u8, "same"),
        .source = .acp,
        .scope = .acp_session,
        .command = try alloc.dupe(u8, "one"),
    });
    try output.append(alloc, .{
        .name = try alloc.dupe(u8, "same"),
        .source = .acp,
        .scope = .acp_session,
        .command = try alloc.dupe(u8, "two"),
    });
    var workspace: std.ArrayList(McpServerConfig) = .empty;
    defer deinitConfigs(alloc, &workspace);
    try workspace.append(alloc, .{
        .name = try alloc.dupe(u8, "same"),
        .source = .workspace,
        .scope = .workspace,
        .command = try alloc.dupe(u8, "workspace"),
        .workspace_admission = .pending,
    });
    try workspace.append(alloc, .{
        .name = try alloc.dupe(u8, "only"),
        .source = .workspace,
        .scope = .workspace,
        .command = try alloc.dupe(u8, "workspace"),
        .workspace_admission = .pending,
    });
    try appendWorkspaceAfterAcpPrimary(alloc, &output, &workspace);
    try std.testing.expectEqual(@as(usize, 3), output.items.len);
    try std.testing.expectEqualStrings("one", output.items[0].command.?);
    try std.testing.expectEqualStrings("two", output.items[1].command.?);
    try std.testing.expectEqualStrings("only", output.items[2].name);
}

test "authority projection detects only removed workspace names" {
    const alloc = std.testing.allocator;
    const configs = [_]McpServerConfig{
        .{ .name = "approved", .source = .workspace, .scope = .workspace, .workspace_admission = .approved },
        .{ .name = "pending", .source = .workspace, .scope = .workspace, .workspace_admission = .pending },
        .{ .name = "profile", .source = .profile, .scope = .profile },
    };
    const interactive = try authorityNames(alloc, &configs, .all);
    defer freeOwnedStrings(alloc, interactive);
    try std.testing.expectEqual(@as(usize, 1), interactive.len);
    try std.testing.expectEqualStrings("approved", interactive[0]);
    const headless = try authorityNames(alloc, &configs, .acp_startup);
    defer freeOwnedStrings(alloc, headless);
    try std.testing.expectEqual(@as(usize, 1), headless.len);
    try std.testing.expectEqualStrings("approved", headless[0]);
}

test "workspace parsing releases every partial allocation failure" {
    const json =
        \\{"mcpServers":{"bad":{"command":3},"remote":{"type":"http","url":"https://example.test/mcp","env":{"TOKEN":"value"},"header_env":{"X-Test":"TEST_ENV"}},"local":{"command":"node","args":["server.js"],"env":{"A":"B"}}}}
    ;
    var fail_index: usize = 0;
    while (fail_index < 256) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(
            std.testing.allocator,
            .{ .fail_index = fail_index },
        );
        var result = parseWorkspaceJson(failing.allocator(), json, .workspace, .{}) catch |err| switch (err) {
            error.OutOfMemory => continue,
        };
        result.deinit(failing.allocator());
        break;
    }
    try std.testing.expect(fail_index < 256);
}

test "choice parsing and mutation release every partial allocation failure" {
    const alloc = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        "{\"enabledMcpjsonServers\":[\"alpha\",\"overlap\"],\"disabledMcpjsonServers\":[\"overlap\",\"beta\"],\"enableAllProjectMcpServers\":true}",
        .{},
    );
    defer parsed.deinit();
    var fail_index: usize = 0;
    while (fail_index < 128) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(
            alloc,
            .{ .fail_index = fail_index },
        );
        var diagnostics: std.ArrayList(WorkspaceDiagnostic) = .empty;
        defer {
            for (diagnostics.items) |*diagnostic| diagnostic.deinit(failing.allocator());
            diagnostics.deinit(failing.allocator());
        }
        var choices = parseChoices(
            failing.allocator(),
            parsed.value,
            &diagnostics,
        ) catch |err| switch (err) {
            error.OutOfMemory => continue,
            else => return err,
        };
        choices.deinit(failing.allocator());
        break;
    }
    try std.testing.expect(fail_index < 128);

    var current = ProjectMcpChoices{
        .enable_all = true,
        .approved = try cloneStrings(alloc, &.{ "alpha", "beta" }),
        .rejected = try cloneStrings(alloc, &.{ "gamma", "delta" }),
    };
    defer current.deinit(alloc);
    fail_index = 0;
    while (fail_index < 128) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(
            alloc,
            .{ .fail_index = fail_index },
        );
        var transition = applyAction(
            failing.allocator(),
            current,
            .{ .reject = "alpha" },
        ) catch |err| switch (err) {
            error.OutOfMemory => continue,
        };
        transition.choices.deinit(failing.allocator());
        break;
    }
    try std.testing.expect(fail_index < 128);
}
