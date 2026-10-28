const std = @import("std");
const builtin = @import("builtin");

const net = std.Io.net;
const Io = std.Io;
const HostName = net.HostName;
const IpAddress = net.IpAddress;
const LookupResult = HostName.LookupResult;
const LookupOptions = HostName.LookupOptions;
const LookupError = HostName.LookupError;
const QueueClosedError = Io.QueueClosedError;
const DnsResponse = HostName.DnsResponse;
const DnsRecord = HostName.DnsRecord;
const ResolvConf = HostName.ResolvConf;

/// Termux keeps its network configuration under its prefix instead of the
/// read-only Android `/etc` symlink target. Upstream Zig's resolver only reads
/// `/etc/resolv.conf` and otherwise falls back to `127.0.0.1:53`, which has no
/// listener on Android. Without this override every fx network request, and
/// therefore every sign-in, times out on Termux.
const termux_resolv_conf_path = "/data/data/com.termux/files/usr/etc/resolv.conf";

var wrapped_vtable: Io.VTable = undefined;
var wrapped_original_vtable: ?*const Io.VTable = null;

/// Returns a Linux `Io` whose `netLookup` reads the Termux resolv.conf when the
/// standard `/etc/resolv.conf` is unavailable. On other platforms the original
/// `Io` is returned unchanged.
pub fn wrap(original: Io) Io {
    if (builtin.os.tag != .linux) return original;
    if (!termuxDnsNeeded(original)) return original;

    if (wrapped_original_vtable) |existing| {
        std.debug.assert(existing == original.vtable);
    } else {
        wrapped_vtable = original.vtable.*;
        wrapped_vtable.netLookup = termuxNetLookup;
        wrapped_original_vtable = original.vtable;
    }
    return .{ .userdata = original.userdata, .vtable = &wrapped_vtable };
}

fn termuxDnsNeeded(io: Io) bool {
    if (fileExists(io, "/etc/resolv.conf")) return false;
    return fileExists(io, termux_resolv_conf_path);
}

fn fileExists(io: Io, path: []const u8) bool {
    var file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return false;
    file.close(io);
    return true;
}

fn termuxNetLookup(
    userdata: ?*anyopaque,
    host_name: HostName,
    resolved: *Io.Queue(LookupResult),
    options: LookupOptions,
) LookupError!void {
    const io: Io = .{ .userdata = userdata, .vtable = wrapped_original_vtable.? };
    defer resolved.close(io);
    termuxLookup(io, host_name, resolved, options) catch |err| switch (err) {
        error.Closed => unreachable, // The queue must not be closed until netLookup returns.
        else => |e| return e,
    };
}

fn termuxLookup(
    io: Io,
    host_name: HostName,
    resolved: *Io.Queue(LookupResult),
    options: LookupOptions,
) (LookupError || QueueClosedError)!void {
    const name = host_name.bytes;

    if (IpAddress.parseIp6(name, options.port)) |addr| {
        if (options.family == .ip4) return error.UnknownHostName;
        try putLiteral(io, resolved, addr, options, name);
        return;
    } else |_| {}
    if (IpAddress.parseIp4(name, options.port)) |addr| {
        if (options.family == .ip6) return error.UnknownHostName;
        try putLiteral(io, resolved, addr, options, name);
        return;
    } else |_| {}

    // RFC 6761 section 6.3.3: localhost always resolves to loopback.
    const localhost = if (name[name.len - 1] == '.') "localhost." else "localhost";
    if (std.mem.endsWith(u8, name, localhost) and
        (name.len == localhost.len or name[name.len - localhost.len] == '.'))
    {
        var results: [3]LookupResult = undefined;
        var count: usize = 0;
        if (options.family != .ip4) {
            results[count] = .{ .address = .{ .ip6 = .loopback(options.port) } };
            count += 1;
        }
        if (options.family != .ip6) {
            results[count] = .{ .address = .{ .ip4 = .loopback(options.port) } };
            count += 1;
        }
        if (options.canonical_name_buffer) |buffer| {
            const canonical = "localhost";
            @memcpy(buffer[0..canonical.len], canonical);
            results[count] = .{ .canonical_name = .{ .bytes = buffer[0..canonical.len] } };
            count += 1;
        }
        try resolved.putAll(io, results[0..count]);
        return;
    }

    try dnsLookup(io, host_name, resolved, options);
}

fn putLiteral(
    io: Io,
    resolved: *Io.Queue(LookupResult),
    address: IpAddress,
    options: LookupOptions,
    name: []const u8,
) (LookupError || QueueClosedError)!void {
    const buffer = options.canonical_name_buffer orelse {
        try resolved.putOne(io, .{ .address = address });
        return;
    };
    const length = @min(name.len, buffer.len);
    @memcpy(buffer[0..length], name[0..length]);
    try resolved.putAll(io, &.{
        .{ .address = address },
        .{ .canonical_name = .{ .bytes = buffer[0..length] } },
    });
}

fn dnsLookup(
    io: Io,
    host_name: HostName,
    resolved: *Io.Queue(LookupResult),
    options: LookupOptions,
) (LookupError || QueueClosedError)!void {
    const rc = try loadTermuxResolvConf(io);

    var canonical_name = host_name.bytes;
    if (std.mem.endsWith(u8, canonical_name, ".")) canonical_name.len -= 1;
    if (std.mem.endsWith(u8, canonical_name, ".")) return error.UnknownHostName;

    return dnsQuery(io, canonical_name, &rc, resolved, options);
}

fn loadTermuxResolvConf(io: Io) LookupError!ResolvConf {
    var rc: ResolvConf = .{
        .nameservers_buffer = undefined,
        .nameservers_len = 0,
        .search_buffer = undefined,
        .search_len = 0,
        .ndots = 1,
        .timeout_seconds = 5,
        .attempts = 2,
    };

    var file = std.Io.Dir.openFileAbsolute(io, termux_resolv_conf_path, .{}) catch
        return error.DetectingNetworkConfigurationFailed;
    defer file.close(io);

    var line_buffer: [512]u8 = undefined;
    var reader = file.reader(io, &line_buffer);
    rc.parse(io, &reader.interface) catch return error.ResolvConfParseFailed;

    if (rc.nameservers_len == 0) {
        rc.nameservers_buffer[0] = .{ .ip4 = .{
            .bytes = .{ 127, 0, 0, 1 },
            .port = 53,
        } };
        rc.nameservers_len = 1;
    }
    return rc;
}

fn dnsQuery(
    io: Io,
    name: []const u8,
    rc: *const ResolvConf,
    resolved: *Io.Queue(LookupResult),
    options: LookupOptions,
) (LookupError || QueueClosedError)!void {
    const want_a = options.family != .ip6;
    const want_aaaa = options.family != .ip4;

    var query_buffers: [2][280]u8 = undefined;
    var queries: [2][]const u8 = undefined;
    var answer_buffer: [2 * 512]u8 = undefined;
    var answers: [2][]const u8 = undefined;
    var query_count: usize = 0;
    var answer_offset: usize = 0;

    if (want_a) {
        var entropy: [2]u8 = undefined;
        io.random(&entropy);
        queries[query_count] = query_buffers[query_count][0..writeQuery(&query_buffers[query_count], name, .A, entropy)];
        query_count += 1;
    }
    if (want_aaaa) {
        var entropy: [2]u8 = undefined;
        io.random(&entropy);
        queries[query_count] = query_buffers[query_count][0..writeQuery(&query_buffers[query_count], name, .AAAA, entropy)];
        query_count += 1;
    }
    for (answers[0..query_count]) |*answer| answer.len = 0;

    // Android resolv.conf entries are IPv4 in practice. Keep the socket IPv4 so
    // A and AAAA records are both requested over one UDP socket.
    var nameservers: [ResolvConf.max_nameservers]IpAddress = undefined;
    var nameserver_count: usize = 0;
    for (rc.nameservers()) |nameserver| {
        if (nameserver == .ip6) continue;
        if (nameserver_count >= nameservers.len) break;
        nameservers[nameserver_count] = nameserver;
        nameserver_count += 1;
    }
    if (nameserver_count == 0) return error.UnknownHostName;

    const bind_address: IpAddress = .{ .ip4 = .unspecified(0) };
    var socket = try bind_address.bind(io, .{ .mode = .dgram });
    defer socket.close(io);

    const clock: Io.Clock = .boot;
    var now = clock.now(io);
    const final_ts = now.addDuration(.fromSeconds(rc.timeout_seconds));
    const attempt_duration: Io.Duration = .{
        .nanoseconds = (std.time.ns_per_s / rc.attempts) * @as(i96, rc.timeout_seconds),
    };

    send: while (now.nanoseconds < final_ts.nanoseconds) : (now = clock.now(io)) {
        for (queries[0..query_count], answers[0..query_count]) |query, *answer| {
            if (answer.len != 0) continue;
            for (nameservers[0..nameserver_count]) |*nameserver| {
                socket.send(io, nameserver, query) catch {};
            }
        }

        const timeout: Io.Timeout = .{ .deadline = .{
            .raw = now.addDuration(attempt_duration),
            .clock = clock,
        } };

        while (true) {
            var message_buffer: [1]net.IncomingMessage = .{.init};
            const buffer = answer_buffer[answer_offset..];
            const receive_err, const receive_count = socket.receiveManyTimeout(
                io,
                &message_buffer,
                buffer,
                .{},
                timeout,
            );
            for (message_buffer[0..receive_count]) |*received| {
                const reply = received.data;
                if (reply.len < 4) continue;

                const nameserver = for (nameservers[0..nameserver_count]) |*candidate| {
                    if (received.from.eql(candidate)) break candidate;
                } else continue;

                const query, const answer = for (queries[0..query_count], answers[0..query_count]) |query, *answer| {
                    if (reply[0] == query[0] and reply[1] == query[1]) break .{ query, answer };
                } else continue;
                if (answer.len != 0) continue;

                switch (reply[3] & 15) {
                    0, 3 => {
                        answer.* = reply;
                        answer_offset += reply.len;
                        if (answer_offset == answer_buffer.len) break :send;
                        var remaining = false;
                        for (answers[0..query_count]) |*answer_check| {
                            if (answer_check.len == 0) {
                                remaining = true;
                                break;
                            }
                        }
                        if (!remaining) break :send;
                    },
                    2 => {
                        socket.send(io, nameserver, query) catch {};
                        continue;
                    },
                    else => continue,
                }
            }
            if (receive_err) |err| switch (err) {
                error.Canceled => return error.Canceled,
                error.Timeout => continue :send,
                else => continue,
            };
        }
    } else {
        return error.NameServerFailure;
    }

    var address_count: usize = 0;
    var canonical_name: ?HostName = null;

    for (answers[0..query_count]) |answer| {
        var iterator = DnsResponse.init(answer) catch continue;
        while (iterator.next() catch continue) |record| switch (record.rr) {
            .A => {
                const data = record.packet[record.data_off..][0..record.data_len];
                if (data.len != 4) return error.InvalidDnsARecord;
                try resolved.putOne(io, .{ .address = .{ .ip4 = .{
                    .bytes = data[0..4].*,
                    .port = options.port,
                } } });
                address_count += 1;
            },
            .AAAA => {
                const data = record.packet[record.data_off..][0..record.data_len];
                if (data.len != 16) return error.InvalidDnsAAAARecord;
                try resolved.putOne(io, .{ .address = .{ .ip6 = .{
                    .bytes = data[0..16].*,
                    .port = options.port,
                } } });
                address_count += 1;
            },
            .CNAME => {
                if (options.canonical_name_buffer) |buffer| {
                    _, canonical_name = HostName.expand(
                        record.packet,
                        record.data_off,
                        buffer,
                    ) catch return error.InvalidDnsCnameRecord;
                }
            },
            _ => continue,
        };
    }

    if (options.canonical_name_buffer != null) {
        try resolved.putOne(io, .{
            .canonical_name = canonical_name orelse .{ .bytes = name },
        });
    }
    if (address_count == 0) return error.NoAddressReturned;
}

fn writeQuery(buffer: *[280]u8, name: []const u8, record: DnsRecord, entropy: [2]u8) usize {
    var query_name = name;
    if (std.mem.endsWith(u8, query_name, ".")) query_name.len -= 1;
    std.debug.assert(query_name.len <= 253);
    const total = 17 + query_name.len + @intFromBool(query_name.len != 0);

    buffer[0..2].* = entropy;
    @memset(buffer[2..total], 0);
    buffer[2] = 1; // Standard query, recursion desired.
    buffer[5] = 1; // One question.
    @memcpy(buffer[13..][0..query_name.len], query_name);

    var label_start: usize = 13;
    var scan: usize = undefined;
    while (buffer[label_start] != 0) : (label_start = scan + 1) {
        scan = label_start;
        while (buffer[scan] != 0 and buffer[scan] != '.') : (scan += 1) {}
        std.debug.assert(scan - label_start - 1 <= 62);
        buffer[label_start - 1] = @intCast(scan - label_start);
    }
    buffer[label_start + 1] = @intFromEnum(record);
    buffer[label_start + 3] = 1; // IN class.
    return total;
}

test "DNS query builder emits a well-formed A question" {
    var buffer: [280]u8 = undefined;
    const length = writeQuery(&buffer, "vercel.com", .A, .{ 0x12, 0x34 });

    try std.testing.expectEqualStrings("\x12\x34", buffer[0..2]);
    try std.testing.expectEqual(@as(u8, 1), buffer[2]);
    try std.testing.expectEqual(@as(u8, 0), buffer[3]);
    try std.testing.expectEqual(@as(u8, 0), buffer[4]);
    try std.testing.expectEqual(@as(u8, 1), buffer[5]);
    try std.testing.expectEqual(@as(u8, 0), buffer[6]);
    try std.testing.expectEqual(@as(u8, 0), buffer[7]);
    try std.testing.expectEqual(@as(u8, 6), buffer[12]); // "vercel" label length
    try std.testing.expectEqualStrings("vercel", buffer[13..19]);
    try std.testing.expectEqual(@as(u8, 3), buffer[19]); // "com" label length
    try std.testing.expectEqualStrings("com", buffer[20..23]);
    try std.testing.expectEqual(@as(u8, 0), buffer[23]);
    try std.testing.expectEqual(@as(u8, 1), buffer[25]); // A record type
    try std.testing.expectEqual(@as(u8, 1), buffer[27]); // IN class
    try std.testing.expectEqual(@as(usize, 28), length);
}

test "DNS query builder tolerates a trailing dot and AAAA records" {
    var buffer: [280]u8 = undefined;
    const length = writeQuery(&buffer, "api.vercel.com.", .AAAA, .{ 0xab, 0xcd });

    try std.testing.expectEqualStrings("\xab\xcd", buffer[0..2]);
    try std.testing.expectEqualStrings("api", buffer[13..16]);
    try std.testing.expectEqual(@as(u8, 28), buffer[29]); // AAAA record type
    try std.testing.expectEqual(@as(u8, 1), buffer[31]); // IN class
    try std.testing.expectEqual(@as(usize, 32), length);
}
