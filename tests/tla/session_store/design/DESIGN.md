# Design: the legacy cleanup

Status: design. No product code changed. The cleanup's model is `Prune.tla` in `tests/tla/session_store/`, and `check.sh` runs its configs, each with its expected verdict. Architect step 6 (a spike in the real program) is not run, because a spike is product code. Part 1 (small bodies) is a later change; its design and models are kept outside this repository.

## Decisions for the lead

1. Part 2: keep the original log as `pruned/log.jsonl` (the default), or discard it after a successful check. Discarding is irreversible.
2. Scope of phase 1: legacy `set usage` and snapshots only (8 logs). Other superseded `set` keys stay until they are proved.
3. Command words: `prune` and `restore` under `fx session`, and the flags `--dry-run`, `--discard-original`, `--all`, were approved by the maintainer and are built as subcommands of the `session` group (Block 4).
4. When this lands: a decision in `system-design.md` (the next number is D101) and a row in `tests/tla/README.md`.

## What the person sees

After the cleanup, an old session's log shrinks from 421.8 MB to about 175.5 MB, and its transcript, totals, resume and fork give the same results. The original stays on disk until the person discards it.

## Facts

Log

| Fact | Where |
|---|---|
| Fact | Where |
|---|---|
| Line: `v`, `seq`, `ts`, `kind`, fields, CRC32C, newline | `schema.zig:1-7`, `:13`; `log.zig:100-130` |
| Writes are one append; fsync only for durable kinds (`set` usage, permissions, moved_files, turn ends, children) | `log.zig:326-341`; `session.zig:1105-1119` |
| Torn tail cut on a writable open | `log.zig:282-308`, `:459` |
| Lines larger than 4 MiB are refused | `log.zig:21` |

Readers and seq

| Fact | Where |
|---|---|
| Every reader requires consecutive seq: a gap is `Corrupt` | `log.zig:198-200` (scanner), `:561-565` (forward), `:636-640` (backward) |
| A newer `v` refuses the open with `UnsupportedVersion`; the lock-free reader does not check `v` | `log.zig:194-196`; `session.zig:1255-1258`; `ForwardReader` checks only `checkLine` (`log.zig:552-566`) |
| Resume: line 1, then the newest snapshot found backward, then the tail | `session.zig:1313-1390` (`:1331-1343`, `:1364-1381`) |
| `stateAt` reads from line 1 and never uses a snapshot | `session.zig:1991-2003` |
| Fold: set keys are newest-wins | `fold.zig:245-250` |
| Fork copies the source's lines verbatim, seq included; snapshots are re-framed | `session.zig:2188-2200`; links for blobs at `:613-628` |
| A fork's view ends at `forkSeq`; child lines at or before it are the source's | `session.zig:1347`; `fold.zig:225-257` |
| `compaction_offset` is a byte offset, stored in the state and in snapshots | `fold.zig:234`, `:382-383`; `schema.zig:169`, `:224` |
| Session-adapter cursors use that offset | `session_adapter.zig:3466`, `:3500`, `:3510` |
| `State.eql` compares `compaction_offset` and `last_seq` | `fold.zig:183-199` |

Unknown kinds

| Fact | Where |
|---|---|
| A kind this build does not know becomes `null`, and the fold skips it | `schema.zig:36-38` |
| Resume skips it and clears `clean_exit` | `session.zig:1374-1378` |
| The page reader gives an entry with a null body | `session.zig:1632-1644` |
| Adapter readers test `entry.body orelse continue`; `lastStarted` runs only after an item body check | `session_adapter.zig:452`, `:2823`, `:3555`, `:4046`, `:4064`, `:5592`; `:5517-5518` |
| Verify and the other scans skip unknown kinds | `session.zig:2009`, `:2046`, `:2138`, `:2459`; `trace.zig:383` |

Released builds

| Fact | Where |
|---|---|
| The skip rule, the seq checks and `UnsupportedVersion` are all in v0.0.13, the oldest tag that has the v2 store (`73559f73db`, tags `v0.0.13` to `v0.0.15` contain it) | `git show v0.0.13:src/core/session_manager/{schema,log,session}.zig`; `git tag --contains 73559f73db` |
| v0.0.13 has the same null-body behavior and `clean_exit = false` | `git show v0.0.13:src/core/session_manager/session.zig` lines `1504-1507`, `1243` |
| The repo records no install base, so "still in use" is unknown | (no file) |

Legacy usage

| Fact | Where |
|---|---|
| Old writer: `{"at_ms":N,"snapshot":{...}}`, from `encodeUsage` | `git show a41fc2d421^:src/core/session/session_adapter.zig:3097-3104` |
| New writer: five token fields, once per reply, durable | `session_adapter.zig:3313-3328`; `session.zig:1114` |
| New reader: the newest value as `types.Usage`, unknown fields ignored, so the old shape reads as zero; no trace line | `session_adapter.zig:3331-3343` (`:3335`, `:3338`) |
| This reset is intended: "a value in any other shape counts from zero" | `tests/tla/session_manager/system-design.md:1609-1616` |

Measured (names, counts and sizes only; no session text read or printed)

| Measure | Value |
|---|---|
| Largest old session: log, lines | 421,782,300 B; 101,611 |
| Old session: `set usage` lines, all legacy shape | 32,103 (`at_ms`, `snapshot` only) |
| Old session: snapshot lines | 4,745 |
| Largest current session: log, lines | 152,528,099 B; 82,894 (83,017 a minute later: it is live) |
| Whole store | 1,729 logs, 6.04 GB of log; 8 logs hold legacy usage (32,148 lines, 198.5 MB, in logs of 421.9 MB total) |
| Forks and children | 21 forked sessions from 17 sources; 1,303 child sessions; neither large session is a fork source |

## The cleanup of legacy logs

### Facts that bind the design

Seq: every reader requires consecutive seq (`log.zig:198-200`, `:561-565`, `:636-640`). Fork and child references use seq: a fork's view ends at `forkSeq` (`session.zig:1347`, `fold.zig:225-257`), a child's `seq` is the line it was spawned on (`fold.zig:251`), `covers_seq` names a line (`schema.zig:169`), and `forked_from` holds a source seq (`schema.zig`, `ForkOrigin`). Renumbering therefore breaks forks and children. Gaps break every reader.

Unknown kinds: skipped by every reader in this tree (facts above), and the same in v0.0.13. The one unguarded `entry.body.?` (`session_adapter.zig:5518`) runs after a body check, so a placeholder never reaches it.

Offsets: `compaction_offset` is a byte offset. Shrinking any earlier line moves it, so the kept snapshot's offset must be recomputed.

Replay equality: `State.eql` includes `compaction_offset` (`fold.zig:195`), so the replay check must mask it and compare the rest.

### Design

Which lines go: every legacy `set usage` that a newer usage line supersedes, and every snapshot except the newest valid one (CRC passes and the body parses). Per-reply `set usage` lines never go: a fork point reads their totals, so replacing one would change that fork's state. Nothing else in phase 1.

Stand-in: each removed line becomes `{"v":1,"seq":N,"ts":T,"kind":"pruned","crc":"........"}`, with its seq and ts kept. Old builds skip it, as the unknown-kind rule says. Its size is about 60 bytes (2,647,419 B for the largest old session's 36,846 lines).

Offsets: the newest snapshot is rewritten with `compaction_offset` recomputed for the new file. Positions before a snapshot do not depend on its own length, so one pass is enough.

Protocol under the writer lock (`session.zig:1230-1235`; busy exits 1):

1. Take the session's flock. A busy session is refused.
2. Verify the whole log (`session.zig:2422`).
3. Write `log.jsonl.pruning` in the session folder, with each line's CRC, and fsync it.
4. Replay check on that file (below). On any mismatch, delete it, exit 1, and leave the log alone.
5. Hard link `log.jsonl` to `pruned/log.jsonl` (no copy, and the original inode survives), then fsync the folder.
6. Rename `log.jsonl.pruning` over `log.jsonl` (atomic), then fsync the folder.
7. Unlock and print sizes.

Crash: before step 5 the original is untouched and a leftover temp file is deleted by the next run. After step 5 the log is still the original and the link keeps it. After step 6 the cleanup is done. The disk is not freed until the original is discarded.

Replay check, on the new file before step 5 (`prune_replay.zig`): the two logs are read in step, and a stand-in may replace only a legacy usage line or a snapshot, and must keep its seq and ts. Every other line is byte-identical, except a kept snapshot, which is checked as below. The folded state is equal at each turn boundary and at the end, with `compaction_offset` not compared and a legacy usage value read as no totals. Every kept snapshot decodes, covers the line before it, and equals the fold of the lines it covers. The model's `FoldEqual` checks the usage meaning and item count for every prefix, and `SnapshotMeaningValid` checks the snapshot values (`Prune.tla`). `verifySession` is checked by the prune test on the result, not by the replay check.

Restore (`restoreWith`, under the writer lock): the restored log is the first original, byte for byte, then every line of the current log past the original's last seq. Those are the turns written after the cleanup, and restore never drops one. Nothing is linked: the original is the source, and `pruned/` is deleted last.

Steps:

1. Take the session's flock. A busy session is refused. No finished cleanup (the kept original is missing, or the log has no placeholders) is refused with `NotPruned`.
2. Remove a staged file a stopped run left behind, then write `log.jsonl.pruning` from the original's lines and the tail, and fsync it (`prune_rewrite.zig` `restoreWrite`).
3. A snapshot past the original is written again from the fold of the lines before it, covering the line before it, so its state and its `compaction_offset` name where it now sits. A placeholder past the original stood for a snapshot a repeat cleanup superseded, so it is written the same way. A tail snapshot that does not cover the line before it is refused (`SnapshotNotRebuildable`). Every line of the original comes back at its own seq, so a fork point or child seq that names an original line names the same line. The restored log has no placeholders in the original's range. The schema has seq references only in a fork's line 1 (`forked_from`, `schema.zig`), which lies in that range.
4. Prove the staged file with `replay.checkRestore` against the current log, before the rename. The two logs pair line for line by seq and ts. A current placeholder may stand for a legacy usage line or a snapshot (`standsFor`). Every other line is byte for byte the same, except a snapshot, which is checked against the fold of the restored lines before it: its covers, its state, and its offset. The folded states agree at each turn boundary and at the end, with the offset masked and a legacy usage value read as no totals. Items are checked by their bytes. The prune tests run `verifySession` on the result; the replay check does not. A refusal leaves the current log, `pruned/`, and the staged file (removed) as they were.
5. Rename the staged file over `log.jsonl` (atomic), then sync the folder.
6. Delete `pruned/`, then sync the folder.

Crash: before step 5 the current log is intact, and the next run removes the staged file. After step 5 the log is the restored one, with `pruned/` still present. The next prune treats `pruned/` as unfinished and deletes it; restore refuses with `NotPruned`, because the restored log holds no placeholders. No turn is lost at either point.

A cleanup can be restored at any time while `pruned/` exists, even after fx has written turns. The `GrewPastCleanup` refusal was removed for that reason.

Repeat cleanup: fx keeps writing after a cleanup, so a later run can find superseded snapshots again. A run that finds a finished cleanup (the kept original exists and the log holds placeholders) keeps that first original, links nothing, and commits its own staged log. Its report sets `original_kept`. The first original is the user's true original, so restore and discard act on it. Every line a repeat run removes is still in that original. The log between the two runs is not kept. Restore after a repeat run gives the first original plus every turn after it (see Restore). Decision for the user: keep one original per run, or keep the first only (the current design).

Dry run: read the durable lines without the lock, count and size, print only numbers. It is a snapshot of a live log, so it says so when the lock is held. Predicted numbers from a script that reads the real log: 1 usage kept, 32,102 superseded, 4,744 snapshots superseded, log 421,782,300 B to 175,459,740 B (saving 246,322,560 B, 234.9 MiB).

Multi-session scope: 8 root sessions hold legacy usage, 198.5 MB in all, and none is a child. Three of the eight are forks, and a fork's log holds copies of its source's lines. The cleanup keeps every seq, so a fork's fork point still names the same line, and each log is cleaned on its own. A fork of a cleaned session keeps its own copy until it is cleaned too.

### Command shape (fx-cli-shape)

A job on one saved session is a subcommand of the `fx session` group:

- `fx session prune <id>`: the cleanup of one session. Output: one line that names the file and the size change; `--json` gives `kind`, sizes and the original's path. Exit 0 when done or nothing to do, 1 when the work fails (busy, replay mismatch), 2 for a bad command line.
- `fx session prune --all`: the same for every session that has legacy lines. A scope flag, not a new command.
- `fx session prune <id> --dry-run` (or `--all --dry-run`): prints only sizes and touches nothing. Approved and built.
- `fx session restore <id>`: the reverse. Approved and built.
- `fx session prune <id> --discard-original`: deletes `pruned/log.jsonl`, and only after a finished cleanup. Irreversible. The maintainer approved the flag, and it is built.

Not a setting and not an env var. Not `fx doctor --fix`: doctor finds problems, and this is an optimization. Not `compact`: "compaction" already means context compaction in fx. Non-interactive runs never wait on a prompt (R5.2), so the command runs without a confirmation and the original keeps the change reversible.

### Edge cases

Empty log or no legacy lines: no-op, exit 0. One superseded line: the same protocol. A snapshot that fails its CRC: not kept as the newest valid one. Two runs at once: the second is busy. A crash at each step: as above. Full disk on the temp file: the original is untouched. A replay mismatch: the temp file is deleted. A session that is live: refused at step 1. A fork of the session: unaffected, because its log is a separate copy with the same seq. An interrupted restore: the rename is atomic.


## Proof status

- TLA+ (`tests/tla/session_store/`): `Prune.tla` only. `check.sh` runs 14 configs: the design (`prune-safety`, `prune-live`, `simulate-prune`), today's dead lines (`today-dead`), and 10 mutants, each planting one bug that its named invariant must catch. Each config is checked against its expected verdict.
- Real-code checks: the reads above, the v0.0.13 comparison, and the measured numbers. The dry-run and count scripts were read-only and lived outside the repo.
- Built and proved in code: the cleanup core (`src/core/session_manager/prune*.zig`), the `fx session prune` and `restore` commands, and the drive run on a copy of the largest old session on the Mac.
- Not done: the fx.sh pages for the new commands (a companion PR in `fx-web`).

## Open questions

- Keep one original per run, or keep the first only (the current design). See Repeat cleanup.
