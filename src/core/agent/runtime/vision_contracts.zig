const std = @import("std");
const image_attachments = @import("../../images/image_attachments.zig");
const types = @import("../../shared/types.zig");
const tool_result_errors = @import("../../tooling/tool_result_errors.zig");

const Allocator = std.mem.Allocator;

const max_focus_bytes: usize = 4096;
const max_provider_images_per_batch: usize = 8;
pub const native_route_unavailable_message = "Vision is unavailable for this request.";
pub const provider_response_format_name = "fx_vision_evidence";
pub const provider_response_format_description = "Factual evidence extracted from the requested images.";

pub const VisionRequestError = error{
    InvalidVisionJson,
    InvalidVisionRequest,
    EmptyImageIds,
    InvalidImageId,
    DuplicateImageId,
    EmptyPaths,
    InvalidImagePath,
    DuplicateImagePath,
    EmptyFocus,
    FocusTooLong,
};

pub const VisionResultError = error{
    InvalidVisionJson,
    InvalidVisionResult,
    InvalidImageId,
    DuplicateImageId,
    UnauthorizedImageId,
    ProviderResultTooLarge,
    TooManyProviderImages,
};

pub const VisionSource = union(enum) {
    image_ids: []usize,
    paths: [][]u8,

    fn deinit(self: VisionSource, alloc: Allocator) void {
        switch (self) {
            .image_ids => |image_ids| alloc.free(image_ids),
            .paths => |paths| free_owned_strings(alloc, paths),
        }
    }
};

pub const VisionRequest = struct {
    source: VisionSource,
    focus: []u8,

    pub fn deinit(self: VisionRequest, alloc: Allocator) void {
        self.source.deinit(alloc);
        alloc.free(self.focus);
    }

    pub fn image_ids(self: VisionRequest) ?[]const usize {
        return switch (self.source) {
            .image_ids => |ids| ids,
            .paths => null,
        };
    }

    pub fn paths(self: VisionRequest) ?[]const []u8 {
        return switch (self.source) {
            .image_ids => null,
            .paths => |paths_value| paths_value,
        };
    }
};

pub const OutputLimit = struct {
    observed_bytes: usize,
    configured_bytes: usize,
};

pub const VisionFailure = union(enum) {
    image_unavailable,
    provider_response_invalid,
    output_limit_exceeded: OutputLimit,
    vision_unavailable,
    missing_provider_record,

    pub fn code(self: VisionFailure) FailureCode {
        return std.meta.activeTag(self);
    }

    fn retryable(self: VisionFailure) bool {
        return switch (self) {
            .image_unavailable => false,
            .provider_response_invalid,
            .output_limit_exceeded,
            .vision_unavailable,
            .missing_provider_record,
            => true,
        };
    }

    fn suggestion(self: VisionFailure) []const u8 {
        return switch (self) {
            .image_unavailable => "Explain the local image failure; do not retry the same snapshot unchanged.",
            .provider_response_invalid => "Try a later explicit Vision call if useful, or continue without visual claims.",
            .output_limit_exceeded => "Call Vision again with a narrower focus or fewer images.",
            .vision_unavailable => "Retry later, change model or strategy, or continue without visual claims.",
            .missing_provider_record => "Call Vision again for only this image if its evidence is still needed.",
        };
    }
};

pub const FailureCode = std.meta.Tag(VisionFailure);

pub const ImageEvidence = struct {
    summary: []u8,
    visible_text: [][]u8,
    details: [][]u8,

    pub fn deinit(self: ImageEvidence, alloc: Allocator) void {
        alloc.free(self.summary);
        free_owned_strings(alloc, self.visible_text);
        free_owned_strings(alloc, self.details);
    }
};

pub const ImageOutcome = union(enum) {
    ok: ImageEvidence,
    failed: VisionFailure,
};

pub const VisionImageResult = struct {
    image_id: usize,
    outcome: ImageOutcome,

    pub fn deinit(self: VisionImageResult, alloc: Allocator) void {
        switch (self.outcome) {
            .ok => |evidence| evidence.deinit(alloc),
            .failed => {},
        }
    }
};

pub const VisionResult = struct {
    images: []VisionImageResult,

    pub fn deinit(self: VisionResult, alloc: Allocator) void {
        for (self.images) |image| image.deinit(alloc);
        if (self.images.len > 0) alloc.free(self.images);
    }
};

/// Builds the provider-enforced JSON shape for one verified Vision batch.
/// The caller owns the returned bytes.
pub fn build_provider_response_schema(
    alloc: Allocator,
    image_count: usize,
) ![]u8 {
    if (image_count == 0 or image_count > max_provider_images_per_batch) {
        return error.InvalidVisionResponseImageCount;
    }

    const ok_statuses = [_][]const u8{"ok"};
    const failed_statuses = [_][]const u8{"failed"};
    const failure_codes = [_][]const u8{"vision_unavailable"};
    const success_required = [_][]const u8{ "image_id", "status", "summary", "visible_text", "details" };
    const failure_required = [_][]const u8{ "image_id", "status", "error" };
    const root_required = [_][]const u8{"images"};
    const schema = .{
        .type = "object",
        .properties = .{
            .images = .{
                .type = "array",
                .minItems = image_count,
                .maxItems = image_count,
                .items = .{
                    .anyOf = .{
                        .{
                            .type = "object",
                            .properties = .{
                                .image_id = .{ .type = "integer" },
                                .status = .{ .type = "string", .@"enum" = ok_statuses[0..] },
                                .summary = .{ .type = "string" },
                                .visible_text = .{ .type = "array", .items = .{ .type = "string" } },
                                .details = .{ .type = "array", .items = .{ .type = "string" } },
                            },
                            .required = success_required[0..],
                            .additionalProperties = false,
                        },
                        .{
                            .type = "object",
                            .properties = .{
                                .image_id = .{ .type = "integer" },
                                .status = .{ .type = "string", .@"enum" = failed_statuses[0..] },
                                .@"error" = .{ .type = "string", .@"enum" = failure_codes[0..] },
                            },
                            .required = failure_required[0..],
                            .additionalProperties = false,
                        },
                    },
                },
            },
        },
        .required = root_required[0..],
        .additionalProperties = false,
    };

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try std.json.Stringify.value(schema, .{}, &out.writer);
    return out.toOwnedSlice();
}

pub fn parse_vision_request(
    alloc: Allocator,
    json: []const u8,
) (Allocator.Error || VisionRequestError)!VisionRequest {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidVisionJson,
    };
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidVisionRequest;
    const object = parsed.value.object;
    const image_ids_value = object.get("image_ids");
    const paths_value = object.get("paths");
    if (object.count() != 2 or (image_ids_value == null) == (paths_value == null)) {
        return error.InvalidVisionRequest;
    }

    const source: VisionSource = if (image_ids_value) |value| blk: {
        if (value != .array) return error.InvalidVisionRequest;
        if (value.array.items.len == 0) return error.EmptyImageIds;

        const image_ids = try alloc.alloc(usize, value.array.items.len);
        errdefer alloc.free(image_ids);
        for (value.array.items, 0..) |item, index| {
            image_ids[index] = try parse_image_id(item);
        }
        try image_attachments.validate_image_ids(image_ids);
        break :blk .{ .image_ids = image_ids };
    } else blk: {
        const value = paths_value.?;
        if (value != .array) return error.InvalidVisionRequest;
        if (value.array.items.len == 0) return error.EmptyPaths;

        const paths = try alloc.alloc([]u8, value.array.items.len);
        errdefer alloc.free(paths);
        var copied: usize = 0;
        errdefer for (paths[0..copied]) |path| alloc.free(path);
        for (value.array.items, 0..) |item, index| {
            if (item != .string or
                std.mem.trim(u8, item.string, " \t\r\n").len == 0 or
                item.string.len > std.fs.max_path_bytes)
            {
                return error.InvalidImagePath;
            }
            for (paths[0..index]) |previous| {
                if (std.mem.eql(u8, previous, item.string)) return error.DuplicateImagePath;
            }
            paths[index] = try alloc.dupe(u8, item.string);
            copied += 1;
        }
        break :blk .{ .paths = paths };
    };
    errdefer source.deinit(alloc);

    const focus_value = object.get("focus") orelse return error.InvalidVisionRequest;
    if (focus_value != .string) return error.InvalidVisionRequest;
    if (std.mem.trim(u8, focus_value.string, " \t\r\n").len == 0) return error.EmptyFocus;
    if (focus_value.string.len > max_focus_bytes) return error.FocusTooLong;

    return .{
        .source = source,
        .focus = try alloc.dupe(u8, focus_value.string),
    };
}

/// Parses provider JSON up to the caller-supplied effective capture bound.
pub fn parse_vision_provider_result(
    alloc: Allocator,
    json: []const u8,
    max_result_bytes: usize,
) (Allocator.Error || VisionResultError)!VisionResult {
    if (json.len > max_result_bytes) return error.ProviderResultTooLarge;
    const payload = single_json_fence_payload(json) orelse json;
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, payload, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidVisionJson,
    };
    defer parsed.deinit();

    const object = exact_object(parsed.value, &.{"images"}) orelse
        return error.InvalidVisionResult;
    const images_value = object.get("images") orelse return error.InvalidVisionResult;
    if (images_value != .array) return error.InvalidVisionResult;
    if (images_value.array.items.len > max_provider_images_per_batch) {
        return error.TooManyProviderImages;
    }
    if (images_value.array.items.len == 0) return error.InvalidVisionResult;

    const images = try alloc.alloc(VisionImageResult, images_value.array.items.len);
    errdefer alloc.free(images);
    var parsed_count: usize = 0;
    errdefer for (images[0..parsed_count]) |image| image.deinit(alloc);

    for (images_value.array.items, 0..) |value, index| {
        images[index] = try parse_image_result(alloc, value);
        parsed_count += 1;
        for (images[0..index]) |previous| {
            if (previous.image_id == images[index].image_id) return error.DuplicateImageId;
        }
    }
    return .{ .images = images };
}

fn single_json_fence_payload(bytes: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, bytes, " \t\r\n");
    const prefix = "```json";
    if (!std.mem.startsWith(u8, trimmed, prefix)) return null;
    const after_prefix = trimmed[prefix.len..];
    if (after_prefix.len == 0 or (after_prefix[0] != '\n' and after_prefix[0] != '\r')) return null;
    const suffix = "```";
    if (!std.mem.endsWith(u8, trimmed, suffix)) return null;
    const body = trimmed[prefix.len .. trimmed.len - suffix.len];
    return std.mem.trim(u8, body, " \t\r\n");
}

/// Returns a deep-owned result in the exact order of `requested_ids`.
pub fn merge_vision_results(
    alloc: Allocator,
    requested_ids: []const usize,
    provider_records: []const VisionImageResult,
) (Allocator.Error || VisionResultError || error{EmptyImageIds})!VisionResult {
    try image_attachments.validate_image_ids(requested_ids);
    for (provider_records, 0..) |record, index| {
        try validate_result_record(record);
        for (provider_records[0..index]) |previous| {
            if (previous.image_id == record.image_id) return error.DuplicateImageId;
        }
        if (!contains_image_id(requested_ids, record.image_id)) {
            return error.UnauthorizedImageId;
        }
    }

    const images = try alloc.alloc(VisionImageResult, requested_ids.len);
    errdefer alloc.free(images);
    var copied: usize = 0;
    errdefer for (images[0..copied]) |image| image.deinit(alloc);

    for (requested_ids, 0..) |image_id, index| {
        const provider_record = find_result_record(provider_records, image_id);
        images[index] = if (provider_record) |record|
            try dupe_result_record(alloc, record)
        else
            .{ .image_id = image_id, .outcome = .{ .failed = .missing_provider_record } };
        copied += 1;
    }
    return .{ .images = images };
}

/// Serializes a validated path-free Vision result. The caller owns the bytes.
pub fn stringify_vision_result(
    alloc: Allocator,
    result: VisionResult,
) (Allocator.Error || VisionResultError || std.Io.Writer.Error)![]u8 {
    try validate_vision_result(result);

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll("{\"images\":[");
    for (result.images, 0..) |image, index| {
        if (index > 0) try out.writer.writeByte(',');
        try out.writer.print("{{\"image_id\":{d},", .{image.image_id});
        switch (image.outcome) {
            .ok => |evidence| {
                try out.writer.writeAll("\"status\":\"ok\",\"summary\":");
                try std.json.Stringify.value(evidence.summary, .{}, &out.writer);
                try out.writer.writeAll(",\"visible_text\":");
                try std.json.Stringify.value(evidence.visible_text, .{}, &out.writer);
                try out.writer.writeAll(",\"details\":");
                try std.json.Stringify.value(evidence.details, .{}, &out.writer);
            },
            .failed => |failure| {
                try out.writer.writeAll("\"status\":\"failed\",\"error\":");
                try write_failure_diagnostic(&out.writer, failure);
            },
        }
        try out.writer.writeByte('}');
    }
    try out.writer.writeAll("]}");
    return try out.toOwnedSlice();
}

fn write_failure_diagnostic(
    writer: *std.Io.Writer,
    failure: VisionFailure,
) std.Io.Writer.Error!void {
    try writer.writeAll("{\"code\":");
    try std.json.Stringify.value(@tagName(failure.code()), .{}, writer);
    try writer.writeAll(",\"message\":");
    switch (failure) {
        .image_unavailable => try std.json.Stringify.value(
            "Vision could not safely load or verify this image.",
            .{},
            writer,
        ),
        .provider_response_invalid => try std.json.Stringify.value(
            "Vision received an invalid provider response after one retry.",
            .{},
            writer,
        ),
        .output_limit_exceeded => |limit| try writer.print(
            "\"Vision produced {d} bytes; the configured budget is {d} bytes.\"",
            .{ limit.observed_bytes, limit.configured_bytes },
        ),
        .vision_unavailable => try std.json.Stringify.value(
            "Vision could not obtain a usable provider response.",
            .{},
            writer,
        ),
        .missing_provider_record => try std.json.Stringify.value(
            "Vision returned no record for this image.",
            .{},
            writer,
        ),
    }
    try writer.writeAll(",\"retryable\":");
    try writer.writeAll(if (failure.retryable()) "true" else "false");
    try writer.writeAll(",\"suggestion\":");
    try std.json.Stringify.value(failure.suggestion(), .{}, writer);
    try writer.writeByte('}');
}

/// Projects only stable attachment IDs. The caller owns the returned bytes.
pub fn project_image_references(
    alloc: Allocator,
    catalog: []const types.ImageAttachment,
) (Allocator.Error || error{ InvalidImageId, InvalidImageCatalog } || std.Io.Writer.Error)![]u8 {
    if (!image_attachments.imageAttachmentsSortedById(catalog)) {
        return error.InvalidImageCatalog;
    }

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll("<available_images>");
    for (catalog) |attachment| {
        if (attachment.id == 0) return error.InvalidImageId;
        try out.writer.writeByte('\n');
        try image_attachments.writeImagePlaceholder(&out.writer, attachment.id);
    }
    if (catalog.len > 0) try out.writer.writeByte('\n');
    try out.writer.writeAll("</available_images>");
    return try out.toOwnedSlice();
}

/// Projects an eligible text-only request without carrying filesystem-backed
/// image parts. Every authorized stable ID is attached to the current root user
/// message as a compact reference list. Returned storage belongs to `alloc`.
pub noinline fn project_text_only_messages(
    alloc: Allocator,
    messages: []const types.ChatMessage,
    current_user_message_index: usize,
    catalog: []const types.ImageAttachment,
) ![]types.ChatMessage {
    const projected = try alloc.dupe(types.ChatMessage, messages);
    errdefer alloc.free(projected);
    for (projected) |*chat_message| chat_message.images = &.{};
    if (catalog.len == 0) return projected;

    if (current_user_message_index >= projected.len or
        projected[current_user_message_index].role != .user or
        projected[current_user_message_index].permission_feedback)
    {
        return error.MissingUserMessage;
    }
    const references = try project_image_references(alloc, catalog);
    defer alloc.free(references);
    const content = projected[current_user_message_index].content orelse "";
    projected[current_user_message_index].content = if (content.len == 0)
        try alloc.dupe(u8, references)
    else
        try std.fmt.allocPrint(alloc, "{s}\n\n{s}", .{ content, references });
    return projected;
}

/// Produces arena-scoped native-route messages with raw images. Retains only
/// root-turn Vision calls followed by contiguous structured route rejections.
/// Canonical history is unchanged.
pub noinline fn project_native_messages(
    alloc: Allocator,
    messages: []const types.ChatMessage,
    current_user_message_index: usize,
) Allocator.Error![]const types.ChatMessage {
    std.debug.assert(current_user_message_index < messages.len);
    std.debug.assert(messages[current_user_message_index].role == .user);

    var contains_vision = false;
    for (messages) |chat_message| {
        if (std.mem.eql(u8, chat_message.tool_name orelse "", "vision")) {
            contains_vision = true;
            break;
        }
        for (chat_message.tool_calls) |call| {
            if (std.mem.eql(u8, call.name, "vision")) {
                contains_vision = true;
                break;
            }
        }
        if (contains_vision) break;
    }
    if (!contains_vision) return messages;

    var projected: std.ArrayList(types.ChatMessage) = .empty;
    errdefer projected.deinit(alloc);
    var filtered_call_slices: std.ArrayList([]types.ToolCall) = .empty;
    defer filtered_call_slices.deinit(alloc);
    errdefer for (filtered_call_slices.items) |calls| alloc.free(calls);

    for (messages, 0..) |chat_message, message_index| {
        if (chat_message.role == .tool and
            std.mem.eql(u8, chat_message.tool_name orelse "", "vision") and
            !(message_index >= current_user_message_index and
                is_paired_native_route_rejection_result(messages, message_index)))
        {
            continue;
        }

        var projected_message = chat_message;
        var vision_call_count: usize = 0;
        for (chat_message.tool_calls, 0..) |call, call_index| {
            if (std.mem.eql(u8, call.name, "vision") and
                !(message_index >= current_user_message_index and
                    native_route_rejection_result_index(
                        messages,
                        message_index,
                        call_index,
                    ) != null))
            {
                vision_call_count += 1;
            }
        }
        if (vision_call_count > 0) {
            const retained_count = chat_message.tool_calls.len - vision_call_count;
            if (retained_count == 0) {
                projected_message.tool_calls = &.{};
                if (projected_message.content == null or projected_message.content.?.len == 0) {
                    continue;
                }
            } else {
                const retained = try alloc.alloc(types.ToolCall, retained_count);
                errdefer alloc.free(retained);
                try filtered_call_slices.append(alloc, retained);
                var retained_index: usize = 0;
                for (chat_message.tool_calls, 0..) |call, call_index| {
                    if (std.mem.eql(u8, call.name, "vision") and
                        !(message_index >= current_user_message_index and
                            native_route_rejection_result_index(
                                messages,
                                message_index,
                                call_index,
                            ) != null))
                    {
                        continue;
                    }
                    retained[retained_index] = call;
                    retained_index += 1;
                }
                projected_message.tool_calls = retained;
            }
        }
        try projected.append(alloc, projected_message);
    }
    return projected.toOwnedSlice(alloc);
}

fn is_native_route_rejection(message: types.ChatMessage) bool {
    const content = message.content orelse "";
    return tool_result_errors.isToolExecutionFailedOutput(content) and std.mem.find(
        u8,
        content,
        native_route_unavailable_message,
    ) != null;
}

fn native_route_rejection_result_index(
    messages: []const types.ChatMessage,
    assistant_message_index: usize,
    call_index: usize,
) ?usize {
    if (assistant_message_index >= messages.len) return null;
    const assistant_message = messages[assistant_message_index];
    if (assistant_message.role != .assistant or call_index >= assistant_message.tool_calls.len) {
        return null;
    }
    const call = assistant_message.tool_calls[call_index];
    if (!std.mem.eql(u8, call.name, "vision")) return null;

    var result_index = assistant_message_index + 1;
    while (result_index < messages.len and messages[result_index].role == .tool) : (result_index += 1) {
        const result = messages[result_index];
        if (std.mem.eql(u8, result.tool_name orelse "", "vision") and
            std.mem.eql(u8, result.tool_call_id orelse "", call.id) and
            is_native_route_rejection(result))
        {
            return result_index;
        }
    }
    return null;
}

fn is_paired_native_route_rejection_result(
    messages: []const types.ChatMessage,
    result_index: usize,
) bool {
    if (result_index >= messages.len or messages[result_index].role != .tool) return false;

    var block_start = result_index;
    while (block_start > 0 and messages[block_start - 1].role == .tool) {
        block_start -= 1;
    }
    if (block_start == 0) return false;
    const assistant_message_index = block_start - 1;
    const assistant_message = messages[assistant_message_index];
    if (assistant_message.role != .assistant) return false;

    for (assistant_message.tool_calls, 0..) |_, call_index| {
        if (native_route_rejection_result_index(
            messages,
            assistant_message_index,
            call_index,
        ) == result_index) return true;
    }
    return false;
}

pub const VisionBatchIterator = struct {
    image_ids: []const usize,
    offset: usize = 0,

    pub fn init(image_ids: []const usize) VisionBatchIterator {
        return .{ .image_ids = image_ids };
    }

    pub fn next(self: *VisionBatchIterator) ?[]const usize {
        if (self.offset >= self.image_ids.len) return null;
        const remaining = self.image_ids.len - self.offset;
        const batch_len = @min(remaining, max_provider_images_per_batch);
        const batch = self.image_ids[self.offset .. self.offset + batch_len];
        self.offset += batch_len;
        return batch;
    }
};

pub const VisionRoute = enum {
    native_images,
    text_only,
};

pub const VisionGate = enum {
    vision_required,
    unrestricted,
};

pub const VisionAttempt = union(enum) {
    start,
    valid: []const usize,
    malformed,
    unauthorized,
    cancelled,
};

pub const PendingTransitionDisposition = enum {
    unchanged,
    settled,
    rejected_malformed,
    rejected_unauthorized,
    cancelled,
    not_applicable,
};

pub const PendingImageTransition = struct {
    pending_ids: []usize,
    gate: VisionGate,
    disposition: PendingTransitionDisposition,

    pub fn deinit(self: PendingImageTransition, alloc: Allocator) void {
        if (self.pending_ids.len > 0) alloc.free(self.pending_ids);
    }
};

pub fn transition_pending_images(
    alloc: Allocator,
    route: VisionRoute,
    pending_ids: []const usize,
    attempt: VisionAttempt,
) (Allocator.Error || error{ EmptyImageIds, InvalidImageId, DuplicateImageId })!PendingImageTransition {
    if (pending_ids.len > 0) try image_attachments.validate_image_ids(pending_ids);
    if (route == .native_images) {
        return .{
            .pending_ids = try dupe_ids(alloc, pending_ids),
            .gate = .unrestricted,
            .disposition = .not_applicable,
        };
    }

    return switch (attempt) {
        .start => unchanged_pending_transition(alloc, pending_ids, .unchanged),
        .malformed => unchanged_pending_transition(alloc, pending_ids, .rejected_malformed),
        .unauthorized => unchanged_pending_transition(alloc, pending_ids, .rejected_unauthorized),
        .cancelled => unchanged_pending_transition(alloc, pending_ids, .cancelled),
        .valid => |settled_ids| blk: {
            try image_attachments.validate_image_ids(settled_ids);
            var remaining_count: usize = 0;
            for (pending_ids) |pending_id| {
                if (!contains_image_id(settled_ids, pending_id)) remaining_count += 1;
            }
            if (remaining_count == 0) {
                break :blk .{
                    .pending_ids = &.{},
                    .gate = .unrestricted,
                    .disposition = .settled,
                };
            }
            const remaining = try alloc.alloc(usize, remaining_count);
            var index: usize = 0;
            for (pending_ids) |pending_id| {
                if (contains_image_id(settled_ids, pending_id)) continue;
                remaining[index] = pending_id;
                index += 1;
            }
            break :blk .{
                .pending_ids = remaining,
                .gate = .vision_required,
                .disposition = .settled,
            };
        },
    };
}

fn exact_object(value: std.json.Value, keys: []const []const u8) ?std.json.ObjectMap {
    if (value != .object or value.object.count() != keys.len) return null;
    var iterator = value.object.iterator();
    while (iterator.next()) |entry| {
        var known = false;
        for (keys) |key| {
            if (std.mem.eql(u8, entry.key_ptr.*, key)) {
                known = true;
                break;
            }
        }
        if (!known) return null;
    }
    return value.object;
}

fn parse_image_id(value: std.json.Value) error{InvalidImageId}!usize {
    if (value != .integer or value.integer <= 0) return error.InvalidImageId;
    return std.math.cast(usize, value.integer) orelse error.InvalidImageId;
}

fn parse_image_result(
    alloc: Allocator,
    value: std.json.Value,
) (Allocator.Error || VisionResultError)!VisionImageResult {
    if (value != .object) return error.InvalidVisionResult;
    const status_value = value.object.get("status") orelse return error.InvalidVisionResult;
    if (status_value != .string) return error.InvalidVisionResult;

    if (std.mem.eql(u8, status_value.string, "ok")) {
        const object = exact_object(
            value,
            &.{ "image_id", "status", "summary", "visible_text", "details" },
        ) orelse return error.InvalidVisionResult;
        return .{
            .image_id = try parse_image_id(object.get("image_id") orelse return error.InvalidVisionResult),
            .outcome = .{ .ok = try parse_evidence(alloc, object) },
        };
    }
    if (std.mem.eql(u8, status_value.string, "failed")) {
        const object = exact_object(value, &.{ "image_id", "status", "error" }) orelse
            return error.InvalidVisionResult;
        const failure_value = object.get("error") orelse return error.InvalidVisionResult;
        if (failure_value != .string) return error.InvalidVisionResult;
        if (!std.mem.eql(u8, failure_value.string, "vision_unavailable")) {
            return error.InvalidVisionResult;
        }
        return .{
            .image_id = try parse_image_id(object.get("image_id") orelse return error.InvalidVisionResult),
            .outcome = .{ .failed = .vision_unavailable },
        };
    }
    return error.InvalidVisionResult;
}

fn parse_evidence(
    alloc: Allocator,
    object: std.json.ObjectMap,
) (Allocator.Error || VisionResultError)!ImageEvidence {
    const summary_value = object.get("summary") orelse return error.InvalidVisionResult;
    const summary = try dupe_evidence_string(alloc, summary_value, true);
    errdefer alloc.free(summary);
    const visible_text = try parse_evidence_list(
        alloc,
        object.get("visible_text") orelse return error.InvalidVisionResult,
    );
    errdefer free_owned_strings(alloc, visible_text);
    return .{
        .summary = summary,
        .visible_text = visible_text,
        .details = try parse_evidence_list(
            alloc,
            object.get("details") orelse return error.InvalidVisionResult,
        ),
    };
}

fn parse_evidence_list(
    alloc: Allocator,
    value: std.json.Value,
) (Allocator.Error || VisionResultError)![][]u8 {
    if (value != .array) return error.InvalidVisionResult;
    if (value.array.items.len == 0) return &.{};

    const items = try alloc.alloc([]u8, value.array.items.len);
    errdefer alloc.free(items);
    var copied: usize = 0;
    errdefer for (items[0..copied]) |item| alloc.free(item);
    for (value.array.items, 0..) |item, index| {
        items[index] = try dupe_evidence_string(alloc, item, false);
        copied += 1;
    }
    return items;
}

fn dupe_evidence_string(
    alloc: Allocator,
    value: std.json.Value,
    require_nonempty: bool,
) (Allocator.Error || VisionResultError)![]u8 {
    if (value != .string) return error.InvalidVisionResult;
    if (!std.unicode.utf8ValidateSlice(value.string)) return error.InvalidVisionResult;
    if (require_nonempty and std.mem.trim(u8, value.string, " \t\r\n").len == 0) {
        return error.InvalidVisionResult;
    }
    return alloc.dupe(u8, value.string);
}

fn validate_vision_result(result: VisionResult) VisionResultError!void {
    for (result.images, 0..) |image, index| {
        try validate_result_record(image);
        for (result.images[0..index]) |previous| {
            if (previous.image_id == image.image_id) return error.DuplicateImageId;
        }
    }
}

fn validate_result_record(record: VisionImageResult) VisionResultError!void {
    if (record.image_id == 0) return error.InvalidImageId;
    switch (record.outcome) {
        .ok => |evidence| {
            try validate_evidence_string(evidence.summary, true);
            try validate_evidence_strings(evidence.visible_text);
            try validate_evidence_strings(evidence.details);
        },
        .failed => |failure| switch (failure) {
            .output_limit_exceeded => |limit| {
                if (limit.observed_bytes <= limit.configured_bytes) {
                    return error.InvalidVisionResult;
                }
            },
            else => {},
        },
    }
}

fn validate_evidence_strings(items: []const []u8) VisionResultError!void {
    for (items) |item| try validate_evidence_string(item, false);
}

fn validate_evidence_string(value: []const u8, require_nonempty: bool) VisionResultError!void {
    if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidVisionResult;
    if (require_nonempty and std.mem.trim(u8, value, " \t\r\n").len == 0) {
        return error.InvalidVisionResult;
    }
}

fn dupe_result_record(alloc: Allocator, record: VisionImageResult) Allocator.Error!VisionImageResult {
    return .{
        .image_id = record.image_id,
        .outcome = switch (record.outcome) {
            .failed => |failure| .{ .failed = failure },
            .ok => |evidence| .{ .ok = try dupe_evidence(alloc, evidence) },
        },
    };
}

fn dupe_evidence(alloc: Allocator, evidence: ImageEvidence) Allocator.Error!ImageEvidence {
    const summary = try alloc.dupe(u8, evidence.summary);
    errdefer alloc.free(summary);
    const visible_text = try dupe_strings(alloc, evidence.visible_text);
    errdefer free_owned_strings(alloc, visible_text);
    return .{
        .summary = summary,
        .visible_text = visible_text,
        .details = try dupe_strings(alloc, evidence.details),
    };
}

fn dupe_strings(alloc: Allocator, strings: []const []u8) Allocator.Error![][]u8 {
    if (strings.len == 0) return &.{};
    const copy = try alloc.alloc([]u8, strings.len);
    errdefer alloc.free(copy);
    var copied: usize = 0;
    errdefer for (copy[0..copied]) |item| alloc.free(item);
    for (strings, 0..) |item, index| {
        copy[index] = try alloc.dupe(u8, item);
        copied += 1;
    }
    return copy;
}

fn free_owned_strings(alloc: Allocator, strings: [][]u8) void {
    for (strings) |string| alloc.free(string);
    if (strings.len > 0) alloc.free(strings);
}

fn find_result_record(records: []const VisionImageResult, image_id: usize) ?VisionImageResult {
    for (records) |record| {
        if (record.image_id == image_id) return record;
    }
    return null;
}

fn contains_image_id(image_ids: []const usize, image_id: usize) bool {
    for (image_ids) |candidate| {
        if (candidate == image_id) return true;
    }
    return false;
}

fn dupe_ids(alloc: Allocator, image_ids: []const usize) Allocator.Error![]usize {
    if (image_ids.len == 0) return &.{};
    return alloc.dupe(usize, image_ids);
}

fn unchanged_pending_transition(
    alloc: Allocator,
    pending_ids: []const usize,
    disposition: PendingTransitionDisposition,
) Allocator.Error!PendingImageTransition {
    return .{
        .pending_ids = try dupe_ids(alloc, pending_ids),
        .gate = if (pending_ids.len == 0) .unrestricted else .vision_required,
        .disposition = disposition,
    };
}

fn test_ok_result(image_id: usize) VisionImageResult {
    return .{
        .image_id = image_id,
        .outcome = .{ .ok = .{
            .summary = @constCast("verified image evidence"),
            .visible_text = &.{},
            .details = &.{},
        } },
    };
}

const max_fuzz_input_bytes: usize = 20 * 1024;

fn fuzz_vision_json(_: void, smith: *std.testing.Smith) !void {
    var buffer: [max_fuzz_input_bytes + 1]u8 = undefined;
    const len = smith.slice(&buffer);
    const bytes = buffer[0..len];

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    if (parse_vision_request(arena, bytes)) |request| {
        request.deinit(arena);
    } else |_| {}
    if (parse_vision_provider_result(arena, bytes, max_fuzz_input_bytes)) |result| {
        result.deinit(arena);
    } else |_| {}
}

test "Vision JSON parsers tolerate arbitrary bounded bytes" {
    try std.testing.fuzz({}, fuzz_vision_json, .{
        .corpus = &.{
            "{\"image_ids\":[1],\"focus\":\"inspect\"}",
            "{\"images\":[{\"image_id\":1,\"status\":\"failed\",\"error\":\"vision_unavailable\"}]}",
            "{",
        },
    });
}

test "Vision request parsing preserves ordered ids and bounded focus" {
    const request = try parse_vision_request(
        std.testing.allocator,
        "{\"image_ids\":[9,2,7],\"focus\":\"Read the highlighted error\"}",
    );
    defer request.deinit(std.testing.allocator);

    try std.testing.expectEqualSlices(usize, &.{ 9, 2, 7 }, request.image_ids().?);
    try std.testing.expectEqualStrings("Read the highlighted error", request.focus);
}

test "Vision request parsing preserves ordered image paths" {
    const request = try parse_vision_request(
        std.testing.allocator,
        "{\"paths\":[\"~/Desktop/test.png\",\"screenshots/result.webp\"],\"focus\":\"Read the error\"}",
    );
    defer request.deinit(std.testing.allocator);

    const paths = request.paths().?;
    try std.testing.expectEqual(@as(usize, 2), paths.len);
    try std.testing.expectEqualStrings("~/Desktop/test.png", paths[0]);
    try std.testing.expectEqualStrings("screenshots/result.webp", paths[1]);
    try std.testing.expectEqualStrings("Read the error", request.focus);
}

test "Vision request parsing rejects duplicate malformed and nonexact arguments" {
    try std.testing.expectError(
        error.DuplicateImageId,
        parse_vision_request(std.testing.allocator, "{\"image_ids\":[1,1],\"focus\":\"compare\"}"),
    );
    try std.testing.expectError(
        error.InvalidImageId,
        parse_vision_request(std.testing.allocator, "{\"image_ids\":[0],\"focus\":\"compare\"}"),
    );
    try std.testing.expectError(
        error.InvalidVisionRequest,
        parse_vision_request(std.testing.allocator, "{\"image_ids\":[1],\"focus\":\"compare\",\"path\":\"/tmp/private.png\"}"),
    );
    try std.testing.expectError(
        error.InvalidVisionJson,
        parse_vision_request(std.testing.allocator, "{\"image_ids\":[1],"),
    );
}

test "Vision request parsing enforces nonempty ids and focus bounds" {
    try std.testing.expectError(
        error.EmptyImageIds,
        parse_vision_request(std.testing.allocator, "{\"image_ids\":[],\"focus\":\"compare\"}"),
    );
    try std.testing.expectError(
        error.EmptyFocus,
        parse_vision_request(std.testing.allocator, "{\"image_ids\":[1],\"focus\":\"  \\n\\t\"}"),
    );
    try std.testing.expectError(
        error.FocusTooLong,
        parse_vision_request(
            std.testing.allocator,
            "{\"image_ids\":[1],\"focus\":\"" ++ ("x" ** (max_focus_bytes + 1)) ++ "\"}",
        ),
    );
}

test "Vision request parsing requires exactly one nonempty source" {
    try std.testing.expectError(
        error.EmptyPaths,
        parse_vision_request(std.testing.allocator, "{\"paths\":[],\"focus\":\"inspect\"}"),
    );
    try std.testing.expectError(
        error.InvalidImagePath,
        parse_vision_request(std.testing.allocator, "{\"paths\":[\"  \"],\"focus\":\"inspect\"}"),
    );
    try std.testing.expectError(
        error.DuplicateImagePath,
        parse_vision_request(std.testing.allocator, "{\"paths\":[\"a.png\",\"a.png\"],\"focus\":\"inspect\"}"),
    );
    try std.testing.expectError(
        error.InvalidVisionRequest,
        parse_vision_request(std.testing.allocator, "{\"image_ids\":[1],\"paths\":[\"a.png\"],\"focus\":\"inspect\"}"),
    );
}

test "Vision provider parsing is strict and validates every evidence field" {
    const provider_json =
        "{\"images\":[{\"image_id\":3,\"status\":\"ok\",\"summary\":\"terminal screenshot\",\"visible_text\":[\"error: failed\"],\"details\":[\"red underline\"]},{\"image_id\":4,\"status\":\"failed\",\"error\":\"vision_unavailable\"}]}";
    const parsed = try parse_vision_provider_result(
        std.testing.allocator,
        provider_json,
        provider_json.len,
    );
    defer parsed.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), parsed.images.len);
    try std.testing.expectEqual(@as(usize, 3), parsed.images[0].image_id);
    try std.testing.expectEqualStrings("terminal screenshot", parsed.images[0].outcome.ok.summary);
    try std.testing.expectEqual(
        FailureCode.vision_unavailable,
        parsed.images[1].outcome.failed.code(),
    );

    const path_json =
        "{\"images\":[{\"image_id\":3,\"status\":\"ok\",\"summary\":\"ok\",\"visible_text\":[],\"details\":[],\"path\":\"/tmp/private.png\"}]}";
    try std.testing.expectError(
        error.InvalidVisionResult,
        parse_vision_provider_result(
            std.testing.allocator,
            path_json,
            path_json.len,
        ),
    );
}

test "Vision provider parsing accepts forty evidence items within the total byte limit" {
    var json: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer json.deinit();
    try json.writer.writeAll(
        "{\"images\":[{\"image_id\":3,\"status\":\"ok\",\"summary\":\"dense screenshot\",\"visible_text\":[",
    );
    for (0..40) |index| {
        if (index > 0) try json.writer.writeByte(',');
        try json.writer.print("\"item-{d}\"", .{index});
    }
    try json.writer.writeAll("],\"details\":[]}]}");

    const parsed = try parse_vision_provider_result(
        std.testing.allocator,
        json.written(),
        json.written().len,
    );
    defer parsed.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 40), parsed.images[0].outcome.ok.visible_text.len);
    try std.testing.expectEqualStrings("item-39", parsed.images[0].outcome.ok.visible_text[39]);
}

test "Vision provider parsing accepts one long evidence string within the total byte limit" {
    const provider_json =
        "{\"images\":[{\"image_id\":3,\"status\":\"ok\",\"summary\":\"long text\",\"visible_text\":[\"" ++
        ("x" ** 5000) ++
        "\"],\"details\":[]}]}";
    const parsed = try parse_vision_provider_result(
        std.testing.allocator,
        provider_json,
        provider_json.len,
    );
    defer parsed.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 5000), parsed.images[0].outcome.ok.visible_text[0].len);
}

test "Vision result serialization emits the five fx-owned diagnostics" {
    const Case = struct {
        failure: VisionFailure,
        expected: []const u8,
    };
    const cases = [_]Case{
        .{
            .failure = .image_unavailable,
            .expected = "{\"images\":[{\"image_id\":7,\"status\":\"failed\",\"error\":{\"code\":\"image_unavailable\",\"message\":\"Vision could not safely load or verify this image.\",\"retryable\":false,\"suggestion\":\"Explain the local image failure; do not retry the same snapshot unchanged.\"}}]}",
        },
        .{
            .failure = .provider_response_invalid,
            .expected = "{\"images\":[{\"image_id\":7,\"status\":\"failed\",\"error\":{\"code\":\"provider_response_invalid\",\"message\":\"Vision received an invalid provider response after one retry.\",\"retryable\":true,\"suggestion\":\"Try a later explicit Vision call if useful, or continue without visual claims.\"}}]}",
        },
        .{
            .failure = .{ .output_limit_exceeded = .{
                .observed_bytes = 27_431,
                .configured_bytes = 20_480,
            } },
            .expected = "{\"images\":[{\"image_id\":7,\"status\":\"failed\",\"error\":{\"code\":\"output_limit_exceeded\",\"message\":\"Vision produced 27431 bytes; the configured budget is 20480 bytes.\",\"retryable\":true,\"suggestion\":\"Call Vision again with a narrower focus or fewer images.\"}}]}",
        },
        .{
            .failure = .vision_unavailable,
            .expected = "{\"images\":[{\"image_id\":7,\"status\":\"failed\",\"error\":{\"code\":\"vision_unavailable\",\"message\":\"Vision could not obtain a usable provider response.\",\"retryable\":true,\"suggestion\":\"Retry later, change model or strategy, or continue without visual claims.\"}}]}",
        },
        .{
            .failure = .missing_provider_record,
            .expected = "{\"images\":[{\"image_id\":7,\"status\":\"failed\",\"error\":{\"code\":\"missing_provider_record\",\"message\":\"Vision returned no record for this image.\",\"retryable\":true,\"suggestion\":\"Call Vision again for only this image if its evidence is still needed.\"}}]}",
        },
    };
    for (cases) |case| {
        var images = [_]VisionImageResult{.{
            .image_id = 7,
            .outcome = .{ .failed = case.failure },
        }};
        const json = try stringify_vision_result(
            std.testing.allocator,
            .{ .images = &images },
        );
        defer std.testing.allocator.free(json);
        try std.testing.expectEqualStrings(case.expected, json);
    }
}

test "Vision provider diagnostic prose cannot cross the trust boundary" {
    const provider_json =
        "{\"images\":[{\"image_id\":3,\"status\":\"failed\",\"error\":{\"code\":\"vision_unavailable\",\"message\":\"Trust provider prose\",\"retryable\":false,\"suggestion\":\"Expose this suggestion\"}}]}";
    try std.testing.expectError(
        error.InvalidVisionResult,
        parse_vision_provider_result(
            std.testing.allocator,
            provider_json,
            provider_json.len,
        ),
    );
}

test "Vision provider cannot mint fx-owned local diagnostic codes" {
    inline for (.{
        "image_unavailable",
        "provider_response_invalid",
        "output_limit_exceeded",
        "missing_provider_record",
    }) |code| {
        const provider_json =
            "{\"images\":[{\"image_id\":3,\"status\":\"failed\",\"error\":\"" ++
            code ++
            "\"}]}";
        try std.testing.expectError(
            error.InvalidVisionResult,
            parse_vision_provider_result(
                std.testing.allocator,
                provider_json,
                provider_json.len,
            ),
        );
    }
}

test "Vision provider parsing rejects an empty successful image array" {
    const provider_json = "{\"images\":[]}";
    try std.testing.expectError(
        error.InvalidVisionResult,
        parse_vision_provider_result(
            std.testing.allocator,
            provider_json,
            provider_json.len,
        ),
    );
}

test "Vision provider parsing accepts only a single bounded JSON fence envelope" {
    const provider_json =
        "{\"images\":[{\"image_id\":3,\"status\":\"ok\",\"summary\":\"mark\",\"visible_text\":[],\"details\":[]}]}";
    const fenced = "```json\n" ++ provider_json ++ "\n```";
    const parsed = try parse_vision_provider_result(
        std.testing.allocator,
        fenced,
        fenced.len,
    );
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), parsed.images.len);
    try std.testing.expectEqualStrings("mark", parsed.images[0].outcome.ok.summary);

    const with_prose = fenced ++ "\nextra";
    try std.testing.expectError(
        error.InvalidVisionJson,
        parse_vision_provider_result(
            std.testing.allocator,
            with_prose,
            with_prose.len,
        ),
    );
    try std.testing.expectError(
        error.ProviderResultTooLarge,
        parse_vision_provider_result(
            std.testing.allocator,
            fenced,
            fenced.len - 1,
        ),
    );
}

test "Vision provider parsing obeys the supplied result byte limit" {
    const provider_json =
        "{\"images\":[{\"image_id\":3,\"status\":\"failed\",\"error\":\"vision_unavailable\"}]}";
    const parsed = try parse_vision_provider_result(
        std.testing.allocator,
        provider_json,
        provider_json.len,
    );
    defer parsed.deinit(std.testing.allocator);

    try std.testing.expectError(
        error.ProviderResultTooLarge,
        parse_vision_provider_result(
            std.testing.allocator,
            provider_json,
            provider_json.len - 1,
        ),
    );
}

test "Vision provider parsing has no hidden twenty kibibyte ceiling" {
    const evidence_chunk_bytes = 4096;
    const large_provider_json =
        "{\"images\":[{\"image_id\":3,\"status\":\"ok\",\"summary\":\"ok\",\"visible_text\":[\"" ++
        ("x" ** evidence_chunk_bytes) ++
        "\",\"" ++
        ("x" ** evidence_chunk_bytes) ++
        "\",\"" ++
        ("x" ** evidence_chunk_bytes) ++
        "\",\"" ++
        ("x" ** evidence_chunk_bytes) ++
        "\",\"" ++
        ("x" ** evidence_chunk_bytes) ++
        "\",\"" ++
        ("x" ** evidence_chunk_bytes) ++
        "\"],\"details\":[]}]}";
    try std.testing.expect(large_provider_json.len > 20 * 1024);

    const parsed = try parse_vision_provider_result(
        std.testing.allocator,
        large_provider_json,
        large_provider_json.len,
    );
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), parsed.images.len);
}

test "Vision omission preserves sibling evidence and synthesizes an ordered diagnostic" {
    const provider_records = [_]VisionImageResult{
        test_ok_result(3),
        test_ok_result(1),
    };
    const merged = try merge_vision_results(
        std.testing.allocator,
        &.{ 1, 2, 3 },
        &provider_records,
    );
    defer merged.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), merged.images.len);
    try std.testing.expectEqual(@as(usize, 1), merged.images[0].image_id);
    try std.testing.expectEqualStrings(
        "verified image evidence",
        merged.images[0].outcome.ok.summary,
    );
    try std.testing.expectEqual(@as(usize, 2), merged.images[1].image_id);
    try std.testing.expectEqual(
        FailureCode.missing_provider_record,
        merged.images[1].outcome.failed.code(),
    );
    try std.testing.expectEqual(@as(usize, 3), merged.images[2].image_id);
}

test "Vision merge preserves nineteen successes and one failure" {
    var requested: [20]usize = undefined;
    var provider_records: [20]VisionImageResult = undefined;
    for (&requested, &provider_records, 0..) |*image_id, *record, index| {
        image_id.* = index + 1;
        record.* = if (index == 12)
            .{ .image_id = index + 1, .outcome = .{ .failed = .vision_unavailable } }
        else
            test_ok_result(index + 1);
    }

    const merged = try merge_vision_results(std.testing.allocator, &requested, &provider_records);
    defer merged.deinit(std.testing.allocator);

    var successes: usize = 0;
    var failures: usize = 0;
    for (merged.images) |record| switch (record.outcome) {
        .ok => successes += 1,
        .failed => failures += 1,
    };
    try std.testing.expectEqual(@as(usize, 19), successes);
    try std.testing.expectEqual(@as(usize, 1), failures);
}

test "Vision batching partitions twenty ids deterministically and merge keeps cardinality" {
    var requested: [20]usize = undefined;
    var provider_records: [20]VisionImageResult = undefined;
    for (&requested, &provider_records, 0..) |*image_id, *record, index| {
        image_id.* = index + 1;
        record.* = test_ok_result(index + 1);
    }

    var batches = VisionBatchIterator.init(&requested);
    try std.testing.expectEqualSlices(usize, requested[0..8], batches.next().?);
    try std.testing.expectEqualSlices(usize, requested[8..16], batches.next().?);
    try std.testing.expectEqualSlices(usize, requested[16..20], batches.next().?);
    try std.testing.expect(batches.next() == null);

    const merged = try merge_vision_results(std.testing.allocator, &requested, &provider_records);
    defer merged.deinit(std.testing.allocator);
    try std.testing.expectEqual(requested.len, merged.images.len);
    for (merged.images, requested) |record, image_id| {
        try std.testing.expectEqual(image_id, record.image_id);
    }
}

test "Vision merge rejects duplicate and unauthorized provider ids" {
    const duplicate = [_]VisionImageResult{ test_ok_result(1), test_ok_result(1) };
    try std.testing.expectError(
        error.DuplicateImageId,
        merge_vision_results(std.testing.allocator, &.{ 1, 2 }, &duplicate),
    );

    const unauthorized = [_]VisionImageResult{test_ok_result(99)};
    try std.testing.expectError(
        error.UnauthorizedImageId,
        merge_vision_results(std.testing.allocator, &.{ 1, 2 }, &unauthorized),
    );
}

test "Vision references and result JSON expose ids without attachment paths" {
    const catalog = [_]types.ImageAttachment{
        .{ .id = 2, .path = @constCast("/tmp/private-two.png"), .media_type = @constCast("image/png") },
        .{ .id = 7, .path = @constCast("/Users/private/seven.jpg"), .media_type = @constCast("image/jpeg") },
    };
    const references = try project_image_references(std.testing.allocator, &catalog);
    defer std.testing.allocator.free(references);

    try std.testing.expect(std.mem.find(u8, references, "[Image #2]") != null);
    try std.testing.expect(std.mem.find(u8, references, "[Image #7]") != null);
    try std.testing.expect(std.mem.find(u8, references, "/tmp/private-two.png") == null);
    try std.testing.expect(std.mem.find(u8, references, "/Users/private/seven.jpg") == null);

    const result = VisionResult{ .images = @constCast(&[_]VisionImageResult{test_ok_result(2)}) };
    const json = try stringify_vision_result(std.testing.allocator, result);
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.find(u8, json, "\"image_id\":2") != null);
    try std.testing.expect(std.mem.find(u8, json, "path") == null);
}

test "text-only message projection removes raw images and exposes all authorized ids" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const catalog = [_]types.ImageAttachment{
        .{ .id = 2, .path = @constCast("/tmp/private-two.png"), .media_type = @constCast("image/png") },
        .{ .id = 7, .path = @constCast("/Users/private/seven.jpg"), .media_type = @constCast("image/jpeg") },
    };
    const messages = [_]types.ChatMessage{
        .{ .role = .system, .content = "system" },
        .{ .role = .user, .content = "inspect", .images = &catalog },
    };

    const projected = try project_text_only_messages(arena, &messages, 1, &catalog);
    try std.testing.expectEqual(messages.len, projected.len);
    for (projected) |chat_message| try std.testing.expectEqual(@as(usize, 0), chat_message.images.len);
    const content = projected[1].content.?;
    try std.testing.expect(std.mem.find(u8, content, "[Image #2]") != null);
    try std.testing.expect(std.mem.find(u8, content, "[Image #7]") != null);
    try std.testing.expect(std.mem.find(u8, content, "/tmp/private-two.png") == null);
    try std.testing.expect(std.mem.find(u8, content, "/Users/private/seven.jpg") == null);
}

test "text-only projection preserves typed permission feedback byte-exact" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const catalog = [_]types.ImageAttachment{.{
        .id = 1,
        .path = @constCast("/tmp/private.png"),
        .media_type = @constCast("image/png"),
    }};
    const feedback = "Do not modify any more files.";
    const messages = [_]types.ChatMessage{
        .{ .role = .user, .content = "Make the requested changes.", .images = &catalog },
        .{ .role = .assistant, .content = "I need permission." },
        .{ .role = .tool, .content = "read result", .tool_call_id = "read", .tool_name = "read_file" },
        .{ .role = .user, .content = feedback, .permission_feedback = true },
    };

    const projected = try project_text_only_messages(arena, &messages, 0, &catalog);

    try std.testing.expectEqualStrings(feedback, projected[3].content.?);
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, projected[0].content.?, "<available_images>"),
    );
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(
        u8,
        projected[3].content.?,
        "<available_images>",
    ));
    try std.testing.expectEqualStrings(feedback, messages[3].content.?);
    try std.testing.expectEqualStrings("Make the requested changes.", messages[0].content.?);
}

test "native message projection retains only the current turn structured rejection" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const images = [_]types.ImageAttachment{.{
        .id = 2,
        .path = @constCast("/tmp/native.png"),
        .media_type = @constCast("image/png"),
    }};
    const historical_calls = [_]types.ToolCall{
        .{ .id = "historical-success", .name = "vision", .arguments_json = "{}" },
        .{ .id = "read-call", .name = "read_file", .arguments_json = "{}" },
    };
    const rejected_call = [_]types.ToolCall{
        .{ .id = "reused-call-id", .name = "vision", .arguments_json = "{}" },
    };
    const reused_success_call = [_]types.ToolCall{
        .{ .id = "reused-call-id", .name = "vision", .arguments_json = "{}" },
    };
    const rejection = try tool_result_errors.toolExecutionFailureJson(arena, .{
        .tool_name = "vision",
        .message = native_route_unavailable_message,
        .suggestion = "Continue using the model's native image input without Vision.",
    });
    const messages = [_]types.ChatMessage{
        .{ .role = .user, .content = "inspect", .images = &images },
        .{ .role = .assistant, .tool_calls = &historical_calls },
        .{ .role = .tool, .content = "historical vision evidence", .tool_call_id = "historical-success", .tool_name = "vision" },
        .{ .role = .tool, .content = "file evidence", .tool_call_id = "read-call", .tool_name = "read_file" },
        .{ .role = .user, .content = "recover now" },
        .{ .role = .assistant, .tool_calls = &rejected_call },
        .{ .role = .tool, .content = rejection, .tool_call_id = "reused-call-id", .tool_name = "vision" },
        .{ .role = .assistant, .content = "recovered" },
        .{ .role = .user, .content = "continue later" },
        .{ .role = .assistant, .tool_calls = &reused_success_call },
        .{ .role = .tool, .content = "current successful evidence", .tool_call_id = "reused-call-id", .tool_name = "vision" },
        .{ .role = .assistant, .content = "later answer" },
    };

    const immediate = try project_native_messages(arena, messages[0..8], 4);
    try std.testing.expectEqual(@as(usize, 7), immediate.len);
    try std.testing.expectEqual(@as(usize, 1), immediate[0].images.len);
    try std.testing.expectEqual(@as(usize, 1), immediate[1].tool_calls.len);
    try std.testing.expectEqualStrings("read_file", immediate[1].tool_calls[0].name);
    try std.testing.expectEqualStrings("read_file", immediate[2].tool_name.?);
    try std.testing.expectEqualStrings("vision", immediate[4].tool_calls[0].name);
    try std.testing.expectEqualStrings("reused-call-id", immediate[4].tool_calls[0].id);
    try std.testing.expectEqualStrings("vision", immediate[5].tool_name.?);
    try std.testing.expectEqualStrings("reused-call-id", immediate[5].tool_call_id.?);
    try std.testing.expectEqualStrings(rejection, immediate[5].content.?);

    const later = try project_native_messages(arena, &messages, 8);
    try std.testing.expectEqual(@as(usize, 7), later.len);
    try std.testing.expectEqual(@as(usize, 1), later[0].images.len);
    try std.testing.expectEqualStrings("read_file", later[1].tool_calls[0].name);
    try std.testing.expectEqualStrings("recover now", later[3].content.?);
    try std.testing.expectEqualStrings("recovered", later[4].content.?);
    try std.testing.expectEqualStrings("continue later", later[5].content.?);
    try std.testing.expectEqualStrings("later answer", later[6].content.?);
    for (later) |chat_message| {
        try std.testing.expect(!std.mem.eql(u8, chat_message.tool_name orelse "", "vision"));
        for (chat_message.tool_calls) |call| {
            try std.testing.expect(!std.mem.eql(u8, call.name, "vision"));
        }
    }

    const success_then_rejection_first_calls = [_]types.ToolCall{
        .{ .id = "success-then-rejection", .name = "vision", .arguments_json = "{}" },
        .{ .id = "first-read", .name = "read_file", .arguments_json = "{}" },
    };
    const success_then_rejection_second_calls = [_]types.ToolCall{
        .{ .id = "success-then-rejection", .name = "vision", .arguments_json = "{}" },
        .{ .id = "second-read", .name = "read_file", .arguments_json = "{}" },
    };
    const success_then_rejection_messages = [_]types.ChatMessage{
        .{ .role = .user, .content = "inspect two steps" },
        .{ .role = .assistant, .tool_calls = &success_then_rejection_first_calls },
        .{ .role = .tool, .content = "successful evidence", .tool_call_id = "success-then-rejection", .tool_name = "vision" },
        .{ .role = .tool, .content = "first file", .tool_call_id = "first-read", .tool_name = "read_file" },
        .{ .role = .assistant, .tool_calls = &success_then_rejection_second_calls },
        .{ .role = .tool, .content = rejection, .tool_call_id = "success-then-rejection", .tool_name = "vision" },
        .{ .role = .tool, .content = "second file", .tool_call_id = "second-read", .tool_name = "read_file" },
        .{ .role = .assistant, .content = "recovered after two steps" },
    };
    const success_then_rejection = try project_native_messages(
        arena,
        &success_then_rejection_messages,
        0,
    );
    try std.testing.expectEqual(@as(usize, 7), success_then_rejection.len);
    try std.testing.expectEqual(@as(usize, 1), success_then_rejection[1].tool_calls.len);
    try std.testing.expectEqualStrings("first-read", success_then_rejection[1].tool_calls[0].id);
    try std.testing.expectEqualStrings("first-read", success_then_rejection[2].tool_call_id.?);
    try std.testing.expectEqual(@as(usize, 2), success_then_rejection[3].tool_calls.len);
    try std.testing.expectEqualStrings("success-then-rejection", success_then_rejection[3].tool_calls[0].id);
    try std.testing.expectEqualStrings("second-read", success_then_rejection[3].tool_calls[1].id);
    try std.testing.expectEqualStrings("success-then-rejection", success_then_rejection[4].tool_call_id.?);
    try std.testing.expectEqualStrings(rejection, success_then_rejection[4].content.?);
    try std.testing.expectEqualStrings("second-read", success_then_rejection[5].tool_call_id.?);

    const rejection_then_success_calls = [_]types.ToolCall{
        .{ .id = "rejection-then-success", .name = "vision", .arguments_json = "{}" },
    };
    const rejection_then_success_messages = [_]types.ChatMessage{
        .{ .role = .user, .content = "inspect both routes" },
        .{ .role = .assistant, .tool_calls = &rejection_then_success_calls },
        .{ .role = .tool, .content = rejection, .tool_call_id = "rejection-then-success", .tool_name = "vision" },
        .{ .role = .assistant, .tool_calls = &rejection_then_success_calls },
        .{ .role = .tool, .content = "successful evidence", .tool_call_id = "rejection-then-success", .tool_name = "vision" },
        .{ .role = .assistant, .content = "recovered before success" },
    };
    const rejection_then_success = try project_native_messages(
        arena,
        &rejection_then_success_messages,
        0,
    );
    try std.testing.expectEqual(@as(usize, 4), rejection_then_success.len);
    try std.testing.expectEqualStrings("rejection-then-success", rejection_then_success[1].tool_calls[0].id);
    try std.testing.expectEqualStrings("rejection-then-success", rejection_then_success[2].tool_call_id.?);
    try std.testing.expectEqualStrings("recovered before success", rejection_then_success[3].content.?);
}

test "native message projection rejects reversed and unmatched Vision evidence" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const rejection = try tool_result_errors.toolExecutionFailureJson(arena, .{
        .tool_name = "vision",
        .message = native_route_unavailable_message,
        .suggestion = "Continue using the model's native image input without Vision.",
    });
    const before_call = [_]types.ToolCall{
        .{ .id = "before-call", .name = "vision", .arguments_json = "{}" },
    };
    const no_result = [_]types.ToolCall{
        .{ .id = "no-result", .name = "vision", .arguments_json = "{}" },
    };
    const noncontiguous = [_]types.ToolCall{
        .{ .id = "noncontiguous", .name = "vision", .arguments_json = "{}" },
    };
    const messages = [_]types.ChatMessage{
        .{ .role = .user, .content = "reject malformed evidence" },
        .{ .role = .tool, .content = rejection, .tool_call_id = "before-call", .tool_name = "vision" },
        .{ .role = .assistant, .tool_calls = &before_call },
        .{ .role = .assistant, .content = "before-call separator" },
        .{ .role = .assistant, .tool_calls = &no_result },
        .{ .role = .assistant, .content = "no-result separator" },
        .{ .role = .assistant, .tool_calls = &noncontiguous },
        .{ .role = .assistant, .content = "noncontiguous separator" },
        .{ .role = .tool, .content = rejection, .tool_call_id = "noncontiguous", .tool_name = "vision" },
        .{ .role = .tool, .content = rejection, .tool_call_id = "unmatched", .tool_name = "vision" },
        .{ .role = .assistant, .content = "finished" },
    };

    const projected = try project_native_messages(arena, &messages, 0);
    try std.testing.expectEqual(@as(usize, 5), projected.len);
    try std.testing.expectEqualStrings("reject malformed evidence", projected[0].content.?);
    try std.testing.expectEqualStrings("before-call separator", projected[1].content.?);
    try std.testing.expectEqualStrings("no-result separator", projected[2].content.?);
    try std.testing.expectEqualStrings("noncontiguous separator", projected[3].content.?);
    try std.testing.expectEqualStrings("finished", projected[4].content.?);
    for (projected) |chat_message| {
        try std.testing.expect(!std.mem.eql(u8, chat_message.tool_name orelse "", "vision"));
        for (chat_message.tool_calls) |call| {
            try std.testing.expect(!std.mem.eql(u8, call.name, "vision"));
        }
    }
}

test "Vision pending transition gates text routes and cancellation is neutral" {
    const initial = try transition_pending_images(
        std.testing.allocator,
        .text_only,
        &.{ 1, 2, 3 },
        .start,
    );
    defer initial.deinit(std.testing.allocator);
    try std.testing.expectEqual(VisionGate.vision_required, initial.gate);
    try std.testing.expectEqualSlices(usize, &.{ 1, 2, 3 }, initial.pending_ids);

    const partial = try transition_pending_images(
        std.testing.allocator,
        .text_only,
        initial.pending_ids,
        .{ .valid = &.{ 3, 1 } },
    );
    defer partial.deinit(std.testing.allocator);
    try std.testing.expectEqual(VisionGate.vision_required, partial.gate);
    try std.testing.expectEqualSlices(usize, &.{2}, partial.pending_ids);

    const cancelled = try transition_pending_images(
        std.testing.allocator,
        .text_only,
        partial.pending_ids,
        .cancelled,
    );
    defer cancelled.deinit(std.testing.allocator);
    try std.testing.expectEqual(PendingTransitionDisposition.cancelled, cancelled.disposition);
    try std.testing.expectEqualSlices(usize, partial.pending_ids, cancelled.pending_ids);

    const complete = try transition_pending_images(
        std.testing.allocator,
        .text_only,
        partial.pending_ids,
        .{ .valid = &.{2} },
    );
    defer complete.deinit(std.testing.allocator);
    try std.testing.expectEqual(VisionGate.unrestricted, complete.gate);
    try std.testing.expectEqual(@as(usize, 0), complete.pending_ids.len);

    const native = try transition_pending_images(
        std.testing.allocator,
        .native_images,
        &.{ 1, 2, 3 },
        .start,
    );
    defer native.deinit(std.testing.allocator);
    try std.testing.expectEqual(VisionGate.unrestricted, native.gate);
    try std.testing.expectEqual(PendingTransitionDisposition.not_applicable, native.disposition);
    try std.testing.expectEqualSlices(usize, &.{ 1, 2, 3 }, native.pending_ids);
}

test "Vision malformed and unauthorized attempts settle no pending ids" {
    inline for (.{ VisionAttempt.malformed, VisionAttempt.unauthorized }) |attempt| {
        const transition = try transition_pending_images(
            std.testing.allocator,
            .text_only,
            &.{ 4, 5 },
            attempt,
        );
        defer transition.deinit(std.testing.allocator);
        try std.testing.expectEqualSlices(usize, &.{ 4, 5 }, transition.pending_ids);
        try std.testing.expectEqual(VisionGate.vision_required, transition.gate);
    }
}

test "Vision owned parsing and merge clean up every allocation failure" {
    for ([_][]const u8{
        "{\"image_ids\":[1,2],\"focus\":\"compare both images\"}",
        "{\"paths\":[\"first.png\",\"second.png\"],\"focus\":\"compare both images\"}",
    }) |request_json| {
        var request_probe = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        const probed_request = try parse_vision_request(request_probe.allocator(), request_json);
        probed_request.deinit(request_probe.allocator());
        for (0..request_probe.alloc_index) |fail_index| {
            var failing = std.testing.FailingAllocator.init(
                std.testing.allocator,
                .{ .fail_index = fail_index },
            );
            try std.testing.expectError(
                error.OutOfMemory,
                parse_vision_request(failing.allocator(), request_json),
            );
        }
    }

    const provider_json =
        "{\"images\":[{\"image_id\":1,\"status\":\"ok\",\"summary\":\"summary\",\"visible_text\":[\"visible\"],\"details\":[\"detail\"]}]}";
    var provider_probe = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const probed_provider = try parse_vision_provider_result(
        provider_probe.allocator(),
        provider_json,
        provider_json.len,
    );
    probed_provider.deinit(provider_probe.allocator());
    for (0..provider_probe.alloc_index) |fail_index| {
        var failing = std.testing.FailingAllocator.init(
            std.testing.allocator,
            .{ .fail_index = fail_index },
        );
        try std.testing.expectError(
            error.OutOfMemory,
            parse_vision_provider_result(
                failing.allocator(),
                provider_json,
                provider_json.len,
            ),
        );
    }

    const provider_records = [_]VisionImageResult{ test_ok_result(2), test_ok_result(1) };
    var merge_probe = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const probed_merge = try merge_vision_results(
        merge_probe.allocator(),
        &.{ 1, 2 },
        &provider_records,
    );
    probed_merge.deinit(merge_probe.allocator());
    for (0..merge_probe.alloc_index) |fail_index| {
        var failing = std.testing.FailingAllocator.init(
            std.testing.allocator,
            .{ .fail_index = fail_index },
        );
        try std.testing.expectError(
            error.OutOfMemory,
            merge_vision_results(failing.allocator(), &.{ 1, 2 }, &provider_records),
        );
    }
}

test "Vision provider response schema matches the strict parser contract" {
    const schema = try build_provider_response_schema(std.testing.allocator, 2);
    defer std.testing.allocator.free(schema);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, schema, .{});
    defer parsed.deinit();
    const images = parsed.value.object.get("properties").?.object.get("images").?;
    try std.testing.expectEqual(@as(i64, 2), images.object.get("minItems").?.integer);
    try std.testing.expectEqual(@as(i64, 2), images.object.get("maxItems").?.integer);

    const alternatives = images.object.get("items").?.object.get("anyOf").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), alternatives.len);
    const success = alternatives[0].object;
    const failure = alternatives[1].object;
    try std.testing.expectEqual(@as(usize, 5), success.get("required").?.array.items.len);
    try std.testing.expectEqual(@as(usize, 3), failure.get("required").?.array.items.len);
    try std.testing.expect(success.get("additionalProperties").?.bool == false);
    try std.testing.expect(failure.get("additionalProperties").?.bool == false);
    const success_image_id = success.get("properties").?.object.get("image_id").?.object;
    const failure_image_id = failure.get("properties").?.object.get("image_id").?.object;
    try std.testing.expect(success_image_id.get("enum") == null);
    try std.testing.expect(failure_image_id.get("enum") == null);
    const failure_error = failure.get("properties").?.object.get("error").?.object;
    try std.testing.expectEqualStrings(
        "vision_unavailable",
        failure_error.get("enum").?.array.items[0].string,
    );

    try std.testing.expectError(
        error.InvalidVisionResponseImageCount,
        build_provider_response_schema(std.testing.allocator, 0),
    );
    try std.testing.expectError(
        error.InvalidVisionResponseImageCount,
        build_provider_response_schema(std.testing.allocator, max_provider_images_per_batch + 1),
    );
}
