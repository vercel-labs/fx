//! Local wall-clock readings of timestamps, for text a person reads. fx
//! stores and serializes times in UTC; display reads them in the user's time
//! zone, from the C library's rules for `TZ` or the system default.

const builtin = @import("builtin");
const std = @import("std");

/// 9999-12-31 23:59:59.999 UTC, the last time a four-digit year can show.
pub const max_timestamp_ms: i64 = 253_402_300_799_999;

/// Longest zone abbreviation shown, such as `PDT` or `+0545`.
const max_zone_name_len = 10;

/// A fixed offset from UTC and its abbreviation.
pub const Zone = struct {
    /// Seconds east of UTC.
    offset_s: i32,
    /// The abbreviation, such as `PDT`.
    name: []const u8,

    pub const utc: Zone = .{ .offset_s = 0, .name = "UTC" };
};

/// The zone test builds read local time in, in place of the machine's, so
/// rendered text is the same wherever tests run. A test that changes it
/// restores `Zone.utc` before it returns.
pub var test_zone: if (builtin.is_test) Zone else void = if (builtin.is_test) Zone.utc else {};

/// A timestamp's calendar date and clock time in one zone.
pub const Reading = struct {
    year: std.time.epoch.Year,
    month: std.time.epoch.Month,
    /// Day of the month, from 1.
    day: u5,
    hour: u5,
    minute: u6,
    second: u6,
    millisecond: u10,
    zone_name_buf: [max_zone_name_len]u8,
    zone_name_len: u8,

    /// The zone's abbreviation, borrowed from this reading.
    pub fn zoneName(self: *const Reading) []const u8 {
        return self.zone_name_buf[0..self.zone_name_len];
    }

    /// `2026-10-16 13:31:49.123 PDT`.
    pub fn format(self: Reading, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}.{d:0>3} {s}", .{
            self.year,
            self.month.numeric(),
            self.day,
            self.hour,
            self.minute,
            self.second,
            self.millisecond,
            self.zoneName(),
        });
    }
};

/// Reads `timestamp_ms` in the local time zone in effect at that moment, so
/// daylight saving time follows each timestamp's own date. Returns null
/// outside 1970 through 9999.
pub fn local(timestamp_ms: i64) ?Reading {
    if (timestamp_ms < 0 or timestamp_ms > max_timestamp_ms) return null;
    return inZone(timestamp_ms, localZoneAt(@divFloor(timestamp_ms, std.time.ms_per_s)));
}

/// Reads `timestamp_ms` in `requested`, or in UTC when that zone's offset is
/// a day or more or the shifted time would leave the supported range.
/// Returns null outside 1970 through 9999.
fn inZone(timestamp_ms: i64, requested: Zone) ?Reading {
    if (timestamp_ms < 0 or timestamp_ms > max_timestamp_ms) return null;
    var zone = requested;
    var local_ms = timestamp_ms + @as(i64, zone.offset_s) * std.time.ms_per_s;
    if (@abs(zone.offset_s) >= std.time.s_per_day or local_ms < 0 or local_ms > max_timestamp_ms) {
        zone = .utc;
        local_ms = timestamp_ms;
    }
    const epoch_seconds: std.time.epoch.EpochSeconds = .{
        .secs = @intCast(@divFloor(local_ms, std.time.ms_per_s)),
    };
    const day = epoch_seconds.getDaySeconds();
    const year_day = epoch_seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    var reading: Reading = .{
        .year = year_day.year,
        .month = month_day.month,
        .day = month_day.day_index + 1,
        .hour = day.getHoursIntoDay(),
        .minute = day.getMinutesIntoHour(),
        .second = day.getSecondsIntoMinute(),
        .millisecond = @intCast(@mod(local_ms, std.time.ms_per_s)),
        .zone_name_buf = undefined,
        .zone_name_len = 0,
    };
    reading.zone_name_len = @intCast(writeZoneName(zone, &reading.zone_name_buf).len);
    return reading;
}

/// Writes `zone`'s abbreviation into `buf` when it is a short plain token,
/// and otherwise its offset in the `+HHMM` form tzdata uses for zones
/// without a name. `TZ` comes from the environment, so its abbreviation never
/// reaches the terminal unchecked. `zone.offset_s` is under a day.
fn writeZoneName(zone: Zone, buf: *[max_zone_name_len]u8) []const u8 {
    if (isPlainZoneName(zone.name)) {
        @memcpy(buf[0..zone.name.len], zone.name);
        return buf[0..zone.name.len];
    }
    const minutes = @abs(zone.offset_s) / std.time.s_per_min;
    buf[0] = if (zone.offset_s < 0) '-' else '+';
    buf[1..3].* = std.fmt.digits2(@intCast(minutes / 60));
    buf[3..5].* = std.fmt.digits2(@intCast(minutes % 60));
    return buf[0..5];
}

fn isPlainZoneName(name: []const u8) bool {
    if (name.len == 0 or name.len > max_zone_name_len) return false;
    for (name) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '+' and byte != '-') return false;
    }
    return true;
}

/// C `struct tm` as macOS, glibc, and musl lay it out. wasi-libc adds a
/// trailing field, so WASI builds never pass this to the C library.
const Tm = extern struct {
    sec: c_int,
    min: c_int,
    hour: c_int,
    mday: c_int,
    mon: c_int,
    year: c_int,
    wday: c_int,
    yday: c_int,
    isdst: c_int,
    gmtoff: c_long,
    zone: ?[*:0]const u8,
};

extern "c" fn localtime_r(timer: *const std.c.time_t, result: *Tm) ?*Tm;

/// The local zone in effect at `epoch_s`, or UTC when the C library cannot
/// convert the time. WASI has no time zone data, so it reads UTC. The name
/// borrows C library storage, so `local` copies it into its reading straight
/// away.
fn localZoneAt(epoch_s: i64) Zone {
    if (builtin.is_test) return test_zone;
    if (!builtin.link_libc or builtin.target.os.tag == .wasi) return .utc;
    const timer = std.math.cast(std.c.time_t, epoch_s) orelse return .utc;
    var tm: Tm = undefined;
    if (localtime_r(&timer, &tm) == null) return .utc;
    const offset_s = std.math.cast(i32, tm.gmtoff) orelse return .utc;
    return .{
        .offset_s = offset_s,
        .name = if (tm.zone) |name| std.mem.span(name) else "",
    };
}

const ist: Zone = .{ .offset_s = 5 * 3600 + 30 * 60, .name = "IST" };

fn expectReading(expected: []const u8, reading: ?Reading) !void {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings(expected, try std.mem.print(&buf, "{f}", .{reading.?}));
}

test "local time reads a timestamp in the given zone" {
    try expectReading("2024-01-02 03:04:05.006 UTC", inZone(1_704_164_645_006, .utc));
    // East of UTC rolls the clock forward.
    try expectReading("2024-01-02 08:34:05.006 IST", inZone(1_704_164_645_006, ist));
    // West of UTC crosses back into the previous day and year.
    try expectReading(
        "2023-12-31 22:04:05.006 EST",
        inZone(1_704_078_245_006, .{ .offset_s = -5 * 3600, .name = "EST" }),
    );
}

test "local time falls back to UTC when the zone cannot apply" {
    // Shifting back from the epoch would leave the calendar range.
    try expectReading("1970-01-01 00:00:00.002 UTC", inZone(2, .{ .offset_s = -7 * 3600, .name = "PDT" }));
    try expectReading(
        "2024-01-02 03:04:05.006 UTC",
        inZone(1_704_164_645_006, .{ .offset_s = std.time.s_per_day, .name = "BAD" }),
    );
    try std.testing.expect(inZone(-1, .utc) == null);
    try std.testing.expect(inZone(max_timestamp_ms + 1, .utc) == null);
    try std.testing.expect(local(-1) == null);
    try std.testing.expect(local(max_timestamp_ms + 1) == null);
}

test "local time shows a zone without a plain name as its offset" {
    try expectReading("2024-01-02 08:49:05.006 +0545", inZone(1_704_164_645_006, .{
        .offset_s = 5 * 3600 + 45 * 60,
        .name = "+0545",
    }));
    try expectReading("2024-01-02 08:34:05.006 +0530", inZone(1_704_164_645_006, .{
        .offset_s = ist.offset_s,
        .name = "",
    }));
    try expectReading("2024-01-01 17:34:05.006 -0930", inZone(1_704_164_645_006, .{
        .offset_s = -(9 * 3600 + 30 * 60),
        .name = "\x1b[2J",
    }));
    try expectReading("2024-01-02 03:04:05.006 +0000", inZone(1_704_164_645_006, .{
        .offset_s = 0,
        .name = "ABCDEFGHIJK",
    }));
}

test "local time follows the test zone" {
    try expectReading("2024-01-02 03:04:05.006 UTC", local(1_704_164_645_006));
    test_zone = ist;
    defer test_zone = .utc;
    try expectReading("2024-01-02 08:34:05.006 IST", local(1_704_164_645_006));
}
