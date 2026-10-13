const std = @import("std");
const testing_allocator = @import("../shared/testing_allocator.zig");
const image_data = @import("../images/image_data.zig");
const io_mod = @import("../shared/io.zig");
const text_utils = @import("../shared/text_utils.zig");
const types = @import("../shared/types.zig");
const artifact_digest = @import("artifact_digest.zig");
const session_child_store = @import("session_child_store.zig");
const session_codec = @import("session_codec.zig");
const compactor = @import("../compactor/compactor.zig");

const Allocator = std.mem.Allocator;

pub const large_result_threshold_bytes: usize = 16 * 1024;
pub const preview_bytes: usize = 4 * 1024;
pub const read_default_bytes: usize = 8 * 1024;
pub const read_max_bytes: usize = 64 * 1024;
pub const full_read_chunk_bytes: usize = 64 * 1024;
pub const stored_text_max_bytes: usize = 8 * 1024 * 1024;

pub const PreparedResult = struct {
    model_output: []const u8,
    memory: types.ToolResultMemory,
};

const StorageTarget = union(enum) {
    legacy_dir: []const u8,
    managed: *session_child_store.SessionChildCapability,
};

/// Read-only, validated access to persisted tool-result text. The
/// caller chooses bounded raw pages and owns each returned allocation.
pub const ResultReader = struct {
    source: Source,
    size: usize,

    const Source = union(enum) {
        file: session_child_store.ManagedFile,
        /// A v2 session's body, read whole from its blob (D44); owned.
        bytes: struct { alloc: Allocator, data: []u8 },
    };

    pub fn deinit(self: *ResultReader) void {
        switch (self.source) {
            .file => |*file| file.deinit(),
            .bytes => |body| body.alloc.free(body.data),
        }
        self.* = undefined;
    }

    pub fn readPage(
        self: *ResultReader,
        alloc: Allocator,
        offset: usize,
        max_bytes: usize,
    ) ![]u8 {
        if (offset >= self.size or max_bytes == 0) return alloc.dupe(u8, "");
        const len = @min(max_bytes, self.size - offset);
        return switch (self.source) {
            .file => |*file| file.readRange(alloc, offset, len),
            .bytes => |body| alloc.dupe(u8, body.data[offset..][0..len]),
        };
    }
};

pub fn prepare(
    alloc: Allocator,
    result_dir: ?[]const u8,
    tool_call_id: []const u8,
    tool_name: []const u8,
    output_bytes: usize,
    durable_output: []const u8,
    inline_cap: usize,
) !PreparedResult {
    if (result_dir) |dir| {
        if (output_bytes > large_result_threshold_bytes or
            durable_output.len > inline_cap)
        {
            return prepareStoredResult(
                alloc,
                .{ .legacy_dir = dir },
                tool_call_id,
                tool_name,
                output_bytes,
                durable_output,
            );
        }
        return prepareExternallyBackedInlineResult(
            alloc,
            .{ .legacy_dir = dir },
            tool_call_id,
            tool_name,
            output_bytes,
            durable_output,
        );
    }
    const capped = try cappedInlineOutput(alloc, tool_name, durable_output, inline_cap);
    return .{
        .model_output = capped,
        .memory = .{
            .output_bytes = output_bytes,
            .stored_output_bytes = durable_output.len,
            .truncated = capped.len < durable_output.len,
        },
    };
}

pub fn prepareManaged(
    alloc: Allocator,
    capability: ?*session_child_store.SessionChildCapability,
    tool_call_id: []const u8,
    tool_name: []const u8,
    output_bytes: usize,
    durable_output: []const u8,
    inline_cap: usize,
) !PreparedResult {
    if (capability) |managed| {
        if (output_bytes > large_result_threshold_bytes or
            durable_output.len > inline_cap)
        {
            return prepareStoredResult(
                alloc,
                .{ .managed = managed },
                tool_call_id,
                tool_name,
                output_bytes,
                durable_output,
            );
        }
        return prepareExternallyBackedInlineResult(
            alloc,
            .{ .managed = managed },
            tool_call_id,
            tool_name,
            output_bytes,
            durable_output,
        );
    }
    const capped = try cappedInlineOutput(alloc, tool_name, durable_output, inline_cap);
    return .{
        .model_output = capped,
        .memory = .{
            .output_bytes = output_bytes,
            .stored_output_bytes = durable_output.len,
            .truncated = capped.len < durable_output.len,
        },
    };
}

fn prepareExternallyBackedInlineResult(
    alloc: Allocator,
    target: StorageTarget,
    tool_call_id: []const u8,
    tool_name: []const u8,
    output_bytes: usize,
    durable_output: []const u8,
) !PreparedResult {
    const handle = try targetHandle(alloc, target, tool_call_id, tool_name, durable_output);
    errdefer alloc.free(handle);
    const model_output = try alloc.dupe(u8, durable_output);
    errdefer alloc.free(model_output);
    const preview = try previewText(alloc, durable_output, preview_bytes);
    errdefer alloc.free(preview);
    switch (target) {
        .legacy_dir => |dir| try storeLargeResultAtHandle(
            alloc,
            dir,
            handle,
            durable_output,
        ),
        .managed => |capability| try storeLargeResultAtHandleManaged(
            alloc,
            capability,
            handle,
            durable_output,
        ),
    }
    return .{
        .model_output = model_output,
        .memory = .{
            .output_handle = handle,
            .preview = preview,
            .output_bytes = output_bytes,
            .stored_output_bytes = durable_output.len,
            .truncated = false,
        },
    };
}

fn prepareStoredResult(
    alloc: Allocator,
    target: StorageTarget,
    tool_call_id: []const u8,
    tool_name: []const u8,
    output_bytes: usize,
    durable_output: []const u8,
) !PreparedResult {
    const handle = try targetHandle(alloc, target, tool_call_id, tool_name, durable_output);
    errdefer alloc.free(handle);
    const preview = try previewText(alloc, durable_output, preview_bytes);
    errdefer alloc.free(preview);
    const model_output = try formatStoredResultOutput(
        alloc,
        handle,
        preview,
        durable_output.len,
    );
    errdefer alloc.free(model_output);
    switch (target) {
        .legacy_dir => |dir| try storeLargeResultAtHandle(
            alloc,
            dir,
            handle,
            durable_output,
        ),
        .managed => |capability| try storeLargeResultAtHandleManaged(
            alloc,
            capability,
            handle,
            durable_output,
        ),
    }
    return .{
        .model_output = model_output,
        .memory = .{
            .output_handle = handle,
            .preview = preview,
            .output_bytes = output_bytes,
            .stored_output_bytes = durable_output.len,
            .truncated = true,
        },
    };
}

pub fn storeLargeResult(
    alloc: Allocator,
    result_dir: []const u8,
    tool_call_id: []const u8,
    tool_name: []const u8,
    text: []const u8,
) ![]u8 {
    const handle = try makeHandle(alloc, tool_call_id, tool_name, text);
    errdefer alloc.free(handle);
    try storeLargeResultAtHandle(alloc, result_dir, handle, text);
    return handle;
}

fn storeLargeResultAtHandle(
    alloc: Allocator,
    result_dir: []const u8,
    handle: []const u8,
    text: []const u8,
) !void {
    var capability = try session_child_store.SessionChildCapability.initLegacyRoute(
        alloc,
        result_dir,
        .tool_results,
        .writable,
    );
    defer capability.deinit();
    return storeLargeResultAtHandleManaged(
        alloc,
        &capability,
        handle,
        text,
    );
}

pub fn storeToolImages(alloc: Allocator, capability: *session_child_store.SessionChildCapability, call_id: []const u8, tool_name: []const u8, images: []const types.ToolImage) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try session_codec.writePersistedToolImages(&out.writer, images);
    if (out.written().len > image_data.max_result_frame_bytes) return error.ResultTooLarge;
    const base = try handleFor(alloc, capability, call_id, tool_name, out.written());
    defer alloc.free(base);
    const handle = try alloc.print("image-{s}", .{base});
    errdefer alloc.free(handle);
    try storeLargeResultAtHandleManaged(alloc, capability, handle, out.written());
    return handle;
}

pub fn isImageHandle(handle: []const u8) bool {
    return std.mem.startsWith(u8, handle, "image-result-");
}

pub fn loadToolImages(alloc: Allocator, capability: *session_child_store.SessionChildCapability, handle: []const u8) ![]types.ToolImage {
    if (!isImageHandle(handle)) return error.InvalidResultHandle;
    var reader = try openReaderManaged(alloc, capability, handle);
    defer reader.deinit();
    if (reader.size > image_data.max_result_frame_bytes) return error.ResultTooLarge;
    const bytes = try reader.readPage(alloc, 0, image_data.max_result_frame_bytes);
    defer alloc.free(bytes);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    if (!handleMatchesContentDigest(handle, digest)) return error.ImageArtifactChanged;
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .array) return error.InvalidImageArtifact;
    const images = try session_codec.parsePersistedToolImages(alloc, parsed.value.array.items);
    errdefer types.freeToolImages(alloc, images);
    if (images.len != parsed.value.array.items.len) return error.InvalidImageArtifact;
    return images;
}

pub fn storeLargeResultManaged(
    alloc: Allocator,
    capability: *session_child_store.SessionChildCapability,
    tool_call_id: []const u8,
    tool_name: []const u8,
    text: []const u8,
) ![]u8 {
    const handle = try handleFor(alloc, capability, tool_call_id, tool_name, text);
    errdefer alloc.free(handle);
    try storeLargeResultAtHandleManaged(alloc, capability, handle, text);
    return handle;
}

/// Bound on one serialized diff content pack (previous + after snapshots of
/// a committed file edit). Oversized packs stay inline and the enclosing
/// record's own size guard covers them.
pub const diff_content_max_bytes: usize = 2 * stored_text_max_bytes;

/// Restored previous/after contents of a committed file presentation.
/// The caller owns both slices; release with deinit.
pub const DiffContentPack = struct {
    previous_content: ?[]u8 = null,
    after_content: ?[]u8 = null,

    pub fn deinit(self: *DiffContentPack, alloc: Allocator) void {
        if (self.previous_content) |content| alloc.free(content);
        if (self.after_content) |content| alloc.free(content);
        self.* = undefined;
    }
};

const diff_content_handle_prefix = "diff-";
const diff_content_handle_suffix = ".json";
const diff_content_digest_hex_bytes = 16;
const diff_content_handle_bytes = diff_content_handle_prefix.len +
    diff_content_digest_hex_bytes + 1 + diff_content_digest_hex_bytes +
    diff_content_handle_suffix.len;

fn isLowerHex(bytes: []const u8) bool {
    for (bytes) |byte| {
        if (!std.ascii.isDigit(byte) and (byte < 'a' or byte > 'f')) return false;
    }
    return true;
}

pub fn isDiffContentHandle(handle: []const u8) bool {
    if (handle.len != diff_content_handle_bytes or
        !std.mem.startsWith(u8, handle, diff_content_handle_prefix) or
        !std.mem.endsWith(u8, handle, diff_content_handle_suffix))
    {
        return false;
    }
    const call_start = diff_content_handle_prefix.len;
    const call_end = call_start + diff_content_digest_hex_bytes;
    const content_start = call_end + 1;
    const content_end = content_start + diff_content_digest_hex_bytes;
    return handle[call_end] == '-' and
        isLowerHex(handle[call_start..call_end]) and
        isLowerHex(handle[content_start..content_end]);
}

pub fn diffContentHandleMatchesCall(
    handle: []const u8,
    tool_call_id: []const u8,
) bool {
    if (!isDiffContentHandle(handle)) return false;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(tool_call_id, &digest, .{});
    const expected = std.fmt.bytesToHex(digest[0..8].*, .lower);
    const start = diff_content_handle_prefix.len;
    return std.mem.eql(
        u8,
        handle[start .. start + diff_content_digest_hex_bytes],
        &expected,
    );
}

pub fn diffContentHandleMatchesContentDigest(
    handle: []const u8,
    digest: [32]u8,
) bool {
    return isDiffContentHandle(handle) and
        artifact_digest.handleMatchesContentDigest(
            handle,
            diff_content_handle_suffix,
            digest,
        );
}

/// Persists one edit's previous/after snapshots as a single content-addressed
/// artifact in the session result store and returns its handle. Keeping the
/// snapshots out of the event log and recovery checkpoint keeps those records
/// small; readers resolve the handle on demand.
pub fn storeDiffContent(
    alloc: Allocator,
    result_dir: []const u8,
    tool_call_id: []const u8,
    previous_content: ?[]const u8,
    after_content: ?[]const u8,
) ![]u8 {
    const pack = try encodeDiffContentPack(alloc, previous_content, after_content);
    defer alloc.free(pack);
    const handle = try makeDiffContentHandle(alloc, tool_call_id, pack);
    errdefer alloc.free(handle);
    try storeLargeResultAtHandle(alloc, result_dir, handle, pack);
    return handle;
}

/// Loads and digest-verifies a pack written by storeDiffContent.
pub fn loadDiffContentManaged(
    alloc: Allocator,
    capability: *session_child_store.SessionChildCapability,
    tool_call_id: []const u8,
    handle: []const u8,
) !DiffContentPack {
    if (!diffContentHandleMatchesCall(handle, tool_call_id)) {
        return error.InvalidResultHandle;
    }
    var reader = try openReaderManaged(alloc, capability, handle);
    defer reader.deinit();
    if (reader.size > diff_content_max_bytes) return error.ResultTooLarge;
    const bytes = try reader.readPage(alloc, 0, diff_content_max_bytes);
    defer alloc.free(bytes);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    if (!diffContentHandleMatchesContentDigest(handle, digest)) {
        return error.DiffContentArtifactChanged;
    }
    const Wire = struct {
        previous_content: ?[]const u8 = null,
        after_content: ?[]const u8 = null,
    };
    var parsed = std.json.parseFromSlice(Wire, alloc, bytes, .{
        .allocate = .alloc_always,
        .max_value_len = diff_content_max_bytes,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidDiffContentArtifact,
    };
    defer parsed.deinit();
    var pack: DiffContentPack = .{};
    errdefer pack.deinit(alloc);
    if (parsed.value.previous_content) |content| {
        pack.previous_content = try alloc.dupe(u8, content);
    }
    if (parsed.value.after_content) |content| {
        pack.after_content = try alloc.dupe(u8, content);
    }
    return pack;
}

fn encodeDiffContentPack(
    alloc: Allocator,
    previous_content: ?[]const u8,
    after_content: ?[]const u8,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    out.writer.writeAll("{\"previous_content\":") catch return error.OutOfMemory;
    writeOptionalPackString(&out.writer, previous_content) catch return error.OutOfMemory;
    out.writer.writeAll(",\"after_content\":") catch return error.OutOfMemory;
    writeOptionalPackString(&out.writer, after_content) catch return error.OutOfMemory;
    out.writer.writeByte('}') catch return error.OutOfMemory;
    if (out.written().len > diff_content_max_bytes) return error.DiffContentTooLarge;
    return try out.toOwnedSlice();
}

fn writeOptionalPackString(writer: *std.Io.Writer, value: ?[]const u8) !void {
    if (value) |text| {
        try std.json.Stringify.value(text, .{}, writer);
    } else {
        try writer.writeAll("null");
    }
}

fn makeDiffContentHandle(alloc: Allocator, tool_call_id: []const u8, pack: []const u8) ![]u8 {
    var content_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(pack, &content_digest, .{});
    const content_hex = std.fmt.bytesToHex(content_digest[0..8].*, .lower);
    var call_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(tool_call_id, &call_digest, .{});
    const call_hex = std.fmt.bytesToHex(call_digest[0..8].*, .lower);
    return alloc.print(
        "diff-{s}-{s}.json",
        .{ &call_hex, &content_hex },
    );
}

fn storeLargeResultAtHandleManaged(
    alloc: Allocator,
    capability: *session_child_store.SessionChildCapability,
    handle: []const u8,
    text: []const u8,
) !void {
    if (capability.holdsBlobs()) {
        const hash = try capability.putBlob(text);
        // `handleFor` names the handle after this very blob.
        std.debug.assert(std.mem.eql(u8, artifact_digest.blobHash(handle).?, &hash));
        return;
    }
    var entry = try capability.atomicReplace(
        alloc,
        .tool_results,
        handle,
        text,
    );
    entry.deinit(alloc);
}

pub fn formatStoredResultOutput(alloc: Allocator, handle: []const u8, preview: []const u8, stored_bytes: usize) ![]u8 {
    return alloc.print(
        "<tool_result_preview handle=\"{s}\" stored_bytes=\"{d}\">\n{s}\n</tool_result_preview>\n" ++
            "<tool_result_handle>{s}</tool_result_handle>\n" ++
            "Full result is stored outside session JSON. Use read_tool_result with this handle to inspect a byte range or literal query.",
        .{ handle, stored_bytes, preview, handle },
    );
}

pub fn readByRange(alloc: Allocator, result_dir: []const u8, handle: []const u8, start_byte: usize, byte_count: usize) ![]u8 {
    var capability = try session_child_store.SessionChildCapability.initLegacyRoute(
        alloc,
        result_dir,
        .tool_results,
        .read_only,
    );
    defer capability.deinit();
    return readByRangeManaged(
        alloc,
        &capability,
        handle,
        start_byte,
        byte_count,
    );
}

pub fn readByRangeManaged(
    alloc: Allocator,
    capability: *session_child_store.SessionChildCapability,
    handle: []const u8,
    start_byte: usize,
    byte_count: usize,
) ![]u8 {
    try validateHandle(handle);
    const text = try readStoredTextManaged(alloc, capability, handle);
    defer alloc.free(text);
    const start = if (start_byte == 0) 0 else @min(start_byte - 1, text.len);
    const requested = @min(if (byte_count == 0) read_default_bytes else byte_count, read_max_bytes);
    const end = @min(text.len, start + requested);
    const safe_start = text_utils.utf8ForwardBoundary(text, start);
    const safe_end = text_utils.utf8BackwardBoundary(text, end);
    return alloc.print(
        "<tool_result handle=\"{s}\" start_byte=\"{d}\" end_byte=\"{d}\" total_bytes=\"{d}\">\n{s}\n</tool_result>",
        .{ handle, safe_start + 1, safe_end, text.len, text[safe_start..safe_end] },
    );
}

pub fn readForReplayManaged(
    alloc: Allocator,
    capability: *session_child_store.SessionChildCapability,
    handle: []const u8,
    expected_bytes: usize,
) ![]u8 {
    if (expected_bytes > stored_text_max_bytes) return error.ResultSizeUnsupported;
    // A blob is read once; a file's size is checked before it is read.
    if (!capability.holdsBlobs()) {
        const stat = try statManaged(capability, handle);
        if (stat.size != expected_bytes) return error.ResultSizeMismatch;
    }
    const text = try readStoredTextManaged(alloc, capability, handle);
    if (text.len != expected_bytes) {
        alloc.free(text);
        return error.ResultSizeMismatch;
    }
    return text;
}

pub fn searchByQuery(alloc: Allocator, result_dir: []const u8, handle: []const u8, query: []const u8) ![]u8 {
    var capability = try session_child_store.SessionChildCapability.initLegacyRoute(
        alloc,
        result_dir,
        .tool_results,
        .read_only,
    );
    defer capability.deinit();
    return searchByQueryManaged(alloc, &capability, handle, query);
}

pub fn searchByQueryManaged(
    alloc: Allocator,
    capability: *session_child_store.SessionChildCapability,
    handle: []const u8,
    query: []const u8,
) ![]u8 {
    try validateHandle(handle);
    const trimmed_query = std.mem.trim(u8, query, " \t\r\n");
    if (trimmed_query.len == 0) return error.InvalidQuery;
    const text = try readStoredTextManaged(alloc, capability, handle);
    defer alloc.free(text);

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.print("<tool_result_query handle=\"{s}\">\nquery: ", .{handle});
    try std.json.Stringify.value(trimmed_query, .{}, &out.writer);
    try out.writer.writeAll("\n");

    var matches: usize = 0;
    var line_number: usize = 1;
    var line_iter = std.mem.splitScalar(u8, text, '\n');
    while (line_iter.next()) |line| : (line_number += 1) {
        if (std.mem.find(u8, line, trimmed_query) == null) continue;
        try out.writer.print("{d}|{s}\n", .{ line_number, line });
        matches += 1;
        if (matches >= 50 or out.written().len >= read_max_bytes) break;
    }

    if (matches == 0) try out.writer.writeAll("(no matches)\n");
    try out.writer.writeAll("</tool_result_query>");
    return try out.toOwnedSlice();
}

/// A stored file's size; a v2 session's blob is only read whole.
fn statManaged(
    capability: *session_child_store.SessionChildCapability,
    handle: []const u8,
) !session_child_store.ManagedStat {
    std.debug.assert(!capability.holdsBlobs());
    try validateHandle(handle);
    return capability.stat(.tool_results, handle) catch |err| switch (err) {
        error.FileNotFound => error.ResultHandleNotFound,
        else => err,
    };
}

/// Opens a persisted tool result for bounded read-only pages. This never
/// materializes the full sidecar in memory.
pub fn openReaderManaged(
    alloc: Allocator,
    capability: *session_child_store.SessionChildCapability,
    handle: []const u8,
) !ResultReader {
    try validateHandle(handle);
    if (capability.holdsBlobs()) {
        const data = try readStoredTextManaged(alloc, capability, handle);
        return .{ .source = .{ .bytes = .{ .alloc = alloc, .data = data } }, .size = data.len };
    }
    var file = capability.openFileReadOnly(alloc, .tool_results, handle) catch |err| switch (err) {
        error.FileNotFound => return error.ResultHandleNotFound,
        else => return err,
    };
    errdefer file.deinit();
    const stat = try file.stat();
    const size = std.math.cast(usize, stat.size) orelse {
        return error.ResultTooLarge;
    };
    return .{ .source = .{ .file = file }, .size = size };
}

/// Removes a stored result. A v2 session's blob stays with the session,
/// which a fork or recover may share (D44).
pub fn deleteManaged(
    capability: *session_child_store.SessionChildCapability,
    handle: []const u8,
) !void {
    try validateHandle(handle);
    if (capability.holdsBlobs()) {
        @import("../shared/debug_trace.zig").logf("session", "event=sessions_v2_result_kept handle_bytes={d} reason=blob", .{handle.len});
        return;
    }
    capability.delete(.tool_results, handle) catch |err| switch (err) {
        error.FileNotFound => return error.ResultHandleNotFound,
        else => return err,
    };
}

fn cappedInlineOutput(alloc: Allocator, tool_name: []const u8, text: []const u8, max_bytes: usize) ![]u8 {
    const marker = try alloc.print(
        "\n... [tool result truncated for {s}: original {d} bytes; cap is {d} bytes]\n",
        .{ tool_name, text.len, max_bytes },
    );
    defer alloc.free(marker);
    if (text.len <= max_bytes) return try alloc.dupe(u8, text);
    const prefix_cap = if (max_bytes > marker.len) max_bytes - marker.len else 0;
    const prefix_len = text_utils.utf8BackwardBoundary(text, prefix_cap);
    if (prefix_len == 0) return try alloc.dupe(u8, marker);
    return try std.mem.concat(alloc, u8, &.{ text[0..prefix_len], marker });
}

pub fn previewText(alloc: Allocator, text: []const u8, max_bytes: usize) ![]u8 {
    return try alloc.dupe(u8, text_utils.utf8PrefixByBytes(text, max_bytes));
}

/// The handle `storeLargeResultManaged` gives `text`: the name holds the call
/// and a hash of the content, so the same bytes always get the same name.
pub fn makeHandle(alloc: Allocator, tool_call_id: []const u8, tool_name: []const u8, text: []const u8) ![]u8 {
    var content_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(text, &content_digest, .{});
    const content_hex = std.fmt.bytesToHex(content_digest[0..8].*, .lower);
    var call_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(tool_call_id, &call_digest, .{});
    const call_hex = std.fmt.bytesToHex(call_digest[0..8].*, .lower);
    const safe_tool = try safeHandlePart(alloc, tool_name);
    defer alloc.free(safe_tool);
    return alloc.print(
        "result-{s}-{s}-{s}.txt",
        .{ safe_tool, &call_hex, &content_hex },
    );
}

/// The handle a v2 session gives `text`: `result-`, the name of its blob,
/// and `.txt` (D44).
pub fn blobHandle(alloc: Allocator, text: []const u8) ![]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(text, &digest, .{});
    return artifact_digest.blobHandle(alloc, "result-", digest, ".txt");
}

/// The handle a store through `capability` gives `text`: its blob's for a
/// v2 session (`blobHandle`), otherwise `makeHandle`'s.
pub fn handleFor(
    alloc: Allocator,
    capability: *const session_child_store.SessionChildCapability,
    tool_call_id: []const u8,
    tool_name: []const u8,
    text: []const u8,
) ![]u8 {
    if (capability.holdsBlobs()) return blobHandle(alloc, text);
    return makeHandle(alloc, tool_call_id, tool_name, text);
}

fn targetHandle(
    alloc: Allocator,
    target: StorageTarget,
    tool_call_id: []const u8,
    tool_name: []const u8,
    text: []const u8,
) ![]u8 {
    return switch (target) {
        .legacy_dir => makeHandle(alloc, tool_call_id, tool_name, text),
        .managed => |capability| handleFor(alloc, capability, tool_call_id, tool_name, text),
    };
}

pub fn isStoredTextHandle(handle: []const u8) bool {
    return std.mem.startsWith(u8, handle, "result-") and
        std.mem.endsWith(u8, handle, ".txt");
}

/// A compactor record's name, such as `compacted-M12.txt`, which
/// `read_tool_result` opens by its ID (D50).
fn isRecordHandle(handle: []const u8) bool {
    return std.mem.startsWith(u8, handle, "compacted-") and
        std.mem.endsWith(u8, handle, ".txt");
}

pub fn handleMatchesContentDigest(
    handle: []const u8,
    digest: [32]u8,
) bool {
    return artifact_digest.handleMatchesContentDigest(
        handle,
        ".txt",
        digest,
    );
}

fn safeHandlePart(alloc: Allocator, text: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    var wrote = false;
    for (text) |byte| {
        if (out.written().len >= 48) break;
        const safe = std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-';
        try out.writer.writeByte(if (safe) byte else '-');
        wrote = true;
    }
    if (!wrote) try out.writer.writeAll("call");
    return try out.toOwnedSlice();
}

fn readStoredTextManaged(
    alloc: Allocator,
    capability: *session_child_store.SessionChildCapability,
    handle: []const u8,
) ![]u8 {
    if (capability.holdsBlobs()) {
        // Every store's blobs share the session, found by hash alone, so
        // only this store's own handles are its results, its compactor
        // records among them: a command replay's is read by its own store
        // (D44, D50).
        if (!isStoredTextHandle(handle) and !isImageHandle(handle) and !isRecordHandle(handle)) return error.ResultHandleNotFound;
        return capability.readBlob(alloc, .tool_results, handle, stored_text_max_bytes) catch |err| switch (err) {
            error.BlobNotFound => error.ResultHandleNotFound,
            error.BlobTooLarge => error.StreamTooLong,
            else => err,
        };
    }
    var file = capability.openFileReadOnly(
        alloc,
        .tool_results,
        handle,
    ) catch |err| switch (err) {
        error.FileNotFound => return error.ResultHandleNotFound,
        else => return err,
    };
    defer file.deinit();
    return file.readToEnd(alloc, stored_text_max_bytes);
}

/// This session's tool-results folder as fx-compactor's record store, or on
/// v2 its records kept as blobs (D50). The store borrows `capability`.
pub fn compactorStore(capability: *session_child_store.SessionChildCapability) compactor.Store {
    return .{ .context = capability, .vtable = &.{
        .write = writeCompactorFile,
        .list = listCompactorFiles,
        .read = readCompactorFile,
    } };
}

fn writeCompactorFile(context: *anyopaque, alloc: Allocator, name: []const u8, content: []const u8) compactor.Store.Error!void {
    const capability: *session_child_store.SessionChildCapability = @ptrCast(@alignCast(context));
    if (capability.holdsBlobs()) {
        session_child_store.SessionChildCapability.validateManagedName(name) catch |err| return compactorStoreError("write", name, err);
        return capability.putRecord(name, content) catch |err| compactorStoreError("write", name, err);
    }
    var entry = capability.atomicReplace(alloc, .tool_results, name, content) catch |err| return compactorStoreError("write", name, err);
    entry.deinit(alloc);
}

fn listCompactorFiles(context: *anyopaque, arena: Allocator) compactor.Store.Error![]const []const u8 {
    const capability: *session_child_store.SessionChildCapability = @ptrCast(@alignCast(context));
    if (capability.holdsBlobs()) return capability.recordNames(arena) catch |err| compactorStoreError("list", "", err);
    const entries = capability.iterate(arena, .tool_results) catch |err| return compactorStoreError("list", "", err);
    return entries.names;
}

fn readCompactorFile(context: *anyopaque, arena: Allocator, name: []const u8, max_bytes: usize) compactor.Store.Error![]const u8 {
    const capability: *session_child_store.SessionChildCapability = @ptrCast(@alignCast(context));
    if (capability.holdsBlobs()) return readRecordBlob(capability, arena, name, max_bytes);
    var file = capability.openFileReadOnly(arena, .tool_results, name) catch |err| return compactorStoreError("open", name, err);
    defer file.deinit();
    const size = (file.stat() catch |err| return compactorStoreError("stat", name, err)).size;
    return file.readRange(arena, 0, @intCast(@min(size, max_bytes))) catch |err| compactorStoreError("read", name, err);
}

/// Up to `max_bytes` from the start of a v2 record's read-only blob file,
/// which may be far larger than what the compactor searches (D50).
fn readRecordBlob(capability: *session_child_store.SessionChildCapability, arena: Allocator, name: []const u8, max_bytes: usize) compactor.Store.Error![]const u8 {
    session_child_store.SessionChildCapability.validateManagedName(name) catch |err| return compactorStoreError("read", name, err);
    const io = io_mod.getIo();
    var file = capability.openBlobFile(arena, .tool_results, name) catch |err| return compactorStoreError("open", name, switch (err) {
        error.BlobNotFound => error.FileNotFound,
        else => err,
    });
    defer file.close(io);
    const size = (file.stat(io) catch |err| return compactorStoreError("stat", name, err)).size;
    const bytes = try arena.alloc(u8, std.math.cast(usize, @min(size, max_bytes)) orelse return error.OutOfMemory);
    const got = file.readPositionalAll(io, bytes, 0) catch |err| return compactorStoreError("read", name, err);
    return bytes[0..got];
}

fn compactorStoreError(operation: []const u8, name: []const u8, err: anyerror) compactor.Store.Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.FileNotFound => error.FileNotFound,
        else => {
            compactor.traceLog(true, "record store {s} failed name={s} err={s}", .{ operation, name, @errorName(err) });
            return error.StoreFailed;
        },
    };
}

fn validateHandle(handle: []const u8) !void {
    if (isImageHandle(handle)) return validateHandle(handle[6..]);
    if (handle.len == 0 or handle.len > 160) return error.InvalidHandle;
    if (std.mem.find(u8, handle, "..") != null) return error.InvalidHandle;
    for (handle) |byte| {
        const ok = std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-' or byte == '.';
        if (!ok) return error.InvalidHandle;
    }
}

test "large result storage creates stable handle and bounded preview" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(dir);

    var bytes: [large_result_threshold_bytes + 128]u8 = @splat('x');
    const prepared = try prepare(alloc, dir, "call/1", "run_command", bytes.len, bytes[0..], 64 * 1024);
    defer alloc.free(prepared.model_output);
    defer alloc.free(@constCast(prepared.memory.output_handle.?));
    defer alloc.free(@constCast(prepared.memory.preview.?));

    try std.testing.expect(prepared.memory.truncated);
    try std.testing.expect(prepared.memory.preview.?.len <= preview_bytes);
    try std.testing.expect(std.mem.find(u8, prepared.model_output, prepared.memory.output_handle.?) != null);

    const again = try prepare(alloc, dir, "call/1", "run_command", bytes.len, bytes[0..], 64 * 1024);
    defer alloc.free(again.model_output);
    defer alloc.free(@constCast(again.memory.output_handle.?));
    defer alloc.free(@constCast(again.memory.preview.?));
    try std.testing.expectEqualStrings(prepared.memory.output_handle.?, again.memory.output_handle.?);
}

test "a v2 session stores results and images as blobs named by their hash (D44)" {
    const alloc = std.testing.allocator;
    var memory = session_child_store.MemoryBlobsForTesting.init(alloc);
    defer memory.deinit();
    var capability = try session_child_store.SessionChildCapability.initBlobs(alloc, memory.blobs(), "", .writable);
    defer capability.deinit();

    var bytes: [large_result_threshold_bytes + 128]u8 = @splat('x');
    bytes[3] = '\n';
    const prepared = try prepareManaged(alloc, &capability, "call/1", "run_command", bytes.len, bytes[0..], 64 * 1024);
    defer alloc.free(prepared.model_output);
    defer alloc.free(@constCast(prepared.memory.output_handle.?));
    defer alloc.free(@constCast(prepared.memory.preview.?));
    const handle = prepared.memory.output_handle.?;
    const expected = try blobHandle(alloc, &bytes);
    defer alloc.free(expected);
    try std.testing.expectEqualStrings(expected, handle);
    try std.testing.expect(isStoredTextHandle(handle));
    try std.testing.expect(std.mem.find(u8, prepared.model_output, handle) != null);
    try std.testing.expectEqual(@as(usize, 1), memory.count());

    // The same bytes from another call are the same blob.
    const again = try storeLargeResultManaged(alloc, &capability, "call/2", "read_file", &bytes);
    defer alloc.free(again);
    try std.testing.expectEqualStrings(handle, again);
    try std.testing.expectEqual(@as(usize, 1), memory.count());

    const page = try readByRangeManaged(alloc, &capability, handle, 2, 4);
    defer alloc.free(page);
    try std.testing.expect(std.mem.find(u8, page, "start_byte=\"2\" end_byte=\"5\"") != null);
    const query = try searchByQueryManaged(alloc, &capability, handle, "xxx");
    defer alloc.free(query);
    try std.testing.expect(std.mem.find(u8, query, "2|xxx") != null);
    const replay = try readForReplayManaged(alloc, &capability, handle, bytes.len);
    defer alloc.free(replay);
    try std.testing.expectEqualSlices(u8, &bytes, replay);
    try std.testing.expectError(error.ResultSizeMismatch, readForReplayManaged(alloc, &capability, handle, bytes.len - 1));
    var reader = try openReaderManaged(alloc, &capability, handle);
    defer reader.deinit();
    try std.testing.expectEqual(bytes.len, reader.size);
    const tail = try reader.readPage(alloc, bytes.len - 2, 10);
    defer alloc.free(tail);
    try std.testing.expectEqualStrings("xx", tail);

    // Every store's blobs share the session: the same blob under a command
    // replay's handle is not a result, so the caller asks that store.
    const foreign = try std.mem.concat(alloc, u8, &.{ "fx-command-replay-", artifact_digest.blobHash(handle).?, ".bin" });
    defer alloc.free(foreign);
    try std.testing.expectError(error.ResultHandleNotFound, readByRangeManaged(alloc, &capability, foreign, 1, 4));
    try std.testing.expectError(error.ResultHandleNotFound, searchByQueryManaged(alloc, &capability, foreign, "xxx"));

    // A blob stays with the session; an unknown hash is not found.
    try deleteManaged(&capability, handle);
    const kept = try readByRangeManaged(alloc, &capability, handle, 1, 1);
    alloc.free(kept);
    const missing = try blobHandle(alloc, "never stored");
    defer alloc.free(missing);
    try std.testing.expectError(error.ResultHandleNotFound, readByRangeManaged(alloc, &capability, missing, 1, 1));

    // Image packs are blobs too, and their handle still routes as an image.
    const png = [_]u8{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n', 0, 0, 0, 13, 'I', 'H', 'D', 'R', 0, 0, 0, 1, 0, 0, 0, 1, 8, 6, 0, 0, 0 };
    const encoded = try alloc.alloc(u8, std.base64.standard.Encoder.calcSize(png.len));
    defer alloc.free(encoded);
    _ = std.base64.standard.Encoder.encode(encoded, &png);
    const images = [_]types.ToolImage{.{ .mime_type = @constCast("image/png"), .data = encoded }};
    const image_handle = try storeToolImages(alloc, &capability, "call/3", "screenshot", &images);
    defer alloc.free(image_handle);
    try std.testing.expect(isImageHandle(image_handle));
    try std.testing.expect(artifact_digest.blobHash(image_handle) != null);
    const loaded = try loadToolImages(alloc, &capability, image_handle);
    defer types.freeToolImages(alloc, loaded);
    try std.testing.expectEqualStrings(encoded, loaded[0].data);

    // A read-only copy reads, but cannot store.
    var read_only = try capability.cloneReadOnly(alloc);
    defer read_only.deinit();
    const through_copy = try readByRangeManaged(alloc, &read_only, handle, 1, 3);
    alloc.free(through_copy);
    try std.testing.expectError(error.SessionChildReadOnly, storeLargeResultManaged(alloc, &read_only, "call/4", "x", "new body"));
}

test "the tool-results folder serves as the compactor's record store" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const dir = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(dir);
    var capability = try session_child_store.SessionChildCapability.initLegacyRoute(alloc, dir, .tool_results, .writable);
    defer capability.deinit();
    const store = compactorStore(&capability);
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try store.write(alloc, "compacted-T1.txt", "T1 shell: ls\nResult:\nfirst\n");
    try store.write(alloc, "compacted-T1.txt", "T1 shell: ls\nResult:\nreplaced\n");
    const names = try store.list(arena);
    try std.testing.expectEqual(@as(usize, 1), names.len);
    try std.testing.expectEqualStrings("compacted-T1.txt", names[0]);
    try std.testing.expectEqualStrings("T1 shell: ls\nResult:\nreplaced\n", try store.read(arena, "compacted-T1.txt", 1024));
    try std.testing.expectEqualStrings("T1 shell", try store.read(arena, "compacted-T1.txt", 8));
    try std.testing.expectError(error.FileNotFound, store.read(arena, "compacted-T2.txt", 1024));
    try std.testing.expectError(error.StoreFailed, store.write(alloc, "../escape.txt", "no"));
}

test "a v2 session's compactor records are blobs, replaced and listed by name (D50)" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const blob_dir = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(blob_dir);
    var memory = session_child_store.MemoryBlobsForTesting.initWithFiles(alloc, blob_dir);
    defer memory.deinit();
    var capability = try session_child_store.SessionChildCapability.initBlobs(alloc, memory.blobs(), "", .writable);
    defer capability.deinit();
    const store = compactorStore(&capability);
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try store.write(alloc, "compacted-T1.txt", "T1 shell: ls\nResult:\nfirst\n");
    try store.write(alloc, "compacted-T1.txt", "T1 shell: ls\nResult:\nreplaced\n");
    const names = try store.list(arena);
    try std.testing.expectEqual(@as(usize, 1), names.len);
    try std.testing.expectEqualStrings("compacted-T1.txt", names[0]);
    try std.testing.expectEqualStrings("T1 shell: ls\nResult:\nreplaced\n", try store.read(arena, "compacted-T1.txt", 1024));
    try std.testing.expectEqualStrings("T1 shell", try store.read(arena, "compacted-T1.txt", 8));
    try std.testing.expectError(error.FileNotFound, store.read(arena, "compacted-T2.txt", 1024));
    try std.testing.expectError(error.StoreFailed, store.write(alloc, "../escape.txt", "no"));

    // read_tool_result opens a record by its ID through the ordinary reader.
    const page = try readByRangeManaged(alloc, &capability, "compacted-T1.txt", 1, 64);
    defer alloc.free(page);
    try std.testing.expect(std.mem.find(u8, page, "replaced") != null);

    // A read-only copy reads records but cannot keep one.
    var read_only = try capability.cloneReadOnly(alloc);
    defer read_only.deinit();
    try std.testing.expectEqualStrings("T1 shell", try compactorStore(&read_only).read(arena, "compacted-T1.txt", 8));
    try std.testing.expectError(error.StoreFailed, compactorStore(&read_only).write(alloc, "compacted-T2.txt", "x"));
}

test "diff content packs round trip, bound, and reject tampering" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(dir);

    const handle = try storeDiffContent(alloc, dir, "call-edit-1", "line one\nline two\n", "line one\nline 2\n");
    defer alloc.free(handle);
    try std.testing.expect(isDiffContentHandle(handle));
    try std.testing.expect(!isDiffContentHandle("result-shell.txt"));

    var capability = try session_child_store.SessionChildCapability.initLegacyRoute(
        alloc,
        dir,
        .tool_results,
        .writable,
    );
    defer capability.deinit();
    var pack = try loadDiffContentManaged(
        alloc,
        &capability,
        "call-edit-1",
        handle,
    );
    defer pack.deinit(alloc);
    try std.testing.expectEqualStrings("line one\nline two\n", pack.previous_content.?);
    try std.testing.expectEqualStrings("line one\nline 2\n", pack.after_content.?);
    try std.testing.expectError(
        error.InvalidResultHandle,
        loadDiffContentManaged(alloc, &capability, "call-edit-2", handle),
    );

    // Null snapshots survive the round trip.
    const partial = try storeDiffContent(alloc, dir, "call-edit-2", null, "created\n");
    defer alloc.free(partial);
    var partial_pack = try loadDiffContentManaged(
        alloc,
        &capability,
        "call-edit-2",
        partial,
    );
    defer partial_pack.deinit(alloc);
    try std.testing.expect(partial_pack.previous_content == null);
    try std.testing.expectEqualStrings("created\n", partial_pack.after_content.?);

    // A tampered artifact fails the content digest check.
    var rewritten = try capability.atomicReplace(alloc, .tool_results, handle, "{\"previous_content\":\"forged\",\"after_content\":null}");
    rewritten.deinit(alloc);
    try std.testing.expectError(
        error.DiffContentArtifactChanged,
        loadDiffContentManaged(alloc, &capability, "call-edit-1", handle),
    );

    // Handles from other artifact families are rejected before any read.
    try std.testing.expectError(
        error.InvalidResultHandle,
        loadDiffContentManaged(
            alloc,
            &capability,
            "call-edit-1",
            "result-shell.txt",
        ),
    );
}

test "diff content encoding propagates every allocation failure" {
    const backing = testing_allocator.no_resize;
    const previous = text_utils.repeat("before\n", 800);
    const after = text_utils.repeat("after\n", 800);
    var probe = std.testing.FailingAllocator.init(backing, .{});
    const encoded = try encodeDiffContentPack(
        probe.allocator(),
        previous,
        after,
    );
    probe.allocator().free(encoded);
    const allocation_count = probe.alloc_index;
    try std.testing.expect(allocation_count > 1);

    for (0..allocation_count) |fail_index| {
        var failing = std.testing.FailingAllocator.init(
            backing,
            .{ .fail_index = fail_index },
        );
        try std.testing.expectError(
            error.OutOfMemory,
            encodeDiffContentPack(failing.allocator(), previous, after),
        );
        try std.testing.expect(failing.has_induced_failure);
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    }
}

test "saved preparation externalizes small results" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(dir);

    const prepared = try prepare(
        alloc,
        dir,
        "call-small",
        "read_file",
        4,
        "done",
        64 * 1024,
    );
    defer alloc.free(prepared.model_output);
    defer if (prepared.memory.output_handle) |handle| alloc.free(@constCast(handle));
    defer if (prepared.memory.preview) |preview| alloc.free(@constCast(preview));

    const handle = prepared.memory.output_handle orelse return error.TestExpectedResultHandle;
    const stored = try readByRange(
        alloc,
        dir,
        handle,
        0,
        16,
    );
    defer alloc.free(stored);
    try std.testing.expect(std.mem.find(u8, stored, "total_bytes=\"4\"") != null);
    try std.testing.expect(std.mem.find(u8, stored, "\ndone\n") != null);
}

test "inline cap and stored preview keep complete codepoints" {
    const alloc = std.testing.allocator;

    const inline_text = "x" ++ text_utils.repeat("\xc3\xa9", 300);
    for ([_]usize{ 128, 129 }) |cap| {
        const prepared = try prepare(alloc, null, "call/2", "grep_files", inline_text.len, inline_text, cap);
        defer alloc.free(prepared.model_output);
        const marker_start = std.mem.find(u8, prepared.model_output, "\n... [tool result truncated").?;
        const prefix = prepared.model_output[0..marker_start];
        try std.testing.expect(std.unicode.utf8ValidateSlice(prefix));
        try std.testing.expect(std.mem.endsWith(u8, prefix, "\xc3\xa9"));
    }

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(dir);
    const stored_text = "x" ++ text_utils.repeat("\xc3\xa9", 8200);
    const stored = try prepare(alloc, dir, "call/3", "run_command", stored_text.len, stored_text, 64 * 1024);
    defer alloc.free(stored.model_output);
    defer alloc.free(@constCast(stored.memory.output_handle.?));
    defer alloc.free(@constCast(stored.memory.preview.?));
    try std.testing.expectEqual(@as(usize, preview_bytes - 1), stored.memory.preview.?.len);
    try std.testing.expect(std.mem.endsWith(u8, stored.memory.preview.?, "\xc3\xa9"));
    try std.testing.expect(std.unicode.utf8ValidateSlice(stored.memory.preview.?));
}

test "large result handles never expose token-shaped call ids" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(dir);

    var bytes: [large_result_threshold_bytes + 1]u8 = @splat('x');
    const secret_id = "sk-abcdefghijklmnop";
    const prepared = try prepare(
        alloc,
        dir,
        secret_id,
        "read_file",
        bytes.len,
        bytes[0..],
        bytes.len,
    );
    defer alloc.free(prepared.model_output);
    defer alloc.free(@constCast(prepared.memory.output_handle.?));
    defer alloc.free(@constCast(prepared.memory.preview.?));

    try std.testing.expect(
        std.mem.find(u8, prepared.memory.output_handle.?, secret_id) == null,
    );
    try std.testing.expect(
        std.mem.find(u8, prepared.model_output, secret_id) == null,
    );
}

const PrepareRoute = enum {
    legacy,
    managed,
};

fn expectLargeResultPreparationLeavesNoOrphan(route: PrepareRoute) !void {
    const base = testing_allocator.no_resize;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "results");
    const dir = try io_mod.dirRealpathAlloc(base, tmp.dir, "results");
    defer base.free(dir);
    var capability = try session_child_store.SessionChildCapability.initLegacyRoute(
        base,
        dir,
        .tool_results,
        .writable,
    );
    defer capability.deinit();

    var bytes: [large_result_threshold_bytes + 128]u8 = @splat('x');
    var reached_success = false;
    var fail_index: usize = 0;
    while (fail_index < 128) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(
            base,
            .{ .fail_index = fail_index },
        );
        const alloc = failing.allocator();
        const prepared_result = switch (route) {
            .legacy => prepare(
                alloc,
                dir,
                "call",
                "read_file",
                bytes.len,
                bytes[0..],
                bytes.len,
            ),
            .managed => prepareManaged(
                alloc,
                &capability,
                "call",
                "read_file",
                bytes.len,
                bytes[0..],
                bytes.len,
            ),
        };
        if (prepared_result) |prepared| {
            defer alloc.free(@constCast(prepared.model_output));
            defer if (prepared.memory.output_handle) |handle| {
                alloc.free(@constCast(handle));
            };
            defer if (prepared.memory.preview) |preview| {
                alloc.free(@constCast(preview));
            };
            if (prepared.memory.output_handle) |handle| {
                try deleteManaged(&capability, handle);
            }
            reached_success = true;
            break;
        } else |_| {
            var entries = try capability.iterate(base, .tool_results);
            defer entries.deinit();
            try std.testing.expectEqual(@as(usize, 0), entries.names.len);
        }
    }
    try std.testing.expect(reached_success);
}

test "legacy large result preparation removes committed files on later allocation failure" {
    try expectLargeResultPreparationLeavesNoOrphan(.legacy);
}

test "managed large result preparation removes committed files on later allocation failure" {
    try expectLargeResultPreparationLeavesNoOrphan(.managed);
}

fn expectExistingLargeResultSurvivesPreparationFailure(
    route: PrepareRoute,
) !void {
    const base = testing_allocator.no_resize;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "results");
    const dir = try io_mod.dirRealpathAlloc(base, tmp.dir, "results");
    defer base.free(dir);
    var capability = try session_child_store.SessionChildCapability.initLegacyRoute(
        base,
        dir,
        .tool_results,
        .writable,
    );
    defer capability.deinit();

    var bytes: [large_result_threshold_bytes + 128]u8 = @splat('x');
    const seeded_handle = try storeLargeResultManaged(
        base,
        &capability,
        "call",
        "read_file",
        bytes[0..],
    );
    defer base.free(seeded_handle);
    defer deleteManaged(&capability, seeded_handle) catch {};

    var reached_success = false;
    var fail_index: usize = 0;
    while (fail_index < 128) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(
            base,
            .{ .fail_index = fail_index },
        );
        const alloc = failing.allocator();
        const prepared_result = switch (route) {
            .legacy => prepare(
                alloc,
                dir,
                "call",
                "read_file",
                bytes.len,
                bytes[0..],
                bytes.len,
            ),
            .managed => prepareManaged(
                alloc,
                &capability,
                "call",
                "read_file",
                bytes.len,
                bytes[0..],
                bytes.len,
            ),
        };
        if (prepared_result) |prepared| {
            defer alloc.free(@constCast(prepared.model_output));
            defer if (prepared.memory.output_handle) |handle| {
                alloc.free(@constCast(handle));
            };
            defer if (prepared.memory.preview) |preview| {
                alloc.free(@constCast(preview));
            };
            reached_success = true;
            break;
        } else |_| {
            const stored = try readByRangeManaged(
                base,
                &capability,
                seeded_handle,
                1,
                bytes.len,
            );
            defer base.free(stored);
            try std.testing.expect(std.mem.find(u8, stored, bytes[0..64]) != null);
        }
    }
    try std.testing.expect(reached_success);
}

test "legacy preparation failure preserves an existing deterministic handle" {
    try expectExistingLargeResultSurvivesPreparationFailure(.legacy);
}

test "managed preparation failure preserves an existing deterministic handle" {
    try expectExistingLargeResultSurvivesPreparationFailure(.managed);
}

test "stored result reads support ranges and literal queries" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(dir);

    const handle = try storeLargeResult(alloc, dir, "call", "grep_files", "alpha\nneedle one\nbeta\nneedle two\n");
    defer alloc.free(handle);
    const ranged = try readByRange(alloc, dir, handle, 1, 5);
    defer alloc.free(ranged);
    try std.testing.expect(std.mem.find(u8, ranged, "alpha") != null);

    const queried = try searchByQuery(alloc, dir, handle, "needle");
    defer alloc.free(queried);
    try std.testing.expect(std.mem.find(u8, queried, "needle one") != null);
    try std.testing.expect(std.mem.find(u8, queried, "needle two") != null);
}

test "range reads snap to utf8 rune boundaries" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(dir);

    const handle = try storeLargeResult(alloc, dir, "call", "grep_files", "ab\xc3\xa9\xc3\xa9cd");
    defer alloc.free(handle);

    const tail = try readByRange(alloc, dir, handle, 4, 3);
    defer alloc.free(tail);
    try std.testing.expect(std.mem.find(u8, tail, "start_byte=\"5\" end_byte=\"6\"") != null);
    try std.testing.expect(std.mem.find(u8, tail, "\n\xc3\xa9\n") != null);

    const head = try readByRange(alloc, dir, handle, 1, 3);
    defer alloc.free(head);
    try std.testing.expect(std.mem.find(u8, head, "start_byte=\"1\" end_byte=\"2\"") != null);
    try std.testing.expect(std.mem.find(u8, head, "\nab\n") != null);
}

test "managed result reader reaches head middle and tail through bounded pages" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "results");
    const result_dir = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "results");
    defer alloc.free(result_dir);
    var capability = try session_child_store.SessionChildCapability.initLegacyRoute(
        alloc,
        result_dir,
        .tool_results,
        .writable,
    );
    defer capability.deinit();

    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(alloc);
    try content.appendSlice(alloc, "FULL_READER_HEAD\n");
    try content.appendNTimes(alloc, 'x', 8 * 1024 * 1024);
    try content.appendSlice(alloc, "\nFULL_READER_TAIL\n");
    const handle = try storeLargeResultManaged(
        alloc,
        &capability,
        "full-reader",
        "read_file",
        content.items,
    );
    defer alloc.free(handle);
    defer deleteManaged(&capability, handle) catch {};

    var reader = try openReaderManaged(alloc, &capability, handle);
    defer reader.deinit();
    try std.testing.expectEqual(content.items.len, reader.size);

    const head = try reader.readPage(alloc, 0, full_read_chunk_bytes);
    defer alloc.free(head);
    try std.testing.expect(std.mem.startsWith(u8, head, "FULL_READER_HEAD\n"));

    const middle = try reader.readPage(alloc, reader.size / 2, full_read_chunk_bytes);
    defer alloc.free(middle);
    try std.testing.expectEqual(@as(usize, full_read_chunk_bytes), middle.len);
    try std.testing.expect(std.mem.findScalar(u8, middle, 'x') != null);

    const tail_offset = reader.size - "\nFULL_READER_TAIL\n".len;
    const tail = try reader.readPage(alloc, tail_offset, full_read_chunk_bytes);
    defer alloc.free(tail);
    try std.testing.expectEqualStrings("\nFULL_READER_TAIL\n", tail);
}

test "managed replay reads a complete result whose close tag is beyond the range limit" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(dir);
    var capability = try session_child_store.SessionChildCapability.initLegacyRoute(
        alloc,
        dir,
        .tool_results,
        .writable,
    );
    defer capability.deinit();

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(alloc);
    try output.appendSlice(alloc, "<stdout>\n");
    try output.appendNTimes(alloc, 'x', read_max_bytes);
    try output.appendSlice(alloc, "\n</stdout>\n");

    const handle = try storeLargeResultManaged(
        alloc,
        &capability,
        "replay",
        "run_command",
        output.items,
    );
    defer alloc.free(handle);

    const ranged = try readByRangeManaged(
        alloc,
        &capability,
        handle,
        1,
        read_max_bytes,
    );
    defer alloc.free(ranged);
    try std.testing.expect(std.mem.find(u8, ranged, "</stdout>") == null);

    const replayed = try readForReplayManaged(
        alloc,
        &capability,
        handle,
        output.items.len,
    );
    defer alloc.free(replayed);
    try std.testing.expectEqualStrings(output.items, replayed);
    try std.testing.expectError(
        error.ResultSizeMismatch,
        readForReplayManaged(alloc, &capability, handle, output.items.len - 1),
    );
    try std.testing.expectError(
        error.ResultSizeUnsupported,
        readForReplayManaged(alloc, &capability, handle, stored_text_max_bytes + 1),
    );
}

test "managed result create read stat delete remains contained after route swap" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "results");
    try tmp.dir.createDirPath(io_mod.getIo(), "outside");
    const result_dir = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "results");
    defer alloc.free(result_dir);
    var capability = try session_child_store.SessionChildCapability.initLegacyRoute(
        alloc,
        result_dir,
        .tool_results,
        .writable,
    );
    defer capability.deinit();

    try tmp.dir.rename(
        "results",
        tmp.dir,
        "retained-results",
        io_mod.getIo(),
    );
    try tmp.dir.symLink(
        io_mod.getIo(),
        "outside",
        "results",
        .{ .is_directory = true },
    );

    const handle = try storeLargeResultManaged(
        alloc,
        &capability,
        "managed",
        "grep_files",
        "alpha\nneedle\n",
    );
    defer alloc.free(handle);
    const stat = try statManaged(&capability, handle);
    try std.testing.expectEqual(@as(u64, 13), stat.size);
    const ranged = try readByRangeManaged(
        alloc,
        &capability,
        handle,
        1,
        5,
    );
    defer alloc.free(ranged);
    try std.testing.expect(std.mem.find(u8, ranged, "alpha") != null);
    const outside_path = try std.Io.Dir.path.join(
        alloc,
        &.{ "outside", handle },
    );
    defer alloc.free(outside_path);
    try std.testing.expectError(
        error.FileNotFound,
        tmp.dir.statFile(io_mod.getIo(), outside_path, .{}),
    );

    try deleteManaged(&capability, handle);
    try std.testing.expectError(
        error.ResultHandleNotFound,
        readByRangeManaged(alloc, &capability, handle, 1, 5),
    );
}

test "managed result read only absence does not create route" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(
        io_mod.getIo(),
        "session",
        std.Io.File.Permissions.fromMode(0o700),
    );
    var session_dir = try tmp.dir.openDir(io_mod.getIo(), "session", .{
        .iterate = true,
        .follow_symlinks = false,
    });
    defer session_dir.close(io_mod.getIo());
    const session_path = try io_mod.dirRealpathAlloc(
        alloc,
        tmp.dir,
        "session",
    );
    defer alloc.free(session_path);
    var capability = try session_child_store.SessionChildCapability.initForTesting(
        alloc,
        session_dir,
        session_path,
        .read_only,
        .{},
    );
    defer capability.deinit();

    try std.testing.expectError(
        error.ResultHandleNotFound,
        readByRangeManaged(alloc, &capability, "missing.txt", 1, 5),
    );
    try std.testing.expectError(
        error.FileNotFound,
        session_dir.statFile(io_mod.getIo(), "tool-results", .{}),
    );
}

test "managed result handles authenticate stored content" {
    const alloc = std.testing.allocator;
    const content = "authenticated result";
    const handle = try makeHandle(
        alloc,
        "call-authenticated",
        "run_command",
        content,
    );
    defer alloc.free(handle);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(content, &digest, .{});
    try std.testing.expect(isStoredTextHandle(handle));
    try std.testing.expect(!isStoredTextHandle("image-result-shell-0123456789abcdef.txt"));
    try std.testing.expect(!isStoredTextHandle("other-0123456789abcdef.txt"));
    try std.testing.expect(handleMatchesContentDigest(handle, digest));
    std.crypto.hash.sha2.Sha256.hash("xuthenticated result", &digest, .{});
    try std.testing.expect(!handleMatchesContentDigest(handle, digest));
    try std.testing.expect(!handleMatchesContentDigest(
        "result-run_command-legacy.txt",
        digest,
    ));
}

test "stored tool image source refs round trip without reading the host source" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "images");
    const path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "images");
    defer alloc.free(path);
    var capability = try session_child_store.SessionChildCapability.initLegacyRoute(alloc, path, .tool_results, .writable);
    defer capability.deinit();
    const png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jP0cAAAAASUVORK5CYII=";
    const originals = [_]types.ToolImage{
        .{ .data = @constCast(png), .mime_type = @constCast("image/png"), .source_ref = @constCast("host:original") },
        .{ .data = @constCast(""), .mime_type = @constCast("image/jpeg"), .source_ref = @constCast("/unavailable/host/source") },
    };
    const handle = try storeToolImages(alloc, &capability, "recover", "host_image", &originals);
    defer alloc.free(handle);
    const loaded = try loadToolImages(alloc, &capability, handle);
    defer types.freeToolImages(alloc, loaded);
    try std.testing.expectEqual(@as(usize, 2), loaded.len);
    try std.testing.expectEqualStrings(png, loaded[0].data);
    try std.testing.expectEqualStrings("host:original", loaded[0].source_ref.?);
    try std.testing.expectEqualStrings("", loaded[1].data);
    try std.testing.expectEqualStrings("/unavailable/host/source", loaded[1].source_ref.?);
    try std.testing.expectError(error.InvalidSourceRef, storeToolImages(alloc, &capability, "bad", "host_image", &.{.{
        .data = @constCast(""),
        .mime_type = @constCast("image/png"),
        .source_ref = @constCast("bad\nref"),
    }}));
    try std.testing.expectError(error.InvalidImage, storeToolImages(alloc, &capability, "empty", "host_image", &.{.{
        .data = @constCast(""),
        .mime_type = @constCast("image/png"),
    }}));
}

test "stored tool images round trip and reject changed artifacts" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "images");
    const path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "images");
    defer alloc.free(path);
    var capability = try session_child_store.SessionChildCapability.initLegacyRoute(alloc, path, .tool_results, .writable);
    defer capability.deinit();
    const png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jP0cAAAAASUVORK5CYII=";
    const handle = try storeToolImages(alloc, &capability, "screenshot", "browser", &.{.{ .data = @constCast(png), .mime_type = @constCast("image/png") }});
    defer alloc.free(handle);
    const loaded = try loadToolImages(alloc, &capability, handle);
    defer types.freeToolImages(alloc, loaded);
    try std.testing.expectEqual(@as(usize, 1), loaded.len);
    try std.testing.expectEqualStrings(png, loaded[0].data);
    try std.testing.expectEqualStrings("image/png", loaded[0].mime_type);
    var entry = try capability.atomicReplace(alloc, .tool_results, handle, "[]");
    entry.deinit(alloc);
    try std.testing.expectError(error.ImageArtifactChanged, loadToolImages(alloc, &capability, handle));
    try std.testing.expectError(error.InvalidHandle, loadToolImages(alloc, &capability, "image-result-../../elsewhere"));
}
