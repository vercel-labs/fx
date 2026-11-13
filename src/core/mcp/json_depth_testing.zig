//! Nested JSON for the tests of the depth limit on a server's JSON
//! (`tests/tla/mcp/WireDepth.tla`): a text with an exact depth, in the shape a test asks for,
//! and a capture of the trace the limit writes. Only tests import this file: the tests of
//! `features/tools.zig`, `elicitation.zig` and `json_depth.zig`, and the fuzz target.

const std = @import("std");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");

/// Which containers a nested text is made of.
pub const Shape = enum(u8) { objects, arrays, mixed };

fn isObject(level: usize, shape: Shape, object_root: bool) bool {
    return shape == .objects or (shape == .mixed and level % 2 == 0) or (object_root and level == 0);
}

/// Writes `depth` containers inside one another, level 0 outermost, with 1 at the bottom. `{}` has depth 1.
pub fn write(writer: *std.Io.Writer, depth: usize, shape: Shape, object_root: bool) std.Io.Writer.Error!void {
    for (0..depth) |level| try writer.writeAll(if (isObject(level, shape, object_root)) "{\"a\":" else "[");
    try writer.writeAll("1");
    var level = depth;
    while (level > 0) {
        level -= 1;
        try writer.writeAll(if (isObject(level, shape, object_root)) "}" else "]");
    }
}

pub fn text(alloc: std.mem.Allocator, depth: usize, shape: Shape, object_root: bool) std.mem.Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    write(&out.writer, depth, shape, object_root) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

/// The places a server's JSON is written again, with the depth of the value the host checks at each.
pub const Site = enum(u8) {
    structured,
    content_meta,
    content_annotations,
    tool_meta,
    tool_annotations,
    tool_icons,

    pub fn isTool(site: Site) bool {
        return switch (site) {
            .tool_meta, .tool_annotations, .tool_icons => true,
            else => false,
        };
    }
};

/// A `tools/call` response whose `result` is `depth` levels deep, nested at `site`. `depth` is at least 4.
pub fn response(alloc: std.mem.Allocator, site: Site, depth: usize, shape: Shape) std.mem.Allocator.Error![]u8 {
    std.debug.assert(!site.isTool() and depth >= 4);
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const w = &out.writer;
    const failed = error.OutOfMemory;
    w.writeAll("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"ok\"") catch return failed;
    switch (site) {
        .structured => {
            w.writeAll("}],\"structuredContent\":") catch return failed;
            write(w, depth - 1, shape, true) catch return failed;
        },
        .content_meta => {
            w.writeAll(",\"_meta\":") catch return failed;
            write(w, depth - 3, shape, true) catch return failed;
            w.writeAll("}]") catch return failed;
        },
        .content_annotations => {
            w.writeAll(",\"annotations\":{\"x\":") catch return failed;
            write(w, depth - 4, shape, false) catch return failed;
            w.writeAll("}}]") catch return failed;
        },
        else => unreachable,
    }
    w.writeAll("}}") catch return failed;
    return out.toOwnedSlice();
}

/// One tool of a `tools/list` result, `depth` levels deep, nested at `site`. `depth` is at least 4.
pub fn tool(alloc: std.mem.Allocator, site: Site, depth: usize, shape: Shape) std.mem.Allocator.Error![]u8 {
    std.debug.assert(site.isTool() and depth >= 4);
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const w = &out.writer;
    const failed = error.OutOfMemory;
    w.writeAll("{\"name\":\"deep\",\"description\":\"d\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"text\":{\"type\":\"string\"}}}") catch return failed;
    switch (site) {
        .tool_meta => {
            w.writeAll(",\"_meta\":") catch return failed;
            write(w, depth - 1, shape, true) catch return failed;
        },
        .tool_annotations => {
            w.writeAll(",\"annotations\":{\"x\":") catch return failed;
            write(w, depth - 2, shape, false) catch return failed;
            w.writeAll("}") catch return failed;
        },
        .tool_icons => {
            w.writeAll(",\"icons\":[{\"src\":\"https://example.test/i.png\",\"x\":") catch return failed;
            write(w, depth - 3, shape, false) catch return failed;
            w.writeAll("}]") catch return failed;
        },
        else => unreachable,
    }
    w.writeAll("}") catch return failed;
    return out.toOwnedSlice();
}

/// An elicitation form's params whose root is `depth` levels deep, through `_meta`. `depth` is at least 4.
pub fn elicitationMeta(alloc: std.mem.Allocator, depth: usize, shape: Shape) std.mem.Allocator.Error![]u8 {
    std.debug.assert(depth >= 4);
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const w = &out.writer;
    w.writeAll("{\"message\":\"Profile\",\"requestedSchema\":{\"type\":\"object\",\"properties\":{\"name\":{\"type\":\"string\"}}},\"_meta\":") catch return error.OutOfMemory;
    write(w, depth - 1, shape, true) catch return error.OutOfMemory;
    w.writeAll("}") catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

/// An elicitation form's params whose root is `depth` levels deep, through the requested schema.
pub fn elicitationSchema(alloc: std.mem.Allocator, depth: usize, shape: Shape) std.mem.Allocator.Error![]u8 {
    std.debug.assert(depth >= 4);
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const w = &out.writer;
    w.writeAll("{\"message\":\"Profile\",\"requestedSchema\":{\"type\":\"object\",\"properties\":{\"name\":{\"type\":\"string\"}},\"x\":") catch return error.OutOfMemory;
    write(w, depth - 2, shape, false) catch return error.OutOfMemory;
    w.writeAll("}}") catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

/// A protocol error response whose `data` is `depth` levels deep.
pub fn errorResponse(alloc: std.mem.Allocator, depth: usize, shape: Shape) std.mem.Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const w = &out.writer;
    w.writeAll("{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32602,\"message\":\"bad\",\"data\":") catch return error.OutOfMemory;
    write(w, depth, shape, false) catch return error.OutOfMemory;
    w.writeAll("}}") catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

/// The trace the code under test writes in the `mcp` scope, in a temporary file.
pub const TraceCapture = struct {
    tmp: std.testing.TmpDir,
    alloc: std.mem.Allocator,
    path: []u8,

    pub fn start(alloc: std.mem.Allocator) !TraceCapture {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
        defer alloc.free(root);
        const path = try std.Io.Dir.path.join(alloc, &.{ root, "trace.log" });
        errdefer alloc.free(path);
        debug_trace.resetForTest();
        try debug_trace.configureForTestWithScopes(alloc, path, "mcp");
        return .{ .tmp = tmp, .alloc = alloc, .path = path };
    }

    pub fn stop(self: *TraceCapture) void {
        debug_trace.resetForTest();
        self.alloc.free(self.path);
        self.tmp.cleanup();
    }

    pub fn read(self: *const TraceCapture) ![]u8 {
        const zio = io_mod.getIo();
        var file = try std.Io.Dir.openFileAbsolute(zio, self.path, .{});
        defer file.close(zio);
        return io_mod.readFileToEnd(self.alloc, &file, 64 * 1024);
    }

    /// The text after `[mcp] ` of each trace line that holds `needle`.
    pub fn lines(self: *const TraceCapture, needle: []const u8) !std.ArrayList([]u8) {
        const trace = try self.read();
        defer self.alloc.free(trace);
        var found: std.ArrayList([]u8) = .empty;
        errdefer {
            for (found.items) |line| self.alloc.free(line);
            found.deinit(self.alloc);
        }
        var parts = std.mem.splitScalar(u8, trace, '\n');
        while (parts.next()) |line| {
            if (std.mem.find(u8, line, needle) == null) continue;
            const at = std.mem.find(u8, line, "[mcp] ") orelse continue;
            try found.append(self.alloc, try self.alloc.dupe(u8, line[at + "[mcp] ".len ..]));
        }
        return found;
    }
};
