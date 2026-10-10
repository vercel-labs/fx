//! fx's side of MCP-v2 in one place: the runtime that owns the
//! engine, and the catalog the model sees. Chosen with FX_MCP_ENGINE=v2
//! until v1 is removed.

const std = @import("std");
const mcp_contract = @import("../mcp/mcp_contract.zig");
const tool_dispatch = @import("../tooling/tool_dispatch.zig");
const elicitation = @import("../mcp/elicitation.zig");
const runtime_mod = @import("runtime.zig");
const model = @import("model.zig");

const Allocator = std.mem.Allocator;

pub const Runtime = runtime_mod.Runtime;
pub const Options = runtime_mod.Options;
pub const Catalog = model.Catalog;
pub const Notify = runtime_mod.Notify;
pub const Notice = runtime_mod.Notice;
pub const selected = runtime_mod.selected;
pub const signalServersForExit = runtime_mod.signalServersForExit;
pub const menu = @import("menu.zig");

pub const Extras = struct {
    /// The questions fx's UI on this surface can ask.
    questions: elicitation.Capabilities = .{},
    /// Gets sign-in notices.
    notify: ?runtime_mod.Notify = null,
};

/// Loads the host for a workspace, or null when MCP-v2 isn't selected or no
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
    /// What loading the config skipped and why, one sentence each; owned by `gpa`.
    notes: []const []const u8 = &.{},
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
        for (h.notes) |note| gpa.free(note);
        gpa.free(h.notes);
        h.catalog.deinit();
        h.runtime.deinit();
        gpa.destroy(h);
    }
};

test {
    _ = model;
    _ = runtime_mod;
}
