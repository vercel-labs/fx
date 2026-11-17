# Zig 0.17 toolchain, targets, and upgrade gotchas

Read this before installing a Zig next to another one, changing CI, release
targets, or minimum OS versions, when a project moves between 0.17.0 and
0.17.1, and during any 0.16 to 0.17 migration.

## Installing a Zig next to another one

Leave the shared `zig` (for example Homebrew's) alone: other checkouts and
agents may build branches that pin another release with it. Install each
release into its own versioned directory and select it per command or per
checkout.

Release archives are named `zig-<arch>-<os>-<version>.tar.xz` (`.zip` on
Windows), architecture first; 0.14.0 and earlier used `zig-<os>-<arch>-...`.
On Apple silicon the 0.17.1 archive is `zig-aarch64-macos-0.17.1.tar.xz`.
`https://ziglang.org/download/index.json` lists each release under its version
and `"<arch>-<os>"`, with its `tarball` URL, `shasum` (SHA-256), and `size`.
Set `v` to the version the project pins:

```sh
v=0.17.1; t=aarch64-macos      # or x86_64-macos, x86_64-linux, aarch64-linux
dir="$HOME/.local/zig/$v"
mkdir -p "$dir" && cd "$dir"
curl -fLO "https://ziglang.org/download/$v/zig-$t-$v.tar.xz"
sum=$(curl -fsSL https://ziglang.org/download/index.json |
  python3 -c "import json,sys; print(json.load(sys.stdin)['$v']['$t']['shasum'])")
echo "$sum  zig-$t-$v.tar.xz" | shasum -a 256 -c -   # stop unless it prints OK
tar -xJf "zig-$t-$v.tar.xz" --strip-components=1 && rm "zig-$t-$v.tar.xz"
"$dir/zig" version                                  # 0.17.1
```

Then select it without changing anything shared:

- Per command: `PATH="$HOME/.local/zig/0.17.1:$PATH" zig build test`, or run
  `"$HOME/.local/zig/0.17.1/zig"` directly.
- Per checkout, if the project uses direnv: `PATH_add ~/.local/zig/0.17.1` in
  `.envrc`.

Do not `brew upgrade zig`, relink Homebrew's `zig`, copy `zig` into a shared
`bin` directory, or add a versioned directory to a shell startup file. Each of
those switches every checkout at once. All releases can share the global cache
in `~/.cache/zig`.

A login shell can reorder `PATH`: on macOS, `/etc/zprofile` runs `path_helper`,
which puts `/opt/homebrew/bin` first again. When a tool starts commands in a
login shell, check `zig version` inside it, or call the compiler by absolute
path.

## Zig 0.17.1

0.17.1 (2026-11-02) is a bug-fix release: 209 commits, 57 closed issues, the
same language, and the same LLVM and Clang 22.1.8. Prefer it to 0.17.0. Neither
compiler enforces `minimum_zig_version`, so 0.17.0 still builds a project that
pins 0.17.1 and fails only on the changes below.

### The 0.17.0 regressions

| Issue | 0.17.1 |
|---|---|
| #37006 compiler-rt fails for soft-float x86 | Fixed |
| #37050 SPIR-V modules invalid | Fixed |
| #37357 Mach-O duplicate `LC_LOAD_DYLIB` from repeated `-framework`/`-l`; dyld refuses the binary | Fixed |
| #37310 `SafeAllocator` deadlocks on macOS arm64 while capturing a stack | Fixed (unwind handling of `FRAME_PAUTH_LR`) |
| #36986 a strong `@export` cannot override a weak symbol, which breaks `std.debug.simple_panic` and overriding zig libc | Partly fixed: the LLVM backend and the ELF linker work; the C backend, self-hosted WebAssembly, and self-hosted Mach-O (`-fno-llvm`) still fail |
| #36444 response files with `std.Build.Step.Run` after the maker and configurer split | Not fixed (0.18.0) |
| #37228 `std.c.termios` size and layout against glibc | Closed, but only `NCCS` changed; the struct is still the kernel layout (see the termios gotcha) |

### Still broken in 0.17.1

- **`std.Io.Evented` does not compile.** 0.17.0 fails on removed `Io.VTable`
  fields. 0.17.1 fails differently, at `Uring.zig` (Linux) and `Dispatch.zig`
  (macOS): `enum ... has no member named 'net_accept'`, because a backport
  brought cases for an `Io.Operation` member that only master has. Use
  `std.Io.Threaded`.

### Changes that can break or alter 0.17.0 code

- **Ending an HTTP request can now wait on the server.** In 0.17.0,
  `std.http.Client.Request.deinit` closed the connection of a request that
  sent a body (POST, PUT, PATCH) when its answer head was read but its body
  was not. In 0.17.1 it closes only while the request body is unsent
  (`payload_pending`) and otherwise reads the answer to its end to reuse the
  connection. An answer without a length, such as a 202 Accepted or an error
  page from some servers, or a stream the server holds open, then blocks
  `deinit` until the server closes. A clean build and most tests pass; it
  shows as a hang. Before `deinit` of a request whose answer you leave unread,
  set `req.connection.?.closing = true` when
  `req.reader.state == .received_head`. Once a body reader has started, or
  after a cancellation, `deinit` still closes.
- **`-femit-llvm-bc` is optimized.** `zig build-exe -femit-llvm-bc` and
  `Compile.getEmittedLlvmBc()` now write the module after LLVM's passes, and
  for Darwin targets LLVM wraps it in the `0x0B17C0DE` header; 0.17.0 wrote
  the unoptimized module, raw. Only `--verbose-llvm-bc=PATH` still writes the
  unoptimized one, and `std.Build` can't pass it to one step: run the compile
  that `zig build --verbose` prints again with that flag and `-fno-emit-bin`,
  which skips LLVM's passes. Profile-guided pipelines that instrument Zig's
  bitcode need this.
- `std.http.Reader` has a new required field `side: std.http.Side`
  (`.request` or `.response`); code that builds the struct by hand fails to
  compile. A request with neither `Content-Length` nor `Transfer-Encoding` now
  has no body, and GET, HEAD, DELETE, and OPTIONS may carry one.
- `std.Io.net.Ip4Address.fromAny` returns `?Ip4Address` (it returned
  `?Ip6Address`).
- `HashMap.removeByPtr` and `HashMapUnmanaged.removeByPtr` take `*const K`.
- `std.c.ffsl` and `ffsll` return `c_int`, and zig libc's `ffs*` now return the
  correct bit.
- A doc comment before `...` in a parameter list is a parse error.
- `std.crypto.sha3.TupleHash` output and AES-SIV output for empty input
  changed; stored digests from 0.17.0 do not match.
- `std.Io.Event.waitTimeout` waits until the deadline instead of returning
  `error.Timeout` on a spurious wake.
- `std.testing.checkAllAllocationFailures` fails every resize
  (`.resize_fail_index = 0`), so it no longer reports
  `NondeterministicMemoryUsage` for in-place growth (#37141).
- Threaded file reads, `pread`, and seek map `EACCES` to
  `error.AccessDenied`. On Linux, `Dir.renamePreserve` falls back to a hard
  link and unlink when `renameat2` returns `EINVAL` or `EOPNOTSUPP` (0.17.0
  panicked).
- `std.os.linux.sigdelset` clears the bit (it toggled it), and the aarch64,
  RISC-V, and MIPS syscall clobber lists are fixed.
- `std.process.can_spawn` is true on iOS and visionOS, and `std.Io.Threaded`
  compiles for iOS, tvOS, visionOS, and watchOS again.
- Build system: new `LazyPath` bases `deployed_prefix`, `deployed_lib`,
  `deployed_bin`, and `deployed_include` give install paths without
  `$DESTDIR`; with `$DESTDIR` set and no `--prefix`, the deployed prefix is
  `/usr`. A missing lazy dependency is fetched and retried instead of
  panicking (#37163). `dependOnDirectoryContents` directories are watched,
  `-Ddynamic-linker` no longer crashes, and a metadata-only change no longer
  misses the cache.
- Native builds on Apple M1 to M5 drop the `fuse_aes` CPU feature to avoid an
  LLVM miscompilation that made `zig build` run out of memory (#37215).
- New macOS `net/*.h` libc headers (`net/if_types.h`, `net/bpf.h`, ...).

Among the compiler fixes are miscompilations a clean build cannot reveal:
incorrect struct initialization in release builds (#37335), a ReleaseSafe
`@shrExact` check optimized away (#37001), `@intCast` from signed to narrower
unsigned emitting `trunc nsw` (#37127), and x86 backend switch-on-modulo
(#36732). Re-run release-mode tests after moving to 0.17.1.

## Minimum OS versions

| OS | Minimum |
|---|---|
| macOS (Darwin) | 15.0 |
| Linux | 5.10 |
| Windows | 10 |
| FreeBSD | 14.0 |
| NetBSD | 10.1 |
| OpenBSD | 7.8 |
| DragonFly BSD | 6.4 |

These are the standard library's minimums, so the compiler and any program
that uses std inherit them. Raise the declared minimum OS of release builds to
match.

## Targets

- `x86_64-linux` is Tier 1. `aarch64-macos` is Tier 2.
- `x86_64-macos` is Tier 2 and **obsolescent** (best-effort, expected to be
  removed). Plan its retirement before relying on it for releases.
- A self-hosted loongarch64 backend exists but is not usable yet. The
  WebAssembly backend passes the behavior tests but is not the debug default.

## Bundled components

- LLVM, Clang (`zig cc`, `zig c++`), libc++, libc++abi, libunwind, and libtsan:
  22.1.8 in both 0.17.0 and 0.17.1. LLVM loop vectorization stays disabled to
  avoid a miscompilation; 0.18 moves to LLVM 23.
- musl 1.2.5 with backports, glibc 2.44, Linux 7.2 headers, macOS 27.0 headers,
  NetBSD 11.0 and OpenBSD 7.9 libc, and current MinGW-w64. Many musl, MinGW, and
  WASI functions now come from zig libc; report their bugs to Zig.
- `libc.txt`: `gcc_dir` is renamed `cc_dir` (the old name still parses), and
  `cc_dir` is required on Linux. For Android and OpenHarmony, set it to the
  `crt_dir` value.

## Tools

- `zig fmt --complexity` prints tokens and AST nodes per file, a better
  size-of-change signal than line count.
- `zig objdump` inspects COFF, ELF, and other objects, with `--redact` and `-s`
  for snapshot tests.
- `zig rc` remains; `std.Build` resource compilation moves to a package in 0.18.

## Gotchas from a real 0.16 to 0.17 port

These came from upgrading a large Zig CLI and are worth checking in any
migration:

- **Lazy analysis hides breakage.** A successful `zig build` of one artifact
  left 0.16-only code compiling in tests, WebAssembly, and Node-API surfaces.
  Build every artifact and run the whole test suite.
- **`@hasDecl` duck typing failed silently.** Test doubles and real types that
  declared probed functions without `pub` lost features with no error. Search
  every probe target.
- **`main` keeps reintroducing old idioms.** Each merge from a branch written
  for 0.16 brought new `**`, private `@hasDecl` targets, and field-literal
  `std.json.Array` values, and later commits brought back deprecated calls
  such as `std.fmt.bufPrint`. Rerun the scanner and the full tests after every
  merge.
- **Labels changed.** Printing `@tagName(builtin.mode)` turned `ReleaseSafe`
  into `safe` in a user-visible report.
- **termios size, still present in 0.17.1.** On Linux with libc,
  `std.posix.termios` and `std.c.termios` are the 44-byte kernel struct, but
  `std.posix.tcgetattr` calls libc, which writes glibc's 60-byte struct and
  overruns the caller's stack. 0.17.1 closed #37228 by fixing `std.c.NCCS`
  only, so this is not fixed. Issue the `TCGETS` ioctl through
  `std.os.linux.tcgetattr` instead.
- **Allocation-failure sweeps can flake.** `std.testing.allocator` may grow an
  allocation in place on one run and not the next, which changes the
  allocation sequence a sweep enumerates. 0.17.1 fixes this inside
  `std.testing.checkAllAllocationFailures` by failing every resize, but a
  hand-written `std.testing.FailingAllocator` still lets resizes succeed by
  default (`resize_fail_index = maxInt(usize)`), and allocation-count
  comparisons still vary on 0.17.0 and 0.17.1. Back those with an allocator
  that refuses in-place resize, or set `resize_fail_index = 0`.
- **`posixConnect` can panic on macOS.** In `std.Io.Threaded` (0.16, 0.17.0,
  and 0.17.1), a `connect` interrupted by a signal is retried; macOS may then
  return `EISCONN`, which std treats as a programmer bug: Debug builds panic,
  and release builds fail the connect with `error.Unexpected`. The usual source
  of that signal is `std.Io.Select.cancel` or `cancelDiscard` while one of the
  select's tasks is still running: cancelling signals the task's worker
  thread, and the signal can land in the next task that thread runs. To stop a
  helper task early, tell it to stop (for example with a `std.Io.Event`), take
  its result from the select's queue, and only then cancel the select.
- **Release-build differences.** Rebuilding the same commit on another runner
  can number anonymous symbols differently, so builds are not byte-identical
  across machines. Array `@bitCast` lowers to per-element loops that the
  optimizer later folds, which matters to PGO pipelines that instrument before
  unrolling.
- **Xcode 16.4's linker rejects the macOS 27 stub.** Zig 0.17's libSystem stub
  lists `arm64e.x1` targets that Apple's 16.4 `ld` reports as an unknown
  architecture. Drop those targets from a copied stub or use a newer Xcode.
