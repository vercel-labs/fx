const std = @import("std");
const contracts = @import("contracts.zig");

const Allocator = std.mem.Allocator;

pub const header_len: usize = 28;
const magic = "FXTH";

pub const DecodeError = error{
    TruncatedFrame,
    InvalidFrameMagic,
    InvalidFrameKind,
    InvalidFrameSubject,
    InvalidHostFrame,
    HostFrameTooLarge,
    InvalidPayload,
} || contracts.HostMessageValidationError || Allocator.Error;

pub const Header = struct {
    envelope: contracts.MessageEnvelope,

    pub fn decode(bytes: []const u8) DecodeError!Header {
        if (bytes.len < header_len) return error.TruncatedFrame;
        if (!std.mem.eql(u8, bytes[0..magic.len], magic)) {
            return error.InvalidFrameMagic;
        }

        const revision = std.mem.readInt(u16, bytes[4..6], .little);
        const kind = try decodeKind(bytes[6], bytes[7]);
        const required_capabilities = std.mem.readInt(u64, bytes[8..16], .little);
        const correlation_value = std.mem.readInt(u64, bytes[16..24], .little);
        const payload_len = std.mem.readInt(u32, bytes[24..28], .little);
        const correlation_id: ?contracts.CorrelationId =
            if (correlation_value == 0) null else .{ .value = correlation_value };
        const envelope = contracts.MessageEnvelope{
            .revision = revision,
            .kind = kind,
            .required_capabilities = required_capabilities,
            .correlation_id = correlation_id,
            .payload_len = payload_len,
        };
        try envelope.validate(payload_len);
        return .{ .envelope = envelope };
    }

    pub fn encode(self: Header) DecodeError![header_len]u8 {
        try self.envelope.validate(self.envelope.payload_len);
        const wire_kind = encodeKind(self.envelope.kind);
        var bytes: [header_len]u8 = @splat(0);
        @memcpy(bytes[0..magic.len], magic);
        std.mem.writeInt(u16, bytes[4..6], self.envelope.revision, .little);
        bytes[6] = wire_kind.kind;
        bytes[7] = wire_kind.subject;
        std.mem.writeInt(
            u64,
            bytes[8..16],
            self.envelope.required_capabilities,
            .little,
        );
        std.mem.writeInt(
            u64,
            bytes[16..24],
            if (self.envelope.correlation_id) |id| id.value else 0,
            .little,
        );
        std.mem.writeInt(u32, bytes[24..28], self.envelope.payload_len, .little);
        return bytes;
    }
};

pub const EncodedFrame = struct {
    bytes: []u8,

    pub fn deinit(self: *EncodedFrame, alloc: Allocator) void {
        alloc.free(self.bytes);
        self.* = undefined;
    }
};

pub const DecodedFrame = struct {
    envelope: contracts.MessageEnvelope,
    parsed: std.json.Parsed(contracts.MessagePayload),

    pub fn message(self: *const DecodedFrame) contracts.HostMessage {
        return .{
            .envelope = self.envelope,
            .payload = self.parsed.value,
        };
    }

    pub fn deinit(self: *DecodedFrame) void {
        self.parsed.deinit();
        self.* = undefined;
    }
};

pub fn encodeFrame(
    alloc: Allocator,
    revision: u16,
    required_capabilities: u64,
    correlation_id: ?contracts.CorrelationId,
    payload: contracts.MessagePayload,
) DecodeError!EncodedFrame {
    var payload_out: std.Io.Writer.Allocating = .init(alloc);
    defer payload_out.deinit();
    try stringifyPayload(revision, payload, &payload_out.writer);
    const payload_bytes = payload_out.written();
    if (payload_bytes.len > contracts.max_host_frame_bytes) {
        return error.HostFrameTooLarge;
    }
    const payload_len = std.math.cast(u32, payload_bytes.len) orelse
        return error.HostFrameTooLarge;
    const kind = kindForPayload(payload);
    const envelope = contracts.MessageEnvelope{
        .revision = revision,
        .kind = kind,
        .required_capabilities = required_capabilities,
        .correlation_id = correlation_id,
        .payload_len = payload_len,
    };
    try (contracts.HostMessage{
        .envelope = envelope,
        .payload = payload,
    }).validate(payload_bytes.len);

    const total_len = std.math.add(usize, header_len, payload_bytes.len) catch
        return error.HostFrameTooLarge;
    var bytes = try alloc.alloc(u8, total_len);
    errdefer alloc.free(bytes);
    const header = try (Header{ .envelope = envelope }).encode();
    @memcpy(bytes[0..header_len], &header);
    @memcpy(bytes[header_len..], payload_bytes);
    return .{ .bytes = bytes };
}

fn stringifyPayload(
    revision: u16,
    payload: contracts.MessagePayload,
    writer: *std.Io.Writer,
) DecodeError!void {
    if (revision == contracts.previous_protocol_revision) {
        const projected = projectPayloadV4(payload);
        std.json.Stringify.value(projected, .{}, writer) catch
            return error.OutOfMemory;
        return;
    }
    std.json.Stringify.value(payload, .{}, writer) catch
        return error.OutOfMemory;
}

fn projectPayloadV4(payload: contracts.MessagePayload) contracts.MessagePayload {
    return switch (payload) {
        .hello => |hello| .{ .hello = hello },
        .request => |request| .{ .request = request },
        .response => |response| .{ .response = projectResultV4(response) },
        .cancel => .cancel,
    };
}

fn projectResultV4(result: contracts.Result) contracts.Result {
    return result;
}

pub fn projectResultForCapabilities(
    result: contracts.Result,
    capabilities: u64,
) contracts.Result {
    const failure = switch (result) {
        .success => return result,
        .failure => |value| value,
    };
    if (failure.code != .path_outside_workspace or
        capabilities & contracts.protocol_capability_path_outside_workspace_error != 0)
    {
        return result;
    }
    var compatible = failure;
    compatible.code = .invalid_request;
    return .{ .failure = compatible };
}

inline fn failDecodedFrame(err: anytype) @TypeOf(err)!DecodedFrame {
    return @errorCast(failDecodedFrameDynamic(err));
}

noinline fn failDecodedFrameDynamic(err: anyerror) anyerror!DecodedFrame {
    return err;
}

test "decoded frame failures preserve exact error types and identities" {
    const truncated = failDecodedFrame(error.TruncatedFrame);
    try std.testing.expect(
        @TypeOf(truncated) == error{TruncatedFrame}!DecodedFrame,
    );
    try std.testing.expectError(error.TruncatedFrame, truncated);
    try std.testing.expectError(error.OutOfMemory, failDecodedFrame(error.OutOfMemory));
}

pub fn decodeFrame(alloc: Allocator, bytes: []const u8) DecodeError!DecodedFrame {
    const header = try Header.decode(bytes);
    const payload_len: usize = header.envelope.payload_len;
    const expected_len = std.math.add(usize, header_len, payload_len) catch
        return failDecodedFrame(error.HostFrameTooLarge);
    if (bytes.len < expected_len) return failDecodedFrame(error.TruncatedFrame);
    if (bytes.len != expected_len) return failDecodedFrame(error.InvalidHostFrame);

    var parsed = std.json.parseFromSlice(
        contracts.MessagePayload,
        alloc,
        bytes[header_len..],
        .{ .allocate = .alloc_always },
    ) catch |err| switch (err) {
        error.OutOfMemory => return failDecodedFrame(error.OutOfMemory),
        else => return failDecodedFrame(error.InvalidPayload),
    };
    errdefer parsed.deinit();
    try (contracts.HostMessage{
        .envelope = header.envelope,
        .payload = parsed.value,
    }).validate(payload_len);
    return .{
        .envelope = header.envelope,
        .parsed = parsed,
    };
}

pub fn readFrame(
    alloc: Allocator,
    reader: *std.Io.Reader,
) (DecodeError || std.Io.Reader.Error)!DecodedFrame {
    var header_bytes: [header_len]u8 = undefined;
    reader.readSliceAll(&header_bytes) catch |err| switch (err) {
        error.EndOfStream => return failDecodedFrame(error.TruncatedFrame),
        else => return err,
    };
    const header = try Header.decode(&header_bytes);
    const payload_len: usize = header.envelope.payload_len;
    const total_len = std.math.add(usize, header_len, payload_len) catch
        return failDecodedFrame(error.HostFrameTooLarge);
    var bytes = try alloc.alloc(u8, total_len);
    defer alloc.free(bytes);
    @memcpy(bytes[0..header_len], &header_bytes);
    reader.readSliceAll(bytes[header_len..]) catch |err| switch (err) {
        error.EndOfStream => return failDecodedFrame(error.TruncatedFrame),
        else => return err,
    };
    return decodeFrame(alloc, bytes);
}

pub fn writeFrame(
    writer: *std.Io.Writer,
    frame: EncodedFrame,
) std.Io.Writer.Error!void {
    try writer.writeAll(frame.bytes);
    try writer.flush();
}

fn kindForPayload(payload: contracts.MessagePayload) contracts.MessageKind {
    return switch (payload) {
        .hello => .hello,
        .request => |request| .{ .request = request.action() },
        .response => |response| .{ .response = response.action() },
        .cancel => .cancel,
    };
}

const WireKind = struct {
    kind: u8,
    subject: u8,
};

fn encodeKind(kind: contracts.MessageKind) WireKind {
    return switch (kind) {
        .hello => .{ .kind = 0, .subject = 0 },
        .request => |action| .{ .kind = 1, .subject = @intFromEnum(action) },
        .response => |action| .{ .kind = 2, .subject = @intFromEnum(action) },
        .cancel => .{ .kind = 4, .subject = 0 },
    };
}

fn decodeKind(kind: u8, subject: u8) DecodeError!contracts.MessageKind {
    return switch (kind) {
        0 => if (subject == 0) .hello else error.InvalidFrameSubject,
        1 => if (subject <= @intFromEnum(contracts.Action.close))
            .{ .request = @enumFromInt(subject) }
        else
            error.InvalidFrameSubject,
        2 => if (subject <= @intFromEnum(contracts.Action.close))
            .{ .response = @enumFromInt(subject) }
        else
            error.InvalidFrameSubject,
        3 => error.InvalidFrameKind,
        4 => if (subject == 0) .cancel else error.InvalidFrameSubject,
        else => error.InvalidFrameKind,
    };
}

fn testRequestFrame(alloc: Allocator) !void {
    var encoded = try encodeFrame(
        alloc,
        contracts.current_protocol_revision,
        0,
        .{ .value = 41 },
        .{ .request = .{ .screen = .{ .session_id = "terminal-1" } } },
    );
    defer encoded.deinit(alloc);
    var decoded = try decodeFrame(alloc, encoded.bytes);
    defer decoded.deinit();
    const message = decoded.message();
    try std.testing.expectEqual(@as(u64, 41), message.envelope.correlation_id.?.value);
    try std.testing.expectEqual(contracts.Action.screen, message.payload.request.action());
}

test "host protocol round trips owned correlated frames" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        testRequestFrame,
        .{},
    );
}

test "host protocol reads fragmented frames and preserves cancel framing" {
    var encoded = try encodeFrame(
        std.testing.allocator,
        contracts.current_protocol_revision,
        0,
        .{ .value = 7 },
        .cancel,
    );
    defer encoded.deinit(std.testing.allocator);
    var reader_buffer: [64]u8 = undefined;
    var fragmented: std.testing.Reader = .init(&reader_buffer, &.{
        .{ .buffer = encoded.bytes },
    });
    fragmented.artificial_limit = .limited(1);
    var decoded = try readFrame(
        std.testing.allocator,
        &fragmented.interface,
    );
    defer decoded.deinit();
    try std.testing.expectEqual(contracts.MessageKind.cancel, decoded.message().envelope.kind);
    try std.testing.expectEqual(@as(u8, 4), encoded.bytes[6]);
}

test "host protocol reserves removed event kind" {
    var encoded = try encodeFrame(
        std.testing.allocator,
        contracts.current_protocol_revision,
        0,
        .{ .value = 7 },
        .cancel,
    );
    defer encoded.deinit(std.testing.allocator);
    encoded.bytes[6] = 3;
    try std.testing.expectError(
        error.InvalidFrameKind,
        decodeFrame(std.testing.allocator, encoded.bytes),
    );
}

test "host protocol rejects partial truncated oversized and invalid correlation frames" {
    var encoded = try encodeFrame(
        std.testing.allocator,
        contracts.current_protocol_revision,
        0,
        .{ .value = 9 },
        .{ .request = .{ .screen = .{ .session_id = "terminal-1" } } },
    );
    defer encoded.deinit(std.testing.allocator);

    try std.testing.expectError(
        error.TruncatedFrame,
        decodeFrame(std.testing.allocator, encoded.bytes[0 .. header_len - 1]),
    );
    try std.testing.expectError(
        error.TruncatedFrame,
        decodeFrame(std.testing.allocator, encoded.bytes[0 .. encoded.bytes.len - 1]),
    );

    var oversized = encoded.bytes[0..header_len].*;
    std.mem.writeInt(
        u32,
        oversized[24..28],
        contracts.max_host_frame_bytes + 1,
        .little,
    );
    try std.testing.expectError(
        error.HostFrameTooLarge,
        Header.decode(&oversized),
    );

    var invalid_correlation = encoded.bytes[0..header_len].*;
    @memset(invalid_correlation[16..24], 0);
    try std.testing.expectError(
        error.MissingCorrelationId,
        Header.decode(&invalid_correlation),
    );
}

test "host protocol rejects required capabilities before payload allocation" {
    var encoded = try encodeFrame(
        std.testing.allocator,
        contracts.current_protocol_revision,
        0,
        null,
        .{ .hello = .{
            .range = contracts.local_protocol_range,
            .capabilities = contracts.known_protocol_capabilities,
        } },
    );
    defer encoded.deinit(std.testing.allocator);
    std.mem.writeInt(u64, encoded.bytes[8..16], 1 << 63, .little);
    try std.testing.expectError(
        error.UnknownRequiredCapability,
        decodeFrame(std.testing.allocator, encoded.bytes),
    );
}

test "host protocol preserves opaque terminal output bytes" {
    const output = [_]u8{ 0, 0x80, 0xff };
    var encoded = try encodeFrame(
        std.testing.allocator,
        contracts.current_protocol_revision,
        0,
        .{ .value = 1 },
        .{ .response = .{ .success = .{ .read = .{
            .session = .{
                .session_id = "terminal-opaque",
                .lifecycle = .running,
                .attention = .{},
                .backend = .native,
                .output_cursor = .{ .segment = 1, .offset = output.len },
                .screen_recovery = .{ .unavailable = .missing },
            },
            .output = &output,
            .raw_range = .{
                .start = .{ .segment = 1, .offset = 0 },
                .end = .{ .segment = 1, .offset = output.len },
            },
        } } } },
    );
    defer encoded.deinit(std.testing.allocator);
    var decoded = try decodeFrame(std.testing.allocator, encoded.bytes);
    defer decoded.deinit();
    const result = switch (decoded.message().payload) {
        .response => |response| response,
        else => return error.TestExpectedResponse,
    };
    const read = switch (result) {
        .success => |success| switch (success) {
            .read => |value| value,
            else => return error.TestExpectedRead,
        },
        .failure => return error.TestExpectedSuccess,
    };
    try std.testing.expectEqualSlices(u8, &output, read.output);
}

fn expectProjectedErrorCode(
    capabilities: u64,
    expected: contracts.StructuredErrorCode,
) !void {
    const projected = projectResultForCapabilities(.{ .failure = .{
        .action = .start,
        .code = .path_outside_workspace,
    } }, capabilities);
    var encoded = try encodeFrame(
        std.testing.allocator,
        contracts.current_protocol_revision,
        0,
        .{ .value = 1 },
        .{ .response = projected },
    );
    defer encoded.deinit(std.testing.allocator);
    var decoded = try decodeFrame(std.testing.allocator, encoded.bytes);
    defer decoded.deinit();
    const response = switch (decoded.message().payload) {
        .response => |value| value,
        else => return error.TestExpectedResponse,
    };
    const failure = switch (response) {
        .failure => |value| value,
        .success => return error.TestExpectedFailure,
    };
    try std.testing.expectEqual(expected, failure.code);
}

test "host protocol projects path scope failures by negotiated capability" {
    try expectProjectedErrorCode(
        contracts.protocol_capability_path_outside_workspace_error,
        .path_outside_workspace,
    );
    try expectProjectedErrorCode(0, .invalid_request);

    const generic: contracts.Result = .{ .failure = .{
        .action = .start,
        .code = .invalid_request,
    } };
    try std.testing.expectEqual(
        contracts.StructuredErrorCode.invalid_request,
        projectResultForCapabilities(generic, 0).failure.code,
    );
}

test "host protocol fuzzes the real untrusted frame decoder" {
    const Context = struct {
        fn run(_: @This(), smith: *std.testing.Smith) anyerror!void {
            var bytes: [4096]u8 = undefined;
            const len: usize = @intCast(smith.slice(&bytes));
            var decoded = decodeFrame(
                std.testing.allocator,
                bytes[0..len],
            ) catch return;
            decoded.deinit();
        }
    };
    try std.testing.fuzz(Context{}, Context.run, .{});
}
