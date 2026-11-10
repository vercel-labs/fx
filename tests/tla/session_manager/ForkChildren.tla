---------------------------- MODULE ForkChildren ----------------------------
(***************************************************************************)
(* Step: a fork that brings the source's subagents (D97).                 *)
(*                                                                         *)
(* The source parent's log ends turns (fork points), spawns children and  *)
(* closes them for good. Each child keeps its own log, whose lines carry  *)
(* the time they were written, and keeps writing while the fork runs: one *)
(* child turn can span many fork points. When the person says yes, the    *)
(* fork copies each child the source had at the fork point and had not    *)
(* closed by then: every child line written up to the fork point's time, *)
(* and, when that leaves a turn open, one interrupt that ends it. Only    *)
(* after every copy is on disk does the fork register them, in one batch. *)
(* The process can crash at any step, which leaves what is on disk. When  *)
(* the source is itself a fork, a child here is one of its copies, spawned *)
(* when the child it copies was.                                          *)
(*                                                                         *)
(* Design: system-design.md D22, D58 and D97.                              *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS Children, MaxTime, MaxLen

Never == MaxTime + 1
Times == 0..MaxTime

VARIABLES
    now,        \* the clock lines are stamped with
    clog,       \* [Children -> Seq(line)]: each source child's log
    spawned,    \* [Children -> Times \cup {Never}]: when the parent spawned it
    closedAt,   \* [Children -> Times \cup {Never}]: when the parent closed it for good
    points,     \* the fork points: times at which a parent turn ended
    phase,      \* the fork: "none", "copying", "registered"
    point,      \* the fork point's time, once the fork starts
    plan,       \* the children the fork copies
    copied,     \* [Children -> BOOLEAN]: the copy's session is on disk
    copy,       \* [Children -> Seq(line)]: the copy's log
    reg,        \* the children the fork's log registers
    up          \* FALSE once the process crashed

vars == <<now, clog, spawned, closedAt, points, phase, point, plan, copied, copy, reg, up>>

L(k, t) == [k |-> k, t |-> t]

Count(s, k) == Cardinality({i \in 1..Len(s) : s[i].k = k})
IsOpen(s) == Count(s, "start") > Count(s, "commit") + Count(s, "interrupt")

\* Every line written up to time p. Lines are written in time order, so this
\* is a prefix of the log.
Upto(s, p) == SelectSeq(s, LAMBDA x : x.t <= p)

\* What a copy holds: the lines up to p, and an interrupt when they leave a
\* turn open.
Cut(s, p) == LET c == Upto(s, p) IN IF IsOpen(c) THEN Append(c, L("interrupt", p)) ELSE c

\* The children the source had at fork point p and had not closed by then.
Eligible(p) == {c \in Children : spawned[c] <= p /\ closedAt[c] > p}

TypeOK ==
    /\ now \in Times
    /\ spawned \in [Children -> Times \cup {Never}]
    /\ closedAt \in [Children -> Times \cup {Never}]
    /\ points \subseteq Times
    /\ phase \in {"none", "copying", "registered"}
    /\ point \in Times \cup {Never}
    /\ plan \subseteq Children
    /\ copied \in [Children -> BOOLEAN]
    /\ reg \subseteq Children
    /\ up \in BOOLEAN

Init ==
    /\ now = 0
    /\ clog = [c \in Children |-> <<>>]
    /\ spawned = [c \in Children |-> Never]
    /\ closedAt = [c \in Children |-> Never]
    /\ points = {}
    /\ phase = "none"
    /\ point = Never
    /\ plan = {}
    /\ copied = [c \in Children |-> FALSE]
    /\ copy = [c \in Children |-> <<>>]
    /\ reg = {}
    /\ up = TRUE

Tick ==
    /\ up /\ now < MaxTime
    /\ now' = now + 1
    /\ UNCHANGED <<clog, spawned, closedAt, points, phase, point, plan, copied, copy, reg, up>>

\* The parent's own steps run on the main loop, which the fork holds until
\* it ends; after a fork the source is closed (D58). Only its children's
\* threads write while the fork runs.
ParentFree == up /\ phase = "none"

\* The source parent ends a turn: a fork point at this time.
TurnEnd ==
    /\ ParentFree /\ now \notin points
    /\ points' = points \cup {now}
    /\ UNCHANGED <<now, clog, spawned, closedAt, phase, point, plan, copied, copy, reg, up>>

Spawn(c) ==
    /\ ParentFree /\ spawned[c] = Never
    /\ spawned' = [spawned EXCEPT ![c] = now]
    /\ UNCHANGED <<now, clog, closedAt, points, phase, point, plan, copied, copy, reg, up>>

\* The person closes an idle child for good from the agent list.
CloseChild(c) ==
    /\ ParentFree /\ spawned[c] # Never /\ closedAt[c] = Never
    /\ ~IsOpen(clog[c])
    /\ closedAt' = [closedAt EXCEPT ![c] = now]
    /\ UNCHANGED <<now, clog, spawned, points, phase, point, plan, copied, copy, reg, up>>

\* A child writes a line of its own log, also while the fork runs.
ChildWrite(c, k) ==
    /\ up /\ spawned[c] # Never /\ closedAt[c] = Never
    /\ Len(clog[c]) < MaxLen
    /\ \/ k = "start" /\ ~IsOpen(clog[c])
       \/ k \in {"item", "commit"} /\ IsOpen(clog[c])
    /\ clog' = [clog EXCEPT ![c] = Append(@, L(k, now))]
    /\ UNCHANGED <<now, spawned, closedAt, points, phase, point, plan, copied, copy, reg, up>>

\* /fork at fork point p; `yes` is the person's answer to the one question.
ForkStart(p, yes) ==
    /\ up /\ phase = "none"
    /\ p \in points
    /\ phase' = "copying"
    /\ point' = p
    /\ plan' = IF yes THEN Eligible(p) ELSE {}
    /\ UNCHANGED <<now, clog, spawned, closedAt, points, copied, copy, reg, up>>

\* One child's copy lands on disk: a new child session of the fork.
CopyChild(c) ==
    /\ up /\ phase = "copying"
    /\ c \in plan /\ ~copied[c]
    /\ copy' = [copy EXCEPT ![c] = Cut(clog[c], point)]
    /\ copied' = [copied EXCEPT ![c] = TRUE]
    /\ UNCHANGED <<now, clog, spawned, closedAt, points, phase, point, plan, reg, up>>

\* The fork's log registers every copy in one batch, once all are on disk.
Register ==
    /\ up /\ phase = "copying"
    /\ \A c \in plan : copied[c]
    /\ reg' = plan
    /\ phase' = "registered"
    /\ UNCHANGED <<now, clog, spawned, closedAt, points, point, plan, copied, copy, up>>

Crash ==
    /\ up
    /\ up' = FALSE
    /\ UNCHANGED <<now, clog, spawned, closedAt, points, phase, point, plan, copied, copy, reg>>

Next ==
    \/ Tick \/ TurnEnd \/ Register \/ Crash
    \/ \E c \in Children :
          \/ Spawn(c) \/ CloseChild(c) \/ CopyChild(c)
          \/ \E k \in {"start", "item", "commit"} : ChildWrite(c, k)
    \/ \E p \in Times, yes \in BOOLEAN : ForkStart(p, yes)

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
(* Invariants *)

\* Every child the fork registers has its copy on disk, also after a crash.
RegisteredExist == \A c \in reg : copied[c]

\* Closes a cut that leaves a turn open.
Closed(c, p) == IF IsOpen(c) THEN Append(c, L("interrupt", p)) ELSE c

\* A copy is the source child's log up to the fork point: a prefix with no
\* line after the point and every line before it, and an interrupt only to
\* end a turn the prefix left open. A line stamped with the point's own time
\* but written after the copy came after the point, so it may be left out.
CopyAtPoint ==
    \A c \in Children : copied[c] =>
        \E n \in 0..Len(clog[c]) :
            LET u == SubSeq(clog[c], 1, n) IN
                /\ copy[c] = Closed(u, point)
                /\ \A i \in 1..n : clog[c][i].t <= point
                /\ \A i \in 1..Len(clog[c]) : clog[c][i].t < point => i <= n

\* A copy never leaves a turn open.
CopyClosed == \A c \in Children : copied[c] => ~IsOpen(copy[c])

\* Only children the source had at the fork point and had not closed are
\* copied or registered.
OnlyEligible == phase # "none" => (plan \subseteq Eligible(point) /\ reg \subseteq plan)

\* A yes copies every eligible child; a no copies none.
AllOrNone == phase = "registered" => reg \in {{}, Eligible(point)}

\* The fork's steps never write the source's children.
ForkLeavesSources ==
    [][\A c \in Children : (CopyChild(c) \/ Register) => (clog' = clog /\ spawned' = spawned /\ closedAt' = closedAt)]_vars
=============================================================================
