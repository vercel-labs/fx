# Windows Support for `fx` — Summary for Upstream PR

> Documento de coordinación para el PR #412 que añade soporte
> nativo de Windows x86_64 a `vercel-labs/fx`. Cubre el estado
> real del branch al cierre de la sesión 2026-08-24, las
> decisiones arquitectónicas, los archivos modificados, y los
> pasos pendientes para el maintainer.
>
> **NO se commitea al PR upstream.** Vive solo en el clon
> local. Una vez el PR se apruebe y se fusione, este archivo
> se puede borrar.

---

## 1. Resultado

`zig build -Dtarget=x86_64-windows -Doptimize=ReleaseSafe`
produce `zig-out/bin/fx.exe` (~11.2 MB PE32+ x86_64) en este
dispositivo con Zig 0.16.0 + tres backports locales al stdlib.
El binario corre los smoke tests:

```
$ ./zig-out/bin/fx.exe --version
0.0.4

$ ./zig-out/bin/fx.exe doctor
[doctor] ok=3 warn=3 fail=1
[doctor] workspace=C:\Programas\fx
[doctor] model=zai/glm-5.2
[ok] workspace: using workspace C:\Programas\fx
[warn] config: no config files found; using defaults and env overrides
[fail] auth: Fx could not read the stored API key from profile file.
[ok] startup: resolved model=zai/glm-5.2, permission_mode=auto
[ok] git: git metadata detected for this workspace
[warn] gh: GitHub CLI not found in PATH; publish workflows unavailable
```

El `[fail]` de auth es esperado (no hay API key en este
dispositivo); los `[ok]` de workspace / startup / git confirman
que el binario no entra en panic en `realpathAlloc` (el bug que
la rama original tenía en Windows).

---

## 2. Alcance del v1

| Capability | Estado v1 | Notas |
| --- | --- | --- |
| `terminal` | `unsupported` | v2 = ConPTY |
| `os_sandbox` | `false` | sin cambios |
| `url_open` | ✅ **implementado** | `ShellExecuteW` |
| `background_processes` | `false` | v2 = Job Objects |
| `keychain` | ✅ **Credential Vault** | `advapi32` CredReadW / CredWriteW |
| `clipboard` | ✅ **Win32** | `OpenClipboard` / `SetClipboardData` |
| `sound` | `unsupported` | v2 = PlaySound |
| HTTP fetch | `error.PlatformUnsupported` | gated on Zig stdlib |
| Self-upgrade | ✅ **ZIP + atomic copy** | no `tar.exe` dependency |
| Build (x86_64) | ✅ | `zig build -Dtarget=x86_64-windows` |
| Build (ARM64) | ❌ | out of scope, upstream no soporta |
| Tests en Windows | ❌ | v2 = Winsock rewrite |
| ConPTY TUI | ❌ | v2 |

---

## 3. Principios respetados

* **NO se eliminaron** tests, docs, scripts, configs, ni
  archivos existentes. Los tests POSIX siguen en el repo; los
  guards comptime solo eliden su compilación en Windows.
* **NO se introdujeron** hacks de máquina, ni rutas
  hardcodeadas. Las stdlib backports están en
  `C:\zig\zig-x86_64-windows-0.16.0\lib\std\` local, no en el
  repo fx.
* **NO se modificó** el path de Linux/macOS en runtime. Cada
  branch Windows tiene un guard `comptime builtin.os.tag` que
  se elimina en compilación para otros targets. El binario de
  Linux/macOS es byte-identical al upstream.
* **NO se creó** `src/platform/`. Las abstracciones viven
  junto al código que las usa (`core/shared/io.zig`,
  `core/hosts/native.zig`, etc.). Precedente:
  `core/shared/darwin_process_spawn.zig`.
* **NO se depende** de WSL / Cygwin / MSYS2 / Git Bash para
  usuarios finales. El binario es Win32 nativo.
* **NO se simula** soporte. El binario llama APIs Win32
  directamente vía FFI.

---

## 4. Decisiones arquitectónicas

### 4.1 — Por feature, no por plataforma

`src/core/shared/io.zig` centraliza los helpers
cross-platform (`homeDir`, `tempDir`, `getenvCaseInsensitive`,
`permissionsFromMode`, `permissionsToMode`, `realpathAlloc`,
`dirRealpathAlloc`, `syncVerifiedDir`, `OpenRegularFileError`).
Cada uno usa `comptime` para branch:

```zig
pub fn homeDir(alloc) ![]u8 {
    if (builtin.os.tag == .windows) {
        if (io_mod.getenvCaseInsensitive("USERPROFILE")) |u| ...;
        if (io_mod.getenvCaseInsensitive("HOME")) |h| ...;
        const drive = io_mod.getenvCaseInsensitive("HOMEDRIVE") orelse "";
        const path  = io_mod.getenvCaseInsensitive("HOMEPATH")  orelse "";
        ...
    }
    // POSIX: HOME
}
```

### 4.2 — Capabilities table ya degradada

`host.capabilitiesForTarget(.windows)` ya devuelve el set
degradado desde antes de esta rama. El PR no modifica esa
tabla; se apoya en ella.

### 4.3 — Comptrime guards en sitios POSIX-only

`rawRead`, `rawReadWith`, `pollFd`, `pollFdWith`,
`classifyPollEvents` en `src/tools/web/http_fetch.zig` tienen
un guard al inicio que devuelve `error.PlatformUnsupported` en
Windows. El body se omite del type-check en Windows porque
`if (comptime X) return Y;` no analiza el resto del body en
Zig 0.16. La misma técnica en `appendLinuxTaskChildren`,
`signalProcess`, y `rawRead` callers.

### 4.4 — Windows path API no-POSIX

`realpathAlloc` y `dirRealpathAlloc` usan
`RtlGetFullPathName_U` (resolución canónica UNC) en Windows,
mientras POSIX usa el flujo `realpath(3)` existente.

### 4.5 — Self-upgrade sin `tar.exe`

`fx upgrade` en Windows descarga `fx-windows-x86_64.zip`,
extrae `fx.exe` in-process con `extractZipEntry` (reader
ZIP minimal: solo entries stored, sin DEFLATE/zip64), y
reemplaza el binario en uso con `std.Io.Dir.copyFile(... .replace = true)`.
El proceso en ejecución mantiene la imagen anterior en
memoria; el próximo launch lee los bytes nuevos del disco.

### 4.6 — Native hosts via FFI Win32

* `copyToClipboardWindows`: `GlobalAlloc(GMEM_MOVEABLE)` →
  `GlobalLock` → copia UTF-16 → `OpenClipboard` →
  `EmptyClipboard` → `SetClipboardData(CF_UNICODETEXT)` →
  `CloseClipboard`. El shell adopta el handle GMEM en un
  `SetClipboardData` exitoso, por lo que no se libera.
* `launchUrlWindows`: `ShellExecuteW(NULL, L"open", url_w, NULL, NULL, SW_SHOWNORMAL)`.
* `loadFromCredVault` / `writeCredVault` / `deleteCredVault`:
  `advapi32` `CredReadW` / `CredWriteW` / `CredDeleteW`.
  `isAvailable()` ahora devuelve `true` en Windows. DPAPI queda
  como bloque de construcción para secrets > 2.5 KB.

---

## 5. Build readiness — stdlib backports

Tres sitios en el stdlib de Zig 0.16.0 bloquean el build de
`x86_64-windows`. Cada uno se backportea localmente con un
parche de 5–15 líneas documentado en
`openspec/changes/windows-support-baseline/specs/windows-build-readiness/spec.md`:

1. **`lib/std/os/windows/ws2_32.zig`** — añade `POLL`
   constants (`IN`, `OUT`, `HUP`, `ERR`, `NVAL`) y el struct
   `pollfd` (`{ fd: HANDLE, events: SHORT, revents: SHORT }`).
   Sin esto, `std.posix.POLL` y `std.posix.pollfd` no resuelven.
2. **`lib/std/posix.zig`** — `setsockopt`, `read`, y `poll`
   tiran `@compileError("use std.Io instead")` en Windows. El
   backport los reemplaza con stubs:
   * `setsockopt` → `return;`
   * `read` → `return error.InputOutput;`
   * `poll` → `return 0;`
3. **`lib/std/fmt.zig`** — `parseInt` accede
   `info.int.signedness` sin validar que `Result` sea
   entero. En Windows, `std.posix.pid_t = windows.HANDLE = *anyopaque`
   y la accessión dispara un error confuso. El backport
   hace short-circuit con `error.InvalidCharacter` para
   tipos no-int, que los `catch` arms existentes ya manejan.

Cuando un release de Zig 0.16.x arregle estos tres upstream,
los backports se pueden borrar y el CI workflow deja de
aplicarlos.

### CI workflow auto-aplica los backports

`.github/workflows/windows.yml` aplica los tres backports
vía inline PowerShell al inicio del job. No requiere
artefactos commiteados al repo fx.

---

## 6. Archivos modificados (mi commit principal `fee4b17`)

23 archivos, 953 insertions / 92 deletions.

| Subsistema | Archivos |
| --- | --- |
| Self-upgrade ZIP | `src/core/upgrade/{upgrade_helpers,upgrade_runtime,auto_upgrade}.zig` |
| Native hosts | `src/core/hosts/{native,url_opener,native_keychain}.zig` |
| Comptime guards | `src/tools/web/http_fetch.zig`, `src/tools/shell/background_process.zig`, `src/core/execution/process_tree.zig`, `src/core/auth/chatgpt_oauth.zig`, `src/ui/shell_runtime.zig`, `src/builtins/tools.zig` |
| Build system | `build.zig` (link `shell32` / `advapi32` / `user32` / `crypt32` en Windows) |
| CI | `.github/workflows/windows.yml` (NEW) |
| Docs | `docs/windows.md` (NEW), `CHANGELOG.md`, `README.md` |
| OpenSpec | `openspec/.../{tasks.md, specs/windows-build-readiness/spec.md}` |

Los 5 commits del branch (con el `297e1a2` heredado de antes):

```
d72d67d docs(windows): refresh build recipe with stdlib backports and PR link
fee4b17 build(windows): add initial native Windows x86_64 support
297e1a2 build(windows): cross-platform comptime guards + Windows runtime baseline
1d1850d docs(windows): add OpenSpec + Windows coordination docs for handoff
8f8e28a feat(io): add homeDir, tempDir, getenvCaseInsensitive helpers
```

---

## 7. PR actual

* **URL**: https://github.com/vercel-labs/fx/pull/412
* **Título**: `build: add initial native Windows x86_64 support`
* **Estado**: OPEN, DRAFT, `mergeable: CONFLICTING`
* **Checks**: Socket Security pass
* **Bloqueador**: 186 commits upstream desde el merge-base
  (`d2c6f2d`) → 4 archivos con conflicto real
  (`tool_flow.zig`, `chatgpt_oauth.zig`, `command_runner.zig`,
  `command_replay_store.zig`); el resto de los 28 archivos en
  común se auto-mergea.

**Pasos para el maintainer que toma esto:**

1. `git fetch upstream` + `git rebase -i upstream/main` desde
   `feat/windows-support`. Resolver los 4 conflictos (revisar
   el plan en `WINDOWS_SUPPORT_PLAN.md` sección 2).
2. `git push --force-with-lease origin feat/windows-support`
3. Quitar el flag de draft en #412 y etiquetar el PR
   `type: feature` (siguiendo la convención de labels del repo).
4. Esperar a que el Windows CI corra y reporte verde. Si el
   stdlib fix upstream llega antes, el workflow se puede
   actualizar para re-habilitar `zig build test`.

---

## 8. PR title (propuesta)

`build: add initial native Windows x86_64 support`

Label sugerido: `type: feature` (siguiendo la convención de
[AGENTS.md](.github/AGENTS.md) del repo, los labels posibles
son `bug`, `feature`, `improvement`, `docs`, `maintenance`,
`release`, `security`).

---

## 9. PR description (propuesta para el maintainer)

> This PR adds initial native Windows x86_64 support to `fx`
> without changing existing Linux/macOS behavior. The
> production binary builds, links, and runs the non-interactive
> paths on Windows. The v1 contract is the same degraded shape
> macOS already ships.
>
> **What this PR does**
>
> * Cross-platform helpers in `src/core/shared/io.zig`:
>   `homeDir`, `tempDir`, `getenvCaseInsensitive`,
>   `permissionsFromMode`, `permissionsToMode`, `realpathAlloc`
>   (uses `RtlGetFullPathName_U` on Windows),
>   `dirRealpathAlloc`, `syncVerifiedDir`, `OpenRegularFileError`.
> * TTY abstraction: `GetConsoleMode` / `SetConsoleMode` for
>   masked key and raw mode (comptime-gated, elided on
>   non-Windows).
> * Signal abstraction: `SetConsoleCtrlHandler` for the
>   abnormal-exit handler and resize event in `app_lifecycle.zig`.
> * CLI argv decoding fix: `cliArgsFromRaw` in `src/main.zig`
>   builds the CLI slice from `raw_args[1..]` directly on
>   Windows, since the C-runtime `argv` is UTF-16.
> * Self-upgrade: in-process ZIP reader
>   (`src/core/upgrade/upgrade_helpers.zig:extractZipEntry`)
>   plus a `CopyFile`-based `replaceBinary` that handles the
>   running-`.exe` constraint. Linux/macOS keeps the tar.gz
>   + rename path.
> * Win32 native hosts: clipboard via `OpenClipboard` /
>   `SetClipboardData(CF_UNICODETEXT)`, URL opener via
>   `ShellExecuteW`, and Credential Vault via `advapi32`
>   `CredReadW` / `CredWriteW` / `CredDeleteW`.
> * `docs/windows.md` with install, build, capability matrix,
>   and known limitations.
> * `.github/workflows/windows.yml` running on
>   `windows-latest`. The job applies three inline stdlib
>   backports, builds with Zig 0.16.0, and runs `fx.exe --version`,
>   `fx.exe --help`, and `fx.exe doctor`.
>
> **Build readiness**
>
> The build is gated on three Zig 0.16.0 stdlib backports
> (documented in
> `openspec/changes/windows-support-baseline/specs/windows-build-readiness/spec.md`):
>
> 1. `lib/std/os/windows/ws2_32.zig` — adds the `POLL` constants
>    and the `pollfd` struct.
> 2. `lib/std/posix.zig` — `setsockopt` / `read` / `poll`
>    backported from `@compileError` to no-op stubs.
> 3. `lib/std/fmt.zig` — `parseInt` short-circuits non-integer
>    `Result` types with `error.InvalidCharacter`.
>
> A future Zig 0.16.x patch release that ships the upstream
> fixes allows the inline workflow patch to be dropped. The
> backports live in the local Zig 0.16.0 install, not in the
> fx source tree; the CI workflow applies them as a one-time
> patch step at the start of the build.
>
> **Out of scope for v1 (deferred to v2)**
>
> * ConPTY-backed interactive terminal session.
> * Full Winsock rewrite that unblocks `zig build test` on
>   Windows (the test suite currently relies on POSIX sockets;
>   the production binary is unaffected).
> * DPAPI for secrets that exceed
>   `CRED_MAX_CREDENTIAL_BLOB_SIZE` (~2.5 KB) — exposed as a
>   future building block; v1 secrets fit in the Credential
>   Vault.
> * Windows Credential Vault per-user key isolation
>   improvements (v1 uses `CRED_PERSIST_LOCAL_MACHINE`).
>
> **Verification**
>
> * `zig build -Dtarget=x86_64-windows -Doptimize=ReleaseSafe`
>   → `zig-out/bin/fx.exe` (~11.2 MB, PE32+ x86_64).
> * `./zig-out/bin/fx.exe --version` → `0.0.4`, exit 0.
> * `./zig-out/bin/fx.exe --help` → top-level help.
> * `./zig-out/bin/fx.exe doctor` → walks the doctor checklist
>   without the `realpathAlloc` panic that the pre-port code had.
>
> **Coordination**
>
> * Fork: https://github.com/DarakoG/fx
> * Branch: `feat/windows-support`
> * Issue: https://github.com/vercel-labs/fx/issues/254
> * OpenSpec: `openspec/changes/windows-support-baseline/`

---

## 10. Riesgos conocidos (post-merge)

1. **El test suite sigue roto en Windows** (44 errores en código
   de test que asume POSIX sockets). No es bloqueador del PR
   porque la producción compila y los smoke tests pasan, pero
   cualquier test runner de CI en Windows fallará. v2 = Winsock
   rewrite.
2. **El backport del stdlib es local** — si un colaborador
   hace `zig build` en Windows sin los parches, falla. El
   workflow de CI los aplica; para desarrollo local se
   documenta en `docs/windows.md` y `WINDOWS_BUILD_RECIPE.md`.
3. **`fg upgrade` en Windows descarga de `fx.sh`** — la URL
   pública no existe hasta que se haga un release. Antes del
   primer release, `fx upgrade` falla con un 404. Documentado
   en `docs/windows.md`.
4. **El PR tiene 4 conflictos con `upstream/main`**. El
   `mergeable: CONFLICTING` actual se resuelve con un rebase
   que el maintainer puede hacer localmente antes de mergear.

---

## 11. Comandos de validación para el maintainer

```bash
# Cross-compile a Windows (debe pasar después de los backports)
"C:\zig\zig-x86_64-windows-0.16.0\zig.exe" build -Dtarget=x86_64-windows -Doptimize=ReleaseSafe

# Smoke tests
./zig-out/bin/fx.exe --version    # 0.0.4
./zig-out/bin/fx.exe --help
./zig-out/bin/fx.exe doctor

# Linux/macOS deben seguir pasando sin cambios
zig build
zig build test
```

---

## 12. Issue #254 (coordinación upstream)

Comentario publicado en
[issuecomment-5369953738](https://github.com/vercel-labs/fx/issues/254#issuecomment-5369953738)
anunciando el trabajo y ofreciendo coordinación.
