const std = @import("std");

pub const max_source_entries: usize = 256;

pub const Anchor = union(enum) {
    tail,
    entry_index: usize,
    /// A page of an older compaction cycle the transcript reads from the
    /// session log: `back` cycles before the held entries (1 is the newest),
    /// around one of that cycle's entries. `maxInt` is its last entry.
    archive: Archive,
};

pub const Archive = struct {
    back: u32,
    entry_index: usize,
};

pub const Request = struct {
    content_revision: u64,
    cols: u16,
    anchor: Anchor,
};

pub const SourceRange = struct {
    start: usize,
    end: usize,

    pub fn len(self: SourceRange) usize {
        return self.end - self.start;
    }
};

pub fn sourceRange(request: Request, total_entries: usize) SourceRange {
    if (total_entries <= max_source_entries) {
        return .{ .start = 0, .end = total_entries };
    }

    const latest_start = total_entries - max_source_entries;
    const requested_index = switch (request.anchor) {
        .tail => return .{ .start = latest_start, .end = total_entries },
        .entry_index => |index| index,
        .archive => |archive| archive.entry_index,
    };
    const anchor_index = @min(requested_index, total_entries - 1);
    const start = @min(anchor_index -| max_source_entries / 2, latest_start);
    return .{ .start = start, .end = start + max_source_entries };
}

pub fn sameRequest(lhs: Request, rhs: Request) bool {
    return lhs.content_revision == rhs.content_revision and
        lhs.cols == rhs.cols and
        std.meta.eql(lhs.anchor, rhs.anchor);
}

pub fn sameSurface(lhs: Request, rhs: Request) bool {
    return lhs.cols == rhs.cols and std.meta.eql(lhs.anchor, rhs.anchor);
}

pub fn previousAnchor(range: SourceRange) ?Anchor {
    if (range.start == 0) return null;
    return .{ .entry_index = range.start - 1 };
}

pub fn nextAnchor(range: SourceRange, total_entries: usize) ?Anchor {
    if (range.end >= total_entries) return null;
    return .{ .entry_index = range.end };
}

test "full transcript page range stays bounded at the tail" {
    const request = Request{
        .content_revision = 41,
        .cols = 80,
        .anchor = .tail,
    };
    const range = sourceRange(request, 10_000);

    try std.testing.expectEqual(@as(usize, 10_000), range.end);
    try std.testing.expectEqual(max_source_entries, range.len());
}

test "full transcript page range centers an entry without crossing bounds" {
    const middle = sourceRange(.{
        .content_revision = 42,
        .cols = 120,
        .anchor = .{ .entry_index = 5_000 },
    }, 10_000);
    try std.testing.expect(middle.start <= 5_000);
    try std.testing.expect(middle.end > 5_000);
    try std.testing.expectEqual(max_source_entries, middle.len());

    const head = sourceRange(.{
        .content_revision = 42,
        .cols = 120,
        .anchor = .{ .entry_index = 0 },
    }, 3);
    try std.testing.expectEqual(SourceRange{ .start = 0, .end = 3 }, head);
}

test "full transcript page request identity includes revision width and anchor" {
    const request = Request{
        .content_revision = 73,
        .cols = 96,
        .anchor = .tail,
    };
    try std.testing.expect(sameRequest(request, .{
        .content_revision = 73,
        .cols = 96,
        .anchor = .tail,
    }));
    try std.testing.expect(!sameRequest(request, .{
        .content_revision = 72,
        .cols = 96,
        .anchor = .tail,
    }));
    try std.testing.expect(!sameRequest(request, .{
        .content_revision = 73,
        .cols = 80,
        .anchor = .tail,
    }));
    try std.testing.expect(!sameRequest(request, .{
        .content_revision = 73,
        .cols = 96,
        .anchor = .{ .entry_index = 42 },
    }));
}

test "full transcript page surface ignores revisions but not width or anchor" {
    const original = Request{
        .content_revision = 73,
        .cols = 96,
        .anchor = .tail,
    };
    var changed = original;
    changed.content_revision = 74;
    try std.testing.expect(sameSurface(original, changed));

    changed.cols = 80;
    try std.testing.expect(!sameSurface(original, changed));
    changed.cols = original.cols;
    changed.anchor = .{ .entry_index = 42 };
    try std.testing.expect(!sameSurface(original, changed));
}

test "full transcript page navigation stops at document boundaries" {
    const previous = previousAnchor(.{ .start = 256, .end = 512 });
    try std.testing.expect(previous != null);
    try std.testing.expectEqual(
        Anchor{ .entry_index = 255 },
        previous.?,
    );
    try std.testing.expect(previousAnchor(.{ .start = 0, .end = 256 }) == null);

    const next = nextAnchor(.{ .start = 256, .end = 512 }, 1_000);
    try std.testing.expect(next != null);
    try std.testing.expectEqual(
        Anchor{ .entry_index = 512 },
        next.?,
    );
    try std.testing.expect(nextAnchor(.{ .start = 744, .end = 1_000 }, 1_000) == null);
}

test "an archive page ranges over its own cycle's entries" {
    const request = Request{
        .content_revision = 1,
        .cols = 80,
        .anchor = .{ .archive = .{ .back = 2, .entry_index = std.math.maxInt(usize) } },
    };
    const tail = sourceRange(request, 1000);
    try std.testing.expectEqual(@as(usize, 1000), tail.end);
    try std.testing.expectEqual(max_source_entries, tail.len());
    var middle = request;
    middle.anchor.archive.entry_index = 500;
    const range = sourceRange(middle, 1000);
    try std.testing.expect(range.start <= 500 and 500 < range.end);
    try std.testing.expect(!sameRequest(request, middle));
}
