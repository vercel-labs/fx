const std = @import("std");
const question_prompt = @import("../../core/agent/question_prompt.zig");
const approval_prompt = @import("../../core/permissions/approval_prompt.zig");
const auth_runtime = @import("../../core/auth/auth_runtime.zig");
const activity_status = @import("../../core/output/activity_status.zig");
const model_cache_runtime = @import("../../core/app/model_cache_runtime.zig");
const picker_state = @import("../../core/input/picker_state.zig");
const session_catalog = @import("../../core/session/session_catalog.zig");
const session_store = @import("../../core/session/session_store.zig");
const usage_report = @import("../../core/session/usage_report.zig");
const command_specs = @import("../../core/slash_commands/command_specs.zig");
const settings_catalog = @import("../../core/config/settings_catalog.zig");
const skill_runtime = @import("../../core/skills/skill_runtime.zig");
const display_width = @import("../../core/shared/display_width.zig");
const types = @import("../../core/shared/types.zig");
const workspace_access = @import("../../core/workspace/workspace_access.zig");
const file_index = @import("../../core/workspace/file_index.zig");
const workspace_menu = @import("../../core/workspace/workspace_menu.zig");
const activity_runtime = @import("../../core/output/activity_runtime.zig");
const transcript_presentation = @import("../../core/output/transcript_presentation.zig");
const usage_menu = @import("../../core/session/usage_menu.zig");
const core_input_runtime = @import("../../core/input/runtime.zig");
const presentation_mode = @import("../../core/config/presentation_mode.zig");
const ui_render = @import("../render.zig");
const render_engine = @import("../render_engine.zig");
const render_request = @import("../render_request.zig");
const transcript_runtime = @import("../transcript/runtime.zig");
const interaction_state = @import("interaction_state.zig");

const activity_overlay = render_engine.activity_overlay;
const StreamState = types.StreamState;
const ActivityProjection = activity_runtime.ActivityProjection;
const InputRuntime = core_input_runtime.Runtime;
const TranscriptRuntime = transcript_runtime.TranscriptRuntime;
const SubagentStatus = @import("../../core/subagent/domain.zig").State;

pub const SkillsMenuProjection = struct {
    active: bool = false,
    items: []const skill_runtime.Skill = &.{},
    source_filter: skill_runtime.SkillMenuSourceFilter = .all,
    selected_index: usize = 0,
    window_start: usize = 0,
    query: []const u8 = "",
};

pub const ModelMenuProjection = struct {
    active: bool = false,
    load_state: model_cache_runtime.ModelMenuLoadState = .loading,
    catalog_state: model_cache_runtime.ModelMenuCatalogState = .{},
    auth_service_label: []const u8 = "",
    items: []const model_cache_runtime.ModelMenuItem = &.{},
    provider_index: usize = 0,
    selected_index: usize = 0,
    window_start: usize = 0,
    query: []const u8 = "",

    pub fn providerFilter(self: ModelMenuProjection) model_cache_runtime.ModelProviderFilter {
        return @enumFromInt(@min(self.provider_index, model_cache_runtime.model_provider_filter_count - 1));
    }

    pub fn filteredItemCount(self: ModelMenuProjection) usize {
        return model_cache_runtime.modelMenuFilteredItemCount(self.items, self.providerFilter(), self.query);
    }

    pub fn itemAt(self: ModelMenuProjection, display_index: usize) ?*const model_cache_runtime.ModelMenuItem {
        return model_cache_runtime.modelMenuItemAt(self.items, self.providerFilter(), self.query, display_index);
    }
};

pub const SessionMenuProjection = struct {
    active: bool = false,
    load_state: session_catalog.LoadState = .loading,
    summaries: []const session_store.SessionSummary = &.{},
    has_more: bool = false,
    loading_more: bool = false,
    scope: session_catalog.Scope = .current_workspace,
    selected_index: usize = 0,
    window_start: usize = 0,
    query: []const u8 = "",
    now_ms: i64 = 0,
    selection_failure: ?session_catalog.ResumeFailure = null,

    pub fn filteredItemCount(self: SessionMenuProjection) usize {
        return session_catalog.filteredCount(self.summaries, self.query);
    }

    pub fn navigationItemCount(self: SessionMenuProjection) usize {
        return self.filteredItemCount() + @intFromBool(self.has_more);
    }

    pub fn isLoadMoreIndex(self: SessionMenuProjection, display_index: usize) bool {
        return self.has_more and display_index == self.filteredItemCount();
    }

    pub fn itemAt(self: SessionMenuProjection, display_index: usize) ?*const session_store.SessionSummary {
        return session_catalog.summaryAt(self.summaries, self.query, display_index);
    }
};

pub const HelpMenuProjection = struct {
    active: bool = false,
    registry: command_specs.SlashRegistry = .{},
    auth_service_label: []const u8 = "",
    selected_index: usize = 0,
    window_start: usize = 0,
    query: []const u8 = "",

    pub fn filteredItemCount(self: HelpMenuProjection) usize {
        return command_specs.helpCatalogCount(self.registry, self.query);
    }

    pub fn itemAt(self: HelpMenuProjection, display_index: usize) ?*const command_specs.SlashSpec {
        return command_specs.helpCatalogSpecAt(self.registry, self.query, display_index);
    }
};

pub const SettingsMenuProjection = struct {
    active: bool = false,
    category: settings_catalog.Category = .all,
    selected_index: usize = 0,
    window_start: usize = 0,
    snapshot: settings_catalog.Snapshot = .{},
    query: []const u8 = "",
    models: ModelMenuProjection = .{},

    pub fn filteredItemCount(self: SettingsMenuProjection) usize {
        return settings_catalog.filteredCount(self.snapshot, self.category, self.query);
    }

    pub fn itemAt(self: SettingsMenuProjection, display_index: usize) ?settings_catalog.Item {
        return settings_catalog.itemAt(self.snapshot, self.category, self.query, display_index);
    }
};

pub const AppearanceMenuProjection = struct {
    active: bool = false,
    selected_index: usize = 0,
    snapshot: settings_catalog.Snapshot = .{},
};

pub fn appearanceMenuProjection(
    menu: *const settings_catalog.AppearanceMenu,
    snapshot: settings_catalog.Snapshot,
) AppearanceMenuProjection {
    return .{
        .active = menu.active,
        .selected_index = menu.selected_index,
        .snapshot = snapshot,
    };
}

pub const StatuslineMenuProjection = struct {
    active: bool = false,
    selected_index: usize = 0,
    snapshot: settings_catalog.Snapshot = .{},
};

pub fn statuslineMenuProjection(
    menu: *const settings_catalog.StatuslineMenu,
    snapshot: settings_catalog.Snapshot,
) StatuslineMenuProjection {
    return .{
        .active = menu.active,
        .selected_index = menu.selected_index,
        .snapshot = snapshot,
    };
}

pub const SandboxMenuProjection = struct {
    active: bool = false,
    selected_index: usize = 0,
    snapshot: settings_catalog.Snapshot = .{},
    os_sandbox_available: bool = true,
};

pub fn sandboxMenuProjection(
    menu: *const settings_catalog.SandboxMenu,
    snapshot: settings_catalog.Snapshot,
    os_sandbox_available: bool,
) SandboxMenuProjection {
    return .{
        .active = menu.active,
        .selected_index = menu.selected_index,
        .snapshot = snapshot,
        .os_sandbox_available = os_sandbox_available,
    };
}

pub const UsageMenuProjection = struct {
    active: bool = false,
    scope: usage_report.Scope = .days_30,
    selected_model: usize = 0,
    expanded_model: ?usize = null,
    model_window_start: usize = 0,
    snapshot: ?*const usage_report.Snapshot = null,
    refresh_error: ?[]const u8 = null,
};

pub fn usageMenuProjection(
    menu: *const usage_menu.State,
) UsageMenuProjection {
    return .{
        .active = menu.active,
        .scope = menu.scope(),
        .selected_model = menu.selected_model,
        .expanded_model = menu.expanded_model,
        .model_window_start = menu.model_window_start,
        .snapshot = if (menu.snapshot) |*snapshot| snapshot else null,
        .refresh_error = menu.refresh_error,
    };
}

pub const WorkspaceMenuProjection = struct {
    active: bool = false,
    selected_row: usize = 0,
    primary_directory: []const u8 = "",
    saved_suppressed: bool = false,
    entries: []const workspace_access.Entry = &.{},
};

pub fn workspaceMenuProjection(
    menu: *const workspace_menu.State,
    primary_directory: []const u8,
    access: *const workspace_access.WorkspaceAccess,
) WorkspaceMenuProjection {
    return .{
        .active = menu.active,
        .selected_row = menu.selectedRow(access.entries) orelse 0,
        .primary_directory = primary_directory,
        .saved_suppressed = access.saved_suppressed,
        .entries = access.entries,
    };
}

pub const CompactCommandMenuProjection = union(enum) {
    statusline: StatuslineMenuProjection,
    sandbox: SandboxMenuProjection,
    usage: UsageMenuProjection,
    workspace: WorkspaceMenuProjection,
};

pub fn settingsMenuProjection(
    menu: *const settings_catalog.Menu,
    snapshot: settings_catalog.Snapshot,
    query: []const u8,
) SettingsMenuProjection {
    return .{
        .active = menu.active,
        .category = menu.category,
        .selected_index = menu.selected_index,
        .window_start = menu.window_start,
        .snapshot = snapshot,
        .query = query,
    };
}

pub fn helpMenuProjection(
    menu: *const command_specs.HelpMenu,
    registry: command_specs.SlashRegistry,
    auth_service_label: []const u8,
    query: []const u8,
) HelpMenuProjection {
    return .{
        .active = menu.active,
        .registry = registry,
        .auth_service_label = auth_service_label,
        .selected_index = menu.selected_index,
        .window_start = menu.window_start,
        .query = query,
    };
}

pub fn skillsMenuProjection(skills: *const skill_runtime.Runtime) SkillsMenuProjection {
    return .{
        .active = skills.menu.active,
        .items = skills.items,
        .source_filter = skills.menu.source_filter,
        .selected_index = skills.menu.selected_index,
        .window_start = skills.menu.window_start,
        .query = skills.menu.query(),
    };
}

pub fn modelMenuProjection(cache: *const model_cache_runtime.Runtime) ModelMenuProjection {
    return .{
        .active = cache.menu.active,
        .load_state = cache.menu.load_state,
        .catalog_state = cache.menu.catalog_state,
        .items = cache.menu.items.items,
        .provider_index = cache.menu.provider_index,
        .selected_index = cache.menu.selected_index,
        .window_start = cache.menu.window_start,
        .query = cache.menu.query(),
    };
}

pub fn modelMenuProjectionWithAuth(
    cache: *const model_cache_runtime.Runtime,
    auth_service_label: []const u8,
) ModelMenuProjection {
    var projection = modelMenuProjection(cache);
    projection.auth_service_label = auth_service_label;
    return projection;
}

const max_static_status_activity_rows: u16 = 3;

pub const InputAppearance = core_input_runtime.InputAppearance;
pub const MaxxingMode = presentation_mode.MaxxingMode;

pub const QueuedPromptCard = struct {
    bytes: []const u8,
    row_count: u16,
    editing: bool = false,
};

pub const RenderContext = struct {
    slash_registry: command_specs.SlashRegistry = .{},
    stream: StreamState,
    completed_assistant_presentation_tail: bool = false,
    // Pacer emitting visible text, including the post-finish tail drain.
    writing_response: bool = false,
    has_credential: bool,
    model: []const u8,
    pending_images: []const types.ImageAttachment = &.{},
    composer_visible: bool = true,
    input_appearance: InputAppearance = .lines,
    maxxing_mode: MaxxingMode = .legacy,
    permission_mode: types.PermissionMode = .ask,
    queued_count: usize,
    queued_paused: bool = false,
    queued_cancel_all_available: bool = false,
    queued_prompt_cards: []const QueuedPromptCard = &.{},
    queued_prompt_card_rows: u16 = 0,
    queued_editor_active: bool = false,
    subagent_count: usize,
    subagent_view_active: bool,
    selected_subagent_id: ?u64,
    selected_subagent_label: ?[]const u8,
    selected_subagent_status: ?SubagentStatus,
    selected_subagent_tool_calls: usize = 0,
    selected_subagent_activity: ?[]const u8 = null,
    fast_mode: bool = false,
    model_supports_fast: bool = false,
    effort: types.ReasoningEffort = .auto,
    model_supports_effort: bool = false,
    ctrl_c_pending: bool = false,
    shimmer_pos: i16 = -render_request.animation_padding,
    now_ms: i64 = 0,
    model_query_active: bool = false,
    model_picker_stage: picker_state.ModelPickerStage = .model,
    model_completions_loading: bool = false,
    model_completions_failed: bool = false,
    model_completions: []const []const u8 = &.{},
    model_completion_index: usize = 0,
    model_completion_window_start: usize = 0,
    model_completion_anchor: usize = 0,
    file_query_active: bool = false,
    file_completions: []const file_index.SearchResult = &.{},
    file_completion_index: usize = 0,
    file_completion_window_start: usize = 0,
    file_completion_anchor: usize = 0,
    file_completions_loading: bool = false,
    file_completions_failed: bool = false,
    inline_completion_suffix: []const u8 = "",
    auth_picker: auth_runtime.PickerView = .{
        .active = false,
        .sources = &.{},
        .selected_choice = null,
        .active_source = null,
        .include_skip = false,
    },
    skills_menu: SkillsMenuProjection = .{},
    model_menu: ModelMenuProjection = .{},
    session_menu: SessionMenuProjection = .{},
    appearance_menu: AppearanceMenuProjection = .{},
    statusline_menu: StatuslineMenuProjection = .{},
    sandbox_menu: SandboxMenuProjection = .{},
    usage_menu: UsageMenuProjection = .{},
    workspace_menu: WorkspaceMenuProjection = .{},
    upgrade_status: []const u8 = "",
    danger_status: []const u8 = "",
    danger_status_compact: []const u8 = "",
    esc_clear_armed: bool = false,
    question: ?question_prompt.Projection = null,
    statusline: ui_render.StatuslineItems = .{},
    activity: ActivityProjection = .none,
    transcript_depth: transcript_presentation.Depth = .inline_mode,
    input: *const InputRuntime,
};

pub fn activeCompactCommandMenu(ctx: RenderContext) ?CompactCommandMenuProjection {
    if (ctx.statusline_menu.active) return .{ .statusline = ctx.statusline_menu };
    if (ctx.sandbox_menu.active) return .{ .sandbox = ctx.sandbox_menu };
    if (ctx.usage_menu.active) return .{ .usage = ctx.usage_menu };
    if (ctx.workspace_menu.active) return .{ .workspace = ctx.workspace_menu };
    return null;
}

// Trailing blank row that keeps the collapsed summary off the composer.
pub const collapsed_queue_banner_gap_rows: u16 = 1;

// Expanded cards plus one blank row between adjacent prompts, so queued drafts
// read as separate items instead of a single connected block.
pub fn queuedCardContentRows(ctx: RenderContext) u16 {
    const between_cards: u16 = @intCast(@min(
        ctx.queued_prompt_cards.len -| 1,
        std.math.maxInt(u16),
    ));
    return ctx.queued_prompt_card_rows +| between_cards;
}

// Blank rows framing the expanded cards: one closing the band off the composer,
// plus one above the paused hint so it reads as the block's footer.
pub fn queuedCardSpacerRows(ctx: RenderContext) u16 {
    const above_hint: u16 = @intFromBool(ctx.queued_paused);
    return 1 +| above_hint;
}

pub fn queuedBannerRows(ctx: RenderContext) u16 {
    if (ctx.queued_count == 0) return 0;
    const paused_hint_rows: u16 = @intFromBool(ctx.queued_paused);
    if (ctx.queued_prompt_card_rows > 0) {
        return queuedCardContentRows(ctx) +|
            paused_hint_rows +|
            queuedCardSpacerRows(ctx);
    }
    // No cards means the banner is collapsed to its single summary row.
    return 1 +| paused_hint_rows +| collapsed_queue_banner_gap_rows;
}

pub fn transientActivityGapRows(shell: *const TranscriptRuntime, tool_before_activity: bool) u16 {
    if (tool_before_activity and shell.maxxing_mode == .minimal) return 0;
    return shell.transientAssistantGapRows();
}

pub fn activityOverlayInput(
    shell: *TranscriptRuntime,
    projection: ActivityProjection,
    place_mid_line_active: bool,
    cursor_row: u16,
    cursor_col: u16,
    footer_top_for_extra: u16,
) activity_overlay.Input {
    const entry_bound_active = switch (projection) {
        .tool_slot => true,
        .none, .turn_thinking => false,
    };
    const active_label_present = switch (projection) {
        .turn_thinking => true,
        .tool_slot => |slot| slot.thinking_label != null,
        .none => false,
    };
    const tool_before_activity = switch (projection) {
        .tool_slot => |slot| slot.thinking_label != null,
        .none, .turn_thinking => false,
    };
    const stream_active = switch (projection) {
        .tool_slot => |slot| slot.active,
        .none, .turn_thinking => false,
    };
    const placement_cursor_col = if (entry_bound_active and stream_active and cursor_col == 1)
        2
    else
        cursor_col;
    return .{
        .active_label_present = active_label_present,
        .activity_rows = activityProjectionRows(projection, shell.layout.cols),
        .tool_before_activity = tool_before_activity,
        .cursor_row = cursor_row,
        .cursor_col = placement_cursor_col,
        .transient_gap_rows = transientActivityGapRows(shell, tool_before_activity),
        .place_mid_line_active = place_mid_line_active,
        .entry_bound_active = entry_bound_active,
        .stream_active = stream_active,
        .footer_top_for_extra = footer_top_for_extra,
        .footer_clearance_rows = if (active_label_present)
            render_engine.transcript_blocks.footerBoundaryGapRowsForTail(.turn_summary)
        else
            0,
    };
}

pub fn activityProjectionRows(projection: ActivityProjection, cols: u16) u16 {
    return switch (projection) {
        .turn_thinking => |thinking| if (thinking.tone == .thinking)
            1
        else
            wrappedStatusRowCount(thinking.label, cols, max_static_status_activity_rows),
        .none, .tool_slot => 1,
    };
}

pub fn frameOwnedActivityProjection(
    buf: []u8,
    shell: *TranscriptRuntime,
    ctx: RenderContext,
    approval: ?approval_prompt.Projection,
) ActivityProjection {
    if (approval != null or ctx.question != null) return .none;
    switch (ctx.activity) {
        .tool_slot => return thinkingActivityProjection(buf, shell, ctx),
        .turn_thinking => |thinking| {
            if (thinking.tone != .thinking) return ctx.activity;
            return thinkingActivityProjection(buf, shell, ctx);
        },
        .none => return thinkingActivityProjection(buf, shell, ctx),
    }
}

fn thinkingActivityProjection(
    buf: []u8,
    shell: *TranscriptRuntime,
    ctx: RenderContext,
) ActivityProjection {
    _ = shell;
    // The markerless counter row belongs to the response: the text landing on
    // screen is its own progress report, and it keeps the row through the gaps
    // where the pacer waits on the next chunk. Once the model switches to a
    // tool payload nothing will print for a while, so the row takes the marker
    // back and starts blinking again.
    if (ctx.stream.active and ctx.stream.assistant_text_started and ctx.stream.composing_tool_payload) {
        return .{ .turn_thinking = .{
            .label = activity_status.buildQuietTurnLabel(buf, ctx.stream, ctx.now_ms),
        } };
    }
    if (ctx.writing_response or (ctx.stream.active and ctx.stream.assistant_text_started)) {
        return .{ .turn_thinking = .{
            .label = activity_status.buildStreamingLabel(buf, ctx.stream),
            .tone = if (ctx.stream.active) .thinking else .neutral,
        } };
    }
    if (!ctx.stream.active) {
        if (!ctx.completed_assistant_presentation_tail) return .none;
        const presentation_stream: StreamState = .{ .active = true };
        return .{ .turn_thinking = .{
            .label = activity_status.buildThinkingLabel(buf, presentation_stream, ctx.now_ms) orelse "• Thinking",
        } };
    }
    var thinking_stream = ctx.stream;
    thinking_stream.last_activity_kind = null;
    thinking_stream.read_count = 0;
    thinking_stream.list_count = 0;
    thinking_stream.write_count = 0;
    thinking_stream.edit_count = 0;
    thinking_stream.open_count = 0;
    thinking_stream.command_count = 0;
    thinking_stream.subagent_count = 0;
    if (activity_status.buildThinkingLabel(buf, thinking_stream, ctx.now_ms)) |label| {
        return .{ .turn_thinking = .{ .label = label } };
    }
    return .{ .turn_thinking = .{
        .label = "• Thinking",
    } };
}

fn toolSlotLabelWithTokens(buf: []u8, label: []const u8, stream: StreamState) []const u8 {
    var out: std.Io.Writer = .fixed(buf);
    out.writeAll(label) catch return label;
    activity_status.appendTurnTokenSuffix(&out, stream) catch return out.buffered();
    return out.buffered();
}

fn appendConnectedToolLabel(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    label: []const u8,
    cols: u16,
) !void {
    var marker_start: usize = 0;
    while (marker_start < label.len and label[marker_start] == 0x1b) {
        const ansi_end = display_width.ansiSequenceEnd(label, marker_start);
        if (ansi_end <= marker_start) break;
        marker_start = ansi_end;
    }
    const marker = display_width.decodeNextRune(label, marker_start);
    if (marker.len == 0) return;
    const marker_end = @min(marker_start + marker.len, label.len);
    const marker_bytes = label[marker_start..marker_end];
    const line_end = std.mem.findScalar(u8, label[marker_end..], '\n') orelse label[marker_end..].len;

    // The live label arrives with the formatter's bold styling; the connected
    // row belongs to the dimmed group block, so restyle it plain gray.
    var connected: std.ArrayList(u8) = .empty;
    defer connected.deinit(alloc);
    try connected.appendSlice(alloc, ui_render.statusline_style);
    if (std.mem.eql(u8, marker_bytes, "●") or std.mem.eql(u8, marker_bytes, "■")) {
        try connected.appendSlice(alloc, "└");
        try appendWithoutAnsi(alloc, &connected, label[marker_end .. marker_end + line_end]);
    } else {
        try appendWithoutAnsi(alloc, &connected, label[0 .. marker_end + line_end]);
    }

    const clipped = try render_engine.transcript_blocks.formatCompactCommandStatus(
        alloc,
        connected.items,
        cols,
    );
    defer alloc.free(clipped);
    try out.appendSlice(alloc, clipped);
    try out.appendSlice(alloc, ui_render.reset_style);
}

fn appendWithoutAnsi(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    text: []const u8,
) !void {
    var index: usize = 0;
    while (index < text.len) {
        if (text[index] == 0x1b) {
            const ansi_end = display_width.ansiSequenceEnd(text, index);
            if (ansi_end > index) {
                index = ansi_end;
                continue;
            }
        }
        try out.append(alloc, text[index]);
        index += 1;
    }
}

pub fn activityProjectionLabel(projection: ActivityProjection) ?[]const u8 {
    return switch (projection) {
        .none => null,
        .turn_thinking => |thinking| thinking.label,
        .tool_slot => |slot| slot.thinking_label orelse slot.fallback_label,
    };
}

test "skillsMenuProjection mirrors runtime menu state" {
    var skills = [_]skill_runtime.Skill{
        .{ .name = "managed", .description = "managed desc", .path = "/tmp/managed/SKILL.md", .source = .global_fx },
        .{ .name = "workspace", .description = "workspace desc", .path = "/tmp/workspace/SKILL.md", .source = .workspace_shared },
    };
    var runtime: skill_runtime.Runtime = .{ .items = &skills };
    runtime.menu.active = true;
    runtime.menu.source_filter = .workspace;
    runtime.menu.selected_index = 1;
    runtime.menu.window_start = 1;
    runtime.menu.setQuery("work");

    const projection = skillsMenuProjection(&runtime);

    try std.testing.expect(projection.active);
    try std.testing.expectEqual(@as(usize, skills.len), projection.items.len);
    try std.testing.expectEqual(skill_runtime.SkillMenuSourceFilter.workspace, projection.source_filter);
    try std.testing.expectEqual(@as(usize, 1), projection.selected_index);
    try std.testing.expectEqual(@as(usize, 1), projection.window_start);
    try std.testing.expectEqualStrings("work", projection.query);
}

test "modelMenuProjection mirrors cache-owned catalog state" {
    var cache = model_cache_runtime.Runtime.init(std.testing.allocator);
    defer cache.deinit();
    cache.menu.load_state = .failed;
    cache.menu.catalog_state = .{
        .access_level = .public_only,
        .public_only_reason = .refresh_failed,
        .private_models_hidden = true,
        .failure = .{ .category = .transport, .retryable = true },
    };

    const projection = modelMenuProjection(&cache);

    try std.testing.expectEqual(cache.menu.load_state, projection.load_state);
    try std.testing.expectEqual(cache.menu.catalog_state, projection.catalog_state);
}

fn wrappedStatusRowCount(label: []const u8, cols: u16, max_rows: u16) u16 {
    if (max_rows <= 1 or cols == 0) return 1;
    if (display_width.visibleWidthIgnoringAnsi(label) <= cols) return 1;

    const safe_cols = @max(@as(usize, cols), 1);
    const prefix_end = display_width.statusPrefixEnd(label);
    const prefix_width = display_width.visibleWidthIgnoringAnsi(label[0..prefix_end]);
    var remaining = label[prefix_end..];
    var row_count: u16 = 0;
    var first = true;
    while (remaining.len > 0 and row_count < max_rows) {
        const indent_width = if (first) prefix_width else @max(prefix_width, 1);
        const available = if (safe_cols > indent_width) safe_cols - indent_width else 1;
        var chunk = display_width.wrapCutIgnoringAnsi(remaining, available);
        if (chunk.len == 0) {
            const unit = display_width.displayUnitAt(remaining, 0);
            chunk = remaining[0..unit.byte_len];
        }
        remaining = display_width.trimBreakWhitespace(remaining[chunk.len..]);
        row_count += 1;
        first = false;
    }
    return @max(row_count, 1);
}

pub fn activityFallbackLabel(buf: []u8, projection: ActivityProjection, ctx: RenderContext) []const u8 {
    return switch (projection) {
        .none => "",
        .turn_thinking => |thinking| thinking.label,
        .tool_slot => |slot| slot.thinking_label orelse toolSlotLabelWithTokens(buf, slot.fallback_label, ctx.stream),
    };
}

pub fn appendActivityToolLabel(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    projection: ActivityProjection,
    cols: u16,
) !void {
    switch (projection) {
        .tool_slot => |slot| if (slot.thinking_label != null) {
            try appendConnectedToolLabel(alloc, out, slot.fallback_label, cols);
        },
        .none, .turn_thinking => {},
    }
}

test "frame-owned thinking activity projects the thinking label" {
    var input = InputRuntime{};
    defer input.deinit(std.testing.allocator);
    var shell = TranscriptRuntime{};
    defer shell.deinit(std.testing.allocator);
    const ctx: RenderContext = .{
        .stream = .{ .active = true },
        .has_credential = true,
        .model = "gpt-5.1",
        .queued_count = 0,
        .subagent_count = 0,
        .subagent_view_active = false,
        .selected_subagent_id = null,
        .selected_subagent_label = null,
        .selected_subagent_status = null,
        .shimmer_pos = 0,
        .input = &input,
    };

    var dot_buf: [128]u8 = undefined;
    switch (frameOwnedActivityProjection(&dot_buf, &shell, ctx, null)) {
        .turn_thinking => |thinking| try std.testing.expectEqualStrings("• Thinking", thinking.label),
        .none, .tool_slot => return error.TestUnexpectedResult,
    }
}

test "frame-owned activity renders the thinking elapsed counter from the frame clock" {
    var input = InputRuntime{};
    defer input.deinit(std.testing.allocator);

    var shell = TranscriptRuntime{};
    defer shell.deinit(std.testing.allocator);
    const ctx: RenderContext = .{
        .stream = .{ .active = true, .turn_started_ms = 1_000 },
        .now_ms = 4_200,
        .has_credential = true,
        .model = "gpt-5.1",
        .queued_count = 0,
        .subagent_count = 0,
        .subagent_view_active = false,
        .selected_subagent_id = null,
        .selected_subagent_label = null,
        .selected_subagent_status = null,
        .input = &input,
    };

    var counter_buf: [128]u8 = undefined;
    switch (frameOwnedActivityProjection(&counter_buf, &shell, ctx, null)) {
        .turn_thinking => |thinking| try std.testing.expectEqualStrings("• Thinking (3s)", thinking.label),
        .none, .tool_slot => return error.TestUnexpectedResult,
    }
}

test "frame-owned activity keeps active tools out of the turn status row" {
    var input = InputRuntime{};
    defer input.deinit(std.testing.allocator);

    var shell = TranscriptRuntime{
        .last_visible_transcript_tail_kind = .tool_status,
    };
    defer shell.deinit(std.testing.allocator);
    const ctx: RenderContext = .{
        .stream = .{ .active = true, .last_activity_kind = .read, .read_count = 1 },
        .has_credential = true,
        .model = "gpt-5.1",
        .queued_count = 0,
        .subagent_count = 0,
        .subagent_view_active = false,
        .selected_subagent_id = null,
        .selected_subagent_label = null,
        .selected_subagent_status = null,
        .activity = .{ .tool_slot = .{
            .entry_id = 123,
            .fallback_label = "reading src/main.zig",
            .active = true,
            .kind = .read,
        } },
        .input = &input,
    };

    var active_buf: [256]u8 = undefined;
    switch (frameOwnedActivityProjection(&active_buf, &shell, ctx, null)) {
        .turn_thinking => |thinking| {
            try std.testing.expectEqual(ActivityProjection.Tone.thinking, thinking.tone);
            try std.testing.expectEqualStrings("• Thinking", thinking.label);
        },
        .none, .tool_slot => return error.TestUnexpectedResult,
    }
}

test "minimal frame-owned activity leaves the focused tool in the transcript" {
    var input = InputRuntime{};
    defer input.deinit(std.testing.allocator);

    var shell = TranscriptRuntime{ .maxxing_mode = .minimal };
    defer shell.deinit(std.testing.allocator);
    const ctx: RenderContext = .{
        .stream = .{
            .active = true,
            .command_count = 1,
            .last_activity_kind = .command,
            .token_progress = .{
                .input_tokens = 50_000,
                .output_tokens = 1_250,
                .input_exact = false,
                .output_exact = false,
            },
        },
        .has_credential = true,
        .model = "test-model",
        .queued_count = 0,
        .subagent_count = 0,
        .subagent_view_active = false,
        .selected_subagent_id = null,
        .selected_subagent_label = null,
        .selected_subagent_status = null,
        .activity = .{ .tool_slot = .{
            .entry_id = 123,
            .fallback_label = "● Running\x1b[0m \x1b[38;5;245mzig build test\x1b[0m\n",
            .active = true,
            .kind = .command,
        } },
        .input = &input,
    };

    var active_buf: [256]u8 = undefined;
    const projection = frameOwnedActivityProjection(&active_buf, &shell, ctx, null);
    switch (projection) {
        .turn_thinking => |thinking| try std.testing.expectEqualStrings(
            "• Thinking (↑50k ↓1.2k)",
            thinking.label,
        ),
        .none, .tool_slot => return error.TestUnexpectedResult,
    }

    var streaming_buf: [256]u8 = undefined;
    var streaming_ctx = ctx;
    streaming_ctx.writing_response = true;
    switch (frameOwnedActivityProjection(&streaming_buf, &shell, streaming_ctx, null)) {
        .turn_thinking => |thinking| try std.testing.expectEqualStrings(
            "  (↑50k ↓1.2k)",
            thinking.label,
        ),
        .none, .tool_slot => return error.TestUnexpectedResult,
    }
}

test "minimal connected tool label clips with an ellipsis" {
    const alloc = std.testing.allocator;
    const projection: ActivityProjection = .{ .tool_slot = .{
        .entry_id = 123,
        .fallback_label = "● Running\x1b[0m \x1b[38;5;245mzig build test with a deliberately long target\x1b[0m\n",
        .thinking_label = "• Thinking",
        .active = true,
        .kind = .command,
    } };

    var label: std.ArrayList(u8) = .empty;
    defer label.deinit(alloc);
    try appendActivityToolLabel(alloc, &label, projection, 24);

    try std.testing.expect(std.mem.startsWith(u8, label.items, "\x1b[38;5;245m└ Running"));
    try std.testing.expect(std.mem.find(u8, label.items, "\x1b[1m") == null);
    try std.testing.expect(std.mem.find(u8, label.items, "…") != null);
    try std.testing.expect(std.mem.findScalar(u8, label.items, '\n') == null);
    try std.testing.expect(display_width.visibleWidthIgnoringAnsi(label.items) <= 24);
}

test "frame-owned activity preserves route recovery status tone" {
    var input = InputRuntime{};
    defer input.deinit(std.testing.allocator);
    var shell = TranscriptRuntime{};
    defer shell.deinit(std.testing.allocator);
    const ctx: RenderContext = .{
        .stream = .{},
        .has_credential = true,
        .model = "gpt-5.1",
        .queued_count = 0,
        .subagent_count = 0,
        .subagent_view_active = false,
        .selected_subagent_id = null,
        .selected_subagent_label = null,
        .selected_subagent_status = null,
        .activity = .{ .turn_thinking = .{
            .label = "⚠ API error · attempt 1/3 failed · retrying",
            .tone = .warning,
        } },
        .input = &input,
    };

    var active_buf: [256]u8 = undefined;
    switch (frameOwnedActivityProjection(&active_buf, &shell, ctx, null)) {
        .turn_thinking => |thinking| {
            try std.testing.expectEqual(ActivityProjection.Tone.warning, thinking.tone);
            try std.testing.expectEqualStrings("⚠ API error · attempt 1/3 failed · retrying", thinking.label);
        },
        .none, .tool_slot => return error.TestUnexpectedResult,
    }

    var question_ctx = ctx;
    question_ctx.question = .{
        .current_entry = null,
        .current_index = 0,
        .entry_count = 0,
    };
    try std.testing.expect(frameOwnedActivityProjection(&active_buf, &shell, question_ctx, null) == .none);
}

test "frame-owned activity shows live streaming token progress" {
    var input = InputRuntime{};
    defer input.deinit(std.testing.allocator);
    var shell = TranscriptRuntime{};
    defer shell.deinit(std.testing.allocator);
    const ctx: RenderContext = .{
        .stream = .{
            .active = true,
            .token_progress = .{
                .input_tokens = 50_000,
                .output_tokens = 1_250,
                .input_exact = false,
                .output_exact = false,
            },
        },
        .writing_response = true,
        .has_credential = true,
        .model = "test-model",
        .queued_count = 0,
        .subagent_count = 0,
        .subagent_view_active = false,
        .selected_subagent_id = null,
        .selected_subagent_label = null,
        .selected_subagent_status = null,
        .activity = .none,
        .input = &input,
    };

    var active_buf: [256]u8 = undefined;
    switch (frameOwnedActivityProjection(&active_buf, &shell, ctx, null)) {
        .turn_thinking => |thinking| {
            try std.testing.expectEqualStrings("  (↑50k ↓1.2k)", thinking.label);
            try std.testing.expectEqual(ActivityProjection.Tone.thinking, thinking.tone);
        },
        .none, .tool_slot => return error.TestUnexpectedResult,
    }

    // Pacer caught up mid-response and is waiting on the next chunk: the quiet
    // row holds for the whole response instead of flipping inside every gap.
    var drained_ctx = ctx;
    drained_ctx.writing_response = false;
    drained_ctx.stream.assistant_text_started = true;
    var drained_buf: [256]u8 = undefined;
    switch (frameOwnedActivityProjection(&drained_buf, &shell, drained_ctx, null)) {
        .turn_thinking => |thinking| {
            try std.testing.expectEqualStrings("  (↑50k ↓1.2k)", thinking.label);
            try std.testing.expectEqual(ActivityProjection.Tone.thinking, thinking.tone);
        },
        .none, .tool_slot => return error.TestUnexpectedResult,
    }

    // The model moved on to a tool payload that prints nothing: the marker
    // comes back with the turn clock so the row does not read as finished.
    var composing_ctx = drained_ctx;
    composing_ctx.stream.composing_tool_payload = true;
    composing_ctx.stream.turn_started_ms = 1_000;
    composing_ctx.now_ms = 13_000;
    var stalled_buf: [256]u8 = undefined;
    switch (frameOwnedActivityProjection(&stalled_buf, &shell, composing_ctx, null)) {
        .turn_thinking => |thinking| {
            try std.testing.expectEqualStrings("• (12s) (↑50k ↓1.2k)", thinking.label);
            try std.testing.expectEqual(ActivityProjection.Tone.thinking, thinking.tone);
        },
        .none, .tool_slot => return error.TestUnexpectedResult,
    }

    var tail_ctx = ctx;
    tail_ctx.stream.active = false;
    tail_ctx.completed_assistant_presentation_tail = true;
    var tail_buf: [256]u8 = undefined;
    switch (frameOwnedActivityProjection(&tail_buf, &shell, tail_ctx, null)) {
        .turn_thinking => |thinking| {
            try std.testing.expectEqualStrings("  (↑50k ↓1.2k)", thinking.label);
            try std.testing.expectEqual(ActivityProjection.Tone.neutral, thinking.tone);
        },
        .none, .tool_slot => return error.TestUnexpectedResult,
    }
}

test "static turn status reserves wrapped activity rows" {
    const label = "⚠ API access denied · HTTP 403 · Provider: wafer · Your team has restricted access to this provider. Contact the owner of the account.";
    const projection: ActivityProjection = .{ .turn_thinking = .{
        .label = label,
        .tone = .danger,
    } };
    const normal_thinking: ActivityProjection = .{ .turn_thinking = .{
        .label = label,
        .tone = .thinking,
    } };

    try std.testing.expectEqual(@as(u16, 1), activityProjectionRows(normal_thinking, 42));
    try std.testing.expect(activityProjectionRows(projection, 42) > 1);
    try std.testing.expectEqual(@as(u16, 1), activityProjectionRows(projection, 160));
}

test "static turn status wraps at word boundaries" {
    const label = "⚠ aaaaaaaa bbbbbbbbbbb";
    const projection: ActivityProjection = .{ .turn_thinking = .{
        .label = label,
        .tone = .danger,
    } };

    try std.testing.expectEqual(@as(u16, 3), activityProjectionRows(projection, 12));
    try std.testing.expectEqual(@as(u16, 1), activityProjectionRows(projection, 30));
}

test "frame-owned activity uses clipped command activity label" {
    var input = InputRuntime{};
    defer input.deinit(std.testing.allocator);

    var shell = TranscriptRuntime{
        .last_visible_transcript_tail_kind = .assistant_turn,
    };
    defer shell.deinit(std.testing.allocator);
    const ctx: RenderContext = .{
        .stream = .{
            .active = true,
            .command_count = 1,
            .last_activity_kind = .command,
            .token_progress = .{ .input_tokens = 10, .output_tokens = 20 },
        },
        .has_credential = true,
        .model = "gpt-5.1",
        .queued_count = 0,
        .subagent_count = 0,
        .subagent_view_active = false,
        .selected_subagent_id = null,
        .selected_subagent_label = null,
        .selected_subagent_status = null,
        .activity = .{ .tool_slot = .{
            .entry_id = 123,
            .fallback_label = "running read-only tools",
            .active = true,
            .kind = .command,
        } },
        .input = &input,
    };

    var active_buf: [256]u8 = undefined;
    switch (frameOwnedActivityProjection(&active_buf, &shell, ctx, null)) {
        .turn_thinking => |thinking| {
            try std.testing.expectEqual(ActivityProjection.Tone.thinking, thinking.tone);
            try std.testing.expectEqualStrings("• Thinking (↑10 ↓20)", thinking.label);
        },
        .none, .tool_slot => return error.TestUnexpectedResult,
    }
}
