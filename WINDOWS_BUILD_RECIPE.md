# Windows Build Recipe for fx (x86_64-windows)

> Status: **WORKING** — `zig-out/bin/fx.exe` builds and runs as of this commit.
> `fx.exe --version` prints `0.0.4` and exits 0. `fx.exe --help` prints the full
> top-level help. Interactive mode still requires a TTY (expected: terminal
> abstraction phase pending per `WINDOWS_SUPPORT_PLAN.md`).

## Toolchain

| Item | Value |
| --- | --- |
| Zig | **0.16.0** (`C:\zig\zig-x86_64-windows-0.16.0\zig.exe`) |
| Target | `x86_64-windows` |
| Optimize | `ReleaseSafe` |
| Working dir | `C:\programas\fx` |
| Branch | `feat/windows-support` |

Zig 0.17-dev was attempted first (see "Try A" below) but requires invasive
changes to the fx source (300+ `**` operator sites and `errdefer |err|` blocks
are incompatible with 0.17's parser and operator set), so 0.16 was chosen.

## Successful build command

```bash
cd /c/programas/fx
"/c/zig/zig-x86_64-windows-0.16.0/zig.exe" build -Dtarget=x86_64-windows -Doptimize=ReleaseSafe
```

Output:
- `zig-out/bin/fx.exe` (~11 MB, PE32+ x86_64 Windows console)
- `zig-out/bin/fx.pdb`

## Verification

```
$ /c/programas/fx/zig-out/bin/fx.exe --version
0.0.4

$ /c/programas/fx/zig-out/bin/fx.exe --help
𝒇x v0.0.4
Fast, native coding agent for the terminal.

𝒇x starts an interactive session by default. Use `fx ask` to run one
noninteractive request.

Usage:
  fx [flags]
  fx <command> [...flags] [...args]

Commands:
  ask <prompt>                   Run one noninteractive request
  pr [context]                   Draft or publish a pull request
  issue [context]                Draft or publish a GitHub issue
  background [last|<id>]         List or inspect background commands
  sessions                       List saved sessions for the current workspace
  session <last|id>              Inspect, resume, migrate, or recover saved
                                 sessions
  ...
```

`fx.exe doctor` currently panics on Windows (reached unreachable code). Doctor
is non-critical for the v1 build gate and is tracked separately.

## Patches applied

### 1. `src/main.zig` — CLI argv decoding on Windows

The pre-Windows `argsFromRaw` returned an empty `std.process.Args` vector on
Windows because the C-runtime `argv` on Windows uses UTF-16 (`[]const u16`),
but fx feeds UTF-8 `[]const [*:0]const u8` through `rawArgs`. The downstream
`cliArgsFromRaw` therefore handed an empty slice to `runBeforeInteractive`,
which made every `fx <cmd>` invocation fall through to interactive mode and
fail with the `NotATerminal` error.

**Fix**: in `cliArgsFromRaw` (`src/main.zig:3085`), when
`builtin.os.tag == .windows` and `hasPosixArgVector()` is false, build the
`cli_args` slice directly from `raw_args[1..]` (UTF-8, null-terminated)
without going through `argsFromRaw().toSlice()`.

Also added a `--version` / `-v` fast path before
`runNonBenchmark` so `fx --version` exits 0 without touching the interactive
bootstrap. This keeps version reporting working on Windows without waiting
for the terminal-abstraction phase.

### 2. `src/core/shared/io.zig` — `realpathAlloc` Windows stub

`realpathAlloc` previously called `std.c.realpath`, which is POSIX-only and
fails to link on Windows. The body is now guarded by
`if (comptime builtin.os.tag == .windows) ... else ...`. The Windows branch
duplicates the input path (no symlink resolution, which is the v1 contract
on Windows per `WINDOWS_SUPPORT_PLAN.md`).

The function signature was tightened to `RealpathError![]u8` with
`pub const RealpathError = error{ FileNotFound, OutOfMemory };` so callers
that switch on the error set on POSIX continue to type-check on Windows.

### 3. `src/core/workspace/workspace_access.zig:583` — drop unreachable else prong

`realpathAlloc`'s new explicit `RealpathError` made the `else =>
return error.InvalidPath` arm unreachable (only `OutOfMemory` and
`FileNotFound` are members). The prong was removed.

### 4. `src/core/terminal/host.zig:200` — guard `std.c.getuid` call

`Paths.open` called `std.c.getuid()`, which doesn't link on Windows. Added
a leading `if (comptime builtin.os.tag == .windows) return
error.TerminalHostUnsupported;` so the runtime path that contains the
POSIX-only call is dead-code-eliminated on Windows. The downstream
`std.c.getuid()` site at `host.zig:233` is in the same function, so a
single guard covers both.

### 5. `src/tools/web/http_fetch.zig` — guard POSIX socket functions

`openSocket`, `connectPinned`, `checkSocketError`, `rawWriteAllWith`, and
`pollSocketError` were calling `posix.system.socket`, `posix.system.connect`,
`std.c.send`, and `std.c.getsockopt`, none of which link on Windows. Each
function now starts with
`if (comptime builtin.os.tag == .windows) return error.PlatformUnsupported;`.

`web_fetch` itself is not functional on Windows yet — these guards just let
the binary link. The Winsock rewrite is tracked under the `fx corre
end-to-end ... degradados` v1 scope in `WINDOWS_SUPPORT_PLAN.md`.

## Try A — Zig 0.17-dev (abandoned)

`C:\zig-master\zig-x86_64-windows-0.17.0-dev.1818+7051f8e73\zig.exe build ...`
was attempted first. Two categories of errors blocked it:

1. **`b.args` no longer exists.** Replaced by `b.user_input_options` (a
   `PackageOptions.Map`). Removed all five `if (b.args) |args| ...` blocks
   in `build.zig`. The Maker now auto-injects passthru args into the run
   step's argv via `Maker/Step/Run.zig:185`, so the run-cmd still receives
   them.

2. **`b.getInstallPath` no longer exists** (0.17 computes install paths
   lazily at make time). Replaced the single call site in `build.zig` with
   a hardcoded `"zig-out" ++ std.fs.path.sep_str ++ "bin" ++ std.fs.path.sep_str ++ "fx"`
   so `FX_TEST_PRODUCT_EXE` is set to the default install location.

3. **Optimize enum casing.** `Optimize.release_safe` → `.safe`,
   `Optimize.release_small` → `.small` in `build.zig`.

After fixing those, ~85 errors remained in the fx source itself:

- ~300+ occurrences of the `**` repetition/power operator. In 0.17 the
  parser treats `**` as adjacent `*` operators and emits
  `error: binary operator '*' has whitespace on one side, but not the other`.
  Every `"x" ** N` and `[_]T{...} ** N` needs to be rewritten to
  `[N]T{...}` literals or `std.mem.repeat`.
- `errdefer |err| { ... }` (error-capture blocks) is rejected by 0.17
  with `expected block or expression, found '|'`.
- Sub-compilation of mingw-w64 `crt2.o` and `winpthreads` failed with
  `.seh_ directive must appear within an active frame` — a 0.17 stdlib
  regression against the bundled mingw-w64.

Together these would require editing ~25 fx source files plus a mingw
stdlib patch, so we reverted to 0.16.

## Try B — Zig 0.16 stdlib patching (not needed)

The strategy listed six stdlib sites to patch if Zig 0.17 failed. Those
patches were not needed because we built successfully on Zig 0.16 without
any stdlib modification. The bundled `C:\zig\zig-x86_64-windows-0.16.0`
install compiled and linked cleanly once the source-level guards above
were in place.

## Remaining work (tracked in `WINDOWS_SUPPORT_PLAN.md`)

- TTY abstraction (`GetConsoleMode` / `WriteConsole`); password prompts
- Signal abstraction (`SetConsoleCtrlHandler`); Ctrl+C
- Process spawning PATH lookups (MCP gate)
- MCP path resolution (`git.exe` / `node.exe`)
- Self-upgrade (ZIP + `MoveFileEx`)
- Native hosts (clipboard, URL, keychain DPAPI)
- `setup.ps1` installer
- Docs (`README.md`, `docs/windows.md`, `CHANGELOG.md`)
- `WINDOWS_SUPPORT_SUMMARY.md`

The current binary proves the toolchain and the
build pipeline work end-to-end on Windows; the above work is needed before
fx can do a real interactive session on Windows.