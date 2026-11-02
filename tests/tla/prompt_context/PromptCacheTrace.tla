-------------------------- MODULE PromptCacheTrace --------------------------
(***************************************************************************)
(* Replays the requests the real fx binary sent (recorded by               *)
(* tests/tla/drivers/prompt_context/) through PromptCache's provider cache *)
(* and checks them against one modeled design.                             *)
(*                                                                         *)
(* PromptCacheObserved, which the driver writes, defines Observed: one     *)
(* record per model request in send order, with the worktree w, its        *)
(* repository repo, the session s, the request as PromptCache blocks, and  *)
(* manual, the block positions that carried a cache marker. Whether a      *)
(* request is a session's first, which request came before it, and whether *)
(* the context changed are derived here, not trusted from the driver: the  *)
(* turn context differs from the previous request's, or the request        *)
(* carries more changes on its messages than the previous one did.         *)
(*                                                                         *)
(* A check passes when TLC stops on ReplayIncomplete: every request was    *)
(* replayed and no listed property failed on the way. Conforms holds when  *)
(* every request has the modeled layout and exactly Design's markers.      *)
(***************************************************************************)
EXTENDS PromptCacheObserved, Naturals, Sequences, FiniteSets, TLC

CONSTANTS Design, Family, Notes, Carrier

VARIABLES i, cache, log
vars == <<i, cache, log>>

PC == INSTANCE PromptCache WITH
  Mutation <- "none", Worktrees <- {}, RepoOf <- [w \in {} |-> "none"],
  MaxSessions <- 0, MaxSteps <- 0, Limit <- 4, PathScoped <- TRUE, Events <- {"switch", "deliver", "skill"},
  sessions <- 0, active <- 0, branchOf <- 0

Kinds == <<"tools", "base", "skills", "project", "mcp", "ctx", "rt">>

Has(req, kind) == \E j \in 1..Len(req) : req[j].k = kind

\* The messages of a request that carry a change (Carrier "message").
Carried(req) == Cardinality({j \in 1..Len(req) : req[j].k \in {"asstc", "userc"}})

\* Blocks fx before P6 adds ahead of the history mid-session, and the blocks a
\* note carrier adds inside it. With Carrier = "message" a change is part of
\* the message that caused it, so no block of its own may appear.
Inserted == {"scoped", "skill"}
Noted == {"note", "skilltext", "skillnote"}
ConversationKinds ==
  CASE ~Notes -> {"user", "asst"}
    [] Carrier = "message" -> PC!MessageKinds
    [] OTHER -> {"user", "asst"} \cup Noted

Layout(req) ==
  /\ Has(req, "rt")
  /\ LET lead == SubSeq(req, 1, PC!NInstr(req))
         base == SelectSeq(lead, LAMBDA b : b.k \notin Inserted)
     IN /\ Len(base) = Len(Kinds)
        /\ \A j \in 1..Len(Kinds) : base[j].k = Kinds[j]
        /\ Notes => Len(base) = Len(lead)
  /\ Len(req) > PC!NInstr(req)
  /\ \A j \in (PC!NInstr(req) + 1)..Len(req) : req[j].k \in ConversationKinds
  /\ \E j \in (PC!NInstr(req) + 1)..Len(req) : req[j].k \in PC!UserKinds

\* The request before n in the same session, or 0 for a session's first.
Before(n) ==
  LET earlier == {j \in 1..(n - 1) : Observed[j].s = Observed[n].s}
  IN IF earlier = {} THEN 0 ELSE PC!Max(earlier)

Ctx(req) == IF Has(req, "ctx") THEN req[PC!PosOf(req, "ctx")] ELSE PC!Block("none", "none")

\* How much of the request before, Observed[b], the next request must read.
\* On a new user turn after a named skill, the history before that turn's
\* user message, whose skill text is swapped for a short note; otherwise all
\* of it except the notes at its end. The driver records which user message
\* carried the skill's text (skill), as it records the blocks.
Keep(b, req) ==
  LET prev == Observed[b].req
  IN IF (Has(prev, "skill") \/ Has(prev, "skilltext") \/ Observed[b].skill > 0)
        /\ PC!LastUser(req) > PC!LastUser(prev)
     THEN PC!LastUser(prev) - 1
     ELSE PC!LastKept(prev)

Init ==
  /\ i = 0
  /\ cache = {}
  /\ log = <<>>

Next ==
  /\ i < Len(Observed)
  /\ LET n == i + 1
         o == Observed[n]
         b == Before(n)
         bps == PC!BpsWith(o.req, o.manual)
     IN /\ cache' = cache \cup {SubSeq(o.req, 1, m) : m \in PC!WritesWith(o.req, o.manual)}
        /\ log' = Append(log, [w |-> o.w, s |-> o.s, first |-> b = 0, req |-> o.req, bps |-> bps,
                               read |-> PC!ReadWith(o.req, o.manual, cache),
                               prev |-> IF b = 0 THEN <<>> ELSE Observed[b].req,
                               changed |-> b # 0 /\ (Ctx(o.req) # Ctx(Observed[b].req)
                                                       \/ Carried(o.req) > Carried(Observed[b].req)),
                               keep |-> IF b = 0 THEN 0 ELSE Keep(b, o.req),
                               repoSeen |-> \E j \in 1..i : Observed[j].repo = o.repo,
                               worktreeSeen |-> \E j \in 1..i : Observed[j].w = o.w,
                               anySeen |-> i > 0])
        /\ i' = n

Spec == Init /\ [][Next]_vars

Conforms ==
  \A j \in 1..i : Layout(Observed[j].req) /\ Observed[j].manual = PC!Manual(Observed[j].req)

Budget == PC!Budget
SessionReuse == PC!SessionReuse
CrossRepoReuse == PC!CrossRepoReuse
SameWorktreeReuse == PC!SameWorktreeReuse
WorktreeReuse == PC!WorktreeReuse
ContextChangeKeepsStable == PC!ContextChangeKeepsStable
ContextChangeKeepsHistory == PC!ContextChangeKeepsHistory
MidSessionKeepsHistory == PC!MidSessionKeepsHistory
PreviousFullyReused == PC!PreviousFullyReused

ReplayIncomplete == i < Len(Observed)
=============================================================================
