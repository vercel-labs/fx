# Workspace capture evidence prototype

This directory supports [the capture plan](../WORKSPACE_CAPTURE_PLAN.md). It is not part of fx's runtime, build, or CI. It does not enable capture in fx.

## Files

| File | Purpose |
| --- | --- |
| `run.sh` | Git fixtures, capture prototype, restoration comparisons, concurrency regressions and mutation switches |
| `list_indexer.zig` | Lists eligible paths using fx's current native indexer; compiled against a temporary copy of `src/` |
| `budget.py` | Budget maintenance prototype driven by an explicit session manifest |
| `test_budget.py` | Tests selection, eviction, active-session protection and real Git reclamation |

## Run from the checkout root

Requires the checkout's Zig version, Bash, Python 3 and `/usr/bin/git`. Current evidence is from macOS. Keep `/usr/bin/git` and platform-specific commands in mind before attempting this on Linux; cross-platform verification is still pending.

```sh
bash -n capture-prototype/run.sh
bash capture-prototype/run.sh
LIST_MODE=git bash capture-prototype/run.sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s capture-prototype -p test_budget.py -v
```

Both shell runs currently report `86 passed, 0 failed`. The Python suite has 6 tests. A successful run exits with 0. Do not pipe a test command through another command without `pipefail`, or its failure status may be lost.

The normal suites create fixtures and stores under temporary directories and remove them on exit. They isolate HOME and Git configuration. Zig compilation may use its normal compiler caches. No provider credentials or model calls are needed. No files are restored into the developer's checkout.

## Qualify a regression test

Mutation runs deliberately reintroduce a known defect and must exit nonzero. They are not supposed to pass.

```sh
MUTATION=shared_temporaries bash capture-prototype/run.sh
MUTATION=fresh_copy bash capture-prototype/run.sh
MUTATION=keep_flags bash capture-prototype/run.sh
MUTATION=stale_sparse bash capture-prototype/run.sh
MUTATION=shared_index bash capture-prototype/run.sh
```

Other switches are `no_skip`, `no_tracked`, `no_stale`, `link_any` and `late_touch`. Test 28 forces the cross-worktree interleaving with a barrier rather than hoping a race occurs. The shared-temporaries variant also changes diagnostic locations: failures outside test 28 are not independent proof of that race.

## Optional measurement on a real repository

This opt-in mode reads that repository's file contents and writes the captured content to a temporary store. Do not point it at sensitive or large workspaces without reviewing the script and its scope. The normal tests do not need it.

```sh
PERF_REPO=/absolute/path/to/repository bash capture-prototype/run.sh
```

## Limits

The shell prototype implements selected mechanisms, not every policy in the plan. It does not enforce the complete time/byte budgets, provide production-safe initialization and maintenance coordination, or integrate with Sessions v2, permissions or runtime cancellation.

`budget.py` assumes its caller supplies a consistent session manifest and excludes capture writers during maintenance. The tests check selector behavior and actual reclamation, not a production inventory or crash-recovery protocol. It journals outside stores and never edits inactive session logs.

Passing these checks does not prove product readiness. Port the relevant regressions to their owning Zig modules, then exercise the integrated behavior with the built fx binary and fake Gateway.
