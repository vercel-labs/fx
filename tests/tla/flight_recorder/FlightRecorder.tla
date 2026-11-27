--------------------------- MODULE FlightRecorder ---------------------------
(***************************************************************************)
(* Model of an always-on event recorder for fx (`src/core/flight_recorder/`). *)
(* Trace-checked against `flight-recorder-lab` via `FlightRecorderTrace.tla`.  *)
(*                                                                         *)
(* Compares three designs selected by the constant Design:                 *)
(*   "current"  bounded in-memory ring of capacity RingCap; overwrites     *)
(*              oldest on full; lost on crash or session reset; no disk.   *)
(*   "queue"    unbounded in-memory queue; a recorder thread pops and      *)
(*              writes to the file (page cache), fsynced on Tick.          *)
(*              ProcessCrash loses the queue; PowerLoss loses after Tick.  *)
(*   "mmap"     MAP_SHARED segment files. Producers run ReserveOffset      *)
(*              (atomic slot add, zero bytes), WriteHeader (magic + length *)
(*              + header CRC), Copy (payload), Commit (CRC word).          *)
(*              When a segment is full, producers enter switching and run  *)
(*              SwitchSegment (CAS on current segment index; loser retries *)
(*              in the new segment). Prealloc allocates the next segment   *)
(*              ahead; if none is ready, producers increment a             *)
(*              mapped-header dropped counter without waiting. Reopen      *)
(*              scans forward past holes and torn frames via the length    *)
(*              header, cuts them, reports gaps, and marks missing exits.  *)
(*              When segments exceed MaxSegs, Evict writes a durable gap   *)
(*              record first, then deletes the oldest sealed segment that  *)
(*              has no reserved frame in it.                               *)
(*                                                                         *)
(* Requirements: docs/flight-recorder/requirements.md (R1-R8) and plan.md. *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets, TLC

CONSTANTS
    Design,       \* "current" | "queue" | "mmap"
    Mutant,       \* "none" | "no_length_header" | "no_resync" | "switch_without_cas" | "counter_in_memory" | "wait_for_prealloc" | "no_exit_mark" | "evict_without_gap" | "delete_before_gap" | "evict_open"
    AllowFaults,  \* BOOLEAN: FALSE for ideal simulation, TRUE otherwise
    AllowReset,   \* BOOLEAN: TRUE to enable SessionReset in "current"
    MaxEvents,    \* max events emitted per thread across the run
    SegCap,       \* frames per segment (2)
    MaxSegs,      \* max segments on disk before eviction runs (2)
    RingCap,      \* ring capacity for Design = "current"
    MaxInstances, \* max process instances across reopens
    MaxConv       \* max conversation log turns

ASSUME Design \in {"current", "queue", "mmap"}
ASSUME Mutant \in {
    "none", "no_length_header", "no_resync", "switch_without_cas",
    "counter_in_memory", "wait_for_prealloc", "no_exit_mark",
    "evict_without_gap", "delete_before_gap", "evict_open"
}
ASSUME AllowFaults \in BOOLEAN
ASSUME AllowReset \in BOOLEAN
ASSUME MaxEvents \in Nat /\ MaxEvents >= 1
ASSUME SegCap \in Nat /\ SegCap >= 1
ASSUME MaxSegs \in Nat /\ MaxSegs >= 1
ASSUME RingCap \in Nat /\ RingCap >= 1
ASSUME MaxInstances \in Nat /\ MaxInstances >= 1
ASSUME MaxConv \in Nat /\ MaxConv >= 1

Threads == {"ui", "worker"}
NoFrame == [seg |-> 0, slot |-> 0, inst |-> 0, tid |-> "ui", seq |-> 0]

VARIABLES
    status,              \* "open" | "down" | "exited"
    deleted,             \* TRUE after SessionDelete
    instance,            \* 1..MaxInstances
    nextSeq,             \* next per-instance sequence number
    nextSegId,           \* next unique segment ID
    lastCrash,           \* "none" | "process" | "power" | "clean"
    justReopened,        \* "none" | "process" | "power" | "clean"
    tPhase,              \* [Threads -> "idle" | "offset_reserved" | "header_written" | "copied" | "switching" | "waiting_prealloc"]
    tSeq,                \* [Threads -> 0..MaxEvents]
    tFrame,              \* [Threads -> in-flight frame locator (by seg ID) or NoFrame]
    tSwitchSeg,          \* [Threads -> Nat]: segment ID seen full when entering "switching"
    switchViolation,     \* TRUE if a segment had more than one successor opened
    ring,                \* "current": bounded in-memory ring of events
    queue,               \* "queue": unbounded in-memory queue of events
    segs,                \* page cache segments: Seq([id: Nat, sealed: BOOLEAN, frames: Seq(Frame)])
    durableSegs,         \* stable storage segments (synced on Tick / Reopen)
    nextSegReady,        \* TRUE when Prealloc has prepared the next segment
    durableNextSegReady, \* stable storage copy of nextSegReady
    mappedDropped,       \* dropped-events counter in mapped segment header
    durableDropped,      \* stable storage copy of mappedDropped
    memDropped,          \* mutant_counter_in_memory: volatile dropped counter
    persistedGap,        \* cumulative gap count recorded on disk
    durableGap,          \* stable storage copy of persistedGap
    evictState,          \* "idle" | "gap_written" | "deleted_awaiting_gap"
    pendingEvictSegId,   \* segment ID awaiting delete in EvictStep2
    pendingEvictEvents,  \* events of deleted segment awaiting gap in delete_before_gap
    evictedOpenSeg,      \* TRUE if eviction ever deleted an unsealed or in-use segment
    exitRecords,         \* set of [inst: Nat, kind: "clean" | "ended_without_exit_record"]
    durableExitRecords,  \* stable storage copy of exitRecords
    recoveredEvents,     \* set of [inst, tid, seq] recovered at Reopen
    recoveredSeq,        \* sequence of [inst, tid, seq] in segment/slot order
    recoveredGap,        \* gap count reported at Reopen
    tornFound,           \* set of [inst, tid, seq] frames treated as torn at Reopen
    diskFull,            \* TRUE when disk cannot allocate new space
    convLog,             \* [accepted: 0..MaxConv, status: "ok" | "failed"]
    convExpected,        \* ghost count of conversation turns accepted
    emitted,             \* ghost set of all events emitted/started by producers
    emittedBeforeTick,   \* ghost set of emitted events started before last Tick
    completedEvents,     \* ghost set of events whose emit completed (Commit/Emit)
    committedBeforeTick, \* ghost set of events completed before last Tick
    mappedDroppedSet,    \* ghost set of events counted in mappedDropped
    durableDroppedSet,   \* stable storage copy of mappedDroppedSet
    persistedGapSet,     \* ghost set of events counted in persistedGap
    durableGapSet,       \* stable storage copy of persistedGapSet
    evictedDurableSet,   \* ghost set of evicted events with a durable gap record
    powerLost,           \* ghost set of events lost to any PowerLoss
    powerLostPrev,       \* powerLost before the most recent PowerLoss
    syncedInFlight,      \* ghost set of [inst, tid, seq] in Reserve..Copy at last Tick
    expectedInFlight     \* ghost set of [inst, tid, seq] in Reserve..Copy at crash

vars == <<
    status, deleted, instance, nextSeq, nextSegId, lastCrash, justReopened,
    tPhase, tSeq, tFrame, tSwitchSeg, switchViolation, ring, queue, segs, durableSegs,
    nextSegReady, durableNextSegReady, mappedDropped, durableDropped,
    memDropped, persistedGap, durableGap, evictState, pendingEvictSegId,
    pendingEvictEvents, evictedOpenSeg, exitRecords, durableExitRecords,
    recoveredEvents, recoveredSeq, recoveredGap, tornFound, diskFull,
    convLog, convExpected, emitted, emittedBeforeTick, completedEvents,
    committedBeforeTick, mappedDroppedSet, durableDroppedSet,
    persistedGapSet, durableGapSet, evictedDurableSet, powerLost,
    powerLostPrev, syncedInFlight, expectedInFlight
>>

(* ----------------------------- Helpers ---------------------------------- *)

EventOf(instVal, tidVal, seqVal) == [inst |-> instVal, tid |-> tidVal, seq |-> seqVal]

FrameToEvent(f) == EventOf(f.inst, f.tid, f.seq)

MakeFrame(instVal, tidVal, seqVal, hasLenVal) ==
    [inst |-> instVal, tid |-> tidVal, seq |-> seqVal,
     hasLen |-> hasLenVal, copied |-> FALSE, committed |-> FALSE]

EmptySeg(idVal) == [id |-> idVal, sealed |-> FALSE, frames |-> <<>>]

SegIdxById(segList, sid) ==
    IF \E i \in 1..Len(segList) : segList[i].id = sid
    THEN CHOOSE i \in 1..Len(segList) : segList[i].id = sid
    ELSE 0

RemoveSegAt(segList, idx) ==
    SubSeq(segList, 1, idx - 1) \o SubSeq(segList, idx + 1, Len(segList))

InFlightPhases == {"offset_reserved", "header_written", "copied"}

HasInFlightInSeg(sid) ==
    \E t \in Threads : tPhase[t] \in InFlightPhases /\ tFrame[t].seg = sid

RawSegEvents(seg) ==
    { FrameToEvent(seg.frames[j]) : j \in 1..Len(seg.frames) }

InFlightEvents ==
    { EventOf(tFrame[t].inst, tFrame[t].tid, tFrame[t].seq) :
        t \in { th \in Threads : tPhase[th] \in InFlightPhases } }

RECURSIVE CommittedSeqOf(_)
CommittedSeqOf(fs) ==
    IF fs = <<>> THEN <<>>
    ELSE LET rest == CommittedSeqOf(Tail(fs))
         IN IF Head(fs).committed
            THEN <<FrameToEvent(Head(fs))>> \o rest
            ELSE rest

(* First uncommitted frame index in fs, or 0 if all are committed. *)
FirstUncommitted(fs) ==
    IF \E i \in 1..Len(fs) : ~fs[i].committed
    THEN CHOOSE i \in 1..Len(fs) : ~fs[i].committed /\ \A j \in 1..(i - 1) : fs[j].committed
    ELSE 0

(* First zero-hole frame index in fs (no valid header written), or 0 if none. *)
FirstNoHeader(fs) ==
    IF \E i \in 1..Len(fs) : ~fs[i].hasLen
    THEN CHOOSE i \in 1..Len(fs) : ~fs[i].hasLen /\ \A j \in 1..(i - 1) : fs[j].hasLen
    ELSE 0

(* Frames recovered from one segment during Reopen. *)
SegCommittedSeq(s) ==
    IF Mutant = "no_length_header" THEN
        LET k == FirstUncommitted(s.frames)
        IN IF k = 0 THEN CommittedSeqOf(s.frames)
           ELSE CommittedSeqOf(SubSeq(s.frames, 1, k - 1))
    ELSE IF Mutant = "no_resync" THEN
        LET k == FirstNoHeader(s.frames)
        IN IF k = 0 THEN CommittedSeqOf(s.frames)
           ELSE CommittedSeqOf(SubSeq(s.frames, 1, k - 1))
    ELSE
        CommittedSeqOf(s.frames)

(* Frames treated as torn in one segment during Reopen. *)
SegTornSet(s) ==
    IF Mutant = "no_length_header" THEN
        LET k == FirstUncommitted(s.frames)
        IN IF k = 0 THEN {}
           ELSE { FrameToEvent(s.frames[j]) : j \in k..Len(s.frames) }
    ELSE IF Mutant = "no_resync" THEN
        LET k == FirstNoHeader(s.frames)
        IN IF k = 0 THEN
              { FrameToEvent(s.frames[j]) :
                  j \in { idx \in 1..Len(s.frames) : ~s.frames[idx].committed } }
           ELSE
              { FrameToEvent(s.frames[j]) :
                  j \in { idx \in 1..(k - 1) : ~s.frames[idx].committed } }
              \cup { FrameToEvent(s.frames[k]) }
    ELSE
        { FrameToEvent(s.frames[j]) :
            j \in { idx \in 1..Len(s.frames) : ~s.frames[idx].committed } }

(* Repaired segment after Reopen cuts torn frames and seals non-empty segments. *)
RepairSeg(s) ==
    IF Mutant = "no_length_header" THEN
        LET k == FirstUncommitted(s.frames)
            kept == IF k = 0 THEN s.frames ELSE SubSeq(s.frames, 1, k - 1)
        IN [id |-> s.id, sealed |-> Len(s.frames) > 0, frames |-> kept]
    ELSE IF Mutant = "no_resync" THEN
        LET k == FirstNoHeader(s.frames)
            prefix == IF k = 0 THEN s.frames ELSE SubSeq(s.frames, 1, k - 1)
            kept == SelectSeq(prefix, LAMBDA f : f.committed)
        IN [id |-> s.id, sealed |-> Len(s.frames) > 0, frames |-> kept]
    ELSE
        LET kept == SelectSeq(s.frames, LAMBDA f : f.committed)
        IN [id |-> s.id, sealed |-> Len(s.frames) > 0, frames |-> kept]

RECURSIVE AllCommittedSeq(_)
AllCommittedSeq(segList) ==
    IF segList = <<>> THEN <<>>
    ELSE SegCommittedSeq(Head(segList)) \o AllCommittedSeq(Tail(segList))

AllTornSet(segList) ==
    UNION { SegTornSet(segList[i]) : i \in 1..Len(segList) }

(* Committed events directly in segList (ignoring mutant scan truncation). *)
RawCommittedSet(segList) ==
    UNION { { FrameToEvent(segList[i].frames[j]) :
                j \in { idx \in 1..Len(segList[i].frames) : segList[i].frames[idx].committed } } :
            i \in 1..Len(segList) }

(* Uncommitted frames directly in segList. *)
RawTornSet(segList) ==
    UNION { { FrameToEvent(segList[i].frames[j]) :
                j \in { idx \in 1..Len(segList[i].frames) : ~segList[i].frames[idx].committed } } :
            i \in 1..Len(segList) }

RepairSegs(segList) ==
    [i \in 1..Len(segList) |-> RepairSeg(segList[i])]

EventSeqSet(evSeq) == { evSeq[i] : i \in 1..Len(evSeq) }

MissingExitMarks(existing, upToInst) ==
    { [inst |-> i, kind |-> "ended_without_exit_record"] :
        i \in { k \in 1..upToInst : ~\E r \in existing : r.inst = k } }

IdleThreads ==
    /\ tPhase' = [t \in Threads |-> "idle"]
    /\ tFrame' = [t \in Threads |-> NoFrame]
    /\ tSwitchSeg' = [t \in Threads |-> 0]

(* ------------------------------- Init ----------------------------------- *)

Init ==
    /\ status = "open"
    /\ deleted = FALSE
    /\ instance = 1
    /\ nextSeq = 1
    /\ nextSegId = 2
    /\ lastCrash = "none"
    /\ justReopened = "none"
    /\ tPhase = [t \in Threads |-> "idle"]
    /\ tSeq = [t \in Threads |-> 0]
    /\ tFrame = [t \in Threads |-> NoFrame]
    /\ tSwitchSeg = [t \in Threads |-> 0]
    /\ switchViolation = FALSE
    /\ ring = <<>>
    /\ queue = <<>>
    /\ segs = IF Design = "current" THEN <<>> ELSE <<EmptySeg(1)>>
    /\ durableSegs = IF Design = "current" THEN <<>> ELSE <<EmptySeg(1)>>
    /\ nextSegReady = FALSE
    /\ durableNextSegReady = FALSE
    /\ mappedDropped = 0
    /\ durableDropped = 0
    /\ memDropped = 0
    /\ persistedGap = 0
    /\ durableGap = 0
    /\ evictState = "idle"
    /\ pendingEvictSegId = 0
    /\ pendingEvictEvents = {}
    /\ evictedOpenSeg = FALSE
    /\ exitRecords = {}
    /\ durableExitRecords = {}
    /\ recoveredEvents = {}
    /\ recoveredSeq = <<>>
    /\ recoveredGap = 0
    /\ tornFound = {}
    /\ diskFull = FALSE
    /\ convLog = [accepted |-> 0, status |-> "ok"]
    /\ convExpected = 0
    /\ emitted = {}
    /\ emittedBeforeTick = {}
    /\ completedEvents = {}
    /\ committedBeforeTick = {}
    /\ mappedDroppedSet = {}
    /\ durableDroppedSet = {}
    /\ persistedGapSet = {}
    /\ durableGapSet = {}
    /\ evictedDurableSet = {}
    /\ powerLost = {}
    /\ powerLostPrev = {}
    /\ syncedInFlight = {}
    /\ expectedInFlight = {}

(* ----------------------------- Actions ---------------------------------- *)

(* Conversation log accepts a turn; independent of recorder state and faults. *)
ConvAccept ==
    /\ status = "open"
    /\ ~deleted
    /\ convExpected < MaxConv
    /\ convLog' = [convLog EXCEPT !.accepted = @ + 1]
    /\ convExpected' = convExpected + 1
    /\ justReopened' = "none"
    /\ UNCHANGED <<
        status, deleted, instance, nextSeq, nextSegId, lastCrash,
        tPhase, tSeq, tFrame, tSwitchSeg, switchViolation, ring, queue, segs, durableSegs,
        nextSegReady, durableNextSegReady, mappedDropped, durableDropped,
        memDropped, persistedGap, durableGap, evictState, pendingEvictSegId,
        pendingEvictEvents, evictedOpenSeg, exitRecords, durableExitRecords,
        recoveredEvents, recoveredSeq, recoveredGap, tornFound, diskFull,
        emitted, emittedBeforeTick, completedEvents, committedBeforeTick,
        mappedDroppedSet, durableDroppedSet, persistedGapSet, durableGapSet,
        evictedDurableSet, powerLost, powerLostPrev, syncedInFlight,
        expectedInFlight
       >>

(* Producer emit in "current": append to bounded in-memory ring, drop oldest. *)
EmitCurrent(t) ==
    /\ Design = "current"
    /\ status = "open"
    /\ ~deleted
    /\ tSeq[t] < MaxEvents
    /\ LET ev == EventOf(instance, t, nextSeq)
           nextRing == IF Len(ring) < RingCap
                       THEN Append(ring, ev)
                       ELSE Append(Tail(ring), ev)
       IN /\ ring' = nextRing
          /\ emitted' = emitted \cup {ev}
          /\ completedEvents' = completedEvents \cup {ev}
    /\ tSeq' = [tSeq EXCEPT ![t] = @ + 1]
    /\ nextSeq' = nextSeq + 1
    /\ justReopened' = "none"
    /\ UNCHANGED <<
        status, deleted, instance, nextSegId, lastCrash, tPhase, tFrame,
        tSwitchSeg, switchViolation, queue, segs, durableSegs, nextSegReady,
        durableNextSegReady, mappedDropped, durableDropped, memDropped,
        persistedGap, durableGap, evictState, pendingEvictSegId,
        pendingEvictEvents, evictedOpenSeg, exitRecords, durableExitRecords,
        recoveredEvents, recoveredSeq, recoveredGap, tornFound, diskFull,
        convLog, convExpected, emittedBeforeTick, committedBeforeTick,
        mappedDroppedSet, durableDroppedSet, persistedGapSet, durableGapSet,
        evictedDurableSet, powerLost, powerLostPrev, syncedInFlight,
        expectedInFlight
       >>

(* "current" only: diagnostics.resetSession clears the in-memory ring. *)
SessionReset ==
    /\ Design = "current"
    /\ AllowReset
    /\ status = "open"
    /\ ~deleted
    /\ Len(ring) > 0
    /\ ring' = <<>>
    /\ justReopened' = "none"
    /\ UNCHANGED <<
        status, deleted, instance, nextSeq, nextSegId, lastCrash,
        tPhase, tSeq, tFrame, tSwitchSeg, switchViolation, queue, segs, durableSegs,
        nextSegReady, durableNextSegReady, mappedDropped, durableDropped,
        memDropped, persistedGap, durableGap, evictState, pendingEvictSegId,
        pendingEvictEvents, evictedOpenSeg, exitRecords, durableExitRecords,
        recoveredEvents, recoveredSeq, recoveredGap, tornFound, diskFull,
        convLog, convExpected, emitted, emittedBeforeTick, completedEvents,
        committedBeforeTick, mappedDroppedSet, durableDroppedSet,
        persistedGapSet, durableGapSet, evictedDurableSet, powerLost,
        powerLostPrev, syncedInFlight, expectedInFlight
       >>

(* Producer emit in "queue": push to unbounded in-memory queue (never touches disk). *)
EmitQueue(t) ==
    /\ Design = "queue"
    /\ status = "open"
    /\ ~deleted
    /\ tSeq[t] < MaxEvents
    /\ LET ev == EventOf(instance, t, nextSeq)
       IN /\ queue' = Append(queue, ev)
          /\ emitted' = emitted \cup {ev}
          /\ completedEvents' = completedEvents \cup {ev}
    /\ tSeq' = [tSeq EXCEPT ![t] = @ + 1]
    /\ nextSeq' = nextSeq + 1
    /\ justReopened' = "none"
    /\ UNCHANGED <<
        status, deleted, instance, nextSegId, lastCrash, tPhase, tFrame,
        tSwitchSeg, switchViolation, ring, segs, durableSegs, nextSegReady,
        durableNextSegReady, mappedDropped, durableDropped, memDropped,
        persistedGap, durableGap, evictState, pendingEvictSegId,
        pendingEvictEvents, evictedOpenSeg, exitRecords, durableExitRecords,
        recoveredEvents, recoveredSeq, recoveredGap, tornFound, diskFull,
        convLog, convExpected, emittedBeforeTick, committedBeforeTick,
        mappedDroppedSet, durableDroppedSet, persistedGapSet, durableGapSet,
        evictedDurableSet, powerLost, powerLostPrev, syncedInFlight,
        expectedInFlight
       >>

(* Recorder thread in "queue": pops head of queue and writes to page cache segment. *)
RecorderStep ==
    /\ Design = "queue"
    /\ status = "open"
    /\ ~deleted
    /\ Len(queue) > 0
    /\ ~diskFull
    /\ LET ev == Head(queue)
           frame == [inst |-> ev.inst, tid |-> ev.tid, seq |-> ev.seq,
                     hasLen |-> TRUE, copied |-> TRUE, committed |-> TRUE]
           curIdx == Len(segs)
           hasOpen == curIdx > 0 /\ ~segs[curIdx].sealed /\ Len(segs[curIdx].frames) < SegCap
       IN /\ queue' = Tail(queue)
          /\ IF hasOpen THEN
                /\ segs' = [segs EXCEPT ![curIdx].frames = Append(@, frame)]
                /\ UNCHANGED nextSegId
             ELSE IF curIdx > 0 THEN
                /\ segs' = Append([segs EXCEPT ![curIdx].sealed = TRUE],
                                  [id |-> nextSegId, sealed |-> FALSE, frames |-> <<frame>>])
                /\ nextSegId' = nextSegId + 1
             ELSE
                /\ segs' = <<[id |-> nextSegId, sealed |-> FALSE, frames |-> <<frame>>]>>
                /\ nextSegId' = nextSegId + 1
    /\ justReopened' = "none"
    /\ UNCHANGED <<
        status, deleted, instance, nextSeq, lastCrash,
        tPhase, tSeq, tFrame, tSwitchSeg, switchViolation, ring, durableSegs,
        nextSegReady, durableNextSegReady, mappedDropped, durableDropped,
        memDropped, persistedGap, durableGap, evictState, pendingEvictSegId,
        pendingEvictEvents, evictedOpenSeg, exitRecords, durableExitRecords,
        recoveredEvents, recoveredSeq, recoveredGap, tornFound, diskFull,
        convLog, convExpected, emitted, emittedBeforeTick, completedEvents,
        committedBeforeTick, mappedDroppedSet, durableDroppedSet,
        persistedGapSet, durableGapSet, evictedDurableSet, powerLost,
        powerLostPrev, syncedInFlight, expectedInFlight
       >>

(* "mmap" producer step 1a: atomic add reserves a slot (zero bytes; no header yet), *)
(* or enters segment switch if the current segment is full and nextSegReady, or drops. *)
ReserveOffset(t) ==
    /\ Design = "mmap"
    /\ status = "open"
    /\ ~deleted
    /\ tPhase[t] \in {"idle", "waiting_prealloc"}
    /\ tSeq[t] < MaxEvents
    /\ LET curIdx == Len(segs)
           hasRoom == curIdx > 0 /\ ~segs[curIdx].sealed /\ Len(segs[curIdx].frames) < SegCap
           ev == EventOf(instance, t, nextSeq)
           zeroFrame == MakeFrame(instance, t, nextSeq, FALSE)
       IN IF hasRoom THEN
             /\ segs' = [segs EXCEPT ![curIdx].frames = Append(@, zeroFrame)]
             /\ tPhase' = [tPhase EXCEPT ![t] = "offset_reserved"]
             /\ tFrame' = [tFrame EXCEPT ![t] = [seg |-> segs[curIdx].id,
                                                 slot |-> Len(segs[curIdx].frames) + 1,
                                                 inst |-> instance, tid |-> t, seq |-> nextSeq]]
             /\ tSeq' = [tSeq EXCEPT ![t] = @ + 1]
             /\ nextSeq' = nextSeq + 1
             /\ emitted' = emitted \cup {ev}
             /\ justReopened' = "none"
             /\ UNCHANGED <<tSwitchSeg, mappedDropped, memDropped, mappedDroppedSet>>
          ELSE IF nextSegReady THEN
             /\ tPhase' = [tPhase EXCEPT ![t] = "switching"]
             /\ tSwitchSeg' = [tSwitchSeg EXCEPT ![t] = IF curIdx > 0 THEN segs[curIdx].id ELSE 0]
             /\ justReopened' = "none"
             /\ UNCHANGED <<segs, tFrame, tSeq, nextSeq, emitted,
                            mappedDropped, memDropped, mappedDroppedSet>>
          ELSE IF Mutant = "wait_for_prealloc" THEN
             /\ tPhase[t] = "idle"
             /\ tPhase' = [tPhase EXCEPT ![t] = "waiting_prealloc"]
             /\ UNCHANGED <<segs, tFrame, tSwitchSeg, tSeq, nextSeq, emitted,
                            justReopened, mappedDropped, memDropped, mappedDroppedSet>>
          ELSE
             (* Non-blocking drop: no next segment ready, record drop in counter. *)
             /\ tSeq' = [tSeq EXCEPT ![t] = @ + 1]
             /\ nextSeq' = nextSeq + 1
             /\ emitted' = emitted \cup {ev}
             /\ justReopened' = "none"
             /\ IF Mutant = "counter_in_memory"
                THEN /\ memDropped' = memDropped + 1
                     /\ UNCHANGED <<mappedDropped, mappedDroppedSet>>
                ELSE /\ mappedDropped' = mappedDropped + 1
                     /\ mappedDroppedSet' = mappedDroppedSet \cup {ev}
                     /\ UNCHANGED memDropped
             /\ UNCHANGED <<segs, tPhase, tFrame, tSwitchSeg>>
    /\ UNCHANGED <<
        status, deleted, instance, nextSegId, lastCrash, switchViolation,
        ring, queue, durableSegs, nextSegReady, durableNextSegReady,
        durableDropped, persistedGap, durableGap, evictState,
        pendingEvictSegId, pendingEvictEvents, evictedOpenSeg, exitRecords,
        durableExitRecords, recoveredEvents, recoveredSeq, recoveredGap,
        tornFound, diskFull, convLog, convExpected, emittedBeforeTick,
        completedEvents, committedBeforeTick, durableDroppedSet,
        persistedGapSet, durableGapSet, evictedDurableSet, powerLost,
        powerLostPrev, syncedInFlight, expectedInFlight
       >>

(* "mmap" producer segment switch: CAS on current segment index; loser retries. *)
SwitchSegment(t) ==
    /\ Design = "mmap"
    /\ status = "open"
    /\ ~deleted
    /\ tPhase[t] = "switching"
    /\ LET curIdx == Len(segs)
           curId == IF curIdx > 0 THEN segs[curIdx].id ELSE 0
       IN IF curId = tSwitchSeg[t] THEN
             /\ nextSegReady
             /\ segs' = IF curIdx > 0
                        THEN Append([segs EXCEPT ![curIdx].sealed = TRUE], EmptySeg(nextSegId))
                        ELSE <<EmptySeg(nextSegId)>>
             /\ nextSegId' = nextSegId + 1
             /\ nextSegReady' = FALSE
             /\ tPhase' = [tPhase EXCEPT ![t] = "idle"]
             /\ tSwitchSeg' = [tSwitchSeg EXCEPT ![t] = 0]
             /\ UNCHANGED switchViolation
          ELSE IF Mutant = "switch_without_cas" THEN
             /\ segs' = IF curIdx > 0
                        THEN Append([segs EXCEPT ![curIdx].sealed = TRUE], EmptySeg(nextSegId))
                        ELSE <<EmptySeg(nextSegId)>>
             /\ nextSegId' = nextSegId + 1
             /\ nextSegReady' = FALSE
             /\ switchViolation' = TRUE
             /\ tPhase' = [tPhase EXCEPT ![t] = "idle"]
             /\ tSwitchSeg' = [tSwitchSeg EXCEPT ![t] = 0]
          ELSE
             (* CAS lost: another thread already switched; retry reservation in new segment. *)
             /\ tPhase' = [tPhase EXCEPT ![t] = "idle"]
             /\ tSwitchSeg' = [tSwitchSeg EXCEPT ![t] = 0]
             /\ UNCHANGED <<segs, nextSegId, nextSegReady, switchViolation>>
    /\ justReopened' = "none"
    /\ UNCHANGED <<
        status, deleted, instance, nextSeq, lastCrash,
        tSeq, tFrame, ring, queue, durableSegs,
        durableNextSegReady, mappedDropped, durableDropped,
        memDropped, persistedGap, durableGap, evictState, pendingEvictSegId,
        pendingEvictEvents, evictedOpenSeg, exitRecords, durableExitRecords,
        recoveredEvents, recoveredSeq, recoveredGap, tornFound, diskFull,
        convLog, convExpected, emitted, emittedBeforeTick, completedEvents,
        committedBeforeTick, mappedDroppedSet, durableDroppedSet,
        persistedGapSet, durableGapSet, evictedDurableSet, powerLost,
        powerLostPrev, syncedInFlight, expectedInFlight
       >>

(* "mmap" producer step 1b: write frame header (magic, length, header CRC). *)
WriteHeader(t) ==
    /\ Design = "mmap"
    /\ status = "open"
    /\ ~deleted
    /\ tPhase[t] = "offset_reserved"
    /\ LET f == tFrame[t]
           idx == SegIdxById(segs, f.seg)
       IN /\ idx > 0
          /\ segs' = [segs EXCEPT ![idx].frames[f.slot].hasLen = (Mutant # "no_length_header")]
    /\ tPhase' = [tPhase EXCEPT ![t] = "header_written"]
    /\ justReopened' = "none"
    /\ UNCHANGED <<
        status, deleted, instance, nextSeq, nextSegId, lastCrash,
        tSeq, tFrame, tSwitchSeg, switchViolation, ring, queue, durableSegs,
        nextSegReady, durableNextSegReady, mappedDropped, durableDropped,
        memDropped, persistedGap, durableGap, evictState, pendingEvictSegId,
        pendingEvictEvents, evictedOpenSeg, exitRecords, durableExitRecords,
        recoveredEvents, recoveredSeq, recoveredGap, tornFound, diskFull,
        convLog, convExpected, emitted, emittedBeforeTick, completedEvents,
        committedBeforeTick, mappedDroppedSet, durableDroppedSet,
        persistedGapSet, durableGapSet, evictedDurableSet, powerLost,
        powerLostPrev, syncedInFlight, expectedInFlight
       >>

(* "mmap" producer step 2: Copy payload bytes into the reserved frame. *)
Copy(t) ==
    /\ Design = "mmap"
    /\ status = "open"
    /\ ~deleted
    /\ tPhase[t] = "header_written"
    /\ LET f == tFrame[t]
           idx == SegIdxById(segs, f.seg)
       IN /\ idx > 0
          /\ segs' = [segs EXCEPT ![idx].frames[f.slot].copied = TRUE]
    /\ tPhase' = [tPhase EXCEPT ![t] = "copied"]
    /\ justReopened' = "none"
    /\ UNCHANGED <<
        status, deleted, instance, nextSeq, nextSegId, lastCrash,
        tSeq, tFrame, tSwitchSeg, switchViolation, ring, queue, durableSegs,
        nextSegReady, durableNextSegReady, mappedDropped, durableDropped,
        memDropped, persistedGap, durableGap, evictState, pendingEvictSegId,
        pendingEvictEvents, evictedOpenSeg, exitRecords, durableExitRecords,
        recoveredEvents, recoveredSeq, recoveredGap, tornFound, diskFull,
        convLog, convExpected, emitted, emittedBeforeTick, completedEvents,
        committedBeforeTick, mappedDroppedSet, durableDroppedSet,
        persistedGapSet, durableGapSet, evictedDurableSet, powerLost,
        powerLostPrev, syncedInFlight, expectedInFlight
       >>

(* "mmap" producer step 3: Commit writes the CRC/commit word. *)
Commit(t) ==
    /\ Design = "mmap"
    /\ status = "open"
    /\ ~deleted
    /\ tPhase[t] = "copied"
    /\ LET f == tFrame[t]
           idx == SegIdxById(segs, f.seg)
           ev == EventOf(f.inst, f.tid, f.seq)
       IN /\ idx > 0
          /\ segs' = [segs EXCEPT ![idx].frames[f.slot].committed = TRUE]
          /\ completedEvents' = completedEvents \cup {ev}
    /\ tPhase' = [tPhase EXCEPT ![t] = "idle"]
    /\ tFrame' = [tFrame EXCEPT ![t] = NoFrame]
    /\ justReopened' = "none"
    /\ UNCHANGED <<
        status, deleted, instance, nextSeq, nextSegId, lastCrash,
        tSeq, tSwitchSeg, switchViolation, ring, queue, durableSegs,
        nextSegReady, durableNextSegReady, mappedDropped, durableDropped,
        memDropped, persistedGap, durableGap, evictState, pendingEvictSegId,
        pendingEvictEvents, evictedOpenSeg, exitRecords, durableExitRecords,
        recoveredEvents, recoveredSeq, recoveredGap, tornFound, diskFull,
        convLog, convExpected, emitted, emittedBeforeTick,
        committedBeforeTick, mappedDroppedSet, durableDroppedSet,
        persistedGapSet, durableGapSet, evictedDurableSet, powerLost,
        powerLostPrev, syncedInFlight, expectedInFlight
       >>

(* "mmap" recorder thread pre-allocates the next segment ahead of producers. *)
Prealloc ==
    /\ Design = "mmap"
    /\ status = "open"
    /\ ~deleted
    /\ ~nextSegReady
    /\ ~diskFull
    /\ nextSegReady' = TRUE
    /\ justReopened' = "none"
    /\ UNCHANGED <<
        status, deleted, instance, nextSeq, nextSegId, lastCrash,
        tPhase, tSeq, tFrame, tSwitchSeg, switchViolation, ring, queue, segs, durableSegs,
        durableNextSegReady, mappedDropped, durableDropped,
        memDropped, persistedGap, durableGap, evictState, pendingEvictSegId,
        pendingEvictEvents, evictedOpenSeg, exitRecords, durableExitRecords,
        recoveredEvents, recoveredSeq, recoveredGap, tornFound, diskFull,
        convLog, convExpected, emitted, emittedBeforeTick, completedEvents,
        committedBeforeTick, mappedDroppedSet, durableDroppedSet,
        persistedGapSet, durableGapSet, evictedDurableSet, powerLost,
        powerLostPrev, syncedInFlight, expectedInFlight
       >>

(* Size-cap eviction step 1 ("mmap" and "queue"): when Len(segs) > MaxSegs, *)
(* write the durable gap record first for the oldest sealed segment with no  *)
(* reserved frame in it (or mutate to omit/reorder gap or pick open/in-use). *)
EvictWriteGap ==
    /\ Design \in {"mmap", "queue"}
    /\ status = "open"
    /\ ~deleted
    /\ evictState = "idle"
    /\ Len(segs) > MaxSegs
    /\ \E k \in 1..Len(segs) :
        /\ (Mutant # "evict_open" =>
                /\ k = 1
                /\ segs[k].sealed
                /\ ~HasInFlightInSeg(segs[k].id))
        /\ LET seg == segs[k]
               evs == RawSegEvents(seg)
           IN IF Mutant = "evict_without_gap" THEN
                 /\ segs' = RemoveSegAt(segs, k)
                 /\ evictedOpenSeg' = (evictedOpenSeg \/ ~seg.sealed \/ HasInFlightInSeg(seg.id))
                 /\ UNCHANGED <<evictState, pendingEvictSegId, pendingEvictEvents,
                                persistedGap, persistedGapSet, durableGap,
                                durableGapSet, evictedDurableSet>>
              ELSE IF Mutant = "delete_before_gap" THEN
                 /\ segs' = RemoveSegAt(segs, k)
                 /\ evictState' = "deleted_awaiting_gap"
                 /\ pendingEvictEvents' = evs
                 /\ evictedOpenSeg' = (evictedOpenSeg \/ ~seg.sealed \/ HasInFlightInSeg(seg.id))
                 /\ UNCHANGED <<pendingEvictSegId, persistedGap, persistedGapSet,
                                durableGap, durableGapSet, evictedDurableSet>>
              ELSE
                 LET newGapSet == persistedGapSet \cup evs
                     newGap == Cardinality(newGapSet)
                 IN /\ persistedGapSet' = newGapSet
                    /\ persistedGap' = newGap
                    /\ IF Design = "mmap"
                       THEN /\ durableGapSet' = newGapSet
                            /\ durableGap' = newGap
                            /\ evictedDurableSet' = evictedDurableSet \cup evs
                       ELSE UNCHANGED <<durableGapSet, durableGap, evictedDurableSet>>
                    /\ evictState' = "gap_written"
                    /\ pendingEvictSegId' = seg.id
                    /\ UNCHANGED <<segs, pendingEvictEvents, evictedOpenSeg>>
    /\ justReopened' = "none"
    /\ UNCHANGED <<
        status, deleted, instance, nextSeq, nextSegId, lastCrash,
        tPhase, tSeq, tFrame, tSwitchSeg, switchViolation, ring, queue, durableSegs,
        nextSegReady, durableNextSegReady, mappedDropped, durableDropped,
        memDropped, exitRecords, durableExitRecords,
        recoveredEvents, recoveredSeq, recoveredGap, tornFound, diskFull,
        convLog, convExpected, emitted, emittedBeforeTick, completedEvents,
        committedBeforeTick, mappedDroppedSet, durableDroppedSet,
        powerLost, powerLostPrev, syncedInFlight, expectedInFlight
       >>

(* Size-cap eviction step 2: delete the segment after its gap record is written. *)
EvictDeleteSeg ==
    /\ Design \in {"mmap", "queue"}
    /\ status = "open"
    /\ ~deleted
    /\ evictState = "gap_written"
    /\ LET idx == SegIdxById(segs, pendingEvictSegId)
       IN /\ idx > 0
          /\ LET target == segs[idx]
             IN /\ segs' = RemoveSegAt(segs, idx)
                /\ evictedOpenSeg' = (evictedOpenSeg \/ ~target.sealed \/ HasInFlightInSeg(target.id))
    /\ evictState' = "idle"
    /\ pendingEvictSegId' = 0
    /\ justReopened' = "none"
    /\ UNCHANGED <<
        status, deleted, instance, nextSeq, nextSegId, lastCrash,
        tPhase, tSeq, tFrame, tSwitchSeg, switchViolation, ring, queue, durableSegs,
        nextSegReady, durableNextSegReady, mappedDropped, durableDropped,
        memDropped, persistedGap, durableGap, pendingEvictEvents,
        exitRecords, durableExitRecords, recoveredEvents, recoveredSeq,
        recoveredGap, tornFound, diskFull, convLog, convExpected, emitted,
        emittedBeforeTick, completedEvents, committedBeforeTick,
        mappedDroppedSet, durableDroppedSet, persistedGapSet, durableGapSet,
        evictedDurableSet, powerLost, powerLostPrev, syncedInFlight,
        expectedInFlight
       >>

(* Mutant delete_before_gap step 2: write the gap record after the segment was deleted. *)
EvictFinishGap ==
    /\ Design \in {"mmap", "queue"}
    /\ Mutant = "delete_before_gap"
    /\ status = "open"
    /\ ~deleted
    /\ evictState = "deleted_awaiting_gap"
    /\ LET newGapSet == persistedGapSet \cup pendingEvictEvents
           newGap == Cardinality(newGapSet)
       IN /\ persistedGapSet' = newGapSet
          /\ persistedGap' = newGap
          /\ IF Design = "mmap"
             THEN /\ durableGapSet' = newGapSet
                  /\ durableGap' = newGap
                  /\ evictedDurableSet' = evictedDurableSet \cup pendingEvictEvents
             ELSE UNCHANGED <<durableGapSet, durableGap, evictedDurableSet>>
    /\ evictState' = "idle"
    /\ pendingEvictEvents' = {}
    /\ justReopened' = "none"
    /\ UNCHANGED <<
        status, deleted, instance, nextSeq, nextSegId, lastCrash,
        tPhase, tSeq, tFrame, tSwitchSeg, switchViolation, ring, queue, segs, durableSegs,
        nextSegReady, durableNextSegReady, mappedDropped, durableDropped,
        memDropped, pendingEvictSegId, evictedOpenSeg, exitRecords,
        durableExitRecords, recoveredEvents, recoveredSeq, recoveredGap,
        tornFound, diskFull, convLog, convExpected, emitted,
        emittedBeforeTick, completedEvents, committedBeforeTick,
        mappedDroppedSet, durableDroppedSet, powerLost, powerLostPrev,
        syncedInFlight, expectedInFlight
       >>

Evict ==
    \/ EvictWriteGap
    \/ EvictDeleteSeg
    \/ EvictFinishGap

(* Periodic fsync ("queue") or msync ("mmap") when dirty state exists. *)
Tick ==
    /\ status = "open"
    /\ ~deleted
    /\ \/ durableSegs # segs
       \/ durableNextSegReady # nextSegReady
       \/ durableDropped # mappedDropped
       \/ durableGap # persistedGap
       \/ durableExitRecords # exitRecords
       \/ emittedBeforeTick # emitted
       \/ committedBeforeTick # completedEvents
       \/ syncedInFlight # InFlightEvents
    /\ durableSegs' = segs
    /\ durableNextSegReady' = nextSegReady
    /\ durableDropped' = mappedDropped
    /\ durableDroppedSet' = mappedDroppedSet
    /\ durableGap' = persistedGap
    /\ durableGapSet' = persistedGapSet
    /\ durableExitRecords' = exitRecords
    /\ emittedBeforeTick' = emitted
    /\ committedBeforeTick' = completedEvents
    /\ syncedInFlight' = InFlightEvents
    /\ justReopened' = "none"
    /\ UNCHANGED <<
        status, deleted, instance, nextSeq, nextSegId, lastCrash,
        tPhase, tSeq, tFrame, tSwitchSeg, switchViolation, ring, queue, segs, nextSegReady,
        mappedDropped, memDropped, persistedGap, evictState,
        pendingEvictSegId, pendingEvictEvents, evictedOpenSeg, exitRecords,
        recoveredEvents, recoveredSeq, recoveredGap, tornFound, diskFull,
        convLog, convExpected, emitted, completedEvents,
        mappedDroppedSet, persistedGapSet, evictedDurableSet, powerLost,
        powerLostPrev, expectedInFlight
       >>

(* Clean process exit: writes an exit record into the store when threads are idle. *)
CleanExit ==
    /\ status = "open"
    /\ ~deleted
    /\ \A t \in Threads : tPhase[t] = "idle"
    /\ status' = "exited"
    /\ lastCrash' = "clean"
    /\ justReopened' = "none"
    /\ evictState' = "idle"
    /\ pendingEvictSegId' = 0
    /\ pendingEvictEvents' = {}
    /\ queue' = <<>>
    /\ IF Design = "current"
       THEN /\ ring' = <<>>
            /\ UNCHANGED exitRecords
       ELSE /\ exitRecords' = exitRecords \cup {[inst |-> instance, kind |-> "clean"]}
            /\ UNCHANGED ring
    /\ UNCHANGED <<
        deleted, instance, nextSeq, nextSegId, tPhase, tSeq, tFrame,
        tSwitchSeg, switchViolation, segs,
        durableSegs, nextSegReady, durableNextSegReady, mappedDropped,
        durableDropped, memDropped, persistedGap, durableGap, evictedOpenSeg,
        durableExitRecords, recoveredEvents, recoveredSeq, recoveredGap,
        tornFound, diskFull, convLog, convExpected, emitted,
        emittedBeforeTick, completedEvents, committedBeforeTick,
        mappedDroppedSet, durableDroppedSet, persistedGapSet, durableGapSet,
        evictedDurableSet, powerLost, powerLostPrev, syncedInFlight,
        expectedInFlight
       >>

(* ProcessCrash (kill -9): volatile memory is lost; page cache survives. *)
ProcessCrash ==
    /\ AllowFaults
    /\ status = "open"
    /\ ~deleted
    /\ status' = "down"
    /\ lastCrash' = "process"
    /\ justReopened' = "none"
    /\ expectedInFlight' = InFlightEvents
    /\ IdleThreads
    /\ evictState' = "idle"
    /\ pendingEvictSegId' = 0
    /\ pendingEvictEvents' = {}
    /\ ring' = <<>>
    /\ queue' = <<>>
    /\ memDropped' = 0
    /\ UNCHANGED <<
        deleted, instance, nextSeq, nextSegId, switchViolation, segs, durableSegs, tSeq,
        nextSegReady, durableNextSegReady, mappedDropped, durableDropped,
        persistedGap, durableGap, evictedOpenSeg, exitRecords,
        durableExitRecords, recoveredEvents, recoveredSeq, recoveredGap,
        tornFound, diskFull, convLog, convExpected, emitted,
        emittedBeforeTick, completedEvents, committedBeforeTick,
        mappedDroppedSet, durableDroppedSet, persistedGapSet, durableGapSet,
        evictedDurableSet, powerLost, powerLostPrev, syncedInFlight
       >>

(* PowerLoss: everything after the last Tick (msync/fsync) is lost. *)
PowerLoss ==
    /\ AllowFaults
    /\ status \in {"open", "exited", "down"}
    /\ ~(status = "down" /\ lastCrash = "power")
    /\ ~deleted
    /\ status' = "down"
    /\ lastCrash' = "power"
    /\ justReopened' = "none"
    /\ IdleThreads
    /\ evictState' = "idle"
    /\ pendingEvictSegId' = 0
    /\ pendingEvictEvents' = {}
    /\ ring' = <<>>
    /\ queue' = <<>>
    /\ memDropped' = 0
    /\ segs' = durableSegs
    /\ nextSegReady' = durableNextSegReady
    /\ mappedDropped' = durableDropped
    /\ mappedDroppedSet' = durableDroppedSet
    /\ persistedGap' = durableGap
    /\ persistedGapSet' = durableGapSet
    /\ exitRecords' = durableExitRecords
    /\ expectedInFlight' = syncedInFlight
    /\ LET surviving ==
               IF Design = "current" THEN {}
               ELSE RawCommittedSet(durableSegs) \cup RawTornSet(durableSegs)
                    \cup durableDroppedSet \cup durableGapSet
           survivingDone ==
               IF Design = "current" THEN {}
               ELSE RawCommittedSet(durableSegs) \cup durableDroppedSet \cup durableGapSet
       IN /\ powerLost' = powerLost \cup (emitted \ surviving)
          /\ completedEvents' = completedEvents \cap survivingDone
    /\ UNCHANGED <<
        deleted, instance, nextSeq, nextSegId, switchViolation, tSeq, durableSegs,
        durableNextSegReady, durableDropped, durableGap, evictedOpenSeg,
        durableExitRecords, recoveredEvents, recoveredSeq, recoveredGap,
        tornFound, diskFull, convLog, convExpected, emitted,
        emittedBeforeTick, committedBeforeTick, durableDroppedSet,
        durableGapSet, evictedDurableSet, powerLostPrev, syncedInFlight
       >>

(* Reopen: new process starts, scans segments, cuts torn frames, records gaps/exits. *)
Reopen ==
    /\ status \in {"down", "exited"}
    /\ ~deleted
    /\ instance < MaxInstances
    /\ status' = "open"
    /\ instance' = instance + 1
    /\ nextSeq' = 1
    /\ justReopened' = lastCrash
    /\ powerLostPrev' = powerLost
    /\ IdleThreads
    /\ evictState' = "idle"
    /\ pendingEvictSegId' = 0
    /\ pendingEvictEvents' = {}
    /\ IF Design = "current" THEN
          /\ recoveredEvents' = {}
          /\ recoveredSeq' = <<>>
          /\ recoveredGap' = 0
          /\ tornFound' = {}
          /\ UNCHANGED <<segs, durableSegs, nextSegReady, durableNextSegReady,
                         mappedDropped, durableDropped, mappedDroppedSet,
                         durableDroppedSet, persistedGap, durableGap,
                         persistedGapSet, durableGapSet, exitRecords,
                         durableExitRecords>>
       ELSE
          LET recSeq == AllCommittedSeq(segs)
              recEvs == EventSeqSet(recSeq)
              torn == AllTornSet(segs)
              repaired == RepairSegs(segs)
              newGapSet == persistedGapSet \cup mappedDroppedSet \cup torn
              newGap == Cardinality(newGapSet)
              newExits == IF Mutant = "no_exit_mark"
                          THEN exitRecords
                          ELSE exitRecords \cup MissingExitMarks(exitRecords, instance)
          IN /\ recoveredSeq' = recSeq
             /\ recoveredEvents' = recEvs
             /\ tornFound' = torn
             /\ recoveredGap' = newGap
             /\ segs' = repaired
             /\ durableSegs' = repaired
             /\ UNCHANGED nextSegReady
             /\ durableNextSegReady' = nextSegReady
             /\ mappedDropped' = 0
             /\ durableDropped' = 0
             /\ mappedDroppedSet' = {}
             /\ durableDroppedSet' = {}
             /\ persistedGap' = newGap
             /\ durableGap' = newGap
             /\ persistedGapSet' = newGapSet
             /\ durableGapSet' = newGapSet
             /\ exitRecords' = newExits
             /\ durableExitRecords' = newExits
    /\ UNCHANGED <<
        deleted, nextSegId, lastCrash, switchViolation, tSeq, ring, queue, memDropped,
        evictedOpenSeg, diskFull, convLog, convExpected, emitted,
        emittedBeforeTick, completedEvents, committedBeforeTick,
        evictedDurableSet, powerLost, syncedInFlight, expectedInFlight
       >>

(* Disk full environment fault: prevents Prealloc and queue writes. *)
DiskFull ==
    /\ AllowFaults
    /\ ~deleted
    /\ ~diskFull
    /\ diskFull' = TRUE
    /\ justReopened' = "none"
    /\ UNCHANGED <<
        status, deleted, instance, nextSeq, nextSegId, lastCrash,
        tPhase, tSeq, tFrame, tSwitchSeg, switchViolation, ring, queue, segs, durableSegs,
        nextSegReady, durableNextSegReady, mappedDropped, durableDropped,
        memDropped, persistedGap, durableGap, evictState, pendingEvictSegId,
        pendingEvictEvents, evictedOpenSeg, exitRecords, durableExitRecords,
        recoveredEvents, recoveredSeq, recoveredGap, tornFound,
        convLog, convExpected, emitted, emittedBeforeTick, completedEvents,
        committedBeforeTick, mappedDroppedSet, durableDroppedSet,
        persistedGapSet, durableGapSet, evictedDurableSet, powerLost,
        powerLostPrev, syncedInFlight, expectedInFlight
       >>

(* Session deleted: removes all recorder data of this session, leaves convLog intact. *)
SessionDelete ==
    /\ ~deleted
    /\ deleted' = TRUE
    /\ IdleThreads
    /\ evictState' = "idle"
    /\ pendingEvictSegId' = 0
    /\ pendingEvictEvents' = {}
    /\ ring' = <<>>
    /\ queue' = <<>>
    /\ segs' = <<>>
    /\ durableSegs' = <<>>
    /\ nextSegReady' = FALSE
    /\ durableNextSegReady' = FALSE
    /\ mappedDropped' = 0
    /\ durableDropped' = 0
    /\ memDropped' = 0
    /\ persistedGap' = 0
    /\ durableGap' = 0
    /\ exitRecords' = {}
    /\ durableExitRecords' = {}
    /\ recoveredEvents' = {}
    /\ recoveredSeq' = <<>>
    /\ recoveredGap' = 0
    /\ tornFound' = {}
    /\ mappedDroppedSet' = {}
    /\ durableDroppedSet' = {}
    /\ persistedGapSet' = {}
    /\ durableGapSet' = {}
    /\ evictedDurableSet' = {}
    /\ justReopened' = "none"
    /\ UNCHANGED <<
        status, instance, nextSeq, nextSegId, lastCrash, switchViolation, tSeq, evictedOpenSeg,
        diskFull, convLog, convExpected, emitted, emittedBeforeTick,
        completedEvents, committedBeforeTick, powerLost, powerLostPrev,
        syncedInFlight, expectedInFlight
       >>

Done ==
    /\ UNCHANGED vars

Next ==
    \/ ConvAccept
    \/ \E t \in Threads : EmitCurrent(t)
    \/ SessionReset
    \/ \E t \in Threads : EmitQueue(t)
    \/ RecorderStep
    \/ \E t \in Threads : ReserveOffset(t)
    \/ \E t \in Threads : SwitchSegment(t)
    \/ \E t \in Threads : WriteHeader(t)
    \/ \E t \in Threads : Copy(t)
    \/ \E t \in Threads : Commit(t)
    \/ Prealloc
    \/ Evict
    \/ Tick
    \/ CleanExit
    \/ ProcessCrash
    \/ PowerLoss
    \/ Reopen
    \/ DiskFull
    \/ SessionDelete
    \/ Done

Spec == Init /\ [][Next]_vars

(* ---------------------------- Invariants -------------------------------- *)

TypeOK ==
    /\ status \in {"open", "down", "exited"}
    /\ deleted \in BOOLEAN
    /\ instance \in 1..MaxInstances
    /\ nextSeq \in Nat
    /\ nextSegId \in Nat
    /\ lastCrash \in {"none", "process", "power", "clean"}
    /\ justReopened \in {"none", "process", "power", "clean"}
    /\ tPhase \in [Threads -> {"idle", "offset_reserved", "header_written", "copied", "switching", "waiting_prealloc"}]
    /\ tSeq \in [Threads -> 0..MaxEvents]
    /\ switchViolation \in BOOLEAN
    /\ evictState \in {"idle", "gap_written", "deleted_awaiting_gap"}
    /\ evictedOpenSeg \in BOOLEAN
    /\ diskFull \in BOOLEAN
    /\ convLog.accepted \in 0..MaxConv
    /\ convLog.status \in {"ok", "failed"}
    /\ convExpected \in 0..MaxConv

\* R1 NoSilentLoss: after Reopen following a ProcessCrash, every emitted event
\* is either in the recovered store or counted by a gap record.
NoSilentLoss ==
    (~deleted /\ status = "open" /\ justReopened = "process") =>
        /\ recoveredEvents \subseteq emitted
        /\ Cardinality((emitted \ powerLost) \ recoveredEvents) <= recoveredGap

\* R2 PowerLossBounded: after a PowerLoss, every missing event was emitted
\* after the last Tick (or evicted with a durable gap record).
PowerLossBounded ==
    (~deleted /\ status = "open" /\ justReopened = "power") =>
        /\ committedBeforeTick \ (powerLostPrev \cup evictedDurableSet) \subseteq recoveredEvents
        /\ Cardinality((emittedBeforeTick \ powerLostPrev) \ recoveredEvents) <= recoveredGap

\* R3 TornOnlyInFlight: every torn frame found at Reopen belonged to a thread
\* that was between Reserve and Commit at the crash; at most one per thread.
TornOnlyInFlight ==
    (~deleted /\ status = "open" /\ justReopened \in {"process", "power"}) =>
        /\ tornFound \subseteq expectedInFlight
        /\ \A t \in Threads : Cardinality({ f \in tornFound : f.tid = t }) <= 1

\* R4 OrderKept: recovered events of one thread are in emit order, and
\* (instance, seq) is unique.
OrderKept ==
    (~deleted) =>
        \A i, j \in 1..Len(recoveredSeq) :
            i < j =>
                /\ ~(recoveredSeq[i].inst = recoveredSeq[j].inst /\ recoveredSeq[i].seq = recoveredSeq[j].seq)
                /\ (recoveredSeq[i].tid = recoveredSeq[j].tid =>
                        \/ recoveredSeq[i].inst < recoveredSeq[j].inst
                        \/ (recoveredSeq[i].inst = recoveredSeq[j].inst /\ recoveredSeq[i].seq < recoveredSeq[j].seq))

\* R5 InstanceEndKnown: after Reopen, every earlier instance has an exit
\* record or an ended_without_exit_record record.
InstanceEndKnown ==
    (~deleted /\ status = "open") =>
        \A i \in 1..(instance - 1) : \E r \in exitRecords : r.inst = i

\* R6 SessionIsolated: no recorder action changes the conversation log
\* variable or its status.
SessionIsolated ==
    /\ convLog.status = "ok"
    /\ convLog.accepted = convExpected

\* R7 UiNeverWaitsOnDisk: the "ui" thread never takes a step that waits for a
\* disk action (in "mmap", segment switch must not wait for Prealloc).
UiNeverWaitsOnDisk ==
    tPhase["ui"] # "waiting_prealloc"

\* R8 DeleteRemovesAll: after SessionDelete, no recorder data of that
\* session remains.
DeleteRemovesAll ==
    deleted =>
        /\ segs = <<>>
        /\ durableSegs = <<>>
        /\ queue = <<>>
        /\ ring = <<>>
        /\ mappedDropped = 0
        /\ durableDropped = 0
        /\ memDropped = 0
        /\ persistedGap = 0
        /\ durableGap = 0
        /\ exitRecords = {}
        /\ durableExitRecords = {}
        /\ recoveredEvents = {}
        /\ recoveredSeq = <<>>
        /\ recoveredGap = 0
        /\ tornFound = {}

\* R3.7 EvictOnlySealed: eviction never removes the open (not sealed) segment,
\* and never removes a segment that a thread has a reserved frame in.
EvictOnlySealed ==
    /\ ~evictedOpenSeg
    /\ \A t \in Threads :
         tPhase[t] \in InFlightPhases => SegIdxById(segs, tFrame[t].seg) > 0

\* Segment switch CAS: each full segment is sealed once and gets at most one successor.
OneSwitchPerSegment ==
    ~switchViolation

=============================================================================
