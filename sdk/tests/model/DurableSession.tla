---------------------------- MODULE DurableSession ----------------------------
(***************************************************************************)
(* One libfx session, one turn, two workers sharing one World.             *)
(*                                                                         *)
(* The turn is: a model step that calls one tool, the tool, then a model   *)
(* step that answers. Workers take the session with a lease whose entries  *)
(* form a chain in the session log. The World accepts every write (the     *)
(* "bump and report" behavior of world-vercel 5.0.1 and world-local), so a *)
(* write counts only when its writer still heads the chain, and a writer   *)
(* that does not learns it at that write and stops.                        *)
(*                                                                         *)
(* A worker reads the log, then claims: it writes the input and its lease, *)
(* which continues the chain where the worker read it. Its first model     *)
(* request goes out while the claim is written, and the turn continues     *)
(* from what the worker read; until the claim lands it writes nothing,     *)
(* shows nothing and runs no tool. A claim counts only when the chain has  *)
(* not moved since the read; a refused one leaves the worker to read       *)
(* again. With ClaimFenced = FALSE a claim counts on a stale read          *)
(* (Witness-NoClaimFence).                                                 *)
(*                                                                         *)
(* The UI stream is a separate World stream with no fencing, so a replaced *)
(* worker's late lines land in it. A worker that takes the session over    *)
(* writes its first line, turn_resume or turn_start, before it continues,  *)
(* and readers hide any line whose epoch is lower than one before it.      *)
(*                                                                         *)
(* A worker can freeze while it waits on the model or a tool; others then  *)
(* treat its lease as dead and may take the session over. A frozen worker  *)
(* that never wakes is a crash. One that wakes carries on until its next   *)
(* write, so two workers can be active at once (the witness below).        *)
(*                                                                         *)
(* With Heartbeat, a holder renews a short lease while it runs, as on a    *)
(* World that cannot tell whether a holder lives. A freeze is then any     *)
(* stall long enough for the lease to run out, and a renewal is a write:   *)
(* one that lands after a worker wakes keeps its lease when it still heads *)
(* the chain, and stops it when another worker took the session over.      *)
(*                                                                         *)
(* Shortly before its deadline a worker's own timer stops it: it cuts off  *)
(* the call still running, hands the open turn back to the log, and the    *)
(* same message comes back for a new delivery. So a lease that runs out at *)
(* the deadline never leaves its worker running, and two workers are       *)
(* active at once only when one of them froze. With SelfStop = FALSE the   *)
(* platform ends the lease while the worker runs on (Witness-NoSelfStop).  *)
(*                                                                         *)
(* A step the deadline cuts off is cut off again in each delivery when it  *)
(* always outlasts one. After MaxCutoffs cut-offs in a row with no record  *)
(* between, the next delivery stops running it: a cut-off call is answered *)
(* as possibly run, and a model request cancels the turn. With             *)
(* CutoffBound = FALSE it is run again forever (Witness-NoCutoffBound).    *)
(*                                                                         *)
(* `act` names each step and its worker, so a driver can replay any path   *)
(* of the state graph against the real code and compare every state:       *)
(* sdk/tests/model/drive.mjs.                                              *)
(***************************************************************************)
EXTENDS Naturals, Sequences

CONSTANTS
    Workers,     \* the processes that can run the session
    Tool,        \* "lookup" (safe to run twice) or "send" (has effects)
    MaxEpoch,    \* bound on lease claims
    MaxFreezes,  \* bound on freezes
    SelfStop,    \* whether a worker stops itself before its deadline
    ClaimFenced, \* whether a claim on a stale read is refused
    MaxCutoffs,  \* cut-offs of one step in a row before it is not run again
    CutoffBound, \* whether that bound applies
    Heartbeat    \* whether a holder renews a short lease while it runs

ASSUME Tool \in {"lookup", "send"}
ASSUME SelfStop \in BOOLEAN
ASSUME ClaimFenced \in BOOLEAN
ASSUME MaxCutoffs \in Nat
ASSUME CutoffBound \in BOOLEAN
ASSUME Heartbeat \in BOOLEAN

None == "none"
Waiting == {"announce", "model1", "tool", "model2"}
Busy == {"model1", "tool", "model2"}
Progress == {"start", "intent", "result", "done"}

VARIABLES
    pc,        \* where each worker is in the turn
    epoch,     \* the lease epoch each worker last claimed
    frozen,    \* whether a worker is frozen
    lease,     \* the lease at the head of the chain
    progress,  \* how far the chain has recorded the turn
    runs,      \* how many times the tool has started
    ui,        \* each line in the UI stream: its writer's epoch, and whether
               \* that writer still headed the chain when it wrote
    freezes,   \* freezes so far
    froze,     \* whether a worker froze since it last claimed the session
    chain,     \* how many counted writes the chain holds
    cutoffs,   \* deadline cut-offs in a row since the turn's last record
    seen,      \* what each worker read before its claim
    act        \* the step that led here

vars == <<pc, epoch, frozen, lease, progress, runs, ui, freezes, froze, chain, cutoffs, seen, act>>

TypeOK ==
    /\ pc \in [Workers -> {"none", "early", "announce", "model1", "tool", "model2", "done", "stopped"}]
    /\ epoch \in [Workers -> 0..MaxEpoch]
    /\ frozen \in [Workers -> BOOLEAN]
    /\ lease \in [holder: Workers \cup {None}, epoch: 0..MaxEpoch, live: BOOLEAN]
    /\ progress \in Progress
    /\ runs \in 0..(MaxEpoch + 1)
    /\ ui \in Seq([e: 0..MaxEpoch, legit: BOOLEAN])
    /\ freezes \in 0..MaxFreezes
    /\ froze \in [Workers -> BOOLEAN]
    /\ chain \in Nat
    /\ cutoffs \in Nat
    /\ seen \in [Workers -> [chain: Nat, progress: Progress, epoch: 0..MaxEpoch, cutoffs: Nat]]
    /\ act \in [name: {"Init", "Start", "Claim", "Announce", "Model1", "ToolEnd", "Model2",
                       "Freeze", "Wake", "Deadline", "Expire"},
                w: Workers \cup {None}]

Init ==
    /\ pc = [w \in Workers |-> "none"]
    /\ epoch = [w \in Workers |-> 0]
    /\ frozen = [w \in Workers |-> FALSE]
    /\ lease = [holder |-> None, epoch |-> 0, live |-> FALSE]
    /\ progress = "start"
    /\ runs = 0
    /\ ui = <<>>
    /\ freezes = 0
    /\ froze = [w \in Workers |-> FALSE]
    /\ chain = 0
    /\ cutoffs = 0
    /\ seen = [w \in Workers |-> [chain |-> 0, progress |-> "start", epoch |-> 0, cutoffs |-> 0]]
    /\ act = [name |-> "Init", w |-> None]

\* A worker's writes count while its claim heads the lease chain.
Heads(w) == lease.holder = w /\ lease.epoch = epoch[w]

\* A line w writes now.
Line(w) == [e |-> epoch[w], legit |-> Heads(w)]

\* A write that does not count may still have put a line in the UI stream.
MaybeLine(w) == ui' \in {ui, Append(ui, Line(w))}

\* The lines every reader shows: each line no earlier line outranks. The
\* same stored stream always shows the same lines.
ShownAt(lines) == {i \in 1..Len(lines) : \A j \in 1..(i - 1) : lines[j].e <= lines[i].e}

\* What w reads now: where the chain stands and how far it recorded the turn.
Read == [chain |-> chain, progress |-> progress, epoch |-> lease.epoch, cutoffs |-> cutoffs]

\* Whether w, reading now, finds work it can claim.
CanClaim == progress # "done" /\ (lease.holder = None \/ ~lease.live)

\* w receives work for the session, reads the log, and finds no live worker
\* holding it. It writes its claim and sends its first model request at
\* once; nothing it does shows or counts until the claim lands.
Start(w) ==
    /\ pc[w] \in {"none", "stopped"}
    /\ ~frozen[w]
    /\ CanClaim
    /\ lease.epoch < MaxEpoch
    /\ pc' = [pc EXCEPT ![w] = "early"]
    /\ seen' = [seen EXCEPT ![w] = Read]
    /\ UNCHANGED <<epoch, frozen, lease, progress, runs, ui, freezes, froze, chain, cutoffs>>
    /\ act' = [name |-> "Start", w |-> w]

\* w's claim lands. Its lease continues the chain where w read it, so it
\* counts only when nothing counted since. Its first line follows; until
\* then a replaced worker's late lines still show. A refused claim wrote
\* nothing that counts, and w reads the log again in the same delivery.
\* MaxEpoch bounds only the model: a claim that would pass it never lands.
Claim(w) ==
    /\ pc[w] = "early"
    /\ ~frozen[w]
    /\ IF chain = seen[w].chain \/ ~ClaimFenced
          THEN /\ seen[w].epoch < MaxEpoch
               /\ lease' = [holder |-> w, epoch |-> seen[w].epoch + 1, live |-> TRUE]
               /\ epoch' = [epoch EXCEPT ![w] = seen[w].epoch + 1]
               /\ chain' = chain + 1
               /\ pc' = [pc EXCEPT ![w] = "announce"]
               /\ froze' = [froze EXCEPT ![w] = FALSE]
               /\ UNCHANGED seen
          ELSE /\ UNCHANGED <<lease, epoch, chain, froze>>
               /\ IF CanClaim
                     THEN /\ pc' = [pc EXCEPT ![w] = "early"]
                          /\ seen' = [seen EXCEPT ![w] = Read]
                     ELSE /\ pc' = [pc EXCEPT ![w] = "none"]
                          /\ UNCHANGED seen
    /\ UNCHANGED <<frozen, progress, runs, ui, freezes, cutoffs>>
    /\ act' = [name |-> "Claim", w |-> w]

\* w writes turn_start or turn_resume and waits for it to land, then
\* continues the turn from what it read before its claim. A call left
\* running is rerun only when it is safe to run twice; otherwise the model
\* is told it may have partly run, which is stored as the call's result,
\* and the turn goes on to the answer. The records this writes are left out
\* of `chain`: in the code it follows its claim at once, and fewer chain
\* moves only let the model do more. A step
\* cut off MaxCutoffs times in a row is not run again: a call is answered
\* as possibly run, and a model request cancels the turn, whose end only
\* the chain's head writes.
Announce(w) ==
    /\ pc[w] = "announce"
    /\ ~frozen[w]
    /\ LET from == seen[w].progress
           spent == CutoffBound /\ seen[w].cutoffs >= MaxCutoffs
           rerun == from = "intent" /\ Tool = "lookup" /\ ~spent
       IN IF spent /\ from \in {"start", "result"}
          THEN /\ UNCHANGED runs
               /\ IF Heads(w)
                     THEN /\ progress' = "done"
                          /\ pc' = [pc EXCEPT ![w] = "done"]
                          /\ lease' = [lease EXCEPT !.holder = None, !.live = FALSE]
                          \* turn_resume, then turn_end
                          /\ ui' = ui \o <<Line(w), Line(w)>>
                          /\ chain' = chain + 1
                          /\ cutoffs' = 0
                     ELSE /\ pc' = [pc EXCEPT ![w] = "stopped"]
                          /\ ui' \in {Append(ui, Line(w)), ui \o <<Line(w), Line(w)>>}
                          /\ UNCHANGED <<progress, lease, chain, cutoffs>>
          ELSE /\ pc' = [pc EXCEPT ![w] =
                          CASE from = "start" -> "model1"
                            [] from = "intent" -> IF rerun THEN "tool" ELSE "model2"
                            [] from \in {"result", "done"} -> "model2"]
               /\ runs' = IF rerun THEN runs + 1 ELSE runs
               \* then tool_start for a rerun
               /\ ui' = IF rerun THEN ui \o <<Line(w), Line(w)>> ELSE Append(ui, Line(w))
               \* a call answered as possibly run is the turn's next record
               /\ IF from = "intent" /\ ~rerun /\ Heads(w)
                     THEN /\ progress' = "result"
                          /\ cutoffs' = 0
                     ELSE UNCHANGED <<progress, cutoffs>>
               /\ UNCHANGED <<lease, chain>>
    /\ UNCHANGED <<epoch, frozen, freezes, froze, seen>>
    /\ act' = [name |-> "Announce", w |-> w]

\* The model asks for the tool. The call starts only once its intent is in
\* the chain, a safe one included: after a crash, only a recorded intent
\* lets it run again.
Model1(w) ==
    /\ pc[w] = "model1"
    /\ ~frozen[w]
    /\ IF Heads(w)
          THEN /\ progress' = "intent"
               /\ runs' = runs + 1
               /\ pc' = [pc EXCEPT ![w] = "tool"]
               /\ ui' = Append(ui, Line(w))
          ELSE /\ pc' = [pc EXCEPT ![w] = "stopped"]
               /\ MaybeLine(w)
               /\ UNCHANGED <<progress, runs>>
    /\ chain' = IF Heads(w) THEN chain + 1 ELSE chain
    /\ cutoffs' = IF Heads(w) THEN 0 ELSE cutoffs
    /\ UNCHANGED <<epoch, frozen, lease, freezes, froze, seen>>
    /\ act' = [name |-> "Model1", w |-> w]

\* The tool returns, and its result goes to the chain.
ToolEnd(w) ==
    /\ pc[w] = "tool"
    /\ ~frozen[w]
    /\ IF Heads(w)
          THEN /\ progress' = "result"
               /\ pc' = [pc EXCEPT ![w] = "model2"]
               /\ ui' = Append(ui, Line(w))
          ELSE /\ pc' = [pc EXCEPT ![w] = "stopped"]
               /\ MaybeLine(w)
               /\ UNCHANGED progress
    /\ chain' = IF Heads(w) THEN chain + 1 ELSE chain
    /\ cutoffs' = IF Heads(w) THEN 0 ELSE cutoffs
    /\ UNCHANGED <<epoch, frozen, lease, runs, freezes, froze, seen>>
    /\ act' = [name |-> "ToolEnd", w |-> w]

\* The model answers; the turn ends and the worker lets the session go.
Model2(w) ==
    /\ pc[w] = "model2"
    /\ ~frozen[w]
    /\ IF Heads(w)
          THEN /\ progress' = "done"
               /\ pc' = [pc EXCEPT ![w] = "done"]
               /\ lease' = [lease EXCEPT !.holder = None, !.live = FALSE]
               \* the answer's text, then turn_end
               /\ ui' = ui \o <<Line(w), Line(w)>>
          ELSE /\ pc' = [pc EXCEPT ![w] = "stopped"]
               /\ MaybeLine(w)
               /\ UNCHANGED <<progress, lease>>
    /\ chain' = IF Heads(w) THEN chain + 1 ELSE chain
    /\ cutoffs' = IF Heads(w) THEN 0 ELSE cutoffs
    /\ UNCHANGED <<epoch, frozen, runs, freezes, froze, seen>>
    /\ act' = [name |-> "Model2", w |-> w]

\* w freezes while it waits; its lease no longer counts as alive.
Freeze(w) ==
    /\ pc[w] \in Waiting
    /\ ~frozen[w]
    /\ freezes < MaxFreezes
    /\ frozen' = [frozen EXCEPT ![w] = TRUE]
    /\ freezes' = freezes + 1
    /\ froze' = [froze EXCEPT ![w] = TRUE]
    /\ lease' = IF lease.holder = w THEN [lease EXCEPT !.live = FALSE] ELSE lease
    /\ UNCHANGED <<pc, epoch, progress, runs, ui, chain, cutoffs, seen>>
    /\ act' = [name |-> "Freeze", w |-> w]

\* w wakes and carries on from where it waited. With Heartbeat its next
\* renewal may land first: it keeps the lease where w still heads the chain,
\* and stops w where another worker took the session over.
Wake(w) ==
    /\ frozen[w]
    /\ frozen' = [frozen EXCEPT ![w] = FALSE]
    /\ \/ UNCHANGED <<pc, lease, chain>>
       \/ /\ Heartbeat
          /\ Heads(w)
          /\ lease' = [lease EXCEPT !.live = TRUE]
          /\ chain' = chain + 1
          /\ UNCHANGED pc
       \/ /\ Heartbeat
          /\ ~Heads(w)
          /\ pc' = [pc EXCEPT ![w] = "stopped"]
          /\ UNCHANGED <<lease, chain>>
    /\ UNCHANGED <<epoch, progress, runs, ui, freezes, froze, cutoffs, seen>>
    /\ act' = [name |-> "Wake", w |-> w]

\* Shortly before its deadline, w's own timer stops it and cuts off the call
\* still running; a frozen worker's timer does not run. w writes turn_yield,
\* hands the open turn back to the log and releases the session, and the
\* same message comes back at once. w takes it again, or, where the platform
\* routes it elsewhere, any worker may. A worker that was replaced without
\* knowing it learns so at the release and stops.
Deadline(w) ==
    /\ SelfStop
    /\ pc[w] \in Busy
    /\ ~frozen[w]
    /\ IF Heads(w)
          THEN /\ ui' = Append(ui, Line(w))
               /\ chain' = chain + 1
               \* its release names the turn whose step it cut off
               /\ cutoffs' = cutoffs + 1
               /\ \/ /\ lease.epoch < MaxEpoch
                     /\ lease' = [holder |-> w, epoch |-> lease.epoch + 1, live |-> TRUE]
                     /\ epoch' = [epoch EXCEPT ![w] = lease.epoch + 1]
                     /\ pc' = [pc EXCEPT ![w] = "announce"]
                     /\ froze' = [froze EXCEPT ![w] = FALSE]
                     \* it reads the log after its release and continues from there
                     /\ seen' = [seen EXCEPT ![w] = [chain |-> chain + 1, progress |-> progress, epoch |-> lease.epoch, cutoffs |-> cutoffs + 1]]
                  \/ /\ lease' = [lease EXCEPT !.holder = None, !.live = FALSE]
                     /\ pc' = [pc EXCEPT ![w] = "none"]
                     /\ UNCHANGED <<epoch, froze, seen>>
          ELSE /\ pc' = [pc EXCEPT ![w] = "stopped"]
               /\ MaybeLine(w)
               /\ UNCHANGED <<epoch, lease, froze, chain, cutoffs, seen>>
    /\ UNCHANGED <<frozen, progress, runs, freezes>>
    /\ act' = [name |-> "Deadline", w |-> w]

\* Without the self-stop: the deadline passes while w is still busy, and its
\* lease runs out while it runs on.
Expire(w) ==
    /\ ~SelfStop
    /\ pc[w] \in Busy
    /\ ~frozen[w]
    /\ Heads(w)
    /\ lease.live
    /\ lease' = [lease EXCEPT !.live = FALSE]
    /\ UNCHANGED <<pc, epoch, frozen, progress, runs, ui, freezes, froze, chain, cutoffs, seen>>
    /\ act' = [name |-> "Expire", w |-> w]

Next ==
    \E w \in Workers :
        \/ Start(w) \/ Claim(w) \/ Announce(w) \/ Model1(w) \/ ToolEnd(w) \/ Model2(w)
        \/ Freeze(w) \/ Wake(w) \/ Deadline(w) \/ Expire(w)

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
(* Properties *)

\* A call with effects never starts twice.
EffectsAtMostOnce == Tool = "send" => runs <= 1

\* The deadline cuts off one step at most MaxCutoffs times in a row: the
\* delivery after that does not run it again.
HandoffsBounded == cutoffs <= MaxCutoffs

\* A call starts only after its intent counts in the chain.
CallAfterIntent == runs > 0 => progress # "start"

\* Only the chain's head ends the turn.
DoneByHead == progress = "done" => \E w \in Workers : pc[w] = "done"

\* No reader hides a line its writer wrote while it headed the chain.
LegitShown == \A i \in 1..Len(ui) : ui[i].legit => i \in ShownAt(ui)

Active(w) == pc[w] \in Waiting /\ ~frozen[w]

\* Two workers are active at once only when one of them froze since it
\* claimed the session. A clock that stops is the one case left, and only a
\* World that refuses stale writes closes it.
TwoActiveNeedsFreeze ==
    \A v, w \in Workers : v # w /\ Active(v) /\ Active(w) => froze[v] \/ froze[w]

\* Witness, expected to FAIL: a replaced worker's line can still show when
\* it lands between its successor's claim and first line. Only a World
\* that refuses stale stream writes closes that window.
NoStaleShown == \A i \in ShownAt(ui) : ui[i].legit

\* The stream as stored, expected to FAIL: late lines land out of order.
UiInOrder == \A i \in 1..(Len(ui) - 1) : ui[i].e <= ui[i + 1].e

\* Witness, expected to FAIL: two workers active at once.
NotTwoActive ==
    ~(\E v, w \in Workers :
        /\ v # w
        /\ Active(v)
        /\ Active(w))
=============================================================================
