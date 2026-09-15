//! Pure Puppetmaster swarm snapshot: parse the CLI's JSON and render it as text.
//!
//! Puppetmaster owns the orchestration truth and the on-disk state; fx only owns
//! how it looks in the transcript. This module therefore holds no process, no
//! filesystem, and no app state: it takes the two JSON documents a swarm read
//! returns and produces owned, bounded text.
//!
//! The field set mirrors `puppetmaster status <job>` and
//! `puppetmaster feed <job> --json` as they exist today. Every field is optional
//! on read, because Puppetmaster adds keys over time and a schema addition must
//! not break the view.

const std = @import("std");

const Allocator = std.mem.Allocator;

/// Keeps a single rendered line from swallowing scrollback.
pub const max_field_bytes: usize = 160;
pub const max_feed_items: usize = 12;

pub const Counts = struct {
    complete: usize = 0,
    running: usize = 0,
    queued: usize = 0,
    blocked: usize = 0,
    failed: usize = 0,
    other: usize = 0,

    pub fn total(self: Counts) usize {
        return self.complete + self.running + self.queued + self.blocked + self.failed + self.other;
    }
};

pub const FeedItem = struct {
    artifact_type: []u8,
    event: []u8,
    at: []u8,

    fn deinit(self: FeedItem, alloc: Allocator) void {
        alloc.free(self.artifact_type);
        alloc.free(self.event);
        alloc.free(self.at);
    }
};

pub const Snapshot = struct {
    job_id: []u8,
    status: []u8,
    label: []u8,
    goal: []u8,
    counts: Counts,
    artifact_count: usize = 0,
    delivery_verdict: []u8,
    quality: []u8,
    trustworthy: ?bool = null,
    finding_count: usize = 0,
    feed: std.ArrayList(FeedItem) = .empty,

    pub fn deinit(self: *Snapshot, alloc: Allocator) void {
        alloc.free(self.job_id);
        alloc.free(self.status);
        alloc.free(self.label);
        alloc.free(self.goal);
        alloc.free(self.delivery_verdict);
        alloc.free(self.quality);
        for (self.feed.items) |item| item.deinit(alloc);
        self.feed.deinit(alloc);
        self.* = undefined;
    }
};

/// A read failed in a way the caller should surface rather than retry blindly.
pub const ParseError = error{
    InvalidSwarmJson,
    SwarmShapeUnexpected,
};

fn emptyString(alloc: Allocator) ![]u8 {
    return alloc.alloc(u8, 0);
}

fn dupeString(alloc: Allocator, value: ?std.json.Value) ![]u8 {
    const present = value orelse return emptyString(alloc);
    const text = switch (present) {
        .string => |s| s,
        .integer => |n| return std.fmt.allocPrint(alloc, "{d}", .{n}),
        .float => |n| return std.fmt.allocPrint(alloc, "{d}", .{n}),
        .bool => |b| if (b) "true" else "false",
        else => return emptyString(alloc),
    };
    return alloc.dupe(u8, text);
}

fn objectField(value: std.json.Value, key: []const u8) ?std.json.Value {
    if (value != .object) return null;
    return value.object.get(key);
}

fn stringField(alloc: Allocator, value: std.json.Value, key: []const u8) ![]u8 {
    return dupeString(alloc, objectField(value, key));
}

fn usizeField(value: std.json.Value, key: []const u8) usize {
    const raw = objectField(value, key) orelse return 0;
    return switch (raw) {
        .integer => |n| if (n < 0) 0 else @intCast(n),
        .float => |n| if (n < 0) 0 else @intFromFloat(n),
        else => 0,
    };
}

fn boolField(value: std.json.Value, key: []const u8) ?bool {
    const raw = objectField(value, key) orelse return null;
    return switch (raw) {
        .bool => |b| b,
        else => null,
    };
}

fn countsFrom(value: std.json.Value) Counts {
    var counts = Counts{};
    if (value != .object) return counts;
    var it = value.object.iterator();
    while (it.next()) |entry| {
        const raw = entry.value_ptr.*;
        const n: usize = switch (raw) {
            .integer => |v| if (v < 0) 0 else @intCast(v),
            .float => |v| if (v < 0) 0 else @intFromFloat(v),
            else => 0,
        };
        if (std.mem.eql(u8, entry.key_ptr.*, "complete")) {
            counts.complete += n;
        } else if (std.mem.eql(u8, entry.key_ptr.*, "running")) {
            counts.running += n;
        } else if (std.mem.eql(u8, entry.key_ptr.*, "queued")) {
            counts.queued += n;
        } else if (std.mem.eql(u8, entry.key_ptr.*, "blocked")) {
            counts.blocked += n;
        } else if (std.mem.eql(u8, entry.key_ptr.*, "failed")) {
            counts.failed += n;
        } else {
            counts.other += n;
        }
    }
    return counts;
}

/// Parses `puppetmaster status <job>` output and attaches feed rows when present.
/// The caller owns the returned snapshot and must call `deinit`.
pub fn parse(
    alloc: Allocator,
    status_json: []const u8,
    feed_json: ?[]const u8,
) !Snapshot {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, status_json, .{}) catch
        return ParseError.InvalidSwarmJson;
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return ParseError.SwarmShapeUnexpected;

    const job = objectField(root, "job") orelse return ParseError.SwarmShapeUnexpected;
    var snapshot = Snapshot{
        .job_id = try stringField(alloc, job, "id"),
        .status = try stringField(alloc, job, "status"),
        .label = try stringField(alloc, job, "label"),
        .goal = try stringField(alloc, job, "goal"),
        .counts = countsFrom(objectField(root, "task_counts") orelse .null),
        .artifact_count = usizeField(root, "artifact_count"),
        .delivery_verdict = try stringField(alloc, objectField(root, "delivery") orelse .null, "verdict"),
        .quality = try stringField(alloc, objectField(root, "outcome") orelse .null, "quality"),
        .trustworthy = boolField(objectField(root, "outcome") orelse .null, "trustworthy"),
    };
    errdefer snapshot.deinit(alloc);

    if (feed_json) |text| {
        var feed_parsed = std.json.parseFromSlice(std.json.Value, alloc, text, .{}) catch
            return ParseError.InvalidSwarmJson;
        defer feed_parsed.deinit();
        const items = switch (feed_parsed.value) {
            .array => |array| array.items,
            // A single object is still a usable view of one event.
            .object => &[_]std.json.Value{feed_parsed.value},
            else => return ParseError.SwarmShapeUnexpected,
        };
        for (items) |item| {
            const artifact = objectField(item, "artifact") orelse .null;
            try snapshot.feed.append(alloc, .{
                .artifact_type = try stringField(alloc, artifact, "type"),
                .event = try stringField(alloc, item, "event"),
                .at = try stringField(alloc, item, "at"),
            });
            if (std.mem.eql(u8, snapshot.feed.items[snapshot.feed.items.len - 1].artifact_type, "finding")) {
                snapshot.finding_count += 1;
            }
        }
    }

    return snapshot;
}

/// One line of a multi-line field, clipped to a visible width.
fn writeClipped(writer: *std.Io.Writer, text: []const u8) !void {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    const first_line_end = std.mem.indexOfAny(u8, trimmed, "\r\n") orelse trimmed.len;
    const line = std.mem.trim(u8, trimmed[0..first_line_end], " \t");
    if (line.len <= max_field_bytes) return writer.writeAll(line);
    // Reserve one byte for the ellipsis so the clipped line is never wider than
    // the budget it advertises.
    try writer.writeAll(line[0 .. max_field_bytes - 1]);
    try writer.writeAll("\u{2026}");
}

fn writeCounts(writer: *std.Io.Writer, counts: Counts) !void {
    try writer.print("{d} total", .{counts.total()});
    if (counts.complete > 0) try writer.print(" \u{b7} {d} complete", .{counts.complete});
    if (counts.running > 0) try writer.print(" \u{b7} {d} running", .{counts.running});
    if (counts.queued > 0) try writer.print(" \u{b7} {d} queued", .{counts.queued});
    if (counts.blocked > 0) try writer.print(" \u{b7} {d} blocked", .{counts.blocked});
    if (counts.failed > 0) try writer.print(" \u{b7} {d} failed", .{counts.failed});
}

/// Renders the snapshot as inline lines. The caller owns the returned bytes.
pub fn render(alloc: Allocator, snapshot: Snapshot, findings_only: bool) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    const writer = &out.writer;

    if (snapshot.job_id.len > 0) {
        try writer.writeAll("swarm ");
        try writeClipped(writer, snapshot.job_id);
        if (snapshot.status.len > 0) {
            try writer.writeAll(" \u{b7} ");
            try writeClipped(writer, snapshot.status);
        }
        try writer.writeByte('\n');
    }

    if (!findings_only) {
        if (snapshot.label.len > 0) {
            try writer.writeAll("  ");
            try writeClipped(writer, snapshot.label);
            try writer.writeByte('\n');
        }
        if (snapshot.goal.len > 0) {
            try writer.writeAll("  goal: ");
            try writeClipped(writer, snapshot.goal);
            try writer.writeByte('\n');
        }
        try writer.writeAll("  tasks: ");
        try writeCounts(writer, snapshot.counts);
        try writer.print(" \u{b7} {d} artifacts\n", .{snapshot.artifact_count});
        if (snapshot.delivery_verdict.len > 0 or snapshot.quality.len > 0) {
            try writer.writeAll("  delivery: ");
            if (snapshot.delivery_verdict.len > 0) try writeClipped(writer, snapshot.delivery_verdict);
            if (snapshot.quality.len > 0) {
                try writer.writeAll(" \u{b7} quality ");
                try writeClipped(writer, snapshot.quality);
            }
            if (snapshot.trustworthy) |trustworthy| {
                try writer.writeAll(if (trustworthy) " \u{b7} trustworthy" else " \u{b7} untrusted");
            }
            try writer.writeByte('\n');
        }
    }

    try writer.print("  findings: {d}\n", .{snapshot.finding_count});

    if (snapshot.feed.items.len > 0) {
        try writer.writeAll("  recent:\n");
        const shown = @min(snapshot.feed.items.len, max_feed_items);
        for (snapshot.feed.items[0..shown]) |item| {
            try writer.writeAll("    ");
            if (item.artifact_type.len > 0) {
                try writeClipped(writer, item.artifact_type);
            } else {
                try writer.writeAll("event");
            }
            if (item.event.len > 0) {
                try writer.writeAll(" \u{b7} ");
                try writeClipped(writer, item.event);
            }
            try writer.writeByte('\n');
        }
        if (snapshot.feed.items.len > shown) {
            try writer.print("    \u{2026} {d} more\n", .{snapshot.feed.items.len - shown});
        }
    }

    return out.toOwnedSlice();
}

/// Renders a short failure notice for a read that could not produce a snapshot.
pub fn renderFailure(alloc: Allocator, reason: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "swarm unavailable: {s}", .{reason});
}

const captured_status =
    \\{
    \\  "job": {
    \\    "id": "job_01054acb05c0",
    \\    "status": "complete",
    \\    "label": "kernel analyze request",
    \\    "goal": "Role: analysis\nGoal: check for open PRs.\nSecond line ignored."
    \\  },
    \\  "task_counts": {"complete": 1},
    \\  "artifact_count": 4,
    \\  "delivery": {"verdict": "delivered"},
    \\  "outcome": {"quality": "ok", "trustworthy": true}
    \\}
;

const captured_feed =
    \\[
    \\  {"id": 1, "at": "2026-08-28T05:21:59+00:00", "event": "artifact.saved",
    \\   "artifact": {"task_id": "task_1", "type": "finding", "payload": {}}},
    \\  {"id": 2, "at": "2026-08-28T05:21:59+00:00", "event": "artifact.saved",
    \\   "artifact": {"task_id": "task_1", "type": "verification", "payload": {}}}
    \\]
;

test "parses a captured status and feed into a snapshot" {
    const alloc = std.testing.allocator;
    var snapshot = try parse(alloc, captured_status, captured_feed);
    defer snapshot.deinit(alloc);

    try std.testing.expectEqualStrings("job_01054acb05c0", snapshot.job_id);
    try std.testing.expectEqualStrings("complete", snapshot.status);
    try std.testing.expectEqual(@as(usize, 1), snapshot.counts.complete);
    try std.testing.expectEqual(@as(usize, 1), snapshot.counts.total());
    try std.testing.expectEqual(@as(usize, 4), snapshot.artifact_count);
    try std.testing.expectEqualStrings("delivered", snapshot.delivery_verdict);
    try std.testing.expectEqualStrings("ok", snapshot.quality);
    try std.testing.expect(snapshot.trustworthy.?);
    try std.testing.expectEqual(@as(usize, 2), snapshot.feed.items.len);
    try std.testing.expectEqual(@as(usize, 1), snapshot.finding_count);
    try std.testing.expectEqualStrings("finding", snapshot.feed.items[0].artifact_type);
}

test "renders the job, counts, delivery, and feed" {
    const alloc = std.testing.allocator;
    var snapshot = try parse(alloc, captured_status, captured_feed);
    defer snapshot.deinit(alloc);

    const text = try render(alloc, snapshot, false);
    defer alloc.free(text);

    try std.testing.expect(std.mem.find(u8, text, "swarm job_01054acb05c0 \u{b7} complete") != null);
    try std.testing.expect(std.mem.find(u8, text, "tasks: 1 total \u{b7} 1 complete \u{b7} 4 artifacts") != null);
    try std.testing.expect(std.mem.find(u8, text, "delivery: delivered \u{b7} quality ok \u{b7} trustworthy") != null);
    try std.testing.expect(std.mem.find(u8, text, "findings: 1") != null);
    // Only the first line of multi-line goal prose reaches the transcript.
    try std.testing.expect(std.mem.find(u8, text, "Second line ignored") == null);
}

test "findings-only mode drops the goal and task detail" {
    const alloc = std.testing.allocator;
    var snapshot = try parse(alloc, captured_status, captured_feed);
    defer snapshot.deinit(alloc);

    const text = try render(alloc, snapshot, true);
    defer alloc.free(text);

    try std.testing.expect(std.mem.find(u8, text, "findings: 1") != null);
    try std.testing.expect(std.mem.find(u8, text, "tasks:") == null);
    try std.testing.expect(std.mem.find(u8, text, "goal:") == null);
}

test "clips an over-long goal to the field budget" {
    const alloc = std.testing.allocator;
    var long_goal: std.ArrayList(u8) = .empty;
    defer long_goal.deinit(alloc);
    try long_goal.appendSlice(alloc, "{\"job\":{\"id\":\"job_x\",\"goal\":\"");
    try long_goal.appendNTimes(alloc, 'a', max_field_bytes * 3);
    try long_goal.appendSlice(alloc, "\"}}");

    var snapshot = try parse(alloc, long_goal.items, null);
    defer snapshot.deinit(alloc);
    const text = try render(alloc, snapshot, false);
    defer alloc.free(text);

    const line = std.mem.find(u8, text, "goal: ").?;
    const end = std.mem.findScalar(u8, text[line..], '\n').?;
    // "  goal: " prefix plus the clipped budget.
    try std.testing.expect(end <= "  goal: ".len + max_field_bytes);
    try std.testing.expect(std.mem.find(u8, text[line..][0..end], "\u{2026}") != null);
}

test "missing optional fields degrade instead of failing" {
    const alloc = std.testing.allocator;
    var snapshot = try parse(alloc, "{\"job\":{\"id\":\"job_min\"}}", null);
    defer snapshot.deinit(alloc);

    try std.testing.expectEqualStrings("job_min", snapshot.job_id);
    try std.testing.expectEqualStrings("", snapshot.status);
    try std.testing.expectEqual(@as(usize, 0), snapshot.counts.total());
    try std.testing.expect(snapshot.trustworthy == null);

    const text = try render(alloc, snapshot, false);
    defer alloc.free(text);
    try std.testing.expect(std.mem.find(u8, text, "findings: 0") != null);
}

test "rejects malformed and wrongly shaped documents" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(ParseError.InvalidSwarmJson, parse(alloc, "not json", null));
    try std.testing.expectError(ParseError.SwarmShapeUnexpected, parse(alloc, "[]", null));
    try std.testing.expectError(ParseError.SwarmShapeUnexpected, parse(alloc, "{}", null));
    try std.testing.expectError(
        ParseError.InvalidSwarmJson,
        parse(alloc, captured_status, "not json"),
    );
}

test "counts tolerate an added status key without miscounting" {
    const alloc = std.testing.allocator;
    var snapshot = try parse(
        alloc,
        "{\"job\":{\"id\":\"j\"},\"task_counts\":{\"complete\":2,\"running\":1,\"cancelled\":3}}",
        null,
    );
    defer snapshot.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 2), snapshot.counts.complete);
    try std.testing.expectEqual(@as(usize, 1), snapshot.counts.running);
    try std.testing.expectEqual(@as(usize, 3), snapshot.counts.other);
    try std.testing.expectEqual(@as(usize, 6), snapshot.counts.total());
}
