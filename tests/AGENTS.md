# AGENTS.md

Instructions for work under `tests/`. They supplement the repository-level `AGENTS.md`, which still owns the readiness rules, CI gates, and Zig conventions.

`tests/` holds the checks that run against the built binary or against a model of its design. Unit tests do not live here: Zig tests stay inline in the `src/` file they cover.

## Where a test belongs

Pick the lowest layer that proves the behavior, and extend the closest existing file before creating a new one.

| What you are proving | Where it goes |
| --- | --- |
| A parser, policy, reducer, formatter, or state transition | An inline `test` block in the owning `src/` file |
| Terminal cells, wrapping, cursor, scroll, or resize | `src/ui/resize_tests.zig` or a VT test in the owning UI file |
| CLI, ACP, or TUI behavior of the built binary | A root `tests/e2e/*.test.ts` file; terminal flows use `tui-*.test.ts` |
| fx against the official MCP client conformance suite | `tests/e2e/conformance/`, an isolated npm project |
| Evidence tooling for terminal rendering bugs | `tests/e2e/render-lab/` |
| Task quality or tool choice with real models | `tests/evals/` |
| Saved inputs for a fuzz test | `tests/fuzz/corpus/<target>/`, with the target listed in `tests/fuzz/targets.json` |
| A protocol or crash-safety design, checked with TLC | A folder under `tests/tla/` named after the module it models |
| libfx SDK behavior | `sdk/tests/`, which `sdk/AGENTS.md` owns |
| Startup latency or memory | `benchmarks/` |

## Layout

```text
tests/
├── e2e/                   deterministic runtime tests, run on every pull request
│   ├── *.test.ts          one file per feature area, all at this level
│   ├── *.ts               shared helpers, such as tmux-helpers.ts and tui-render-assertions.ts
│   ├── fixtures/          fake servers, MCP servers, and recorded captures
│   ├── conformance/       MCP conformance package, run with npm
│   └── render-lab/        rendering evidence tool
├── evals/                 model-backed evals, run only on request
├── fixtures/
│   └── v1-sessions/       sessions the v0.0.14 release saved, which the converter's tests copy;
│                          generate.ts rebuilds them and manifest.json lists them
├── fuzz/
│   ├── targets.json       every fuzz test, for zig build fuzz and the nightly Fuzz workflow
│   └── corpus/<target>/   saved inputs that zig build test replays; CONTRIBUTING.md explains them
└── tla/                   TLA+ models, their checkers, and their Bun drivers
    ├── session_manager/   one folder per model area, named after the module it describes,
    ├── mcp/               each with a check.sh; tla/README.md lists them all
    ├── ...
    ├── lib/               tlc.sh, tlc.py, and run-tlc.sh: find TLC and run configs with their verdicts
    └── drivers/           Bun drivers that run real code and have TLC check each run
        ├── lib/           tlc.ts and context.ts, shared by every driver
        └── <area>/        one folder per model area
```

Only files that end in `.test.ts` at the root of `tests/e2e/` are E2E tests. CI discovers them there and nowhere else, so a test in a subfolder never runs in CI.

## Write an E2E test

- Build first with `zig build`. Tests run `zig-out/bin/fx` through `FX_BIN` from `tests/evals/eval-helpers.ts`, never an installed `fx`.
- Give every test its own profile with `createIsolatedTestHome()` and remove it with `cleanupIsolatedTestHome()`. A test must never read or write the developer's `~/.fx`.
- Keep the network local. Point fx at a fake model server with `startFakeGateway()` or `startDynamicFakeGateway()` from `tmux-helpers.ts`, or the builders in `fixtures/chat-completions.ts`. `TmuxSession` clears credentials and the `FX_E2E_*` overrides from the inherited environment.
- Wait for state the user can see: `TmuxSession.waitForText()`, `waitForStableGrid()`, `waitForComposer()`, or `waitForSessionEnd()`. A fixed sleep can pace input, but it does not prove the state you assert next.
- Skip, do not fail, a terminal test when tmux is missing: `test.skipIf(!tmuxAvailable())`.
- A new test must not play sound. `TmuxSession` and the fixtures set `FX_SOUND=0`; set it yourself when you spawn fx another way. Sound playback is covered only by `notifications.test.ts` and the `/sound on` test in `tui-command-permissions.test.ts`, so keep sound coverage there. The repository `AGENTS.md` explains how to run them locally.
- Fixtures are public. Use `/Users/example/` for home paths and never commit credentials. `scripts/check-public-surface.sh` rejects personal paths, real team IDs, and internal or personal project slugs.

## Wire an E2E file into CI

Every root `tests/e2e/*.test.ts` file needs these entries in the same change, and removing a file means removing them:

1. A positive integer weight in `tests/e2e/ci-shard-weights.json`. CI splits the files into four shards by weight.
2. Exactly one classification in `scripts/pgso/corpus.json`: a training scenario, a verification scenario, or an intentional exclusion with its reason. The repository `AGENTS.md` explains how to choose.
3. An entry in `tests/e2e/macos-platform-tests.json` when the file branches on `process.platform` or `platform()` being `darwin` or `linux`.

CI runs each file in its own Bun process and tmux server through `tests/e2e/ci-run-files.sh` and retries a failure once. A file that passes only on retry is reported as a warning: treat it as a race to fix, not a pass.

Check the wiring locally:

```sh
cd tests/e2e && bun test ci-shards.test.ts
python3 -m scripts.pgso.corpus --manifest scripts/pgso/corpus.json --list   # from the repository root
```

## Evals

`tests/evals/` drives the agent through `fx ask --json` against real models. It needs `AI_GATEWAY_API_KEY` or `VERCEL_OIDC_TOKEN`, makes billed calls, and varies between runs, so it is not a pull request check. Do not move a deterministic check here; put it in `tests/e2e/` with a fake gateway.

## TLA+ models

Every TLA+ spec, its TLC checker, the Bun drivers that walk code along a spec, and the design record a spec checks live in `tests/tla/`, and nowhere else. `tests/tla/README.md` lists the requirements and commands.

- Name a model's folder after the module it describes: `session_manager/` for `src/core/session_manager/`, `mcp_host/` for `src/core/mcp_host/`, and `sdk/` for libfx.
- Give each folder a `check.sh` that runs every config and exits non-zero when one misses its expected verdict. Configs that must fail, such as witnesses and planted mutations, are part of that contract, so encode their verdicts in `check.sh`. Source `../lib/tlc.sh` and list each config with its verdict for `tlc_verdicts`, rather than finding TLC yourself. A Python checker gets Java and the jar from `toolchain()` in `lib/tlc.py`.
- Put Bun drivers in `tests/tla/drivers/<area>/`. They run the code under test, from `zig-out/bin/fx` or by relative import, and have TLC check each run. Use `drivers/lib/tlc.ts` to run TLC and `drivers/lib/context.ts` for the binary, the output folder, and the `tests/e2e/` helpers. Every fx process a driver starts sets `FX_SOUND=0`. Generated output, such as `tests/tla/sdk/graphs/`, goes to the temp folder or is ignored by git.
- A model of code that has not landed says so at the top, and the drivers that need that code run only behind an explicit flag, such as `--next` or `FX_TLA_NEXT_MCP=1`. `tests/tla/README.md` lists them. Remove the flag in the change that lands the code.
- When a change alters behavior that a spec models, update the spec in the same change and run its checker. CI runs the `sdk/`, `mcp/`, and `mcp_host/` models and their drivers on `main` and on pull requests that change the code they cover (`scripts/detect-ci-need.sh`), and the `recovery/` model and its module driver on every pull request; run the others yourself.
- A new model, checker, or driver gets a row in `tests/tla/README.md`.

## Cite tests and specs from `src/`

Code comments point readers at the test or model that pins a behavior. Keep those references stable and public.

- Cite by repository-relative path, plus the property, action, or test name, so a reader can open it without searching: ``(`tests/tla/session_manager/Wiring.tla` ParentOutlivesChildren)``.
- Cite session-manager design decisions by number, such as `(D44)`. They are defined in `tests/tla/session_manager/system-design.md`.
- Name a test by its file and test name, not by line number. Line numbers move with every edit.
- Cite only files in this repository. A reference to a local note, private harness, or file outside the tree is a dead end for every other contributor; describe the behavior instead.
- When you move or rename a test or spec, update every citation in the same change. A `git grep` for the old path should return nothing.

## Before you finish

- Run the check for what you changed: the E2E file, such as `FX_SOUND=0 bun test cli.test.ts` from `tests/e2e/`; the folder's `check.sh` under `tests/tla/`; or `zig build test` for inline Zig tests.
- After adding, removing, or renaming an E2E file, run the wiring checks above.
- Do not run the full E2E suite locally as your development loop. CI runs it on the pull request, and a passing focused run does not replace that result.
