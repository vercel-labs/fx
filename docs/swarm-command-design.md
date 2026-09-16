# `/swarm` design note

Status: sketch for the fx side of Puppetmaster swarm visibility. Renders in fx's
inline style; PM contributes data only.

## Caller's usage

```
/swarm                 # latest job in this workspace's PM state dir
/swarm <job-id>        # one job by id
/swarm findings        # findings-only for the latest job
```

`/mcp`, `/skills`, and `/workspace` are subcommand-style commands with
`has_args = true` and `accepts_payload = true`; `/swarm` follows that shape.

## Where each piece lives

- `src/core/slash_commands/command_specs.zig` - `SlashKind.swarm` + `SlashSpec`.
- `src/core/slash_commands/command_router.zig` - `ParsedCommand.swarm`, a
  `handle_swarm` handler field, and the route case.
- `src/builtins/commands.zig` - the spec row and the `slash_specs` list entry.
- `src/core/app/app_commands.zig` - `commandHandlers` wiring plus `commandHandleSwarm`.
- `src/core/swarm/snapshot.zig` (new) - pure parsing of PM JSON into an owned
  snapshot, plus pure rendering to text. No process, no fs, no app state.
- `src/core/swarm/provider.zig` (new) - the bounded `pm` invocation and JSON
  decode, injected as a function pointer so the App (and tests) can substitute it.

New module directory because this is a product capability with its own data
contract, not part of MCP, skills, or workspace.

## Data contract (captured from the real CLI, not assumed)

Only some PM commands emit JSON. Verified against `puppetmaster` on this machine:

- `status <job> [--compact]` -> one JSON object. Keys: `job`, `tasks`,
  `task_counts`, `artifact_count`, `frontier`, `progress`, `delivery`,
  `outcome`, `stale_task_ids`. `status` has *no* `--json` flag; it is always JSON.
- `feed <job> [--json]` -> a JSON **array** whose items are
  `{id, at, event, artifact}`; `artifact` is `{job_id, task_id, type, created_by,
  payload}`. Observed `type` values include `finding`, `verification`, `routing`,
  `gist`, `patch`.
- `effort-index --json` -> `{effort_id, jobs, count, refs, ...}`.
- `last --json` -> `{job_id, status, state_dir, goal_preview, role_count,
  finding_count, store_scope}`.
- `jobs` -> **TSV, no `--json`**. Not used.

The snapshot keeps only what it renders and tolerates missing keys, because PM
adds fields over time and a schema addition must not break the view.

## Design A (chosen): one bounded `pm status` + `pm feed --json`, rendered inline

One handler, two child processes, both bounded. Parse into an owned snapshot,
render text, write it as a domain notice. Reuses fx's existing
`std.process.run` capture pattern (as `processMemorySnapshot` does).

## Design B (rejected): long-lived follower

`live_artifacts_follow` streams deltas. Rejected for v1: it needs a background
thread, a cancellation path, and cooperating rendering with the inline
transcript, which turns a read-only view into a live subsystem. A one-shot
snapshot answers the question the command exists for, and the follower can be
added later behind the same provider seam.

## Design C (rejected): read PM's state dir directly

Read `jobs/<id>/artifact_index.json` with no subprocess. Rejected: it hardcodes
PM's private on-disk layout and project hashing, which is exactly the coupling
that breaks. The CLI JSON is the supported surface.

## Red flags rejected while screening A

- **Guessing JSON shape.** Captured real output first; `status` has no `--json`
  and `feed` returns an array, neither of which a guess would have produced.
- **Unbounded output.** `status` embeds full goal/instruction prose and `feed`
  can be long, so both reads are byte-capped and the renderer clips with a
  visible suffix rather than printing megabytes into scrollback.
- **Absolute `pm` path.** The binary is `puppetmaster` on PATH with
  `PUPPETMASTER_COMMAND` as the override, matching how the PM fx adapter treats
  its own executable rather than inventing a hardcoded location.
- **Blocking the render thread forever.** A missing binary, a non-zero exit, or
  invalid JSON each produce a short notice, never a hang; the child is bounded by
  a deadline.
- **Inventing a second rendering path.** Output goes through the same
  `writeDomainNotice` path as `/mcp` and `/skills`.