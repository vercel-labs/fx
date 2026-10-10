//! Built-in color themes plus theme.json loading.
//!
//! `fx_dark` and `fx_light` retain their historical palette bytes. The ui
//! keeps diff marker accents off until a theme is explicitly selected. Both
//! core presentation and ui rendering resolve their themed values from here.
//! User themes load from `~/.fx/themes/<name>.json` (selected with
//! FX_THEME=<name>) in either the
//! native fx slot schema or the VS Code theme schema (`colors` +
//! `tokenColors`), so editor themes like GitHub Dark apply
//! directly. Hex colors resolve to truecolor escapes when the terminal
//! supports them, otherwise they quantize to the xterm-256 palette.

const std = @import("std");
const debug_trace = @import("debug_trace.zig");
const io_mod = @import("io.zig");
const text_utils = @import("text_utils.zig");

pub const Rgb = struct { r: u8, g: u8, b: u8 };

pub const SyntaxPalette = struct {
    /// `syntax: false` in a native theme turns syntax highlighting off; the
    /// style slots keep their defaults but the highlighter passes text through.
    enabled: bool = true,
    keyword_style: []const u8,
    string_style: []const u8,
    number_style: []const u8,
    comment_style: []const u8,
    /// Command words (the grammar's variable.function).
    function_style: []const u8,
    /// `$VAR`, `${VAR}`, and `~` references.
    variable_style: []const u8,
    /// `&&`, `|`, redirects, glob stars.
    operator_style: []const u8,
};

pub const Theme = struct {
    name: []const u8,
    light: bool,

    divider_style: []const u8,
    hint_style: []const u8,
    statusline_style: []const u8,
    tag_style: []const u8,
    subtitle_style: []const u8,
    system_notice_label_style: []const u8,
    system_notice_text_style: []const u8,
    dim_style: []const u8,
    warning_style: []const u8,
    green_style: []const u8,
    red_style: []const u8,
    diff_added_style: []const u8,
    diff_removed_style: []const u8,
    // When selected, the line number and +/- sign carry the diff color:
    // green for additions (#30A46C), red for deletions (#E5484D).
    // Unconfigured builtins keep markers monochrome. Both truecolor and
    // 256-color variants ship in each theme for terminal capability selection.
    diff_added_marker_truecolor: []const u8,
    diff_removed_marker_truecolor: []const u8,
    diff_added_marker_fallback: []const u8,
    diff_removed_marker_fallback: []const u8,
    approval_button_active_style: []const u8,
    approval_button_inactive_style: []const u8,
    selected_completion_style: []const u8,
    permission_auto_style: []const u8,
    user_card_marker_style: []const u8,
    user_card_accent_style: []const u8,
    inline_code_open: []const u8,
    task_completed_open: []const u8,
    tool_stdout_style: []const u8,
    tool_stderr_style: []const u8,
    link_style: []const u8,
    syntax: SyntaxPalette,
};

pub const fx_dark: Theme = .{
    .name = "fx-dark",
    .light = false,

    .divider_style = "\x1b[38;5;240m",
    .hint_style = "\x1b[38;5;255m",
    .statusline_style = "\x1b[38;5;245m",
    .tag_style = "\x1b[1;38;5;255m",
    .subtitle_style = "\x1b[1;38;5;255m",
    .system_notice_label_style = "\x1b[1;38;5;252m",
    .system_notice_text_style = "\x1b[38;5;250m",
    .dim_style = "\x1b[38;5;245m",
    .warning_style = "\x1b[38;5;252m",
    .green_style = "\x1b[38;5;252m",
    .red_style = "\x1b[38;5;252m",
    .diff_added_style = "\x1b[38;5;252m",
    .diff_removed_style = "\x1b[38;5;252m",
    .diff_added_marker_truecolor = "\x1b[38;2;48;164;108m",
    .diff_removed_marker_truecolor = "\x1b[38;2;229;72;77m",
    .diff_added_marker_fallback = "\x1b[38;5;71m",
    .diff_removed_marker_fallback = "\x1b[38;5;167m",
    .approval_button_active_style = "\x1b[48;5;255m\x1b[38;5;235m\x1b[1m",
    .approval_button_inactive_style = "\x1b[48;5;239m\x1b[38;5;255m",
    .selected_completion_style = "\x1b[1;38;5;255m",
    .permission_auto_style = "\x1b[38;5;252m",
    .user_card_marker_style = "\x1b[38;5;255m",
    .user_card_accent_style = "\x1b[38;5;252m",
    .inline_code_open = "\x1b[38;5;245m",
    .task_completed_open = "\x1b[38;5;252m",
    .tool_stdout_style = "\x1b[38;5;245m",
    .tool_stderr_style = "\x1b[38;5;252m",
    .link_style = "\x1b[38;5;75m",
    .syntax = .{
        .keyword_style = "\x1b[38;5;252m",
        .string_style = "\x1b[38;5;250m",
        .number_style = "\x1b[38;5;250m",
        .comment_style = "\x1b[38;5;245m",
        .function_style = "\x1b[38;5;252m",
        .variable_style = "\x1b[38;5;252m",
        .operator_style = "\x1b[38;5;252m",
    },
};

pub const fx_light: Theme = .{
    .name = "fx-light",
    .light = true,

    .divider_style = "\x1b[38;5;250m",
    .hint_style = "\x1b[38;5;235m",
    .statusline_style = "\x1b[38;5;241m",
    .tag_style = "\x1b[1;38;5;235m",
    .subtitle_style = "\x1b[1;38;5;235m",
    .system_notice_label_style = "\x1b[1;38;5;238m",
    .system_notice_text_style = "\x1b[38;5;241m",
    .dim_style = "\x1b[38;5;247m",
    .warning_style = "\x1b[38;5;238m",
    .green_style = "\x1b[38;5;238m",
    .red_style = "\x1b[38;5;238m",
    .diff_added_style = "\x1b[38;5;238m",
    .diff_removed_style = "\x1b[38;5;238m",
    .diff_added_marker_truecolor = "\x1b[38;2;48;164;108m",
    .diff_removed_marker_truecolor = "\x1b[38;2;229;72;77m",
    .diff_added_marker_fallback = "\x1b[38;5;71m",
    .diff_removed_marker_fallback = "\x1b[38;5;167m",
    .approval_button_active_style = "\x1b[48;5;236m\x1b[38;5;255m\x1b[1m",
    .approval_button_inactive_style = "\x1b[48;5;251m\x1b[38;5;237m",
    .selected_completion_style = "\x1b[1;38;5;235m",
    .permission_auto_style = "\x1b[38;5;238m",
    .user_card_marker_style = "\x1b[38;5;235m",
    .user_card_accent_style = "\x1b[38;5;238m",
    .inline_code_open = "\x1b[38;5;247m",
    .link_style = "\x1b[38;5;25m",
    .task_completed_open = "\x1b[38;5;238m",
    .tool_stdout_style = "\x1b[38;5;245m",
    .tool_stderr_style = "\x1b[38;5;252m",
    .syntax = .{
        .keyword_style = "\x1b[38;5;238m",
        .string_style = "\x1b[38;5;241m",
        .number_style = "\x1b[38;5;241m",
        .comment_style = "\x1b[38;5;243m",
        .function_style = "\x1b[38;5;238m",
        .variable_style = "\x1b[38;5;238m",
        .operator_style = "\x1b[38;5;238m",
    },
};

pub fn builtin(light: bool) Theme {
    return if (light) fx_light else fx_dark;
}

/// The theme currently applied to the process. Core producers that cannot
/// import ui state read their colors through `current()`; `activate` is called
/// by the ui layer whenever a theme is applied.
var active_theme: Theme = fx_dark;

pub fn current() Theme {
    return active_theme;
}

pub fn activate(theme: Theme) void {
    active_theme = theme;
}

pub const ThemeChoice = union(enum) {
    pin_light,
    pin_dark,
    custom: []const u8,
};

/// Classifies a configured theme value (FX_THEME or the settings "theme"
/// key): light/dark pin the builtin variant, anything else names a theme file
/// under ~/.fx/themes.
pub fn classifyValue(value: []const u8) ?ThemeChoice {
    if (value.len == 0) return null;
    if (std.ascii.eqlIgnoreCase(value, "light")) return .pin_light;
    if (std.ascii.eqlIgnoreCase(value, "dark")) return .pin_dark;
    return .{ .custom = value };
}

/// Where the active theme came from: the configured custom theme file key (so
/// live terminal flips can re-resolve it), and whether a light/dark variant is
/// pinned by configuration. Recorded once at startup by the app lifecycle.
/// The name is copied into bounded internal storage: callers never donate
/// memory, and the bound matches loadNamed's validation.
var source_name_buf: [64]u8 = undefined;
var source_name_len: usize = 0;
var source_name_set: bool = false;
var variant_pinned: bool = false;

pub fn setSource(name: ?[]const u8, pinned: bool) void {
    source_name_set = false;
    source_name_len = 0;
    if (name) |value| {
        if (value.len <= source_name_buf.len) {
            @memcpy(source_name_buf[0..value.len], value);
            source_name_len = value.len;
            source_name_set = true;
        } else {
            debug_trace.logf("theme", "theme_source_name_too_long len={d}", .{value.len});
        }
    }
    variant_pinned = pinned;
}

pub fn sourceName() ?[]const u8 {
    if (!source_name_set) return null;
    return source_name_buf[0..source_name_len];
}

pub fn variantPinned() bool {
    return variant_pinned;
}

// --- Hex colors and terminal capability resolution ---

pub const HexColor = struct { rgb: Rgb, alpha: u8 };

/// Parses `#rgb`, `#rrggbb`, and `#rrggbbaa` (the forms VS Code themes use).
pub fn parseHexColor(bytes: []const u8) ?HexColor {
    if (bytes.len < 2 or bytes[0] != '#') return null;
    const hex = bytes[1..];
    const n = std.fmt.charToDigit;
    switch (hex.len) {
        3 => {
            const r = n(hex[0], 16) catch return null;
            const g = n(hex[1], 16) catch return null;
            const b = n(hex[2], 16) catch return null;
            return .{ .rgb = .{ .r = r * 17, .g = g * 17, .b = b * 17 }, .alpha = 0xff };
        },
        6, 8 => {
            var channels: [4]u8 = .{ 0, 0, 0, 0xff };
            const count = hex.len / 2;
            for (0..count) |i| {
                const hi = n(hex[i * 2], 16) catch return null;
                const lo = n(hex[i * 2 + 1], 16) catch return null;
                channels[i] = hi * 16 + lo;
            }
            return .{ .rgb = .{ .r = channels[0], .g = channels[1], .b = channels[2] }, .alpha = channels[3] };
        },
        else => return null,
    }
}

/// Composites a possibly translucent color over a background, the same way an
/// editor renders theme colors with an alpha channel.
pub fn blendOver(fg: Rgb, alpha: u8, bg: Rgb) Rgb {
    if (alpha == 0xff) return fg;
    const a: u32 = alpha;
    const inv: u32 = 0xff - a;
    return .{
        .r = @intCast((@as(u32, fg.r) * a + @as(u32, bg.r) * inv + 127) / 255),
        .g = @intCast((@as(u32, fg.g) * a + @as(u32, bg.g) * inv + 127) / 255),
        .b = @intCast((@as(u32, fg.b) * a + @as(u32, bg.b) * inv + 127) / 255),
    };
}

const cube_levels = [6]u8{ 0, 95, 135, 175, 215, 255 };

fn cubeLevelIndex(v: u8) u8 {
    var best: u8 = 0;
    var best_dist: u32 = std.math.maxInt(u32);
    for (cube_levels, 0..) |level, i| {
        const d = if (level > v) level - v else v - level;
        if (d < best_dist) {
            best_dist = d;
            best = @intCast(i);
        }
    }
    return best;
}

fn colorDistance(r1: u8, g1: u8, b1: u8, r2: u8, g2: u8, b2: u8) u32 {
    const dr = @as(i32, r1) - r2;
    const dg = @as(i32, g1) - g2;
    const db = @as(i32, b1) - b2;
    return @intCast(dr * dr + dg * dg + db * db);
}

/// Maps an RGB color to the nearest xterm-256 palette index, choosing between
/// the 6x6x6 color cube (16-231) and the grayscale ramp (232-255).
pub fn rgbToAnsi256(r: u8, g: u8, b: u8) u8 {
    const ri = cubeLevelIndex(r);
    const gi = cubeLevelIndex(g);
    const bi = cubeLevelIndex(b);
    const cube_dist = colorDistance(r, g, b, cube_levels[ri], cube_levels[gi], cube_levels[bi]);

    const avg: u32 = (@as(u32, r) + g + b) / 3;
    const gray_idx: u32 = if (avg < 8) 0 else @min((avg - 8) / 10, 23);
    const gray_level: u8 = @intCast(8 + gray_idx * 10);
    const gray_dist = colorDistance(r, g, b, gray_level, gray_level, gray_level);

    if (gray_dist < cube_dist) return @intCast(232 + gray_idx);
    return 16 + 36 * ri + 6 * gi + bi;
}

const SlotSpec = struct {
    fg: ?Rgb = null,
    bg: ?Rgb = null,
    bold: bool = false,
    italic: bool = false,
};

fn writeColorParam(writer: *std.Io.Writer, prefix: []const u8, rgb: Rgb, truecolor: bool) !void {
    if (truecolor) {
        try writer.print("{s};2;{d};{d};{d}", .{ prefix, rgb.r, rgb.g, rgb.b });
    } else {
        try writer.print("{s};5;{d}", .{ prefix, rgbToAnsi256(rgb.r, rgb.g, rgb.b) });
    }
}

/// True when an SGR open sets the given parameter ("1" bold, "3" italic, "48"
/// background), parsed from the parameter list rather than substring matched.
/// Handles slots built from multiple concatenated SGR escapes.
pub fn sgrHasParam(open: []const u8, param: []const u8) bool {
    var rest = open;
    while (std.mem.find(u8, rest, "\x1b[")) |start| {
        const after = rest[start + 2 ..];
        const end = std.mem.findScalar(u8, after, 'm') orelse return false;
        var it = std.mem.splitScalar(u8, after[0..end], ';');
        var skip: usize = 0;
        while (it.next()) |part| {
            if (skip > 0) {
                skip -= 1;
                continue;
            }
            if (std.mem.eql(u8, part, "38") or std.mem.eql(u8, part, "48")) {
                if (std.mem.eql(u8, part, param)) return true;
                // Color introducer: 5;n consumes one parameter, 2;r;g;b three.
                // Skipping keeps RGB triples from reading as bold/italic.
                const mode = it.next() orelse break;
                if (std.mem.eql(u8, mode, "2")) {
                    skip = 3;
                } else if (std.mem.eql(u8, mode, "5")) {
                    skip = 1;
                }
                continue;
            }
            if (std.mem.eql(u8, part, param)) return true;
        }
        rest = after[end + 1 ..];
    }
    return false;
}

/// The closing sequence that fully neutralizes an SGR open: always resets the
/// foreground, and resets background, bold, and italic only when the open set
/// them. Builtin fg-only slots keep their historical one-escape close.
pub fn closingFor(open: []const u8) []const u8 {
    const has_bg = sgrHasParam(open, "48");
    const has_bold = sgrHasParam(open, "1");
    const has_italic = sgrHasParam(open, "3");
    if (has_bg) {
        if (has_bold and has_italic) return "\x1b[39m\x1b[49m\x1b[22m\x1b[23m";
        if (has_bold) return "\x1b[39m\x1b[49m\x1b[22m";
        if (has_italic) return "\x1b[39m\x1b[49m\x1b[23m";
        return "\x1b[39m\x1b[49m";
    }
    if (has_bold and has_italic) return "\x1b[39m\x1b[22m\x1b[23m";
    if (has_bold) return "\x1b[39m\x1b[22m";
    if (has_italic) return "\x1b[39m\x1b[23m";
    return "\x1b[39m";
}

/// Renders a slot style as one SGR escape. Caller owns the returned slice.
fn slotEscapeChecked(alloc: std.mem.Allocator, spec: SlotSpec, truecolor: bool) ParseError![]u8 {
    return slotEscape(alloc, spec, truecolor) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        // Writer.Allocating reports allocation failure as WriteFailed in 0.17.
        error.WriteFailed => error.OutOfMemory,
    };
}

fn slotEscape(alloc: std.mem.Allocator, spec: SlotSpec, truecolor: bool) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const writer = &out.writer;
    try writer.writeAll("\x1b[");
    if (spec.bold) try writer.writeAll("1;");
    if (spec.italic) try writer.writeAll("3;");
    if (spec.fg) |fg| try writeColorParam(writer, "38", fg, truecolor);
    if (spec.bg) |bg| {
        if (spec.fg != null or spec.bold or spec.italic) try writer.writeByte(';');
        try writeColorParam(writer, "48", bg, truecolor);
    }
    try writer.writeByte('m');
    return out.toOwnedSlice();
}

// --- theme.json parsing ---

pub const max_theme_bytes: usize = 1024 * 1024;

pub const ParseError = error{ InvalidTheme, OutOfMemory };
pub const ParseOptions = struct { truecolor: bool = true };

/// Parses a theme.json document, auto-detecting the native fx slot schema and
/// the VS Code theme schema. Slots the file does not mention inherit from the
/// matching builtin variant, so partial themes compose with the fx look.
///
/// The returned Theme borrows from `alloc`; themes are process-lifetime state,
/// so the caller keeps the allocation alive rather than freeing per theme.
pub fn parse(alloc: std.mem.Allocator, bytes: []const u8, options: ParseOptions) ParseError!Theme {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{}) catch return error.InvalidTheme;
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |object| object,
        else => return error.InvalidTheme,
    };
    if (looksLikeVsCode(root)) return parseVsCode(alloc, root, options);
    return parseNative(alloc, root, options);
}

fn looksLikeVsCode(root: std.json.ObjectMap) bool {
    if (root.get("tokenColors")) |token_colors| {
        if (token_colors == .array) return true;
    }
    if (root.get("colors")) |colors| {
        if (colors == .object) {
            var it = colors.object.iterator();
            while (it.next()) |entry| {
                if (std.mem.findScalar(u8, entry.key_ptr.*, '.') != null) return true;
            }
        }
    }
    return false;
}

fn jsonString(value: std.json.Value) ?[]const u8 {
    return switch (value) {
        .string => |s| s,
        else => null,
    };
}

/// Maps JSON slot keys to Theme fields: field names minus a trailing
/// `_style` or `_open` ("divider", "inline_code"). Unknown keys are ignored
/// so newer theme files keep loading on older binaries.
fn assignSlotEscape(theme: *Theme, json_key: []const u8, escape: []const u8) void {
    const info = @typeInfo(Theme).@"struct";
    inline for (info.field_names, info.field_types) |field_name, field_type| {
        if (field_type == []const u8 and !std.mem.eql(u8, field_name, "name")) {
            const stripped = comptime blk: {
                if (std.mem.endsWith(u8, field_name, "_style")) break :blk field_name[0 .. field_name.len - "_style".len];
                if (std.mem.endsWith(u8, field_name, "_open")) break :blk field_name[0 .. field_name.len - "_open".len];
                break :blk field_name;
            };
            if (std.mem.eql(u8, json_key, stripped)) {
                @field(theme, field_name) = escape;
                return;
            }
        }
    }
}

fn parseSlotSpec(value: std.json.Value) ParseError!SlotSpec {
    return switch (value) {
        .string => |s| blk: {
            const parsed = parseHexColor(s) orelse return error.InvalidTheme;
            if (parsed.alpha != 0xff) return error.InvalidTheme;
            break :blk SlotSpec{ .fg = parsed.rgb };
        },
        .object => |object| blk: {
            var spec: SlotSpec = .{};
            if (object.get("fg")) |fg| {
                const parsed = parseHexColor(jsonString(fg) orelse return error.InvalidTheme) orelse return error.InvalidTheme;
                if (parsed.alpha != 0xff) return error.InvalidTheme;
                spec.fg = parsed.rgb;
            }
            if (object.get("bg")) |bg| {
                const parsed = parseHexColor(jsonString(bg) orelse return error.InvalidTheme) orelse return error.InvalidTheme;
                if (parsed.alpha != 0xff) return error.InvalidTheme;
                spec.bg = parsed.rgb;
            }
            if (object.get("bold")) |bold| {
                if (bold != .bool) return error.InvalidTheme;
                spec.bold = bold.bool;
            }
            if (object.get("italic")) |italic| {
                if (italic != .bool) return error.InvalidTheme;
                spec.italic = italic.bool;
            }
            if (spec.fg == null and spec.bg == null) return error.InvalidTheme;
            break :blk spec;
        },
        else => error.InvalidTheme,
    };
}

fn applySlot(theme: *Theme, alloc: std.mem.Allocator, json_key: []const u8, spec: SlotSpec, options: ParseOptions) ParseError!void {
    if (std.mem.eql(u8, json_key, "diff_added_marker") or std.mem.eql(u8, json_key, "diff_removed_marker")) {
        // Markers resolve both capability forms from one color so the
        // terminal picks at render time, matching the builtin contract.
        const fg = spec.fg orelse return error.InvalidTheme;
        if (spec.bg != null or spec.bold or spec.italic) return error.InvalidTheme;
        const truecolor = try slotEscapeChecked(alloc, .{ .fg = fg }, true);
        const fallback = try slotEscapeChecked(alloc, .{ .fg = fg }, false);
        if (json_key[5] == 'a') {
            theme.diff_added_marker_truecolor = truecolor;
            theme.diff_added_marker_fallback = fallback;
        } else {
            theme.diff_removed_marker_truecolor = truecolor;
            theme.diff_removed_marker_fallback = fallback;
        }
        return;
    }
    assignSlotEscape(theme, json_key, try slotEscapeChecked(alloc, spec, options.truecolor));
}

fn parseNative(alloc: std.mem.Allocator, root: std.json.ObjectMap, options: ParseOptions) ParseError!Theme {
    var light = false;
    if (root.get("type")) |type_value| {
        const type_string = jsonString(type_value) orelse return error.InvalidTheme;
        if (std.ascii.eqlIgnoreCase(type_string, "light")) {
            light = true;
        } else if (!std.ascii.eqlIgnoreCase(type_string, "dark")) {
            return error.InvalidTheme;
        }
    }
    var theme = builtin(light);
    if (root.get("name")) |name_value| {
        const name = jsonString(name_value) orelse return error.InvalidTheme;
        if (name.len == 0) return error.InvalidTheme;
        theme.name = try alloc.dupe(u8, name);
    }
    if (root.get("colors")) |colors_value| {
        if (colors_value != .object) return error.InvalidTheme;
        var it = colors_value.object.iterator();
        while (it.next()) |entry| {
            const spec = try parseSlotSpec(entry.value_ptr.*);
            try applySlot(&theme, alloc, entry.key_ptr.*, spec, options);
        }
    }
    if (root.get("syntax")) |syntax_value| {
        switch (syntax_value) {
            .object => |syntax_object| try applySyntax(&theme, alloc, syntax_object, options),
            .bool => |enabled| theme.syntax.enabled = enabled,
            else => return error.InvalidTheme,
        }
    }
    return theme;
}

fn applySyntax(theme: *Theme, alloc: std.mem.Allocator, syntax: std.json.ObjectMap, options: ParseOptions) ParseError!void {
    var it = syntax.iterator();
    while (it.next()) |entry| {
        const spec = try parseSlotSpec(entry.value_ptr.*);
        const resolved = try slotEscapeChecked(alloc, spec, options.truecolor);
        if (std.mem.eql(u8, entry.key_ptr.*, "keyword")) {
            theme.syntax.keyword_style = resolved;
        } else if (std.mem.eql(u8, entry.key_ptr.*, "string")) {
            theme.syntax.string_style = resolved;
        } else if (std.mem.eql(u8, entry.key_ptr.*, "number")) {
            theme.syntax.number_style = resolved;
        } else if (std.mem.eql(u8, entry.key_ptr.*, "comment")) {
            theme.syntax.comment_style = resolved;
        } else if (std.mem.eql(u8, entry.key_ptr.*, "function")) {
            theme.syntax.function_style = resolved;
        } else if (std.mem.eql(u8, entry.key_ptr.*, "variable")) {
            theme.syntax.variable_style = resolved;
        } else if (std.mem.eql(u8, entry.key_ptr.*, "operator")) {
            theme.syntax.operator_style = resolved;
        }
    }
}

// --- VS Code theme schema ---

const VsCodeSlot = struct {
    key: []const u8,
    sources: []const []const u8,
    bg_sources: []const []const u8 = &.{},
    bold: bool = false,
};

/// Maps editor workbench colors onto fx chrome slots. Unmapped slots inherit
/// the builtin variant, which keeps fx's neutral layout under editor themes.
const vscode_slot_map = [_]VsCodeSlot{
    .{ .key = "divider", .sources = &.{ "editorLineNumber.foreground", "panel.border" } },
    .{ .key = "hint", .sources = &.{ "editor.foreground", "foreground" } },
    .{ .key = "statusline", .sources = &.{ "statusBar.foreground", "editor.foreground", "foreground" } },
    .{ .key = "tag", .sources = &.{ "editor.foreground", "foreground" }, .bold = true },
    .{ .key = "subtitle", .sources = &.{ "editor.foreground", "foreground" }, .bold = true },
    .{ .key = "system_notice_label", .sources = &.{ "editor.foreground", "foreground" }, .bold = true },
    .{ .key = "system_notice_text", .sources = &.{ "editor.foreground", "foreground" } },
    .{ .key = "dim", .sources = &.{ "editorLineNumber.foreground", "editor.foreground", "foreground" } },
    // No foreground fallbacks: a link that matches body text stops reading as a link.
    .{ .key = "link", .sources = &.{"textLink.foreground"} },
    .{ .key = "warning", .sources = &.{ "editorWarning.foreground", "terminal.ansiYellow" } },
    .{ .key = "green", .sources = &.{"terminal.ansiGreen"} },
    .{ .key = "red", .sources = &.{"terminal.ansiRed"} },
    .{ .key = "diff_added", .sources = &.{ "editorGutter.addedBackground", "terminal.ansiGreen" } },
    .{ .key = "diff_removed", .sources = &.{ "editorGutter.deletedBackground", "terminal.ansiRed" } },
    .{ .key = "diff_added_marker", .sources = &.{ "editorGutter.addedBackground", "terminal.ansiGreen" } },
    .{ .key = "diff_removed_marker", .sources = &.{ "editorGutter.deletedBackground", "terminal.ansiRed" } },
    .{ .key = "approval_button_active", .sources = &.{ "button.foreground", "editor.background" }, .bg_sources = &.{ "button.background", "editor.foreground" }, .bold = true },
    .{ .key = "approval_button_inactive", .sources = &.{ "editor.foreground", "foreground" }, .bg_sources = &.{"editor.lineHighlightBackground"} },
    .{ .key = "selected_completion", .sources = &.{ "editor.foreground", "foreground" }, .bold = true },
    .{ .key = "permission_auto", .sources = &.{ "editor.foreground", "foreground" } },
    .{ .key = "user_card_marker", .sources = &.{ "editor.foreground", "foreground" } },
    .{ .key = "user_card_accent", .sources = &.{ "editor.foreground", "foreground" } },
    .{ .key = "inline_code", .sources = &.{ "terminal.ansiCyan", "editor.foreground", "foreground" } },
    .{ .key = "task_completed", .sources = &.{ "terminal.ansiGreen", "editor.foreground", "foreground" } },
    .{ .key = "tool_stdout", .sources = &.{ "terminal.foreground", "editor.foreground", "foreground" } },
    .{ .key = "tool_stderr", .sources = &.{ "editorWarning.foreground", "terminal.foreground", "editor.foreground" } },
};

const vscode_syntax_scopes = [_]struct { slot: []const u8, scope: []const u8 }{
    .{ .slot = "keyword", .scope = "keyword" },
    .{ .slot = "string", .scope = "string" },
    .{ .slot = "number", .scope = "constant.numeric" },
    .{ .slot = "comment", .scope = "comment" },
    .{ .slot = "function", .scope = "entity.name.function" },
    .{ .slot = "variable", .scope = "variable" },
    .{ .slot = "operator", .scope = "keyword.operator" },
};

fn vscodeColor(colors: ?std.json.ObjectMap, sources: []const []const u8, bg: Rgb) ?Rgb {
    const map = colors orelse return null;
    for (sources) |key| {
        if (map.get(key)) |value| {
            if (jsonString(value)) |s| {
                if (parseHexColor(s)) |parsed| return blendOver(parsed.rgb, parsed.alpha, bg);
            }
        }
    }
    return null;
}

const ScopeMatch = struct { rgb: Rgb, bold: bool, italic: bool };

/// Finds the best TextMate scope match for one of fx's syntax slots. Exact
/// scope beats a dotted prefix match; on a tie the later entry wins, matching
/// VS Code's override order. Compound (space-separated) selectors are skipped.
fn tokenColorMatch(token_colors: []const std.json.Value, want: []const u8, bg: Rgb) ?ScopeMatch {
    var best_score: u8 = 0;
    var best: ?ScopeMatch = null;
    for (token_colors) |entry| {
        if (entry != .object) continue;
        const settings = switch (entry.object.get("settings") orelse continue) {
            .object => |object| object,
            else => continue,
        };
        const foreground = blk: {
            const value = settings.get("foreground") orelse break :blk null;
            const s = jsonString(value) orelse break :blk null;
            const parsed = parseHexColor(s) orelse break :blk null;
            break :blk blendOver(parsed.rgb, parsed.alpha, bg);
        } orelse continue;

        var score: u8 = 0;
        switch (entry.object.get("scope") orelse continue) {
            .string => |s| score = scopeAlternativesScore(s, want),
            .array => |items| {
                for (items.items) |item| {
                    const s = jsonString(item) orelse continue;
                    score = @max(score, scopeAlternativesScore(s, want));
                }
            },
            else => continue,
        }
        if (score == 0 or score < best_score) continue;

        var bold = false;
        var italic = false;
        if (settings.get("fontStyle")) |font_style| {
            if (jsonString(font_style)) |s| {
                bold = std.mem.find(u8, s, "bold") != null;
                italic = std.mem.find(u8, s, "italic") != null;
            }
        }
        best_score = score;
        best = .{ .rgb = foreground, .bold = bold, .italic = italic };
    }
    return best;
}

fn scopeAlternativesScore(scopes: []const u8, want: []const u8) u8 {
    var best: u8 = 0;
    var it = std.mem.splitScalar(u8, scopes, ',');
    while (it.next()) |part| {
        const alt = std.mem.trim(u8, part, " \t");
        if (std.mem.findScalar(u8, alt, ' ') != null) continue;
        if (std.mem.eql(u8, alt, want)) {
            best = @max(best, 2);
        } else if (std.mem.startsWith(u8, alt, want) and alt.len > want.len and alt[want.len] == '.') {
            best = @max(best, 1);
        }
    }
    return best;
}

fn parseVsCode(alloc: std.mem.Allocator, root: std.json.ObjectMap, options: ParseOptions) ParseError!Theme {
    const colors: ?std.json.ObjectMap = switch (root.get("colors") orelse .null) {
        .object => |object| object,
        else => null,
    };

    const declared_bg = vscodeColor(colors, &.{"editor.background"}, .{ .r = 0, .g = 0, .b = 0 });
    var light = false;
    if (root.get("type")) |type_value| {
        const type_string = jsonString(type_value) orelse return error.InvalidTheme;
        if (std.ascii.eqlIgnoreCase(type_string, "light") or std.ascii.eqlIgnoreCase(type_string, "hc-light")) {
            light = true;
        } else if (std.ascii.eqlIgnoreCase(type_string, "dark") or std.ascii.eqlIgnoreCase(type_string, "hc")) {
            light = false;
        } else {
            return error.InvalidTheme;
        }
    } else if (declared_bg) |bg| {
        const luminance = (@as(u32, bg.r) * 299 + @as(u32, bg.g) * 587 + @as(u32, bg.b) * 114) / 1000;
        light = luminance >= 128;
    }

    // Alpha-bearing workbench colors composite over the editor background,
    // matching how the editor itself renders them.
    const blend_bg = declared_bg orelse if (light) Rgb{ .r = 0xff, .g = 0xff, .b = 0xff } else Rgb{ .r = 0, .g = 0, .b = 0 };

    var theme = builtin(light);
    if (root.get("name")) |name_value| {
        if (jsonString(name_value)) |name| {
            if (name.len > 0) theme.name = try alloc.dupe(u8, name);
        }
    }

    for (vscode_slot_map) |mapping| {
        const fg = vscodeColor(colors, mapping.sources, blend_bg);
        const bg = vscodeColor(colors, mapping.bg_sources, blend_bg);
        if (fg == null and bg == null) continue;
        const spec: SlotSpec = .{ .fg = fg, .bg = bg, .bold = mapping.bold };
        try applySlot(&theme, alloc, mapping.key, spec, options);
    }

    if (root.get("tokenColors")) |token_colors| {
        if (token_colors == .array) {
            inline for (vscode_syntax_scopes) |target| {
                if (tokenColorMatch(token_colors.array.items, target.scope, blend_bg)) |match| {
                    const resolved = try slotEscapeChecked(alloc, .{ .fg = match.rgb, .bold = match.bold, .italic = match.italic }, options.truecolor);
                    @field(theme.syntax, target.slot ++ "_style") = resolved;
                }
            }
        }
    }
    return theme;
}

// --- Loading from ~/.fx/themes ---

pub const LoadError = error{ InvalidName, ThemeNotFound, InvalidTheme, OutOfMemory };

/// Returns the sibling variant name for the common `-dark` / `-light`
/// (or `_dark` / `_light`) file naming convention, so a pinned theme can
/// follow the terminal's detected mode: github-dark -> github-light.
/// Returns null when the name carries no recognizable variant suffix.
pub fn siblingName(alloc: std.mem.Allocator, name: []const u8, want_light: bool) !?[]const u8 {
    const suffixes = [_][]const u8{ "-dark", "-light", "_dark", "_light" };
    for (suffixes) |suffix| {
        if (name.len <= suffix.len) continue;
        const tail = name[name.len - suffix.len ..];
        if (!std.ascii.eqlIgnoreCase(tail, suffix)) continue;
        const is_light_suffix = std.mem.find(u8, suffix, "light") != null;
        if (is_light_suffix == want_light) return null;
        const base = name[0 .. name.len - suffix.len];
        // Preserve the suffix capitalization style: GitHub_Light -> GitHub_Dark.
        const replacement: []const u8 = if (std.ascii.isUpper(tail[1]))
            (if (want_light) "Light" else "Dark")
        else
            (if (want_light) "light" else "dark");
        return try alloc.print("{s}{s}{s}", .{ base, suffix[0..1], replacement });
    }
    return null;
}

/// Resolves the named theme for the terminal's detected mode: loads it, swaps
/// to a sibling variant file (github-dark <-> github-light) when the variant
/// mismatches, and returns null to signal the builtin variant when neither
/// file fits. Used both at startup and on live terminal theme notifications.
pub fn resolveNamed(alloc: std.mem.Allocator, name: []const u8, terminal_light: bool, options: ParseOptions) LoadError!?Theme {
    const theme = loadNamed(alloc, name, options) catch |err| {
        debug_trace.logf("theme", "custom_theme_load_failed name={s} err={s}", .{ name, @errorName(err) });
        return null;
    };
    if (theme.light == terminal_light) return theme;
    if (siblingName(alloc, name, terminal_light) catch null) |sibling| {
        if (loadNamed(alloc, sibling, options)) |swapped| {
            if (swapped.light == terminal_light) {
                debug_trace.logf("theme", "theme_variant_swapped from={s} to={s}", .{ name, sibling });
                return swapped;
            }
            // A sibling whose declared variant also mismatches is a user file
            // error; fall through to the builtin rather than trusting it.
            debug_trace.logf("theme", "theme_sibling_variant_mismatch name={s}", .{sibling});
        } else |err| {
            debug_trace.logf("theme", "theme_sibling_load_failed name={s} err={s}", .{ sibling, @errorName(err) });
        }
    }
    debug_trace.logf("theme", "theme_variant_fallback name={s} terminal_light={s}", .{ name, if (terminal_light) "true" else "false" });
    return null;
}

/// Loads `~/.fx/themes/<name>.json` and resolves it for the terminal's color
/// capability. The returned Theme is process-lifetime state allocated from
/// `alloc`; the caller keeps the allocation alive.
pub fn loadNamed(alloc: std.mem.Allocator, name: []const u8, options: ParseOptions) LoadError!Theme {
    if (name.len == 0 or name.len > 64) return error.InvalidName;
    for (name) |byte| {
        const ok = std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.';
        if (!ok) return error.InvalidName;
    }
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return error.InvalidName;

    const home = io_mod.getenv("HOME") orelse return error.ThemeNotFound;
    const dir_path = try alloc.print("{s}/.fx/themes", .{home});
    defer alloc.free(dir_path);
    var dir = std.Io.Dir.openDirAbsolute(io_mod.getIo(), dir_path, .{}) catch return error.ThemeNotFound;
    defer dir.close(io_mod.getIo());

    const file_name = try alloc.print("{s}.json", .{name});
    defer alloc.free(file_name);
    var file = io_mod.openExistingRegularFile(dir, file_name, .read_only) catch return error.ThemeNotFound;
    defer file.close(io_mod.getIo());
    const stat = file.stat(io_mod.getIo()) catch return error.ThemeNotFound;
    if (stat.size > max_theme_bytes) return error.InvalidTheme;
    const bytes = io_mod.readFileToEnd(alloc, &file, max_theme_bytes) catch return error.ThemeNotFound;
    defer alloc.free(bytes);

    return parse(alloc, bytes, options);
}

test "builtin selects the variant matching the light flag" {
    try std.testing.expectEqualStrings("fx-dark", builtin(false).name);
    try std.testing.expectEqualStrings("fx-light", builtin(true).name);
    try std.testing.expect(!builtin(false).light);
    try std.testing.expect(builtin(true).light);
}

test "every theme slot is populated" {
    const info = @typeInfo(Theme).@"struct";
    inline for (info.field_names, info.field_types) |field_name, field_type| {
        if (field_type == []const u8) {
            try std.testing.expect(@field(fx_dark, field_name).len > 0);
            try std.testing.expect(@field(fx_light, field_name).len > 0);
        } else if (field_type == SyntaxPalette) {
            const syntax_info = @typeInfo(SyntaxPalette).@"struct";
            inline for (syntax_info.field_names, syntax_info.field_types) |syntax_name, syntax_type| {
                if (syntax_type != []const u8) continue;
                try std.testing.expect(@field(fx_dark.syntax, syntax_name).len > 0);
                try std.testing.expect(@field(fx_light.syntax, syntax_name).len > 0);
            }
        }
    }
}

test "builtin themes pin the historical fx palette bytes" {
    // Dark defaults.
    try std.testing.expectEqualStrings("\x1b[38;5;240m", fx_dark.divider_style);
    try std.testing.expectEqualStrings("\x1b[38;5;255m", fx_dark.hint_style);
    try std.testing.expectEqualStrings("\x1b[38;5;245m", fx_dark.statusline_style);
    try std.testing.expectEqualStrings("\x1b[38;5;255m", fx_dark.user_card_marker_style);
    try std.testing.expectEqualStrings("\x1b[38;5;252m", fx_dark.user_card_accent_style);
    try std.testing.expectEqualStrings("\x1b[38;5;245m", fx_dark.inline_code_open);
    try std.testing.expectEqualStrings("\x1b[38;5;252m", fx_dark.task_completed_open);
    try std.testing.expectEqualStrings("\x1b[38;5;245m", fx_dark.tool_stdout_style);
    try std.testing.expectEqualStrings("\x1b[38;5;252m", fx_dark.tool_stderr_style);
    try std.testing.expectEqualStrings("\x1b[38;5;252m", fx_dark.syntax.keyword_style);
    try std.testing.expectEqualStrings("\x1b[38;5;245m", fx_dark.syntax.comment_style);

    // Light defaults.
    try std.testing.expectEqualStrings("\x1b[38;5;250m", fx_light.divider_style);
    try std.testing.expectEqualStrings("\x1b[38;5;235m", fx_light.hint_style);
    try std.testing.expectEqualStrings("\x1b[38;5;241m", fx_light.statusline_style);
    try std.testing.expectEqualStrings("\x1b[38;5;235m", fx_light.user_card_marker_style);
    try std.testing.expectEqualStrings("\x1b[38;5;238m", fx_light.user_card_accent_style);
    try std.testing.expectEqualStrings("\x1b[38;5;247m", fx_light.inline_code_open);
    try std.testing.expectEqualStrings("\x1b[38;5;238m", fx_light.task_completed_open);
    // Tool text stays the pre-theme gray in both variants (parity guard).
    try std.testing.expectEqualStrings("\x1b[38;5;245m", fx_light.tool_stdout_style);
    try std.testing.expectEqualStrings("\x1b[38;5;252m", fx_light.tool_stderr_style);
    try std.testing.expectEqualStrings("\x1b[38;5;238m", fx_light.syntax.keyword_style);
    try std.testing.expectEqualStrings("\x1b[38;5;243m", fx_light.syntax.comment_style);

    // Diff markers read the same on light and dark in both capability modes.
    try std.testing.expectEqualStrings("\x1b[38;2;48;164;108m", fx_dark.diff_added_marker_truecolor);
    try std.testing.expectEqualStrings("\x1b[38;2;229;72;77m", fx_dark.diff_removed_marker_truecolor);
    try std.testing.expectEqualStrings("\x1b[38;5;71m", fx_dark.diff_added_marker_fallback);
    try std.testing.expectEqualStrings("\x1b[38;5;167m", fx_dark.diff_removed_marker_fallback);
    try std.testing.expectEqualStrings(fx_dark.diff_added_marker_truecolor, fx_light.diff_added_marker_truecolor);
    try std.testing.expectEqualStrings(fx_dark.diff_removed_marker_truecolor, fx_light.diff_removed_marker_truecolor);
    try std.testing.expectEqualStrings(fx_dark.diff_added_marker_fallback, fx_light.diff_added_marker_fallback);
    try std.testing.expectEqualStrings(fx_dark.diff_removed_marker_fallback, fx_light.diff_removed_marker_fallback);
}

test "activate switches the current theme seen by core producers" {
    const previous = current();
    defer activate(previous);
    activate(fx_light);
    try std.testing.expectEqualStrings("fx-light", current().name);
    activate(fx_dark);
    try std.testing.expectEqualStrings("fx-dark", current().name);
}

test "parseHexColor accepts the hex forms VS Code themes use" {
    const short = parseHexColor("#fff").?;
    try std.testing.expectEqual(@as(u8, 0xff), short.rgb.r);
    try std.testing.expectEqual(@as(u8, 0xff), short.alpha);

    const full = parseHexColor("#82D2CE").?;
    try std.testing.expectEqual(@as(u8, 0x82), full.rgb.r);
    try std.testing.expectEqual(@as(u8, 0xd2), full.rgb.g);
    try std.testing.expectEqual(@as(u8, 0xce), full.rgb.b);

    const alpha = parseHexColor("#F0F0F026").?;
    try std.testing.expectEqual(@as(u8, 0x26), alpha.alpha);

    try std.testing.expect(parseHexColor("fff") == null);
    try std.testing.expect(parseHexColor("#ff") == null);
    try std.testing.expect(parseHexColor("#fffff") == null);
    try std.testing.expect(parseHexColor("#gggggg") == null);
    try std.testing.expect(parseHexColor("") == null);
}

test "blendOver composites translucent colors onto a background" {
    const bg = Rgb{ .r = 0x18, .g = 0x18, .b = 0x18 };
    const solid = blendOver(.{ .r = 0xf0, .g = 0xf0, .b = 0xf0 }, 0xff, bg);
    try std.testing.expectEqual(@as(u8, 0xf0), solid.r);

    // 0x26/0xff of #F0F0F0 over #181818.
    const faint = blendOver(.{ .r = 0xf0, .g = 0xf0, .b = 0xf0 }, 0x26, bg);
    try std.testing.expect(faint.r > bg.r and faint.r < 0x40);
    try std.testing.expectEqual(faint.r, faint.g);
    try std.testing.expectEqual(faint.g, faint.b);
}

test "rgbToAnsi256 lands on the expected palette indexes" {
    try std.testing.expectEqual(@as(u8, 16), rgbToAnsi256(0, 0, 0));
    try std.testing.expectEqual(@as(u8, 231), rgbToAnsi256(255, 255, 255));
    try std.testing.expectEqual(@as(u8, 196), rgbToAnsi256(255, 0, 0));
    try std.testing.expectEqual(@as(u8, 46), rgbToAnsi256(0, 255, 0));
    try std.testing.expectEqual(@as(u8, 21), rgbToAnsi256(0, 0, 255));
    try std.testing.expectEqual(@as(u8, 244), rgbToAnsi256(0x80, 0x80, 0x80));
}

test "parse resolves a native theme overlay on the matching builtin" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const doc =
        \\{
        \\  "name": "test-native",
        \\  "colors": {
        \\    "divider": "#ff0000",
        \\    "approval_button_active": { "fg": "#191c22", "bg": "#81a1c1", "bold": true },
        \\    "diff_added_marker": "#30a46c"
        \\  },
        \\  "syntax": { "keyword": "#82d2ce", "comment": { "fg": "#6a9955", "italic": true } }
        \\}
    ;
    const theme = try parse(alloc, doc, .{ .truecolor = true });
    try std.testing.expectEqualStrings("test-native", theme.name);
    try std.testing.expect(!theme.light);
    try std.testing.expectEqualStrings("\x1b[38;2;255;0;0m", theme.divider_style);
    try std.testing.expectEqualStrings("\x1b[1;38;2;25;28;34;48;2;129;161;193m", theme.approval_button_active_style);
    try std.testing.expectEqualStrings("\x1b[38;2;48;164;108m", theme.diff_added_marker_truecolor);
    try std.testing.expectEqualStrings(fx_dark.diff_removed_marker_truecolor, theme.diff_removed_marker_truecolor);
    try std.testing.expectEqualStrings("\x1b[38;2;130;210;206m", theme.syntax.keyword_style);
    try std.testing.expectEqualStrings("\x1b[3;38;2;106;153;85m", theme.syntax.comment_style);
    // Untouched slots inherit the builtin variant.
    try std.testing.expectEqualStrings(fx_dark.hint_style, theme.hint_style);
    try std.testing.expectEqualStrings(fx_dark.syntax.string_style, theme.syntax.string_style);
}

test "parse honors a native syntax boolean switch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const disabled = try parse(alloc, "{ \"name\": \"no-syntax\", \"syntax\": false }", .{ .truecolor = true });
    try std.testing.expect(!disabled.syntax.enabled);
    // Style slots keep the builtin defaults; the flag alone gates highlighting.
    try std.testing.expectEqualStrings(fx_dark.syntax.keyword_style, disabled.syntax.keyword_style);

    const enabled = try parse(alloc, "{ \"name\": \"yes-syntax\", \"syntax\": true }", .{ .truecolor = true });
    try std.testing.expect(enabled.syntax.enabled);

    const object = try parse(alloc, "{ \"name\": \"obj-syntax\", \"syntax\": { \"keyword\": \"#ff0000\" } }", .{ .truecolor = true });
    try std.testing.expect(object.syntax.enabled);

    try std.testing.expectError(error.InvalidTheme, parse(alloc, "{ \"syntax\": 3 }", .{ .truecolor = true }));
}

test "parse quantizes native themes for 256-color terminals" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const theme = try parse(alloc, "{ \"colors\": { \"divider\": \"#ff0000\", \"diff_added_marker\": \"#30a46c\" } }", .{ .truecolor = false });
    try std.testing.expectEqualStrings("\x1b[38;5;196m", theme.divider_style);
    try std.testing.expectEqualStrings("\x1b[38;2;48;164;108m", theme.diff_added_marker_truecolor);
    const fallback_n = rgbToAnsi256(0x30, 0xa4, 0x6c);
    try std.testing.expectEqualStrings(try alloc.print("\x1b[38;5;{d}m", .{fallback_n}), theme.diff_added_marker_fallback);
}

test "parse resolves a VS Code theme through the adapter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const doc =
        \\{
        \\  "name": "Test Dark",
        \\  "colors": {
        \\    "editor.background": "#181818",
        \\    "editor.foreground": "#F0F0F0",
        \\    "statusBar.foreground": "#F0F0F099",
        \\    "editorLineNumber.foreground": "#F0F0F05C",
        \\    "editorWarning.foreground": "#F1B467",
        \\    "terminal.ansiGreen": "#3FA266",
        \\    "terminal.ansiRed": "#FC6B83",
        \\    "button.background": "#81A1C1",
        \\    "button.foreground": "#191c22"
        \\  },
        \\  "tokenColors": [
        \\    { "scope": "keyword.operator", "settings": { "foreground": "#111111" } },
        \\    { "scope": "keyword", "settings": { "foreground": "#82D2CE" } },
        \\    { "scope": ["string", "markup"], "settings": { "foreground": "#A8CC7C" } },
        \\    { "scope": "comment markup.link", "settings": { "foreground": "#000000" } },
        \\    { "scope": "comment", "settings": { "foreground": "#6A9955", "fontStyle": "italic" } }
        \\  ]
        \\}
    ;
    const theme = try parse(alloc, doc, .{ .truecolor = true });
    try std.testing.expectEqualStrings("Test Dark", theme.name);
    try std.testing.expect(!theme.light); // inferred from editor.background, no type field
    try std.testing.expectEqualStrings("\x1b[38;2;240;240;240m", theme.hint_style);
    // Alpha colors blend over editor.background before resolution.
    const status_expected = blendOver(.{ .r = 0xf0, .g = 0xf0, .b = 0xf0 }, 0x99, .{ .r = 0x18, .g = 0x18, .b = 0x18 });
    try std.testing.expectEqualStrings(try alloc.print("\x1b[38;2;{d};{d};{d}m", .{ status_expected.r, status_expected.g, status_expected.b }), theme.statusline_style);
    try std.testing.expectEqualStrings("\x1b[38;2;241;180;103m", theme.warning_style);
    try std.testing.expectEqualStrings("\x1b[38;2;63;162;102m", theme.green_style);
    try std.testing.expectEqualStrings("\x1b[38;2;252;107;131m", theme.red_style);
    try std.testing.expectEqualStrings("\x1b[1;38;2;25;28;34;48;2;129;161;193m", theme.approval_button_active_style);
    // Exact scope beats prefix; later entries override at equal specificity;
    // compound selectors never fill a base slot.
    try std.testing.expectEqualStrings("\x1b[38;2;130;210;206m", theme.syntax.keyword_style);
    try std.testing.expectEqualStrings("\x1b[38;2;168;204;124m", theme.syntax.string_style);
    try std.testing.expectEqualStrings("\x1b[3;38;2;106;153;85m", theme.syntax.comment_style);
    // Unmapped scopes and slots inherit the builtin variant.
    try std.testing.expectEqualStrings(fx_dark.syntax.number_style, theme.syntax.number_style);
}

test "parse honors an explicit VS Code type field over background luminance" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const theme = try parse(alloc, "{ \"type\": \"light\", \"colors\": { \"editor.background\": \"#181818\" } }", .{ .truecolor = true });
    try std.testing.expect(theme.light);
    try std.testing.expectEqualStrings(fx_light.dim_style[0..4], theme.dim_style[0..4]);
}

test "parse rejects malformed themes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    try std.testing.expectError(error.InvalidTheme, parse(alloc, "not json", .{}));
    try std.testing.expectError(error.InvalidTheme, parse(alloc, "[]", .{}));
    try std.testing.expectError(error.InvalidTheme, parse(alloc, "{ \"type\": \"solarized\" }", .{}));
    try std.testing.expectError(error.InvalidTheme, parse(alloc, "{ \"colors\": { \"divider\": \"red\" } }", .{}));
    try std.testing.expectError(error.InvalidTheme, parse(alloc, "{ \"colors\": { \"divider\": { \"bold\": true } } }", .{}));
}

test "loadNamed validates the theme name before touching disk" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    try std.testing.expectError(error.InvalidName, loadNamed(alloc, "", .{}));
    try std.testing.expectError(error.InvalidName, loadNamed(alloc, "../escape", .{}));
    try std.testing.expectError(error.InvalidName, loadNamed(alloc, "a/b", .{}));
    try std.testing.expectError(error.InvalidName, loadNamed(alloc, "..", .{}));
    try std.testing.expectError(error.ThemeNotFound, loadNamed(alloc, "fx-theme-that-does-not-exist-9z9z", .{}));
}

test "siblingName maps variant suffixes for terminal-mode swaps" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    try std.testing.expectEqualStrings("cursor-light", (try siblingName(alloc, "cursor-dark", true)).?);
    try std.testing.expectEqualStrings("cursor-dark", (try siblingName(alloc, "cursor-light", false)).?);
    try std.testing.expectEqualStrings("GitHub_Dark", (try siblingName(alloc, "GitHub_Light", false)).?);
    // Already on the wanted variant, or no recognizable suffix.
    try std.testing.expect((try siblingName(alloc, "cursor-dark", false)) == null);
    try std.testing.expect((try siblingName(alloc, "monokai", true)) == null);
    try std.testing.expect((try siblingName(alloc, "-dark", true)) == null);
}

test "sgrHasParam parses the parameter list exactly" {
    try std.testing.expect(sgrHasParam("\x1b[38;5;245m", "38"));
    try std.testing.expect(sgrHasParam("\x1b[1;38;2;1;2;3m", "38"));
    try std.testing.expect(sgrHasParam("\x1b[1;38;2;1;2;3m", "1"));
    try std.testing.expect(sgrHasParam("\x1b[3;48;5;240m", "48"));
    try std.testing.expect(sgrHasParam("\x1b[3;48;5;240m", "3"));
    // No prefix or substring confusion, and RGB triples are not attributes.
    try std.testing.expect(!sgrHasParam("\x1b[3;38;2;1;2;3m", "1"));
    try std.testing.expect(!sgrHasParam("\x1b[38;2;1;2;3m", "3"));
    try std.testing.expect(!sgrHasParam("\x1b[38;5;245m", "3"));
    try std.testing.expect(!sgrHasParam("\x1b[38;5;245m", "8"));
    try std.testing.expect(!sgrHasParam("\x1b[38;5;245m", "48"));
    try std.testing.expect(!sgrHasParam("\x1b[39m", "38"));
    try std.testing.expect(!sgrHasParam("plain", "38"));
    try std.testing.expect(!sgrHasParam("\x1b[38;5;245", "38"));
}

test "closingFor resets exactly what the open set" {
    try std.testing.expectEqualStrings("\x1b[39m", closingFor(fx_dark.hint_style));
    try std.testing.expectEqualStrings("\x1b[39m", closingFor(fx_dark.inline_code_open));
    try std.testing.expectEqualStrings("\x1b[39m\x1b[22m", closingFor(fx_dark.tag_style));
    try std.testing.expectEqualStrings("\x1b[39m\x1b[23m", closingFor("\x1b[3;38;2;1;2;3m"));
    try std.testing.expectEqualStrings("\x1b[39m\x1b[22m\x1b[23m", closingFor("\x1b[1;3;38;2;1;2;3m"));
    try std.testing.expectEqualStrings("\x1b[39m\x1b[49m\x1b[22m", closingFor(fx_dark.approval_button_active_style));
    try std.testing.expectEqualStrings("\x1b[39m\x1b[49m", closingFor(fx_dark.approval_button_inactive_style));
}

test "classifyValue maps configured theme values" {
    try std.testing.expect(classifyValue("") == null);
    try std.testing.expect(classifyValue("light").? == .pin_light);
    try std.testing.expect(classifyValue("Dark").? == .pin_dark);
    try std.testing.expectEqualStrings("cursor-dark", classifyValue("cursor-dark").?.custom);
}

test "theme source copies the configured name and pin for live re-resolution" {
    defer setSource(null, false);
    try std.testing.expect(sourceName() == null);
    try std.testing.expect(!variantPinned());

    // The donor buffer may be freed right after setSource; the source state
    // must not dangle (startup state is deinited before the event loop).
    const donated = try std.testing.allocator.dupe(u8, "cursor-dark");
    setSource(donated, false);
    std.testing.allocator.free(donated);
    try std.testing.expectEqualStrings("cursor-dark", sourceName().?);
    try std.testing.expect(!variantPinned());

    setSource(null, true);
    try std.testing.expect(sourceName() == null);
    try std.testing.expect(variantPinned());

    const too_long = text_utils.repeat("x", 65);
    setSource(too_long, false);
    try std.testing.expect(sourceName() == null);
}

test "parse maps the link color and split syntax scopes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const vscode_doc =
        \\{
        \\  "type": "dark",
        \\  "colors": { "textLink.foreground": "#58A6FF" },
        \\  "tokenColors": [
        \\    { "scope": "keyword", "settings": { "foreground": "#82D2CE" } },
        \\    { "scope": "entity.name.function", "settings": { "foreground": "#D2A8FF" } },
        \\    { "scope": "variable.other", "settings": { "foreground": "#FFA657" } },
        \\    { "scope": "keyword.operator", "settings": { "foreground": "#FF7B72" } }
        \\  ]
        \\}
    ;
    const vscode = try parse(alloc, vscode_doc, .{ .truecolor = true });
    try std.testing.expectEqualStrings("\x1b[38;2;88;166;255m", vscode.link_style);
    try std.testing.expectEqualStrings("\x1b[38;2;210;168;255m", vscode.syntax.function_style);
    try std.testing.expectEqualStrings("\x1b[38;2;255;166;87m", vscode.syntax.variable_style);
    try std.testing.expectEqualStrings("\x1b[38;2;255;123;114m", vscode.syntax.operator_style);
    // Keyword keeps its own scope, not keyword.operator's.
    try std.testing.expectEqualStrings("\x1b[38;2;130;210;206m", vscode.syntax.keyword_style);

    const native = try parse(alloc, "{ \"colors\": { \"link\": \"#58A6FF\" }, \"syntax\": { \"function\": \"#D2A8FF\", \"variable\": \"#FFA657\", \"operator\": \"#FF7B72\" } }", .{ .truecolor = true });
    try std.testing.expectEqualStrings("\x1b[38;2;88;166;255m", native.link_style);
    try std.testing.expectEqualStrings("\x1b[38;2;210;168;255m", native.syntax.function_style);
    try std.testing.expectEqualStrings("\x1b[38;2;255;166;87m", native.syntax.variable_style);
    try std.testing.expectEqualStrings("\x1b[38;2;255;123;114m", native.syntax.operator_style);

    // A VS Code theme without textLink keeps the builtin link color.
    const no_link = try parse(alloc, "{ \"type\": \"dark\", \"colors\": {} }", .{ .truecolor = true });
    try std.testing.expectEqualStrings(fx_dark.link_style, no_link.link_style);
}

test "builtin themes pin the new slot bytes" {
    try std.testing.expectEqualStrings("\x1b[38;5;75m", fx_dark.link_style);
    try std.testing.expectEqualStrings("\x1b[38;5;25m", fx_light.link_style);
    // The split slots default to the keyword color so default rendering is
    // byte-identical to before the split.
    for ([_][]const u8{ fx_dark.syntax.function_style, fx_dark.syntax.variable_style, fx_dark.syntax.operator_style }) |style| {
        try std.testing.expectEqualStrings(fx_dark.syntax.keyword_style, style);
    }
    for ([_][]const u8{ fx_light.syntax.function_style, fx_light.syntax.variable_style, fx_light.syntax.operator_style }) |style| {
        try std.testing.expectEqualStrings(fx_light.syntax.keyword_style, style);
    }
}
