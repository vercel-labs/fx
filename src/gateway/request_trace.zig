//! Opt-in structural Gateway diagnostics. Request contents are never logged.
//! FX_TRACE_GATEWAY_BODIES=1 additionally exports sensitive response payloads.
const std = @import("std");
const debug_trace = @import("../core/shared/debug_trace.zig");
const io_mod = @import("../core/shared/io.zig");

const max_roles = 512;
const max_error_scan_bytes = 64 * 1024;
const max_body_bytes = 256 * 1024;
const body_chunk_bytes = 2048;
var next_request_id: std.atomic.Value(u64) = .init(1);

pub const Attempt = struct {
    id: u64 = 0,
    ctx: debug_trace.TraceContext = .{},
    status: u16 = 0,
    outcome: enum { interrupted, http_error, completed, transport_error } = .interrupted,
    error_category: ErrorCategory = .none,
    error_bytes: usize = 0,
    error_name: []const u8 = "none",
    finish_reason: []const u8 = "none",
    capture_body: bool = false,
    body_bytes_seen: usize = 0,
    body_bytes_logged: usize = 0,
    body_event_count: usize = 0,

    pub fn start(alloc: std.mem.Allocator, ctx: debug_trace.TraceContext, model: []const u8, payload: []const u8, attempt: usize) Attempt {
        if (!debug_trace.isScopeEnabled("gateway")) return .{};
        const self: Attempt = .{
            .id = next_request_id.fetchAdd(1, .monotonic),
            .ctx = ctx,
            .capture_body = std.mem.eql(u8, io_mod.getenv("FX_TRACE_GATEWAY_BODIES") orelse "", "1"),
        };
        const summary = requestSummary(alloc, payload) catch |err| {
            debug_trace.eventf("gateway", "request_shape", ctx, "request_id={d} attempt={d} model={s} summary_error={s}", .{ self.id, attempt, safeToken(model), @errorName(err) });
            return self;
        };
        defer alloc.free(summary);
        debug_trace.eventf("gateway", "request_shape", ctx, "request_id={d} attempt={d} model={s} {s}", .{ self.id, attempt, safeToken(model), summary });
        return self;
    }

    pub fn headers(self: *Attempt, head: std.http.Client.Response.Head) void {
        if (self.id == 0) return;
        self.status = @intFromEnum(head.status);
        debug_trace.eventf("gateway", "response_headers", self.ctx, "request_id={d} status={d}", .{ self.id, self.status });
        // Only these response correlation headers are exported. They are not
        // proof of which downstream model backend the Gateway selected.
        const names = [_][]const u8{ "x-request-id", "request-id", "x-vercel-id" };
        for (names) |name| {
            var iterator = head.iterateHeaders();
            while (iterator.next()) |header| {
                if (!std.ascii.eqlIgnoreCase(header.name, name)) continue;
                debug_trace.eventf("gateway", "response_id", self.ctx, "request_id={d} header={s} value={s}", .{ self.id, name, safeToken(header.value) });
                break;
            }
        }
    }

    pub fn httpError(self: *Attempt, data: []const u8) void {
        if (self.id == 0) return;
        self.outcome = .http_error;
        self.error_bytes = data.len;
        self.error_category = classifyError(data);
        self.body(.http_error, data);
    }

    /// Logs HTTP error bodies or SSE data payloads, not HTTP/SSE framing.
    /// Text is deliberately unredacted; the shared logger escapes control bytes.
    pub fn body(self: *Attempt, kind: enum { http_error, sse }, data: []const u8) void {
        if (self.id == 0 or !self.capture_body) return;
        const offset = self.body_bytes_seen;
        self.body_bytes_seen +|= data.len;
        self.body_event_count += 1;
        const kept = @min(data.len, max_body_bytes - self.body_bytes_logged);
        var cursor: usize = 0;
        while (cursor < kept) {
            const end_index = @min(cursor + body_chunk_bytes, kept);
            debug_trace.eventf("gateway", "response_body", self.ctx, "request_id={d} kind={s} body_event={d} offset={d} event_offset={d} event_bytes={d} sensitive=true data={s}", .{
                self.id, @tagName(kind), self.body_event_count, offset + cursor, cursor, data.len, data[cursor..end_index],
            });
            cursor = end_index;
        }
        self.body_bytes_logged += kept;
    }

    pub fn complete(self: *Attempt, finish_reason: []const u8) void {
        if (self.id == 0) return;
        self.outcome = .completed;
        self.finish_reason = finish_reason;
    }

    pub fn fail(self: *Attempt, err: anyerror) void {
        if (self.id == 0) return;
        self.outcome = .transport_error;
        self.error_name = @errorName(err);
    }

    pub fn end(self: Attempt) void {
        if (self.id == 0) return;
        debug_trace.eventf("gateway", "request_outcome", self.ctx, "request_id={d} status={d} outcome={s} error_category={s} error_bytes={d} error_scan_truncated={s} err={s} finish_reason={s} sensitive_body_capture={s} body_bytes_seen={d} body_bytes_logged={d} body_truncated={s}", .{
            self.id,                                                          self.status,                                                            @tagName(self.outcome),        @tagName(self.error_category),              self.error_bytes,
            if (self.error_bytes > max_error_scan_bytes) "true" else "false", self.error_name,                                                        safeToken(self.finish_reason), if (self.capture_body) "true" else "false", self.body_bytes_seen,
            self.body_bytes_logged,                                           if (self.body_bytes_seen > self.body_bytes_logged) "true" else "false",
        });
    }
};

const ErrorCategory = enum { none, system_message_not_first, template_rendering_failed, other };

fn classifyError(body: []const u8) ErrorCategory {
    if (body.len == 0) return .none;
    const scan = body[0..@min(body.len, max_error_scan_bytes)];
    if (std.mem.find(u8, scan, "System message must be at the beginning") != null) return .system_message_not_first;
    if (std.mem.find(u8, scan, "jinja template rendering failed") != null) return .template_rendering_failed;
    return .other;
}

fn safeToken(value: []const u8) []const u8 {
    if (value.len == 0) return "none";
    if (value.len > 128) return "omitted";
    for (value) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and std.mem.findScalar(u8, "-_.:/", byte) == null) return "omitted";
    }
    return value;
}

fn roleName(entry: std.json.Value) []const u8 {
    if (entry != .object) return "invalid";
    const role = entry.object.get("role") orelse return "invalid";
    if (role != .string) return "invalid";
    for ([_][]const u8{ "system", "user", "assistant", "tool" }) |known| {
        if (std.mem.eql(u8, role.string, known)) return known;
    }
    return "invalid";
}

// Owned by the caller. Only structural fields from the actual serialized body
// are used; invalid values never enter the diagnostic as arbitrary text.
fn requestSummary(alloc: std.mem.Allocator, payload: []const u8) ![]u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, payload, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidRequestObject;
    const prompt = parsed.value.object.get("prompt") orelse return error.MissingPrompt;
    if (prompt != .array) return error.InvalidPrompt;
    const messages = prompt.array.items;
    var system_count: usize = 0;
    var leading_system_count: usize = 0;
    var first_nonleading_system: ?usize = null;
    var invalid_roles: usize = 0;
    for (messages, 0..) |message, i| {
        const role = roleName(message);
        if (std.mem.eql(u8, role, "invalid")) invalid_roles += 1;
        if (std.mem.eql(u8, role, "system")) {
            system_count += 1;
            if (i == leading_system_count) {
                leading_system_count += 1;
            } else if (first_nonleading_system == null) {
                first_nonleading_system = i;
            }
        }
    }
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.print("request_bytes={d} prompt_count={d} system_count={d} leading_system_count={d} invalid_roles={d} first_nonleading_system=", .{ payload.len, messages.len, system_count, leading_system_count, invalid_roles });
    if (first_nonleading_system) |index| try out.writer.print("{d}", .{index}) else try out.writer.writeAll("none");
    try out.writer.writeAll(" roles=");
    const shown = @min(messages.len, max_roles);
    for (messages[0..shown], 0..) |message, i| {
        if (i > 0) try out.writer.writeByte(',');
        try out.writer.writeAll(roleName(message));
    }
    try out.writer.print(" roles_omitted={d}", .{messages.len - shown});
    return out.toOwnedSlice();
}

test "gateway request trace reports role order without contents" {
    const payload =
        \\{"prompt":[{"role":"system","content":"SECRET_RULES"},{"role":"system","content":"SECRET_CONTEXT"},{"role":"user","content":"SECRET_PROMPT"},{"role":"assistant","content":[]},{"role":"tool","content":"SECRET_RESULT"},{"role":"system","content":"SECRET_LATE"}],"tools":[{"name":"SECRET_TOOL"}]}
    ;
    const summary = try requestSummary(std.testing.allocator, payload);
    defer std.testing.allocator.free(summary);
    try std.testing.expect(std.mem.find(u8, summary, "system_count=3 leading_system_count=2") != null);
    try std.testing.expect(std.mem.find(u8, summary, "first_nonleading_system=5 roles=system,system,user,assistant,tool,system roles_omitted=0") != null);
    try std.testing.expect(std.mem.find(u8, summary, "SECRET") == null);
}

test "gateway request trace bounds role output but counts the whole prompt" {
    var payload: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer payload.deinit();
    try payload.writer.writeAll("{\"prompt\":[");
    for (0..max_roles) |i| {
        if (i > 0) try payload.writer.writeByte(',');
        try payload.writer.writeAll("{\"role\":\"user\"}");
    }
    try payload.writer.writeAll(",{\"role\":\"system\"}]}");
    const summary = try requestSummary(std.testing.allocator, payload.written());
    defer std.testing.allocator.free(summary);
    try std.testing.expect(std.mem.find(u8, summary, "prompt_count=513 system_count=1 leading_system_count=0") != null);
    try std.testing.expect(std.mem.find(u8, summary, "first_nonleading_system=512") != null);
    try std.testing.expect(std.mem.endsWith(u8, summary, "roles_omitted=1"));
    try std.testing.expect(summary.len < 4096);
}

test "gateway request trace rejects malformed structures and never echoes unknown roles" {
    try std.testing.expectError(error.InvalidRequestObject, requestSummary(std.testing.allocator, "[]"));
    try std.testing.expectError(error.MissingPrompt, requestSummary(std.testing.allocator, "{}"));
    try std.testing.expectError(error.InvalidPrompt, requestSummary(std.testing.allocator, "{\"prompt\":true}"));
    const summary = try requestSummary(std.testing.allocator, "{\"prompt\":[null,{}, {\"role\":\"SECRET_ROLE\"}]}");
    defer std.testing.allocator.free(summary);
    try std.testing.expect(std.mem.find(u8, summary, "invalid_roles=3") != null);
    try std.testing.expect(std.mem.find(u8, summary, "roles=invalid,invalid,invalid") != null);
    try std.testing.expect(std.mem.find(u8, summary, "SECRET") == null);
}

test "gateway request trace classifies errors without exporting provider text" {
    try std.testing.expectEqual(ErrorCategory.system_message_not_first, classifyError("{\"error\":{\"message\":\"jinja template rendering failed. System message must be at the beginning. SECRET_PROMPT\"}}"));
    try std.testing.expectEqual(ErrorCategory.template_rendering_failed, classifyError("jinja template rendering failed. SECRET_REASON"));
    try std.testing.expectEqual(ErrorCategory.other, classifyError("SECRET_UNRECOGNIZED_ERROR"));
    try std.testing.expectEqual(ErrorCategory.none, classifyError(""));
    var body: [max_error_scan_bytes + 64]u8 = @splat('x');
    const marker = "System message must be at the beginning";
    @memcpy(body[max_error_scan_bytes..][0..marker.len], marker);
    try std.testing.expectEqual(ErrorCategory.other, classifyError(&body));
}

test "gateway request trace response tokens are bounded and terminal safe" {
    try std.testing.expectEqualStrings("sfo1::req-123", safeToken("sfo1::req-123"));
    try std.testing.expectEqualStrings("omitted", safeToken("Bearer SECRET"));
    try std.testing.expectEqualStrings("omitted", safeToken("request\nforged=event"));
    try std.testing.expectEqualStrings("omitted", safeToken("\x1b[31mSECRET"));
    try std.testing.expectEqualStrings("omitted", safeToken("x" ** 129));
}

test "gateway request trace disabled scope skips parsing and body capture" {
    debug_trace.resetForTest();
    defer debug_trace.resetForTest();
    var trace = Attempt.start(std.testing.failing_allocator, .{}, "model", "not json", 1);
    try std.testing.expectEqual(@as(u64, 0), trace.id);
    trace.capture_body = true;
    trace.body(.http_error, "PRIVATE");
    try std.testing.expectEqual(@as(usize, 0), trace.body_bytes_seen);
    trace.end();
}

test "gateway request trace header allowlist and nonfatal allocation failure" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const path = try std.fs.path.join(alloc, &.{ root, "trace.log" });
    defer alloc.free(path);
    debug_trace.resetForTest();
    defer debug_trace.resetForTest();
    try debug_trace.configureForTestWithScopes(alloc, path, "gateway");
    var trace = Attempt.start(std.testing.failing_allocator, .{}, "test/model", "{}", 1);
    try std.testing.expect(trace.id != 0);
    const head = try std.http.Client.Response.Head.parse(
        "HTTP/1.1 400 Bad Request\r\n" ++
            "X-Request-ID: req-first\r\n" ++
            "x-request-id: req-duplicate\r\n" ++
            "request-id: provider-request\r\n" ++
            "x-vercel-id: edge-request\r\n" ++
            "authorization: Bearer SECRET_AUTH\r\n" ++
            "set-cookie: SECRET_COOKIE\r\n\r\n",
    );
    trace.headers(head);
    trace.httpError("System message must be at the beginning. SECRET_BODY");
    trace.end();
    var file = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{});
    defer file.close(io_mod.getIo());
    const output = try io_mod.readFileToEnd(alloc, &file, 8192);
    defer alloc.free(output);
    try std.testing.expect(std.mem.find(u8, output, "summary_error=OutOfMemory") != null);
    try std.testing.expect(std.mem.find(u8, output, "header=x-request-id value=req-first") != null);
    try std.testing.expect(std.mem.find(u8, output, "req-duplicate") == null);
    try std.testing.expect(std.mem.find(u8, output, "header=request-id value=provider-request") != null);
    try std.testing.expect(std.mem.find(u8, output, "header=x-vercel-id value=edge-request") != null);
    try std.testing.expect(std.mem.find(u8, output, "error_category=system_message_not_first") != null);
    try std.testing.expect(std.mem.find(u8, output, "SECRET") == null);
}
