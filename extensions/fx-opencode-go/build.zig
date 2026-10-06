// Independent native packaging keeps provider transport outside fx Core.
const std = @import("std");
const executable_name = "fx-opencode-go";

pub fn build(b: *std.Build) void {
    b.installArtifact(create(b, b.path("main.zig"), b.standardTargetOptions(.{}), b.standardOptimizeOption(.{})));
}

/// Both standalone and repository builds produce the same provider executable.
pub fn create(b: *std.Build, source: std.Build.LazyPath, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Step.Compile {
    return b.addExecutable(.{ .name = executable_name, .root_module = b.createModule(.{
        .root_source_file = source,
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }) });
}
