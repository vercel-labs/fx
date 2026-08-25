# fx on Windows x86_64

> Status: **Preview** — `fx.exe` builds, links, and runs on Windows x86_64 with
> a deliberately small feature surface. The interactive terminal, full
> ConPTY-backed TUI, Windows Credential Vault, and the Windows clipboard host
> are deferred to a future v2. Use `fx` for non-interactive workflows and
> the Linux/macOS build for the full experience until then.

## What works

| Capability | Windows v1 | Notes |
| --- | --- | --- |
| Build | yes | `zig build -Dtarget=x86_64-windows -Doptimize=ReleaseSafe` |
| `fx.exe --version` | yes | prints `0.0.4` and exits 0 |
| `fx.exe --help` | yes | top-level help, same shape as Linux/macOS |
| `fx.exe doctor` | yes | walks the doctor checklist, surfaces missing env |
| `fx ask <prompt>` | yes | non-interactive requests, no TTY required |
| `fx pr` / `fx issue` | yes | uses the local `gh` CLI when present |
| `fx session` / `fx sessions` | yes | saved sessions under `%USERPROFILE%\.fx\sessions` |
| `fx upgrade` | yes | in-process ZIP + atomic copy replace |
| MCP stdio | yes | `std.process.spawn` already supports Windows |
| MCP HTTP / OAuth | **no** | HTTP fetch returns `error.PlatformUnsupported` |
| Background processes | **no** | job objects + ConPTY are v2 |
| Interactive terminal | **no** | `terminalSupportForOs(.windows) = .unsupported` |
| `os_sandbox` | **no** | always `false` (no Job Objects integration yet) |
| `url_open` | **no** | `ShellExecuteW` is v2 |
| `keychain` | **no** | tokens land in plaintext profile files; DPAPI / Credential Vault is v2 |
| `clipboard` | **no** | `OpenClipboard` / `SetClipboardData` is v2 |
| `sound` | **no** | `PlaySound` is v2 |

The v1 contract on Windows is "fx runs end-to-end with degraded features,
same shape as macOS today".

## Install

The one-liner is the recommended path:

```powershell
iwr -useb https://fx.sh/setup.ps1 | iex
```

`setup.ps1` mirrors `setup.sh`:

- Downloads `fx-windows-x86_64.zip` and its `fx.sha256` sidecar
- Verifies the SHA-256 checksum
- Extracts `fx.exe` to `$env:LOCALAPPDATA\fx\bin` by default
- Persists the install directory to your user PATH via `SetEnvironmentVariable`
- Supports `-Version`, `-Channel`, `-InstallDir`, `-NoPathUpdate`,
  `-SkipVerify`, `-Verbose`, `-WhatIf`, and `-Help`

To install to a custom location without touching PATH:

```powershell
iex (iwr -useb https://fx.sh/setup.ps1) -InstallDir C:\tools\fx -NoPathUpdate
```

## Manual install

1. Download `fx-windows-x86_64.zip` and the matching `fx.sha256` from the
   GitHub release.
2. Verify:

   ```powershell
   Get-FileHash .\fx-windows-x86_64.zip -Algorithm SHA256
   # Compare against the value in fx.sha256
   ```

3. Extract `fx.exe` somewhere on your `PATH`
   (e.g. `$env:LOCALAPPDATA\fx\bin`).
4. Open a new PowerShell window so PATH changes take effect, then run
   `fx --version`.

## Build from source

You need Zig 0.16.0 (Windows download from <https://ziglang.org/download/0.16.0/>).
Extract it to a known location, e.g. `C:\zig\zig-x86_64-windows-0.16.0\`.

> **Build readiness note**: The `vercel-labs/fx` Windows port has been
> validated on Zig 0.16.0 with three stdlib backports applied to
> `C:\zig\zig-x86_64-windows-0.16.0\lib\std\`:
>
> 1. `os/windows/ws2_32.zig` — adds the `POLL` event-flag constants and the
>    `pollfd` struct that `std.posix.POLL` and `std.posix.pollfd` reference on
>    Windows. Without these, every cross-platform file referencing
>    `posix.poll` / `posix.POLL.*` fails to type-check.
> 2. `posix.zig` — `setsockopt` and `read` throw `@compileError("use std.Io instead")`
>    on Windows. We backport a no-op (setsockopt) and a typed-error stub
>    (read) so cross-platform POSIX call sites link.
> 3. `c.zig` — `fmt.parseInt` accesses `info.int.signedness` without
>    validating that `Result` is an integer. On Windows, `std.posix.pid_t`
>    resolves to `windows.HANDLE = *anyopaque` and the access fires a
>    confusing "field 'pointer' is active" error. The backport short-circuits
>    `parseInt` to return `error.InvalidCharacter` for non-integer `Result`
>    types, which the existing `catch` arms in call sites already handle.
>
> These patches are tracked in `openspec/changes/windows-support-baseline/`
> under `specs/windows-build-readiness/spec.md`. A future Zig 0.16.x patch
> release is expected to ship the upstream fixes.

```powershell
$env:Path = "C:\zig\zig-x86_64-windows-0.16.0;$env:Path"
git clone https://github.com/vercel-labs/fx.git
cd fx
git checkout -b my-feature origin/main
zig build -Dtarget=x86_64-windows -Doptimize=ReleaseSafe
.\zig-out\bin\fx.exe --version   # 0.0.4
```

## Capability matrix

`host.capabilitiesForTarget(.windows)` returns:

```zig
.{
    .terminal = .unsupported,
    .os_sandbox = false,
    .url_open = .unsupported,
    .background_processes = false,
    .native_url_open = false,
    .keychain = .unsupported,
    .clipboard = .unsupported,
    .sound = .unsupported,
}
```

This is the same degraded shape macOS ships with today. v2 will lift
`terminal` to `.win_native_vt` (ConPTY) and the rest to native
implementations.

## Self-upgrade

`fx upgrade` on Windows:

1. Downloads `fx-windows-x86_64.zip` (the `.zip` extension is the v1
   contract; the Linux/macOS upgrade still uses `.tar.gz`).
2. Verifies the SHA-256 against the sidecar `fx.sha256` next to the
   archive.
3. Extracts `fx.exe` in-process using the in-repo minimal ZIP reader
   (`src/core/upgrade/upgrade_helpers.zig:extractZipEntry`). No
   `tar.exe` / `Expand-Archive` / PowerShell dependency.
4. Replaces the running `fx.exe` in place using the stdlib's
   atomic copy (`std.Io.Dir.copyFile` with `replace = true`). The
   running process keeps the old image in memory; the next launch
   reads the fresh bytes from disk. This is the same trick `setup.ps1`
   uses to install over an existing binary.

No legacy Windows (no `tar.exe` in `System32`) is impacted — the
ZIP path does not shell out to anything.

## Known limitations

- The Zig 0.16 stdlib is missing cross-platform definitions for
  `ws2_32.POLL` and `ws2_32.pollfd`, and several POSIX functions on
  Windows throw `@compileError("use std.Io instead")`. The build
  recipes in this doc require the three backports listed above.
  Once Zig ships a 0.16.x patch that fixes the upstream issues, the
  backports can be dropped.
- The unit test suite (`zig build test`) still depends on POSIX
  sockets and a Winsock rewrite is v2. The production binary is
  tested via the smoke checks listed above.
- The interactive terminal is unsupported; running `fx` without a
  subcommand drops to a `NotATerminal` error. Use `fx ask`,
  `fx pr`, `fx doctor`, or `fx upgrade` instead.

## Reporting issues

File Windows-specific bugs at <https://github.com/vercel-labs/fx/issues/254>.
Include the output of `fx doctor` and the `zig version` you used to build.
