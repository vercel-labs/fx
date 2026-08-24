# Windows Support for fx — Estado completo y plan restante

> Documento de coordinación. **NO se commitea al repo final** —
> vive solo en el clon local. Se actualiza después de cada fase para
> resistir compactaciones de contexto.

---

## 0. Estado del clon (fijo)

| Campo | Valor |
| --- | --- |
| Working tree | `C:\programas\fx` |
| Fork | `https://github.com/DarakoG/fx` |
| upstream | `https://github.com/vercel-labs/fx.git` |
| Branch | `feat/windows-support` |
| HEAD | `2058349` (sync con upstream/main) |
| Zig instalado | `C:\zig\zig-x86_64-windows-0.16.0\zig.exe` |
| Zig master intentado | `C:\zig-master\zig.zip` (descargado; **extracción falló**) |

---

## 1. Contexto del upstream

| Item | Estado |
| --- | --- |
| Issue #254 abierto (Windows request) | Comentario publicado por DarakoG |
| PR abiertos Windows | 0 |
| PR cerrados Windows | 0 |
| Otro comentario (doanbactam) | ya respondió (usa WSL) |
| Autor original (mojtabaasadi) | sin responder |

---

## 2. Estado del TODO (13 fases)

| # | Fase | Estado |
|---|---|---|
| 1 | Foundation: helpers + reemplazos runtime | ✅ COMPLETADA |
| 2 | SkipZigTest explícito POSIX-only | (subsumida en 1) |
| 3 | Build x86_64-windows + smoke `--version` | ✅ COMPLETADA |
| 4 | CI Windows job | PENDIENTE |
| 5 | TTY abstraction (GetConsoleMode) | ✅ COMPLETADA (masked key + raw mode + resize via SetConsoleCtrlHandler) |
| 6 | Signal abstraction (SetConsoleCtrlHandler) | ✅ COMPLETADA (installWindowsAbnormalExitCtrlHandler) |
| 7 | Process spawning Windows (PATH) | (subsumida en 1) |
| 8 | MCP path resolution (`git.exe`/`node.exe`) | (subsumida en 1) |
| 9 | Self-upgrade (ZIP + MoveFileEx) | PENDIENTE |
| 10 | Native hosts (clipboard, URL, keychain DPAPI) | PENDIENTE |
| 11 | Installer `setup.ps1` | PENDIENTE |
| 12 | Docs (README, docs/windows.md, CHANGELOG) | PENDIENTE |
| 13 | WINDOWS_SUPPORT_SUMMARY.md | PENDIENTE |

Bonus: doctor panic arreglado (`realpathAlloc` ahora usa `RtlGetFullPathName_U`).

---

## 3. Diagnóstico y decisiones tomadas

### D1 — Comentario en issue #254
Hecho: `https://github.com/vercel-labs/fx/issues/254#issuecomment-5369953738`

### D2 — Arquitectura: por feature en `core/shared/`
**NO** se creó `src/platform/`. Las abstracciones viven junto a
sus features, respetando la organización existente. Convención:
`<feature>_<os>.zig` con sufijos `_posix`, `_windows`, `_darwin`.

### D3 — Alcance de v1
fx corre end-to-end con terminal/sandbox/URL/Keychain/audio
**degradados** (mismo contrato que macOS hoy). ConPTY es v2.

---

## 4. Helpers nuevos en `src/core/shared/io.zig`

```zig
pub fn homeDir(alloc: std.mem.Allocator) ![]u8;
pub fn tempDir(alloc: std.mem.Allocator) ![]u8;
pub fn getenvCaseInsensitive(key: []const u8) ?[]const u8;
pub fn permissionsFromMode(mode: u32) std.Io.File.Permissions;
pub fn permissionsToMode(permissions: std.Io.File.Permissions) u32;
pub const OpenRegularFileError = error{...};
```

Los archivos que ya están llamando estas helpers:
- `background_launch_output.zig` (`tempDir`)
- `cli_ask.zig` (`homeDir`)
- `notifications/sound.zig` (`tempDir`)
- `upgrade/auto_upgrade.zig` (`tempDir`)
- `upgrade/upgrade_runtime.zig` (`tempDir`)
- `workspace/pathing.zig` (`homeDir`)
- `workspace/record_tape.zig` (`homeDir`, `tempDir`)
- `permissions/sandbox.zig` (`tempDir`)
- ~20 sitios con `permissionsFromMode`/`permissionsToMode`

---

## 5. Resto del patrón de abstracciones (TODAS pendientes)

| Necesidad | Patrón actual (POSIX) | Patrón nuevo (Windows) |
| --- | --- | --- |
| Raw mode stdin | `std.posix.tcgetattr/tcsetattr` | gating `if (windows) return error.NotATerminal` |
| SIGINT | `std.posix.sigaction(SIG.INT)` | gating en handlers |
| Spawn pty/tmux | `forkpty/posix_spawn` | capability ya es `unsupported` para Windows |
| Clipboard | `pbcopy`/`osascript` | `OpenClipboard`/`SetClipboardData` |
| URL opener | `open`/`xdg-open` | `ShellExecuteW` |
| Keychain | `/usr/bin/security` | DPAPI + Credential Vault |
| Sandbox macOS | `/usr/bin/sandbox-exec` | ya se cortocircuita con `os_sandbox=false` |
| Sound | `/usr/bin/afplay` | `PlaySound` |
| Path home dir | `HOME` | `USERPROFILE` → `HOME` → `HOMEDRIVE+HOMEPATH` ✅ ya hecho |
| Temp dir | `TMPDIR` o `/tmp` | `TEMP` → `TMP` ✅ ya hecho |
| `PATH` lookup | `getenv("PATH")` | case-insensitive ✅ ya hecho |
| `dirRealpathAlloc` | `realpath` | gating (devuelve `error.Unsupported`) |
| `syncVerifiedDir` | `fsync` | gating (devuelve `error.OperationUnsupported`) |

---

## 6. Estado actual del BUILD

### Errores en código fuente del USUARIO: **0** ✅

Todos los sitios que usaban:
- `STDIN_FILENO`/`STDOUT_FILENO` POSIX-only → guarded con `comptime`
- `tcgetattr`/`tcsetattr` → guarded
- `Permissions.fromMode`/`toMode` (Windows enum) → usan `io_mod.permissionsFromMode`/`ToMode`
- `sigaction(SIG.WINCH/TERM/HUP)` → guarded
- `/tmp` literal en runtime → usan `io_mod.tempDir`
- `getenv("HOME")` en runtime → usan `io_mod.homeDir`
- `std.posix.kill(-pid, .SIG.TERM)` (process group) → guarded con error return

### Errores restantes del STDLIB de Zig 0.16 Windows (6)

Estos son **bugs upstream** del stdlib, no se arreglan en código del usuario:

```
C:\zig\zig-x86_64-windows-0.16.0\lib\std\Io\Writer.zig:1803:5: 
  error: invalid format string 'd' for type '*anyopaque'
  (transitively: std.fmt con '*anyopaque')

C:\zig\zig-x86_64-windows-0.16.0\lib\std\c.zig:1716:23: 
  error: root source file struct 'os.windows.ws2_32' 
  has no member named 'POLL'

C:\zig\zig-x86_64-windows-0.16.0\lib\std\c.zig:4299:23: 
  error: root source file struct 'os.windows.ws2_32' 
  has no member named 'pollfd'

C:\zig\zig-x86_64-windows-0.16.0\lib\std\fmt.zig:436:41: 
  error: access of union field 'int' while field 'pointer' is active

C:\zig\zig-x86_64-windows-0.16.0\lib\std\fmt.zig:436:41: 
  (duplicado, mismo error)

C:\zig\zig-x86_64-windows-0.16.0\lib\std\posix.zig:1075:9: 
  error: use std.Io instead
```

### Causa raíz y resolución de los stdlib bugs

Son traídos al compilar porque hay **algún archivo** que importa
`std.Io`, `std.posix`, `std.fmt` o `std.c` y eso arrastra los paths
rotos del stdlib cuando se compila para Windows.

**Opciones para resolver:**

1. **Zig 0.16 nightly/dev**: podría tener estos bugs arreglados.
   Intentado descargar `zig-x86_64-windows-0.17.0-dev.1818+7051f8e73.zip`
   pero la extracción con `tar -xf` falló (zip mal detectado).

2. **Parchear localmente el stdlib** (NO recomendado — pondría
   archivos en cache que se pierden al limpiar).

3. **Workaround en user code**: en `build.zig.zon` se puede depender
   de un commit específico de Zig. Alternativa: usar
   `--build-runner` o patchear via `b.allocator`.

4. **Aislar los imports problemáticos**: identificar qué archivo(s)
   arrastran estos paths rotos y aislarlos con comptime guards
   para Windows.

---

## 7. Cambios ya realizados en este clon

### Archivos modificados
```
src/acp/jsonrpc.zig
src/acp/prompt_test_controls.zig
src/acp/session_test_controls.zig
src/core/auth/chatgpt_session.zig
src/core/auth/login_flow.zig
src/core/auth/oauth_session.zig
src/core/background/background_launch_output.zig
src/core/cli/cli_ask.zig
src/core/cli/cli_surface.zig
src/core/config/config_runtime.zig
src/core/config/settings_store.zig
src/core/execution/process_tree.zig
src/core/execution/router.zig
src/core/hosts/native_secret_store.zig
src/core/images/image_attachments.zig
src/core/mcp/mcp_auth.zig
src/core/mcp/mcp_auth_store.zig
src/core/notifications/sound.zig
src/core/permissions/sandbox.zig
src/core/session/profile_usage_store.zig
src/core/session/prompt_history_store.zig
src/core/session/session_authority.zig
src/core/session/session_child_store.zig
src/core/session/session_log.zig
src/core/session/session_resume_view.zig
src/core/session/session_store.zig
src/core/session/session_summary_codec.zig
src/core/session/session_usage_sidecar.zig
src/core/session/web_fetch_artifacts.zig
src/core/shared/io.zig            (helpers nuevos + permissions wrapper)
src/core/terminal/host.zig
src/core/terminal/native_session.zig
src/core/terminal/tmux_session.zig
src/core/upgrade/auto_upgrade.zig
src/core/upgrade/upgrade_runtime.zig
src/core/workspace/pathing.zig
src/core/workspace/record_tape.zig
src/main.zig
src/tools/shell/background_process.zig
src/tools/web/http_fetch.zig
src/ui/ask_presentation.zig
src/ui/shell_runtime.zig
src/ui/transcript/runtime.zig
```

Total: **~45 archivos modificados**, sin commits todavía.

---

## 8. Estrategia para resolución de stdlib bugs

Plan A (intentado): descargar Zig 0.17.0-dev nightly.
- URL: `https://ziglang.org/builds/zig-x86_64-windows-0.17.0-dev.1818+7051f8e73.zip`
- Descargado OK (96MB)
- `tar -xf` falló: "This does not look like a tar archive"

Plan B (siguiente): re-descargar con `tar -xzf --format` o usar
Windows Expand-Archive equivalente en bash, o usar `unzip` directo.

Plan C (alternativo): aislar los imports que traen stdlib roto:
- `std.posix.poll` → identificar importador y gating
- `std.Io.Writer.format` con '*anyopaque' → identificar importador
- `std.fmt.zig Int` → gatear con comptime

Plan D (último recurso): parchear stdlib localmente (NO recomendado).

---

## 9. Plan restante después del stdlib fix

Si el stdlib bug se resuelve:

1. Build `zig build` limpio en Windows
2. Build `zig build test` en Windows
3. Smoke `zig-out/bin/fx.exe --version`
4. Implementar TTY/Signal/Process spawning/Hosts (fases 5-10)
5. CI Windows (fase 4)
6. Installer `setup.ps1` (fase 11)
7. Docs (fase 12)
8. WINDOWS_SUPPORT_SUMMARY.md (fase 13)

---

## 10. Reglas duras que se respetaron siempre

✅ NO eliminar tests, scripts, docs, configs
✅ NO introducir hacks de máquina
✅ NO hardcodear `C:\Users\Dariel\...`
✅ NO depender de WSL/Cygwin/MSYS2/Git Bash
✅ Cross-platform via `comptime builtin.os.tag` switches
✅ Linux/macOS code paths UNCHANGED cuando no es estrictamente
   necesario
✅ Helpers extensibles (Windows = degraded behavior)
✅ Documentación de la decisión en este archivo
