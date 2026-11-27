# Flight recorder TLA+ model

`FlightRecorder.tla` models the always-on event recorder (`src/core/flight_recorder/`) against requirements R1 through R8 in `docs/flight-recorder/requirements.md` and the per-session size cap (R3.7) in `docs/flight-recorder/plan.md`, and proves which design preserves emitted events across crashes, power loss, full disks, size-cap eviction, reservation holes, concurrent segment switches, and restarts. `FlightRecorderTrace.tla` replays scripted traces from `tests/tla/drivers/flight_recorder/trace.test.ts` against `FlightRecorder.tla`.

## Designs

The `Design` constant selects one of three recorder architectures:

| Design | How events are recorded | Crash, eviction, and reset behavior |
|---|---|---|
| `current` | Bounded in-memory ring (`RingCap`); oldest entry is overwritten when full; nothing reaches disk. | `ProcessCrash`, `PowerLoss`, or `SessionReset` loses the ring. |
| `queue` | Producers push to an unbounded in-memory queue without touching disk; one recorder thread pops and writes to the segment file (kernel page cache), and `Tick` calls `fsync`. When segments exceed `MaxSegs`, `Evict` writes a gap record and deletes the oldest sealed segment. | `ProcessCrash` (`kill -9`) keeps the page cache but loses everything still in the queue with no gap count. `PowerLoss` loses the queue and page cache after the last `Tick`. |
| `mmap` | `MAP_SHARED` segment files of `SegCap` frames. Each producer runs `ReserveOffset` (atomic add reserves a slot with zero bytes), `WriteHeader` (magic, length, header CRC), `Copy` (payload bytes), and `Commit` (CRC/commit word) directly into mapped page cache. When the current segment has no room and a preallocated segment is ready, both producers may enter `switching` concurrently and run `SwitchSegment` (CAS on the current segment index; the winner seals the full segment and opens the next one, and the loser retries `ReserveOffset` in the new segment). Background `Prealloc` prepares the next segment ahead; if none is ready (or `DiskFull`), the producer never waits and increments a dropped-events counter in the mapped header. `Tick` calls `msync`. When segments exceed `MaxSegs`, `Evict` runs in two steps on the oldest sealed segment with no reserved frame in it: write a durable gap record for every event in that segment (committed or torn) first, then delete the segment. `Reopen` scans forward past zero holes and torn frames via the length header (magic plus header CRC), cuts them, turns drops, holes, and cuts into gap records, and marks crashed instances `ended_without_exit_record`. | `ProcessCrash` keeps all committed bytes, the mapped dropped counter, and any eviction gap record written before the delete; zero holes and torn in-flight frames (at most one per thread) are skipped and counted as cuts on `Reopen`. `PowerLoss` loses only events after the last `Tick`. |

## Invariants and requirements

| Invariant | Requirement | What it checks |
|---|---|---|
| `NoSilentLoss` | R1 | After `Reopen` following a `ProcessCrash`, every emitted event (not lost in an earlier power loss) is in the recovered store or counted by a gap record. |
| `PowerLossBounded` | R2 | After `Reopen` following a `PowerLoss`, every event committed before the last `Tick` (and not evicted with a durable gap record) is in the recovered store, and every missing event was emitted after the last `Tick` or counted by a gap record. |
| `TornOnlyInFlight` | R3 | Every torn frame or zero hole found at `Reopen` belonged to a thread that was between `ReserveOffset` and `Commit` at the crash (or at the last `Tick` before power loss), with at most one per thread. |
| `OrderKept` | R4 | Recovered events of each thread preserve emit order, and `(instance, seq)` is unique. |
| `InstanceEndKnown` | R5 | After `Reopen`, every earlier process instance has a clean exit record or an `ended_without_exit_record` mark. |
| `SessionIsolated` | R6 | No recorder action or failure alters the conversation log count or status. |
| `UiNeverWaitsOnDisk` | R7 | The `"ui"` thread never enters a state waiting on a disk action such as `Prealloc`. |
| `DeleteRemovesAll` | R8 | After `SessionDelete`, no recorder segments, queues, rings, counters, exit records, or recovered data of that session remain. |
| `EvictOnlySealed` | R3.7 | Eviction never removes the open (not sealed) segment, and never removes a segment that a thread still holds a reserved or copied frame in. |
| `OneSwitchPerSegment` | — | Each full or sealed segment is sealed once and gets at most one successor from `SwitchSegment` CAS. |

## Configs and mutants

- `design-mmap.cfg`: exhaustive check of `"mmap"` (`MaxEvents = 2`, `SegCap = 2`, `MaxSegs = 2`, `MaxInstances = 3`) against `TypeOK`, R1 through R8, `EvictOnlySealed`, and `OneSwitchPerSegment` (expected: pass).
- `design-queue.cfg`: `"queue"` checked against `NoSilentLoss` (expected: violate `NoSilentLoss`).
- `current-ring.cfg`: `"current"` with `RingCap = 2` checked against `NoSilentLoss` (expected: violate `NoSilentLoss`).
- `current-reset.cfg`: `"current"` with `RingCap = 4` and `AllowReset = TRUE` checked against `NoSilentLoss` (expected: violate `NoSilentLoss`).
- `mutant-no-length-header.cfg`: `"mmap"` where `WriteHeader` omits the length header, so `Reopen` cannot skip a torn middle frame (expected: violate `TornOnlyInFlight`).
- `mutant-no-resync.cfg`: `"mmap"` where `Reopen` stops at the first zero hole instead of scanning forward to the next valid header, so committed frames after the hole are neither recovered nor counted (expected: violate `NoSilentLoss`).
- `mutant-switch-without-cas.cfg`: `"mmap"` where `SwitchSegment` opens a successor without checking CAS on the current segment index, so two overflowing threads both open a successor (expected: violate `OneSwitchPerSegment`).
- `mutant-counter-in-memory.cfg`: `"mmap"` where the dropped-events counter is kept in volatile memory instead of the mapped header (expected: violate `NoSilentLoss`).
- `mutant-wait-for-prealloc.cfg`: `"mmap"` where producers wait on `Prealloc` when no next segment is ready (expected: violate `UiNeverWaitsOnDisk`).
- `mutant-no-exit-mark.cfg`: `"mmap"` where `Reopen` omits `ended_without_exit_record` (expected: violate `InstanceEndKnown`).
- `mutant-evict-without-gap.cfg`: `"mmap"` where `Evict` deletes the oldest sealed segment without writing a gap record (expected: violate `NoSilentLoss`).
- `mutant-delete-before-gap.cfg`: `"mmap"` where `Evict` deletes the segment first and writes the gap record afterward, allowing a crash in between (expected: violate `NoSilentLoss`).
- `mutant-evict-open.cfg`: `"mmap"` where `Evict` may remove an unsealed segment or a segment with a reserved frame in it (expected: violate `EvictOnlySealed`).
- `simulate-ideal.cfg` and `simulate-nonideal.cfg`: 20,000 random traces (`depth 20`, `seed 1`) of `"mmap"` with `MaxSegs = 2` without faults and with crashes, power loss, and disk full (expected: pass).

## Running

From the repository root, run TLC inside the sandbox with `fx-cloud run`:

```sh
fx-cloud run sh tests/tla/flight_recorder/check.sh
```

Run a single configuration by passing its name:

```sh
fx-cloud run sh tests/tla/flight_recorder/check.sh design-mmap
```

See `chart.mmd` for the state diagram of `"mmap"` and the shortest counterexample paths.

## Crash, trace, and full-disk tests

Build the test-only lab executable, then run the scripted TLA+ trace checks (`trace.test.ts`), the SIGKILL crash suite (`kill.test.ts`, both the 128 KiB unpaced mode and the 4 MiB paced `--delay-us 20` mode), or the full-disk suite (`fulldisk.sh`).

Linux (in the sandbox):

```sh
fx-cloud run sh -c 'zig build flight-recorder-lab && cd tests/tla/drivers/flight_recorder && bun test'
fx-cloud run sh tests/tla/drivers/flight_recorder/fulldisk.sh
```

macOS (requires a local kernel for `F_PREALLOCATE`, APFS, and `hdiutil`; `trace.test.ts` needs TLC in the sandbox):

```sh
FXC_LOCAL=1 zig build flight-recorder-lab
cd tests/tla/drivers/flight_recorder && FXC_LOCAL=1 bun test kill.test.ts
FXC_LOCAL=1 sh tests/tla/drivers/flight_recorder/fulldisk.sh
```

`fulldisk.sh` runs on request only (not in CI). On Linux it creates a 40 MB `tmpfs` and a 40 MB `ext4` loop image when root or passwordless `sudo` is available, and skips otherwise. On macOS it creates temporary 40 MB APFS disk images with `hdiutil` and detaches them on exit.
