----------------------------- MODULE SavedTurn -----------------------------
(***************************************************************************)
(* The order of one turn's messages at each step boundary, as the turn     *)
(* sends them live and as the next turn restores them from the saved turn. *)
(*                                                                         *)
(* A provider's prompt cache covers a request only up to the first message *)
(* that differs from the request before it. The next turn's request holds  *)
(* the previous turn as the session saved it, so it starts with the last   *)
(* request of that turn only if restoring the saved turn gives back the    *)
(* messages in the order the turn sent them.                               *)
(*                                                                         *)
(* fx side: the step loop in src/core/agent/runtime/orchestrator.zig       *)
(* appends to the turn's messages, `within_turn_suffix`;                   *)
(* src/core/agent/runtime/execution_memory.zig `buildExecutionMemory`      *)
(* saves them (Save below); src/core/session/session.zig                   *)
(* `appendExecutionMemoryChatMessages` restores them (Restore below).      *)
(*                                                                         *)
(* A message is one atom:                                                  *)
(*   "C"  an assistant message with tool calls, which starts a step       *)
(*   "R"  a tool result of the step                                       *)
(*   "F"  permission feedback the user typed for a call of the step       *)
(*   "A"  a reply with no tool call that stays in the turn, a step too    *)
(*   "P"  a plain assistant message just before steering, its prefix      *)
(*   "N"  a context note: a gate's rules, or a runtime context update     *)
(*   "T"  steering the user typed                                         *)
(*   "K"  fx's own prompt: a continuation, the empty-reply nudge, the     *)
(*        prefill recovery prompt                                          *)
(*   "H"  a Stop hook's message to continue                               *)
(*   "V"  review mode's message                                           *)
(*   "Q"  a tool's notice to the model, such as Vision's                   *)
(*   "X"  a user message fx sent with no marker, which the save drops      *)
(* The steering kinds are T, K, H, V and Q: the save keeps each in the     *)
(* turn's steering list, anchored at the number of steps before it. fx     *)
(* marks every one but T, which is the user's own, as its own message      *)
(* (`recovery_prompt`). X is a message fx does not send: only a planted    *)
(* defect sends it.                                                        *)
(*                                                                         *)
(* Save keeps steps with their results and feedback, notes anchored the    *)
(* same way, and steering with its assistant prefix. Restore puts back, at *)
(* every boundary, the notes first and then the steering, then the step.   *)
(* So the turn must send a boundary's notes before its steering: the rule  *)
(* these checks hold (D93).                                                *)
(*                                                                         *)
(* Constants:                                                              *)
(*   Notices      how a tool's notice joins the turn: "none"; "end", once  *)
(*                the step's results and feedback are in, which is how fx  *)
(*                sends it; "inline", right after its own result, which    *)
(*                ends the step there; "plain", with no marker             *)
(*   Review       review mode's message after a step that wrote            *)
(*   Hook         a Stop hook may continue the turn (no production code    *)
(*                registers a Stop hook today)                             *)
(*   DoubleTrail  a second steering message may follow one the last        *)
(*                request already carried, with no reply between them      *)
(*   Bug          "none" is the design: a boundary's notes join before the *)
(*                steering the last step ended with. Each other value      *)
(*                plants one defect; check.sh names the rule that must     *)
(*                catch it:                                                *)
(*     append_notes     notes join after that steering, as fx did before   *)
(*     review_plain     review mode's message has no marker                *)
(*     hook_plain       a Stop hook's message has no marker                *)
(*     steering_first   Restore puts a boundary's steering before its notes *)
(*     prefix_dropped   Save forgets the assistant message before steering *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS MaxAtoms, MaxRequests, Notices, Review, Hook, DoubleTrail, Bug

Steer == {"T", "K", "H", "V", "Q"}
Atoms == {"C", "R", "F", "A", "P", "N", "X"} \cup Steer
StepStart == {"C", "A"}

Range(s) == {s[i] : i \in 1..Len(s)}
IsPrefix(a, b) == Len(a) <= Len(b) /\ SubSeq(b, 1, Len(a)) = a
Repeat(x, n) == [i \in 1..n |-> x]

(***************************************************************************)
(* Where a boundary's notes join: before the run of steering the last step *)
(* ended with, which is the start of the longest tail of steering          *)
(* messages, each with the plain assistant message before it, if any       *)
(* (`execution_memory.zig` `boundaryNotesStart`).                          *)
(***************************************************************************)
RECURSIVE RunStart(_, _)
RunStart(s, i) ==
    IF i = 0 THEN 1
    ELSE IF s[i] \in Steer
        THEN IF i > 1 /\ s[i - 1] = "P" THEN RunStart(s, i - 2) ELSE RunStart(s, i - 1)
        ELSE i + 1

Place(live, notes) ==
    IF Bug = "append_notes"
        THEN live \o notes
        ELSE LET at == RunStart(live, Len(live))
             IN SubSeq(live, 1, at - 1) \o notes \o SubSeq(live, at, Len(live))

(***************************************************************************)
(* Save and Restore                                                        *)
(***************************************************************************)
RECURSIVE SaveFrom(_, _, _)
SaveFrom(s, i, acc) ==
    IF i > Len(s) THEN acc
    ELSE LET e == s[i]
             n == Len(acc.steps)
         IN SaveFrom(s, i + 1,
              CASE e = "C" -> [acc EXCEPT !.steps = Append(@, [k |-> "tool", nr |-> 0, nf |-> 0]), !.pre = FALSE]
                [] e = "A" -> [acc EXCEPT !.steps = Append(@, [k |-> "reply", nr |-> 0, nf |-> 0]), !.pre = FALSE]
                [] e = "R" -> [acc EXCEPT !.steps[n].nr = @ + 1]
                [] e = "F" -> [acc EXCEPT !.steps[n].nf = @ + 1]
                [] e = "P" -> [acc EXCEPT !.pre = TRUE]
                [] e = "N" -> [acc EXCEPT !.notes = Append(@, [a |-> n])]
                [] e \in Steer -> [acc EXCEPT !.steer = Append(@, [k |-> e, a |-> n, pre |-> (acc.pre /\ Bug # "prefix_dropped")]),
                                              !.pre = FALSE]
                [] e = "X" -> [acc EXCEPT !.pre = FALSE])

Save(live) == SaveFrom(live, 1, [steps |-> <<>>, notes |-> <<>>, steer |-> <<>>, pre |-> FALSE])

NoteAtoms(sv, b) == Repeat("N", Len(SelectSeq(sv.notes, LAMBDA x : x.a = b)))

RECURSIVE SteerAtoms(_)
SteerAtoms(q) ==
    IF q = <<>> THEN <<>>
    ELSE (IF Head(q).pre THEN <<"P", Head(q).k>> ELSE <<Head(q).k>>) \o SteerAtoms(Tail(q))

Boundary(sv, b) ==
    LET steer == SteerAtoms(SelectSeq(sv.steer, LAMBDA x : x.a = b))
    IN IF Bug = "steering_first" THEN steer \o NoteAtoms(sv, b) ELSE NoteAtoms(sv, b) \o steer

StepAtoms(st) == IF st.k = "tool" THEN <<"C">> \o Repeat("R", st.nr) \o Repeat("F", st.nf) ELSE <<"A">>

RECURSIVE RestoreFrom(_, _)
RestoreFrom(sv, b) ==
    IF b >= Len(sv.steps) THEN Boundary(sv, b)
    ELSE Boundary(sv, b) \o StepAtoms(sv.steps[b + 1]) \o RestoreFrom(sv, b + 1)

Restore(live) == RestoreFrom(Save(live), 0)

(***************************************************************************)
(* The step loop                                                           *)
(***************************************************************************)
VARIABLES
    live,      \* the turn's messages after the user's own, in the order sent
    sent,      \* the messages the last request carried
    pend,      \* context notes the last step's gate queued
    ctx,       \* the runtime context changed and no note has carried it yet
    wrote,     \* the step that just ended wrote a file
    phase,     \* "top", "reply", "end" (a step's results are in), or "done"
    requests,  \* requests sent
    how        \* how the turn ended

vars == <<live, sent, pend, ctx, wrote, phase, requests, how>>

Init ==
    /\ live = <<>> /\ sent = <<>> /\ pend = 0 /\ ctx = FALSE
    /\ wrote = FALSE /\ phase = "top" /\ requests = 0 /\ how = "none"

\* Another process changes the git branch or the date.
ContextChange ==
    /\ ~ctx /\ phase \in {"top", "reply", "end"}
    /\ ctx' = TRUE
    /\ UNCHANGED <<live, sent, pend, wrote, phase, requests, how>>

\* The top of a step: the gate's notes and the runtime context update, which
\* join before the steering the last step ended with, then steering the user
\* typed, and the request.
Top ==
    /\ phase = "top" /\ requests < MaxRequests
    /\ \E typed \in BOOLEAN :
         LET notes == Repeat("N", pend) \o (IF ctx THEN <<"N">> ELSE <<>>)
             next == Place(live, notes) \o (IF typed THEN <<"T">> ELSE <<>>)
         IN /\ live' = next /\ sent' = next
    /\ pend' = 0 /\ ctx' = FALSE /\ wrote' = FALSE
    /\ requests' = requests + 1 /\ phase' = "reply" /\ UNCHANGED how

\* A fresh reply may not add steering to a tail the last request already
\* carried, unless DoubleTrail allows it.
MaySteer == DoubleTrail \/ ~(sent = live /\ Len(live) > 0 /\ live[Len(live)] \in Steer)

\* A notice that joins right after its own result.
NoticeAtoms ==
    CASE Notices = "inline" -> <<"Q">>
      [] Notices = "plain" -> <<"X">>
      [] OTHER -> <<>>

\* A notice that joins once the step's results and feedback are in.
EndNotice == IF Notices = "end" THEN <<"Q">> ELSE <<>>

ToolStep ==
    /\ phase = "reply"
    /\ \E nr \in 1..2, fb \in BOOLEAN, notice \in BOOLEAN, gate \in 0..1, writes \in BOOLEAN :
         /\ live' = live \o <<"C", "R">> \o (IF notice THEN NoticeAtoms ELSE <<>>)
                         \o (IF nr = 2 THEN <<"R">> ELSE <<>>) \o (IF fb THEN <<"F">> ELSE <<>>)
                         \o (IF notice THEN EndNotice ELSE <<>>)
         /\ pend' = pend + gate
         /\ wrote' = writes
    /\ phase' = "end"
    /\ UNCHANGED <<sent, ctx, requests, how>>

\* The empty-reply nudge, a continuation, or the prefill recovery prompt: with
\* a reply that stays in the turn, or after a failed request with none.
EmptyReply ==
    /\ phase = "reply" /\ MaySteer
    /\ \E replay \in BOOLEAN : live' = live \o (IF replay THEN <<"A", "K">> ELSE <<"K">>)
    /\ phase' = "top"
    /\ UNCHANGED <<sent, pend, ctx, wrote, requests, how>>

HookReply ==
    /\ phase = "reply" /\ Hook /\ MaySteer
    /\ live' = live \o <<"A", IF Bug = "hook_plain" THEN "X" ELSE "H">>
    /\ phase' = "top"
    /\ UNCHANGED <<sent, pend, ctx, wrote, requests, how>>

\* Steering the user typed arrives while the reply finishes.
SteerReply ==
    /\ phase = "reply" /\ MaySteer
    /\ \E replay \in BOOLEAN : live' = live \o (IF replay THEN <<"A", "T">> ELSE <<"P", "T">>)
    /\ phase' = "top"
    /\ UNCHANGED <<sent, pend, ctx, wrote, requests, how>>

Finish(h) ==
    /\ phase' = "done" /\ how' = h
    /\ UNCHANGED <<sent, pend, ctx, wrote, requests>>

FinalReply == phase = "reply" /\ Finish("final") /\ UNCHANGED live
Cancel == phase = "reply" /\ Finish("cancel") /\ UNCHANGED live

\* After a step with writes, review mode asks for a look at the changes.
ReviewStep ==
    /\ phase = "end" /\ Review /\ wrote
    /\ live' = live \o <<IF Bug = "review_plain" THEN "X" ELSE "V">>
    /\ wrote' = FALSE
    /\ UNCHANGED <<sent, pend, ctx, phase, requests, how>>

GoOn ==
    /\ phase = "end" /\ phase' = "top"
    /\ UNCHANGED <<live, sent, pend, ctx, wrote, requests, how>>

\* A repeated-failure exit: steering typed meanwhile follows the step's
\* messages, and the turn continues.
FinalizingSteer ==
    /\ phase = "end" /\ phase' = "top"
    /\ live' = live \o <<"T">>
    /\ UNCHANGED <<sent, pend, ctx, wrote, requests, how>>

\* The step limit ends the turn after a step.
StepLimit ==
    /\ phase = "end" /\ phase' = "done" /\ how' = "limit"
    /\ UNCHANGED <<live, sent, pend, ctx, wrote, requests>>

\* The turn is over, or the model's bound on requests stops the search.
Ended == (phase = "done" \/ (phase = "top" /\ requests >= MaxRequests)) /\ UNCHANGED vars

Next ==
    \/ ContextChange \/ Top \/ ToolStep \/ EmptyReply \/ HookReply \/ SteerReply
    \/ FinalReply \/ Cancel \/ ReviewStep \/ GoOn \/ FinalizingSteer \/ StepLimit \/ Ended

Spec == Init /\ [][Next]_vars

Bounded == Len(live) <= MaxAtoms /\ requests <= MaxRequests

(***************************************************************************)
(* The rules                                                               *)
(***************************************************************************)
TypeOK ==
    /\ live \in Seq(Atoms) /\ sent \in Seq(Atoms)
    /\ pend \in Nat /\ ctx \in BOOLEAN /\ wrote \in BOOLEAN
    /\ phase \in {"top", "reply", "end", "done"} /\ requests \in Nat

\* A boundary's notes come before its steering: no note follows steering
\* with no step between them.
NotesFirst ==
    \A i, j \in 1..Len(live) :
        (i < j /\ live[i] \in Steer /\ live[j] = "N") => \E k \in i..j : live[k] \in StepStart

\* Steering never sits between the results or the feedback of one step.
ResultsTogether ==
    \A i, j \in 1..Len(live) :
        (i < j /\ live[i] \in Steer /\ live[j] \in {"R", "F"}) => \E k \in i..j : live[k] \in StepStart

\* The save keeps every message the turn sent.
NothingDropped == Len(Restore(live)) = Len(live)

\* The saved turn restores the messages in the order the turn sent them.
RoundTrip == Restore(live) = live

\* The next turn's request starts with the turn's last request.
NextExtendsLast == phase = "done" => IsPrefix(sent, Restore(live))

\* Each request of a turn starts with the one before it, so the provider's
\* cache covers it while the turn runs.
RequestsExtend == [][(phase = "top" /\ phase' = "reply") => IsPrefix(sent, sent')]_vars
=============================================================================
