# Zig 0.17 build system

Read this before editing `build.zig`, `build.zig.zon`, CI that runs
`zig build`, or anything that parses build output.

## Architecture

- `zig build` runs `build.zig` in a separate **configurer** process. A
  **maker** executable, built once with optimizations after installing Zig,
  fetches packages and executes the graph. Editing `build.zig` no longer
  rebuilds the maker.
- Package management moved from the compiler into the build system. `zig
  build`, `zig fetch`, `zig init`, `zig libc`, and `zig cache-cat` run that
  code in `-Osafe`. Set `ZIG_DEBUG_CMD=1` to build it in debug mode.
- Configuration is cached in a compact binary format. Pass
  `--print-configuration` to print it as ZON.
- Overriding the build runner is no longer supported. The **Build Server
  Protocol** (`zig build --listen=-`) exposes the graph, step progress, errors,
  generated files, and build requests to tools.
- **ZLS does not work with 0.17** because of this split.

## Configure-cache poisoning

`build.zig` logic that has side effects or depends on untracked state
"poisons" the configuration cache, which forces it to rerun. `b.findProgram` and
`b.graph.poisonCache()` poison it. Declare dependencies instead:

- `b.dependOnFileContents(lazy_path)`, `b.dependOnFileMetadata(...)`
- `b.dependOnDirectoryContents(...)`, `b.dependOnDirectoryMetadata(...)`

`--cache-poison=pure|poisoned|disallowed|ignored` overrides the behavior
(`pure` is the default).

## API changes in `build.zig`

| 0.16 | 0.17 |
|---|---|
| `b.build_root` (a `Directory`) | `b.root` (a `Cache.Path`); print paths with `{f}` |
| `if (b.args) \|args\| run.addArgs(args);` | `run.addPassthruArgs();` (configure can no longer read run args) |
| `b.addFmt(.{ .paths = &.{ "src" }, .exclude_paths = ... })` | `.paths = b.pathList(&.{ "src", "build.zig" })` |
| `lazy_path.getDisplayName()` | `"{f}"` formatting |
| `lazy_path.basename()` | removed, since the value is unknown until make |
| `ConfigHeader.Options.include_guard_override` | `include_guard` |
| `b.findProgram(...)` when configure does not need the result | `b.findProgramLazy(.{ ... })` returning a `LazyPath` |
| `options.addOptionPath(name, path)` for a directory | `addOptionPathDirectory`; `addOptionPathUntracked` opts out of tracking |
| `b.lazyDependency(name, args)` returning `?*Dependency` | `try b.dependencyLazy(name, args)`; `b.dependency` also supports lazy deps |
| `b.dupe`, `b.dupeStrings`, `b.dupePath` | `b.graph.dupeString`, `dupeStrings`, `dupePath` |
| `b.runAllowFail` | `b.runFallible` |
| `run.enableTestRunnerMode()` | `run.enableProtocolMode()` |
| `optimize == .ReleaseSafe` | `optimize == .safe` |
| `b.addTranslateC(...)` | the translate-c package (below) |
| `Module.addWin32ResourceFile` | deprecated; resource compilation moves to an official package in 0.18 (`zig rc` stays) |

### Run step arguments

Each `addX` and `addPrefixedX` pair is deprecated in favor of one `addX2` with
options. `PathArgOptions` is `.{ .prefix = "", .suffix = "", .make_absolute =
false }`; `ArgOptions` has `prefix` and `suffix`.

| Deprecated | 0.17 |
|---|---|
| `addArtifactArg(exe)`, `addPrefixedArtifactArg("-p", exe)` | `addArtifactArg2(exe, .{ .prefix = "-p" })` |
| `addFileArg`, `addPrefixedFileArg` | `addFileArg2(lazy_path, .{})` |
| `addOutputFileArg`, `addPrefixedOutputFileArg` | `addOutputFileArg2(sub_path, .{})` returns a `LazyPath` |
| `addFileContentArg`, `addPrefixedFileContentArg` | `addFileContentArg2(lazy_path, .{})` |
| `addOutputDirectoryArg`, `addPrefixedOutputDirectoryArg` | `addOutputDirectoryArg2(basename, .{})` returns a `LazyPath` |
| `addDirectoryArg`, `addPrefixedDirectoryArg`, `addDecoratedDirectoryArg` | `addDirectoryArg2(lazy_dir, .{})` |
| `addDepFileOutputArg`, `addPrefixedDepFileOutputArg` | `addDepFileOutputArg2(basename, .{})` returns a `LazyPath` |

On Windows and Wine, artifact arguments now extend `PATH` with DLL directories
only for `argv[0]`.

## C translation

`@cImport` is removed and `std.Build.Step.TranslateC` is deprecated. The
official ZSF package has the same implementation and more options:

```sh
zig fetch --save git+https://codeberg.org/ziglang/translate-c
```

```zig
const Translator = @import("translate_c").Translator;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const translate_c = b.dependency("translate_c", .{});
    const translator: Translator = .init(translate_c, .{
        .c_source_file = b.path("src/c.h"),
        .target = target,
        .optimize = optimize,
        .link_system_libs = &.{.{ .name = "glfw" }},
    });
    // import it as: .{ .name = "c", .module = translator.mod }
}
```

This adds a package dependency. If the project restricts dependencies, keep
`b.addTranslateC` (deprecated but working) and ask before switching.

## Package management

- `--pkg-path` and `ZIG_LOCAL_PKG_DIR` override the package directory for both
  `zig fetch` and `zig build`.
- `zig fetch` fills only the global cache unless `--save` is passed, and it no
  longer needs a `build.zig`. Fetching by path always recomputes the hash and
  overwrites the global entry. `zig fetch .` works again.
- Path dependencies that escape the parent package root are rejected.
- Lazy dependencies are logged when they are fetched.

## Incremental compilation

`zig build -fincremental --watch` works for most projects targeting
`x86_64-linux`, using the new ELF linker. Other targets still use LLVM and LLD
and do not benefit yet.

## Changed in 0.17.1

- `getEmittedLlvmBc()` gives bitcode after LLVM's passes (wrapped for Darwin);
  0.17.0 gave the unoptimized module. No `Compile` option passes
  `--verbose-llvm-bc` or `-fopt-bisect-limit`; toolchain.md shows the
  workaround.
- New `LazyPath` bases `deployed_prefix`, `deployed_lib`, `deployed_bin`, and
  `deployed_include` name install paths without `$DESTDIR`; the `install_*`
  bases are `$DESTDIR` plus those. With `$DESTDIR` set and no `--prefix`, the
  deployed prefix is `/usr`. Like `install_*`, they cannot be read during
  configure.
- `Dependency.artifact`, `module`, `namedWriteFiles`, and `namedLazyPath`
  fetch a pending lazy dependency and retry instead of panicking with "unable
  to find".
- `--fork` handles two packages with the same name and a package together with
  its dependency; `dependOnDirectoryContents` directories are watched;
  `-Ddynamic-linker` no longer crashes the maker; `stack_protector` is part of
  the cache hash, and a metadata-only change no longer misses the cache.
- Run steps still cannot use response files (#36444, planned for 0.18.0).

## CI

Pin the toolchain everywhere it is installed, for example `mlugg/setup-zig`
with `version: "0.17.1"`, and set `.minimum_zig_version = "0.17.1"` in
`build.zig.zon`. Neither 0.16 nor 0.17 enforces that field, so a job that installs
another release fails later and less clearly. When a workflow builds an older
commit, read that commit's `minimum_zig_version` instead of assuming the
current one.
