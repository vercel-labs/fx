//! One number for the largest message the engine reads from a server: a
//! stdio stdout line (`process.zig` `max_line`) or a Streamable HTTP body
//! (`http.zig` `max_message`). The host's wire sizes its frames and its
//! per-connection queue from it, so a message a server may legally send
//! always fits both.
const std = @import("std");

pub const max_message_bytes: usize = 16 * 1024 * 1024;
