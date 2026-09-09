# Journal acceptance witnesses

These tests exercise journaled execution in the shared core, native CLI, and SDK.
Separate deterministic simulations cover host policies that still need deployment
qualification. Keep recovery guards and effect-count assertions intact.

The source contract is [fx-brain PR 15](https://github.com/vercel-labs/fx-brain/pull/15),
reviewed at `3b06bfa6317eb03e4c61943317cbe89bd8c8ff7a`, especially its
[13 acceptance cases](https://github.com/vercel-labs/fx-brain/blob/3b06bfa6317eb03e4c61943317cbe89bd8c8ff7a/JOURNALED-EXECUTION/04-verification-and-qualification.md)
and [safety rules](https://github.com/vercel-labs/fx-brain/blob/3b06bfa6317eb03e4c61943317cbe89bd8c8ff7a/JOURNALED-EXECUTION/03-safety-and-failure-contracts.md).
The branch implements the `journal`, `onEntry`, `requestId`, tool `replay`,
identity, and draft-generation contracts. Passing these tests alone does not
qualify the complete native restart flow or production adapters.

## Run only this worklist

Requirements: Zig 0.16, Node 24, Bun, and tmux for the CLI witness. No credentials,
external services, browser, Cloudflare, or Rivet account is required.

```sh
node scripts/test-journal.mjs
```

This builds the native CLI, native addon, and core Wasm from this checkout, then
runs all selected layers even when an earlier one fails. It exits nonzero when
any selected assertion fails. Logs are under `.zig-cache/journal-results/`.

After a fresh build, rerun only the tests:

```sh
node scripts/test-journal.mjs --no-build
node scripts/test-journal.mjs --only=core
node scripts/test-journal.mjs --only=simulation
node scripts/test-journal.mjs --only=cli
node scripts/test-journal.mjs --only=sdk
```

`--no-build` must not be used after changes that make the artifacts stale. Core
witnesses always rebuild their Zig test executable. To restrict SDK iterations:

```sh
FX_JOURNAL_BACKENDS=native node scripts/test-journal.mjs --only=sdk --no-build
FX_JOURNAL_BACKENDS=wasm node scripts/test-journal.mjs --only=sdk --no-build
```

Individual commands:

```sh
zig build test-journal
zig test src/core/session/journal_simulation_tests.zig
node --test sdk/tests/journal/host-simulation.test.mjs
node --test sdk/tests/journal/runtime.test.mjs
FX_E2E_DISABLE_DOTENV=1 FX_SOUND=0 bun test tests/e2e/session-recovery.test.ts --test-name-pattern 'journal witness native crash'
```

## Owners and evidence

### Shared Zig core: real orchestrator, fake provider/tool

`src/core/agent/runtime/tests/journal_crash_flow.zig` invokes the real
`processAgentPrompt`, permission/admission plumbing, recovery codec, and history
boundary. It copies only persistence acknowledged **at** each chosen cut, then
constructs a fresh runtime from those serialized bytes. The first runtime is
allowed to finish solely to release resources; none of its post-cut writes are
used for recovery. This is a deterministic crash-state simulation, not SIGKILL.

Assertions cover the original selected call before its effect, A's result
before B enters, safe receipt recovery on either side of the external transaction,
and final output before history commit. Controls retain the existing fail-closed
rules for unknown effects and failed checkpoint writes.

The persistence seam consumes acknowledged execution records. Replay-safe tool
fixtures opt into the typed policy; ordinary shell calls remain blocked.
`zig build test-journal` is a separate root run explicitly by Full CI on all four
native platforms.

For actual older-executable compatibility, Full CI builds the pinned public
pre-journal revision through `scripts/legacy-session-fixture.sh` and sets
`FX_JOURNAL_OLDER_EXE`. The helper caches its output in `.zig-cache`; local runs
may supply an absolute `FX_TEST_LEGACY_EXE` instead. The E2E legacy recovery
fixtures use that binary only to create or explicitly resolve older sessions.
Recovery, conversion, and journal continuation run against the current binary.

```sh
FX_JOURNAL_OLDER_EXE="$(bash scripts/legacy-session-fixture.sh)"
export FX_JOURNAL_OLDER_EXE
zig build test-journal
FX_SOUND=0 bun test tests/e2e/session-recovery.test.ts
```

### Native CLI: actual killed process and `fx -c`

`tests/e2e/journal/crash.test.ts` is imported by the existing
`session-recovery.test.ts` owner. It starts `zig-out/bin/fx ask`, lets a real local
shell publish an effect while its result is gated, kills the exact fx process
with SIGKILL, and starts the same built binary with `-c` under tmux. It checks
paused reopening, no automatic provider replay, the same session, one effect,
and retention of the original selected call in authoritative session storage.
The shell may itself terminate when its owner dies; that does not undo its effect.
All fixture processes and files are cleaned up.

These tests run through their existing PGSO recovery owner in ordinary E2E CI. This is not a replacement for the existing safe-upgrade, session
selection, partial-tail, writer-lock, and restart tests.

### SDK: actual core in isolated native/Wasm processes

`sdk/tests/journal/runtime.test.mjs` launches `worker.mjs` with the real native
addon or Wasm core. Only model transport, host storage, and effects are fixtures.
The parent retains the durable files; `process.exit(86)` kills an owner inside an
explicit callback boundary, without `close()`, cancellation, or cleanup writes.
A watchdog failure, wrong exit, or unexpected stderr is a harness failure, not a
valid red witness. No real API credentials are passed to child processes.

Recreation uses the acknowledged journal entries, with no alternate checkpoint
writer. Effects and local receipts commit in one fixture
replacement; the deployment case instead has a separate provider store, accepts
a job before any local receipt, and finishes it while no owner exists.

Files use synchronous flushed replacements at controlled process-death cuts.
They do not establish power-loss durability, directory-fsync behavior, platform
storage guarantees, or general exactly-once external execution.

### Deterministic reference simulations

`src/core/session/journal_simulation_tests.zig` uses the real low-level Journal
append/ack primitive with a small test-only execution policy. It enumerates 17
cuts around the six durable entries and two external transactions. Correct
recovery passes; removing decision ordering, receipts, blocked-tool protection,
or the per-tool result barrier yields a counterexample. Importing the primitive
also runs its existing bounded acknowledgement, partial-write, ownership, and
reentry tests.

`sdk/tests/journal/host-simulation.test.mjs` models adapter-owned projection,
drafts, admission/retention, checkpoint pruning, and external-job reconciliation.
Correct schedules pass; mutations lose history/dedup, revive drafts, or mislabel
unknown effects. These tests explain requirements. They do **not** test a real
host adapter or validate the proposal's TLA+ model.

## Acceptance map

| PR case | Real implementation witness | Reference / remaining scope |
| --- | --- | --- |
| J01 append acknowledgement and recreation | Native/Wasm before/after all four entry boundaries; owner fencing | Zig primitive + lost-ack simulation |
| J02 durable model decision before effect | Zig core, native `-c`, Native/Wasm | Optimistic-effect counterexample |
| J03 receipt committed, result missing | Zig core, Native/Wasm process death | All crash cuts with original receipts |
| J04 effect acknowledgement lost | Native/Wasm tool throws after committing receipt | Same independent receipt rule |
| J05 effect not committed | Zig core, Native/Wasm | Inverse crash cut |
| J06 blocked single/batch | Zig fail-closed control; Native/Wasm pending state, resume, abandon | `unknown` A / `skipped` B projection simulation; SDK transcript projection |
| J07 final response and turn completion | Zig history cut; Native/Wasm final-step and result durability | No-model-after-final simulation |
| J08 interrupted drafts | Native/Wasm streamed identity and fresh generation | Queued-flush and double-crash host simulation; real durable adapter remains unqualified |
| J09 admission and retention | Completed-ID execution/conflict witnesses cover kernel dedup only | Age/skew and busy count-bound simulation; no HTTP admission adapter exists here |
| J10 checkpoint/prune | Native/Wasm duplicate request after checkpoint/prune | Full transcript retention and missing-mapping counterexamples |
| J11 semantic replay | Native/Wasm recorded text and no new model request | No token-chunk identity promise |
| J12 identities | Zig original call; Native/Wasm request/turn/call context and repeated restoration | SDK transcript message-ID projection; actual client remains unqualified |
| J13 independent deployment | Native/Wasm provider accepts job, local receipt absent, process dies; safe/blocked recovery | New call ID is not a global deployment lock simulation |

## Limits and next step

Core, CLI, and SDK witnesses establish their own tested boundaries. The host
simulations do not qualify actual platform adapters or deployed request lifetimes.

Do not infer that every adapter abstraction in PR 15 is necessary from these
witnesses. They establish narrower ordering, identity, durability, and recovery
requirements. Platform adapters, race-free client snapshot/update handoff, actual
browser locks, cross-host ownership, all native upgrade/version scenarios,
performance budgets, and Full CI qualification remain separate work. No test here
claims the journal can undo an already issued external effect.
