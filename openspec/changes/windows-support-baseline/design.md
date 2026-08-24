# Design: Native Windows x86_64 Support

> Architectural decisions for the Windows port. Resolves where each
> Windows-only concern lives in `src/`, how the comptime branches are
> structured, and how the upstream contract degrades gracefully.

## 1. Where Windows abstractions live

```
src/
├── core/
│   ├── shared/
│   │   ├── io.zig                  ← homeDir, tempDir, getenvCaseInsensitive,
│   │   │                              permissionsFromMode, permissionsToMode,
│   │   │                              realpathAlloc, dirRealpathAlloc,
│   │   │                              syncVerifiedDir, OpenRegularFileError
│   │   └── darwin_process_spawn.zig  ← precedent for *_posix/_windows/_darwin files
│   ├── hosts/
│   │   ├── native_keychain.zig      ← darwin-only today; v2 adds windows_credential.zig
│   │   ├── native_secret_store.zig  ← permissions wrapper, comptime branch
│   │   └── url_opener.zig           ← ShellExecuteW path planned (v2)
│   ├── permissions/
│   │   └── sandbox.zig              ← os_sandbox capability already false on Windows
│   ├── notifications/
│   │   └── sound.zig                ← PlaySound path planned (v2)
│   └── terminal/
│       ├── host.zig                 ← capabilitiesForTarget(.windows) returns
│       │                              terminal=unsupported, os_sandbox=false,
│       │                              url_open=unsupported
│       ├── native_session.zig       ← Linux-only fields gated
│       └── tmux_session.zig         ← Linux-only fields gated
├── ui/
│   ├── shell_runtime.zig            ← Windows console-mode (DWORD) replaces termios
│   ├── ask_presentation.zig         ← enableRawMode goes through abstraction
│   └── transcript/runtime.zig       ← CLI argv decoding (Windows uses UTF-16)
├── main.zig                         ← CLI argv decoding Windows fix (UTF-8 slice
│                                       built from raw_args[1..] when hasPosixArgVector=false)
└── tools/
    ├── shell/background_process.zig ← std.posix.kill guarded with error return
    └── web/http_fetch.zig           ← PollFd platform-conditional, returns error.PlatformUnsupported
```

**No `src/platform/` directory.** Abstractions live next to their
feature. This keeps `import` paths short, lets reviewers read the
Windows branch next to the POSIX one, and follows the existing
precedent set by `core/shared/darwin_process_spawn.zig`.

## 2. Comptime branch pattern

Every Windows-only block uses one of four patterns. Mixing patterns
in the same call site is allowed but discouraged; pick the highest
abstraction that does not leak platform symbols.

### Pattern A — Inline guard (preferred for one-off sites)
```zig
if (comptime builtin.os.tag == .windows) return error.NotATerminal;
std.c.isatty(std.posix.STDIN_FILENO) != 0
```

Use when: the call site has no Windows-side equivalent, or the Windows
side is a simple error.

### Pattern B — Helper with comptime branch (preferred for shared logic)
```zig
const home = try io_mod.homeDir(alloc);
defer alloc.free(home);
```

Use when: more than one call site needs the same Windows-vs-POSIX
decision, or the Windows logic is non-trivial.

### Pattern C — Permission wrapper (preferred for `.permissions`)
```zig
io_mod.permissionsFromMode(0o600)   // Windows → .default_file
io_mod.permissionsToMode(stat.permissions)   // Windows → 0
```

Use when: a `std.Io.File.Permissions` enum is being constructed or
compared. The wrapper centralizes the Windows enum mapping so call
sites stay platform-neutral.

### Pattern D — Error-union propagate
```zig
io_mod.tempDir(alloc) catch return error.AllocFailed;
```

Use when: a helper returns a typed error and the call site already
returns an error union.

## 3. Capability table

`src/core/terminal/host.zig` already returns the right degradation
for Windows. This change does not modify that table — it relies on it.

| Capability | Windows v1 | macOS today | Notes |
| --- | --- | --- | --- |
| `terminal` | `unsupported` | `tmux_fallback` | ConPTY is v2 |
| `os_sandbox` | `false` | `sandbox_exec` | macOS keeps `sandbox-exec` |
| `url_open` | `unsupported` | `native` | `ShellExecuteW` is v2 |
| `background_processes` | `false` | `true` | Job objects are v2 |
| `native_url_open` | `false` | `true` | ShellExecuteW is v2 |
| `keychain` | `unsupported` | `security_cli` | DPAPI is v2 |
| `clipboard` | `unsupported` | `pbcopy_fallback` | Win32 clipboard is v2 |
| `sound` | `unsupported` | `afplay` | `PlaySound` is v2 |

The v1 contract is "fx runs end-to-end with degraded features, same
shape as macOS today".

## 4. TTY abstraction

The TTY abstraction replaces `std.posix.termios` with a Windows
console-mode DWORD. The helper lives next to its consumer
(`src/ui/shell_runtime.zig`); a separate
`core/shared/windows_console.zig` would be extracted only when a
second consumer appears.

```zig
// comptime-switched; elides on non-Windows
pub fn enableWindowsRawMode() !struct { original: u32 } {
    const handle = std.os.windows.GetStdHandle(...);
    var mode: u32 = 0;
    if (std.os.windows.kernel32.GetConsoleMode(handle, &mode) == 0)
        return error.NotATerminal;
    const original = mode;
    const raw = mode & ~(
        ENABLE_ECHO_INPUT | ENABLE_LINE_INPUT | ENABLE_PROCESSED_INPUT
    );
    if (std.os.windows.kernel32.SetConsoleMode(handle, raw) == 0)
        return error.IoError;
    return .{ .original = original };
}
```

`MaskedKeyRawMode` in `src/core/cli/cli_surface.zig` and
`enableRawMode` / `disableRawMode` in `src/main.zig` and
`src/ui/shell_runtime.zig` all flow through this helper.

`installResizeSignal` posts to the resize interlock via
`SetConsoleCtrlHandler` → `WINDOW_BUFFER_SIZE_EVENT`.

## 5. Signal abstraction

`SetConsoleCtrlHandler` replaces `sigaction(SIG.TERM/HUP/INT)`. The
abnormal-exit handler writes `abnormal_exit_restore` then calls
`std.process.exit(1)` from inside the handler thread (which is the
documented contract for Ctrl+C-style signals on Windows).

```zig
pub fn installWindowsAbnormalExitCtrlHandler(
    abnormal_exit_restore: *std.atomic.Value(bool),
) !void {
    const Handler = struct {
        fn routine(ctrl_type: std.os.windows.DWORD) callconv(.c) std.os.windows.BOOL {
            switch (ctrl_type) {
                std.os.windows.CTRL_C_EVENT,
                std.os.windows.CTRL_BREAK_EVENT,
                std.os.windows.CTRL_CLOSE_EVENT,
                std.os.windows.CTRL_LOGOFF_EVENT,
                std.os.windows.CTRL_SHUTDOWN_EVENT => {
                    abnormal_exit_restore.store(true, .seq_cst);
                    std.process.exit(1);
                },
                else => return std.os.windows.FALSE,
            }
            return std.os.windows.TRUE;
        }
    };
    if (std.os.windows.kernel32.SetConsoleCtrlHandler(&Handler.routine, std.os.windows.TRUE) == 0)
        return error.IoError;
}
```

`installAbnormalExitHandlers` in `src/core/app/app_lifecycle.zig`
calls this when `supports_resize_signal` is true (Windows now).

## 6. Path resolution helpers

All three live in `src/core/shared/io.zig` with comptime branches.

```zig
pub fn homeDir(alloc: std.mem.Allocator) ![]u8 {
    if (builtin.os.tag == .windows) {
        if (io_mod.getenvCaseInsensitive("USERPROFILE")) |u| return alloc.dupe(u8, u) catch return error.OutOfMemory;
        if (io_mod.getenvCaseInsensitive("HOME"))        |h| return alloc.dupe(u8, h) catch return error.OutOfMemory;
        const drive = io_mod.getenvCaseInsensitive("HOMEDRIVE") orelse "";
        const path  = io_mod.getenvCaseInsensitive("HOMEPATH")  orelse "";
        if (drive.len == 0 or path.len == 0) return error.UserProfileMissing;
        return std.fmt.allocPrint(alloc, "{s}{s}", .{ drive, path });
    }
    // POSIX
    const home = std.posix.getenv("HOME") orelse return error.HomeMissing;
    return alloc.dupe(u8, home) catch return error.OutOfMemory;
}

pub fn tempDir(alloc: std.mem.Allocator) ![]u8 {
    if (builtin.os.tag == .windows) {
        const t = io_mod.getenvCaseInsensitive("TEMP")
            orelse io_mod.getenvCaseInsensitive("TMP")
            orelse return error.TempMissing;
        return alloc.dupe(u8, t) catch return error.OutOfMemory;
    }
    const t = std.posix.getenv("TMPDIR") orelse "/tmp";
    return alloc.dupe(u8, t) catch return error.OutOfMemory;
}

pub fn getenvCaseInsensitive(key: []const u8) ?[]const u8 {
    if (builtin.os.tag == .windows) {
        const wide = std.unicode.utf8ToUtf16Le(...);
        const w = std.os.windows.kernel32.GetEnvironmentVariableW(wide.ptr, ...);
        ...
    }
    return std.posix.getenv(key);
}
```

All call sites that previously read `HOME`, `TMPDIR`, or `/tmp` at
runtime now route through these helpers. There is no `case_sensitive`
flag because every Windows env-var lookup is case-insensitive.

## 7. Permissions wrapper

`std.Io.File.Permissions.fromMode` and `.toMode` do not exist on
Windows (the Windows enum is a different shape). The wrappers return
`.default_file` / `0` on Windows, which matches the existing macOS
degradation pattern.

```zig
pub fn permissionsFromMode(mode: u32) std.Io.File.Permissions {
    if (builtin.os.tag == .windows) return .default_file;
    return std.Io.File.Permissions.fromMode(mode);
}

pub fn permissionsToMode(permissions: std.Io.File.Permissions) u32 {
    if (builtin.os.tag == .windows) return 0;
    return permissions.toMode();
}
```

Approximately 20 call sites across `src/core/config/`,
`src/core/hosts/`, `src/core/mcp/`, `src/core/permissions/`,
`src/core/session/`, `src/core/tooling/`, `src/core/images/`,
`src/tools/filesystem/` already use these wrappers.

## 8. CLI argv decoding on Windows

The pre-port `argsFromRaw` returned an empty `std.process.Args` vector
on Windows because the C-runtime `argv` is UTF-16 (`[]const u16`),
not UTF-8. fx feeds UTF-8 `[]const [*:0]const u8` through `rawArgs`,
which silently truncated to an empty slice on Windows and made every
`fx <cmd>` invocation fall through to interactive mode.

Fix in `src/main.zig:3085` (`cliArgsFromRaw`): when
`builtin.os.tag == .windows` and `hasPosixArgVector()` is false, build
the `cli_args` slice directly from `raw_args[1..]` (UTF-8,
null-terminated) without going through `argsFromRaw().toSlice()`.

Also added a `--version` / `-v` fast path before the dispatch so the
version string is reachable from a non-POSIX shell.

## 9. Process spawning and process group termination

Windows has no process groups, so `std.posix.kill(-pid, .SIG.TERM)`
becomes a guard that returns `error.ProcessGroupUnsupported` on
Windows.

```zig
if (builtin.os.tag == .windows) {
    // Process group termination is not available on Windows. Kill the
    // direct child only; sibling processes started by the same
    // CreateProcess call are unaffected.
    return error.ProcessGroupUnsupported;
}
std.posix.kill(-pid, .SIG.TERM) catch ...;
```

For `mcp_runtime.zig` test helpers, the `kill(pid, 0)` probe is
replaced with `WaitForSingleObject(handle, 0)` on Windows.

## 10. MCP process resolution

`commandInPath` (used by MCP to resolve `git.exe` / `node.exe`) now
probes both `git` and `git.exe` on Windows. The capability table
still marks `background_processes = false` for Windows, so MCP HTTP
transport is the only viable path on Windows today; stdio MCP works
because `std.process.spawn` already supports Windows.

## 11. Self-upgrade

`extractTarGz` currently shells out to `tar -xzf`. Windows 10/11
ships `tar.exe` in `System32`; legacy Windows does not. The v1
upgrade path on Windows is "redownload the latest zip and replace
the binary" via `MoveFileEx` (the running `.exe` cannot be renamed on
Windows; a rename-on-reboot or a side-by-side swap is required).

This is task **T-F9** and is open.

## 12. Native hosts (deferred)

| Host | Windows v2 | Today (POSIX) | Notes |
| --- | --- | --- | --- |
| Clipboard | `OpenClipboard` / `SetClipboardData` | `pbcopy` / `osascript` | macOS has a fallback; Windows v1 returns `error.Unsupported` |
| URL opener | `ShellExecuteW(NULL, "open", url, NULL, NULL, SW_SHOWNORMAL)` | `open` / `xdg-open` | Already gated `unsupported` on Windows |
| Keychain | DPAPI + Credential Vault | `/usr/bin/security` | v2 only; v1 stores tokens in plaintext profile |

These are tracked as tasks **T-F10a/b/c** and remain open.

## 13. CI

No Windows runner today. Phase 4 (task **T-F4**) adds
`.github/workflows/windows.yml` modeled on the existing Linux/macOS
matrix. It runs on `windows-latest` with Zig 0.16.0 and gates the
build on the stdlib bugs being fixed (see
`specs/windows-build-readiness/spec.md`).

## 14. Installer

`setup.ps1` (459 lines, untracked in the working tree) is the
PowerShell mirror of `setup.sh`. Differences:

- Downloads `fx-windows-x86_64.zip` instead of the
  `fx-{version}-{os}-{arch}.tar.gz`.
- Verifies the SHA-256 checksum against a sidecar `fx.sha256`.
- Persists the install directory to the user PATH via
  `SetEnvironmentVariable` (no `~/.bashrc` / `~/.zshrc`).
- Supports `-Version`, `-InstallDir`, `-NoPathUpdate`,
  `-SkipVerify`, `-Verbose`, `-WhatIf`, and `-Help`.

Mirrors the Unix installer conventions and is part of this PR.

## 15. What does NOT change for Linux/macOS

Because every Windows branch is `comptime`-gated, the Linux/macOS
build is byte-identical to `vercel-labs/fx` upstream. The CI matrix
on `main` continues to gate the PR without modification. The `setup.sh`
installer is untouched. AGENTS.md, CONTRIBUTING.md, README.md, and
CHANGELOG.md are untouched (only `docs/windows.md` is added by
task **T-F12**).