const std = @import("std");

pub const Kind = enum {
    prompt,
    response,
    tool,
    task,
    issue,
    notice,
    error_notice,
    usage,

    pub fn label(self: Kind) []const u8 {
        return switch (self) {
            .prompt => "Prompt",
            .response => "Response",
            .tool => "Tool",
            .task => "Task",
            .issue => "Issue",
            .notice => "Notice",
            .error_notice => "Error",
            .usage => "Usage",
        };
    }
};

pub fn formatHeader(
    buf: []u8,
    timestamp_ms: i64,
    kind: Kind,
) ?[]const u8 {
    const max_supported_timestamp_ms: i64 = 253_402_300_799_999;
    if (timestamp_ms <= 0 or timestamp_ms > max_supported_timestamp_ms) {
        return null;
    }
    const epoch_seconds: std.time.epoch.EpochSeconds = .{
        .secs = @intCast(@divTrunc(timestamp_ms, std.time.ms_per_s)),
    };
    const milliseconds: u16 = @intCast(@mod(
        timestamp_ms,
        std.time.ms_per_s,
    ));
    const day = epoch_seconds.getDaySeconds();
    const year_day = epoch_seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    return std.fmt.bufPrint(
        buf,
        "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}.{d:0>3} UTC · {s}",
        .{
            year_day.year,
            @intFromEnum(month_day.month),
            month_day.day_index + 1,
            day.getHoursIntoDay(),
            day.getMinutesIntoHour(),
            day.getSecondsIntoMinute(),
            milliseconds,
            kind.label(),
        },
    ) catch null;
}

test "full transcript metadata formats a stable UTC entry header" {
    var buf: [64]u8 = undefined;
    const header = formatHeader(&buf, 1_704_164_645_006, .prompt);
    try std.testing.expect(header != null);
    try std.testing.expectEqualStrings(
        "2024-01-02 03:04:05.006 UTC · Prompt",
        header.?,
    );
    try std.testing.expect(formatHeader(&buf, 0, .response) == null);
    try std.testing.expect(formatHeader(&buf, -1, .tool) == null);
}
