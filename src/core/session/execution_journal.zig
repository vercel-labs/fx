//! Acknowledged execution records for one durable conversation. The runtime owns
//! decisions; this state validates and indexes them without executing effects.
const std = @import("std");
const codec = @import("execution_journal_codec.zig");

const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const max_records = 16_384;
const checkpoint_header_reserve = 128;
const max_sequence: u64 = 9_007_199_254_740_991;
const max_calls = 256;

pub const Kind = codec.Kind;
pub const Entry = codec.Entry;
pub const Replay = enum { blocked, safe };

/// Borrows the entry for the callback. Success acknowledges durable storage of
/// these exact bytes. The caller retains neither this callback nor its context.
pub const Sink = struct {
    context: *anyopaque,
    append_fn: *const fn (*anyopaque, Entry) anyerror!void,
    /// Native readers share this guard with the entire prepare/write/adopt
    /// boundary, so an in-flight write is never mistaken for a failed owner.
    guard: ?struct {
        enter: *const fn (*anyopaque) void,
        leave: *const fn (*anyopaque) void,
    } = null,
};

/// Typed payload validation runs against the acknowledged prefix before the
/// candidate is adopted. It must not mutate the prefix or execute effects.
pub const Validator = struct {
    context: *anyopaque,
    validate_fn: *const fn (*anyopaque, *const State, Value) anyerror!void,
};

pub const Limits = struct {
    bytes: usize = codec.max_entry_bytes,
    records: usize = max_records,
};

/// The execution owner supplies bounds for the operation it is about to enter
/// and its resulting terminal record. Checkpoint framing is reserved here.
pub const Reservation = struct {
    append_bytes: usize,
    append_records: usize,
    terminal_bytes: usize,
};

pub const Pending = union(enum) {
    idle,
    model: usize,
    tool: struct { turn: usize, step: usize, call: usize },
    ending: usize,
};

const Step = struct {
    record: usize,
    results: std.ArrayList(usize) = .empty,
};

const Turn = struct {
    start: usize,
    steps: std.ArrayList(Step) = .empty,
    last_request: ?usize = null,
    last_request_step: usize = 0,
    last_context: ?usize = null,
    last_steering: ?usize = null,
    last_active_compaction: ?usize = null,
    end: ?usize = null,
};

pub const State = struct {
    limits: Limits = .{},
    native_base_json: ?[]u8 = null,
    native_base: ?std.json.Parsed(Value) = null,
    records: std.ArrayList(codec.OwnedEntry) = .empty,
    turns: std.ArrayList(Turn) = .empty,
    requests: std.StringHashMapUnmanaged(usize) = .empty,
    last_seq: u64 = 0,
    last_hash: [64]u8 = @splat(0),
    retained_bytes: usize = 0,
    blocked: bool = false,

    pub fn deinit(self: *State, alloc: Allocator) void {
        if (self.native_base) |base| base.deinit();
        if (self.native_base_json) |bytes| alloc.free(bytes);
        for (self.turns.items) |*turn| {
            for (turn.steps.items) |*step| step.results.deinit(alloc);
            turn.steps.deinit(alloc);
        }
        self.turns.deinit(alloc);
        self.requests.deinit(alloc);
        for (self.records.items) |*record| record.deinit(alloc);
        self.records.deinit(alloc);
        self.* = .{};
    }

    pub fn ensureAvailable(self: *const State) error{PersistenceUncertain}!void {
        if (self.isBlocked()) return error.PersistenceUncertain;
    }

    pub fn isBlocked(self: *const State) bool {
        return @atomicLoad(bool, &self.blocked, .acquire);
    }

    pub fn block(self: *State) void {
        @atomicStore(bool, &self.blocked, true, .release);
    }

    pub fn preflight(self: *const State, reservation: Reservation) !void {
        if (reservation.append_bytes > try self.appendCapacity(reservation.append_records, reservation.terminal_bytes)) return error.JournalCapacityExceeded;
    }

    pub fn appendCapacity(self: *const State, append_records: usize, terminal_bytes: usize) !usize {
        try self.ensureAvailable();
        try self.validateLimits();
        const new_records = std.math.add(usize, append_records, 1) catch return error.JournalCapacityExceeded;
        const count = std.math.add(usize, self.records.items.len, new_records) catch return error.JournalCapacityExceeded;
        if (count > self.limits.records or new_records > max_sequence -| self.last_seq or
            self.last_seq + new_records >= max_sequence) return error.JournalCapacityExceeded;
        var bytes = std.math.add(usize, self.retained_bytes, terminal_bytes) catch return error.JournalCapacityExceeded;
        bytes = std.math.add(usize, bytes, count) catch return error.JournalCapacityExceeded;
        bytes = std.math.add(usize, bytes, checkpoint_header_reserve) catch return error.JournalCapacityExceeded;
        if (bytes > self.limits.bytes) return error.JournalCapacityExceeded;
        return self.limits.bytes - bytes;
    }

    fn validateLimits(self: *const State) !void {
        if (self.limits.bytes > codec.max_entry_bytes or self.limits.bytes < checkpoint_header_reserve or
            self.limits.records > max_records or self.limits.records == 0) return error.InvalidJournalLimit;
    }

    /// A completed request is found before any host age policy is applied.
    pub fn request(self: *const State, id: []const u8) ?usize {
        return self.requests.get(id);
    }

    pub fn nativeBase(self: *const State) ?Value {
        return if (self.native_base) |base| base.value else null;
    }

    pub fn start(self: *const State, turn: usize) Value {
        return self.records.items[self.turns.items[turn].start].payload.value;
    }

    pub fn modelStep(self: *const State, turn: usize, step: usize) Value {
        return self.records.items[self.turns.items[turn].steps.items[step].record].payload.value;
    }

    pub fn toolResult(self: *const State, turn: usize, step: usize, call: usize) ?Value {
        const results = self.turns.items[turn].steps.items[step].results.items;
        if (call >= results.len) return null;
        return self.records.items[results[call]].payload.value;
    }

    pub fn outcome(self: *const State, turn: usize) ?Value {
        return if (self.turns.items[turn].end) |index| self.records.items[index].payload.value else null;
    }

    pub fn stepCount(self: *const State, turn: usize) usize {
        return self.turns.items[turn].steps.items.len;
    }

    pub fn latestContextRecord(self: *const State, turn: usize) ?Value {
        const index = self.turns.items[turn].last_context orelse return null;
        return self.records.items[index].payload.value;
    }

    pub fn activeCompaction(self: *const State, turn: usize) ?Value {
        const index = self.turns.items[turn].last_active_compaction orelse return null;
        return self.records.items[index].payload.value;
    }

    pub fn requestForCurrentStep(self: *const State, turn: usize) ?Value {
        const current = self.turns.items[turn];
        const index = current.last_request orelse return null;
        if (current.last_request_step != current.steps.items.len) return null;
        return self.records.items[index].payload.value;
    }

    pub fn pending(self: *const State) Pending {
        if (self.turns.items.len == 0) return .idle;
        const turn_index = self.turns.items.len - 1;
        const turn = self.turns.items[turn_index];
        if (turn.end != null) return .idle;
        if (turn.steps.items.len == 0) return .{ .model = turn_index };
        const step_index = turn.steps.items.len - 1;
        const step = turn.steps.items[step_index];
        const body = self.modelStep(turn_index, step_index);
        const selected = body.object.get("calls").?.array.items;
        if (step.results.items.len < selected.len) return .{ .tool = .{
            .turn = turn_index,
            .step = step_index,
            .call = step.results.items.len,
        } };
        const guided = if (turn.last_steering) |index| index > step.record else false;
        return if (body.object.get("final").?.bool and !guided)
            .{ .ending = turn_index }
        else
            .{ .model = turn_index };
    }

    /// Internal tool-loop guards may stop successfully after the entire selected
    /// group settles. A new request or context change invalidates that boundary.
    pub fn canFinishToolLoop(self: *const State, turn_index: usize) bool {
        const position = self.pending();
        if (position != .model or position.model != turn_index or self.records.items.len == 0) return false;
        return self.records.items[self.records.items.len - 1].entry.kind == .tool_result and
            self.requestForCurrentStep(turn_index) == null;
    }

    /// Provider-owned tools can arrive with their results and the final answer
    /// in one response. Only the last acknowledged result can close that path;
    /// a later reservation or context record means execution has moved on.
    pub fn canFinishProviderResponse(self: *const State, turn_index: usize) bool {
        if (turn_index >= self.turns.items.len or self.records.items.len == 0) return false;
        const turn = self.turns.items[turn_index];
        if (turn.steps.items.len == 0 or self.requestForCurrentStep(turn_index) != null) return false;
        if (self.records.items[self.records.items.len - 1].entry.kind != .tool_result) return false;
        return hasProviderTerminalResponse(self.modelStep(turn_index, turn.steps.items.len - 1));
    }

    /// All allocation and transition validation precedes the durability callback.
    /// Failure fences this instance; only recreation can establish the new cursor.
    pub fn append(self: *State, alloc: Allocator, sink: Sink, kind: Kind, bytes: []const u8) !void {
        if (sink.guard) |guard| guard.enter(sink.context);
        defer if (sink.guard) |guard| guard.leave(sink.context);
        try self.ensureAvailable();
        if (kind == .checkpoint) return error.InvalidJournalTransition;
        const seq = std.math.add(u64, self.last_seq, 1) catch return error.JournalCapacityExceeded;
        var owned = try codec.create(alloc, seq, kind, bytes);
        errdefer owned.deinit(alloc);
        try self.prepare(alloc, owned);
        self.block();
        sink.append_fn(sink.context, owned.entry) catch return error.PersistenceUncertain;
        self.adopt(owned);
        @atomicStore(bool, &self.blocked, false, .release);
    }

    /// Pure replay. A caller must discard the whole owner if any entry fails.
    pub fn restore(self: *State, alloc: Allocator, seq: u64, kind: []const u8, bytes: []const u8, hash: []const u8) !void {
        return self.restoreInternal(alloc, seq, kind, bytes, hash, null);
    }

    pub fn restoreValidated(self: *State, alloc: Allocator, seq: u64, kind: []const u8, bytes: []const u8, hash: []const u8, validator: Validator) !void {
        return self.restoreInternal(alloc, seq, kind, bytes, hash, validator);
    }

    fn restoreInternal(self: *State, alloc: Allocator, seq: u64, kind: []const u8, bytes: []const u8, hash: []const u8, validator: ?Validator) !void {
        try self.ensureAvailable();
        var owned = try codec.decode(alloc, seq, kind, bytes, hash);
        errdefer owned.deinit(alloc);
        if (seq == self.last_seq and std.mem.eql(u8, hash, &self.last_hash)) {
            owned.deinit(alloc);
            return;
        }
        if (owned.entry.kind == .checkpoint) {
            try self.restoreCheckpoint(alloc, owned, validator);
            owned.deinit(alloc);
            return;
        }
        if (seq != self.last_seq + 1) return error.JournalConflict;
        try self.prepare(alloc, owned);
        if (validator) |check| try check.validate_fn(check.context, self, owned.payload.value);
        self.adopt(owned);
    }

    fn prepare(self: *State, alloc: Allocator, owned: codec.OwnedEntry) !void {
        try self.validateLimits();
        const body = owned.payload.value;
        const framing = checkpoint_header_reserve + self.records.items.len + 1;
        if (self.records.items.len >= self.limits.records or
            framing > self.limits.bytes or self.retained_bytes > self.limits.bytes - framing or
            owned.entry.bytes.len > self.limits.bytes - framing - self.retained_bytes)
            return error.JournalCapacityExceeded;
        try self.records.ensureUnusedCapacity(alloc, 1);
        switch (owned.entry.kind) {
            .turn_start => {
                if (self.pending() != .idle) return error.PendingTurnError;
                const id = try string(body, "requestId");
                const turn_id = try string(body, "turnId");
                _ = try string(body, "userMessageId");
                const namespace = try string(body, "namespace");
                if (self.nativeBase()) |base| if (!std.mem.eql(u8, namespace, try string(base, "id"))) return error.JournalConflict;
                if (self.turns.items.len != 0 and !std.mem.eql(u8, namespace, try string(self.start(0), "namespace"))) return error.JournalConflict;
                _ = try string(body, "model");
                _ = try string(body, "runtimeTurnId");
                const input_json = try string(body, "inputJson");
                const input_hash = try string(body, "inputHash");
                if (!std.mem.eql(u8, input_hash, &inputHash(input_json))) return error.JournalConflict;
                if (self.requests.contains(id)) return error.RequestConflict;
                for (self.turns.items, 0..) |_, index| {
                    if (std.mem.eql(u8, turn_id, try string(self.start(index), "turnId"))) return error.JournalConflict;
                }
                try self.turns.ensureUnusedCapacity(alloc, 1);
                try self.requests.ensureUnusedCapacity(alloc, 1);
            },
            .model_step => {
                if (isContext(body)) {
                    const steering = try isSteering(body);
                    const pending_state = self.pending();
                    if (steering) {
                        if (pending_state != .model and pending_state != .ending) return error.InvalidJournalTransition;
                    } else if (pending_state != .idle and pending_state != .model) return error.InvalidJournalTransition;
                    const count = try field(body, "afterTurnCount", .integer);
                    if (count.integer < 0 or @as(u64, @intCast(count.integer)) != self.turns.items.len) return error.JournalConflict;
                    const turn_id = body.object.get("turnId") orelse return error.InvalidJournalRecord;
                    if (pending_state != .idle) {
                        try self.checkTurn(body, if (pending_state == .model) pending_state.model else pending_state.ending);
                    } else if (turn_id != .null) return error.JournalConflict;
                    if (steering) {
                        const turn = self.turns.items.len - 1;
                        const after = (try field(body, "afterStepCount", .integer)).integer;
                        if (after < 0 or @as(u64, @intCast(after)) != self.stepCount(turn)) return error.JournalConflict;
                        const guidance = try array(body, "guidance");
                        if (guidance.len == 0 or guidance.len > max_records) return error.InvalidJournalRecord;
                        for (guidance) |item| {
                            _ = try string(item, "id");
                            _ = try field(item, "text", .string);
                        }
                        if (!body.object.contains("prefix") or !body.object.contains("retiredDraft")) return error.InvalidJournalRecord;
                        if (body.object.contains("summary") or body.object.contains("retainedFrom") or body.object.contains("activeThrough")) return error.InvalidJournalRecord;
                        if (body.object.contains("completion") or body.object.contains("calls") or body.object.contains("generationId")) return error.InvalidJournalRecord;
                        return;
                    }
                    _ = try object(body, "summary");
                    _ = try object(body, "retainedFrom");
                    if (body.object.contains("activeThrough")) {
                        if (pending_state != .model) return error.InvalidJournalTransition;
                        _ = try object(body, "activeThrough");
                        const after = (try field(body, "afterStepCount", .integer)).integer;
                        if (after < 0 or @as(u64, @intCast(after)) != self.stepCount(pending_state.model)) return error.JournalConflict;
                    } else if (body.object.contains("afterStepCount")) return error.InvalidJournalRecord;
                    if (body.object.contains("completion") or body.object.contains("calls") or body.object.contains("generationId")) return error.InvalidJournalRecord;
                    return;
                }
                const turn_index = switch (self.pending()) {
                    .model => |index| index,
                    else => return error.InvalidJournalTransition,
                };
                try self.checkTurn(body, turn_index);
                _ = try string(body, "messageId");
                _ = try string(body, "generationId");
                if (try isRequest(body)) {
                    if (body.object.contains("completion") or body.object.contains("calls") or body.object.contains("final")) return error.InvalidJournalRecord;
                    _ = try object(body, "executionContext");
                    const supersedes = body.object.get("supersedesGenerationId") orelse .null;
                    if (self.requestForCurrentStep(turn_index)) |previous_request| {
                        if (supersedes != .string or !std.mem.eql(u8, supersedes.string, try string(previous_request, "generationId"))) return error.JournalConflict;
                        if (!std.mem.eql(u8, try string(body, "messageId"), try string(previous_request, "messageId"))) return error.JournalConflict;
                    } else if (supersedes != .null) return error.JournalConflict;
                    for (self.records.items) |record| {
                        if (record.entry.kind == .model_step and try isRequest(record.payload.value) and
                            std.mem.eql(u8, try string(body, "generationId"), try string(record.payload.value, "generationId"))) return error.JournalConflict;
                    }
                    return;
                }
                if (self.requestForCurrentStep(turn_index)) |request_body| {
                    if (!std.mem.eql(u8, try string(body, "messageId"), try string(request_body, "messageId")) or
                        !std.mem.eql(u8, try string(body, "generationId"), try string(request_body, "generationId"))) return error.JournalConflict;
                }
                _ = try boolean(body, "final");
                _ = try object(body, "completion");
                const selected = try array(body, "calls");
                if (selected.len > max_calls) return error.JournalCapacityExceeded;
                if (try boolean(body, "final") and selected.len != 0) return error.InvalidJournalTransition;
                for (selected, 0..) |call, index| {
                    const id = try string(call, "callId");
                    _ = try string(call, "providerId");
                    _ = try string(call, "name");
                    _ = try string(call, "argumentsJson");
                    _ = std.meta.stringToEnum(Replay, try string(call, "replay")) orelse return error.InvalidJournalRecord;
                    for (selected[0..index]) |prior| {
                        if (std.mem.eql(u8, id, try string(prior, "callId"))) return error.JournalConflict;
                    }
                    for (self.turns.items, 0..) |turn, ti| for (turn.steps.items, 0..) |_, si| {
                        for (try array(self.modelStep(ti, si), "calls")) |prior| {
                            if (std.mem.eql(u8, id, try string(prior, "callId"))) return error.JournalConflict;
                        }
                    };
                }
                try self.turns.items[turn_index].steps.ensureUnusedCapacity(alloc, 1);
            },
            .tool_result => {
                const position = switch (self.pending()) {
                    .tool => |value| value,
                    else => return error.InvalidJournalTransition,
                };
                try self.checkTurn(body, position.turn);
                const call = (try array(self.modelStep(position.turn, position.step), "calls"))[position.call];
                if (!std.mem.eql(u8, try string(body, "callId"), try string(call, "callId"))) return error.JournalConflict;
                _ = try boolean(body, "isError");
                _ = try field(body, "content", .string);
                try self.turns.items[position.turn].steps.items[position.step].results.ensureUnusedCapacity(alloc, 1);
            },
            .turn_end => {
                const position = self.pending();
                const turn_index = switch (position) {
                    .model, .ending => |index| index,
                    .tool => |value| value.turn,
                    .idle => return error.InvalidJournalTransition,
                };
                try self.checkTurn(body, turn_index);
                const result = try object(body, "result");
                const ok = try boolean(result, "ok");
                if (ok) {
                    const stop_reason = try string(result, "stopReason");
                    _ = std.meta.stringToEnum(enum { stop, length, tool_limit }, stop_reason) orelse return error.InvalidJournalRecord;
                    const tool_limit = std.mem.eql(u8, stop_reason, "tool_limit") and self.canFinishToolLoop(turn_index);
                    if (position != .ending and !tool_limit and
                        (position != .model or !self.canFinishProviderResponse(turn_index))) return error.InvalidJournalTransition;
                } else {
                    _ = try string(result, "reason");
                    _ = try boolean(result, "retryable");
                    _ = try field(result, "message", .string);
                    if (position == .tool) {
                        const pending_tool = try object(result, "pendingTool");
                        const call = (try array(self.modelStep(position.tool.turn, position.tool.step), "calls"))[position.tool.call];
                        if (!std.mem.eql(u8, try string(pending_tool, "callId"), try string(call, "callId"))) return error.JournalConflict;
                    }
                }
            },
            .checkpoint => return error.InvalidJournalTransition,
        }
    }

    fn checkTurn(self: *const State, body: Value, turn: usize) !void {
        if (!std.mem.eql(u8, try string(body, "turnId"), try string(self.start(turn), "turnId"))) return error.JournalConflict;
    }

    fn adopt(self: *State, owned: codec.OwnedEntry) void {
        const index = self.records.items.len;
        const position = self.pending();
        self.records.appendAssumeCapacity(owned);
        switch (owned.entry.kind) {
            .turn_start => {
                self.requests.putAssumeCapacity(owned.payload.value.object.get("requestId").?.string, self.turns.items.len);
                self.turns.appendAssumeCapacity(.{ .start = index });
            },
            .model_step => {
                if (isContext(owned.payload.value)) {
                    if (isSteering(owned.payload.value) catch unreachable) self.turns.items[self.turns.items.len - 1].last_steering = index;
                    if (owned.payload.value.object.contains("activeThrough")) self.turns.items[position.model].last_active_compaction = index;
                } else {
                    const turn = &self.turns.items[position.model];
                    turn.last_context = index;
                    if (isRequest(owned.payload.value) catch unreachable) {
                        turn.last_request = index;
                        turn.last_request_step = turn.steps.items.len;
                    } else {
                        turn.steps.appendAssumeCapacity(.{ .record = index });
                    }
                }
            },
            .tool_result => self.turns.items[position.tool.turn].steps.items[position.tool.step].results.appendAssumeCapacity(index),
            .turn_end => self.turns.items[self.turns.items.len - 1].end = index,
            .checkpoint => unreachable,
        }
        self.last_seq = owned.entry.seq;
        self.last_hash = owned.entry.hash;
        self.retained_bytes += owned.entry.bytes.len;
    }

    /// Periodic idle checkpoint: preserves the complete semantic record set and
    /// therefore every request mapping. No per-turn whole-history write is made.
    pub fn checkpoint(self: *State, alloc: Allocator, sink: Sink) !codec.OwnedEntry {
        if (sink.guard) |guard| guard.enter(sink.context);
        defer if (sink.guard) |guard| guard.leave(sink.context);
        try self.ensureAvailable();
        if (self.pending() != .idle) return error.PendingTurnError;
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();
        try out.writer.print("{{\"v\":{d},\"kind\":\"checkpoint\",\"lastIncludedSeq\":{d}", .{ if (self.native_base_json != null) @as(u8, 2) else 1, self.last_seq });
        if (self.native_base_json) |base| {
            try out.writer.writeAll(",\"nativeBase\":");
            try out.writer.writeAll(base);
        }
        try out.writer.writeAll(",\"records\":[");
        for (self.records.items, 0..) |record, index| {
            if (index != 0) try out.writer.writeByte(',');
            try out.writer.writeAll(record.entry.bytes);
        }
        try out.writer.writeAll("]}");
        var owned = try codec.create(alloc, self.last_seq + 1, .checkpoint, out.written());
        errdefer owned.deinit(alloc);
        self.block();
        sink.append_fn(sink.context, owned.entry) catch return error.PersistenceUncertain;
        self.last_seq = owned.entry.seq;
        self.last_hash = owned.entry.hash;
        @atomicStore(bool, &self.blocked, false, .release);
        return owned;
    }

    fn restoreCheckpoint(self: *State, alloc: Allocator, owned: codec.OwnedEntry, validator: ?Validator) !void {
        const body = owned.payload.value;
        const covered = try field(body, "lastIncludedSeq", .integer);
        if (covered.integer < 0 or @as(u64, @intCast(covered.integer)) != owned.entry.seq - 1) return error.JournalConflict;
        if (self.last_seq != 0 and self.last_seq + 1 != owned.entry.seq) return error.JournalConflict;
        const records = try array(body, "records");
        const base = body.object.get("nativeBase");
        if (records.len > @as(u64, @intCast(covered.integer))) return error.JournalConflict;
        if (self.last_seq != 0) {
            if ((base == null) != (self.native_base_json == null)) return error.JournalConflict;
            if (base) |value| {
                const incoming = try std.json.Stringify.valueAlloc(alloc, value, .{});
                defer alloc.free(incoming);
                if (!std.mem.eql(u8, incoming, self.native_base_json.?)) return error.JournalConflict;
            }
            if (records.len != self.records.items.len) return error.JournalConflict;
            for (records, self.records.items) |record, current| {
                const expected = try std.json.Stringify.valueAlloc(alloc, current.payload.value, .{});
                defer alloc.free(expected);
                const actual = try std.json.Stringify.valueAlloc(alloc, record, .{});
                defer alloc.free(actual);
                if (!std.mem.eql(u8, expected, actual)) return error.JournalConflict;
            }
        }
        var replacement: State = .{ .limits = self.limits };
        errdefer replacement.deinit(alloc);
        if (base) |value| {
            const bytes = try std.json.Stringify.valueAlloc(alloc, value, .{});
            replacement.native_base_json = bytes;
            if (bytes.len + checkpoint_header_reserve > replacement.limits.bytes) return error.JournalCapacityExceeded;
            replacement.native_base = try std.json.parseFromSlice(Value, alloc, bytes, .{ .allocate = .alloc_always });
            replacement.retained_bytes = bytes.len;
        }
        for (records) |record| {
            const kind = std.meta.stringToEnum(Kind, try string(record, "kind")) orelse return error.InvalidJournalRecord;
            if (kind == .checkpoint) return error.InvalidJournalRecord;
            const bytes = try std.json.Stringify.valueAlloc(alloc, record, .{});
            defer alloc.free(bytes);
            var restored = try codec.create(alloc, replacement.last_seq + 1, kind, bytes);
            errdefer restored.deinit(alloc);
            try replacement.prepare(alloc, restored);
            if (validator) |check| try check.validate_fn(check.context, &replacement, restored.payload.value);
            replacement.adopt(restored);
        }
        if (replacement.pending() != .idle) return error.InvalidJournalTransition;
        if (validator) |check| try check.validate_fn(check.context, &replacement, body);
        replacement.last_seq = owned.entry.seq;
        replacement.last_hash = owned.entry.hash;
        self.deinit(alloc);
        self.* = replacement;
    }
};

pub fn isRequest(body: Value) !bool {
    if (body != .object) return error.InvalidJournalRecord;
    const phase = body.object.get("phase") orelse return false;
    if (phase != .string) return error.InvalidJournalRecord;
    if (std.mem.eql(u8, phase.string, "request")) return true;
    if (std.mem.eql(u8, phase.string, "decision")) return false;
    if (std.mem.eql(u8, phase.string, "context")) return false;
    return error.InvalidJournalRecord;
}

pub fn isContext(body: Value) bool {
    if (body != .object) return false;
    const phase = body.object.get("phase") orelse return false;
    return phase == .string and std.mem.eql(u8, phase.string, "context");
}

pub fn isSteering(body: Value) !bool {
    const change = body.object.get("change") orelse return false;
    if (change != .string) return error.InvalidJournalRecord;
    if (std.mem.eql(u8, change.string, "steering")) return true;
    if (std.mem.eql(u8, change.string, "compaction")) return false;
    return error.InvalidJournalRecord;
}

fn hasProviderTerminalResponse(body: Value) bool {
    const completion = object(body, "completion") catch return false;
    const reason = string(completion, "finish_reason") catch return false;
    if (!std.mem.eql(u8, reason, "stop")) return false;
    const content = string(completion, "content") catch return false;
    if (content.len == 0) return false;
    const calls = array(body, "calls") catch return false;
    if (calls.len == 0) return false;
    for (calls) |call| {
        const provenance = string(call, "provenance") catch return false;
        if (!std.mem.eql(u8, provenance, "provider_executed")) return false;
        _ = string(call, "provider_result") catch return false;
    }
    return true;
}

test "journal witness capacity reserves terminal and checkpoint bytes and sequence" {
    var state: State = .{ .limits = .{ .bytes = 1024, .records = 3 } };
    // Two future records plus a terminal record and all checkpoint punctuation.
    try state.preflight(.{ .append_bytes = 600, .append_records = 2, .terminal_bytes = 293 });
    try std.testing.expectError(error.JournalCapacityExceeded, state.preflight(.{ .append_bytes = 600, .append_records = 2, .terminal_bytes = 294 }));
    try std.testing.expectError(error.JournalCapacityExceeded, state.preflight(.{ .append_bytes = 1, .append_records = 3, .terminal_bytes = 1 }));
    try std.testing.expectEqual(@as(u64, 0), state.last_seq);
    try std.testing.expect(!state.blocked);
    state.last_seq = max_sequence - 4;
    try state.preflight(.{ .append_bytes = 600, .append_records = 2, .terminal_bytes = 293 });
    state.last_seq += 1;
    try std.testing.expectError(error.JournalCapacityExceeded, state.preflight(.{ .append_bytes = 600, .append_records = 2, .terminal_bytes = 293 }));
    try std.testing.expect(!state.blocked);
    state.last_seq = 0;
    try std.testing.expectError(error.JournalCapacityExceeded, state.preflight(.{ .append_bytes = std.math.maxInt(usize), .append_records = 1, .terminal_bytes = 1 }));
    try std.testing.expectError(error.JournalCapacityExceeded, state.preflight(.{ .append_bytes = 1, .append_records = std.math.maxInt(usize), .terminal_bytes = 1 }));
}

pub fn field(value: Value, key: []const u8, tag: std.meta.Tag(Value)) error{InvalidJournalRecord}!Value {
    if (value != .object) return error.InvalidJournalRecord;
    const result = value.object.get(key) orelse return error.InvalidJournalRecord;
    if (std.meta.activeTag(result) != tag) return error.InvalidJournalRecord;
    return result;
}

pub fn string(value: Value, key: []const u8) error{InvalidJournalRecord}![]const u8 {
    const result = (try field(value, key, .string)).string;
    if (result.len == 0) return error.InvalidJournalRecord;
    return result;
}

pub fn object(value: Value, key: []const u8) error{InvalidJournalRecord}!Value {
    return field(value, key, .object);
}

pub fn array(value: Value, key: []const u8) error{InvalidJournalRecord}![]Value {
    return (try field(value, key, .array)).array.items;
}

pub fn boolean(value: Value, key: []const u8) error{InvalidJournalRecord}!bool {
    return (try field(value, key, .bool)).bool;
}

pub fn inputHash(bytes: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

const TestStore = struct {
    entries: std.ArrayList(codec.OwnedEntry) = .empty,
    lose_ack: bool = false,
    calls: usize = 0,

    fn deinit(self: *TestStore) void {
        for (self.entries.items) |*entry| entry.deinit(std.testing.allocator);
        self.entries.deinit(std.testing.allocator);
    }

    fn sink(self: *TestStore) Sink {
        return .{ .context = self, .append_fn = write };
    }

    fn write(raw: *anyopaque, entry: Entry) !void {
        const self: *TestStore = @ptrCast(@alignCast(raw));
        self.calls += 1;
        var copy = try codec.decode(std.testing.allocator, entry.seq, @tagName(entry.kind), entry.bytes, &entry.hash);
        self.entries.append(std.testing.allocator, copy) catch |err| {
            copy.deinit(std.testing.allocator);
            return err;
        };
        if (self.lose_ack) return error.TestLostAcknowledgement;
    }

    fn restore(self: *const TestStore, state: *State) !void {
        for (self.entries.items) |entry| {
            try state.restore(std.testing.allocator, entry.entry.seq, @tagName(entry.entry.kind), entry.entry.bytes, &entry.entry.hash);
        }
    }
};

fn testStart(state: *State, store: *TestStore) !void {
    const input = "{\"text\":\"hello\",\"images\":[]}";
    const hash = inputHash(input);
    const bytes = try std.json.Stringify.valueAlloc(std.testing.allocator, .{
        .v = 1,
        .kind = "turn_start",
        .namespace = "session",
        .turnId = "turn",
        .userMessageId = "user",
        .requestId = "request",
        .model = "fixture",
        .runtimeTurnId = "1",
        .inputJson = input,
        .inputHash = @as([]const u8, &hash),
    }, .{});
    defer std.testing.allocator.free(bytes);
    try state.append(std.testing.allocator, store.sink(), .turn_start, bytes);
}

const test_decision = "{\"v\":1,\"kind\":\"model_step\",\"turnId\":\"turn\",\"messageId\":\"message\",\"generationId\":\"generation\",\"final\":false,\"completion\":{},\"calls\":[{\"callId\":\"a\",\"providerId\":\"provider-a\",\"name\":\"effect\",\"argumentsJson\":\"{}\",\"replay\":\"safe\"},{\"callId\":\"b\",\"providerId\":\"provider-b\",\"name\":\"effect\",\"argumentsJson\":\"{}\",\"replay\":\"blocked\"}]}";
const test_result_a = "{\"v\":1,\"kind\":\"tool_result\",\"turnId\":\"turn\",\"callId\":\"a\",\"content\":\"original receipt\",\"isError\":false}";
const test_final = "{\"v\":1,\"kind\":\"model_step\",\"turnId\":\"turn\",\"messageId\":\"final-message\",\"generationId\":\"final-generation\",\"final\":true,\"completion\":{\"content\":\"saved answer\"},\"calls\":[]}";
const test_end = "{\"v\":1,\"kind\":\"turn_end\",\"turnId\":\"turn\",\"result\":{\"ok\":true,\"stopReason\":\"stop\"}}";

test "journal witness invalid stop reasons fail before append and during replay" {
    const alloc = std.testing.allocator;
    for ([_][]const u8{ "end_turn", "unknown" }) |reason| {
        var state: State = .{};
        defer state.deinit(alloc);
        var store: TestStore = .{};
        defer store.deinit();
        try testStart(&state, &store);
        try state.append(alloc, store.sink(), .model_step, test_final);
        const invalid = try std.json.Stringify.valueAlloc(alloc, .{
            .v = 1,
            .kind = "turn_end",
            .turnId = "turn",
            .result = .{ .ok = true, .stopReason = reason },
        }, .{});
        defer alloc.free(invalid);
        try std.testing.expectError(error.InvalidJournalRecord, state.append(alloc, store.sink(), .turn_end, invalid));
        try std.testing.expectEqual(@as(usize, 2), store.calls);
        var restored: State = .{};
        defer restored.deinit(alloc);
        try store.restore(&restored);
        var entry = try codec.create(alloc, 3, .turn_end, invalid);
        defer entry.deinit(alloc);
        try std.testing.expectError(error.InvalidJournalRecord, restored.restore(alloc, 3, "turn_end", entry.entry.bytes, &entry.entry.hash));
        try state.append(alloc, store.sink(), .turn_end, test_end);
        try std.testing.expectEqual(Pending.idle, state.pending());
    }
}

test "journal witness tool loop termination requires every result and no later request" {
    const alloc = std.testing.allocator;
    const stopped = "{\"v\":1,\"kind\":\"turn_end\",\"turnId\":\"turn\",\"result\":{\"ok\":true,\"stopReason\":\"tool_limit\"}}";
    const result_b = "{\"v\":1,\"kind\":\"tool_result\",\"turnId\":\"turn\",\"callId\":\"b\",\"content\":\"stored failure\",\"isError\":true}";
    for ([_]bool{ false, true }) |new_request| {
        var state: State = .{};
        defer state.deinit(alloc);
        var store: TestStore = .{};
        defer store.deinit();
        try testStart(&state, &store);
        try std.testing.expectError(error.InvalidJournalTransition, state.append(alloc, store.sink(), .turn_end, stopped));
        try state.append(alloc, store.sink(), .model_step, test_decision);
        try std.testing.expectError(error.InvalidJournalTransition, state.append(alloc, store.sink(), .turn_end, stopped));
        try state.append(alloc, store.sink(), .tool_result, test_result_a);
        try std.testing.expectError(error.InvalidJournalTransition, state.append(alloc, store.sink(), .turn_end, stopped));
        try state.append(alloc, store.sink(), .tool_result, result_b);
        try std.testing.expect(state.canFinishToolLoop(0));
        if (new_request) {
            try state.append(alloc, store.sink(), .model_step, "{\"v\":1,\"kind\":\"model_step\",\"phase\":\"request\",\"turnId\":\"turn\",\"messageId\":\"next\",\"generationId\":\"next\",\"supersedesGenerationId\":null,\"executionContext\":{}}");
            try std.testing.expect(!state.canFinishToolLoop(0));
            try std.testing.expectError(error.InvalidJournalTransition, state.append(alloc, store.sink(), .turn_end, stopped));
        } else {
            try state.append(alloc, store.sink(), .turn_end, stopped);
            var checkpoint = try state.checkpoint(alloc, store.sink());
            defer checkpoint.deinit(alloc);
            var restored: State = .{};
            defer restored.deinit(alloc);
            try store.restore(&restored);
            try std.testing.expect(restored.pending() == .idle);
            try std.testing.expectEqualStrings("tool_limit", try string(try object(restored.outcome(0).?, "result"), "stopReason"));
        }
    }
}

test "execution journal preserves pending calls and ordered result progress" {
    const alloc = std.testing.allocator;
    var state: State = .{};
    defer state.deinit(alloc);
    var store: TestStore = .{};
    defer store.deinit();
    try testStart(&state, &store);
    try state.append(alloc, store.sink(), .model_step, test_decision);
    try std.testing.expectEqual(@as(usize, 0), state.pending().tool.call);
    try state.append(alloc, store.sink(), .tool_result, test_result_a);
    try std.testing.expectEqual(@as(usize, 1), state.pending().tool.call);
    try std.testing.expectEqualStrings("original receipt", try string(state.toolResult(0, 0, 0).?, "content"));
    const before = store.calls;
    try std.testing.expectError(error.JournalConflict, state.append(alloc, store.sink(), .tool_result, test_result_a));
    try std.testing.expectError(error.InvalidJournalTransition, state.append(alloc, store.sink(), .turn_end, test_end));
    try std.testing.expectEqual(before, store.calls);
    var restored: State = .{};
    defer restored.deinit(alloc);
    try store.restore(&restored);
    try std.testing.expectEqual(state.pending(), restored.pending());
    try std.testing.expectEqualStrings("request", try string(restored.start(0), "requestId"));
}

test "execution journal lost acknowledgement fences owner and replays landed decision" {
    const alloc = std.testing.allocator;
    var state: State = .{};
    defer state.deinit(alloc);
    var store: TestStore = .{};
    defer store.deinit();
    try testStart(&state, &store);
    store.lose_ack = true;
    try std.testing.expectError(error.PersistenceUncertain, state.append(alloc, store.sink(), .model_step, test_decision));
    try std.testing.expectEqual(@as(u64, 1), state.last_seq);
    try std.testing.expectError(error.PersistenceUncertain, state.append(alloc, store.sink(), .tool_result, test_result_a));
    try std.testing.expectEqual(@as(usize, 2), store.calls);
    var restored: State = .{};
    defer restored.deinit(alloc);
    try store.restore(&restored);
    try std.testing.expectEqual(@as(u64, 2), restored.last_seq);
    try std.testing.expectEqual(@as(usize, 0), restored.pending().tool.call);
}

test "execution journal final response remains ending until durable turn end" {
    const alloc = std.testing.allocator;
    var state: State = .{};
    defer state.deinit(alloc);
    var store: TestStore = .{};
    defer store.deinit();
    try testStart(&state, &store);
    try state.append(alloc, store.sink(), .model_step, test_final);
    try std.testing.expectEqual(Pending{ .ending = 0 }, state.pending());
    var restored: State = .{};
    defer restored.deinit(alloc);
    try store.restore(&restored);
    try std.testing.expectEqual(Pending{ .ending = 0 }, restored.pending());
    try restored.append(alloc, store.sink(), .turn_end, test_end);
    try std.testing.expectEqual(Pending.idle, restored.pending());
    try std.testing.expect(try boolean(try object(restored.outcome(0).?, "result"), "ok"));
}

test "execution journal checkpoint retains completed request and sequence after pruning" {
    const alloc = std.testing.allocator;
    var state: State = .{};
    defer state.deinit(alloc);
    var store: TestStore = .{};
    defer store.deinit();
    try testStart(&state, &store);
    try state.append(alloc, store.sink(), .model_step, test_final);
    try state.append(alloc, store.sink(), .turn_end, test_end);
    var checkpoint_entry = try state.checkpoint(alloc, store.sink());
    defer checkpoint_entry.deinit(alloc);
    var restored: State = .{};
    defer restored.deinit(alloc);
    const entry = checkpoint_entry.entry;
    try restored.restore(alloc, entry.seq, @tagName(entry.kind), entry.bytes, &entry.hash);
    try std.testing.expectEqual(@as(u64, 4), restored.last_seq);
    try std.testing.expectEqual(@as(?usize, 0), restored.request("request"));
    try std.testing.expectEqual(Pending.idle, restored.pending());
    try std.testing.expectEqualStrings("saved answer", try string(try object(restored.modelStep(0, 0), "completion"), "content"));
    try std.testing.expectError(error.RequestConflict, testStart(&restored, &store));
    var second = try restored.checkpoint(alloc, store.sink());
    defer second.deinit(alloc);
    try std.testing.expectEqual(@as(u64, 5), second.entry.seq);
}

test "execution journal rejects checkpoint history replacement when prefix is known" {
    const alloc = std.testing.allocator;
    var state: State = .{};
    defer state.deinit(alloc);
    var store: TestStore = .{};
    defer store.deinit();
    try testStart(&state, &store);
    const bytes = "{\"v\":1,\"kind\":\"checkpoint\",\"lastIncludedSeq\":1,\"records\":[]}";
    const hash = codec.digest(2, .checkpoint, bytes);
    try std.testing.expectError(error.JournalConflict, state.restore(alloc, 2, "checkpoint", bytes, &hash));
    try std.testing.expectEqual(@as(u64, 1), state.last_seq);
}
