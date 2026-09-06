const std = @import("std");
const model_provider = @import("../config/model_provider.zig");

const Allocator = std.mem.Allocator;

pub const LookupInput = struct {
    credential: ?[]const u8,
    tenant: ?[]const u8,
    origin: []const u8,
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

pub const LookupError = Allocator.Error || error{
    Cancelled,
    Unavailable,
};

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
    return error.Unavailable;
}

pub const unavailable_provider = Provider{
    .lookup_fn = lookupUnavailable,
};

pub const Set = struct {
    gateway: ?Provider = null,
    codex: ?Provider = null,
    grok: ?Provider = null,

    pub fn gatewayOnly(provider: Provider) Set {
        return .{ .gateway = provider };
    }

    pub fn select(self: Set, provider: model_provider.ProviderId) ?Provider {
        return switch (provider) {
            .gateway => self.gateway,
            .codex => self.codex,
            .grok => self.grok,
        };
    }
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
                input.credential != null and
                std.mem.eql(u8, "credential", input.credential.?) and
                std.mem.eql(u8, "generation", input.generation_id);
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
        .origin = "https://provider.example",
        .generation_id = "generation",
        .cancel_flag = &cancel,
    });
    defer outcome.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), fake.calls);
    try std.testing.expect(fake.saw_expected_input);
    try std.testing.expectEqualStrings("provider/model", outcome.found.model);
}

test "generation usage lookup can defer authentication to the host" {
    const Fake = struct {
        fn lookup(_: ?*anyopaque, _: Allocator, input: LookupInput) LookupError!LookupOutcome {
            if (input.credential != null) return error.Unavailable;
            return .preserve_pending;
        }
    };
    var cancel = std.atomic.Value(bool).init(false);
    const outcome = try (Provider{ .lookup_fn = Fake.lookup }).lookup(std.testing.allocator, .{
        .credential = null,
        .tenant = null,
        .origin = "https://ai-gateway.vercel.sh",
        .generation_id = "gen_01ARZ3NDEKTSV4RRFFQ69G5FAV",
        .cancel_flag = &cancel,
    });
    try std.testing.expectEqual(LookupOutcome.preserve_pending, outcome);
}

test "generation usage providers are selected by provider identity" {
    const routes = Set.gatewayOnly(unavailable_provider);
    try std.testing.expect(routes.select(.gateway) != null);
    try std.testing.expect(routes.select(.codex) == null);
    try std.testing.expect(routes.select(.grok) == null);
}
