# OpenSpec — fx Windows x86_64 support

> Source of truth for the `feat/windows-support` branch at
> `C:\programas\fx` (fork `DarakoG/fx`, upstream `vercel-labs/fx`).
> Authored 2026-08-24 as a cross-device / cross-person handoff.

## Index

| File | Purpose |
| --- | --- |
| `changes/windows-support-baseline/proposal.md` | Executive summary, why, what changes, constraints, coordination, known blockers |
| `changes/windows-support-baseline/design.md` | Architectural decisions, comptime patterns, capability table, every abstraction |
| `changes/windows-support-baseline/tasks.md` | 13 phases, 41 tasks; 31 complete, 10 open |
| `changes/windows-support-baseline/specs/shared-io-helpers/spec.md` | Delta spec for `homeDir`, `tempDir`, `getenvCaseInsensitive`, `permissionsFromMode/ToMode`, `realpathAlloc`, `OpenRegularFileError` |
| `changes/windows-support-baseline/specs/windows-platform-support/spec.md` | Delta spec for the Windows-side runtime support that has already landed (TTY, signals, CLI argv, MCP probes, doctor realpath) |
| `changes/windows-support-baseline/specs/windows-build-readiness/spec.md` | Toolchain / stdlib bug requirements, CI job, installer, self-upgrade, native hosts, docs |

## How to read this in 5 minutes

1. Read `proposal.md` to understand intent and constraints.
2. Skim `tasks.md` to see what is done and what is open.
3. Read `specs/windows-build-readiness/spec.md` to understand the
   open blockers.
4. Drop into `design.md` and the per-spec files for detail when you
   need to implement or audit a specific area.

## How to continue the work

The 10 open tasks live in `tasks.md`. The execution order suggested
by the design is:

1. **Resolve Zig stdlib bugs** (gate for everything else).
   - Try `unzip` or `Expand-Archive` on the Zig 0.17-dev nightly
     zip already downloaded.
   - Alternative: try a Zig 0.16.x patch release when one ships.
2. **CI workflow** (`T-F9.1-3`) — once the stdlib bugs are fixed,
   add `.github/workflows/windows.yml`.
3. **Self-upgrade ZIP** (`T-F7.1-3`) — `extractTarGz` →
   in-process ZIP; `replaceBinary` → `MoveFileEx`.
4. **Native hosts** (`T-F8.1-3`) — clipboard, URL, keychain.
5. **Docs** (`T-F11.1-3`) — `docs/windows.md`, README,
   CHANGELOG.
6. **Open the PR** (`T-F13.4`).

## What does NOT change for Linux/macOS

Because every Windows branch is `comptime`-gated, the Linux/macOS
build is byte-identical to `vercel-labs/fx` upstream. The CI
matrix on `main` continues to gate the PR without modification.

## Coordination

- **Fork**: `https://github.com/DarakoG/fx`
- **Upstream**: `https://github.com/vercel-labs/fx`
- **Branch**: `feat/windows-support`
- **Issue**: https://github.com/vercel-labs/fx/issues/254

## Companion docs at the repo root

These four `WINDOWS_*.md` files are committed in the handoff commit
but stripped before the upstream PR opens:

- `WINDOWS_BUILD_RECIPE.md` — reproducible build recipe (181 lines).
- `WINDOWS_SUPPORT_ANALYSIS.md` — full technical audit (383 lines).
- `WINDOWS_SUPPORT_PLAN.md` — 13-phase plan with state per phase
  (279 lines).
- `WINDOWS_SUPPORT_SUMMARY.md` — summary for the upstream PR
  description (288 lines).

The OpenSpec is the durable source of truth. The `WINDOWS_*.md`
files are coordination-only snapshots.