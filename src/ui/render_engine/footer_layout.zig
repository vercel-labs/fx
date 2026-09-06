const std = @import("std");

pub const FooterRows = struct {
    /// Outer top of the footer. Matches `banner` when a banner is
    /// active, otherwise matches `top_divider`.
    top: u16,
    top_divider: u16,
    /// Row that sits above the top divider for state banners.
    banner: u16,
    banner_active: bool = false,
    banner_rows: u16 = 0,
    input_base: u16,
    picker_divider: u16,
    picker_start: u16,
    bottom_divider: u16,
    hint: u16,
    total_rows: u16,
    composer_top_chrome_rows: u16 = 1,
};

pub const Input = struct {
    footer_top_for_extra: u16,
    terminal_rows: u16,
    activity_offset: u16,
    extra_input_rows: u16,
    input_extra: u16,
    input_visible: bool = true,
    composer_top_chrome_rows: u16 = 1,
    picker_rows: u16,
    banner_active: bool,
    banner_rows: u16 = 0,
    allocated_rows: ?u16 = null,
};

pub fn reservedBaseRows(input_visible: bool, composer_top_chrome_rows: u16) u16 {
    return if (input_visible) 2 +| composer_top_chrome_rows else 3;
}

pub fn resolve(input: Input) FooterRows {
    if (input.allocated_rows) |allocated_rows| {
        return resolveAllocated(input, allocated_rows);
    }

    const composer_top_chrome_rows: u16 = if (input.input_visible) input.composer_top_chrome_rows else 1;
    const reserved: u32 = @as(u32, reservedBaseRows(input.input_visible, composer_top_chrome_rows)) + @as(u32, input.extra_input_rows);
    const max_top: u16 = if (@as(u32, input.terminal_rows) > reserved)
        @intCast(@as(u32, input.terminal_rows) - reserved)
    else
        1;
    const outer_top = @min(input.footer_top_for_extra + input.activity_offset, max_top);
    const banner_offset: u16 = if (input.banner_rows > 0)
        input.banner_rows
    else if (input.banner_active)
        1
    else
        0;
    const banner_row = outer_top;
    const top_divider = outer_top + banner_offset;
    if (!input.input_visible) {
        const picker_start = top_divider + 1;
        const bottom_divider = picker_start + input.picker_rows;
        const hint = bottom_divider + 1;
        return .{
            .top = outer_top,
            .top_divider = top_divider,
            .banner = banner_row,
            .banner_active = banner_offset > 0,
            .banner_rows = banner_offset,
            .input_base = top_divider,
            .picker_divider = top_divider,
            .picker_start = picker_start,
            .bottom_divider = bottom_divider,
            .hint = hint,
            .total_rows = hint - outer_top + 1,
            .composer_top_chrome_rows = 1,
        };
    }
    const input_base = top_divider + composer_top_chrome_rows + input.input_extra;
    const picker_divider = input_base + 1;
    const bottom_divider = if (input.picker_rows > 0) picker_divider + 1 + input.picker_rows else picker_divider;
    const hint = bottom_divider + 1;
    return .{
        .top = outer_top,
        .top_divider = top_divider,
        .banner = banner_row,
        .banner_active = banner_offset > 0,
        .banner_rows = banner_offset,
        .input_base = input_base,
        .picker_divider = picker_divider,
        .picker_start = picker_divider + 1,
        .bottom_divider = bottom_divider,
        .hint = hint,
        .total_rows = hint - outer_top + 1,
        .composer_top_chrome_rows = composer_top_chrome_rows,
    };
}

fn resolveAllocated(input: Input, requested_rows: u16) FooterRows {
    const top = @max(@min(input.footer_top_for_extra, input.terminal_rows), 1);
    const available = input.terminal_rows - top + 1;
    const allocated_rows = @max(@min(requested_rows, available), 1);
    const bottom = top + allocated_rows - 1;
    const requested_banner_rows: u16 = if (input.banner_rows > 0)
        input.banner_rows
    else if (input.banner_active)
        1
    else
        0;
    const banner_rows = @min(requested_banner_rows, allocated_rows -| 1);
    const top_divider = top + banner_rows;
    const approval_rows = allocated_rows - banner_rows;
    const picker_start = if (approval_rows > 1) top_divider + 1 else top_divider;
    const bottom_divider = if (approval_rows > 1) bottom - 1 else bottom;

    return .{
        .top = top,
        .top_divider = top_divider,
        .banner = top,
        .banner_active = banner_rows > 0,
        .banner_rows = banner_rows,
        .input_base = top_divider,
        .picker_divider = top_divider,
        .picker_start = picker_start,
        .bottom_divider = bottom_divider,
        .hint = bottom,
        .total_rows = allocated_rows,
        .composer_top_chrome_rows = 1,
    };
}

test "footer rows anchor to transcript cursor" {
    const rows = resolve(.{
        .footer_top_for_extra = 8,
        .terminal_rows = 24,
        .activity_offset = 0,
        .extra_input_rows = 0,
        .input_extra = 0,
        .picker_rows = 0,
        .banner_active = false,
    });
    try std.testing.expectEqual(@as(u16, 8), rows.top);
    try std.testing.expectEqual(@as(u16, 8), rows.top_divider);
    try std.testing.expectEqual(@as(u16, 9), rows.input_base);
    try std.testing.expectEqual(@as(u16, 10), rows.picker_divider);
    try std.testing.expectEqual(@as(u16, 10), rows.bottom_divider);
    try std.testing.expectEqual(@as(u16, 11), rows.hint);
}

test "footer rows clamp near window bottom" {
    const rows = resolve(.{
        .footer_top_for_extra = 19,
        .terminal_rows = 24,
        .activity_offset = 0,
        .extra_input_rows = 2,
        .input_extra = 2,
        .picker_rows = 0,
        .banner_active = false,
    });
    try std.testing.expectEqual(@as(u16, 19), rows.top);
    try std.testing.expectEqual(@as(u16, 19), rows.top_divider);
    try std.testing.expectEqual(@as(u16, 22), rows.input_base);
    try std.testing.expectEqual(@as(u16, 23), rows.picker_divider);
    try std.testing.expectEqual(@as(u16, 23), rows.bottom_divider);
    try std.testing.expectEqual(@as(u16, 24), rows.hint);
}

test "footer rows reserve vertical picker block below input" {
    const rows = resolve(.{
        .footer_top_for_extra = 17,
        .terminal_rows = 24,
        .activity_offset = 0,
        .extra_input_rows = 4,
        .input_extra = 0,
        .picker_rows = 3,
        .banner_active = false,
    });
    try std.testing.expectEqual(@as(u16, 17), rows.top);
    try std.testing.expectEqual(@as(u16, 17), rows.top_divider);
    try std.testing.expectEqual(@as(u16, 18), rows.input_base);
    try std.testing.expectEqual(@as(u16, 19), rows.picker_divider);
    try std.testing.expectEqual(@as(u16, 20), rows.picker_start);
    try std.testing.expectEqual(@as(u16, 23), rows.bottom_divider);
    try std.testing.expectEqual(@as(u16, 24), rows.hint);
}

test "footer rows collapse visible tint top chrome" {
    const rows = resolve(.{
        .footer_top_for_extra = 20,
        .terminal_rows = 24,
        .activity_offset = 0,
        .extra_input_rows = 0,
        .input_extra = 0,
        .composer_top_chrome_rows = 0,
        .picker_rows = 0,
        .banner_active = false,
    });
    try std.testing.expectEqual(@as(u16, 20), rows.top);
    try std.testing.expectEqual(@as(u16, 20), rows.top_divider);
    try std.testing.expectEqual(@as(u16, 20), rows.input_base);
    try std.testing.expectEqual(@as(u16, 21), rows.bottom_divider);
    try std.testing.expectEqual(@as(u16, 22), rows.hint);
    try std.testing.expectEqual(@as(u16, 3), rows.total_rows);
    try std.testing.expectEqual(@as(u16, 0), rows.composer_top_chrome_rows);
}

test "footer rows keep tint multiline and picker offsets coherent" {
    const rows = resolve(.{
        .footer_top_for_extra = 18,
        .terminal_rows = 24,
        .activity_offset = 0,
        .extra_input_rows = 5,
        .input_extra = 1,
        .composer_top_chrome_rows = 0,
        .picker_rows = 3,
        .banner_active = false,
    });
    try std.testing.expectEqual(@as(u16, 17), rows.top);
    try std.testing.expectEqual(@as(u16, 17), rows.top_divider);
    try std.testing.expectEqual(@as(u16, 18), rows.input_base);
    try std.testing.expectEqual(@as(u16, 19), rows.picker_divider);
    try std.testing.expectEqual(@as(u16, 20), rows.picker_start);
    try std.testing.expectEqual(@as(u16, 23), rows.bottom_divider);
    try std.testing.expectEqual(@as(u16, 24), rows.hint);
}

test "footer rows keep the steering banner above input" {
    const rows = resolve(.{
        .footer_top_for_extra = 20,
        .terminal_rows = 24,
        .activity_offset = 0,
        .extra_input_rows = 1,
        .input_extra = 0,
        .composer_top_chrome_rows = 0,
        .picker_rows = 0,
        .banner_active = true,
        .banner_rows = 1,
    });
    try std.testing.expectEqual(@as(u16, 20), rows.top);
    try std.testing.expectEqual(@as(u16, 20), rows.banner);
    try std.testing.expectEqual(@as(u16, 21), rows.top_divider);
    try std.testing.expectEqual(@as(u16, 21), rows.input_base);
    try std.testing.expectEqual(@as(u16, 22), rows.bottom_divider);
    try std.testing.expectEqual(@as(u16, 23), rows.hint);
}

test "footer rows can replace input row with picker panel" {
    const rows = resolve(.{
        .footer_top_for_extra = 17,
        .terminal_rows = 24,
        .activity_offset = 0,
        .extra_input_rows = 7,
        .input_extra = 0,
        .input_visible = false,
        .composer_top_chrome_rows = 0,
        .picker_rows = 7,
        .banner_active = false,
    });
    try std.testing.expectEqual(@as(u16, 14), rows.top);
    try std.testing.expectEqual(@as(u16, 14), rows.top_divider);
    try std.testing.expectEqual(@as(u16, 14), rows.input_base);
    try std.testing.expectEqual(@as(u16, 14), rows.picker_divider);
    try std.testing.expectEqual(@as(u16, 15), rows.picker_start);
    try std.testing.expectEqual(@as(u16, 22), rows.bottom_divider);
    try std.testing.expectEqual(@as(u16, 23), rows.hint);
}

test "footer rows reserve an active steering banner" {
    const rows = resolve(.{
        .footer_top_for_extra = 8,
        .terminal_rows = 24,
        .activity_offset = 0,
        .extra_input_rows = 1,
        .input_extra = 0,
        .picker_rows = 0,
        .banner_active = true,
    });
    try std.testing.expectEqual(@as(u16, 8), rows.top);
    try std.testing.expectEqual(@as(u16, 8), rows.banner);
    try std.testing.expect(rows.banner_active);
    try std.testing.expectEqual(@as(u16, 9), rows.top_divider);
    try std.testing.expectEqual(@as(u16, 10), rows.input_base);
    try std.testing.expectEqual(@as(u16, 11), rows.bottom_divider);
    try std.testing.expectEqual(@as(u16, 12), rows.hint);
}

test "footer rows reserve explicit multi-row banner" {
    const rows = resolve(.{
        .footer_top_for_extra = 8,
        .terminal_rows = 24,
        .activity_offset = 0,
        .extra_input_rows = 6,
        .input_extra = 0,
        .picker_rows = 0,
        .banner_active = true,
        .banner_rows = 6,
    });
    try std.testing.expectEqual(@as(u16, 8), rows.top);
    try std.testing.expectEqual(@as(u16, 8), rows.banner);
    try std.testing.expect(rows.banner_active);
    try std.testing.expectEqual(@as(u16, 6), rows.banner_rows);
    try std.testing.expectEqual(@as(u16, 14), rows.top_divider);
    try std.testing.expectEqual(@as(u16, 15), rows.input_base);
    try std.testing.expectEqual(@as(u16, 16), rows.bottom_divider);
    try std.testing.expectEqual(@as(u16, 17), rows.hint);
}
