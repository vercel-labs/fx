# Spec: Windows platform support — runtime and capability

> Delta spec for the Windows-side runtime support that has already
> landed in the working tree of `feat/windows-support`.

## Purpose

Make `fx.exe` build, link, and run the non-interactive paths on
Windows x86_64 with the same degraded-feature contract that macOS
already has today. v1 does not include interactive terminal support.

## Requirements

### REQ-platform-capability-table
`host.capabilitiesForTarget(.windows)` MUST return the existing
degraded table:

- `terminal = .unsupported`
- `os_sandbox = false`
- `url_open = .unsupported`
- `background_processes = false`
- `native_url_open = false`
- `keychain = .unsupported`
- `clipboard = .unsupported`
- `sound = .unsupported`

This change does not modify the table; it relies on it.

### REQ-platform-tty-abstraction
The TTY abstraction MUST replace `std.posix.termios` with Windows
console-mode DWORD on Windows:

- `enableWindowsRawMode() !struct { original: u32 }` clears
  `ENABLE_ECHO_INPUT | ENABLE_LINE_INPUT | ENABLE_PROCESSED_INPUT`
  and returns the previous mode.
- `disableWindowsRawMode(original: u32)` restores the previous
  mode.
- On non-Windows, the helpers are not callable (comptime-elided).

The masked-key prompt in `cli_surface.zig` and the raw-mode prompt
in `main.zig` and `ui/shell_runtime.zig` MUST route through these
helpers on Windows.

### REQ-platform-resize-signal
`installResizeSignal` MUST post to the resize interlock when
`WINDOW_BUFFER_SIZE_EVENT` fires from `SetConsoleCtrlHandler`:

- Windows-only.
- On non-Windows, the existing `SIG.WINCH` flow is unchanged.

### REQ-platform-signal-abstraction
The abnormal-exit handler MUST install a `SetConsoleCtrlHandler`
on Windows that:

- Triggers on `CTRL_C_EVENT`, `CTRL_BREAK_EVENT`,
  `CTRL_CLOSE_EVENT`, `CTRL_LOGOFF_EVENT`,
  `CTRL_SHUTDOWN_EVENT`.
- Writes `abnormal_exit_restore = true` before
  `std.process.exit(1)`.
- On non-Windows, the existing `sigaction(SIG.TERM/HUP/INT)` flow
  is unchanged.

### REQ-platform-cli-argv
`cliArgsFromRaw` MUST build the `cli_args` slice from
`raw_args[1..]` when `builtin.os.tag == .windows` and
`hasPosixArgVector()` is false:

- The Windows C-runtime passes UTF-16 `argv`; the standard library
  `argsFromRaw` returns empty on Windows.
- Bypassing `argsFromRaw` and using the UTF-8 `raw_args` directly
  restores `fx <cmd>` invocations on Windows.
- A `--version` / `-v` fast path is added before the dispatch so
  `fx --version` is reachable from any shell.

### REQ-platform-process-group
Calls to `std.posix.kill(-pid, .SIG.…)` MUST return
`error.ProcessGroupUnsupported` on Windows. The direct child
process is killed separately via `child.kill(io_mod.getIo())`
before the negative-pid call.

### REQ-platform-mcp-probe
`commandInPath` MUST probe both `git` and `git.exe` (and the
node variants) on Windows so MCP and workspace resolution can
locate Git for Windows installations.

### REQ-platform-mcp-probe-process-alive
`expectTestProcessExited` and similar `kill(pid, 0)` probes MUST
use `WaitForSingleObject(handle, 0)` on Windows. The helper
returns `true` when the wait times out (still alive) and `false`
when the handle is signaled (exited).

### REQ-platform-http-degrade
`PollFd`, `connectPinned`, and related HTTP helpers MUST return
`error.PlatformUnsupported` on Windows. v1 disables HTTP fetch on
Windows; MCP HTTP transport, OAuth, and upgrade HTTP are all
affected.

### REQ-platform-doctor-realpath
`realpathAlloc` MUST use `RtlGetFullPathName_U` on Windows so
`fx.exe doctor` no longer panics on the unreachable code path.

## Scenarios

### SCN-platform-build-windows
Given Zig 0.16.0 and the stdlib bugs fixed (see
`specs/windows-build-readiness/spec.md`), when
`zig build -Dtarget=x86_64-windows -Doptimize=ReleaseSafe` is run,
then `zig-out/bin/fx.exe` is produced (~11 MB, PE32+ x86_64).

### SCN-platform-version
Given `fx.exe` is built, when `fx.exe --version` is invoked,
then the output is `0.0.4` and the exit code is `0`.

### SCN-platform-help
Given `fx.exe` is built, when `fx.exe --help` is invoked,
then the top-level help is printed.

### SCN-platform-cli-argv
Given `fx.exe` is built, when `fx.exe ask "hi"` is invoked,
then the command is routed to `ask` (not the interactive
default).

### SCN-platform-masked-key
Given `fx.exe` is built, when the user is prompted for an API
key on Windows, then `MaskedKeyRawMode` toggles the console mode
without losing the original mode after the prompt completes.

### SCN-platform-resize
Given `fx.exe` is running interactively, when the user resizes
the Windows Terminal window, then the TUI re-renders at the new
size.

## Out of scope

- ConPTY-backed interactive terminal session (v2).
- DPAPI-backed keychain (v2).
- Windows clipboard / URL opener (v2).
- Interactive MCP OAuth on Windows (v2).
- macOS-only sandbox paths (already disabled on Windows).

## Known regressions

- HTTP fetch returns `error.PlatformUnsupported` on Windows until
  the stdlib `ws2_32` issues are resolved. This blocks OAuth
  login, MCP HTTP transport, and upgrade HTTP fetches.
- `fx.exe doctor` was panicking before this change; the
  `realpathAlloc` fix removes that panic.