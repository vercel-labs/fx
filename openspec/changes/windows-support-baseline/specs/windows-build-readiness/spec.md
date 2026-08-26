# Spec: Windows build readiness

> Delta spec for the requirements on the Zig toolchain and the
> upstream PR-blocker items. The `fx.exe` build is gated on
> either a Zig upstream fix or a small set of local stdlib
> backports that document the gap.

## Purpose

Capture every requirement that gates the
`fx.exe` Windows build, the `zig build test` green run on
Windows, and the upstream PR opening. Each requirement is
explicit about whether the fix lives in the Zig standard library,
in a new Windows-specific fx helper, or in a new CI workflow.

## Requirements

### REQ-readiness-zig-version
fx MUST build on a Zig version where the six stdlib bugs below
are either fixed upstream or worked around by the documented
backports. On Zig 0.16.0, the build is gated on the backports
documented in `REQ-readiness-stdlib-backports` below. A future
Zig 0.16.x patch release that ships the upstream fixes allows
the backports to be dropped.

The Zig 0.17-dev nightly upgrade was attempted first (see
`WINDOWS_BUILD_RECIPE.md`) and abandoned: 0.17 removed the
`**` repetition operator and `errdefer |err|` capture blocks
(300+ fx call sites would have to be rewritten), and its
bundled mingw-w64 regressed with `.seh_ directive must appear
within an active frame`. The next attempt after that is a
local Zig 0.16 install with the backports below.

### REQ-readiness-stdlib-backports
The following six Zig 0.16.0 stdlib issues block the build on
Windows. They are backported locally so the `fx.exe` build is
green on a stock Zig 0.16.0 install. Each backport is a 5–15
line diff against `C:\zig\zig-x86_64-windows-0.16.0\lib\std\`
and is documented inline as a comment in the patched file.

1. `lib\std\c.zig:1716` and `lib\std\c.zig:4299` — `ws2_32` has
   no member named `POLL` / `pollfd`. **Backport** in
   `lib\std/os/windows/ws2_32.zig`: add the `POLL` constants
   (`IN`, `OUT`, `ERR`, `HUP`, `NVAL` mapped to their Win32
   `WSAPOLLFD` values) and the `pollfd` struct
   (`{ fd: HANDLE, events: SHORT, revents: SHORT }`).
2. `lib\std/c.zig:4299` — transitively references
   `ws2_32.pollfd`. Resolved by patch (1).
3. `lib\std\fmt.zig:436` — `parseInt` accesses
   `info.int.signedness` without validating that `Result` is
   an integer. On Windows, `std.posix.pid_t` resolves to
   `windows.HANDLE = *anyopaque` and the access fires a
   confusing "field 'pointer' is active" error. **Backport** in
   `lib\std/fmt.zig`: short-circuit `parseInt` to return
   `error.InvalidCharacter` for non-integer `Result` types so
   the existing `catch` arms in call sites handle it.
4. `lib\std\fmt.zig:436` — duplicate of (3), fired from a
   different `parseIntWithGenericCharacter` arm. Resolved by
   the same patch.
5. `lib\std\posix.zig:1075` — `setsockopt` on Windows throws
   `@compileError("use std.Io instead")`. **Backport** in
   `lib\std/posix.zig`: replace the compile error with a
   no-op `return;` so cross-platform `setsockopt` call sites
   (e.g. `herdr` socket timeouts) link. The Winsock rewrite is
   v2.
6. `lib\std\posix.zig:1075` (additional) — `read` and `poll` on
   Windows also throw `@compileError`. **Backport**: `read`
   returns `error.InputOutput`; `poll` returns `0` (no
   `WSAPoll` is performed; the Winsock rewrite is v2).

Items 1, 2, and 6 are gated by the fx decision to disable HTTP
fetch on Windows (`REQ-platform-http-degrade` in
`specs/windows-platform-support/spec.md`). When HTTP fetch is
re-enabled, those items must be resolved upstream first.

### REQ-readiness-zig-test-windows
`zig build test` MUST pass on Windows once the stdlib bugs are
resolved. Today this cannot be measured.

### REQ-readiness-ci-windows-job
A new GitHub Actions workflow at
`.github/workflows/windows.yml` MUST:

- Run on `windows-latest`.
- Use Zig 0.16.0 (or the nightly that fixes the stdlib bugs).
- Build with
  `zig build -Dtarget=x86_64-windows -Doptimize=ReleaseSafe`.
- Smoke-test `fx.exe --version` and `fx.exe --help`.
- Run `zig build test` when the stdlib bugs are fixed; otherwise
  downgrade to a smoke-only job.

### REQ-readiness-self-upgrade-zip
`extractTarGz` in `src/core/upgrade/upgrade_helpers.zig` MUST
be replaced with an in-process ZIP extractor (Windows has
`tar.exe` in `System32` on Win10/11 but not on legacy Windows;
fx must not depend on the system `tar`).

### REQ-readiness-replace-binary
`replaceBinary` in `src/core/upgrade/upgrade_runtime.zig` MUST
use `MoveFileEx` (or `MOVEFILE_DELAY_UNTIL_REBOOT`) to handle
the Windows constraint that a running `.exe` cannot be renamed.

### REQ-readiness-clipboard
The Windows clipboard host MUST use `OpenClipboard` /
`SetClipboardData` so the `clipboard` capability is not
`unsupported` on Windows. Today it is.

### REQ-readiness-url-opener
The Windows URL opener MUST use `ShellExecuteW(NULL, "open", url,
NULL, NULL, SW_SHOWNORMAL)`. Today the `url_open` capability is
`unsupported` on Windows.

### REQ-readiness-keychain
The Windows keychain host MUST use DPAPI for symmetric encryption
and the Credential Vault (`CredWriteW` / `CredReadW`) for
storage. Today tokens are stored in plaintext profile files on
Windows.

### REQ-readiness-installer
A PowerShell installer at `setup.ps1` MUST be authored and
shipped with this PR:

- Downloads `fx-windows-x86_64.zip`.
- Verifies the SHA-256 against a `fx.sha256` sidecar.
- Extracts `fx.exe` to the install directory
  (`$env:LOCALAPPDATA\fx\bin` by default).
- Persists the install directory to the user PATH via
  `SetEnvironmentVariable`.
- Supports `-Version`, `-Channel`, `-InstallDir`,
  `-NoPathUpdate`, `-SkipVerify`, `-Verbose`, `-WhatIf`,
  `-Help`.

The installer already exists in the working tree (459 lines,
untracked). It MUST be committed in this PR.

### REQ-readiness-docs
A new file at `docs/windows.md` MUST document:

- Installing `fx` on Windows (one-liner and manual).
- Building `fx` from source on Windows.
- The capability matrix (degraded features).
- Known limitations (HTTP fetch, ConPTY, keychain).
- The 6 stdlib bugs and their status.

`README.md` MUST link to `docs/windows.md` from a new "Windows"
section. `CHANGELOG.md` MUST include a Windows preview entry
under the next version.

## Scenarios

### SCN-readiness-zig-build-clean
Given a Zig install with the stdlib bugs fixed, when
`zig build -Dtarget=x86_64-windows -Doptimize=ReleaseSafe` is
run, then it exits 0 and produces `zig-out/bin/fx.exe`.

### SCN-readiness-zig-test-clean
Given a Zig install with the stdlib bugs fixed, when
`zig build test` is run on Windows, then it exits 0.

### SCN-readiness-ci-windows
Given the new `.github/workflows/windows.yml`, when a PR is
opened that touches a Windows-affecting file, then the
`windows-latest` job runs and reports its result on the PR
check suite.

### SCN-readiness-upgrade-zip
Given `fx.exe` is running on Windows, when the user runs
`fx upgrade`, then the binary is replaced with the new version
without requiring manual download.

### SCN-readiness-installer
Given a Windows machine with PowerShell, when the user runs
`iwr -useb https://fx.sh/setup.ps1 | iex`, then `fx.exe` is
installed to `$env:LOCALAPPDATA\fx\bin` and is reachable on the
PATH.

## PR-blocker summary

The upstream PR against `vercel-labs/fx` MUST NOT open until:

1. `zig build test` is green on a Windows runner (REQ-readiness-zig-test-windows).
2. The CI workflow is in place (REQ-readiness-ci-windows-job).
3. The self-upgrade ZIP path is implemented (REQ-readiness-self-upgrade-zip,
   REQ-readiness-replace-binary).
4. `docs/windows.md`, README, and CHANGELOG updates land
   (REQ-readiness-docs).

The native hosts (clipboard, URL, keychain) are documented
follow-ups; they do NOT block the PR but they MUST land before
fx is "fully featured" on Windows.