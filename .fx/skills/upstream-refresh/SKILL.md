# Upstream refresh

Use this skill when updating attached OMIFX worktrees from `upstream/main`.

## Deterministic lifecycle

Prepare one pinned session:

```bash
python3 scripts/upstream_refresh.py prepare
```

The command records the exact upstream SHA, `origin/main` base SHA, and a
session-owned integration worktree under the common Git directory. It includes
the repository root, attached branches, detached worktrees, dirty worktrees,
and worktrees with active Git operation markers in the JSON plan. It never
mutates an entry marked skipped.

The integration phase is authoritative upstream plus the current OMIFX base.
When it conflicts, resolve that one integration worktree first. Do not resolve
the same upstream conflict independently in every feature worktree. Record the
decision and verify the integration result before applying branches.

When the plan phase is `ready`, apply it:

```bash
python3 scripts/upstream_refresh.py apply --plan /path/to/plan.json
```

Each clean branch is rebased from its recorded fork point onto the same
integration commit. A backup ref is created before mutation. The command
rechecks branch tip, worktree cleanliness, and Git operation markers so a stale
plan refuses drift rather than rebasing newer work.

## Agent conflict policy

Prefer upstream architecture, APIs, and behavior by default. Preserve an OMIFX
change only when it is an intentional feature not replaced upstream; adapt that
feature to the current upstream implementation instead of retaining obsolete
local structure. Never use blanket `git checkout --ours` or `--theirs`, reset a
worktree, or discard uncommitted work.

For every semantic conflict, write down the file, upstream choice, preserved
OMIFX behavior, and verification command in the agent report. Resolve conflicts
in the session-owned worktree only, then run the focused build/test and
`./zig-out/bin/fx` smoke check required by `AGENTS.md`.

Inspect or hand off a session without changing it:

```bash
python3 scripts/upstream_refresh.py status --plan /path/to/plan.json
```

Dirty, detached, missing, and active-operation worktrees are intentionally
left for explicit agent/user handling. Do not stash or reset them implicitly.
