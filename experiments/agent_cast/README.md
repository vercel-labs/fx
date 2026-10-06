# agent-cast foundation experiment

This standalone Zig 0.16.0 experiment implements typed logical calls, exact
fixture admission, certified immutable read grouping, and per-call receipts.
It is the M1 foundation of the [implementation program](../../docs/agent-cast/milestones.md).

The executor captures real file bytes into owned immutable storage and dispatches
only its registered content reader. Enabled and disabled modes preserve logical
results while using different backing read groups. Two agent identities appear
in one embedded process; multi-process clients belong to the broker milestone.

Host admission and current generation values are trusted fixture contracts.
Production permissions, live expiry, broker cancellation, worker supervision,
service pools, and sandbox containment remain planned. Completed-value caching
is implemented in the separate embedded cache executor described below.

## Build and qualify

Use the repository's pinned Zig 0.16.0. Set `AGENT_CAST_ZIG` to the verified
executable, then run from the fx repository root:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 scripts/qualify_agent_cast.py --zig "$AGENT_CAST_ZIG"
```

The runner creates a new temporary receipt directory and retains its fixtures,
logs, and JSON evidence. `--output PATH` selects a new directory and rejects an
existing path. It checks formatting, builds with one job, runs focused unit
tests, and drives the foundation and cache binaries against two distinct 1 KiB
fixtures. Full result bytes, provenance, logical identities, and rejected
consumers are checked independently of the binaries' own verification flags.

To run individual checks, change to this directory:

```sh
"$AGENT_CAST_ZIG" fmt --check src/ build.zig
"$AGENT_CAST_ZIG" build -Doptimize=ReleaseSafe -j1
"$AGENT_CAST_ZIG" build test -Doptimize=ReleaseSafe -j1
./zig-out/bin/agent-cast-demo --help
```

Run the built demo with a file containing 256 bytes to 1 MiB:

```sh
./zig-out/bin/agent-cast-demo --fixture /path/to/fixture --mode compare
```

Replace `/path/to/fixture` with the actual input file. `--mode enabled` and
`--mode disabled` run one mode; `compare` runs both against the same capture.

## Interpreting results

The demo requests four distinct 64-byte windows twice, plus a denied and a stale
request. Each mode retains ten logical receipts. Successful allowed requests
must match actual captured bytes; rejected requests have no output or backing
group.

`physical_reads` counts successful calls to the captured-content reader. It does
not count OS file opens, network requests, elapsed time, or simultaneous agents.
The source file is captured once before these reads. This experiment supplies
correctness evidence and no performance claim.

Snapshot bytes, path, and identity remain at a stable address and unchanged
through execution. Receipt output slices borrow the snapshot; consume receipts
and destroy executions before destroying the snapshot. Plan-owned arrays have
explicit `deinit` methods.

## Completed-value cache

Run the separately built cache demonstration with the same bounded input:

```sh
./zig-out/bin/agent-cast-cache-demo --fixture /path/to/fixture
```

The first four-window batch executes backing reads. A second admitted agent
requests the same windows through four new logical calls and receives four
cache hits. A third batch of denied, stale, and mismatched consumers receives
no output. Each receipt reports its own identity and cache/backing provenance.

Every lookup checks fresh exact fixture admission, capture integrity, and the
registered reader contract. Keys and values are owned. FIFO eviction charges
the allocated table plus retained strings and values to the cache quota;
replacement storage fits that quota before allocation. Optional retention
allocation failure preserves an already-copied successful output.

Returned output copies survive eviction. They consume a separate explicit
batch budget: 64 KiB by default, capped at 16 MiB. Before any cache access, the
batch reserves admitted snapshot-read requested window lengths, including
windows that may later fail dispatch. Excess or overflow rejects the whole
batch without results or cache changes. Allocator overhead and the supplied
snapshot have separate ownership and accounting.

The subscriber registry enforces independent deadlines, cancellation, credit
and output sequences, stale-handle rejection, and output drainage before
success. The wire module bounds framed payloads and rejects duplicate JSON
fields, excessive nesting, explicit null IDs, and non-object params. Their
current evidence is unit testing. Actual broker connections, shared producer
execution, and asynchronous cancellation qualification remain pending.

## Work ledger

From the fx root:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 scripts/agent_cast_ledger.py next --json
```

Local proof is recorded separately from CI and readiness in
[tasks.json](../../docs/agent-cast/tasks.json). Read the referenced receipts before
advancing a gate.

The `Agent-cast Foundation` workflow qualifies this experiment on Linux and
macOS using the same runner. It supplements the repository's product checks.
The local checkpoint has no CI result until a permitted contributor publishes
the branch and those checks run on its exact commit.
