//! A change that waits for its hooks (R2.1, R4.2): a permission-mode change, a setting change, a model change, or the
//! observe-only check after a model change. The change is held here while a `HookGate` (user_hooks.zig) runs the check on
//! its thread, and the tick applies the answer or shows it (`app_commands.collectHookGateFacts`). One check runs at a time,
//! and Esc twice stops it. The App owns this runtime: it starts a change, takes its answer, and cancels and joins the check on
//! shutdown (PR #57 lesson 2).

const std = @import("std");
const runtime_lifecycle = @import("../agent/runtime/lifecycle.zig");
const user_hooks = @import("../agent/runtime/user_hooks.zig");
const types = @import("../shared/types.zig");
const settings_catalog = @import("../config/settings_catalog.zig");
const io_mod = @import("../shared/io.zig");
const testing_listener = @import("../shared/testing_listener.zig");
const hooks_view = @import("../hooks/hooks.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const hooks_host = @import("../hooks_host/hooks_host.zig");
const hook_engine = @import("../../hooks/hooks.zig");

/// A permission mode change: from `old` to `target`. A reset (`/permissions reset`) goes to ask and
/// clears the session grants. `typed` is whether a person typed `/permissions`: that command prints a
/// notice when its change applies, and Shift+Tab prints none.
pub const PermissionModeChange = struct {
    old: types.PermissionMode,
    target: types.PermissionMode,
    reset: bool,
    typed: bool,
};

/// How a setting's apply step reports itself: the feedback the synchronous path gave. `saved`, `named`, and `none`
/// are the effort's reports; `announce` and `silent` are the statusline's.
pub const SettingFeedback = enum { none, announce, silent, saved, named };

/// The model a picker pick chose, with the speed it chose. It waits behind the effort's check: once the effort is
/// allowed, the model changes with it (R2.1).
pub const PickedModel = struct {
    model: []const u8,
    fast_mode: bool,
    ultrafast_mode: bool,
};

/// A setting change: which setting, the hook fields it presents (`source`, `old_value`, `new_value`, and the key, which
/// is the setting's tag name), and the text its apply step reads (`value`). `effort` is set for the effort setting and
/// for a picker pick's speed step, which carries the pick's effort on to the model. `picked` is set for a model picker
/// pick. The strings are borrowed when a change starts; the pending change owns copies.
pub const SettingChange = struct {
    setting: settings_catalog.SettingId,
    source: []const u8,
    old_value: []const u8,
    new_value: []const u8,
    value: []const u8,
    effort: ?types.ReasoningEffort = null,
    feedback: SettingFeedback = .none,
    picked: ?PickedModel = null,
};

/// The effort and speed the model picker chose. They apply after the model changes.
pub const PickerChoice = struct {
    effort: types.ReasoningEffort,
    fast_mode: bool,
    ultrafast_mode: bool,
};

/// A model change from `from` to `to`. `announce` is whether a typed `/model` prints its announcement when the change
/// applies. `picker` holds the effort and speed the model picker chose; it is null for a typed change. The strings are
/// borrowed when a change starts, and the pending change owns its own copies.
pub const ModelChange = struct {
    from: []const u8,
    to: []const u8,
    announce: bool,
    picker: ?PickerChoice,
};

/// A model change that already applied, for its PostModelSwitch hooks. The check is observe-only: nothing applies when it ends.
pub const ModelSwitch = struct {
    from: []const u8,
    to: []const u8,
};

/// What waits for its hooks. A permission-mode, setting, or model change waits for its refusal. A model switch only observes.
pub const Change = union(enum) {
    permission_mode: PermissionModeChange,
    setting: SettingChange,
    model: ModelChange,
    model_switched: ModelSwitch,

    /// A copy of this change whose strings `alloc` owns. The pending change dupes into its own arena.
    fn dupe(self: Change, alloc: std.mem.Allocator) !Change {
        return switch (self) {
            .permission_mode => |mode| .{ .permission_mode = mode },
            .setting => |setting| .{ .setting = try dupeSetting(alloc, setting) },
            .model => |change| .{ .model = .{
                .from = try alloc.dupe(u8, change.from),
                .to = try alloc.dupe(u8, change.to),
                .announce = change.announce,
                .picker = change.picker,
            } },
            .model_switched => |switched| .{ .model_switched = .{
                .from = try alloc.dupe(u8, switched.from),
                .to = try alloc.dupe(u8, switched.to),
            } },
        };
    }
};

fn dupeSetting(alloc: std.mem.Allocator, setting: SettingChange) !SettingChange {
    var copy = setting;
    copy.source = try alloc.dupe(u8, setting.source);
    copy.old_value = try alloc.dupe(u8, setting.old_value);
    copy.new_value = try alloc.dupe(u8, setting.new_value);
    copy.value = try alloc.dupe(u8, setting.value);
    if (setting.picked) |picked| {
        copy.picked = .{
            .model = try alloc.dupe(u8, picked.model),
            .fast_mode = picked.fast_mode,
            .ultrafast_mode = picked.ultrafast_mode,
        };
    }
    return copy;
}

const Pending = struct {
    /// Owns the change's strings and the session copy. It is freed when the change is taken and finished, or on deinit.
    arena: std.heap.ArenaAllocator,
    change: Change,
    /// The screen agent the change was made for. It is compared by address and never read.
    agent_key: usize,
    /// The session the change was made in, copied into `arena`. Null when that session has no id yet.
    session_id: ?[]const u8,
};

/// A finished check: the change it decided, and the hooks' answer. `deinit` frees the change and the answer.
pub const Taken = struct {
    arena: std.heap.ArenaAllocator,
    change: Change,
    agent_key: usize,
    session_id: ?[]const u8,
    result: user_hooks.HookGate.Result,

    pub fn deinit(self: *Taken) void {
        self.result.deinit();
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const State = struct {
    gate: user_hooks.HookGate = .{ .alloc = std.heap.c_allocator },
    pending: ?Pending = null,

    /// Starts the check for `change` when a trusted hook would run for it. Returns false when none would: the caller
    /// applies the change now. Returns error.HookGateBusy while another change waits. The change's strings and the
    /// session id are copied into the pending change; the agent is recorded by address.
    pub fn begin(
        self: *State,
        lifecycle: runtime_lifecycle.LifecycleContext,
        change: Change,
        agent_key: usize,
        session_id: ?[]const u8,
    ) !bool {
        if (self.pending != null) return error.HookGateBusy;
        var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        errdefer arena.deinit();
        const owned = try change.dupe(arena.allocator());
        const copy: ?[]const u8 = if (session_id) |text| try arena.allocator().dupe(u8, text) else null;
        const started = switch (change) {
            .permission_mode => |mode| try user_hooks.beginConfigChange(
                &self.gate,
                lifecycle,
                "permissions",
                "permission_mode",
                mode.old.label(),
                mode.target.label(),
            ),
            .setting => |setting| try user_hooks.beginConfigChange(
                &self.gate,
                lifecycle,
                setting.source,
                @tagName(setting.setting),
                setting.old_value,
                setting.new_value,
            ),
            .model => |model| try user_hooks.beginPreModelSwitch(&self.gate, lifecycle, model.from, model.to),
            .model_switched => |switched| try user_hooks.beginPostModelSwitch(&self.gate, lifecycle, switched.from, switched.to),
        };
        if (!started) {
            arena.deinit();
            return false;
        }
        self.pending = .{ .arena = arena, .change = owned, .agent_key = agent_key, .session_id = copy };
        return true;
    }

    /// The finished check, or null while it runs or no change waits. It never waits on a hook.
    pub fn take(self: *State) ?Taken {
        var result = self.gate.take() orelse return null;
        const pending = self.pending orelse {
            result.deinit();
            return null;
        };
        self.pending = null;
        return .{
            .arena = pending.arena,
            .change = pending.change,
            .agent_key = pending.agent_key,
            .session_id = pending.session_id,
            .result = result,
        };
    }

    /// Esc: asks the check to stop. The hooks stop within one poll, and the next `take` returns
    /// `cancelled`. Returns false when no change waits.
    pub fn cancel(self: *State) bool {
        if (self.pending == null) return false;
        return self.gate.requestCancel();
    }

    /// Whether a change waits for its hooks.
    pub fn isPending(self: *const State) bool {
        return self.pending != null;
    }

    /// The footer's working line while a change waits, or "" when none does.
    pub fn statusText(self: *const State) []const u8 {
        const pending = self.pending orelse return "";
        return switch (pending.change) {
            .permission_mode => "Checking hooks for the permission mode… Esc twice stops it",
            .setting => "Checking hooks for the setting change… Esc twice stops it",
            .model => "Checking hooks for the model change… Esc twice stops it",
            .model_switched => "Running the model switch hooks… Esc twice stops them",
        };
    }

    /// Shutdown: cancels and joins the check, then frees what waits. The hooks stop within one poll, so
    /// exit does not wait on them.
    pub fn deinit(self: *State) void {
        self.gate.deinit();
        if (self.pending) |*pending| pending.arena.deinit();
        self.pending = null;
    }
};

/// Whether a finished check still targets the screen agent and its session, as it did when it started. A session
/// without an id matches only a check that had none. Otherwise the change is dropped (R2.1).
pub fn isCurrentTarget(taken: *const Taken, agent_key: usize, current_session: ?[]const u8) bool {
    if (taken.agent_key != agent_key) return false;
    const was = taken.session_id orelse return current_session == null;
    const now = current_session orelse return false;
    return std.mem.eql(u8, now, was);
}

// --- tests ---

const testing = std.testing;

/// A lifecycle with the given hooks runtime, for a test. Trust stays on, as it does on every surface.
fn testLifecycle(workspace: []const u8, runtime: ?*runtime_lifecycle.UserHooksRuntime) runtime_lifecycle.LifecycleContext {
    return .{
        .view = hooks_view.RuntimeView.empty(),
        .scope = .{ .kind = .interactive, .workspace_root = workspace },
        .outcome_allocator = testing.allocator,
        .user_hooks = runtime,
    };
}

/// Trusts the one hook in `text`, as `fx hook trust` does, so the check can run it.
fn trustHook(alloc: std.mem.Allocator, home: []const u8, text: []const u8) !void {
    var parsed = try hook_engine.config.parse(alloc, text, .{ .layer = .profile, .workspace_root = home });
    defer parsed.deinit(alloc);
    var named = try hooks_host.trust.namedFiles(alloc, parsed.hooks[0].command, home, home);
    defer named.deinit(alloc);
    const value = try hooks_host.trust.digest(alloc, &parsed.hooks[0], home, named.files);
    var store = hooks_host.trust.Store{};
    defer store.deinit(alloc);
    try store.add(alloc, value, "gate test hook");
    const trust_file = try hooks_host.trust.path(alloc, home);
    defer alloc.free(trust_file);
    try hooks_host.trust.save(alloc, trust_file, &store);
}

fn autoChange() Change {
    return .{ .permission_mode = .{ .old = .ask, .target = .auto, .reset = false, .typed = false } };
}

/// Waits for the check to finish, then takes it. A check that never finishes fails the test.
fn waitTaken(state: *State) !Taken {
    const job = state.gate.current orelse return error.CheckDidNotFinish;
    if (!testing_listener.waitFor(&job.done, 5000)) return error.CheckDidNotFinish;
    return state.take() orelse error.CheckDidNotFinish;
}

/// Writes the profile hooks file under `home` and starts a runtime on it, with a PATH for the hooks' shell.
const TestHooks = struct {
    tmp: std.testing.TmpDir,
    home: []u8,
    env: std.process.Environ.Map,
    runtime: ?runtime_lifecycle.UserHooksRuntime = null,

    fn init(alloc: std.mem.Allocator, text: []const u8) !TestHooks {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
        errdefer alloc.free(home);
        var env = std.process.Environ.Map.init(alloc);
        errdefer env.deinit();
        try env.put("PATH", "/usr/bin:/bin");
        var hooks: TestHooks = .{ .tmp = tmp, .home = home, .env = env };
        try hooks.tmp.dir.createDirPath(io_mod.getIo(), ".fx");
        const file_path = try profile_paths.rootPath(alloc, home, &.{"hooks.json"});
        defer alloc.free(file_path);
        try io_mod.writeFileAtomic(alloc, file_path, text);
        try std.Io.Dir.cwd().setFilePermissions(io_mod.getIo(), file_path, std.Io.File.Permissions.fromMode(0o600), .{});
        try trustHook(alloc, home, text);
        return hooks;
    }

    /// Starts the runtime on the written file. It stays in the struct, so its address is stable.
    fn start(self: *TestHooks, alloc: std.mem.Allocator) !void {
        var runtime = try runtime_lifecycle.UserHooksRuntime.init(alloc, .{
            .enabled = true,
            .home = self.home,
            .workspace_root = self.home,
        });
        runtime.native.base_env = &self.env;
        runtime.refresh();
        self.runtime = runtime;
    }

    fn deinit(self: *TestHooks, alloc: std.mem.Allocator) void {
        if (self.runtime) |*runtime| runtime.deinit();
        alloc.free(self.home);
        self.env.deinit();
        self.tmp.cleanup();
    }
};

/// A profile hooks file with one hook on `event`, whose id is "gate" and whose command is `command`.
fn eventHooks(comptime event: []const u8, comptime command: []const u8) []const u8 {
    return "{\"hooks\":{\"" ++ event ++ "\":[{\"hooks\":[{\"type\":\"command\",\"id\":\"gate\",\"command\":\"" ++ command ++ "\"}]}]}}";
}

fn configHooks(comptime command: []const u8) []const u8 {
    return eventHooks("ConfigChange", command);
}

test "a change with no hook to run starts no check and applies at once" {
    var state: State = .{};
    defer state.deinit();
    const started = try state.begin(testLifecycle("/fixture", null), autoChange(), 1, null);
    try testing.expect(!started);
    try testing.expect(!state.isPending());
}

test "a refusing ConfigChange hook answers a waiting change as refused, with its reason" {
    var hooks = try TestHooks.init(testing.allocator, configHooks("echo no mode change >&2; exit 2"));
    defer hooks.deinit(testing.allocator);
    try hooks.start(testing.allocator);

    var state: State = .{};
    defer state.deinit();
    const lifecycle = testLifecycle(hooks.home, &hooks.runtime.?);
    try testing.expect(try state.begin(lifecycle, autoChange(), 7, "s-1"));
    try testing.expect(state.isPending());
    try testing.expectEqualStrings("Checking hooks for the permission mode… Esc twice stops it", state.statusText());

    var taken = try waitTaken(&state);
    defer taken.deinit();
    try testing.expectEqual(user_hooks.HookGate.Outcome.refused, taken.result.outcome);
    try testing.expectEqualStrings(
        "A hook refused this setting change: no mode change",
        taken.result.refusal orelse return error.MissingRefusal,
    );
    try testing.expectEqual(@as(usize, 7), taken.agent_key);
    try testing.expectEqualStrings("s-1", taken.session_id orelse return error.MissingSession);
    try testing.expect(!state.isPending());
    try testing.expectEqualStrings("", state.statusText());
}

test "cancel stops a waiting hook, and the change is taken as cancelled" {
    var hooks = try TestHooks.init(testing.allocator, configHooks("exec sleep 30"));
    defer hooks.deinit(testing.allocator);
    try hooks.start(testing.allocator);

    var state: State = .{};
    defer state.deinit();
    try testing.expect(try state.begin(testLifecycle(hooks.home, &hooks.runtime.?), autoChange(), 1, null));
    try testing.expect(state.cancel());

    var taken = try waitTaken(&state);
    defer taken.deinit();
    try testing.expectEqual(user_hooks.HookGate.Outcome.cancelled, taken.result.outcome);
    try testing.expect(taken.result.refusal == null);
    try testing.expect(taken.session_id == null);
}

test "a second change is refused while one waits" {
    var hooks = try TestHooks.init(testing.allocator, configHooks("exec sleep 30"));
    defer hooks.deinit(testing.allocator);
    try hooks.start(testing.allocator);

    var state: State = .{};
    defer state.deinit();
    const lifecycle = testLifecycle(hooks.home, &hooks.runtime.?);
    try testing.expect(try state.begin(lifecycle, autoChange(), 1, null));
    try testing.expectError(error.HookGateBusy, state.begin(lifecycle, autoChange(), 1, null));

    try testing.expect(state.cancel());
    var taken = try waitTaken(&state);
    taken.deinit();
}

test "a model change with no PreModelSwitch hook starts no check" {
    var state: State = .{};
    defer state.deinit();
    const change: Change = .{ .model = .{ .from = "acme/thinker", .to = "acme/other", .announce = true, .picker = null } };
    try testing.expect(!try state.begin(testLifecycle("/fixture", null), change, 1, null));
    try testing.expect(!state.isPending());
}

test "a refusing PreModelSwitch hook answers a waiting model change as refused, and the change keeps its own copies" {
    var hooks = try TestHooks.init(testing.allocator, eventHooks("PreModelSwitch", "echo no model >&2; exit 2"));
    defer hooks.deinit(testing.allocator);
    try hooks.start(testing.allocator);

    var state: State = .{};
    defer state.deinit();
    var from_buf = "acme/thinker".*;
    var to_buf = "acme/other".*;
    const change: Change = .{ .model = .{ .from = &from_buf, .to = &to_buf, .announce = true, .picker = null } };
    try testing.expect(try state.begin(testLifecycle(hooks.home, &hooks.runtime.?), change, 3, "s-2"));
    // The caller's buffers may go away once begin returns, so the pending change must hold its own copies.
    @memset(&from_buf, 'x');
    @memset(&to_buf, 'x');
    try testing.expectEqualStrings("Checking hooks for the model change… Esc twice stops it", state.statusText());

    var taken = try waitTaken(&state);
    defer taken.deinit();
    try testing.expectEqual(user_hooks.HookGate.Outcome.refused, taken.result.outcome);
    try testing.expectEqualStrings(
        "A hook refused the model change: no model",
        taken.result.refusal orelse return error.MissingRefusal,
    );
    const model = taken.change.model;
    try testing.expectEqualStrings("acme/thinker", model.from);
    try testing.expectEqualStrings("acme/other", model.to);
    try testing.expect(model.announce);
    try testing.expectEqualStrings("s-2", taken.session_id orelse return error.MissingSession);
}

test "an observed PostModelSwitch check gives its notices and framed context when taken" {
    var hooks = try TestHooks.init(testing.allocator, eventHooks("PostModelSwitch", "printf '%s' 'the new model is faster'"));
    defer hooks.deinit(testing.allocator);
    try hooks.start(testing.allocator);

    var state: State = .{};
    defer state.deinit();
    const change: Change = .{ .model_switched = .{ .from = "acme/thinker", .to = "acme/other" } };
    try testing.expect(try state.begin(testLifecycle(hooks.home, &hooks.runtime.?), change, 1, "s-3"));
    try testing.expectEqualStrings("Running the model switch hooks… Esc twice stops them", state.statusText());

    var taken = try waitTaken(&state);
    defer taken.deinit();
    try testing.expectEqual(user_hooks.HookGate.Outcome.allowed, taken.result.outcome);
    try testing.expect(taken.result.refusal == null);
    const context = taken.result.context orelse return error.MissingContext;
    try testing.expect(std.mem.startsWith(u8, context, "<hook-context event=\"PostModelSwitch\">"));
    try testing.expect(std.mem.find(u8, context, "the new model is faster") != null);
}

test "a setting change with no hook to run starts no check" {
    var state: State = .{};
    defer state.deinit();
    const change: Change = .{ .setting = .{
        .setting = .collapse_tool_calls,
        .source = "settings",
        .old_value = "off",
        .new_value = "on",
        .value = "on",
    } };
    try testing.expect(!try state.begin(testLifecycle("/fixture", null), change, 1, null));
    try testing.expect(!state.isPending());
}

test "a refusing ConfigChange hook answers a waiting effort change as refused, and the change keeps its own copies" {
    var hooks = try TestHooks.init(testing.allocator, configHooks("echo no effort >&2; exit 2"));
    defer hooks.deinit(testing.allocator);
    try hooks.start(testing.allocator);

    var state: State = .{};
    defer state.deinit();
    var old_buf = "medium".*;
    var new_buf = "high".*;
    const change: Change = .{ .setting = .{
        .setting = .effort,
        .source = "effort",
        .old_value = &old_buf,
        .new_value = &new_buf,
        .value = &new_buf,
        .effort = types.ReasoningEffort.literal("high"),
        .feedback = .named,
    } };
    try testing.expect(try state.begin(testLifecycle(hooks.home, &hooks.runtime.?), change, 5, "s-4"));
    @memset(&old_buf, 'x');
    @memset(&new_buf, 'x');
    try testing.expectEqualStrings("Checking hooks for the setting change… Esc twice stops it", state.statusText());

    var taken = try waitTaken(&state);
    defer taken.deinit();
    try testing.expectEqual(user_hooks.HookGate.Outcome.refused, taken.result.outcome);
    try testing.expectEqualStrings(
        "A hook refused this setting change: no effort",
        taken.result.refusal orelse return error.MissingRefusal,
    );
    const setting = taken.change.setting;
    try testing.expectEqual(settings_catalog.SettingId.effort, setting.setting);
    try testing.expectEqualStrings("effort", setting.source);
    try testing.expectEqualStrings("medium", setting.old_value);
    try testing.expectEqualStrings("high", setting.new_value);
    try testing.expectEqualStrings("high", setting.value);
    const effort = setting.effort orelse return error.MissingEffort;
    try testing.expectEqualStrings("high", effort.label());
    try testing.expectEqual(SettingFeedback.named, setting.feedback);
    try testing.expect(setting.picked == null);
    try testing.expectEqual(@as(usize, 5), taken.agent_key);
}
