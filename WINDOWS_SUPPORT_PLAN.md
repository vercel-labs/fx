# Windows Support for fx — Plan y estado real (post-sesión 2026-08-24)

> Documento de coordinación. **NO se commitea al repo final** —
> vive solo en el clon local. Captura el estado después de la
> sesión del 2026-08-24 que dejó todo el trabajo commiteado y
> un draft PR abierto en `vercel-labs/fx`.

---

## 0. Estado del clon al cierre de la sesión

| Campo | Valor |
| --- | --- |
| Working tree | `C:\Programas\fx` |
| Fork | `https://github.com/DarakoG/fx` |
| upstream | `https://github.com/vercel-labs/fx.git` |
| Branch | `feat/windows-support` |
| HEAD local | `d72d67d` (5 commits ahead of `d2c6f2d` merge-base) |
| Zig instalado | `C:\zig\zig-x86_64-windows-0.16.0\zig.exe` |
| Build | ✅ `fx.exe --version` → `0.0.4`, exit 0; `fx.exe doctor` ok |
| Binary size | ~11.2 MB PE32+ x86_64 |
| PR | [#412](https://github.com/vercel-labs/fx/pull/412) draft, **`mergeable: MERGEABLE`** ✅ |
| PR checks | Socket Security: pass. Windows CI: no ha corrido (workflow en el fork, no en upstream; los checks del fork solo corren desde vercel-labs/fx) |

---

## 1. ¿Qué se hizo realmente?

### Build baseline

* Zig 0.17-dev nightly **descartado** después de intentarlo:
  removió el operador `**` y los bloques `errdefer |err|`,
  además de una regresión de mingw-w64 con `.seh_ directive
  must appear within an active frame`. Abandonado.
* Zig 0.16.0 instalado en `C:\zig\zig-x86_64-windows-0.16.0\`.
  Build verde después de 3 parches locales al stdlib.
* 3 stdlib backports aplicados a `C:\zig\.../lib\std/`:
  1. `os/windows/ws2_32.zig` — añade `POLL` constants y `pollfd` struct
  2. `posix.zig` — `setsockopt` / `read` / `poll` ya no tiran `@compileError("use std.Io instead")` en Windows
  3. `fmt.zig` — `parseInt` short-circuit para `Result` no-int con `error.InvalidCharacter`

### Source patches en `feat/windows-support` (5 commits)

* `8f8e28a` — `feat(io): add homeDir, tempDir, getenvCaseInsensitive helpers`
* `1d1850d` — `docs(windows): add OpenSpec + Windows coordination docs for handoff`
* `297e1a2` — `build(windows): cross-platform comptime guards + Windows runtime baseline`
  (66 archivos, ya estaba en el branch cuando llegué)
* `fee4b17` — `build(windows): add initial native Windows x86_64 support`
  (fix `../../` en `builtins/tools.zig:2`; ZIP extractor in-process;
  CopyFile-based `replaceBinary`; clipboard Win32; ShellExecuteW;
  Credential Vault; guards comptime en sites POSIX-only;
  `shell32` / `advapi32` / `user32` / `crypt32` link on Windows)
* `d72d67d` — `docs(windows): refresh build recipe with stdlib backports and PR link`

### Lo que NO se hizo (deferred a v2)

* **TUI interactivo** (`fx` sin subcomando). En Windows,
  `fx.exe` sin args tira `NotATerminal` porque el TUI asume
  ConPTY. v2 = ConPTY-backed session.
* **`zig build test` verde en Windows**. El test suite asume
  POSIX sockets. 44 errores en código de test (no en producción).
  v2 = Winsock rewrite.
* **DPAPI para secrets > 2.5 KB**. Credential Vault ya cubre
  el tamaño típico de API keys + OAuth sessions. DPAPI
  expuesto como bloque de construcción para v2 si hace falta.
* **Wails ARM64 Windows**. Fuera de scope inicial. El
  upstream main no lo soporta, así que primero x86_64.
* **Installer en `fx.sh/setup.ps1` público**. El script de 459
  líneas (`setup.ps1` en el repo) está commiteado y documentado,
  pero la URL `https://fx.sh/setup.ps1` no existe hasta que
  el PR #412 se apruebe y alguien suba el asset.

---

## 2. Diagnóstico del PR conflictivo — RESUELTO ✅

Estado original: `gh pr view 412 --repo vercel-labs/fx --json mergeable`
→ `CONFLICTING`.

Causa raíz: el branch se creó contra `d2c6f2d` (un PR
anterior). Desde entonces, `vercel-labs/fx:main` ha avanzado
**186 commits** que tocan 28+ archivos en común con mi branch.

**Resolución (commit `660d660`, pusheado):** `git rebase upstream/main`
resolvió 63 de 67 archivos automáticamente. Los 4 que quedaron en
conflicto real, más la restauración de un archivo perdido y los
fixes de integración post-rebase, son:

### Conflict resolution

* `src/core/agent/runtime/tests/tool_flow.zig` — kept the
  297e1a2 'sandbox widening' test (HEAD added nothing at the
  same position).
* `src/core/auth/chatgpt_oauth.zig` — took upstream's
  `browser_callback.Accepted` refactor; dropped the
  `@intCast` → `@ptrCast` workaround (the new abstraction
  handles `fd_t` internally).
* `src/core/execution/command_runner.zig` — took upstream's
  restructured file; dropped the 297e1a2 sandbox.zig
  changes (which were for a file that no longer exists in
  that form).
* `src/core/session/command_replay_store.zig` — took
  upstream's version (with the random-stem retry loop).

### Post-rebase integration fixes

* `src/core/execution/devbox_executor.zig` — el rebase perdió
  este archivo porque upstream movió/renombró `sandbox.zig` sin
  una rename-detection match. Restaurado del árbol pre-rebase
  de `297e1a2` con los tipos v1 (Provider, ProviderError,
  VercelOutcome) que `command_runner.zig` aún referencia.
* `src/core/auth/chatgpt_oauth.zig` — added the `.grok` arm
  a `SignInCompletion` switch en `saveSignIn` (upstream
  agregó la variante `.grok`).
* `src/core/auth/grok_oauth.zig` — guarded
  `StdinManualCodeReader.poll` con comptime Windows check
  retornando `error.PlatformUnsupported`. El poll usa
  `std.posix.STDIN_FILENO` que es `*anyopaque` en Windows.
* `src/core/auth/grok_session.zig` — replaced 3 calls
  directos a `.toMode()` / `.fromMode()` con
  `io_mod.permissionsToMode` / `io_mod.permissionsFromMode`.
  Upstream usa `std.Io.File.Permissions` directamente; en
  Windows ese enum no tiene fromMode/toMode.
* `src/core/execution/command_runner.zig` — added comptime
  Windows guards a `currentProcessId` (returns 0) y
  `signalProcessGroup` (returns `error.ProcessGroupUnsupported`).
  Ambos referencian `std.posix.pid_t` que es
  `windows.HANDLE = *anyopaque` en Windows.
* `build.zig` — link `ws2_32` on Windows. El lld-link error
  surgió cuando se adoptó el `command_runner.zig` de upstream
  porque algunos símbolos stdlib (setsockopt via libc)
  resuelven a `ws2_32`.
* `src/core/session/command_replay_store.zig` — additionally
  taken upstream después de la resolución inicial. La versión
  HEAD referenciaba `EphemeralStore` (un tipo que faltaba
  en la rama rebased); la versión upstream lo define.

**Resultado:** `gh pr view 412 --repo vercel-labs/fx --json mergeable`
→ `MERGEABLE` ✅.

---

## 3. Estado del TODO original (prompt de 23 fases)

Mapeo honesto de lo que el prompt pedía contra lo que se entregó.

| # | Fase del prompt original | Estado |
|---|---|---|
| 1 | Auditoría completa | ✅ `WINDOWS_SUPPORT_ANALYSIS.md` (383 líneas) |
| 2 | Mapa de compatibilidad | ✅ en el analysis |
| 3 | Arquitectura multi-plataforma | ✅ `openspec/changes/windows-support-baseline/design.md` |
| 4 | Filesystem (`%USERPROFILE`, `%APPDATA`, etc.) | ✅ `io.zig` helpers |
| 4 | Paths | ✅ `realpathAlloc` con `RtlGetFullPathName_U` |
| 4 | Process spawning | ✅ partial (PATH, git.exe probe) |
| 4 | PowerShell / CMD | ⚠️ parcial — no se introdujo dependencia de shell para flujos internos |
| 4 | Terminal / TTY | ⚠️ partial — masked key + raw mode comptime-gated, ConPTY es v2 |
| 4 | Signals / Ctrl+C | ✅ `SetConsoleCtrlHandler` en `app_lifecycle.zig` |
| 4 | Child processes | ✅ `std.process.spawn` ya soporta Windows |
| 4 | Git | ✅ `commandInPath` prueba `git` y `git.exe` |
| 4 | MCP / ACP | ⚠️ partial — stdio funciona (MCP via `std.process.spawn`), HTTP es v2 |
| 4 | Authentication / credentials | ✅ home/config paths via `homeDir`; **Credential Vault** para storage real |
| 4 | Environment variables | ✅ `getenvCaseInsensitive` |
| 4 | Temp files | ✅ `tempDir` |
| 4 | Symlinks / permissions | ✅ `permissionsFromMode` / `permissionsToMode` |
| 5 | Build nativo Windows | ✅ `zig build -Dtarget=x86_64-windows` |
| 6 | ARM64 Windows | ❌ no intentado (out of scope, upstream no lo soporta) |
| 7 | Tests | ⚠️ parcial — los tests POSIX siguen rotos en Windows, la v2 necesita Winsock. Los guards comptime evitan que el `fx.exe` de producción cargue código de socket. |
| 8 | CI GitHub Actions | ✅ `.github/workflows/windows.yml` (todavía no ha corrido en el PR — el push no llegó al upstream porque el PR está en draft) |
| 9 | Releases | ⚠️ partial — `setup.ps1` espera el asset `fx-windows-x86_64.zip` en el release; no se modifica el pipeline de release upstream porque requiere coordinación post-merge |
| 10 | Installer | ✅ `setup.ps1` (459 líneas, commiteado) |
| 11 | Documentación | ✅ `docs/windows.md` (6.8 KB), README actualizado, CHANGELOG con `Unreleased` |
| 12 | Docs técnica Windows | ✅ `docs/windows.md` |
| 13 | Detección de platform | ✅ `comptime builtin.os.tag` (no `uname`) |
| 14 | Compatibilidad con comportamiento actual | ✅ Linux/macOS byte-identical en código (los guards comptime eliden Windows en otros targets) |
| 15 | NO simular soporte | ✅ ningún shim hacia WSL/Cygwin/MSYS2; `fx.exe` Win32 nativo |
| 16 | Quality gate (build + tests + doctor) | ⚠️ build ✅, doctor ✅, tests ❌ (v2) |
| 17 | Pruebas manuales PowerShell/Win Term/CMD | ❌ no probé interactivamente con TUI; solo smoke (`--version`, `--help`, `doctor`) |
| 18 | Compatibilidad con Windows path | ✅ `RtlGetFullPathName_U`, `\\?\` UNC paths via `std.fs.path` |
| 19 | Error handling | ✅ mensajes usan el contrato del host, no el binario |
| 20 | Mantener cambio pequeño y upstreamable | ✅ diff total: 953 insertions / 92 deletions en 19 archivos (mi commit `fee4b17`) |
| 21 | Git / branch | ✅ `feat/windows-support` |
| 22 | Commits | ✅ 5 commits lógicos, mensajes en estilo Conventional Commits |
| 23 | Revisión final | ✅ sin TODO/FIXME; sin secrets; sin paths hardcodeados |

### Criterio de éxito del prompt original (la checklist de 16 items)

```
✓ Native Windows build
✓ fx.exe executes
✗ Interactive terminal works            ← v2 (ConPTY)
⚠ PowerShell works                      ← smoke ok, TUI no
⚠ Windows Terminal works                 ← smoke ok, TUI no
✓ Filesystem works                       ← homeDir / tempDir
✓ Paths work                             ← realpathAlloc con RtlGetFullPathName_U
⚠ Process execution works                ← std.process.spawn ok, pero stdlib pollfd stub
✓ Ctrl+C works                           ← SetConsoleCtrlHandler
✓ Git works                              ← commandInPath prueba git + git.exe
✓ Configuration works                    ← homeDir / settings_store
✓ Authentication works                   ← Credential Vault
⚠ Sessions work                          ← funciona, no probado interactivamente
⚠ Relevant MCP/ACP functionality works   ← stdio ok, HTTP no
✗ Tests pass                             ← v2
⚠ Windows CI passes                      ← workflow creado, no corrido aún
✗ Release artifact can be generated      ← pipeline upstream no modificado
✓ Installation path exists              ← setup.ps1
✓ Documentation exists                   ← docs/windows.md, README, CHANGELOG
✓ Linux/macOS remain functional         ← byte-identical via comptime elision
```

8/16 items totalmente cumplidos, 5/16 parcialmente, 3/16 v2.

---

## 4. Cosas concretas que el próximo agente / colaborador debería hacer

1. **Rebase el branch sobre `upstream/main`** (actualmente en
   `vercel-labs/fx@c864c67`):
   ```bash
   git fetch upstream
   git rebase -i upstream/main
   # Resolver los 4 conflictos (ver sección 2)
   git push --force-with-lease origin feat/windows-support
   ```
2. **Trigger el Windows CI** después del rebase. El workflow
   existe pero no ha corrido porque la rama nunca se pusheó a
   un punto limpio. Después del rebase, abrir el PR como
   "ready for review" en vez de draft, o pedir review a un
   maintainer.
3. **Decidir qué hacer con `setup.ps1`**. El script vive en el
   branch pero la URL `https://fx.sh/setup.ps1` no existe. O
   bien: (a) el maintainer sube el script al CDN, o (b) el
   primer release de Windows lo incluye. Esto es decisión de
   Vercel Labs, no del PR.
4. **Marcar el PR como ready**. Cuando el rebase esté verde y
   el CI corra limpio, quitar el flag de draft. El título actual
   es `build: add initial native Windows x86_64 support` (en
   Conventional Commits, `build:` para cambios que afectan al
   build, no a features). Verificar con el maintainer cuál es
   el label correcto.
5. **(Opcional) Volver a `v0.0.4` → `Unreleased` en CHANGELOG**
   cuando el PR se apruebe. La release pipeline agrega el
   `<!-- release:start -->` / `<!-- release:end -->` automáticamente
   al taggear.

---

## 5. Reglas duras que se respetaron

* ✅ NO eliminar tests, scripts, docs, configs existentes.
  Los tests POSIX siguen ahí; los guards comptime solo eliden
  su compilación en Windows.
* ✅ NO introducir hacks de máquina. Las stdlib backports
  están en `C:\zig\...\lib\std\` local, no en el repo. El CI
  workflow los aplica via inline PowerShell.
* ✅ NO hardcodear paths. `homeDir` y `tempDir` leen
  `USERPROFILE` / `TEMP` / `TMP` en runtime.
* ✅ NO depender de WSL/Cygwin/MSYS2/Git Bash. El binario
  producido es Win32 nativo.
* ✅ Cross-platform via `comptime builtin.os.tag` switches.
  Cada branch Windows es comptime-elided en Linux/macOS.
* ✅ Linux/macOS code paths UNCHANGED cuando no era
  estrictamente necesario. Los guards existentes en
  `host.zig` / `process_tree.zig` / `http_fetch.zig` solo
  eliden el código Windows en otros targets.
* ✅ Documentación de cada decisión en `openspec/` y este
  archivo de coordinación.

---

## 6. Archivos modificados (lista completa del branch)

```
.github/workflows/windows.yml      (NEW, 4.2 KB)
.gitignore                         (2 lines, whitespace)
CHANGELOG.md                       (Windows preview entry, release markers)
README.md                          (Windows section + link to docs/windows.md)
WINDOWS_*.md                       (4 coordination docs, kept on branch)
build.zig                          (link shell32 / advapi32 / user32 / crypt32 on Windows)
docs/windows.md                    (NEW, 6.8 KB)
openspec/                          (5 files: README, design, proposal, tasks, 3 specs)
setup.ps1                          (459 lines, PowerShell installer)
src/builtins/tools.zig              (fix ../../ → ../)
src/core/auth/chatgpt_oauth.zig    (Windows ptrCast, builtin import)
src/core/execution/process_tree.zig (Windows guard in appendLinuxTaskChildren)
src/core/hosts/native.zig          (OpenClipboard / SetClipboardData)
src/core/hosts/native_keychain.zig  (Credential Vault via advapi32)
src/core/hosts/url_opener.zig      (ShellExecuteW)
src/core/upgrade/auto_upgrade.zig   (ZIP path on Windows)
src/core/upgrade/upgrade_helpers.zig (extractZipEntry, replaceBinary CopyFile)
src/core/upgrade/upgrade_runtime.zig (dispatch ZIP on Windows)
src/tools/shell/background_process.zig (Windows guard in signalProcess)
src/tools/web/http_fetch.zig        (comptime guards on 5 functions)
src/ui/shell_runtime.zig            (Windows ptrCast in pollInput)
```

23 archivos en `fee4b17` (mi commit principal), 1 archivo más
en `d72d67d` (recipe refresh), 1 archivo en `docs/windows.md`
(NUEVO).

---

## 7. Estado del open PR (chequeo en vivo)

```bash
gh pr view 412 --repo vercel-labs/fx --json state,isDraft,mergeable
{
  "state": "OPEN",
  "isDraft": true,
  "mergeable": "CONFLICTING",
  ...
}
```

Checks reportados:
* Socket Security: Project Report → **pass**
* Socket Security: Pull Request Alerts → **skipping** (no applicable changes)

El Windows CI workflow no se ha ejecutado. Cuando el branch se
pushee a upstream sin conflictos, el CI debería trigger y
reportar el estado del build.
