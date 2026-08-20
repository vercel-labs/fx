const std = @import("std");
const builtin = @import("builtin");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const secret = @import("../auth/secret.zig");

pub const service_name = "FX_AI_GATEWAY_API_KEY";
const mcp_credentials_service_name = "FX_MCP_OAUTH_CREDENTIALS_V1";
pub const oauth_session_service_name = "FX_OAUTH_SESSION_V1";

/// Backing store for a resolved account name. Must outlive any argv built from it.
pub const AccountBuffer = [256]u8;

const passwd_scratch_bytes = 2048;
const max_mcp_credentials_bytes: usize = 1024 * 1024;
const max_oauth_session_bytes: usize = 64 * 1024;
const keychain_process_timeout: std.Io.Timeout = .{
    .duration = .{
        .raw = .{ .nanoseconds = 10 * std.time.ns_per_s },
        .clock = .awake,
    },
};

pub const Error = error{
    Cancelled,
    UnsupportedPlatform,
    UserNotSet,
    KeychainItemNotFound,
    KeychainReadFailed,
    KeychainWriteFailed,
    KeychainDeleteFailed,
};

pub fn isAvailable() bool {
    return builtin.os.tag == .macos;
}

pub fn isDisabled() bool {
    const value = io_mod.getenv("FX_DISABLE_KEYCHAIN") orelse return false;
    return std.mem.eql(u8, value, "1") or std.ascii.eqlIgnoreCase(value, "true");
}

/// Returns a slice borrowing `buf`. `USER` stays authoritative when set, because it
/// is the only way to target a non-login account. ACP clients launched by GUI editors
/// inherit a thinner environment than a shell, so the operating system supplies the
/// account when `USER` is absent instead of failing the read.
fn accountName(buf: *AccountBuffer) Error![]const u8 {
    if (io_mod.getenv("USER")) |user| {
        if (user.len > 0 and user.len <= buf.len) {
            @memcpy(buf[0..user.len], user);
            return buf[0..user.len];
        }
    }
    if (osAccountName(buf)) |name| {
        debug_trace.logf("keychain", "account resolved from os; step=env unavailable", .{});
        return name;
    }
    debug_trace.logf("keychain", "account failed step=resolve err=UserNotSet", .{});
    return error.UserNotSet;
}

fn osAccountName(buf: *AccountBuffer) ?[]const u8 {
    if (comptime builtin.os.tag == .macos) return posixAccountName(buf);
    return null;
}

fn posixAccountName(buf: *AccountBuffer) ?[]const u8 {
    var entry: std.c.passwd = undefined;
    var scratch: [passwd_scratch_bytes]u8 = undefined;
    var found: ?*std.c.passwd = null;
    if (std.c.getpwuid_r(std.c.getuid(), &entry, &scratch, scratch.len, &found) != 0) return null;

    const record = found orelse return null;
    const name_ptr = record.name orelse return null;
    const name = std.mem.span(name_ptr);
    if (name.len == 0 or name.len > buf.len) return null;
    @memcpy(buf[0..name.len], name);
    return buf[0..name.len];
}

pub fn load(alloc: std.mem.Allocator) !?[]u8 {
    return loadFromService(alloc, service_name);
}

pub fn loadMcpCredentials(alloc: std.mem.Allocator) !?[]u8 {
    return loadMcpValueMacControlled(alloc, mcp_credentials_service_name, null);
}

pub fn loadOAuthSession(alloc: std.mem.Allocator) !?[]u8 {
    return loadMcpValueMacControlled(alloc, oauth_session_service_name, null);
}

pub fn loadMcpCredentialsCancellable(
    alloc: std.mem.Allocator,
    cancel_flag: *const std.atomic.Value(bool),
) !?[]u8 {
    return loadMcpValueMacControlled(
        alloc,
        mcp_credentials_service_name,
        cancel_flag,
    );
}

fn loadFromService(alloc: std.mem.Allocator, service: []const u8) !?[]u8 {
    if (!isAvailable()) return null;

    var account_buf: AccountBuffer = undefined;
    const account = try accountName(&account_buf);
    const result = std.process.run(alloc, io_mod.getIo(), .{
        .argv = &.{ "/usr/bin/security", "find-generic-password", "-a", account, "-s", service, "-w" },
    }) catch |err| {
        debug_trace.logf("keychain", "load failed step=spawn err={s}", .{@errorName(err)});
        return error.KeychainReadFailed;
    };
    defer alloc.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) {
        secret.zeroAndFree(alloc, result.stdout);
        if (std.mem.indexOf(u8, result.stderr, "could not be found") != null) {
            debug_trace.logf("keychain", "load failed step=lookup err=KeychainItemNotFound", .{});
            return error.KeychainItemNotFound;
        }
        debug_trace.logf("keychain", "load failed step=lookup err=KeychainReadFailed", .{});
        return error.KeychainReadFailed;
    }

    const trimmed = std.mem.trim(u8, result.stdout, "\r\n");
    if (trimmed.len == 0) {
        secret.zeroAndFree(alloc, result.stdout);
        return null;
    }
    if (trimmed.len == result.stdout.len) return result.stdout;

    const key = try alloc.dupe(u8, trimmed);
    secret.zeroAndFree(alloc, result.stdout);
    return key;
}

fn storeArgv(account: []const u8) [8][]const u8 {
    return .{ "/usr/bin/security", "add-generic-password", "-a", account, "-s", service_name, "-U", "-w" };
}

const store_value_script =
    \\log_user 0
    \\set timeout 10
    \\fconfigure stdin -translation binary -encoding binary
    \\set account_length [gets stdin]
    \\set service_length [gets stdin]
    \\set secret_length [gets stdin]
    \\set account [read stdin $account_length]
    \\set service [read stdin $service_length]
    \\set secret [read stdin $secret_length]
    \\spawn -noecho /usr/bin/security add-generic-password -a $account -s $service -U -w
    \\expect {
    \\    -exact "password data for new item:" {}
    \\    timeout { exit 124 }
    \\    eof { exit 1 }
    \\}
    \\send -- "$secret\r"
    \\expect {
    \\    -exact "retype password for new item:" {}
    \\    timeout { exit 124 }
    \\    eof { exit 1 }
    \\}
    \\send -- "$secret\r"
    \\expect {
    \\    eof {}
    \\    timeout { exit 124 }
    \\}
    \\set result [wait]
    \\if {![string is integer -strict [lindex $result 3]]} { exit 1 }
    \\exit [lindex $result 3]
;

// `security add-generic-password -w` uses a 128-byte interactive buffer. MCP's
// aggregate credential store is larger, so use the native Security API through
// the stable system osascript host. Account and service are non-secret argv;
// credential bytes travel only through stdin/stdout.
const mcp_keychain_script =
    \\ObjC.import("Security");
    \\ObjC.import("Foundation");
    \\const object = (value) => ObjC.castRefToObject(value);
    \\function query(account, service) {
    \\    const value = $.NSMutableDictionary.alloc.init;
    \\    value.setObjectForKey(object($.kSecClassGenericPassword), object($.kSecClass));
    \\    value.setObjectForKey($(account), object($.kSecAttrAccount));
    \\    value.setObjectForKey($(service), object($.kSecAttrService));
    \\    return value;
    \\}
    \\function failed(status) {
    \\    throw new Error("keychain status=" + status);
    \\}
    \\function run(argv) {
    \\    const operation = argv[0];
    \\    const value = query(argv[1], argv[2]);
    \\    if (operation === "load") {
    \\        value.setObjectForKey($.NSNumber.numberWithBool(true), object($.kSecReturnData));
    \\        value.setObjectForKey(object($.kSecMatchLimitOne), object($.kSecMatchLimit));
    \\        const result = Ref();
    \\        const status = $.SecItemCopyMatching(value, result);
    \\        if (status === -25300) return;
    \\        if (status !== 0) failed(status);
    \\        $.NSFileHandle.fileHandleWithStandardOutput.writeData(
    \\            ObjC.castRefToObject(result[0]),
    \\        );
    \\        return;
    \\    }
    \\    if (operation === "store") {
    \\        const secret = $.NSFileHandle.fileHandleWithStandardInput.readDataToEndOfFile;
    \\        if (secret.length === 0) failed(-50);
    \\        const update = $.NSMutableDictionary.alloc.init;
    \\        update.setObjectForKey(secret, object($.kSecValueData));
    \\        const updateStatus = $.SecItemUpdate(value, update);
    \\        if (updateStatus === 0) return;
    \\        if (updateStatus !== -25300) failed(updateStatus);
    \\        value.setObjectForKey(secret, object($.kSecValueData));
    \\        const addStatus = $.SecItemAdd(value, null);
    \\        if (addStatus !== 0) failed(addStatus);
    \\        return;
    \\    }
    \\    if (operation === "delete") {
    \\        const status = $.SecItemDelete(value);
    \\        if (status === 0) return "1";
    \\        if (status === -25300) return "0";
    \\        failed(status);
    \\    }
    \\    failed(-50);
    \\}
;

fn storeValueArgv() [3][]const u8 {
    return .{ "/usr/bin/expect", "-c", store_value_script };
}

/// The returned argv borrows `account_buf`, which must outlive it.
pub fn storeInteractiveArgv(account_buf: *AccountBuffer) Error![8][]const u8 {
    if (!isAvailable()) return error.UnsupportedPlatform;
    return storeArgv(try accountName(account_buf));
}

pub fn storeInteractive() Error!void {
    if (!isAvailable()) return error.UnsupportedPlatform;

    // Let macOS prompt for the secret; do not put it in argv.
    var account_buf: AccountBuffer = undefined;
    const argv = try storeInteractiveArgv(&account_buf);
    var child = std.process.spawn(io_mod.getIo(), .{
        .argv = &argv,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch |err| return writeFailed("interactive_spawn", err);
    const term = child.wait(io_mod.getIo()) catch |err| return writeFailed("interactive_wait", err);
    if (term != .exited or term.exited != 0) return writeFailedTerm("interactive_exit", term);
}

pub fn storeValue(value: []const u8) Error!void {
    if (!isAvailable()) return error.UnsupportedPlatform;
    if (value.len == 0) return error.KeychainWriteFailed;

    if (comptime builtin.os.tag == .macos) return storeValueMac(service_name, value);
    return error.UnsupportedPlatform;
}

pub fn storeMcpCredentials(value: []const u8) Error!void {
    return storeMcpCredentialsControlled(value, null);
}

pub fn storeOAuthSession(value: []const u8) Error!void {
    if (!isAvailable()) return error.UnsupportedPlatform;
    if (value.len == 0 or value.len > max_oauth_session_bytes) {
        return error.KeychainWriteFailed;
    }
    return storeMcpValueMac(oauth_session_service_name, value);
}

pub fn storeMcpCredentialsCancellable(
    value: []const u8,
    cancel_flag: *const std.atomic.Value(bool),
) Error!void {
    return storeMcpCredentialsControlled(value, cancel_flag);
}

fn storeMcpCredentialsControlled(
    value: []const u8,
    cancel_flag: ?*const std.atomic.Value(bool),
) Error!void {
    if (!isAvailable()) return error.UnsupportedPlatform;
    if (value.len == 0 or value.len > max_mcp_credentials_bytes) {
        return error.KeychainWriteFailed;
    }

    if (comptime builtin.os.tag == .macos) {
        return storeMcpValueMacControlled(
            mcp_credentials_service_name,
            value,
            cancel_flag,
        );
    }
    return error.UnsupportedPlatform;
}

pub fn deleteMcpCredentials(alloc: std.mem.Allocator) Error!bool {
    return deleteMcpValueMac(alloc, mcp_credentials_service_name);
}

pub fn deleteOAuthSession(alloc: std.mem.Allocator) Error!bool {
    return deleteMcpValueMac(alloc, oauth_session_service_name);
}

fn writeFailed(step: []const u8, err: anyerror) Error {
    debug_trace.logf("keychain", "store failed step={s} err={s}", .{ step, @errorName(err) });
    return error.KeychainWriteFailed;
}

fn writeFailedTerm(step: []const u8, term: std.process.Child.Term) Error {
    debug_trace.logf("keychain", "store failed step={s} term={t}", .{ step, term });
    return error.KeychainWriteFailed;
}

fn storeValueMac(service: []const u8, value: []const u8) Error!void {
    var account_buf: AccountBuffer = undefined;
    const account = try accountName(&account_buf);
    const argv = storeValueArgv();
    var child = std.process.spawn(io_mod.getIo(), .{
        .argv = &argv,
        .stdin = .pipe,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch |err| return writeFailed("spawn", err);
    defer child.kill(io_mod.getIo());

    var input = child.stdin orelse return writeFailed("stdin", error.BrokenPipe);
    child.stdin = null;
    var input_open = true;
    defer if (input_open) input.close(io_mod.getIo());

    var header_buffer: [96]u8 = undefined;
    const header = std.fmt.bufPrint(
        &header_buffer,
        "{d}\n{d}\n{d}\n",
        .{ account.len, service.len, value.len },
    ) catch |err| return writeFailed("header", err);
    input.writeStreamingAll(io_mod.getIo(), header) catch |err| return writeFailed("write_header", err);
    input.writeStreamingAll(io_mod.getIo(), account) catch |err| return writeFailed("write_account", err);
    input.writeStreamingAll(io_mod.getIo(), service) catch |err| return writeFailed("write_service", err);
    input.writeStreamingAll(io_mod.getIo(), value) catch |err| return writeFailed("write_secret", err);
    input.close(io_mod.getIo());
    input_open = false;

    const term = child.wait(io_mod.getIo()) catch |err| return writeFailed("wait", err);
    if (term != .exited or term.exited != 0) return writeFailedTerm("exit", term);
}

fn mcpScriptArgv(
    operation: []const u8,
    account: []const u8,
    service: []const u8,
) [8][]const u8 {
    return .{
        "/usr/bin/osascript",
        "-l",
        "JavaScript",
        "-e",
        mcp_keychain_script,
        operation,
        account,
        service,
    };
}

fn loadMcpValueMac(
    alloc: std.mem.Allocator,
    service: []const u8,
) Error!?[]u8 {
    return loadMcpValueMacControlled(alloc, service, null);
}

fn loadMcpValueMacControlled(
    alloc: std.mem.Allocator,
    service: []const u8,
    cancel_flag: ?*const std.atomic.Value(bool),
) Error!?[]u8 {
    if (!isAvailable()) return error.UnsupportedPlatform;

    var account_buf: AccountBuffer = undefined;
    const account = try accountName(&account_buf);
    const argv = mcpScriptArgv("load", account, service);
    const result = runMcpKeychainProcess(
        alloc,
        &argv,
        cancel_flag,
        .limited(max_mcp_credentials_bytes + 1),
    ) catch |err| {
        if (err == error.Cancelled) return error.Cancelled;
        debug_trace.logf("keychain", "load failed step=native err={s}", .{@errorName(err)});
        return error.KeychainReadFailed;
    };
    defer alloc.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) {
        secret.zeroAndFree(alloc, result.stdout);
        debug_trace.logf("keychain", "load failed step=native term={t}", .{result.term});
        return error.KeychainReadFailed;
    }
    if (result.stdout.len == 0) {
        alloc.free(result.stdout);
        return error.KeychainItemNotFound;
    }
    if (result.stdout.len > max_mcp_credentials_bytes) {
        secret.zeroAndFree(alloc, result.stdout);
        return error.KeychainReadFailed;
    }
    return result.stdout;
}

const McpKeychainRunContext = struct {
    alloc: std.mem.Allocator,
    argv: []const []const u8,
    stdout_limit: std.Io.Limit,
};

const McpKeychainRunEvent = union(enum) {
    process: anyerror!std.process.RunResult,
    cancelled: anyerror!void,
};

fn runMcpKeychainChild(
    context: *const McpKeychainRunContext,
) anyerror!std.process.RunResult {
    return std.process.run(context.alloc, io_mod.getIo(), .{
        .argv = context.argv,
        .stdout_limit = context.stdout_limit,
        .stderr_limit = .limited(4096),
        .timeout = keychain_process_timeout,
    });
}

fn waitForMcpKeychainCancellation(
    cancel_flag: *const std.atomic.Value(bool),
) anyerror!void {
    while (!cancel_flag.load(.acquire)) {
        try io_mod.getIo().sleep(.fromMilliseconds(5), .awake);
    }
}

fn runMcpKeychainProcess(
    alloc: std.mem.Allocator,
    argv: []const []const u8,
    cancel_flag: ?*const std.atomic.Value(bool),
    stdout_limit: std.Io.Limit,
) anyerror!std.process.RunResult {
    const flag = cancel_flag orelse return runMcpKeychainChild(&.{
        .alloc = alloc,
        .argv = argv,
        .stdout_limit = stdout_limit,
    });
    var context = McpKeychainRunContext{
        .alloc = alloc,
        .argv = argv,
        .stdout_limit = stdout_limit,
    };
    var select_buffer: [2]McpKeychainRunEvent = undefined;
    var select: std.Io.Select(McpKeychainRunEvent) = .init(
        io_mod.getIo(),
        &select_buffer,
    );
    select.concurrent(.process, runMcpKeychainChild, .{&context}) catch |err|
        return err;
    select.concurrent(
        .cancelled,
        waitForMcpKeychainCancellation,
        .{flag},
    ) catch |err| {
        select.cancelDiscard();
        return err;
    };
    const event = select.await() catch |err| {
        select.cancelDiscard();
        return err;
    };
    return switch (event) {
        .process => |result| blk: {
            select.cancelDiscard();
            break :blk result catch |err| return err;
        },
        .cancelled => |result| {
            result catch |err| {
                select.cancelDiscard();
                return err;
            };
            select.cancelDiscard();
            return error.Cancelled;
        },
    };
}

const McpStoreEvent = union(enum) {
    wait: anyerror!std.process.Child.Term,
    timeout: anyerror!void,
    cancelled: anyerror!void,
};

fn waitForMcpStoreChild(child: *std.process.Child) anyerror!std.process.Child.Term {
    return child.wait(io_mod.getIo());
}

fn waitForMcpStoreTimeout() anyerror!void {
    return std.Io.Timeout.sleep(keychain_process_timeout, io_mod.getIo());
}

fn waitForMcpStore(
    child: *std.process.Child,
    cancel_flag: ?*const std.atomic.Value(bool),
) Error!std.process.Child.Term {
    var select_buffer: [3]McpStoreEvent = undefined;
    var select: std.Io.Select(McpStoreEvent) = .init(io_mod.getIo(), &select_buffer);
    select.concurrent(.wait, waitForMcpStoreChild, .{child}) catch |err|
        return writeFailed("native_wait_start", err);
    select.concurrent(.timeout, waitForMcpStoreTimeout, .{}) catch |err| {
        select.cancelDiscard();
        return writeFailed("native_timeout_start", err);
    };
    if (cancel_flag) |flag| {
        select.concurrent(
            .cancelled,
            waitForMcpKeychainCancellation,
            .{flag},
        ) catch |err| {
            select.cancelDiscard();
            return writeFailed("native_cancel_start", err);
        };
    }
    const event = select.await() catch |err| {
        select.cancelDiscard();
        return writeFailed("native_wait", err);
    };
    switch (event) {
        .wait => |result| {
            select.cancelDiscard();
            return result catch |err| writeFailed("native_wait", err);
        },
        .timeout => |result| {
            result catch |err| {
                select.cancelDiscard();
                return writeFailed("native_timeout", err);
            };
            select.cancelDiscard();
            return writeFailed("native_wait", error.Timeout);
        },
        .cancelled => |result| {
            result catch |err| {
                select.cancelDiscard();
                return writeFailed("native_cancel", err);
            };
            select.cancelDiscard();
            return error.Cancelled;
        },
    }
}

fn storeMcpValueMac(service: []const u8, value: []const u8) Error!void {
    return storeMcpValueMacControlled(service, value, null);
}

fn storeMcpValueMacControlled(
    service: []const u8,
    value: []const u8,
    cancel_flag: ?*const std.atomic.Value(bool),
) Error!void {
    var account_buf: AccountBuffer = undefined;
    const account = try accountName(&account_buf);
    const argv = mcpScriptArgv("store", account, service);
    var child = std.process.spawn(io_mod.getIo(), .{
        .argv = &argv,
        .stdin = .pipe,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch |err| return writeFailed("native_spawn", err);
    defer child.kill(io_mod.getIo());

    var input = child.stdin orelse return writeFailed("native_stdin", error.BrokenPipe);
    child.stdin = null;
    var input_open = true;
    defer if (input_open) input.close(io_mod.getIo());
    input.writeStreamingAll(io_mod.getIo(), value) catch |err|
        return writeFailed("native_write", err);
    input.close(io_mod.getIo());
    input_open = false;

    const term = try waitForMcpStore(&child, cancel_flag);
    if (term != .exited or term.exited != 0) {
        return writeFailedTerm("native_exit", term);
    }
}

fn deleteMcpValueMac(
    alloc: std.mem.Allocator,
    service: []const u8,
) Error!bool {
    if (!isAvailable()) return error.UnsupportedPlatform;

    var account_buf: AccountBuffer = undefined;
    const account = try accountName(&account_buf);
    const argv = mcpScriptArgv("delete", account, service);
    const result = std.process.run(alloc, io_mod.getIo(), .{
        .argv = &argv,
        .stdout_limit = .limited(16),
        .stderr_limit = .limited(4096),
        .timeout = keychain_process_timeout,
    }) catch |err| {
        debug_trace.logf("keychain", "delete failed step=native err={s}", .{@errorName(err)});
        return error.KeychainDeleteFailed;
    };
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) {
        debug_trace.logf("keychain", "delete failed step=native term={t}", .{result.term});
        return error.KeychainDeleteFailed;
    }
    const marker = std.mem.trim(u8, result.stdout, "\r\n");
    if (std.mem.eql(u8, marker, "1")) return true;
    if (std.mem.eql(u8, marker, "0")) return false;
    return error.KeychainDeleteFailed;
}

fn deleteServiceItem(
    alloc: std.mem.Allocator,
    service: []const u8,
) Error!bool {
    if (!isAvailable()) return error.UnsupportedPlatform;

    var account_buf: AccountBuffer = undefined;
    const account = try accountName(&account_buf);
    const result = std.process.run(alloc, io_mod.getIo(), .{
        .argv = &.{
            "/usr/bin/security",
            "delete-generic-password",
            "-a",
            account,
            "-s",
            service,
        },
    }) catch |err| {
        debug_trace.logf("keychain", "delete failed step=spawn err={s}", .{@errorName(err)});
        return error.KeychainDeleteFailed;
    };
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);
    if (result.term == .exited and result.term.exited == 0) return true;
    if (std.mem.find(u8, result.stderr, "could not be found") != null) return false;
    debug_trace.logf("keychain", "delete failed step=remove term={t}", .{result.term});
    return error.KeychainDeleteFailed;
}

const test_service_name = "FX_TEST_AI_GATEWAY_API_KEY";

fn deleteTestServiceItem(alloc: std.mem.Allocator) void {
    _ = deleteServiceItem(alloc, test_service_name) catch {};
}

test "account name resolves from the operating system when USER is unset" {
    if (comptime builtin.os.tag != .macos) return error.SkipZigTest;
    try std.testing.expect(io_mod.getenv("USER") == null);

    var buf: AccountBuffer = undefined;
    const account = try accountName(&buf);
    try std.testing.expect(account.len > 0);
    try std.testing.expectEqual(@intFromPtr(&buf), @intFromPtr(account.ptr));
}

test "stored key round-trips byte-identically with USER unset" {
    if (comptime builtin.os.tag != .macos) return error.SkipZigTest;
    if (isDisabled()) return error.SkipZigTest;
    try std.testing.expect(io_mod.getenv("USER") == null);

    const alloc = std.testing.allocator;
    const written = "vt1-round-trip-value";

    storeValueMac(test_service_name, written) catch return error.SkipZigTest;
    defer deleteTestServiceItem(alloc);

    const read_back = (try loadFromService(alloc, test_service_name)) orelse
        return error.KeychainItemNotFound;
    defer secret.zeroAndFree(alloc, read_back);
    try std.testing.expectEqualStrings(written, read_back);
    try std.testing.expect(try deleteServiceItem(alloc, test_service_name));
    try std.testing.expectError(
        error.KeychainItemNotFound,
        loadFromService(alloc, test_service_name),
    );
}

test "MCP Keychain storage round-trips values beyond the security prompt limit" {
    if (comptime builtin.os.tag != .macos) return error.SkipZigTest;
    if (isDisabled()) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    const test_mcp_service = "FX_TEST_MCP_OAUTH_CREDENTIALS_V1";
    const written = "mcp-credential-section-" ** 32;

    storeMcpValueMac(test_mcp_service, written) catch return error.SkipZigTest;
    defer _ = deleteMcpValueMac(alloc, test_mcp_service) catch false;

    const read_back = (try loadMcpValueMac(alloc, test_mcp_service)) orelse
        return error.KeychainItemNotFound;
    defer secret.zeroAndFree(alloc, read_back);
    try std.testing.expectEqualStrings(written, read_back);
    try std.testing.expect(try deleteMcpValueMac(alloc, test_mcp_service));
    try std.testing.expectError(
        error.KeychainItemNotFound,
        loadMcpValueMac(alloc, test_mcp_service),
    );
}

test "Keychain store command has no secret argument" {
    const argv = storeArgv("user");
    try std.testing.expectEqualStrings("-w", argv[argv.len - 1]);
    for (argv) |arg| {
        try std.testing.expect(!std.mem.eql(u8, arg, "vca_secret_value"));
    }
}

test "cancellable MCP Keychain runner interrupts and reaps a stalled child" {
    if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi) {
        return error.SkipZigTest;
    }
    const Canceller = struct {
        flag: *std.atomic.Value(bool),

        fn run(self: *@This()) void {
            io_mod.sleep(25 * std.time.ns_per_ms);
            self.flag.store(true, .release);
        }
    };

    var cancel = std.atomic.Value(bool).init(false);
    var canceller = Canceller{ .flag = &cancel };
    const thread = try std.Thread.spawn(.{}, Canceller.run, .{&canceller});
    const started_ms = io_mod.milliTimestamp();
    try std.testing.expectError(
        error.Cancelled,
        runMcpKeychainProcess(
            std.testing.allocator,
            &.{ "/bin/sh", "-c", "exec sleep 60" },
            &cancel,
            .limited(16),
        ),
    );
    thread.join();
    try std.testing.expect(io_mod.milliTimestamp() - started_ms < 1_000);
}

test "cancellable MCP Keychain store wait interrupts a stalled child" {
    if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi) {
        return error.SkipZigTest;
    }
    const Canceller = struct {
        flag: *std.atomic.Value(bool),

        fn run(self: *@This()) void {
            io_mod.sleep(25 * std.time.ns_per_ms);
            self.flag.store(true, .release);
        }
    };

    var child = try std.process.spawn(std.testing.io, .{
        .argv = &.{ "/bin/sh", "-c", "exec sleep 60" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    defer child.kill(std.testing.io);
    var cancel = std.atomic.Value(bool).init(false);
    var canceller = Canceller{ .flag = &cancel };
    const thread = try std.Thread.spawn(.{}, Canceller.run, .{&canceller});
    const started_ms = io_mod.milliTimestamp();
    try std.testing.expectError(
        error.Cancelled,
        waitForMcpStore(&child, &cancel),
    );
    thread.join();
    try std.testing.expect(io_mod.milliTimestamp() - started_ms < 1_000);
}

test "Keychain value store uses a bounded PTY bridge without a secret argument" {
    const argv = storeValueArgv();
    try std.testing.expectEqualStrings("/usr/bin/expect", argv[0]);
    try std.testing.expect(std.mem.indexOf(u8, argv[2], "set timeout 10") != null);
    for (argv) |arg| {
        try std.testing.expect(!std.mem.eql(u8, arg, "vca_secret_value"));
    }
}
