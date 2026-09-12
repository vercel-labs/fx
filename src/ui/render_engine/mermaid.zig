//! Terminal Mermaid renderer facade.
//!
//! The renderer is deliberately split at ownership boundaries:
//!
//!     Mermaid source
//!          │
//!          ▼
//!       parser ──> owned model ──> layout ──> styled canvas ──> terminal rows
//!          │
//!          └── unsupported or over bounds ──> ordinary code-block fallback

const std = @import("std");
const display_width = @import("../../core/shared/display_width.zig");
const model = @import("mermaid/model.zig");
const parser = @import("mermaid/parser.zig");
const layout = @import("mermaid/layout.zig");
const canvas = @import("mermaid/canvas.zig");

const Allocator = std.mem.Allocator;
const MermaidError = model.MermaidError;

const max_source_bytes = 64 * 1024;

pub const Styles = canvas.Styles;

/// Renders a supported Mermaid diagram. The caller owns the returned bytes.
/// `null` means that the source should be rendered as an ordinary code block.
pub fn render(
    alloc: Allocator,
    source: []const u8,
    max_width: usize,
    styles: Styles,
) Allocator.Error!?[]u8 {
    if (source.len > max_source_bytes or max_width < 8) return null;
    const trimmed = std.mem.trim(u8, source, " \t\r\n");
    if (trimmed.len == 0) return null;

    return render_bounded(alloc, trimmed, max_width, styles) catch |err| switch (err) {
        error.TooComplex => null,
        error.OutOfMemory => error.OutOfMemory,
    };
}

fn render_bounded(
    alloc: Allocator,
    source: []const u8,
    max_width: usize,
    styles: Styles,
) MermaidError!?[]u8 {
    const kind = first_word(source);
    if (eql_ignore_case(kind, "sequencediagram")) {
        var sequence = (try parser.parse_sequence(alloc, source)) orelse return null;
        defer sequence.deinit();
        return try layout.render_sequence(alloc, &sequence, max_width, styles);
    }

    var graph = if (eql_ignore_case(kind, "graph") or eql_ignore_case(kind, "flowchart"))
        (try parser.parse_flowchart(alloc, source)) orelse return null
    else if (starts_with_ignore_case(kind, "statediagram"))
        (try parser.parse_state(alloc, source)) orelse return null
    else if (eql_ignore_case(kind, "classdiagram"))
        (try parser.parse_class(alloc, source)) orelse return null
    else if (eql_ignore_case(kind, "erdiagram"))
        (try parser.parse_er(alloc, source)) orelse return null
    else
        return null;
    defer graph.deinit();
    return try layout.render_graph(alloc, &graph, max_width, styles);
}

fn first_word(source: []const u8) []const u8 {
    const trimmed = std.mem.trimStart(u8, source, " \t\r\n");
    var end: usize = 0;
    while (end < trimmed.len and trimmed[end] != ' ' and trimmed[end] != '\t' and
        trimmed[end] != '\r' and trimmed[end] != '\n') : (end += 1)
    {}
    return trimmed[0..end];
}

fn eql_ignore_case(left: []const u8, right: []const u8) bool {
    return std.ascii.eqlIgnoreCase(left, right);
}

fn starts_with_ignore_case(source: []const u8, prefix: []const u8) bool {
    return source.len >= prefix.len and std.ascii.eqlIgnoreCase(source[0..prefix.len], prefix);
}

test "mermaid renders flowchart nodes edges labels and wide glyphs" {
    const alloc = std.testing.allocator;
    const rendered = (try render(
        alloc,
        "flowchart TD\n  A[开始] -->|检查| B{Ready?}\n  B --> C[Done]",
        80,
        .{},
    )).?;
    defer alloc.free(rendered);
    try std.testing.expect(std.mem.find(u8, rendered, "开始") != null);
    try std.testing.expect(std.mem.find(u8, rendered, "Ready?") != null);
    try std.testing.expect(std.mem.find(u8, rendered, "检查") != null);
    try std.testing.expect(std.mem.find(u8, rendered, "▼") != null);
    var lines = std.mem.splitScalar(u8, rendered, '\n');
    while (lines.next()) |line| try std.testing.expect(display_width.visibleWidthIgnoringAnsi(line) <= 80);
}

test "mermaid renders state class er and sequence diagrams" {
    const alloc = std.testing.allocator;
    const sources = [_][]const u8{
        "stateDiagram-v2\n  [*] --> Idle\n  Idle --> Active: start\n  Active --> [*]",
        "classDiagram\n  class Animal {\n    +name String\n    +move()\n  }\n  Animal <|-- Dog",
        "erDiagram\n  CUSTOMER ||--o{ ORDER : places\n  CUSTOMER {\n    string name\n  }",
        "sequenceDiagram\n  participant A as Alice\n  participant B as Bob\n  A->>B: Hello\n  B-->>A: Hi",
    };
    const needles = [_][]const u8{ "start", "+move()", "places", "Alice" };
    for (sources, needles) |source, needle| {
        const rendered = (try render(alloc, source, 100, .{})).?;
        defer alloc.free(rendered);
        try std.testing.expect(std.mem.find(u8, rendered, "┌") != null or std.mem.find(u8, rendered, "╭") != null);
        try std.testing.expect(std.mem.find(u8, rendered, needle) != null);
        try std.testing.expect(std.unicode.utf8ValidateSlice(rendered));
    }
}

test "mermaid unsupported and bounded diagrams fall back" {
    const alloc = std.testing.allocator;
    try std.testing.expect((try render(alloc, "pie\n title Pets", 80, .{})) == null);
    try std.testing.expect((try render(alloc, "sequenceDiagram\n loop empty\n end", 80, .{})) == null);
    try std.testing.expect((try render(alloc, "flowchart LR\n A --> B", 8, .{})) == null);
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(alloc);
    try source.appendSlice(alloc, "flowchart TD\n");
    var index: usize = 0;
    while (index <= model.max_nodes) : (index += 1) try source.print(alloc, "N{d}\n", .{index});
    try std.testing.expect((try render(alloc, source.items, 200, .{})) == null);
}

test "mermaid labels cannot inject terminal controls" {
    const alloc = std.testing.allocator;
    const rendered = (try render(alloc, "flowchart TD\n A[ok&#27;bad]", 80, .{})).?;
    defer alloc.free(rendered);
    try std.testing.expect(std.mem.findScalar(u8, rendered, 0x1b) == null);
}

test "mermaid preserves compact links line styles and reversed direction" {
    const alloc = std.testing.allocator;
    const dotted = (try render(alloc, "flowchart TD\nA-.->B", 80, .{})).?;
    defer alloc.free(dotted);
    try std.testing.expect(std.mem.find(u8, dotted, "╎") != null or std.mem.find(u8, dotted, "╌") != null);

    const thick = (try render(alloc, "flowchart TD\nA==>B", 80, .{})).?;
    defer alloc.free(thick);
    try std.testing.expect(std.mem.find(u8, thick, "┃") != null or std.mem.find(u8, thick, "━") != null);

    const reversed = (try render(alloc, "flowchart RL\nA[Vec<T>] --> B[<b>done</b><br/>now]", 80, .{})).?;
    defer alloc.free(reversed);
    try std.testing.expect(std.mem.find(u8, reversed, "Vec<T>") != null);
    try std.testing.expect(std.mem.find(u8, reversed, "done now") != null);
    try std.testing.expect(std.mem.find(u8, reversed, "◄") != null);

    const paired_shapes = (try render(alloc, "flowchart TD\nA([Start]) --> B[[End]]", 80, .{})).?;
    defer alloc.free(paired_shapes);
    try std.testing.expect(std.mem.find(u8, paired_shapes, "Start") != null);
    try std.testing.expect(std.mem.find(u8, paired_shapes, "[Start]") == null);
    try std.testing.expect(std.mem.find(u8, paired_shapes, "End") != null);
}

test "mermaid sequence renders notes self messages and autonumber" {
    const alloc = std.testing.allocator;
    const rendered = (try render(
        alloc,
        "sequenceDiagram\n  autonumber\n  participant A as Alice\n  participant B as Bob\n  Note over A,B: handshake\n  A->>A: prepare\n  A-->>B: send",
        100,
        .{},
    )).?;
    defer alloc.free(rendered);
    try std.testing.expect(std.mem.find(u8, rendered, "handshake") != null);
    try std.testing.expect(std.mem.find(u8, rendered, "1. prepare") != null);
    try std.testing.expect(std.mem.find(u8, rendered, "2. send") != null);
    try std.testing.expect(std.mem.find(u8, rendered, "╮") != null);

    const boxed = (try render(
        alloc,
        "sequenceDiagram\n  box Team\n  participant A as Alice\n  end\n  A->>A: ready",
        80,
        .{},
    )).?;
    defer alloc.free(boxed);
    try std.testing.expect(std.mem.find(u8, boxed, "Alice") != null);
    try std.testing.expect(std.mem.find(u8, boxed, " end ") == null);
}

fn check_render_allocation_failures(alloc: Allocator) !void {
    const sources = [_][]const u8{
        "flowchart LR\n  A[Request] -->|validate| B[Response]",
        "stateDiagram-v2\n  [*] --> Idle\n  Idle --> Active: start",
        "classDiagram\n  class Worker {\n    +name String\n    +run()\n  }\n  Worker <|-- Agent : extends",
        "erDiagram\n  CUSTOMER ||--o{ ORDER : places",
        "sequenceDiagram\n  participant A as Alice\n  participant B as Bob\n  A->>B: Hello",
    };
    for (sources) |source| {
        const rendered = try render(alloc, source, 100, .{});
        if (rendered) |owned| alloc.free(owned);
    }
}

test "mermaid renderer cleans partial allocations" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        check_render_allocation_failures,
        .{},
    );
}
