//! The bridge between a program in the bash tool and fx. Outside code imports
//! only this file.
//!
//! `edit_blocks` reads the SEARCH/REPLACE blocks that a program sends to
//! `edit PATH` on stdin.

pub const edit_blocks = @import("edit_blocks.zig");

test {
    _ = edit_blocks;
}
