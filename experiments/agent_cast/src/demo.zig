const std = @import("std");
const contracts = @import("contracts.zig");
const executor = @import("executor.zig");

const DemoMode = enum { compare, enabled, disabled };
const max_fixture_bytes = 1024 * 1024;
const help =
    \\Usage: agent-cast-demo --fixture PATH [--mode compare|enabled|disabled]
    \\
    \\Capture one file of 256 bytes to 1 MiB and exercise an experimental embedded
    \\immutable content reader. Compare mode checks every logical receipt and prints
    \\JSON with actual physical read counts. This is a correctness demonstration.
    \\Host admissions are fixture contracts, with no production permission checks.
    \\
    \\  --fixture PATH  File to capture once into owned immutable storage
    \\  --mode MODE     Select execution mode (default: compare)
    \\  --help          Show this help
    \\
;

pub fn main(init: std.process.Init) !void {
    run(init) catch |err| {
        var buffer: [256]u8 = undefined;
        const message = try std.fmt.bufPrint(&buffer, "agent-cast-demo: {s}; see --help\n", .{@errorName(err)});
        try std.Io.File.stderr().writeStreamingAll(init.io, message);
        std.process.exit(1);
    };
}

fn run(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const alloc = arena.allocator();
    const args = try init.minimal.args.toSlice(alloc);
    var fixture_path: ?[]const u8 = null;
    var mode: DemoMode = .compare;
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        if (std.mem.eql(u8, args[index], "--help")) {
            try std.Io.File.stdout().writeStreamingAll(init.io, help);
            return;
        } else if (std.mem.eql(u8, args[index], "--fixture")) {
            index += 1;
            if (index >= args.len) return error.MissingFixturePath;
            if (fixture_path != null) return error.DuplicateFixtureOption;
            fixture_path = args[index];
        } else if (std.mem.eql(u8, args[index], "--mode")) {
            index += 1;
            if (index >= args.len) return error.MissingMode;
            mode = std.meta.stringToEnum(DemoMode, args[index]) orelse return error.InvalidMode;
        } else {
            return error.UnknownArgument;
        }
    }
    const path = fixture_path orelse return error.MissingFixturePath;
    const captured_file = try std.Io.Dir.cwd().readFileAlloc(init.io, path, alloc, .limited(max_fixture_bytes + 1));
    if (captured_file.len < 256) return error.FixtureTooSmall;
    var snapshot = try executor.Snapshot.init(alloc, path, captured_file);
    defer snapshot.deinit(alloc);
    alloc.free(captured_file);

    const calls = fixture_calls(&snapshot);
    var executions: [2]executor.Execution = undefined;
    var run_count: usize = 0;
    defer for (executions[0..run_count]) |*execution| execution.deinit(alloc);
    switch (mode) {
        .compare => {
            executions[0] = try executor.execute(alloc, &snapshot, &calls, .disabled);
            run_count = 1;
            executions[1] = try executor.execute(alloc, &snapshot, &calls, .enabled);
            run_count = 2;
        },
        .disabled, .enabled => {
            executions[0] = try executor.execute(alloc, &snapshot, &calls, if (mode == .enabled) .enabled else .disabled);
            run_count = 1;
        },
    }
    const parity: ?bool = if (mode == .compare) receipts_equal(executions[0].receipts, executions[1].receipts) else null;
    const reports = try alloc.alloc(RunReport, run_count);
    for (executions[0..run_count], 0..) |execution, run_index| {
        const execution_mode: contracts.Mode = if (mode == .compare and run_index == 0 or mode == .disabled) .disabled else .enabled;
        try validate_fixture(&snapshot, &calls, execution, execution_mode);
        reports[run_index] = try run_report(alloc, execution, execution_mode);
    }
    const report = .{
        .experimental_scope = "certified embedded immutable content-reader sharing; fixture host admissions; no production permission integration or performance claim",
        .mode = @tagName(mode),
        .immutable_input_sha256 = @as([]const u8, &snapshot.input_hash_hex),
        .immutable_input_bytes = snapshot.bytes.len,
        .logical_call_count = calls.len,
        .fixture_contract_verified = true,
        .parity = parity,
        .runs = reports,
    };
    var writer: std.Io.Writer.Allocating = .init(alloc);
    defer writer.deinit();
    try std.json.Stringify.value(report, .{ .whitespace = .indent_2 }, &writer.writer);
    try writer.writer.writeByte('\n');
    try std.Io.File.stdout().writeStreamingAll(init.io, writer.written());
    if (parity != null and !parity.?) return error.ReceiptParityFailed;
}

fn fixture_calls(snapshot: *const executor.Snapshot) [10]contracts.LogicalCall {
    var calls: [10]contracts.LogicalCall = undefined;
    for (0..4) |window_index| {
        for (0..2) |agent_index| {
            const index = window_index * 2 + agent_index;
            calls[index] = fixture_call(snapshot, @intCast(index + 1), if (agent_index == 0) "agent-a" else "agent-b", window_index * 64);
        }
    }
    calls[8] = fixture_call(snapshot, 9, "denied-agent", 0);
    calls[8].admission = .denied;
    calls[9] = fixture_call(snapshot, 10, "stale-agent", 0);
    calls[9].admission.admitted.current_authority.generation += 1;
    return calls;
}

fn fixture_call(snapshot: *const executor.Snapshot, id: u64, agent_id: []const u8, offset: usize) contracts.LogicalCall {
    const request: contracts.CallBinding = .{
        .id = id,
        .agent_id = agent_id,
        .principal_domain = "fixture-operator",
        .task_id = "fixture-task",
        .tool_id = "embedded-content-reader",
        .effect = .snapshot_read,
        .snapshot = snapshot.identity(),
        .args = .{ .path = snapshot.path, .window = .{ .offset = offset, .length = 64 }, .options = "raw" },
        .result = .{ .schema_id = "content", .version = 1, .encoding = .bytes },
        .output_budget = 64,
        .authority = .{ .partition = "fixture-read", .epoch = 1, .generation = 1 },
    };
    return .{
        .request = request,
        .admission = .{ .admitted = .{
            .binding = request,
            .current_authority = request.authority,
            .immutable_snapshot = request.snapshot,
        } },
    };
}

const CallReport = struct {
    logical_id: u64,
    agent_id: []const u8,
    principal_domain: []const u8,
    task_id: []const u8,
    admission_status: []const u8,
    status: []const u8,
    physical_group: ?usize,
    output_bytes: usize,
    output_sha256: []const u8,
    output_hex: []const u8,
};

const RunReport = struct {
    mode: []const u8,
    logical_call_count: usize,
    receipt_count: usize,
    physical_reads: usize,
    receipts: []CallReport,
};

fn run_report(alloc: std.mem.Allocator, execution: executor.Execution, mode: contracts.Mode) !RunReport {
    const receipts = try alloc.alloc(CallReport, execution.receipts.len);
    for (execution.receipts, 0..) |receipt, index| {
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(receipt.output, &hash, .{});
        receipts[index] = .{
            .logical_id = receipt.request.id,
            .agent_id = receipt.request.agent_id,
            .principal_domain = receipt.request.principal_domain,
            .task_id = receipt.request.task_id,
            .admission_status = @tagName(receipt.admission_status),
            .status = @tagName(receipt.status),
            .physical_group = receipt.physical_group,
            .output_bytes = receipt.output.len,
            .output_sha256 = try hex_owned(alloc, &hash),
            .output_hex = try hex_owned(alloc, receipt.output),
        };
    }
    return .{
        .mode = @tagName(mode),
        .logical_call_count = execution.plan.logical_calls.len,
        .receipt_count = execution.receipts.len,
        .physical_reads = execution.physical_read_count,
        .receipts = receipts,
    };
}

fn hex_owned(alloc: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    const hex = try alloc.alloc(u8, bytes.len * 2);
    const alphabet = "0123456789abcdef";
    for (bytes, 0..) |byte, index| {
        hex[index * 2] = alphabet[byte >> 4];
        hex[index * 2 + 1] = alphabet[byte & 15];
    }
    return hex;
}

fn receipts_equal(a: []const contracts.Receipt, b: []const contracts.Receipt) bool {
    if (a.len != b.len) return false;
    for (a, b) |receipt_a, receipt_b| {
        if (receipt_a.request.id != receipt_b.request.id or
            !std.mem.eql(u8, receipt_a.request.agent_id, receipt_b.request.agent_id) or
            !std.mem.eql(u8, receipt_a.request.principal_domain, receipt_b.request.principal_domain) or
            !std.mem.eql(u8, receipt_a.request.task_id, receipt_b.request.task_id) or
            receipt_a.admission_status != receipt_b.admission_status or
            receipt_a.status != receipt_b.status or
            !std.mem.eql(u8, receipt_a.output, receipt_b.output)) return false;
    }
    return true;
}

fn validate_fixture(snapshot: *const executor.Snapshot, calls: []const contracts.LogicalCall, execution: executor.Execution, mode: contracts.Mode) !void {
    if (execution.receipts.len != calls.len) return error.FixtureReceiptCountMismatch;
    const allowed_calls = calls.len - 2;
    const expected_reads = if (mode == .enabled) allowed_calls / 2 else allowed_calls;
    if (execution.physical_read_count != expected_reads) return error.FixturePhysicalReadCountMismatch;
    for (execution.receipts, calls, 0..) |receipt, call, index| {
        if (receipt.request.id != call.request.id or
            !std.mem.eql(u8, receipt.request.agent_id, call.request.agent_id) or
            !std.mem.eql(u8, receipt.request.principal_domain, call.request.principal_domain) or
            !std.mem.eql(u8, receipt.request.task_id, call.request.task_id)) return error.FixtureIdentityMismatch;
        if (index < allowed_calls) {
            if (receipt.admission_status != .admitted or receipt.status != .success or receipt.physical_group == null)
                return error.FixtureAllowedCallFailed;
            const offset = call.request.args.window.offset;
            const length = call.request.args.window.length;
            if (!std.mem.eql(u8, receipt.output, snapshot.bytes[offset..][0..length])) return error.FixtureOutputMismatch;
        } else {
            const expected_admission: contracts.AdmissionStatus = if (index == allowed_calls) .denied else .stale_authority;
            if (receipt.admission_status != expected_admission or receipt.status != .admission_rejected or
                receipt.physical_group != null or receipt.output.len != 0) return error.FixtureRejectedCallExecuted;
        }
    }
}

test "demo compares full receipt bytes and identities rather than aggregate counts" {
    var snapshot = try executor.Snapshot.init(std.testing.allocator, "fixture", "abcdef");
    defer snapshot.deinit(std.testing.allocator);
    var call = fixture_call(&snapshot, 1, "agent-a", 0);
    call.request.args.window.length = 3;
    call.admission.admitted.binding = call.request;
    var execution = try executor.execute(std.testing.allocator, &snapshot, &.{call}, .enabled);
    defer execution.deinit(std.testing.allocator);
    var altered = execution.receipts[0];
    try std.testing.expect(receipts_equal(execution.receipts, &.{altered}));
    altered.output = "abd";
    try std.testing.expect(!receipts_equal(execution.receipts, &.{altered}));
    altered = execution.receipts[0];
    altered.request.agent_id = "other-agent";
    try std.testing.expect(!receipts_equal(execution.receipts, &.{altered}));
    altered = execution.receipts[0];
    altered.admission_status = .denied;
    try std.testing.expect(!receipts_equal(execution.receipts, &.{altered}));
}
