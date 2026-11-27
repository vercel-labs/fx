//! The model id rule for every saved field that holds one: a non-empty,
//! trimmed, control-free UTF-8 id no longer than `max_bytes`. Settings and
//! shortcuts both store model ids, so both read the rule from here.

const std = @import("std");

pub const max_bytes: usize = 1024;

pub fn validate(model: []const u8) !void {
    if (model.len == 0 or model.len > max_bytes or !std.unicode.utf8ValidateSlice(model)) {
        return error.InvalidDurableField;
    }
    if (!std.mem.eql(u8, model, std.mem.trim(u8, model, " \t\r\n"))) return error.InvalidDurableField;
    for (model) |byte| {
        if (std.ascii.isControl(byte)) return error.InvalidDurableField;
    }
}
