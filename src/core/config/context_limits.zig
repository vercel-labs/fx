const std = @import("std");

pub const emergency_ceiling_bytes: usize = 64 * 1024 * 1024;

pub const Name = enum {
    skill_description_bytes,
    skill_catalog_bytes,
    skill_chunk_bytes,
    skill_file_bytes,
    mcp_description_bytes,
    mcp_search_result_bytes,
    mcp_server_instructions_bytes,
    mcp_selected_schema_bytes,
    project_instruction_file_bytes,
    project_instructions_total_bytes,
    image_adapter_output_bytes,

    pub fn defaultBytes(self: Name) usize {
        return switch (self) {
            .skill_description_bytes => 1024,
            .skill_catalog_bytes => 16 * 1024,
            .skill_chunk_bytes => 20 * 1024,
            .skill_file_bytes => 1024 * 1024,
            .mcp_description_bytes => 1024,
            .mcp_search_result_bytes => 16 * 1024,
            .mcp_server_instructions_bytes => 2 * 1024,
            .mcp_selected_schema_bytes => 64 * 1024,
            .project_instruction_file_bytes => 64 * 1024,
            .project_instructions_total_bytes => 128 * 1024,
            .image_adapter_output_bytes => 20 * 1024,
        };
    }

    pub fn parse(raw: []const u8) ?Name {
        const name_info = @typeInfo(Name).@"enum";
        inline for (name_info.field_names, name_info.field_values) |field_name, field_value| {
            if (std.mem.eql(u8, raw, field_name)) return @fromBackingInt(@intCast(field_value));
        }
        return null;
    }
};

pub const Source = enum {
    compiled_default,
    user_global,
    user_workspace,
    command_line,

    pub fn label(self: Source) []const u8 {
        return switch (self) {
            .compiled_default => "compiled default",
            .user_global => "global settings",
            .user_workspace => "workspace settings",
            .command_line => "command line",
        };
    }
};

pub const Value = union(enum) {
    bytes: usize,
    off,

    pub fn normalBytes(self: Value) ?usize {
        return switch (self) {
            .bytes => |bytes| bytes,
            .off => null,
        };
    }

    pub fn effectiveBytes(self: Value) usize {
        return @min(self.normalBytes() orelse emergency_ceiling_bytes, emergency_ceiling_bytes);
    }
};

pub const Resolved = struct {
    value: Value,
    source: Source,

    pub fn effectiveBytes(self: Resolved) usize {
        return self.value.effectiveBytes();
    }
};

pub const Override = struct {
    name: Name,
    value: Value,
};

pub const Values = struct {
    skill_description_bytes: Resolved = defaultResolved(.skill_description_bytes),
    skill_catalog_bytes: Resolved = defaultResolved(.skill_catalog_bytes),
    skill_chunk_bytes: Resolved = defaultResolved(.skill_chunk_bytes),
    skill_file_bytes: Resolved = defaultResolved(.skill_file_bytes),
    mcp_description_bytes: Resolved = defaultResolved(.mcp_description_bytes),
    mcp_search_result_bytes: Resolved = defaultResolved(.mcp_search_result_bytes),
    mcp_server_instructions_bytes: Resolved = defaultResolved(.mcp_server_instructions_bytes),
    mcp_selected_schema_bytes: Resolved = defaultResolved(.mcp_selected_schema_bytes),
    project_instruction_file_bytes: Resolved = defaultResolved(.project_instruction_file_bytes),
    project_instructions_total_bytes: Resolved = defaultResolved(.project_instructions_total_bytes),
    image_adapter_output_bytes: Resolved = defaultResolved(.image_adapter_output_bytes),

    pub fn get(self: Values, name: Name) Resolved {
        return switch (name) {
            inline else => |tag| @field(self, @tagName(tag)),
        };
    }

    pub fn apply(self: *Values, overrides: Overrides) void {
        const name_info = @typeInfo(Name).@"enum";
        inline for (name_info.field_names, name_info.field_values) |field_name, field_value| {
            const name: Name = @fromBackingInt(@intCast(field_value));
            if (overrides.get(name)) |value| @field(self, field_name) = value;
        }
    }

    pub fn applyCommandLine(self: *Values, overrides: []const Override) void {
        for (overrides) |override| {
            self.set(override.name, .{ .value = override.value, .source = .command_line });
        }
    }

    pub fn set(self: *Values, name: Name, value: Resolved) void {
        switch (name) {
            inline else => |tag| @field(self, @tagName(tag)) = value,
        }
    }
};

pub const Overrides = struct {
    skill_description_bytes: ?Resolved = null,
    skill_catalog_bytes: ?Resolved = null,
    skill_chunk_bytes: ?Resolved = null,
    skill_file_bytes: ?Resolved = null,
    mcp_description_bytes: ?Resolved = null,
    mcp_search_result_bytes: ?Resolved = null,
    mcp_server_instructions_bytes: ?Resolved = null,
    mcp_selected_schema_bytes: ?Resolved = null,
    project_instruction_file_bytes: ?Resolved = null,
    project_instructions_total_bytes: ?Resolved = null,
    image_adapter_output_bytes: ?Resolved = null,

    pub fn get(self: Overrides, name: Name) ?Resolved {
        return switch (name) {
            inline else => |tag| @field(self, @tagName(tag)),
        };
    }

    pub fn set(self: *Overrides, name: Name, value: Resolved) void {
        switch (name) {
            inline else => |tag| @field(self, @tagName(tag)) = value,
        }
    }

    pub fn retag(self: *Overrides, source: Source) void {
        inline for (@typeInfo(Name).@"enum".field_names) |field_name| {
            if (@field(self, field_name)) |*value| value.source = source;
        }
    }

    pub fn merge(self: *Overrides, incoming: Overrides) void {
        inline for (@typeInfo(Name).@"enum".field_names) |field_name| {
            if (@field(incoming, field_name)) |value| @field(self, field_name) = value;
        }
    }
};

pub fn parseOverride(raw: []const u8) !Override {
    const separator = std.mem.findScalar(u8, raw, '=') orelse return error.InvalidContextLimitOverride;
    const raw_name = std.mem.trim(u8, raw[0..separator], " \t\r\n");
    const raw_value = std.mem.trim(u8, raw[separator + 1 ..], " \t\r\n");
    if (raw_name.len == 0 or raw_value.len == 0) return error.InvalidContextLimitOverride;
    return .{
        .name = Name.parse(raw_name) orelse return error.UnknownContextLimit,
        .value = try parseValueString(raw_value),
    };
}

pub fn parseJsonObject(value: std.json.Value) !Overrides {
    if (value != .object) return error.InvalidContextLimitsType;

    var result = Overrides{};
    var iterator = value.object.iterator();
    while (iterator.next()) |entry| {
        const name = Name.parse(entry.key_ptr.*) orelse return error.UnknownContextLimit;
        result.set(name, .{
            .value = try parseJsonValue(entry.value_ptr.*),
            .source = .compiled_default,
        });
    }
    return result;
}

fn parseJsonValue(value: std.json.Value) !Value {
    return switch (value) {
        .integer => |integer| .{ .bytes = std.math.cast(usize, integer) orelse return error.InvalidContextLimitValue },
        .string => |string| parseValueString(string),
        else => error.InvalidContextLimitValue,
    };
}

fn parseValueString(raw: []const u8) !Value {
    if (std.ascii.eqlIgnoreCase(raw, "off")) return .off;
    return .{ .bytes = std.fmt.parseUnsigned(usize, raw, 10) catch return error.InvalidContextLimitValue };
}

fn defaultResolved(comptime name: Name) Resolved {
    return .{
        .value = .{ .bytes = name.defaultBytes() },
        .source = .compiled_default,
    };
}

pub fn utf8PrefixLength(bytes: []const u8, max_bytes: usize) usize {
    var end = @min(max_bytes, bytes.len);
    while (end > 0 and !std.unicode.utf8ValidateSlice(bytes[0..end])) : (end -= 1) {}
    return end;
}

pub fn lineSafePrefixLength(bytes: []const u8, max_bytes: usize) usize {
    const utf8_end = utf8PrefixLength(bytes, max_bytes);
    if (utf8_end == bytes.len) return utf8_end;
    if (std.mem.findScalarLast(u8, bytes[0..utf8_end], '\n')) |newline| return newline + 1;
    return utf8_end;
}

test "defaults match the public context limit contract" {
    const values = Values{};
    inline for (@typeInfo(Name).@"enum".field_values) |field_value| {
        const name: Name = @fromBackingInt(@intCast(field_value));
        try std.testing.expectEqual(name.defaultBytes(), values.get(name).effectiveBytes());
        try std.testing.expectEqual(Source.compiled_default, values.get(name).source);
    }
}

test "context limit overrides accept bytes and off" {
    const bytes = try parseOverride("skill_chunk_bytes=4096");
    try std.testing.expectEqual(Name.skill_chunk_bytes, bytes.name);
    try std.testing.expectEqual(@as(usize, 4096), bytes.value.bytes);

    const off = try parseOverride("mcp_description_bytes=off");
    try std.testing.expectEqual(Name.mcp_description_bytes, off.name);
    try std.testing.expectEqual(emergency_ceiling_bytes, off.value.effectiveBytes());
}

test "context limit overrides reject unknown names and malformed values" {
    try std.testing.expectError(error.UnknownContextLimit, parseOverride("wat=1"));
    try std.testing.expectError(error.InvalidContextLimitValue, parseOverride("skill_chunk_bytes=-1"));
    try std.testing.expectError(error.InvalidContextLimitOverride, parseOverride("skill_chunk_bytes"));
}

test "line safe prefix preserves utf8 and complete lines when possible" {
    try std.testing.expectEqual(@as(usize, 4), lineSafePrefixLength("one\ntwo\n", 7));
    try std.testing.expectEqual(@as(usize, 0), lineSafePrefixLength("éclair", 1));
    try std.testing.expectEqual(@as(usize, 2), lineSafePrefixLength("éclair", 2));
    try std.testing.expectEqual(@as(usize, 3), lineSafePrefixLength(&.{ 'a', 'b', 'c', 0xe4 }, 4));
}
