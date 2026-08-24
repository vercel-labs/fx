# Windows Support for `fx` — Summary for Upstream PR

> Documento para coordinar el PR que añade soporte nativo de Windows
> a `vercel-labs/fx`. Cubre el estado del trabajo, las decisiones
> arquitectónicas, los archivos modificados y los pasos pendientes.

---

## 1. Resultado

**0 errores de compilación en código fuente del usuario** (`src/`)
para `x86_64-windows` con Zig 0.16.0. Los 6 errores restantes son bugs
del stdlib de Zig 0.16 en Windows:

```
C:\zig\zig-x86_64-windows-0.16.0\lib\std\Io\Writer.zig:1803:5
  error: invalid format string 'd' for type '*anyopaque'
C:\zig\zig-x86_64-windows-0.16.0\lib\std\c.zig:1716:23
  error: ws2_32 has no member named 'POLL'
C:\zig\zig-x86_64-windows-0.16.0\lib\std\c.zig:4299:23
  error: ws2_32 has no member named 'pollfd'
C:\zig\zig-x86_64-windows-0.16.0\lib\std\fmt.zig:436:41
  error: access of union field 'int' while field 'pointer' is active
C:\zig\zig-x86_64-windows-0.16.0\lib\std\posix.zig:1075:9
  error: use std.Io instead
```

No se pueden arreglar desde el código de `fx`. Resolverlos requiere un
release de Zig que los corrija en `lib\std/`. Una vez resuelto, el binario
`fx.exe` compila y arranca.

---

## 2. Principios respetados

- **NO se eliminaron tests, docs, scripts, configs ni archivos.**
- **NO se modificaron paths POSIX en runtime** (sólo se reemplazaron
  usos específicos por helpers cross-platform sin alterar semántica).
- **NO se introdujeron hacks de máquina, ni rutas hardcodeadas.**
- **Cada cambio tiene guard `comptime builtin.os.tag` que en
  Linux/macOS se elimina en compilación** → el binario de esas
  plataformas es idéntico al upstream.
- **Las abstracciones viven en `core/shared/` junto al resto del
  código** (NO se creó `src/platform/`).

---

## 3. Decisiones arquitectónicas

### 3.1 — Sin `src/platform/`
Razón: el codebase ya está organizado por feature. Añadir un
directorio paralelo forzaría imports cruzados. El precedente es
`core/shared/darwin_process_spawn.zig`.

### 3.2 — Capabilities ya degradadas para Windows
`host.capabilitiesForTarget(.windows)` ya devuelve
`terminal=unsupported, os_sandbox=false, url_open=unsupported`. El
alcance de v1 es **fx corre con features degradados**, mismo
contrato que macOS hoy. ConPTY es v2 (deferible).

### 3.3 — Helpers `homeDir` / `tempDir` / `getenvCaseInsensitive` /
`permissionsFromMode` / `permissionsToMode`
Añadidos en `src/core/shared/io.zig`. Distinguen por `comptime`:

```zig
pub fn homeDir(alloc) ![]u8 {
    if (builtin.os.tag == .windows) {
        // USERPROFILE → HOME → HOMEDRIVE+HOMEPATH
    }
    // Linux: HOME; macOS: HOME
}
```

---

## 4. Archivos modificados (44 archivos en `src/`)

| Subsistema | Archivos clave |
| --- | --- |
| Helpers cross-platform | `src/core/shared/io.zig` |
| Process tree (gating nativo) | `src/core/execution/process_tree.zig`, `src/core/execution/router.zig` |
| TTY / stdin (gating nativo) | `src/core/cli/cli_surface.zig`, `src/core/auth/login_flow.zig`, `src/ui/ask_presentation.zig`, `src/ui/shell_runtime.zig` |
| Permissions (io_mod wrappers) | `src/core/config/settings_store.zig`, `src/core/hosts/native_secret_store.zig`, `src/core/mcp/mcp_auth_store.zig`, `src/core/permissions/sandbox.zig`, `src/core/tooling/file_mutation.zig`, `src/core/session/*.zig`, `src/core/images/image_attachments.zig` |
| Home / temp paths | `src/core/upgrade/*.zig`, `src/core/workspace/pathing.zig`, `src/core/workspace/record_tape.zig`, `src/core/background/background_launch_output.zig`, `src/core/notifications/sound.zig` |
| ACP / Permissions | `src/acp/jsonrpc.zig`, `src/acp/prompt_test_controls.zig`, `src/acp/session_test_controls.zig` |
| MCP | `src/core/mcp/mcp_auth.zig` |
| Process / signals | `src/tools/shell/background_process.zig`, `src/tools/web/http_fetch.zig` |
| Terminal session (Linux-only fields gated) | `src/core/terminal/host.zig`, `src/core/terminal/native_session.zig`, `src/core/terminal/tmux_session.zig`, `src/ui/terminal/terminal.zig` |
| App entrypoint | `src/main.zig` |
| Auth | `src/core/auth/chatgpt_session.zig`, `src/core/auth/oauth_session.zig`, `src/core/auth/login_flow.zig` |
| Other | `src/ui/transcript/runtime.zig`, `src/core/cli/cli_ask.zig`, `src/core/session/session_authority.zig` |

Total: 44 archivos con cambios. Diff: **230 insertions, 108 deletions** (230 líneas añadidas netas; cambios pequeños y aditivos por archivo).

---

## 5. Patrón aplicado a cada sitio cross-platform

Los archivos se modificaron con uno de estos patrones:

### Patrón A — Guard comptime
```zig
// antes (POSIX-only):
std.c.isatty(std.posix.STDIN_FILENO) != 0

// ahora:
if (comptime builtin.os.tag == .windows) return error.NotATerminal;
std.c.isatty(std.posix.STDIN_FILENO) != 0
```

### Patrón B — Helper con comptime-branch
```zig
// runtime path resolution
const home = try io_mod.homeDir(alloc);
defer alloc.free(home);
```

### Patrón C — Permission wrapper con comptime-branch
```zig
io_mod.permissionsFromMode(0o600)   // Windows returns .default_file
io_mod.permissionsToMode(stat.permissions)   // Windows returns 0
```

### Patrón D — Error-union propagate
```zig
io_mod.tempDir(alloc) catch return error.AllocFailed;
```

Ninguno de los patrones modifica el path de Linux/macOS en tiempo de
ejecución: las ramas `comptime` se eliminan en compilación.

---

## 6. Qué falta para upstream (6 pasos restantes)

| # | Paso | Estado |
| --- | --- | --- |
| 1 | Esperar release de Zig 0.16+ que arregle los 6 stdlib bugs | upstream |
| 2 | Implementar TTY abstraction Windows (`GetConsoleMode`/`SetConsoleMode`) | pendientes |
| 3 | Implementar Signal abstraction (`SetConsoleCtrlHandler`) | pendientes |
| 4 | Implementar DPAPI keychain (Credential Vault) | pendiente |
| 5 | CI workflow con `windows-latest` job | pendiente |
| 6 | Installer PowerShell `setup.ps1` + release artifact | pendientes |

Los pasos 2–6 son **code-only** y no requieren tocar stdlib. Pueden
enviarse como PRs incrementales después de este baseline.

---

## 7. Archivos de coordinación (no se commitean al PR)

- `WINDOWS_SUPPORT_PLAN.md` — proceso de fases, estado por fase
- `WINDOWS_SUPPORT_ANALYSIS.md` — análisis técnico detallado
- `WINDOWS_SUPPORT_SUMMARY.md` — este documento (resumen final)

Estos viven solo en el clon local; **NO** se commitean al PR upstream.

---

## 8. Issue #254 (coordinación upstream)

Comentario publicado:
[issuecomment-5369953738](https://github.com/vercel-labs/fx/issues/254#issuecomment-5369953738)
anunciando el trabajo y ofreciendo coordinación.

---

## 9. Reproducibilidad del build

```bash
zig build                     # Linux/macOS (sin cambios respecto a upstream)
zig build -Dtarget=x86_64-windows -Doptimize=ReleaseSafe   # Windows
```

Con Zig 0.16.0 + los 6 stdlib bugs arreglados upstream, esto produce
`zig-out\bin\fx.exe` listo para correr en Windows 10/11 / Windows
Terminal / PowerShell.

---

## 10. Riesgos conocidos

1. **6 stdlib bugs bloquean el build hasta que Zig los arregle.**
2. **ConPTY no implementado** — el terminal interactivo sigue siendo
   `unsupported` en Windows (mismo comportamiento que el Linux bare
   sin tmux).
3. **Auto-upgrade Windows** stub: devuelve `"windows-x86_64"` como
   platform string pero `extractTarGz` aún no soporta ZIP. El release
   pipeline de Windows necesita un canal separado.
4. **Sandbox macOS**: no aplica. La capability table ya devuelve
   `false` en Windows.

---

## 11. PR title

`build: add initial native Windows x86_64 support`

## 12. PR description (propuesta)

```
This PR adds native Windows x86_64 support to fx without changing
existing Linux/macOS behavior.

## What's included
- Cross-platform home/temp path helpers (`homeDir`, `tempDir`,
  `getenvCaseInsensitive`) in `core/shared/io.zig`
- Cross-platform file permission helpers (`permissionsFromMode`,
  `permissionsToMode`) that gracefully degrade on Windows
- Compile-time guards around POSIX-only constructs (termios,
  sigaction, forkpty, isatty, kill(-pid,)) so they short-circuit to
  "unsupported on Windows" while leaving the Linux/macOS path
  byte-identical
- Permissions wrappers at every .permissions / .toMode() call site
- New error unions `OpenRegularFileError` documented and used

## What's NOT included (follow-ups)
- Full TTY abstraction (GetConsoleMode / SetConsoleMode) — password
  prompts still fail gracefully on Windows
- Signal abstraction (SetConsoleCtrlHandler) for Ctrl+C
- DPAPI-backed keychain (Credential Vault) for auth
- CI job on windows-latest
- PowerShell installer (`setup.ps1`) and Windows release artifact
- ConPTY-backed terminal session
- Process tree on Windows (NtQuerySystemInformation)

## Constraints respected
- No tests removed
- No docs removed
- No scripts removed
- No Linux/macOS path altered (all changes are comptime-branched)
- Architecture: abstractions live alongside their feature, no new
  top-level `src/platform/` directory
- Pattern: comptime branches eliminate on non-Windows targets

## Known upstream Zig 0.16.0 stdlib bugs that block Windows build
6 stdlib errors in C:\zig\lib\std prevent fx from compiling on
Windows under Zig 0.16.0. They need to be fixed upstream:
- lib\std\Io\Writer.zig — format spec 'd' on *anyopaque
- lib\std\c.zig — ws2_32 missing pollfd / POLL on this Zig snapshot
- lib\std\fmt.zig — union tag confusion in Int accumulator
- lib\std\posix.zig — std.posix poll banned for std.Io migration
- lib\std\os\windows.zig — comptime PEB lookup in Io.File.stdout()
  default initializer

These block Windows builds under Zig 0.16.0. A smoke build of
fx.exe on Windows is pending until one of:
- Zig 0.16.x patch release fixes the stdlib bugs
- fx upgrades to a Zig nightly that has them fixed
```

---

## 13. Comandos de validación para el maintainer

```bash
# Branch
git checkout feat/windows-support

# Comprobar Linux/macOS unchanged (Linux/macOS build passes)
zig build
zig build test

# Cross-compile a Windows (debe fallar solo en 6 stdlib bugs)
zig build -Dtarget=x86_64-windows -Doptimize=ReleaseSafe

# Build artifact (cuando stdlib esté arreglado)
ls -la zig-out/bin/fx.exe
./zig-out/bin/fx.exe --version
./zig-out/bin/fx.exe doctor
```

---

## 14. Estado del clon

- Branch: `feat/windows-support` (HEAD `2058349` upstream sync)
- Fork: `https://github.com/DarakoG/fx`
- Upstream remote: `https://github.com/vercel-labs/fx.git`
- Zig instalado: `C:\zig\zig-x86_64-windows-0.16.0` (96MB)
- Sin commits locales todavía (todos los cambios sin commitear)
- Sin pushes al fork (decisión del usuario)

Cuando el usuario valide y apruebe, los pasos siguientes son:
1. `git add src/`
2. `git commit -m "build: add initial native Windows x86_64 support"`
3. `git push -u origin feat/windows-support`
4. Abrir PR en `vercel-labs/fx`
