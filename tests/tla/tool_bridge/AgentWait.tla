----------------------------- MODULE AgentWait -----------------------------
(***************************************************************************)
(* `fx tool agent wait`, sent by a bash program through the tool bridge.   *)
(* The code has not landed yet.                                            *)
(*                                                                         *)
(* The wait works as the subagent tool's `wait` does: it ends when mail is *)
(* queued for the parent, when no child can still post, or when its call   *)
(* is canceled. It never takes the mail. The mail joins the parent's turn  *)
(* only while fx is not inside the bash call, so the model reads it after  *)
(* the call returns. While a bridge call runs, the bash call does not      *)
(* yield, on the first call and on `wait_more`. The program can exit or be *)
(* killed at any step. Its socket then closes, and the bridge cancels the  *)
(* wait. The bash call returns, and the next program starts, only after    *)
(* the bridge's calls for the last program have ended.                     *)
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

\* The yield time passes. A bridge call that runs holds the bash call.
\* Today `wait_more` ignores the hold (`managed_execution.zig` `waitOrYield`).
Yield ==
    /\ Inside
    /\ prog = "running"
    /\ \/ call = "none"
       \/ Mutation = "more-ignores-hold" /\ bash = "more"
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

\* The program sends `fx tool agent wait`. It returns at once when mail is
\* queued or no child works, as the subagent tool's wait does.
StartWait ==
    /\ prog = "running"
    /\ call = "none"
    /\ waits < MaxWaits
    /\ waits' = waits + 1
    /\ IF queued > 0 THEN call' = "none" /\ told' = "mail"
       ELSE IF ~working THEN call' = "none" /\ told' = "quiet"
       ELSE call' = "waiting" /\ told' = told
    /\ UNCHANGED <<prog, programs, bash, working, posted, queued, joined, lost>>

\* The child posts a report or a message to the parent.
Post ==
    /\ working
    /\ posted < MaxPosts
    /\ posted' = posted + 1
    /\ queued' = queued + 1
    /\ UNCHANGED <<prog, programs, call, waits, bash, working, joined, lost, told>>

\* The child's work ends. It posts before it stops counting as working.
ChildEnds ==
    /\ working
    /\ working' = FALSE
    /\ UNCHANGED <<prog, programs, call, waits, bash, posted, queued, joined, lost, told>>

\* The wait sees queued mail and ends. It leaves the mail in the queue. The
\* rejected design takes the mail and prints it, so a gone program loses it.
Wake ==
    /\ call = "waiting"
    /\ queued > 0
    /\ call' = "none"
    /\ told' = "mail"
    /\ IF Mutation = "wait-takes-mail"
       THEN /\ queued' = queued - 1
            /\ IF prog = "running"
               THEN joined' = joined + 1 /\ lost' = lost
               ELSE lost' = lost + 1 /\ joined' = joined
       ELSE UNCHANGED <<queued, joined, lost>>
    /\ UNCHANGED <<prog, programs, waits, bash, working, posted>>

\* The wait sees that no child works and no mail waits, and ends.
Quiet ==
    /\ call = "waiting"
    /\ ~working
    /\ queued = 0
    /\ call' = "none"
    /\ told' = "quiet"
    /\ UNCHANGED <<prog, programs, waits, bash, working, posted, queued, joined, lost>>

\* The bridge cancels the call of a program that is gone, and the wait ends.
\* Today the subagent wait reads no cancel flag (`tool_host.zig` `waitForMail`).
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
    \/ Wake \/ Quiet \/ Cancel \/ Join

\* Only fx's own steps are fair. The child, the program, and the model may
\* stop at any time, so no rule depends on them.
Spec ==
    /\ Init /\ [][Next]_vars
    /\ WF_vars(Wake) /\ WF_vars(Quiet) /\ WF_vars(Cancel) /\ WF_vars(Return)

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
    /\ told \in {"none", "mail", "quiet", "canceled"}

\* A wait runs only for a program that sent it, and only one at a time.
WaitHasProgram == call = "waiting" => prog \in {"running", "gone"}

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

\* A `wait_more` call was held by a running wait.
NeverHeldOnMore == ~(bash = "more" /\ call = "waiting")

=============================================================================
