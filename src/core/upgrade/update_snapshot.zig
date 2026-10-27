//! What `proto-fx update` found or did, rendered as text and JSON from the
//! same value (`output_contracts.UpdateSnapshot`).
const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Method = enum {
    /// Fast-forward and rebuild the checkout this binary was built from.
    source,
    /// Install the latest GitHub release of `update.repo`.
    release,

    pub fn parse(raw: []const u8) ?Method {
        if (std.ascii.eqlIgnoreCase(raw, "source")) return .source;
        if (std.ascii.eqlIgnoreCase(raw, "release")) return .release;
        return null;
    }
};

pub const Outcome = enum { up_to_date, available, updated, refused, failed };

/// What became of the supervisor daemon after an install.
pub const Supervisor = enum {
    /// No update was installed, or no supervisor was running.
    none,
    /// It already runs the installed binary.
    current,
    /// It was idle, so it stopped; the next terminal starts the new binary.
    restarted,
    /// A session is working or another terminal is attached, so it keeps
    /// the previous binary until its next idle exit.
    deferred,
    /// It predates this check, so it keeps the previous binary until its
    /// next idle exit.
    unknown,
};

pub const UpdateSnapshot = struct {
    method: Method,
    check_only: bool,
    outcome: Outcome,
    version: []const u8,
    revision: []const u8,
    checkout: []const u8 = "",
    branch: []const u8 = "",
    upstream: ?[]const u8 = null,
    head: []const u8 = "",
    ahead: u32 = 0,
    behind: u32 = 0,
    dirty: bool = false,
    fetch_error: ?[]const u8 = null,
    repo: []const u8 = "",
    latest_version: []const u8 = "",
    installed_path: []const u8 = "",
    supervisor: Supervisor = .none,
    message: []const u8 = "",

    pub fn ok(self: UpdateSnapshot) bool {
        return switch (self.outcome) {
            .refused, .failed => false,
            else => true,
        };
    }

    pub fn render(self: UpdateSnapshot, alloc: Allocator, json: bool) ![]u8 {
        return if (json) self.renderJson(alloc) else self.renderText(alloc);
    }

    pub fn renderText(self: UpdateSnapshot, alloc: Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();
        const w = &out.writer;
        try w.print("Current: proto-fx {s} ({s})\n", .{ self.version, short(self.revision) });
        switch (self.method) {
            .source => if (self.checkout.len > 0) {
                try w.print("Source: {s}", .{self.checkout});
                if (self.branch.len > 0) try w.print(" on {s}", .{self.branch});
                if (self.upstream) |upstream| try w.print(", tracking {s}", .{upstream});
                try w.writeByte('\n');
            },
            .release => {
                try w.print("Releases: {s}\n", .{if (self.repo.len > 0) self.repo else "(not configured)"});
                if (self.latest_version.len > 0) try w.print("Latest release: {s}\n", .{self.latest_version});
            },
        }
        if (self.fetch_error) |reason| try w.print("Warning: git fetch failed ({s}); using the last fetched state.\n", .{reason});
        switch (self.outcome) {
            .up_to_date => try w.writeAll("✓ Already up to date\n"),
            .available => {
                try w.writeAll("Update available: ");
                try self.writeChange(w);
                try w.writeAll(". Run proto-fx update, or /update in a session.\n");
            },
            .updated => {
                try w.writeAll("✓ Updated");
                if (self.method == .source and self.head.len > 0) try w.print(" to {s}", .{short(self.head)});
                if (self.method == .release and self.latest_version.len > 0) try w.print(" to {s}", .{self.latest_version});
                if (self.installed_path.len > 0) try w.print(" at {s}", .{self.installed_path});
                try w.writeByte('\n');
                switch (self.supervisor) {
                    .restarted => try w.writeAll("The idle supervisor stopped; the next session starts it on the new binary.\n"),
                    .deferred => try w.writeAll("The supervisor keeps the previous binary while sessions are working or attached. It switches after its next idle exit.\n"),
                    .unknown => try w.writeAll("The running supervisor keeps the previous binary until its next idle exit. Run proto-fx daemon stop when no turns are running to switch now.\n"),
                    .none, .current => {},
                }
            },
            .refused, .failed => try w.print("Update {s}: {s}\n", .{ if (self.outcome == .refused) "refused" else "failed", self.message }),
        }
        return out.toOwnedSlice();
    }

    fn writeChange(self: UpdateSnapshot, w: *std.Io.Writer) !void {
        if (self.method == .release) return w.print("{s}", .{self.latest_version});
        if (self.behind > 0) {
            try w.print("{d} new commit{s} on {s}", .{ self.behind, if (self.behind == 1) "" else "s", self.upstream orelse "the upstream" });
        } else {
            try w.print("the checkout is at {s}, which this binary was not built from", .{short(self.head)});
        }
    }

    pub fn renderJson(self: UpdateSnapshot, alloc: Allocator) ![]u8 {
        return std.json.Stringify.valueAlloc(alloc, .{
            .kind = "update",
            .ok = self.ok(),
            .method = @tagName(self.method),
            .check = self.check_only,
            .outcome = @tagName(self.outcome),
            .version = self.version,
            .revision = self.revision,
            .checkout = self.checkout,
            .branch = self.branch,
            .upstream = self.upstream,
            .head = self.head,
            .ahead = self.ahead,
            .behind = self.behind,
            .dirty = self.dirty,
            .fetch_error = self.fetch_error,
            .repo = self.repo,
            .latest_version = self.latest_version,
            .installed_path = self.installed_path,
            .supervisor = @tagName(self.supervisor),
            .message = self.message,
        }, .{});
    }
};

fn short(revision: []const u8) []const u8 {
    return revision[0..@min(revision.len, 12)];
}

test "update snapshot renders a source check as text and JSON" {
    const alloc = std.testing.allocator;
    const snapshot: UpdateSnapshot = .{
        .method = .source,
        .check_only = true,
        .outcome = .available,
        .version = "0.3.0",
        .revision = "aaaaaaaaaaaa",
        .checkout = "/Users/example/proto-fx",
        .branch = "main",
        .upstream = "origin/main",
        .head = "aaaaaaaaaaaaaaaa",
        .behind = 2,
    };
    const text = try snapshot.render(alloc, false);
    defer alloc.free(text);
    try std.testing.expectEqualStrings(
        \\Current: proto-fx 0.3.0 (aaaaaaaaaaaa)
        \\Source: /Users/example/proto-fx on main, tracking origin/main
        \\Update available: 2 new commits on origin/main. Run proto-fx update, or /update in a session.
        \\
    , text);
    const json = try snapshot.render(alloc, true);
    defer alloc.free(json);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("available", parsed.value.object.get("outcome").?.string);
    try std.testing.expectEqual(@as(i64, 2), parsed.value.object.get("behind").?.integer);
    try std.testing.expect(parsed.value.object.get("ok").?.bool);
}

test "update snapshot names a refusal and a deferred supervisor" {
    const alloc = std.testing.allocator;
    const refused: UpdateSnapshot = .{ .method = .source, .check_only = false, .outcome = .refused, .version = "0.3.0", .revision = "a", .message = "the checkout has uncommitted changes" };
    const text = try refused.renderText(alloc);
    defer alloc.free(text);
    try std.testing.expect(std.mem.endsWith(u8, text, "Update refused: the checkout has uncommitted changes\n"));
    try std.testing.expect(!refused.ok());
    const updated: UpdateSnapshot = .{ .method = .release, .check_only = false, .outcome = .updated, .version = "0.3.0", .revision = "a", .latest_version = "0.4.0", .installed_path = "/Users/example/.local/bin/proto-fx", .supervisor = .deferred };
    const updated_text = try updated.renderText(alloc);
    defer alloc.free(updated_text);
    try std.testing.expect(std.mem.find(u8, updated_text, "✓ Updated to 0.4.0 at /Users/example/.local/bin/proto-fx\n") != null);
    try std.testing.expect(std.mem.find(u8, updated_text, "next idle exit") != null);
}
