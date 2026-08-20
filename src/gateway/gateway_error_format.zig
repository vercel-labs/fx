const std = @import("std");
const display_width = @import("../core/shared/display_width.zig");
const text_utils = @import("../core/shared/text_utils.zig");

const Allocator = std.mem.Allocator;
const max_published_error_bytes: usize = 1024;
const max_recovery_diagnostic_bytes: usize = 600;

pub fn formatSchemaDiagnostic(alloc: Allocator, detail: []const u8) !?[]u8 {
    if (detail.len == 0) return null;

    var parsed = std.json.parseFromSlice(std.json.Value, alloc, detail, .{}) catch return null;
    defer parsed.deinit();

    const root = objectValue(parsed.value) orelse return null;
    const error_value = root.get("error") orelse return null;
    const error_object = objectValue(error_value) orelse return null;
    const message = stringField(error_object, "message");

    const param_path = if (error_object.get("param")) |param_value|
        try formatParamPath(alloc, param_value)
    else
        null;
    defer if (param_path) |path| alloc.free(path);

    const expected = stringField(error_object, "expected") orelse schemaKindAfter(message, "expected ");
    const received = stringField(error_object, "received") orelse schemaKindAfter(message, "received ");

    if (param_path == null and expected == null and received == null) return null;

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    var wrote = false;
    if (param_path) |path| {
        if (path.len > 0) {
            try out.writer.writeAll("path=");
            try appendSafeToken(&out.writer, path);
            wrote = true;
        }
    }
    if (expected) |kind| {
        if (kind.len > 0) {
            if (wrote) try out.writer.writeByte(' ');
            try out.writer.writeAll("expected=");
            try appendSafeToken(&out.writer, kind);
            wrote = true;
        }
    }
    if (received) |kind| {
        if (kind.len > 0) {
            if (wrote) try out.writer.writeByte(' ');
            try out.writer.writeAll("received=");
            try appendSafeToken(&out.writer, kind);
            wrote = true;
        }
    }
    if (!wrote) {
        out.deinit();
        return null;
    }
    return try out.toOwnedSlice();
}

pub fn formatHttpErrorMessage(alloc: Allocator, status: std.http.Status, detail: []const u8) ![]u8 {
    const status_code = @intFromEnum(status);
    const title = if (status_code == 401 or status_code == 403)
        "API access denied"
    else
        "API request failed";
    return formatHttpDiagnostic(alloc, status, detail, title, max_published_error_bytes);
}

pub fn formatHttpRecoveryDiagnostic(alloc: Allocator, status: std.http.Status, detail: []const u8) ![]u8 {
    return formatHttpDiagnostic(alloc, status, detail, null, max_recovery_diagnostic_bytes);
}

fn formatHttpDiagnostic(
    alloc: Allocator,
    status: std.http.Status,
    detail: []const u8,
    title: ?[]const u8,
    max_bytes: usize,
) ![]u8 {
    if (detail.len == 0) return std.fmt.allocPrint(alloc, "HTTP {d}", .{@intFromEnum(status)});

    var parsed = std.json.parseFromSlice(std.json.Value, alloc, detail, .{}) catch
        return formatFallbackBounded(alloc, status, detail, max_bytes);
    defer parsed.deinit();

    const root = objectValue(parsed.value) orelse
        return formatFallbackBounded(alloc, status, detail, max_bytes);
    const error_value = root.get("error") orelse
        return formatFallbackBounded(alloc, status, detail, max_bytes);
    const error_object = objectValue(error_value) orelse
        return formatFallbackBounded(alloc, status, detail, max_bytes);
    const param_object = if (error_object.get("param")) |param_value| objectValue(param_value) else null;
    const code = stringField(error_object, "code") orelse
        stringField(error_object, "type") orelse
        if (param_object) |param| stringField(param, "name") else null;
    const message = stringField(error_object, "message") orelse if (param_object) |param| stringField(param, "message") else null;
    const provider = stringField(error_object, "provider") orelse providerFromGatewayMessage(message);

    const raw = try formatParsedHttpMessage(
        alloc,
        title,
        @intFromEnum(status),
        provider,
        code,
        message,
    );
    defer alloc.free(raw);
    return sanitizeExternalText(alloc, raw, max_bytes);
}

fn formatParsedHttpMessage(
    alloc: Allocator,
    title: ?[]const u8,
    status_code: u16,
    provider: ?[]const u8,
    code: ?[]const u8,
    message: ?[]const u8,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();

    if (title) |title_text| {
        try out.writer.print("{s} · ", .{title_text});
    }
    try out.writer.print("HTTP {d}", .{status_code});

    if (provider) |provider_text| {
        try out.writer.print(" · Provider: {s}", .{provider_text});
    }
    if (code) |code_text| {
        try out.writer.print(" · {s}", .{code_text});
        if (message) |message_text| {
            if (!std.mem.eql(u8, code_text, message_text)) {
                try out.writer.print(": {s}", .{message_text});
            }
        }
    } else if (message) |message_text| {
        try out.writer.print(" · {s}", .{message_text});
    }
    return out.toOwnedSlice();
}

pub fn formatMarkedLine(alloc: Allocator, marker_prefix: []const u8, message: []const u8, cols: u16) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    const safe_cols = @max(@as(usize, cols), 1);
    const prefix_width = display_width.visibleWidth(marker_prefix);
    const continuation_width = @max(prefix_width, 1);
    const continuation_indent = try alloc.alloc(u8, continuation_width);
    defer alloc.free(continuation_indent);
    @memset(continuation_indent, ' ');

    var remaining = message;
    var first = true;
    while (remaining.len > 0) {
        const prefix = if (first) marker_prefix else continuation_indent;
        const available = if (safe_cols > display_width.visibleWidth(prefix))
            safe_cols - display_width.visibleWidth(prefix)
        else
            1;
        var chunk = wrapCut(remaining, available);
        if (chunk.len == 0) {
            const rune = display_width.decodeNextRune(remaining, 0);
            chunk = remaining[0..@max(rune.len, 1)];
        }

        if (!first) try out.append(alloc, '\n');
        try out.appendSlice(alloc, prefix);
        try out.appendSlice(alloc, chunk);

        remaining = trimBreakWhitespace(remaining[chunk.len..]);
        first = false;
    }

    if (message.len == 0) try out.appendSlice(alloc, marker_prefix);
    return try out.toOwnedSlice(alloc);
}

fn formatFallbackBounded(
    alloc: Allocator,
    status: std.http.Status,
    detail: []const u8,
    max_bytes: usize,
) ![]u8 {
    if (detail.len == 0) return std.fmt.allocPrint(alloc, "HTTP {d}", .{@intFromEnum(status)});
    const raw = try std.fmt.allocPrint(alloc, "HTTP {d}: {s}", .{ @intFromEnum(status), detail });
    defer alloc.free(raw);
    return sanitizeExternalText(alloc, raw, max_bytes);
}

fn sanitizeExternalText(alloc: Allocator, raw: []const u8, max_bytes: usize) ![]u8 {
    const masked = try text_utils.maskSecrets(alloc, raw);
    defer if (masked.ptr != raw.ptr) alloc.free(masked);

    const encoded = try text_utils.encodeTerminalSafe(alloc, masked, max_bytes);
    return encoded.bytes;
}

fn objectValue(value: std.json.Value) ?std.json.ObjectMap {
    return switch (value) {
        .object => |object| object,
        else => null,
    };
}

fn stringField(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

fn formatParamPath(alloc: Allocator, value: std.json.Value) !?[]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    if (!try writeParamPath(&out.writer, value)) {
        out.deinit();
        return null;
    }
    return try out.toOwnedSlice();
}

fn writeParamPath(writer: *std.Io.Writer, value: std.json.Value) !bool {
    switch (value) {
        .string => |text| {
            if (text.len == 0) return false;
            try appendSafeToken(writer, text);
            return true;
        },
        .array => |array| {
            if (array.items.len == 0) return false;
            for (array.items, 0..) |item, i| {
                if (i > 0) try writer.writeByte('.');
                switch (item) {
                    .string => |text| try appendSafeToken(writer, text),
                    .integer => |number| try writer.print("{d}", .{number}),
                    .number_string => |raw| try appendSafeToken(writer, raw),
                    .object => |object| {
                        if (object.get("path")) |path| {
                            if (!try writeParamPath(writer, path)) try writer.writeAll("object");
                        } else if (object.get("param")) |param| {
                            if (!try writeParamPath(writer, param)) try writer.writeAll("object");
                        } else {
                            try writer.writeAll("object");
                        }
                    },
                    else => try writer.writeAll(jsonKindName(item)),
                }
            }
            return true;
        },
        .object => |object| {
            if (object.get("path")) |path| return writeParamPath(writer, path);
            if (object.get("param")) |param| return writeParamPath(writer, param);
            return false;
        },
        else => return false,
    }
}

fn schemaKindAfter(message: ?[]const u8, marker: []const u8) ?[]const u8 {
    const text = message orelse return null;
    const marker_index = std.mem.indexOf(u8, text, marker) orelse return null;
    var start = marker_index + marker.len;
    while (start < text.len and (text[start] == ' ' or text[start] == '\'' or text[start] == '"' or text[start] == '`')) : (start += 1) {}
    var end = start;
    while (end < text.len) : (end += 1) {
        switch (text[end]) {
            'a'...'z', 'A'...'Z', '0'...'9', '_', '-' => {},
            else => break,
        }
    }
    if (end == start) return null;
    return text[start..end];
}

fn appendSafeToken(writer: *std.Io.Writer, raw: []const u8) !void {
    var wrote = false;
    var last_was_underscore = false;
    for (raw) |c| {
        switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '_', '-', '.', '[', ']' => {
                try writer.writeByte(c);
                wrote = true;
                last_was_underscore = c == '_';
            },
            else => {
                if (!last_was_underscore) {
                    try writer.writeByte('_');
                    wrote = true;
                    last_was_underscore = true;
                }
            },
        }
    }
    if (!wrote) try writer.writeAll("unknown");
}

fn jsonKindName(value: std.json.Value) []const u8 {
    return switch (value) {
        .null => "null",
        .bool => "bool",
        .integer, .float, .number_string => "number",
        .string => "string",
        .array => "array",
        .object => "object",
    };
}

fn providerFromGatewayMessage(message: ?[]const u8) ?[]const u8 {
    const text = message orelse return null;
    const marker = "Providers considered: ";
    const start = std.mem.indexOf(u8, text, marker) orelse return null;
    const provider_text = trimBreakWhitespace(text[start + marker.len ..]);
    var end: usize = 0;
    while (end < provider_text.len) : (end += 1) {
        switch (provider_text[end]) {
            '.', '\n', '\r', '\t' => break,
            else => {},
        }
    }
    if (end == 0) return null;
    return provider_text[0..end];
}

fn wrapCut(text: []const u8, max_width: usize) []const u8 {
    const prefix = display_width.prefixByWidth(text, max_width);
    if (prefix.len == text.len) return prefix;

    var last_space: ?usize = null;
    var index: usize = 0;
    while (index < prefix.len) {
        const rune = display_width.decodeNextRune(prefix, index);
        if (prefix[index] == ' ' or prefix[index] == '\t') last_space = index;
        index += @max(rune.len, 1);
    }
    if (last_space) |space_index| {
        if (space_index > 0) return text[0..space_index];
    }
    return prefix;
}

fn trimBreakWhitespace(text: []const u8) []const u8 {
    var index: usize = 0;
    while (index < text.len and (text[index] == ' ' or text[index] == '\t')) : (index += 1) {}
    return text[index..];
}

test "formatHttpErrorMessage renders restricted provider details without raw JSON" {
    const detail =
        \\{"error":{"code":"RestrictedProvidersError","message":"demo account is restricted from provider wafer","provider":"wafer"}}
    ;
    const line = try formatHttpErrorMessage(std.testing.allocator, .forbidden, detail);
    defer std.testing.allocator.free(line);

    try std.testing.expectEqualStrings(
        "API access denied · HTTP 403 · Provider: wafer · RestrictedProvidersError: demo account is restricted from provider wafer",
        line,
    );
}

test "formatHttpErrorMessage renders live restricted provider body shape" {
    const detail =
        \\{"error":{"message":"Your team has restricted access to this provider. Contact the owner of the account for more details. Providers considered: wafer","type":"no_providers_available","param":{"name":"RestrictedProvidersError","message":"Your team has restricted access to this provider. Contact the owner of the account for more details. Providers considered: wafer"}},"providerMetadata":{"gateway":{"routing":{}}}}
    ;
    const line = try formatHttpErrorMessage(std.testing.allocator, .forbidden, detail);
    defer std.testing.allocator.free(line);

    try std.testing.expectEqualStrings(
        "API access denied · HTTP 403 · Provider: wafer · no_providers_available: Your team has restricted access to this provider. Contact the owner of the account for more details. Providers considered: wafer",
        line,
    );
}

test "formatHttpErrorMessage renders API key and credits setup bodies" {
    const api_key_detail =
        \\{"error":{"code":"api_key_required","message":"Set AI_GATEWAY_API_KEY to use this endpoint."}}
    ;
    const api_key_line = try formatHttpErrorMessage(std.testing.allocator, .unauthorized, api_key_detail);
    defer std.testing.allocator.free(api_key_line);
    try std.testing.expectEqualStrings(
        "API access denied · HTTP 401 · api_key_required: Set AI_GATEWAY_API_KEY to use this endpoint.",
        api_key_line,
    );

    const credits_detail =
        \\{"error":{"code":"credit_card_required","message":"Buy credits to use AI Gateway."}}
    ;
    const credits_line = try formatHttpErrorMessage(std.testing.allocator, .forbidden, credits_detail);
    defer std.testing.allocator.free(credits_line);
    try std.testing.expectEqualStrings(
        "API access denied · HTTP 403 · credit_card_required: Buy credits to use AI Gateway.",
        credits_line,
    );
}

test "formatHttpErrorMessage masks structured and fallback secrets" {
    const alloc = std.testing.allocator;
    const secret = "abcdefghijklmnop";
    const structured_detail =
        \\{"error":{"code":"provider_error","message":"AI_GATEWAY_API_KEY=abcdefghijklmnop"}}
    ;
    const structured = try formatHttpErrorMessage(alloc, .service_unavailable, structured_detail);
    defer alloc.free(structured);
    try std.testing.expectEqualStrings(
        "API request failed · HTTP 503 · provider_error: AI_GATEWAY_API_KEY=[redacted]",
        structured,
    );
    try std.testing.expect(std.mem.find(u8, structured, secret) == null);

    const fallback = try formatHttpErrorMessage(
        alloc,
        .service_unavailable,
        "API_KEY=abcdefghijklmnop",
    );
    defer alloc.free(fallback);
    try std.testing.expectEqualStrings("HTTP 503: API_KEY=[redacted]", fallback);
    try std.testing.expect(std.mem.find(u8, fallback, secret) == null);
}

test "formatHttpRecoveryDiagnostic keeps status code and provider error identity" {
    const detail =
        \\{"error":{"code":"no_available_providers","message":"No providers are currently available","provider":"wafer"}}
    ;
    const diagnostic = try formatHttpRecoveryDiagnostic(
        std.testing.allocator,
        .service_unavailable,
        detail,
    );
    defer std.testing.allocator.free(diagnostic);

    try std.testing.expectEqualStrings(
        "HTTP 503 · Provider: wafer · no_available_providers: No providers are currently available",
        diagnostic,
    );
}

test "formatSchemaDiagnostic renders array param path and expected kinds" {
    const detail =
        \\{"error":{"message":"Invalid input: expected string, received array","param":["prompt",0,"content"]}}
    ;
    const diagnostic = try formatSchemaDiagnostic(std.testing.allocator, detail);
    defer if (diagnostic) |owned| std.testing.allocator.free(owned);

    try std.testing.expect(diagnostic != null);
    try std.testing.expectEqualStrings(
        "path=prompt.0.content expected=string received=array",
        diagnostic.?,
    );
}

test "formatSchemaDiagnostic renders live issue-object param path" {
    const detail =
        \\{"error":{"message":"Invalid input: expected string, received array","param":[{"expected":"string","code":"invalid_type","path":["prompt",0,"content"],"message":"Invalid input: expected string, received array"}],"type":"invalid_request_error"}}
    ;
    const diagnostic = try formatSchemaDiagnostic(std.testing.allocator, detail);
    defer if (diagnostic) |owned| std.testing.allocator.free(owned);

    try std.testing.expect(diagnostic != null);
    try std.testing.expectEqualStrings(
        "path=prompt.0.content expected=string received=array",
        diagnostic.?,
    );
}

test "formatSchemaDiagnostic ignores restricted provider body without schema path" {
    const detail =
        \\{"error":{"message":"Your team has restricted access to this provider. Providers considered: wafer","type":"no_providers_available","param":{"name":"RestrictedProvidersError","message":"Your team has restricted access to this provider. Providers considered: wafer"}}}
    ;
    const diagnostic = try formatSchemaDiagnostic(std.testing.allocator, detail);
    try std.testing.expect(diagnostic == null);
}

test "formatMarkedLine indents wrapped continuation under message text" {
    const message = "API access denied · HTTP 403 · Provider: wafer · demo account is restricted from provider wafer";
    const line = try formatMarkedLine(std.testing.allocator, "▲ ", message, 72);
    defer std.testing.allocator.free(line);

    try std.testing.expectEqualStrings(
        "▲ API access denied · HTTP 403 · Provider: wafer · demo account is\n  restricted from provider wafer",
        line,
    );
}
