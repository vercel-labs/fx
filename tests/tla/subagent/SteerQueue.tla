----------------------------- MODULE SteerQueue -----------------------------
(***************************************************************************)
(* Main's messages into its subagents' running turns, for Owner.steer in   *)
(* src/core/subagent/managed_owner.zig.                                    *)
(*                                                                         *)
(* A message to a working subagent joins its running turn and waits there  *)
(* unread until the subagent's next step reads it (worker_runtime.zig      *)
(* takeSteeringBoundaryInto). The owner keeps an entry for each message    *)
(* so a replayed tool call with the same operation id gets the same answer *)
(* and is never delivered twice. An entry is "waiting" until the subagent  *)
(* reads the message, then "settled"; a turn that ends or is cancelled     *)
(* before reading settles its unread ones too.                             *)
(*                                                                         *)
(* The limit is for one moment: a subagent with Cap unread messages takes  *)
(* no more until it reads them, and settled entries never count. Entries   *)
(* are dropped only where no worker can still touch their receipts: a new  *)
(* work starts with none, and a close forgets them all. So a subagent      *)
(* keeps entries only for its current work's own messages.                 *)
(*                                                                         *)
(* Bug plants one defect; check.sh names the rule that must catch each.    *)
(* "today" is fx before this design: one list for every subagent, settled  *)
(* entries counted, nothing dropped until the same subagent starts again.  *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS Children, Cap, MaxSends, Bug

Bugs == {"none", "today", "global_waiting", "settled_count", "off_by_one",
         "no_limit", "no_start_prune", "no_close_forget"}
Ops == {"none", "start", "steer", "read", "end", "cancel", "close"}
Results == {"none", "started", "accepted", "refused", "read", "ended",
            "cancelled", "closed"}

VARIABLES
    spawned,  \* [Children -> BOOLEAN]: started at least once, so it exists
    running,  \* [Children -> BOOLEAN]: a work runs that can take messages
    closed,   \* [Children -> BOOLEAN]: closed for good
    waiting,  \* [Children -> Nat]: accepted, not yet read
    settled,  \* [Children -> Nat]: entries kept for replay after reading
    taken,    \* [Children -> Nat]: messages accepted during the current work
    sends,    \* messages main tried, to bound the search
    last      \* the last event and its result, for the rules and traces

vars == <<spawned, running, closed, waiting, settled, taken, sends, last>>

RECURSIVE SumOver(_, _)
SumOver(f, S) ==
    IF S = {} THEN 0
    ELSE LET x == CHOOSE y \in S : TRUE IN f[x] + SumOver(f, S \ {x})

Kept(c) == waiting[c] + settled[c]
AllKept == SumOver([c \in Children |-> Kept(c)], Children)
AllWaiting == SumOver(waiting, Children)

\* Whether a message to working subagent c is refused.
Full(c) ==
    CASE Bug = "today"          -> AllKept >= Cap
      [] Bug = "global_waiting" -> AllWaiting >= Cap
      [] Bug = "settled_count"  -> Kept(c) >= Cap
      [] Bug = "off_by_one"     -> waiting[c] >= Cap - 1
      [] Bug = "no_limit"       -> FALSE
      [] OTHER                  -> waiting[c] >= Cap

Note(op, c, result) == last' = [op |-> op, child |-> c, result |-> result]

Init ==
    /\ spawned = [c \in Children |-> FALSE]
    /\ running = [c \in Children |-> FALSE]
    /\ closed = [c \in Children |-> FALSE]
    /\ waiting = [c \in Children |-> 0]
    /\ settled = [c \in Children |-> 0]
    /\ taken = [c \in Children |-> 0]
    /\ sends = 0
    /\ last = [op |-> "none", child |-> "none", result |-> "none"]

\* Main sends an idle subagent new work (Owner.start). Its settled
\* entries are dropped, as start has always done.
Start(c) ==
    /\ ~running[c] /\ ~closed[c]
    /\ spawned' = [spawned EXCEPT ![c] = TRUE]
    /\ running' = [running EXCEPT ![c] = TRUE]
    /\ settled' = [settled EXCEPT ![c] = IF Bug = "no_start_prune" THEN @ ELSE 0]
    /\ taken' = [taken EXCEPT ![c] = 0]
    /\ UNCHANGED <<closed, waiting, sends>>
    /\ Note("start", c, "started")

\* Main messages a working subagent (Owner.steer).
Steer(c) ==
    /\ running[c] /\ sends < MaxSends
    /\ sends' = sends + 1
    /\ IF Full(c)
          THEN /\ UNCHANGED <<spawned, running, closed, waiting, settled, taken>>
               /\ Note("steer", c, "refused")
          ELSE /\ waiting' = [waiting EXCEPT ![c] = @ + 1]
               /\ taken' = [taken EXCEPT ![c] = @ + 1]
               /\ UNCHANGED <<spawned, running, closed, settled>>
               /\ Note("steer", c, "accepted")

\* The subagent's next step reads every waiting message.
Read(c) ==
    /\ running[c] /\ waiting[c] > 0
    /\ settled' = [settled EXCEPT ![c] = @ + waiting[c]]
    /\ waiting' = [waiting EXCEPT ![c] = 0]
    /\ UNCHANGED <<spawned, running, closed, taken, sends>>
    /\ Note("read", c, "read")

\* The work ends on its own; its last step reads any waiting message first.
End(c) ==
    /\ running[c] /\ waiting[c] = 0
    /\ running' = [running EXCEPT ![c] = FALSE]
    /\ UNCHANGED <<spawned, closed, waiting, settled, taken, sends>>
    /\ Note("end", c, "ended")

\* Main or the user stops the work; unread messages settle as not applied.
Cancel(c) ==
    /\ running[c]
    /\ running' = [running EXCEPT ![c] = FALSE]
    /\ settled' = [settled EXCEPT ![c] = @ + waiting[c]]
    /\ waiting' = [waiting EXCEPT ![c] = 0]
    /\ UNCHANGED <<spawned, closed, taken, sends>>
    /\ Note("cancel", c, "cancelled")

\* Main closes an idle subagent for good; the close settles once nothing
\* of it runs (tool_host.zig settleClose). One never started doesn't exist.
Close(c) ==
    /\ spawned[c] /\ ~running[c] /\ ~closed[c]
    /\ closed' = [closed EXCEPT ![c] = TRUE]
    /\ settled' = [settled EXCEPT ![c] =
                     IF Bug \in {"today", "no_close_forget"} THEN @ ELSE 0]
    /\ UNCHANGED <<spawned, running, waiting, taken, sends>>
    /\ Note("close", c, "closed")

Next == \E c \in Children :
    Start(c) \/ Steer(c) \/ Read(c) \/ End(c) \/ Cancel(c) \/ Close(c)

Spec == Init /\ [][Next]_vars

TypeOK ==
    /\ Bug \in Bugs
    /\ spawned \in [Children -> BOOLEAN]
    /\ running \in [Children -> BOOLEAN]
    /\ closed \in [Children -> BOOLEAN]
    /\ waiting \in [Children -> Nat]
    /\ settled \in [Children -> Nat]
    /\ taken \in [Children -> Nat]
    /\ sends \in 0..MaxSends
    /\ last.op \in Ops /\ last.result \in Results

\* The limit is one moment's: a message is refused only when its subagent
\* already has Cap unread messages.
RefusedOnlyWhenFull ==
    last.result = "refused" => waiting[last.child] = Cap

\* No subagent ever holds more than Cap unread messages.
WaitingBounded == \A c \in Children : waiting[c] <= Cap

\* A subagent's entries are only its current work's own messages, so what
\* the owner keeps never grows over the session.
EntriesFromThisWork == \A c \in Children : Kept(c) <= taken[c]

\* A closed subagent holds nothing.
ClosedHoldsNothing ==
    \A c \in Children : closed[c] => waiting[c] = 0 /\ settled[c] = 0

\* A subagent with no running work has no unread message.
IdleHoldsNoUnread == \A c \in Children : ~running[c] => waiting[c] = 0
=============================================================================
