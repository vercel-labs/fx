--------------------------- MODULE AcpSubagents ---------------------------
(***************************************************************************)
(* Subagents in the sh.fx extension to ACP: the "Subagents" section of     *)
(* src/protocol/spec/sh-fx.md, which follows ACP's Subagent Sessions and   *)
(* hasn't landed in src/acp/ yet.                                          *)
(*                                                                         *)
(* One client, one parent session, and its children. fx writes the         *)
(* client's messages in order, and the client reads them later (Read): a   *)
(* child's announcement (subagent_update), an update of a child's work, a  *)
(* child's permission request or its cancellation, and the response that   *)
(* ends a reload. Several clients on one session are in AcpSharedSession.  *)
(*                                                                         *)
(* Rules (Rules = TRUE):                                                   *)
(*  - fx announces a child before any update of its work, and every        *)
(*    update and request of the child carries the child's id.              *)
(*  - session/cancel of a child stops only the child; the parent's turn    *)
(*    goes on and gets the child's result. Stopping the parent stops its   *)
(*    children. A stopped child's request is cancelled.                    *)
(*  - A client message to a child steers it while it works, starts its     *)
(*    work while it's idle, and runs as its next turn when its work ends   *)
(*    or stops first. A child's report reaches the parent: it joins the    *)
(*    parent's turn, or runs as the parent's next turn.                    *)
(*  - A reload replays every child's announcement and history before the   *)
(*    response, and sends a request that still waits, never a decided one. *)
(*                                                                         *)
(* Today (Rules = FALSE): fx sends the client nothing of a child: no       *)
(* announcement, no work, and no permission request. A child's request     *)
(* waits for an answer that no client can give. A parent session/cancel    *)
(* stops the parent and leaves its children running. A reload replays no   *)
(* child. A client that sends a child's id gets these refusals. A prompt   *)
(* gets -32600 "Prompt already in progress" while the parent runs, and     *)
(* -32602 "Session is not active" while it's idle. A cancel request gets   *)
(* -32602 "Session is not active", and fx ignores a cancel notification.   *)
(* The model records each refusal as a flag, not as a code.                *)
(***************************************************************************)
EXTENDS Integers, Sequences, FiniteSets

CONSTANTS
    Rules,          \* TRUE: the sh.fx rules; FALSE: fx's ACP path today
    Kids,           \* the children the parent can start
    MaxChildTurns,  \* child turns in the whole run
    MaxAsks,        \* permission requests in the whole run
    MaxSteers,      \* client messages to children in the whole run
    MaxCancels,     \* client cancels of children in the whole run
    MaxLoads        \* reloads of the parent

VARIABLES
    parent,      \* "idle" or "running"
    child,       \* [Kids -> {"none", "running", "idle"}]
    childTurns,  \* child turns started
    perm,        \* [Kids -> Nat]: the child's waiting request; 0 is none
    asks,        \* requests made, which number them
    shown,       \* the requests the client shows: a set of [k, n]
    chan,        \* Seq(message): written by fx, not yet read by the client
    seen,        \* [Kids -> BOOLEAN]: the client has read the child's announcement
    steersSent,  \* client messages to children that fx accepted
    waiting,     \* [Kids -> Nat]: messages waiting for the child's work to take them
    steersTaken, \* messages a child's work took
    reportsMade, \* child reports made
    reports,     \* reports waiting for the parent
    reportsTaken,\* reports the parent took
    cancels,     \* session/cancel requests the client sent to children
    loads,       \* reloads done
    flags        \* the mistakes the properties rule out, as a set of names

vars == <<parent, child, childTurns, perm, asks, shown, chan, seen, steersSent, waiting,
          steersTaken, reportsMade, reports, reportsTaken, cancels, loads, flags>>

Msg(kind, k, n) == [kind |-> kind, k |-> k, n |-> n]
Flag(name) == flags' = flags \cup {name}

RECURSIVE SumOver(_, _)
SumOver(f, S) == IF S = {} THEN 0 ELSE LET x == CHOOSE y \in S : TRUE IN f[x] + SumOver(f, S \ {x})

RECURSIVE SeqOf(_)
SeqOf(S) == IF S = {} THEN <<>> ELSE LET x == CHOOSE y \in S : TRUE IN <<x>> \o SeqOf(S \ {x})

RECURSIVE Cat(_)
Cat(s) == IF s = <<>> THEN <<>> ELSE Head(s) \o Cat(Tail(s))

\* What fx writes to the client about a child. Today it writes nothing.
ToClient(msgs) == IF Rules THEN msgs ELSE <<>>

\* The client knows a child's id: from its announcement or, today, from the
\* hooks and the report.
KnowsChild(k) == seen[k] \/ ~Rules

Init ==
    /\ parent = "idle"
    /\ child = [k \in Kids |-> "none"]
    /\ childTurns = 0
    /\ perm = [k \in Kids |-> 0]
    /\ asks = 0
    /\ shown = {}
    /\ chan = <<>>
    /\ seen = [k \in Kids |-> FALSE]
    /\ steersSent = 0
    /\ waiting = [k \in Kids |-> 0]
    /\ steersTaken = 0
    /\ reportsMade = 0
    /\ reports = 0
    /\ reportsTaken = 0
    /\ cancels = 0
    /\ loads = 0
    /\ flags = {}

\* An update of child k's work, under the child's id.
Work(k) == Msg("work", k, 0)

\* The client prompts the parent.
ParentPrompt ==
    /\ parent = "idle"
    /\ parent' = "running"
    /\ UNCHANGED <<child, childTurns, perm, asks, shown, chan, seen, steersSent, waiting,
                   steersTaken, reportsMade, reports, reportsTaken, cancels, loads, flags>>

\* The parent's turn starts child k's first work. fx announces the child first.
Spawn(k) ==
    /\ parent = "running" /\ child[k] = "none" /\ childTurns < MaxChildTurns
    /\ child' = [child EXCEPT ![k] = "running"]
    /\ childTurns' = childTurns + 1
    /\ chan' = chan \o ToClient(<<Msg("announce", k, 0), Work(k)>>)
    /\ UNCHANGED <<parent, perm, asks, shown, seen, steersSent, waiting, steersTaken,
                   reportsMade, reports, reportsTaken, cancels, loads, flags>>

\* The parent's turn gives an idle child new work.
Reuse(k) ==
    /\ parent = "running" /\ child[k] = "idle" /\ childTurns < MaxChildTurns
    /\ child' = [child EXCEPT ![k] = "running"]
    /\ childTurns' = childTurns + 1
    /\ chan' = chan \o ToClient(<<Work(k)>>)
    /\ UNCHANGED <<parent, perm, asks, shown, seen, steersSent, waiting, steersTaken,
                   reportsMade, reports, reportsTaken, cancels, loads, flags>>

\* More of a running child's work.
ChildWork(k) ==
    /\ child[k] = "running"
    /\ chan' = chan \o ToClient(<<Work(k)>>)
    /\ UNCHANGED <<parent, child, childTurns, perm, asks, shown, seen, steersSent, waiting,
                   steersTaken, reportsMade, reports, reportsTaken, cancels, loads, flags>>

\* A running child asks for a permission. Today the request stays with fx.
ChildAsk(k) ==
    /\ child[k] = "running" /\ perm[k] = 0 /\ asks < MaxAsks
    /\ asks' = asks + 1
    /\ perm' = [perm EXCEPT ![k] = asks + 1]
    /\ chan' = chan \o ToClient(<<Msg("req", k, asks + 1)>>)
    /\ UNCHANGED <<parent, child, childTurns, shown, seen, steersSent, waiting, steersTaken,
                   reportsMade, reports, reportsTaken, cancels, loads, flags>>

\* The client answers a request it shows.
Answer(k, n) ==
    /\ [k |-> k, n |-> n] \in shown
    /\ shown' = shown \ {[k |-> k, n |-> n]}
    /\ perm' = IF perm[k] = n THEN [perm EXCEPT ![k] = 0] ELSE perm
    /\ UNCHANGED <<parent, child, childTurns, asks, chan, seen, steersSent, waiting, steersTaken,
                   reportsMade, reports, reportsTaken, cancels, loads, flags>>

\* A child's work takes a waiting client message at its next boundary.
ChildTakeSteer(k) ==
    /\ child[k] = "running" /\ waiting[k] > 0
    /\ waiting' = [waiting EXCEPT ![k] = @ - 1]
    /\ steersTaken' = steersTaken + 1
    /\ UNCHANGED <<parent, child, childTurns, perm, asks, shown, chan, seen, steersSent,
                   reportsMade, reports, reportsTaken, cancels, loads, flags>>

\* Child k's work ends or stops: its report goes to the parent, its waiting
\* request is cancelled, and waiting messages run as its next turn.
ChildStops(k, report) ==
    /\ child' = [child EXCEPT ![k] = IF waiting[k] > 0 THEN "running" ELSE "idle"]
    /\ childTurns' = IF waiting[k] > 0 THEN childTurns + 1 ELSE childTurns
    /\ steersTaken' = steersTaken + waiting[k]
    /\ waiting' = [waiting EXCEPT ![k] = 0]
    /\ perm' = [perm EXCEPT ![k] = 0]
    /\ chan' = (IF perm[k] # 0 THEN Append(chan, Msg("cancel", k, perm[k])) ELSE chan)
               \o (IF waiting[k] > 0 THEN ToClient(<<Work(k)>>) ELSE <<>>)
    /\ reportsMade' = IF report THEN reportsMade + 1 ELSE reportsMade
    /\ reports' = IF report THEN reports + 1 ELSE reports

\* A child's work ends on its own, once no request of it waits.
ChildEnd(k) ==
    /\ child[k] = "running" /\ perm[k] = 0
    /\ ChildStops(k, TRUE)
    /\ UNCHANGED <<parent, asks, shown, seen, steersSent, reportsTaken, cancels, loads, flags>>

\* session/cancel with the id of a child the client knows. Today fx refuses it.
CancelChild(k) ==
    /\ KnowsChild(k) /\ child[k] = "running" /\ cancels < MaxCancels
    /\ cancels' = cancels + 1
    /\ IF Rules
       THEN /\ ChildStops(k, TRUE)
            /\ UNCHANGED <<parent, flags>>
       ELSE /\ Flag("child_cancel_refused")
            /\ UNCHANGED <<parent, child, childTurns, perm, chan, waiting, steersTaken,
                           reportsMade, reports>>
    /\ UNCHANGED <<asks, shown, seen, steersSent, reportsTaken, loads>>

\* The sh.fx stop: session/cancel of the parent stops the parent and every
\* running child. The children's results stay on the parent's stopped tool
\* calls, and their waiting messages run as their next turns.
StopChildren ==
    LET running == {k \in Kids : child[k] = "running"}
        stopped == SeqOf({k \in running : perm[k] # 0})
        restarted == SeqOf({k \in running : waiting[k] > 0})
    IN /\ parent' = "idle"
       /\ child' = [k \in Kids |-> IF k \in running THEN (IF waiting[k] > 0 THEN "running" ELSE "idle") ELSE child[k]]
       /\ childTurns' = childTurns + Cardinality({k \in running : waiting[k] > 0})
       /\ steersTaken' = steersTaken + SumOver([k \in Kids |-> IF k \in running THEN waiting[k] ELSE 0], Kids)
       /\ waiting' = [k \in Kids |-> IF k \in running THEN 0 ELSE waiting[k]]
       /\ perm' = [k \in Kids |-> IF k \in running THEN 0 ELSE perm[k]]
       /\ chan' = chan \o [i \in 1..Len(stopped) |-> Msg("cancel", stopped[i], perm[stopped[i]])]
                       \o ToClient([i \in 1..Len(restarted) |-> Work(restarted[i])])

\* session/cancel of the parent. Today it stops the parent only: the children
\* run on.
CancelParent ==
    /\ parent = "running"
    /\ IF Rules
       THEN StopChildren
       ELSE /\ parent' = "idle"
            /\ UNCHANGED <<child, childTurns, perm, chan, waiting, steersTaken>>
    /\ UNCHANGED <<asks, shown, seen, steersSent, reportsMade, reports, reportsTaken, cancels,
                   loads, flags>>

\* The parent's turn ends on its own.
ParentEnd ==
    /\ parent = "running"
    /\ parent' = "idle"
    /\ UNCHANGED <<child, childTurns, perm, asks, shown, chan, seen, steersSent, waiting,
                   steersTaken, reportsMade, reports, reportsTaken, cancels, loads, flags>>

\* A child's report joins the parent's running turn, or starts its next turn.
ParentTakeReport ==
    /\ reports > 0
    /\ parent' = "running"
    /\ reports' = reports - 1
    /\ reportsTaken' = reportsTaken + 1
    /\ UNCHANGED <<child, childTurns, perm, asks, shown, chan, seen, steersSent, waiting,
                   steersTaken, reportsMade, cancels, loads, flags>>

\* The client sends session/prompt with a known child's id. Today fx refuses it.
SteerChild(k) ==
    /\ KnowsChild(k) /\ child[k] # "none" /\ steersSent < MaxSteers
    /\ IF Rules
       THEN /\ steersSent' = steersSent + 1
            /\ IF child[k] = "running"
               THEN /\ waiting' = [waiting EXCEPT ![k] = @ + 1]
                    /\ UNCHANGED <<child, childTurns, steersTaken, chan>>
               ELSE /\ childTurns < MaxChildTurns
                    /\ child' = [child EXCEPT ![k] = "running"]
                    /\ childTurns' = childTurns + 1
                    /\ steersTaken' = steersTaken + 1
                    /\ chan' = chan \o ToClient(<<Work(k)>>)
                    /\ UNCHANGED waiting
            /\ UNCHANGED flags
       ELSE /\ Flag("child_prompt_refused")
            /\ UNCHANGED <<steersSent, waiting, child, childTurns, steersTaken, chan>>
    /\ UNCHANGED <<parent, perm, asks, shown, seen, reportsMade, reports, reportsTaken,
                   cancels, loads>>

\* The client loads the parent again. It forgets what it read, and fx replays
\* every child's announcement and history, then each waiting request, then
\* the response.
Reload ==
    /\ loads < MaxLoads /\ chan = <<>>
    /\ loads' = loads + 1
    /\ seen' = [k \in Kids |-> FALSE]
    /\ shown' = {}
    /\ LET ordered == SeqOf({k \in Kids : child[k] # "none"})
           replay(k) == ToClient(<<Msg("announce", k, 0), Work(k)>>)
           asksOut(k) == IF perm[k] # 0 THEN ToClient(<<Msg("req", k, perm[k])>>) ELSE <<>>
           all == Cat([i \in 1..Len(ordered) |-> replay(ordered[i])])
                  \o Cat([i \in 1..Len(ordered) |-> asksOut(ordered[i])])
       IN chan' = all \o <<[kind |-> "loaded", k |-> {k \in Kids : child[k] # "none"}, n |-> 0]>>
    /\ UNCHANGED <<parent, child, childTurns, perm, asks, steersSent, waiting, steersTaken,
                   reportsMade, reports, reportsTaken, cancels, flags>>

\* The client reads the next message fx wrote to it.
Read ==
    /\ chan # <<>>
    /\ LET m == Head(chan) IN
       /\ chan' = Tail(chan)
       /\ seen' = IF m.kind = "announce" THEN [seen EXCEPT ![m.k] = TRUE] ELSE seen
       /\ shown' = CASE m.kind \in {"req", "parent_req"} -> shown \cup {[k |-> m.k, n |-> m.n]}
                     [] m.kind = "cancel" -> shown \ {[k |-> m.k, n |-> m.n]}
                     [] OTHER -> shown
       /\ flags' = flags
                   \cup (IF m.kind \in {"work", "req"} /\ ~seen[m.k] THEN {"before_announce"} ELSE {})
                   \cup (IF m.kind \in {"parent_work", "parent_req"} THEN {"under_parent"} ELSE {})
                   \cup (IF m.kind = "loaded" /\ \E k \in m.k : ~seen[k] THEN {"replay_missing"} ELSE {})
    /\ UNCHANGED <<parent, child, childTurns, perm, asks, steersSent, waiting, steersTaken,
                   reportsMade, reports, reportsTaken, cancels, loads>>

Next ==
    \/ ParentPrompt \/ ParentEnd \/ ParentTakeReport \/ CancelParent \/ Reload \/ Read
    \/ \E k \in Kids : Spawn(k) \/ Reuse(k) \/ ChildWork(k) \/ ChildAsk(k) \/ ChildTakeSteer(k)
                       \/ ChildEnd(k) \/ CancelChild(k) \/ SteerChild(k)
    \/ \E k \in Kids, n \in 1..MaxAsks : Answer(k, n)

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
(* Properties *)

\* The client reads a child's announcement before any of its work.
AnnouncedFirst == "before_announce" \notin flags

\* Every update and request of a child's work carries the child's id.
ChildIdUsed == "under_parent" \notin flags

\* Every request a child is waiting on is on the client, or on its way to it.
RequestShown ==
    \A k \in Kids : perm[k] # 0 =>
        \/ [k |-> k, n |-> perm[k]] \in shown
        \/ \E i \in 1..Len(chan) : chan[i] = Msg("req", k, perm[k])

\* A request the client shows is the child's waiting one, or its
\* cancellation is on its way.
RequestEndsWithChild ==
    \A r \in shown : perm[r.k] = r.n \/ \E i \in 1..Len(chan) : chan[i] = Msg("cancel", r.k, r.n)

\* session/cancel with a child's id stops the child.
ChildCancelWorks == "child_cancel_refused" \notin flags

\* A client can send a known child messages.
ChildPromptsWork == "child_prompt_refused" \notin flags

\* Each step of a child's work goes out to the client under the child's id.
WorkReachesClient ==
    [][\A k \in Kids : (Spawn(k) \/ Reuse(k) \/ ChildWork(k)) =>
        Len(chan') > 0 /\ chan'[Len(chan')] = Msg("work", k, 0)]_vars

\* Each turn a child starts, from the parent, a message, or a waiting message,
\* sends the client an update of the child's work in the same step. A message
\* that joins the running turn (ChildTakeSteer) starts no turn.
TurnStartSendsWork ==
    [][\A k \in Kids :
        (child'[k] = "running"
         /\ (child[k] # "running" \/ (waiting[k] > 0 /\ waiting'[k] = 0 /\ childTurns' > childTurns)))
            => \E i \in (Len(chan) + 1)..Len(chan') : chan'[i] = Msg("work", k, 0)]_vars

\* A child that isn't running sends no work and no request.
NoWorkWhenStopped ==
    [][~Reload => \A k \in Kids : child'[k] # "running" =>
        ~\E i \in (Len(chan) + 1)..Len(chan') :
            chan'[i].kind \in {"work", "parent_work", "req", "parent_req"} /\ chan'[i].k = k]_vars

\* session/cancel of a child stops it, ends its request, and gives the parent
\* its result.
CancelChildStops ==
    [][\A k \in Kids : CancelChild(k) =>
        /\ (child'[k] = "idle" \/ waiting[k] > 0)
        /\ perm'[k] = 0
        /\ reportsMade' = reportsMade + 1]_vars

\* Every session/cancel of a child makes its report.
CancelReports ==
    [][\A k \in Kids : CancelChild(k) => reportsMade' = reportsMade + 1]_vars

\* After the parent stops, a child still runs only to run the messages that
\* waited for it.
ParentStopStopsChildren ==
    [][CancelParent => \A k \in Kids : child'[k] = "running" => waiting[k] > 0]_vars

\* Stopping a child leaves the parent's turn as it was.
ChildStopLeavesParent == [][\A k \in Kids : CancelChild(k) => parent' = parent]_vars

\* A message to a child that waits when its work stops runs as its next turn.
SteerRunsNext ==
    [][\A k \in Kids : (ChildStops(k, TRUE) /\ waiting[k] > 0) => childTurns' = childTurns + 1]_vars

\* No message to a child is lost.
NoSteerLost == steersSent = steersTaken + SumOver(waiting, Kids)

\* No child's report is lost.
NoReportLost == reportsMade = reports + reportsTaken

\* A reload gives every child before its response.
ReplayComplete == "replay_missing" \notin flags

\* A reload replays each child's history, not only its announcement.
ReplayHasHistory ==
    [][Reload => \A k \in Kids : child[k] # "none" => \E i \in 1..Len(chan') : chan'[i] = Msg("work", k, 0)]_vars
=============================================================================
