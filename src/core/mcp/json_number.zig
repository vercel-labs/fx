const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Limits = struct {
    max_lexeme_bytes: usize = 4096,
    max_exponent_abs: i64 = 1_000_000,
    max_expanded_digits: usize = 8192,
};

pub const Error = error{
    InvalidNumber,
    NumberLimitExceeded,
} || Allocator.Error;

pub const Number = struct {
    negative: bool,
    digits: []u8,
    exponent: i64,

    pub fn parse(alloc: Allocator, lexeme: []const u8, limits: Limits) Error!Number {
        if (lexeme.len == 0) return error.InvalidNumber;
        if (lexeme.len > limits.max_lexeme_bytes) return error.NumberLimitExceeded;

        var index: usize = 0;
        const negative = lexeme[index] == '-';
        if (negative) {
            index += 1;
            if (index == lexeme.len) return error.InvalidNumber;
        }

        var raw_digits: std.ArrayList(u8) = .empty;
        defer raw_digits.deinit(alloc);
        var fraction_digits: usize = 0;
        if (lexeme[index] == '0') {
            try raw_digits.append(alloc, '0');
            index += 1;
            if (index < lexeme.len and std.ascii.isDigit(lexeme[index])) {
                return error.InvalidNumber;
            }
        } else if (lexeme[index] >= '1' and lexeme[index] <= '9') {
            while (index < lexeme.len and std.ascii.isDigit(lexeme[index])) : (index += 1) {
                try raw_digits.append(alloc, lexeme[index]);
            }
        } else {
            return error.InvalidNumber;
        }

        if (index < lexeme.len and lexeme[index] == '.') {
            index += 1;
            const fraction_start = index;
            while (index < lexeme.len and std.ascii.isDigit(lexeme[index])) : (index += 1) {
                try raw_digits.append(alloc, lexeme[index]);
            }
            if (index == fraction_start) return error.InvalidNumber;
            fraction_digits = index - fraction_start;
        }

        var explicit_exponent: i64 = 0;
        if (index < lexeme.len and (lexeme[index] == 'e' or lexeme[index] == 'E')) {
            index += 1;
            if (index == lexeme.len) return error.InvalidNumber;
            var exponent_negative = false;
            if (lexeme[index] == '+' or lexeme[index] == '-') {
                exponent_negative = lexeme[index] == '-';
                index += 1;
            }
            const exponent_start = index;
            while (index < lexeme.len and std.ascii.isDigit(lexeme[index])) : (index += 1) {
                const digit: i64 = lexeme[index] - '0';
                explicit_exponent = std.math.mul(i64, explicit_exponent, 10) catch
                    return error.NumberLimitExceeded;
                explicit_exponent = std.math.add(i64, explicit_exponent, digit) catch
                    return error.NumberLimitExceeded;
                if (explicit_exponent > limits.max_exponent_abs) {
                    return error.NumberLimitExceeded;
                }
            }
            if (index == exponent_start) return error.InvalidNumber;
            if (exponent_negative) explicit_exponent = -explicit_exponent;
        }
        if (index != lexeme.len) return error.InvalidNumber;
        if (raw_digits.items.len > limits.max_lexeme_bytes) return error.NumberLimitExceeded;

        var first_nonzero: usize = 0;
        while (first_nonzero < raw_digits.items.len and raw_digits.items[first_nonzero] == '0') {
            first_nonzero += 1;
        }
        if (first_nonzero == raw_digits.items.len) {
            return .{
                .negative = false,
                .digits = try alloc.dupe(u8, "0"),
                .exponent = 0,
            };
        }

        var significant_end = raw_digits.items.len;
        while (raw_digits.items[significant_end - 1] == '0') significant_end -= 1;
        const removed_trailing = raw_digits.items.len - significant_end;
        const fractional_exponent = std.math.cast(i64, fraction_digits) orelse
            return error.NumberLimitExceeded;
        const trailing_exponent = std.math.cast(i64, removed_trailing) orelse
            return error.NumberLimitExceeded;
        var exponent = std.math.sub(i64, explicit_exponent, fractional_exponent) catch
            return error.NumberLimitExceeded;
        exponent = std.math.add(i64, exponent, trailing_exponent) catch
            return error.NumberLimitExceeded;
        if (exponent > limits.max_exponent_abs or exponent < -limits.max_exponent_abs) {
            return error.NumberLimitExceeded;
        }
        return .{
            .negative = negative,
            .digits = try alloc.dupe(u8, raw_digits.items[first_nonzero..significant_end]),
            .exponent = exponent,
        };
    }

    pub fn deinit(self: *Number, alloc: Allocator) void {
        alloc.free(self.digits);
        self.* = undefined;
    }

    pub fn isZero(self: Number) bool {
        return self.digits.len == 1 and self.digits[0] == '0';
    }

    pub fn isInteger(self: Number) bool {
        return self.isZero() or self.exponent >= 0;
    }

    pub fn order(left: Number, right: Number) std.math.Order {
        if (left.isZero() and right.isZero()) return .eq;
        if (left.isZero()) return if (right.negative) .gt else .lt;
        if (right.isZero()) return if (left.negative) .lt else .gt;
        if (left.negative != right.negative) return if (left.negative) .lt else .gt;
        const magnitude = magnitudeOrder(left, right);
        return if (left.negative) switch (magnitude) {
            .lt => .gt,
            .eq => .eq,
            .gt => .lt,
        } else magnitude;
    }

    pub fn eql(left: Number, right: Number) bool {
        return order(left, right) == .eq;
    }

    pub fn toNonNegativeUsize(self: Number) ?usize {
        if (self.negative or !self.isInteger()) return null;
        var result: usize = 0;
        for (self.digits) |digit| {
            result = std.math.mul(usize, result, 10) catch return null;
            result = std.math.add(usize, result, digit - '0') catch return null;
        }
        const zero_count = std.math.cast(usize, self.exponent) orelse return null;
        for (0..zero_count) |_| result = std.math.mul(usize, result, 10) catch return null;
        return result;
    }

    pub fn isMultipleOf(
        value: Number,
        alloc: Allocator,
        divisor: Number,
        limits: Limits,
    ) Error!bool {
        if (divisor.isZero()) return error.InvalidNumber;
        if (value.isZero()) return true;
        const delta = std.math.sub(i64, value.exponent, divisor.exponent) catch
            return error.NumberLimitExceeded;
        const numerator_zeros = if (delta > 0)
            std.math.cast(usize, delta) orelse return error.NumberLimitExceeded
        else
            0;
        const denominator_zeros = if (delta < 0)
            std.math.cast(usize, -delta) orelse return error.NumberLimitExceeded
        else
            0;
        const numerator_len = std.math.add(usize, value.digits.len, numerator_zeros) catch
            return error.NumberLimitExceeded;
        const denominator_len = std.math.add(usize, divisor.digits.len, denominator_zeros) catch
            return error.NumberLimitExceeded;
        if (numerator_len > limits.max_expanded_digits or
            denominator_len > limits.max_expanded_digits)
        {
            return error.NumberLimitExceeded;
        }

        const numerator_text = try expandedDigits(alloc, value.digits, numerator_zeros);
        defer alloc.free(numerator_text);
        const denominator_text = try expandedDigits(alloc, divisor.digits, denominator_zeros);
        defer alloc.free(denominator_text);

        var numerator = try std.math.big.int.Managed.init(alloc);
        defer numerator.deinit();
        var denominator = try std.math.big.int.Managed.init(alloc);
        defer denominator.deinit();
        var quotient = try std.math.big.int.Managed.init(alloc);
        defer quotient.deinit();
        var remainder = try std.math.big.int.Managed.init(alloc);
        defer remainder.deinit();
        numerator.setString(10, numerator_text) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidNumber,
        };
        denominator.setString(10, denominator_text) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidNumber,
        };
        try std.math.big.int.Managed.divTrunc(
            &quotient,
            &remainder,
            &numerator,
            &denominator,
        );
        return remainder.eqlZero();
    }
};

pub fn fromValue(
    alloc: Allocator,
    value: std.json.Value,
    limits: Limits,
) Error!?Number {
    return switch (value) {
        .number_string => |lexeme| try Number.parse(alloc, lexeme, limits),
        .integer => |integer| blk: {
            var buffer: [64]u8 = undefined;
            const lexeme = std.mem.print(&buffer, "{d}", .{integer}) catch
                return error.InvalidNumber;
            break :blk try Number.parse(alloc, lexeme, limits);
        },
        // A float has already lost its source lexeme and may have rounded before
        // reaching the validator. Callers that parse JSON must retain numbers as
        // number_string; integer remains exact for programmatic values.
        .float => return error.InvalidNumber,
        else => null,
    };
}

fn magnitudeOrder(left: Number, right: Number) std.math.Order {
    const left_places = @as(i64, @intCast(left.digits.len)) + left.exponent;
    const right_places = @as(i64, @intCast(right.digits.len)) + right.exponent;
    if (left_places < right_places) return .lt;
    if (left_places > right_places) return .gt;
    const max_digits = @max(left.digits.len, right.digits.len);
    for (0..max_digits) |index| {
        const left_digit = if (index < left.digits.len) left.digits[index] else '0';
        const right_digit = if (index < right.digits.len) right.digits[index] else '0';
        if (left_digit < right_digit) return .lt;
        if (left_digit > right_digit) return .gt;
    }
    return .eq;
}

fn expandedDigits(alloc: Allocator, digits: []const u8, zero_count: usize) Error![]u8 {
    const output = try alloc.alloc(u8, digits.len + zero_count);
    @memcpy(output[0..digits.len], digits);
    @memset(output[digits.len..], '0');
    return output;
}

fn expectEquivalent(left: []const u8, right: []const u8) !void {
    var left_number = try Number.parse(std.testing.allocator, left, .{});
    defer left_number.deinit(std.testing.allocator);
    var right_number = try Number.parse(std.testing.allocator, right, .{});
    defer right_number.deinit(std.testing.allocator);
    try std.testing.expect(left_number.eql(right_number));
}

test "exact JSON numbers normalize signed zero exponents and high precision" {
    try expectEquivalent("0", "-0.0e+999");
    try expectEquivalent("1", "1.000e0");
    try expectEquivalent("9007199254740993", "9.007199254740993e15");
    try expectEquivalent("0.12345678901234567890123456789", "12345678901234567890123456789e-29");

    var lower = try Number.parse(std.testing.allocator, "9007199254740992", .{});
    defer lower.deinit(std.testing.allocator);
    var upper = try Number.parse(std.testing.allocator, "9007199254740993", .{});
    defer upper.deinit(std.testing.allocator);
    try std.testing.expectEqual(std.math.Order.lt, lower.order(upper));
}

test "exact JSON numbers detect integers and multipleOf without floating point" {
    var integer = try Number.parse(std.testing.allocator, "1e3", .{});
    defer integer.deinit(std.testing.allocator);
    var fraction = try Number.parse(std.testing.allocator, "1e-3", .{});
    defer fraction.deinit(std.testing.allocator);
    try std.testing.expect(integer.isInteger());
    try std.testing.expect(!fraction.isInteger());

    var value = try Number.parse(std.testing.allocator, "0.300000000000000000000000000000", .{});
    defer value.deinit(std.testing.allocator);
    var divisor = try Number.parse(std.testing.allocator, "0.1", .{});
    defer divisor.deinit(std.testing.allocator);
    try std.testing.expect(try value.isMultipleOf(std.testing.allocator, divisor, .{}));
    var not_multiple = try Number.parse(std.testing.allocator, "0.300000000000000000000000000001", .{});
    defer not_multiple.deinit(std.testing.allocator);
    try std.testing.expect(!try not_multiple.isMultipleOf(std.testing.allocator, divisor, .{}));
}

test "exact JSON numbers order signed magnitudes around zero" {
    var zero = try Number.parse(std.testing.allocator, "0", .{});
    defer zero.deinit(std.testing.allocator);
    var positive = try Number.parse(std.testing.allocator, "0.0000000000000000000000000001", .{});
    defer positive.deinit(std.testing.allocator);
    var negative = try Number.parse(std.testing.allocator, "-0.0000000000000000000000000001", .{});
    defer negative.deinit(std.testing.allocator);

    try std.testing.expectEqual(std.math.Order.lt, zero.order(positive));
    try std.testing.expectEqual(std.math.Order.gt, zero.order(negative));
    try std.testing.expectEqual(std.math.Order.gt, positive.order(zero));
    try std.testing.expectEqual(std.math.Order.lt, negative.order(zero));
}
