//! What the process knows of its AI Gateway team's Token Pass: whether the
//! team has one, and the models AI Gateway marks as paid by it in the model
//! catalog. A process has one AI Gateway credential at a time, so one value
//! serves all its sessions and threads. The owners of the answer and of the
//! catalog publish each change; any thread reads, such as the permission
//! reviewer and the vision tool, which run off the main thread.
const std = @import("std");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const model_catalog = @import("model_catalog.zig");
const token_pass = @import("token_pass.zig");

var mutex: std.Io.Mutex = .init;
var team: token_pass.Team = .{};

pub fn publishHasPass(has_pass: bool) void {
    mutex.lockUncancelable(io_mod.getIo());
    defer mutex.unlock(io_mod.getIo());
    team.has_pass = has_pass;
}

/// Takes the Token Pass models an AI Gateway catalog marks. AI Gateway marks
/// models only for a team with an active pass, so a catalog with marks also
/// says the team has Token Pass; one without says nothing either way. Returns
/// whether the catalog marks any model.
pub fn publishCatalog(entries: []const model_catalog.ModelCatalogEntry) bool {
    var models: token_pass.TeamModels = .{};
    for (entries) |entry| {
        if (!entry.token_pass) continue;
        if (!models.add(entry.id)) debug_trace.logf("token_pass", "catalog mark dropped id_len={d} reason=set_full_or_id_too_long", .{entry.id.len});
    }
    mutex.lockUncancelable(io_mod.getIo());
    defer mutex.unlock(io_mod.getIo());
    team.models = models;
    if (models.count > 0) team.has_pass = true;
    return models.count > 0;
}

/// Forgets the team, for a new credential or provider.
pub fn clear() void {
    mutex.lockUncancelable(io_mod.getIo());
    defer mutex.unlock(io_mod.getIo());
    team = .{};
}

/// A copy of what the process knows of the team.
pub fn snapshot() token_pass.Team {
    mutex.lockUncancelable(io_mod.getIo());
    defer mutex.unlock(io_mod.getIo());
    return team;
}

/// fx's Token Pass model for a side call, as `token_pass.modelForSideCall`
/// chooses it for the process's team.
pub fn modelForSideCall(call: token_pass.SideCall, session_model: []const u8, fallback_model: []const u8) []const u8 {
    const current = snapshot();
    return token_pass.modelForSideCall(call, session_model, fallback_model, &current);
}

/// The Token Pass model that retries a summary, as
/// `token_pass.compactionFallback` chooses it for the process's team.
pub fn compactionFallback(primary: []const u8) ?[]const u8 {
    const current = snapshot();
    return token_pass.compactionFallback(primary, &current);
}

/// Whether the team's Token Pass pays for `model`.
pub fn paysFor(model: []const u8) bool {
    mutex.lockUncancelable(io_mod.getIo());
    defer mutex.unlock(io_mod.getIo());
    return team.paysFor(model);
}

test "token pass team: a catalog's marks name the team's models and say it has Token Pass" {
    defer clear();
    clear();
    var entries = [_]model_catalog.ModelCatalogEntry{
        .{ .id = @constCast("zai/glm-5.3"), .model_type = @constCast("language"), .token_pass = true },
        .{ .id = @constCast("acme/new-pass-model"), .model_type = @constCast("language"), .token_pass = true },
        .{ .id = @constCast("openai/gpt-6"), .model_type = @constCast("language") },
    };
    try std.testing.expect(publishCatalog(&entries));
    try std.testing.expect(paysFor("zai/glm-5.3"));
    try std.testing.expect(paysFor("acme/new-pass-model"));
    try std.testing.expect(!paysFor("openai/gpt-6"));

    // A catalog without marks, such as one loaded without sign-in, drops the
    // models but leaves the answer.
    entries[0].token_pass = false;
    entries[1].token_pass = false;
    try std.testing.expect(!publishCatalog(&entries));
    try std.testing.expect(snapshot().has_pass);
    try std.testing.expect(!paysFor("zai/glm-5.3"));

    // AI Gateway saying the team has no Token Pass ends it.
    entries[0].token_pass = true;
    _ = publishCatalog(&entries);
    publishHasPass(false);
    try std.testing.expect(!paysFor("zai/glm-5.3"));
    clear();
    try std.testing.expect(!snapshot().has_pass);
    try std.testing.expectEqual(@as(u8, 0), snapshot().models.count);
}
