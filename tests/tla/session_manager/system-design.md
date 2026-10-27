# Session Manager (Sessions v2) Design And Contracts

This document is canonical for the v2 format, API, contracts and decisions,
and the TLA+ specs in this folder model each step. It began as the design proposal and was kept
current through implementation, so the Decisions section also records what
implementation found. Decisions D1 to D19 were settled on 2026-09-27.

## Intent

**Outcome:** one self-contained Zig module, the session-manager, owns
everything about fx sessions:
- storage;
- the live-session lifecycle: create, append, resume, fork, close, delete;
- crash recovery and listing.

Each session is one append-only JSONL log. The interactive app, `fx ask`,
ACP, subagents and the wasm SDK reach sessions only through its API. It is
built and proven standalone, then wired into fx next to v1, then replaces
v1.

**Constraints and non-goals** that shape this design:
- Zig and the standard library only;
- no I/O until the first session call, because of the 2 ms startup budget;
- Linux and macOS;
- the host thread models;
- no daemon and no second writing process.

## Repository Evidence

All paths are relative to fx at `46408935b`.

- `src/core/session/session_store.zig::Store` (line 526) is the front desk. Its
  47 public methods open, list, delete and migrate; none of them appends.
- `src/core/session/session_log.zig::LoadedWritableSession.appendEvent`
  (line 3353) is the only writer. It routes six update kinds to four files.
- `src/core/session/session_log.zig::ConversationWriter.writePrepared`
  (line 537) does a positional write plus a plain `fsync` on every append.
- `src/core/session/session_log.zig::ConversationWriter.init` (line 150)
  cuts a torn frame and discards an unfinished turn on open.
- `src/core/session/session_event.zig::Envelope` (line 847) and
  `src/core/session/session_event.zig::ConversationEvent` (line 174) are
  today's line envelope and history event kinds.
- `src/core/agent/runtime/deps.zig::AgentRuntimeDeps` (line 189) holds the
  persistence callbacks the agent loop uses.
- `src/core/agent/runtime/orchestrator.zig:3857` (`persistRecoveryCheckpoint`)
  rebuilds the whole current turn at each of 13 step boundaries.
- The four host copies of the save logic:
  `src/core/app/app_session_runtime.zig::Persistence` (line 1210),
  `src/core/cli/cli_ask.zig:3102`, `src/acp/prompt.zig:2143`,
  `src/core/subagent/execution.zig:509`.
- `src/core/app/app_session_runtime.zig:2604` and `:1754` make `-c` remember
  only the interactive app's sessions; `session_store.zig:1168` resolves
  `--resume last` as the newest session in the workspace from any host.
- `src/core/session/session_log.zig:4060` shows today's atomic publish.
- `src/core/hosts/runtime_profile.zig::native` and `::wasm` are the capability
  profiles; wasm sets `js_host_sessions`.
- `sdk/fx-sdk.js:922` shows the embedder-supplied `sessionStore` with
  `load`, `commit(id, bytes, expectedRevision)`, `list` and `remove`; it
  backs `src/core/session/js_host_session_store.zig`.
- `src/acp/sessions.zig:45` (`handleNewLibfxSession`): the N-API host keeps
  sessions in memory only.
- `build.zig.zon` has no dependencies.
- End-to-end coverage: `tests/e2e/session-recovery.test.ts`,
  `tests/e2e/tui-resume-brutal.test.ts`,
  `tests/e2e/tui-interrupt-recovery.test.ts`, `tests/e2e/acp.test.ts`,
  `tests/e2e/cli.test.ts`, `sdk/tests/test-term-session-resume.mjs`.

## Current System And Contracts

**Current flow and owner:** the agent loop calls one of four host callbacks.
The host's own copy of the save logic calls `LoadedWritableSession`, which
writes five files. wasm writes whole snapshots through the embedder's
`sessionStore`. `Store` owns opening, listing and deleting; nothing owns the
live session as a whole.

**Binding contracts v2 must keep:**
- **One writer.** One writing process per session. A contender waits up to 2 s,
  then gets Busy.
- **Crash safety.** Committed turns survive an fx crash. An unfinished turn is
  never silently continued after an unclean exit, and asking stays sticky
  until the turn is resolved (`session_log.zig:38` comment).
- **Resume by id, by `--resume last` and through the picker.** `--resume last`
  means the newest session of any host.
- **`-c` returns to the session the interactive app last opened.** `fx ask`
  and ACP runs never change it.
- **Portability.** Sessions are global and portable, and each tracks
  `workspace_root` (fx `AGENTS.md`, Configuration and State).
- **Children.** Child sessions stay out of discovery and cannot be resumed
  directly. The parent collects a child's result by work id.
- **What survives resume.** Preferences, title, permissions, usage and the
  conversation language.
- **wasm embedders' `sessionStore` API keeps working.**
- **Private files.** Session folders are created `0700`, files `0600` and
  blobs `0400` (D49), and
  paths are opened without following symlinks, as v1 does
  (`session_log.zig:25`, `io_mod.VerifiedDir`). Sessions contain code and
  secrets.
- **Startup stays within the per-command budget.**

## Proposed Delta

**Approach:** add one module that owns session storage and the live-session
lifecycle.
- A session is a folder with `log.jsonl`, `lock` and `blobs/`.
- State is the fold of the log.
- The manager assigns `seq`, enforces the turn rules and takes every lock.
- fx reaches it through one adapter file.
- v2 is the only store; a v1 session converts when it is opened (D53, D59).

**Preserved:** every binding contract above, the host entry points, the
`sessionStore` SDK API, and the agent loop's existing callbacks.

**Changed:**
- **One log holds everything:** preferences, title, permissions, usage,
  workspace, conversation language, fx recovery details and children. v1 spread these over five
  files plus a child registry.
- **Streamed turns (D10).** Each completed piece of a turn is appended as it
  happens, through one new agent-loop callback, `append_turn_piece` (D12).
  The recovery checkpoint shrinks to fx's small recovery details.
- **No truncation (D1).** An unfinished turn gets `turn_interrupted` on
  reopen instead of being cut. `recovery.json`, `recovery.asked` and
  `owner.live` go away; flock is the only liveness signal.
- **Sync at durability points only (D3).** A plain `fsync` on every platform,
  and no fsync per line.
- **Lazy creation (D2).** A session folder is created at the first turn. There
  is no startup I/O and no delete-if-empty logic. Reads create nothing: with
  no root, `open(.resume)`, `read`, `get_blob` and `verify` return NotFound
  and `list` returns an empty page.
- **Checksums (D4).** Every line ends with a CRC32C field.
- **Snapshots (D7).** Snapshots after each compaction and every ~64 KB bound
  resume cost. The transcript is paged on demand.
- **Blobs (D6).** Large bodies move from fx's four stores into per-session
  blobs.
- **Index.** `index.jsonl`, derived and rebuildable, replaces
  `.resume-catalog`. It records host and open time, which keeps `-c` distinct
  (D11).
- **Children in the parent log.** They replace `children.json`,
  `children.lock`, `owner.json`, `control.json` and `relationship-index.bin`.
- **Fork is new** and starts only at turn boundaries (D5).
- **v1 conversion (D8).** A one-time background conversion carries every v1
  session into v2.
- **wasm (D9).** wasm persists through a JS-host storage level (L0) over the
  unchanged `sessionStore`.
- **Hosts hold no session locks.** The four host copies of the save logic
  collapse into the adapter.
- **Terminal state leaves the session folder (D13).** Hosted terminal state
  moves to an fx-owned `~/.fx/terminal/{session-id}/`, like Unix
  `/var/lib/{service}`. The terminal store keeps its own recovery protocol;
  only its base path changes.
- **Diagnostics through the caller (D14).** The manager reports every repair
  or drop through one optional callback; the adapter forwards it to
  `debug_trace`.
- **Session commands keep working (D15).**
  - `fx session recover` forks at the last good turn.
  - `fx session migrate` runs the conversion.
  - `fx sessions`, `fx session last|{id}` and doctor map onto `list`, `read`,
    `verify` and `rebuild`.

### On-disk layout

```text
~/.fx/sessions/v2/   inside v1's folder, which v1 skips (D19)
  index.jsonl        session list, one line per change, derived
  index.lock         flock held while appending to or rewriting the index
  .tmp/              staging for new, forked and imported sessions
  .trash/            sessions being deleted
  {id}/
    log.jsonl        the session; append-only; the only source of truth
    lock             empty file held with flock by the writing process
    blobs/{sha256}   large bodies, content-addressed, immutable
```

On wasm, the embedder's `sessionStore` holds each session's `log.jsonl`
bytes under its id, and the manager keeps the index in memory, rebuilt from
`list()`. Where blobs live on wasm is still open (inline in the log, or as
separate `sessionStore` entries), and the format gains nothing for it until
that is settled.

### Line format (persisted contract)

One event is one JSON object followed by `\n`. The last field is always
`crc`:

```text
{"v":1,"seq":7,"ts":1727400000000,"kind":"turn_committed","turn":1,"crc":"1a2b3c4d"}
```

- **Envelope:** `v` (format version), `seq`, `ts` (ms), `kind` and `crc`
  belong to the manager. Kind-specific fields sit between `kind` and `crc`.
  `data` holds fx content, which the manager stores but never interprets.
- **`crc`:** CRC32C, as 8 lowercase hex digits, of the exact bytes of the line
  before `,"crc":"`. The line stays valid JSON, so `jq`, `grep` and `tail`
  keep working.
- **`seq`:** starts at 1 on `session_created` and goes up by exactly 1 per
  line. Only the manager assigns it.
- **`ts`:** stamped by the manager. The one exception is a Session opened
  with `.import`, which keeps each event's original `ts`.
- **Validity:** a line counts only when it ends with `\n`, parses, and its
  `crc` matches.
  - A final line that is incomplete or fails those checks is torn and gets
    cut on open. That is the only shape a crash can leave.
  - A failing line before the final one, or a `seq` gap anywhere, makes the
    session readable only up to the last good line. A line with a good `crc`
    is never cut. Nothing is ever skipped silently.
- **Compatibility:** unknown kinds are skipped by the fold. A `v` newer than
  the manager supports opens read-only.
- **Size:** each line has a hard cap of 4 MiB, newline included. The
  adapter moves bodies above a smaller threshold into blobs.

| Kind | Fields | Written by | Rule |
|---|---|---|---|
| `session_created` | `workspace`, `role` (`root` or `child`), `host`, `parent` (child), `forked_from` (fork: `id`, `seq`) | manager | Always line 1; written with the first turn |
| `turn_started` | `turn` | host call; the manager assigns the number | Only when no turn is open |
| `item` | `turn`, `type`, `data`, `blobs` (optional hashes) | host, through `append_turn_piece` | Only inside an open turn; one line per completed piece, never per token; `type` is required, 1 to 32 of `a-z`, `0-9` and `_`, named by fx (D17); every blob named in `blobs` must already exist in the session |
| `compacted` | `turn` (inside a turn), `data` | host | Allowed at any time; a snapshot follows |
| `turn_committed` | `turn` | host | Ends the open turn |
| `turn_interrupted` | `turn`, `reason`: `cancel` or `failed` (host), `closed` or `crash` (manager) | host, or the manager on close or reopen | Ends the open turn (D21) |
| `set` | `key` (`prefs`, `title`, `permissions`, `usage`, `workspace`, `language`), `value` | host | Allowed at any time; the newest per key wins; before the first turn it is held in memory |
| `child_spawned` | `child`, `work_id`, `data` (optional, at most 4 KiB) | host (parent) | A new spawn, or a new work id for a persistent child; refused while that child has unfinished work (D22) |
| `child_finished` | `child`, `work_id`, `outcome` (`ok`, `failed`, `cancelled`, `interrupted`, `lost`), `data` (optional, at most 4 KiB) | host, or the manager on parent reopen (`interrupted`, `lost`) | That work item is the child's unfinished one; hosts never write `lost` (D22) |
| `snapshot` | `covers_seq`, `state`, `compaction_offset` | manager, after each `compacted` and whenever ~64 KB of log was written since the previous snapshot | Derived cache, never needed for correctness; skipped, with a diagnostic, when the state does not fit in one line |
| `closed` | none | manager on `close()` | Marks a clean exit |

The values of `prefs`, `permissions` and `usage`, and every `data` payload,
are JSON whose shape fx owns. `title` and `workspace` are strings that the
manager also puts in the index. Token counters (input, output, cost) live
inside fx's `usage` value; the index and `fx sessions` do not list them
(D25).

### Fold (how state is computed)

| State field | Comes from |
|---|---|
| identity (`id`, `role`, `host`, `parent`, `forked_from`, initial `workspace`) | line 1 |
| `open_turn` | a `turn_started` with no end line yet |
| turn counts | end lines, split by committed or interrupted |
| `last_interrupted` | newest `turn_interrupted`, with `reason` |
| `prefs`, `title`, `permissions`, `usage`, current `workspace`, `language` | newest `set` per key |
| `children` | one record per child, in first-spawn order, counting only lines after `forked_from.seq`: the newest `work_id`, whether that work is unfinished, the newest finished work's `outcome`, the newest `child_spawned` and `child_finished` `data`, and the seq of the child's newest line, which fx uses as a generation (D22) |
| `last_compaction_seq`, `compaction_offset` | newest `compacted` and its byte offset; fx's `data` may keep a tail of earlier lines, which the adapter reads back to |
| `clean_exit` | the last line is `closed` |
| `last_seq` | last good line |
| `created_ms`, `updated_ms` | `ts` of line 1 and of the newest line; 0 before the first turn (D20) |

A snapshot carries this state without the identity fields and the two
times: the session reads both from the log it opens and updates them on
every write, so they are not folded. Its
`compaction_offset` is a byte offset, and a fork's line 1 has a different
length, so a fork encodes each copied snapshot again from its own fold, with
the same `seq`. Folding from line 1 and folding from the newest snapshot must
give identical state (`ResumeSnapshot.tla`).

### API (the only boundary fx sees)

The manager is created once per process with
`init{root, backend: posix or js_host, diagnostics}`. `diagnostics` is an
optional callback (D14). It receives a typed event, with a kind, a session id
and numbers such as the bytes cut or the seq, for every repair or drop:
- a torn or bad-checksum final line cut;
- a session opened read-only after a damaged middle line;
- held settings discarded at a close before the first turn;
- an index self-heal;
- a rebuild sweep;
- a snapshot skipped because the state does not fit in one line;
- a converter skip or failure.

With no callback, the cost is one null check.

Thirteen operations:

```text
open(.new{workspace, role, parent, host, id})   -> Session   no disk I/O until the first turn; `id` for a child only (D34)
open(.resume{target, workspace, parent, host, lock_wait_ms})
                                                -> Session   Busy, NotFound, ChildSession, Corrupt, UnsupportedVersion
     target: id | .last (newest updated, any host) | .last_opened{host} (newest opened by that host)
     lock_wait_ms: this open's wait for the writer lock; unset uses the manager's (D38)
open(.fork{source, at_turn, workspace, host})   -> Session   new id at a turn boundary; NotFound, InvalidForkPoint
open(.import{id, workspace, role, parent, created_ts})
                                                -> Session   one-time v1 conversion only; Exists if the id is taken
append(session, events)                         -> last seq  InvalidTransition, SessionClosed, TooLarge, Io
put_blob(session, bytes)                        -> hash      returns once the blob is durable; InvalidTransition before the first turn, TooLarge, Io
state(session)                                  -> State     owned copy taken under the mutex, no I/O
read(id, from, direction, limit)                -> lines     lock-free; forward from a seq, or backward from the end
session.read(from, direction, limit)            -> lines     the open session's own log: no open; empty before the first turn; SessionClosed
get_blob(id, hash)                              -> bytes     NotFound
peek(id)                                        -> State     lock-free: line 1, the newest snapshot and the tail, as the catalog reads it (D37)
list(workspace or all, cursor, limit)           -> summaries reads the index only
close(session)                                               closed line, fsync, index, unlock
delete(id)                                                   Busy if open anywhere; removes owned children
```

- **Threads:** a `Session` is safe to use from any thread, and each call is
  atomic relative to the others on the same session.
- **Batches:** `append` writes a batch with one `write()`, and does an
  `fsync` before returning if the batch holds a durable-class event.
- **Child sessions:** resuming a child requires its `parent`; otherwise the
  result is ChildSession.
- **Host names:** `host` is one of `app`, `ask`, `acp`, `sdk` or `child`.
  `-c` maps to `.last_opened{host: app}`. `--resume last` maps to `.last`.

### fx mapping (the adapter's side)

The pre-wiring API check (2026-09-27) traced every host's persistence
through the API above. These rules live in `session_adapter.zig`, not in the
manager:
- **Item types and data:** each completed piece is one `item`, and its
  `data` comes from v1's piece codec (`encodeConversationFrame`,
  `src/core/session/session_event.zig` lines 439 to 482). The types are
  `user`, `assistant`, `tool_call`, `tool_result`, `steering`, `turn_end`
  (files and turn summary), `interruption` (reason detail, partial text,
  command refs, origin), `recovery` and `continues`.
- **Recovery:** the agent loop's checkpoint becomes a small `recovery` item
  (cause, action, tool state, attempts, route, partial text). The pieces it
  used to copy are already in the log (D10).
- **Continue (D23):** continuing an interrupted turn starts a new turn whose
  first item is `continues{turn}`; the adapter joins both turns when it
  rebuilds fx's history.
- **Turn endings:** an `interruption` item precedes `turn_interrupted`, whose
  reason is `cancel` or `failed` (D21).
- **Settings:** `set` replaces the whole value, so the adapter writes fx's
  merged preferences. `title` holds a JSON string; whether a title was
  generated or typed stays in fx's `prefs`.
- **Compaction:** `compacted.data` names the first turn fx keeps, which the
  adapter reads back to from `compaction_offset`, and how many of that
  turn's steps and steering messages the summary covers (D87).
- **Order:** `turn_started` comes before `put_blob`, which refuses earlier.
- **Subagents (D22):** names, the agent, the request fingerprint and failure
  text go in child `data`; a child's instructions go in the child's own
  `prefs`. fx checks its own rules (unique names, at most 256 children)
  under an in-process lock, which is enough because only the process holding
  the parent's flock can append to it. Unfinished work's message and
  root-user evidence stay in memory: v1 drops them on restart too
  (`child_state.zig` `interruptActive`), and the child's own log holds the
  message once its turn starts. A child's turn opens on disk when its work
  starts, as `Subagents.tla` `ChildStart` models, so the bodies its
  tools keep are blobs of a session on disk (D44);
  its pieces are written whole at its end, as v1's children are, while
  roots stream theirs (D28). A crash before that start leaves no log
  (`lost`); after it, the child's log keeps an open turn with no pieces,
  the parent's repair records the work `interrupted`, and replay skips the
  empty turn, so the child's history is its earlier turns. A child keeps no paused-response checkpoint (D31), so the
  child runner, like a v2 root, offers the orchestrator none. `lost`
  reaches the parent's model as `child_lost`, whose result says the
  message never ran and may be sent again (D33).
- **Usage:** the profile's usage-recovery marker stays fx's. For v2
  sessions it lives in `~/.fx/usage-recovery-v2/{id}`, apart from v1's
  folder. The adapter follows v1's rules around `set usage` (a durability
  point whose value carries a checkpoint time that only grows):
  - before a checkpoint that still owes the profile ledger, it writes the
    marker, unless one already covers the session and keeps its first time;
  - once a durable checkpoint owes nothing, it clears the marker.

  fx's usage recovery reads the v2 markers too. It takes the newest usage
  from the log without the lock, and trusts it only when the checkpoint's
  time is at least the marker's (D20, `Wiring.tla`).

  fx has since dropped its local usage ledger and these markers with it,
  so this item describes the design before that change, and `Wiring.tla`
  no longer models it (D85).
- **Checks the adapter keeps:** tool call and result pairing, and v1's
  per-piece size rules, before anything reaches `append`.

### Levels

```text
L4 api       the calls above, input validation, error mapping
L3 catalog   index.jsonl, .last and .last_opened, list, rebuild, self-heal
L2 session   fold, turn rules, open/resume/fork/import/close/delete, crash rules,
             snapshots, per-session mutex
L1 log       line framing and CRC32C, append, backward scan, read range, torn-tail cut, seq check
L0 storage   posix: open, positional write at the end, fsync, flock, mkdir, rename, link, unlink
             js-host: load, commit(expected revision), list, remove over the SDK sessionStore
```

Each level calls only the one below, and only L4 is public.

### Reuse Decision

Strategy: a new mechanism that replaces v1. The v1 patterns that fit are
reused as ideas; no v1 code is shared.

- **Extending v1 was rejected.** Extending `Store` and `LoadedWritableSession`
  (`src/core/session/session_log.zig:3207`) keeps the five-file state split
  and the per-host copies of the save logic.
- **Composing inside fx was rejected.** Merging the callbacks inside
  `src/core/app/app_session_runtime.zig` alone leaves `fx ask`, ACP and
  subagents on their own copies.
- **Reused as patterns:**
  - the event envelope from `session_event.zig::Envelope`;
  - the staged publish from `Root.startConversationSession`;
  - the bounded lock wait from `session_log.zig:27`;
  - fx's kebab-case flags and `FX_*` environment variables (`FX_MODEL`,
    `FX_PERMISSION_MODE`) for the switch (D26).
- **Reused unchanged:** the embedder `sessionStore` contract (`sdk/fx-sdk.js:922`).

### New Mechanism Justification

| Kind and name | Present requirement | Existing candidates inspected | Contract mismatch | Owner and lifecycle | Replaces/removes, or why coexistence is necessary |
|---|---|---|---|---|---|
| Module `session-manager` (L0 to L4) | One owner for session storage and the live-session lifecycle across all hosts | `session_store.zig::Store`, `session_log.zig::LoadedWritableSession`, `app_session_runtime.zig::Persistence` | State spans five files, the open turn is truncated on reopen, and nothing owns the live session | A host opens a Session per log; `close()` or process exit ends it | Coexists with v1 behind the switch, then replaces v1 |
| fx file `session_adapter.zig` | fx types become events; the persistence callbacks are implemented once | The four host copies in Repository Evidence | Each copy embeds host state and host-specific side effects | fx core; each host creates one adapter per open session | Replaces the four host copies |
| Callback `append_turn_piece` in `AgentRuntimeDeps` | Streaming each completed piece (D10) | `propagate_history_turn` (whole turn at the end), `recovery_checkpoint.set` (full rebuild at 13 boundaries) | The first arrives too late; the second is quadratic and misses pieces between checkpoints | Called by the agent loop; implemented by the adapter | Shrinks the recovery checkpoint to fx recovery details |
| Derived file `index.jsonl` | Listing and `.last` or `.last_opened` without opening every session | `session_catalog_cache.zig` (`.resume-catalog`), v1 `continue/` files | Keyed to stat fingerprints of v1 files; the remembered session lives in a separate file | Written by the manager on create, open, title, workspace or language change, close and delete; rebuilt by scanning logs | Replaces `.resume-catalog` and `continue/` |
| Folder `blobs/` per session | Large bodies kept out of the log and shared with forks through hard links | `result_store.zig`, `command_replay_store.zig`, the `images/` dir, `web_fetch_artifacts.zig` | Four stores with their own formats, and no fork rule | Written before the line that references it; removed with its session | Replaces those four stores (D6) |
| L0 `storage_js` | wasm persistence without changing the SDK (D9) | `js_host_session_store.zig` | It stores whole v1 state snapshots, not a log | Created by the wasm host profile; commits at durability points | Replaces `js_host_session_store.zig` |
| fx v1 converter | Carry v1 sessions into v2 under the same ids (D8) | `session_store.zig::migrateLegacyStorageOnly` | It migrates only between v1 formats | Converts a v1 family when it is first opened, or every family through `fx sessions convert` (D59, D61); writes through `open(.import)` | Kept with v1's read path, with no release set for its removal (D65) |

## Durable State And Schema

- **Source of truth:** `{id}/log.jsonl`, or the log bytes held by
  `sessionStore` on wasm. The index, snapshots and in-memory state are
  derived and can be rebuilt.
- **Write points:** every `append` is one positional `write()` at the end
  offset, which the writer knows because it holds the session flock. That
  survives an fx crash, because the bytes are already in the kernel. On wasm,
  lines not yet committed stay in memory.
- **Durability points** (a plain `fsync` on native; a `sessionStore` commit
  on wasm):
  - after a batch containing `turn_committed`, `turn_interrupted`,
    `set permissions`, `set usage`, `child_spawned` or `child_finished`
    (`set usage` since the wiring check, while fx cleared a usage-recovery
    marker only after the usage was durable; `Wiring.tla` modeled it until
    D85);
  - on `close()`;
  - on the first publish;
  - at the end of `open(.resume)` repair.

  A blob is durable before `put_blob` returns: its file, then its folder
  entry. That is required because one log `fsync` makes every line already
  written durable, including a line another thread wrote after its own blob,
  so a blob cannot wait for the next durability point (`Fork.tla`
  `RefsExist`). Cost: two `fsync` calls per blob.
- **What a sync guarantees:** a synced line survives an fx crash and an OS
  crash (kernel panic or freeze) on every platform, and a power cut on Linux.
  - On macOS, a plain `fsync` can leave recent data in the drive's own cache,
    so a power cut can lose the newest synced lines.
  - In rare cases a power cut can also damage a line in the middle. Such
    damage is recent, so it lies in what open reads, and the checksum makes
    the session open read-only up to the last good line. Older damage (bit
    rot) is found by `read` and `verify`.
  - This is accepted by D3.
- **Acknowledged seq:** a `seq` is stable only after a durability point. After
  a machine crash, a line that was never synced can vanish and its `seq`
  number is handed out again (`SessionLog.tla`).
- **Publish (D2):** the first batch that contains `turn_started`, together
  with any held `set` lines, is written to `.tmp/{id}/log.jsonl` and synced.
  Then it's renamed to `{id}` and the parent directory is synced.
  - A visible session always has a durable first line (`Lifecycle.tla`).
  - A session that never starts a turn never touches the disk.
- **Restart:**
  - `open(.resume)` cuts a torn or bad-checksum final line.
  - It appends `turn_interrupted{reason: crash}` for an open turn, and
    `child_finished{interrupted or lost}` for unfinished children.
  - Then it syncs (`TurnLifecycle.tla`, `Subagents.tla`).
- **Versioning:** `v` is on every line, and only the manager writes it.
  Readers accept every version up to their own, skip unknown kinds, and open
  newer versions read-only.
- **Migration (D8, D16):** on every start with v2 as the default, during the
  one-release window, an fx background task converts every v1 session with
  at least one turn that isn't in v2 yet. It runs after startup and never on
  the startup path.
  - It uses `open(.import)` under the same id and keeps original timestamps
    and children.
  - It is crash-safe (staged in `.tmp`) and safe to rerun (Exists means
    skip).
  - A family's v1 folders are removed once its v2 copy is durable (D60),
    except one that keeps a file the conversion left out (D56, D62).
  - wasm v1 snapshots are converted the same way through `sessionStore`.
  - A session converted earlier and then continued in an old fx binary is
    not re-imported, because its id already exists; the newer turns stay
    only in the v1 copy.
  - v1 hosted terminal state moves to `~/.fx/terminal/{id}/` (D13, D56).
  - It skips `~/.fx/sessions/v2` itself, the v2 root (D19).
  - v1 event kinds map one to one: `user`, `assistant`, `tool_call`,
    `tool_result` and `steering` become `item` lines with that `type`;
    `turn_completed` becomes `turn_committed`, `interrupted` becomes
    `turn_interrupted`, and `context_checkpoint` becomes `compacted`.
- **Cleanup:**
  - `delete` renames `{id}` to `.trash/{id}`, appends an index tombstone, then
    removes it.
  - Rebuild removes stale `.tmp` and `.trash` entries.
  - An unreferenced blob goes away with its session.
  - When fx deletes a session, the adapter also removes
    `~/.fx/terminal/{session-id}/`, for its children too. Doctor removes any
    terminal folder whose session no longer exists (D13).

## Concurrency And Ordering

- **Between processes (native):** one exclusive `flock` on `{id}/lock`, held
  from open to close. A contender retries for up to 2 s, then gets Busy; a
  resume may set its own wait, and fx's session picker sets none (D38). The
  kernel releases the lock on process death (`WriterLock.tla`).
- **Between writers (wasm):** single-writer is optimistic. Every commit
  carries the expected revision, and a conflict makes that Session fail with
  Busy. This is not covered by `WriterLock.tla` (Design Risks).
- **Inside a process:**
  - one mutex per `Session` serializes seq assignment, validation, the write
    and the fold update;
  - the sync may run after the mutex is released, and the requesting
    call returns only after its own sync;
  - hosts call from any thread and take no locks.
- **Ordering:** file order is seq order, which is the order in which calls
  took the mutex.
- **Readers:** `read`, `get_blob`, `list` and `fork` take no session lock.
  They read up to the last complete, valid line; written bytes never change.
- **Index:** appends and rewrites hold `index.lock`, and every `open` appends
  an `opened` line (D11); a resume writes the whole entry instead, since its
  repair may move the workspace or interrupt a turn (D42). A new session
  counts as opened by the host that created it. The index is derived: when an index write fails after the
  session change it records succeeded, the change stands and the failure is
  reported once (`index_stale`); the next change or a rebuild fixes it.
- **Close:** `close()` takes the mutex, interrupts an open turn with
  `reason: closed`, appends `closed` and syncs. Later calls return
  SessionClosed.
- **Children:** each child is its own session. The child thread appends
  `child_finished` through the parent's Session, ordered by the parent's
  mutex. A child has at most one unfinished work item, so a spawn and a
  finish can never race for the same child (D22).

## Performance And Capacity

The workload is one interactive session: a few to hundreds of pieces per turn,
and up to hundreds of thousands of turns over a session's life.

The standalone module's ReleaseSafe benchmark measured every row through the
public API against a Zig replay of v1's I/O pattern on the same file system.
The figures are medians from 2026-09-27 on a Mac (APFS, SSD).
- The v1 replay follows v1's code:
  - one `fsync` per log frame (`session_log.zig:254`);
  - a temp-file rewrite with two syncs per side file (`io.zig:700`);
  - resume takes `session.lock`, writes `owner.live`, reads four side files
    and replays every event;
  - list parses `.resume-catalog` and checks seven stat fingerprints per
    session (`session_catalog_cache.zig`).
- Where v1 does more than the replay (authority and commit guards, the
  history cache, catalog rewrites), the replay leaves it out, so no gate is
  easier than v1 itself.
- A piece is a ~200-byte line; a turn is 32 pieces and 10 tool steps.

| Operation | v2 | v1 replay |
|---|---|---|
| Startup | no session I/O | a session created at startup |
| Append one piece | one `write()`, 1.9 µs | positional write plus `fsync`, 23.6 µs |
| End of turn | 32 writes plus one `fsync`, 0.12 ms | a sync per frame plus side-file rewrites, 3.4 ms |
| Permission change | one write plus one `fsync`, 24 µs | a `permissions.json` rewrite, 167 µs |
| Resume at 10 turns | 130 µs | 186 µs |
| Resume at 1K, 10K, 100K turns | 376, 390, 393 µs | 5.6, 53, 529 ms |
| Scrollback of 100 lines at 10 turns, in the open session | 30 µs | 83 µs to load the history |
| Scrollback of 100 lines at 1K, 10K, 100K turns | 126, 125, 124 µs | 5.5, 55, 548 ms to load the history |
| Read of 100 lines by id at 10 turns, a session not open (no gate) | 57 to 94 µs | 74 to 83 µs to load the history |
| List of 1K sessions | 4.0 ms | 6.7 ms |
| First page (50) of 1K sessions | 2.9 ms | 6.7 ms |
| Fork of a 1K-turn session at turn 500 | 1.7 ms | none; a raw durable copy of the prefix takes 0.07 ms |

- **Gate:** every row is at least as fast as v1, with no exceptions, and
  permission change and resume take at most 5 ms. Every row passes.
  - The thinnest gated margin is resume at 10 turns, where fixed costs
    dominate: 1.4x to 2.4x across runs. v2 opens the session folder without
    following symlinks, takes the flock, and records the open in the index.
  - Scrollback reads the open session through its handle (`session.read`),
    with no open per page: 2.6x to 2.9x at 10 turns, also under load.
  - Reading a session that is not open (`read(id)`, a picker preview)
    opens its folder and log without following symlinks for each page. At
    10 turns that is about v1's whole-history load (0.9x to 1.3x across
    runs, slower under heavy load). It is not a scrollback row and has no
    gate; from 1K turns on it is far faster than v1.
  - Fork has no v1 row. It parses every copied line to encode the fork's
    own snapshots, so it grows with the prefix; it is a rare user action.
- **Size independence:** from 1K to 100K turns, resume grows 5% and
  scrollback stays flat (the gate allows 3x); v1 grows 100x.
- **Where the time goes:** list is mostly parsing index lines, then one
  `stat` per listed session for self-heal. Resume is mostly checking and
  folding the tail after the newest snapshot.
- **Memory:** a sync allocates nothing. It asks the kernel to write pages
  already in the page cache, so it lowers kernel dirty memory.
  - On native, the manager holds no unsynced lines of its own, because each
    line goes to the kernel with one `write()`.
  - On wasm, lines stay in memory until the next commit, so at most one
    turn's worth.
  - Resume keeps only the folded state and the model context since the last
    compaction. The transcript is paged, never loaded whole as v1 does.
- **Tuning (D7):** resume at 100K turns by snapshot distance.

  | Distance | Resume | Snapshot lines |
  |---|---|---|
  | 16 KB | 0.27 ms | 1.0% |
  | 32 KB | 0.27 ms | 0.5% |
  | 64 KB | 0.42 ms | 0.3% |
  | 128 KB | 0.71 ms | 0.1% |
  | 256 KB | 1.20 ms | 0.07% |

  64 KB is the default. It resumes about three times faster than 256 KB,
  and it keeps snapshots a small share of the log even when the folded
  state (settings, children) is large; smaller distances gain little.

## Compatibility And Rollout

- **Phases:**
  - standalone first;
  - then side by side behind the switch;
  - then v2 by default, with the one-time conversion;
  - then v1 removed, keeping the converter and v1's read path (D65).
- **Mixed state:** v1 and v2 use separate roots, `~/.fx/sessions/{id}` and
  `~/.fx/sessions/v2/` (D19), and one process uses one backend.
- **Switch (D26):** `--sessions-v2` on `fx` and `fx ask`, or
  `FX_SESSIONS_V2=1` for any host, including ACP launched by an editor and
  the E2E suite. It was off by default. Subagents followed their parent's
  process, and the wasm build stayed on v1 until `storage_js` landed. D53
  removed the switch with v1.
- **Side files while the switch exists (D27):** per-session side folders
  (tool results, images, command logs, artifacts, background and terminal
  state) keep v1's layout under an fx-owned `~/.fx/session-files/{id}/`,
  removed with the session. The move to blobs (D6) and to
  `~/.fx/terminal/{id}/` (D13) happens before the default flips.
- **Rollback:**
  - Before the default flips, switching back to v1 hides v2 sessions but
    loses nothing.
  - After the conversion, a downgraded fx sees only the v1 folders a
    conversion did not remove (D60): the sessions not yet converted and
    those that keep a file the conversion left out (D56, D62). It sees nothing
    done in v2.
- **Removal condition:** none. The converter and v1's read path stay, so a
  user can open a v1 session after any number of releases (D65).

## Reliability And Recovery

| Left after a crash | Next open |
|---|---|
| Torn or bad-checksum final line | Cut, because it never counted |
| Bad-checksum line that open reads (line 1, the newest snapshot, or after it) | Read-only up to the last good line |
| Bad-checksum line before the newest snapshot | Open does not read it and stays writable; `read` stops there and reports the damage, `verify` finds it, and `recover` forks the good prefix |
| Open turn | `turn_interrupted{reason: crash}`; fx decides whether to offer "continue", which starts a new linked turn (D23) |
| No `closed` line | `clean_exit` is false |
| Lock | Already released by the kernel |
| Child spawned without a log | `child_finished{outcome: lost}`; a named child keeps its name, and its next message starts it fresh (D33) |
| Child with a log but no finish | `child_finished{outcome: interrupted}` |
| Orphan blob, `.tmp` or `.trash` entry | Harmless; removed by rebuild |
| A blob the log names is missing, or its bytes fail their hash | The session is damaged, as for a bad line: resume refuses (`InvalidSessionFormat` in fx), `verify` counts it, and `recover` forks up to the last turn before the first line that names it (D39) |
| Stale index | `list` self-heals entries whose folder is missing; rebuild fixes the rest |

- **Stickiness:** "ask after an unclean exit" is carried by the last
  interrupted turn's `reason: crash` until the user starts a new turn.
- **Diagnostics:**
  - `verify` scans a whole log: checksums, seq, and fold equivalence against
    the newest snapshot;
  - `rebuild` rewrites the index from the logs and sweeps `.tmp` and
    `.trash`;
  - fx doctor calls both.

## Decisions

Settled before the decision reviews:
- **Decision:** build standalone, prove it through the API only, then wire
  it into fx next to v1, then replace v1. **Why:**
  isolation and discipline. **Alternative:** build inside fx from day one,
  which would couple the design to v1 while it is changing.
- **Decision:** one append-only JSONL log per session, one module, an API-only
  boundary, compiled into fx. The microservice and JSON-schema ideas describe
  the discipline, not a process or call format. **Why:** one owner and one
  source of truth. **Alternative:** a separate process, which adds IPC,
  startup cost and a new failure mode.
- **Decision:** fork is part of the API. **Why:** fx offers `/fork`, and the
  log's one owner should make the copy.

Settled in the 2026-09-27 scope lock:
- **D1 Decision:** an unfinished turn gets `turn_interrupted{reason: crash}`
  on reopen and is never cut. **Why:** keeps the log append-only and removes
  `recovery.json` and `recovery.asked`. **Alternative:** truncate as v1 does,
  losing the partial turn.
- **D2 Decision:** a session folder is created at the first turn; earlier
  `set` lines are held in memory and written with it. **Why:** there are no
  empty sessions, no startup I/O and no delete-if-empty logic.
  **Alternative:** create at the first save of any kind, or at startup as v1
  does.
- **D3 Decision:** a plain `fsync` at durability points only, on every
  platform. There is no fsync per line, no `F_FULLFSYNC` and no background
  sync. Revised on 2026-09-27.
  **Why:** power loss is rare, and stronger syncing is not worth its cost.
  This is the simplest and fastest option, 0.12 ms per turn against the v1
  replay's 3.4 ms in the Zig benchmark (an earlier prototype measured
  0.13 ms and 7.1 ms), with v1's guarantee against fx and OS crashes.
  **Alternative:** `F_FULLFSYNC` at durability points (power-loss safe on
  macOS, about 4 ms per turn), or a background full sync after a plain
  `fsync`. The latter needs a sync thread and still loses turns already
  reported as saved.
- **D4 Decision:** a CRC32C field ends every line. **Why:** detects silent
  damage the way real journals do, and stays valid JSON. **Alternative:**
  newline, parse and seq only.
- **D5 Decision:** forks start only at turn boundaries, or turn 0.
  **Why:** a fork's log is clean from line 1. **Alternative:** any line,
  with an interrupted turn appended; deferred.
- **D6 Decision:** large bodies go through per-session blobs, hard-linked on
  fork, replacing fx's four stores. **Why:** one rule for large data, simple
  delete, forks that cannot break. **Alternative:** a shared store (reference
  counting and GC), or keeping fx's stores.
- **D7 Decision:** snapshots now, after each compaction and every ~64 KB
  (tuned by the benchmark; see Performance And Capacity). **Why:** resume
  cost is bounded like a filesystem checkpoint, and the transcript is paged
  on demand. **Alternative:** defer until measured.
- **D8 Decision:** a one-time background conversion of every v1 session, same
  ids, v1 files untouched, v1 reader deleted one release later. **Why:** one
  listing path and a clean v1 removal. **Alternative:** convert on first
  resume (two listing paths) or don't convert.
- **D9 Decision:** wasm persists through a JS-host L0 over the unchanged
  `sessionStore`. **Why:** embedders change nothing. **Alternative:** a new
  append-style SDK API, or dropping wasm persistence.
- **D10 Decision:** each completed piece of a turn is appended as it happens,
  with no sync until the commit. **Why:** a crash keeps every finished piece,
  with no separate recovery snapshot. **Alternative:** one batch at commit, as
  v1 does.
- **D11 Decision:** `-c` stays distinct from `--resume last`, using host and
  open time in the index. Sessions tied on that time resolve as `list` sorts
  them (the smaller id first), so `--resume last` is the list's first entry.
  **Why:** keeps v1 behavior without a separate file, and the same state
  always resolves the same way. **Alternative:** merge both into "newest session".
- **D12 Decision:** the agent loop gains one callback, `append_turn_piece`.
  **Why:** the loop knows exactly when each piece completes, and it removes
  the quadratic full-turn rebuild. **Alternative:** diff recovery checkpoints
  in the adapter.

Settled in the second 2026-09-27 review:
- **D13 Decision:** hosted terminal state lives in an fx-owned
  `~/.fx/terminal/{session-id}/`, outside the manager. **Why:** it is mutable
  runtime state of live shells, not history. Unix keeps these apart
  (`/var/log` versus `/run` and `/var/lib/{service}`), and it keeps
  screen churn out of the log. **Alternative:** a manager-provided writable
  folder inside `{id}/` (breaks the boundary), or rewriting the terminal
  store as log events.
- **D14 Decision:** one optional diagnostics callback at manager init,
  forwarded by the adapter to `debug_trace`. **Why:** fx logs dropped user
  state, and a callback does that without importing fx; the SQLite
  log-callback pattern.
  **Alternative:** a separate manager log file, or repairs returned only in
  call results.
- **D15 Decision:** fx's session commands keep working with v2 meanings.
  `recover` forks at the last good turn and leaves the source untouched.
  `migrate` (hidden) runs the conversion and is removed with v1. List, show
  and doctor map to `list`, `read`, `verify` and `rebuild`. **Why:** keeps
  v1's promise for damaged sessions, reusing fork. **Alternative:** drop
  `recover` and `migrate`.
- **D16 Decision** (amends D8): the converter reruns on every v2 start during
  the one-release window, skipping ids already in v2. **Why:** older fx
  binaries on PATH can create v1 sessions after the first run.
  **Alternative:** a one-time run.
- **D17 Decision:** every `item` carries a required `type`, a short name fx
  chooses (`user`, `assistant`, `tool_call`, `tool_result`, `steering`, and
  any later ones). The manager checks only its form (1 to 32 of `a-z`, `0-9`
  and `_`), stores it, and returns it from `read`; it never interprets it
  and keeps no list of allowed names, like a file extension the filesystem
  stores but never opens. **Why:** logs stay readable with `jq` and `grep`,
  readers can filter without parsing fx's `data`, and the converter keeps
  v1's kinds by name, while fx still adds a type with no manager change.
  **Alternative:** the type only inside
  `data`, or one manager-owned kind per message type with ordering rules
  (which ties the manager to the agent's message model).
- **D18 Decision:** the conversation language is a `set` key, `language`, a
  JSON string of 1 to 24 bytes such as `"es"` or `"und-Latn"`, and the
  index lists it next to the title. **Why:** `fx sessions` prints each
  session's language in text and JSON (`src/core/output/output_contracts.zig`
  lines 978 to 996 and 1098), and `list` reads the index only.
  **Alternative:** the adapter opens every listed
  session to read it (slow), or `fx sessions` drops the language.
- **D19 Decision:** the v2 root is `~/.fx/sessions/v2/`, inside v1's
  sessions folder, so every session stays under `~/.fx/sessions/`.
  - v1 treats every folder there whose name is a valid id as a session
    (`src/core/session/session_store.zig` lines 385 to 387, and the doctor
    scan at lines 2549 to 2555). fx skips `v2` there, as it already skips
    `latest`, once v2 is wired in; the converter skips it too.
  - Installed older fx versions never learn the rule. Their `fx doctor`
    reports a harmless `session v2: canonical_state_invalid`. No v1 path was
    found that deletes or rewrites the folder: doctor cleanup never runs on
    it, and legacy migration works on one named session at a time.
  - Removing `~/.fx/sessions` by hand removes v2 sessions too.
  - The path is permanent; moving to plain `~/.fx/sessions/` after v1 is
    gone would be another migration.
  - The manager creates missing parent folders `0700`, like its own.
  **Alternative:** `~/.fx/sessions-v2/`, which v1 never looks inside.

Settled in the 2026-09-27 pre-wiring API check:
- **D20 Decision:** `State` carries `created_ms` and `updated_ms`, the `ts`
  of line 1 and of the newest line (0 before the first turn), and the index
  records the same `updated_ms` instead of the clock at the index write.
  **Why:** ACP's load and usage recovery need both on resume
  (`src/acp/sessions.zig` lines 669 to 679, and fx's usage recovery, since
  removed), and a converted
  session keeps its original times in the list rather than the conversion
  time. **Alternative:** the adapter looks the session up in `list`.
- **D21 Decision:** a host may end a turn with `reason: failed` as well as
  `cancel`. **Why:** fx ends turns both ways
  (`src/core/shared/types.zig` lines 2243 to 2246), and recording a failure
  as a cancel would make `last_interrupted` wrong. TurnLifecycle treats
  every reason as one interrupt, so the spec is unchanged.
  **Alternative:** only `cancel`, with the difference kept in fx's data.
- **D22 Decision:** the parent's log owns all subagent state.
  `child_spawned` and `child_finished` carry optional fx `data` (at most
  4 KiB), `cancelled` joins the outcomes, a child has at most one unfinished
  work item, and `State.children` lists every child with its newest work,
  outcome, data and seq. **Why:** fx needs the whole list, not only running
  work, to continue a named child, detect replaced work and report status
  (`src/core/subagent/child_state.zig` lines 42 to 57), and this removes
  `children.json` without a second owner. **Alternative:** keep
  `children.json` next to v2 for now, which gives the same state two owners.
- **D23 Decision:** "continue" after an interrupted turn starts a new turn
  that links back to it; D1 stands and the manager never reopens an ended
  turn. **Why:** no manager or spec change, and the log stays append-only.
  **Alternative:** let a crashed turn stay open until fx decides, which
  changes D1 and TurnLifecycle.
- **D24 Decision:** an ACP session that never gets a prompt is never written
  (D2 applies to every host); loading its id after a restart returns
  NotFound. **Why:** it holds nothing to lose, and no empty folders appear.
  **Alternative:** write every ACP session at creation as v1 does.
- **D25 Decision:** token counters stay inside fx's `usage` value and are
  not added to the index or `fx sessions`. **Why:** the list does not show
  them today. **Alternative:** index them for the list.

Settled when wiring started (2026-09-27):
- **D26 Decision:** the switch is `--sessions-v2` plus `FX_SESSIONS_V2=1`,
  off by default, instead of a runtime-profile capability flag. **Why:** a flag
  opts one run in from the command line, and editors that launch ACP can only
  set the environment. **Alternative:** a flag only, which leaves ACP and
  the E2E suite out.
- **D27 Decision:** until the default flips, v2 sessions keep side files in
  v1's layout under `~/.fx/session-files/{id}/`, a temporary deviation from
  D6 and D13. **Why:** wiring and dogfooding can start without first
  rewriting four stores and the terminal store. **Alternative:** move to
  blobs and `~/.fx/terminal/` before any wiring.

Settled after the first fault-injection runs (2026-09-27):
- **D28 Decision:** a tool call is saved before it runs, as a
  `tool_running` item with no result yet. On resume, each such call that
  the turn does not already hold gets a failed result, telling the model
  the tool was running when fx stopped and may have partly run. The result
  is derived from the log on every resume, never written, and only for a
  turn fx did not finish itself; a turn fx ended (a cancel) keeps what fx
  saved. **Why:** the model never gets an unpaired call, and it knows a
  side effect is uncertain. **Alternative:** v1's behavior, where the
  running call is lost with its turn.
- **D29 Decision:** I/O failures keep their kind across the API:
  `NoSpaceLeft`, `AccessDenied`, `ReadOnlyFileSystem` and `FileTooBig` join
  `Io` in the manager's error sets, and fx shows them as v1 does. The
  failed write or sync itself reports its cause; the session is then
  failed, and later calls on it report that same cause (D40). **Why:** a
  full disk or a read-only folder shows its cause. **Alternative:** `Io`
  alone.
- **D30 Decision:** a new session that was renamed but never prompted is
  not kept (D2). **Why:** it holds no conversation. **Alternative:** save it
  on rename, as v1 keeps it.
- **D31 Decision:** while dogfooding, v2 does not store v1's paused-response
  checkpoint behind `--continue-recovery`; an interrupted turn comes back
  with the pieces saved so far. Revisit before the flip. **Alternative:**
  port the checkpoint now.

Settled while wiring ACP (2026-09-27):
- **D32 Decision:** the transcript shown on resume and on an ACP load
  lists every saved turn, as v1's does, while the model's history still
  starts at the newest compaction. The adapter reads the whole log for it,
  one turn and one page in memory at a time, and must stay at least as
  fast as v1's full history load. `fx session {id}` lists every saved turn
  as well, with each compaction's summary where its line sits in the log,
  counted as v1's archive counts it: the turns before it, and its place
  among the compactions. **Why:** a compaction must not hide old turns
  from the person reading them. **Alternative:** show the summary and the
  turns after it.
- **D33 Decision:** a named child whose first message was `lost` keeps its
  name. The lost message's result tells the parent it was lost, and the
  next message to that name is new work for the same child, whose log is
  created by that work's first turn (`Subagents.tla` already allows
  this). Nothing is resent on its own. **Why:** the parent decides whether
  to resend, so no work runs twice. **Alternative:** refuse the name, or
  resend the lost message on reopen.
- **D34 Decision:** fx chooses a child's id and names it in the parent's
  `child_spawned` before the child exists; `open(.new)` takes that id for
  a child session only, with no disk I/O. A child with no log yet keeps its
  id, and its first turn creates the log under it (`Subagents.tla`
  `ChildStart`); a taken id fails that turn's append, because the publish
  rename never replaces a folder. A lost named child's instructions (kept
  in its own `prefs`) are lost with it; the parent's log still holds the
  call that gave them. **Why:** D33 and v1's flow need an id that exists
  before the log. **Alternative:** a fresh id per attempt, which gives one
  name several children.

Settled while wiring side files, `fx sessions` and doctor (2026-09-28):
- **D35 Decision:** with v2 on, `fx session migrate` refuses with a clear
  message that it applies to v1 storage until the v1-to-v2 converter
  lands; it touches no v1 file. **Why:** one backend per
  process (D26), and the converter is its own step. **Alternative:** build
  the converter now, or run v1's migration from a v2 process.
- **D36 Decision:** with v2 on, `fx doctor` verifies up to 64 sessions,
  v1's bound, says when it stopped early, and reports damage, and removes
  only side folders whose session is gone (D27), as v1's doctor removes
  stray temporary files. A folder changed in the last 24 hours stays: a new session keeps side files
  (an attached image) before its first turn creates its log, so a young
  folder may still have an owner. It rebuilds nothing
  and forks nothing; `fx session recover` stays the way to salvage a
  damaged session. **Why:** doctor stays safe to run at any time.
  **Alternative:** report only, or also rebuild and repair.
- **D37 Decision:** `peek(id)` returns a saved session's state and identity
  without its lock, folded as the catalog folds it (line 1, the newest
  snapshot, the tail); a torn tail is left as it is, and a child needs no
  parent to be read. `fx session {id}` and doctor read through it and
  `read`, never through a writable open. **Why:** a read-only command must
  not take the writer lock or repair anything. **Alternative:** rebuild
  the state in fx from `read` pages, a second fold that could drift. No
  TLA+ change: it reads, as `list` does.

Settled on 2026-09-28:
- **D38 Decision:** a resume may set how long it waits for the writer lock
  (`lock_wait_ms` on `open(.resume)`); unset keeps the manager's 2 s. fx's
  session picker waits for none, as v1's picker does (its
  `session_lock_deadline_ms = 0`), so a session open in another fx shows
  as busy at once instead of freezing the app for 2 s; every other resume
  keeps the 2 s. **Why:** v1's picker contract; found by v1's `tui-resume`
  contention test under v2. **Alternative:** one wait per manager, which
  either freezes the picker or drops the 2 s other resumes rely on. No
  TLA+ change: `WriterLock.tla` models Busy as `Open` being disabled while
  the lock is held, and how long a contender retries is outside it.
- **D39 Decision:** a blob the log names that is missing, or whose bytes
  fail their hash, damages the session the way a bad line does. Replay
  fails with Corrupt (fx: "saved session is unreadable", never "not
  found"); `verify` reports how many such blobs it met (doctor shows the
  session as damaged); a fork copies only lines whose blobs are present
  and whole, so `.last_good` ends before the first turn that names a bad
  one and a `.turn` fork past it is refused. **Why:** found by the
  fault matrix: resume said NotFound for a session that exists, doctor
  said ok, and a recover copy would have named the same missing blob.
  **Alternative:** show the piece as unavailable and resume anyway, as fx
  does for a missing image; rejected because a blob holds a turn's own
  text, which the model would then silently lose. `Fork.tla` gains
  `Lose`, and `RefsExist` now allows a missing reference only in the
  session that lost it.
- **D40 Decision:** a failed session keeps the cause of the write or sync
  that failed it, including a sync that failed on another thread and the
  first turn's publish, and every later call on it reports that cause
  instead of `Io`. **Why:** found by the fault matrix: fx reports a
  failed streamed write only at the turn's commit, so the same full disk
  read "FileTooBig" on one run and "Io" on another; the fault grid later
  found a new session in a read-only folder reading "Io". **Alternative:** keep `Io` and have every fx host
  remember the first error itself. No TLA+ change: the specs model a
  session going down, not the name of the error.
- **D41 Decision:** a host switching sessions may open the next session
  before it closes the current one. ACP creates or loads the next session
  first and closes the current one only once the next is ready, so a
  failed switch leaves the current session in place. While a switch is
  pending, the current session's turn may still end and its children may
  still finish, but no turn or child starts; the current session closes
  only after its children are joined, and closing the next one instead
  abandons the switch. **Why:** found by the trace check of `Wiring`:
  every ACP switch in the E2E runs opened the next session first, which
  the spec's single session slot did not allow. **Alternative:** close the
  current session first, which leaves ACP without a session when the next
  one fails to open. `Wiring.tla` gains `next`, the session being
  switched to.
- **D42 Decision:** a resume rewrites the session's index entry, stamped as
  opened by the resuming host, instead of appending only an `opened` line.
  **Why:** found while porting ACP's load `cwd`: a resume from another
  workspace records `set workspace` in the log, but `list` kept the old
  workspace until the session closed, so `session/list` and `fx sessions`
  showed a moved session under the folder it left; a repaired open turn
  left the turn count stale the same way. **Alternative:** write the entry
  only when the repair changed the listing, which saves one index line per
  resume but needs the repair to report what it wrote. `Catalog.tla`
  gains `Refresh`, a put for a live, indexed session, which the title,
  workspace and language updates already wrote.
- **D43 Decision:** an ACP session on v2 keeps the client system prompt and
  its MCP tool identities in its side folder, through the
  `SessionChildCapability` v1 uses, and `session/new` and `session/load`
  take the request's `cwd` as v1 does. The prompt is written at
  `session/new`, as on v1; closing a session that never got a prompt
  removes its side folder, and doctor sweeps one that a crash leaves
  (D36). **Why:** fx's ACP gained these while v2 was being built; without
  them a v2 session silently lost the client's instructions and its replay
  detail, and started in the process folder. **Alternative:** hold the
  prompt in memory until the first turn, which keeps D24 exact but loses
  the prompt when the side write fails after that turn commits. No TLA+
  change: side files are outside the specs.

Settled while moving off the side folder (2026-10-01):
- **D44 Decision:** a v2 session's large bodies are blobs of that session,
  realizing D6 for fx's stores: tool results and tool images, command
  replay and web-fetch downloads (an edit's diff stays inside its item, as
  v2 already keeps it). Each handle keeps its store's
  prefix and extension, and its name is the body's full 64-hex hash: a
  tool result is `result-`, the hash and `.txt`, and a command's output is
  `fx-command-replay-`, the hash and `.bin`, so no name
  index exists and `read_tool_result` still tells text, images and command
  output apart. All of a session's blobs are found by hash alone, so each
  store reads only handles with its own prefix and reports any other as not
  found, as v1's separate folders did; otherwise the result store would
  page a command's replay as raw frames. Every blob is listed on an item of the turn that stored it;
  one stored outside a turn is listed on the next item the session writes
  (only the move's own setting lists blobs, D47). A body is stored only
  while the session is on disk: the adapter opens the turn before it
  stores one itself, and a subagent child opens its turn when it starts,
  as the hosts that stream a turn already do. The store modules keep their callers: the session's
  `SessionChildCapability` gains a blob backend on v2 that puts and gets
  whole bodies, and only the stores and the two direct readers of replay
  files change. A command's output streams to a temporary file outside the
  session while it runs and becomes a blob when it is kept, copied from
  that file by `Session.putBlobFile` so it is never whole in memory; output
  that is never kept goes with the file. A command's own log files, which
  its process writes directly, stay in the temporary folder fx uses when no
  session is open. Prompt images are captured before the
  session is on disk, where no blob can be written, so they are saved
  inside the user's item, as libfx saves them; a large item is a blob
  already. D89 saves them as blobs when their turn starts. fx's own size
  limits stay where they are. **Why:** one folder per session,
  forks that hard-link instead of copying, no orphan side folders, and
  content addressing that makes a stored body unforgeable. **Alternative:**
  keep today's handle names with an index from name to blob, which grows
  with every stored result.
- **D45 Decision:** a v2 session's hosted terminal state lives in
  `~/.fx/terminal/{id}/` (D13). Deleting the session removes it, `fx
  session recover` copies it as it copied side files, and doctor removes a
  terminal folder whose session is gone and that is more than a day old
  (as D36). **Why:** live shell state is not history, and it no longer
  depends on the side folder. **Alternative:** keep it in the side folder.
- **D46 Decision:** the manager gains two setting keys, `client_prompt` and
  `tool_identities`, whose values are fx's JSON. fx writes each only when it
  changes, at most 64 KiB and 1,024 entries, well under a line. This
  replaces D43's side files. **Why:** both are small session settings, and
  the side folder goes away. **Alternative:** one generic host key, where a
  new tool identity would rewrite the client prompt too.
- **D47 Decision:** an older v2 session moves to this layout on its first
  writable open. fx puts each side body its log names as a blob, and the map
  from each old handle to its hash as one more blob, then writes one batch:
  `set moved_files`, whose value names the map blob and whose line lists
  every moved blob, plus the two settings from the old files. The map stays
  out of snapshots, which repeat every setting's value. It then
  renames the terminal folder and removes the side folder. Each step can be
  repeated, so a crash at any point redoes the move on the next open, and an
  old handle resolves through the map. A read-only view of a session not
  moved yet, such as `fx session {id}`, reads its side files as today; that
  read path goes with v1. The manager lets a `set` line list
  blobs, outside a turn, under the same rule as an item: each exists before
  the line, a fork hard-links them, and verify checks them. **Why:**
  teammates' sessions keep working with no permanent dual path, since an old
  handle resolves through one map. **Alternative:** read both layouts until
  v1 is removed, or treat old bodies as unavailable.
- **D48 Decision:** with D44 to D47 a v2 session never creates
  `~/.fx/session-files/{id}`; D27 is retired. Doctor still removes leftover
  side folders. `Fork.tla` gains `set` lines with blobs, and
  `MoveSideFiles.tla` models the move under crashes.
- **D49 Decision:** a web-fetch download is a blob, and the model opens it
  by path with its own tools, so the manager gives the path of a durable
  blob (`Manager.blobPath`) after checking it exists. Blob files are
  written read-only (`0400`), so a tool cannot change one by accident; a
  fork's hard link shares that mode. The path stays valid after resume,
  and `getBlob` still checks the bytes against the name. **Why:** one copy
  that outlives the process, and the model's tools work unchanged.
  **Alternative:** a temporary copy that goes when fx exits, or plain files
  in a downloads folder outside the session, which forks do not carry.
  No TLA+ change: a blob is never rewritten in any spec.

Settled after main's new compactor landed (2026-10-01):
- **D50 Decision:** fx's compactor keeps its records (each compacted tool
  call, turn and folded earlier compaction, as `compacted-T12.txt`,
  `compacted-M12.txt` and `compacted-L1.txt`) in a named store it can
  write, replace, list and read. On v2 each record is a blob, and one
  `set compaction_records` setting names a blob holding the map from
  record name to blob, as `moved_files` does (D47). The adapter writes
  that setting with the session's next batch, listing the map and the
  records added since the last one, so the compaction line that cites them
  never lands without them: the log keeps a prefix, so the setting needs
  no sync of its own. A moved session's old records, under
  `tool-results/` in its move map, are listed and read too; a newer record
  of the same name wins. **Why:** v2 has no side folder (D48), and a map
  in a blob keeps snapshots small. **Alternative:** rebuild records from
  the log, which copies the compactor's format into fx's session code, or
  a side folder kept only for records, which D48 rules out. `Fork.tla`
  `SetBlob` now lists a blob inside a turn as well as outside it, since
  compaction runs mid-turn; such a setting is checked as an item is.

Settled after the first dogfood finding (2026-10-01):
- **D51 Decision:** the message that issues running calls keeps its text
  with them. In the batch that first saves a step's calls as running
  (D28), one `assistant_running` item holds that message's text; a step
  with no text writes none. Replay uses it only when it answers running
  calls after a crash: the repaired step carries that text, so the
  transcript and the next request show what fx showed before it stopped.
  A finished assistant piece clears it, so text that an earlier step
  finished with never lands on a later one. The provider replay stays
  out: it binds to every call of its message, and a repaired step may
  hold only some of them, so it is dropped as fx drops any replay whose
  calls changed. **Why:** fx had shown the text, the model had sent it,
  and v1 keeps it; without it the plan for an interrupted command is
  gone. **Alternative:** stream the assistant piece early, which makes
  the finished step's prefix match depend on every later change to that
  message. No TLA+ change: the item rides in D28's batch, and no spec
  models fx's items.

Settled after the second dogfood finding (2026-10-02):
- **D52 Decision:** a session's title comes from its first prompt even
  when a crash took its first turn. A new session still writes the title
  its first prompt gives with its first turn end. A resumed host session
  with no stored title keeps the title v1's listing derives from its
  restored history (the first usable prompt, an interrupted turn's
  included) and writes it with its next turn end; later turns leave it.
  A child stays as before. The app's title generation keeps
  its gate (an untitled session with no history), so a crash-recovered
  session gets the prompt title, not a generated one. **Why:** v2 keeps
  the crashed prompt, so the old rule (only a session started in this
  process names itself) left such a session untitled for good, while the
  app already shows that prompt as its title on resume. **Alternative:**
  also generate a title on the first prompt after resume, as v1 does
  because it drops the crashed turn; that changes the app's title gate and
  resume title cache, which v1 shares. No TLA+ change: a title is a
  setting no spec reads.

Settled for making v2 the only store (2026-10-02):
- **D53 Decision:** v2 becomes the only session store, and the switch goes:
  `--sessions-v2` and `FX_SESSIONS_V2` are removed, not kept as no-ops.
  **Why:** a no-op flag is dead code, and every host keeps one path.
  **Alternative:** accept the flag silently for one release.
- **D54 Decision:** v1's paused-response recovery is removed:
  `fx ask --continue-recovery`, the app's offer to continue an interrupted
  reply, and the recovery checkpoint files (`recovery.json`,
  `recovery.asked`, `owner.live`). This settles D31. v2's interrupted turns
  and running-call repair (D1, D28, D51) stay. The orchestrator's
  checkpoint save also streams v2's finished pieces, so only its
  full-turn rebuild goes. **Why:** v2 keeps every finished piece already,
  and the checkpoint is a second recovery path. **Alternative:** port the
  checkpoint to v2.
- **D55 Decision (amends D8 and D16):** the converter comes first, on v1's
  existing read path, and v1 is removed after it, except that read path.
  On every start, the new build imports each v1 session v2 does not hold,
  once per id, keeping its id: a family, the root and the children in its
  registry, under the v1 lock of every member, staged and then published
  children first. A busy family is skipped and retried on a later start;
  crash leftovers are swept before an import. A v1 session that changes
  after its import is not imported again, and the converter never writes
  a v1 file. A fresh v2 session never takes the id of a live v1 session
  (R1). `V1Conversion.tla` models this with older builds still
  writing v1. **Why:** no window where the new build hides a user's v1
  sessions, and no v1 reader written twice. **Alternative:** remove v1
  first and write a fresh read-only importer; or re-import a v1 session
  whose v2 copy got no new turn, which needs a stored fingerprint.

Confirmed for the converter and the removal (2026-10-02;
D59 replaces D55's import at start with conversion on open):
- **D56 Decision:** besides the conversation and state, the converter
  carries what a user would otherwise lose: side files as blobs with old
  handles mapped as D47 maps them; ACP client prompts and tool identities
  as D46's settings; hosted terminal state into `~/.fx/terminal/{id}`
  (D45), whatever its folders' modes, as v1 made each private when it
  opened it, while an entry the copy can't take (a link, a FIFO, a file
  that does not open, or nesting deeper than 8 folders) is left out and
  named, and the member's v1 folder keeps it, as D62 keeps a side file
  (2026-10-19); `-c`'s remembered app session as v2's last-opened when v2 has
  none; and a `recovery.json` open turn as an interrupted turn with its
  saved pieces (D1), exactly when v1 would show it: v1 drops a checkpoint
  whose turn is not open in its log. It carried unsettled usage markers
  too until fx dropped its usage ledger; it now carries no usage, and
  leaves v1's usage files in place, ignored, as fx does. **Why:** each is
  state a v1 session holds outside `session.json` and its event log.
  **Alternative:** convert the conversation only.
- **D57 Decision:** v1 is removed in one step after the converter ships:
  the writer, store, listing, catalog, migration, recovery and every
  host branch, leaving only the converter's read path. One release later
  the converter and that path go too (D8); D65 keeps them. wasm and
  libfx persistence is decided separately and blocks only the JS-host
  snapshot store and the codec parts it needs. **Why:** each release
  ships one store and no unused code. **Alternative:** remove v1 module
  by module across several releases.

Settled for `/fork` (2026-10-02):
- **D58 Decision:** `/fork` in the interactive app opens a menu
  of the session's prompts, oldest at the top and the newest selected,
  each shown up to three lines and then `…`. Picking one forks the
  session before that prompt: the manager's `open(.fork)` copies the log
  to the end of the previous turn under a new id and hard-links the
  blobs (D5), so the source is never written. The app switches to the
  fork as a resume does, opening it before it closes the source (D41),
  writes `original session fx --resume` and the source's id in the
  transcript, and puts the prompt back in the input box. The fork's title
  is the source's with ` (fork)` once. `/fork` waits for a running turn
  to end. (Until D53 removed the switch, the line named `--sessions-v2`
  and `/fork` refused without it.)
  Subagent children and hosted terminals stay with the source, since the
  fold counts children only after a fork point. The adapter adds two
  calls: `forkPoints`, each turn's prompt and number, and
  `fork(before_turn, …)`. **Why:** the manager already forks at turn
  boundaries, so the feature adds no format and no new way to write a
  log. **Alternative:** fork after the chosen turn's reply; or copy the
  log in fx instead of the manager. `Fork.tla` models the manager's fork
  at a boundary with blob links. `Wiring.tla` gains `Fork`:
  between turns and with no child running, a session that never existed
  becomes the one to switch to, and the source is not written
  (`ForkIsNewSession`, `ForkLeavesSource`, `ForkBetweenTurns`).
  `trace/check_wiring_traces.py` checks the `wiring` traces of `/fork`
  runs against `Wiring`, and `trace/check_saved_logs.py` checks each
  saved log against `TurnLifecycle` and, for a fork,
  `trace/ForkLog.tla`, which accepts only a copy that is the source's
  first lines byte for byte, ending at a turn boundary.

Settled for the converter (2026-10-06):
- **D59 Decision (amends D55 and D57):** a v1 session converts when it
  is opened, not at start. Every open (the app's resume, `-c`, the
  picker and `/resume`, `fx ask`, ACP `session/load`) goes through one
  function: it opens the v2 copy, or converts the family (the root and
  the children in its registry, from one v1 state) and then opens it.
  Start scans nothing. Listing shows v1 sessions not yet converted next
  to v2 ones, v2 winning on an id (D60 dropped a rule for v2 deletions);
  listing never converts. A conversion stages the family, writes it with one
  fsync, publishes the children first, and ends with a snapshot so the
  open after it takes the fast path; the manager gains this staged
  import, since an import today syncs every batch. A busy v1 session is
  refused as busy; an unreadable one is refused with the reason, its v1
  files untouched and nothing half converted. Later v1 writes by an
  older build are ignored (as D55). A dim line says it is converting
  only when it takes longer than about 150 ms. A convert-all command
  ships with it, for sessions never opened before the converter goes.
  Budget: convert plus open, p95 under 50 ms for sessions up to 1K
  turns and under 200 ms at 10K turns, on a corpus of real v1 sessions,
  gated by a benchmark. In the manager an import holds every batch, its
  turns included, framed behind line 1 until `publishImport`, which
  writes them through the first turn's staged publish: one write and one
  fsync of the log, a folder fsync, the rename, a root fsync. Its blobs
  go to `.tmp/{id}/blobs` first, and an abandoned import leaves only that
  folder, which the next attempt clears. Batches keep their original
  times until a host appends after the publish. The standalone benchmark: 1K
  turns import in 1.91 ms and 10K in 16.24 ms, half of each budget being
  the ceiling. **Why:** no start cost and no background work; a session
  pays once, when it is used. **Alternative:** the background import on
  every start, as D55 first had it.
- **D60 Decision (amends D55 and D59; 2026-10-07):** once a
  family's v2 copy is published and durable, the converter deletes the
  family's v1 folders one by one while it still holds their v1 locks, so
  a v1 session is kept once, not twice. Each folder is first renamed out
  of v1's root into a trash folder neither store lists, so it disappears
  in one step, then removed; a later conversion empties that trash. Each v2 member records the fingerprint
  of the v1 version it copied. A v1 folder left behind (a crash between
  the publish and the delete, or a delete the file system refused) is
  deleted by a later open of that session only while its fingerprint
  still matches; one an older build changed since is left alone, and
  its later writes are ignored as D59 says. A refused delete does not
  fail the open. Older fx versions no longer see a converted session.
  With the v1 copy gone, a v2 deletion cannot bring it back, so D59's
  rule that a v2 deletion hides a v1 id goes: no host deletes a v2
  session, and nothing would exercise it. **Why:** a converted session
  should not take its space twice. **Alternative:** keep the v1 copy
  until the converter is removed, or delete only from `fx sessions
  convert`.
- **D61 Decision (2026-10-07, on questions left open when the converter
  was designed):** sessions in v1's older formats (schema 3 and legacy, about
  82% of a real profile) convert too, through v1's older reader; a slow
  one shows the slow notice. So do v1 folders an old release left
  world-readable (0755), which today's v1 refuses: others could only read
  them, the v2 copy is private, and the readable v1 copy is deleted. `--resume last` picks the newest of the
  merged listing. `fx session {id}` shows an unconverted v1 session read
  only, without converting it. A converted session is a v2 session and
  behaves as one: nothing special for converted sessions. The slow notice
  shows in the app, on `fx ask`'s stderr, and to ACP clients. `fx
  sessions convert` prints `converted N, busy N, unreadable N` and a line
  per skipped session, and exits 1 when any was skipped. A damaged session's
  error names the file and the reason. Internal, by the same pass: a
  registry child whose v1 folder is gone is recorded as lost (D33);
  taking a v1 lock may create a missing `session.lock`, which is not
  content; a v1 child id opened directly answers SessionNotFound, as v2
  does; the sweep runs under the family's locks, so two processes
  converting one family serialize, and `V1Conversion.tla` models two
  converters. **Why:** these were left open when the converter was designed. **Alternative:** refuse the older formats,
  or keep `fx session` v2 only.
- **D62 Decision (2026-10-07, after converting a clone of a
  real profile: 13,970 families converted, 13 unreadable):** a conversion
  first checks every member keeping nothing, then reads and stages one
  member at a time, so memory holds at most one member (a 15-member
  family had peaked at 3.6 GB); families with children are read twice.
  A side file over v2's per-file limit (one real 16.8 GB command replay)
  is left out, named in the trace and the convert output, and the rest of
  the family converts. That member's v1 folder is then kept rather than
  removed (D60), so the file stays where it was, and the notice and the
  convert output name the folder (2026-10-19). The copy names the first
  32 files it left out and counts them all, in place of its v1
  fingerprint, so a later open, or a reuse of the member after a crash,
  keeps that folder whatever has changed in it since, a reuse names those
  files again, an older fx finds no fingerprint to match and keeps the folder too, and `fx doctor` counts
  such folders, a subagent's among them. `V1Conversion.tla`'s `keeps`
  holds such members, and `NoLossOnDelete` checks that no conversion or
  cleanup removes their folders. The v2 listing must stay fast at the
  size conversion creates (about 14,000 sessions took 1.9 s a page):
  fixed in this change, gated by the manager's benchmark. A usage marker
  move came with this decision and went with fx's usage ledger. **Why:**
  the real run showed each limit. **Alternative:** keep whole families in
  memory, refuse the
  family, or fix the listing later.

Settled for removing v1 (2026-10-16):
- **D63 Decision:** libfx's `createFxTerminal({ sessionStore })` keeps
  saving conversations as the snapshots `js_host_session_store` writes
  through `session_codec`, unchanged, and so do the codec parts that
  `sdk/durable.js` uses. Removing v1 removes v1's store on disk, not this
  format: an app's store holds data fx cannot convert for it. **Why:** no
  app's saved conversations are lost. **Alternative:** move the snapshots
  to v2's log, with a conversion in the SDK.
- **D64 Decision:** `fx session recover` on a v1 session salvages it as
  v1's recover did: it copies the start that v1's validated prefix keeps
  (a schema-3 session's manifest boundary) into a fresh v2 session with
  a new id, and never changes the v1 session, which stays listed and can
  be salvaged again. A healthy v1 session answers that no recovery is
  needed, in an older format too, where v1 asked for `migrate` first;
  damage v1 could not get past is reported as such, a busy one is
  busy, and a subagent child is refused as v1 refused it.
  `V1Conversion.tla` models it (`SBegin`, `SFinish`,
  `SalvageLeavesSource`, `RefusedOnlyWithCause`) with two kinds of damage:
  one v1's recover salvages and one it cannot. **Why:** a user with a
  damaged v1 session keeps the way back v1 gave. **Alternative:** drop
  salvage, which leaves such a session unreadable.
- **D65 Decision (amends D8 and D57):** removing v1 keeps the converter
  and v1's read path, with no release set for their removal: a user may
  open a v1 session after any number of releases. Everything else of v1
  goes in one change: the writer, the switch, the listing and catalog,
  migration and every host branch. The converter's checks run against
  v1 sessions written by a built v1 writer, the last commit with v1 and
  older releases, since the new build writes no v1. **Why:** no user's
  session becomes unreadable. **Alternative:** remove the converter one
  release later, as D57 had it.
- **D66 Decision:** a v1 session today's v1 cannot continue stays as it
  is, read only: a schema-3 prompt that is not UTF-8, which v1 shows but
  cannot continue or salvage (`InvalidConversationEvent`), is refused by
  the converter with the file, the turn and the reason, and `fx session`
  shows it. **Why:** the new build loses nothing v1 had, and adds no
  rewriting of a prompt. **Alternative:** convert it with each invalid
  sequence replaced by U+FFFD.

Settled while removing v1 (2026-10-17):
- **D67 Decision:** the v2 store checks `~/.fx`, `~/.fx/sessions` and
  `v2` when it opens and refuses one that is not a real folder, such as
  a file or a symlink, with `SessionPathUnsafe` before any session is
  asked for: `fx ask` warns and runs without saving, as v1 did, and a
  resume fails with that error. A missing folder is made by the first
  write; one others can read converts (D61). **Why:** every write would
  fail on such a path, and the user hears why before the turn.
  **Alternative:** fail at the first write, mid-turn.
- **D68 Decision:** the converter's tests read copies of sessions a v1
  release wrote, committed under `tests/fixtures/v1-sessions/` and made
  by its `generate.ts` with v0.0.14, instead of sessions a v1 writer in
  the tree makes. Tests that could only set up through that writer are
  deleted; the cases that still matter on the surviving path are kept as
  fixture tests: a symlinked side folder, a legacy authority fence, zero
  image ids and a FIFO in a session. **Why:** the writer goes with v1,
  and a release's output is what users have on disk. **Alternative:**
  keep the v1 writer for tests only.
- **D69 Decision:** the converter repairs a schema-2 session's prompt
  image ids as v1's resume did (`repair_legacy_zero_image_ids`): images
  saved with id 0 get the numbers v1 gave them, and the prompt's text is
  renumbered to match. **Why:** a converted session shows its images as
  v1 showed them. **Alternative:** keep the zeros, which collide.
- **D70 Decision:** a schema-2 snapshot with a pending `legacy_to_v3`
  authority fence is refused (`InvalidSessionFormat`) and keeps its v1
  folder for `fx session recover`; one whose upgrade already published
  converts despite a leftover fence. **Why:** as in v1, an upgrade left
  half done is not guessed at. **Alternative:** convert past the fence.
- **D71 Decision:** resuming a subagent child's id directly, with `fx
  ask --resume-id`, `fx --resume` or ACP `session/load`, fails with v1's
  message: subagent child sessions cannot be resumed directly; message
  the named agent from its parent session. **Why:** it tells the user
  what to do instead. **Alternative:** a plain not-found.
- **D72 Decision:** `fx session recover` on a v1 session whose
  `permissions.json` is malformed or empty copies its conversation
  without the saved permission rules, says so
  (`permission_rules_dropped`), and leaves the v1 session as it was. A
  resume still refuses to convert it. **Why:** a damaged file of rules
  does not cost the conversation. **Alternative:** refuse, as conversion
  does.
- **D73 Decision:** `fx doctor` counts the v1 sessions not converted yet
  and names each one that cannot be converted, with its reason and what
  `fx session recover` would copy: the conversation without its rules,
  its good turns, or nothing. It reads each with the converter's own
  check, skips a busy one, and shares doctor's limit on sessions
  checked. **Why:** a user sees which old sessions need attention before
  opening them. **Alternative:** report only v2 sessions.
- **D74 Decision:** salvage checks each side file that a kept tool
  result or command replay names, by its size and the digest in its
  handle. A missing or changed file is left out, its result says the
  content is unavailable, and the recovery reports
  `recovered_with_unverified_artifacts` and exits 1. v1 refused the
  whole recovery. **Why:** a damaged side file costs one result, not the
  session. **Alternative:** refuse, as v1 did.
- **D75 Decision:** a v1 log whose context checkpoint splits a tool call
  from its result keeps converting: the model gets the checkpoint's
  summary, then the whole first turn, and `fx session recover` answers
  that no recovery is needed. **Why:** nothing is lost. **Alternative:**
  drop the split turn.
- **D76 Decision:** `--resume last` and `fx session last`, when they
  find nothing to open but skipped an unreadable v1 session, fail with
  `NoReadableSessions` instead of `NoSavedSessions`. **Why:** the user
  learns that a session exists and is damaged. **Alternative:** say
  there are none.
- **D77 Decision:** a converted v1 session whose last turn never ended
  keeps that turn, marked interrupted as failed (D1). v1's next writable
  open discarded it unless a checkpoint covered it. **Why:** no
  truncation. **Alternative:** discard it, as v1 did.
- **D78 Decision:** `fx session --id` on a damaged v1 session fails with
  `InvalidSessionFormat`, the file and the reason the converter's check
  gives, and points at `fx doctor`. **Why:** the user can act on it.
  **Alternative:** a generic message that the session is corrupt.
- **D79 Decision (amends D44; D89 amends it):** each request names the
  saved file of every prompt image it sends, as
  `[Image #N (type) is saved at "<path>".]` ahead of the prompt, and the
  notice for an image too large to send, or left out to keep a request
  within its size limit, names the same file, in the running process and
  after a resume alike. That file is the image's blob (D89). An image
  with no saved file, one the store did not save or one in a session
  that is not saved, is named by no note, and its notices name no file.
  **Why:** the model can read the original to make a smaller copy, or
  open the image it sees with tools, as v1's `images/` folder let it.
  **Alternative:** tell the model no local file is available.
- **D80 Decision:** when fx is killed while a response is being retried,
  the reopened session shows the turn's finished pieces, such as a tool
  call and its result, and the turn as interrupted, but not the text
  streamed by the attempt being retried, which v1 kept. With D54 an fx
  session has no recovery to continue: ACP's `_meta.fx.continueRecovery`
  answers that the session does not support durable recovery, and serves
  only libfx sessions that keep a journal. **Why:** text from an attempt
  being retried is not a result, and the next turn never sends it.
  **Alternative:** save it in the open turn.
- **D81 Decision:** when fx relaunches itself after an update and the
  session it hands over had no turn, so that nothing of it was saved
  (D2), the new build opens a fresh session with the update's notice
  instead of failing to find it. Only that relaunch does so; a resume of
  a missing id typed by a user still fails with `SessionNotFound`.
  **Why:** v1 saved every session at startup, and an update must not
  leave the user without fx. **Alternative:** exit with a message saying
  there was nothing to resume.
- **D82 Decision:** an image the oldest format (schema 2) saved only as
  the path of its original file is captured from that file once when the
  session converts, with the checks of any new capture, as v1's resume
  did (`repair_legacy_image_snapshots`). One that cannot be captured,
  because its file is gone, unreadable, not a supported image or too
  large, is left out of that prompt with a trace line, and the prompt's
  text stays as it was, as in v1. **Why:** the model sees the images v1
  sent. **Alternative:** convert them without bytes, which the model
  never sees.
- **D83 Decision:** tests of a prompt with many images, one of them
  damaged, run on a committed v1 fixture, `many-images`: one v0.0.14
  session with twenty images. The fixture generator takes
  `FX_FIXTURE_KINDS` to rebuild only the kinds it names. **Why:** a test
  damages what a user can have, a v1 session's own files; damaging a v2
  log tests the checksum on every line (D4) instead. **Alternative:**
  write the damaged session by hand in each test.
- **D84 Decision:** recalling a prompt from the input history uses the
  image bytes saved with the prompt, checked against their digest, so a
  damaged or deleted captured file no longer refuses the recall. The
  recalled image keeps those bytes inline and writes no file, so its turn
  saves it as a blob as it does any prompt image (D89); a copy in the
  temporary folder would be gone once fx exits. The composer tests pin
  that the recall succeeds and names the same blob. **Why:** the saved
  bytes are the prompt's image; the captured file is a temporary copy.
  **Alternative:** read the captured file again, as v1 did.
- **D85 Decision:** `Wiring.tla` models one store. The backend choice
  (`Backends`, `backend`, `wrote`, `OneBackend`) and the usage ledger
  (`usageSplit`, `marker`, `UsageNeverSilent`) leave it, its trace
  module and its mutants, and `profile_paths` loses the unused usage
  names. The `rollout/` models keep their own `OneBackend` as the record
  of the rollout. **Why:** with v1 and the usage ledger gone, those states
  cannot happen. **Alternative:** keep them, checking states fx cannot
  reach.
- **D86 Decision:** `-c`, when the new store remembers no session for the
  workspace and fx cannot read v1's bookmark (not a plain file, the wrong
  mode, unreadable or malformed), exits 1 saying the remembered session ID
  could not be read and naming `fx -r` and `fx --resume <id>`, as v1 did.
  A missing bookmark still means no remembered session. **Why:** the user
  learns what happened and what to do instead of seeing an error name.
  **Alternative:** treat an unreadable bookmark as none.
- **D87 Decision:** a compaction inside a turn keeps that turn from where
  the summary ends. Its `compacted` line saves the steps and steering
  messages of the first kept turn that the summary covers
  (`keep_tool_steps`, `keep_steering`), and a resume leaves them out of
  that turn, as fx's history does once it compacts; a later cut inside
  the same turn counts on from there. The converter takes the same counts
  from a v1 checkpoint's coverage, as v1's writer counted them, so a
  converted session shows the model the turn's prompt and the steps after
  the summary, as v1 did. A line without them, or a turn that no longer has
  those steps, keeps the whole turn. **Why:** the steps the summary covers
  reached the model a second time, up to 170 messages in real sessions,
  enough to fill the window on resume. **Alternative:** keep whole turns.
- **D88 Decision:** a v1 subagent whose parent is not a v1 root, such as
  a subagent's own subagent from before v0.0.8 (from then until D91 a
  subagent had no subagent tool, so no v1 build opens one), or one whose
  parent is gone or does not list it, is kept as it is. `fx sessions convert` names each
  under `kept` and `fx doctor` names each too, with the reason, and its
  family converts without it. **Why:** no v1 session is left unexplained.
  **Alternative:** convert descendants at every depth, for sessions no
  build opens.

Settled for prompt images (2026-10-19, after a model searched the disk
for an image pasted into its prompt):
- **D89 Decision (amends D44 and D79):** each prompt image becomes its own
  blob, named by its digest, when its turn starts and before the turn's
  first request is built (`AgentRuntimeDeps.save_prompt_images`). D44's
  reason for keeping prompt images inside the user's item holds when an
  image is captured, before the session is on disk, but not when its turn
  starts.
  - The `user` item names the image by `blob`, without its base64 bytes or
    the temporary snapshot path of the process that captured it. The blob
    is listed on the turn's next item, so a fork hard-links it and
    `verify` checks it.
  - A conversion's import saves each converted prompt image the same way,
    and a recalled image keeps its bytes (D84), so its turn saves it too.
  - In memory a saved image is only its handle too: the blob's path and
    its digest. Whatever needs the bytes, a request, Vision or a recall,
    reads them from the blob and checks them against the digest, as v1
    read an image's snapshot file. A resumed session loads no image bytes,
    and the turn's own copy drops them once the blob is saved. The
    request still sends the bytes inline. Its note and every notice for an
    image left out of it name the blob's path (D79), so the model can open
    the image with its tools.
  - Every save lists the blob again, so the next turn that sends an image
    repairs a listing a crash lost. The session remembers the digests it
    saved, so every copy of the turn a host commits encodes the same way
    and the commit matches what was streamed.
  - An image the store does not save keeps its bytes inline, as before,
    and no note or notice names a file for it. A blob an item names that
    is gone damages the session when it opens (D39). One whose bytes were
    damaged is found by `verify` and by any reader, which leaves the image
    out as it does a damaged snapshot. Items written before D89 read as
    they did.
  - `PromptImages.tla` checks that a note names only a saved, listed blob,
    that every request sends every image, and that a fork holds every blob
    its items name, for a conversion's import as for a turn. `mutants.py`
    plants eight bugs against it.

  **Why:** D79 kept each image twice, as its blob and as base64 inside the
  item, a third larger than its bytes, and wrote both only when the user
  item was written, after the first request named the blob. Keeping the
  bytes in memory too would hold every image of a long session for as long
  as it is open, and copy them again for each turn's Vision catalog.
  **Alternative:** save at capture, when no session is on disk (D44);
  keep D79's two copies; load every blob when the session opens; or name
  the temporary snapshot, which is gone when its process exits.

Settled for `/status` (2026-10-23, after a user could find a session's id
only by quitting):
- **D90 Decision (amends D2's exit line and D58):** `/status` in the
  interactive app opens a panel in the footer, and writes nothing to the
  transcript. Its first line names the open session as `<id> · saved`
  exactly when its log is on disk, so `fx --resume <id>` opens it, and as
  `<id> · not saved yet` before then. A shell with no session, because none
  could be created, shows `none · this shell can't save sessions`. While
  the panel is open, it follows a turn that saves the session or ends. The
  manager answers whether the log is on disk
  (`Session.onDisk`): from the publish of the first turn, or from the open
  of a resumed or forked session. A failed session keeps the log it had.
  One whose first publish failed counts as not on disk, though the publish
  may have landed before the failure, so `/status` errs toward unsaved.
  - The adapter's `saved` asks the manager instead of counting turns. A
    fork before the first prompt holds no turn, but its log is on disk
    from the fork, and resume opens it. Counting turns hid it: the exit
    line left it out, while `/status` would have to show it as unsaved.
    Now the exit line and `/status` give the same answer for every
    session.
  - `fx status` runs outside any session and shows none.
  - `tests/tla/session/ShellSession.tla` models the open session across
    launches, prompts, `/new`, `/clear`, `/resume`, `/fork`, quitting and
    crashes, with what `/status` and the exit line say. Its planted bugs
    include counting turns. `tests/tla/drivers/session/` runs the real
    binary along it and has TLC check every run.

  **Why:** a user who wants to come back to a session needs its id while
  it is open, and an id is useful only when fx says truthfully whether it
  can be resumed yet. **Alternative:** show the id only once saved; print
  the full `fx --resume` command; or keep counting turns and show a fork
  before its first prompt as unsaved, though resume opens it.

Settled for nested subagents (2026-10-25, replacing D88's rule that a
subagent has no subagent tool):
- **D91 Decision:** every agent is the same kind of session node, and
  subagents nest to depth 3. The root is the node at depth 0.
  - A child's line 1 records `parent`, `root` and `depth` (`root` and
    `depth` are new optional fields of `session_created`). A line 1
    without them is a root at depth 0, or a child written before D91, at
    depth 1 under its parent. The layout stays flat: one folder per
    session, and each node's `child_spawned` and `child_finished` lines in
    its own parent's log. Nothing infers the tree from paths.
  - One spawn policy (`src/core/subagent/tree.zig` `SpawnPolicy`) decides
    every spawn, checked by the node's host: nodes sit at depths 0 to
    `max_depth` (3), a node has at most 64 children, and a tree holds at
    most 256 nodes below its root, counted across every depth from the
    saved logs on first need.
  - A node's abilities come from its depth once, when its host starts. A
    child's tools are a subset of its parent's, and a node at the depth
    limit is not offered the subagent tool. A child's permission mode is
    never wider than the node that spawns it
    (`authority.admitChildPermission`). No code asks whether a session is
    a child.
  - The root's host is created by the frontend and owns the tree. Every
    child has its own host for its children, whose children live in the
    child's own log; D96 says how long it lives (it first lived for one
    turn of the child). A cancel stops the subtree deepest first. A child
    may outlive its parent's turn, as yielded work of the root or as a
    person's message to it (D96), but never the root's host.
  - A node's host answers whether it or any of its descendants runs
    (`Runtime.subtreeBusy`), the check a rewind of that node must pass
    (D97).

  `Tree.tla` checks the depth limit, the tree budget, that every ancestor
  waits while a descendant lives, and that no node is an orphan.
  **Why:** a tree of identical nodes keeps one code path for every depth,
  and recording the place in the tree on line 1 lets any reader place a
  session without opening its ancestors. **Alternative:** keep subagents
  flat; or give each depth its own host kind.
- **D92 Decision:** a child's turn runs only while it holds a run slot:
  one of its tree's pool (8) and one of the process's pool (32), taken in
  that order and given back in reverse (`slot_pool.zig` `Permit`). The
  session, turn state and kernel of a child's turn start after it holds
  its slot. A parent blocked on its children lends its slot back while it
  waits, and takes one again before its turn goes on. A parallel tool
  group delegates to at most 8 children at once. `Tree.tla` checks that
  never more turns run than there are slots, and, with fairness, that a
  queued child always runs, so a chain from the root to depth 3 cannot
  deadlock even with one slot. **Why:** threads and turn state were
  unbounded in the number of delegations. **Alternative:** one thread per
  child, as before; or a slot held across the wait, which deadlocks a
  chain deeper than the pool.
- **D93 Decision:** one approval registry per tree. Each pending approval
  carries the path of node ids from the root to the node that asked, and
  the host forwards every pending approval up to a bound, oldest first
  (`Runtime.pendingApprovalRequests`). An approval resolves against the
  asking node's id at any depth. **Why:** a frontend that watches the root
  sees every approval in its tree and can name the node that asked.
  **Alternative:** a registry per node, which the frontend would have to
  find and poll one by one.
- **D94 Decision:** a child's result reaches its parent with at most 6000
  bytes inline. A longer one keeps its start and names a handle to the
  whole text, saved as a blob of the parent's session, which
  `read_tool_result` reads. **Why:** a deep tree would otherwise carry
  every descendant's full answer in each ancestor's context.
  **Alternative:** the general 64 KiB tool result cap, which is too large
  to repeat at every level.
- **D95 Decision:** one process-wide kernel pool owns every Python kernel
  (`src/core/kernel/pool.zig`), keyed by the node's snapshot directory, so
  each session node has one kernel however many runtimes or nested hosts
  reach it. A session runtime holds it through its `kernel.Slot`. A
  child's turn names its tree as the kernel's retainer, so the kernel's
  live process outlives that turn and the nested host that ran it, until
  the root host closes the tree. Admission is bounded by memory, not by a
  count: the sweeper samples each live kernel's and zygote's private memory
  (phys_footprint on macOS, Pss on Linux), and while the total, or the
  total plus an estimate for a kernel about to start, exceeds the budget
  (a quarter of physical memory, at most 4 GiB, or
  `PROTO_FX_KERNEL_MEMORY_BUDGET`), the least recently used idle kernel
  parks (snapshot, then stop); the next cell restores it. One kernel always
  stays. A hard ceiling of 32 live processes, the process slot pool,
  applies whatever the budget. A kernel running a cell is never parked:
  over budget with nothing parkable, a start is admitted anyway, since the
  budget is a soft target on a lagging sample and the sweeper parks as soon
  as cells end; at the ceiling with every kernel busy, a start waits up to
  a minute and then refuses. An idle kernel also parks after a TTL: 5
  minutes when no runtime holds it, 30 minutes when one does, such as an
  open root session. A park whose snapshot fails leaves the kernel running.
  Kernels fork from a single-threaded zygote per interpreter that has
  imported the runtime and dill and frozen its objects out of the
  collector, so they share those pages; the zygote reaps them, and this
  process signals a forked kernel only while its pid still has the
  recorded start time. A dead zygote is replaced on the next start, and
  any zygote failure falls back to a direct spawn. **Why:** each kernel is
  a Python process of 10 to 20 MiB before user imports, the same count of
  kernels can cost very different memory, and a tree of 256 nodes could
  otherwise keep one alive per node. **Alternative:** a fixed cap of 4
  live kernels, which parked work the machine could hold; kernels owned by
  each node host, which stopped a grandchild's kernel at the end of every
  turn of its parent; or refusing at once when the pool is full, which
  fails a fan-out of children that only needed to queue.

Settled for persistent node hosts and rewinding nodes (2026-10-25):
- **D96 Decision:** every node below the root keeps its host between its
  turns. One registry per tree (`src/core/subagent/node_hosts.zig`) owns
  each node host: the node's only writable log handle in the process, its
  children, and the host that runs them. A host opens on demand, for the
  node's own turn (which its parent runs and leases the host for), for a
  person's message to one of its children, or for a command on it, and
  each lease of a deep node leases the hosts on its way down. Every open
  host holds its parent's open, so hosts nest as the tree does. A host
  closes only with no lease, no open child host and no running work, once
  idle past a TTL (5 minutes, `PROTO_FX_NODE_HOST_IDLE_MS`) or while the
  tree has more open hosts than its cap (16, `PROTO_FX_MAX_NODE_HOSTS`),
  least recently used first; the next use opens it again from its log.
  The root host closes the tree: every node's work is told to stop, every
  turn ends, and the hosts close deepest first. A node's model, effort and
  latest context use live on its own log (`prefs` and `usage`), so they
  survive its host closing; its kernel lives in the process pool (D95).
  A person may message an idle named node at any depth: its parent's host
  runs the message as that parent's own `message` call would, lending no
  run slot, since no turn of the parent holds one, and with a mode no
  wider than the parent's. `NodeHosts.tla` checks that an open host's
  ancestors are open, that a running turn or a use keeps its host open,
  and, with fairness, that idle hosts close and the tree's closing closes
  every host. **Why:** a host that lived for one turn of its node left a
  node below depth 1 with nobody to take a message or a command between
  turns. **Alternative:** a host per turn, as D91 first had; or hosts that
  never close, which grow with every node a tree ever ran.
- **D97 Decision:** a node is rewound in place, never forked. A
  `rewound` line (a new manager line kind, written between turns) names
  the turns it drops, from a turn through the newest, and the children
  first spawned once that turn started, which become abandoned. The fold
  keeps the dropped turn ranges and the abandoned mark per child; replay
  leaves the dropped turns out of every history, fork points included,
  and turn numbers keep growing past them. The manager refuses a rewind
  inside a turn, past the newest turn, or over a child whose work is
  open, and fx refuses one over a compaction newer than the turn, whose
  summary covers what would stay. `/undo` on a child node rewinds its
  newest turn (a node keeps no file journal of its own). A rewind runs
  only while the node and every node below it are idle: the node's parent
  admits no turn of it, the node admits no child, and the registry leases
  no host at or below it until the line is written. The parent's recorded
  tool result of the node's earlier work never changes; the rewind only
  changes what the node's later turns see. An abandoned node, and every
  node below it, stays browsable but read-only: messages and changing
  commands are refused with a typed reason, the browser shows it as
  abandoned, and its parent's registry drops it, so the agent name is free
  for a new child. A fork of a node is D98's, never a sibling: its parent
  addresses its children by name, and a sibling would be a child the
  parent never started.
  `Rewind.tla` checks that a dropped turn comes only with the subtree
  idle, that exactly the children of dropped turns are abandoned, that no
  abandoned node or node below it runs again, and that the parent's
  record only grows. **Why:** an append-only log keeps every line, so a
  rewind has to be a line that later readers apply; abandoning children in
  the same line keeps the tree and the history consistent after a crash.
  **Alternative:** fork the node to a new id, which breaks its parent's
  record of it; or truncate the log, which the manager never does.

- **D98 Decision:** `/fork` of a node at any depth makes a new root
  session, through the same fork as the root's (D58, D5): the manager
  copies the node's log through its newest kept turn, every line kind
  as it is (unknown and future kinds included, a `rewound` line with the
  turns it drops), and hard-links every blob. The copy owns none of the
  node's children, so their results stay in the transcript as text and
  their names are free. Line 1 keeps `forked_from` naming the node and
  adds `forked_node {root, turn}`, the source tree and turn, as a field of
  its own that readers before D98 skip; the title says the same, such as
  "forked from root › reviewer · turn 4". The fork drops the child's
  instructions from its preferences but keeps the node's first prompt, its
  mission, as the first turn. It is a normal root: it has the subagent
  tool at depth 0, its own tree budget and run slots, the node's
  kernels and store as they were at the fork point (D99), and the
  session's permission mode rather than the ceiling
  the node had under its parent. The person's `/fork` authorizes that
  wider authority, as opening any root session would. The source tree is
  not changed, and the frontend switches to the fork as root `/fork`
  does. Refused while a turn of the node runs. `Wiring.tla` checks that
  a fork of the root or of any node is a new root (`ForkIsNewRoot`).
  **Why:** a person forks a subagent to give it their own attention, so
  it gets its own session. **Alternative:** a sibling node under the same
  parent, which the parent never asked for; or refusing the fork.

- **D99 Decision (amends D95 and D98):** a node's Python state lives in
  its own session log. Three manager line kinds, allowed only inside a
  turn and stamped with it: `store_set {turn, key, blob}` and
  `store_del {turn, key}` for the `proto_fx` store, and
  `kernel_snapshot {turn, kernel, names, blobs, failed}` for a kernel's
  globals at the end of a turn in which it ran a cell. Each global is one
  record, its dill bytes a content-addressed blob of the node's session,
  so unchanged globals reuse their blobs and every turn's state is kept
  for the life of the session. The kernel process writes its records into
  the node's blob folder with the manager's blob steps; only the manager
  writes lines, and every read checks a blob against its name. A turn's
  end snapshots each due kernel under its command gate before the end
  line, so no later cell comes first. Both states fold on demand and skip
  lines of turns a rewind dropped, so a rewind returns the node's kernels
  to the newest snapshot it kept (they restart and restore in the
  background) and a fork at turn N restores the newest snapshot at or
  before N, with no fork or rewind code of their own. A park writes the
  same records and is remembered by the process, which restores it before
  the log. Background saves are gone: a crash mid-turn restores the last
  ended turn. `PythonState.tla` checks `RestoreExact`. **Why:** a fork or
  undo at any turn must give that turn's exact Python state. **Alternative:**
  one snapshot file per kernel, which kept only the newest state.

- **D100 Decision:** the supervisor deletes a session as a job on that
  session's executor. The job refuses while a client watches the session,
  another request waits behind it, or a turn, host request, running child,
  or armed heartbeat is outstanding. It then saves the session stopped and
  closes its host, deletes the v2 family through the manager (D13), the
  terminal and side folders of every member, and their kernel folders, and
  marks the session retired; the accept loop drops the row and saves the
  registry last. A crash after the stopped save never reopens the session,
  and discovery prunes a stopped row whose conversation is gone. A v1 root
  not converted yet (D59) is refused, not reported deleted. **Why:** only
  the executor starts work on a session, so its check and the stop that
  follows see the same state. **Alternative:** checking from a connection
  thread, which a request queued between the check and the stop defeats.

- **D110 Decision:** a settled background job's result reaches the model
  exactly once. Each job source keeps one reservation at a time per job
  (the managed execution runtime's delivery state for shell jobs, a
  delivery table for fleet turns); a consumer reserves the result, and
  commits it once the model has it or releases it so it stays deliverable.
  A `jobs wait` leases its targets, counted so overlapping waits keep the
  lease, and automatic delivery skips leased jobs; when the wait returns,
  what it did not take is delivered automatically. `tests/tla/jobs/Jobs.tla`
  checks `ExactlyOnceDelivery` and `NoDeliveryUnderLease`. **Why:** a shell
  `interact`, a wait and the notice all read the same output, and only the
  source can tell whether it was handed over. **Alternative:** a delivered
  flag in the registry, which a shell interact bypasses.

- **D111 Decision:** jobs that settle with nobody waiting are delivered by
  the supervisor's tick as one async-result notice, a `<system-notice>` fx
  writes. It steers a running turn at its next safe boundary without
  cutting a streaming reply short, and wakes an idle session with a turn of
  its own, as proto does for finished background work. Steering keeps the
  notice out of the user envelope, saves it whole, and the transcript shows
  one status row per job. The notice's results stay reserved until the
  host answers it: a steer the turn took, or a turn it ran, commits them;
  a dropped steer or a failed turn releases them for a later tick, after a
  backoff. Until the turn hands a queued notice to the model, a wait on
  one of its jobs withdraws it and returns the result itself, as proto's
  wait makes a queued delivery stale (`Jobs.tla` `WaitReclaim`). A turn
  the notice starts is saved with the `job_notice` user origin, never
  inferred from its text: the auto reviewer's trusted root requests skip
  it and keep the person's latest request current, the notice reaches the
  reviewer only as untrusted evidence, and it cannot invoke a skill.
  **Why:** the model
  should react to a result as soon as it can, and a stopped session must
  not run. **Alternative:** holding results for the next user prompt,
  which leaves a finished build unread until the person types.

- **D112 Decision:** the `subagent` tool becomes the `fleet` tool, one tool
  with the ops `run`, `spawn`, `send`, `list`, `inspect` and `terminate`.
  `run` waits for its one turn, as `subagent` did, and with a label runs it
  on that named worker (the old `message`). `spawn` and `send` answer at
  once with a receipt (accepted, queued, steered, rejected or terminal)
  naming the turn job `<worker id>-t<turn>`, the turn number reserved at
  acceptance and saved on the work's `child_spawned` or `child_queued`
  line. The node's host keeps each job in a ledger (`turn_jobs.zig`) that
  the jobs registry reads. When a turn settles, the fleet stores its result
  behind a `read_tool_result` handle and calls the registry's settle hook;
  the fleet never hands a result to the model itself, and the registry
  delivers each settled turn once, to a waiter or as an async notice.
  `Fleet.tla` checks `ExactlyOnceDelivery` for those two takers.
  **Why:** proto's workers run beside their parent and report as they
  settle. **Alternative:** keeping `message` for peers, which fx has no
  bus for; it stays `run` with a label.

- **D113 Decision:** a worker's queued turns and its tombstone live in its
  parent's log. Two manager line kinds: `child_queued {child, work_id,
  data}` appends to the child's queue, which its next `child_spawned`
  takes from the front and a cancelled `child_finished` drops from;
  `child_terminated {child, data}` is allowed only between the child's
  work items and makes it terminal: it takes no more work, its queue is
  gone, and it stays listed and readable. The end of a turn and the start
  of the queue's front are one save, unless the turn was cancelled. A
  terminate cancels and joins the running turn before its line.
  `Fleet.tla` checks `QueueInOrder` and `NoWorkAfterTerminate`. **Why:**
  a send queued behind a busy worker must survive a restart, and a
  terminated worker must never run again. **Alternative:** a queue kept
  only in memory, which a restart loses.

- **D120 Decision:** the model's `checkpoint(goal)` and `rewind(report)`
  reuse D97's `rewound` line, with a seq `from`: written inside the open
  turn, it drops that turn's items from `from` up to the line, and
  abandons the children first spawned after them; the turn and its number
  stay, and replay skips exactly those items. A checkpoint belongs to the
  running turn and is read from its messages: the newest successful
  `checkpoint` call with no successful `rewind` after it. So it survives
  whatever keeps the turn, a detached client or a resumed turn, holds at
  most one open, and closes with the turn. A rewind keeps the steps
  through the checkpoint's and its own step, whose result carries the
  report; the agent loop applies it when the step ends, the saved turn
  first and then its messages. It keeps the node's kernels and store,
  because an exploration usually computes results worth keeping in
  variables, and it never undoes file edits; the tool descriptions say
  both. It is refused while a worker or child node of the node runs, and
  it only closes the checkpoint when a compaction came after it, whose
  summary already covers the exploration. A reply while a checkpoint is
  open gets a hidden reminder instead of ending the turn, at most three
  a turn; then the turn ends and the person is told. The footer names
  the open checkpoint, and the compact transcript shows a rewind as one
  `branch · ctrl+o` divider. `Checkpoint.tla` checks `AtMostOneOpen`,
  `DropsOnlySinceCheckpoint`, `NoRewindWhileBusy`, `KeepsPython` and
  `RemindersBounded`. **Why:** proto's investigations keep only their
  findings in context, and fx can do the same without a second rewind
  path. **Alternative:** restoring the kernels to the checkpoint, which
  D99 makes exact but throws away what the exploration computed; or a
  checkpoint that outlives its turn, whose rewind would have to drop a
  person's later prompts.

- **D125 Decision:** recall reads a node's history from its log, not from
  the compactor's M and T records. The log keeps every turn word for word
  after a compaction (only the context restarts at the summary), it leaves
  out turns a rewind dropped (D97), and it numbers turns as
  `history://<id>/turn/<n>` names them, so a hit on a compacted turn opens
  through `read_file` like any other; reading the records as well would
  find each compacted turn twice. Each node's index is built on first use
  and cached in its tree, at most four nodes, labelled with the log's newest
  line seen before the build; a call whose node logged a newer line builds
  again. The tree frees the cache after every node host closed.
  `RecallCache.tla` checks `FreshAtStart`, `CacheBounded` and
  `NoUseAfterFree`. Every node of a tree may read every other through
  `history://` and `agent://`, as in proto; other trees are refused.
  **Why:** one source for the agent's own history and the nodes it reads.
  **Alternative:** searching the compactor's records, which miss turns not
  compacted yet and know no turn numbers.

## Design Risks And Failure Behavior

- **Stale index.** A crash between publish and the index append hides a
  session until rebuild; `list` self-heals missing folders
  (`Catalog.tla`).
- **Wrong snapshot.** Snapshots are derived and can be ignored; a test
  requires fold equivalence (`ResumeSnapshot.tla`). A state too large
  for one line gets no snapshot: the append succeeds, the diagnostic says
  so, and resume folds from the previous snapshot. Found in the API check:
  the error used to reach the host after its batch was written, skipping
  that batch's `fsync`.
- **Seq reuse after a machine crash.** Only a seq past a durability point is
  stable (`SessionLog.tla`).
- **Power cut on macOS (accepted by D3).**
  - The newest synced turns can be lost.
  - A rare damaged middle line opens the session read-only up to the last
    good line; damage older than the newest snapshot is found by `read` and
    `verify` instead.
  - The specs model only the guarantee a plain `fsync` gives: an fx or OS
    crash, or a power cut on Linux.
- **Unmodeled wasm locking.** wasm's single writer relies on the embedder
  honoring `expectedRevision`. `WriterLock.tla` models only flock; a buggy
  embedder store could allow two writers.
- **Converter correctness.** It must handle every v1 format still on disk,
  including children and interrupted turns, so it needs testing against real
  sessions.
- **A session continued in an old binary after conversion** keeps its newer
  turns only in the v1 copy (D16).
- **Two locations per session.** The session folder and the terminal folder
  (D13). A missed delete leaves an orphan terminal folder, which doctor
  removes.
- **Behavior changes.**
  - Creation at the first turn means a session-level `/model` or `/rename`
    before any prompt is not kept in the session.
  - An unused ACP session is not kept, and loading its id after a restart
    returns NotFound (D24).
  - Handles become hashes.
  - The E2E suite must pass unchanged, or each difference must be approved.
- **Hard links.** Same filesystem only, which holds inside the sessions root;
  a copy is the fallback.
- **Profile usage recovery.** The markers stay fx's. v2 sessions have their
  own folder, `~/.fx/usage-recovery-v2/{id}`, read by the same recovery,
  which compares the checkpoint's own time with the marker's instead of file
  times (D20). fx has since dropped these markers with its usage ledger.
- **Side folder retired (D27, D48).** A v2 session no longer has side files;
  older sessions move on their first writable open (D47). A move cut short
  leaves the side folder until the next open, and doctor removes folders
  whose session is gone. A missed terminal-folder delete is swept the same
  way (D45).

## Verification

- **Changed contract:**
  - unit tests at each level;
  - tests asserting every invariant of the matching spec;
  - TLC runs of every spec plus `mutants.py`;
  - a fold-equivalence property test;
  - trace validation of the code against the specs, where every trace from
    unit tests, the driver and the crash matrix must be accepted by
    `trace/validate.sh`. The hook contract is in `trace/README.md`;
    this ran in the standalone module, and fx's build compiles the hook out.
- **Integration:** a standalone driver running the four native host thread
  models through the API, plus a wasm host double over a fake `sessionStore`.
- **Failure:**
  - `kill -9` at every append and durability step;
  - a fault-injecting L0 that drops unsynced bytes and tears lines;
  - flipped bits for the checksum;
  - two processes contending for one session.
- **Migration:** the converter run against real v1 sessions from the current
  release, including children, interrupted turns and wasm snapshots; a second
  start converts only sessions created since.
- **Commands:** `fx session recover` on a session with a damaged middle line
  produces a writable copy up to the last good turn; the source is
  unchanged.
- **Permissions:** tests check `0700` folders, `0600` files and `0400`
  blobs, and refuse a
  symlinked session path.
- **Diagnostics:** every repair in the crash matrix emits exactly one
  diagnostics event.
- **Real path:** `./zig-out/bin/fx` exercised interactively, through
  `fx ask` and through ACP; the fx E2E session suite and
  `sdk/tests/test-term-session-resume.mjs`.
- **Regression:** the E2E suite; the startup benchmark unchanged.

## Implementation Freedom

- private names and the file split inside each level;
- allocator strategy;
- the JSON encoder;
- the backward-scan block size;
- fsync versus fdatasync on Linux;
- the blob threshold below the hard cap;
- the index rewrite threshold;
- the snapshot distance, tuned to 64 KB by the benchmark;
- test names and fixture layout.
