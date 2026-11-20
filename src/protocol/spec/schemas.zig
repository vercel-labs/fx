//! Tests for the schema files of the `sh.fx` specification in this folder. The copy of ACP's
//! version 1 schema in `acp/v1/` must match agent-client-protocol commit `7ec5185c18ca` byte for
//! byte, every schema file must parse as a JSON object, and `sh-fx.schema.json` must use the JSON
//! Schema draft of ACP's schema. `README.md` in this folder says how to move the copy to a newer
//! commit.

const std = @import("std");

const SpecFile = struct {
    path: []const u8,
    bytes: []const u8,
};

fn specFile(comptime path: []const u8) SpecFile {
    return .{ .path = path, .bytes = @embedFile(path) };
}

const acp_license = specFile("acp/v1/LICENSE");
const acp_meta = specFile("acp/v1/meta.json");
const acp_meta_unstable = specFile("acp/v1/meta.unstable.json");
const acp_schema = specFile("acp/v1/schema.json");
const acp_schema_unstable = specFile("acp/v1/schema.unstable.json");
const fx_schema = specFile("sh-fx.schema.json");

const PinnedFile = struct {
    file: SpecFile,
    /// The lowercase hex SHA-256 of the file at the pinned ACP commit.
    sha256: *const [64]u8,
};

const pinned_files = [_]PinnedFile{
    .{
        .file = acp_license,
        .sha256 = "f250d08cee4549b22b3b4aaaf3a743473336fd280316df5d0340717e5127a221",
    },
    .{
        .file = acp_meta,
        .sha256 = "061edb6efa8fb2aa2792459a86ec7268de5fe665bba48b2ffe7939df01481f88",
    },
    .{
        .file = acp_meta_unstable,
        .sha256 = "dc99f7006087ad5d32e40c019326854b379eaa95963a6497c366f2a371966f0d",
    },
    .{
        .file = acp_schema,
        .sha256 = "e747a7bec3c02708b70885bf3cccac5c72fa421390dd7e85758fd61e33b1ae21",
    },
    .{
        .file = acp_schema_unstable,
        .sha256 = "cff9aa6f463eccfff38c0918fc57ada6efd1952a2b7868baba432b5dc8aaeb59",
    },
};

const json_files = [_]SpecFile{ acp_meta, acp_meta_unstable, acp_schema, acp_schema_unstable, fx_schema };

/// Returns the field `name` of `value`, or null when `value` is not an object or has no such field.
fn field(value: std.json.Value, name: []const u8) ?std.json.Value {
    if (value != .object) return null;
    return value.object.get(name);
}

fn stringField(value: std.json.Value, name: []const u8) ?[]const u8 {
    const found = field(value, name) orelse return null;
    return if (found == .string) found.string else null;
}

/// Reports whether `values` is an object with `want` among its string values. ACP's `meta.json`
/// lists methods this way, keyed by a Rust identifier, such as `"session_prompt": "session/prompt"`.
fn hasStringValue(values: std.json.Value, want: []const u8) bool {
    if (values != .object) return false;
    for (values.object.values()) |value| {
        if (value == .string and std.mem.eql(u8, value.string, want)) return true;
    }
    return false;
}

fn parseSpecFile(file: SpecFile) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, std.testing.allocator, file.bytes, .{}) catch |err| {
        std.debug.print("{s} does not parse as JSON\n", .{file.path});
        return err;
    };
}

test "the ACP copy matches the files of the pinned commit" {
    for (pinned_files) |pinned| {
        var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(pinned.file.bytes, &digest, .{});
        const hex = std.fmt.bytesToHex(digest, .lower);
        std.testing.expectEqualStrings(pinned.sha256, &hex) catch |err| {
            std.debug.print("{s} differs from the pinned ACP commit\n", .{pinned.file.path});
            return err;
        };
    }
}

test "every schema file parses as a JSON object" {
    for (json_files) |file| {
        const parsed = try parseSpecFile(file);
        defer parsed.deinit();
        if (parsed.value != .object) {
            std.debug.print("{s} is not a JSON object\n", .{file.path});
            return error.TestUnexpectedResult;
        }
    }
}

test "ACP's method lists are version 1 and the unstable list includes every stable method" {
    const stable = try parseSpecFile(acp_meta);
    defer stable.deinit();
    const unstable = try parseSpecFile(acp_meta_unstable);
    defer unstable.deinit();

    for ([_]std.json.Value{ stable.value, unstable.value }) |meta| {
        const version = field(meta, "version") orelse return error.TestUnexpectedResult;
        try std.testing.expect(version == .integer and version.integer == 1);
    }
    try std.testing.expect(hasStringValue(field(stable.value, "agentMethods") orelse .null, "session/prompt"));
    try std.testing.expect(hasStringValue(field(stable.value, "clientMethods") orelse .null, "session/update"));

    for ([_][]const u8{ "agentMethods", "clientMethods", "protocolMethods" }) |list| {
        const stable_list = field(stable.value, list) orelse return error.TestUnexpectedResult;
        const unstable_list = field(unstable.value, list) orelse return error.TestUnexpectedResult;
        try std.testing.expect(stable_list == .object);
        for (stable_list.object.values()) |method| {
            try std.testing.expect(method == .string);
            if (!hasStringValue(unstable_list, method.string)) {
                std.debug.print("{s} is stable but missing from the unstable {s}\n", .{ method.string, list });
                return error.TestUnexpectedResult;
            }
        }
    }
}

test "the unstable ACP schema includes every stable type" {
    const stable = try parseSpecFile(acp_schema);
    defer stable.deinit();
    const unstable = try parseSpecFile(acp_schema_unstable);
    defer unstable.deinit();

    const stable_defs = field(stable.value, "$defs") orelse return error.TestUnexpectedResult;
    const unstable_defs = field(unstable.value, "$defs") orelse return error.TestUnexpectedResult;
    try std.testing.expect(stable_defs == .object and unstable_defs == .object);
    try std.testing.expect(stable_defs.object.count() > 0);
    for (stable_defs.object.keys()) |name| {
        if (!unstable_defs.object.contains(name)) {
            std.debug.print("{s} is a stable type but missing from the unstable schema\n", .{name});
            return error.TestUnexpectedResult;
        }
    }
}

test "sh-fx.schema.json uses the JSON Schema draft of ACP's schema" {
    const acp = try parseSpecFile(acp_schema);
    defer acp.deinit();
    const fx = try parseSpecFile(fx_schema);
    defer fx.deinit();

    const acp_draft = stringField(acp.value, "$schema") orelse return error.TestUnexpectedResult;
    const fx_draft = stringField(fx.value, "$schema") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(acp_draft, fx_draft);

    const fx_defs = field(fx.value, "$defs") orelse return error.TestUnexpectedResult;
    try std.testing.expect(fx_defs == .object);
}
