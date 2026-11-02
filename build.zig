const std = @import("std");

const UpdateChannel = enum { stable, dev };

const WasmSurface = enum {
    none,
    core,
    term,
};

const PgsoArtifact = enum {
    fx,
    file_index,
    ui_activity,
    approval_review,
};

const NapiSurface = enum {
    none,
    core,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const pgso_artifact = b.option(
        PgsoArtifact,
        "pgso-artifact",
        "Emit ReleaseSafe LLVM bitcode for one PGO/PGSO artifact",
    );
    const wasm_surface = b.option(
        WasmSurface,
        "wasm-surface",
        "Build a WASI WebAssembly surface for JavaScript hosts (core or term)",
    ) orelse .none;
    const napi_surface = b.option(
        NapiSurface,
        "napi-surface",
        "Build a Node-API addon surface (core)",
    ) orelse .none;

    const sanitize_thread = b.option(
        bool,
        "sanitize-thread",
        "Build fx and its tests with ThreadSanitizer",
    ) orelse false;

    const git_commit = readGitCommit(b);
    const app_version = readAppVersion(b);
    const update_channel = b.option(UpdateChannel, "update-channel", "Build update channel (stable or dev)") orelse .stable;

    const build_options = b.addOptions();
    build_options.addOption([]const u8, "git_commit", git_commit);
    build_options.addOption([]const u8, "app_version", app_version);
    build_options.addOption([]const u8, "update_channel", @tagName(update_channel));
    build_options.addOption(WasmSurface, "wasm_surface", .none);
    // Whether this is a libfx artifact, which leaves out what only the fx
    // binary uses, such as its E2E test controls.
    build_options.addOption(bool, "libfx", false);
    build_options.addOption(bool, "builtin_tools", true);

    const fuzz_corpora = readFuzzCorpora(b);
    const fuzz_corpus = addFuzzCorpusModule(b, fuzz_corpora);
    // Encodes the fuzz tests' inline seeds the way they read them.
    const fuzz_seed = b.createModule(.{
        .root_source_file = b.path("src/fuzz_seed.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "fx",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .stack_check = false,
            .stack_protector = false,
            // A sanitized build keeps its frame pointers and symbols, so race
            // reports show whole stacks and name the code.
            .omit_frame_pointer = !sanitize_thread,
            .unwind_tables = .none,
            .error_tracing = false,
            .strip = optimize != .debug and !sanitize_thread,
            .sanitize_thread = sanitize_thread,
        }),
    });
    exe.root_module.addImport("build_options", build_options.createModule());
    exe.root_module.addImport("fuzz_corpus", fuzz_corpus);
    exe.root_module.addImport("fuzz_seed", fuzz_seed);
    const session_manager = addSessionManager(b, exe.root_module, target, optimize, null, fuzz_corpora);
    session_manager.sanitize_thread = sanitize_thread;

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();

    const run_step = b.step("run", "Run fx");
    run_step.dependOn(&run_cmd.step);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    run_exe_tests.step.dependOn(b.getInstallStep());
    // Tests launch the installed fx binary, and the session boundary test
    // walks the source tree.
    const test_paths = b.addOptions();
    test_paths.addOptionPathUntracked("product_exe", b.graph.path(.install_bin, "fx"));
    test_paths.addOptionPathUntracked("source_root", b.path("src"));
    const test_paths_module = test_paths.createModule();
    exe.root_module.addImport("test_paths", test_paths_module);

    // The session manager's own tests, as fx compiles it (no hooks).
    const session_manager_tests = b.addTest(.{ .root_module = session_manager });

    const run_session_manager_tests = b.addRunArtifact(session_manager_tests);
    // And with its fault and trace hooks, whose tests fx's build leaves out.
    const session_manager_hook_tests = b.addTest(.{
        .root_module = sessionManagerModule(b, target, optimize, null, true, fuzz_corpora),
    });
    session_manager_hook_tests.root_module.sanitize_thread = sanitize_thread;
    if (sanitize_thread and target.result.os.tag == .linux and
        (target.result.cpu.arch == .x86_64 or target.result.cpu.arch == .aarch64))
    {
        // Lets ThreadSanitizer see pages that `mremap` releases (see the
        // file). fx and its tests reach it through the session manager.
        const tsan_mremap = b.addObject(.{
            .name = "tsan_mremap",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/tsan_mremap.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .sanitize_thread = true,
            }),
        });
        session_manager.addObject(tsan_mremap);
        session_manager_hook_tests.root_module.addObject(tsan_mremap);
    }
    const run_session_manager_hook_tests = b.addRunArtifact(session_manager_hook_tests);
    const session_manager_test_step = b.step("test-session-manager", "Run the session manager's tests");
    session_manager_test_step.dependOn(&run_session_manager_tests.step);
    session_manager_test_step.dependOn(&run_session_manager_hook_tests.step);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&run_session_manager_tests.step);
    test_step.dependOn(&run_session_manager_hook_tests.step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = fuzz_seed })).step);

    const fuzz_step = b.step(
        "fuzz",
        "Replay the fuzz targets' saved inputs; add --fuzz=N to search N new inputs",
    );
    const fuzz_target = b.option(
        []const u8,
        "fuzz-target",
        "Run only this fuzz target from " ++ fuzz_registry_path,
    );
    const fuzz_root = b.createModule(.{
        .root_source_file = b.path("src/fuzz_targets.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    fuzz_root.addImport("build_options", build_options.createModule());
    fuzz_root.addImport("fuzz_corpus", fuzz_corpus);
    fuzz_root.addImport("fuzz_seed", fuzz_seed);
    fuzz_root.addImport("session_manager", session_manager);
    fuzz_root.addImport("test_paths", test_paths_module);
    addFuzzStep(b, fuzz_step, fuzz_corpora, fuzz_target, .{
        .fx = fuzz_root,
        .session_manager = session_manager,
    });

    if (wasm_surface != .none) {
        addWasmArtifact(b, wasm_surface, git_commit, app_version, update_channel);
    }
    if (napi_surface != .none) {
        addNapiArtifact(b, napi_surface, target, git_commit, app_version, update_channel);
    }

    // --- file_index search benchmark ---
    const benchmark_exports_mod = b.createModule(.{
        .root_source_file = b.path("src/benchmark_exports.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const file_index_bench = b.addExecutable(.{
        .name = "file-index-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("benchmarks/file_index_bench.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    file_index_bench.root_module.addImport("file_index", benchmark_exports_mod);
    const install_bench = b.addInstallArtifact(file_index_bench, .{});
    const bench_step = b.step("bench-file-index", "Build file_index search benchmark");
    bench_step.dependOn(&install_bench.step);

    const run_bench = b.addRunArtifact(file_index_bench);
    run_bench.step.dependOn(&install_bench.step);
    run_bench.addPassthruArgs();
    const run_bench_step = b.step("run-bench-file-index", "Build and run file_index search benchmark");
    run_bench_step.dependOn(&run_bench.step);

    // --- UI activity progress benchmark ---
    const ui_activity_bench = b.addExecutable(.{
        .name = "ui-activity-progress-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("benchmarks/activity_progress.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    ui_activity_bench.root_module.addImport(
        "benchmark_exports",
        benchmark_exports_mod,
    );
    const install_ui_activity_bench = b.addInstallArtifact(ui_activity_bench, .{});
    const ui_activity_bench_step = b.step(
        "bench-ui-activity",
        "Build the UI activity progress benchmark",
    );
    ui_activity_bench_step.dependOn(&install_ui_activity_bench.step);

    const run_ui_activity_bench = b.addRunArtifact(ui_activity_bench);
    run_ui_activity_bench.step.dependOn(&install_ui_activity_bench.step);
    const run_ui_activity_bench_step = b.step(
        "run-bench-ui-activity",
        "Build and run the UI activity progress benchmark",
    );
    run_ui_activity_bench_step.dependOn(&run_ui_activity_bench.step);

    const ui_activity_bench_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("benchmarks/activity_progress.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    ui_activity_bench_tests.root_module.addImport(
        "benchmark_exports",
        benchmark_exports_mod,
    );
    const run_ui_activity_bench_tests = b.addRunArtifact(ui_activity_bench_tests);
    test_step.dependOn(&run_ui_activity_bench_tests.step);
    const test_ui_activity_bench_step = b.step(
        "test-ui-activity-benchmark",
        "Run UI activity benchmark policy tests",
    );
    test_ui_activity_bench_step.dependOn(&run_ui_activity_bench_tests.step);

    // --- file-diff approval review benchmark ---
    const approval_review_bench = b.addExecutable(.{
        .name = "approval-review-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("benchmarks/approval_review.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    approval_review_bench.root_module.addImport(
        "benchmark_exports",
        benchmark_exports_mod,
    );
    const install_approval_review_bench = b.addInstallArtifact(
        approval_review_bench,
        .{},
    );
    const approval_review_bench_step = b.step(
        "bench-approval-review",
        "Build the file-diff approval review benchmark",
    );
    approval_review_bench_step.dependOn(&install_approval_review_bench.step);

    const run_approval_review_bench = b.addRunArtifact(approval_review_bench);
    run_approval_review_bench.step.dependOn(&install_approval_review_bench.step);
    run_approval_review_bench.addPassthruArgs();
    const run_approval_review_bench_step = b.step(
        "run-bench-approval-review",
        "Build and run the file-diff approval review benchmark",
    );
    run_approval_review_bench_step.dependOn(&run_approval_review_bench.step);

    const approval_review_bench_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("benchmarks/approval_review.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    approval_review_bench_tests.root_module.addImport(
        "benchmark_exports",
        benchmark_exports_mod,
    );
    const run_approval_review_bench_tests = b.addRunArtifact(
        approval_review_bench_tests,
    );
    test_step.dependOn(&run_approval_review_bench_tests.step);
    const test_approval_review_bench_step = b.step(
        "test-approval-review-benchmark",
        "Run file-diff approval review benchmark qualification tests",
    );
    test_approval_review_bench_step.dependOn(
        &run_approval_review_bench_tests.step,
    );

    const pgso_ir_step = b.step(
        "pgso-ir",
        "Emit selected ReleaseSafe LLVM bitcode for PGO/PGSO qualification",
    );
    if (pgso_artifact) |artifact| {
        const selected: *std.Build.Step.Compile = switch (artifact) {
            .fx => exe,
            .file_index => file_index_bench,
            .ui_activity => ui_activity_bench,
            .approval_review => approval_review_bench,
        };
        const output_name = switch (artifact) {
            .fx => "pgso/fx.bc",
            .file_index => "pgso/file-index.bc",
            .ui_activity => "pgso/ui-activity.bc",
            .approval_review => "pgso/approval-review.bc",
        };
        const install_ir = b.addInstallFile(
            selected.getEmittedLlvmBc(),
            output_name,
        );
        pgso_ir_step.dependOn(&install_ir.step);
    } else {
        const missing_artifact = b.addFail(
            "pgso-ir requires -Dpgso-artifact",
        );
        pgso_ir_step.dependOn(&missing_artifact.step);
    }
}

fn addWasmArtifact(
    b: *std.Build,
    surface: WasmSurface,
    git_commit: []const u8,
    app_version: []const u8,
    update_channel: UpdateChannel,
) void {
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .wasi,
    });
    const name = switch (surface) {
        .core => "fx-core",
        .term => "fx-term",
        .none => unreachable,
    };
    const description = switch (surface) {
        .core => "Build the headless fx WebAssembly artifact",
        .term => "Build the terminal fx WebAssembly artifact",
        .none => unreachable,
    };

    const wasm_options = b.addOptions();
    wasm_options.addOption([]const u8, "git_commit", git_commit);
    wasm_options.addOption([]const u8, "app_version", app_version);
    wasm_options.addOption([]const u8, "update_channel", @tagName(update_channel));
    wasm_options.addOption(WasmSurface, "wasm_surface", surface);
    wasm_options.addOption(bool, "libfx", true);
    wasm_options.addOption(bool, "builtin_tools", true);

    const wasm_root = switch (surface) {
        .core => "src/wasm_core_main.zig",
        .term => "src/wasm_term_main.zig",
        .none => unreachable,
    };
    const wasm_exe = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(wasm_root),
            .target = wasm_target,
            .optimize = .small,
            .single_threaded = true,
            .link_libc = true,
            .stack_check = false,
            .stack_protector = false,
            .omit_frame_pointer = true,
            .unwind_tables = .none,
            .error_tracing = false,
            .strip = true,
        }),
    });
    if (surface == .core) wasm_exe.stack_size = 1024 * 1024;
    wasm_exe.root_module.addImport("build_options", wasm_options.createModule());
    _ = addSessionManager(b, wasm_exe.root_module, wasm_target, .small, true, &.{});

    const install_wasm = b.addInstallArtifact(wasm_exe, .{});
    const wasm_step = b.step(name ++ "-wasm", description);
    wasm_step.dependOn(&install_wasm.step);
    b.getInstallStep().dependOn(&install_wasm.step);
}

fn addNapiArtifact(
    b: *std.Build,
    surface: NapiSurface,
    target: std.Build.ResolvedTarget,
    git_commit: []const u8,
    app_version: []const u8,
    update_channel: UpdateChannel,
) void {
    const napi_options = b.addOptions();
    napi_options.addOption([]const u8, "git_commit", git_commit);
    napi_options.addOption([]const u8, "app_version", app_version);
    napi_options.addOption([]const u8, "update_channel", @tagName(update_channel));
    napi_options.addOption(NapiSurface, "napi_surface", surface);
    napi_options.addOption(bool, "libfx", true);
    // libfx agents run only the host's tools, so the addon leaves fx's out.
    napi_options.addOption(bool, "builtin_tools", false);

    const root = switch (surface) {
        .core => "src/napi_core_main.zig",
        .none => unreachable,
    };
    const lib = b.addLibrary(.{
        .name = "libfx",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path(root),
            .target = target,
            .optimize = .safe,
            .link_libc = true,
            // Node never unwinds C++ exceptions through the addon, and its Zig
            // code already bounds-checks in ReleaseSafe, so unwind tables and
            // stack canaries only add size. Unlike the fx executable, the
            // addon keeps frame pointers: Apple's arm64 ABI requires them,
            // crash reports and profilers of the app walk them through the
            // addon, and on x86-64 they make it about 0.2 MB smaller.
            .stack_check = false,
            .stack_protector = false,
            .omit_frame_pointer = false,
            .unwind_tables = .none,
            .error_tracing = false,
            .strip = true,
        }),
    });
    lib.root_module.addImport("build_options", napi_options.createModule());
    _ = addSessionManager(b, lib.root_module, target, .safe, null, &.{});
    const node_include = b.option(
        []const u8,
        "node-include-dir",
        "Directory containing node_api.h for the N-API addon",
    ) orelse discoverNodeIncludeDir(b);
    const node_api = b.addTranslateC(.{
        .root_source_file = .{ .cwd_relative = b.pathJoin(&.{ node_include, "node_api.h" }) },
        .target = target,
        .optimize = .safe,
    });
    node_api.addSystemIncludePath(.{ .cwd_relative = node_include });
    lib.root_module.addImport("node_api", node_api.createModule());
    lib.linker_allow_shlib_undefined = true;

    const install = b.addInstallArtifact(lib, .{ .dest_sub_path = "libfx.node" });
    const step = b.step("libfx-napi", "Build the libfx Node-API core addon");
    step.dependOn(&install.step);
    b.getInstallStep().dependOn(&install.step);
}

fn discoverNodeIncludeDir(b: *std.Build) []const u8 {
    const out = switch (b.runFallible(
        &.{ "node", "-p", "require('node:path').join(require('node:path').dirname(process.execPath), '..', 'include', 'node')" },
        .{ .stderr_behavior = .ignore },
    )) {
        .success => |stdout| stdout,
        .spawn_failed, .crashed => std.process.fatal("Node.js is required to locate node_api.h; pass -Dnode-include-dir=<path>", .{}),
        .bad_exit_code => std.process.fatal("could not locate node_api.h; pass -Dnode-include-dir=<path>", .{}),
    };
    const trimmed = std.mem.trim(u8, out, " \t\r\n");
    return b.allocator.dupe(u8, trimmed) catch std.process.fatal("could not allocate Node include path", .{});
}

fn readGitCommit(b: *std.Build) []const u8 {
    // The configure cache cannot see a new commit, so rerun configure.
    b.graph.poisonCache();
    const out = switch (b.runFallible(
        &.{ "git", "rev-parse", "--short=12", "HEAD" },
        .{ .stderr_behavior = .ignore },
    )) {
        .success => |stdout| stdout,
        .spawn_failed, .bad_exit_code, .crashed => return "unknown",
    };
    const trimmed = std.mem.trim(u8, out, " \t\r\n");
    return b.allocator.dupe(u8, trimmed) catch "unknown";
}

/// The session manager as its own module, rooted at its API. It imports
/// nothing but its own options, and a file cannot belong to two modules, so
/// fx reaches it only through `@import("session_manager")`. Its fuzz targets'
/// saved inputs travel in those options as `fuzz_corpus_<target>`.
fn addSessionManager(
    b: *std.Build,
    importer: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    single_threaded: ?bool,
    fuzz_corpora: []const FuzzCorpus,
) *std.Build.Module {
    const module = sessionManagerModule(b, target, optimize, single_threaded, false, fuzz_corpora);
    importer.addImport("session_manager", module);
    return module;
}

/// `hooks` compiles in the fault and trace hooks, which only tests use.
fn sessionManagerModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    single_threaded: ?bool,
    hooks: bool,
    fuzz_corpora: []const FuzzCorpus,
) *std.Build.Module {
    const options = b.addOptions();
    options.addOption(bool, "hooks", hooks);
    options.addOptionPathUntracked("trace_dir", b.graph.path(.install_prefix, "session-manager-traces"));
    options.addOptionPathUntracked("src_dir", b.path("src/core/session_manager"));
    for (fuzz_corpora) |corpus| {
        if (corpus.target.module != .session_manager) continue;
        options.addOption(
            []const []const u8,
            b.fmt("fuzz_corpus_{s}", .{corpus.target.name}),
            corpus.inputs,
        );
    }
    const module = b.createModule(.{
        .root_source_file = b.path("src/core/session_manager/api.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .single_threaded = single_threaded,
    });
    module.addImport("build_options", options.createModule());
    return module;
}

fn readAppVersion(b: *std.Build) []const u8 {
    b.dependOnFileContents(b.path("src/main.zig"));
    const main_path = b.pathJoin(&.{ b.root.sub_path, "src/main.zig" });
    const bytes = b.root.root_dir.handle.readFileAlloc(b.graph.io, main_path, b.allocator, .limited(1024 * 1024)) catch
        @panic("could not read src/main.zig to resolve app version");
    defer b.allocator.free(bytes);

    const prefix = "pub const version = \"";
    const start = (std.mem.find(u8, bytes, prefix) orelse
        @panic("could not find pub const version in src/main.zig")) + prefix.len;
    const end_rel = std.mem.findScalar(u8, bytes[start..], '"') orelse
        @panic("could not parse pub const version in src/main.zig");
    return b.allocator.dupe(u8, bytes[start .. start + end_rel]) catch
        @panic("could not allocate app version");
}

const fuzz_registry_path = "tests/fuzz/targets.json";
const fuzz_corpus_dir = "tests/fuzz/corpus";
/// A saved input this large is almost certainly a mistake, such as a build
/// artifact copied into a corpus folder.
const max_fuzz_input_bytes = 1024 * 1024;

const FuzzModule = enum { fx, session_manager };

/// One entry in `tests/fuzz/targets.json`.
const FuzzTarget = struct {
    /// Names the target's corpus folder and its `fuzz_corpus` declaration.
    name: []const u8,
    /// The module whose test binary holds the fuzz test.
    module: FuzzModule,
    /// The fuzz test's exact name, used as the test filter.
    @"test": []const u8,
    /// Iterations for one nightly run. Only the nightly workflow reads it.
    iterations: u64,
};

const FuzzRegistry = struct {
    targets: []const FuzzTarget,
};

/// A registered fuzz target and its saved inputs, sorted by file name.
const FuzzCorpus = struct {
    target: FuzzTarget,
    inputs: []const []const u8,
};

const FuzzRoots = struct {
    fx: *std.Build.Module,
    session_manager: *std.Build.Module,
};

/// Reads the fuzz registry and each target's saved inputs. Configuration
/// reruns on every build (see `readGitCommit`), so a newly added input is
/// picked up without listing it anywhere.
fn readFuzzCorpora(b: *std.Build) []const FuzzCorpus {
    b.dependOnFileContents(b.path(fuzz_registry_path));
    const registry_bytes = b.root.root_dir.handle.readFileAlloc(
        b.graph.io,
        b.pathJoin(&.{ b.root.sub_path, fuzz_registry_path }),
        b.allocator,
        .limited(max_fuzz_input_bytes),
    ) catch |err| std.process.fatal("could not read {s}: {t}", .{ fuzz_registry_path, err });
    const registry = std.json.parseFromSliceLeaky(FuzzRegistry, b.allocator, registry_bytes, .{}) catch |err|
        std.process.fatal("{s} is not a valid fuzz registry: {t}", .{ fuzz_registry_path, err });

    const corpora = b.allocator.alloc(FuzzCorpus, registry.targets.len) catch |err|
        std.process.fatal("could not list the fuzz targets: {t}", .{err});
    for (registry.targets, corpora, 0..) |fuzz_target, *corpus, index| {
        if (!isFuzzTargetName(fuzz_target.name)) std.process.fatal(
            "{s}: fuzz target name '{s}' must start with a lowercase letter and use only lowercase letters, digits, and underscores",
            .{ fuzz_registry_path, fuzz_target.name },
        );
        for (registry.targets[0..index]) |earlier| {
            if (std.mem.eql(u8, earlier.name, fuzz_target.name)) std.process.fatal(
                "{s}: fuzz target '{s}' is listed twice",
                .{ fuzz_registry_path, fuzz_target.name },
            );
        }
        corpus.* = .{ .target = fuzz_target, .inputs = readFuzzInputs(b, fuzz_target.name) };
    }
    rejectUnregisteredCorpusFolders(b, registry.targets);
    return corpora;
}

fn isFuzzTargetName(name: []const u8) bool {
    if (name.len == 0 or !std.ascii.isLower(name[0])) return false;
    for (name) |byte| {
        if (!std.ascii.isLower(byte) and !std.ascii.isDigit(byte) and byte != '_') return false;
    }
    return true;
}

/// Returns the files in `tests/fuzz/corpus/<name>/`, sorted by file name so
/// the generated module does not depend on directory order. A missing folder
/// means the target has no saved inputs yet. Dotfiles are skipped.
fn readFuzzInputs(b: *std.Build, name: []const u8) []const []const u8 {
    const io = b.graph.io;
    const folder = b.pathJoin(&.{ fuzz_corpus_dir, name });
    var dir = b.root.root_dir.handle.openDir(io, b.pathJoin(&.{ b.root.sub_path, folder }), .{
        .iterate = true,
    }) catch |err| switch (err) {
        error.FileNotFound => return &.{},
        else => std.process.fatal("could not open {s}: {t}", .{ folder, err }),
    };
    defer dir.close(io);

    var file_names: std.ArrayList([]const u8) = .empty;
    var entries = dir.iterate();
    while (entries.next(io) catch |err| std.process.fatal("could not list {s}: {t}", .{ folder, err })) |entry| {
        if (entry.name[0] == '.') continue;
        if (entry.kind != .file) std.process.fatal(
            "{s}/{s}: saved fuzz inputs must be regular files",
            .{ folder, entry.name },
        );
        file_names.append(b.allocator, b.dupe(entry.name)) catch |err|
            std.process.fatal("could not list {s}: {t}", .{ folder, err });
    }
    std.mem.sort([]const u8, file_names.items, {}, lessThanBytes);

    const inputs = b.allocator.alloc([]const u8, file_names.items.len) catch |err|
        std.process.fatal("could not read {s}: {t}", .{ folder, err });
    for (file_names.items, inputs) |file_name, *input| {
        b.dependOnFileContents(b.path(b.pathJoin(&.{ folder, file_name })));
        input.* = dir.readFileAlloc(io, file_name, b.allocator, .limited(max_fuzz_input_bytes + 1)) catch |err| switch (err) {
            error.StreamTooLong => std.process.fatal("{s}/{s} is larger than 1 MiB", .{ folder, file_name }),
            else => std.process.fatal("could not read {s}/{s}: {t}", .{ folder, file_name, err }),
        };
    }
    return inputs;
}

/// Fails the build when a corpus folder has no registry entry, so a typo in
/// a folder name cannot leave saved inputs that never run.
fn rejectUnregisteredCorpusFolders(b: *std.Build, targets: []const FuzzTarget) void {
    const io = b.graph.io;
    var dir = b.root.root_dir.handle.openDir(io, b.pathJoin(&.{ b.root.sub_path, fuzz_corpus_dir }), .{
        .iterate = true,
    }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => std.process.fatal("could not open {s}: {t}", .{ fuzz_corpus_dir, err }),
    };
    defer dir.close(io);

    var entries = dir.iterate();
    entries: while (entries.next(io) catch |err| std.process.fatal("could not list {s}: {t}", .{ fuzz_corpus_dir, err })) |entry| {
        if (entry.name[0] == '.') continue;
        for (targets) |fuzz_target| {
            if (entry.kind == .directory and std.mem.eql(u8, entry.name, fuzz_target.name)) continue :entries;
        }
        std.process.fatal(
            "{s}/{s} does not match a fuzz target in {s}",
            .{ fuzz_corpus_dir, entry.name, fuzz_registry_path },
        );
    }
}

fn lessThanBytes(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.lessThan(u8, lhs, rhs);
}

/// The `fuzz_corpus` module: one `[]const []const u8` of saved inputs per fx
/// fuzz target, named after the target.
fn addFuzzCorpusModule(b: *std.Build, corpora: []const FuzzCorpus) *std.Build.Module {
    const options = b.addOptions();
    for (corpora) |corpus| {
        if (corpus.target.module != .fx) continue;
        options.addOption([]const []const u8, corpus.target.name, corpus.inputs);
    }
    return options.createModule();
}

/// Runs the selected fuzz targets, or all of them. Each module's test binary
/// is filtered to its targets' fuzz tests, so `--fuzz` spends every iteration
/// on them and ordinary unit tests never run here.
fn addFuzzStep(
    b: *std.Build,
    step: *std.Build.Step,
    corpora: []const FuzzCorpus,
    selected: ?[]const u8,
    roots: FuzzRoots,
) void {
    var fx_filters: std.ArrayList([]const u8) = .empty;
    var session_manager_filters: std.ArrayList([]const u8) = .empty;
    for (corpora) |corpus| {
        if (selected) |name| {
            if (!std.mem.eql(u8, name, corpus.target.name)) continue;
        }
        const filters = switch (corpus.target.module) {
            .fx => &fx_filters,
            .session_manager => &session_manager_filters,
        };
        filters.append(b.allocator, corpus.target.@"test") catch |err|
            std.process.fatal("could not select the fuzz tests: {t}", .{err});
    }
    if (fx_filters.items.len == 0 and session_manager_filters.items.len == 0) {
        const message = if (selected) |name|
            b.fmt("unknown fuzz target '{s}'; the targets are listed in {s}", .{ name, fuzz_registry_path })
        else
            "no fuzz targets are listed in " ++ fuzz_registry_path;
        step.dependOn(&b.addFail(message).step);
        return;
    }

    const binaries = [_]struct {
        name: []const u8,
        root: *std.Build.Module,
        filters: []const []const u8,
    }{
        .{ .name = "fuzz", .root = roots.fx, .filters = fx_filters.items },
        .{ .name = "fuzz-session-manager", .root = roots.session_manager, .filters = session_manager_filters.items },
    };
    for (binaries) |binary| {
        if (binary.filters.len == 0) continue;
        const tests = b.addTest(.{
            .name = binary.name,
            .root_module = binary.root,
            .filters = binary.filters,
        });
        step.dependOn(&b.addRunArtifact(tests).step);
    }
}
