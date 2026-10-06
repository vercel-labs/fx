//! Serialized handles and joined workers keep asynchronous HTTP behind one stdin lifecycle.
const std = @import("std");
const wire = @import("wire.zig");
const requests = @import("request.zig");
const transport = @import("transport.zig");
const input_buffer_bytes = 16 * 1024;
const success_exit_code = 0;
const catalog = @embedFile("models.json");

const Job = struct {
    alloc: wire.Allocator,
    io: std.Io,
    output: *wire.Output,
    id: u64,
    prepared: requests.Prepared,
    envelope: std.json.Parsed(wire.Value),
    thread: ?std.Thread = null,
    cancel: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    socket_mutex: std.Io.Mutex = .init,
    socket: ?std.Io.net.Stream = null,

    /// The stdin owner can interrupt reads without freeing a worker-owned connection.
    pub fn publish_socket(self: *Job, socket: ?std.Io.net.Stream) void {
        self.socket_mutex.lockUncancelable(self.io);
        defer self.socket_mutex.unlock(self.io);
        self.socket = socket;
    }
    fn stop(self: *Job) void {
        self.cancel.store(true, .seq_cst);
        self.socket_mutex.lockUncancelable(self.io);
        defer self.socket_mutex.unlock(self.io);
        if (self.socket) |socket| socket.shutdown(self.io, .both) catch {};
    }
    fn run(self: *Job) void {
        defer self.done.store(true, .seq_cst);
        transport.run(self) catch {
            self.output.failure(self.id) catch {};
        };
    }
    fn deinit(self: *Job) void {
        if (self.thread) |thread| thread.join();
        self.prepared.deinit();
        const params = wire.field(self.envelope.value, "params") catch unreachable;
        const credential = wire.field(params, "credential") catch .null;
        if (credential == .string) std.crypto.secureZero(u8, @constCast(credential.string));
        self.envelope.deinit();
    }
};

const State = struct {
    alloc: wire.Allocator,
    io: std.Io,
    output: *wire.Output,
    initialized: bool = false,
    prepared: ?requests.Prepared = null,
    active: ?*Job = null,

    /// Completed workers retire before a subsequent handle can reuse their storage.
    fn retire(self: *State) void {
        if (self.active) |job| {
            job.deinit();
            self.alloc.destroy(job);
            self.active = null;
        }
    }

    /// Returned true transfers parser ownership to a worker; every other envelope remains caller-owned.
    fn dispatch(self: *State, id: u64, method: []const u8, envelope: std.json.Parsed(wire.Value)) !bool {
        const params = try wire.field(envelope.value, "params");
        if (std.mem.eql(u8, method, "initialize")) {
            const version = try wire.field(params, "version");
            if (version != .integer or version.integer != wire.version) return error.UnsupportedVersion;
            self.initialized = true;
            try self.output.reply(id, .{ .version = wire.version });
        } else if (!self.initialized) return error.NotInitialized else if (std.mem.eql(u8, method, "provider.models")) {
            var models = try std.json.parseFromSlice(wire.Value, self.alloc, catalog, .{});
            defer models.deinit();
            try self.output.reply(id, models.value);
        } else if (std.mem.eql(u8, method, "provider.prepare")) {
            if (self.active) |job| if (!job.done.load(.seq_cst)) return error.RequestActive;
            self.retire();
            if (self.prepared) |*previous| previous.deinit();
            self.prepared = null;
            self.prepared = try requests.Prepared.create(self.alloc, id, params);
            try self.output.reply(id, .{ .handle = self.prepared.?.handle });
        } else if (std.mem.eql(u8, method, "provider.stream")) {
            if (self.active != null) return error.RequestActive;
            const prepared = self.prepared orelse return error.HandleUnavailable;
            const handle = try wire.text(try wire.field(params, "handle"));
            if (!std.mem.eql(u8, prepared.handle, handle)) return error.HandleMismatch;
            const job = try self.alloc.create(Job);
            errdefer self.alloc.destroy(job);
            job.* = .{ .alloc = self.alloc, .io = self.io, .output = self.output, .id = id, .prepared = prepared, .envelope = envelope };
            job.thread = try std.Thread.spawn(.{}, Job.run, .{job});
            self.active = job;
            self.prepared = null;
            return true;
        } else if (std.mem.eql(u8, method, "provider.cancel")) {
            if (self.active) |job| {
                const handle = try wire.text(try wire.field(params, "handle"));
                if (!std.mem.eql(u8, handle, job.prepared.handle)) return error.HandleMismatch;
                job.stop();
            }
            try self.output.reply(id, .{});
        } else if (std.mem.eql(u8, method, "shutdown")) {
            if (self.active) |job| job.stop();
            try self.output.reply(id, .{});
            // Process exit bounds shutdown even when the peer stalls during connection setup.
            std.process.exit(success_exit_code);
        } else return error.UnknownMethod;
        return false;
    }
};

/// Only stdin carries credentials; this executable never consults ambient API-key variables.
pub fn serve(alloc: wire.Allocator, io: std.Io) !void {
    var output = wire.Output{ .alloc = alloc, .io = io };
    var state = State{ .alloc = alloc, .io = io, .output = &output };
    var buffer: [input_buffer_bytes]u8 = undefined;
    var input = std.Io.File.stdin().reader(io, &buffer);
    while (try wire.read_line(alloc, &input.interface)) |line| {
        defer {
            std.crypto.secureZero(u8, line);
            alloc.free(line);
        }
        var envelope = try std.json.parseFromSlice(wire.Value, alloc, line, .{ .allocate = .alloc_always });
        var transferred = false;
        defer if (!transferred) envelope.deinit();
        const jsonrpc = try wire.text(try wire.field(envelope.value, "jsonrpc"));
        if (!std.mem.eql(u8, jsonrpc, wire.jsonrpc)) return error.InvalidRequest;
        const value = try wire.field(envelope.value, "id");
        if (value != .integer or value.integer < 0) return error.InvalidRequest;
        const id: u64 = @intCast(value.integer);
        const method = try wire.text(try wire.field(envelope.value, "method"));
        transferred = state.dispatch(id, method, envelope) catch {
            try output.failure(id);
            continue;
        };
    }
    // EOF cannot leave a credential-owning network worker orphaned behind its parent.
    if (state.active) |job| job.stop();
    std.process.exit(success_exit_code);
}
