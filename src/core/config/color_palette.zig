const std = @import("std");

pub const ColorPalette = enum {
    fx,
    terminal,

    pub fn parse(raw: []const u8) ?ColorPalette {
        if (std.ascii.eqlIgnoreCase(raw, "fx")) return .fx;
        if (std.ascii.eqlIgnoreCase(raw, "terminal")) return .terminal;
        return null;
    }

    pub fn label(self: ColorPalette) []const u8 {
        return @tagName(self);
    }
};

test "color palette parsing is case insensitive and labels are canonical" {
    try std.testing.expectEqual(ColorPalette.fx, ColorPalette.parse("fx").?);
    try std.testing.expectEqual(ColorPalette.terminal, ColorPalette.parse("TERMINAL").?);
    try std.testing.expectEqualStrings("fx", ColorPalette.fx.label());
    try std.testing.expectEqualStrings("terminal", ColorPalette.terminal.label());
    try std.testing.expect(ColorPalette.parse("system") == null);
}
