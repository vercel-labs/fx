//! Program Resume Protocol (OSC 7577) reports for the interactive shell.
//!
//! fx tells the terminal which command resumes the current session, or that
//! the earlier command no longer applies. Each report ends with a SHA-256 tag
//! over its body and the token. The encoder reads no environment, clock, or
//! file and allocates nothing: the caller passes the token and the time in.
//! `takeToken` is the one function that changes process state. It runs once at
//! startup, removes the token from the environment, and keeps it for `keptToken`.
//! Specification: https://www.superlogical.com/rex/docs/build/program-resume

const std = @import("std");

pub const token_env_name = "OSC7577_TOKEN";

pub const max_sequence_bytes: usize = 2048;
const max_argv_elements: usize = 64;
const min_token_bytes = 22;
const max_token_bytes = 64;
const max_session_id_bytes: usize = 128;
const max_program_name_bytes: usize = 255;

const prefix = "\x1b]7577;";
const terminator = "\x1b\\";
const mac_field = ":mac=";
const resume_argument = "--resume";
/// A u32 or a positive i64 with its sign fits in this many bytes.
const max_decimal_bytes: usize = 20;
const last_c0_control: u21 = 0x1f;
const delete_codepoint: u21 = 0x7f;
const first_c1_control: u21 = 0x80;
const last_c1_control: u21 = 0x9f;

const base64 = std.base64.standard.Encoder;
const Sha256 = std.crypto.hash.sha2.Sha256;
const token_entry_prefix = token_env_name ++ "=";

/// `takeToken` sets these once at startup, before any thread starts. They are
/// read-only after that.
var process_token_buffer: [max_token_bytes]u8 = undefined;
var process_token_len: usize = 0;

/// `rememberProgramName` sets these once at startup, before any thread starts.
var program_name_buffer: [max_program_name_bytes]u8 = undefined;
var program_name_len: usize = 0;

fn isValidToken(token: []const u8) bool {
    if (token.len < min_token_bytes or token.len > max_token_bytes) return false;
    for (token) |byte| {
        if (!isTokenByte(byte)) return false;
    }
    return true;
}

fn isTokenByte(byte: u8) bool {
    return switch (byte) {
        'A'...'Z', 'a'...'z', '0'...'9', '_', '-' => true,
        else => false,
    };
}

/// Removes every OSC7577_TOKEN entry from `envp`, in place, and keeps the first
/// valid value. Entries for other names keep their order.
pub fn takeToken(envp: [*:null]?[*:0]c_char) void {
    var read: usize = 0;
    var write: usize = 0;
    while (envp[read]) |item| : (read += 1) {
        const text = entryText(item);
        if (std.mem.startsWith(u8, text, token_entry_prefix)) {
            keepFirstValidToken(text[token_entry_prefix.len..]);
            continue;
        }
        envp[write] = item;
        write += 1;
    }
    envp[write] = null;
}

fn entryText(item: [*:0]c_char) []const u8 {
    return std.mem.sliceTo(@as([*:0]const u8, @ptrCast(item)), 0);
}

fn keepFirstValidToken(value: []const u8) void {
    if (process_token_len != 0 or !isValidToken(value)) return;
    @memcpy(process_token_buffer[0..value.len], value);
    process_token_len = value.len;
}

/// The token `takeToken` kept, or null when the environment had none.
pub fn keptToken() ?[]const u8 {
    if (process_token_len == 0) return null;
    return process_token_buffer[0..process_token_len];
}

/// Keeps `argv0` as the program name when it is a bare command name. A path
/// keeps nothing, so the terminal looks the name up on its own PATH.
pub fn rememberProgramName(argv0: [*:0]const c_char) void {
    const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(argv0)), 0);
    if (!isBareProgramName(name)) return;
    @memcpy(program_name_buffer[0..name.len], name);
    program_name_len = name.len;
}

fn isBareProgramName(name: []const u8) bool {
    if (name.len == 0 or name.len > max_program_name_bytes) return false;
    if (name[0] == '-' or std.mem.findScalar(u8, name, '/') != null) return false;
    return isSafeText(name);
}

/// The bare program name that `rememberProgramName` kept, or null.
pub fn programName() ?[]const u8 {
    if (program_name_len == 0) return null;
    return program_name_buffer[0..program_name_len];
}

/// Puts the kept token back into `environ` for the relaunch that continues this
/// session. Returns false, and puts nothing, when no token was kept.
pub fn putToken(environ: *std.process.Environ.Map) !bool {
    const value = keptToken() orelse return false;
    try environ.put(token_env_name, value);
    return true;
}

fn resetTokenForTest() void {
    comptime std.debug.assert(@import("builtin").is_test);
    process_token_len = 0;
}

fn resetProgramNameForTest() void {
    comptime std.debug.assert(@import("builtin").is_test);
    program_name_len = 0;
}

pub const Command = struct {
    pid: u32,
    time_s: i64,
    argv: []const []const u8,
    cwd: ?[]const u8 = null,
};

/// Returns the full report in `buffer`, or null when the command cannot be
/// reported. The returned slice borrows `buffer`.
fn encodeReport(buffer: *[max_sequence_bytes]u8, command: Command, token: []const u8) ?[]const u8 {
    if (!isReportableCommand(command) or !isValidToken(token)) return null;
    var sink = newSequence(buffer);
    const fields_written = appendPidAndTime(&sink, command.pid, command.time_s) and
        appendArgv(&sink, command.argv) and
        appendCwd(&sink, command.cwd);
    if (!fields_written) return null;
    return finishSequence(&sink, token);
}

/// Returns a report that removes the record for this pid. The returned slice
/// borrows `buffer`.
fn encodeClear(buffer: *[max_sequence_bytes]u8, pid: u32, time_s: i64, token: []const u8) ?[]const u8 {
    if (!isPidAndTimeValid(pid, time_s) or !isValidToken(token)) return null;
    var sink = newSequence(buffer);
    const fields_written = appendPidAndTime(&sink, pid, time_s) and sink.append(":clear=1");
    if (!fields_written) return null;
    return finishSequence(&sink, token);
}

pub const Reporter = struct {
    last_session_id: [max_session_id_bytes]u8 = undefined,
    /// Null until the first session ID is seen. A longer ID sets the length
    /// without its bytes, so it never matches a later ID.
    last_session_len: ?usize = null,
    reported: bool = false,
    /// Holds the bytes that `update` and `clear` return. Those slices stay
    /// valid until the next call.
    sequence: [max_sequence_bytes]u8 = undefined,

    pub const Process = struct {
        pid: u32,
        time_s: i64,
        executable: []const u8,
        cwd: []const u8,
    };

    pub fn update(self: *Reporter, token: []const u8, process: Process, session_id: ?[]const u8) ?[]const u8 {
        const id = session_id orelse return null;
        if (self.isLastSessionId(id)) return null;
        self.rememberSessionId(id);
        if (id.len <= max_session_id_bytes) {
            const argv = [_][]const u8{ process.executable, resume_argument, id };
            const command = Command{
                .pid = process.pid,
                .time_s = process.time_s,
                .argv = &argv,
                .cwd = process.cwd,
            };
            if (encodeReport(&self.sequence, command, token)) |sequence| {
                self.reported = true;
                return sequence;
            }
        }
        return self.clear(token, process.pid, process.time_s);
    }

    pub fn clear(self: *Reporter, token: []const u8, pid: u32, time_s: i64) ?[]const u8 {
        if (!self.reported) return null;
        self.reported = false;
        return encodeClear(&self.sequence, pid, time_s, token);
    }

    /// True when `update` would act on this session ID, so a caller can skip
    /// building the process report when nothing changed.
    pub fn changed(self: *const Reporter, session_id: []const u8) bool {
        return !self.isLastSessionId(session_id);
    }

    fn isLastSessionId(self: *const Reporter, id: []const u8) bool {
        const last_len = self.last_session_len orelse return false;
        if (id.len > max_session_id_bytes or id.len != last_len) return false;
        return std.mem.eql(u8, self.last_session_id[0..last_len], id);
    }

    fn rememberSessionId(self: *Reporter, id: []const u8) void {
        self.last_session_len = id.len;
        if (id.len <= max_session_id_bytes) {
            @memcpy(self.last_session_id[0..id.len], id);
        }
    }
};

fn isReportableCommand(command: Command) bool {
    return isPidAndTimeValid(command.pid, command.time_s) and
        isValidArgv(command.argv) and
        isValidCwd(command.cwd);
}

fn isPidAndTimeValid(pid: u32, time_s: i64) bool {
    return pid != 0 and time_s > 0;
}

fn isValidArgv(argv: []const []const u8) bool {
    if (argv.len == 0 or argv.len > max_argv_elements) return false;
    if (!isValidFirstElement(argv[0])) return false;
    for (argv) |element| {
        if (!isSafeText(element)) return false;
    }
    return true;
}

/// The spec allows a first element that is an absolute path or a bare command
/// name. A relative path such as "./run.sh" is not allowed.
fn isValidFirstElement(name: []const u8) bool {
    if (isAbsolutePath(name)) return true;
    return name.len > 0 and name[0] != '-' and std.mem.findScalar(u8, name, '/') == null;
}

fn isValidCwd(cwd: ?[]const u8) bool {
    const path = cwd orelse return true;
    return isAbsolutePath(path) and isSafeText(path);
}

fn isAbsolutePath(path: []const u8) bool {
    return path.len > 0 and path[0] == '/';
}

/// Rejects text that is not UTF-8 or holds a C0 or C1 control character.
fn isSafeText(text: []const u8) bool {
    var view = std.unicode.Utf8View.init(text) catch return false;
    var codepoints = view.iterator();
    while (codepoints.nextCodepoint()) |codepoint| {
        if (isControlCodepoint(codepoint)) return false;
    }
    return true;
}

fn isControlCodepoint(codepoint: u21) bool {
    return codepoint <= last_c0_control or
        codepoint == delete_codepoint or
        (codepoint >= first_c1_control and codepoint <= last_c1_control);
}

/// Writes one sequence into a fixed buffer. Every write fails instead of
/// running past max_sequence_bytes, so no report can exceed the protocol limit.
const Sink = struct {
    buffer: *[max_sequence_bytes]u8,
    len: usize,

    fn reserve(self: *Sink, count: usize) ?[]u8 {
        if (count > max_sequence_bytes - self.len) return null;
        const start = self.len;
        self.len += count;
        return self.buffer[start..self.len];
    }

    fn append(self: *Sink, bytes: []const u8) bool {
        const dest = self.reserve(bytes.len) orelse return false;
        @memcpy(dest, bytes);
        return true;
    }

    fn appendInt(self: *Sink, value: anytype) bool {
        var digits: [max_decimal_bytes]u8 = undefined;
        const length = std.fmt.printInt(&digits, value, 10, .lower, .{});
        return self.append(digits[0..length]);
    }

    fn appendBase64(self: *Sink, bytes: []const u8) bool {
        const dest = self.reserve(base64.calcSize(bytes.len)) orelse return false;
        _ = base64.encode(dest, bytes);
        return true;
    }
};

fn newSequence(buffer: *[max_sequence_bytes]u8) Sink {
    @memcpy(buffer[0..prefix.len], prefix);
    return .{ .buffer = buffer, .len = prefix.len };
}

fn appendPidAndTime(sink: *Sink, pid: u32, time_s: i64) bool {
    return sink.append("pid=") and
        sink.appendInt(pid) and
        sink.append(":time=") and
        sink.appendInt(time_s);
}

fn appendArgv(sink: *Sink, argv: []const []const u8) bool {
    if (!sink.append(":argv=")) return false;
    for (argv, 0..) |element, index| {
        if (index > 0 and !sink.append(",")) return false;
        if (!sink.appendBase64(element)) return false;
    }
    return true;
}

fn appendCwd(sink: *Sink, cwd: ?[]const u8) bool {
    const path = cwd orelse return true;
    return sink.append(":cwd=") and sink.appendBase64(path);
}

/// The tag covers the body, one ":", and the token. The body is the bytes
/// written so far, after the prefix.
fn finishSequence(sink: *Sink, token: []const u8) ?[]const u8 {
    const digest = tagDigest(sink.buffer[prefix.len..sink.len], token);
    const hex = std.fmt.bytesToHex(digest, .lower);
    const tail_written = sink.append(mac_field) and
        sink.append(&hex) and
        sink.append(terminator);
    if (!tail_written) return null;
    return sink.buffer[0..sink.len];
}

fn tagDigest(body: []const u8, token: []const u8) [Sha256.digest_length]u8 {
    var hasher = Sha256.init(.{});
    hasher.update(body);
    hasher.update(":");
    hasher.update(token);
    var digest: [Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    return digest;
}

const test_token = "dummy-token-replace-me";
const test_time_s: i64 = 1795543200;

fn expectSequence(comptime expected: []const u8, actual: ?[]const u8) !void {
    const sequence = actual orelse return error.ExpectedSequence;
    try std.testing.expectEqualStrings(expected, sequence);
}

fn expectRejected(command: Command, token: []const u8) !void {
    var buffer: [max_sequence_bytes]u8 = undefined;
    try std.testing.expect(encodeReport(&buffer, command, token) == null);
}

test "report with argv matches the spec vector" {
    var buffer: [max_sequence_bytes]u8 = undefined;
    const argv = [_][]const u8{ "nvim", "-S", "/home/user/.local/state/nvim/sessions/8f2c1d.vim" };
    const command = Command{ .pid = 74877, .time_s = test_time_s, .argv = &argv };
    try expectSequence(
        prefix ++ "pid=74877:time=1795543200:argv=bnZpbQ==,LVM=,L2hvbWUvdXNlci8ubG9jYWwvc3RhdGUvbnZpbS9zZXNzaW9ucy84ZjJjMWQudmlt" ++
            mac_field ++ "9dbb99bfb856749a87563839d7ce9062818d78cf25909db93f309e0cd3b1909b" ++ terminator,
        encodeReport(&buffer, command, test_token),
    );
}

test "clear matches the spec vector" {
    var buffer: [max_sequence_bytes]u8 = undefined;
    try expectSequence(
        prefix ++ "pid=74877:time=1795543200:clear=1" ++
            mac_field ++ "c30603369f98fef581a4098be889175b0c74f0641e49f8b25f4326cb38f97c93" ++ terminator,
        encodeClear(&buffer, 74877, test_time_s, test_token),
    );
}

test "report with cwd matches the spec vector" {
    var buffer: [max_sequence_bytes]u8 = undefined;
    const argv = [_][]const u8{"lazygit"};
    const command = Command{
        .pid = 74877,
        .time_s = test_time_s,
        .argv = &argv,
        .cwd = "/home/user/src/project",
    };
    try expectSequence(
        prefix ++ "pid=74877:time=1795543200:argv=bGF6eWdpdA==:cwd=L2hvbWUvdXNlci9zcmMvcHJvamVjdA==" ++
            mac_field ++ "35cb909805c380336efd3689a125acc774a9dec8422a1d21492ebec06ca758e1" ++ terminator,
        encodeReport(&buffer, command, test_token),
    );
}

test "report with a wrapper command matches the spec vector" {
    var buffer: [max_sequence_bytes]u8 = undefined;
    const argv = [_][]const u8{ "resume-wrap", "ssh", "devbox" };
    const command = Command{ .pid = 90412, .time_s = test_time_s, .argv = &argv };
    try expectSequence(
        prefix ++ "pid=90412:time=1795543200:argv=cmVzdW1lLXdyYXA=,c3No,ZGV2Ym94" ++
            mac_field ++ "e76149d0ba54a83570ffab0583867dacdfa23928ba9d18604f0badea88b62b65" ++ terminator,
        encodeReport(&buffer, command, test_token),
    );
}

test "report accepts an absolute first element and 64 arguments" {
    var buffer: [max_sequence_bytes]u8 = undefined;
    const argv = [_][]const u8{"/usr/bin/vim"};
    const command = Command{ .pid = 1, .time_s = 1, .argv = &argv };
    try std.testing.expect(encodeReport(&buffer, command, test_token) != null);

    var many: [max_argv_elements][]const u8 = undefined;
    for (&many) |*element| element.* = "a";
    const full = Command{ .pid = 1, .time_s = 1, .argv = &many };
    try std.testing.expect(encodeReport(&buffer, full, test_token) != null);
}

test "report accepts an empty later argument" {
    var buffer: [max_sequence_bytes]u8 = undefined;
    const argv = [_][]const u8{ "git", "" };
    const command = Command{ .pid = 1, .time_s = 1, .argv = &argv };
    try std.testing.expect(encodeReport(&buffer, command, test_token) != null);
}

test "report rejects a relative first element" {
    const argv = [_][]const u8{ "./run.sh", "--flag" };
    try expectRejected(.{ .pid = 1, .time_s = 1, .argv = &argv }, test_token);
}

test "report rejects a first element that starts with a dash" {
    const argv = [_][]const u8{"-S"};
    try expectRejected(.{ .pid = 1, .time_s = 1, .argv = &argv }, test_token);
}

test "report rejects an empty first element" {
    const argv = [_][]const u8{""};
    try expectRejected(.{ .pid = 1, .time_s = 1, .argv = &argv }, test_token);
}

test "report rejects empty argv" {
    const argv = [_][]const u8{};
    try expectRejected(.{ .pid = 1, .time_s = 1, .argv = &argv }, test_token);
}

test "report rejects an element with a newline" {
    const argv = [_][]const u8{ "nvim", "a\nb" };
    try expectRejected(.{ .pid = 1, .time_s = 1, .argv = &argv }, test_token);
}

test "report rejects a U+0085 control character" {
    const argv = [_][]const u8{ "nvim", "a\xc2\x85b" };
    try expectRejected(.{ .pid = 1, .time_s = 1, .argv = &argv }, test_token);
}

test "report rejects invalid UTF-8" {
    const argv = [_][]const u8{ "nvim", "\xff" };
    try expectRejected(.{ .pid = 1, .time_s = 1, .argv = &argv }, test_token);
}

test "report rejects a relative cwd" {
    const argv = [_][]const u8{"lazygit"};
    try expectRejected(.{ .pid = 1, .time_s = 1, .argv = &argv, .cwd = "src/project" }, test_token);
}

test "report rejects more than 64 elements" {
    var many: [max_argv_elements + 1][]const u8 = undefined;
    for (&many) |*element| element.* = "a";
    try expectRejected(.{ .pid = 1, .time_s = 1, .argv = &many }, test_token);
}

test "report rejects a pid of 0 and a time that is not positive" {
    const argv = [_][]const u8{"lazygit"};
    try expectRejected(.{ .pid = 0, .time_s = 1, .argv = &argv }, test_token);
    try expectRejected(.{ .pid = 1, .time_s = 0, .argv = &argv }, test_token);
}

test "report of exactly max_sequence_bytes is accepted and a longer one is rejected" {
    // Pid 74877 and time 1795 leave 104 fixed bytes around the argv, so a
    // base64 blob of 1936 bytes (1452 bytes of input) fills the buffer.
    var buffer: [max_sequence_bytes]u8 = undefined;
    const fits: [1452]u8 = @splat('a');
    const fit_argv = [_][]const u8{ "nvim", &fits };
    const fit = encodeReport(&buffer, .{ .pid = 74877, .time_s = 1795, .argv = &fit_argv }, test_token) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(max_sequence_bytes, fit.len);

    const too_big: [1453]u8 = @splat('a');
    const big_argv = [_][]const u8{ "nvim", &too_big };
    try expectRejected(.{ .pid = 74877, .time_s = 1795, .argv = &big_argv }, test_token);
}

test "token length and alphabet are checked" {
    try std.testing.expect(!isValidToken("abcdefghijklmnopqrstu"));
    try std.testing.expect(isValidToken("abcdefghijklmnopqrstuv"));
    try std.testing.expect(isValidToken("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"));
    try std.testing.expect(!isValidToken("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-x"));
    try std.testing.expect(!isValidToken("dummy-token-replace.me-1234567"));
}

test "clear rejects a bad token and a zero pid" {
    var buffer: [max_sequence_bytes]u8 = undefined;
    try std.testing.expect(encodeClear(&buffer, 74877, test_time_s, "short") == null);
    try std.testing.expect(encodeClear(&buffer, 0, test_time_s, test_token) == null);
    try std.testing.expect(encodeClear(&buffer, 74877, 0, test_token) == null);
}

const test_process = Reporter.Process{
    .pid = 74877,
    .time_s = test_time_s,
    .executable = "nvim",
    .cwd = "/home/user/project",
};

test "reporter reports the first session" {
    var reporter: Reporter = .{};
    const sequence = reporter.update(test_token, test_process, "session-one-0123456789") orelse
        return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.startsWith(u8, sequence, prefix ++ "pid=74877:"));
    try std.testing.expect(reporter.reported);
}

test "reporter changed is true until its session is reported" {
    var reporter: Reporter = .{};
    try std.testing.expect(reporter.changed("session-one-0123456789"));
    _ = reporter.update(test_token, test_process, "session-one-0123456789");
    try std.testing.expect(!reporter.changed("session-one-0123456789"));
    try std.testing.expect(reporter.changed("session-two-0123456789"));
}

test "reporter does not report the same session again" {
    var reporter: Reporter = .{};
    _ = reporter.update(test_token, test_process, "session-one-0123456789");
    try std.testing.expect(reporter.update(test_token, test_process, "session-one-0123456789") == null);
}

test "reporter reports a new session again" {
    var reporter: Reporter = .{};
    _ = reporter.update(test_token, test_process, "session-one-0123456789");
    try std.testing.expect(reporter.update(test_token, test_process, "session-two-0123456789") != null);
}

test "reporter ignores a null session and keeps its record" {
    var reporter: Reporter = .{};
    _ = reporter.update(test_token, test_process, "session-one-0123456789");
    try std.testing.expect(reporter.update(test_token, test_process, null) == null);
    try std.testing.expect(reporter.reported);
    try std.testing.expect(reporter.update(test_token, test_process, "session-one-0123456789") == null);
}

test "reporter clear returns the clear sequence once" {
    var reporter: Reporter = .{};
    _ = reporter.update(test_token, test_process, "session-one-0123456789");
    try expectSequence(
        prefix ++ "pid=74877:time=1795543200:clear=1" ++
            mac_field ++ "c30603369f98fef581a4098be889175b0c74f0641e49f8b25f4326cb38f97c93" ++ terminator,
        reporter.clear(test_token, 74877, test_time_s),
    );
    try std.testing.expect(reporter.clear(test_token, 74877, test_time_s) == null);
}

test "reporter clears once when a session cannot be reported" {
    var reporter: Reporter = .{};
    _ = reporter.update(test_token, test_process, "session-one-0123456789");
    const too_long: [max_session_id_bytes + 1]u8 = @splat('s');
    const too_long_session: []const u8 = &too_long;
    try std.testing.expect(reporter.update(test_token, test_process, too_long_session) != null);
    try std.testing.expect(!reporter.reported);
    try std.testing.expect(reporter.update(test_token, test_process, too_long_session) == null);
}

test "reporter reports a session ID of exactly max_session_id_bytes" {
    var reporter: Reporter = .{};
    const longest: [max_session_id_bytes]u8 = @splat('s');
    const longest_session: []const u8 = &longest;
    try std.testing.expect(reporter.update(test_token, test_process, longest_session) != null);
    try std.testing.expect(reporter.reported);
}

test "reporter clears when a command cannot be reported after a report" {
    var reporter: Reporter = .{};
    _ = reporter.update(test_token, test_process, "session-one-0123456789");
    const relative_process = Reporter.Process{
        .pid = 74877,
        .time_s = test_time_s,
        .executable = "nvim",
        .cwd = "relative/project",
    };
    try expectSequence(
        prefix ++ "pid=74877:time=1795543200:clear=1" ++
            mac_field ++ "c30603369f98fef581a4098be889175b0c74f0641e49f8b25f4326cb38f97c93" ++ terminator,
        reporter.update(test_token, relative_process, "session-two-0123456789"),
    );
    try std.testing.expect(!reporter.reported);
}

const second_test_token = "second-dummy-token-value";

fn entry(comptime text: [:0]const u8) ?[*:0]c_char {
    return @ptrCast(@constCast(text.ptr));
}

fn expectEnviron(expected: []const []const u8, envp: [*:null]?[*:0]c_char) !void {
    for (expected, 0..) |want, index| {
        const got = envp[index] orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings(want, entryText(got));
    }
    try std.testing.expect(envp[expected.len] == null);
}

test "takeToken removes every token entry and keeps the first valid value" {
    resetTokenForTest();
    defer resetTokenForTest();
    var entries = [_:null]?[*:0]c_char{
        entry("A=1"),
        entry(token_entry_prefix ++ test_token),
        entry("OSC7577_TOKENX=keep"),
        entry("B=2"),
        entry(token_entry_prefix ++ second_test_token),
    };
    takeToken(&entries);
    try expectEnviron(&.{ "A=1", "OSC7577_TOKENX=keep", "B=2" }, &entries);
    try std.testing.expectEqualStrings(test_token, keptToken() orelse return error.TestUnexpectedResult);
}

test "takeToken removes an invalid token entry and keeps no token" {
    resetTokenForTest();
    defer resetTokenForTest();
    var entries = [_:null]?[*:0]c_char{
        entry("A=1"),
        entry(token_entry_prefix ++ "abcdefghijklmnopqrstu"),
        entry("B=2"),
    };
    takeToken(&entries);
    try expectEnviron(&.{ "A=1", "B=2" }, &entries);
    try std.testing.expect(keptToken() == null);
}

test "takeToken leaves an environment without a token unchanged" {
    resetTokenForTest();
    defer resetTokenForTest();
    var entries = [_:null]?[*:0]c_char{
        entry("A=1"),
        entry("OSC7577_TOKENX=keep"),
    };
    takeToken(&entries);
    try expectEnviron(&.{ "A=1", "OSC7577_TOKENX=keep" }, &entries);
    try std.testing.expect(keptToken() == null);
}

test "putToken puts the kept token into the environment map" {
    resetTokenForTest();
    defer resetTokenForTest();
    var entries = [_:null]?[*:0]c_char{entry(token_entry_prefix ++ test_token)};
    takeToken(&entries);
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    try std.testing.expect(try putToken(&environ));
    try std.testing.expectEqualStrings(test_token, environ.get(token_env_name) orelse return error.TestUnexpectedResult);
}

test "putToken does nothing without a kept token" {
    resetTokenForTest();
    defer resetTokenForTest();
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    try std.testing.expect(!try putToken(&environ));
    try std.testing.expect(environ.get(token_env_name) == null);
}

fn argv0ForTest(comptime text: [:0]const u8) [*:0]const c_char {
    return @ptrCast(text.ptr);
}

test "program name keeps a bare command name" {
    resetProgramNameForTest();
    defer resetProgramNameForTest();
    rememberProgramName(argv0ForTest("fx"));
    try std.testing.expectEqualStrings("fx", programName() orelse return error.TestUnexpectedResult);
}

test "program name keeps nothing for a relative path" {
    resetProgramNameForTest();
    defer resetProgramNameForTest();
    rememberProgramName(argv0ForTest("./zig-out/bin/fx"));
    try std.testing.expect(programName() == null);
}

test "program name keeps nothing for an absolute path" {
    resetProgramNameForTest();
    defer resetProgramNameForTest();
    rememberProgramName(argv0ForTest("/opt/fx"));
    try std.testing.expect(programName() == null);
}

test "program name keeps nothing for a leading dash or an empty name" {
    resetProgramNameForTest();
    defer resetProgramNameForTest();
    rememberProgramName(argv0ForTest("-fx"));
    try std.testing.expect(programName() == null);
    rememberProgramName(argv0ForTest(""));
    try std.testing.expect(programName() == null);
}
