# macOS arm64 PGSO candidate pipeline

This directory owns the non-publishing Stage 1 build for a smaller macOS arm64 `fx` candidate. It preserves Zig ReleaseSafe semantics and the complete product feature set, then uses native LLVM profiles to keep measured hot code speed-oriented and compile profile-proven cold functions for size.

The candidate is accepted only when it is no larger than **7.800 MiB**, has the preferred **0.250 MiB** of size headroom, passes the deterministic product corpus, and stays within a **10%** p50 and p95 performance regression limit. The ordinary ReleaseSafe binary remains the control and recovery path.

## Toolchain and target

The driver fails unless all of these match exactly:

- macOS on an arm64 host
- generic `aarch64-macos` output
- Zig `0.16.0`
- LLVM `21.1.8` tools and profile runtime from one configured LLVM root
- Bun `1.3.14`
- Hyperfine `1.20.0`
- the selected source commit, update channel, bitcode hash, corpus hash, and profile-generation flags

The pipeline does not use the host CPU as the release target. The final candidate must match the control's architecture and minimum macOS version, contain a valid code signature, contain no profile sections or profile-runtime dependency, and produce no profile output when executed.

## Commands

Every mutating command requires a fresh or empty output directory. State from separate runs is never merged implicitly.

```bash
python3 -m scripts.pgso build \
  --llvm-bin "$(brew --prefix llvm@21)/bin" \
  --output-dir /tmp/fx-pgso-build

python3 -m scripts.pgso train \
  --llvm-bin "$(brew --prefix llvm@21)/bin" \
  --output-dir /tmp/fx-pgso-train

python3 -m scripts.pgso all \
  --llvm-bin "$(brew --prefix llvm@21)/bin" \
  --output-dir /tmp/fx-pgso-candidate \
  --target aarch64-macos \
  --update-channel stable \
  --samples 50
```

`build` verifies the control, bitcode, instrumented link, profile-section alignment, signature, and one profile-producing smoke. `train` additionally runs the versioned corpus and creates a checked candidate. Both are useful diagnostics but finish with `eligible: false` because they do not run the complete release-safety gate.

`all` runs the complete fresh-build path: training, profile use, candidate verification, the candidate behavior corpus, six startup comparisons, and six heavy-workload comparisons. It is the canonical CI entry point. `report --output-dir <path>` is the only command that may reuse an existing directory, and it only reads a complete eligible manifest.

The production workflow runs the same gate as a distributed DAG. One seed job
builds the control, bitcode, and instrumented binary. Up to twenty training
jobs execute non-overlapping corpus assignments, one coordinator validates and
merges every shard profile, builds three dedicated heavy-workload benchmark
pairs, adds their hash-compatible speed evidence to the production profile,
and builds the candidate. Up to twenty behavior jobs then verify
non-overlapping candidate assignments. The six startup and six heavy-workload
comparisons run on twelve fresh machines. Every performance job measures its
immutable control and candidate on the same machine.

`python3 -m scripts.pgso.distributed plan` emits deterministic, non-empty
GitHub Actions matrices. The remaining distributed subcommands are workflow
phase interfaces: `train-shard`, `candidate`, `behavior-shard`, `measure`, and
`aggregate`. They reject a source, corpus, toolchain, bitcode, instrumented
binary, candidate, assignment, or shard identity mismatch. The aggregate
command requires all 36 training scenarios, all 53 behavior scenarios, and all
12 performance gates exactly once before it emits `eligible: true`.

## Corpus

[`corpus.json`](corpus.json) references existing test owners instead of copying their behavior. Training contains six direct CLI commands and thirty deterministic E2E files covering CLI, configuration, tools, Gateway lifecycle, fake web and vision routes, ACP, modern and legacy MCP, sessions, terminal hosting, TUI startup, resizing, rendering, permissions, interruption, subagents, and recovery. A bounded `profile_runs` count can weight a direct training command without duplicating manifest entries or final behavior checks. Seventeen additional deterministic E2E files verify the final candidate without influencing LLVM's hot and cold classification.

Every root `tests/e2e/*.test.ts` file must be classified as training, verification-only, or intentionally excluded. The corpus loader fails on missing, duplicate, stale, or unclassified files, so a new E2E owner cannot silently bypass release qualification. New tests added to an already classified file inherit that file's classification.

Sound-bearing `notifications.test.ts` and `tui-command-permissions.test.ts` are explicitly excluded. The credential-dependent `tui-agent.test.ts` suite is replaced by deterministic fake-Gateway permission-error coverage. Live-model and live-network files are forbidden. Corpus processes receive per-scenario homes and isolated tmux sockets and cannot inherit model credentials, the caller's tmux session, an external LLVM profile destination, or caller-selected fx tracing. The CLI and MCP authentication suites explicitly link the host Keychains directory into only their scenario homes so their uniquely named fake macOS Keychain assertions can run; no other scenario receives that access.

Each training scenario must create a new nonempty raw profile. The driver merges that batch into the accumulator atomically, deletes only the successfully merged raw files, and stops before profile use on any missing scenario, timeout, warning, merge failure, or cleanup failure.

Tmux-backed E2E scenarios receive one bounded file-level retry, matching Full
CI. Before that retry, the driver removes the failed scenario HOME, isolated
tmux directory, debug trace, and every raw profile created by the failed
attempt. A second failure remains terminal. Direct commands and non-tmux E2E
scenarios are never retried.

Candidate behavior qualification records each scenario's debug trace under `candidate-behavior/traces/` without restricting its trace scopes. A failed tmux case therefore preserves its internal startup subtype and cleanup evidence instead of retaining only the public protocol error, while tests that select their own trace path or scopes keep their intended behavior.

## Qualification policy

Startup compares `help`, `--version`, `status --json`, `doctor --json`, and `sessions --json`. It first executes each verified immutable artifact once to require successful output and empty stderr. Timing then uses pinned Hyperfine with no intermediate shell, ten warmups per artifact in each of at least 100 alternating rounds, and at least 1,000 measured samples per artifact. No contiguous block exceeds ten measured runs, so short machine-noise bursts are distributed between control and candidate while p95 retains 50 tail observations. Startup measurement sets `FX_DISABLE_KEYCHAIN=1` so the compiler comparison cannot be dominated by host-global macOS Keychain subprocess latency; the deterministic behavior corpus remains responsible for exercising Keychain integration. No per-sample Python process management or evidence-file write is included in the timed boundary, and measurement never replaces `zig-out/bin/fx`. Heavy qualification compares file indexing at 100,000 paths, UI activity, and approval transcript, diff, combined, and large-payload workloads.

Heavy comparisons use at least 50 measured samples for each artifact and alternate pair order AB then BA. Command failures and timeouts fail qualification and are never replaced. A candidate fails when either p50 or p95 is more than 10% slower than its matching control. The existing Linux startup workflow remains the authority for the repository's absolute 2 ms command budget.

The heavy benchmarks are trained once by the candidate coordinator, not rebuilt
by measurement jobs. For each benchmark, the coordinator selects only functions
inside the workload's owned source families that remain speed-shaped in the
benchmark's profile-use IR. Counts enter the production profile only when the
production and benchmark records have the same LLVM function hash and counter
layout. Counts are normalized against the production profile's cold cutoff so a
synthetic benchmark cannot dominate ordinary product behavior. The final
production IR must prove that every transferred function is speed-shaped or was
optimized away. The coordinator then maps the complete final production profile
into each benchmark module. Exact function-hash and counter-layout matches keep
their real benchmark names; every unmatched record receives an inert name so
LLVM sees the same global count distribution without applying unrelated counts.
Each measured benchmark candidate is rebuilt from that mapped production
profile, and the transferred functions must again be speed-shaped or optimized
away. Heavy measurement manifests retain the production, training, mapped,
supplement, and binary hashes, and aggregation rejects any mismatch.

## Output and failure behavior

The output root contains:

```text
control/bin/fx
instrumented/fx
candidate/fx
profiles/merged.profdata
profiles/supplements/
heavy/
candidate-behavior/traces/
logs/
measurements/
manifest.json
```

Generated binaries, bitcode, objects, profiles, caches, measurements, and logs are evidence artifacts and must not be committed. `manifest.json` is rewritten atomically after every stage. A failed manifest retains completed evidence, names the failing stage, records `eligible: false`, and never falls back to an unprofiled candidate.

The driver also streams operational progress to the invoking terminal or GitHub Actions log. Every stage announces its start and terminal status with elapsed time, every child command announces its start and terminal status, and child stdout and stderr remain visible while the process runs. A silent child emits a heartbeat every 30 seconds. JSON evidence retains at most the last 1,048,576 characters from each output stream per command and records the total character counts and truncation status; no environment variables are printed.

Corpus scenarios inherit only a small operating-system environment allowlist. Credentials, live-test flags, tracing settings, and repository dotenv files are excluded unless a value is explicitly declared in the versioned corpus. The runner temporarily installs the assigned artifact at `zig-out/bin/fx` for E2E compatibility, then restores the prior file (or prior absence) after success, failure, timeout, or cancellation.

The native workflow uploads bounded phase evidence rather than caches or
intermediate compiler objects. Pull requests and manual runs have read-only
repository permissions and do not change release, dev-channel, CDN, tag, or
GitHub Release state. The stable release workflow may call the same gate with
release packaging enabled; only the candidate copied by the successful final
aggregate is packaged as `fx-macos-aarch64.tar.gz`.
