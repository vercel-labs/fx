# macOS arm64 PGSO candidate pipeline

This directory owns the non-publishing Stage 1 build for a smaller macOS arm64 `fx` candidate. It preserves Zig ReleaseSafe semantics and the complete product feature set, then uses native LLVM profiles to keep measured hot code speed-oriented and compile profile-proven cold functions for size.

The candidate is accepted only when it is no larger than **7.000 MiB**, has the preferred **0.250 MiB** of size headroom, passes the deterministic product corpus, and stays within a **10%** p50 and p95 performance regression limit. The ordinary ReleaseSafe binary remains the control and recovery path.

## Toolchain and target

The driver requires:

- macOS on an arm64 host
- generic `aarch64-macos` output
- Zig `0.17.0`
- LLVM `22.1.8` tools, profile runtime, and C library (`lib/libLLVM.dylib`) from one configured LLVM root
- the selected Xcode macOS SDK and native Apple linker with arm64 support
- Bun `1.3.14`
- Hyperfine `1.20.0`
- the selected source commit, update channel, bitcode hash, corpus hash, and profile-generation flags

The pipeline does not use the host CPU as the release target. The final candidate must match the control's architecture, minimum macOS version, SDK compatibility stamp, main-stack request, and dynamic-library dependency versions. It must contain a valid code signature, contain no profile sections or profile-runtime dependency, and produce no profile output when executed.

The target-specific steps live in a platform module, which [`platforms.py`](platforms.py) selects for the requested target: the host check, native tools, the instrumented and candidate links, the control properties the candidate must match, and the candidate's layout checks. [`macos.py`](macos.py) builds `aarch64-macos`, and [`linux.py`](linux.py) builds `aarch64-linux`. The profile, outlining, corpus, and measurement stages are shared.

The Linux platform runs on an arm64 Linux host and needs `ld.lld`, `llvm-readelf`, the `aarch64-unknown-linux-gnu` profile runtime, and `lib/libLLVM.so` from the same LLVM root. Zig links the static musl control with its own `ld.lld`, so the control build records that exact link (`--verbose-link`), and the instrumented and candidate links rerun it with only the Zig object replaced. The candidate must match the control's ELF class, type, machine, OS ABI, segment types, first load address, stack segment, and whether it has interpreter, dynamic, TLS, and note segments. It must contain no profile sections.

Profile use compiles the functions it judges cold for size, which slows Linux's short commands such as `fx help`. So training keeps a profile for each of the startup scenarios `direct-help`, `direct-version`, `direct-status`, `direct-doctor`, and `direct-sessions`. Before profile use, a first pass applies the production profile to find the startup functions marked `minsize`, and their records are removed from the production profile. Startup functions that stay hot, those the build inlines away, and those any heavy benchmark runs keep their records: the benchmarks build from the production profile, so removing a record they rely on would slow them. Every startup function is also marked `nooutline`, so neither outliner moves its code into shared helpers far from the rest of the startup code. The candidate link places the startup functions first, in the order they first run. Distributed builds don't carry the startup profiles, so they reject Linux. `.github/workflows/pgso-linux-arm64.yml` runs `all` for `aarch64-linux` in one job on a GitHub-hosted arm64 runner and uploads the manifest, logs, measurements, and candidate. Releases don't use it yet.

Training records execution counts and first-use function timestamps in the same
continuous profiles. Counter supplements preserve the temporal traces. The
main PGSO executable uses LLVM's temporal function order through the native
Apple linker; benchmark and other native release links keep their existing
paths. Identical-code folding stays disabled. The function-starts table is
omitted, matching the existing stripped Zig link. The exact optimized Zig
runtime object and bundled system-library stub remain the link inputs; the
selected Xcode SDK supplies re-export stubs. Compatibility and sysroot SDK
versions are recorded separately. Build evidence retains input digests, every
mapped or unmapped profile name, the full linker map, and verified ordered code
counts. Empty or ambiguous mappings, an unapplied order, and truncated symbol
output fail closed.

## Commands

Every mutating command requires a fresh or empty output directory. State from separate runs is never merged implicitly.

```bash
brew install llvm@22

python3 -m scripts.pgso build \
  --llvm-bin "$(brew --prefix llvm@22)/bin" \
  --output-dir /tmp/fx-pgso-build

python3 -m scripts.pgso train \
  --llvm-bin "$(brew --prefix llvm@22)/bin" \
  --output-dir /tmp/fx-pgso-train

python3 -m scripts.pgso all \
  --llvm-bin "$(brew --prefix llvm@22)/bin" \
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

The fx candidate applies the accepted whole-program profile-use pipeline, then
runs LLVM's IR outliner once over the whole optimized program. Generated IR
helpers are kept in one dense linker cluster ordered by their hottest profiled
caller so outlining does not scatter startup code across cold pages.

Code generation for the fx candidate runs the AArch64 machine outliner a second
time and enables LLVM's homogeneous prologue and epilogue. Each function that
profile use compiled for size then saves and restores its callee-saved
registers by calling one of a few dozen shared frame helpers instead of
repeating those loads and stores inline. Functions compiled for speed keep
inline prologues. fx builds without frame pointers or unwind tables, so the
helpers change no stack walking. Benchmark candidates keep the default code
generation.

LLVM's IR outliner does not compare constants nested inside a constant
expression. Two regions that differ only in an instruction's constant can share
one parameter that also replaces a nested constant, so one of them reads the
wrong address. Before each outliner run, `ir_size.py expand-constant-exprs`
rebuilds the constant expressions that instructions use as instructions, so the
outliner compares every constant. Afterwards, `ir_size.py check-outlined` fails
the run if an outlined function still holds a constant expression the outliner
rebuilt from a parameter. Benchmark candidates take the same two steps.

The IR outliner also matches `a > b` with `b < a` by reversing the operands it
compares, but it passes the reversed region's operands to the outlined function
in their original order, so that region computes `a < b`. A PGSO build turned a
skill file read's bounds check around this way and panicked on the first chunk.
After `expand-constant-exprs` and before each outliner run, `ir_size.py
swap-compares` rewrites each greater-than comparison as the less-than
comparison with its operands swapped, so the outliner only matches comparisons
written the same way.

Four size passes in [`ir_size.py`](ir_size.py) run through the pinned LLVM C
library. Right after Zig emits bitcode, `outline-helpers` marks small shared
std helpers `noinline`: the allocator's slice `free`, `remap`, and aligned
allocation, the writer's `write`, `writeAll`, `writeByte`, and
allocating-writer setup and teardown, the byte list's `appendSlice`, every
list's `deinit`, `mem.eql`, `mem.startsWith`, `ascii.eqlIgnoreCase`, and the
`Io.Mutex` lock and unlock. Zig otherwise copies
them into thousands of call sites (`free` alone into about 11,000). The pass
runs before instrumentation, so training, profile use, and the recorded
bitcode identity all include it. It reports matches per pattern and fails if
the allocator `free` helper does not match. After profile use and outlining,
`sparse-constants` rewrites copies from mostly undefined internal constants
into stores of their defined bytes. Zig emits such a constant for each
`return error.X` from a function returning a large error union. Undefined
bytes become "destination unchanged", a refinement of copying undefined
bytes; explicit values, including zeros, are still stored. The constants it
cannot rewrite, because a load, a PHI, or a call still reads them, go to
`overlay-constants`, along with `return null` results of large optionals. It
packs them into one constant where they overlap: they are `unnamed_addr`, so
only their defined bytes matter, and two may share bytes wherever neither
defines a byte the other defines differently. Each becomes an alias of its
offset. Members that hot code reads, or that are under 64 bytes, never
receive another member's nonzero byte in their undefined bytes, so their
copies still compile as before. `zero-fill-globals` then moves internal
writable globals of at least 4 KB whose nonzero bytes fit in 64 bytes to
zero-fill, which takes no space in the file, and stores those bytes at the
start of `main`, or of the function Zig's `main` alias names. Even one nonzero
byte otherwise writes the whole global out; std's `Progress` state is 18 KB for
a single 255. Nothing reads these globals before `main`, and no later stage
folds the stores back into an initializer. `compact-error-names` then reads
every error name through one function: Zig's `__zig_error_name_table` holds a
16-byte pointer and length per error, about 26 KB of relocated data, and each
`@errorName` reads it in place. The function returns the same pointer and
length from 16-bit offsets into one blob of the same NUL-terminated names.
Where a PHI merges an entry with another pointer, or a call passes it to a
function that only reads it, such as a pair copy the IR outliner made, the
pair goes to a stack slot laid out like the entry. Any entry or use the pass
does not recognize leaves
the table unchanged. `globaldce,verify` then drops the dead constants. Benchmark artifacts receive every pass so their candidates keep
the production code shape. The candidate link passes
`-no_compact_unwind`: fx builds without unwind tables, and newer Apple linkers
otherwise emit about 160 KB of compact unwind data.

`python3 -m scripts.pgso.distributed plan` emits deterministic, non-empty
GitHub Actions matrices. The remaining distributed subcommands are workflow
phase interfaces: `train-shard`, `candidate`, `behavior-shard`, `measure`, and
`aggregate`. They reject a source, corpus, toolchain, bitcode, instrumented
binary, candidate, assignment, or shard identity mismatch. The aggregate
command requires all 36 training scenarios, all 53 behavior scenarios, and all
12 performance gates exactly once before it emits `eligible: true`.

Workflow artifact names include the producing run attempt, so earlier attempts
remain available. Seed and candidate consumers use the artifact IDs returned
by their producer jobs. Shard collection selects the newest attempt for each
shard; a failed or invalid newest result cannot fall back to an earlier pass.
Source and artifact hashes must still match before aggregation can qualify a
release. Overwrite applies only to an identical attempt-qualified name.

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

Startup compares `help`, `--version`, `status --json`, `doctor --json`, and `sessions --json`. It first copies each verified immutable artifact into the measurement directory and checks that the copy's SHA-256 matches, so both binaries start from the same page-cache state: on Linux a binary whose pages were read back from disk can start 10 to 15 percent slower than one written moments ago. It then executes each copy once to require successful output and empty stderr. Timing then uses pinned Hyperfine with no intermediate shell, ten warmups per artifact in each of at least 100 alternating rounds, and at least 1,000 measured samples per artifact. No contiguous block exceeds ten measured runs, so short machine-noise bursts are distributed between control and candidate while p95 retains 50 tail observations. Startup measurement sets `FX_DISABLE_KEYCHAIN=1` so the compiler comparison cannot be dominated by host-global macOS Keychain subprocess latency; the deterministic behavior corpus remains responsible for exercising Keychain integration. No per-sample Python process management or evidence-file write is included in the timed boundary, and measurement never replaces `zig-out/bin/fx`. Heavy qualification compares file indexing at 100,000 paths, UI activity, and approval transcript, diff, combined, and large-payload workloads.

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

The driver also streams operational progress to the invoking terminal or GitHub Actions log. Every stage announces its start and terminal status with elapsed time, every child command announces its start and terminal status, and child stdout and stderr remain visible while the process runs. A silent child emits a heartbeat every 30 seconds. JSON evidence normally retains at most the last 1,048,576 characters from each output stream per command. The candidate symbol census permits 8,388,608 characters and rejects truncated output. Records include total character counts and truncation status; no environment variables are printed.

To compare a qualified PR merge with its exact main parent, or a qualified
manual branch head with its exact main ancestor, dispatch the
**Benchmarks** workflow on the comparison branch with `pgso_control_artifact`
and `pgso_candidate_artifact` set to the two qualified aggregate artifact IDs.
The main control may come from the dedicated PGSO workflow or the Release
workflow that invokes it. Release runs keep their aggregate evidence for 90
days, so the last release can serve as the control. Both artifacts must have completed qualification.
The candidate must come from the dedicated PGSO workflow. For source-only PRs,
run that workflow manually on the PR branch. Its manifest source must match the
run head, and GitHub's immutable SHA comparison must prove that exact control
is both the base and merge base, with no behind commits and a complete nonempty
ahead commit list ending at the candidate. Missing or truncated ancestry is
rejected. The manual candidate branch cannot be `main`.
Leave `signed_run` empty. The native macOS arm64 job downloads those immutable
artifacts without rebuilding them, checks their run/source relationships and
binary hashes, then measures normal and recovered no-history requests. It runs
identical-control calibration before paired memory and latency comparisons,
rejects uncalibrated or resolved-regression results, and retains raw evidence.
These checks supplement the production PGSO gate; they do not replace it or
prove performance for every workload. Legacy aggregate names are accepted only
from a first-attempt run; attempt-qualified names must match the run attempt.

Corpus scenarios inherit only a small operating-system environment allowlist. Credentials, live-test flags, tracing settings, and repository dotenv files are excluded unless a value is explicitly declared in the versioned corpus. The runner temporarily installs the assigned artifact at `zig-out/bin/fx` for E2E compatibility, then restores the prior file (or prior absence) after success, failure, timeout, or cancellation.

The native workflow uploads bounded phase evidence rather than caches or
intermediate compiler objects. Pull requests and manual runs have read-only
repository permissions and do not change release, dev-channel, CDN, tag, or
GitHub Release state. The stable release workflow may call the same gate with
release packaging enabled; only the candidate copied by the successful final
aggregate is packaged as `fx-macos-aarch64.tar.gz`.
