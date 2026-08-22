const std = @import("std");

pub const background_processes = false;

pub fn isTarget(arch: std.Target.Cpu.Arch) bool {
    return arch == .wasm32 or arch == .wasm64;
}

/// Returns an owned target description. The caller must free it with `alloc`.
pub fn operatingSystemText(
    alloc: std.mem.Allocator,
    os_tag: std.Target.Os.Tag,
) std.mem.Allocator.Error![]u8 {
    return alloc.dupe(u8, @tagName(os_tag));
}

test "WASM targets expose no native process capabilities" {
    try std.testing.expect(isTarget(.wasm32));
    try std.testing.expect(isTarget(.wasm64));
    try std.testing.expect(!isTarget(.x86_64));
    try std.testing.expect(!background_processes);
}

test "WASM operating system text does not require native discovery" {
    const wasi = try operatingSystemText(std.testing.allocator, .wasi);
    defer std.testing.allocator.free(wasi);
    try std.testing.expectEqualStrings("wasi", wasi);

    const emscripten = try operatingSystemText(std.testing.allocator, .emscripten);
    defer std.testing.allocator.free(emscripten);
    try std.testing.expectEqualStrings("emscripten", emscripten);
}
