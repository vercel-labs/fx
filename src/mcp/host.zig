//! What the host gives the engine: fx, or the dev lab. Everything else
//! the host does it does through the engine's API and events: showing input
//! forms, opening sign-in URLs, and rendering status.

const std = @import("std");

/// Loads trusted roots into an HTTP server's client before a request to
/// `uri`, in place of std's own scan. A request whose roots fail to load
/// can't go out.
pub const Trust = *const fn (client: *std.http.Client, uri: std.Uri) error{ CertificateBundleLoadFailure, Canceled }!void;

pub const Host = struct {
    context: *anyopaque,
    /// Whether this exact tool call may run. Asked once per call,
    /// before anything about it is sent or any server starts for it. The
    /// tool's description and annotations are the server's, untrusted.
    allow: *const fn (context: *anyopaque, server: []const u8, tool: []const u8, arguments: ?[]const u8) bool,
    /// A line a server's process wrote to stderr, for logs only.
    /// Called from that server's reader task, so it must be safe
    /// to call from any thread, and it must not block for long.
    log: *const fn (context: *anyopaque, server: []const u8, line: []const u8) void,
    /// Trusted roots for HTTP servers; null leaves them to std's own scan.
    trust: ?Trust = null,
};
