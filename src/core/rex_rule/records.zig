//! Reads Rex's answer to `rex block call -b $REX_BLOCK program_resume_records`
//! and returns the state of fx's own record in it. The answer is outside bytes,
//! so every shape is checked before use, and a wrong shape is `.other`.
//! It imports only `std` and `plan.zig`.

const std = @import("std");
const plan = @import("plan.zig");

pub const max_answer_bytes: usize = 64 * 1024;

const records_key = "records";
const owner_key = "owner";
const pid_key = "pid";
const trusted_key = "trusted";
const reason_key = "untrusted_reason";
const no_rule_reason = "no_rule";

/// Returns the state of the first record whose owner pid is `pid`. The caller
/// owns `arena`, and the parsed answer lives in it until the arena is freed.
pub fn ownRecord(arena: std.mem.Allocator, json: []const u8, pid: u32) plan.RecordState {
    if (json.len > max_answer_bytes) return .other;
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{}) catch return .other;
    const records = recordList(root) orelse return .other;
    var answer: plan.RecordState = .none;
    for (records) |item| {
        const record = objectOf(item) orelse return .other;
        const record_pid = ownerPid(record) orelse return .other;
        if (answer == .none and record_pid == pid) answer = classify(record);
    }
    return answer;
}

fn recordList(root: std.json.Value) ?[]const std.json.Value {
    const top = objectOf(root) orelse return null;
    const records = top.get(records_key) orelse return null;
    return switch (records) {
        .array => |array| array.items,
        else => null,
    };
}

fn objectOf(value: std.json.Value) ?std.json.ObjectMap {
    return switch (value) {
        .object => |object| object,
        else => null,
    };
}

fn ownerPid(record: std.json.ObjectMap) ?i64 {
    const owner = objectOf(record.get(owner_key) orelse return null) orelse return null;
    const pid = owner.get(pid_key) orelse return null;
    return switch (pid) {
        .integer => |number| number,
        else => null,
    };
}

fn classify(record: std.json.ObjectMap) plan.RecordState {
    if (record.get(trusted_key)) |trusted| switch (trusted) {
        .bool => |is_trusted| if (is_trusted) return .trusted,
        else => {},
    };
    if (record.get(reason_key)) |reason| switch (reason) {
        .string => |text| if (std.mem.eql(u8, text, no_rule_reason)) return .no_rule,
        else => {},
    };
    return .other;
}

const test_pid: u32 = 123;

const trusted_answer =
    \\{"records":[{"owner":{"pid":123,"name":"fx"},"program":"fx","reported_at":"2026-11-27T12:00:00Z","command":["fx","--resume","/Users/example/.fx/sessions/v2"],"cwd":"/Users/example/work","chosen":true,"trusted":true,"rule":"fx"}]}
;

const no_rule_answer =
    \\{"records":[{"owner":{"pid":123,"name":"fx"},"program":"fx","command":["fx","--resume","/Users/example/.fx/sessions/v2"],"chosen":true,"trusted":false,"untrusted_reason":"no_rule"}]}
;

fn answerState(json: []const u8, pid: u32) plan.RecordState {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    return ownRecord(arena.allocator(), json, pid);
}

test "ownRecord reports a trusted record" {
    try std.testing.expectEqual(plan.RecordState.trusted, answerState(trusted_answer, test_pid));
}

test "ownRecord reports a record that is untrusted for lack of a rule" {
    try std.testing.expectEqual(plan.RecordState.no_rule, answerState(no_rule_answer, test_pid));
}

test "ownRecord reports another untrusted reason as other" {
    const json =
        \\{"records":[{"owner":{"pid":123},"trusted":false,"untrusted_reason":"command_changed"}]}
    ;
    try std.testing.expectEqual(plan.RecordState.other, answerState(json, test_pid));
}

test "ownRecord reports none when the answer has no records" {
    try std.testing.expectEqual(plan.RecordState.none, answerState("{\"records\":[]}", test_pid));
}

test "ownRecord ignores a record of another pid" {
    const json =
        \\{"records":[{"owner":{"pid":999},"trusted":false,"untrusted_reason":"no_rule"}]}
    ;
    try std.testing.expectEqual(plan.RecordState.none, answerState(json, test_pid));
}

test "ownRecord takes the first record with our pid" {
    const json =
        \\{"records":[{"owner":{"pid":999},"trusted":true},{"owner":{"pid":123},"trusted":false,"untrusted_reason":"no_rule"},{"owner":{"pid":123},"trusted":true}]}
    ;
    try std.testing.expectEqual(plan.RecordState.no_rule, answerState(json, test_pid));
}

test "ownRecord refuses invalid JSON as other" {
    try std.testing.expectEqual(plan.RecordState.other, answerState("{\"records\":[", test_pid));
}

test "ownRecord refuses an answer longer than the cap as other" {
    const padded = try std.testing.allocator.alloc(u8, max_answer_bytes + 1);
    defer std.testing.allocator.free(padded);
    @memset(padded, ' ');
    @memcpy(padded[0..2], "{}");
    try std.testing.expectEqual(plan.RecordState.other, answerState(padded, test_pid));
}

test "ownRecord refuses a record with no owner as other" {
    try std.testing.expectEqual(plan.RecordState.other, answerState("{\"records\":[{\"trusted\":true}]}", test_pid));
}

test "ownRecord refuses a wrong top-level shape as other" {
    try std.testing.expectEqual(plan.RecordState.other, answerState("{\"records\":{}}", test_pid));
    try std.testing.expectEqual(plan.RecordState.other, answerState("[]", test_pid));
}

test "a deeply nested answer is .other" {
    const depth = 32000;
    const nested = try std.testing.allocator.alloc(u8, 2 * depth);
    defer std.testing.allocator.free(nested);
    @memset(nested[0..depth], '[');
    @memset(nested[depth..], ']');
    try std.testing.expectEqual(plan.RecordState.other, answerState(nested, test_pid));

    const wrapper = "{\"records\":";
    const wrapped_depth = 30000;
    const wrapped = try std.testing.allocator.alloc(u8, wrapper.len + 2 * wrapped_depth + 1);
    defer std.testing.allocator.free(wrapped);
    @memcpy(wrapped[0..wrapper.len], wrapper);
    @memset(wrapped[wrapper.len..][0..wrapped_depth], '[');
    @memset(wrapped[wrapper.len + wrapped_depth ..][0..wrapped_depth], ']');
    wrapped[wrapped.len - 1] = '}';
    try std.testing.expectEqual(plan.RecordState.other, answerState(wrapped, test_pid));
}

fn fuzzOwnRecord(_: void, smith: *std.testing.Smith) !void {
    var buffer: [max_answer_bytes + 1]u8 = undefined;
    const len: usize = @intCast(smith.slice(&buffer));
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    switch (ownRecord(arena.allocator(), buffer[0..len], test_pid)) {
        .none, .trusted, .no_rule, .other => {},
    }
}

test "rex_rule records decoder never fails" {
    try std.testing.fuzz({}, fuzzOwnRecord, .{
        .corpus = &(@import("fuzz_seed").slices(.{
            "",
            "{}",
            "{\"records\":[]}",
            trusted_answer,
            no_rule_answer,
        }) ++ @import("fuzz_corpus").rex_rule_records.*),
    });
}
