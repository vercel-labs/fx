const std = @import("std");
const session_layout = @import("../session/session_layout.zig");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;

pub const max_authority_text_bytes: usize = 4096;
pub const max_command_bytes: usize = 64 * 1024;
pub const max_shell_path_bytes: usize = 4096;
pub const max_write_bytes: usize = 64 * 1024;
pub const max_write_items: usize = 4096;
pub const max_match_bytes: usize = 4096;
pub const max_monitor_definitions: usize = 32;
pub const max_list_results: usize = 256;
pub const max_cell_text_bytes: usize = 64;
pub const max_render_snapshot_bytes: usize = 8 * 1024 * 1024;
pub const max_checkpoint_payload_bytes: usize = 64 * 1024 * 1024;
pub const max_host_frame_bytes: usize = 1024 * 1024;
pub const max_dimension: u16 = 4096;

pub const current_protocol_revision: u16 = 5;
pub const previous_protocol_revision: u16 = 4;
pub const oldest_hello_revision: u16 = 1;
pub const compatibility_hello_revision: u16 = previous_protocol_revision - 1;

pub const protocol_capability_authority_generations: u64 = 1 << 0;
pub const protocol_capability_screen_checkpoints: u64 = 1 << 1;
pub const protocol_capability_tmux_recovery: u64 = 1 << 2;
pub const protocol_capability_path_outside_workspace_error: u64 = 1 << 3;
pub const protocol_capability_complete_process_tree_signals: u64 = 1 << 4;
pub const known_protocol_capabilities: u64 =
    protocol_capability_authority_generations |
    protocol_capability_screen_checkpoints |
    protocol_capability_tmux_recovery |
    protocol_capability_path_outside_workspace_error |
    protocol_capability_complete_process_tree_signals;

pub const Action = enum {
    start,
    read,
    screen,
    write,
    wait,
    inspect,
    list,
    resize,
    signal,
    close,
};

pub const Lifecycle = enum {
    starting,
    running,
    exited,
    lost,
    closed,
};

pub const LifecycleEvent = enum {
    child_started,
    child_exited,
    host_lost,
    close,
};

pub const LifecycleTransitionError = error{InvalidLifecycleTransition};

pub fn transition_lifecycle(
    current: Lifecycle,
    event: LifecycleEvent,
) LifecycleTransitionError!Lifecycle {
    return switch (current) {
        .starting => switch (event) {
            .child_started => .running,
            .child_exited => .exited,
            .host_lost => .lost,
            .close => .closed,
        },
        .running => switch (event) {
            .child_exited => .exited,
            .host_lost => .lost,
            .close => .closed,
            .child_started => error.InvalidLifecycleTransition,
        },
        .exited, .lost => switch (event) {
            .close => .closed,
            .child_started, .child_exited, .host_lost => error.InvalidLifecycleTransition,
        },
        .closed => error.InvalidLifecycleTransition,
    };
}

pub const Attention = enum {
    background,
    agent_wait,
    user_takeover,
};

pub const ActorRole = enum {
    human,
    agent,
};

pub const WriteLease = enum {
    none,
    human,
    agent,
};

pub const AttentionState = struct {
    attention: Attention = .background,
    write_lease: WriteLease = .none,

    pub fn validate(self: AttentionState) error{InvalidAttentionState}!void {
        if (self.attention == .user_takeover and self.write_lease != .human) {
            return error.InvalidAttentionState;
        }
        if (self.attention != .user_takeover and self.write_lease == .human) {
            return error.InvalidAttentionState;
        }
    }
};

/// Cancels only the caller's attention or write lease. It never changes the
/// terminal lifecycle.
pub fn cancel_attention(state: AttentionState, actor: ActorRole) AttentionState {
    var next = state;
    switch (actor) {
        .human => {
            if (next.attention == .user_takeover) next.attention = .background;
            if (next.write_lease == .human) next.write_lease = .none;
        },
        .agent => {
            if (next.attention == .agent_wait) next.attention = .background;
            if (next.write_lease == .agent) next.write_lease = .none;
        },
    }
    return next;
}

pub const Backend = enum {
    native,
    tmux,
};

pub const PersistenceLevel = enum {
    durable,
};

pub const ReturnCondition = union(enum) {
    started,
    exit,
    quiet: u64,
    match: []const u8,

    pub fn validate(self: ReturnCondition) error{InvalidReturnCondition}!void {
        switch (self) {
            .started, .exit => {},
            .quiet => |duration_ms| {
                if (duration_ms == 0) return error.InvalidReturnCondition;
            },
            .match => |pattern| {
                if (pattern.len == 0 or pattern.len > max_match_bytes) {
                    return error.InvalidReturnCondition;
                }
            },
        }
    }
};

pub const PollSchedule = struct {
    interval_ms: u64,

    pub fn validate(self: PollSchedule) error{InvalidSchedule}!void {
        if (self.interval_ms == 0) return error.InvalidSchedule;
    }
};

pub const ShellSpec = union(enum) {
    user_login,
    executable: struct {
        path: []const u8,
        clean_start: bool = false,
    },

    pub fn validate(self: ShellSpec) error{InvalidShell}!void {
        switch (self) {
            .user_login => {},
            .executable => |value| {
                if (!valid_bounded_text(value.path, max_shell_path_bytes)) {
                    return error.InvalidShell;
                }
            },
        }
    }
};

pub const NamedKey = enum {
    enter,
    tab,
    escape,
    backspace,
    delete,
    insert,
    arrow_up,
    arrow_down,
    arrow_left,
    arrow_right,
    home,
    end,
    page_up,
    page_down,
};

pub const ControlInput = struct {
    character: u8,

    pub fn validate(self: ControlInput) error{InvalidControlInput}!void {
        const uppercase_control = self.character >= '@' and self.character <= '_';
        const lowercase_control = self.character >= 'a' and self.character <= 'z';
        if (!uppercase_control and !lowercase_control and self.character != '?') {
            return error.InvalidControlInput;
        }
    }
};

pub const WritePayload = union(enum) {
    text: []const u8,
    keys: []const NamedKey,
    controls: []const ControlInput,
    paste: []const u8,

    pub fn validate(self: WritePayload) error{InvalidWritePayload}!void {
        switch (self) {
            .text, .paste => |bytes| {
                if (bytes.len == 0 or bytes.len > max_write_bytes) {
                    return error.InvalidWritePayload;
                }
            },
            .keys => |keys| {
                if (keys.len == 0 or keys.len > max_write_items) {
                    return error.InvalidWritePayload;
                }
            },
            .controls => |controls| {
                if (controls.len == 0 or controls.len > max_write_items) {
                    return error.InvalidWritePayload;
                }
                for (controls) |control| {
                    control.validate() catch return error.InvalidWritePayload;
                }
            },
        }
    }
};

pub const Signal = enum {
    hangup,
    interrupt,
    quit,
    terminate,
    kill,
};

pub const ClosePolicy = enum {
    graceful,
    force,
};

pub const NotifySchedule = union(enum) {
    on_match,
    on_state_change,
    on_exit,
    every_check,
    every_n_checks: u32,
    interval: PollSchedule,

    pub fn validate(self: NotifySchedule) error{InvalidSchedule}!void {
        switch (self) {
            .on_match, .on_state_change, .on_exit, .every_check => {},
            .every_n_checks => |count| {
                if (count == 0) return error.InvalidSchedule;
            },
            .interval => |schedule| try schedule.validate(),
        }
    }
};

pub const MonitorLifetime = union(enum) {
    until_match,
    until_session_end,
    duration_ms: u64,

    pub fn validate(self: MonitorLifetime) error{InvalidMonitorLifetime}!void {
        switch (self) {
            .until_match, .until_session_end => {},
            .duration_ms => |duration_ms| {
                if (duration_ms == 0) return error.InvalidMonitorLifetime;
            },
        }
    }
};

pub const StartRequest = struct {
    cwd: []const u8,
    command: ?[]const u8 = null,
    shell: ShellSpec = .user_login,
    backend: Backend = .native,
    return_when: ?ReturnCondition = null,
    wait_ceiling_ms: ?u64 = null,
    timeout_ms: ?u64 = null,
    dimensions: ?Dimensions = null,
    persistence: ?StartPersistence = null,
};

pub const StartPersistence = struct {
    grant: AuthorityGrant,
    proof: HolderProof,
    direct_human_model_read_only: bool = false,

    pub fn validate(self: StartPersistence, request: StartRequest) error{
        InvalidPrincipal,
        InvalidSessionId,
        InvalidAuthorityGeneration,
        InvalidAuthorityGrant,
        InvalidHolderProof,
        InvalidStartPersistence,
    }!void {
        try self.grant.validate();
        try self.proof.validate();
        if (!std.mem.eql(u8, self.grant.principal.cwd, request.cwd) or
            self.grant.principal.backend != request.backend)
        {
            return error.InvalidStartPersistence;
        }
        if (self.direct_human_model_read_only and self.grant.actor != .human) {
            return error.InvalidStartPersistence;
        }
    }
};

pub const ReadRequest = struct {
    session_id: []const u8,
    cursor: RawCursor,
    authority: ?AuthorityClaim = null,
};

pub const SessionRequest = struct {
    session_id: []const u8,
    authority: ?AuthorityClaim = null,
};

pub const WriteLeaseIntent = enum {
    acquire,
    use,
    release,
    revoke,
};

fn write_payload_required(lease: WriteLeaseIntent) bool {
    return lease == .use;
}

pub const WriteRequest = struct {
    session_id: []const u8,
    payload: ?WritePayload = null,
    lease: WriteLeaseIntent = .use,
    authority: ?AuthorityClaim = null,
};

pub const WaitRequest = struct {
    session_id: []const u8,
    return_when: ReturnCondition,
    safety_ceiling_ms: u64,
    authority: ?AuthorityClaim = null,
};

pub const ListFilters = struct {
    task_id: ?[]const u8 = null,
    workspace_root: ?[]const u8 = null,
    lifecycle: ?Lifecycle = null,
    backend: ?Backend = null,
    owner_authority: ?OwnerCatalogAuthorityClaim = null,

    pub fn validate(self: ListFilters) error{InvalidListFilter}!void {
        if (self.task_id) |task_id| {
            if (!valid_bounded_text(task_id, max_authority_text_bytes)) {
                return error.InvalidListFilter;
            }
        }
        if (self.workspace_root) |workspace_root| {
            if (!valid_bounded_text(workspace_root, max_authority_text_bytes)) {
                return error.InvalidListFilter;
            }
        }
    }
};

pub const ResizeRequest = struct {
    session_id: []const u8,
    dimensions: Dimensions,
    authority: ?AuthorityClaim = null,
};

pub const SignalRequest = struct {
    session_id: []const u8,
    signal: Signal,
    authority: ?AuthorityClaim = null,
};

pub const CloseRequest = struct {
    session_id: []const u8,
    policy: ClosePolicy,
    authority: ?AuthorityClaim = null,
};

pub const RequestValidationError = error{
    InvalidCommand,
    InvalidCwd,
    InvalidShell,
    InvalidReturnCondition,
    MissingReturnCondition,
    MissingWaitCeiling,
    InvalidWaitCeiling,
    InvalidTimeout,
    InvalidDimensions,
    InvalidSessionId,
    InvalidRawCursor,
    InvalidWritePayload,
    InvalidListFilter,
    InvalidPrincipal,
    InvalidAuthorityGeneration,
    InvalidAuthorityGrant,
    InvalidAuthorityClaim,
    InvalidHolderProof,
    InvalidStartPersistence,
};

pub const ActionRequest = union(enum) {
    start: StartRequest,
    read: ReadRequest,
    screen: SessionRequest,
    write: WriteRequest,
    wait: WaitRequest,
    inspect: SessionRequest,
    list: ListFilters,
    resize: ResizeRequest,
    signal: SignalRequest,
    close: CloseRequest,

    pub fn action(self: ActionRequest) Action {
        return switch (self) {
            .start => .start,
            .read => .read,
            .screen => .screen,
            .write => .write,
            .wait => .wait,
            .inspect => .inspect,
            .list => .list,
            .resize => .resize,
            .signal => .signal,
            .close => .close,
        };
    }

    pub fn validate(self: ActionRequest) RequestValidationError!void {
        switch (self) {
            .start => |request| {
                if (!valid_bounded_text(request.cwd, max_authority_text_bytes) or
                    !std.fs.path.isAbsolute(request.cwd))
                {
                    return error.InvalidCwd;
                }
                try request.shell.validate();
                if (request.command) |command| {
                    if (!valid_bounded_text(command, max_command_bytes)) {
                        return error.InvalidCommand;
                    }
                    if (request.return_when == null) return error.MissingReturnCondition;
                }
                if (request.return_when) |condition| {
                    try condition.validate();
                    if (!return_condition_is_immediate(condition) and
                        request.wait_ceiling_ms == null)
                    {
                        return error.MissingWaitCeiling;
                    }
                }
                if (request.wait_ceiling_ms) |ceiling_ms| {
                    if (ceiling_ms == 0) return error.InvalidWaitCeiling;
                }
                if (request.timeout_ms) |timeout_ms| {
                    if (timeout_ms == 0 or timeout_ms > std.math.maxInt(i64)) {
                        return error.InvalidTimeout;
                    }
                }
                if (request.dimensions) |dimensions| try dimensions.validate();
                if (request.persistence) |persistence| {
                    try persistence.validate(request);
                }
            },
            .read => |request| {
                try validate_session_id(request.session_id);
                try request.cursor.validate();
                try validate_optional_authority_claim(request.authority);
            },
            .screen => |request| {
                try validate_session_id(request.session_id);
                try validate_optional_authority_claim(request.authority);
            },
            .inspect => |request| {
                try validate_session_id(request.session_id);
                try validate_optional_authority_claim(request.authority);
            },
            .write => |request| {
                try validate_session_id(request.session_id);
                if (write_payload_required(request.lease) != (request.payload != null)) {
                    return error.InvalidWritePayload;
                }
                if (request.payload) |payload| try payload.validate();
                try validate_optional_authority_claim(request.authority);
            },
            .wait => |request| {
                try validate_session_id(request.session_id);
                try request.return_when.validate();
                if (request.safety_ceiling_ms == 0) return error.InvalidWaitCeiling;
                try validate_optional_authority_claim(request.authority);
            },
            .list => |filters| {
                try filters.validate();
                if (filters.owner_authority) |claim| {
                    claim.validate() catch return error.InvalidAuthorityClaim;
                }
            },
            .resize => |request| {
                try validate_session_id(request.session_id);
                try request.dimensions.validate();
                try validate_optional_authority_claim(request.authority);
            },
            .signal => |request| {
                try validate_session_id(request.session_id);
                try validate_optional_authority_claim(request.authority);
            },
            .close => |request| {
                try validate_session_id(request.session_id);
                try validate_optional_authority_claim(request.authority);
            },
        }
    }
};

pub fn required_capabilities(request: ActionRequest) u64 {
    var required = protocol_capability_authority_generations;
    switch (request) {
        .start => |start| {
            required |= protocol_capability_complete_process_tree_signals;
            if (start.backend == .tmux) {
                required |= protocol_capability_tmux_recovery;
            }
        },
        .signal => {
            required |= protocol_capability_complete_process_tree_signals;
        },
        .close => |close| {
            if (close.policy == .force) {
                required |= protocol_capability_complete_process_tree_signals;
            }
        },
        .read,
        .screen,
        .write,
        .wait,
        .inspect,
        .list,
        .resize,
        => {},
    }
    return required;
}

fn validate_optional_authority_claim(claim: ?AuthorityClaim) error{
    InvalidPrincipal,
    InvalidSessionId,
    InvalidAuthorityGeneration,
    InvalidAuthorityClaim,
}!void {
    if (claim) |value| try value.validate();
}

/// Owned semantic request. The caller frees every copied external value with
/// `deinit` using the allocator passed to `init`.
pub const OwnedActionRequest = struct {
    value: ActionRequest,

    pub fn init(
        alloc: Allocator,
        request: ActionRequest,
    ) (Allocator.Error || RequestValidationError)!OwnedActionRequest {
        try request.validate();
        return .{ .value = try clone_action_request(alloc, request) };
    }

    pub fn deinit(self: *OwnedActionRequest, alloc: Allocator) void {
        deinit_action_request(alloc, &self.value);
        self.* = undefined;
    }
};

fn clone_action_request(alloc: Allocator, request: ActionRequest) Allocator.Error!ActionRequest {
    return switch (request) {
        .start => |value| .{ .start = try clone_start_request(alloc, value) },
        .read => |value| blk: {
            const parts = try clone_authorized_session(
                alloc,
                value.session_id,
                value.authority,
            );
            break :blk .{ .read = .{
                .session_id = parts.session_id,
                .cursor = value.cursor,
                .authority = parts.authority,
            } };
        },
        .screen => |value| .{ .screen = try clone_session_request(alloc, value) },
        .write => |value| blk: {
            const session_id = try alloc.dupe(u8, value.session_id);
            errdefer alloc.free(session_id);
            const payload = if (value.payload) |payload|
                try clone_write_payload(alloc, payload)
            else
                null;
            errdefer if (payload) |owned| deinit_write_payload(alloc, owned);
            break :blk .{ .write = .{
                .session_id = session_id,
                .payload = payload,
                .lease = value.lease,
                .authority = try clone_optional_authority_claim(alloc, value.authority),
            } };
        },
        .wait => |value| blk: {
            const session_id = try alloc.dupe(u8, value.session_id);
            errdefer alloc.free(session_id);
            const return_when = try clone_return_condition(alloc, value.return_when);
            errdefer deinit_return_condition(alloc, return_when);
            break :blk .{ .wait = .{
                .session_id = session_id,
                .return_when = return_when,
                .safety_ceiling_ms = value.safety_ceiling_ms,
                .authority = try clone_optional_authority_claim(alloc, value.authority),
            } };
        },
        .inspect => |value| .{ .inspect = try clone_session_request(alloc, value) },
        .list => |value| .{ .list = try clone_list_filters(alloc, value) },
        .resize => |value| blk: {
            const parts = try clone_authorized_session(
                alloc,
                value.session_id,
                value.authority,
            );
            break :blk .{ .resize = .{
                .session_id = parts.session_id,
                .dimensions = value.dimensions,
                .authority = parts.authority,
            } };
        },
        .signal => |value| blk: {
            const parts = try clone_authorized_session(
                alloc,
                value.session_id,
                value.authority,
            );
            break :blk .{ .signal = .{
                .session_id = parts.session_id,
                .signal = value.signal,
                .authority = parts.authority,
            } };
        },
        .close => |value| blk: {
            const parts = try clone_authorized_session(
                alloc,
                value.session_id,
                value.authority,
            );
            break :blk .{ .close = .{
                .session_id = parts.session_id,
                .policy = value.policy,
                .authority = parts.authority,
            } };
        },
    };
}

fn clone_session_request(
    alloc: Allocator,
    request: SessionRequest,
) Allocator.Error!SessionRequest {
    const session_id = try alloc.dupe(u8, request.session_id);
    errdefer alloc.free(session_id);
    return .{
        .session_id = session_id,
        .authority = try clone_optional_authority_claim(alloc, request.authority),
    };
}

const AuthorizedSessionParts = struct {
    session_id: []const u8,
    authority: ?AuthorityClaim,
};

fn clone_authorized_session(
    alloc: Allocator,
    session_id: []const u8,
    authority: ?AuthorityClaim,
) Allocator.Error!AuthorizedSessionParts {
    const owned_session_id = try alloc.dupe(u8, session_id);
    errdefer alloc.free(owned_session_id);
    return .{
        .session_id = owned_session_id,
        .authority = try clone_optional_authority_claim(alloc, authority),
    };
}

fn clone_start_request(alloc: Allocator, request: StartRequest) Allocator.Error!StartRequest {
    const cwd = try alloc.dupe(u8, request.cwd);
    errdefer alloc.free(cwd);
    const command = if (request.command) |value| try alloc.dupe(u8, value) else null;
    errdefer if (command) |value| alloc.free(value);
    const shell = try clone_shell_spec(alloc, request.shell);
    errdefer deinit_shell_spec(alloc, shell);
    const return_when = if (request.return_when) |value|
        try clone_return_condition(alloc, value)
    else
        null;
    errdefer if (return_when) |value| deinit_return_condition(alloc, value);
    const persistence = if (request.persistence) |value|
        StartPersistence{
            .grant = try clone_authority_grant(alloc, value.grant),
            .proof = value.proof,
            .direct_human_model_read_only = value.direct_human_model_read_only,
        }
    else
        null;
    return .{
        .cwd = cwd,
        .command = command,
        .shell = shell,
        .backend = request.backend,
        .return_when = return_when,
        .wait_ceiling_ms = request.wait_ceiling_ms,
        .timeout_ms = request.timeout_ms,
        .dimensions = request.dimensions,
        .persistence = persistence,
    };
}

fn clone_authority_grant(
    alloc: Allocator,
    grant: AuthorityGrant,
) Allocator.Error!AuthorityGrant {
    const principal = try clone_principal(alloc, grant.principal);
    errdefer deinit_principal(alloc, principal);
    const repeated_probes = try alloc.alloc(
        RepeatedProbeAuthority,
        grant.repeated_probes.len,
    );
    var initialized: usize = 0;
    errdefer {
        for (repeated_probes[0..initialized]) |probe| {
            alloc.free(probe.cwd);
            alloc.free(probe.command);
        }
        alloc.free(repeated_probes);
    }
    for (grant.repeated_probes, 0..) |probe, index| {
        const command = try alloc.dupe(u8, probe.command);
        errdefer alloc.free(command);
        repeated_probes[index] = .{
            .command = command,
            .cwd = try alloc.dupe(u8, probe.cwd),
            .check_schedule = probe.check_schedule,
            .notify_schedule = probe.notify_schedule,
            .lifetime = probe.lifetime,
        };
        initialized += 1;
    }
    return .{
        .principal = principal,
        .actor = grant.actor,
        .controls = grant.controls,
        .generation = grant.generation,
        .repeated_probes = repeated_probes,
    };
}

fn clone_principal(
    alloc: Allocator,
    principal: Principal,
) Allocator.Error!Principal {
    const profile_user = try alloc.dupe(u8, principal.profile_user);
    errdefer alloc.free(profile_user);
    const durable_session_id = try alloc.dupe(u8, principal.durable_session_id);
    errdefer alloc.free(durable_session_id);
    const workspace_root = try alloc.dupe(u8, principal.workspace_root);
    errdefer alloc.free(workspace_root);
    return .{
        .profile_user = profile_user,
        .durable_session_id = durable_session_id,
        .workspace_root = workspace_root,
        .cwd = try alloc.dupe(u8, principal.cwd),
        .transport_role = principal.transport_role,
        .backend = principal.backend,
        .lifetime = principal.lifetime,
    };
}

fn clone_optional_authority_claim(
    alloc: Allocator,
    claim: ?AuthorityClaim,
) Allocator.Error!?AuthorityClaim {
    return if (claim) |value| try clone_authority_claim(alloc, value) else null;
}

fn clone_authority_claim(
    alloc: Allocator,
    claim: AuthorityClaim,
) Allocator.Error!AuthorityClaim {
    return .{
        .principal = try clone_principal(alloc, claim.principal),
        .actor = claim.actor,
        .generation = claim.generation,
        .proof = claim.proof,
        .process_owner = claim.process_owner,
    };
}

fn deinit_optional_authority_claim(
    alloc: Allocator,
    claim: ?AuthorityClaim,
) void {
    if (claim) |value| deinit_principal(alloc, value.principal);
}

fn clone_optional_owner_catalog_claim(
    alloc: Allocator,
    claim: ?OwnerCatalogAuthorityClaim,
) Allocator.Error!?OwnerCatalogAuthorityClaim {
    const value = claim orelse return null;
    const profile_user = try alloc.dupe(u8, value.principal.profile_user);
    errdefer alloc.free(profile_user);
    const durable_session_id = try alloc.dupe(
        u8,
        value.principal.durable_session_id,
    );
    errdefer alloc.free(durable_session_id);
    return .{
        .principal = .{
            .profile_user = profile_user,
            .durable_session_id = durable_session_id,
            .workspace_root = try alloc.dupe(
                u8,
                value.principal.workspace_root,
            ),
            .transport_role = value.principal.transport_role,
        },
        .actor = value.actor,
        .proof = value.proof,
    };
}

fn deinit_optional_owner_catalog_claim(
    alloc: Allocator,
    claim: ?OwnerCatalogAuthorityClaim,
) void {
    const value = claim orelse return;
    alloc.free(value.principal.workspace_root);
    alloc.free(value.principal.durable_session_id);
    alloc.free(value.principal.profile_user);
}

fn deinit_authority_grant(alloc: Allocator, grant: AuthorityGrant) void {
    for (grant.repeated_probes) |probe| {
        alloc.free(probe.cwd);
        alloc.free(probe.command);
    }
    alloc.free(grant.repeated_probes);
    deinit_principal(alloc, grant.principal);
}

fn deinit_principal(alloc: Allocator, principal: Principal) void {
    alloc.free(principal.cwd);
    alloc.free(principal.workspace_root);
    alloc.free(principal.durable_session_id);
    alloc.free(principal.profile_user);
}

fn clone_shell_spec(alloc: Allocator, shell: ShellSpec) Allocator.Error!ShellSpec {
    return switch (shell) {
        .user_login => .user_login,
        .executable => |value| .{ .executable = .{
            .path = try alloc.dupe(u8, value.path),
            .clean_start = value.clean_start,
        } },
    };
}

fn deinit_shell_spec(alloc: Allocator, shell: ShellSpec) void {
    switch (shell) {
        .user_login => {},
        .executable => |value| alloc.free(value.path),
    }
}

fn clone_return_condition(
    alloc: Allocator,
    condition: ReturnCondition,
) Allocator.Error!ReturnCondition {
    return switch (condition) {
        .started => .started,
        .exit => .exit,
        .quiet => |duration_ms| .{ .quiet = duration_ms },
        .match => |pattern| .{ .match = try alloc.dupe(u8, pattern) },
    };
}

fn deinit_return_condition(alloc: Allocator, condition: ReturnCondition) void {
    switch (condition) {
        .match => |pattern| alloc.free(pattern),
        .started, .exit, .quiet => {},
    }
}

fn clone_write_payload(alloc: Allocator, payload: WritePayload) Allocator.Error!WritePayload {
    return switch (payload) {
        .text => |bytes| .{ .text = try alloc.dupe(u8, bytes) },
        .keys => |keys| .{ .keys = try alloc.dupe(NamedKey, keys) },
        .controls => |controls| .{
            .controls = try alloc.dupe(ControlInput, controls),
        },
        .paste => |bytes| .{ .paste = try alloc.dupe(u8, bytes) },
    };
}

fn deinit_write_payload(alloc: Allocator, payload: WritePayload) void {
    switch (payload) {
        .text => |bytes| alloc.free(bytes),
        .keys => |keys| alloc.free(keys),
        .controls => |controls| alloc.free(controls),
        .paste => |bytes| alloc.free(bytes),
    }
}

fn clone_list_filters(alloc: Allocator, filters: ListFilters) Allocator.Error!ListFilters {
    const task_id = if (filters.task_id) |value| try alloc.dupe(u8, value) else null;
    errdefer if (task_id) |value| alloc.free(value);
    const workspace_root = if (filters.workspace_root) |value|
        try alloc.dupe(u8, value)
    else
        null;
    errdefer if (workspace_root) |value| alloc.free(value);
    return .{
        .task_id = task_id,
        .workspace_root = workspace_root,
        .lifecycle = filters.lifecycle,
        .backend = filters.backend,
        .owner_authority = try clone_optional_owner_catalog_claim(
            alloc,
            filters.owner_authority,
        ),
    };
}

fn deinit_list_filters(alloc: Allocator, filters: ListFilters) void {
    if (filters.task_id) |task_id| alloc.free(task_id);
    if (filters.workspace_root) |workspace_root| alloc.free(workspace_root);
    deinit_optional_owner_catalog_claim(alloc, filters.owner_authority);
}

fn deinit_action_request(alloc: Allocator, request: *ActionRequest) void {
    switch (request.*) {
        .start => |value| {
            alloc.free(value.cwd);
            if (value.command) |command| alloc.free(command);
            deinit_shell_spec(alloc, value.shell);
            if (value.return_when) |condition| {
                deinit_return_condition(alloc, condition);
            }
            if (value.persistence) |persistence| {
                deinit_authority_grant(alloc, persistence.grant);
            }
        },
        .read => |value| {
            alloc.free(value.session_id);
            deinit_optional_authority_claim(alloc, value.authority);
        },
        .screen => |value| {
            alloc.free(value.session_id);
            deinit_optional_authority_claim(alloc, value.authority);
        },
        .write => |value| {
            alloc.free(value.session_id);
            if (value.payload) |payload| deinit_write_payload(alloc, payload);
            deinit_optional_authority_claim(alloc, value.authority);
        },
        .wait => |value| {
            alloc.free(value.session_id);
            deinit_return_condition(alloc, value.return_when);
            deinit_optional_authority_claim(alloc, value.authority);
        },
        .inspect => |value| {
            alloc.free(value.session_id);
            deinit_optional_authority_claim(alloc, value.authority);
        },
        .list => |value| deinit_list_filters(alloc, value),
        .resize => |value| {
            alloc.free(value.session_id);
            deinit_optional_authority_claim(alloc, value.authority);
        },
        .signal => |value| {
            alloc.free(value.session_id);
            deinit_optional_authority_claim(alloc, value.authority);
        },
        .close => |value| {
            alloc.free(value.session_id);
            deinit_optional_authority_claim(alloc, value.authority);
        },
    }
}

fn return_condition_is_immediate(condition: ReturnCondition) bool {
    return switch (condition) {
        .started => true,
        .exit, .quiet, .match => false,
    };
}

fn valid_bounded_text(text: []const u8, maximum: usize) bool {
    return text.len > 0 and text.len <= maximum and
        std.mem.findScalar(u8, text, 0) == null;
}

pub fn validate_session_id(session_id: []const u8) error{InvalidSessionId}!void {
    session_layout.validateSessionId(session_id) catch
        return error.InvalidSessionId;
}

pub const RawCursor = struct {
    segment: u64,
    offset: u64,

    pub fn validate(self: RawCursor) error{InvalidRawCursor}!void {
        if (self.segment == 0) return error.InvalidRawCursor;
    }
};

pub fn compare_raw_cursors(a: RawCursor, b: RawCursor) std.math.Order {
    const segment_order = std.math.order(a.segment, b.segment);
    if (segment_order != .eq) return segment_order;
    return std.math.order(a.offset, b.offset);
}

pub const RawRange = struct {
    start: RawCursor,
    end: RawCursor,

    pub fn validate(self: RawRange) error{InvalidRawRange}!void {
        self.start.validate() catch return error.InvalidRawRange;
        self.end.validate() catch return error.InvalidRawRange;
        if (self.start.segment != self.end.segment or
            compare_raw_cursors(self.start, self.end) == .gt)
        {
            return error.InvalidRawRange;
        }
    }
};

pub const RawGap = struct {
    missing_from: RawCursor,
    available_from: RawCursor,

    pub fn validate(self: RawGap) error{InvalidRawGap}!void {
        self.missing_from.validate() catch return error.InvalidRawGap;
        self.available_from.validate() catch return error.InvalidRawGap;
        if (compare_raw_cursors(self.missing_from, self.available_from) != .lt) {
            return error.InvalidRawGap;
        }
    }
};

pub const Dimensions = struct {
    rows: u16,
    columns: u16,

    pub fn validate(self: Dimensions) error{InvalidDimensions}!void {
        if (self.rows == 0 or self.columns == 0 or
            self.rows > max_dimension or self.columns > max_dimension)
        {
            return error.InvalidDimensions;
        }
    }
};

pub const RenderCursor = struct {
    row: u16,
    column: u16,
    visible: bool = true,
    shape: CursorShape = .block,
    blinking: bool = true,
};

pub const CursorShape = enum {
    block,
    underline,
    bar,
};

pub const TerminalModes = struct {
    alternate_screen: bool = false,
    origin: bool = false,
    autowrap: bool = true,
    insert: bool = false,
    bracketed_paste: bool = false,
    mouse_tracking: bool = false,
    focus_tracking: bool = false,
    application_cursor_keys: bool = false,
    application_keypad: bool = false,
    keyboard_protocol: bool = false,
    synchronized_updates: bool = false,
};

pub const CellColor = union(enum) {
    default,
    indexed: u8,
    rgb: struct {
        red: u8,
        green: u8,
        blue: u8,
    },
};

pub const CellStyle = struct {
    foreground: CellColor = .default,
    background: CellColor = .default,
    bold: bool = false,
    faint: bool = false,
    italic: bool = false,
    underline: bool = false,
    inverse: bool = false,
    strikethrough: bool = false,
};

pub const CellKind = enum {
    blank,
    single,
    wide,
    continuation,
};

pub const RenderCell = struct {
    kind: CellKind = .blank,
    text: []const u8 = "",
    style: CellStyle = .{},
};

pub const max_render_cells: usize =
    max_render_snapshot_bytes / @sizeOf(RenderCell);

/// Immutable row-major cell-grid projection. The producer retains ownership
/// of `cells` and each cell's UTF-8 `text`.
pub const RenderSnapshot = struct {
    dimensions: Dimensions,
    cursor: RenderCursor,
    modes: TerminalModes = .{},
    cells: []const RenderCell,

    pub fn validate(self: RenderSnapshot) error{
        InvalidDimensions,
        InvalidRenderSnapshot,
        InvalidRenderCell,
        RenderSnapshotTooLarge,
    }!void {
        try self.dimensions.validate();
        if (self.cursor.row >= self.dimensions.rows or
            self.cursor.column >= self.dimensions.columns)
        {
            return error.InvalidRenderSnapshot;
        }

        const cell_count = std.math.mul(
            usize,
            @intCast(self.dimensions.rows),
            @intCast(self.dimensions.columns),
        ) catch return error.RenderSnapshotTooLarge;
        if (cell_count > max_render_cells) return error.RenderSnapshotTooLarge;
        if (cell_count != self.cells.len) return error.InvalidRenderSnapshot;

        var total_bytes = std.math.mul(
            usize,
            self.cells.len,
            @sizeOf(RenderCell),
        ) catch return error.RenderSnapshotTooLarge;
        for (self.cells, 0..) |cell, index| {
            if (cell.text.len > max_cell_text_bytes) {
                return error.RenderSnapshotTooLarge;
            }
            total_bytes = std.math.add(
                usize,
                total_bytes,
                cell.text.len,
            ) catch return error.RenderSnapshotTooLarge;
            if (total_bytes > max_render_snapshot_bytes) {
                return error.RenderSnapshotTooLarge;
            }

            switch (cell.kind) {
                .blank, .continuation => {
                    if (cell.text.len != 0) return error.InvalidRenderCell;
                },
                .single, .wide => {
                    if (cell.text.len == 0 or
                        !std.unicode.utf8ValidateSlice(cell.text))
                    {
                        return error.InvalidRenderCell;
                    }
                },
            }

            const column = index % @as(usize, self.dimensions.columns);
            switch (cell.kind) {
                .wide => {
                    if (column + 1 >= @as(usize, self.dimensions.columns) or
                        self.cells[index + 1].kind != .continuation)
                    {
                        return error.InvalidRenderCell;
                    }
                },
                .continuation => {
                    if (column == 0 or self.cells[index - 1].kind != .wide) {
                        return error.InvalidRenderCell;
                    }
                },
                .blank, .single => {},
            }
        }
        if (total_bytes > max_render_snapshot_bytes) {
            return error.RenderSnapshotTooLarge;
        }
    }
};

/// Owned immutable snapshot copy. The caller frees it with `deinit` using the
/// allocator passed to `init`.
pub const OwnedRenderSnapshot = struct {
    dimensions: Dimensions,
    cursor: RenderCursor,
    modes: TerminalModes,
    cells: []RenderCell,
    text_storage: []u8,

    pub fn init(
        alloc: Allocator,
        snapshot: RenderSnapshot,
    ) (Allocator.Error || error{
        InvalidDimensions,
        InvalidRenderSnapshot,
        InvalidRenderCell,
        RenderSnapshotTooLarge,
    })!OwnedRenderSnapshot {
        try snapshot.validate();

        var text_bytes: usize = 0;
        for (snapshot.cells) |cell| {
            text_bytes = std.math.add(usize, text_bytes, cell.text.len) catch
                return error.RenderSnapshotTooLarge;
        }

        const cells = try alloc.alloc(RenderCell, snapshot.cells.len);
        errdefer alloc.free(cells);
        const text_storage = try alloc.alloc(u8, text_bytes);
        errdefer alloc.free(text_storage);

        var offset: usize = 0;
        for (snapshot.cells, 0..) |cell, index| {
            const end = offset + cell.text.len;
            @memcpy(text_storage[offset..end], cell.text);
            cells[index] = .{
                .kind = cell.kind,
                .text = text_storage[offset..end],
                .style = cell.style,
            };
            offset = end;
        }

        return .{
            .dimensions = snapshot.dimensions,
            .cursor = snapshot.cursor,
            .modes = snapshot.modes,
            .cells = cells,
            .text_storage = text_storage,
        };
    }

    pub fn view(self: *const OwnedRenderSnapshot) RenderSnapshot {
        return .{
            .dimensions = self.dimensions,
            .cursor = self.cursor,
            .modes = self.modes,
            .cells = self.cells,
        };
    }

    pub fn deinit(self: *OwnedRenderSnapshot, alloc: Allocator) void {
        alloc.free(self.cells);
        alloc.free(self.text_storage);
        self.* = undefined;
    }
};

pub const CheckpointChecksum = [std.crypto.hash.sha2.Sha256.digest_length]u8;

pub fn checkpoint_checksum(payload: []const u8) CheckpointChecksum {
    var checksum: CheckpointChecksum = undefined;
    std.crypto.hash.sha2.Sha256.hash(payload, &checksum, .{});
    return checksum;
}

pub const CheckpointEnvelope = struct {
    engine_schema_revision: u16,
    applied_cursor: RawCursor,
    payload_len: u32,
    checksum: CheckpointChecksum,

    pub fn validate_header(self: CheckpointEnvelope) error{
        InvalidCheckpoint,
        CheckpointTooLarge,
    }!void {
        if (self.engine_schema_revision == 0 or self.payload_len == 0) {
            return error.InvalidCheckpoint;
        }
        self.applied_cursor.validate() catch return error.InvalidCheckpoint;
        if (self.payload_len > max_checkpoint_payload_bytes) {
            return error.CheckpointTooLarge;
        }
    }

    pub fn validate(
        self: CheckpointEnvelope,
        payload: []const u8,
    ) error{
        InvalidCheckpoint,
        CheckpointTooLarge,
        CheckpointChecksumMismatch,
    }!void {
        try self.validate_header();
        const payload_len = std.math.cast(u32, payload.len) orelse
            return error.CheckpointTooLarge;
        if (payload_len != self.payload_len) return error.InvalidCheckpoint;
        const actual = checkpoint_checksum(payload);
        if (!std.mem.eql(u8, &self.checksum, &actual)) {
            return error.CheckpointChecksumMismatch;
        }
    }
};

pub const ScreenUnavailableReason = enum {
    missing,
    corrupt,
    unsupported_schema,
    retention_evicted,
    raw_gap,
    resize_uncheckpointed,
};

pub const ScreenRecovery = union(enum) {
    available: CheckpointEnvelope,
    unavailable: ScreenUnavailableReason,
};

pub fn validate_checkpoint_anchor(
    checkpoint: CheckpointEnvelope,
    output_cursor: RawCursor,
) error{
    InvalidCheckpoint,
    CheckpointTooLarge,
}!void {
    try checkpoint.validate_header();
    output_cursor.validate() catch return error.InvalidCheckpoint;
    if (checkpoint.applied_cursor.segment != output_cursor.segment or
        checkpoint.applied_cursor.offset > output_cursor.offset)
    {
        return error.InvalidCheckpoint;
    }
}

pub const TransportRole = enum {
    interactive,
    headless,
    acp,
};

pub const TerminalLifetime = enum {
    session,
};

pub const Principal = struct {
    profile_user: []const u8,
    durable_session_id: []const u8,
    workspace_root: []const u8,
    cwd: []const u8,
    transport_role: TransportRole,
    backend: Backend,
    lifetime: TerminalLifetime = .session,

    pub fn validate(self: Principal) error{
        InvalidPrincipal,
        InvalidSessionId,
    }!void {
        try validate_authority_text(self.profile_user);
        try validate_session_id(self.durable_session_id);
        try validate_authority_text(self.workspace_root);
        try validate_authority_text(self.cwd);
    }

    pub fn eql(self: Principal, other: Principal) bool {
        return std.mem.eql(u8, self.profile_user, other.profile_user) and
            std.mem.eql(u8, self.durable_session_id, other.durable_session_id) and
            std.mem.eql(u8, self.workspace_root, other.workspace_root) and
            std.mem.eql(u8, self.cwd, other.cwd) and
            self.transport_role == other.transport_role and
            self.backend == other.backend and
            self.lifetime == other.lifetime;
    }
};

pub const OwnerCatalogPrincipal = struct {
    profile_user: []const u8,
    durable_session_id: []const u8,
    workspace_root: []const u8,
    transport_role: TransportRole,

    pub fn validate(self: OwnerCatalogPrincipal) error{
        InvalidPrincipal,
        InvalidSessionId,
    }!void {
        try validate_authority_text(self.profile_user);
        try validate_session_id(self.durable_session_id);
        try validate_authority_text(self.workspace_root);
        if (!std.fs.path.isAbsolute(self.workspace_root)) {
            return error.InvalidPrincipal;
        }
    }

    pub fn eql(self: OwnerCatalogPrincipal, other: OwnerCatalogPrincipal) bool {
        return std.mem.eql(u8, self.profile_user, other.profile_user) and
            std.mem.eql(u8, self.durable_session_id, other.durable_session_id) and
            std.mem.eql(u8, self.workspace_root, other.workspace_root) and
            self.transport_role == other.transport_role;
    }
};

pub const OwnerCatalogProof = struct {
    bytes: [32]u8,

    pub fn validate(self: OwnerCatalogProof) error{InvalidHolderProof}!void {
        if (std.mem.allEqual(u8, &self.bytes, 0)) return error.InvalidHolderProof;
    }
};

pub const OwnerCatalogAuthorityClaim = struct {
    principal: OwnerCatalogPrincipal,
    actor: ActorRole,
    proof: OwnerCatalogProof,

    pub fn validate(self: OwnerCatalogAuthorityClaim) error{
        InvalidPrincipal,
        InvalidSessionId,
        InvalidAuthorityClaim,
    }!void {
        try self.principal.validate();
        self.proof.validate() catch return error.InvalidAuthorityClaim;
    }
};

fn validate_authority_text(text: []const u8) error{InvalidPrincipal}!void {
    if (text.len == 0 or text.len > max_authority_text_bytes or
        std.mem.findScalar(u8, text, 0) != null)
    {
        return error.InvalidPrincipal;
    }
}

pub const AllowedControls = packed struct {
    read: bool = false,
    screen: bool = false,
    write: bool = false,
    wait: bool = false,
    monitor: bool = false,
    inspect: bool = false,
    list: bool = false,
    resize: bool = false,
    signal: bool = false,
    close: bool = false,

    pub fn observer() AllowedControls {
        return .{
            .read = true,
            .screen = true,
            .inspect = true,
            .list = true,
        };
    }

    pub fn full() AllowedControls {
        return .{
            .read = true,
            .screen = true,
            .write = true,
            .wait = true,
            .inspect = true,
            .list = true,
            .resize = true,
            .signal = true,
            .close = true,
        };
    }

    pub fn humanTakeover() AllowedControls {
        return .{
            .screen = true,
            .write = true,
            .resize = true,
        };
    }

    pub fn any(self: AllowedControls) bool {
        return self.read or
            self.screen or
            self.write or
            self.wait or
            self.monitor or
            self.inspect or
            self.list or
            self.resize or
            self.signal or
            self.close;
    }

    pub fn allows(self: AllowedControls, action: Action) bool {
        return switch (action) {
            .start => false,
            .read => self.read,
            .screen => self.screen,
            .write => self.write,
            .wait => self.wait,
            .inspect => self.inspect,
            .list => self.list,
            .resize => self.resize,
            .signal => self.signal,
            .close => self.close,
        };
    }
};

pub fn intersect_controls(
    left: AllowedControls,
    right: AllowedControls,
) AllowedControls {
    return .{
        .read = left.read and right.read,
        .screen = left.screen and right.screen,
        .write = left.write and right.write,
        .wait = left.wait and right.wait,
        .monitor = left.monitor and right.monitor,
        .inspect = left.inspect and right.inspect,
        .list = left.list and right.list,
        .resize = left.resize and right.resize,
        .signal = left.signal and right.signal,
        .close = left.close and right.close,
    };
}

pub fn lifecycle_controls(lifecycle: Lifecycle) AllowedControls {
    return switch (lifecycle) {
        .starting, .running => .{
            .read = true,
            .screen = true,
            .write = true,
            .wait = true,
            .inspect = true,
            .list = true,
            .resize = true,
            .signal = true,
            .close = true,
        },
        .exited, .lost => .{
            .read = true,
            .screen = true,
            .wait = true,
            .inspect = true,
            .list = true,
            .close = true,
        },
        .closed => .{
            .read = true,
            .screen = true,
            .inspect = true,
            .list = true,
        },
    };
}

pub fn project_next_actions(
    lifecycle: Lifecycle,
    granted: AllowedControls,
    actor: ActorRole,
    attention: AttentionState,
) AllowedControls {
    var projected = intersect_controls(lifecycle_controls(lifecycle), granted);
    const lease = switch (actor) {
        .human => WriteLease.human,
        .agent => WriteLease.agent,
    };
    if (attention.write_lease != .none and attention.write_lease != lease) {
        projected.write = false;
    }
    return projected;
}

pub const HolderProof = struct {
    bytes: [32]u8,

    pub fn validate(self: HolderProof) error{InvalidHolderProof}!void {
        for (self.bytes) |byte| {
            if (byte != 0) return;
        }
        return error.InvalidHolderProof;
    }
};

pub const AuthorityGeneration = struct {
    value: u64,

    pub fn init(value: u64) error{InvalidAuthorityGeneration}!AuthorityGeneration {
        if (value == 0) return error.InvalidAuthorityGeneration;
        return .{ .value = value };
    }

    pub fn validate(
        self: AuthorityGeneration,
    ) error{InvalidAuthorityGeneration}!void {
        if (self.value == 0) return error.InvalidAuthorityGeneration;
    }

    pub fn next(
        self: AuthorityGeneration,
    ) error{
        InvalidAuthorityGeneration,
        AuthorityGenerationExhausted,
    }!AuthorityGeneration {
        try self.validate();
        return .{
            .value = std.math.add(u64, self.value, 1) catch
                return error.AuthorityGenerationExhausted,
        };
    }
};

pub const AuthorityGrant = struct {
    principal: Principal,
    actor: ActorRole,
    controls: AllowedControls,
    generation: AuthorityGeneration,
    repeated_probes: []const RepeatedProbeAuthority = &.{},

    pub fn validate(self: AuthorityGrant) error{
        InvalidPrincipal,
        InvalidSessionId,
        InvalidAuthorityGeneration,
        InvalidAuthorityGrant,
    }!void {
        try self.principal.validate();
        try self.generation.validate();
        if (!self.controls.any()) return error.InvalidAuthorityGrant;
        if (self.repeated_probes.len > max_monitor_definitions or
            (self.repeated_probes.len != 0 and !self.controls.monitor))
        {
            return error.InvalidAuthorityGrant;
        }
        for (self.repeated_probes) |probe| probe.validate() catch
            return error.InvalidAuthorityGrant;
    }
};

pub const RepeatedProbeAuthority = struct {
    command: []const u8,
    cwd: []const u8,
    check_schedule: PollSchedule,
    notify_schedule: NotifySchedule,
    lifetime: MonitorLifetime,

    pub fn validate(self: RepeatedProbeAuthority) !void {
        if (!valid_bounded_text(self.command, max_command_bytes) or
            !valid_bounded_text(self.cwd, max_authority_text_bytes) or
            !std.fs.path.isAbsolute(self.cwd))
        {
            return error.InvalidProbeAuthority;
        }
        try self.check_schedule.validate();
        try self.notify_schedule.validate();
        try self.lifetime.validate();
    }
};

pub const AuthorityClaim = struct {
    principal: Principal,
    actor: ActorRole,
    generation: AuthorityGeneration,
    proof: HolderProof,
    process_owner: ?ProcessOwner = null,

    pub fn jsonStringify(self: AuthorityClaim, writer: anytype) !void {
        try writer.beginObject();
        try writer.objectField("principal");
        try writer.write(self.principal);
        try writer.objectField("actor");
        try writer.write(self.actor);
        try writer.objectField("generation");
        try writer.write(self.generation);
        try writer.objectField("proof");
        try writer.write(self.proof);
        try writer.endObject();
    }

    pub fn validate(self: AuthorityClaim) error{
        InvalidPrincipal,
        InvalidSessionId,
        InvalidAuthorityGeneration,
        InvalidAuthorityClaim,
    }!void {
        try self.principal.validate();
        try self.generation.validate();
        self.proof.validate() catch return error.InvalidAuthorityClaim;
        if (self.process_owner) |owner| {
            owner.validate() catch return error.InvalidAuthorityClaim;
        }
    }
};

pub const ProcessOwner = struct {
    pid: i32,
    process_token: [128]u8 = @splat(0),
    process_token_len: u8,

    pub fn init(pid: i32, token_text: []const u8) error{InvalidProcessOwner}!ProcessOwner {
        if (pid <= 0 or token_text.len == 0 or token_text.len > 128) {
            return error.InvalidProcessOwner;
        }
        var owner = ProcessOwner{
            .pid = pid,
            .process_token_len = @intCast(token_text.len),
        };
        @memcpy(owner.process_token[0..token_text.len], token_text);
        return owner;
    }

    pub fn validate(self: ProcessOwner) error{InvalidProcessOwner}!void {
        if (self.pid <= 0 or self.process_token_len == 0 or
            self.process_token_len > self.process_token.len)
        {
            return error.InvalidProcessOwner;
        }
    }

    pub fn token(self: *const ProcessOwner) []const u8 {
        return self.process_token[0..self.process_token_len];
    }
};

pub const ProtocolRange = struct {
    minimum: u16,
    current: u16,

    pub fn validate(self: ProtocolRange) error{InvalidProtocolRange}!void {
        if (self.minimum == 0 or self.minimum > self.current) {
            return error.InvalidProtocolRange;
        }
    }
};

pub const local_protocol_range = ProtocolRange{
    .minimum = previous_protocol_revision,
    .current = current_protocol_revision,
};

pub const ProtocolHello = struct {
    range: ProtocolRange,
    capabilities: u64,
    required_capabilities: u64 = 0,

    pub fn validate(self: ProtocolHello) error{
        InvalidProtocolRange,
        UnknownRequiredCapability,
        InvalidRequiredCapabilities,
    }!void {
        try self.range.validate();
        if (self.required_capabilities & ~known_protocol_capabilities != 0) {
            return error.UnknownRequiredCapability;
        }
        if (self.required_capabilities & ~self.capabilities != 0) {
            return error.InvalidRequiredCapabilities;
        }
    }
};

pub const IncompatibilityReason = enum {
    revision_mismatch,
    required_capability_missing,
};

pub const ProtocolIncompatibility = struct {
    reason: IncompatibilityReason,
    client_range: ProtocolRange,
    host_range: ProtocolRange,
    missing_capabilities: u64 = 0,
};

pub const NegotiatedProtocol = struct {
    revision: u16,
    capabilities: u64,
};

pub const Negotiation = union(enum) {
    compatible: NegotiatedProtocol,
    incompatible: ProtocolIncompatibility,
};

pub fn negotiate_protocol(
    client: ProtocolHello,
    host: ProtocolHello,
) error{
    InvalidProtocolRange,
    UnknownRequiredCapability,
    InvalidRequiredCapabilities,
}!Negotiation {
    try client.validate();
    try host.validate();

    const missing_for_host = host.required_capabilities & ~client.capabilities;
    const missing_for_client = client.required_capabilities & ~host.capabilities;
    const missing = missing_for_host | missing_for_client;
    if (missing != 0) {
        return .{ .incompatible = .{
            .reason = .required_capability_missing,
            .client_range = client.range,
            .host_range = host.range,
            .missing_capabilities = missing,
        } };
    }

    const minimum = @max(client.range.minimum, host.range.minimum);
    const current = @min(client.range.current, host.range.current);
    if (minimum > current) {
        return .{ .incompatible = .{
            .reason = .revision_mismatch,
            .client_range = client.range,
            .host_range = host.range,
        } };
    }

    return .{ .compatible = .{
        .revision = current,
        .capabilities = client.capabilities &
            host.capabilities &
            known_protocol_capabilities,
    } };
}

pub const CorrelationId = struct {
    value: u64,

    pub fn init(value: u64) error{InvalidCorrelationId}!CorrelationId {
        if (value == 0) return error.InvalidCorrelationId;
        return .{ .value = value };
    }

    pub fn validate(self: CorrelationId) error{InvalidCorrelationId}!void {
        if (self.value == 0) return error.InvalidCorrelationId;
    }
};

pub const HostEvent = enum {
    lifecycle,
    output,
    screen_recovery,
    authority_revoked,
};

pub const MessageKind = union(enum) {
    hello,
    request: Action,
    response: Action,
    cancel,
};

pub const MessageEnvelopeValidationError = error{
    UnsupportedProtocolRevision,
    UnknownRequiredCapability,
    HostFrameTooLarge,
    InvalidHostFrame,
    InvalidCorrelationId,
    MissingCorrelationId,
    UnexpectedCorrelationId,
};

pub const MessageEnvelope = struct {
    revision: u16,
    kind: MessageKind,
    required_capabilities: u64 = 0,
    correlation_id: ?CorrelationId = null,
    payload_len: u32,

    pub fn validate(
        self: MessageEnvelope,
        actual_payload_len: usize,
    ) MessageEnvelopeValidationError!void {
        const minimum_revision = switch (self.kind) {
            .hello => oldest_hello_revision,
            .request, .response, .cancel => previous_protocol_revision,
        };
        if (self.revision < minimum_revision or
            self.revision > current_protocol_revision)
        {
            return error.UnsupportedProtocolRevision;
        }
        if (self.required_capabilities & ~known_protocol_capabilities != 0) {
            return error.UnknownRequiredCapability;
        }
        if (self.payload_len > max_host_frame_bytes or
            actual_payload_len > max_host_frame_bytes)
        {
            return error.HostFrameTooLarge;
        }
        const actual = std.math.cast(u32, actual_payload_len) orelse
            return error.HostFrameTooLarge;
        if (self.payload_len != actual) return error.InvalidHostFrame;

        switch (self.kind) {
            .hello => {
                if (self.correlation_id != null) {
                    return error.UnexpectedCorrelationId;
                }
            },
            .request, .response, .cancel => {
                const correlation_id = self.correlation_id orelse
                    return error.MissingCorrelationId;
                try correlation_id.validate();
            },
        }
    }
};

pub const MessagePayloadValidationError =
    RequestValidationError ||
    ResultValidationError ||
    error{
        InvalidProtocolRange,
        UnknownRequiredCapability,
        InvalidRequiredCapabilities,
        MessageKindMismatch,
    };

pub const MessagePayload = union(enum) {
    hello: ProtocolHello,
    request: ActionRequest,
    response: Result,
    cancel,

    pub fn validate(
        self: MessagePayload,
        kind: MessageKind,
    ) MessagePayloadValidationError!void {
        switch (self) {
            .hello => |hello| switch (kind) {
                .hello => try hello.validate(),
                .request, .response, .cancel => return error.MessageKindMismatch,
            },
            .request => |request| switch (kind) {
                .request => |action| {
                    if (request.action() != action) return error.MessageKindMismatch;
                    try request.validate();
                },
                .hello, .response, .cancel => return error.MessageKindMismatch,
            },
            .response => |result| switch (kind) {
                .response => |action| {
                    if (result.action() != action) return error.MessageKindMismatch;
                    try result.validate();
                },
                .hello, .request, .cancel => return error.MessageKindMismatch,
            },
            .cancel => switch (kind) {
                .cancel => {},
                .hello, .request, .response => return error.MessageKindMismatch,
            },
        }
    }
};

pub const HostMessageValidationError =
    MessageEnvelopeValidationError ||
    MessagePayloadValidationError;

/// Typed semantic host message paired with its bounded wire envelope.
pub const HostMessage = struct {
    envelope: MessageEnvelope,
    payload: MessagePayload,

    pub fn validate(
        self: HostMessage,
        actual_payload_len: usize,
    ) HostMessageValidationError!void {
        try self.envelope.validate(actual_payload_len);
        try self.payload.validate(self.envelope.kind);
    }
};

pub const StructuredErrorCode = enum {
    invalid_request,
    path_outside_workspace,
    unsupported_host,
    shell_unavailable,
    pty_unavailable,
    startup_failed,
    process_identity_unavailable,
    session_lost,
    session_not_found,
    invalid_lifecycle,
    authority_denied,
    authority_retired,
    lease_conflict,
    cursor_gap,
    screen_unavailable,
    protocol_incompatible,
    capacity_exceeded,
    cancelled,
};

pub const StructuredError = struct {
    action: Action,
    code: StructuredErrorCode,
    session_id: ?[]const u8 = null,
    retryable: bool = false,

    pub fn validate(self: StructuredError) error{InvalidSessionId}!void {
        if (self.session_id) |session_id| try validate_session_id(session_id);
    }
};

pub const SessionFacts = struct {
    session_id: []const u8,
    lifecycle: Lifecycle,
    attention: AttentionState,
    backend: Backend,
    persistence: PersistenceLevel = .durable,
    model_managed: bool = true,
    timed_out: bool = false,
    output_cursor: RawCursor,
    unread_range: ?RawRange = null,
    raw_gap: ?RawGap = null,
    screen_recovery: ScreenRecovery,
    next_actions: AllowedControls = .{},

    pub fn validate(self: SessionFacts) error{
        InvalidSessionId,
        InvalidAttentionState,
        InvalidRawCursor,
        InvalidRawRange,
        InvalidRawGap,
        InvalidCheckpoint,
        CheckpointTooLarge,
    }!void {
        try validate_session_id(self.session_id);
        try self.attention.validate();
        try self.output_cursor.validate();
        if (self.unread_range) |range| {
            try range.validate();
            if (compare_raw_cursors(range.end, self.output_cursor) == .gt) {
                return error.InvalidRawRange;
            }
        }
        if (self.raw_gap) |gap| {
            try gap.validate();
            if (compare_raw_cursors(gap.available_from, self.output_cursor) == .gt) {
                return error.InvalidRawGap;
            }
        }
        switch (self.screen_recovery) {
            .available => |checkpoint| try validate_checkpoint_anchor(
                checkpoint,
                self.output_cursor,
            ),
            .unavailable => {},
        }
    }
};

pub const ReadResult = struct {
    session: SessionFacts,
    output: []const u8 = "",
    raw_range: ?RawRange = null,
};

pub const ScreenResult = struct {
    session: SessionFacts,
    snapshot: RenderSnapshot,
};

pub const WriteResult = struct {
    session: SessionFacts,
    accepted_bytes: u32,
};

pub const ReturnOutcomeValidationError = error{InvalidReturnOutcome};

pub const ReturnOutcome = union(enum) {
    started,
    condition_met,
    safety_ceiling,
    cancelled,
    exited: i32,
    signal: u32,

    pub fn validate(self: ReturnOutcome) ReturnOutcomeValidationError!void {
        switch (self) {
            .started, .condition_met, .safety_ceiling, .cancelled => {},
            .exited => |exit_code| {
                if (exit_code < 0 or exit_code > std.math.maxInt(u8)) {
                    return error.InvalidReturnOutcome;
                }
            },
            .signal => |signal| {
                if (signal == 0 or signal > std.math.maxInt(u8)) {
                    return error.InvalidReturnOutcome;
                }
            },
        }
    }
};

pub const StartResult = struct {
    session: SessionFacts,
    outcome: ReturnOutcome,
};

pub const WaitResult = struct {
    session: SessionFacts,
    outcome: ReturnOutcome,
};

pub const InspectResult = struct {
    session: SessionFacts,
    shell: []const u8,
    cwd: []const u8,
    command: ?[]const u8 = null,
};

pub const ListResult = struct {
    sessions: []const SessionFacts,
};

pub const ResizeResult = struct {
    session: SessionFacts,
    dimensions: Dimensions,
};

pub const SignalResult = struct {
    session: SessionFacts,
    signal: Signal,
};

pub const CloseResult = struct {
    session: SessionFacts,
    policy: ClosePolicy,
};

pub const ResultValidationError = error{
    InvalidResult,
    InvalidSessionId,
    InvalidAttentionState,
    InvalidRawCursor,
    InvalidRawRange,
    InvalidRawGap,
    InvalidCheckpoint,
    CheckpointTooLarge,
    InvalidDimensions,
    InvalidRenderSnapshot,
    InvalidRenderCell,
    RenderSnapshotTooLarge,
    HostFrameTooLarge,
    InvalidReturnOutcome,
};

pub const ActionResult = union(enum) {
    start: StartResult,
    read: ReadResult,
    screen: ScreenResult,
    write: WriteResult,
    wait: WaitResult,
    inspect: InspectResult,
    list: ListResult,
    resize: ResizeResult,
    signal: SignalResult,
    close: CloseResult,

    pub fn action(self: ActionResult) Action {
        return switch (self) {
            .start => .start,
            .read => .read,
            .screen => .screen,
            .write => .write,
            .wait => .wait,
            .inspect => .inspect,
            .list => .list,
            .resize => .resize,
            .signal => .signal,
            .close => .close,
        };
    }

    pub fn validate(self: ActionResult) ResultValidationError!void {
        switch (self) {
            .start => |value| {
                try value.session.validate();
                try value.outcome.validate();
            },
            .read => |value| {
                try value.session.validate();
                if (value.output.len > max_host_frame_bytes) {
                    return error.HostFrameTooLarge;
                }
                if (value.raw_range) |range| {
                    try range.validate();
                    if (compare_raw_cursors(
                        range.end,
                        value.session.output_cursor,
                    ) == .gt) {
                        return error.InvalidRawRange;
                    }
                }
            },
            .screen => |value| {
                try value.session.validate();
                try value.snapshot.validate();
            },
            .write => |value| {
                try value.session.validate();
                if (value.accepted_bytes > max_write_bytes) {
                    return error.InvalidResult;
                }
            },
            .wait => |value| {
                try value.session.validate();
                try value.outcome.validate();
            },
            .inspect => |value| {
                try value.session.validate();
                if (!valid_bounded_text(value.shell, max_shell_path_bytes) or
                    !valid_bounded_text(value.cwd, max_authority_text_bytes))
                {
                    return error.InvalidResult;
                }
                if (value.command) |command| {
                    if (!valid_bounded_text(command, max_command_bytes)) {
                        return error.InvalidResult;
                    }
                }
            },
            .list => |value| {
                if (value.sessions.len > max_list_results) {
                    return error.InvalidResult;
                }
                for (value.sessions) |session| try session.validate();
            },
            .resize => |value| {
                try value.session.validate();
                try value.dimensions.validate();
            },
            .signal => |value| try value.session.validate(),
            .close => |value| try value.session.validate(),
        }
    }
};

pub const Result = union(enum) {
    success: ActionResult,
    failure: StructuredError,

    pub fn action(self: Result) Action {
        return switch (self) {
            .success => |success| success.action(),
            .failure => |failure| failure.action,
        };
    }

    pub fn validate(self: Result) ResultValidationError!void {
        switch (self) {
            .success => |success| try success.validate(),
            .failure => |failure| try failure.validate(),
        }
    }
};

pub const OwnedScreenResult = struct {
    session: SessionFacts,
    snapshot: OwnedRenderSnapshot,
};

pub const OwnedSuccessResult = union(enum) {
    start: StartResult,
    read: ReadResult,
    screen: OwnedScreenResult,
    write: WriteResult,
    wait: WaitResult,
    inspect: InspectResult,
    list: ListResult,
    resize: ResizeResult,
    signal: SignalResult,
    close: CloseResult,

    fn view(self: *const OwnedSuccessResult) ActionResult {
        return switch (self.*) {
            .start => |value| .{ .start = value },
            .read => |value| .{ .read = value },
            .screen => |*value| .{ .screen = .{
                .session = value.session,
                .snapshot = value.snapshot.view(),
            } },
            .write => |value| .{ .write = value },
            .wait => |value| .{ .wait = value },
            .inspect => |value| .{ .inspect = value },
            .list => |value| .{ .list = value },
            .resize => |value| .{ .resize = value },
            .signal => |value| .{ .signal = value },
            .close => |value| .{ .close = value },
        };
    }
};

/// Owned semantic result. The caller frees every copied external value with
/// `deinit` using the allocator passed to `init`.
pub const OwnedResult = union(enum) {
    success: OwnedSuccessResult,
    failure: StructuredError,

    pub fn init(
        alloc: Allocator,
        result: Result,
    ) (Allocator.Error || ResultValidationError)!OwnedResult {
        try result.validate();
        return switch (result) {
            .success => |success| .{
                .success = try clone_success_result(alloc, success),
            },
            .failure => |failure| .{
                .failure = .{
                    .action = failure.action,
                    .code = failure.code,
                    .session_id = if (failure.session_id) |session_id|
                        try alloc.dupe(u8, session_id)
                    else
                        null,
                    .retryable = failure.retryable,
                },
            },
        };
    }

    pub fn view(self: *const OwnedResult) Result {
        return switch (self.*) {
            .success => |*success| .{ .success = success.view() },
            .failure => |failure| .{ .failure = failure },
        };
    }

    pub fn deinit(self: *OwnedResult, alloc: Allocator) void {
        switch (self.*) {
            .success => |*success| deinit_success_result(alloc, success),
            .failure => |failure| {
                if (failure.session_id) |session_id| alloc.free(session_id);
            },
        }
        self.* = undefined;
    }
};

fn clone_success_result(
    alloc: Allocator,
    result: ActionResult,
) (Allocator.Error || ResultValidationError)!OwnedSuccessResult {
    return switch (result) {
        .start => |value| .{ .start = .{
            .session = try clone_session_facts(alloc, value.session),
            .outcome = value.outcome,
        } },
        .read => |value| blk: {
            const session = try clone_session_facts(alloc, value.session);
            errdefer deinit_session_facts(alloc, session);
            break :blk .{ .read = .{
                .session = session,
                .output = try alloc.dupe(u8, value.output),
                .raw_range = value.raw_range,
            } };
        },
        .screen => |value| blk: {
            const session = try clone_session_facts(alloc, value.session);
            errdefer deinit_session_facts(alloc, session);
            break :blk .{ .screen = .{
                .session = session,
                .snapshot = try OwnedRenderSnapshot.init(alloc, value.snapshot),
            } };
        },
        .write => |value| .{ .write = .{
            .session = try clone_session_facts(alloc, value.session),
            .accepted_bytes = value.accepted_bytes,
        } },
        .wait => |value| .{ .wait = .{
            .session = try clone_session_facts(alloc, value.session),
            .outcome = value.outcome,
        } },
        .inspect => |value| .{
            .inspect = try clone_inspect_result(alloc, value),
        },
        .list => |value| .{ .list = .{
            .sessions = try clone_session_facts_slice(alloc, value.sessions),
        } },
        .resize => |value| .{ .resize = .{
            .session = try clone_session_facts(alloc, value.session),
            .dimensions = value.dimensions,
        } },
        .signal => |value| .{ .signal = .{
            .session = try clone_session_facts(alloc, value.session),
            .signal = value.signal,
        } },
        .close => |value| .{ .close = .{
            .session = try clone_session_facts(alloc, value.session),
            .policy = value.policy,
        } },
    };
}

fn clone_inspect_result(
    alloc: Allocator,
    result: InspectResult,
) Allocator.Error!InspectResult {
    const session = try clone_session_facts(alloc, result.session);
    errdefer deinit_session_facts(alloc, session);
    const shell = try alloc.dupe(u8, result.shell);
    errdefer alloc.free(shell);
    const cwd = try alloc.dupe(u8, result.cwd);
    errdefer alloc.free(cwd);
    const command = if (result.command) |value| try alloc.dupe(u8, value) else null;
    errdefer if (command) |value| alloc.free(value);
    return .{
        .session = session,
        .shell = shell,
        .cwd = cwd,
        .command = command,
    };
}

fn clone_session_facts(
    alloc: Allocator,
    facts: SessionFacts,
) Allocator.Error!SessionFacts {
    var owned = facts;
    owned.session_id = try alloc.dupe(u8, facts.session_id);
    return owned;
}

fn clone_session_facts_slice(
    alloc: Allocator,
    sessions: []const SessionFacts,
) Allocator.Error![]SessionFacts {
    const owned = try alloc.alloc(SessionFacts, sessions.len);
    var initialized: usize = 0;
    errdefer {
        for (owned[0..initialized]) |session| deinit_session_facts(alloc, session);
        alloc.free(owned);
    }
    for (sessions, 0..) |session, index| {
        owned[index] = try clone_session_facts(alloc, session);
        initialized += 1;
    }
    return owned;
}

fn deinit_session_facts(alloc: Allocator, facts: SessionFacts) void {
    alloc.free(facts.session_id);
}

fn deinit_session_facts_slice(
    alloc: Allocator,
    sessions: []const SessionFacts,
) void {
    for (sessions) |session| deinit_session_facts(alloc, session);
    alloc.free(sessions);
}

fn deinit_success_result(alloc: Allocator, result: *OwnedSuccessResult) void {
    switch (result.*) {
        .start => |value| deinit_session_facts(alloc, value.session),
        .read => |value| {
            deinit_session_facts(alloc, value.session);
            alloc.free(value.output);
        },
        .screen => |*value| {
            deinit_session_facts(alloc, value.session);
            value.snapshot.deinit(alloc);
        },
        .write => |value| deinit_session_facts(alloc, value.session),
        .wait => |value| deinit_session_facts(alloc, value.session),
        .inspect => |value| {
            deinit_session_facts(alloc, value.session);
            alloc.free(value.shell);
            alloc.free(value.cwd);
            if (value.command) |command| alloc.free(command);
        },
        .list => |value| deinit_session_facts_slice(alloc, value.sessions),
        .resize => |value| deinit_session_facts(alloc, value.session),
        .signal => |value| deinit_session_facts(alloc, value.session),
        .close => |value| deinit_session_facts(alloc, value.session),
    }
    result.* = undefined;
}

test "action requests own every accepted action input" {
    const requests = [_]ActionRequest{
        .{ .start = .{
            .cwd = "/workspace",
            .command = "zig build",
            .shell = .{ .executable = .{
                .path = "/bin/zsh",
                .clean_start = true,
            } },
            .backend = .native,
            .return_when = .{ .match = "Build Summary" },
            .wait_ceiling_ms = 30_000,
            .dimensions = .{ .rows = 24, .columns = 80 },
        } },
        .{ .read = .{
            .session_id = "terminal-1",
            .cursor = .{ .segment = 1, .offset = 4 },
        } },
        .{ .screen = .{ .session_id = "terminal-1" } },
        .{ .write = .{
            .session_id = "terminal-1",
            .payload = .{ .text = "hello" },
        } },
        .{ .wait = .{
            .session_id = "terminal-1",
            .return_when = .{ .quiet = 100 },
            .safety_ceiling_ms = 1_000,
        } },
        .{ .inspect = .{ .session_id = "terminal-1" } },
        .{ .list = .{
            .task_id = "task-1",
            .workspace_root = "/workspace",
            .lifecycle = .running,
            .backend = .native,
        } },
        .{ .resize = .{
            .session_id = "terminal-1",
            .dimensions = .{ .rows = 40, .columns = 120 },
        } },
        .{ .signal = .{
            .session_id = "terminal-1",
            .signal = .interrupt,
        } },
        .{ .close = .{
            .session_id = "terminal-1",
            .policy = .graceful,
        } },
    };

    for (requests, std.meta.tags(Action)) |request, action| {
        try std.testing.expectEqual(action, request.action());
        var owned = try OwnedActionRequest.init(std.testing.allocator, request);
        defer owned.deinit(std.testing.allocator);
        try std.testing.expectEqual(action, owned.value.action());
        try owned.value.validate();
    }
}

test "write requests own text keys controls and paste bytes" {
    const keys = [_]NamedKey{ .escape, .arrow_up, .enter };
    const controls = [_]ControlInput{
        .{ .character = 'c' },
        .{ .character = 'D' },
    };
    const payloads = [_]WritePayload{
        .{ .text = "text" },
        .{ .keys = &keys },
        .{ .controls = &controls },
        .{ .paste = &.{ 0, 1, 2, 3 } },
    };

    for (payloads) |payload| {
        var owned = try OwnedActionRequest.init(std.testing.allocator, .{
            .write = .{
                .session_id = "terminal-1",
                .payload = payload,
            },
        });
        defer owned.deinit(std.testing.allocator);
        try owned.value.validate();
    }
}

test "action request validation enforces binding and bounded input rules" {
    try (ActionRequest{ .start = .{ .cwd = "/workspace" } }).validate();
    try std.testing.expectError(
        error.InvalidCwd,
        (ActionRequest{ .start = .{ .cwd = "" } }).validate(),
    );
    try std.testing.expectError(
        error.InvalidCwd,
        (ActionRequest{ .start = .{ .cwd = "workspace" } }).validate(),
    );
    try std.testing.expectError(
        error.MissingReturnCondition,
        (ActionRequest{ .start = .{
            .cwd = "/workspace",
            .command = "zig build",
        } }).validate(),
    );
    try std.testing.expectError(
        error.MissingWaitCeiling,
        (ActionRequest{ .start = .{
            .cwd = "/workspace",
            .command = "zig build",
            .return_when = .exit,
        } }).validate(),
    );
    try std.testing.expectError(
        error.InvalidWaitCeiling,
        (ActionRequest{ .start = .{
            .cwd = "/workspace",
            .command = "zig build",
            .return_when = .exit,
            .wait_ceiling_ms = 0,
        } }).validate(),
    );
    try std.testing.expectError(
        error.InvalidShell,
        (ActionRequest{ .start = .{
            .cwd = "/workspace",
            .shell = .{ .executable = .{ .path = "" } },
        } }).validate(),
    );
    try std.testing.expectError(
        error.InvalidWaitCeiling,
        (ActionRequest{ .wait = .{
            .session_id = "terminal-1",
            .return_when = .exit,
            .safety_ceiling_ms = 0,
        } }).validate(),
    );
    try std.testing.expectError(
        error.InvalidRawCursor,
        (ActionRequest{ .read = .{
            .session_id = "terminal-1",
            .cursor = .{ .segment = 0, .offset = 0 },
        } }).validate(),
    );
    try std.testing.expectError(
        error.InvalidWritePayload,
        (ActionRequest{ .write = .{
            .session_id = "terminal-1",
            .payload = .{ .text = "" },
        } }).validate(),
    );
    try std.testing.expectError(
        error.InvalidWritePayload,
        (ActionRequest{ .write = .{
            .session_id = "terminal-1",
            .payload = .{ .controls = &.{
                .{ .character = '1' },
            } },
        } }).validate(),
    );
    try std.testing.expectError(
        error.InvalidListFilter,
        (ActionRequest{ .list = .{
            .workspace_root = "bad\x00workspace",
        } }).validate(),
    );
    try std.testing.expectError(
        error.InvalidDimensions,
        (ActionRequest{ .resize = .{
            .session_id = "terminal-1",
            .dimensions = .{ .rows = 0, .columns = 80 },
        } }).validate(),
    );
    try std.testing.expectError(
        error.InvalidSessionId,
        (ActionRequest{ .screen = .{ .session_id = "../terminal" } }).validate(),
    );
}

test "write payload presence follows the lease intent" {
    const cases = [_]struct {
        lease: WriteLeaseIntent,
        payload_present: bool,
        accepted: bool,
    }{
        .{ .lease = .acquire, .payload_present = false, .accepted = true },
        .{ .lease = .acquire, .payload_present = true, .accepted = false },
        .{ .lease = .use, .payload_present = false, .accepted = false },
        .{ .lease = .use, .payload_present = true, .accepted = true },
        .{ .lease = .release, .payload_present = false, .accepted = true },
        .{ .lease = .release, .payload_present = true, .accepted = false },
        .{ .lease = .revoke, .payload_present = false, .accepted = true },
        .{ .lease = .revoke, .payload_present = true, .accepted = false },
    };
    for (cases) |case| {
        try std.testing.expectEqual(case.accepted, write_payload_required(case.lease) == case.payload_present);
        const request = ActionRequest{ .write = .{
            .session_id = "terminal-1",
            .lease = case.lease,
            .payload = if (case.payload_present) .{ .text = "input" } else null,
        } };
        if (case.accepted) {
            try request.validate();
        } else {
            try std.testing.expectError(error.InvalidWritePayload, request.validate());
        }
    }
}

test "start persistence binds authority to cwd backend and a nonzero proof" {
    const persistence = StartPersistence{
        .grant = .{
            .principal = .{
                .profile_user = "profile-user",
                .durable_session_id = "session-owner",
                .workspace_root = "/workspace",
                .cwd = "/workspace",
                .transport_role = .interactive,
                .backend = .native,
            },
            .actor = .agent,
            .controls = .full(),
            .generation = .{ .value = 1 },
        },
        .proof = .{ .bytes = @splat(7) },
    };
    try (ActionRequest{ .start = .{
        .cwd = "/workspace",
        .persistence = persistence,
    } }).validate();
    try std.testing.expectError(
        error.InvalidStartPersistence,
        (ActionRequest{ .start = .{
            .cwd = "/other",
            .persistence = persistence,
        } }).validate(),
    );
    var wrong_backend = persistence;
    wrong_backend.grant.principal.backend = .tmux;
    try std.testing.expectError(
        error.InvalidStartPersistence,
        (ActionRequest{ .start = .{
            .cwd = "/workspace",
            .persistence = wrong_backend,
        } }).validate(),
    );
    var zero_proof = persistence;
    zero_proof.proof.bytes = @splat(0);
    try std.testing.expectError(
        error.InvalidHolderProof,
        (ActionRequest{ .start = .{
            .cwd = "/workspace",
            .persistence = zero_proof,
        } }).validate(),
    );
}

fn check_owned_action_request_allocation_failures(alloc: Allocator) !void {
    var request = try OwnedActionRequest.init(alloc, .{ .start = .{
        .cwd = "/workspace",
        .command = "zig build",
        .shell = .{ .executable = .{
            .path = "/bin/zsh",
            .clean_start = true,
        } },
        .return_when = .{ .match = "Build Summary" },
        .wait_ceiling_ms = 30_000,
        .dimensions = .{ .rows = 24, .columns = 80 },
        .persistence = .{
            .grant = .{
                .principal = .{
                    .profile_user = "profile-user",
                    .durable_session_id = "session-owner",
                    .workspace_root = "/workspace",
                    .cwd = "/workspace",
                    .transport_role = .interactive,
                    .backend = .native,
                },
                .actor = .agent,
                .controls = .full(),
                .generation = .{ .value = 1 },
            },
            .proof = .{ .bytes = @splat(7) },
        },
    } });
    defer request.deinit(alloc);
    try request.value.validate();
}

test "owned action request cleans every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        check_owned_action_request_allocation_failures,
        .{},
    );
}

test "terminal lifecycle accepts every valid transition and rejects the rest" {
    const valid = [_]struct {
        from: Lifecycle,
        event: LifecycleEvent,
        to: Lifecycle,
    }{
        .{ .from = .starting, .event = .child_started, .to = .running },
        .{ .from = .starting, .event = .child_exited, .to = .exited },
        .{ .from = .starting, .event = .host_lost, .to = .lost },
        .{ .from = .starting, .event = .close, .to = .closed },
        .{ .from = .running, .event = .child_exited, .to = .exited },
        .{ .from = .running, .event = .host_lost, .to = .lost },
        .{ .from = .running, .event = .close, .to = .closed },
        .{ .from = .exited, .event = .close, .to = .closed },
        .{ .from = .lost, .event = .close, .to = .closed },
    };
    const states = [_]Lifecycle{ .starting, .running, .exited, .lost, .closed };
    const events = [_]LifecycleEvent{ .child_started, .child_exited, .host_lost, .close };

    for (states) |state| {
        for (events) |event| {
            var expected: ?Lifecycle = null;
            for (valid) |case| {
                if (case.from == state and case.event == event) {
                    expected = case.to;
                    break;
                }
            }
            if (expected) |next| {
                try std.testing.expectEqual(next, try transition_lifecycle(state, event));
            } else {
                try std.testing.expectError(
                    error.InvalidLifecycleTransition,
                    transition_lifecycle(state, event),
                );
            }
        }
    }
}

test "attention cancellation releases only the caller claim" {
    const user_state = AttentionState{
        .attention = .user_takeover,
        .write_lease = .human,
    };
    try user_state.validate();
    try std.testing.expectEqual(
        AttentionState{ .attention = .background, .write_lease = .none },
        cancel_attention(user_state, .human),
    );
    try std.testing.expectEqual(user_state, cancel_attention(user_state, .agent));

    const agent_state = AttentionState{
        .attention = .agent_wait,
        .write_lease = .agent,
    };
    try agent_state.validate();
    try std.testing.expectEqual(
        AttentionState{ .attention = .background, .write_lease = .none },
        cancel_attention(agent_state, .agent),
    );
    try std.testing.expectError(
        error.InvalidAttentionState,
        (AttentionState{
            .attention = .user_takeover,
            .write_lease = .agent,
        }).validate(),
    );
}

test "raw cursor ranges and gaps preserve monotonic segments" {
    try (RawRange{
        .start = .{ .segment = 1, .offset = 4 },
        .end = .{ .segment = 1, .offset = 9 },
    }).validate();
    try std.testing.expectError(
        error.InvalidRawRange,
        (RawRange{
            .start = .{ .segment = 1, .offset = 9 },
            .end = .{ .segment = 1, .offset = 4 },
        }).validate(),
    );
    try std.testing.expectError(
        error.InvalidRawRange,
        (RawRange{
            .start = .{ .segment = 1, .offset = 4 },
            .end = .{ .segment = 2, .offset = 4 },
        }).validate(),
    );
    try (RawGap{
        .missing_from = .{ .segment = 1, .offset = 10 },
        .available_from = .{ .segment = 2, .offset = 0 },
    }).validate();
    try std.testing.expectError(
        error.InvalidRawGap,
        (RawGap{
            .missing_from = .{ .segment = 2, .offset = 0 },
            .available_from = .{ .segment = 1, .offset = 10 },
        }).validate(),
    );
    try std.testing.expectError(
        error.InvalidRawCursor,
        (RawCursor{ .segment = 0, .offset = 0 }).validate(),
    );
}

test "return conditions schedules and identifiers reject invalid boundaries" {
    try (ReturnCondition{ .quiet = 1 }).validate();
    try (ReturnCondition{ .match = "ready" }).validate();
    try std.testing.expectError(
        error.InvalidReturnCondition,
        (ReturnCondition{ .quiet = 0 }).validate(),
    );
    try std.testing.expectError(
        error.InvalidReturnCondition,
        (ReturnCondition{ .match = "" }).validate(),
    );

    try (PollSchedule{ .interval_ms = 1 }).validate();
    try std.testing.expectError(
        error.InvalidSchedule,
        (PollSchedule{ .interval_ms = 0 }).validate(),
    );

    try validate_session_id("terminal-1");
    try std.testing.expectError(
        error.InvalidSessionId,
        validate_session_id("../terminal-1"),
    );
}

fn test_render_cells() [4]RenderCell {
    return .{
        .{
            .kind = .single,
            .text = "A",
            .style = .{
                .foreground = .{ .rgb = .{
                    .red = 10,
                    .green = 20,
                    .blue = 30,
                } },
                .bold = true,
            },
        },
        .{ .kind = .blank },
        .{ .kind = .wide, .text = "界" },
        .{ .kind = .continuation },
    };
}

test "render snapshots validate exact cell grids cursor and checked bounds" {
    const cells = test_render_cells();
    const snapshot = RenderSnapshot{
        .dimensions = .{ .rows = 2, .columns = 2 },
        .cursor = .{
            .row = 1,
            .column = 1,
            .shape = .bar,
            .blinking = false,
        },
        .modes = .{
            .alternate_screen = true,
            .bracketed_paste = true,
        },
        .cells = &cells,
    };
    try snapshot.validate();
    try std.testing.expect(max_render_snapshot_bytes <= max_checkpoint_payload_bytes);

    try std.testing.expectError(
        error.InvalidDimensions,
        (RenderSnapshot{
            .dimensions = .{ .rows = 0, .columns = 80 },
            .cursor = .{ .row = 0, .column = 0 },
            .cells = &.{},
        }).validate(),
    );
    try std.testing.expectError(
        error.InvalidRenderSnapshot,
        (RenderSnapshot{
            .dimensions = .{ .rows = 2, .columns = 2 },
            .cursor = .{ .row = 2, .column = 0 },
            .cells = &cells,
        }).validate(),
    );
    try std.testing.expectError(
        error.InvalidRenderSnapshot,
        (RenderSnapshot{
            .dimensions = .{ .rows = 2, .columns = 3 },
            .cursor = .{ .row = 0, .column = 0 },
            .cells = &cells,
        }).validate(),
    );
    try std.testing.expectError(
        error.RenderSnapshotTooLarge,
        (RenderSnapshot{
            .dimensions = .{
                .rows = max_dimension,
                .columns = max_dimension,
            },
            .cursor = .{ .row = 0, .column = 0 },
            .cells = &.{},
        }).validate(),
    );

    var invalid_wide = cells;
    invalid_wide[2].kind = .blank;
    try std.testing.expectError(
        error.InvalidRenderCell,
        (RenderSnapshot{
            .dimensions = .{ .rows = 2, .columns = 2 },
            .cursor = .{ .row = 0, .column = 0 },
            .cells = &invalid_wide,
        }).validate(),
    );
}

fn check_owned_render_snapshot_allocation_failures(alloc: Allocator) !void {
    const cells = test_render_cells();
    var snapshot = try OwnedRenderSnapshot.init(alloc, .{
        .dimensions = .{ .rows = 2, .columns = 2 },
        .cursor = .{ .row = 1, .column = 1 },
        .cells = &cells,
    });
    defer snapshot.deinit(alloc);
    try snapshot.view().validate();
}

test "owned render snapshots clean every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        check_owned_render_snapshot_allocation_failures,
        .{},
    );
}

test "checkpoint envelopes bind payload size checksum and cursor anchor" {
    const payload = "opaque checkpoint";
    const valid = CheckpointEnvelope{
        .engine_schema_revision = 1,
        .applied_cursor = .{ .segment = 2, .offset = 41 },
        .payload_len = payload.len,
        .checksum = checkpoint_checksum(payload),
    };
    try valid.validate(payload);
    try validate_checkpoint_anchor(
        valid,
        .{ .segment = 2, .offset = 42 },
    );

    var corrupt = valid;
    corrupt.checksum[0] ^= 1;
    try std.testing.expectError(
        error.CheckpointChecksumMismatch,
        corrupt.validate(payload),
    );
    try std.testing.expectError(
        error.InvalidCheckpoint,
        valid.validate("short"),
    );

    var unsupported_anchor = valid;
    unsupported_anchor.applied_cursor.segment = 0;
    try std.testing.expectError(
        error.InvalidCheckpoint,
        unsupported_anchor.validate(payload),
    );
    try std.testing.expectError(
        error.InvalidCheckpoint,
        validate_checkpoint_anchor(
            valid,
            .{ .segment = 3, .offset = 42 },
        ),
    );
    try std.testing.expectError(
        error.InvalidCheckpoint,
        validate_checkpoint_anchor(
            valid,
            .{ .segment = 2, .offset = 40 },
        ),
    );

    var oversized = valid;
    oversized.payload_len = max_checkpoint_payload_bytes + 1;
    try std.testing.expectError(
        error.CheckpointTooLarge,
        oversized.validate(payload),
    );

    const reasons = [_]ScreenUnavailableReason{
        .missing,
        .corrupt,
        .unsupported_schema,
        .retention_evicted,
        .raw_gap,
        .resize_uncheckpointed,
    };
    for (reasons) |reason| {
        const state = ScreenRecovery{ .unavailable = reason };
        try std.testing.expectEqual(reason, state.unavailable);
    }
}

fn test_session_facts() SessionFacts {
    return .{
        .session_id = "terminal-1",
        .lifecycle = .running,
        .attention = .{},
        .backend = .native,
        .output_cursor = .{ .segment = 1, .offset = 8 },
        .unread_range = .{
            .start = .{ .segment = 1, .offset = 4 },
            .end = .{ .segment = 1, .offset = 8 },
        },
        .screen_recovery = .{ .unavailable = .missing },
        .next_actions = .full(),
    };
}

test "results own every action-specific success and structured failure" {
    const cells = test_render_cells();
    const sessions = [_]SessionFacts{test_session_facts()};
    const successes = [_]ActionResult{
        .{ .start = .{
            .session = test_session_facts(),
            .outcome = .started,
        } },
        .{ .read = .{
            .session = test_session_facts(),
            .output = "done",
            .raw_range = .{
                .start = .{ .segment = 1, .offset = 4 },
                .end = .{ .segment = 1, .offset = 8 },
            },
        } },
        .{ .screen = .{
            .session = test_session_facts(),
            .snapshot = .{
                .dimensions = .{ .rows = 2, .columns = 2 },
                .cursor = .{ .row = 1, .column = 1 },
                .cells = &cells,
            },
        } },
        .{ .write = .{
            .session = test_session_facts(),
            .accepted_bytes = 4,
        } },
        .{ .wait = .{
            .session = test_session_facts(),
            .outcome = .condition_met,
        } },
        .{ .inspect = .{
            .session = test_session_facts(),
            .shell = "/bin/zsh",
            .cwd = "/workspace",
            .command = "zig build",
        } },
        .{ .list = .{ .sessions = &sessions } },
        .{ .resize = .{
            .session = test_session_facts(),
            .dimensions = .{ .rows = 40, .columns = 120 },
        } },
        .{ .signal = .{
            .session = test_session_facts(),
            .signal = .interrupt,
        } },
        .{ .close = .{
            .session = test_session_facts(),
            .policy = .graceful,
        } },
    };

    for (successes, std.meta.tags(Action)) |success, action| {
        try std.testing.expectEqual(action, success.action());
        var owned = try OwnedResult.init(std.testing.allocator, .{
            .success = success,
        });
        defer owned.deinit(std.testing.allocator);
        const view = owned.view();
        try std.testing.expectEqual(action, view.action());
        try view.validate();
    }

    var failure = try OwnedResult.init(std.testing.allocator, .{
        .failure = .{
            .action = .read,
            .code = .session_not_found,
            .session_id = "terminal-1",
        },
    });
    defer failure.deinit(std.testing.allocator);
    try std.testing.expectEqual(Action.read, failure.view().action());
    try failure.view().validate();
}

test "start and wait results preserve every valid return outcome" {
    const outcomes = [_]ReturnOutcome{
        .started,
        .condition_met,
        .safety_ceiling,
        .cancelled,
        .{ .exited = 23 },
        .{ .signal = 9 },
    };

    for (outcomes) |outcome| {
        const successes = [_]ActionResult{
            .{ .start = .{
                .session = test_session_facts(),
                .outcome = outcome,
            } },
            .{ .wait = .{
                .session = test_session_facts(),
                .outcome = outcome,
            } },
        };
        for (successes) |success| {
            var owned = try OwnedResult.init(std.testing.allocator, .{
                .success = success,
            });
            defer owned.deinit(std.testing.allocator);

            const owned_success = switch (owned.view()) {
                .success => |value| value,
                .failure => return error.TestUnexpectedResult,
            };
            const owned_outcome = switch (owned_success) {
                .start => |value| value.outcome,
                .wait => |value| value.outcome,
                else => return error.TestUnexpectedResult,
            };
            try std.testing.expectEqual(outcome, owned_outcome);
            try owned.view().validate();
        }
    }
}

test "return outcomes reject malformed termination values" {
    const malformed = [_]ReturnOutcome{
        .{ .exited = -1 },
        .{ .exited = 256 },
        .{ .signal = 0 },
        .{ .signal = 256 },
    };

    for (malformed) |outcome| {
        try std.testing.expectError(
            error.InvalidReturnOutcome,
            outcome.validate(),
        );
        try std.testing.expectError(
            error.InvalidReturnOutcome,
            (ActionResult{ .start = .{
                .session = test_session_facts(),
                .outcome = outcome,
            } }).validate(),
        );
        try std.testing.expectError(
            error.InvalidReturnOutcome,
            (ActionResult{ .wait = .{
                .session = test_session_facts(),
                .outcome = outcome,
            } }).validate(),
        );
    }
}

test "action-specific result validation rejects incoherent values" {
    try std.testing.expectError(
        error.InvalidResult,
        (ActionResult{ .write = .{
            .session = test_session_facts(),
            .accepted_bytes = max_write_bytes + 1,
        } }).validate(),
    );
    try std.testing.expectError(
        error.InvalidRawRange,
        (ActionResult{ .read = .{
            .session = test_session_facts(),
            .output = "late",
            .raw_range = .{
                .start = .{ .segment = 1, .offset = 8 },
                .end = .{ .segment = 1, .offset = 9 },
            },
        } }).validate(),
    );
}

fn check_owned_result_allocation_failures(alloc: Allocator) !void {
    const cells = test_render_cells();
    var result = try OwnedResult.init(alloc, .{ .success = .{ .screen = .{
        .session = test_session_facts(),
        .snapshot = .{
            .dimensions = .{ .rows = 2, .columns = 2 },
            .cursor = .{ .row = 1, .column = 1 },
            .cells = &cells,
        },
    } } });
    defer result.deinit(alloc);
    try result.view().validate();
}

test "owned results clean every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        check_owned_result_allocation_failures,
        .{},
    );
}

fn test_principal() Principal {
    return .{
        .profile_user = "user-501",
        .durable_session_id = "session-1",
        .workspace_root = "/workspace",
        .cwd = "/workspace/src",
        .transport_role = .interactive,
        .backend = .native,
    };
}

fn test_proof() HolderProof {
    return .{ .bytes = [_]u8{1} ** 32 };
}

test "authority wire encoding excludes host-authenticated process ownership" {
    const claim = AuthorityClaim{
        .principal = test_principal(),
        .actor = .human,
        .generation = try AuthorityGeneration.init(1),
        .proof = test_proof(),
        .process_owner = try ProcessOwner.init(42, "process-instance"),
    };
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try std.json.Stringify.value(claim, .{}, &output.writer);
    try std.testing.expect(std.mem.indexOf(
        u8,
        output.written(),
        "process_owner",
    ) == null);

    var parsed = try std.json.parseFromSlice(
        AuthorityClaim,
        std.testing.allocator,
        output.written(),
        .{},
    );
    defer parsed.deinit();
    try std.testing.expect(parsed.value.process_owner == null);
    try parsed.value.validate();
}

test "authority generations increase monotonically and reject exhaustion" {
    const first = try AuthorityGeneration.init(1);
    const second = try first.next();
    try std.testing.expectEqual(@as(u64, 2), second.value);
    try std.testing.expectError(
        error.InvalidAuthorityGeneration,
        AuthorityGeneration.init(0),
    );
    try std.testing.expectError(
        error.InvalidAuthorityGeneration,
        (AuthorityGeneration{ .value = 0 }).validate(),
    );
    try std.testing.expectError(
        error.InvalidAuthorityGeneration,
        (AuthorityGeneration{ .value = 0 }).next(),
    );
    try std.testing.expectError(
        error.AuthorityGenerationExhausted,
        (AuthorityGeneration{ .value = std.math.maxInt(u64) }).next(),
    );
}

test "direct human observation does not grant model control" {
    const observer = AllowedControls.observer();
    try std.testing.expect(observer.allows(.read));
    try std.testing.expect(observer.allows(.screen));
    try std.testing.expect(!observer.allows(.write));
    try std.testing.expect(!observer.allows(.wait));
    try std.testing.expect(!observer.allows(.resize));
    try std.testing.expect(!observer.allows(.signal));
    try std.testing.expect(!observer.allows(.close));
}

test "next actions are the pure lifecycle authority and lease intersection" {
    const observer = project_next_actions(
        .running,
        .observer(),
        .agent,
        .{},
    );
    try std.testing.expectEqual(AllowedControls.observer(), observer);

    const lifecycle_cases = [_]struct {
        lifecycle: Lifecycle,
        signal: bool,
    }{
        .{ .lifecycle = .starting, .signal = true },
        .{ .lifecycle = .running, .signal = true },
        .{ .lifecycle = .exited, .signal = false },
        .{ .lifecycle = .lost, .signal = false },
        .{ .lifecycle = .closed, .signal = false },
    };
    for (lifecycle_cases) |case| {
        const projected = project_next_actions(
            case.lifecycle,
            .full(),
            .agent,
            .{},
        );
        try std.testing.expectEqual(case.signal, projected.signal);
    }

    const leased = project_next_actions(
        .running,
        .full(),
        .agent,
        .{ .attention = .user_takeover, .write_lease = .human },
    );
    try std.testing.expect(!leased.write);
    try std.testing.expect(leased.resize);

    const closed = project_next_actions(
        .closed,
        .full(),
        .human,
        .{},
    );
    try std.testing.expectEqual(lifecycle_controls(.closed), closed);
}

test "protocol negotiates current and previous revisions without destructive fallback" {
    const capabilities =
        protocol_capability_authority_generations |
        protocol_capability_screen_checkpoints;
    const current = ProtocolHello{
        .range = local_protocol_range,
        .capabilities = capabilities,
        .required_capabilities = protocol_capability_authority_generations,
    };
    const previous = ProtocolHello{
        .range = .{
            .minimum = previous_protocol_revision,
            .current = previous_protocol_revision,
        },
        .capabilities = protocol_capability_authority_generations,
    };

    const same = try negotiate_protocol(current, current);
    try std.testing.expectEqual(
        current_protocol_revision,
        same.compatible.revision,
    );
    const skewed = try negotiate_protocol(current, previous);
    try std.testing.expectEqual(
        previous_protocol_revision,
        skewed.compatible.revision,
    );
    try std.testing.expectEqual(
        protocol_capability_authority_generations,
        skewed.compatible.capabilities,
    );

    const future = ProtocolHello{
        .range = .{
            .minimum = current_protocol_revision + 1,
            .current = current_protocol_revision + 2,
        },
        .capabilities = known_protocol_capabilities,
    };
    const incompatible = try negotiate_protocol(current, future);
    try std.testing.expectEqual(
        IncompatibilityReason.revision_mismatch,
        incompatible.incompatible.reason,
    );

    const missing_capability = ProtocolHello{
        .range = local_protocol_range,
        .capabilities = protocol_capability_authority_generations,
        .required_capabilities = protocol_capability_authority_generations,
    };
    const no_capabilities = ProtocolHello{
        .range = local_protocol_range,
        .capabilities = 0,
    };
    const missing = try negotiate_protocol(missing_capability, no_capabilities);
    try std.testing.expectEqual(
        IncompatibilityReason.required_capability_missing,
        missing.incompatible.reason,
    );
    try std.testing.expectError(
        error.UnknownRequiredCapability,
        (ProtocolHello{
            .range = local_protocol_range,
            .capabilities = std.math.maxInt(u64),
            .required_capabilities = 1 << 63,
        }).validate(),
    );
}

test "protocol accepts complete process tree signal capability" {
    const complete_process_tree_signals: u64 = 1 << 4;
    try (ProtocolHello{
        .range = local_protocol_range,
        .capabilities = complete_process_tree_signals,
        .required_capabilities = complete_process_tree_signals,
    }).validate();
}

test "durable actions derive policy specific protocol capabilities" {
    const authority = protocol_capability_authority_generations;
    const complete_signals = protocol_capability_complete_process_tree_signals;
    const tmux_recovery = protocol_capability_tmux_recovery;
    const cases = [_]struct {
        request: ActionRequest,
        expected: u64,
    }{
        .{
            .request = .{ .start = .{ .cwd = "/" } },
            .expected = authority | complete_signals,
        },
        .{
            .request = .{ .start = .{ .cwd = "/", .backend = .tmux } },
            .expected = authority | complete_signals | tmux_recovery,
        },
        .{
            .request = .{ .read = .{
                .session_id = "terminal-a",
                .cursor = .{ .segment = 1, .offset = 0 },
            } },
            .expected = authority,
        },
        .{
            .request = .{ .screen = .{ .session_id = "terminal-a" } },
            .expected = authority,
        },
        .{
            .request = .{ .write = .{
                .session_id = "terminal-a",
                .lease = .acquire,
            } },
            .expected = authority,
        },
        .{
            .request = .{ .wait = .{
                .session_id = "terminal-a",
                .return_when = .exit,
                .safety_ceiling_ms = 1,
            } },
            .expected = authority,
        },
        .{
            .request = .{ .inspect = .{ .session_id = "terminal-a" } },
            .expected = authority,
        },
        .{
            .request = .{ .list = .{} },
            .expected = authority,
        },
        .{
            .request = .{ .resize = .{
                .session_id = "terminal-a",
                .dimensions = .{ .rows = 24, .columns = 80 },
            } },
            .expected = authority,
        },
        .{
            .request = .{ .signal = .{
                .session_id = "terminal-a",
                .signal = .interrupt,
            } },
            .expected = authority | complete_signals,
        },
        .{
            .request = .{ .close = .{
                .session_id = "terminal-a",
                .policy = .graceful,
            } },
            .expected = authority,
        },
        .{
            .request = .{ .close = .{
                .session_id = "terminal-a",
                .policy = .force,
            } },
            .expected = authority | complete_signals,
        },
    };

    for (cases) |case| {
        try case.request.validate();
        try std.testing.expectEqual(
            case.expected,
            required_capabilities(case.request),
        );
    }
}

test "hello envelopes bridge older incompatible ranges without admitting old actions" {
    try (MessageEnvelope{
        .revision = oldest_hello_revision,
        .kind = .hello,
        .payload_len = 0,
    }).validate(0);
    try std.testing.expectError(
        error.UnsupportedProtocolRevision,
        (MessageEnvelope{
            .revision = compatibility_hello_revision,
            .kind = .{ .request = .screen },
            .correlation_id = .{ .value = 1 },
            .payload_len = 0,
        }).validate(0),
    );
}

test "host message correlation isolates request response and cancel semantics" {
    const correlation_id = try CorrelationId.init(7);
    const request = HostMessage{
        .envelope = .{
            .revision = current_protocol_revision,
            .kind = .{ .request = .screen },
            .correlation_id = correlation_id,
            .payload_len = 0,
        },
        .payload = .{ .request = .{
            .screen = .{ .session_id = "terminal-1" },
        } },
    };
    try request.validate(0);

    const response = HostMessage{
        .envelope = .{
            .revision = current_protocol_revision,
            .kind = .{ .response = .screen },
            .correlation_id = correlation_id,
            .payload_len = 0,
        },
        .payload = .{ .response = .{ .failure = .{
            .action = .screen,
            .code = .screen_unavailable,
            .session_id = "terminal-1",
        } } },
    };
    try response.validate(0);

    try (HostMessage{
        .envelope = .{
            .revision = current_protocol_revision,
            .kind = .hello,
            .payload_len = 0,
        },
        .payload = .{ .hello = .{
            .range = local_protocol_range,
            .capabilities = known_protocol_capabilities,
        } },
    }).validate(0);
    try (HostMessage{
        .envelope = .{
            .revision = current_protocol_revision,
            .kind = .cancel,
            .correlation_id = correlation_id,
            .payload_len = 0,
        },
        .payload = .cancel,
    }).validate(0);

    try std.testing.expectError(
        error.MissingCorrelationId,
        (MessageEnvelope{
            .revision = current_protocol_revision,
            .kind = .{ .request = .read },
            .payload_len = 0,
        }).validate(0),
    );
    try std.testing.expectError(
        error.InvalidCorrelationId,
        (MessageEnvelope{
            .revision = current_protocol_revision,
            .kind = .cancel,
            .correlation_id = .{ .value = 0 },
            .payload_len = 0,
        }).validate(0),
    );
    try std.testing.expectError(
        error.UnexpectedCorrelationId,
        (MessageEnvelope{
            .revision = current_protocol_revision,
            .kind = .hello,
            .correlation_id = correlation_id,
            .payload_len = 0,
        }).validate(0),
    );
}

test "typed host messages reject action and payload mismatches" {
    const cells = test_render_cells();
    try std.testing.expectError(
        error.MessageKindMismatch,
        (HostMessage{
            .envelope = .{
                .revision = current_protocol_revision,
                .kind = .{ .response = .write },
                .correlation_id = .{ .value = 1 },
                .payload_len = 0,
            },
            .payload = .{ .response = .{ .success = .{ .screen = .{
                .session = test_session_facts(),
                .snapshot = .{
                    .dimensions = .{ .rows = 2, .columns = 2 },
                    .cursor = .{ .row = 1, .column = 1 },
                    .cells = &cells,
                },
            } } } },
        }).validate(0),
    );
    try std.testing.expectError(
        error.MessageKindMismatch,
        (HostMessage{
            .envelope = .{
                .revision = current_protocol_revision,
                .kind = .{ .request = .read },
                .correlation_id = .{ .value = 1 },
                .payload_len = 0,
            },
            .payload = .{ .request = .{
                .screen = .{ .session_id = "terminal-1" },
            } },
        }).validate(0),
    );
}
