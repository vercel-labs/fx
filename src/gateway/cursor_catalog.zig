//! Cursor GetUsableModels discovery and the static roster fallback.
//!
//! Discovery is intentionally request-scoped: the model catalog runtime owns
//! refresh and persistence, while this module keeps no process-global model
//! cache or mutable route table. Dynamic rows retain the bundled metadata when
//! a row is known and use Cursor's advertised model id as the wire route.
const std = @import("std");
const pb = @import("cursor_protobuf.zig");
const client_mod = @import("client.zig");
const cursor_models = @import("cursor_models.zig");
const model_catalog = @import("../core/gateway/model_catalog.zig");
const credentials = @import("../core/auth/credentials.zig");
const cursor_oauth = @import("../core/auth/cursor_oauth.zig");
const io_mod = @import("../core/shared/io.zig");
const secret = @import("../core/auth/secret.zig");
const types = @import("../core/shared/types.zig");
const Allocator = std.mem.Allocator;

pub const default_base_url = "https://api2.cursor.sh";
const discovery_path = "/agent.v1.AgentService/GetUsableModels";
const default_context_window: u32 = 200_000;
const default_max_tokens: u32 = 64_000;
const one_m_context_window: u32 = 1_000_000;
const max_response_bytes: usize = 16 * 1024 * 1024;
const request_timeout_ms: i64 = 5_000;

/// Fetches the authenticated roster. A malformed, unavailable, or empty
/// discovery response returns the same static table used before discovery;
/// cancellation remains visible to the catalog runtime.
pub fn fetch(
    alloc: Allocator,
    base_url: []const u8,
    access: credentials.CatalogAccess,
    client_version: []const u8,
    input: model_catalog.FetchInput,
) Allocator.Error!model_catalog.ProviderResult {
    if (cancelled(input.cancel_flag)) return .{ .failure = .{ .category = .cancellation } };
    var fallback = try staticCatalog(alloc);
    const token = catalogAccessToken(alloc, access) catch |err| {
        model_catalog.freeModelCatalog(alloc, &fallback);
        return err;
    };
    defer if (token) |value| secret.zeroAndFree(alloc, value);
    if (token == null or token.?.len == 0) return .{ .catalog = fallback };

    const body = fetchResponse(alloc, base_url, token.?, client_version, input.cancel_flag) catch |err| switch (err) {
        error.OutOfMemory => {
            model_catalog.freeModelCatalog(alloc, &fallback);
            return error.OutOfMemory;
        },
        error.Cancelled => {
            model_catalog.freeModelCatalog(alloc, &fallback);
            return .{ .failure = .{ .category = .cancellation } };
        },
        else => return .{ .catalog = fallback },
    };
    defer alloc.free(body);
    if (cancelled(input.cancel_flag)) {
        model_catalog.freeModelCatalog(alloc, &fallback);
        return .{ .failure = .{ .category = .cancellation } };
    }

    const discovered = parseDiscovered(alloc, body) catch |err| {
        model_catalog.freeModelCatalog(alloc, &fallback);
        return err;
    };
    if (discovered) |dynamic| {
        if (dynamic.items.len != 0) {
            model_catalog.freeModelCatalog(alloc, &fallback);
            return .{ .catalog = dynamic };
        }
        var empty = dynamic;
        model_catalog.freeModelCatalog(alloc, &empty);
    }
    return .{ .catalog = fallback };
}

fn cancelled(flag: ?*std.atomic.Value(bool)) bool {
    return if (flag) |value| value.load(.seq_cst) else false;
}

/// Resolves the provider-keyed CatalogAccess credential into the bearer value
/// Cursor discovery expects. Saved Cursor keys use `<access>|<refresh>`;
/// provider-keyed callers hand us that saved form or a bare API key.
pub fn catalogAccessToken(alloc: Allocator, access: credentials.CatalogAccess) Allocator.Error!?[]u8 {
    const credential = access.authorizationCredential() orelse return null;
    const parsed = cursor_oauth.parse(credential);
    const value = if (parsed.access.len != 0) parsed.access else parsed.refresh;
    if (value.len == 0) return null;
    return try alloc.dupe(u8, value);
}

fn staticCatalog(alloc: Allocator) !std.ArrayList(model_catalog.ModelCatalogEntry) {
    var entries: std.ArrayList(model_catalog.ModelCatalogEntry) = .empty;
    errdefer model_catalog.freeModelCatalog(alloc, &entries);
    try entries.ensureTotalCapacity(alloc, cursor_models.models.len);
    for (cursor_models.models) |model| try appendEntry(alloc, &entries, model.id, model.name, model.max_mode orelse false, model);
    return entries;
}

fn appendEntry(
    alloc: Allocator,
    entries: *std.ArrayList(model_catalog.ModelCatalogEntry),
    id: []const u8,
    name: []const u8,
    max_mode: bool,
    reference: cursor_models.Model,
) !void {
    const owned_id = try alloc.dupe(u8, id);
    errdefer alloc.free(owned_id);
    const owned_name = try alloc.dupe(u8, name);
    errdefer alloc.free(owned_name);
    const model_type = try alloc.dupe(u8, "language");
    errdefer alloc.free(model_type);
    const owned_description = if (reference.description) |description| try alloc.dupe(u8, description) else null;
    errdefer if (owned_description) |description| alloc.free(description);
    var efforts: std.ArrayList(types.ReasoningEffort) = .empty;
    errdefer efforts.deinit(alloc);
    for (reference.efforts) |effort| try efforts.append(alloc, types.ReasoningEffort.parse(effort) orelse continue);
    const has_reasoning = reference.efforts.len != 0;
    const has_vision = cursor_models.resolveInput(id);
    try entries.append(alloc, .{
        .id = owned_id,
        .name = owned_name,
        .description = owned_description,
        .cost = reference.cost,
        .intelligence = reference.intelligence,
        .model_type = model_type,
        .has_tool_use = true,
        .has_reasoning = has_reasoning,
        .reasoning_efforts = efforts,
        .has_vision = has_vision,
        .has_file_input = has_vision,
        .context_window = reference.context_window,
        .max_tokens = reference.max_output_tokens,
        .max_context_window = if (max_mode and reference.context_window >= one_m_context_window) reference.context_window else null,
    });
}

fn appendDiscovered(
    alloc: Allocator,
    entries: *std.ArrayList(model_catalog.ModelCatalogEntry),
    id: []const u8,
    display_model_id: []const u8,
    display_name: []const u8,
    display_name_short: []const u8,
    alias: []const u8,
    has_thinking_details: bool,
    max_mode: bool,
) !void {
    if (id.len == 0 or containsId(entries.items, id)) return;
    const reference = cursor_models.find(id);
    const fallback_name = if (reference) |model| model.name else id;
    const name = pickName(&.{ display_name, display_name_short, display_model_id, alias, fallback_name });
    const base_context = if (reference) |model| model.context_window else default_context_window;
    const labeled_one_m = containsIgnoreCase(display_model_id, "1m") or
        containsIgnoreCase(display_name, "1m") or
        containsIgnoreCase(display_name_short, "1m") or
        containsIgnoreCase(alias, "1m");
    const context_window = resolveContextWindow(id, name, max_mode, base_context, labeled_one_m);
    const max_tokens = if (reference) |model| model.max_output_tokens else default_max_tokens;
    const has_reasoning = has_thinking_details or isReasoningId(id) or (reference != null and reference.?.efforts.len != 0);
    const has_vision = cursor_models.resolveInput(id);

    const owned_id = try alloc.dupe(u8, id);
    errdefer alloc.free(owned_id);
    const owned_name = try alloc.dupe(u8, name);
    errdefer alloc.free(owned_name);
    const model_type = try alloc.dupe(u8, "language");
    errdefer alloc.free(model_type);
    const owned_description = if (reference) |model| if (model.description) |description| try alloc.dupe(u8, description) else null else null;
    errdefer if (owned_description) |description| alloc.free(description);
    var efforts: std.ArrayList(types.ReasoningEffort) = .empty;
    errdefer efforts.deinit(alloc);
    if (reference) |model| for (model.efforts) |effort| try efforts.append(alloc, types.ReasoningEffort.parse(effort) orelse continue);

    try entries.append(alloc, .{
        .id = owned_id,
        .name = owned_name,
        .description = owned_description,
        .cost = if (reference) |model| model.cost else .{},
        .intelligence = if (reference) |model| model.intelligence else null,
        .model_type = model_type,
        .has_tool_use = true,
        .has_reasoning = has_reasoning,
        .reasoning_efforts = efforts,
        .has_vision = has_vision,
        .has_file_input = has_vision,
        .context_window = context_window,
        .max_tokens = max_tokens,
        .max_context_window = if (context_window >= one_m_context_window) context_window else null,
    });
}

fn containsId(entries: []const model_catalog.ModelCatalogEntry, id: []const u8) bool {
    for (entries) |entry| if (std.mem.eql(u8, entry.id, id)) return true;
    return false;
}

fn pickName(candidates: []const []const u8) []const u8 {
    for (candidates) |candidate| {
        const trimmed = std.mem.trim(u8, candidate, " \t\r\n");
        if (trimmed.len != 0) return trimmed;
    }
    return "";
}

fn isReasoningId(id: []const u8) bool {
    const grok = std.ascii.startsWithIgnoreCase(id, "cursor-grok-") and
        id.len > "cursor-grok-".len and
        std.ascii.isDigit(id["cursor-grok-".len]);
    return grok or std.ascii.startsWithIgnoreCase(id, "kimi-k3") or std.mem.eql(u8, id, "k3");
}

fn resolveContextWindow(id: []const u8, name: []const u8, max_mode: bool, fallback: u32, labeled_one_m: bool) u32 {
    if (labeled_one_m or containsIgnoreCase(id, "1m") or containsIgnoreCase(name, "1m") or
        (max_mode and (containsIgnoreCase(id, "claude") or containsIgnoreCase(id, "gemini")))) return @max(fallback, one_m_context_window);
    if (std.mem.eql(u8, id, "default")) return @max(fallback, 256_000);
    if (containsIgnoreCase(id, "grok-4.5") or containsIgnoreCase(id, "grok-4.6")) return @max(fallback, 256_000);
    if (containsIgnoreCase(id, "kimi-k2.7-code")) return @max(fallback, 262_000);
    if (containsIgnoreCase(id, "gpt-5.6")) return @max(fallback, 272_000);
    if (containsIgnoreCase(id, "claude-opus-5") or containsIgnoreCase(id, "claude-fable-5")) return @max(fallback, 300_000);
    if (containsIgnoreCase(id, "kimi-k3") or containsIgnoreCase(id, "glm-5.2")) return @max(fallback, one_m_context_window);
    return fallback;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or needle.len > haystack.len) return false;
    var index: usize = 0;
    while (index <= haystack.len - needle.len) : (index += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[index .. index + needle.len], needle)) return true;
    }
    return false;
}

fn parseDiscovered(alloc: Allocator, body: []const u8) Allocator.Error!?std.ArrayList(model_catalog.ModelCatalogEntry) {
    const message = unaryMessage(body) orelse return null;
    if (message.len == 0) return null;
    var entries: std.ArrayList(model_catalog.ModelCatalogEntry) = .empty;
    errdefer model_catalog.freeModelCatalog(alloc, &entries);
    var reader = pb.Reader.init(message);
    while (true) {
        const maybe_field = reader.next() catch {
            model_catalog.freeModelCatalog(alloc, &entries);
            return null;
        };
        const field = maybe_field orelse break;
        if (field.number != 1 or field.wire != .bytes) continue;
        var details = pb.Reader.init(field.data);
        var id: []const u8 = "";
        var display_model_id: []const u8 = "";
        var display_name: []const u8 = "";
        var display_name_short: []const u8 = "";
        var alias: []const u8 = "";
        var thinking = false;
        var max_mode = false;
        while (true) {
            const maybe_detail = details.next() catch {
                model_catalog.freeModelCatalog(alloc, &entries);
                return null;
            };
            const detail = maybe_detail orelse break;
            if (detail.wire == .bytes) switch (detail.number) {
                1 => id = detail.data,
                2 => thinking = true,
                3 => display_model_id = detail.data,
                4 => display_name = detail.data,
                5 => display_name_short = detail.data,
                6 => {
                    if (alias.len == 0) alias = detail.data;
                },
                else => {},
            } else if (detail.number == 7 and detail.wire == .varint) max_mode = detail.int != 0;
        }
        const normalized_id = std.mem.trim(u8, id, " \t\r\n");
        try appendDiscovered(alloc, &entries, normalized_id, display_model_id, display_name, display_name_short, alias, thinking, max_mode);
    }
    std.mem.sort(model_catalog.ModelCatalogEntry, entries.items, {}, compareDiscoveredEntries);
    return entries;
}

fn compareDiscoveredEntries(_: void, a: model_catalog.ModelCatalogEntry, b: model_catalog.ModelCatalogEntry) bool {
    return std.mem.order(u8, a.id, b.id) == .lt;
}

fn unaryMessage(body: []const u8) ?[]const u8 {
    if (body.len < 5) return body;
    const flags = body[0];
    if ((flags & 0x01) != 0) return null;
    const length = std.mem.readInt(u32, body[1..5], .big);
    const end = 5 +| @as(usize, length);
    if (end > body.len or (flags & 0x02) != 0) return body;
    return body[5..end];
}

fn buildRequest(alloc: Allocator) ![]u8 {
    var request = pb.Writer.init(alloc);
    defer request.deinit();
    return try alloc.dupe(u8, request.bytes.items);
}

fn fetchResponse(
    alloc: Allocator,
    base_url: []const u8,
    token: []const u8,
    client_version: []const u8,
    cancel_flag: ?*std.atomic.Value(bool),
) ![]u8 {
    const url = try std.mem.concat(alloc, u8, &.{ std.mem.trimEnd(u8, base_url, "/"), discovery_path });
    defer alloc.free(url);
    const authorization = try alloc.print("Bearer {s}", .{token});
    defer secret.zeroAndFree(alloc, authorization);
    var client: std.http.Client = .{ .allocator = alloc, .io = io_mod.getIo() };
    defer client.deinit();
    const uri = try std.Uri.parse(url);
    var extra: [4]std.http.Header = .{
        .{ .name = "x-ghost-mode", .value = "true" },
        .{ .name = "x-cursor-client-version", .value = client_version },
        .{ .name = "x-cursor-client-type", .value = "cli" },
        .{ .name = "te", .value = "trailers" },
    };
    var operation = DiscoveryOpen{ .client = &client, .uri = uri, .authorization = authorization, .extra_headers = &extra };
    var local_cancel = std.atomic.Value(bool).init(false);
    const cancel = cancel_flag orelse &local_cancel;
    var connection = try client_mod.runBoundedHttpOperation(
        client_mod.OpenedPost,
        alloc,
        cancel,
        std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{ .clock = .awake, .raw = .fromMilliseconds(request_timeout_ms) }),
        &operation,
    );
    defer connection.deinit(alloc);
    const http = &connection.request.?;
    var watch: client_mod.ConnectionWatch = .init(.{ .timeout_ms = request_timeout_ms, .stall_timeout_ms = request_timeout_ms });
    defer watch.stop();
    if (http.connection) |stream_connection| try watch.start(cancel, null, stream_connection.stream_writer.stream);
    if (watch.armHead()) |err| return err;

    const payload = try buildRequest(alloc);
    defer alloc.free(payload);
    http.transfer_encoding = .{ .content_length = payload.len };
    var send_buffer: [8192]u8 = undefined;
    var writer = try http.sendBodyUnflushed(&send_buffer);
    try writer.writer.writeAll(payload);
    try writer.end();
    if (http.connection) |stream_connection| try stream_connection.flush();
    var transfer: [64 * 1024]u8 = undefined;
    var response = http.receiveHead(&.{}) catch |err| return watch.failure(err);
    if (watch.commitHead()) |err| return err;
    const reader = response.reader(&transfer);
    if (response.head.status != .ok) return error.CursorDiscoveryUnavailable;
    const body = reader.allocRemaining(alloc, .limited(max_response_bytes)) catch |err| return watch.failure(err);
    if (watch.finish()) |err| {
        alloc.free(body);
        return err;
    }
    return body;
}

const DiscoveryOpen = struct {
    client: *std.http.Client,
    uri: std.Uri,
    authorization: []const u8,
    extra_headers: []const std.http.Header,

    pub fn run(self: *DiscoveryOpen) !client_mod.OpenedPost {
        return .{ .request = try self.client.request(.POST, self.uri, .{
            .headers = .{
                .content_type = .{ .override = "application/proto" },
                .accept_encoding = .omit,
                .authorization = .{ .override = self.authorization },
            },
            .extra_headers = self.extra_headers,
            .keep_alive = false,
            .redirect_behavior = .unhandled,
        }) };
    }
};

const CatalogHttpFixture = struct {
    io_backend: std.Io.Threaded = .init_single_threaded,
    server: std.Io.net.Server,
    thread: ?std.Thread = null,
    open: bool = true,
    stopping: std.atomic.Value(bool) = .init(false),
    request_headers: [16 * 1024]u8 = undefined,
    request_headers_len: std.atomic.Value(usize) = .init(0),
    response: [4096]u8 = undefined,
    response_len: usize = 0,
    failure: ?anyerror = null,

    fn init(response: []const u8) !@This() {
        var fixture: @This() = .{ .server = undefined };
        var address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
        fixture.server = try address.listen(fixture.io_backend.io(), .{ .reuse_address = true });
        if (response.len > fixture.response.len) return error.ResponseTooLarge;
        @memcpy(fixture.response[0..response.len], response);
        fixture.response_len = response.len;
        return fixture;
    }

    fn io(self: *@This()) std.Io {
        return self.io_backend.io();
    }

    fn port(self: *@This()) u16 {
        return self.server.socket.address.getPort();
    }

    fn start(self: *@This()) !void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    fn deinit(self: *@This()) void {
        if (!self.open) return;
        self.stopping.store(true, .seq_cst);
        if (self.thread) |thread| {
            const listener = std.Io.net.Stream{ .socket = self.server.socket };
            listener.shutdown(self.io(), .both) catch {};
            self.wakeAccept();
            thread.join();
            self.thread = null;
        }
        self.server.deinit(self.io());
        self.open = false;
    }

    fn wakeAccept(self: *@This()) void {
        var io_backend: std.Io.Threaded = .init_single_threaded;
        const address = std.Io.net.IpAddress{ .ip4 = .loopback(self.port()) };
        var stream = address.connect(io_backend.io(), .{ .mode = .stream }) catch return;
        stream.close(io_backend.io());
    }

    fn run(self: *@This()) void {
        self.runFallible() catch |err| {
            if (!self.stopping.load(.seq_cst)) self.failure = err;
        };
    }

    fn runFallible(self: *@This()) !void {
        var stream = try self.server.accept(self.io());
        defer stream.close(self.io());
        var socket_buffer: [4096]u8 = undefined;
        var reader = stream.reader(self.io(), &socket_buffer);
        var request: [16 * 1024]u8 = undefined;
        var header_len: usize = 0;
        while (header_len < request.len) {
            request[header_len] = try reader.interface.takeByte();
            header_len += 1;
            if (!std.mem.endsWith(u8, request[0..header_len], "\r\n\r\n")) continue;
            const headers = request[0 .. header_len - 4];
            @memcpy(self.request_headers[0..headers.len], headers);
            self.request_headers_len.store(headers.len, .seq_cst);
            if (contentLength(headers)) |length| {
                var body: [4096]u8 = undefined;
                var consumed: usize = 0;
                while (consumed < length) {
                    const chunk = body[0..@min(body.len, length - consumed)];
                    const count = try reader.interface.readSliceShort(chunk);
                    if (count == 0) return error.UnexpectedEndOfStream;
                    consumed += count;
                }
            }
            break;
        } else return error.RequestTooLarge;

        var head: [256]u8 = undefined;
        const response_head = try std.fmt.bufPrint(&head, "HTTP/1.1 200 OK\r\nContent-Type: application/proto\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{self.response_len});
        var writer_buffer: [4096]u8 = undefined;
        var writer = stream.writer(self.io(), &writer_buffer);
        try writer.interface.writeAll(response_head);
        try writer.interface.writeAll(self.response[0..self.response_len]);
        try writer.interface.flush();
    }

    fn contentLength(headers: []const u8) ?usize {
        var lines = std.mem.splitSequence(u8, headers, "\r\n");
        while (lines.next()) |line| {
            const name = "content-length:";
            if (line.len < name.len or !std.ascii.eqlIgnoreCase(line[0..name.len], name)) continue;
            return std.fmt.parseInt(usize, std.mem.trim(u8, line[name.len..], " \t"), 10) catch null;
        }
        return null;
    }

    fn header(self: *@This(), name: []const u8) ?[]const u8 {
        const len = self.request_headers_len.load(.seq_cst);
        var lines = std.mem.splitSequence(u8, self.request_headers[0..len], "\r\n");
        _ = lines.next();
        while (lines.next()) |line| {
            const colon = std.mem.findScalar(u8, line, ':') orelse continue;
            if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " \t"), name)) continue;
            return std.mem.trim(u8, line[colon + 1 ..], " \t");
        }
        return null;
    }
};

test "Cursor catalog fixture sends provider credential and required headers" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var details = pb.Writer.init(arena);
    try details.stringField(1, "gpt-5.6-luna");
    try details.stringField(4, "Luna live");
    var response = pb.Writer.init(arena);
    try response.bytesField(1, details.bytes.items);
    var fixture = try CatalogHttpFixture.init(response.bytes.items);
    defer fixture.deinit();
    try fixture.start();

    const base_url = try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}", .{fixture.port()});
    const access = credentials.catalogAccessForCredential(.stored_key, "provider-catalog-token", null);
    const input = model_catalog.FetchInput{ .access = access, .endpoint = "" };
    var result = try fetch(arena, base_url, access, "cli-test", input);
    defer model_catalog.freeModelCatalog(arena, &result.catalog);
    try std.testing.expectEqual(@as(usize, 1), result.catalog.items.len);
    try std.testing.expectEqualStrings("Bearer provider-catalog-token", fixture.header("authorization").?);
    try std.testing.expectEqualStrings("true", fixture.header("x-ghost-mode").?);
    try std.testing.expectEqualStrings("cli-test", fixture.header("x-cursor-client-version").?);
    try std.testing.expectEqualStrings("cli", fixture.header("x-cursor-client-type").?);
    try std.testing.expectEqualStrings("trailers", fixture.header("te").?);
    try std.testing.expect(fixture.failure == null);
}

test "Cursor discovery preserves display metadata and bundled effort routes" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var luna = pb.Writer.init(arena);
    try luna.stringField(1, "gpt-5.6-luna");
    try luna.emptyField(2);
    try luna.stringField(3, "gpt-5.6-luna");
    try luna.stringField(4, " Luna live ");
    try luna.boolField(7, true);
    var zeta = pb.Writer.init(arena);
    try zeta.stringField(1, "zeta-model");
    var response = pb.Writer.init(arena);
    try response.bytesField(1, zeta.bytes.items);
    try response.bytesField(1, luna.bytes.items);
    try response.bytesField(1, luna.bytes.items);

    var entries = (try parseDiscovered(arena, response.bytes.items)).?;
    defer model_catalog.freeModelCatalog(arena, &entries);
    try std.testing.expectEqual(@as(usize, 2), entries.items.len);
    try std.testing.expectEqualStrings("gpt-5.6-luna", entries.items[0].id);
    try std.testing.expectEqualStrings("zeta-model", entries.items[1].id);
    const entry = entries.items[0];
    try std.testing.expectEqualStrings("Luna live", entry.name.?);
    try std.testing.expect(entry.has_reasoning);
    try std.testing.expect(entry.has_vision);
    try std.testing.expectEqual(@as(u32, 1_000_000), entry.context_window);
    try std.testing.expectEqual(@as(usize, 5), entry.reasoning_efforts.items.len);
}
