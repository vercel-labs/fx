# Spec: Windows build readiness

> Delta spec for the requirements on the Zig toolchain and the
> upstream PR-blocker items. No `fx` source change can resolve
> these; they depend on either a Zig release or an fx-side helper
> that works around the issue.

## Purpose

Capture every requirement that gates the
`fx.exe` Windows build, the `zig build test` green run on
Windows, and the upstream PR opening. Each requirement is
explicit about whether the fix lives in the Zig standard library,
in a new Windows-specific fx helper, or in a new CI workflow.

## Requirements

### REQ-readiness-zig-version
fx MUST build on a Zig version where all six stdlib bugs below
are fixed. Today (Zig 0.16.0) they are not. The build is gated
on either:

- A Zig 0.16.x patch release that fixes the bugs, OR
- An fx upgrade to a Zig nightly where the bugs are fixed.

The currently-attempted upgrade is
`zig-x86_64-windows-0.17.0-dev.1818+7051f8e73.zip` (download
succeeded, extraction with `tar -xf` failed; next attempt is
`unzip` / `Expand-Archive`).

### REQ-readiness-stdlib-bugs
The following six Zig stdlib errors MUST be resolvable from fx
side without modification OR must be fixed upstream:

1. `lib\std\Io\Writer.zig:1803` — format spec `'d'` invalid for
   `*anyopaque` (transitively via `std.fmt`).
2. `lib\std\c.zig:1716` — `ws2_32` has no member named `POLL`.
3. `lib\std\c.zig:4299` — `ws2_32` has no member named `pollfd`.
4. `lib\std\fmt.zig:436` — access of union field `'int'` while
   field `'pointer'` is active.
5. `lib\std\fmt.zig:436` — duplicate of (4).
6. `lib\std\posix.zig:1075` — `use std.Io instead`.

Items 2 and 3 are gated by the fx decision to disable HTTP fetch
on Windows (`REQ-platform-http-degrade` in
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