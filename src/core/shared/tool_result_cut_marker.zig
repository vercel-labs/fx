//! How the marker that ends a cut tool result is written. `prepareModelOutputWithTruncation` in
//! `src/core/tooling/tool_result_limits.zig` writes it, and `src/core/mcp/tool_result.zig` finds it by its start and
//! end words, so a cut text's cause line never reads the marker. The words sit here, in a shared file that imports
//! nothing, so the writer and the reader use one copy.

/// What the marker starts with. The tool's name, `: original <n> bytes; cap is <n>` and `cut_marker_end` follow.
pub const cut_marker_start = "\n... [tool result truncated for ";

/// What the marker ends with.
pub const cut_marker_end = " bytes]\n";

/// The whole marker as a format string: the tool's name, its original size and the cap, in that order.
pub const cut_marker_format = cut_marker_start ++ "{s}: original {d} bytes; cap is {d}" ++ cut_marker_end;
