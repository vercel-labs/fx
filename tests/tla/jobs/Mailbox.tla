------------------------------- MODULE Mailbox -------------------------------
(***************************************************************************)
(* Messages between the agents of a tree reach the recipient's model       *)
(* exactly once and in order, across a crash, a restart and a parked host  *)
(* (D185 to D189).                                                         *)
(*                                                                         *)
(* One recipient. A sender appends a message to the recipient's mailbox,   *)
(* a durable log; a full mailbox drops its oldest message first. The       *)
(* message then reaches the model by one of three carriers, one at a time *)
(* (OneCarrier):                                                           *)
(*   - a steer or a root notice: the batch is in flight in memory until    *)
(*     the model takes it into its history (Absorb), then the batch leaves *)
(*     the mailbox (Commit); a steer the turn never took goes back         *)
(*     (Release);                                                          *)
(*   - a turn of its own: the turn's admission is durable in the parent's  *)
(*     log, so the batch leaves the mailbox at once and the turn runs      *)
(*     later, even after a crash (AdmitTurn, RunTurn);                     *)
(*   - an inbox read or a mailbox wait, which takes the batch into a tool  *)
(*     result.                                                             *)
(* A crash loses what is in flight. On restart, recovery takes a waiting   *)
(* message that the history already holds out of the mailbox as delivered *)
(* (RecoverDelivered). A mailbox wait holds automatic delivery off.        *)
(*                                                                         *)
(* Code: src/core/subagent/mailbox.zig (send, post, deliverWorker,         *)
(* settleSteers, recover, takeRootNotice, rootAnswered, inbox, waitRoot),  *)
(* src/core/session_manager/fold_mail.zig, src/core/supervisor/wake.zig.   *)
(*                                                                         *)
(* `Mutation` enables one broken rule so TLC shows each property bites:    *)
(*   no_recover        recovery leaves an absorbed message waiting         *)
(*   commit_early      a steer's batch leaves the mailbox before it is     *)
(*                     absorbed                                            *)
(*   overtake          a new batch is taken while one is in flight         *)
(*   release_absorbed  a steer the model took goes back to the mailbox     *)
(*   ignore_wait       automatic delivery takes mail a wait holds          *)
(*   two_carriers      an inbox read runs beside a delivery                *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS N, Cap, MaxCrashes, MaxWaits, MaxReleases, Mutation

ASSUME Mutation \in {"none", "no_recover", "commit_early", "overtake",
                     "release_absorbed", "ignore_wait", "two_carriers"}

Msgs == 1..N

VARIABLES
    next,       \* the next message a sender sends
    box,        \* the durable mailbox: waiting messages, oldest first
    dropped,    \* messages a full mailbox dropped
    history,    \* the model's durable history, in the order it got them
    flight,     \* a steer or notice batch in memory, not absorbed or released
    absorbed,   \* the in-flight batch's messages the model took
    turnq,      \* messages durably admitted turns carry, not run yet
    carrier,    \* "none", or "read" while an inbox read holds the mailbox
    waiting,    \* a mailbox wait holds automatic delivery off
    stolen,     \* automatic delivery took mail while a wait held it
    up,         \* the process runs
    recovered,  \* recovery ran since the last start
    parked,     \* the recipient's host is closed
    crashes,    \* budgets that keep the model finite and fair
    waits,
    releases

vars == <<next, box, dropped, history, flight, absorbed, turnq, carrier, waiting, stolen, up, recovered, parked, crashes, waits, releases>>

SetOf(s) == {s[i] : i \in DOMAIN s}
Remove(s, set) == SelectSeq(s, LAMBDA m : m \notin set)
Keep(s, set) == SelectSeq(s, LAMBDA m : m \in set)

TypeOK ==
    /\ next \in 1..(N + 1)
    /\ box \in Seq(Msgs)
    /\ dropped \subseteq Msgs
    /\ history \in Seq(Msgs)
    /\ flight \subseteq Msgs
    /\ absorbed \subseteq flight
    /\ turnq \in Seq(Msgs)
    /\ carrier \in {"none", "read"}
    /\ waiting \in BOOLEAN
    /\ stolen \in BOOLEAN
    /\ up \in BOOLEAN
    /\ recovered \in BOOLEAN
    /\ parked \in BOOLEAN
    /\ crashes \in 0..MaxCrashes
    /\ waits \in 0..MaxWaits
    /\ releases \in 0..MaxReleases

Init ==
    /\ next = 1
    /\ box = <<>>
    /\ dropped = {}
    /\ history = <<>>
    /\ flight = {}
    /\ absorbed = {}
    /\ turnq = <<>>
    /\ carrier = "none"
    /\ waiting = FALSE
    /\ stolen = FALSE
    /\ up = TRUE
    /\ recovered = TRUE
    /\ parked = FALSE
    /\ crashes = 0
    /\ waits = 0
    /\ releases = 0

\* post: a full mailbox drops its oldest message not in flight, else its
\* oldest. A message to a parked host reopens it (revive).
Send ==
    /\ up /\ next <= N
    /\ IF Len(box) < Cap
       THEN /\ box' = Append(box, next)
            /\ UNCHANGED dropped
       ELSE LET free == {i \in DOMAIN box : box[i] \notin flight}
                victim == IF free = {} THEN box[1] ELSE box[CHOOSE i \in free : \A j \in free : i <= j]
            IN /\ box' = Append(Remove(box, {victim}), next)
               /\ dropped' = dropped \cup {victim}
    /\ next' = next + 1
    /\ parked' = FALSE
    /\ UNCHANGED <<history, flight, absorbed, turnq, carrier, waiting, stolen, up, recovered, crashes, waits, releases>>

\* deliverWorker and takeRootNotice: one batch at a time, never past an
\* inbox read, a wait, or an admitted turn that has not run.
CanTake ==
    /\ up /\ recovered /\ Remove(box, flight) /= <<>>
    /\ (flight = {} \/ Mutation = "overtake")
    /\ (turnq = <<>> \/ Mutation = "overtake")
    /\ carrier = "none"
    /\ (~waiting \/ Mutation = "ignore_wait")

\* A steer of the running turn, or the root's notice: the batch in flight.
TakeSteer ==
    /\ CanTake
    /\ LET b == SetOf(box) \ flight IN
       /\ flight' = flight \cup b
       /\ box' = IF Mutation = "commit_early" THEN Remove(box, b) ELSE box
    /\ stolen' = (stolen \/ waiting)
    /\ UNCHANGED <<next, dropped, history, absorbed, turnq, carrier, waiting, up, recovered, parked, crashes, waits, releases>>

\* The turn takes the steer, or runs the notice's turn: the model gets the
\* oldest message of the batch it has not got.
Absorb ==
    /\ up /\ flight \ absorbed /= {}
    /\ LET pending == flight \ absorbed
           first == CHOOSE m \in pending : \A k \in pending : m <= k
       IN /\ history' = Append(history, first)
          /\ absorbed' = absorbed \cup {first}
    /\ UNCHANGED <<next, box, dropped, flight, turnq, carrier, waiting, stolen, up, recovered, parked, crashes, waits, releases>>

\* settleSteers, or rootAnswered(delivered): the absorbed batch leaves.
Commit ==
    /\ up /\ flight /= {} /\ absorbed = flight
    /\ box' = Remove(box, flight)
    /\ flight' = {} /\ absorbed' = {}
    /\ UNCHANGED <<next, dropped, history, turnq, carrier, waiting, stolen, up, recovered, parked, crashes, waits, releases>>

\* The turn ended before it took the steer: the batch waits again, in front.
Release ==
    /\ up /\ flight /= {} /\ releases < MaxReleases
    /\ (absorbed = {} \/ Mutation = "release_absorbed")
    /\ flight' = {} /\ absorbed' = {}
    /\ releases' = releases + 1
    /\ UNCHANGED <<next, box, dropped, history, turnq, carrier, waiting, stolen, up, recovered, parked, crashes, waits>>

\* deliverWorker's own turn: admitted durably in the parent's log, so the
\* batch leaves the mailbox at once.
AdmitTurn ==
    /\ CanTake
    /\ turnq' = turnq \o Remove(box, flight)
    /\ box' = Keep(box, flight)
    /\ stolen' = (stolen \/ waiting)
    /\ UNCHANGED <<next, dropped, history, flight, absorbed, carrier, waiting, up, recovered, parked, crashes, waits, releases>>

\* The admitted turn runs, after a restart too: the model gets its batch.
RunTurn ==
    /\ up /\ turnq /= <<>>
    /\ history' = history \o turnq
    /\ turnq' = <<>>
    /\ UNCHANGED <<next, box, dropped, flight, absorbed, carrier, waiting, stolen, up, recovered, parked, crashes, waits, releases>>

\* inbox, or one poll of a mailbox wait: it holds the mailbox and takes
\* what waits, unless a batch is in flight, which reaches the model first.
ReadStart ==
    /\ up /\ recovered /\ carrier = "none"
    /\ carrier' = "read"
    /\ UNCHANGED <<next, box, dropped, history, flight, absorbed, turnq, waiting, stolen, up, recovered, parked, crashes, waits, releases>>

Read ==
    /\ up /\ carrier = "read" /\ box /= <<>>
    /\ (flight = {} \/ Mutation = "two_carriers")
    /\ turnq = <<>>
    /\ history' = history \o box
    /\ box' = <<>>
    /\ UNCHANGED <<next, dropped, flight, absorbed, turnq, carrier, waiting, stolen, up, recovered, parked, crashes, waits, releases>>

ReadEnd ==
    /\ carrier = "read"
    /\ carrier' = "none"
    /\ UNCHANGED <<next, box, dropped, history, flight, absorbed, turnq, waiting, stolen, up, recovered, parked, crashes, waits, releases>>

\* waitRoot holds automatic delivery off while it waits; it reads with
\* ReadStart and Read as it polls.
WaitStart ==
    /\ up /\ ~waiting /\ waits < MaxWaits
    /\ waiting' = TRUE
    /\ waits' = waits + 1
    /\ UNCHANGED <<next, box, dropped, history, flight, absorbed, turnq, carrier, stolen, up, recovered, parked, crashes, releases>>

WaitEnd ==
    /\ waiting
    /\ waiting' = FALSE
    /\ UNCHANGED <<next, box, dropped, history, flight, absorbed, turnq, carrier, stolen, up, recovered, parked, crashes, waits, releases>>

\* A wrongly concurrent delivery beside a read (`two_carriers`).
TakeBesideRead ==
    /\ Mutation = "two_carriers"
    /\ up /\ recovered /\ carrier = "read" /\ flight = {} /\ turnq = <<>> /\ box /= <<>>
    /\ flight' = SetOf(box)
    /\ UNCHANGED <<next, box, dropped, history, absorbed, turnq, carrier, waiting, stolen, up, recovered, parked, crashes, waits, releases>>

\* An idle host closes; a host with work in flight stays open.
Park ==
    /\ up /\ ~parked /\ flight = {} /\ carrier = "none"
    /\ parked' = TRUE
    /\ UNCHANGED <<next, box, dropped, history, flight, absorbed, turnq, carrier, waiting, stolen, up, recovered, crashes, waits, releases>>

\* Memory goes; the logs stay.
Crash ==
    /\ up /\ crashes < MaxCrashes
    /\ up' = FALSE
    /\ flight' = {} /\ absorbed' = {}
    /\ carrier' = "none" /\ waiting' = FALSE
    /\ recovered' = FALSE
    /\ crashes' = crashes + 1
    /\ UNCHANGED <<next, box, dropped, history, turnq, stolen, parked, waits, releases>>

Restart ==
    /\ ~up
    /\ up' = TRUE
    /\ UNCHANGED <<next, box, dropped, history, flight, absorbed, turnq, carrier, waiting, stolen, recovered, parked, crashes, waits, releases>>

\* recover: a waiting message the history holds leaves as delivered.
Recover ==
    /\ up /\ ~recovered
    /\ box' = IF Mutation = "no_recover" THEN box ELSE Remove(box, SetOf(history))
    /\ recovered' = TRUE
    /\ UNCHANGED <<next, dropped, history, flight, absorbed, turnq, carrier, waiting, stolen, up, parked, crashes, waits, releases>>

Next ==
    \/ Send \/ TakeSteer \/ Absorb \/ Commit \/ Release \/ AdmitTurn \/ RunTurn
    \/ ReadStart \/ Read \/ ReadEnd \/ WaitStart \/ WaitEnd \/ TakeBesideRead
    \/ Park \/ Crash \/ Restart \/ Recover

Done ==
    /\ next > N /\ box = <<>> /\ turnq = <<>> /\ flight = {}
    /\ carrier = "none" /\ ~waiting /\ up /\ recovered

SafetySpec == Init /\ [][Next \/ (Done /\ UNCHANGED vars)]_vars

Spec ==
    /\ SafetySpec
    /\ WF_vars(Send) /\ WF_vars(Restart) /\ WF_vars(Recover)
    /\ SF_vars(TakeSteer \/ AdmitTurn) /\ WF_vars(Absorb) /\ WF_vars(Commit)
    /\ WF_vars(RunTurn) /\ WF_vars(ReadEnd) /\ WF_vars(WaitEnd)

(***************************************************************************)
(* Properties                                                              *)
(***************************************************************************)

Count(s, m) == Cardinality({i \in DOMAIN s : s[i] = m})

\* No message reaches the model twice, across crashes and restarts.
ExactlyOnce == \A m \in Msgs : Count(history, m) <= 1

\* The model gets the messages in the order they were sent.
InOrder == \A i, j \in DOMAIN history : i < j => history[i] < history[j]

\* The mailbox never holds more than its cap.
Bounded == Len(box) <= Cap

\* A sent message is waiting, admitted, received, or dropped: none is lost.
NoLossAcrossRestart ==
    \A m \in 1..(next - 1) :
        \/ m \in SetOf(box) \/ m \in SetOf(history) \/ m \in SetOf(turnq) \/ m \in dropped

\* Automatic delivery never takes mail while a wait holds the mailbox.
NoDeliveryUnderWait == ~stolen

\* Every message reaches the model or is dropped.
EventuallyDelivered == <>Done
=============================================================================
