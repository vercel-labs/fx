# Proposal: Native Windows x86_64 Support — Baseline + Handoff

> **Status**: Active change. Used as a single source of truth for the
> `feat/windows-support` branch at `C:\programas\fx` (fork
> `DarakoG/fx`, upstream `vercel-labs/fx`).
>
> This change captures BOTH the work that has already landed in the
> working tree (foundation helpers, comptime guards, TTY/signal
> abstractions) AND the work that remains before the upstream PR can
> be opened (CI job, self-upgrade ZIP, native hosts, installer,
> docs). Tasks already complete are checked off. Tasks still open
> are actionable.

## Why

`fx` is a Unix-first Zig 0.16 codebase. The Linux and macOS
experience is the production target. The CI matrix covers four native
runners, none of them Windows. The build assumes POSIX paths, POSIX
signals, `tcgetattr`/`tcsetattr`, and `/tmp`/`/bin/sh` literals in
runtime.

A growing number of users (see issue
[#254](https://github.com/vercel-labs/fx/issues/254)) want to run
`fx` natively on Windows without WSL, Cygwin, MSYS2, or Git Bash.
Issue [#254] is open and is the coordination point for this work.

This change introduces native Windows x86_64 support as a **first-class
but degraded platform**, exactly the same contract macOS already has
today: `terminalSupportForOs(.windows) = .unsupported`,
`os_sandbox = false`, `url_open = unsupported`. v1 ships the foundation
that lets `fx.exe` compile, link, and run the non-interactive paths;
the interactive terminal and full ConPTY integration is deferred to v2.

## What changes

### Added
- Cross-platform helpers in `src/core/shared/io.zig`:
  `homeDir`, `tempDir`, `getenvCaseInsensitive`,
  `permissionsFromMode`, `permissionsToMode`, `OpenRegularFileError`,
  plus the `realpathAlloc` / `dirRealpathAlloc` rewrites that use
  `RtlGetFullPathName_U` on Windows.
- TTY abstraction for Windows (`GetConsoleMode` / `SetConsoleMode`)
  covering masked key raw mode in `src/core/cli/cli_surface.zig` and
  raw mode + resize handling in `src/ui/shell_runtime.zig`.
- Signal abstraction for Windows (`SetConsoleCtrlHandler`) covering
  abnormal exit handlers in `src/core/app/app_lifecycle.zig`,
  `src/ui/shell_runtime.zig`, and `src/main.zig` (resize web stub).
- Comptime guards around POSIX-only constructs: `termios`,
  `sigaction`, `forkpty`, `isatty`, `kill(-pid, .SIG.…)`,
  `STDIN_FILENO`/`STDOUT_FILENO`, `realpath` (POSIX),
  `/tmp` literal in runtime paths, `getenv("HOME")` in runtime paths.
- ~20 permission wrapper call sites (`.fromMode` / `.toMode()` →
  `io_mod.permissionsFromMode` / `io_mod.permissionsToMode`).
- PowerShell installer `setup.ps1` (459 lines, mirrors `setup.sh`,
  adds SHA-256 verification).

### Modified (working tree)
66 files: 824 insertions, 270 deletions. Linux/macOS code paths are
byte-identical because every Windows branch is `comptime`-gated and
elides on non-Windows targets.

### Deferred (out of scope for v1)
- Full ConPTY-backed interactive terminal session
  (`terminalSupportForOs(.windows)` stays `.unsupported`).
- Windows Credential Vault (`CredWriteW` / `CredReadW`).
- Windows clipboard (`OpenClipboard` / `SetClipboardData`).
- Interactive MCP OAuth on Windows.
- macOS-only sandbox paths (already `false` for Windows).

## Constraints respected

1. **No tests, docs, scripts, or configs removed.** All existing
   assets are preserved.
2. **No POSIX runtime path altered.** Comptime branches eliminate the
   Windows code on Linux/macOS. The upstream binary is byte-identical
   for non-Windows targets.
3. **No `src/platform/` directory.** Abstractions live alongside
   their feature in `core/shared/`, `core/hosts/`,
   `core/permissions/`, etc. Convention: `<feature>_<os>.zig`
   (precedent: `core/shared/darwin_process_spawn.zig`).
4. **No machine-specific hacks.** No hardcoded `C:\Users\…` paths.
5. **No external dependency on WSL, Cygwin, MSYS2, or Git Bash.**

## Impact

- **Build**: `zig build -Dtarget=x86_64-windows -Doptimize=ReleaseSafe`
  produces `zig-out/bin/fx.exe` (~11 MB, PE32+ x86_64) once the
  Zig 0.16.0 stdlib bugs listed in the design are fixed upstream.
- **Smoke**: `fx.exe --version` → `0.0.4`; `fx.exe --help` →
  top-level help.
- **Degraded capabilities** (same contract as macOS):
  - Interactive terminal: `unsupported` (v2 = ConPTY)
  - `os_sandbox`: `false`
  - `url_open`: `unsupported`
  - Keychain: stored in plaintext profile file (v2 = DPAPI)
  - HTTP fetch: returns `error.PlatformUnsupported` (MCP HTTP, OAuth,
    upgrade HTTP all affected; v2 = `std.http.Client` on Win32)

## Coordination

- **Fork**: `https://github.com/DarakoG/fx`
- **Upstream**: `https://github.com/vercel-labs/fx`
- **Branch**: `feat/windows-support` (HEAD `2058349` on top of
  `origin/main`).
- **Issue**: https://github.com/vercel-labs/fx/issues/254
  (DarakoG has published a coordination comment).
- **PR title** (when opened): `build: add initial native Windows
  x86_64 support`.

## Known blockers

The build is gated on six stdlib bugs in Zig 0.16.0 that are pulled
in when compiling for Windows. They are not bugs in `fx` source and
cannot be fixed in user code. Details in
`specs/windows-build-readiness/spec.md`.

## Specs in this change

- `specs/shared-io-helpers/spec.md` — delta spec for the new
  cross-platform helpers.
- `specs/windows-platform-support/spec.md` — delta spec for the
  Windows-side runtime support that has already landed.
- `specs/windows-build-readiness/spec.md` — requirements on the
  Zig toolchain and the open PR-blocker items.

## Out of scope

- Anything outside the `feat/windows-support` branch.
- New product features unrelated to Windows support.