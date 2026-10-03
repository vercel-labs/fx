//! sub-engine: terminals for agents.
//!
//! Starts programs on their own PTYs and lets the owner read their output,
//! write to them, resize them and close them, the way a terminal multiplexer
//! does. It knows nothing about the programs it runs.
//!
//! `Terminal` is one terminal driven by its owner. `Pool` holds up to
//! `max_terminals` of them and streams them all from one reader thread to
//! the owner's `Sink`.
//!
//! Each child also gets a report channel, a Unix socket pair, for lines meant
//! for the owner rather than the screen; the owner can reply on it. Its
//! environment names the channel in `report_env_name`; a program finds its
//! end with `inheritedReportFd` and sets FD_CLOEXEC on it before it starts
//! other programs, which otherwise inherit the channel.
//!
//! This file is the module's only public root. The module imports nothing
//! but std, and its owner reaches it only through `@import("sub_engine")`.

const terminal = @import("terminal.zig");
const pool = @import("pool.zig");
const report_core = @import("report_core.zig");
const report_env = @import("report_env.zig");

pub const Terminal = terminal.Terminal;
pub const Options = terminal.Options;
pub const OpenError = terminal.OpenError;
pub const ReadResult = terminal.ReadResult;
pub const CloseReport = terminal.CloseReport;
pub const Exit = terminal.Exit;

pub const Pool = pool.Pool;
pub const Sink = pool.Sink;
pub const Id = pool.Id;
pub const PoolOpenError = pool.OpenError;
pub const WriteError = pool.WriteError;
pub const max_terminals = pool.max_terminals;
pub const max_report_line = pool.max_report_line;
pub const max_reply_line = terminal.max_reply_line;
/// Frames the replies a child reads from its report channel.
pub const Lines = report_core.Lines;

pub const report_env_name = report_env.name;
pub const inheritedReportFd = report_env.inheritedFd;

test {
    _ = terminal;
    _ = pool;
    _ = report_env;
    _ = @import("terminal_core.zig");
    _ = @import("pool_core.zig");
    _ = @import("report_core.zig");
    _ = @import("fd.zig");
}
