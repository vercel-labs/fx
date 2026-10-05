//! WebAssembly host attachment store. The JavaScript host keeps inbound
//! payloads until the core copies them into its own memory, and copies
//! outbound payloads out of linear memory when the core publishes them.
const std = @import("std");
const host_attachments = @import("host_attachments.zig");

const Allocator = std.mem.Allocator;

extern "fx" fn fx_attachment_size(id: host_attachments.Id) i32;
extern "fx" fn fx_attachment_take(id: host_attachments.Id, output_ptr: [*]u8, output_cap: usize) i32;
extern "fx" fn fx_attachment_put(input_ptr: [*]const u8, input_len: usize) i32;

pub const store: host_attachments.Store = .{ .take_fn = take, .put_fn = put };

fn take(
    _: ?*anyopaque,
    alloc: Allocator,
    id: host_attachments.Id,
    max_bytes: usize,
) host_attachments.TakeError![]u8 {
    const size = fx_attachment_size(id);
    if (size < 0) return error.AttachmentUnavailable;
    const len: usize = @intCast(size);
    if (len > max_bytes) return error.AttachmentTooLarge;
    const output = try alloc.alloc(u8, len);
    errdefer alloc.free(output);
    const copied = fx_attachment_take(id, output.ptr, output.len);
    if (copied < 0 or @as(usize, @intCast(copied)) != len) return error.AttachmentUnavailable;
    return output;
}

fn put(_: ?*anyopaque, bytes: []const u8) host_attachments.PutError!host_attachments.Id {
    const id = fx_attachment_put(bytes.ptr, bytes.len);
    if (id <= 0) return error.AttachmentStoreFull;
    return @intCast(id);
}
