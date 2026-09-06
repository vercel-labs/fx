const std = @import("std");
const builtin = @import("builtin");
const process_identity = @import("process_identity.zig");

const Allocator = std.mem.Allocator;

pub const ProviderError = Allocator.Error || error{
    Unsupported,
    ProcessIdentityIndeterminate,
    ProcessIdentityMismatch,
    ProcessIdentityUnavailable,
    ProcessIdentityUnsupported,
    ProcessNotFound,
    PermissionDenied,
    Unexpected,
    InvalidPid,
};

pub const Provider = struct {
    context: ?*anyopaque = null,
    capture_token_fn: *const fn (
        ?*anyopaque,
        Allocator,
        []const u8,
    ) ProviderError!process_identity.ProcessInstanceToken,
    match_token_fn: *const fn (
        ?*anyopaque,
        Allocator,
        []const u8,
        process_identity.ProcessInstanceToken,
    ) process_identity.TokenMatch,
    signal_process_fn: *const fn (
        ?*anyopaque,
        Allocator,
        []const u8,
        process_identity.ProcessInstanceToken,
    ) ProviderError!void,

    pub fn captureToken(
        self: Provider,
        alloc: Allocator,
        pid: []const u8,
    ) ProviderError!process_identity.ProcessInstanceToken {
        return self.capture_token_fn(self.context, alloc, pid);
    }

    pub fn matchToken(
        self: Provider,
        alloc: Allocator,
        pid: []const u8,
        expected: process_identity.ProcessInstanceToken,
    ) process_identity.TokenMatch {
        return self.match_token_fn(self.context, alloc, pid, expected);
    }

    pub fn signalProcess(
        self: Provider,
        alloc: Allocator,
        pid: []const u8,
        expected: process_identity.ProcessInstanceToken,
    ) ProviderError!void {
        return self.signal_process_fn(self.context, alloc, pid, expected);
    }
};

fn unsupportedCaptureToken(
    _: ?*anyopaque,
    _: Allocator,
    _: []const u8,
) ProviderError!process_identity.ProcessInstanceToken {
    return error.Unsupported;
}

fn unavailableMatchToken(
    _: ?*anyopaque,
    _: Allocator,
    _: []const u8,
    _: process_identity.ProcessInstanceToken,
) process_identity.TokenMatch {
    return .unavailable;
}

fn unsupportedSignalProcess(
    _: ?*anyopaque,
    _: Allocator,
    _: []const u8,
    _: process_identity.ProcessInstanceToken,
) ProviderError!void {
    return error.Unsupported;
}

fn captureTokenForTest(
    _: ?*anyopaque,
    alloc: Allocator,
    pid: []const u8,
) ProviderError!process_identity.ProcessInstanceToken {
    return process_identity.captureProcessInstanceToken(alloc, pid) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidPid => error.InvalidPid,
        error.ProcessNotFound => error.ProcessNotFound,
        error.ProcessIdentityUnavailable => error.ProcessIdentityUnavailable,
        else => error.ProcessIdentityUnsupported,
    };
}

fn matchTokenForTest(
    _: ?*anyopaque,
    alloc: Allocator,
    pid: []const u8,
    expected: process_identity.ProcessInstanceToken,
) process_identity.TokenMatch {
    return process_identity.matchProcessInstanceToken(alloc, pid, expected);
}

pub const unavailable_provider = Provider{
    .capture_token_fn = unsupportedCaptureToken,
    .match_token_fn = unavailableMatchToken,
    .signal_process_fn = unsupportedSignalProcess,
};

pub const process_identity_test_provider = if (builtin.is_test)
    Provider{
        .capture_token_fn = captureTokenForTest,
        .match_token_fn = matchTokenForTest,
        .signal_process_fn = unsupportedSignalProcess,
    }
else
    unavailable_provider;

test "unavailable provider does not consult process identity test hooks" {
    const Stub = struct {
        var calls: usize = 0;

        fn capture(
            _: Allocator,
            _: []const u8,
        ) anyerror!process_identity.ProcessInstanceToken {
            calls += 1;
            return error.ProcessNotFound;
        }
    };
    Stub.calls = 0;
    process_identity.process_token_capture_for_test = Stub.capture;
    defer process_identity.process_token_capture_for_test = null;

    try std.testing.expectError(
        error.Unsupported,
        unavailable_provider.captureToken(std.testing.allocator, "123"),
    );
    try std.testing.expectEqual(@as(usize, 0), Stub.calls);
}
