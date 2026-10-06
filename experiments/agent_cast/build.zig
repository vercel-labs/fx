const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const demo = b.addExecutable(.{
        .name = "agent-cast-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/demo.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    b.installArtifact(demo);
    const cache_demo = b.addExecutable(.{
        .name = "agent-cast-cache-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cache_demo.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    b.installArtifact(cache_demo);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run the bounded experiment tests");
    test_step.dependOn(&run_tests.step);

    const run_demo = b.addRunArtifact(demo);
    run_demo.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_demo.addArgs(args);
    const run_step = b.step("run", "Run the immutable-reader demonstration");
    run_step.dependOn(&run_demo.step);

    const run_cache_demo = b.addRunArtifact(cache_demo);
    run_cache_demo.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cache_demo.addArgs(args);
    const cache_run_step = b.step("run-cache", "Run the completed-value cache demonstration");
    cache_run_step.dependOn(&run_cache_demo.step);
}
