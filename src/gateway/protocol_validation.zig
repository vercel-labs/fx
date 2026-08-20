const std = @import("std");

pub fn parseTimestamp(text: []const u8) error{InvalidTimestamp}!i64 {
    if (text.len < 20 or
        text[4] != '-' or
        text[7] != '-' or
        text[10] != 'T' or
        text[13] != ':' or
        text[16] != ':')
    {
        return error.InvalidTimestamp;
    }
    const year = try parseTimestampDigits(text[0..4]);
    const month = try parseTimestampDigits(text[5..7]);
    const day = try parseTimestampDigits(text[8..10]);
    const hour = try parseTimestampDigits(text[11..13]);
    const minute = try parseTimestampDigits(text[14..16]);
    const second = try parseTimestampDigits(text[17..19]);
    if (year < 1970 or
        month < 1 or
        month > 12 or
        day < 1 or
        day > daysInMonth(year, month) or
        hour > 23 or
        minute > 59 or
        second > 59)
    {
        return error.InvalidTimestamp;
    }

    var cursor: usize = 19;
    var fractional_ms: i64 = 0;
    if (cursor < text.len and text[cursor] == '.') {
        cursor += 1;
        const fraction_start = cursor;
        while (cursor < text.len and std.ascii.isDigit(text[cursor])) cursor += 1;
        const fraction = text[fraction_start..cursor];
        if (fraction.len == 0 or fraction.len > 9) return error.InvalidTimestamp;
        const digits = @min(fraction.len, 3);
        fractional_ms = @intCast(try parseTimestampDigits(fraction[0..digits]));
        if (digits == 1) fractional_ms *= 100;
        if (digits == 2) fractional_ms *= 10;
    }
    if (cursor + 1 != text.len or text[cursor] != 'Z') return error.InvalidTimestamp;

    const days = daysFromCivil(year, month, day);
    if (days < 0) return error.InvalidTimestamp;
    const seconds = std.math.add(
        i64,
        std.math.mul(i64, days, std.time.s_per_day) catch return error.InvalidTimestamp,
        @as(i64, @intCast(hour * std.time.s_per_hour + minute * std.time.s_per_min + second)),
    ) catch return error.InvalidTimestamp;
    return std.math.add(
        i64,
        std.math.mul(i64, seconds, std.time.ms_per_s) catch return error.InvalidTimestamp,
        fractional_ms,
    ) catch return error.InvalidTimestamp;
}

fn parseTimestampDigits(text: []const u8) error{InvalidTimestamp}!u32 {
    if (text.len == 0) return error.InvalidTimestamp;
    var result: u32 = 0;
    for (text) |byte| {
        if (!std.ascii.isDigit(byte)) return error.InvalidTimestamp;
        result = std.math.mul(u32, result, 10) catch return error.InvalidTimestamp;
        result = std.math.add(u32, result, byte - '0') catch return error.InvalidTimestamp;
    }
    return result;
}

fn daysInMonth(year: u32, month: u32) u32 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (year % 4 == 0 and (year % 100 != 0 or year % 400 == 0)) 29 else 28,
        else => 0,
    };
}

fn daysFromCivil(year_value: u32, month_value: u32, day_value: u32) i64 {
    var year: i64 = year_value;
    const month: i64 = month_value;
    const day: i64 = day_value;
    year -= @intFromBool(month <= 2);
    const era = @divFloor(year, 400);
    const year_of_era = year - era * 400;
    const shifted_month = month + (if (month > 2) @as(i64, -3) else 9);
    const day_of_year = @divFloor(153 * shifted_month + 2, 5) + day - 1;
    const day_of_era = year_of_era * 365 + @divFloor(year_of_era, 4) -
        @divFloor(year_of_era, 100) + day_of_year;
    return era * 146097 + day_of_era - 719468;
}

pub fn validGenerationId(id: []const u8) bool {
    if (id.len != 30 or !std.mem.startsWith(u8, id, "gen_")) return false;
    for (id[4..]) |char| switch (char) {
        '0'...'9', 'A'...'H', 'J'...'K', 'M'...'N', 'P'...'T', 'V'...'Z' => {},
        else => return false,
    };
    return true;
}

pub fn validTeam(team: []const u8) bool {
    if (team.len == 0 or team.len > 128) return false;
    for (team) |char| switch (char) {
        'a'...'z', 'A'...'Z', '0'...'9', '-', '_' => {},
        else => return false,
    };
    return true;
}

test "timestamps parse UTC fractions strictly" {
    try std.testing.expectEqual(@as(i64, 1_775_045_467_000), try parseTimestamp("2026-04-01T12:11:07Z"));
    try std.testing.expectEqual(@as(i64, 1_775_045_467_123), try parseTimestamp("2026-04-01T12:11:07.123456Z"));
    try std.testing.expectError(error.InvalidTimestamp, parseTimestamp("2026-02-30T12:11:07Z"));
    try std.testing.expectError(error.InvalidTimestamp, parseTimestamp("2026-04-01T12:11:07+00:00"));
}

test "timestamp parser handles fuzzed bytes" {
    try std.testing.fuzz({}, fuzzTimestamp, .{ .corpus = &.{ "", "2026-04-01T12:11:07Z", "2026-04-01T12:11:07.123456789Z" } });
}

fn fuzzTimestamp(_: void, smith: *std.testing.Smith) !void {
    var buffer: [128]u8 = undefined;
    const len: usize = @intCast(smith.slice(&buffer));
    _ = parseTimestamp(buffer[0..len]) catch return;
}
