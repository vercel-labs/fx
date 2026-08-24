# fx Windows Support — Análisis Técnico de Compatibilidad

> Documento de Fase 02. Generado por auditoría automatizada del repositorio
> `vercel-labs/fx` (commit `d2c6f2d` sobre `main`).
> **No se commitea al repo final** — vive solo en el clon local.
>
> Auditoría **solo lectura**. Cero modificaciones al código fuente.

---

## 1. Resumen ejecutivo

`fx` es un codebase Zig 0.16 profundamente acoplado a Unix. El árbol `src/`
tiene **617 archivos** que dependen de syscalls POSIX (`std.posix.*`,
`std.c.*`, raw `tcgetattr`/`sigaction`/`kill`/`waitpid`), y trae:

- Un sandbox macOS-Darwin-only (`/usr/bin/sandbox-exec`).
- Un Keychain bridge Darwin-only (`/usr/bin/security`, `/usr/bin/osascript`,
  `/usr/bin/expect`).
- Un inspector de process tree Linux-only (`/proc`, `KERN_PROC`).
- Shells hardcodeados (`/bin/sh`, `/bin/bash`, `/bin/zsh`) y temporales
  (`/tmp`, `$TMPDIR`) en paths de runtime, permisos, fixtures y tests.

La matriz de CI actual es **linux-x86_64 / linux-aarch64 / macos-x86_64 /
macos-aarch64**. No hay runner Windows, ni `windows-latest`, ni `setup.ps1`.
El install es `curl … | bash`.

**Pero el codebase ya tiene seams Windows-aware significativos** que confirman
que la decisión arquitectónica de aceptar Windows como plataforma degradada
ya fue tomada:

- `host.capabilitiesForTarget` ya devuelve `.terminal = .unsupported`,
  `os_sandbox = false` y `url_open = unsupported` para Windows.
- `darwin_process_spawn` se monta solo en `.macos` desde
  `core/shared/io.zig:22`.
- `core/hosts/native_keychain.zig`, `core/notifications/sound.zig` y
  `core/permissions/sandbox.zig` ya ramifican por OS tag.
- `cli_surface.zig` y `main.zig` ya rutean stdout/stderr por `std.Io.File`
  en Windows mientras conservan el fast path `std.c.write` en el resto.

**Implicación:** la superficie realista para soporte nativo Windows es:

1. Un set pequeño pero inevitable de abstracciones en
   `core/shared/io.zig`, `core/shared/signal.zig`, `core/shared/tty.zig`,
   `core/hosts/` y `core/permissions/`.
2. Reescritura de `core/terminal/native_session.zig` y `core/terminal/tmux_session.zig`
   porque son 100% PTY/`forkpty`/`ioctl`/`posix_spawn`. Esto es el bloque más
   grande y se puede **deferir a v2** porque la capability ya está
   `unsupported` para Windows.
3. Equivalentes Windows para Keychain, clipboard y sandbox macOS-only.
4. Refactor de paths, env-vars, signals y permisos en
   `core/workspace/pathing.zig`, `core/upgrade/upgrade_helpers.zig`,
   `core/cli/doctor_runtime.zig`, `core/shared/io.zig`.
5. Limpieza de los `error.SkipZigTest` para que la suite realmente ejerza
   Windows donde corresponde.

> **v1 realista:** `fx` corre end-to-end en Windows con terminal
> interactivo/sandbox/URL/Keychain/audio degradados.

---

## 2. Hallazgos por categoría

### A. Process spawning & subprocesses

| Archivo | Línea | Severidad | Detalle |
| --- | --- | --- | --- |
| `src/main.zig` | 895–906 | blocker | `enableRawMode`/`disableRawMode` usan `tcsetattr` (no existe en Windows). |
| `src/main.zig` | 3380 | blocker | `handleSigWinchNative` se monta sobre `SIG.WINCH` (no existe en Windows). |
| `src/core/cli/cli_surface.zig` | 1707–1798 | blocker | `MaskedKeyRawMode` usa `tcgetattr`/`tcsetattr` para leer passwords. |
| `src/core/cli/cli_surface.zig` | 1727 | abstracción | `std.posix.read(STDIN_FILENO)` debe migrar a `std.Io.File.stdin().read`. |
| `src/core/cli/cli_ask.zig` | 162–175, 5445–5880 | blocker | `sigaction(SIG.INT|TERM)` y suite `headless_interrupt` (POSIX-only). |
| `src/core/hosts/native_keychain.zig` | 35, 36, 110, 139, 152, 231, 360, 635 | blocker | Keychain macOS-only (`security`/`expect`/`osascript`). |
| `src/core/hosts/native.zig` | 18, 84–200 | blocker | Clipboard macOS-only (`pbcopy`/`osascript`/`waitpid`). |
| `src/core/hosts/url_opener.zig` | 57–61 | abstracción | `ShellExecuteW` para abrir URLs en Windows. |
| `src/core/upgrade/upgrade_runtime.zig` | 192 | blocker | `TMPDIR orelse "/tmp"` — `/tmp` no existe en Windows. |
| `src/core/upgrade/upgrade_helpers.zig` | 49 | blocker | `@compileError("unsupported platform …")`. Auto-upgrade es Mac/Linux-only. |
| `src/core/upgrade/upgrade_helpers.zig` | 247 | abstracción | `tar -xzf` — preferir ZIP nativo en Windows. |
| `src/core/upgrade/upgrade_runtime.zig` | 258 | blocker | `replaceBinary` no puede renombrar `.exe` en ejecución en Windows. |
| `src/core/workspace/workspace_files.zig` | 260–280 | abstracción | `trustedGitExecutable()` ya tiene candidatos Windows pero conviene usar `which git` vía PATH. |
| `src/core/execution/process_tree.zig` | 50, 56, 178 | blocker | `kill`/`getpid` — Windows necesita `EnumProcesses`/`OpenProcess`. |
| `src/core/permissions/sandbox.zig` | 254, 478, 482, 2540, 2710–2746 | blocker | `sigaction`/`kill(-pid, …)` (process group no existe en Windows). |
| `src/core/permissions/direct_command.zig` | 952, 963, 1026, 1164, 1179, 1199, 1223, 1244, 1272, 1296, 1464, 1506, 1716, 1734 | blocker | `argv = ["/usr/bin/env", "/usr/bin/wc", …]` — fixtures hardcodeados. |
| `src/core/permissions/direct_command.zig` | 1324, 1343, 1419, 1522, 1579, 1615, 1647, 1679, 1756, 1852 | blocker | `argv = ["/bin/sh", …]` — fixtures hardcodeados. |
| `src/core/terminal/native_session.zig` | 48–57, 474, 5685–5745, 6062 | blocker | PTY + ConPTY. **v2**: deferir; capability ya es `unsupported`. |
| `src/core/terminal/shell_resolver.zig` | 19–28, 79, 84–101, 142–148, 214–250 | blocker | Resolver y arrancar shell POSIX (`bash`/`zsh`). Necesita `pwsh`/`cmd`. |
| `src/core/mcp/stdio_dispatcher.zig` | 1673–1674, 1872 | blocker | `kill(-child_id, .KILL)` (process group); usar `TerminateProcess`. |
| `src/core/mcp/mcp_runtime.zig` | 15980 | blocker | `kill(pid, 0)` (probe) — `WaitForSingleObject(handle, 0)`. |
| `src/builtins/skills.zig` | 1692 | blocker | `argv = ["/bin/sh", "-c", script]`. |
| `src/tools/web/http_fetch.zig` | 3709–3710 | blocker | `sigaction(SIG.USR1, …)` — usar `std.atomic.Value(bool)` + worker. |

### B. Terminal / TTY / signals

| Archivo | Línea | Severidad | Detalle |
| --- | --- | --- | --- |
| `src/core/cli/cli_surface.zig` | 1755–1798 | blocker | `MaskedKeyRawMode` con `tcgetattr`/`tcsetattr`. |
| `src/core/auth/login_flow.zig` | 1258, 1267, 1291, 1298 | blocker | Idem. |
| `src/ui/shell_runtime.zig` | 68, 97–179, 158–166, 254, 576, 601, 611, 634 | blocker | `original_termios`, `sigaction(SIG.WINCH)`, `posix.read`, PTY. |
| `src/ui/ask_presentation.zig` | 405–408 | abstracción | `enableRawMode()` debe pasar por la abstracción. |
| `src/core/app/app_lifecycle.zig` | 51–117 | blocker | `installAbnormalExitHandlers` usa SIG.TERM/HUP — `SetConsoleCtrlHandler`. |
| `src/ui/terminal/terminal.zig` | 37 | abstracción | `std.posix.winsize` — `GetConsoleScreenBufferInfo`. |

### C. Filesystem & paths

| Archivo | Línea | Severidad | Detalle |
| --- | --- | --- | --- |
| `src/core/shared/io.zig` | 565 | blocker | `syncVerifiedDir` devuelve `error.OperationUnsupported` — skip para Windows. |
| `src/core/shared/io.zig` | 891–950 | blocker | `handlePathAlloc`/`dirRealpathAlloc` — `GetFinalPathNameByHandleW`. |
| `src/core/workspace/pathing.zig` | 369 | blocker | `getenv("HOME")` — Windows usa `USERPROFILE`. |
| `src/core/cli/cli_surface.zig` | 1472 | blocker | Idem. |
| `src/core/cli/cli_ask.zig` | 1452 | blocker | Idem. |
| `src/core/cli/cli_surface.zig` | 2653, 2746 | cosmético | Mensaje "HOME is not set" → "user profile directory not found; set HOME or USERPROFILE". |
| `src/core/cli/doctor_runtime.zig` | 609 | blocker | `getenv("PATH")` case-sensitive — Windows usa `Path`. |
| `src/core/cli/doctor_runtime.zig` | 608–633 | abstracción | `commandInPath` debe probar `git.exe`/`node.exe` antes que `git`/`node`. |

**Usos de `/tmp` en runtime (blockers):**
- `src/core/upgrade/upgrade_runtime.zig:192`
- `src/core/upgrade/auto_upgrade.zig:211`
- `src/core/background/background_launch_output.zig:121`
- `src/core/notifications/sound.zig:46`
- `src/core/workspace/record_tape.zig:116`
- `src/core/permissions/sandbox.zig:1937`
- `src/core/app/app_commands.zig:1777`

Los `/tmp/...` que aparecen como literales en **fixtures de tests** son
seguros: `std.testing.tmpDir` abstrae el sistema de archivos del runner.

### D. Environment & configuration

- `HOME` no está establecido en Windows por defecto. Se necesita un helper
  `homeDir()` que pruebe `HOME` → `USERPROFILE` → `std.Io.homeDir`.
- `PATH` es `Path` (case-sensitive) en Windows: case-fold lookup.
- Las herramientas (`git`, `node`, `python`, etc.) terminan en `.exe`.

### E. Networking & sockets

- `std.posix.setsockopt`/`SO_LINGER`/`SO_RCVBUF` ya mapean a Winsock en Zig 0.16.
  **Severidad:** works-as-is con verificación en Windows.

### F. Memory & shared libraries

- Sin uso de `Windows.h`, `GetCurrentProcess`, `CreateProcess`, `dlopen`,
  `dlsym` o `mmap`. **Works-as-is.**

### G. Funciones específicas

- `std.c.waitpid` (POSIX-only) → `WaitForSingleObject` + `GetExitCodeProcess`.
- `std.c.passwd`/`getpwuid_r`/`getuid` → `GetUserNameW`.
- `getpgid` no existe en Windows.
- `SIGUSR1` no existe en Windows.

### H. MCP / ACP

- `src/acp/jsonrpc.zig:312` `std.posix.read(STDIN_FILENO)` → `std.Io.File.stdin().read`.
- Resolución de comandos MCP: usar `commandInPath` para `node`, `python`, etc.
- Servidores MCP que ya son compatibles con Windows (Node-based) deben correr.

### I. Build system

- `build.zig:52–66` ya usa `link_libc = true` → cross-platform.
- `discoverNodeIncludeDir` y `git rev-parse` funcionan con PATH.
- **`wasm32-wasi` ya soportado** — el equipo piensa en multiplataforma.

### J. CI / GitHub Actions

Workflows identificados en `.github/workflows/`:

| Archivo | Runners actuales | ¿Listo para Windows? |
| --- | --- | --- |
| `ci.yml` | `ubuntu-latest` | No. Reemplazar `shell: bash` en algunos steps. |
| `full-ci.yml` | `ubuntu-24.04`, `ubuntu-24.04-arm`, `macos-15-intel`, `macos-15` | No. `apt-get`/`brew install tmux`/`zsh` no corren en Windows. |
| `release.yml` | `ubuntu-latest` | No. `sha256sum`/`tar -czf` no existen; no hay artefacto Windows. |
| `binary-size.yml` | ubuntu, macos | Parcial. `file`/`size` existen en Windows. |
| `bench.yml` | `ubuntu-latest` | No. `wget`/`dpkg -i`. |
| `dev-release.yml` | `ubuntu-latest` | No. |
| `prepare-release.yml` | `ubuntu-latest` | No. |
| `cdn-backfill.yml` | `ubuntu-latest` | No. |
| `pgso-macos-arm64.yml` | `macos-15` | No aplica. |
| `publish-libfx.yml` | `ubuntu-latest` | No. |

**Recomendación:** agregar un nuevo `windows-ci.yml` (o entrada de matriz) que
corra `zig build`, `zig build test`, y un subset Bun-driven de tests sin tmux.

### K. Install / upgrade

- `README.md:7, 25` → `curl -fsSL https://fx.sh/setup.sh | bash`. **Blocker.**
- Necesitamos `setup.ps1` para descargar `fx-windows-x86_64.zip`, extraer a
  `%LOCALAPPDATA%\fx\bin\` y prepender al PATH del usuario.
- Auto-upgrade (`upgrade_helpers.zig:49`) actualmente `@compileError` para
  no Mac/Linux.

### L. Tests

- ~70+ sitios con `error.SkipZigTest` para Windows. Lista completa en el
  informe raw.
- `tests/e2e/*.test.ts` dependen de `tmuxAvailable()` — toda la suite TUI
  se salta si no hay tmux (en Windows no hay tmux nativo).

---

## 3. Archivos con código Windows-aware existente (ya parcial)

Patrón confirmado en el codebase:

| Archivo | Líneas | Qué hace |
| --- | --- | --- |
| `src/main.zig` | 3055–3132 | stdoutIsTerminal / writeStdoutFast / exitFast ya gaten en Windows. |
| `src/acp/prompt.zig` | 3812 | SkipZigTest. |
| `src/builtins/{skills,context,mcp}.zig` | varios | SkipZigTest. |
| `src/core/cli/cli_surface.zig` | 1929, 1936 | `writeRealStdout/Stderr` cae a `std.Io.File` en Windows. |
| `src/core/cli/doctor_runtime.zig` | 588, 636 | `fileExists`/`pathExists` usa `accessAbsolute` en Windows. |
| `src/core/background/background_runtime.zig` | 2815, 2860, 2939, 3017, 3064 | Background tasks son no-op en Windows. |
| `src/core/workspace/pathing.zig` | 1150, 1305, 1401, 2215 | Symlink tests skip. |
| `src/core/workspace/{workspace_files,file_index,grep_search,path_completion}.zig` | varios | SkipZigTest. |
| `src/core/execution/process_tree.zig` | 468, 482–734 | ProcessTreeUnsupported / unavailable. |
| `src/core/hosts/host.zig` | 245–253 | `nativeForOs(.windows)` devuelve capabilities degradadas. |
| `src/core/hosts/native_keychain.zig` | 35, 36 | isAvailable = macos. |
| `src/core/hosts/native.zig` | 175 | clipboard no-op en no-macOS. |
| `src/core/images/image_attachments.zig` | 344 | openat vs CreateFile. |
| `src/core/mcp/mcp_auth.zig` | 1000 | socket timeouts skip. |
| `src/core/permissions/sandbox.zig` | 2727 | resource limit false. |
| `src/core/session/session_store.zig` | 12472 | sync shortcut. |
| `src/core/shared/io.zig` | 214, 307, 401, 565, 891–950 | varias branches. |
| `src/core/skills/{skill_runtime,skill_invocation}.zig` | varios | SkipZigTest. |
| `src/core/terminal/shell_resolver.zig` | 106 | configuredLoginShellInto = null. |
| `src/core/upgrade/upgrade_helpers.zig` | 53–57 | platformFromTarget = null → @compileError. |
| `src/core/app/app_commands.zig` | 1770, 4164 | permissions / SkipZigTest. |
| `src/core/app/app_runtime_setup.zig` | 158 | SkipZigTest. |
| `src/core/auth/oauth_session.zig` | 1295 | SkipZigTest. |
| `src/core/session/session_child_store.zig` | 1285 | SkipZigTest. |
| `src/tools/filesystem/{copy,delete,rename,create_folder,list,glob,semantic}.zig` | varios | SkipZigTest. |
| `src/core/agent/runtime/tests/tool_flow.zig` | 5147, 5213 | SkipZigTest. |

---

## 4. Risk matrix — Top 10 blockers

| # | Severidad | Problema | Mitigación |
| --- | --- | --- | --- |
| 1 | Blocker | `tcgetattr`/`tcsetattr` en 6+ archivos | `core/shared/tty.zig` con backends `posix_tty.zig` y `windows_console.zig` (`GetConsoleMode`/`SetConsoleMode`). |
| 2 | Blocker | `posix_spawn`/`forkpty`/`ioctl` en `native_session.zig` | ConPTY en v2. La capability ya es `unsupported` para Windows. |
| 3 | Blocker | `sigaction(SIG.INT|TERM|HUP|WINCH|USR1)` en ~30 sitios | `core/shared/signal.zig` con `SetConsoleCtrlHandler`. |
| 4 | Blocker | Keychain macOS-only | Backend DPAPI + Credential Vault vía `wincred.h`. |
| 5 | Blocker | macOS Sandbox | v1: `os_sandbox = false` en Windows ya es el contrato. |
| 6 | Blocker | `kill(pid, sig)` y process groups | `core/shared/process_signal.zig`: `TerminateProcess` + `GenerateConsoleCtrlEvent`. |
| 7 | Blocker | Clipboard macOS-only | `windows_clipboard.zig` con `OpenClipboard`/`SetClipboardData`. |
| 8 | Blocker | Hardcoded `/bin/sh` en runtime | Reemplazar por PATH-resolved `sh`; dejar fixtures. |
| 9 | Blocker | `/tmp` en runtime (7 sitios) | `core/platform/temp_dir.zig` con `TMPDIR`/`TEMP`/`TMP`. |
| 10 | Blocker | `HOME` en ~30 sitios | `homeDir()` helper en `core/shared/io.zig`. |

**Menciones honoríficas:** `realpath` (Win32: `GetFullPathNameW`), `acp/jsonrpc.zig:312`
`std.posix.read` (Zig stdio), `tar -xzf` (ZIP nativo), `replaceBinary`
(`MoveFileExW(MOVEFILE_REPLACE_EXISTING)`).

---

## 5. Arquitectura recomendada

> **Decisión clave:** NO crear `src/platform/`. El codebase está organizado
> por feature (`execution`, `terminal`, `upgrade`, `permissions`, `hosts`).
> Un directorio paralelo forzaría imports circulares. Se respeta la
> organización existente.

### Nuevos archivos / extensiones

- **`src/core/shared/io.zig`** (extender):
  - `homeDir()` — `HOME` / `USERPROFILE` / `std.Io.homeDir`.
  - `tempDir()` — `TMPDIR` / `TEMP` / `TMP` / fallback.
  - `setPermissions(file, mode)` — Windows-aware.

- **`src/core/shared/signal.zig`** (nuevo):
  - `installHandlers`, `raiseInterrupt`, `terminateProcess(pid)`,
    `processGroupAlive`, `signalProcessGroup`.
  - Backends: `_posix.zig` y `_windows.zig` vía comptime switch.

- **`src/core/shared/tty.zig`** (nuevo):
  - `isatty`, `enableRawMode`, `restoreRawMode`, `winsize`.
  - Backends `_posix.zig` y `_windows.zig`.

- **`src/core/shared/process_signal.zig`** (nuevo):
  - `kill`, `killProcessGroup`, `pidAlive`.

- **`src/core/shared/process_tree.zig`** (nuevo):
  - Split de `core/execution/process_tree.zig` con backends
    `_posix.zig` (actual) y `_windows.zig` (`EnumProcesses`).

- **`src/core/hosts/native_keychain.zig`** (queda; se agregan):
  - `native_keychain_darwin.zig` (actual renombrado),
  - `native_keychain_windows.zig` (DPAPI + Credential Vault),
  - `native_keychain_other.zig` (profile_file fallback).
  - Dispatcher en `native_secret_store.zig:37`.

- **`src/core/hosts/native_windows_clipboard.zig`** (nuevo),
  **`src/core/hosts/native_windows_url.zig`** (nuevo, `ShellExecuteW`).

- **`src/core/terminal/native_session.zig`** (mantiene interfaz pública):
  - Internamente delega a `pty_posix.zig` (actual) y `pty_windows_conpty.zig` (v2).

- **`src/core/terminal/shell_resolver.zig`** (extender):
  - Kinds `pwsh` / `powershell` / `cmd`. `buildBootstrap` emite snippets
    PowerShell o cmd.

- **`src/core/upgrade/upgrade_helpers.zig`** (extender):
  - `platformFromTarget` incluye `windows-x86_64` / `windows-aarch64`.
  - `expandZip` (pure Zig) en lugar de `tar -xzf`.
  - `replaceBinary` con `MoveFileExW`.

### Convención de nombres

`<feature>_<os>.zig` con sufijos `_posix.zig`, `_windows.zig`, `_darwin.zig`,
`_linux.zig`. Headers públicos exponen una función comptime-dispatched.

### Lo que NO se mueve

`src/main.zig`, `src/acp/`, `src/tools/`, `src/builtins/`, `src/ui/`,
`src/gateway/`, `src/wasm_*.zig`, `src/napi_*.zig`, `src/mcp_test_exports.zig`
— ninguno debe tomar condicionales de OS más allá de los que ya tiene.
Consumen las abstracciones.

---

## 6. Orden de implementación sugerido

Cada paso es un PR chico y revisable.

1. **Foundation: paths, env, temp.** Helpers en `core/shared/io.zig`. Reemplazar
   `getenv("HOME")` y `TMPDIR orelse "/tmp"` en runtime. Compilar
   `x86_64-windows` ReleaseSafe. **~30 archivos, cambios chicos.**
2. **SkipZigTest explícito** en sitios POSIX-only.
3. **Build nativo Windows + smoke `fx --version`.** Smoke job en CI con
   `windows-2022`.
4. **CI Windows** (build + `zig build test` + subset Bun CLI sin tmux).
5. **TTY abstraction (`core/shared/tty.zig`).** Reemplaza `MaskedKeyRawMode`
   y `TerminalState.enableRawMode`. **Necesario para password prompts e
   interactive runtime.**
6. **Process spawning on Windows.** Verificar `std.process.spawn` con
   argv resolvable vía PATH (`git.exe`, `node.exe`).
7. **MCP path resolution.** `commandInPath` ya casi lo hace.
8. **Signal abstraction (`core/shared/signal.zig`).**
   `SetConsoleCtrlHandler` para SIGINT/SIGTERM/SIGHUP.
9. **Doctor / startup degradation.** Confirmar que `doctor_runtime.zig`
   resuelve `git`, `node`, etc. en Windows.
10. **Self-upgrade.** ZIP + `MoveFileExW`.
11. **Native hosts:** clipboard, URL opener, notifications. Keychain Windows.
12. **v2 opcional:** ConPTY para terminal session. (Deferible.)
13. **v2 opcional:** Process tree con `NtQuerySystemInformation`.
14. **Installer `setup.ps1`.** Espejo de `setup.sh`.
15. **Release artefacto:** `windows-x86_64` y `windows-aarch64` en
    `release.yml`, emitir `.zip`.
16. **Docs + cleanup** de `WINDOWS_SUPPORT_PLAN.md` /
    `WINDOWS_SUPPORT_ANALYSIS.md` antes del PR.

---

## 7. Notas para el usuario

- **No hay PRs abiertos ni mergeados sobre Windows** en upstream.
- **Issue #254 abierto HOY** ("Have anyone tried building it on windows?")
  por `mojtabaasadi`, 0 comentarios, sin asignar. Es el lugar natural para
  coordinar antes de empezar a tirar código.
- v1 realista = `fx` corre con terminal/sandbox/url/keychain/audio
  degradados. Eso ya está alineado con `host.capabilitiesForTarget(.windows)`.
- El PR más chico posible (pasos 1–4) ya destraba
  `zig build -Dtarget=x86_64-windows` y un smoke `fx --version`.

---

## 8. Apéndice: paths de runtime a `/tmp` (blockers)

```text
src/core/upgrade/upgrade_runtime.zig:192
src/core/upgrade/auto_upgrade.zig:211
src/core/background/background_launch_output.zig:121
src/core/notifications/sound.zig:46
src/core/workspace/record_tape.zig:116
src/core/permissions/sandbox.zig:1937
src/core/app/app_commands.zig:1777
```

Los `/tmp/...` que aparecen en `src/main.zig`, `src/acp/prompt.zig`,
`src/builtins/{context,skills,mcp}.zig`, `src/core/cli/cli_surface.zig` y
muchos otros son **fixtures de tests** y pueden quedarse tal cual —
`std.testing.tmpDir` los abstrae.
