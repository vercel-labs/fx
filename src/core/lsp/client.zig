const std = @import("std");
const builtin = @import("builtin");
const framing = @import("framing.zig");
const host_target = @import("../hosts/target.zig");
const io_mod = @import("../shared/io.zig");
const protocol = @import("protocol.zig");

const Allocator = std.mem.Allocator;

pub const StartSpec = struct {
    name: []const u8,
    argv: []const []const u8,
    root: []const u8,
};

pub const DiagnosticMark = struct {
    line: usize,
    severity: protocol.Severity,
};

const Pending = struct {
    body: ?[]u8 = null,
    err: ?anyerror = null,
    event: std.Io.Event = .unset,
};

pub const Client = struct {
    owner: Allocator,
    alloc: Allocator,
    name: []u8,
    root: []u8,
    argv: [][]u8,
    child: std.process.Child,
    child_id: std.process.Child.Id,
    stdin: ?std.Io.File = null,
    stdout: ?std.Io.File = null,
    reader_thread: ?std.Thread = null,
    mutex: std.Io.Mutex = .init,
    write_mutex: std.Io.Mutex = .init,
    next_id: i64 = 1,
    running: bool = true,
    initialized: bool = false,
    pending: std.AutoHashMap(i64, *Pending),
    unmatched: std.AutoHashMap(i64, []u8),
    diagnostics: std.StringArrayHashMapUnmanaged(std.ArrayList(protocol.Diagnostic)) = .empty,
    opened: std.StringArrayHashMapUnmanaged(void) = .empty,
    decoder: framing.Decoder,

    pub fn start(alloc: Allocator, spec: StartSpec) !*Client {
        if (comptime host_target.is_wasm) return error.LspUnavailable;
        if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.LspUnavailable;
        if (spec.argv.len == 0) return error.InvalidLspCommand;

        const intern = std.heap.c_allocator;
        var argv_owned = try dupeArgv(intern, spec.argv);
        errdefer freeArgv(intern, argv_owned);
        const argv_view = try intern.alloc([]const u8, argv_owned.len);
        defer intern.free(argv_view);
        for (argv_owned, 0..) |item, i| argv_view[i] = item;

        var child = try std.process.spawn(io_mod.getIo(), .{
            .argv = argv_view,
            .cwd = .{ .path = spec.root },
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .ignore,
            .pgid = if (builtin.os.tag == .windows) null else 0,
        });
        const child_id = child.id orelse {
            _ = child.wait(io_mod.getIo()) catch {};
            return error.LspSpawnFailed;
        };
        const stdin = child.stdin orelse {
            terminateChild(child_id);
            _ = child.wait(io_mod.getIo()) catch {};
            return error.LspStdinClosed;
        };
        const stdout = child.stdout orelse {
            stdin.close(io_mod.getIo());
            child.stdin = null;
            terminateChild(child_id);
            _ = child.wait(io_mod.getIo()) catch {};
            return error.LspStdoutClosed;
        };
        child.stdin = null;
        child.stdout = null;

        const self = try alloc.create(Client);
        self.* = .{
            .owner = alloc,
            .alloc = intern,
            .name = intern.dupe(u8, spec.name) catch {
                alloc.destroy(self);
                return error.OutOfMemory;
            },
            .root = intern.dupe(u8, spec.root) catch {
                alloc.destroy(self);
                return error.OutOfMemory;
            },
            .argv = argv_owned,
            .child = child,
            .child_id = child_id,
            .stdin = stdin,
            .stdout = stdout,
            .pending = std.AutoHashMap(i64, *Pending).init(intern),
            .unmatched = std.AutoHashMap(i64, []u8).init(intern),
            .decoder = framing.Decoder.init(intern),
        };
        argv_owned = &.{};
        errdefer {
            self.shutdown();
            self.destroy();
        }

        self.reader_thread = try std.Thread.spawn(.{}, readerMain, .{self});
        try self.handshake();
        return self;
    }

    pub fn deinit(self: *Client) void {
        self.shutdown();
        self.destroy();
    }

    pub fn notifyDidOpen(self: *Client, path: []const u8, text: []const u8) void {
        const uri = protocol.fileUriFromPath(self.alloc, path) catch return;
        defer self.alloc.free(uri);
        const language = protocol.languageIdForPath(path);
        self.mutex.lockUncancelable(io_mod.getIo());
        const already = self.opened.get(uri) != null;
        if (!already) {
            const key = self.alloc.dupe(u8, uri) catch {
                self.mutex.unlock(io_mod.getIo());
                return;
            };
            self.opened.put(self.alloc, key, {}) catch {
                self.alloc.free(key);
                self.mutex.unlock(io_mod.getIo());
                return;
            };
        }
        self.mutex.unlock(io_mod.getIo());

        var out: std.Io.Writer.Allocating = .init(self.alloc);
        defer out.deinit();
        if (already) {
            writeDidChange(&out.writer, uri, text) catch return;
        } else {
            writeDidOpen(&out.writer, uri, language, text) catch return;
        }
        self.send(out.written()) catch {};
    }

    pub fn requestDefinition(
        self: *Client,
        alloc: Allocator,
        path: []const u8,
        line: u32,
        character: u32,
    ) !?protocol.Location {
        const uri = try protocol.fileUriFromPath(self.alloc, path);
        defer self.alloc.free(uri);
        var out: std.Io.Writer.Allocating = .init(self.alloc);
        defer out.deinit();
        const id = self.reserveId();
        try writeDefinition(&out.writer, id, uri, line, character);
        const body = try self.roundTrip(id, out.written(), 3_000);
        defer self.alloc.free(body);
        const found = try protocol.parseDefinitionResult(self.alloc, body) orelse return null;
        defer found.deinit(self.alloc);
        return .{
            .uri = try alloc.dupe(u8, found.uri),
            .line = found.line,
            .character = found.character,
        };
    }

    pub fn marksForPath(self: *Client, alloc: Allocator, path: []const u8) ![]DiagnosticMark {
        const resolved = try protocol.fileUriFromPath(alloc, path);
        defer alloc.free(resolved);
        const decoded = try protocol.decodeUriPath(alloc, resolved);
        defer alloc.free(decoded);

        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());

        var count: usize = 0;
        var it = self.diagnostics.iterator();
        while (it.next()) |entry| {
            if (!uriMatchesPath(entry.key_ptr.*, decoded, path)) continue;
            count += entry.value_ptr.items.len;
        }
        const marks = try alloc.alloc(DiagnosticMark, count);
        var index: usize = 0;
        it = self.diagnostics.iterator();
        while (it.next()) |entry| {
            if (!uriMatchesPath(entry.key_ptr.*, decoded, path)) continue;
            for (entry.value_ptr.items) |item| {
                marks[index] = .{
                    .line = item.line,
                    .severity = item.severity,
                };
                index += 1;
            }
        }
        return marks;
    }

    pub fn diagnosticCounts(self: *Client, path: []const u8) struct { errors: usize, warnings: usize } {
        const resolved = protocol.fileUriFromPath(self.alloc, path) catch return .{ .errors = 0, .warnings = 0 };
        defer self.alloc.free(resolved);
        const decoded = protocol.decodeUriPath(self.alloc, resolved) catch return .{ .errors = 0, .warnings = 0 };
        defer self.alloc.free(decoded);

        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        var errors: usize = 0;
        var warnings: usize = 0;
        var it = self.diagnostics.iterator();
        while (it.next()) |entry| {
            if (!uriMatchesPath(entry.key_ptr.*, decoded, path)) continue;
            for (entry.value_ptr.items) |item| {
                switch (item.severity) {
                    .err => errors += 1,
                    .warning => warnings += 1,
                    else => {},
                }
            }
        }
        return .{ .errors = errors, .warnings = warnings };
    }

    fn handshake(self: *Client) !void {
        const root_uri = try protocol.fileUriFromPath(self.alloc, self.root);
        defer self.alloc.free(root_uri);
        var out: std.Io.Writer.Allocating = .init(self.alloc);
        defer out.deinit();
        const id = self.reserveId();
        try writeInitialize(&out.writer, id, root_uri);
        const body = try self.roundTrip(id, out.written(), 5_000);
        defer self.alloc.free(body);
        self.sendNotification("initialized", "{}") catch {};
        self.initialized = true;
    }

    fn reserveId(self: *Client) i64 {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        const id = self.next_id;
        self.next_id += 1;
        return id;
    }

    fn roundTrip(self: *Client, id: i64, body: []const u8, timeout_ms: u32) ![]u8 {
        var pending = Pending{};
        self.mutex.lockUncancelable(io_mod.getIo());
        if (self.unmatched.fetchRemove(id)) |entry| {
            self.mutex.unlock(io_mod.getIo());
            self.send(body) catch {};
            return entry.value;
        }
        self.pending.put(id, &pending) catch {
            self.mutex.unlock(io_mod.getIo());
            return error.OutOfMemory;
        };
        self.mutex.unlock(io_mod.getIo());

        errdefer {
            self.mutex.lockUncancelable(io_mod.getIo());
            _ = self.pending.remove(id);
            self.mutex.unlock(io_mod.getIo());
            if (pending.body) |saved| self.alloc.free(saved);
        }

        try self.send(body);
        const deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
            .clock = .awake,
            .raw = .fromMilliseconds(timeout_ms),
        });
        pending.event.waitTimeout(io_mod.getIo(), .{ .deadline = deadline }) catch |err| switch (err) {
            error.Timeout, error.Canceled => return error.LspTimeout,
        };
        if (pending.err) |fail| return fail;
        return pending.body orelse return error.LspTimeout;
    }

    fn sendNotification(self: *Client, method: []const u8, params_json: []const u8) !void {
        var out: std.Io.Writer.Allocating = .init(self.alloc);
        defer out.deinit();
        try out.writer.writeAll("{\"jsonrpc\":\"2.0\",\"method\":");
        try std.json.Stringify.value(method, .{}, &out.writer);
        try out.writer.writeAll(",\"params\":");
        try out.writer.writeAll(params_json);
        try out.writer.writeByte('}');
        try self.send(out.written());
    }

    fn send(self: *Client, body: []const u8) !void {
        self.write_mutex.lockUncancelable(io_mod.getIo());
        defer self.write_mutex.unlock(io_mod.getIo());
        const stdin = self.stdin orelse return error.LspStdinClosed;
        var frame: std.Io.Writer.Allocating = .init(self.alloc);
        defer frame.deinit();
        try framing.write(&frame.writer, body);
        try stdin.writeStreamingAll(io_mod.getIo(), frame.written());
    }

    fn shutdown(self: *Client) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        const already = !self.running;
        self.running = false;
        self.mutex.unlock(io_mod.getIo());
        if (already) {
            self.joinReader();
            return;
        }
        self.sendNotification("exit", "{}") catch {};
        self.closeStdin();
        terminateChild(self.child_id);
        self.joinReader();
        _ = self.child.wait(io_mod.getIo()) catch {};
    }

    fn joinReader(self: *Client) void {
        if (self.reader_thread) |thread| {
            thread.join();
            self.reader_thread = null;
        }
        if (self.stdout) |stdout| {
            stdout.close(io_mod.getIo());
            self.stdout = null;
        }
    }

    fn closeStdin(self: *Client) void {
        self.write_mutex.lockUncancelable(io_mod.getIo());
        defer self.write_mutex.unlock(io_mod.getIo());
        if (self.stdin) |stdin| {
            stdin.close(io_mod.getIo());
            self.stdin = null;
        }
    }

    fn destroy(self: *Client) void {
        self.closeStdin();
        if (self.stdout) |stdout| {
            stdout.close(io_mod.getIo());
            self.stdout = null;
        }
        self.decoder.deinit();
        var pending_it = self.pending.iterator();
        while (pending_it.next()) |entry| {
            if (entry.value_ptr.*.body) |body| self.alloc.free(body);
            entry.value_ptr.*.event.set(io_mod.getIo());
        }
        self.pending.deinit();
        var unmatched_it = self.unmatched.iterator();
        while (unmatched_it.next()) |entry| self.alloc.free(entry.value_ptr.*);
        self.unmatched.deinit();
        var diag_it = self.diagnostics.iterator();
        while (diag_it.next()) |entry| {
            for (entry.value_ptr.items) |item| item.deinit(self.alloc);
            entry.value_ptr.deinit(self.alloc);
            self.alloc.free(entry.key_ptr.*);
        }
        self.diagnostics.deinit(self.alloc);
        var opened_it = self.opened.iterator();
        while (opened_it.next()) |entry| self.alloc.free(entry.key_ptr.*);
        self.opened.deinit(self.alloc);
        self.alloc.free(self.name);
        self.alloc.free(self.root);
        freeArgv(self.alloc, self.argv);
        self.owner.destroy(self);
    }

    fn readerMain(self: *Client) void {
        const stdout = self.stdout orelse return;
        var read_buf: [4096]u8 = undefined;
        var file_reader = stdout.reader(io_mod.getIo(), &read_buf);
        var chunk: [4096]u8 = undefined;
        while (true) {
            self.mutex.lockUncancelable(io_mod.getIo());
            const running = self.running;
            self.mutex.unlock(io_mod.getIo());
            if (!running) break;
            const n = file_reader.interface.readSliceShort(chunk[0..]) catch break;
            if (n == 0) break;
            self.decoder.feed(chunk[0..n]) catch break;
            while (true) {
                const frame = self.decoder.next() catch break;
                const body = frame orelse break;
                self.dispatch(body);
            }
        }
    }

    fn dispatch(self: *Client, body: []u8) void {
        defer self.alloc.free(body);
        if (protocol.parsePublishDiagnostics(self.alloc, body) catch null) |parsed| {
            self.storeDiagnostics(parsed);
            return;
        }
        const parsed = std.json.parseFromSlice(std.json.Value, self.alloc, body, .{}) catch return;
        defer parsed.deinit();
        const object = switch (parsed.value) {
            .object => |value| value,
            else => return,
        };
        const id = protocol.parseRequestId(object.get("id"));
        const method = switch (object.get("method") orelse .null) {
            .string => |text| text,
            else => null,
        };
        if (method != null and id != null) {
            self.replyServerRequest(id.?, method.?, object.get("params")) catch {};
            return;
        }
        if (id) |number| {
            const copy = self.alloc.dupe(u8, body) catch return;
            self.mutex.lockUncancelable(io_mod.getIo());
            if (self.pending.fetchRemove(number)) |entry| {
                self.mutex.unlock(io_mod.getIo());
                entry.value.body = copy;
                entry.value.event.set(io_mod.getIo());
                return;
            }
            self.unmatched.put(number, copy) catch {
                self.mutex.unlock(io_mod.getIo());
                self.alloc.free(copy);
                return;
            };
            self.mutex.unlock(io_mod.getIo());
        }
    }

    fn storeDiagnostics(self: *Client, parsed: protocol.PublishDiagnostics) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (self.diagnostics.fetchSwapRemove(parsed.uri)) |entry| {
            var old = entry.value;
            for (old.items) |item| item.deinit(self.alloc);
            old.deinit(self.alloc);
            self.alloc.free(@constCast(entry.key));
        }
        var list: std.ArrayList(protocol.Diagnostic) = .empty;
        list.appendSlice(self.alloc, parsed.diagnostics) catch {
            parsed.deinit(self.alloc);
            return;
        };
        self.alloc.free(parsed.diagnostics);
        const key = parsed.uri;
        self.diagnostics.put(self.alloc, key, list) catch {
            for (list.items) |item| item.deinit(self.alloc);
            list.deinit(self.alloc);
            self.alloc.free(key);
        };
    }

    fn replyServerRequest(
        self: *Client,
        id: i64,
        method: []const u8,
        params: ?std.json.Value,
    ) !void {
        _ = params;
        var out: std.Io.Writer.Allocating = .init(self.alloc);
        defer out.deinit();
        try out.writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
        try out.writer.print("{d}", .{id});
        if (std.mem.eql(u8, method, "workspace/workspaceFolders")) {
            const root_uri = try protocol.fileUriFromPath(self.alloc, self.root);
            defer self.alloc.free(root_uri);
            try out.writer.writeAll(",\"result\":[{\"uri\":");
            try std.json.Stringify.value(root_uri, .{}, &out.writer);
            try out.writer.writeAll(",\"name\":");
            try std.json.Stringify.value(self.name, .{}, &out.writer);
            try out.writer.writeAll("}]}");
        } else {
            try out.writer.writeAll(",\"result\":null}");
        }
        try self.send(out.written());
    }
};

fn uriMatchesPath(uri: []const u8, decoded_uri: []const u8, path: []const u8) bool {
    if (std.mem.eql(u8, uri, path)) return true;
    if (std.mem.eql(u8, decoded_uri, path)) return true;
    if (std.mem.endsWith(u8, decoded_uri, path)) return true;
    if (std.mem.endsWith(u8, path, decoded_uri)) return true;
    return false;
}

fn writeInitialize(writer: *std.Io.Writer, id: i64, root_uri: []const u8) !void {
    try writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try writer.print("{d}", .{id});
    try writer.writeAll(",\"method\":\"initialize\",\"params\":{\"processId\":null,\"rootUri\":");
    try std.json.Stringify.value(root_uri, .{}, writer);
    try writer.writeAll(
        ",\"capabilities\":{\"workspace\":{\"workspaceFolders\":true},\"textDocument\":{\"publishDiagnostics\":{},\"definition\":{}}}}}",
    );
}

fn writeDidOpen(writer: *std.Io.Writer, uri: []const u8, language: []const u8, text: []const u8) !void {
    try writer.writeAll("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":");
    try std.json.Stringify.value(uri, .{}, writer);
    try writer.writeAll(",\"languageId\":");
    try std.json.Stringify.value(language, .{}, writer);
    try writer.writeAll(",\"version\":1,\"text\":");
    try std.json.Stringify.value(text, .{}, writer);
    try writer.writeAll("}}}");
}

fn writeDidChange(writer: *std.Io.Writer, uri: []const u8, text: []const u8) !void {
    try writer.writeAll(
        "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didChange\",\"params\":{\"textDocument\":{\"uri\":",
    );
    try std.json.Stringify.value(uri, .{}, writer);
    try writer.writeAll(",\"version\":2},\"contentChanges\":[{\"text\":");
    try std.json.Stringify.value(text, .{}, writer);
    try writer.writeAll("}]}");
}

fn writeDefinition(writer: *std.Io.Writer, id: i64, uri: []const u8, line: u32, character: u32) !void {
    try writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try writer.print("{d}", .{id});
    try writer.writeAll(",\"method\":\"textDocument/definition\",\"params\":{\"textDocument\":{\"uri\":");
    try std.json.Stringify.value(uri, .{}, writer);
    try writer.writeAll("},\"position\":{\"line\":");
    try writer.print("{d}", .{line});
    try writer.writeAll(",\"character\":");
    try writer.print("{d}", .{character});
    try writer.writeAll("}}}");
}

fn dupeArgv(alloc: Allocator, argv: []const []const u8) ![][]u8 {
    const copy = try alloc.alloc([]u8, argv.len);
    var count: usize = 0;
    errdefer {
        for (copy[0..count]) |item| alloc.free(item);
        alloc.free(copy);
    }
    for (argv, 0..) |item, i| {
        copy[i] = try alloc.dupe(u8, item);
        count += 1;
    }
    return copy;
}

fn freeArgv(alloc: Allocator, argv: [][]u8) void {
    for (argv) |item| alloc.free(item);
    if (argv.len > 0) alloc.free(argv);
}

fn terminateChild(child_id: std.process.Child.Id) void {
    if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi) return;
    std.posix.kill(child_id, .KILL) catch {};
    std.posix.kill(-child_id, .TERM) catch {};
}

test "client initialize and definition requests use Content-Length frames" {
    const alloc = std.testing.allocator;
    var init_body: std.Io.Writer.Allocating = .init(alloc);
    defer init_body.deinit();
    try writeInitialize(&init_body.writer, 1, "file:///tmp/workspace");
    const init_frame = try framing.encode(alloc, init_body.written());
    defer alloc.free(init_frame);
    try std.testing.expect(std.mem.startsWith(u8, init_frame, "Content-Length: "));
    try std.testing.expect(std.mem.find(u8, init_frame, "\r\n\r\n") != null);
    try std.testing.expect(std.mem.find(u8, init_frame, "\"method\":\"initialize\"") != null);

    var decoder = framing.Decoder.init(alloc);
    defer decoder.deinit();
    try decoder.feed(init_frame);
    const decoded = (try decoder.next()) orelse return error.TestExpectedEqual;
    defer alloc.free(decoded);
    try std.testing.expectEqualStrings(init_body.written(), decoded);

    const result_body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"capabilities\":{}}}";
    const result_frame = try framing.encode(alloc, result_body);
    defer alloc.free(result_frame);
    try decoder.feed(result_frame);
    const result = (try decoder.next()) orelse return error.TestExpectedEqual;
    defer alloc.free(result);
    try std.testing.expect((try protocol.parseDefinitionResult(alloc, result)) == null);

    var def_body: std.Io.Writer.Allocating = .init(alloc);
    defer def_body.deinit();
    try writeDefinition(&def_body.writer, 2, "file:///tmp/a.zig", 3, 0);
    try std.testing.expect(std.mem.find(u8, def_body.written(), "textDocument/definition") != null);
}
