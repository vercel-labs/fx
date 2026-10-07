//! Shared event framing protects every provider codec from oversized or unterminated input.
const std = @import("std");
const wire = @import("wire.zig");
const Allocator = wire.Allocator;
const max_event_bytes = 1024 * 1024;
const data_prefix = "data:";
const carriage_return = "\r";
const leading_space = " ";
const multiline_separator = '\n';

/// Caller-owned event copies keep JSON parsing independent of the next network read.
pub const Reader = struct {
    alloc: Allocator,
    reader: *std.Io.Reader,
    cancel: *std.atomic.Value(bool),
    data: std.ArrayList(u8) = .empty,

    /// All API families share cancellation authority from the same native worker.
    pub fn init(alloc: Allocator, reader: *std.Io.Reader, cancel: *std.atomic.Value(bool)) Reader {
        return .{ .alloc = alloc, .reader = reader, .cancel = cancel };
    }

    /// Retained framing storage must not survive a failed or cancelled codec.
    pub fn deinit(self: *Reader) void {
        self.data.deinit(self.alloc);
    }

    /// Only a blank-line boundary publishes data; EOF cannot manufacture a terminal event.
    pub fn next(self: *Reader) !?[]u8 {
        while (true) {
            if (self.cancel.load(.seq_cst)) return error.Cancelled;
            const line = try wire.read_line(self.alloc, self.reader) orelse return null;
            defer self.alloc.free(line);
            if (self.cancel.load(.seq_cst)) return error.Cancelled;
            const trimmed = std.mem.trimEnd(u8, line, carriage_return);
            if (trimmed.len == 0) {
                if (self.data.items.len == 0) continue;
                const event = try self.alloc.dupe(u8, self.data.items);
                self.data.clearRetainingCapacity();
                return event;
            }
            if (!std.mem.startsWith(u8, trimmed, data_prefix)) continue;
            const value = std.mem.trimStart(u8, trimmed[data_prefix.len..], leading_space);
            // The reserved byte covers a possible separator before the next data fragment.
            if (value.len >= max_event_bytes - self.data.items.len) return error.ResponseTooLarge;
            if (self.data.items.len > 0) try self.data.append(self.alloc, multiline_separator);
            try self.data.appendSlice(self.alloc, value);
        }
    }
};
