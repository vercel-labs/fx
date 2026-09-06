const std = @import("std");

pub const ProcessInstanceToken = struct {
    bytes: [128]u8 = undefined,
    len: u8 = 0,

    pub fn parse(text: []const u8) !ProcessInstanceToken {
        if (text.len == 0 or text.len > 128) {
            return error.InvalidProcessInstanceToken;
        }
        for (text) |byte| {
            if (!std.ascii.isAscii(byte) or std.ascii.isUpper(byte) or
                std.ascii.isWhitespace(byte) or
                std.ascii.isControl(byte))
            {
                return error.InvalidProcessInstanceToken;
            }
        }
        var parts = std.mem.splitScalar(u8, text, ':');
        const platform = parts.next() orelse
            return error.InvalidProcessInstanceToken;
        const boot_id = parts.next() orelse
            return error.InvalidProcessInstanceToken;
        if (!isLowerHex(boot_id, 32)) {
            return error.InvalidProcessInstanceToken;
        }
        if (std.mem.eql(u8, platform, "linux")) {
            const start_ticks = parts.next() orelse
                return error.InvalidProcessInstanceToken;
            if (parts.next() != null or
                !isCanonicalDecimal(start_ticks))
            {
                return error.InvalidProcessInstanceToken;
            }
        } else if (std.mem.eql(u8, platform, "macos")) {
            const start_sec = parts.next() orelse
                return error.InvalidProcessInstanceToken;
            const start_usec = parts.next() orelse
                return error.InvalidProcessInstanceToken;
            if (parts.next() != null or
                !isCanonicalDecimal(start_sec) or
                !isCanonicalDecimal(start_usec))
            {
                return error.InvalidProcessInstanceToken;
            }
        } else {
            return error.InvalidProcessInstanceToken;
        }
        var token = ProcessInstanceToken{};
        @memcpy(token.bytes[0..text.len], text);
        token.len = @intCast(text.len);
        return token;
    }

    pub fn view(self: *const ProcessInstanceToken) []const u8 {
        return self.bytes[0..self.len];
    }

    pub fn eql(self: ProcessInstanceToken, other: ProcessInstanceToken) bool {
        return std.mem.eql(u8, self.view(), other.view());
    }
};

fn isLowerHex(value: []const u8, expected_len: usize) bool {
    if (value.len != expected_len) return false;
    for (value) |byte| {
        if (!std.ascii.isDigit(byte) and
            (byte < 'a' or byte > 'f'))
        {
            return false;
        }
    }
    return true;
}

fn isCanonicalDecimal(value: []const u8) bool {
    if (value.len == 0) return false;
    if (value.len > 1 and value[0] == '0') return false;
    for (value) |byte| {
        if (!std.ascii.isDigit(byte)) return false;
    }
    _ = std.fmt.parseInt(u64, value, 10) catch return false;
    return true;
}

pub const TokenMatch = enum {
    matched,
    missing,
    mismatched,
    unavailable,
};

pub var process_token_match_for_test: ?*const fn ([]const u8, ProcessInstanceToken) TokenMatch = null;
pub var process_token_capture_for_test: ?*const fn (
    std.mem.Allocator,
    []const u8,
) anyerror!ProcessInstanceToken = null;

pub fn captureProcessInstanceToken(
    alloc: std.mem.Allocator,
    pid_text: []const u8,
) !ProcessInstanceToken {
    if (process_token_capture_for_test) |callback| {
        return callback(alloc, pid_text);
    }
    return error.ProcessIdentityUnsupported;
}

pub fn matchProcessInstanceToken(
    alloc: std.mem.Allocator,
    pid_text: []const u8,
    expected: ProcessInstanceToken,
) TokenMatch {
    if (process_token_match_for_test) |callback| {
        return callback(pid_text, expected);
    }
    const actual = captureProcessInstanceToken(alloc, pid_text) catch |err| {
        return switch (err) {
            error.ProcessNotFound => .missing,
            else => .unavailable,
        };
    };
    return if (actual.eql(expected)) .matched else .mismatched;
}

test "process instance tokens are canonical and require exact match" {
    const token = try ProcessInstanceToken.parse(
        "linux:00112233445566778899aabbccddeeff:12345",
    );
    try std.testing.expectEqualStrings(
        "linux:00112233445566778899aabbccddeeff:12345",
        token.view(),
    );
    try std.testing.expect(token.eql(token));
    try std.testing.expectError(
        error.InvalidProcessInstanceToken,
        ProcessInstanceToken.parse(
            "linux:00112233445566778899AABBCCDDEEFF:12345",
        ),
    );
}
