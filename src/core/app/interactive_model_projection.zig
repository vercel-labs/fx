const std = @import("std");
const input_completion_runtime = @import("input_completion_runtime.zig");
const model_capabilities = @import("../config/model_capabilities.zig");
const picker_state = @import("../input/picker_state.zig");
const provider_runtime = @import("provider_runtime.zig");
const command_specs = @import("../slash_commands/command_specs.zig");
const types = @import("../shared/types.zig");

pub const Buffer = struct {
    models: [32][]const u8 = undefined,
    efforts: [types.ReasoningEffort.max_options + 1]types.ReasoningEffort = undefined,
    effort_labels: [types.ReasoningEffort.max_options + 1][]const u8 = undefined,
    fast_labels: [2][]const u8 = undefined,
};

/// Strings borrow the application and Buffer until the next projection.
pub const Snapshot = struct {
    query: ?picker_state.ModelPickerQuery = null,
    stage: picker_state.ModelPickerStage = .model,
    items: []const []const u8 = &.{},
    selected_index: usize = 0,
    window_start: usize = 0,
    anchor: usize = 0,
    loading: bool = false,
    failed: bool = false,
};

pub fn project(comptime App: type, app: *App, buffer: *Buffer) Snapshot {
    var snapshot: Snapshot = .{
        .query = app.input_runtime.picker.activeModelPickerQuery(&app.input_runtime.edit_state),
    };
    if (snapshot.query) |picker_query| {
        snapshot.stage = picker_query.stage;
        snapshot.anchor = picker_query.token_start;
        switch (picker_query.stage) {
            .model => {
                const count = input_completion_runtime.CompletionRuntime(App).modelPickerCompletions(app, picker_query.query, &buffer.models);
                snapshot.items = buffer.models[0..count];
                snapshot.selected_index = input_completion_runtime.CompletionRuntime(App).modelPickerIndex(app, snapshot.items);
                snapshot.window_start = input_completion_runtime.CompletionRuntime(App).modelPickerWindowStart(app, count, snapshot.selected_index);
            },
            .effort => {
                const target = if (app.input_runtime.picker.hasPendingModelPickerSelection()) app.input_runtime.picker.model_picker_pending_model.items else provider_runtime.model(app);
                const capabilities = model_capabilities.resolveForApp(App, app, target);
                const effort_count = model_capabilities.reasoningEffortOptionCount(capabilities);
                for (0..effort_count) |i| {
                    buffer.efforts[i] = model_capabilities.reasoningEffortAtIndex(capabilities, i);
                    buffer.effort_labels[i] = buffer.efforts[i].displayLabel();
                }
                const count = picker_state.filterCompletionLabels(picker_query.query, buffer.effort_labels[0..effort_count], buffer.effort_labels[0..]);
                snapshot.items = buffer.effort_labels[0..count];
                snapshot.selected_index = app.input_runtime.picker.model_picker_effort_index;
                snapshot.window_start = app.input_runtime.picker.model_picker_effort_window_start;
            },
            .fast => {
                for (picker_state.model_picker_fast_options, 0..) |option, i| buffer.fast_labels[i] = option;
                const count = picker_state.filterCompletionLabels(picker_query.query, buffer.fast_labels[0..], buffer.fast_labels[0..]);
                snapshot.items = buffer.fast_labels[0..count];
                snapshot.selected_index = app.input_runtime.picker.model_picker_fast_index;
                snapshot.window_start = app.input_runtime.picker.model_picker_fast_window_start;
            },
        }
    }
    if (snapshot.query != null and snapshot.stage == .model) {
        snapshot.loading = app.isModelCacheLoading();
        snapshot.failed = app.isModelCacheFailed();
    }
    return snapshot;
}

/// Typed interaction intent; model changes still pass through the native picker.
pub const Action = union(enum) {
    open,
    move: i32,
    accept,
    back,
    dismiss,
};

pub fn apply(comptime App: type, app: *App, action: Action) !bool {
    const runtime = input_completion_runtime.CompletionRuntime(App);
    if (action == .open) {
        try runtime.openCurrentModelPicker(app);
        return true;
    }
    if (app.input_runtime.picker.activeModelPickerQuery(&app.input_runtime.edit_state) == null) return false;
    switch (action) {
        .open => unreachable,
        .move => |delta| runtime.navigateModelPicker(app, delta),
        .accept => return runtime.submitModelPicker(app),
        .back => return runtime.stepBackModelPicker(app),
        .dismiss => return runtime.dismissVisibleInlinePicker(app),
    }
    app.shell.render_requests.request(.footer);
    return true;
}

/// Writes semantic data before either terminal or HTML presentation.
pub fn writeJson(snapshot: Snapshot, writer: *std.Io.Writer) !void {
    try std.json.Stringify.value(.{
        .active = snapshot.query != null,
        .stage = snapshot.stage,
        .query = if (snapshot.query) |query| query.query else "",
        .items = snapshot.items,
        .selected_index = snapshot.selected_index,
        .loading = snapshot.loading,
        .failed = snapshot.failed,
    }, .{}, writer);
}

/// Reads command names and descriptions from the application's active registry.
pub fn writeCommandsJson(registry: command_specs.SlashRegistry, writer: *std.Io.Writer) !void {
    try writer.writeByte('[');
    for (registry.commands, 0..) |spec, index| {
        if (index != 0) try writer.writeByte(',');
        try std.json.Stringify.value(.{
            .command = spec.command,
            .aliases = spec.aliases,
            .description = spec.completion_description,
            .category = spec.presentation_category,
            .accepts_payload = spec.accepts_payload,
        }, .{}, writer);
    }
    try writer.writeByte(']');
}

test "interactive model projection writes semantic escaped labels" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    try writeJson(.{ .items = &.{ "a\"b", "line\nbreak" }, .loading = true }, &output.writer);
    const value = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, output.written(), .{});
    defer value.deinit();
    try std.testing.expect(!value.value.object.get("active").?.bool);
    try std.testing.expect(value.value.object.get("loading").?.bool);
    try std.testing.expectEqualStrings("a\"b", value.value.object.get("items").?.array.items[0].string);
}

test "interactive command projection uses supplied registry aliases" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    const commands = [_]command_specs.SlashSpec{.{
        .kind = .model,
        .command = "/model",
        .aliases = &.{"/choose"},
        .completion_description = "Choose model",
        .accepts_payload = true,
    }};
    try writeCommandsJson(.{ .commands = &commands }, &output.writer);
    const value = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, output.written(), .{});
    defer value.deinit();
    const entry = value.value.array.items[0].object;
    try std.testing.expectEqualStrings("/model", entry.get("command").?.string);
    try std.testing.expectEqualStrings("/choose", entry.get("aliases").?.array.items[0].string);
    try std.testing.expect(entry.get("accepts_payload").?.bool);
}
