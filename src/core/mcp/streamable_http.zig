const std = @import("std");
const mcp_auth = @import("mcp_auth.zig");
const mcp_contract = @import("mcp_contract.zig");
const operation_control = @import("operation_control.zig");
const protocol_negotiation = @import("protocol_negotiation.zig");
const io_mod = @import("../shared/io.zig");

const Allocator = std.mem.Allocator;

pub const protocol_version = protocol_negotiation.modern_protocol_version;
const max_sse_events: usize = 1024;
const max_tool_schema_depth: usize = 64;
const max_json_safe_integer: i64 = 9_007_199_254_740_991;

pub const Control = struct {
    deadline: std.Io.Clock.Timestamp,
    cancel_flag: ?*std.atomic.Value(bool) = null,
    lifecycle_cancel_flag: ?*const std.atomic.Value(bool) = null,

    pub fn cancellation(self: Control) operation_control.CancellationSources {
        return .{
            .caller = self.cancel_flag,
            .runtime = self.lifecycle_cancel_flag,
        };
    }
};

pub const PostOptions = struct {
    url: []const u8,
    static_headers: []const mcp_contract.McpHttpHeader = &.{},
    request_body: []const u8,
    input_schema_json: ?[]const u8 = null,
    max_response_bytes: usize,
    max_event_bytes: usize,
    allow_version_error: bool = false,
    allow_discovery_mismatch_status: bool = false,
    progress: ?mcp_contract.ProgressSink = null,
    notifications: ?mcp_contract.NotificationSink = null,
    long_lived: bool = false,
    precommit: ?*mcp_contract.TransportPrecommit = null,
    control: Control,
};

pub const PostResponse = struct {
    body: []u8,
    version_error: bool = false,
    discovery_mismatch_status: bool = false,
    auth_rejection: AuthRejection = .none,
    www_authenticate: ?[]u8 = null,

    pub fn deinit(self: *PostResponse, alloc: Allocator) void {
        alloc.free(self.body);
        if (self.www_authenticate) |value| alloc.free(value);
        self.* = undefined;
    }
};

pub const AuthRejection = enum {
    none,
    unauthorized,
    insufficient_scope,
};

pub const EndpointError = error{
    InvalidEndpoint,
    InsecureEndpoint,
};

pub const HeaderError = error{
    InvalidHeaderName,
    InvalidHeaderValue,
    DuplicateHeader,
    ReservedHeader,
};

pub fn validateEndpoint(url: []const u8) EndpointError!void {
    const uri = std.Uri.parse(url) catch return error.InvalidEndpoint;
    if (uri.user != null or uri.password != null or uri.fragment != null) {
        return error.InvalidEndpoint;
    }
    const host_component = uri.host orelse return error.InvalidEndpoint;

    if (std.ascii.eqlIgnoreCase(uri.scheme, "https")) return;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "http") or uri.port == null) {
        return error.InsecureEndpoint;
    }

    var host_buf: [std.Io.net.HostName.max_len]u8 = undefined;
    const host = host_component.toRaw(&host_buf) catch return error.InvalidEndpoint;
    if (std.mem.eql(u8, host, "127.0.0.1") or
        std.ascii.eqlIgnoreCase(host, "localhost") or
        std.mem.eql(u8, host, "[::1]"))
    {
        return;
    }
    return error.InsecureEndpoint;
}

pub fn validateStaticHeaders(headers: []const mcp_contract.McpHttpHeader) HeaderError!void {
    for (headers, 0..) |header, index| {
        if (!isHttpToken(header.name)) return error.InvalidHeaderName;
        try validateHeaderValue(header.value);
        if (isReservedHeader(header.name)) return error.ReservedHeader;

        for (headers[0..index]) |previous| {
            if (std.ascii.eqlIgnoreCase(previous.name, header.name)) {
                return error.DuplicateHeader;
            }
        }
    }
}

pub fn validateHeaderValue(value: []const u8) HeaderError!void {
    if (!isValidHeaderValue(value)) return error.InvalidHeaderValue;
}

fn isHttpToken(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |byte| {
        if (std.ascii.isAlphanumeric(byte)) continue;
        switch (byte) {
            '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => {},
            else => return false,
        }
    }
    return true;
}

pub fn validateToolInputSchemaHeaders(alloc: Allocator, schema_json: []const u8) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, schema_json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidToolInputSchema,
    };
    defer parsed.deinit();
    try validateToolInputSchemaValue(alloc, parsed.value);
}

pub fn post(alloc: Allocator, options: PostOptions) !PostResponse {
    try validateEndpoint(options.url);
    try validateStaticHeaders(options.static_headers);
    if (options.max_response_bytes == 0 or options.max_event_bytes == 0) {
        return error.InvalidResponseLimit;
    }

    const cancellation = options.control.cancellation();
    if (cancellation.cancelled()) return error.Cancelled;

    const now = std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake);
    if (!std.Io.Clock.Timestamp.compare(now, .lt, options.control.deadline)) {
        return error.McpRequestTimedOut;
    }

    const Operation = struct {
        alloc: Allocator,
        options: PostOptions,

        fn run(self: @This()) anyerror!PostResponse {
            return postCore(self.alloc, self.options);
        }
    };
    const Event = union(enum) {
        request: anyerror!PostResponse,
        cancelled: anyerror!void,
        deadline: anyerror!void,
    };
    const Cleanup = struct {
        fn drain(result_alloc: Allocator, select: *std.Io.Select(Event)) void {
            while (select.cancel()) |item| switch (item) {
                .request => |result| {
                    var response = result catch continue;
                    response.deinit(result_alloc);
                },
                .cancelled, .deadline => {},
            };
        }
    };

    var select_buffer: [3]Event = undefined;
    var select: std.Io.Select(Event) = .init(io_mod.getIo(), &select_buffer);
    select.concurrent(.cancelled, waitForCancellation, .{cancellation}) catch |err| return err;
    select.concurrent(.deadline, waitForDeadline, .{options.control.deadline}) catch |err| {
        select.cancelDiscard();
        return err;
    };
    select.concurrent(.request, Operation.run, .{Operation{
        .alloc = alloc,
        .options = options,
    }}) catch |err| {
        select.cancelDiscard();
        return err;
    };

    const event = select.await() catch |err| {
        Cleanup.drain(alloc, &select);
        return err;
    };
    switch (event) {
        .request => |result| {
            Cleanup.drain(alloc, &select);
            if (cancellation.cancelled()) {
                var response = result catch return error.Cancelled;
                response.deinit(alloc);
                return error.Cancelled;
            }
            return result;
        },
        .cancelled => |result| {
            result catch |err| {
                Cleanup.drain(alloc, &select);
                return err;
            };
            Cleanup.drain(alloc, &select);
            return error.Cancelled;
        },
        .deadline => |result| {
            result catch |err| {
                Cleanup.drain(alloc, &select);
                return err;
            };
            Cleanup.drain(alloc, &select);
            if (cancellation.cancelled()) return error.Cancelled;
            return error.McpRequestTimedOut;
        },
    }
}

const RequestInfo = struct {
    id: i64,
    method: []const u8,
    name: ?[]const u8,
    params: std.json.ObjectMap,
};

const OwnedHeaders = struct {
    items: std.ArrayList(std.http.Header) = .empty,
    owned: std.ArrayList([]u8) = .empty,

    fn deinit(self: *OwnedHeaders, alloc: Allocator) void {
        for (self.owned.items) |value| alloc.free(value);
        self.owned.deinit(alloc);
        self.items.deinit(alloc);
        self.* = undefined;
    }

    fn own(self: *OwnedHeaders, alloc: Allocator, value: []const u8) ![]const u8 {
        const copy = try alloc.dupe(u8, value);
        errdefer alloc.free(copy);
        try self.owned.append(alloc, copy);
        return copy;
    }

    fn append(self: *OwnedHeaders, alloc: Allocator, name: []const u8, value: []const u8) !void {
        try self.items.append(alloc, .{ .name = name, .value = value });
    }

    fn appendOwned(self: *OwnedHeaders, alloc: Allocator, name: []const u8, value: []const u8) !void {
        const owned_name = try self.own(alloc, name);
        const owned_value = try self.own(alloc, value);
        try self.append(alloc, owned_name, owned_value);
    }
};

const PreparedRequest = struct {
    headers: OwnedHeaders,
    id: i64,
    is_discovery: bool,

    fn deinit(self: *PreparedRequest, alloc: Allocator) void {
        self.headers.deinit(alloc);
        self.* = undefined;
    }
};

// The pinned Zig 0.16 Response.reader has aborted on fixed-length MCP responses
// by accessing body_remaining_content_length while its state was `.ready`.
// Keep MCP framing in independent state and requests one-shot so teardown never
// re-enters that body-state path. Remove this adapter when Response.reader
// passes the fixed-length JSON and SSE regression cases on the pinned toolchain.
const McpContentLengthReader = struct {
    source: *std.Io.Reader,
    remaining: u64,
    interface: std.Io.Reader,

    fn init(
        source: *std.Io.Reader,
        content_length: u64,
        buffer: []u8,
    ) McpContentLengthReader {
        return .{
            .source = source,
            .remaining = content_length,
            .interface = .{
                .vtable = &.{
                    .stream = stream,
                },
                .buffer = buffer,
                .seek = 0,
                .end = 0,
            },
        };
    }

    fn stream(
        reader: *std.Io.Reader,
        writer: *std.Io.Writer,
        limit: std.Io.Limit,
    ) std.Io.Reader.StreamError!usize {
        const self: *McpContentLengthReader = @alignCast(@fieldParentPtr("interface", reader));
        if (self.remaining == 0) return error.EndOfStream;
        const count = try self.source.stream(
            writer,
            limit.min(.limited64(self.remaining)),
        );
        const consumed: u64 = @intCast(count);
        if (consumed > self.remaining) return error.ReadFailed;
        self.remaining -= consumed;
        return count;
    }
};

const McpResponseBodyFraming = enum {
    content_length,
    standard,
};

fn mcpResponseBodyFraming(
    transfer_encoding: std.http.TransferEncoding,
    content_length: ?u64,
) McpResponseBodyFraming {
    if (transfer_encoding == .none and content_length != null) {
        return .content_length;
    }
    return .standard;
}

fn postCore(alloc: Allocator, options: PostOptions) !PostResponse {
    var prepared = try prepareRequest(
        alloc,
        options.static_headers,
        options.request_body,
        options.input_schema_json,
    );
    defer prepared.deinit(alloc);

    const uri = std.Uri.parse(options.url) catch return error.InvalidEndpoint;
    var client: std.http.Client = .{
        .allocator = alloc,
        .io = io_mod.getIo(),
    };
    defer client.deinit();

    var request = try client.request(.POST, uri, .{
        .redirect_behavior = .unhandled,
        .keep_alive = false,
        .headers = .{
            .content_type = .{ .override = "application/json" },
            .accept_encoding = .omit,
        },
        .extra_headers = prepared.headers.items.items,
    });
    defer request.deinit();
    defer if (options.precommit) |precommit| precommit.release();
    if (options.precommit) |precommit| try precommit.acquire();
    try request.sendBodyComplete(@constCast(options.request_body));
    if (options.precommit) |precommit| precommit.release();

    var response = request.receiveHead(&.{}) catch |err| switch (err) {
        error.HttpContentEncodingUnsupported => return error.UnsupportedContentEncoding,
        else => |e| return e,
    };
    const status = response.head.status;
    if (status.class() == .redirect) return error.RedirectNotAllowed;

    if (status == .unauthorized or status == .forbidden) {
        const authenticate = try mcp_auth.collectAuthenticateHeader(
            alloc,
            response.head,
        );
        defer if (authenticate) |value| alloc.free(value);
        return .{
            .body = try alloc.dupe(u8, ""),
            .auth_rejection = if (status == .unauthorized)
                .unauthorized
            else
                .insufficient_scope,
            .www_authenticate = if (authenticate) |value|
                try alloc.dupe(u8, value)
            else
                null,
        };
    }

    const version_error = options.allow_version_error and status == .bad_request;
    const discovery_mismatch_status = options.allow_discovery_mismatch_status and
        (status == .not_found or status == .method_not_allowed);
    if (status != .ok and !version_error and !discovery_mismatch_status) {
        return error.UnexpectedHttpStatus;
    }
    if (response.head.content_encoding != .identity) {
        return error.UnsupportedContentEncoding;
    }
    if (discovery_mismatch_status) {
        return .{
            .body = try alloc.dupe(u8, ""),
            .discovery_mismatch_status = true,
        };
    }

    const content_type = response.head.content_type orelse return error.MissingContentType;
    const media_type = parseMediaType(content_type);
    const legacy_plain_text_discovery = version_error and prepared.is_discovery and
        isPlainTextMediaType(content_type);
    if (media_type == null and !legacy_plain_text_discovery) return error.UnsupportedContentType;
    if (version_error and media_type != .json and !legacy_plain_text_discovery) {
        return error.UnsupportedContentType;
    }

    var transfer_buffer: [16 * 1024]u8 = undefined;
    var content_length_reader: McpContentLengthReader = undefined;
    const reader = switch (mcpResponseBodyFraming(
        response.head.transfer_encoding,
        response.head.content_length,
    )) {
        .content_length => reader: {
            content_length_reader = .init(
                response.request.reader.in,
                response.head.content_length.?,
                &transfer_buffer,
            );
            break :reader &content_length_reader.interface;
        },
        .standard => response.reader(&transfer_buffer),
    };
    var body_auth_rejection: AuthRejection = .none;
    const body = if (legacy_plain_text_discovery)
        try readJsonResponseClassified(
            alloc,
            reader,
            prepared.id,
            options.max_response_bytes,
            prepared.is_discovery,
            &body_auth_rejection,
        )
    else switch (media_type.?) {
        .json => try readJsonResponseClassified(
            alloc,
            reader,
            prepared.id,
            options.max_response_bytes,
            prepared.is_discovery,
            &body_auth_rejection,
        ),
        .sse => try readSseResponse(
            alloc,
            reader,
            prepared.id,
            if (options.long_lived) std.math.maxInt(usize) else options.max_response_bytes,
            options.max_event_bytes,
            if (options.long_lived) std.math.maxInt(usize) else max_sse_events,
            options.progress,
            options.notifications,
            options.control.cancellation(),
        ),
    };
    errdefer alloc.free(body);
    if (legacy_plain_text_discovery and body_auth_rejection == .none and
        !try isLegacyDiscoveryCompatibilityResponse(alloc, body))
    {
        return error.UnsupportedContentType;
    }
    return .{
        .body = body,
        .version_error = version_error,
        .discovery_mismatch_status = discovery_mismatch_status,
        .auth_rejection = body_auth_rejection,
    };
}

fn prepareRequest(
    alloc: Allocator,
    static_headers: []const mcp_contract.McpHttpHeader,
    request_body: []const u8,
    input_schema_json: ?[]const u8,
) !PreparedRequest {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, request_body, .{}) catch {
        return error.InvalidModernRequest;
    };
    defer parsed.deinit();
    const request_info = try modernRequestInfo(parsed.value);
    const is_discovery = std.mem.eql(u8, request_info.method, "server/discover");

    var headers: OwnedHeaders = .{};
    errdefer headers.deinit(alloc);
    try headers.append(alloc, "Accept", "application/json, text/event-stream");
    try headers.append(alloc, "MCP-Protocol-Version", protocol_version);
    try headers.appendOwned(alloc, "Mcp-Method", request_info.method);
    if (request_info.name) |name| {
        const encoded_name = try encodeHeaderValue(alloc, name);
        defer alloc.free(encoded_name);
        try headers.appendOwned(alloc, "Mcp-Name", encoded_name);
    }
    for (static_headers) |header| {
        try headers.append(alloc, header.name, header.value);
    }

    if (std.mem.eql(u8, request_info.method, "tools/call")) {
        const schema_json = input_schema_json orelse return error.MissingToolInputSchema;
        try appendProjectedHeaders(
            alloc,
            &headers,
            schema_json,
            request_info.params,
        );
    } else if (input_schema_json != null) {
        return error.UnexpectedToolInputSchema;
    }
    return .{ .headers = headers, .id = request_info.id, .is_discovery = is_discovery };
}

fn modernRequestInfo(value: std.json.Value) !RequestInfo {
    if (value != .object) return error.InvalidModernRequest;
    const jsonrpc = value.object.get("jsonrpc") orelse return error.InvalidModernRequest;
    if (jsonrpc != .string or !std.mem.eql(u8, jsonrpc.string, "2.0")) {
        return error.InvalidModernRequest;
    }
    const id_value = value.object.get("id") orelse return error.InvalidModernRequest;
    if (id_value != .integer) return error.InvalidModernRequest;
    const method_value = value.object.get("method") orelse return error.InvalidModernRequest;
    if (method_value != .string or method_value.string.len == 0) {
        return error.InvalidModernRequest;
    }
    const params_value = value.object.get("params") orelse return error.InvalidModernRequest;
    if (params_value != .object) return error.InvalidModernRequest;
    const meta_value = params_value.object.get("_meta") orelse return error.InvalidModernRequest;
    if (meta_value != .object) return error.InvalidModernRequest;
    const version_value = meta_value.object.get("io.modelcontextprotocol/protocolVersion") orelse {
        return error.InvalidModernRequest;
    };
    if (version_value != .string or !std.mem.eql(u8, version_value.string, protocol_version)) {
        return error.InvalidModernRequest;
    }
    const client_info = meta_value.object.get("io.modelcontextprotocol/clientInfo") orelse {
        return error.InvalidModernRequest;
    };
    if (client_info != .object) return error.InvalidModernRequest;
    const client_name = client_info.object.get("name") orelse return error.InvalidModernRequest;
    const client_version = client_info.object.get("version") orelse return error.InvalidModernRequest;
    if (client_name != .string or client_name.string.len == 0 or
        client_version != .string or client_version.string.len == 0)
    {
        return error.InvalidModernRequest;
    }
    const capabilities = meta_value.object.get("io.modelcontextprotocol/clientCapabilities") orelse {
        return error.InvalidModernRequest;
    };
    if (capabilities != .object) return error.InvalidModernRequest;

    const method = method_value.string;
    const identity_field: ?[]const u8 = if (std.mem.eql(u8, method, "tools/call") or
        std.mem.eql(u8, method, "prompts/get"))
        "name"
    else if (std.mem.eql(u8, method, "resources/read"))
        "uri"
    else
        null;
    const name = if (identity_field) |field| blk: {
        const name_value = params_value.object.get(field) orelse return error.InvalidModernRequest;
        if (name_value != .string) return error.InvalidModernRequest;
        break :blk name_value.string;
    } else null;

    return .{
        .id = id_value.integer,
        .method = method,
        .name = name,
        .params = params_value.object,
    };
}

fn appendProjectedHeaders(
    alloc: Allocator,
    headers: *OwnedHeaders,
    schema_json: []const u8,
    request_params: std.json.ObjectMap,
) !void {
    var schema = std.json.parseFromSlice(std.json.Value, alloc, schema_json, .{}) catch {
        return error.InvalidToolInputSchema;
    };
    defer schema.deinit();
    try validateToolInputSchemaValue(alloc, schema.value);

    const arguments_value = request_params.get("arguments") orelse return error.InvalidToolArguments;
    if (arguments_value != .object) return error.InvalidToolArguments;
    if (schema.value != .object) return error.InvalidToolInputSchema;
    const properties_value = schema.value.object.get("properties") orelse return;
    if (properties_value != .object) return error.InvalidToolInputSchema;

    try appendProjectedProperties(
        alloc,
        headers,
        properties_value.object,
        arguments_value.object,
        0,
    );
}

fn appendProjectedProperties(
    alloc: Allocator,
    headers: *OwnedHeaders,
    properties: std.json.ObjectMap,
    arguments: std.json.ObjectMap,
    depth: usize,
) !void {
    if (depth >= max_tool_schema_depth) return error.ToolInputSchemaTooDeep;

    var it = properties.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* != .object) continue;
        const property = entry.value_ptr.*.object;
        const argument = arguments.get(entry.key_ptr.*) orelse continue;
        if (argument == .null) continue;

        if (property.get("x-mcp-header")) |annotation| {
            const type_value = property.get("type").?;
            const plain_value = if (std.mem.eql(u8, type_value.string, "string")) blk: {
                if (argument != .string) return error.InvalidProjectedHeaderValue;
                break :blk try alloc.dupe(u8, argument.string);
            } else if (std.mem.eql(u8, type_value.string, "integer")) blk: {
                if (argument != .integer or
                    argument.integer < -max_json_safe_integer or
                    argument.integer > max_json_safe_integer)
                {
                    return error.InvalidProjectedHeaderValue;
                }
                break :blk try std.fmt.allocPrint(alloc, "{d}", .{argument.integer});
            } else blk: {
                if (argument != .bool) return error.InvalidProjectedHeaderValue;
                break :blk try alloc.dupe(u8, if (argument.bool) "true" else "false");
            };
            defer alloc.free(plain_value);

            const encoded_value = try encodeHeaderValue(alloc, plain_value);
            defer alloc.free(encoded_value);
            const header_name = try std.fmt.allocPrint(alloc, "Mcp-Param-{s}", .{annotation.string});
            defer alloc.free(header_name);
            try headers.appendOwned(alloc, header_name, encoded_value);
        }

        const nested_properties = property.get("properties") orelse continue;
        if (nested_properties != .object) return error.InvalidToolInputSchema;
        if (argument != .object) {
            if (try containsHeaderAnnotation(nested_properties, depth + 1)) {
                return error.InvalidProjectedHeaderValue;
            }
            continue;
        }
        try appendProjectedProperties(
            alloc,
            headers,
            nested_properties.object,
            argument.object,
            depth + 1,
        );
    }
}

fn validateToolInputSchemaValue(alloc: Allocator, value: std.json.Value) !void {
    if (value != .object) return error.InvalidToolInputSchema;
    var root_it = value.object.iterator();
    while (root_it.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, "properties")) continue;
        if (std.mem.eql(u8, entry.key_ptr.*, "x-mcp-header")) {
            return error.InvalidHeaderAnnotationPlacement;
        }
        if (try containsHeaderAnnotation(entry.value_ptr.*, 0)) {
            return error.InvalidHeaderAnnotationPlacement;
        }
    }

    const properties_value = value.object.get("properties") orelse return;
    if (properties_value != .object) return error.InvalidToolInputSchema;

    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(alloc);
    try validatePropertyAnnotations(
        alloc,
        properties_value.object,
        &names,
        0,
    );
}

fn validatePropertyAnnotations(
    alloc: Allocator,
    properties: std.json.ObjectMap,
    names: *std.ArrayList([]const u8),
    depth: usize,
) !void {
    if (depth >= max_tool_schema_depth) return error.ToolInputSchemaTooDeep;

    var it = properties.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* != .object) {
            if (try containsHeaderAnnotation(entry.value_ptr.*, 0)) {
                return error.InvalidHeaderAnnotationPlacement;
            }
            continue;
        }
        const property = entry.value_ptr.*.object;
        const annotation = property.get("x-mcp-header");
        if (annotation) |header_value| {
            if (header_value != .string or !isHttpToken(header_value.string)) {
                return error.InvalidHeaderAnnotationName;
            }
            const type_value = property.get("type") orelse return error.InvalidHeaderAnnotationType;
            if (type_value != .string or
                (!std.mem.eql(u8, type_value.string, "string") and
                    !std.mem.eql(u8, type_value.string, "integer") and
                    !std.mem.eql(u8, type_value.string, "boolean")))
            {
                return error.InvalidHeaderAnnotationType;
            }
            if (property.contains("$ref") or
                property.contains("allOf") or
                property.contains("anyOf") or
                property.contains("oneOf"))
            {
                return error.InvalidHeaderAnnotationType;
            }
            for (names.items) |name| {
                if (std.ascii.eqlIgnoreCase(name, header_value.string)) {
                    return error.DuplicateHeaderAnnotation;
                }
            }
            try names.append(alloc, header_value.string);
        }

        const nested_properties = property.get("properties");
        if (nested_properties) |nested| {
            if (nested != .object) return error.InvalidToolInputSchema;
            try validatePropertyAnnotations(
                alloc,
                nested.object,
                names,
                depth + 1,
            );
        }

        var property_it = property.iterator();
        while (property_it.next()) |child| {
            if (std.mem.eql(u8, child.key_ptr.*, "x-mcp-header") or
                std.mem.eql(u8, child.key_ptr.*, "properties"))
            {
                continue;
            }
            if (try containsHeaderAnnotation(child.value_ptr.*, 0)) {
                return error.InvalidHeaderAnnotationPlacement;
            }
        }
    }
}

fn containsHeaderAnnotation(value: std.json.Value, depth: usize) !bool {
    if (depth >= max_tool_schema_depth) return error.ToolInputSchemaTooDeep;
    return switch (value) {
        .object => |object| blk: {
            if (object.contains("x-mcp-header")) break :blk true;
            var it = object.iterator();
            while (it.next()) |entry| {
                if (try containsHeaderAnnotation(entry.value_ptr.*, depth + 1)) {
                    break :blk true;
                }
            }
            break :blk false;
        },
        .array => |array| blk: {
            for (array.items) |item| {
                if (try containsHeaderAnnotation(item, depth + 1)) break :blk true;
            }
            break :blk false;
        },
        else => false,
    };
}

fn encodeHeaderValue(alloc: Allocator, value: []const u8) ![]u8 {
    if (!needsHeaderEncoding(value)) return alloc.dupe(u8, value);

    const encoded_len = std.base64.standard.Encoder.calcSize(value.len);
    const result = try alloc.alloc(u8, "=?base64?".len + encoded_len + "?=".len);
    @memcpy(result[0.."=?base64?".len], "=?base64?");
    _ = std.base64.standard.Encoder.encode(
        result["=?base64?".len..][0..encoded_len],
        value,
    );
    @memcpy(result["=?base64?".len + encoded_len ..], "?=");
    return result;
}

fn needsHeaderEncoding(value: []const u8) bool {
    if (std.mem.startsWith(u8, value, "=?base64?")) return true;
    if (value.len > 0 and
        (value[0] == ' ' or value[0] == '\t' or
            value[value.len - 1] == ' ' or value[value.len - 1] == '\t'))
    {
        return true;
    }
    for (value) |byte| {
        if (byte < 0x20 or byte > 0x7e) return true;
    }
    return false;
}

const MediaType = enum { json, sse };

fn parseMediaType(value: []const u8) ?MediaType {
    const separator = std.mem.indexOfScalar(u8, value, ';') orelse value.len;
    const media_type = std.mem.trim(u8, value[0..separator], " \t");
    if (std.ascii.eqlIgnoreCase(media_type, "application/json")) return .json;
    if (std.ascii.eqlIgnoreCase(media_type, "text/event-stream")) return .sse;
    return null;
}

fn isPlainTextMediaType(value: []const u8) bool {
    const separator = std.mem.indexOfScalar(u8, value, ';') orelse value.len;
    const media_type = std.mem.trim(u8, value[0..separator], " \t");
    return std.ascii.eqlIgnoreCase(media_type, "text/plain");
}

fn readJsonResponse(
    alloc: Allocator,
    reader: *std.Io.Reader,
    request_id: i64,
    max_response_bytes: usize,
    allow_discovery_error_id_mismatch: bool,
) ![]u8 {
    var auth_rejection: AuthRejection = .none;
    const body = try readJsonResponseClassified(
        alloc,
        reader,
        request_id,
        max_response_bytes,
        allow_discovery_error_id_mismatch,
        &auth_rejection,
    );
    if (auth_rejection != .none) {
        alloc.free(body);
        return error.InvalidJsonResponse;
    }
    return body;
}

fn readJsonResponseClassified(
    alloc: Allocator,
    reader: *std.Io.Reader,
    request_id: i64,
    max_response_bytes: usize,
    allow_discovery_error_id_mismatch: bool,
    auth_rejection: *AuthRejection,
) ![]u8 {
    auth_rejection.* = .none;
    var body_list: std.ArrayList(u8) = .empty;
    defer body_list.deinit(alloc);
    var chunk: [16 * 1024]u8 = undefined;
    while (true) {
        const read_len = try reader.readSliceShort(&chunk);
        if (read_len > max_response_bytes -| body_list.items.len) {
            return error.ResponseTooLarge;
        }
        try body_list.appendSlice(alloc, chunk[0..read_len]);
        if (read_len < chunk.len) break;
    }
    const body = try body_list.toOwnedSlice(alloc);
    errdefer alloc.free(body);
    validateFinalResponse(
        alloc,
        body,
        request_id,
        allow_discovery_error_id_mismatch,
    ) catch |err| {
        if (allow_discovery_error_id_mismatch) {
            const rejection = try discoveryAuthenticationRejection(alloc, body);
            if (rejection != .none) {
                auth_rejection.* = rejection;
                return body;
            }
        }
        return err;
    };
    return body;
}

fn discoveryAuthenticationRejection(
    alloc: Allocator,
    body: []const u8,
) Allocator.Error!AuthRejection {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .none,
    };
    defer parsed.deinit();
    if (parsed.value != .object or parsed.value.object.contains("jsonrpc")) {
        return .none;
    }
    const status = parsed.value.object.get("error") orelse return .none;
    const reason = parsed.value.object.get("reason") orelse return .none;
    if (status != .integer or reason != .string) return .none;
    if (status.integer == 401 and std.mem.eql(u8, reason.string, "Unauthorized")) {
        return .unauthorized;
    }
    if (status.integer == 403 and std.mem.eql(u8, reason.string, "Forbidden")) {
        return .insufficient_scope;
    }
    return .none;
}

const SseEvent = struct {
    data: []u8,

    fn deinit(self: *SseEvent, alloc: Allocator) void {
        alloc.free(self.data);
        self.* = undefined;
    }
};

const SseParser = struct {
    alloc: Allocator,
    line: std.ArrayList(u8) = .empty,
    data: std.ArrayList(u8) = .empty,
    total_bytes: usize = 0,
    event_count: usize = 0,
    max_total_bytes: usize,
    max_event_bytes: usize,
    max_events: usize,
    pending_cr: bool = false,

    fn init(
        alloc: Allocator,
        max_total_bytes: usize,
        max_event_bytes: usize,
        max_events: usize,
    ) SseParser {
        return .{
            .alloc = alloc,
            .max_total_bytes = max_total_bytes,
            .max_event_bytes = max_event_bytes,
            .max_events = max_events,
        };
    }

    fn deinit(self: *SseParser) void {
        self.line.deinit(self.alloc);
        self.data.deinit(self.alloc);
        self.* = undefined;
    }

    fn feed(self: *SseParser, chunk: []const u8, events: *std.ArrayList(SseEvent)) !void {
        self.total_bytes = std.math.add(usize, self.total_bytes, chunk.len) catch {
            return error.ResponseTooLarge;
        };
        if (self.total_bytes > self.max_total_bytes) return error.ResponseTooLarge;

        for (chunk) |byte| {
            if (self.pending_cr) {
                self.pending_cr = false;
                if (byte == '\n') continue;
            }
            if (byte == '\r') {
                try self.processLine(self.line.items, events);
                self.line.clearRetainingCapacity();
                self.pending_cr = true;
                continue;
            }
            if (byte == '\n') {
                try self.processLine(self.line.items, events);
                self.line.clearRetainingCapacity();
                continue;
            }
            if (self.line.items.len >= self.max_event_bytes) return error.SseEventTooLarge;
            try self.line.append(self.alloc, byte);
        }
    }

    fn finish(self: *SseParser) !void {
        if (self.line.items.len != 0 or self.data.items.len != 0) {
            return error.BrokenSseStream;
        }
    }

    fn processLine(self: *SseParser, line: []const u8, events: *std.ArrayList(SseEvent)) !void {
        if (line.len == 0) {
            if (self.data.items.len == 0) return;
            self.event_count = std.math.add(usize, self.event_count, 1) catch
                return error.TooManySseEvents;
            if (self.event_count > self.max_events) return error.TooManySseEvents;
            const owned = try self.data.toOwnedSlice(self.alloc);
            errdefer self.alloc.free(owned);
            try events.append(self.alloc, .{ .data = owned });
            return;
        }
        if (line[0] == ':') return;

        const colon = std.mem.indexOfScalar(u8, line, ':') orelse line.len;
        if (!std.mem.eql(u8, line[0..colon], "data")) return;
        var value = if (colon < line.len) line[colon + 1 ..] else "";
        if (value.len > 0 and value[0] == ' ') value = value[1..];
        const separator_len: usize = if (self.data.items.len > 0) 1 else 0;
        const next_len = std.math.add(usize, self.data.items.len, separator_len + value.len) catch {
            return error.SseEventTooLarge;
        };
        if (next_len > self.max_event_bytes) return error.SseEventTooLarge;
        if (separator_len == 1) try self.data.append(self.alloc, '\n');
        try self.data.appendSlice(self.alloc, value);
    }
};

const SseOutcome = union(enum) {
    notification,
    progress,
    final,
};

fn classifySseEvent(
    alloc: Allocator,
    data: []const u8,
    request_id: i64,
    progress_sink: ?mcp_contract.ProgressSink,
    notification_sink: ?mcp_contract.NotificationSink,
) !SseOutcome {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, data, .{}) catch {
        return error.InvalidSseEvent;
    };
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidSseEvent;
    const jsonrpc = parsed.value.object.get("jsonrpc") orelse return error.InvalidSseEvent;
    if (jsonrpc != .string or !std.mem.eql(u8, jsonrpc.string, "2.0")) {
        return error.InvalidSseEvent;
    }

    if (parsed.value.object.get("id")) |id_value| {
        if (id_value != .integer or id_value.integer != request_id) {
            return error.MismatchedResponseId;
        }
        if (parsed.value.object.contains("result") or parsed.value.object.contains("error")) {
            return .final;
        }
        return error.UnsupportedServerRequest;
    }

    const method_value = parsed.value.object.get("method") orelse return error.InvalidSseEvent;
    if (method_value != .string) return error.InvalidSseEvent;
    if (!std.mem.eql(u8, method_value.string, "notifications/progress")) {
        if (notification_sink) |sink| sink.callback(sink.context, parsed.value);
        return .notification;
    }
    const params_value = parsed.value.object.get("params") orelse return .notification;
    if (params_value != .object) return .notification;
    const token_value = params_value.object.get("progressToken") orelse return .notification;
    if (token_value != .integer or token_value.integer != request_id) {
        return .notification;
    }
    const progress_value = params_value.object.get("progress") orelse return .notification;
    const progress = jsonNumberAsF64(progress_value) orelse return .notification;
    const total = if (params_value.object.get("total")) |value|
        jsonNumberAsF64(value)
    else
        null;
    const message = if (params_value.object.get("message")) |value|
        if (value == .string) value.string else null
    else
        null;
    if (progress_sink) |sink| {
        sink.callback(sink.context, .{
            .progress = progress,
            .total = total,
            .message = message,
        });
    }
    return .progress;
}

fn jsonNumberAsF64(value: std.json.Value) ?f64 {
    return switch (value) {
        .integer => |integer| @floatFromInt(integer),
        .float => |float| float,
        else => null,
    };
}

fn readSseResponse(
    alloc: Allocator,
    reader: *std.Io.Reader,
    request_id: i64,
    max_response_bytes: usize,
    max_event_bytes: usize,
    max_events: usize,
    progress_sink: ?mcp_contract.ProgressSink,
    notification_sink: ?mcp_contract.NotificationSink,
    cancellation: operation_control.CancellationSources,
) ![]u8 {
    var parser = SseParser.init(
        alloc,
        max_response_bytes,
        max_event_bytes,
        max_events,
    );
    defer parser.deinit();
    var events: std.ArrayList(SseEvent) = .empty;
    defer {
        for (events.items) |*event| event.deinit(alloc);
        events.deinit(alloc);
    }
    while (true) {
        if (reader.buffered().len == 0) {
            reader.fillMore() catch |err| switch (err) {
                error.EndOfStream => {
                    try parser.finish();
                    return error.MissingFinalResponse;
                },
                error.ReadFailed => return error.ReadFailed,
            };
        }
        const chunk = reader.buffered();
        if (chunk.len == 0) continue;
        const chunk_len = if (std.mem.indexOfAny(u8, chunk, "\r\n")) |index|
            index + 1
        else
            chunk.len;
        try parser.feed(chunk[0..chunk_len], &events);
        reader.toss(chunk_len);
        for (events.items) |*event| {
            switch (try classifySseEvent(
                alloc,
                event.data,
                request_id,
                progress_sink,
                notification_sink,
            )) {
                .notification, .progress => {},
                .final => {
                    try validateFinalResponse(alloc, event.data, request_id, false);
                    return alloc.dupe(u8, event.data);
                },
            }
            if (cancellation.cancelled()) return error.Cancelled;
        }
        for (events.items) |*event| event.deinit(alloc);
        events.clearRetainingCapacity();
    }
}

fn validateFinalResponse(
    alloc: Allocator,
    body: []const u8,
    request_id: i64,
    allow_discovery_error_id_mismatch: bool,
) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch {
        return error.InvalidJsonResponse;
    };
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidJsonResponse;
    const jsonrpc = parsed.value.object.get("jsonrpc") orelse return error.InvalidJsonResponse;
    if (jsonrpc != .string or !std.mem.eql(u8, jsonrpc.string, "2.0")) {
        return error.InvalidJsonResponse;
    }
    const id_value = parsed.value.object.get("id") orelse {
        if (allow_discovery_error_id_mismatch and
            isLegacyDiscoveryCompatibilityError(parsed.value.object)) return;
        return error.InvalidJsonResponse;
    };
    const matching_id = id_value == .integer and id_value.integer == request_id;
    const classifiable_discovery_error = allow_discovery_error_id_mismatch and
        parsed.value.object.contains("error") and
        !parsed.value.object.contains("result");
    if (!matching_id and !classifiable_discovery_error) {
        return error.MismatchedResponseId;
    }
    if (!parsed.value.object.contains("result") and !parsed.value.object.contains("error")) {
        return error.InvalidJsonResponse;
    }
}

const legacy_sessionless_invalid_request_code: i64 = -32004;
const legacy_session_required_code: i64 = -32000;
const legacy_missing_session_header_code: i64 = -32600;

fn isLegacyDiscoveryCompatibilityError(object: std.json.ObjectMap) bool {
    if (object.contains("result")) return false;
    const error_value = object.get("error") orelse return false;
    if (error_value != .object) return false;
    const code = error_value.object.get("code") orelse return false;
    const message = error_value.object.get("message") orelse return false;
    if (code != .integer or message != .string) return false;
    return (code.integer == legacy_sessionless_invalid_request_code and
        std.mem.eql(u8, message.string, "invalid request")) or
        (code.integer == legacy_session_required_code and
            std.mem.eql(u8, message.string, "Bad Request: Mcp-Session-Id header is required")) or
        (code.integer == legacy_missing_session_header_code and
            std.mem.eql(
                u8,
                message.string,
                "Missing required Mcp-Session-Id header. Non-initialize requests must include a session ID.",
            ));
}

fn isLegacyDiscoveryCompatibilityResponse(alloc: Allocator, body: []const u8) Allocator.Error!bool {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    return isLegacyDiscoveryCompatibilityError(parsed.value.object);
}

fn waitForCancellation(cancellation: operation_control.CancellationSources) anyerror!void {
    while (!cancellation.cancelled()) {
        try io_mod.getIo().sleep(.fromMilliseconds(5), .awake);
    }
}

fn waitForDeadline(deadline: std.Io.Clock.Timestamp) anyerror!void {
    try deadline.wait(io_mod.getIo());
}

fn isValidHeaderValue(value: []const u8) bool {
    for (value) |byte| {
        if ((byte < 0x20 and byte != '\t') or byte == 0x7f) return false;
    }
    return true;
}

fn isReservedHeader(name: []const u8) bool {
    const reserved = [_][]const u8{
        "accept",
        "accept-encoding",
        "connection",
        "content-length",
        "content-type",
        "host",
        "last-event-id",
        "mcp-method",
        "mcp-name",
        "mcp-protocol-version",
        "mcp-session-id",
        "transfer-encoding",
    };
    for (reserved) |candidate| {
        if (std.ascii.eqlIgnoreCase(name, candidate)) return true;
    }
    return startsWithIgnoreCase(name, "mcp-param-");
}

fn startsWithIgnoreCase(value: []const u8, prefix: []const u8) bool {
    return value.len >= prefix.len and std.ascii.eqlIgnoreCase(value[0..prefix.len], prefix);
}

test "modern MCP endpoint policy accepts HTTPS and explicit loopback HTTP" {
    try validateEndpoint("https://mcp.example.com/rpc?workspace=one");
    try validateEndpoint("http://localhost:4321/mcp");
    try validateEndpoint("http://127.0.0.1:4321/mcp");
    try validateEndpoint("http://[::1]:4321/mcp");

    try std.testing.expectError(error.InsecureEndpoint, validateEndpoint("http://example.com/mcp"));
    try std.testing.expectError(error.InsecureEndpoint, validateEndpoint("http://localhost/mcp"));
    try std.testing.expectError(error.InvalidEndpoint, validateEndpoint("https://user@example.com/mcp"));
    try std.testing.expectError(error.InvalidEndpoint, validateEndpoint("https://example.com/mcp#fragment"));
}

test "modern MCP static headers reject malformed duplicate and protocol-owned names" {
    const valid = [_]mcp_contract.McpHttpHeader{
        .{ .name = @constCast("Authorization"), .value = @constCast("Bearer redacted") },
        .{ .name = @constCast("X-Workspace"), .value = @constCast("one") },
    };
    try validateStaticHeaders(&valid);

    const duplicate = [_]mcp_contract.McpHttpHeader{
        .{ .name = @constCast("X-Workspace"), .value = @constCast("one") },
        .{ .name = @constCast("x-workspace"), .value = @constCast("two") },
    };
    try std.testing.expectError(error.DuplicateHeader, validateStaticHeaders(&duplicate));

    const invalid_name = [_]mcp_contract.McpHttpHeader{
        .{ .name = @constCast("Bad Header"), .value = @constCast("value") },
    };
    try std.testing.expectError(error.InvalidHeaderName, validateStaticHeaders(&invalid_name));

    const injected = [_]mcp_contract.McpHttpHeader{
        .{ .name = @constCast("X-Test"), .value = @constCast("one\r\ntwo") },
    };
    try std.testing.expectError(error.InvalidHeaderValue, validateStaticHeaders(&injected));

    const reserved = [_]mcp_contract.McpHttpHeader{
        .{ .name = @constCast("Mcp-Param-Region"), .value = @constCast("override") },
    };
    try std.testing.expectError(error.ReservedHeader, validateStaticHeaders(&reserved));

    const legacy_reserved = [_]mcp_contract.McpHttpHeader{
        .{ .name = @constCast("MCP-Session-Id"), .value = @constCast("override") },
    };
    try std.testing.expectError(
        error.ReservedHeader,
        validateStaticHeaders(&legacy_reserved),
    );
}

test "modern MCP request headers include protocol metadata and direct scalar projections" {
    const alloc = std.testing.allocator;
    const static_headers = [_]mcp_contract.McpHttpHeader{
        .{ .name = @constCast("X-Workspace"), .value = @constCast("one") },
    };
    const request_body =
        \\{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientInfo":{"name":"fx","version":"test"},"io.modelcontextprotocol/clientCapabilities":{}},"name":"echo","arguments":{"region":"us-west1","priority":42,"verbose":false,"unsafe":"Hello, 世界","padding":" padded ","empty":"","ignored":3.14,"nullable":null}}}
    ;
    const schema_json =
        \\{"type":"object","properties":{"region":{"type":"string","x-mcp-header":"Region"},"priority":{"type":"integer","x-mcp-header":"Priority"},"verbose":{"type":"boolean","x-mcp-header":"Verbose"},"unsafe":{"type":"string","x-mcp-header":"Unsafe"},"padding":{"type":"string","x-mcp-header":"Padding"},"empty":{"type":"string","x-mcp-header":"Empty"},"ignored":{"type":"number"},"nullable":{"type":"string","x-mcp-header":"Nullable"}}}
    ;

    var prepared = try prepareRequest(
        alloc,
        &static_headers,
        request_body,
        schema_json,
    );
    defer prepared.deinit(alloc);
    const headers = &prepared.headers;

    try expectHeader(headers, "Accept", "application/json, text/event-stream");
    try expectHeader(headers, "MCP-Protocol-Version", protocol_version);
    try expectHeader(headers, "Mcp-Method", "tools/call");
    try expectHeader(headers, "Mcp-Name", "echo");
    try expectHeader(headers, "X-Workspace", "one");
    try expectHeader(headers, "Mcp-Param-Region", "us-west1");
    try expectHeader(headers, "Mcp-Param-Priority", "42");
    try expectHeader(headers, "Mcp-Param-Verbose", "false");
    try expectHeader(headers, "Mcp-Param-Unsafe", "=?base64?SGVsbG8sIOS4lueVjA==?=");
    try expectHeader(headers, "Mcp-Param-Padding", "=?base64?IHBhZGRlZCA=?=");
    try expectHeader(headers, "Mcp-Param-Empty", "");
    try std.testing.expect(findHeader(headers, "Mcp-Param-Ignored") == null);
    try std.testing.expect(findHeader(headers, "Mcp-Param-Nullable") == null);
}

test "modern MCP request headers include feature identities" {
    const alloc = std.testing.allocator;
    const meta =
        \\{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientInfo":{"name":"fx","version":"test"},"io.modelcontextprotocol/clientCapabilities":{}}
    ;
    const cases = [_]struct {
        body: []const u8,
        method: []const u8,
        name: []const u8,
    }{
        .{
            .body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"resources/read\",\"params\":{\"_meta\":" ++ meta ++ ",\"uri\":\"Hello, 世界\"}}",
            .method = "resources/read",
            .name = "=?base64?SGVsbG8sIOS4lueVjA==?=",
        },
        .{
            .body = "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"prompts/get\",\"params\":{\"_meta\":" ++ meta ++ ",\"name\":\"review\",\"arguments\":{}}}",
            .method = "prompts/get",
            .name = "review",
        },
    };
    for (cases) |case| {
        var prepared = try prepareRequest(alloc, &.{}, case.body, null);
        defer prepared.deinit(alloc);
        try expectHeader(&prepared.headers, "Mcp-Method", case.method);
        try expectHeader(&prepared.headers, "Mcp-Name", case.name);
    }

    const list_body =
        \\{"jsonrpc":"2.0","id":3,"method":"resources/list","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientInfo":{"name":"fx","version":"test"},"io.modelcontextprotocol/clientCapabilities":{}}}}
    ;
    var list = try prepareRequest(alloc, &.{}, list_body, null);
    defer list.deinit(alloc);
    try std.testing.expect(findHeader(&list.headers, "Mcp-Name") == null);

    const invalid_bodies = [_][]const u8{
        \\{"jsonrpc":"2.0","id":4,"method":"resources/read","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientInfo":{"name":"fx","version":"test"},"io.modelcontextprotocol/clientCapabilities":{}}}}
        ,
        \\{"jsonrpc":"2.0","id":5,"method":"prompts/get","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientInfo":{"name":"fx","version":"test"},"io.modelcontextprotocol/clientCapabilities":{}},"name":7}}
        ,
    };
    for (invalid_bodies) |body| {
        try std.testing.expectError(
            error.InvalidModernRequest,
            prepareRequest(alloc, &.{}, body, null),
        );
    }
}

test "HTTP discovery carries required protocol metadata" {
    const alloc = std.testing.allocator;
    const request_body =
        \\{"jsonrpc":"2.0","id":1,"method":"server/discover","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientInfo":{"name":"fx","version":"test"},"io.modelcontextprotocol/clientCapabilities":{}}}}
    ;

    var initial = try prepareRequest(alloc, &.{}, request_body, null);
    defer initial.deinit(alloc);
    try expectHeader(&initial.headers, "MCP-Protocol-Version", protocol_version);
    try expectHeader(&initial.headers, "Mcp-Method", "server/discover");
}

test "modern MCP request headers project nested properties" {
    const alloc = std.testing.allocator;
    const request_body =
        \\{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientInfo":{"name":"fx","version":"test"},"io.modelcontextprotocol/clientCapabilities":{}},"name":"echo","arguments":{"routing":{"region":"us-east1","options":{"verbose":true}}}}}
    ;
    const schema_json =
        \\{"type":"object","properties":{"routing":{"type":"object","allOf":[],"if":{"type":"object"},"properties":{"region":{"type":"string","x-mcp-header":"Region"},"options":{"type":"object","properties":{"verbose":{"type":"boolean","x-mcp-header":"Verbose"}}}}}}}
    ;

    var prepared = try prepareRequest(alloc, &.{}, request_body, schema_json);
    defer prepared.deinit(alloc);

    try expectHeader(&prepared.headers, "Mcp-Param-Region", "us-east1");
    try expectHeader(&prepared.headers, "Mcp-Param-Verbose", "true");
}

test "modern MCP projected integers stay within the JSON safe range" {
    const alloc = std.testing.allocator;
    const schema_json =
        \\{"type":"object","properties":{"minimum":{"type":"integer","x-mcp-header":"Minimum"},"maximum":{"type":"integer","x-mcp-header":"Maximum"}}}
    ;
    const boundary_request =
        \\{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientInfo":{"name":"fx","version":"test"},"io.modelcontextprotocol/clientCapabilities":{}},"name":"echo","arguments":{"minimum":-9007199254740991,"maximum":9007199254740991}}}
    ;
    var prepared = try prepareRequest(alloc, &.{}, boundary_request, schema_json);
    defer prepared.deinit(alloc);
    try expectHeader(&prepared.headers, "Mcp-Param-Minimum", "-9007199254740991");
    try expectHeader(&prepared.headers, "Mcp-Param-Maximum", "9007199254740991");

    const outside_requests = [_][]const u8{
        \\{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientInfo":{"name":"fx","version":"test"},"io.modelcontextprotocol/clientCapabilities":{}},"name":"echo","arguments":{"minimum":-9007199254740992}}}
        ,
        \\{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientInfo":{"name":"fx","version":"test"},"io.modelcontextprotocol/clientCapabilities":{}},"name":"echo","arguments":{"maximum":9007199254740992}}}
        ,
    };
    for (outside_requests) |request_body| {
        try std.testing.expectError(
            error.InvalidProjectedHeaderValue,
            prepareRequest(alloc, &.{}, request_body, schema_json),
        );
    }
}

test "modern MCP request metadata and projected values are validated before network I/O" {
    const alloc = std.testing.allocator;
    const missing_meta =
        \\{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}
    ;
    try std.testing.expectError(
        error.InvalidModernRequest,
        prepareRequest(alloc, &.{}, missing_meta, null),
    );

    const wrong_version =
        \\{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2025-06-18","io.modelcontextprotocol/clientCapabilities":{}}}}
    ;
    try std.testing.expectError(
        error.InvalidModernRequest,
        prepareRequest(alloc, &.{}, wrong_version, null),
    );

    const call =
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientInfo":{"name":"fx","version":"test"},"io.modelcontextprotocol/clientCapabilities":{}},"name":"echo","arguments":{"region":12}}}
    ;
    try std.testing.expectError(
        error.MissingToolInputSchema,
        prepareRequest(alloc, &.{}, call, null),
    );
    try std.testing.expectError(
        error.InvalidProjectedHeaderValue,
        prepareRequest(
            alloc,
            &.{},
            call,
            \\{"type":"object","properties":{"region":{"type":"string","x-mcp-header":"Region"}}}
            ,
        ),
    );
}

test "modern MCP tool header annotations reject ambiguous schemas without dereferencing" {
    const alloc = std.testing.allocator;
    try validateToolInputSchemaHeaders(
        alloc,
        \\{"type":"object","properties":{"local":{"$ref":"https://example.invalid/schema.json"}}}
        ,
    );

    const invalid_schemas = [_]struct {
        schema: []const u8,
        expected: anyerror,
    }{
        .{
            .schema =
            \\{"type":"object","x-mcp-header":"Root","properties":{}}
            ,
            .expected = error.InvalidHeaderAnnotationPlacement,
        },
        .{
            .schema =
            \\{"type":"object","properties":{"value":{"type":"string","x-mcp-header":""}}}
            ,
            .expected = error.InvalidHeaderAnnotationName,
        },
        .{
            .schema =
            \\{"type":"object","properties":{"value":{"type":"number","x-mcp-header":"Value"}}}
            ,
            .expected = error.InvalidHeaderAnnotationType,
        },
        .{
            .schema =
            \\{"type":"object","properties":{"one":{"type":"string","x-mcp-header":"Region"},"two":{"type":"string","x-mcp-header":"region"}}}
            ,
            .expected = error.DuplicateHeaderAnnotation,
        },
        .{
            .schema =
            \\{"type":"object","properties":{"value":{"type":"string","x-mcp-header":"Value","$ref":"#/$defs/value"}}}
            ,
            .expected = error.InvalidHeaderAnnotationType,
        },
        .{
            .schema =
            \\{"type":"object","properties":{"values":{"type":"array","items":{"type":"string","x-mcp-header":"Item"}}}}
            ,
            .expected = error.InvalidHeaderAnnotationPlacement,
        },
        .{
            .schema =
            \\{"type":"object","properties":{"value":{"oneOf":[{"type":"string","x-mcp-header":"Choice"}]}}}
            ,
            .expected = error.InvalidHeaderAnnotationPlacement,
        },
        .{
            .schema =
            \\{"type":"object","properties":{"value":{"if":{"type":"string","x-mcp-header":"Conditional"}}}}
            ,
            .expected = error.InvalidHeaderAnnotationPlacement,
        },
    };
    for (invalid_schemas) |case| {
        try std.testing.expectError(
            case.expected,
            validateToolInputSchemaHeaders(alloc, case.schema),
        );
    }
}

test "modern MCP tool header annotation names are unique across nested properties" {
    try std.testing.expectError(
        error.DuplicateHeaderAnnotation,
        validateToolInputSchemaHeaders(
            std.testing.allocator,
            \\{"type":"object","properties":{"region":{"type":"string","x-mcp-header":"Region"},"nested":{"type":"object","properties":{"value":{"type":"string","x-mcp-header":"region"}}}}}
            ,
        ),
    );
}

test "modern MCP content length reader leaves bytes after the declared body unread" {
    var source = std.Io.Reader.fixed("bodyafter");
    var reader_buffer: [3]u8 = undefined;
    var bounded = McpContentLengthReader.init(&source, 4, &reader_buffer);

    var body: [8]u8 = undefined;
    const body_len = try bounded.interface.readSliceShort(&body);
    try std.testing.expectEqual(@as(usize, 4), body_len);
    try std.testing.expectEqualStrings("body", body[0..body_len]);
    try std.testing.expectError(
        error.EndOfStream,
        bounded.interface.readSliceAll(body[0..1]),
    );

    var after: [5]u8 = undefined;
    try source.readSliceAll(&after);
    try std.testing.expectEqualStrings("after", &after);
}

test "modern MCP content length reader applies one bound across discard and read" {
    var source = std.Io.Reader.fixed("abcdef");
    var reader_buffer: [3]u8 = undefined;
    var bounded = McpContentLengthReader.init(&source, 4, &reader_buffer);

    try bounded.interface.discardAll(2);
    var body: [2]u8 = undefined;
    try bounded.interface.readSliceAll(&body);
    try std.testing.expectEqualStrings("cd", &body);
    try std.testing.expectError(
        error.EndOfStream,
        bounded.interface.discardAll(1),
    );

    var after: [2]u8 = undefined;
    try source.readSliceAll(&after);
    try std.testing.expectEqualStrings("ef", &after);
}

test "modern MCP zero content length does not consume the source" {
    var source = std.Io.Reader.fixed("x");
    var reader_buffer: [1]u8 = undefined;
    var bounded = McpContentLengthReader.init(&source, 0, &reader_buffer);

    var byte: [1]u8 = undefined;
    try std.testing.expectError(
        error.EndOfStream,
        bounded.interface.readSliceAll(&byte),
    );
    try source.readSliceAll(&byte);
    try std.testing.expectEqualStrings("x", &byte);
}

test "modern MCP content length reader supports incremental buffered reads" {
    var source = std.Io.Reader.fixed("abcdef");
    var reader_buffer: [2]u8 = undefined;
    var bounded = McpContentLengthReader.init(&source, 4, &reader_buffer);

    try bounded.interface.fillMore();
    try std.testing.expectEqualStrings("ab", bounded.interface.buffered());
    bounded.interface.toss(2);
    try bounded.interface.fillMore();
    try std.testing.expectEqualStrings("cd", bounded.interface.buffered());
    bounded.interface.toss(2);
    try std.testing.expectError(error.EndOfStream, bounded.interface.fillMore());

    var after: [2]u8 = undefined;
    try source.readSliceAll(&after);
    try std.testing.expectEqualStrings("ef", &after);
}

test "modern MCP response framing isolates only known content length bodies" {
    try std.testing.expectEqual(
        McpResponseBodyFraming.content_length,
        mcpResponseBodyFraming(.none, 42),
    );
    try std.testing.expectEqual(
        McpResponseBodyFraming.standard,
        mcpResponseBodyFraming(.none, null),
    );
    try std.testing.expectEqual(
        McpResponseBodyFraming.standard,
        mcpResponseBodyFraming(.chunked, 42),
    );
}

test "modern MCP JSON responses are bounded and retain request ownership" {
    const alloc = std.testing.allocator;
    const payload = "{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{\"ok\":true}}";

    var reader = std.Io.Reader.fixed(payload);
    const body = try readJsonResponse(alloc, &reader, 7, payload.len, false);
    defer alloc.free(body);
    try std.testing.expectEqualStrings(payload, body);

    var oversized_reader = std.Io.Reader.fixed(payload);
    try std.testing.expectError(
        error.ResponseTooLarge,
        readJsonResponse(alloc, &oversized_reader, 7, payload.len - 1, false),
    );

    var wrong_id_reader = std.Io.Reader.fixed(
        "{\"jsonrpc\":\"2.0\",\"id\":8,\"result\":{}}",
    );
    try std.testing.expectError(
        error.MismatchedResponseId,
        readJsonResponse(alloc, &wrong_id_reader, 7, 128, false),
    );

    const sdk_error =
        "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32000,\"message\":\"Server not initialized\"}}";
    var sdk_error_reader = std.Io.Reader.fixed(sdk_error);
    const sdk_error_body = try readJsonResponse(
        alloc,
        &sdk_error_reader,
        7,
        sdk_error.len,
        true,
    );
    defer alloc.free(sdk_error_body);
    try std.testing.expectEqualStrings(sdk_error, sdk_error_body);

    var strict_sdk_error_reader = std.Io.Reader.fixed(sdk_error);
    try std.testing.expectError(
        error.MismatchedResponseId,
        readJsonResponse(alloc, &strict_sdk_error_reader, 7, sdk_error.len, false),
    );

    const string_id_discovery_error =
        "{\"jsonrpc\":\"2.0\",\"id\":\"server-error\",\"error\":{\"code\":-32600,\"message\":\"Unsupported protocol version\"}}";
    var string_id_discovery_error_reader = std.Io.Reader.fixed(string_id_discovery_error);
    const string_id_discovery_error_body = try readJsonResponse(
        alloc,
        &string_id_discovery_error_reader,
        7,
        string_id_discovery_error.len,
        true,
    );
    defer alloc.free(string_id_discovery_error_body);
    try std.testing.expectEqualStrings(
        string_id_discovery_error,
        string_id_discovery_error_body,
    );

    const mongodb_session_error =
        "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32004,\"message\":\"invalid request\"}}";
    var mongodb_session_error_reader = std.Io.Reader.fixed(mongodb_session_error);
    const mongodb_session_error_body = try readJsonResponse(
        alloc,
        &mongodb_session_error_reader,
        7,
        mongodb_session_error.len,
        true,
    );
    defer alloc.free(mongodb_session_error_body);
    try std.testing.expectEqualStrings(
        mongodb_session_error,
        mongodb_session_error_body,
    );

    const gitmcp_session_error =
        "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32000,\"message\":\"Bad Request: Mcp-Session-Id header is required\"}}";
    var gitmcp_parsed = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        gitmcp_session_error,
        .{},
    );
    defer gitmcp_parsed.deinit();
    try std.testing.expect(isLegacyDiscoveryCompatibilityError(gitmcp_parsed.value.object));

    const stock_session_error =
        "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32000,\"message\":\"Bad Request: Mcp-Session-Id header is required\"}}";
    var stock_session_error_reader = std.Io.Reader.fixed(stock_session_error);
    const stock_session_error_body = try readJsonResponse(
        alloc,
        &stock_session_error_reader,
        7,
        stock_session_error.len,
        true,
    );
    defer alloc.free(stock_session_error_body);
    try std.testing.expectEqualStrings(stock_session_error, stock_session_error_body);

    const mongodb_deployed_session_error =
        "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32600,\"message\":\"Missing required Mcp-Session-Id header. Non-initialize requests must include a session ID.\"}}";
    var mongodb_deployed_session_error_reader = std.Io.Reader.fixed(
        mongodb_deployed_session_error,
    );
    const mongodb_deployed_session_error_body = try readJsonResponse(
        alloc,
        &mongodb_deployed_session_error_reader,
        7,
        mongodb_deployed_session_error.len,
        true,
    );
    defer alloc.free(mongodb_deployed_session_error_body);
    try std.testing.expectEqualStrings(
        mongodb_deployed_session_error,
        mongodb_deployed_session_error_body,
    );

    var unrelated_session_error = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32000,\"message\":\"Session expired\"}}",
        .{},
    );
    defer unrelated_session_error.deinit();
    try std.testing.expect(!isLegacyDiscoveryCompatibilityError(unrelated_session_error.value.object));

    const unrelated_missing_id_error =
        "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32601,\"message\":\"Method not found\"}}";
    var unrelated_missing_id_reader = std.Io.Reader.fixed(unrelated_missing_id_error);
    try std.testing.expectError(
        error.InvalidJsonResponse,
        readJsonResponse(
            alloc,
            &unrelated_missing_id_reader,
            7,
            unrelated_missing_id_error.len,
            true,
        ),
    );

    const string_id_success =
        "{\"jsonrpc\":\"2.0\",\"id\":\"server-error\",\"result\":{}}";
    var string_id_success_reader = std.Io.Reader.fixed(string_id_success);
    try std.testing.expectError(
        error.MismatchedResponseId,
        readJsonResponse(
            alloc,
            &string_id_success_reader,
            7,
            string_id_success.len,
            true,
        ),
    );
}

test "MCP discovery recognizes bounded authorization error documents" {
    const alloc = std.testing.allocator;
    const unauthorized =
        "{\"error\":401,\"reason\":\"Unauthorized\",\"detail\":\"You are not authorized for this resource.\"}";
    try std.testing.expectEqual(
        AuthRejection.unauthorized,
        try discoveryAuthenticationRejection(alloc, unauthorized),
    );
    var strict_reader = std.Io.Reader.fixed(unauthorized);
    try std.testing.expectError(
        error.InvalidJsonResponse,
        readJsonResponse(alloc, &strict_reader, 7, unauthorized.len, true),
    );
    try std.testing.expectEqual(
        AuthRejection.insufficient_scope,
        try discoveryAuthenticationRejection(
            alloc,
            "{\"error\":403,\"reason\":\"Forbidden\",\"detail\":\"Insufficient scope.\"}",
        ),
    );
    try std.testing.expectEqual(
        AuthRejection.none,
        try discoveryAuthenticationRejection(
            alloc,
            "{\"error\":401,\"reason\":\"not an authorization response\"}",
        ),
    );
    try std.testing.expectEqual(
        AuthRejection.none,
        try discoveryAuthenticationRejection(alloc, "not json"),
    );
}

fn expectModernSseDelimiterSplits(payload: []const u8) !void {
    const alloc = std.testing.allocator;
    for (0..payload.len + 1) |split| {
        var parser = SseParser.init(alloc, payload.len, 64, 1);
        defer parser.deinit();
        var events: std.ArrayList(SseEvent) = .empty;
        defer {
            for (events.items) |*event| event.deinit(alloc);
            events.deinit(alloc);
        }
        try parser.feed(payload[0..split], &events);
        try parser.feed(payload[split..], &events);
        try parser.finish();
        try std.testing.expectEqual(@as(usize, 1), events.items.len);
        try std.testing.expectEqualStrings("one\ntwo", events.items[0].data);
    }
}

test "modern MCP SSE accepts CR LF and CRLF across every chunk split" {
    for ([_][]const u8{
        "data: one\ndata: two\n\n",
        "data: one\rdata: two\r\r",
        "data: one\r\ndata: two\r\n\r\n",
        "data: one\r\ndata: two\r\r\n",
    }) |payload| {
        try expectModernSseDelimiterSplits(payload);
    }
}

fn fuzzModernSseParser(_: void, smith: *std.testing.Smith) !void {
    const alloc = std.testing.allocator;
    var input_buffer: [1024]u8 = undefined;
    const input_len: usize = @intCast(smith.slice(&input_buffer));
    const input = input_buffer[0..input_len];
    const split = input.len / 2;

    var parser = SseParser.init(alloc, input_buffer.len, 256, 16);
    defer parser.deinit();
    var events: std.ArrayList(SseEvent) = .empty;
    defer {
        for (events.items) |*event| event.deinit(alloc);
        events.deinit(alloc);
    }
    parser.feed(input[0..split], &events) catch return;
    parser.feed(input[split..], &events) catch return;
    parser.finish() catch return;
}

test "modern MCP SSE parser handles fuzzed event bytes" {
    try std.testing.fuzz({}, fuzzModernSseParser, .{
        .corpus = &.{
            "",
            "\n",
            "\r",
            "data: {}\n\n",
            "data: {}\r\r",
            "data: one\r\ndata: two\r\n\r\n",
            "data: one\r\ndata: two\r\r\n",
            "\xff\x00\r\r",
        },
    });
}

test "modern MCP SSE incrementally accepts notifications progress and one final response" {
    const alloc = std.testing.allocator;
    const payload =
        \\: keepalive
        \\event: message
        \\data: {"jsonrpc":"2.0","method":"notifications/tools/list_changed","params":{}}
        \\
        \\id: ignored
        \\data: {"jsonrpc":"2.0","method":"notifications/progress",
        \\data: "params":{"progressToken":7,"progress":1,"total":2,"message":"half"}}
        \\
        \\data: {"jsonrpc":"2.0","id":7,"result":{"content":[]}}
        \\
    ++ "\n";
    const Capture = struct {
        calls: usize = 0,
        progress: f64 = 0,
        total: ?f64 = null,
        message_seen: bool = false,

        fn accept(raw: *anyopaque, progress: mcp_contract.Progress) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
            self.progress = progress.progress;
            self.total = progress.total;
            self.message_seen = std.mem.eql(u8, progress.message orelse "", "half");
        }
    };
    var capture: Capture = .{};
    var reader = std.Io.Reader.fixed(payload);
    const body = try readSseResponse(
        alloc,
        &reader,
        7,
        payload.len,
        512,
        3,
        .{ .context = &capture, .callback = Capture.accept },
        null,
        .{},
    );
    defer alloc.free(body);

    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expectEqual(@as(f64, 1), capture.progress);
    try std.testing.expectEqual(@as(?f64, 2), capture.total);
    try std.testing.expect(capture.message_seen);
    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{\"content\":[]}}",
        body,
    );
}

test "modern MCP SSE stops when a notification cancels the operation" {
    const Capture = struct {
        cancelled: *std.atomic.Value(bool),
        calls: usize = 0,

        fn accept(raw: *anyopaque, _: std.json.Value) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
            self.cancelled.store(true, .release);
        }
    };

    const alloc = std.testing.allocator;
    var cancelled = std.atomic.Value(bool).init(false);
    var capture = Capture{ .cancelled = &cancelled };
    var reader = std.Io.Reader.fixed(
        "data: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/subscriptions/acknowledged\",\"params\":{}}\n\n",
    );

    try std.testing.expectError(
        error.Cancelled,
        readSseResponse(
            alloc,
            &reader,
            7,
            512,
            256,
            2,
            null,
            .{ .context = &capture, .callback = Capture.accept },
            .{ .caller = &cancelled },
        ),
    );
    try std.testing.expectEqual(@as(usize, 1), capture.calls);
}

test "modern MCP SSE rejects broken ownership and exceeded bounds" {
    const alloc = std.testing.allocator;

    var broken_reader = std.Io.Reader.fixed(
        "data: {\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{}}",
    );
    try std.testing.expectError(
        error.BrokenSseStream,
        readSseResponse(alloc, &broken_reader, 7, 256, 128, 2, null, null, .{}),
    );

    var wrong_id_reader = std.Io.Reader.fixed(
        "data: {\"jsonrpc\":\"2.0\",\"id\":8,\"result\":{}}\n\n",
    );
    try std.testing.expectError(
        error.MismatchedResponseId,
        readSseResponse(alloc, &wrong_id_reader, 7, 256, 128, 2, null, null, .{}),
    );

    var event_cap_reader = std.Io.Reader.fixed(
        "data: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/one\"}\n\n" ++
            "data: {\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{}}\n\n",
    );
    try std.testing.expectError(
        error.TooManySseEvents,
        readSseResponse(alloc, &event_cap_reader, 7, 512, 128, 1, null, null, .{}),
    );

    var byte_cap_reader = std.Io.Reader.fixed(
        "data: {\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{}}\n\n",
    );
    try std.testing.expectError(
        error.ResponseTooLarge,
        readSseResponse(alloc, &byte_cap_reader, 7, 16, 128, 2, null, null, .{}),
    );
}

test "modern MCP SSE completes at the matching final response" {
    const alloc = std.testing.allocator;
    const first = "data: {\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{}}\n\n";

    var reader = std.Io.Reader.fixed(
        first ++ "data: {\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{}}\n\n",
    );
    const body = try readSseResponse(
        alloc,
        &reader,
        7,
        first.len,
        128,
        2,
        null,
        null,
        .{},
    );
    defer alloc.free(body);
    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{}}",
        body,
    );
}

test "modern MCP response media types tolerate case and parameters only" {
    try std.testing.expectEqual(MediaType.json, parseMediaType("Application/JSON; charset=utf-8").?);
    try std.testing.expectEqual(MediaType.sse, parseMediaType(" text/event-stream ; charset=utf-8").?);
    try std.testing.expect(parseMediaType("application/problem+json") == null);
    try std.testing.expect(parseMediaType("text/plain") == null);
}

test "modern MCP cancellation and deadline fail before network admission" {
    var cancelled = std.atomic.Value(bool).init(true);
    try std.testing.expectError(
        error.Cancelled,
        post(std.testing.allocator, .{
            .url = "http://127.0.0.1:1/mcp",
            .request_body = "{}",
            .max_response_bytes = 128,
            .max_event_bytes = 128,
            .control = .{
                .deadline = std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake),
                .cancel_flag = &cancelled,
            },
        }),
    );

    var caller_cancelled = std.atomic.Value(bool).init(false);
    var runtime_retired = std.atomic.Value(bool).init(true);
    try std.testing.expectError(
        error.Cancelled,
        post(std.testing.allocator, .{
            .url = "http://127.0.0.1:1/mcp",
            .request_body = "{}",
            .max_response_bytes = 128,
            .max_event_bytes = 128,
            .control = .{
                .deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
                    .clock = .awake,
                    .raw = .fromSeconds(1),
                }),
                .cancel_flag = &caller_cancelled,
                .lifecycle_cancel_flag = &runtime_retired,
            },
        }),
    );
    try std.testing.expect(!caller_cancelled.load(.acquire));

    const expired = std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake);
    try std.testing.expectError(
        error.McpRequestTimedOut,
        post(std.testing.allocator, .{
            .url = "http://127.0.0.1:1/mcp",
            .request_body = "{}",
            .max_response_bytes = 128,
            .max_event_bytes = 128,
            .control = .{ .deadline = expired },
        }),
    );
}

fn findHeader(headers: *const OwnedHeaders, name: []const u8) ?[]const u8 {
    for (headers.items.items) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, name)) return header.value;
    }
    return null;
}

fn expectHeader(headers: *const OwnedHeaders, name: []const u8, value: []const u8) !void {
    try std.testing.expectEqualStrings(value, findHeader(headers, name) orelse return error.TestExpectedEqual);
}
