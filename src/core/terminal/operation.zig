const std = @import("std");
const contracts = @import("contracts.zig");
const io_mod = @import("../shared/io.zig");

const Allocator = std.mem.Allocator;

/// Trusted facts accepted only after the caller has completed its own private
/// admission decision. This module constructs terminal authority; it does not
/// decide whether that authority should be granted.
pub const AuthorityPreparation = struct {
    profile_user: []const u8,
    durable_session_id: []const u8,
    workspace_root: []const u8,
    cwd: []const u8,
    transport_role: contracts.TransportRole,
    backend: contracts.Backend,
    actor: contracts.ActorRole,
    controls: contracts.AllowedControls,
    lifetime: contracts.TerminalLifetime,
    repeated_probes: []const contracts.RepeatedProbeAuthority = &.{},
    direct_human_model_read_only: bool = false,
};

/// Owns every string and the secret embedded in the returned persistence
/// value. It may be retained only until the start request has copied it.
pub const PreparedAuthority = struct {
    alloc: Allocator,
    persistence: contracts.StartPersistence,

    pub fn view(self: *const PreparedAuthority) contracts.StartPersistence {
        return self.persistence;
    }

    pub fn deinit(self: *PreparedAuthority) void {
        std.crypto.secureZero(
            u8,
            @volatileCast(self.persistence.proof.bytes[0..]),
        );
        free_repeated_probes(
            self.alloc,
            self.persistence.grant.repeated_probes,
        );
        free_principal(self.alloc, self.persistence.grant.principal);
        self.* = undefined;
    }
};

/// An owner-scoped reload result. The proof and principal backing are kept
/// internal and independently owned by the caller.
pub const OwnedAuthorityClaim = struct {
    alloc: Allocator,
    value: contracts.AuthorityClaim,
    controls: contracts.AllowedControls,

    pub fn view(self: *const OwnedAuthorityClaim) contracts.AuthorityClaim {
        return self.value;
    }

    pub fn deinit(self: *OwnedAuthorityClaim) void {
        const principal = self.value.principal;
        std.crypto.secureZero(u8, @volatileCast(self.value.proof.bytes[0..]));
        free_principal(self.alloc, principal);
        self.* = undefined;
    }
};

pub const OwnedOwnerCatalogClaim = struct {
    alloc: Allocator,
    value: contracts.OwnerCatalogAuthorityClaim,

    pub fn view(self: *const OwnedOwnerCatalogClaim) contracts.OwnerCatalogAuthorityClaim {
        return self.value;
    }

    pub fn deinit(self: *OwnedOwnerCatalogClaim) void {
        std.crypto.secureZero(
            u8,
            @volatileCast(self.value.proof.bytes[0..]),
        );
        free_owner_catalog_principal(self.alloc, self.value.principal);
        self.* = undefined;
    }
};

/// Production entropy edge for private terminal-session authority. Durable
/// storage remains the host/store owner's responsibility.
pub fn prepareStartPersistence(
    alloc: Allocator,
    input: AuthorityPreparation,
) !PreparedAuthority {
    var proof = contracts.HolderProof{ .bytes = undefined };
    defer std.crypto.secureZero(u8, @volatileCast(proof.bytes[0..]));
    while (true) {
        try std.Io.randomSecure(io_mod.getIo(), &proof.bytes);
        proof.validate() catch continue;
        break;
    }
    return construct_start_persistence(alloc, input, proof);
}

/// Deterministic construction kept separate from entropy and persistence so
/// every validation and allocation edge can be tested exhaustively.
fn construct_start_persistence(
    alloc: Allocator,
    input: AuthorityPreparation,
    proof: contracts.HolderProof,
) !PreparedAuthority {
    if (!std.fs.path.isAbsolute(input.workspace_root) or
        !std.fs.path.isAbsolute(input.cwd))
    {
        return error.InvalidPrincipal;
    }
    const borrowed = contracts.StartPersistence{
        .grant = .{
            .principal = .{
                .profile_user = input.profile_user,
                .durable_session_id = input.durable_session_id,
                .workspace_root = input.workspace_root,
                .cwd = input.cwd,
                .transport_role = input.transport_role,
                .backend = input.backend,
                .lifetime = input.lifetime,
            },
            .actor = input.actor,
            .controls = input.controls,
            .generation = try contracts.AuthorityGeneration.init(1),
            .repeated_probes = input.repeated_probes,
        },
        .proof = proof,
        .direct_human_model_read_only = input.direct_human_model_read_only,
    };
    try borrowed.validate(.{
        .cwd = input.cwd,
        .backend = input.backend,
    });
    const principal = try dupe_principal(alloc, borrowed.grant.principal);
    errdefer free_principal(alloc, principal);
    const repeated_probes = try dupe_repeated_probes(
        alloc,
        borrowed.grant.repeated_probes,
    );
    return .{
        .alloc = alloc,
        .persistence = .{
            .grant = .{
                .principal = principal,
                .actor = borrowed.grant.actor,
                .controls = borrowed.grant.controls,
                .generation = borrowed.grant.generation,
                .repeated_probes = repeated_probes,
            },
            .proof = borrowed.proof,
            .direct_human_model_read_only = borrowed.direct_human_model_read_only,
        },
    };
}

fn dupe_repeated_probes(
    alloc: Allocator,
    probes: []const contracts.RepeatedProbeAuthority,
) ![]contracts.RepeatedProbeAuthority {
    const owned = try alloc.alloc(contracts.RepeatedProbeAuthority, probes.len);
    var initialized: usize = 0;
    errdefer {
        for (owned[0..initialized]) |probe| {
            alloc.free(probe.cwd);
            alloc.free(probe.command);
        }
        alloc.free(owned);
    }
    for (probes, 0..) |probe, index| {
        try probe.validate();
        const command = try alloc.dupe(u8, probe.command);
        errdefer alloc.free(command);
        owned[index] = .{
            .command = command,
            .cwd = try alloc.dupe(u8, probe.cwd),
            .check_schedule = probe.check_schedule,
            .notify_schedule = probe.notify_schedule,
            .lifetime = probe.lifetime,
        };
        initialized += 1;
    }
    return owned;
}

fn free_repeated_probes(
    alloc: Allocator,
    probes: []const contracts.RepeatedProbeAuthority,
) void {
    for (probes) |probe| {
        alloc.free(probe.cwd);
        alloc.free(probe.command);
    }
    alloc.free(probes);
}

pub fn ownAuthorityClaim(
    alloc: Allocator,
    authority_claim: contracts.AuthorityClaim,
    controls: contracts.AllowedControls,
) !OwnedAuthorityClaim {
    try authority_claim.validate();
    if (!controls.any()) return error.InvalidAuthorityGrant;
    return .{
        .alloc = alloc,
        .value = .{
            .principal = try dupe_principal(alloc, authority_claim.principal),
            .actor = authority_claim.actor,
            .generation = authority_claim.generation,
            .proof = authority_claim.proof,
            .process_owner = authority_claim.process_owner,
        },
        .controls = controls,
    };
}

pub fn ownOwnerCatalogClaim(
    alloc: Allocator,
    authority_claim: contracts.OwnerCatalogAuthorityClaim,
) !OwnedOwnerCatalogClaim {
    try authority_claim.validate();
    return .{
        .alloc = alloc,
        .value = .{
            .principal = try dupe_owner_catalog_principal(
                alloc,
                authority_claim.principal,
            ),
            .actor = authority_claim.actor,
            .proof = authority_claim.proof,
        },
    };
}

fn dupe_principal(
    alloc: Allocator,
    principal: contracts.Principal,
) !contracts.Principal {
    const profile_user = try alloc.dupe(u8, principal.profile_user);
    errdefer alloc.free(profile_user);
    const durable_session_id = try alloc.dupe(u8, principal.durable_session_id);
    errdefer alloc.free(durable_session_id);
    const workspace_root = try alloc.dupe(u8, principal.workspace_root);
    errdefer alloc.free(workspace_root);
    const cwd = try alloc.dupe(u8, principal.cwd);
    return .{
        .profile_user = profile_user,
        .durable_session_id = durable_session_id,
        .workspace_root = workspace_root,
        .cwd = cwd,
        .transport_role = principal.transport_role,
        .backend = principal.backend,
        .lifetime = principal.lifetime,
    };
}

fn free_principal(alloc: Allocator, principal: contracts.Principal) void {
    alloc.free(principal.profile_user);
    alloc.free(principal.durable_session_id);
    alloc.free(principal.workspace_root);
    alloc.free(principal.cwd);
}

fn dupe_owner_catalog_principal(
    alloc: Allocator,
    principal: contracts.OwnerCatalogPrincipal,
) !contracts.OwnerCatalogPrincipal {
    const profile_user = try alloc.dupe(u8, principal.profile_user);
    errdefer alloc.free(profile_user);
    const durable_session_id = try alloc.dupe(u8, principal.durable_session_id);
    errdefer alloc.free(durable_session_id);
    return .{
        .profile_user = profile_user,
        .durable_session_id = durable_session_id,
        .workspace_root = try alloc.dupe(u8, principal.workspace_root),
        .transport_role = principal.transport_role,
    };
}

fn free_owner_catalog_principal(
    alloc: Allocator,
    principal: contracts.OwnerCatalogPrincipal,
) void {
    alloc.free(principal.workspace_root);
    alloc.free(principal.durable_session_id);
    alloc.free(principal.profile_user);
}

pub const ValidationError = contracts.RequestValidationError || error{
    MissingTerminalAuthority,
};

pub fn validate(request: contracts.ActionRequest) ValidationError!void {
    try request.validate();
    switch (request) {
        .start => |start| {
            if (start.persistence == null) return error.MissingTerminalAuthority;
        },
        .read => |value| try require_claim(value.authority),
        .screen => |value| try require_claim(value.authority),
        .write => |value| try require_claim(value.authority),
        .wait => |value| try require_claim(value.authority),
        .monitor => |value| try require_claim(value.authority),
        .inspect => |value| try require_claim(value.authority),
        .list => |value| {
            const owner_authority = value.owner_authority orelse
                return error.MissingTerminalAuthority;
            owner_authority.validate() catch return error.InvalidAuthorityClaim;
        },
        .resize => |value| try require_claim(value.authority),
        .signal => |value| try require_claim(value.authority),
        .close => |value| try require_claim(value.authority),
    }
}

fn require_claim(presentation: ?contracts.AuthorityClaim) ValidationError!void {
    const value = presentation orelse return error.MissingTerminalAuthority;
    try value.validate();
}

pub fn claim(request: contracts.ActionRequest) ?contracts.AuthorityClaim {
    return switch (request) {
        .start => null,
        .read => |value| value.authority,
        .screen => |value| value.authority,
        .write => |value| value.authority,
        .wait => |value| value.authority,
        .monitor => |value| value.authority,
        .inspect => |value| value.authority,
        .list => null,
        .resize => |value| value.authority,
        .signal => |value| value.authority,
        .close => |value| value.authority,
    };
}

pub fn attachProcessOwner(
    request: *contracts.ActionRequest,
    owner: contracts.ProcessOwner,
) void {
    switch (request.*) {
        .start, .list => {},
        inline else => |*value| if (value.authority) |*claim_value| {
            claim_value.process_owner = owner;
        },
    }
}

pub fn authoritySessionId(request: contracts.ActionRequest) ?[]const u8 {
    return switch (request) {
        .start => null,
        .read => |value| value.session_id,
        .screen => |value| value.session_id,
        .write => |value| value.session_id,
        .wait => |value| value.session_id,
        .monitor => |value| value.session_id,
        .inspect => |value| value.session_id,
        .list => null,
        .resize => |value| value.session_id,
        .signal => |value| value.session_id,
        .close => |value| value.session_id,
    };
}

pub fn requiresOrderedMutation(request: contracts.ActionRequest) bool {
    return switch (request) {
        .write, .monitor, .resize, .signal, .close => true,
        .inspect => |inspect| inspect.acknowledge_event_id != null,
        .start, .read, .screen, .wait, .list => false,
    };
}

/// The single private host operation path. The backend owns durable authority
/// re-resolution because it owns the current session/store state.
pub fn execute(
    backend: anytype,
    request: contracts.ActionRequest,
    cancelled: *const std.atomic.Value(bool),
) !contracts.OwnedResult {
    try validate(request);
    return backend.executeAuthorized(request, cancelled);
}

test "private operation validation requires durable authority on every action" {
    try std.testing.expectError(
        error.MissingTerminalAuthority,
        validate(.{ .screen = .{ .session_id = "terminal-1" } }),
    );
    try std.testing.expectError(
        error.MissingTerminalAuthority,
        validate(.{ .list = .{} }),
    );
    try std.testing.expectError(
        error.MissingTerminalAuthority,
        validate(.{ .start = .{ .cwd = "/workspace" } }),
    );
}

test "terminal mutations that share session write ownership stay ordered" {
    try std.testing.expect(requiresOrderedMutation(.{ .write = .{
        .session_id = "terminal-1",
        .payload = .{ .text = "input" },
    } }));
    try std.testing.expect(requiresOrderedMutation(.{ .close = .{
        .session_id = "terminal-1",
        .policy = .graceful,
    } }));
    try std.testing.expect(requiresOrderedMutation(.{ .inspect = .{
        .session_id = "terminal-1",
        .acknowledge_event_id = 1,
    } }));
    try std.testing.expect(!requiresOrderedMutation(.{ .inspect = .{
        .session_id = "terminal-1",
    } }));
    try std.testing.expect(!requiresOrderedMutation(.{ .wait = .{
        .session_id = "terminal-1",
        .return_when = .exit,
        .safety_ceiling_ms = 1,
    } }));
}

fn test_preparation() AuthorityPreparation {
    return .{
        .profile_user = "profile-user",
        .durable_session_id = "terminal-owner",
        .workspace_root = "/workspace",
        .cwd = "/workspace/project",
        .transport_role = .interactive,
        .backend = .native,
        .actor = .agent,
        .controls = .full(),
        .lifetime = .session,
    };
}

test "production preparation mints canonical generation one authority" {
    var prepared = try prepareStartPersistence(
        std.testing.allocator,
        test_preparation(),
    );
    defer prepared.deinit();
    const persistence = prepared.view();
    try persistence.validate(.{
        .cwd = "/workspace/project",
        .backend = .native,
    });
    try std.testing.expectEqual(@as(u64, 1), persistence.grant.generation.value);
    try std.testing.expectEqual(contracts.TerminalLifetime.session, persistence.grant.principal.lifetime);
    try persistence.proof.validate();
}

test "production preparation owns exact repeated probe authority" {
    const probes = [_]contracts.RepeatedProbeAuthority{.{
        .command = "test -f ready",
        .cwd = "/workspace/project",
        .check_schedule = .{ .interval_ms = 25 },
        .notify_schedule = .{ .every_n_checks = 2 },
        .lifetime = .{ .duration_ms = 500 },
    }};
    var input = test_preparation();
    input.repeated_probes = &probes;
    var prepared = try construct_start_persistence(
        std.testing.allocator,
        input,
        .{ .bytes = @splat(6) },
    );
    defer prepared.deinit();
    const owned = prepared.view().grant.repeated_probes;
    try std.testing.expectEqual(@as(usize, 1), owned.len);
    try std.testing.expect(owned.ptr != probes[0..].ptr);
    try std.testing.expect(owned[0].command.ptr != probes[0].command.ptr);
    try std.testing.expect(owned[0].cwd.ptr != probes[0].cwd.ptr);
    try std.testing.expect(owned[0].matches(.{
        .condition = .{ .custom_probe = .{
            .command = "test -f ready",
            .cwd = "/workspace/project",
        } },
        .check_schedule = .{ .interval_ms = 25 },
        .notify_schedule = .{ .every_n_checks = 2 },
        .lifetime = .{ .duration_ms = 500 },
    }));
}

test "pure authority construction validates direct human policy" {
    const proof = contracts.HolderProof{ .bytes = @splat(9) };
    var input = test_preparation();
    input.actor = .human;
    input.direct_human_model_read_only = true;
    var prepared = try construct_start_persistence(
        std.testing.allocator,
        input,
        proof,
    );
    defer prepared.deinit();
    try std.testing.expect(prepared.view().direct_human_model_read_only);

    input.actor = .agent;
    try std.testing.expectError(
        error.InvalidStartPersistence,
        construct_start_persistence(std.testing.allocator, input, proof),
    );
}

fn check_preparation_allocation_failures(alloc: Allocator) !void {
    var prepared = try construct_start_persistence(
        alloc,
        test_preparation(),
        .{ .bytes = @splat(5) },
    );
    defer prepared.deinit();
    const persistence = prepared.view();
    var owned_claim = try ownAuthorityClaim(
        alloc,
        .{
            .principal = persistence.grant.principal,
            .actor = persistence.grant.actor,
            .generation = persistence.grant.generation,
            .proof = persistence.proof,
        },
        persistence.grant.controls,
    );
    defer owned_claim.deinit();
}

test "authority preparation and owned claims cover allocation failures" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        check_preparation_allocation_failures,
        .{},
    );
}
