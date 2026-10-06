# agent-cast implementation program

Build an effect-aware execution optimizer backed by actor-owned resources. Keep
logical tool calls, current authority, results, and effect evidence intact while
reducing measured physical work.

The initial implementation lives in `experiments/agent_cast/`. The design is in
[the HTML explainer](../agent-cast-architecture.html). The first slice is a
standalone correctness experiment; production permission integration, a broker,
worker supervision, shared completed-value caching, and sandbox isolation are
later milestones.

## Canonical ledger

[tasks.json](tasks.json) is the source of task status. Each task has a stable ID,
milestone, dependencies, assigned role/model, owned file scope, acceptance
criteria, evidence references, and usage fields.

[events.jsonl](events.jsonl) records observed assignments and verification events.
The coordinator owns ledger changes. Workers return artifacts and findings;
they do not mark their own work ready. Unknown token counts remain `null` until
a provider receipt supplies them.

Run these commands from the fx root:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 scripts/agent_cast_ledger.py validate
PYTHONDONTWRITEBYTECODE=1 python3 scripts/agent_cast_ledger.py next --json
PYTHONDONTWRITEBYTECODE=1 python3 scripts/agent_cast_ledger.py show
```

The checker validates structure, dependencies, status requirements, and usage
provenance. It does not verify live CI or establish that evidence is true. The
coordinator reads the referenced receipts and confirms the gate.

## Milestones and exit gates

| ID | Deliverable | Exit gate |
| --- | --- | --- |
| M0 | Program setup | Ledger and dependency graph validate; pinned Zig 0.16.0 runs; scoped model assignments and verification rules are recorded |
| M1 | Typed planner and embedded reader | Known immutable capture; exact fixture bindings; enabled/disabled byte parity; denied/stale exclusion; focused tests and actual built-binary receipts |
| M2 | Shared observation cache | Owned bounded cache; current admission on every hit; two-agent reuse in a compatible domain; isolation, eviction, and result lifetime tests |
| M3 | Broker and language clients | Bounded framed transport; actual Python/Node clients; independent logical identities, deadlines, cancellation, and credits |
| M4 | Supervision and recovery | Epoch replacement, stale-handle rejection, bounded cleanup, fault injection, and explicit uncertain effects without blind retries |
| M5 | libfx integration | A fixture provider drives a real host-tool interaction; existing authority, cancellation, output, and publication rules survive |
| M6 | Isolated eval tasks | One existing Linux backend; independent clean task state; verified process drain and reset; grader outside the agent environment |
| M7 | Service owners and cost model | Scoped pooled HTTP clients execute required requests; credential/configuration drain; complete cost attribution; valid direct fallback |
| M8 | Qualification and release decision | Equivalent work and outcomes against optimized baselines; full resource accounting; repeated trials; exact-commit CI and ship gates |

M5 and M7 can progress from the same verified broker foundation. Isolation
qualification depends on recovery and integration. Performance claims wait for
M8's meaningful comparisons.

## Status rules

| Status | Meaning |
| --- | --- |
| `planned` | Scope and acceptance criteria exist; work has not started |
| `in_progress` | An assigned worker owns the task's file scope |
| `implemented` | Artifacts exist; required verification is pending |
| `verified_local` | Referenced local checks and the applicable real interaction succeeded |
| `ci_pending` | Local proof exists; exact-commit CI or the relevant qualification remains pending |
| `done` | Every applicable local, review, CI, and ship gate is supported by evidence |
| `blocked` | A concrete dependency or external condition prevents the task |

`next` treats `verified_local` dependencies as available for development. That
does not make their artifacts ship-ready. A `done` task requires completed
dependencies, and a shipping task requires CI for the exact current commit.

## First implementation slice

The M1 planner preserves ten logical calls in its demonstration: eight permitted
reads with four unique windows, one denied request, and one stale-authority
request. Two logical agent identities request the same certified captured
content. Enabled grouping can share backing reader invocations while keeping
individual receipts.

This is one embedded process, not two network clients. Host admissions are
fixture-owned assertions, not production capabilities. Immutable content is
captured into owned storage; arbitrary tools and commands are unsupported.

The qualification runner uses two different actual fixtures and checks result
bytes independently. It also runs the built binary's help, enabled, disabled,
and compare paths, and records source/binary hashes, exit results, and stderr.
Planning and read-count differences do not establish a latency speedup.

## Work allocation and handoffs

Use [model-routing.md](model-routing.md) for task selection. A task brief names
its ID, allowed files, dependency artifacts, required invariants, verification
command, and repair limit. Pass a compact brief and relevant files instead of
the full conversation.

Only one worker mutates a file scope. The coordinator owns integration,
resource staging, receipts, task transitions, and checkpoints. Run one heavy
build or benchmark at a time; keep fixture and output bounds explicit.

At a checkpoint, update the ledger and event log with observed results. Retain
failed receipts. After a repair, rerun proof that depended on the broken path.
Leave later milestones planned until their own acceptance criteria are met.

## Shipping gate

Local verification is distinct from publication and readiness. Follow the fx
repository's checkpoint, draft PR, exact-commit CI, macOS arm64, and ship-gate
requirements when promoting changes. A standalone prototype gate must also run
the prototype itself; an unchanged fx smoke test cannot qualify its behavior.

Read the evidence references in the ledger for the current gate state. Do not
infer readiness from a successful model response, nonempty receipt path, or old
CI result.

## Current checkpoint

M0, the bounded M1 slice, and M2 completed-value caching have local evidence in
[evidence/m2.json](evidence/m2.json) and
[evidence/ledger.json](evidence/ledger.json). The refreshed qualification observed
62 Zig tests and two different actual fixtures. Foundation comparisons retain
ten logical receipts while using eight or four captured-content reader calls.
Cache comparisons retain eleven receipts, including four new logical consumers
served from completed values and three rejected consumers with no output.
The subscriber and framing contracts have unit evidence; their actual broker
runtime qualification remains pending. No measured speedup is claimed.

The authority registry owns exact bindings, derives opaque handles with HMAC,
and checks registry generations and deadlines before start. Reclaimed permits
remain charged tombstones for the task lifetime. Its ten tests are included in
the latest qualification. Eight helper-oracle tests reject mutated reports; the
earlier weak checker fails the two controls that exposed its identity and quota
gaps. These checks supplement later runtime red-team validation.

The available account has read access to `vercel-labs/fx`; an owned fork provides
the publication route recorded in
[evidence/publication-route.json](evidence/publication-route.json). Draft PR and
exact-commit CI are pending. The `Agent-cast Foundation` workflow builds and
exercises this prototype on Linux and macOS. Its checks supplement the existing
fx product checks.

The current work is `AC-0301`: broker framing and a host-owned authority registry,
followed by an actual broker executable. `AC-0202` still needs a real shared
producer and cancellation interaction. Later work retains its own runtime,
recovery, containment, service and red-team gates. Refine those scopes into
concrete file ownership before dispatching them.
