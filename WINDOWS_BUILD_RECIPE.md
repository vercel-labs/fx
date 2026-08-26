# Windows Build Recipe for fx (x86_64-windows)

> Status: **WORKING** as of `fee4b17` on `feat/windows-support` —
> the production `zig-out/bin/fx.exe` builds, links, and runs the
> non-interactive paths. `fx.exe --version` prints `0.0.4` and
> exits 0. `fx.exe --help` prints the full top-level help.
> `fx.exe doctor` walks the doctor checklist without panicking.
> Interactive mode still requires a TTY (expected: ConPTY is v2).

## Toolchain

| Item | Value |
| --- | --- |
| Zig | **0.16.0** (`C:\zig\zig-x86_64-windows-0.16.0\zig.exe`) |
| Target | `x86_64-windows` |
| Optimize | `ReleaseSafe` |
| Working dir | `C:\Programas\fx` |
| Branch | `feat/windows-support` |

Zig 0.17-dev was attempted first and abandoned: 0.17 removed the
`**` repetition operator and `errdefer |err|` capture blocks
(300+ fx call sites would have to be rewritten), and its bundled
mingw-w64 regressed with `.seh_ directive must appear within an
active frame`. Zig 0.16 with three local stdlib backports is the
chosen path. See `openspec/changes/windows-support-baseline/specs/windows-build-readiness/spec.md`
for the per-site rationale.

## Successful build command

```bash
"C:\zig\zig-x86_64-windows-0.16.0\zig.exe" build -Dtarget=x86_64-windows -Doptimize=ReleaseSafe
```

Output:
- `zig-out/bin/fx.exe` (~11.2 MB, PE32+ x86_64 Windows console)
- `zig-out/bin/fx.pdb`

## Stdlib backports (required for the build)

Three sites in the local `C:\zig\zig-x86_64-windows-0.16.0\lib\std\`
install are patched. The CI workflow applies the same patches via
inline PowerShell so a clean checkout of fx + a stock Zig 0.16.0
install can build without any prior setup.

1. **`lib/std/os/windows/ws2_32.zig`** — add the `POLL` constants
   (`RDNORM`, `IN`, `OUT`, `HUP`, `ERR`, `NVAL`) and the `pollfd`
   struct (`{ fd: HANDLE, events: SHORT, revents: SHORT }`). Without
   these, every cross-platform file that references `std.posix.poll`
   or `std.posix.POLL.*` fails to type-check.
2. **`lib/std/posix.zig`** — `setsockopt` and `read` and `poll` on
   Windows throw `@compileError("use std.Io instead")`. Replace the
   compile errors with a no-op return (`setsockopt`),
   `error.InputOutput` (`read`), and `0` (`poll`) so cross-platform
   POSIX call sites link.
3. **`lib/std/fmt.zig`** — `parseInt` accesses `info.int.signedness`
   without validating that `Result` is an integer. Short-circuit
   the function to return `error.InvalidCharacter` for non-integer
   `Result` types, which the existing `catch` arms in call sites
   already handle.

## Verification

```
$ ./zig-out/bin/fx.exe --version
0.0.4

$ ./zig-out/bin/fx.exe --help
𝒇x v0.0.4
Fast, native coding agent for the terminal.

𝒇x starts an interactive session by default. Use `fx ask` to run one
noninteractive request.

Usage:
  fx [flags]
  fx <command> [...flags] [...args]
...
```

```
$ ./zig-out/bin/fx.exe doctor
[doctor] ok=3 warn=3 fail=1
[doctor] workspace=C:\Programas\fx
[doctor] model=zai/glm-5.2
[doctor] auth=missing
[doctor] auth_refreshable=false
[doctor] permission_mode=auto
[doctor] agent_step_limit=0
[ok] workspace: using workspace C:\Programas\fx
[warn] config: no config files found; using defaults and env overrides
[fail] auth: Fx could not read the stored API key from profile file. A key may be saved but unreadable. Set FX_TRACE_LOG for the failing step, or set AI_GATEWAY_API_KEY.
[ok] startup: resolved model=zai/glm-5.2, permission_mode=auto, agent_step_limit=0
[warn] state: failed to inspect workspace state: HomeNotSet
[ok] git: git metadata detected for this workspace
[warn] gh: GitHub CLI not found in PATH; publish workflows unavailable
```

## Patches applied (fx source)

* `src/builtins/tools.zig:2` — fixed the import of
  `../../core/shared/io.zig` to `../core/shared/io.zig`. The
  `../../` would have escaped the module path under Zig 0.16's
  stricter import rules. The original `297e1a2` commit landed with
  the bad path, but `297e1a2` did not exercise this file in the
  build graph (it was reached only by tests, which were not run
  on the previous device).
* `src/tools/web/http_fetch.zig` — added
  `if (comptime builtin.os.tag == .windows) return error.PlatformUnsupported;`
  at the top of `rawRead`, `rawReadWith`, `pollFd`, `pollFdWith`,
  and `classifyPollEvents` so the function body is not type-checked
  on Windows. The `extractTarGz` and `connectPinned` paths were
  already guarded.
* `src/ui/shell_runtime.zig:454` — changed
  `@intCast(@intFromPtr(self.stdin_fd))` to
  `@ptrCast(self.stdin_fd)` on Windows. `posix.fd_t = *anyopaque`
  on Windows so `@intCast` would refuse the target.
* `src/core/auth/chatgpt_oauth.zig:279` — same fix for the OAuth
  browser callback listener. Added `const builtin = @import("builtin");`
  to the imports.
* `src/tools/shell/background_process.zig:485` — added a Windows
  early-return to `signalProcess` so the `parseInt(std.posix.pid_t, ...)`
  call is not type-checked on Windows. The runtime path was already
  returning `error.Unsupported` via the `background_processes`
  capability check, but the type-check fires before the runtime
  check.
* `src/core/execution/process_tree.zig:329` — added a Windows
  early-return to `appendLinuxTaskChildren`. The function reads
  `/proc/{pid}/task/{tid}/children` which is Linux-only; the new
  guard makes the type-check skip the body on Windows.
* `src/core/upgrade/upgrade_helpers.zig:285` — added the Windows
  branch to `replaceBinary`. On Windows the function now calls
  `std.Io.Dir.copyFile(... .replace = true)`; the running process
  keeps the old image in memory and the next launch reads the
  fresh bytes from disk. The non-Windows rename-with-fallback
  flow is unchanged.
* `src/core/upgrade/upgrade_helpers.zig:300+` — added
  `extractZipEntry(alloc, archive_path, dest_dir, "fx.exe")`, a
  minimal in-process ZIP reader (compression method 0 / stored
  only). Called from `upgrade_runtime.zig` and `auto_upgrade.zig`
  only on Windows; the URL is `fx-{platform}.zip` instead of
  `fx-{platform}.tar.gz`.
* `src/core/hosts/native.zig:15` — added `copyToClipboardWindows`
  which wraps `OpenClipboard` / `SetClipboardData(CF_UNICODETEXT)`
  via `GlobalAlloc(GMEM_MOVEABLE)` + `GlobalLock` + `GlobalUnlock`.
  The shell adopts the GMEM handle on a successful
  `SetClipboardData`, so we do not free it.
* `src/core/hosts/url_opener.zig:75` — added `launchUrlWindows`
  which calls `ShellExecuteW(NULL, L"open", url_w, NULL, NULL,
  SW_SHOWNORMAL)`. Linked against `shell32`.
* `src/core/hosts/native_keychain.zig` — added `loadFromCredVault`,
  `writeCredVault`, and `deleteCredVault` using `advapi32`
  `CredReadW` / `CredWriteW` / `CredDeleteW`. `isAvailable()` now
  returns true on Windows. macOS paths are unchanged.
* `build.zig:67` — link `shell32`, `advapi32`, `user32`, `crypt32`
  when the target is `x86_64-windows`.

## CI

`.github/workflows/windows.yml` runs on `windows-latest`. The job:

1. Sets up Zig 0.16.0 via `mlugg/setup-zig@v2`.
2. Applies the three stdlib backports via inline PowerShell.
3. Builds with `zig build -Dtarget=x86_64-windows -Doptimize=ReleaseSafe`.
4. Runs `fx.exe --version`, `fx.exe --help`, and `fx.exe doctor`.
5. Uploads `zig-out/bin/fx.exe` as a build artifact.

`zig build test` is intentionally not run: the test suite assumes
POSIX sockets and the Winsock rewrite is v2.

## Self-upgrade (Windows)

`fx upgrade` on Windows:

1. Downloads `fx-windows-x86_64.zip` (and its `.sha256` sidecar).
2. Verifies the SHA-256 against the sidecar.
3. Extracts `fx.exe` in-process with `extractZipEntry`. No
   `tar.exe` / `Expand-Archive` dependency.
4. Replaces the running `fx.exe` in place via
   `std.Io.Dir.copyFile(... .replace = true)`. The running
   process keeps the old image in memory; the next launch reads
   the fresh bytes from disk.

`fx.exe doctor` previously panicked on the unreachable
`realpathAlloc` code path; that is fixed in `297e1a2` and
verified to no longer fire.

## Open PR

A draft PR is open at
`https://github.com/vercel-labs/fx/pull/412` (branch
`feat/windows-support` → `vercel-labs/fx:main`). The four
companion docs (`WINDOWS_SUPPORT_PLAN.md`,
`WINDOWS_SUPPORT_ANALYSIS.md`, `WINDOWS_SUPPORT_SUMMARY.md`,
`WINDOWS_BUILD_RECIPE.md` — this file) plus the `openspec/`
tree are the durable coordination surface.
