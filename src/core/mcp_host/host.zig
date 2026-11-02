//! fx's side of the MCP engine in one place: the runtime that owns the
//! engine, and the catalog the model sees.

const std = @import("std");
const builtin = @import("builtin");
const mcp_contract = @import("../mcp/mcp_contract.zig");
const tool_dispatch = @import("../tooling/tool_dispatch.zig");
const elicitation = @import("../mcp/elicitation.zig");
const runtime_mod = @import("runtime.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const model = @import("model.zig");

const Allocator = std.mem.Allocator;

pub const Runtime = runtime_mod.Runtime;
pub const Options = runtime_mod.Options;
pub const Catalog = model.Catalog;
pub const Notify = runtime_mod.Notify;
pub const Notice = runtime_mod.Notice;
pub const Status = runtime_mod.Status;
pub const signalServersForExit = runtime_mod.signalServersForExit;
pub const waitRetired = runtime_mod.waitRetired;
pub const menu = @import("menu.zig");

pub const Extras = struct {
    /// The questions fx's UI on this surface can ask.
    questions: elicitation.Capabilities = .{},
    /// Gets sign-in notices.
    notify: ?runtime_mod.Notify = null,
    /// See `runtime.Options.slash_commands`.
    slash_commands: bool = false,
    /// The host the config changed under: it takes the new config in place
    /// (`Host.reload`) and is returned, unless no server is left.
    reuse: ?*Host = null,
};

/// Loads the host for a workspace, or null when there is no home folder or no
/// server is configured.
pub const LoadFn = *const fn (
    gpa: Allocator,
    workspace_root: []const u8,
    builtins: tool_dispatch.Registry,
    extras: Extras,
) anyerror!?*Host;

pub const Host = struct {
    gpa: Allocator,
    runtime: Runtime,
    catalog: Catalog,
    /// What loading the config skipped and why, one sentence each; owned by
    /// `gpa`. A reload replaces them under `notes_mutex`, which a thread other
    /// than the reloading one holds while it reads them.
    notes: []const []const u8 = &.{},
    notes_mutex: std.Io.Mutex = .init,
    /// For an owner that replaces the host while others still use it: the
    /// uses still running, and whether it was replaced. The owner guards both.
    leases: usize = 0,
    retired: bool = false,

    /// Starts the runtime with `configs`; no server starts until something
    /// needs it. `gpa` must be thread-safe.
    pub fn create(
        gpa: Allocator,
        io: std.Io,
        configs: []const mcp_contract.McpServerConfig,
        inherited: *const std.process.Environ.Map,
        options: Options,
        builtins: tool_dispatch.Registry,
    ) !*Host {
        const h = try gpa.create(Host);
        errdefer gpa.destroy(h);
        h.gpa = gpa;
        h.notes = &.{};
        h.notes_mutex = .init;
        h.leases = 0;
        h.retired = false;
        try h.runtime.start(gpa, io, configs, inherited, options);
        errdefer h.runtime.deinit();
        try h.catalog.init(gpa, io, &h.runtime, builtins);
        return h;
    }

    /// Stops every server and frees the host.
    pub fn destroy(h: *Host) void {
        const gpa = h.gpa;
        freeNotes(gpa, h.notes);
        h.catalog.deinit();
        h.runtime.deinit();
        gpa.destroy(h);
    }

    /// Takes a changed config in place: only a server whose config changed
    /// restarts (`Runtime.reload`), and the catalog follows. `notes` replace
    /// the host's, which it then owns, also on failure. Called by the one
    /// thread that reloads; others may use the host meanwhile.
    pub fn reload(
        h: *Host,
        configs: []const mcp_contract.McpServerConfig,
        inherited: *const std.process.Environ.Map,
        notes: []const []const u8,
    ) !void {
        h.notes_mutex.lockUncancelable(h.runtime.io);
        const old = h.notes;
        h.notes = notes;
        h.notes_mutex.unlock(h.runtime.io);
        freeNotes(h.gpa, old);
        try h.catalog.reload(try h.runtime.reload(configs, inherited));
    }

    fn freeNotes(gpa: Allocator, notes: []const []const u8) void {
        for (notes) |note| gpa.free(note);
        gpa.free(notes);
    }

    /// Replaced: until this host is gone, no other host starts a server, so
    /// none runs twice. Calls that began on it still finish here.
    pub fn retire(h: *Host) void {
        h.runtime.retire();
    }

    /// Retires the host and destroys it on a thread of its own, so whoever
    /// lets it go never waits for its servers to stop. Nothing else
    /// may use `h` after this.
    pub fn stop(h: *Host) void {
        h.retire();
        // Without threads, as in the wasm builds, it is destroyed in place.
        if (comptime builtin.single_threaded) return h.destroy();
        const thread = std.Thread.spawn(.{}, destroy, .{h}) catch |err| {
            debug_trace.logf("mcp", "MCP host stopped in place err={s}", .{@errorName(err)});
            return h.destroy();
        };
        thread.detach();
    }
};

test {
    _ = model;
    _ = runtime_mod;
}
