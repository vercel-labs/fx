//! Launch-time checks for `--model`, `--fast`, `--ultrafast` and `--effort`.
//!
//! Interactive launch and `fx ask` share these pure decisions. Callers supply
//! what the loaded catalog says and apply the result: `fx ask` refuses to
//! start, while the interactive shell corrects its selection with a notice.
const std = @import("std");
const types = @import("../shared/types.zig");
const model_provider = @import("../config/model_provider.zig");
const model_capabilities = @import("../config/model_capabilities.zig");
const model_contract = @import("../subagent/model_contract.zig");

const Allocator = std.mem.Allocator;

pub const Code = enum {
    unknown_model,
    ambiguous_model,
    unsupported_fast,
    unsupported_ultrafast,
    unsupported_effort,

    /// Stable code reported as the `error` field of `fx ask --json`.
    /// Ultrafast keeps the code its turn-time check already reports.
    pub fn errorCode(self: Code) []const u8 {
        return switch (self) {
            .unknown_model => "UnknownModel",
            .ambiguous_model => "AmbiguousModel",
            .unsupported_fast => "UnsupportedFast",
            .unsupported_ultrafast => "UltrafastUnavailable",
            .unsupported_effort => "UnsupportedEffort",
        };
    }
};

/// A rejected launch flag. The caller owns `message`, which names the model.
pub const Rejection = struct {
    code: Code,
    message: []u8,

    pub fn deinit(self: Rejection, alloc: Allocator) void {
        alloc.free(self.message);
    }
};

/// Result of checking `--model` text against a loaded catalog. The caller
/// owns the payload and releases it with `deinit`.
pub const ModelCheck = union(enum) {
    /// No catalog to judge by, or one that may hide the model: keep the text.
    unchanged,
    /// The catalog ID the text names.
    resolved: []const u8,
    rejected: Rejection,

    pub fn deinit(self: ModelCheck, alloc: Allocator) void {
        switch (self) {
            .unchanged => {},
            .resolved => |id| alloc.free(id),
            .rejected => |rejection| rejection.deinit(alloc),
        }
    }
};

/// Matches `--model` text against `catalog_ids` with the same scoring as
/// `/model`: an exact ID or a unique confident partial resolves. Only a
/// catalog that lists every available model may reject unknown or ambiguous
/// text; with any other catalog the text passes through unchanged. An
/// ambiguous rejection names its candidates; an unknown one points to
/// `fx models`, because weak matches against a large catalog mislead.
pub fn checkModel(
    alloc: Allocator,
    catalog_ids: []const []const u8,
    lists_every_available_model: bool,
    raw: []const u8,
) Allocator.Error!ModelCheck {
    switch (try model_contract.matchCatalogModel(alloc, catalog_ids, raw)) {
        .no_catalog => return .unchanged,
        .matched => |id| return .{ .resolved = id },
        .ambiguous => |candidates| {
            defer freeCandidates(alloc, candidates);
            if (!lists_every_available_model) return .unchanged;
            return .{ .rejected = .{
                .code = .ambiguous_model,
                .message = try ambiguousMessage(alloc, raw, candidates),
            } };
        },
        .unknown => |candidates| {
            defer freeCandidates(alloc, candidates);
            if (!lists_every_available_model) return .unchanged;
            return .{ .rejected = .{
                .code = .unknown_model,
                .message = try alloc.print("Unknown model \"{s}\". Run fx models to list models.", .{raw}),
            } };
        },
    }
}

/// Speed and effort requested by launch flags. Only flags the user passed
/// are checked; `false` and `null` mean the flag was absent or turned off.
pub const TurnOptions = struct {
    fast: bool = false,
    ultrafast: bool = false,
    effort: ?types.ReasoningEffort = null,

    /// Keeps only what needs checking: an explicit `--fast`, `--ultrafast`,
    /// or a non-default `--effort`.
    pub fn fromFlags(fast: ?bool, ultrafast: ?bool, effort: ?types.ReasoningEffort) TurnOptions {
        return .{
            .fast = fast orelse false,
            .ultrafast = ultrafast orelse false,
            .effort = if (effort) |value| (if (value.isDefault()) null else value) else null,
        };
    }

    pub fn any(self: TurnOptions) bool {
        return self.fast or self.ultrafast or self.effort != null;
    }
};

/// Launch flags waiting for the interactive shell's first catalog load.
/// Owns `model`, the `--model` text.
pub const Pending = struct {
    model: ?[]u8 = null,
    turn: TurnOptions = .{},

    /// Captures the flags that need checking, or null when there are none.
    pub fn init(alloc: Allocator, model: ?[]const u8, turn: TurnOptions) Allocator.Error!?Pending {
        if (model == null and !turn.any()) return null;
        return .{ .model = if (model) |text| try alloc.dupe(u8, text) else null, .turn = turn };
    }

    pub fn deinit(self: Pending, alloc: Allocator) void {
        if (self.model) |text| alloc.free(text);
    }
};

/// Checks requested speed and effort for `model`. `listed` holds the model's
/// capabilities when the loaded catalog lists it, else null. Fast and effort
/// are judged only against listed capabilities, so an unavailable catalog
/// never rejects them. Ultrafast always needs a listed Gateway capability,
/// matching the turn-time gate. The caller frees a returned rejection.
pub fn checkTurnOptions(
    alloc: Allocator,
    provider: model_provider.ProviderId,
    model: []const u8,
    listed: ?model_capabilities.Capabilities,
    request: TurnOptions,
) Allocator.Error!?Rejection {
    if (request.ultrafast) {
        if (try model_capabilities.ultrafastRejection(alloc, provider, listed orelse .{}, model)) |message| {
            return .{ .code = .unsupported_ultrafast, .message = message };
        }
    }
    const capabilities = listed orelse return null;
    if (request.fast) {
        var fast_capabilities = capabilities;
        fast_capabilities.intrinsic_fast = fast_capabilities.intrinsic_fast or
            model_capabilities.capabilitiesForModel(model).intrinsic_fast;
        if (try model_capabilities.fastRejection(alloc, fast_capabilities, model)) |message| {
            return .{ .code = .unsupported_fast, .message = message };
        }
    }
    if (request.effort) |effort| {
        if (capabilities.reasoning_efforts.len == 0 and !effort.isDefault()) {
            // The shared message says "the active model"; launch flags name it.
            return .{ .code = .unsupported_effort, .message = try alloc.print(
                "Reasoning effort \"{s}\" is not available for model \"{s}\", which has no effort levels",
                .{ effort.label(), model },
            ) };
        }
        if (try model_capabilities.effortRejection(alloc, capabilities, effort, model)) |message| {
            return .{ .code = .unsupported_effort, .message = message };
        }
    }
    return null;
}

fn freeCandidates(alloc: Allocator, candidates: []const []const u8) void {
    for (candidates) |candidate| alloc.free(candidate);
    alloc.free(candidates);
}

fn writeList(writer: *std.Io.Writer, items: []const []const u8) std.Io.Writer.Error!void {
    for (items, 0..) |item, index| {
        if (index > 0) try writer.writeAll(", ");
        try writer.writeAll(item);
    }
}

fn ambiguousMessage(alloc: Allocator, raw: []const u8, candidates: []const []const u8) Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const writer = &out.writer;
    writer.print("Model \"{s}\" matches several catalog models: ", .{raw}) catch return error.OutOfMemory;
    writeList(writer, candidates) catch return error.OutOfMemory;
    writer.writeAll(". Use an exact model ID.") catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

const test_ids = [_][]const u8{
    "openai/mfv-full",
    "anthropic/mfv-plain",
    "openai/mfv-terra-one",
    "openai/mfv-terra-two",
};

fn expectResolved(expected: []const u8, check: ModelCheck) !void {
    switch (check) {
        .resolved => |id| try std.testing.expectEqualStrings(expected, id),
        else => return error.TestExpectedResolved,
    }
}

fn expectRejected(code: Code, needles: []const []const u8, check: ModelCheck) !void {
    switch (check) {
        .rejected => |rejection| {
            try std.testing.expectEqual(code, rejection.code);
            for (needles) |needle| try std.testing.expect(std.mem.find(u8, rejection.message, needle) != null);
        },
        else => return error.TestExpectedRejected,
    }
}

test "checkModel resolves exact and unique partial names to catalog IDs" {
    const alloc = std.testing.allocator;
    const exact = try checkModel(alloc, &test_ids, true, "OpenAI/MFV-Full");
    defer exact.deinit(alloc);
    try expectResolved("openai/mfv-full", exact);

    const partial = try checkModel(alloc, &test_ids, false, "mfv-plain");
    defer partial.deinit(alloc);
    try expectResolved("anthropic/mfv-plain", partial);
}

test "checkModel rejects unknown and ambiguous names only with a complete catalog" {
    const alloc = std.testing.allocator;
    const unknown = try checkModel(alloc, &test_ids, true, "totally/not-a-real-model");
    defer unknown.deinit(alloc);
    try expectRejected(.unknown_model, &.{ "Unknown model \"totally/not-a-real-model\"", "fx models" }, unknown);

    const ambiguous = try checkModel(alloc, &test_ids, true, "mfv-terra");
    defer ambiguous.deinit(alloc);
    try expectRejected(.ambiguous_model, &.{ "\"mfv-terra\"", "openai/mfv-terra-one", "openai/mfv-terra-two" }, ambiguous);

    for ([_][]const u8{ "totally/not-a-real-model", "mfv-terra", "team/mfv-private" }) |raw| {
        const partial_catalog = try checkModel(alloc, &test_ids, false, raw);
        defer partial_catalog.deinit(alloc);
        try std.testing.expect(partial_catalog == .unchanged);
    }

    const no_catalog = try checkModel(alloc, &.{}, true, "anything");
    try std.testing.expect(no_catalog == .unchanged);
}

test "checkModel releases every allocation when allocation fails" {
    const testing_allocator = @import("../shared/testing_allocator.zig");
    const Sweep = struct {
        fn run(alloc: Allocator, raw: []const u8) !void {
            const check = try checkModel(alloc, &test_ids, true, raw);
            check.deinit(alloc);
        }
    };
    for ([_][]const u8{ "mfv-plain", "mfv-terra", "totally/not-a-real-model" }) |raw| {
        try std.testing.checkAllAllocationFailures(testing_allocator.no_resize, Sweep.run, .{raw});
    }
}

test "checkTurnOptions judges Fast and effort only against listed capabilities" {
    const alloc = std.testing.allocator;
    const plain = model_capabilities.Capabilities{
        .reasoning_efforts = .fromSlice(&.{ types.ReasoningEffort.literal("low"), types.ReasoningEffort.literal("high") }),
    };
    const fast = model_capabilities.Capabilities{ .supports_fast_mode = true };

    const rejected_fast = (try checkTurnOptions(alloc, .gateway, "anthropic/mfv-plain", plain, .{ .fast = true })).?;
    defer rejected_fast.deinit(alloc);
    try std.testing.expectEqual(Code.unsupported_fast, rejected_fast.code);
    try std.testing.expectEqualStrings("Fast mode is not available for model \"anthropic/mfv-plain\"", rejected_fast.message);

    const rejected_effort = (try checkTurnOptions(alloc, .gateway, "anthropic/mfv-plain", plain, .{ .effort = .literal("minimal") })).?;
    defer rejected_effort.deinit(alloc);
    try std.testing.expectEqual(Code.unsupported_effort, rejected_effort.code);
    try std.testing.expect(std.mem.find(u8, rejected_effort.message, "low, high") != null);

    try std.testing.expectEqual(@as(?Rejection, null), try checkTurnOptions(alloc, .gateway, "openai/mfv-full", fast, .{ .fast = true }));
    try std.testing.expectEqual(@as(?Rejection, null), try checkTurnOptions(alloc, .gateway, "provider/model-fast", plain, .{ .fast = true }));
    try std.testing.expectEqual(@as(?Rejection, null), try checkTurnOptions(alloc, .gateway, "anthropic/mfv-plain", plain, .{ .effort = .literal("high") }));
    try std.testing.expectEqual(@as(?Rejection, null), try checkTurnOptions(alloc, .gateway, "anthropic/mfv-plain", plain, .{ .effort = .auto }));
    try std.testing.expectEqual(@as(?Rejection, null), try checkTurnOptions(alloc, .gateway, "team/unlisted", null, .{ .fast = true, .effort = .literal("minimal") }));

    const no_efforts = (try checkTurnOptions(alloc, .gateway, "provider/no-effort", .{}, .{ .effort = .literal("high") })).?;
    defer no_efforts.deinit(alloc);
    try std.testing.expectEqualStrings(
        "Reasoning effort \"high\" is not available for model \"provider/no-effort\", which has no effort levels",
        no_efforts.message,
    );
}

test "checkTurnOptions requires a listed Gateway capability for Ultrafast" {
    const alloc = std.testing.allocator;
    const ultra = model_capabilities.Capabilities{ .supports_ultrafast_mode = true };
    try std.testing.expectEqual(@as(?Rejection, null), try checkTurnOptions(alloc, .gateway, "openai/mfv-full", ultra, .{ .ultrafast = true }));

    for ([_]struct { provider: model_provider.ProviderId, listed: ?model_capabilities.Capabilities }{
        .{ .provider = .gateway, .listed = null },
        .{ .provider = .gateway, .listed = .{} },
        .{ .provider = .codex, .listed = ultra },
    }) |case| {
        const rejection = (try checkTurnOptions(alloc, case.provider, "openai/mfv-full", case.listed, .{ .ultrafast = true })).?;
        defer rejection.deinit(alloc);
        try std.testing.expectEqual(Code.unsupported_ultrafast, rejection.code);
        try std.testing.expectEqualStrings("Ultrafast mode is not available for model \"openai/mfv-full\"", rejection.message);
    }
}
