# WebAssembly SDK instructions

These instructions apply to work under `sdk/` and supplement the repository-level `AGENTS.md`.

This file is maintainer guidance, not consumer documentation. Keep setup and the supported public surface in `sdk/README.md`. Keep exact API shapes in `sdk/fx-sdk.js`, its tests, and the declarations in `sdk/types/`. Add details here only when they help an agent choose the right owner, preserve a non-obvious invariant, or run the right proof. The native Node-API architecture and security model are documented in `sdk/NAPI.md`.

## Start from the correct owner

The SDK has two WebAssembly surfaces and one shared JavaScript host layer:

| Concern | Source of truth |
| --- | --- |
| Shared loader, host imports, adapters, and public JavaScript exports | `sdk/fx-sdk.js` |
| Headless ACP composition for `fx-core.wasm` | `src/wasm_core_main.zig` |
| Interactive terminal entry point for `fx-term.wasm` | `src/wasm_term_main.zig` and `runWasmTerminal` in `src/main.zig` |
| Native and WebAssembly capability policy | `src/core/hosts/runtime_profile.zig` |
| Host-backed terminal session persistence | `src/core/app/app_session_runtime.zig` and `sdk/fx-sdk.js` |
| Browser workspace contract and `shell.run` bridge | `src/core/hosts/js_host_workspace.zig` and `src/tools/shell/browser_shell.zig` |
| Browser workspace AGENTS.md reads | `src/core/hosts/js_host_workspace.zig`, `src/builtins/context.zig`, and `sdk/fx-sdk.js` |
| Browser device login, OAuth session persistence, and URL opening | `src/core/auth/js_host_auth.zig`, `src/core/auth/oauth_session.zig`, and `src/core/hosts/js_host_url_opener.zig` |
| WASI target, optimization mode, threading, and artifact names | `build.zig` |
| Core browser fixture and its automation contract | `sdk/index.html` and `sdk/tests/test-core-browser.mjs` |
| Terminal fixture and static packaging contract | `sdk/term-demo.html` and `sdk/scripts/package-term-demo.mjs` |
| Durable sessions: log, leases, queue, deadlines, UI stream, and the harness contract | `sdk/durable.js` (no fx imports) |
| When a libfx steer interrupts, waits, joins, or hands off a turn | `src/acp/libfx_steering.zig`, used by `src/acp/server.zig` and `src/acp/prompt.zig`; the durable placement rules in `sdk/durable.js` |
| fx as a durable harness: engine options, rerun policy | `sdk/fx-harness.js` |
| A durability over a World the app supplies; `local()` and `vercel()` are built on it | `sdk/durable/world.mjs` |
| TypeScript declarations for every entry point | `sdk/types/`, checked by `sdk/tests/test-types.mjs` |
| Checkpoint format, including the libfx version, tool set, and model each checkpoint records | `src/core/agent/runtime/checkpoint.zig` |
| Images a session saves once, by name: naming in journal events and checkpoints, and the two-phase open | `src/core/session/session_codec.zig`, `src/acp/libfx_journal.zig`, and `src/acp/server.zig` |
| A session's image store (the internal `persistenceImages` key) and storing before sending | `sdk/fx-sdk.js`; a durable session's images are World streams in `sdk/durable.js` |
| Commands required by CI | `.github/workflows/ci.yml` |

Do not treat the demos or this file as the implementation contract. When prose and behavior disagree, establish the current behavior from code and focused tests before changing either.

## Preserve these invariants

- Keep `sdk/fx-sdk.js` a dependency-free ECMAScript module. A bundler, framework, or runtime package must not become necessary to load the SDK.
- Keep the core and terminal surfaces distinct. `fx-core.wasm` starts the headless ACP server; `fx-term.wasm` starts the interactive terminal. Shared loader changes must be validated against both.
- Detect JavaScript Promise Integration (JSPI) by capability through `supportsJspi()`. Do not replace feature detection with browser or version sniffing. Keep loader errors, demo fallback states, and the compatibility statement in `sdk/README.md` consistent.
- Treat JavaScript host stores as durable contracts. Session and OAuth snapshots are opaque bytes with optimistic revisions. Preserve `FX_SESSION_REVISION_CONFLICT` and `FX_OAUTH_SESSION_REVISION_CONFLICT`. Persist configuration only after fx accepts it, and do not collapse prompt-history outcomes into generic success.
- Preserve cancellation and lifecycle behavior. Fetch cancellation must reach the host `AbortSignal`; terminal subscriptions must be released exactly once; `abort()` must settle `exited` and must not leave input or resize listeners attached.
- The WebAssembly runtime is not the native runtime. Keep native tools disabled. The optional workspace host may expose only completion-only `shell.run` through its typed boundary and permission policy. Its schema is exactly `{ action: "run", command }`; native profiles, TTYs, and managed running handles are unavailable. Any additional capability requires its own typed host boundary, permission review where applicable, and coverage on the affected surface.
- The optional workspace `readFile` boundary serves only project instruction loading. Keep it limited to absolute `AGENTS.md` paths inside the workspace root or home, with UTF-8 validation, the 1 MiB copy limit, and the shared abort path. It is not a model-callable file tool. A workspace without `readFile` must report the omitted instructions rather than skip them silently.
- Keep workspace version 1 constrained to an ephemeral, non-git workspace whose normalized `cwd` equals `root`. Preserve command and output limits, the 30-second maximum deadline, and Ctrl+C cancellation through the shared host-effect abort path.
- `window.__fxCoreTest` and `document.body.dataset.state` are test interfaces for the core debugger. If either changes intentionally, update the browser test in the same change.
- The live demos may pass a locally stored credential into the WebAssembly environment. Never print, serialize into artifacts, or add test assertions containing that credential.

## Match the proof to the change

| Change | Minimum focused proof |
| --- | --- |
| Public export, shared loader, WASI import, or JSPI gate | Build and test both surfaces |
| Public export, option, event, or result shape | Update `sdk/types/` and run `node sdk/tests/test-types.mjs` after `npm ci --prefix sdk/node` |
| `createFxAgent()`, ACP translation, core session persistence, streaming, or cancellation | Core build, core Node tests, and the browser test when browser behavior is involved |
| Live Gateway request or model-catalog translation | Core tests plus the opt-in live smoke test when a credential is available |
| How a session saves images: naming, the image store, staging at open | Core and terminal builds, `bun sdk/tests/test-journal.mjs native wasm` and `wasm native`, `test-checkpoint.mjs` both ways, the Zig tests of `checkpoint.zig` and `journal.zig`, then `tests/tla/sdk/check.sh` and `bun tests/tla/drivers/drive-images.mjs` with `--backend native` and `wasm`, which walks the graph of `ImageStore.tla`; change the spec with the code. For durable sessions, also the durable sessions row |
| Terminal adapter, input encoding, resize, cleanup, config, or prompt history | Terminal build and the headless terminal suite |
| Terminal session persistence or browser device login | Terminal build plus `sdk/tests/test-term-session-resume.mjs` or `sdk/tests/test-term-login.mjs` |
| Browser workspace metadata, permissions, execution, limits, or cancellation | Terminal build plus `sdk/node/test-term-workspace.mjs` |
| Browser workspace AGENTS.md reads | Terminal build plus `sdk/node/test-term-agents-md.mjs` |
| `encodeXtermKeyEvent()` or `xtermAdapter()` only | `sdk/node/test-xterm-adapter.mjs` |
| Core debugger query behavior or automation state | `sdk/tests/test-core-browser.mjs` |
| Terminal demo asset references, integrity, or cache policy | Package into a fresh temporary directory and inspect the generated HTML, manifest, and headers |
| Durable sessions: leases, fencing, takeovers, tool reruns, the UI stream | `sdk/tests/test-durable-core.mjs` on memory, local, world, and queue (the core with a scripted harness; world is an app-built World passed to `world()`, queue one whose queue delivers as Vercel Queues does, with `queueLeases`), `sdk/tests/test-durable.mjs` on memory, local, and world, then `tests/tla/sdk/check.sh` and `bun tests/tla/drivers/drive.mjs send`, `lookup`, `write`, `cutoff` (deadline cut-offs up to their bound), `leased` (a World without liveness, where each worker renews a short lease), and `queue` (a World whose queue shows whether a worker lives, so leases are held without renewals), which walk the real code along the TLC state graphs of `DurableSession.tla`; change the spec with the code. For how a session object takes prompts in (images and their image writes, cancels, and closing the agent), also run `bun tests/tla/drivers/drive-intake.mjs` on memory and `--durability world`, which walks the graph of `PromptIntake.tla`. For agent names and routing, also `bun tests/tla/drivers/drive-agents.mjs`, which walks `AgentRouting.tla`'s graph with each process in a worker thread of its own. For what a delivery may run, on whose agent and store, and input limits, also `bun tests/tla/drivers/drive-tenants.mjs`, which walks `TenantIsolation.tla`'s graph with four tenants and a forger sharing one route. With a Vercel access token, also run both against Vercel's World: `test-durable.mjs vercel native` and `drive.mjs --durability vercel`, configured as `sdk/tests/vercel-storage.mjs` describes |
| Steering: interrupts, waits during tools, joins, hand-backs on cancel, image handoffs, steer ids | The libfx steering tests in `src/acp/libfx_steering.zig`, `sdk/tests/test-agent-steering.mjs` and `sdk/tests/test-durable.mjs` on native and wasm, then `tests/tla/sdk/check.sh` and `bun tests/tla/drivers/drive-steer.mjs ideal` and `faults`, with `--backend wasm` too, which walk the real code along the TLC state graphs of `DurableSteer.tla`; change the spec with the code |
| How sessions hold up over long runs with random crashes and faults: images, size retries, resumes, steers. On request; CI doesn't run it | After `zig build libfx-napi -Dnapi-surface=core`, `zig build -Dwasm-surface=core` and `npm ci --prefix sdk/durable`: `node --experimental-wasm-jspi sdk/tests/sim/engine.mjs --runs 60` with `--backend native`, `wasm` and `both`, which runs each plan on both backends and compares them; `sdk/tests/sim/durable.mjs --runs 20` on native and wasm, two workers sharing one `local()` World; and `node --expose-gc --experimental-wasm-jspi sdk/tests/sim/budget.mjs` on both backends, for memory and time per turn as a session's images grow. A run is a seeded plan: `--seed` picks it, a failing plan is saved to a file, and `--plan FILE --shrink` replays it with steps removed while it still fails |
| Supported public behavior or setup | Update `sdk/README.md` in the same change |

Use Node.js 24 for SDK tests. CI relies on its JSPI implementation behind `--experimental-wasm-jspi`.

Core validation from the repository root:

```sh
zig build -Dwasm-surface=core
node --experimental-wasm-jspi sdk/tests/test-core.mjs
node --experimental-wasm-jspi sdk/tests/test-core-cancel.mjs
node --experimental-wasm-jspi sdk/tests/test-core-home-unavailable.mjs
node sdk/tests/test-core-browser.mjs
```

Set `CHROME_PATH` for the browser test only when Chrome or Chromium is outside the paths searched by the script.

Terminal validation from the repository root:

```sh
zig build -Dwasm-surface=term
npm ci --prefix sdk/node
npm run --prefix sdk/node test:term
node --experimental-wasm-jspi sdk/tests/test-term-session-resume.mjs
node --experimental-wasm-jspi sdk/tests/test-term-login.mjs
```

For a live Gateway transport change, `AI_GATEWAY_API_KEY` must already be present in the environment before running the opt-in smoke test:

```sh
node --experimental-wasm-jspi sdk/tests/test-core-live.mjs
```

For behavior changes, also follow `sdk/README.md` to serve the repository and drive one real interaction in the affected browser demo. Automated tests do not replace this runtime exercise.

The terminal packaging script removes its output directory before writing. Always give it a newly created temporary directory:

```sh
sdk_package_dir="$(mktemp -d)"
node sdk/scripts/package-term-demo.mjs "$sdk_package_dir"
```

Do not commit `zig-out/`, `sdk/dist/`, or other generated artifacts. Run `git diff --check` before creating a checkpoint. The repository-level build, binary exercise, and CI ship gates still apply.

## Code review rules

- Flag a public contract change that lacks a focused regression test. Require a README update only when supported public behavior or setup changed.
- Flag code that makes one surface silently depend on the other surface's composition or capability profile.
- Flag user-agent checks for JSPI, swallowed session or OAuth revision conflicts, premature config writes, lost prompt-history outcomes, or terminal listener leaks.
- Flag workspace adapters that bypass typed metadata validation, permission admission, resource limits, or the shared cancellation path.
- Flag deployment changes that give mutable HTML the same long-lived cache policy as content-addressed JavaScript or WebAssembly assets.
