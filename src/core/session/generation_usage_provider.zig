const std = @import("std");
const secret = @import("../auth/secret.zig");

const Allocator = std.mem.Allocator;

pub const LookupInput = struct {
    credential: []const u8,
    tenant: ?[]const u8,
    lookup_scope: ?[]const u8,
    generation_id: []const u8,
    cancel_flag: *std.atomic.Value(bool),
};

pub const Record = struct {
    id: []const u8,
    created_at_ms: i64 = 0,
    model: []const u8,
    total_cost: f64,
    input_tokens: u64,
    output_tokens: u64,
    cache_read_tokens: u64,
    cache_write_tokens: u64,
    reasoning_tokens: ?u64 = null,
    billable_web_search_calls: u64,
};

pub const LookupOutcome = union(enum) {
    found: Record,
    retry,
    preserve_pending,
    reject,

    pub fn deinit(self: *LookupOutcome, alloc: Allocator) void {
        switch (self.*) {
            .found => |record| {
                alloc.free(@constCast(record.id));
                alloc.free(@constCast(record.model));
            },
            .retry, .preserve_pending, .reject => {},
        }
        self.* = undefined;
    }
};

pub const LookupError = Allocator.Error || error{Cancelled};

pub const LookupFn = *const fn (
    context: ?*anyopaque,
    alloc: Allocator,
    input: LookupInput,
) LookupError!LookupOutcome;

pub const Provider = struct {
    /// When set, context must remain valid until every in-flight lookup returns.
    context: ?*anyopaque = null,
    lookup_fn: LookupFn,

    /// A `.found` outcome owns its record strings; the caller must call
    /// `LookupOutcome.deinit`.
    pub fn lookup(
        self: Provider,
        alloc: Allocator,
        input: LookupInput,
    ) LookupError!LookupOutcome {
        return self.lookup_fn(self.context, alloc, input);
    }
};

fn lookupUnavailable(
    _: ?*anyopaque,
    _: Allocator,
    _: LookupInput,
) LookupError!LookupOutcome {
    return .preserve_pending;
}

pub const unavailable_provider = Provider{
    .lookup_fn = lookupUnavailable,
};

pub const ResolvedCredential = struct {
    token: []u8,
    tenant: ?[]u8 = null,

    pub fn initCopy(
        alloc: Allocator,
        token: []const u8,
        tenant: ?[]const u8,
    ) Allocator.Error!ResolvedCredential {
        var result = ResolvedCredential{ .token = try alloc.dupe(u8, token) };
        errdefer result.deinit(alloc);
        result.tenant = if (tenant) |value| try alloc.dupe(u8, value) else null;
        return result;
    }

    pub fn deinit(self: *ResolvedCredential, alloc: Allocator) void {
        secret.zeroAndFree(alloc, self.token);
        if (self.tenant) |tenant| alloc.free(tenant);
        self.* = undefined;
    }
};

test "resolved credential copy owns allocation failures" {
    const Case = struct {
        fn run(alloc: Allocator) !void {
            var credential = try ResolvedCredential.initCopy(alloc, "secret", "team");
            defer credential.deinit(alloc);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Case.run, .{});
}

test "resolved credential copy zeros a token when tenant allocation fails" {
    var buffer: ["secret".len]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&buffer);
    const backing = fixed.allocator();
    const vtable = Allocator.VTable{
        .alloc = backing.vtable.alloc,
        .resize = backing.vtable.resize,
        .remap = backing.vtable.remap,
        .free = Allocator.noFree,
    };
    const alloc = Allocator{ .ptr = backing.ptr, .vtable = &vtable };
    try std.testing.expectError(
        error.OutOfMemory,
        ResolvedCredential.initCopy(alloc, "secret", "team"),
    );
    for (buffer) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
}

pub const ResolveCredentialError = Allocator.Error || error{
    Cancelled,
    Unavailable,
};

pub const CredentialResolver = struct {
    /// When set, context must outlive every prepared dispatch using it.
    context: ?*anyopaque = null,
    resolve_fn: *const fn (
        context: ?*anyopaque,
        alloc: Allocator,
        reference: CredentialReference,
    ) ResolveCredentialError!ResolvedCredential,

    pub fn resolve(
        self: CredentialResolver,
        alloc: Allocator,
        reference: CredentialReference,
    ) ResolveCredentialError!ResolvedCredential {
        return self.resolve_fn(self.context, alloc, reference);
    }
};

pub const CredentialReference = struct {
    connection_id: []const u8,
    adapter_kind: []const u8,
    credential_ref: []const u8,
};

pub const ConnectionInput = struct {
    id: []const u8,
    adapter_kind: []const u8,
    credential_ref: []const u8,
    provider: ?Provider,
};

const Connection = struct {
    id: []u8,
    adapter_kind: []u8,
    credential_ref: []u8,
    provider: ?Provider,

    fn init(alloc: Allocator, input: ConnectionInput) Allocator.Error!Connection {
        const id = try alloc.dupe(u8, input.id);
        errdefer alloc.free(id);
        const adapter_kind = try alloc.dupe(u8, input.adapter_kind);
        errdefer alloc.free(adapter_kind);
        return .{
            .id = id,
            .adapter_kind = adapter_kind,
            .credential_ref = try alloc.dupe(u8, input.credential_ref),
            .provider = input.provider,
        };
    }

    fn deinit(self: *Connection, alloc: Allocator) void {
        alloc.free(self.id);
        alloc.free(self.adapter_kind);
        alloc.free(self.credential_ref);
        self.* = undefined;
    }
};

/// Owned, immutable connection routing prepared on the application owner
/// before the reconciliation worker starts. Credential bytes are resolved
/// only by `lookup` and are never retained by this value.
pub const Dispatch = struct {
    connections: []Connection,
    credential_resolver: CredentialResolver,

    pub fn init(
        alloc: Allocator,
        inputs: []const ConnectionInput,
        credential_resolver: CredentialResolver,
    ) Allocator.Error!Dispatch {
        const connections = try alloc.alloc(Connection, inputs.len);
        errdefer alloc.free(connections);
        var initialized: usize = 0;
        errdefer for (connections[0..initialized]) |*connection| connection.deinit(alloc);
        for (inputs, 0..) |input, index| {
            connections[index] = try Connection.init(alloc, input);
            initialized += 1;
        }
        return .{
            .connections = connections,
            .credential_resolver = credential_resolver,
        };
    }

    pub fn deinit(self: *Dispatch, alloc: Allocator) void {
        for (self.connections) |*connection| connection.deinit(alloc);
        alloc.free(self.connections);
        self.* = undefined;
    }

    pub fn lookup(
        self: Dispatch,
        alloc: Allocator,
        connection_id: []const u8,
        generation_id: []const u8,
        lookup_scope: ?[]const u8,
        cancel_flag: *std.atomic.Value(bool),
    ) LookupError!LookupOutcome {
        if (cancel_flag.load(.seq_cst)) return error.Cancelled;
        const connection = for (self.connections) |connection| {
            if (std.mem.eql(u8, connection.id, connection_id)) break connection;
        } else return .preserve_pending;
        const provider = connection.provider orelse return .preserve_pending;
        var credential = self.credential_resolver.resolve(
            alloc,
            .{
                .connection_id = connection.id,
                .adapter_kind = connection.adapter_kind,
                .credential_ref = connection.credential_ref,
            },
        ) catch |err| switch (err) {
            error.Cancelled => return error.Cancelled,
            error.OutOfMemory => return error.OutOfMemory,
            error.Unavailable => return .preserve_pending,
        };
        defer credential.deinit(alloc);
        return provider.lookup(alloc, .{
            .credential = credential.token,
            .tenant = credential.tenant,
            .lookup_scope = lookup_scope,
            .generation_id = generation_id,
            .cancel_flag = cancel_flag,
        });
    }
};

pub const PrepareError = Allocator.Error || error{Unavailable};

pub const Source = struct {
    /// Preparation runs on the owning application thread before worker spawn.
    context: ?*anyopaque = null,
    prepare_fn: *const fn (
        context: ?*anyopaque,
        alloc: Allocator,
    ) PrepareError!Dispatch,

    pub fn prepare(self: Source, alloc: Allocator) PrepareError!Dispatch {
        return self.prepare_fn(self.context, alloc);
    }
};

fn prepareUnavailable(_: ?*anyopaque, _: Allocator) PrepareError!Dispatch {
    return error.Unavailable;
}

pub const unavailable_source = Source{
    .prepare_fn = prepareUnavailable,
};

test "generation usage lookup dispatches through the injected provider" {
    const Fake = struct {
        calls: usize = 0,
        saw_expected_input: bool = false,

        fn lookup(
            raw_context: ?*anyopaque,
            alloc: Allocator,
            input: LookupInput,
        ) LookupError!LookupOutcome {
            const self: *@This() = @ptrCast(@alignCast(raw_context.?));
            self.calls += 1;
            self.saw_expected_input =
                std.mem.eql(u8, "credential", input.credential) and
                std.mem.eql(u8, "generation", input.generation_id) and
                std.mem.eql(u8, "scope", input.lookup_scope.?);
            const id = try alloc.dupe(u8, input.generation_id);
            errdefer alloc.free(id);
            const model = try alloc.dupe(u8, "provider/model");
            return .{ .found = .{
                .id = id,
                .model = model,
                .total_cost = 1,
                .input_tokens = 2,
                .output_tokens = 3,
                .cache_read_tokens = 0,
                .cache_write_tokens = 0,
                .billable_web_search_calls = 0,
            } };
        }
    };

    var fake: Fake = .{};
    const provider = Provider{
        .context = &fake,
        .lookup_fn = Fake.lookup,
    };
    var cancel = std.atomic.Value(bool).init(false);
    var outcome = try provider.lookup(std.testing.allocator, .{
        .credential = "credential",
        .tenant = null,
        .lookup_scope = "scope",
        .generation_id = "generation",
        .cancel_flag = &cancel,
    });
    defer outcome.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), fake.calls);
    try std.testing.expect(fake.saw_expected_input);
    try std.testing.expectEqualStrings("provider/model", outcome.found.model);
}

test "generation usage dispatch is connection scoped and missing connections are effect free" {
    const Fake = struct {
        calls: usize = 0,
        resolved: usize = 0,

        fn resolve(
            raw: ?*anyopaque,
            alloc: Allocator,
            reference: CredentialReference,
        ) ResolveCredentialError!ResolvedCredential {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            if (!std.mem.eql(u8, reference.connection_id, "connection-a") or
                !std.mem.eql(u8, reference.adapter_kind, "adapter-a"))
            {
                return error.Unavailable;
            }
            self.resolved += 1;
            return .{ .token = try alloc.dupe(u8, reference.credential_ref) };
        }

        fn lookup(
            raw: ?*anyopaque,
            _: Allocator,
            input: LookupInput,
        ) LookupError!LookupOutcome {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.calls += 1;
            if (!std.mem.eql(u8, "credential-a", input.credential)) return error.Cancelled;
            return .retry;
        }
    };

    var fake: Fake = .{};
    const provider = Provider{ .context = &fake, .lookup_fn = Fake.lookup };
    var dispatch = try Dispatch.init(
        std.testing.allocator,
        &.{.{
            .id = "connection-a",
            .adapter_kind = "adapter-a",
            .credential_ref = "credential-a",
            .provider = provider,
        }},
        .{ .context = &fake, .resolve_fn = Fake.resolve },
    );
    defer dispatch.deinit(std.testing.allocator);
    var cancel = std.atomic.Value(bool).init(false);

    try std.testing.expectEqual(
        LookupOutcome.retry,
        try dispatch.lookup(
            std.testing.allocator,
            "connection-a",
            "generation-a",
            "scope-a",
            &cancel,
        ),
    );
    try std.testing.expectEqual(@as(usize, 1), fake.resolved);
    try std.testing.expectEqual(@as(usize, 1), fake.calls);

    try std.testing.expectEqual(
        LookupOutcome.preserve_pending,
        try dispatch.lookup(
            std.testing.allocator,
            "missing",
            "generation-missing",
            "scope-missing",
            &cancel,
        ),
    );
    try std.testing.expectEqual(@as(usize, 1), fake.resolved);
    try std.testing.expectEqual(@as(usize, 1), fake.calls);

    cancel.store(true, .seq_cst);
    try std.testing.expectError(
        error.Cancelled,
        dispatch.lookup(
            std.testing.allocator,
            "connection-a",
            "generation-cancelled",
            null,
            &cancel,
        ),
    );
    try std.testing.expectEqual(@as(usize, 1), fake.resolved);
    try std.testing.expectEqual(@as(usize, 1), fake.calls);

    cancel.store(false, .seq_cst);
    var mismatched = try Dispatch.init(
        std.testing.allocator,
        &.{.{
            .id = "connection-a",
            .adapter_kind = "adapter-b",
            .credential_ref = "credential-b",
            .provider = provider,
        }},
        .{ .context = &fake, .resolve_fn = Fake.resolve },
    );
    defer mismatched.deinit(std.testing.allocator);
    try std.testing.expectEqual(
        LookupOutcome.preserve_pending,
        try mismatched.lookup(
            std.testing.allocator,
            "connection-a",
            "generation-mismatched",
            null,
            &cancel,
        ),
    );
    try std.testing.expectEqual(@as(usize, 1), fake.resolved);
    try std.testing.expectEqual(@as(usize, 1), fake.calls);
}
