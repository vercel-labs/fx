----------------------------- MODULE AgentWait -----------------------------
(***************************************************************************)
(* `fx tool agent wait`, sent by a bash program through the tool bridge.   *)
(* The subagent wait is in the code, and it reads its cancel flag          *)
(* (`tool_host.zig` `waitForWake`, since commit 490ea89719). The bridge's   *)
(* agent operations have not landed yet.                                   *)
(*                                                                         *)
(* The wait works as the subagent tool's `wait` does: it ends when a child *)
(* posts mail for the parent, when no child can still post, or when its    *)
(* call is canceled. It never takes the mail. The mail joins the parent's  *)
(* turn only while fx is not inside the bash call, so the model reads it   *)
(* after the call returns. A post or a child's end ends an open wait in    *)
(* the same step, because the wait returns at once when it sees either.    *)
(*                                                                         *)
(* The bridge serves a program only during its first bash call. Once that  *)
(* call yields, the bridge is gone, and a later wait is refused at once.   *)
(* While a bridge call runs, the first call does not yield. The program    *)
(* can exit or be killed at any step. Its socket then closes, and the      *)
(* bridge cancels the wait. The bash call returns, and the next program    *)
(* starts, only after the bridge's calls for the last program have ended,  *)
(* because the bridge's teardown waits for them.                           *)
(***************************************************************************)
EXTENDS Naturals

CONSTANTS
    MaxPosts,     \* how many mails the child may post
    MaxPrograms,  \* how many programs the model may run
    MaxWaits,     \* how many wait calls each program may send
    Mutation      \* "none", or one planted defect that check.sh names

VARIABLES
    prog,      \* the last program: "none", "running", or "gone"
    programs,  \* programs started so far
    call,      \* its `fx tool agent wait` call: "none" or "waiting"
    waits,     \* wait calls the last program sent
    bash,      \* the model's bash call: "idle", "first", "more", or "yielded"
    working,   \* a child works, so it can still post
    posted,    \* mail the child posted
    queued,    \* mail posted that has not joined the parent's turn
    joined,    \* mail that reached the parent model
    lost,      \* mail that left the queue and reached no one
    told       \* what the last wait told its program

vars == <<prog, programs, call, waits, bash, working, posted, queued, joined, lost, told>>

Init ==
    /\ prog = "none"
    /\ programs = 0
    /\ call = "none"
    /\ waits = 0
    /\ bash = "idle"
    /\ working = TRUE
    /\ posted = 0
    /\ queued = 0
    /\ joined = 0
    /\ lost = 0
    /\ told = "none"

Inside == bash \in {"first", "more"}

\* The model calls bash with a new program. The bridge's calls for the last
\* program must have ended first, because the call tears that bridge down.
Run ==
    /\ bash \in {"idle", "yielded"}
    /\ prog # "running"
    /\ call = "none"
    /\ programs < MaxPrograms
    /\ prog' = "running"
    /\ programs' = programs + 1
    /\ waits' = 0
    /\ bash' = "first"
    /\ UNCHANGED <<call, working, posted, queued, joined, lost, told>>

\* The model calls bash with `wait_more` after a "still running" result.
WaitMore ==
    /\ bash = "yielded"
    /\ bash' = "more"
    /\ UNCHANGED <<prog, programs, call, waits, working, posted, queued, joined, lost, told>>

\* The yield time passes. A bridge call that runs holds the first call
\* (`managed_execution.zig` `yield_hold`). After the yield the bridge is gone.
\* A held first call waits `bridge_yield_grace_ms` (1,000 ms) after the last
\* 10 ms poll that saw the hold, so a hold that no poll saw gives no grace.
\* This model yields at once when no wait holds the call. The timed scenario
\* in tests/tla/drivers/tool_bridge/agent-timing.ts checks the grace.
Yield ==
    /\ Inside
    /\ prog = "running"
    /\ \/ call = "none"
       \/ Mutation = "yield-while-held"
    /\ bash' = "yielded"
    /\ UNCHANGED <<prog, programs, call, waits, working, posted, queued, joined, lost, told>>

\* The program ended, and its bridge calls have ended, so the call returns.
Return ==
    /\ Inside
    /\ prog = "gone"
    /\ call = "none"
    /\ bash' = "idle"
    /\ UNCHANGED <<prog, programs, call, waits, working, posted, queued, joined, lost, told>>

\* The program exits, or it is killed, and its socket closes.
Gone ==
    /\ prog = "running"
    /\ prog' = "gone"
    /\ UNCHANGED <<programs, call, waits, bash, working, posted, queued, joined, lost, told>>

\* The program sends `fx tool agent wait`. After its first call yielded, no
\* bridge is there, and the client exits at once. Otherwise the wait returns
\* at once when mail is queued or no child works, as the subagent tool's
\* wait does, and else it waits.
StartWait ==
    /\ prog = "running"
    /\ call = "none"
    /\ waits < MaxWaits
    /\ waits' = waits + 1
    /\ IF bash # "first" THEN call' = "none" /\ told' = "unavailable"
       ELSE IF queued > 0 THEN call' = "none" /\ told' = "mail"
       ELSE IF ~working THEN call' = "none" /\ told' = "quiet"
       ELSE call' = "waiting" /\ told' = told
    /\ UNCHANGED <<prog, programs, bash, working, posted, queued, joined, lost>>

\* The child posts a report or a message to the parent. A wait that is open
\* ends at once, in this step, with the mail, and the mail stays queued for the
\* parent's turn. The rejected design (wait-takes-mail) takes the mail instead:
\* a gone program loses it, and a running program's turn reads it.
Post ==
    /\ working
    /\ posted < MaxPosts
    /\ posted' = posted + 1
    /\ \/ /\ call = "waiting"
          /\ call' = "none"
          /\ told' = "mail"
          /\ IF Mutation = "wait-takes-mail"
             THEN /\ queued' = queued
                  /\ IF prog = "running"
                     THEN joined' = joined + 1 /\ lost' = lost
                     ELSE lost' = lost + 1 /\ joined' = joined
             ELSE /\ queued' = queued + 1
                  /\ UNCHANGED <<joined, lost>>
       \/ /\ call # "waiting"
          /\ queued' = queued + 1
          /\ UNCHANGED <<call, told, joined, lost>>
    /\ UNCHANGED <<prog, programs, waits, bash, working>>

\* The child's work ends. It posts before it stops counting as working. A wait
\* that is open ends at once, in this step, with quiet. No mail waits then,
\* because a post would have ended the wait first.
ChildEnds ==
    /\ working
    /\ working' = FALSE
    /\ \/ /\ call = "waiting"
          /\ call' = "none"
          /\ told' = "quiet"
       \/ /\ call # "waiting"
          /\ UNCHANGED <<call, told>>
    /\ UNCHANGED <<prog, programs, waits, bash, posted, queued, joined, lost>>

\* The bridge cancels the call of a program that is gone, and the wait ends.
\* The subagent wait reads its cancel flag (`tool_host.zig` `waitForWake`). The
\* planted bug ignore-cancel removes that read.
Cancel ==
    /\ call = "waiting"
    /\ prog = "gone"
    /\ Mutation # "ignore-cancel"
    /\ call' = "none"
    /\ told' = "canceled"
    /\ UNCHANGED <<prog, programs, waits, bash, working, posted, queued, joined, lost>>

\* Queued mail joins the parent's turn while fx is not inside the bash call.
Join ==
    /\ queued > 0
    /\ ~Inside
    /\ queued' = queued - 1
    /\ joined' = joined + 1
    /\ UNCHANGED <<prog, programs, call, waits, bash, working, posted, lost, told>>

Next ==
    \/ Run \/ WaitMore \/ Yield \/ Return \/ Gone
    \/ StartWait \/ Post \/ ChildEnds
    \/ Cancel \/ Join

\* Cancel and Return are fair: fx ends a canceled wait and returns a call whose
\* program is gone. A post and a child's end are not forced, since the child,
\* the program, and the model may stop at any time.
Spec ==
    /\ Init /\ [][Next]_vars
    /\ WF_vars(Cancel) /\ WF_vars(Return)

-----------------------------------------------------------------------------
\* Rules.

TypeOK ==
    /\ prog \in {"none", "running", "gone"}
    /\ programs \in 0..MaxPrograms
    /\ call \in {"none", "waiting"}
    /\ waits \in 0..MaxWaits
    /\ bash \in {"idle", "first", "more", "yielded"}
    /\ working \in BOOLEAN
    /\ posted \in 0..MaxPosts
    /\ {queued, joined, lost} \subseteq 0..MaxPosts
    /\ told \in {"none", "mail", "quiet", "canceled", "unavailable"}

\* A wait runs only for a program that sent it, and only inside the first
\* bash call, which the bridge belongs to.
WaitHasProgram == call = "waiting" => prog \in {"running", "gone"} /\ bash = "first"

\* An open wait holds no mail: a post or a child's end ends it in the same step.
OpenWaitHasNoMail == call = "waiting" => queued = 0

\* Every posted mail is in one place: queued, or with the parent model.
MailKept == posted = queued + joined + lost

\* No mail is lost.
NoMailLost == lost = 0

\* The bash call never yields while a bridge call holds it.
NoYieldWhileHeld == [][Inside /\ bash' = "yielded" => call = "none"]_vars

\* A wait whose program is gone ends, even when no child ever posts.
WaitEndsWhenGone == [](call = "waiting" /\ prog = "gone" => <>(call = "none"))

\* A bash call whose program is gone returns.
CallReturnsWhenGone == [](Inside /\ prog = "gone" => <>(bash = "idle"))

-----------------------------------------------------------------------------
\* Witnesses: each must be violated, to show that TLC reaches that case.

\* A wait ended because its program was gone.
NeverCanceled == told # "canceled"

\* A wait ended because no child could still post.
NeverQuiet == told # "quiet"

\* A wait ended on mail, and the mail later reached the parent model.
NeverMailAfterWait == ~(told = "mail" /\ joined > 0)

\* A program sent a wait after its first call yielded, and was refused.
NeverUnavailable == told # "unavailable"

=============================================================================
