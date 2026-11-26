---------------------------- MODULE TraceResultStore ----------------------------
(***************************************************************************)
(* Checks recorded traces of the real result store against ResultStore's  *)
(* design.                                                                 *)
(*                                                                         *)
(* tests/tla/drivers/bash_tool/ runs the store on the real code (the result *)
(* files in src/core/session/result_files.zig, the text in                  *)
(* src/core/bash_results/ and src/tools/bash/program_output.zig) and writes *)
(* each run as one sequence of states into TraceData.tla. Each state is    *)
(* what the code showed, with the model's variables. The session around    *)
(* the store (which program runs and ends, the saved bash state, the damage *)
(* and the heal, the client's wait) follows the model's rules in the       *)
(* harness, and ConformsToSpec checks those steps too.                     *)
(*                                                                         *)
(* ConformsToSpec holds when every recorded step is a step of ResultStore's *)
(* Next, so each run is a behavior of the model. The invariants re-export  *)
(* the model's store rules, checked on what the code did. Liveness         *)
(* (EverySentIsSaved) needs the whole state space, so ResultStore.tla       *)
(* checks it, not this module.                                             *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets, TraceData

VARIABLES sent, current, phase, ready, waiting, shown, files, indexed, unsaved,
          fullNoticed, stopped, restarts, runs, saves, torn, how, savedBy, refused,
          noticed, damaged, lost, lostNoticed, unreported, trace, at

vars == <<sent, current, phase, ready, waiting, shown, files, indexed, unsaved,
          fullNoticed, stopped, restarts, runs, saves, torn, how, savedBy, refused,
          noticed, damaged, lost, lostNoticed, unreported>>

MC == INSTANCE ResultStore WITH Programs <- {"p1", "p2", "p3"}, Room <- 2,
                                 MaxRestarts <- 1, Mutation <- "none"

ToSet(s) == {s[i] : i \in DOMAIN s}

\* A recorded state's sets come as sequences, and its functions as records.
Load(s) ==
    /\ sent = ToSet(s.sent)
    /\ current = s.current
    /\ phase = s.phase
    /\ ready = s.ready
    /\ waiting = s.waiting
    /\ shown = ToSet(s.shown)
    /\ files = ToSet(s.files)
    /\ indexed = ToSet(s.indexed)
    /\ unsaved = ToSet(s.unsaved)
    /\ fullNoticed = ToSet(s.fullNoticed)
    /\ stopped = ToSet(s.stopped)
    /\ restarts = s.restarts
    /\ runs = s.runs
    /\ saves = s.saves
    /\ torn = s.torn
    /\ how = s.how
    /\ savedBy = ToSet(s.savedBy)
    /\ refused = ToSet(s.refused)
    /\ noticed = ToSet(s.noticed)
    /\ damaged = s.damaged
    /\ lost = ToSet(s.lost)
    /\ lostNoticed = ToSet(s.lostNoticed)
    /\ unreported = s.unreported

LoadNext(s) ==
    /\ sent' = ToSet(s.sent)
    /\ current' = s.current
    /\ phase' = s.phase
    /\ ready' = s.ready
    /\ waiting' = s.waiting
    /\ shown' = ToSet(s.shown)
    /\ files' = ToSet(s.files)
    /\ indexed' = ToSet(s.indexed)
    /\ unsaved' = ToSet(s.unsaved)
    /\ fullNoticed' = ToSet(s.fullNoticed)
    /\ stopped' = ToSet(s.stopped)
    /\ restarts' = s.restarts
    /\ runs' = s.runs
    /\ saves' = s.saves
    /\ torn' = s.torn
    /\ how' = s.how
    /\ savedBy' = ToSet(s.savedBy)
    /\ refused' = ToSet(s.refused)
    /\ noticed' = ToSet(s.noticed)
    /\ damaged' = s.damaged
    /\ lost' = ToSet(s.lost)
    /\ lostNoticed' = ToSet(s.lostNoticed)
    /\ unreported' = s.unreported

TraceInit == trace \in 1..Len(Traces) /\ at = 1 /\ Load(Traces[trace][1])

TraceNext ==
    /\ at < Len(Traces[trace])
    /\ at' = at + 1
    /\ trace' = trace
    /\ LoadNext(Traces[trace][at + 1])

TraceSpec == TraceInit /\ [][TraceNext]_<<vars, trace, at>>

\* Every run starts where the model starts.
StartsAtInit == at = 1 => MC!Init

\* Every recorded step is a step of the model.
ConformsToSpec == [][MC!Next]_vars

TypeOK == MC!TypeOK
NoReuse == MC!NoReuse
IndexNamesFile == MC!IndexNamesFile
FullNoticed == MC!FullNoticed
SavedBeforeShown == MC!SavedBeforeShown
StoreAppendOnly == MC!StoreAppendOnly

\* Witnesses: each must be violated on the runs that reach it, which the driver checks.
OrphanWitness == MC!OrphanWitness
FullWitness == MC!FullWitness
ResumeWitness == MC!ResumeWitness

=============================================================================
