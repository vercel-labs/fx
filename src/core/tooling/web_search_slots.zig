//! Web search slots: the order in which fx offers web search, and what it has
//! learned about the current team.
//!
//! Each Gateway request carries at most one search tool: the first slot in the
//! configured order that is not blocked for the request's team and that the
//! request's model supports. When AI Gateway refuses a Gateway-executed search
//! tool for the team, the step loop records the refused slots here and sends
//! the request again, so it moves down the order and ends with no search tool
//! (`tests/tla/web_search/WebSearchSlots.tla` BoundedSends).
//!
//! `State` keys what it learned by the team: a request built for a different
//! team starts from an empty set, and a refusal for a team that is no longer
//! current changes nothing (NoStaleSkip). One atomic word holds the team and
//! the blocked slots, and only the caller whose compare-and-swap sets a slot
//! learns that it is new, so each slot gets one notice per team (OneNotice).
//! Nothing here is saved: a new fx process starts with an empty set.
//!
//! This file imports only `std`, so `tests/tla/drivers/web_search/lab.zig`
//! builds against it.

const std = @import("std");

pub const Slot = enum(u3) {
    exa = 0,
    native = 1,
    parallel = 2,
    perplexity = 3,
    /// No search tool. Never configured; the resolver returns it when no
    /// configured slot is left.
    none = 4,

    pub fn name(slot: Slot) []const u8 {
        return switch (slot) {
            .exa => "exa",
            .native => "native",
            .parallel => "parallel",
            .perplexity => "perplexity",
            .none => "none",
        };
    }

    fn bit(slot: Slot) u8 {
        return @as(u8, 1) << @backingInt(slot);
    }
};

/// The slots a user can configure.
pub const configurable = [_]Slot{ .exa, .native, .parallel, .perplexity };
pub const max_order_len = configurable.len;

/// The configured order. An empty order sends no search tool.
pub const Order = struct {
    len: u8 = configurable.len,
    slots: [max_order_len]Slot = configurable,

    pub fn items(order: *const Order) []const Slot {
        return order.slots[0..order.len];
    }
};

pub const default_order: Order = .{};

/// Case-insensitive, ignoring surrounding spaces.
pub fn parseName(raw: []const u8) ?Slot {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    for (configurable) |slot| {
        if (std.ascii.eqlIgnoreCase(trimmed, slot.name())) return slot;
    }
    return null;
}

pub const OrderError = error{
    TooManyWebSearchBackends,
    UnknownWebSearchBackend,
    DuplicateWebSearchBackend,
};

/// Parses a configured order. On an unknown or repeated name, `offending`
/// receives that name, borrowed from `names`, so the error can name it.
pub fn parseOrder(names: []const []const u8, offending: ?*[]const u8) OrderError!Order {
    if (names.len > max_order_len) return error.TooManyWebSearchBackends;
    var order: Order = .{ .len = @intCast(names.len) };
    for (names, 0..) |raw, index| {
        const slot = parseName(raw) orelse {
            if (offending) |out| out.* = raw;
            return error.UnknownWebSearchBackend;
        };
        for (order.slots[0..index]) |previous| if (previous == slot) {
            if (offending) |out| out.* = raw;
            return error.DuplicateWebSearchBackend;
        };
        order.slots[index] = slot;
    }
    return order;
}

/// The first slot in `order` that is not in `blocked` and that the model
/// supports, or `.none`.
pub fn resolve(order: Order, blocked: u8, native_supported: bool) Slot {
    for (order.items()) |slot| {
        if (blocked & slot.bit() != 0) continue;
        if (slot == .native and !native_supported) continue;
        return slot;
    }
    return .none;
}

/// What one request sees: the configured order and the slots its team has
/// refused. The default is the default order with nothing blocked.
pub const View = struct {
    order: Order = default_order,
    blocked: u8 = 0,

    pub fn slot(view: View, native_supported: bool) Slot {
        return resolve(view.order, view.blocked, native_supported);
    }
};

/// A model provider with its own search tool. Which models have one is fx's
/// table, not the Gateway catalog's `web-search` tag, which some models that
/// search natively do not carry.
pub const NativeFamily = enum { anthropic, openai, google };

pub fn nativeFamily(model: []const u8) ?NativeFamily {
    if (std.mem.startsWith(u8, model, "anthropic/")) return .anthropic;
    if (std.mem.startsWith(u8, model, "openai/")) return .openai;
    if (std.mem.startsWith(u8, model, "google/")) return .google;
    return null;
}

pub fn nativeSupported(model: []const u8) bool {
    return nativeFamily(model) != null;
}

/// The Gateway tool id a slot sends, for the slots the Gateway runs.
pub fn gatewayToolId(slot: Slot) ?[]const u8 {
    return switch (slot) {
        .exa => "gateway.exa_search",
        .parallel => "gateway.parallel_search",
        .perplexity => "gateway.perplexity_search",
        .native, .none => null,
    };
}

const refusal_prefix = "Gateway-executed tool(s) are not available for this team: ";
/// The refusal lists the tools the request carried, and fx sends at most one
/// search tool, so the classifier reads only the first few ids.
const max_refusal_ids = 16;

/// The slots a Gateway refusal names, as bits, or 0 for any other error.
/// AI Gateway sends this refusal for a contained team, a BYOK-only team, and
/// a team whose fallback is off; each says to remove the tools. Only ids in
/// fx's own table count, so a body can remove a slot but never add one.
pub fn refusedSlots(body: []const u8) u8 {
    const start = std.mem.find(u8, body, refusal_prefix) orelse return 0;
    const rest = body[start + refusal_prefix.len ..];
    var bits: u8 = 0;
    var cursor: usize = 0;
    var read: usize = 0;
    while (read < max_refusal_ids and cursor < rest.len) : (read += 1) {
        const tail = rest[cursor..];
        const comma = std.mem.find(u8, tail, ", ");
        const stop = std.mem.find(u8, tail, ". ") orelse std.mem.findScalar(u8, tail, '"') orelse tail.len;
        const end = if (comma) |at| @min(at, stop) else stop;
        const id = std.mem.trim(u8, tail[0..end], " .");
        for ([_]Slot{ .exa, .parallel, .perplexity }) |slot| {
            if (std.mem.eql(u8, id, gatewayToolId(slot).?)) bits |= slot.bit();
        }
        if (comma == null or comma.? > stop) break;
        cursor += end + 2;
    }
    return bits;
}

/// A 24-bit tag for the team, so one word holds the team and its slots.
/// No team (an API key without one) is tag 0.
pub fn teamTag(team: ?[]const u8) u32 {
    const value = team orelse return 0;
    if (value.len == 0) return 0;
    return @as(u32, @truncate(std.hash.Fnv1a_32.hash(value))) & tag_mask;
}

const tag_mask: u32 = 0xff_ffff;
const tag_shift = 8;
const bits_mask: u32 = 0xff;

fn tagOf(word: u32) u32 {
    return word >> tag_shift;
}

fn bitsOf(word: u32) u8 {
    return @intCast(word & bits_mask);
}

fn wordOf(tag: u32, bits: u8) u32 {
    return (tag << tag_shift) | bits;
}

/// The order and what the current team has refused. One per fx host process
/// part that sends requests (the TUI app, `fx ask`, the ACP server), shared
/// by its main agent and its subagents.
pub const State = struct {
    word: std.atomic.Value(u32) = .init(0),
    order_word: std.atomic.Value(u32) = .init(encodeOrder(default_order)),

    pub fn setOrder(state: *State, order: Order) void {
        state.order_word.store(encodeOrder(order), .seq_cst);
    }

    pub fn configuredOrder(state: *const State) Order {
        return decodeOrder(state.order_word.load(.seq_cst));
    }

    /// The view for a request built for `team`. A team that differs from
    /// the current one becomes current with nothing blocked
    /// (`tests/tla/web_search/WebSearchSlots.tla` SwitchTeam).
    pub fn view(state: *State, team: ?[]const u8) View {
        const tag = teamTag(team);
        var current = state.word.load(.seq_cst);
        while (tagOf(current) != tag) {
            current = state.word.cmpxchgWeak(current, wordOf(tag, 0), .seq_cst, .seq_cst) orelse wordOf(tag, 0);
        }
        return .{ .order = state.configuredOrder(), .blocked = bitsOf(current) };
    }

    /// What `team` has refused, read without making it current: the TLA
    /// driver compares this with the model's blocked set.
    pub fn blockedFor(state: *const State, team: ?[]const u8) u8 {
        const current = state.word.load(.seq_cst);
        return if (tagOf(current) == teamTag(team)) bitsOf(current) else 0;
    }

    /// Records slots the Gateway refused for a request built for `team` and
    /// returns the ones this call newly set, for the one notice each. A
    /// refusal for a team that is no longer current changes nothing
    /// (BlockAtomic, NoStaleSkip).
    pub fn block(state: *State, team: ?[]const u8, bits: u8) u8 {
        const tag = teamTag(team);
        var current = state.word.load(.seq_cst);
        while (true) {
            if (tagOf(current) != tag) return 0;
            const next = current | bits;
            if (next == current) return 0;
            current = state.word.cmpxchgWeak(current, next, .seq_cst, .seq_cst) orelse
                return bits & ~bitsOf(current);
        }
    }
};

fn encodeOrder(order: Order) u32 {
    var value: u32 = order.len;
    for (order.slots, 0..) |slot, index| value |= @as(u32, @backingInt(slot)) << @intCast(8 + 3 * index);
    return value;
}

fn decodeOrder(value: u32) Order {
    var order: Order = .{ .len = @intCast(value & 0xff) };
    for (&order.slots, 0..) |*slot, index| {
        slot.* = @fromBackingInt(@intCast(@as(u3, @truncate(value >> @intCast(8 + 3 * index)))));
    }
    return order;
}

// Tests.

fn testOrder(slots: []const Slot) Order {
    var order: Order = .{ .len = @intCast(slots.len) };
    @memcpy(order.slots[0..slots.len], slots);
    return order;
}

test "the resolver returns the first eligible slot for every order, blocked set, and model" {
    // Every order: each permutation of each subset of the four slots (65).
    var orders: std.ArrayList(Order) = .empty;
    defer orders.deinit(std.testing.allocator);
    var buffer: [max_order_len]Slot = undefined;
    try collectOrders(&orders, &buffer, 0, 0);
    try std.testing.expectEqual(@as(usize, 65), orders.items.len);

    for (orders.items) |order| {
        for (0..16) |blocked_index| {
            const blocked: u8 = @intCast(blocked_index);
            for ([_]bool{ false, true }) |native_supported| {
                const slot = resolve(order, blocked, native_supported);
                if (slot == .none) {
                    for (order.items()) |candidate| {
                        try std.testing.expect(blocked & candidate.bit() != 0 or (candidate == .native and !native_supported));
                    }
                    continue;
                }
                try std.testing.expect(blocked & slot.bit() == 0);
                try std.testing.expect(slot != .native or native_supported);
                const at = std.mem.findScalar(Slot, order.items(), slot).?;
                for (order.items()[0..at]) |earlier| {
                    try std.testing.expect(blocked & earlier.bit() != 0 or (earlier == .native and !native_supported));
                }
            }
        }
    }
}

fn collectOrders(out: *std.ArrayList(Order), buffer: *[max_order_len]Slot, len: usize, used: u8) !void {
    try out.append(std.testing.allocator, testOrder(buffer[0..len]));
    for (configurable) |slot| {
        if (used & slot.bit() != 0) continue;
        buffer[len] = slot;
        try collectOrders(out, buffer, len + 1, used | slot.bit());
    }
}

test "the configured order parses names and names what it refuses" {
    try std.testing.expectEqualDeep(default_order, try parseOrder(&.{ "exa", "native", "parallel", "perplexity" }, null));
    try std.testing.expectEqualDeep(testOrder(&.{ .parallel, .exa }), try parseOrder(&.{ " Parallel ", "EXA" }, null));
    try std.testing.expectEqualDeep(testOrder(&.{}), try parseOrder(&.{}, null));

    var offending: []const u8 = "";
    try std.testing.expectError(error.UnknownWebSearchBackend, parseOrder(&.{ "exa", "bing" }, &offending));
    try std.testing.expectEqualStrings("bing", offending);
    try std.testing.expectError(error.DuplicateWebSearchBackend, parseOrder(&.{ "exa", "Exa" }, &offending));
    try std.testing.expectEqualStrings("Exa", offending);
    try std.testing.expectError(error.TooManyWebSearchBackends, parseOrder(&.{ "exa", "native", "parallel", "perplexity", "exa" }, null));
    try std.testing.expectError(error.UnknownWebSearchBackend, parseOrder(&.{"none"}, null));
}

test "the refusal classifier reads only the Gateway's refusal and only known ids" {
    const two = "{\"error\":{\"message\":\"Gateway-executed tool(s) are not available for this team: gateway.exa_search, gateway.parallel_search. They send request content to vendor(s) outside this team's permitted provider set (exa, parallel). Remove the tool(s) to proceed.\",\"type\":\"invalid_request_error\"}}";
    try std.testing.expectEqual(Slot.exa.bit() | Slot.parallel.bit(), refusedSlots(two));
    const byok = "Gateway-executed tool(s) are not available for this team: gateway.perplexity_search. They run on Vercel-held vendor credentials. Remove the tool(s) to proceed.";
    try std.testing.expectEqual(Slot.perplexity.bit(), refusedSlots(byok));
    const at_end = "Gateway-executed tool(s) are not available for this team: gateway.exa_search\"}}";
    try std.testing.expectEqual(Slot.exa.bit(), refusedSlots(at_end));
    try std.testing.expectEqual(@as(u8, 0), refusedSlots("{\"error\":{\"message\":\"invalid tool schema\"}}"));
    try std.testing.expectEqual(@as(u8, 0), refusedSlots("Gateway-executed tool(s) are not available for this team: gateway.tako_search. Remove"));
    try std.testing.expectEqual(@as(u8, 0), refusedSlots("Gateway-executed tool(s) are not available for this team: "));
    try std.testing.expectEqual(@as(u8, 0), refusedSlots("gateway.exa_search"));
    // Past the first ids the classifier stops reading.
    var many: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer many.deinit();
    try many.writer.writeAll(refusal_prefix);
    for (0..max_refusal_ids) |index| try many.writer.print("gateway.tool_{d}, ", .{index});
    try many.writer.writeAll("gateway.exa_search. Remove the tool(s) to proceed.");
    try std.testing.expectEqual(@as(u8, 0), refusedSlots(many.written()));
}

test "the blocked set is keyed by team and each slot is new once" {
    var state: State = .{};
    try std.testing.expectEqual(@as(u8, 0), state.view("team-a").blocked);
    try std.testing.expectEqual(Slot.exa.bit(), state.block("team-a", Slot.exa.bit()));
    try std.testing.expectEqual(@as(u8, 0), state.block("team-a", Slot.exa.bit()));
    try std.testing.expectEqual(Slot.exa.bit(), state.view("team-a").blocked);

    // A request for another team starts empty, and a late refusal for the
    // old team changes nothing.
    try std.testing.expectEqual(@as(u8, 0), state.view("team-b").blocked);
    try std.testing.expectEqual(@as(u8, 0), state.block("team-a", Slot.parallel.bit()));
    try std.testing.expectEqual(@as(u8, 0), state.view("team-b").blocked);
    try std.testing.expectEqual(Slot.exa.bit(), state.block("team-b", Slot.exa.bit()));

    // No team is its own team.
    try std.testing.expectEqual(@as(u8, 0), state.view(null).blocked);
    try std.testing.expectEqual(@as(u8, 0), state.block("team-b", Slot.perplexity.bit()));

    state.setOrder(testOrder(&.{ .perplexity, .native }));
    try std.testing.expectEqualDeep(testOrder(&.{ .perplexity, .native }), state.view(null).order);
}

test "racing blockers on one team set each slot once and lose none" {
    var state: State = .{};
    _ = state.view("team");
    const thread_count = 16;
    const rounds = 4000;
    var newly: [thread_count]u8 = @splat(0);
    var counts: [thread_count][4]u32 = @splat(@splat(0));
    const Worker = struct {
        fn run(shared: *State, seed: u64, out: *u8, count: *[4]u32) void {
            var prng: std.Random.DefaultPrng = .init(seed);
            const random = prng.random();
            for (0..rounds) |_| {
                const slot = configurable[random.uintLessThan(usize, configurable.len)];
                const got = shared.block("team", slot.bit());
                out.* |= got;
                for (configurable, 0..) |candidate, index| {
                    if (got & candidate.bit() != 0) count[index] += 1;
                }
                _ = shared.view("team");
            }
        }
    };
    var threads: [thread_count]std.Thread = undefined;
    for (&threads, 0..) |*thread, index| {
        thread.* = try std.Thread.spawn(.{}, Worker.run, .{ &state, 0x5107 + index, &newly[index], &counts[index] });
    }
    for (threads) |thread| thread.join();
    var union_bits: u8 = 0;
    for (newly) |bits| union_bits |= bits;
    try std.testing.expectEqual(state.view("team").blocked, union_bits);
    for (0..configurable.len) |slot_index| {
        var total: u32 = 0;
        for (counts) |per_thread| total += per_thread[slot_index];
        try std.testing.expect(total <= 1);
    }
}

test "a stress run of 64 threads switching teams keeps the team key and the bound" {
    var state: State = .{};
    const thread_count = 64;
    const rounds = 20_000;
    const teams = [_][]const u8{ "team-a", "team-b", "team-c" };
    var violations = std.atomic.Value(u32).init(0);
    const Worker = struct {
        fn run(shared: *State, seed: u64, bad: *std.atomic.Value(u32)) void {
            var prng: std.Random.DefaultPrng = .init(seed);
            const random = prng.random();
            for (0..rounds) |_| {
                const team = teams[random.uintLessThan(usize, teams.len)];
                const seen = shared.view(team);
                const slot = seen.slot(random.boolean());
                if (slot == .none or slot == .native) continue;
                if (seen.blocked & slot.bit() != 0) _ = bad.fetchAdd(1, .seq_cst);
                const got = shared.block(team, slot.bit());
                if (got & ~slot.bit() != 0) _ = bad.fetchAdd(1, .seq_cst);
            }
        }
    };
    var threads: [thread_count]std.Thread = undefined;
    for (&threads, 0..) |*thread, index| {
        thread.* = try std.Thread.spawn(.{}, Worker.run, .{ &state, 0xfeed + index, &violations });
    }
    for (threads) |thread| thread.join();
    try std.testing.expectEqual(@as(u32, 0), violations.load(.seq_cst));
    const final = state.word.load(.seq_cst);
    var known_tag = false;
    for (teams) |team| known_tag = known_tag or tagOf(final) == teamTag(team);
    try std.testing.expect(known_tag);
}

fn fuzzRefusal(_: void, smith: *std.testing.Smith) !void {
    var buffer: [4096]u8 = undefined;
    const len = smith.slice(&buffer);
    const body = buffer[0..len];
    const bits = refusedSlots(body);
    // Only Gateway slots, and only when the body is the refusal.
    try std.testing.expectEqual(@as(u8, 0), bits & ~(Slot.exa.bit() | Slot.parallel.bit() | Slot.perplexity.bit()));
    if (bits != 0) try std.testing.expect(std.mem.find(u8, body, refusal_prefix) != null);

    var names: [max_order_len + 1][]const u8 = undefined;
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, body, ',');
    while (it.next()) |name| : (count += 1) {
        if (count == names.len) break;
        names[count] = name;
    }
    var offending: []const u8 = "";
    if (parseOrder(names[0..count], &offending)) |order| {
        try std.testing.expect(order.len <= max_order_len);
        var state: State = .{};
        state.setOrder(order);
        _ = state.block(null, bits);
        try std.testing.expectEqualDeep(order, state.view(null).order);
        try std.testing.expect(state.view(null).slot(true) != .exa or bits & Slot.exa.bit() == 0);
    } else |_| {}
}

test "the web search refusal classifier and order parser hold for fuzzed bytes" {
    try std.testing.fuzz({}, fuzzRefusal, .{
        .corpus = &(@import("fuzz_seed").slices(.{
            "Gateway-executed tool(s) are not available for this team: gateway.exa_search. Remove the tool(s) to proceed.",
            "Gateway-executed tool(s) are not available for this team: gateway.exa_search, gateway.parallel_search, gateway.perplexity_search.",
            "exa,native,parallel,perplexity",
            "Gateway-executed tool(s) are not available for this team: ",
            "",
        }) ++ @import("fuzz_corpus").web_search_refusal.*),
    });
}
