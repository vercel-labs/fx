--------------------------- MODULE AcpCompactionAudience ---------------------------
(***************************************************************************)
(* Who hears a compaction in a shared fx acp session, in one running turn.  *)
(*                                                                          *)
(* A session has a main client, present from the start, and other members  *)
(* that join and leave. Each member lists session.compaction or does not,   *)
(* and that never changes. A session may have no listing member at all.     *)
(*                                                                          *)
(* One compaction runs in the turn: chosen, then in_progress once its       *)
(* summary or its saving starts, then one end: completed, failed or         *)
(* cancelled. A compaction that ends before in_progress sends nothing,      *)
(* unless it failed. When a compaction completes, each member that does not *)
(* list the capability and was present at the end gets one done line,       *)
(* whether or not any member lists the capability.                          *)
(*                                                                          *)
(* The turn's copy (src/acp/server.zig replayRunningCopy): each              *)
(* delivery of the turn is kept in `copy` as an entry with two payloads, one *)
(* for a listing member (w) and one for a member that does not list (wo). A  *)
(* member that joins at any stage of the turn gets the copy filtered by its  *)
(* own listing, so a plain member that joins after the end still gets its    *)
(* done line by the replay. The copy's byte limit is left out.               *)
(*                                                                          *)
(* Two designs for the end (Design):                                        *)
(* - "a": one audience delivery under the audience lock. The end takes its  *)
(*   audience in one step: one entry with w = the end and wo = the done line. *)
(* - "b": two steps without the lock. The end entry (w = the end, wo empty) *)
(*   goes out first; the done line is a second entry (w empty, wo = done),  *)
(*   sent to the members present at that second step.                       *)
(*                                                                          *)
(* Failover: when the current main's write fails, the oldest remaining      *)
(* member becomes the main, and the old main's undelivered message is not   *)
(* sent again. Each member already has its own params from the step that    *)
(* wrote them. Mutation "failover_resend" copies the lost message, with the  *)
(* old main's params, to the new main.                                      *)
(*                                                                          *)
(* Class: "ideal" allows joins, leaves and failovers only when no compaction *)
(* runs and no end is half delivered; "nonideal" allows them at any time.    *)
(*                                                                          *)
(* The rules, by the names of the invariants and the property below:        *)
(* - OnlyListingGetsUpdates (R1): only a member that lists the capability    *)
(*   gets a compaction_update (in_progress or an end).                      *)
(* - ProgressThenEnd: a listing member gets in_progress, then one end, in    *)
(*   that order, each once; or one failed when nothing started.             *)
(* - ListingGetsProgress: a listing member present while the compaction runs *)
(*   after in_progress, or present at its end, has in_progress.             *)
(* - ListingGetsEnd: a listing member present at the end gets the end when   *)
(*   it is due: the compaction started, or it failed.                       *)
(* - ListingGetsNoDone: a listing member never gets a done line.            *)
(* - PlainGetsExactlyOneDone (R3): a member that does not list the          *)
(*   capability and was present at the end of a completed compaction has    *)
(*   exactly one done line written to it. A member that leaves before its    *)
(*   line is written has none.                                              *)
(* - JoinerSeesSameAsPresent: once the turn's deliveries are done, each      *)
(*   present member's stream equals the copy filtered by its own listing,    *)
(*   the same as a member with that listing that was present from the start. *)
(* - ExactlyOneEndOrDone: once the end is delivered, a member present at the *)
(*   end and still present has exactly one of: its end status (a lister),   *)
(*   its done line (a non-lister of a completed compaction), or nothing.    *)
(* - ListingEndDelivered (liveness, with fairness): a listing member that   *)
(*   is present at the end and stays present eventually has the end status. *)
(*                                                                          *)
(* Mutation "today" is fx acp before the change: the gate is the main        *)
(* client's listing, applied to every member, a joiner gets the copy's       *)
(* in_progress whatever it lists, and no done line is sent. Mutation        *)
(* "no_replay_after_end" gives a joiner after the end nothing. The other     *)
(* mutations each remove one guard of design "a" and break one rule (see    *)
(* check.sh). "none" is the design.                                         *)
(*                                                                          *)
(* Scope: one compaction in one turn; a main client and two more members,  *)
(* each of which joins and leaves at most once. A written message reaches    *)
(* its member when the member reads it; a member that left never reads what  *)
(* is pending. Writes are counted when they are made. Crashes, retries and   *)
(* cancels between steps are not modelled, and a failed write is not         *)
(* withdrawn from the count.                                                 *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS
    Members,    \* the clients that can be in the session
    Main,       \* the client that opened the session, present from the start
    Lists,      \* the members that list session.compaction (may be empty)
    Design,     \* "a": one audience step; "b": two steps
    Class,      \* "ideal": no churn while an end is pending; "nonideal": any time
    Mutation    \* "none" is the design; "today" and the planted mutations below

ASSUME Main \in Members /\ Lists \subseteq Members
ASSUME Design \in {"a", "b"}
ASSUME Class \in {"ideal", "nonideal"}
ASSUME Mutation \in {"none", "today", "gate_per_session", "replay_to_plain",
                     "done_to_listing", "two_done", "end_before_progress",
                     "drop_progress", "drop_end", "drop_done", "stall_end",
                     "failover_resend", "no_replay_after_end"}

Ends == {"completed", "failed", "cancelled"}
Updates == {"in_progress"} \cup Ends
Msgs == Updates \cup {"done"}
Entries == [w : Updates \cup {""}, wo : {"done", ""}]

VARIABLES
    status,     \* [Members -> {"out", "in", "gone"}]: not joined, present, left
    late,       \* the members that joined after in_progress was sent
    stage,      \* "none", "chosen" (running), or "ended"
    started,    \* in_progress was sent
    outcome,    \* "none" until the compaction ends, then its end
    finished,   \* the turn's deliveries for this compaction are all written
    pending,    \* [Members -> Seq(Msgs)]: written to the member, not yet read
    got,        \* [Members -> Seq(Msgs)]: read by the member, in order
    atEnd,      \* the members present when the compaction ended
    order,      \* the members in the order they joined, Main first
    mainNow,    \* the current main client
    copy        \* the turn's deliveries, each with its payload for a lister and a non-lister

vars == <<status, late, stage, started, outcome, finished, pending, got,
          atEnd, order, mainNow, copy>>

Present == {m \in Members : status[m] = "in"}
Ended == stage = "ended"
Stream(m) == got[m] \o pending[m]
Count(s, x) == Cardinality({i \in 1..Len(s) : s[i] = x})
EndCount(s) == Cardinality({i \in 1..Len(s) : s[i] \in Ends})
Has(s, x) == \E i \in 1..Len(s) : s[i] = x
Head1(m) == IF pending[m] = <<>> THEN "" ELSE Head(pending[m])

\* Whether the gate sends m a compaction_update live.
Reaches(m) ==
    IF Mutation \in {"today", "gate_per_session"} THEN Main \in Lists
    ELSE m \in Lists

\* Whether a member gets the done line live when a compaction completes.
DoneTo(m) ==
    CASE Mutation \in {"today", "drop_done"} -> FALSE
      [] Mutation = "done_to_listing" -> TRUE
      [] OTHER -> m \notin Lists

\* Whether the end of outcome o goes to m live, a member present at the end.
DueEnd(m, o) ==
    /\ m \in Present
    /\ Reaches(m)
    /\ (started \/ o = "failed")
    /\ ~(Mutation = "drop_end" /\ m \in Lists)

\* The member's pending messages after the end is written. The planted
\* end_before_progress writes the end ahead of a late joiner's replayed
\* in_progress that is not read yet.
AfterEnd(m, o) ==
    IF ~DueEnd(m, o) THEN pending[m]
    ELSE IF Mutation = "end_before_progress" /\ m \in late /\ Head1(m) = "in_progress"
         THEN <<o>> \o pending[m]
         ELSE Append(pending[m], o)

DoneApp(s) ==
    IF Mutation = "two_done" THEN Append(Append(s, "done"), "done")
    ELSE Append(s, "done")

\* Design "a" writes the end and the done line in one step, for the audience
\* of that step. Design "b" writes only the end here.
SettleQueue(m, o) ==
    LET e == AfterEnd(m, o) IN
    IF Design = "a" /\ o = "completed" /\ m \in Present /\ DoneTo(m)
    THEN DoneApp(e)
    ELSE e

\* Design "b"'s second step: the members present now, not the audience of the end.
DoneStepQueue(m) ==
    IF m \in Present /\ DoneTo(m) THEN DoneApp(pending[m]) ELSE pending[m]

\* The payloads of one copy entry for a member, by its own listing.
RefPay(e, m) == IF m \in Lists THEN e.w ELSE e.wo

\* What a joiner is replayed. The planted today and replay_to_plain give every
\* joiner the lister payload.
JoinPay(e, m) ==
    IF Mutation \in {"today", "replay_to_plain"} THEN e.w
    ELSE RefPay(e, m)

Pick(e, m, ref) == IF ref THEN RefPay(e, m) ELSE JoinPay(e, m)

RECURSIVE Filt(_, _, _)
\* The copy, filtered by m's listing: the payload of each entry that is not empty.
Filt(s, m, ref) ==
    IF s = <<>> THEN <<>>
    ELSE LET p == Pick(Head(s), m, ref) IN
         IF p = "" THEN Filt(Tail(s), m, ref)
         ELSE <<p>> \o Filt(Tail(s), m, ref)

Replay(m) == Filt(copy, m, FALSE)
Ref(m) == Filt(copy, m, TRUE)

\* Joins, leaves and failovers: any time with Class "nonideal"; with Class
\* "ideal" only when no compaction runs and no end is half delivered.
MayChurn ==
    \/ Class = "nonideal"
    \/ stage = "none"
    \/ (stage = "ended" /\ finished)

\* The oldest remaining member after the current main.
Pos(m) == CHOOSE i \in 1..Len(order) : order[i] = m
Successors == Present \ {mainNow}
NewMain == CHOOSE n \in Successors : \A k \in Successors : Pos(n) <= Pos(k)

EndW(o) == IF started \/ o = "failed" THEN o ELSE ""
EndWo(o) == IF Design = "a" /\ o = "completed" THEN "done" ELSE ""

Init ==
    /\ status = [m \in Members |-> IF m = Main THEN "in" ELSE "out"]
    /\ late = {}
    /\ stage = "none"
    /\ started = FALSE
    /\ outcome = "none"
    /\ finished = FALSE
    /\ pending = [m \in Members |-> <<>>]
    /\ got = [m \in Members |-> <<>>]
    /\ atEnd = {}
    /\ order = <<Main>>
    /\ mainNow = Main
    /\ copy = <<>>

\* fx-compactor picks what to compact.
Choose ==
    /\ stage = "none"
    /\ stage' = "chosen"
    /\ UNCHANGED <<status, late, started, outcome, finished, pending, got,
                   atEnd, order, mainNow, copy>>

\* The summary or the saving starts: in_progress goes to each present member
\* that the gate reaches, and to the copy.
Start ==
    /\ stage = "chosen" /\ ~started
    /\ started' = TRUE
    /\ pending' = [m \in Members |->
            IF m \in Present /\ Reaches(m) /\ Mutation # "drop_progress"
            THEN Append(pending[m], "in_progress")
            ELSE pending[m]]
    /\ copy' = Append(copy, [w |-> "in_progress", wo |-> ""])
    /\ UNCHANGED <<status, late, stage, outcome, finished, got, atEnd, order, mainNow>>

\* A joiner gets the copy, filtered by its own listing, at any stage of the turn.
Join(m) ==
    /\ status[m] = "out" /\ MayChurn
    /\ status' = [status EXCEPT ![m] = "in"]
    /\ pending' = [pending EXCEPT ![m] =
            IF Mutation = "no_replay_after_end" /\ Ended THEN <<>> ELSE Replay(m)]
    /\ late' = IF started THEN late \cup {m} ELSE late
    /\ order' = Append(order, m)
    /\ UNCHANGED <<stage, started, outcome, finished, got, atEnd, mainNow, copy>>

Leave(m) ==
    /\ status[m] = "in" /\ MayChurn
    /\ status' = [status EXCEPT ![m] = "gone"]
    /\ UNCHANGED <<late, stage, started, outcome, finished, pending, got, atEnd,
                   order, mainNow, copy>>

\* The current main's write fails on its next message. The main is gone, the
\* message is not sent again, and the oldest remaining member becomes the main.
\* Designs "a" and "b" send nothing more: the new main already has its own params.
Failover ==
    /\ MayChurn
    /\ status[mainNow] = "in" /\ pending[mainNow] # <<>>
    /\ Successors # {}
    /\ status' = [status EXCEPT ![mainNow] = "gone"]
    /\ mainNow' = NewMain
    /\ pending' = [pending EXCEPT ![NewMain] =
            IF Mutation = "failover_resend"
            THEN Append(pending[NewMain], Head(pending[mainNow]))
            ELSE pending[NewMain]]
    /\ UNCHANGED <<late, stage, started, outcome, finished, got, atEnd, order, copy>>

\* The member reads its next message. The planted stall_end never lets a listing
\* member read its end.
Deliver(m) ==
    /\ status[m] = "in" /\ pending[m] # <<>>
    /\ ~(Mutation = "stall_end" /\ m \in Lists /\ Head1(m) \in Ends)
    /\ got' = [got EXCEPT ![m] = Append(got[m], Head(pending[m]))]
    /\ pending' = [pending EXCEPT ![m] = Tail(pending[m])]
    /\ UNCHANGED <<status, late, stage, started, outcome, finished, atEnd, order,
                   mainNow, copy>>

\* The compaction ends. A completed compaction must have started. An end before
\* in_progress is sent only when it failed. The copy keeps one entry for the end;
\* design "a" puts the done line in the same entry.
Settle(o) ==
    /\ stage = "chosen"
    /\ o \in Ends
    /\ (o = "completed") => started
    /\ stage' = "ended"
    /\ outcome' = o
    /\ atEnd' = Present
    /\ finished' = ((Design = "a") \/ (o # "completed"))
    /\ pending' = [m \in Members |-> SettleQueue(m, o)]
    /\ copy' = Append(copy, [w |-> EndW(o), wo |-> EndWo(o)])
    /\ UNCHANGED <<status, late, started, got, order, mainNow>>

\* Design "b": the done line, to the members present at this step, and its copy entry.
DoneStep ==
    /\ Design = "b" /\ stage = "ended" /\ ~finished /\ outcome = "completed"
    /\ finished' = TRUE
    /\ pending' = [m \in Members |-> DoneStepQueue(m)]
    /\ copy' = Append(copy, [w |-> "", wo |-> "done"])
    /\ UNCHANGED <<status, late, stage, started, outcome, got, atEnd, order, mainNow>>

Next ==
    \/ Choose
    \/ Start
    \/ \E m \in Members : Join(m) \/ Leave(m) \/ Deliver(m)
    \/ Failover
    \/ \E o \in Ends : Settle(o)
    \/ DoneStep

Fairness ==
    /\ WF_vars(Choose)
    /\ WF_vars(Start)
    /\ WF_vars(\E o \in Ends : Settle(o))
    /\ WF_vars(DoneStep)
    /\ \A m \in Members : WF_vars(Deliver(m))

SafetySpec == Init /\ [][Next]_vars
Spec == SafetySpec /\ Fairness

TypeOK ==
    /\ status \in [Members -> {"out", "in", "gone"}]
    /\ late \subseteq Members
    /\ stage \in {"none", "chosen", "ended"}
    /\ started \in BOOLEAN
    /\ outcome \in {"none"} \cup Ends
    /\ finished \in BOOLEAN
    /\ pending \in [Members -> Seq(Msgs)]
    /\ got \in [Members -> Seq(Msgs)]
    /\ atEnd \subseteq Members
    /\ order \in Seq(Members)
    /\ mainNow \in Members
    /\ copy \in Seq(Entries)

OnlyListingGetsUpdates ==
    \A m \in Members \ Lists :
        \A i \in 1..Len(Stream(m)) : Stream(m)[i] \notin Updates

ProgressThenEnd ==
    \A m \in Lists :
        Stream(m) \in ({<<>>, <<"failed">>, <<"in_progress">>}
                       \cup {<<"in_progress", e>> : e \in Ends})

ListingGetsProgress ==
    \A m \in Lists :
        (started /\ status[m] = "in" /\ (stage = "chosen" \/ m \in atEnd))
            => Has(Stream(m), "in_progress")

ListingGetsEnd ==
    \A m \in Lists :
        (Ended /\ m \in atEnd /\ (started \/ outcome = "failed"))
            => Has(Stream(m), outcome)

ListingGetsNoDone ==
    \A m \in Lists : Count(Stream(m), "done") = 0

PlainGetsExactlyOneDone ==
    \A m \in Members \ Lists :
        /\ Count(Stream(m), "done") <= 1
        /\ ((finished /\ outcome = "completed" /\ m \in atEnd)
                => Count(Stream(m), "done") = 1)

JoinerSeesSameAsPresent ==
    finished =>
        \A m \in Members :
            (status[m] = "in") => (Stream(m) = Ref(m))

ExactlyOneEndOrDone ==
    \A m \in Members :
        (finished /\ m \in atEnd /\ status[m] = "in") =>
            /\ Count(Stream(m), "done") = IF m \notin Lists /\ outcome = "completed" THEN 1 ELSE 0
            /\ EndCount(Stream(m)) = IF m \in Lists /\ (started \/ outcome = "failed") THEN 1 ELSE 0

ListingEndDelivered ==
    \A m \in Lists :
        LET Due == Ended /\ m \in atEnd /\ status[m] = "in"
                   /\ (started \/ outcome = "failed")
        IN [](Due => <>(Has(got[m], outcome) \/ ~Due))
=============================================================================
