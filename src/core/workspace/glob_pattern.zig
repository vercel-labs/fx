const std = @import("std");

const Allocator = std.mem.Allocator;

/// Maximum accepted glob pattern length in bytes.
pub const max_pattern_bytes: usize = 4096;

const max_pattern_segments: usize = max_pattern_bytes + 1;

/// Error set for compiling a borrowed glob pattern.
pub const CompileError = error{
    OutOfMemory,
    PatternTooLong,
};

/// Borrowed, pre-split glob pattern for matching workspace paths.
pub const Pattern = struct {
    raw: []const u8,
    segments: []const []const u8,
    has_path_separator: bool,

    /// Compiles a borrowed pattern. Caller owns the segment slice and releases it with deinit.
    pub fn compile(alloc: Allocator, raw: []const u8) CompileError!Pattern {
        if (raw.len > max_pattern_bytes) return error.PatternTooLong;

        const has_path_separator = std.mem.findScalar(u8, raw, '/') != null;
        if (!has_path_separator) {
            return .{
                .raw = raw,
                .segments = &.{},
                .has_path_separator = false,
            };
        }

        var segments: std.ArrayList([]const u8) = .empty;
        errdefer segments.deinit(alloc);
        try appendSegments(alloc, raw, &segments);
        return .{
            .raw = raw,
            .segments = try segments.toOwnedSlice(alloc),
            .has_path_separator = true,
        };
    }

    /// Frees the owned segment slice. The raw pattern bytes are borrowed.
    pub fn deinit(self: *Pattern, alloc: Allocator) void {
        if (self.has_path_separator) alloc.free(self.segments);
        self.* = .{
            .raw = "",
            .segments = &.{},
            .has_path_separator = false,
        };
    }

    /// Returns true when the pattern matches a path. Patterns without slash match the basename.
    pub fn matchesPath(self: Pattern, candidate_path: []const u8) bool {
        if (!self.has_path_separator) {
            return matchSegment(self.raw, std.Io.Dir.path.basename(candidate_path));
        }
        return matchSegmented(self.segments, candidate_path);
    }

    /// Returns true when a slash-free pattern matches a single basename.
    pub fn matchesBasename(self: Pattern, basename: []const u8) bool {
        if (self.has_path_separator) return false;
        return matchSegment(self.raw, basename);
    }
};

fn appendSegments(alloc: Allocator, path: []const u8, segments: *std.ArrayList([]const u8)) Allocator.Error!void {
    var rest = path;
    while (rest.len > 0) {
        const slash = std.mem.findScalar(u8, rest, '/') orelse {
            try segments.append(alloc, rest);
            return;
        };
        try segments.append(alloc, rest[0..slash]);
        rest = rest[slash + 1 ..];
    }
}

fn matchSegmented(pattern_segments: []const []const u8, candidate_path: []const u8) bool {
    const segment_count = pattern_segments.len;
    std.debug.assert(segment_count <= max_pattern_segments);

    var previous: [max_pattern_segments + 1]bool = @splat(false);
    var current: [max_pattern_segments + 1]bool = @splat(false);

    previous[0] = true;
    for (pattern_segments, 0..) |segment, index| {
        previous[index + 1] = previous[index] and isDoubleStar(segment);
    }

    var candidate_it = SegmentIterator.init(candidate_path);
    while (candidate_it.next()) |candidate_segment| {
        @memset(current[0 .. segment_count + 1], false);
        for (pattern_segments, 0..) |pattern_segment, index| {
            current[index + 1] = if (isDoubleStar(pattern_segment))
                current[index] or previous[index + 1]
            else
                previous[index] and matchSegment(pattern_segment, candidate_segment);
        }
        @memcpy(previous[0 .. segment_count + 1], current[0 .. segment_count + 1]);
    }

    return previous[segment_count];
}

const SegmentIterator = struct {
    rest: []const u8,

    fn init(path: []const u8) SegmentIterator {
        return .{ .rest = path };
    }

    fn next(self: *SegmentIterator) ?[]const u8 {
        if (self.rest.len == 0) return null;
        const slash = std.mem.findScalar(u8, self.rest, '/') orelse {
            const segment = self.rest;
            self.rest = "";
            return segment;
        };
        const segment = self.rest[0..slash];
        self.rest = self.rest[slash + 1 ..];
        return segment;
    }
};

fn isDoubleStar(segment: []const u8) bool {
    return std.mem.eql(u8, segment, "**");
}

fn matchSegment(pattern: []const u8, candidate: []const u8) bool {
    var pattern_index: usize = 0;
    var candidate_index: usize = 0;
    var star_pattern_index: ?usize = null;
    var star_candidate_index: usize = 0;

    while (candidate_index < candidate.len) {
        if (pattern_index < pattern.len) {
            const token = pattern[pattern_index];
            if (token == '*') {
                while (pattern_index < pattern.len and pattern[pattern_index] == '*') {
                    pattern_index += 1;
                }
                if (pattern_index == pattern.len) return true;
                star_pattern_index = pattern_index;
                star_candidate_index = candidate_index;
                continue;
            }
            if (token == '?' or token == candidate[candidate_index]) {
                if (candidate[candidate_index] == '/') return false;
                pattern_index += 1;
                candidate_index += 1;
                continue;
            }
        }

        const retry_pattern_index = star_pattern_index orelse return false;
        star_candidate_index += 1;
        candidate_index = star_candidate_index;
        pattern_index = retry_pattern_index;
    }

    while (pattern_index < pattern.len and pattern[pattern_index] == '*') {
        pattern_index += 1;
    }
    return pattern_index == pattern.len;
}

fn expectCompiledMatch(pattern: []const u8, candidate_path: []const u8, expected: bool) !void {
    var compiled = try Pattern.compile(std.testing.allocator, pattern);
    defer compiled.deinit(std.testing.allocator);
    try std.testing.expectEqual(expected, compiled.matchesPath(candidate_path));
}

test "glob pattern matches recursive and segment wildcards" {
    try expectCompiledMatch("**/*.zig", "main.zig", true);
    try expectCompiledMatch("**/*.zig", "src/core/main.zig", true);
    try expectCompiledMatch("*.zig", "src/main.zig", true);
    try expectCompiledMatch("file?.zig", "dir/file1.zig", true);
    try expectCompiledMatch("file?.zig", "dir/file12.zig", false);
    try expectCompiledMatch("foo\\bar.txt", "src/foo\\bar.txt", true);
    try expectCompiledMatch("src/*.zig", "src/main.zig", true);
    try expectCompiledMatch("src/*.zig", "src/core/main.zig", false);
    try expectCompiledMatch("src/*.zig", "lib/src/main.zig", false);
}

test "glob pattern preserves globstar zero-or-more segment semantics" {
    try expectCompiledMatch("**", "", true);
    try expectCompiledMatch("src/", "src", true);
    try expectCompiledMatch("src/**", "src", true);
    try expectCompiledMatch("src/**", "src/core/main.zig", true);
    try expectCompiledMatch("src/**/main.zig", "src/main.zig", true);
    try expectCompiledMatch("src/**/main.zig", "src/core/nested/main.zig", true);
    try expectCompiledMatch("src/**/main.zig", "lib/src/core/main.zig", false);
}

test "glob pattern treats backslashes literally" {
    try expectCompiledMatch("dir\\*.zig", "dir\\main.zig", true);
    try expectCompiledMatch("dir\\*.zig", "dir/main.zig", false);
}

test "glob pattern handles adversarial repeated-star nonmatches without recursion" {
    const alloc = std.testing.allocator;
    const star_count = 1024;

    var consecutive = try alloc.alloc(u8, star_count + 1);
    defer alloc.free(consecutive);
    @memset(consecutive[0..star_count], '*');
    consecutive[star_count] = 'z';

    const candidate = try alloc.alloc(u8, star_count);
    defer alloc.free(candidate);
    @memset(candidate, 'a');

    var compiled_consecutive = try Pattern.compile(alloc, consecutive);
    defer compiled_consecutive.deinit(alloc);
    try std.testing.expect(!compiled_consecutive.matchesPath(candidate));

    var separated: std.Io.Writer.Allocating = .init(alloc);
    defer separated.deinit();
    var i: usize = 0;
    while (i < 512) : (i += 1) {
        try separated.writer.writeAll("*a");
    }
    try separated.writer.writeByte('z');
    const separated_pattern = try separated.toOwnedSlice();
    defer alloc.free(separated_pattern);

    var compiled_separated = try Pattern.compile(alloc, separated_pattern);
    defer compiled_separated.deinit(alloc);
    try std.testing.expect(!compiled_separated.matchesPath(candidate));
}

test "glob pattern rejects patterns beyond the maximum accepted length" {
    const alloc = std.testing.allocator;

    const accepted = try alloc.alloc(u8, max_pattern_bytes);
    defer alloc.free(accepted);
    @memset(accepted, 'a');
    var accepted_pattern = try Pattern.compile(alloc, accepted);
    defer accepted_pattern.deinit(alloc);
    try std.testing.expect(accepted_pattern.matchesPath(accepted));

    const rejected = try alloc.alloc(u8, max_pattern_bytes + 1);
    defer alloc.free(rejected);
    @memset(rejected, 'a');
    try std.testing.expectError(error.PatternTooLong, Pattern.compile(alloc, rejected));
}
