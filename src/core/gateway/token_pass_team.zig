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

/// The source an owner names for an answer it reads from the catalog's
/// marks, which is fx's reading rather than AI Gateway answering.
pub const catalog_source = "catalog";

var mutex: std.Io.Mutex = .init;
/// The team's answer: the one saved from an earlier run, then the ones AI
/// Gateway gives in this run.
var answer: ?token_pass.Answer = null;
/// Whether AI Gateway answered in this run: the credits check, `/credits`, a
/// response Token Pass served, or a no-pass denial.
var heard_this_run = false;
/// The models the catalog marks as paid by the team's Token Pass.
var models: token_pass.TeamModels = .{};

/// Takes the team's answer. `heard` is true for one AI Gateway gave in this
/// run, and false for the answer saved from an earlier run.
pub fn publishAnswer(new_answer: ?token_pass.Answer, heard: bool) void {
    mutex.lockUncancelable(io_mod.getIo());
    defer mutex.unlock(io_mod.getIo());
    answer = new_answer;
    if (heard) heard_this_run = true;
}

/// Takes the Token Pass models an AI Gateway catalog marks. It does not set
/// the answer; see `catalogAnswers`.
pub fn publishCatalog(entries: []const model_catalog.ModelCatalogEntry) void {
    var marked: token_pass.TeamModels = .{};
    for (entries) |entry| {
        if (!entry.token_pass) continue;
        if (!marked.add(entry.id)) debug_trace.logf("token_pass", "catalog mark dropped id_len={d} reason=set_full_or_id_too_long", .{entry.id.len});
    }
    mutex.lockUncancelable(io_mod.getIo());
    defer mutex.unlock(io_mod.getIo());
    models = marked;
}

/// Whether the catalog's marks answer for the team: AI Gateway marks models
/// only for a team with an active pass, so a catalog with marks says the team
/// has Token Pass until AI Gateway answers otherwise in this run. An answer
/// from this run wins when the two disagree, and a catalog without marks says
/// nothing.
pub fn catalogAnswers() bool {
    mutex.lockUncancelable(io_mod.getIo());
    defer mutex.unlock(io_mod.getIo());
    return catalogAnswersLocked();
}

fn catalogAnswersLocked() bool {
    return !heard_this_run and models.count > 0;
}

/// Forgets the team, for a new credential or provider.
pub fn clear() void {
    mutex.lockUncancelable(io_mod.getIo());
    defer mutex.unlock(io_mod.getIo());
    answer = null;
    heard_this_run = false;
    models = .{};
}

/// A copy of what the process knows of the team.
pub fn snapshot() token_pass.Team {
    mutex.lockUncancelable(io_mod.getIo());
    defer mutex.unlock(io_mod.getIo());
    return .{ .has_pass = answer == .has_pass or catalogAnswersLocked(), .models = models };
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
    const current = snapshot();
    return current.paysFor(model);
}

test "token pass team: marks answer until AI Gateway does, and an answer from this run wins" {
    defer clear();
    clear();
    var entries = [_]model_catalog.ModelCatalogEntry{
        .{ .id = @constCast("zai/glm-5.3"), .model_type = @constCast("language"), .token_pass = true },
        .{ .id = @constCast("acme/new-pass-model"), .model_type = @constCast("language"), .token_pass = true },
        .{ .id = @constCast("openai/gpt-6"), .model_type = @constCast("language") },
    };

    // A saved "no pass" from an earlier run gives way to this run's marks.
    publishAnswer(.no_pass, false);
    publishCatalog(&entries);
    try std.testing.expect(catalogAnswers());
    try std.testing.expect(paysFor("zai/glm-5.3"));
    try std.testing.expect(paysFor("acme/new-pass-model"));
    try std.testing.expect(!paysFor("openai/gpt-6"));

    // AI Gateway saying "no pass" in this run wins over the marks, which then
    // only name the models.
    publishAnswer(.no_pass, true);
    try std.testing.expect(!catalogAnswers());
    try std.testing.expect(!snapshot().has_pass);
    try std.testing.expect(!paysFor("zai/glm-5.3"));
    try std.testing.expectEqual(@as(u8, 2), snapshot().models.count);

    // A catalog without marks says nothing: a saved "has pass" stands.
    clear();
    publishAnswer(.has_pass, false);
    entries[0].token_pass = false;
    entries[1].token_pass = false;
    publishCatalog(&entries);
    try std.testing.expect(!catalogAnswers());
    try std.testing.expect(snapshot().has_pass);
    try std.testing.expect(!paysFor("zai/glm-5.3"));

    clear();
    try std.testing.expect(!snapshot().has_pass);
    try std.testing.expectEqual(@as(u8, 0), snapshot().models.count);
}
