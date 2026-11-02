const std = @import("std");
const observation = @import("observation.zig");

/// Unit-test capture copies only scalar facts, never borrowed event payloads.
pub const Capture = struct {
    mutex: std.Io.Mutex = .init,
    counts: [@typeInfo(observation.Event).@"union".field_names.len]usize = @splat(0),
    purposes: [@typeInfo(observation.ModelPurpose).@"enum".field_names.len]usize = @splat(0),
    outcomes: [@typeInfo(observation.WaitOutcome).@"enum".field_names.len]usize = @splat(0),
    expected_call: ?[]const u8 = null,
    invalid: bool = false,
    saw_mcp_request: bool = false,

    pub fn observer(self: *Capture) observation.Observer {
        return .{ .sink = .{ .context = self, .emit_fn = emit } };
    }

    pub fn count(self: *const Capture, tag: std.meta.Tag(observation.Event)) usize {
        return self.counts[@backingInt(tag)];
    }

    fn emit(raw: *anyopaque, _: usize, event: observation.Event) void {
        const self: *Capture = @ptrCast(@alignCast(raw));
        self.mutex.lockUncancelable(std.testing.io);
        defer self.mutex.unlock(std.testing.io);
        self.counts[@backingInt(std.meta.activeTag(event))] += 1;
        switch (event) {
            .model_start => |value| {
                self.purposes[@backingInt(value.purpose)] += 1;
                if (self.expected_call) |expected| self.invalid = self.invalid or value.parent_call_id == null or !std.mem.eql(u8, expected, value.parent_call_id.?);
            },
            .wait_start => |value| if (self.expected_call) |expected| {
                self.invalid = self.invalid or value.request.call_id == null or !std.mem.eql(u8, expected, value.request.call_id.?);
            },
            .wait_end => |value| self.outcomes[@backingInt(value.outcome)] += 1,
            .mcp_start => |value| if (self.expected_call) |expected| {
                self.invalid = self.invalid or value.identity.call_id == null or !std.mem.eql(u8, expected, value.identity.call_id.?);
            },
            .mcp_request => self.saw_mcp_request = true,
            else => {},
        }
    }
};
