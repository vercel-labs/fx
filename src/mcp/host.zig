//! What the host gives the engine: fx, or the dev lab. Everything else
//! the host does it does through the engine's API and events: showing input
//! forms, opening sign-in URLs, and rendering status.

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
};
