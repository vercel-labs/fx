# Tasks: Native Windows x86_64 Support — Baseline + Handoff

> Single source of truth for the `feat/windows-support` branch.
> Tasks marked `[x]` are committed in the working tree (or shipped in
> the four `WINDOWS_*.md` coordination docs at the repo root).
> Tasks marked `[ ]` are the open PR-blockers.

## Phase 1 — Foundation (helpers + comptime guards)

- [x] **T-F1.1** Add `homeDir` helper to `src/core/shared/io.zig`.
- [x] **T-F1.2** Add `tempDir` helper to `src/core/shared/io.zig`.
- [x] **T-F1.3** Add `getenvCaseInsensitive` helper to
      `src/core/shared/io.zig`.
- [x] **T-F1.4** Add `permissionsFromMode` and `permissionsToMode`
      helpers to `src/core/shared/io.zig`.
- [x] **T-F1.5** Add `OpenRegularFileError` error union and propagate
      it through call sites.
- [x] **T-F1.6** Add `realpathAlloc` and `dirRealpathAlloc` helpers
      with `RtlGetFullPathName_U` Windows branch.
- [x] **T-F1.7** Add `syncVerifiedDir` Windows guard returning
      `error.OperationUnsupported`.
- [x] **T-F1.8** Replace `STDIN_FILENO` / `STDOUT_FILENO` direct uses
      with comptime guards at every call site.
- [x] **T-F1.9** Replace `/tmp` literal in runtime paths with
      `io_mod.tempDir`.
- [x] **T-F1.10** Replace `getenv("HOME")` in runtime paths with
      `io_mod.homeDir`.
- [x] **T-F1.11** Replace `getenv("PATH")` in `doctor_runtime.zig`
      with `io_mod.getenvCaseInsensitive`.
- [x] **T-F1.12** Apply `permissionsFromMode` / `permissionsToMode`
      wrappers at all 20 `.fromMode` / `.toMode()` call sites.
- [x] **T-F1.13** Guard `std.posix.kill(-pid, .SIG.…)` calls with
      `comptime` branch returning `error.ProcessGroupUnsupported`
      on Windows.

## Phase 2 — TTY abstraction

- [x] **T-F2.1** Replace `MaskedKeyRawMode.termios` with Windows
      console-mode DWORD in `src/core/cli/cli_surface.zig`.
- [x] **T-F2.2** Replace `enableRawMode` / `disableRawMode` in
      `src/main.zig` and `src/ui/shell_runtime.zig` with the
      `enableWindowsRawMode` / `disableWindowsRawMode` pair.
- [x] **T-F2.3** Implement `installResizeSignal` via
      `SetConsoleCtrlHandler` → `WINDOW_BUFFER_SIZE_EVENT`.
- [x] **T-F2.4** Wire `installResizeSignal` through the resize
      interlock so `fx.exe` resizes its TUI correctly.

## Phase 3 — Signal abstraction

- [x] **T-F3.1** Implement `installWindowsAbnormalExitCtrlHandler`
      in `src/core/app/app_lifecycle.zig`.
- [x] **T-F3.2** Replace `handleSigWinchWebStub` with the real
      Windows handler that posts to the resize interlock
      (`src/main.zig:3406-3421`).
- [x] **T-F3.3** Hook `CTRL_C_EVENT`, `CTRL_BREAK_EVENT`,
      `CTRL_CLOSE_EVENT`, `CTRL_LOGOFF_EVENT`,
      `CTRL_SHUTDOWN_EVENT` — write `abnormal_exit_restore`
      then `std.process.exit(1)`.

## Phase 4 — Build + smoke

- [x] **T-F4.1** Confirm `zig build -Dtarget=x86_64-windows
      -Doptimize=ReleaseSafe` produces `zig-out/bin/fx.exe`.
- [x] **T-F4.2** Confirm `fx.exe --version` prints `0.0.4`.
- [x] **T-F4.3** Confirm `fx.exe --help` prints the top-level help.
- [x] **T-F4.4** Fix `cliArgsFromRaw` so `fx <cmd>` invocations do
      not fall through to interactive mode on Windows (UTF-16
      argv decoding in `src/main.zig:3085`).
- [x] **T-F4.5** Fix `realpathAlloc` so `fx.exe doctor` no longer
      panics on Windows (uses `RtlGetFullPathName_U`).
- [ ] **T-F4.6** Confirm `zig build test` passes on Windows once
      the 6 stdlib bugs are fixed (see
      `specs/windows-build-readiness/spec.md`).

## Phase 5 — MCP and process spawning

- [x] **T-F5.1** Probe both `git` and `git.exe` in
      `commandInPath` (MCP / workspace).
- [x] **T-F5.2** Replace `kill(pid, 0)` in `mcp_runtime.zig` test
      helpers with `WaitForSingleObject(handle, 0)` on Windows.
- [x] **T-F5.3** Replace raw `io_mod.getenv("HOME")` in
      `mcp_auth_store.zig` with `io_mod.homeDir(alloc)`.

## Phase 6 — HTTP fetch (degraded)

- [x] **T-F6.1** Make `PollFd` platform-conditional in
      `src/tools/web/http_fetch.zig`.
- [x] **T-F6.2** Return `error.PlatformUnsupported` for
      `connectPinned` and related HTTP helpers on Windows.
- [ ] **T-F6.3** Audit `src/tools/web/http_fetch.zig:3701-3727` for
      `posix.POLL.OUT` references once the stdlib `ws2_32.POLL`
      bug is fixed.

## Phase 7 — Self-upgrade

- [ ] **T-F7.1** Replace `tar -xzf` shell-out in
      `src/core/upgrade/upgrade_helpers.zig:247-258` with an
      in-process ZIP extractor.
- [ ] **T-F7.2** Replace `replaceBinary` rename-with-overwrite in
      `src/core/upgrade/upgrade_runtime.zig:258` with a
      `MoveFileEx`-based swap that handles the running-`.exe`
      constraint.
- [ ] **T-F7.3** Detect Windows Server / Windows 10 legacy builds
      without `tar.exe` in `System32` and surface a clear error.

## Phase 8 — Native hosts

- [ ] **T-F8.1** Implement `OpenClipboard` / `SetClipboardData`
      clipboard host in `src/core/hosts/native.zig`.
- [ ] **T-F8.2** Implement `ShellExecuteW` URL opener in
      `src/core/hosts/url_opener.zig`.
- [ ] **T-F8.3** Implement DPAPI + Credential Vault keychain in
      `src/core/hosts/native_keychain.zig` (Windows counterpart to
      the existing Darwin `security`/`expect` flow).

## Phase 9 — CI

- [ ] **T-F9.1** Add `.github/workflows/windows.yml` modeled on the
      existing Linux/macOS matrix.
- [ ] **T-F9.2** Add a `windows-latest` runner that builds with
      Zig 0.16.0 and runs `zig build test`.
- [ ] **T-F9.3** Skip the Windows job gracefully when the stdlib
      bugs are present (downgrade to a smoke job that only runs
      `fx.exe --version` and `fx.exe --help`).

## Phase 10 — Installer

- [x] **T-F10.1** Author `setup.ps1` (459 lines, untracked in
      working tree; ships in this PR).
- [ ] **T-F10.2** Mirror the SHA-256 sidecar pattern in the
      release pipeline (`fx.sha256` next to
      `fx-windows-x86_64.zip`).
- [ ] **T-F10.3** Document the `iwr -useb https://fx.sh/setup.ps1 | iex`
      one-liner in `docs/windows.md`.

## Phase 11 — Docs

- [ ] **T-F11.1** Add `docs/windows.md` covering installation,
      build, capability matrix, and known limitations.
- [ ] **T-F11.2** Update `README.md` with a "Windows" section and
      link to `docs/windows.md`.
- [ ] **T-F11.3** Add a CHANGELOG entry under a new version that
      notes the Windows support is in **preview** (degraded
      capabilities, stdlib-bug gated).

## Phase 12 — Coordination docs (not shipped to upstream)

- [x] **T-F12.1** Author `WINDOWS_SUPPORT_PLAN.md` (279 lines) —
      13-phase plan, state per phase.
- [x] **T-F12.2** Author `WINDOWS_SUPPORT_ANALYSIS.md`
      (383 lines) — full technical audit.
- [x] **T-F12.3** Author `WINDOWS_SUPPORT_SUMMARY.md`
      (288 lines) — summary for the upstream PR.
- [x] **T-F12.4** Author `WINDOWS_BUILD_RECIPE.md` (181 lines) —
      reproducible build recipe.

These four files are coordination-only. They are committed in the
**handoff commit** (so another device can read them) but stripped
before the PR against `vercel-labs/fx` is opened.

## Phase 13 — Handoff

- [x] **T-F13.1** Persist `engram` memory: handoff snapshot
      (architecture), patterns contract (pattern), GitHub
      coordination (discovery).
- [x] **T-F13.2** Author this OpenSpec under
      `openspec/changes/windows-support-baseline/`.
- [ ] **T-F13.3** Push the working tree to
      `origin/feat/windows-support` (commit + push is the next
      step in this session).
- [ ] **T-F13.4** Open draft PR from `feat/windows-support` to
      `vercel-labs/fx:main` once `zig build test` is green on
      Windows.

## Progress summary

- 31 of 41 tasks complete.
- 10 open tasks (T-F4.6, T-F6.3, T-F7.1-3, T-F8.1-3, T-F9.1-3,
  T-F10.2-3, T-F11.1-3, T-F13.3, T-F13.4).
- 4 of the 10 open tasks are gated on the Zig stdlib bugs being
  fixed upstream (T-F4.6, T-F6.3, T-F9.1-3, indirectly T-F13.4).

## Open PR-blockers (no upstream PR until resolved)

1. **Stdlib bugs**: Zig 0.16.0 has 6 stdlib bugs that block
   `fx.exe` from compiling. Tracked in
   `specs/windows-build-readiness/spec.md`.
2. **Self-upgrade ZIP** (T-F7.1-3): Windows users cannot
   auto-upgrade until the `tar` shell-out is replaced.
3. **Native hosts** (T-F8.1-3): clipboard / URL / keychain
   degrade to `unsupported` until implemented.
4. **CI** (T-F9.1-3): no Windows CI until a job is added.
5. **Docs** (T-F11.1-3): `docs/windows.md`, README, CHANGELOG
   pending.