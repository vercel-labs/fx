//! How the marker that ends a cut tool result starts and ends. Two places write it, `prepareModelOutputWithTruncation`
//! in `src/core/tooling/tool_result_limits.zig` and `cappedInlineOutput` in `src/core/session/result_store.zig`, and
//! `src/core/mcp/tool_result.zig` finds it by these words, so a cut text's cause line never reads the marker. They sit
//! here, in shared basics, because the session code may not import the tooling code.

/// What the marker starts with. The tool's name, `: original <n> bytes; cap is <n>` and `cut_marker_end` follow.
pub const cut_marker_start = "\n... [tool result truncated for ";

/// What the marker ends with.
pub const cut_marker_end = " bytes]\n";
