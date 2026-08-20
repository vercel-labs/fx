const std = @import("std");

pub const description_max_bytes: usize = 1024;
pub const truncation_marker = "... [truncated]";

pub const JsonType = enum {
    string,
    integer,
    boolean,
    object,
    array,
};

const no_u32_bound = std.math.maxInt(u32);
const no_u64_bound = std.math.maxInt(u64);

const PropertyShape = union(enum) {
    enum_values: []const []const u8,
    object: *const ObjectSchema,
    array_values: struct {
        json_type: JsonType,
        enum_values: []const []const u8 = &.{},
    },
    array_objects: *const ObjectSchema,
};

pub const Property = struct {
    name: []const u8,
    json_type: JsonType,
    description: []const u8 = "",
    nullable: bool = false,
    nullable_description: []const u8 = "",
    shape: ?*const PropertyShape = null,
    min_length: u32 = no_u32_bound,
    max_length: u32 = no_u32_bound,
    minimum: u64 = no_u64_bound,
    maximum: u64 = no_u64_bound,
    min_items: u32 = no_u32_bound,
    max_items: u32 = no_u32_bound,
};

pub const ObjectSchema = struct {
    properties: []const Property = &.{},
    required: []const []const u8 = &.{},
    additional_properties: ?bool = null,
    min_properties: u32 = no_u32_bound,
    max_properties: u32 = no_u32_bound,
    one_of: []const ObjectSchema = &.{},
};

pub const FunctionSchema = struct {
    name: []const u8,
    description: []const u8,
    input_schema: ObjectSchema = .{},
    dynamic_input_schema: ?std.json.Value = null,

    pub fn validate(self: FunctionSchema) error{InvalidToolSchema}!void {
        if (std.mem.trim(u8, self.name, " \t\r\n").len == 0) return error.InvalidToolSchema;
        if (self.dynamic_input_schema) |value| {
            if (value != .object) return error.InvalidToolSchema;
            const schema_type = value.object.get("type") orelse return error.InvalidToolSchema;
            if (schema_type != .string or !std.mem.eql(u8, schema_type.string, "object")) {
                return error.InvalidToolSchema;
            }
            if (value.object.get("properties")) |properties| {
                if (properties != .object) return error.InvalidToolSchema;
            }
            return;
        }
        if (self.input_schema.min_properties != no_u32_bound and
            self.input_schema.max_properties != no_u32_bound and
            self.input_schema.min_properties > self.input_schema.max_properties)
        {
            return error.InvalidToolSchema;
        }
        for (self.input_schema.properties, 0..) |property, index| {
            if (std.mem.trim(u8, property.name, " \t\r\n").len == 0) return error.InvalidToolSchema;
            for (self.input_schema.properties[0..index]) |prior| {
                if (std.mem.eql(u8, prior.name, property.name)) return error.InvalidToolSchema;
            }
        }
        for (self.input_schema.required, 0..) |required, index| {
            for (self.input_schema.required[0..index]) |prior| {
                if (std.mem.eql(u8, prior, required)) return error.InvalidToolSchema;
            }
            for (self.input_schema.properties) |property| {
                if (std.mem.eql(u8, property.name, required)) break;
            } else return error.InvalidToolSchema;
        }
    }
};

test "static property representation stays within the measured size budget" {
    try std.testing.expect(@sizeOf(Property) <= 96);
}

fn cappedDescriptionAlloc(alloc: std.mem.Allocator, text: []const u8) ![]u8 {
    if (text.len <= description_max_bytes) return alloc.dupe(u8, text);

    const prefix_len = description_max_bytes - truncation_marker.len;
    var out = try alloc.alloc(u8, description_max_bytes);
    @memcpy(out[0..prefix_len], text[0..prefix_len]);
    @memcpy(out[prefix_len..], truncation_marker);
    return out;
}

fn writeCappedDescriptionJsonString(
    alloc: std.mem.Allocator,
    writer: *std.Io.Writer,
    text: []const u8,
) !void {
    const capped_description = try cappedDescriptionAlloc(alloc, text);
    defer alloc.free(capped_description);
    try std.json.Stringify.value(capped_description, .{}, writer);
}

pub fn writeInputSchema(
    alloc: std.mem.Allocator,
    writer: *std.Io.Writer,
    descriptor: FunctionSchema,
) !void {
    try descriptor.validate();
    if (descriptor.dynamic_input_schema) |input_schema| {
        try std.json.Stringify.value(input_schema, .{}, writer);
    } else {
        try writeObjectSchema(alloc, writer, descriptor.input_schema);
    }
}

pub fn inputSchemaJsonAlloc(alloc: std.mem.Allocator, schema: FunctionSchema) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try writeInputSchema(alloc, &out.writer, schema);
    return try out.toOwnedSlice();
}

fn writeObjectSchema(
    alloc: std.mem.Allocator,
    writer: *std.Io.Writer,
    schema: ObjectSchema,
) anyerror!void {
    if (schema.one_of.len > 0) {
        if (schema.properties.len > 0 or
            schema.required.len > 0 or
            schema.additional_properties != null or
            schema.min_properties != no_u32_bound or
            schema.max_properties != no_u32_bound)
        {
            return error.InvalidObjectSchema;
        }
        try writer.writeAll("{\"oneOf\":[");
        for (schema.one_of, 0..) |alternative, index| {
            if (index > 0) try writer.writeByte(',');
            try writeObjectSchema(alloc, writer, alternative);
        }
        try writer.writeAll("]}");
        return;
    }

    try writer.writeAll("{\"type\":\"object\",\"properties\":{");
    for (schema.properties, 0..) |property, index| {
        if (index > 0) try writer.writeByte(',');
        try std.json.Stringify.value(property.name, .{}, writer);
        try writer.writeByte(':');
        try writePropertySchema(alloc, writer, property);
    }
    try writer.writeByte('}');
    if (schema.additional_properties) |value| {
        try writer.writeAll(",\"additionalProperties\":");
        try writer.writeAll(if (value) "true" else "false");
    }
    if (schema.min_properties != no_u32_bound) try writer.print(",\"minProperties\":{d}", .{schema.min_properties});
    if (schema.max_properties != no_u32_bound) try writer.print(",\"maxProperties\":{d}", .{schema.max_properties});
    if (schema.required.len > 0) {
        try writer.writeAll(",\"required\":[");
        for (schema.required, 0..) |name, index| {
            if (index > 0) try writer.writeByte(',');
            try std.json.Stringify.value(name, .{}, writer);
        }
        try writer.writeByte(']');
    }
    try writer.writeByte('}');
}

fn writePropertySchema(
    alloc: std.mem.Allocator,
    writer: *std.Io.Writer,
    property: Property,
) anyerror!void {
    if (property.nullable) {
        var concrete = property;
        concrete.nullable = false;
        concrete.nullable_description = "";
        try writer.writeAll("{\"anyOf\":[");
        try writePropertySchema(alloc, writer, concrete);
        try writer.writeAll(",{\"type\":\"null\"}]");
        if (property.nullable_description.len > 0) {
            try writer.writeAll(",\"description\":");
            try writeCappedDescriptionJsonString(
                alloc,
                writer,
                property.nullable_description,
            );
        }
        try writer.writeByte('}');
        return;
    }
    if (property.shape) |shape| {
        switch (shape.*) {
            .object => |object_schema| {
                try writeObjectSchema(alloc, writer, object_schema.*);
                return;
            },
            else => {},
        }
    }
    try writer.writeAll("{\"type\":");
    try std.json.Stringify.value(@tagName(property.json_type), .{}, writer);
    if (property.shape) |shape| {
        switch (shape.*) {
            .enum_values => |values| {
                try writer.writeAll(",\"enum\":[");
                for (values, 0..) |value, index| {
                    if (index > 0) try writer.writeByte(',');
                    try std.json.Stringify.value(value, .{}, writer);
                }
                try writer.writeByte(']');
            },
            else => {},
        }
    }
    if (property.min_length != no_u32_bound) try writer.print(",\"minLength\":{d}", .{property.min_length});
    if (property.max_length != no_u32_bound) try writer.print(",\"maxLength\":{d}", .{property.max_length});
    if (property.minimum != no_u64_bound) try writer.print(",\"minimum\":{d}", .{property.minimum});
    if (property.maximum != no_u64_bound) try writer.print(",\"maximum\":{d}", .{property.maximum});
    if (property.description.len > 0) {
        try writer.writeAll(",\"description\":");
        try writeCappedDescriptionJsonString(alloc, writer, property.description);
    }
    if (property.min_items != no_u32_bound) try writer.print(",\"minItems\":{d}", .{property.min_items});
    if (property.max_items != no_u32_bound) try writer.print(",\"maxItems\":{d}", .{property.max_items});
    if (property.shape) |shape| {
        switch (shape.*) {
            .array_values => |values| {
                try writer.writeAll(",\"items\":{\"type\":");
                try std.json.Stringify.value(@tagName(values.json_type), .{}, writer);
                if (values.enum_values.len > 0) {
                    try writer.writeAll(",\"enum\":[");
                    for (values.enum_values, 0..) |value, index| {
                        if (index > 0) try writer.writeByte(',');
                        try std.json.Stringify.value(value, .{}, writer);
                    }
                    try writer.writeByte(']');
                }
                try writer.writeByte('}');
            },
            .array_objects => |items| {
                try writer.writeAll(",\"items\":");
                try writeObjectSchema(alloc, writer, items.*);
            },
            else => {},
        }
    }
    try writer.writeByte('}');
}

test "nullable properties preserve concrete constraints and add one null branch" {
    const alloc = std.testing.allocator;
    const object_value_schema = ObjectSchema{
        .properties = &.{.{ .name = "kind", .json_type = .string }},
        .required = &.{"kind"},
        .additional_properties = false,
    };
    const schema = FunctionSchema{
        .name = "nullable",
        .description = "nullable",
        .input_schema = .{
            .properties = &.{
                .{
                    .name = "choice",
                    .json_type = .string,
                    .description = "Concrete choice.",
                    .nullable = true,
                    .nullable_description = "Concrete choice. Set null when unused.",
                    .shape = &.{ .enum_values = &.{ "one", "two" } },
                },
                .{
                    .name = "config",
                    .json_type = .object,
                    .nullable = true,
                    .nullable_description = "Set null when unused.",
                    .shape = &.{ .object = &object_value_schema },
                },
            },
            .required = &.{ "choice", "config" },
        },
    };

    const json = try inputSchemaJsonAlloc(alloc, schema);
    defer alloc.free(json);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
    defer parsed.deinit();

    const properties = parsed.value.object.get("properties").?.object;
    const choice = properties.get("choice").?.object;
    try std.testing.expectEqualStrings(
        "Concrete choice. Set null when unused.",
        choice.get("description").?.string,
    );
    const choice_alternatives = choice.get("anyOf").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), choice_alternatives.len);
    try std.testing.expectEqualStrings("string", choice_alternatives[0].object.get("type").?.string);
    try std.testing.expectEqual(@as(usize, 2), choice_alternatives[0].object.get("enum").?.array.items.len);
    try std.testing.expectEqualStrings("null", choice_alternatives[1].object.get("type").?.string);

    const config_alternatives = properties.get("config").?.object.get("anyOf").?.array.items;
    try std.testing.expectEqualStrings("object", config_alternatives[0].object.get("type").?.string);
    try std.testing.expectEqual(false, config_alternatives[0].object.get("additionalProperties").?.bool);
    try std.testing.expectEqualStrings("null", config_alternatives[1].object.get("type").?.string);
}

test "nested object schema serializes exact property bounds" {
    const alloc = std.testing.allocator;
    const nested = ObjectSchema{
        .properties = &.{.{ .name = "create", .json_type = .object, .shape = &.{ .object = &.{
            .properties = &.{.{ .name = "name", .json_type = .string }},
            .required = &.{"name"},
            .additional_properties = false,
        } } }},
        .additional_properties = false,
        .min_properties = 1,
        .max_properties = 1,
    };
    const schema = FunctionSchema{
        .name = "nested",
        .description = "nested",
        .input_schema = nested,
    };

    const json = try inputSchemaJsonAlloc(alloc, schema);
    defer alloc.free(json);

    try std.testing.expect(std.mem.find(u8, json, "\"minProperties\":1") != null);
    try std.testing.expect(std.mem.find(u8, json, "\"maxProperties\":1") != null);
    try std.testing.expect(std.mem.find(u8, json, "\"create\":{\"type\":\"object\",\"properties\":{") != null);
    try std.testing.expect(std.mem.find(u8, json, "\"additionalProperties\":false") != null);
}

test "object alternatives serialize as exclusive object branches" {
    const alloc = std.testing.allocator;
    const alternatives = [_]ObjectSchema{
        .{
            .properties = &.{
                .{ .name = "action", .json_type = .string, .shape = &.{ .enum_values = &.{"read"} } },
                .{ .name = "path", .json_type = .string },
            },
            .required = &.{ "action", "path" },
            .additional_properties = false,
        },
        .{
            .properties = &.{
                .{ .name = "action", .json_type = .string, .shape = &.{ .enum_values = &.{"list"} } },
            },
            .required = &.{"action"},
            .additional_properties = false,
        },
    };
    const schema = FunctionSchema{
        .name = "alternative",
        .description = "alternative",
        .input_schema = .{ .one_of = &alternatives },
    };

    const json = try inputSchemaJsonAlloc(alloc, schema);
    defer alloc.free(json);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
    defer parsed.deinit();

    const input_schema = parsed.value.object;
    try std.testing.expect(input_schema.get("type") == null);
    try std.testing.expect(input_schema.get("properties") == null);
    const one_of = input_schema.get("oneOf").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), one_of.len);
    try std.testing.expectEqualStrings(
        "read",
        one_of[0].object.get("properties").?.object.get("action").?.object.get("enum").?.array.items[0].string,
    );
    try std.testing.expectEqualStrings(
        "list",
        one_of[1].object.get("properties").?.object.get("action").?.object.get("enum").?.array.items[0].string,
    );
    try std.testing.expectEqual(false, one_of[0].object.get("additionalProperties").?.bool);
    try std.testing.expectEqual(false, one_of[1].object.get("additionalProperties").?.bool);
}

test "object alternatives reject contradictory ordinary object metadata" {
    const schema = FunctionSchema{
        .name = "invalid_alternative",
        .description = "invalid alternative",
        .input_schema = .{
            .properties = &.{.{ .name = "value", .json_type = .string }},
            .one_of = &.{.{
                .properties = &.{.{ .name = "action", .json_type = .string }},
            }},
        },
    };

    try std.testing.expectError(
        error.InvalidObjectSchema,
        inputSchemaJsonAlloc(std.testing.allocator, schema),
    );
}

test "cappedDescriptionAlloc appends explicit truncation marker" {
    const alloc = std.testing.allocator;
    const oversized = "x" ** (description_max_bytes + 20);

    const capped = try cappedDescriptionAlloc(alloc, oversized);
    defer alloc.free(capped);

    try std.testing.expectEqual(description_max_bytes, capped.len);
    try std.testing.expect(std.mem.endsWith(u8, capped, truncation_marker));
}

test "inputSchemaJsonAlloc serializes strings and object schema" {
    const alloc = std.testing.allocator;
    const schema = FunctionSchema{
        .name = "read_file",
        .description = "Read \"quoted\" paths. When to use: test escaping. When NOT to use: unescaped JSON.",
        .input_schema = .{
            .properties = &.{
                .{ .name = "path", .json_type = .string, .description = "File path \"with quotes\"." },
            },
            .required = &.{"path"},
        },
    };

    const json = try inputSchemaJsonAlloc(alloc, schema);
    defer alloc.free(json);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
    defer parsed.deinit();

    try std.testing.expect(std.mem.find(u8, json, "read_file") == null);
    try std.testing.expect(std.mem.find(u8, json, "\\\"with quotes\\\"") != null);
}

test "inputSchemaJsonAlloc serializes every supported property shape" {
    const alloc = std.testing.allocator;
    const object_value_schema = ObjectSchema{
        .properties = &.{.{ .name = "name", .json_type = .string }},
        .required = &.{"name"},
        .additional_properties = false,
    };
    const array_item_schema = ObjectSchema{
        .properties = &.{.{ .name = "id", .json_type = .integer }},
        .required = &.{"id"},
        .additional_properties = false,
    };
    const schema = FunctionSchema{
        .name = "schema_matrix",
        .description = "schema matrix",
        .input_schema = .{
            .properties = &.{
                .{
                    .name = "text",
                    .json_type = .string,
                    .description = "bounded choice",
                    .shape = &.{ .enum_values = &.{ "alpha", "beta" } },
                    .min_length = 1,
                    .max_length = 8,
                },
                .{ .name = "count", .json_type = .integer, .minimum = 2, .maximum = 9 },
                .{ .name = "enabled", .json_type = .boolean },
                .{ .name = "config", .json_type = .object, .shape = &.{ .object = &object_value_schema } },
                .{
                    .name = "tags",
                    .json_type = .array,
                    .min_items = 1,
                    .max_items = 3,
                    .shape = &.{ .array_values = .{ .json_type = .string, .enum_values = &.{ "red", "blue" } } },
                },
                .{ .name = "records", .json_type = .array, .shape = &.{ .array_objects = &array_item_schema } },
            },
            .required = &.{ "text", "count", "enabled", "config", "tags", "records" },
            .additional_properties = false,
            .min_properties = 6,
            .max_properties = 6,
        },
    };

    const json = try inputSchemaJsonAlloc(alloc, schema);
    defer alloc.free(json);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
    defer parsed.deinit();

    const input_schema = parsed.value.object;
    try std.testing.expectEqualStrings("object", input_schema.get("type").?.string);
    try std.testing.expectEqual(false, input_schema.get("additionalProperties").?.bool);
    try std.testing.expectEqual(@as(i64, 6), input_schema.get("minProperties").?.integer);
    try std.testing.expectEqual(@as(i64, 6), input_schema.get("maxProperties").?.integer);
    try std.testing.expectEqual(@as(usize, 6), input_schema.get("required").?.array.items.len);

    const properties = input_schema.get("properties").?.object;
    const text_property = properties.get("text").?.object;
    try std.testing.expectEqualStrings("string", text_property.get("type").?.string);
    try std.testing.expectEqualStrings("bounded choice", text_property.get("description").?.string);
    try std.testing.expectEqual(@as(usize, 2), text_property.get("enum").?.array.items.len);
    try std.testing.expectEqual(@as(i64, 1), text_property.get("minLength").?.integer);
    try std.testing.expectEqual(@as(i64, 8), text_property.get("maxLength").?.integer);

    const count_property = properties.get("count").?.object;
    try std.testing.expectEqualStrings("integer", count_property.get("type").?.string);
    try std.testing.expectEqual(@as(i64, 2), count_property.get("minimum").?.integer);
    try std.testing.expectEqual(@as(i64, 9), count_property.get("maximum").?.integer);
    try std.testing.expectEqualStrings("boolean", properties.get("enabled").?.object.get("type").?.string);

    const config_property = properties.get("config").?.object;
    try std.testing.expectEqualStrings("object", config_property.get("type").?.string);
    try std.testing.expectEqual(false, config_property.get("additionalProperties").?.bool);
    try std.testing.expectEqualStrings(
        "string",
        config_property.get("properties").?.object.get("name").?.object.get("type").?.string,
    );

    const tags_property = properties.get("tags").?.object;
    try std.testing.expectEqualStrings("array", tags_property.get("type").?.string);
    try std.testing.expectEqual(@as(i64, 1), tags_property.get("minItems").?.integer);
    try std.testing.expectEqual(@as(i64, 3), tags_property.get("maxItems").?.integer);
    try std.testing.expectEqualStrings("string", tags_property.get("items").?.object.get("type").?.string);
    try std.testing.expectEqual(@as(usize, 2), tags_property.get("items").?.object.get("enum").?.array.items.len);

    const record_items = properties.get("records").?.object.get("items").?.object;
    try std.testing.expectEqualStrings("object", record_items.get("type").?.string);
    try std.testing.expectEqualStrings(
        "integer",
        record_items.get("properties").?.object.get("id").?.object.get("type").?.string,
    );
}

test "inputSchemaJsonAlloc preserves a valid dynamic schema" {
    const alloc = std.testing.allocator;
    var source = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"}}}",
        .{},
    );
    defer source.deinit();
    const json = try inputSchemaJsonAlloc(alloc, .{
        .name = "mcp_fs_read",
        .description = "Read a file",
        .dynamic_input_schema = source.value,
    });
    defer alloc.free(json);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("properties").?.object.get("path") != null);
}

test "function schema rejects invalid fixed and dynamic object contracts" {
    try std.testing.expectError(error.InvalidToolSchema, (FunctionSchema{
        .name = "",
        .description = "empty name",
    }).validate());
    try std.testing.expectError(error.InvalidToolSchema, (FunctionSchema{
        .name = "duplicate",
        .description = "duplicate property",
        .input_schema = .{ .properties = &.{
            .{ .name = "path", .json_type = .string },
            .{ .name = "path", .json_type = .string },
        } },
    }).validate());
    try std.testing.expectError(error.InvalidToolSchema, (FunctionSchema{
        .name = "missing_required",
        .description = "missing required property",
        .input_schema = .{ .required = &.{"path"} },
    }).validate());
    try std.testing.expectError(error.InvalidToolSchema, (FunctionSchema{
        .name = "bad_bounds",
        .description = "bad object bounds",
        .input_schema = .{ .min_properties = 2, .max_properties = 1 },
    }).validate());
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"type\":\"string\"}", .{});
    defer parsed.deinit();
    try std.testing.expectError(error.InvalidToolSchema, (FunctionSchema{
        .name = "dynamic",
        .description = "dynamic schema",
        .dynamic_input_schema = parsed.value,
    }).validate());
}
