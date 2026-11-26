---------------------------- MODULE ShellSnapshot ----------------------------
(***************************************************************************)
(* fx's in-memory shell snapshot owner (src/core/terminal/shell_snapshot). *)
(*                                                                          *)
(* One owner per fx process, shared by the root agent and every subagent.   *)
(* After admission, a captured shell.run under the user profile does one    *)
(* of the following:                                                        *)
(*   - leases the ready snapshot generation and runs `zsh -f` / clean bash   *)
(*     restored from it;                                                    *)
(*   - starts the single-flight capture (first use, or after a refresh);    *)
(*   - waits for an in-flight capture;                                      *)
(*   - runs with the full dotfile startup when capture failed.          *)
(* A replay the restored shell rejects reruns that call with full startup *)
(* and fails the generation, so later calls fall back until a refresh.     *)
(*                                                                          *)
(* A dotfile change detected before a command, /shell reload, or            *)
(* shell.run reload=true marks the snapshot dirty and bumps the approval    *)
(* epoch. Each session keeps its own remembered grant. A remembered grant  *)
(* authorizes only calls that execute, in that same session, under the     *)
(* epoch it was granted in, so a refresh resets approvals in every session. *)
(* A one-time answer is rechecked at run time the same way: after a refresh, *)
(* the command is asked again.                                                *)
(*                                                                          *)
(* `Sessions` are the fx sessions that share the owner. A command belongs   *)
(* to one of them. Every session is checked against its own grant.         *)
(*                                                                          *)
(* `Mutation` enables one deliberately broken rule so TLC can show each     *)
(* invariant detects the defect it exists for. "none" is the design.        *)
(* "shared_command_epoch" keeps the epoch per command for the whole         *)
(* process: a grant recorded by any session stamps the command, so another  *)
(* session's older grant admits a call without a question. All commands     *)
(* here are one command text.                                               *)
(* "reload_per_command" is the behavior without a snapshot: dotfiles run   *)
(* on every call.                                                           *)
(* The two-session configs run at MaxGen 2. With one session and two       *)
(* commands, MaxGen 3 explores three shell generations (ShellSnapshot-     *)
(* one_session*.cfg). Not explored: three generations with two sessions,   *)
(* or with three commands; three commands with one session at MaxGen 3 did *)
(* not finish in 11 minutes.                                               *)
(* A question is asked in one step and answered in another. The epoch is   *)
(* read when the question is asked, so a refresh while the question is     *)
(* open leaves the answer on the old epoch, and the next call asks again.  *)
(***************************************************************************)
EXTENDS Integers, FiniteSets, TLC

CONSTANTS Cmds, MaxGen, Mutation, Sessions, FirstSession

ASSUME MaxGen \in Nat \ {0}
ASSUME Sessions \subseteq {"s1", "s2"} /\ Sessions # {}
ASSUME FirstSession \subseteq Cmds
ASSUME Mutation \in {"none", "no_single_flight", "free_while_leased",
                     "stale_grant", "reload_per_command", "notice_repeat",
                     "use_partial", "clear_dirty_late", "keep_broken",
                     "shared_command_epoch", "recheck_restamps",
                     "store_stamps_current", "stamp_at_answer"}

Gens    == 1..MaxGen
NoGen   == 0
NoGrant == -1

\* The run-time recheck of a grant-authorized call. The stale-grant planted bug
\* removes it; the shared-epoch bug breaks only the admission rule.
NoRecheck == Mutation = "stale_grant"

\* The restamp bug rewrites the approval's epoch to the current one before the
\* recheck compares it, so the recheck always passes. Only the answer record,
\* `answered`, keeps the epoch the person gave.
RestampRecheck == Mutation = "recheck_restamps"

\* Commands in FirstSession belong to session "s1"; the others belong to "s2".
SessOf(c) == IF c \in FirstSession THEN "s1" ELSE "s2"

VARIABLES
    owner,        \* "empty" | "capturing" | "ready" | "failed"
    active,       \* ready generation, or NoGen
    capGen,       \* generation being captured, or NoGen
    inflight,     \* captures currently running
    nextGen,      \* next generation id
    epoch,        \* approval epoch; bumped by every accepted refresh trigger
    genEpoch,     \* epoch each generation was captured under
    dirty,        \* refresh requested since the last capture started
    completed,    \* generations whose capture succeeded
    leases,       \* commands currently executing with each generation
    freed,        \* generations whose memory has been released
    broken,       \* generations whose replay the restored shell rejected
    loads,        \* times user dotfiles executed (captures + full fallbacks)
    triggers,     \* refresh triggers accepted
    fullRuns,     \* commands run with the full startup
    failEpisodes, \* transitions into "failed"
    notices,      \* one-line fallback notices shown
    noticeShown,  \* notice already shown for the current failure episode
    grant,        \* per session: epoch of its remembered grant, or NoGrant
    sharedEpoch,  \* epoch of the latest remembered grant by any session
    pc,           \* per-command control state
    auth,         \* how each command was authorized
    authEpoch,    \* epoch a command's approval relies on, as its recheck compares it
    answered,     \* epoch the person's approval was given under; never rewritten
    asked,        \* epoch the question was shown under; the answer records it
    pending,      \* remembered answer not yet written to its session's grant
    cgen,         \* generation leased by a running command
    runEpoch      \* epoch a command executed under

snapVars  == <<owner, active, capGen, inflight, nextGen, genEpoch, completed, freed, broken>>
countVars == <<loads, triggers, fullRuns, failEpisodes, notices, noticeShown>>
cmdVars   == <<pc, auth, authEpoch, answered, asked, pending, cgen, runEpoch>>
vars      == <<snapVars, countVars, cmdVars, epoch, dirty, leases, grant, sharedEpoch>>

\* A remembered grant or a one-time answer that the run-time recheck judges.
Approved(c) == auth[c] \in {"grant", "explicit"}

Restamp(c, e) == IF RestampRecheck /\ Approved(c) THEN [authEpoch EXCEPT ![c] = e] ELSE authEpoch

PcStates == {"idle", "asking", "admitted", "waiting", "run_snap", "run_full", "done"}

TypeOK ==
    /\ owner \in {"empty", "capturing", "ready", "failed"}
    /\ active \in 0..MaxGen
    /\ capGen \in 0..MaxGen
    /\ inflight \in 0..Cardinality(Cmds)
    /\ nextGen \in 1..(MaxGen + 1)
    /\ epoch \in Nat
    /\ genEpoch \in [Gens -> Nat]
    /\ dirty \in BOOLEAN
    /\ completed \subseteq Gens
    /\ freed \subseteq Gens
    /\ broken \subseteq Gens
    /\ leases \in [Gens -> 0..Cardinality(Cmds)]
    /\ loads \in Nat /\ triggers \in Nat /\ fullRuns \in Nat
    /\ failEpisodes \in Nat /\ notices \in Nat
    /\ noticeShown \in BOOLEAN
    /\ grant \in [Sessions -> {NoGrant} \cup Nat]
    /\ sharedEpoch \in Nat
    /\ pc \in [Cmds -> PcStates]
    /\ auth \in [Cmds -> {"none", "grant", "explicit"}]
    /\ authEpoch \in [Cmds -> Nat]
    /\ answered \in [Cmds -> Nat]
    /\ asked \in [Cmds -> Nat]
    /\ pending \in [Cmds -> BOOLEAN]
    /\ cgen \in [Cmds -> 0..MaxGen]
    /\ runEpoch \in [Cmds -> Nat]

Init ==
    /\ owner = "empty"
    /\ active = NoGen
    /\ capGen = NoGen
    /\ inflight = 0
    /\ nextGen = 1
    /\ epoch = 0
    /\ genEpoch = [g \in Gens |-> 0]
    /\ dirty = FALSE
    /\ completed = {}
    /\ leases = [g \in Gens |-> 0]
    /\ freed = {}
    /\ broken = {}
    /\ loads = 0
    /\ triggers = 0
    /\ fullRuns = 0
    /\ failEpisodes = 0
    /\ notices = 0
    /\ noticeShown = FALSE
    /\ grant = [s \in Sessions |-> NoGrant]
    /\ sharedEpoch = 0
    /\ pc = [c \in Cmds |-> "idle"]
    /\ auth = [c \in Cmds |-> "none"]
    /\ authEpoch = [c \in Cmds |-> 0]
    /\ answered = [c \in Cmds |-> 0]
    /\ asked = [c \in Cmds |-> 0]
    /\ pending = [c \in Cmds |-> FALSE]
    /\ cgen = [c \in Cmds |-> NoGen]
    /\ runEpoch = [c \in Cmds |-> 0]

Pending(c) == pc[c] \in {"admitted", "waiting"}

-----------------------------------------------------------------------------
(* Admission happens before the snapshot is touched, so a denied command  *)
(* never runs the user's dotfiles.                                         *)

AdmitByGrant(c) ==
    /\ pc[c] = "idle"
    /\ grant[SessOf(c)] # NoGrant
    /\ \/ grant[SessOf(c)] = epoch
       \/ Mutation = "stale_grant"
       \/ (Mutation = "shared_command_epoch" /\ sharedEpoch = epoch)
    /\ pc' = [pc EXCEPT ![c] = "admitted"]
    /\ auth' = [auth EXCEPT ![c] = "grant"]
    /\ authEpoch' = [authEpoch EXCEPT ![c] = grant[SessOf(c)]]
    /\ answered' = [answered EXCEPT ![c] = grant[SessOf(c)]]
    /\ asked' = [asked EXCEPT ![c] = grant[SessOf(c)]]
    /\ UNCHANGED <<snapVars, countVars, epoch, dirty, leases, grant, sharedEpoch, pending, cgen, runEpoch>>

Ask(c) ==
    /\ pc[c] = "idle"
    /\ pc' = [pc EXCEPT ![c] = "asking"]
    /\ asked' = [asked EXCEPT ![c] = epoch]
    /\ UNCHANGED <<snapVars, countVars, epoch, dirty, leases, grant, sharedEpoch, pending, auth, authEpoch, answered, cgen, runEpoch>>

\* The answer comes later, after the question was shown. It keeps the epoch the
\* question recorded. The stamp bug records the epoch current at the answer.
Answer(c) ==
    /\ pc[c] = "asking"
    /\ \E remember \in BOOLEAN :
         pending' = [pending EXCEPT ![c] = remember]
    /\ LET e == IF Mutation = "stamp_at_answer" THEN epoch ELSE asked[c]
       IN  /\ authEpoch' = [authEpoch EXCEPT ![c] = e]
           /\ answered' = [answered EXCEPT ![c] = e]
    /\ pc' = [pc EXCEPT ![c] = "admitted"]
    /\ auth' = [auth EXCEPT ![c] = "explicit"]
    /\ UNCHANGED <<snapVars, countVars, epoch, dirty, leases, grant, sharedEpoch, asked, cgen, runEpoch>>

\* A remembered answer is written to its session's grant in a later step, not
\* with the answer, so a refresh can land in between. The write keeps the epoch
\* the answer was given under. The store bug writes the epoch current at the
\* write instead.
Record(c) ==
    /\ pending[c]
    /\ LET e == IF Mutation = "store_stamps_current" THEN epoch ELSE answered[c]
       IN  /\ grant' = [grant EXCEPT ![SessOf(c)] = e]
           /\ sharedEpoch' = e
    /\ pending' = [pending EXCEPT ![c] = FALSE]
    /\ UNCHANGED <<snapVars, countVars, epoch, dirty, leases, pc, auth, authEpoch, answered, asked, cgen, runEpoch>>

\* A grant-authorized call whose grant predates the current epoch is asked again.
ReAsk(c) ==
    /\ pc' = [pc EXCEPT ![c] = "idle"]
    /\ auth' = [auth EXCEPT ![c] = "none"]
    /\ UNCHANGED <<snapVars, countVars, epoch, dirty, leases, grant, sharedEpoch, authEpoch, answered, asked, pending, cgen, runEpoch>>

-----------------------------------------------------------------------------
(* Snapshot owner.                                                          *)

NeedsCapture ==
    \/ owner = "empty"
    \/ (owner \in {"ready", "failed"} /\ dirty)

StartCapture(c) ==
    /\ Pending(c)
    /\ ~pending[c]
    /\ \/ NeedsCapture
       \/ (Mutation = "no_single_flight" /\ owner = "capturing")
    /\ nextGen <= MaxGen
    /\ owner' = "capturing"
    /\ capGen' = nextGen
    /\ nextGen' = nextGen + 1
    /\ inflight' = inflight + 1
    /\ genEpoch' = [genEpoch EXCEPT ![nextGen] = epoch]
    \* The capture reads the dotfiles as they are now, so the request is
    \* consumed here; a change during capture marks it dirty again.
    /\ dirty' = IF Mutation = "clear_dirty_late" THEN dirty ELSE FALSE
    /\ loads' = loads + 1
    /\ pc' = [pc EXCEPT ![c] = "waiting"]
    /\ UNCHANGED <<active, completed, freed, broken, triggers, fullRuns, failEpisodes,
                   notices, noticeShown, epoch, leases, grant, sharedEpoch, auth, authEpoch,
                   answered, asked, pending, cgen, runEpoch>>

\* Release a replaced generation now, or when its last lease ends.
Retire(g, f) ==
    IF g # NoGen /\ (leases[g] = 0 \/ Mutation = "free_while_leased")
    THEN f \cup {g}
    ELSE f

CaptureOk ==
    /\ owner = "capturing"
    /\ owner' = "ready"
    /\ active' = capGen
    /\ capGen' = NoGen
    /\ inflight' = inflight - 1
    /\ completed' = completed \cup {capGen}
    /\ freed' = Retire(active, freed)
    /\ noticeShown' = FALSE
    /\ dirty' = IF Mutation = "clear_dirty_late" THEN FALSE ELSE dirty
    /\ UNCHANGED <<nextGen, genEpoch, broken, loads, triggers, fullRuns, failEpisodes,
                   notices, epoch, leases, grant, sharedEpoch, cmdVars>>

\* Non-zero exit, 10 s timeout, size cap, or invalid capture output. The old
\* snapshot is retired too: commands use the full startup, which reflects
\* the dotfiles as they are now.
CaptureFail ==
    /\ owner = "capturing"
    /\ owner' = "failed"
    /\ active' = NoGen
    /\ capGen' = NoGen
    /\ inflight' = inflight - 1
    /\ freed' = Retire(active, freed) \cup {capGen}
    /\ failEpisodes' = failEpisodes + 1
    /\ noticeShown' = FALSE
    /\ dirty' = IF Mutation = "clear_dirty_late" THEN FALSE ELSE dirty
    /\ UNCHANGED <<nextGen, genEpoch, completed, broken, loads, triggers, fullRuns,
                   notices, epoch, leases, grant, sharedEpoch, cmdVars>>

Acquire(c) ==
    /\ Pending(c)
    /\ ~pending[c]
    /\ \/ (owner = "ready" /\ ~dirty)
       \/ (Mutation = "use_partial" /\ owner = "capturing")
    /\ LET g == IF owner = "ready" THEN active ELSE capGen
       IN  IF Approved(c) /\ authEpoch[c] # genEpoch[g] /\ ~NoRecheck /\ ~RestampRecheck
           THEN ReAsk(c)
           ELSE /\ leases' = [leases EXCEPT ![g] = @ + 1]
                /\ cgen' = [cgen EXCEPT ![c] = g]
                /\ runEpoch' = [runEpoch EXCEPT ![c] = genEpoch[g]]
                /\ authEpoch' = Restamp(c, genEpoch[g])
                /\ pc' = [pc EXCEPT ![c] = "run_snap"]
                /\ loads' = IF Mutation = "reload_per_command" THEN loads + 1 ELSE loads
                /\ UNCHANGED <<snapVars, triggers, fullRuns, failEpisodes, notices,
                               noticeShown, epoch, dirty, grant, sharedEpoch, auth, answered, asked, pending>>

RunFull(c) ==
    /\ Pending(c)
    /\ ~pending[c]
    /\ owner = "failed"
    /\ ~dirty
    /\ IF Approved(c) /\ authEpoch[c] # epoch /\ ~NoRecheck /\ ~RestampRecheck
       THEN ReAsk(c)
       ELSE /\ pc' = [pc EXCEPT ![c] = "run_full"]
            /\ runEpoch' = [runEpoch EXCEPT ![c] = epoch]
            /\ authEpoch' = Restamp(c, epoch)
            /\ loads' = loads + 1
            /\ fullRuns' = fullRuns + 1
            /\ notices' = IF ~noticeShown \/ Mutation = "notice_repeat"
                          THEN notices + 1
                          ELSE notices
            /\ noticeShown' = TRUE
            /\ UNCHANGED <<snapVars, triggers, failEpisodes, epoch, dirty, leases,
                           grant, sharedEpoch, auth, answered, asked, pending, cgen>>

Finish(c) ==
    /\ pc[c] \in {"run_snap", "run_full"}
    /\ pc' = [pc EXCEPT ![c] = "done"]
    /\ IF pc[c] = "run_snap"
       THEN /\ leases' = [leases EXCEPT ![cgen[c]] = @ - 1]
            /\ freed' = IF cgen[c] # active /\ cgen[c] # capGen /\ leases[cgen[c]] = 1
                        THEN freed \cup {cgen[c]}
                        ELSE freed
            /\ cgen' = [cgen EXCEPT ![c] = NoGen]
       ELSE UNCHANGED <<leases, freed, cgen>>
    /\ UNCHANGED <<owner, active, capGen, inflight, nextGen, genEpoch, completed,
                   broken, countVars, epoch, dirty, grant, sharedEpoch, auth, authEpoch, answered, asked, pending, runEpoch>>

\* The restored shell rejected the replay and exited with the failure marker.
\* The call reruns with the full startup. If the owner still holds that
\* generation it fails it and shows the notice once; a generation that was
\* already replaced only loses the lease.
ReplayFail(c) ==
    /\ pc[c] = "run_snap"
    /\ LET g         == cgen[c]
           holds     == owner = "ready" /\ active = g
           lastLease == leases[g] = 1
       IN  /\ broken' = broken \cup {g}
           /\ leases' = [leases EXCEPT ![g] = @ - 1]
           /\ cgen' = [cgen EXCEPT ![c] = NoGen]
           /\ pc' = [pc EXCEPT ![c] = "run_full"]
           /\ loads' = loads + 1
           /\ fullRuns' = fullRuns + 1
           /\ IF holds /\ Mutation # "keep_broken"
              THEN /\ owner' = "failed"
                   /\ active' = NoGen
                   /\ freed' = IF lastLease THEN freed \cup {g} ELSE freed
                   /\ failEpisodes' = failEpisodes + 1
                   /\ notices' = notices + 1
                   /\ noticeShown' = TRUE
              ELSE /\ freed' = IF g # active /\ g # capGen /\ lastLease
                               THEN freed \cup {g}
                               ELSE freed
                   /\ UNCHANGED <<owner, active, failEpisodes, notices, noticeShown>>
    /\ UNCHANGED <<capGen, inflight, nextGen, genEpoch, completed, triggers,
                   epoch, dirty, grant, sharedEpoch, auth, authEpoch, answered, asked, pending, runEpoch>>

\* Cancelling a waiting command does not cancel the shared capture.
Cancel(c) ==
    /\ Pending(c)
    /\ ~pending[c]
    /\ pc' = [pc EXCEPT ![c] = "done"]
    /\ UNCHANGED <<snapVars, countVars, epoch, dirty, leases, grant, sharedEpoch, auth,
                   authEpoch, answered, asked, pending, cgen, runEpoch>>

\* Dotfile fingerprint changed, /shell reload, or shell.run reload=true.
MarkDirty ==
    /\ ~dirty
    /\ nextGen <= MaxGen
    /\ dirty' = TRUE
    /\ epoch' = epoch + 1
    /\ triggers' = triggers + 1
    /\ UNCHANGED <<snapVars, loads, fullRuns, failEpisodes, notices, noticeShown,
                   leases, grant, sharedEpoch, cmdVars>>

Done ==
    /\ \A c \in Cmds : pc[c] = "done"
    /\ UNCHANGED vars

Next ==
    \/ \E c \in Cmds :
          \/ AdmitByGrant(c)
          \/ Ask(c)
          \/ Answer(c)
          \/ StartCapture(c)
          \/ Acquire(c)
          \/ RunFull(c)
          \/ Finish(c)
          \/ ReplayFail(c)
          \/ Cancel(c)
          \/ Record(c)
    \/ CaptureOk
    \/ CaptureFail
    \/ MarkDirty
    \/ Done

Fairness ==
    /\ WF_vars(CaptureOk \/ CaptureFail)
    /\ \A c \in Cmds : WF_vars(StartCapture(c) \/ Acquire(c) \/ RunFull(c))
    /\ \A c \in Cmds : WF_vars(Finish(c))
    /\ \A c \in Cmds : WF_vars(Record(c))

Spec       == Init /\ [][Next]_vars /\ Fairness
SafetySpec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
(* Safety: each invariant names the design contract it checks.              *)

\* At most one capture of the user's dotfiles runs at a time.
SingleFlight == inflight <= 1

\* A running command never uses a released generation.
NoUseAfterFree == \A c \in Cmds : pc[c] = "run_snap" => cgen[c] \notin freed

\* A generation is released only after its last lease ends.
FreeOnlyUnleased == \A g \in freed : leases[g] = 0

\* Commands only ever run with a fully captured, validated snapshot.
RunsCompleteSnapshot == \A c \in Cmds : pc[c] = "run_snap" => cgen[c] \in completed

\* Every replaced, unleased generation has been released.
NoLeak ==
    \A g \in 1..(nextGen - 1) :
        (g # active /\ g # capGen /\ leases[g] = 0) => g \in freed

\* Dotfiles run once per refresh (plus one initial capture), not once per
\* command, except for commands that fell back to the full startup.
DotfilesPaidOnce == loads <= 1 + triggers + fullRuns

\* A remembered grant authorizes only calls executing under its own epoch, in
\* the session that granted it.
GrantMatchesEpoch ==
    \A c \in Cmds :
        (pc[c] \in {"run_snap", "run_full"} /\ auth[c] = "grant")
            => authEpoch[c] = runEpoch[c]

\* A one-time or remembered approval runs only in the epoch its question was shown
\* in. The answer keeps that epoch, and the recheck compares it with the current one.
ApprovalMatchesAnswer ==
    \A c \in Cmds :
        (pc[c] \in {"run_snap", "run_full"} /\ Approved(c))
            => runEpoch[c] = asked[c]

\* A remembered answer is written to its grant with the epoch the answer was
\* given under. (An action property: it is checked on every step.)
StoredGrantMatchesAnswer ==
    [][\A c \in Cmds :
          (pending[c] /\ ~pending'[c]) => grant'[SessOf(c)] = answered[c]]_vars

\* The fallback notice appears at most once per failure episode.
NoticeOncePerEpisode == notices <= failEpisodes

\* A generation the restored shell rejected is never offered again. During a
\* refresh the old generation stays active but is not leasable.
NoReuseOfBroken == owner = "ready" => active \notin broken

\* A grant admits a call only when the grant was made in the current epoch,
\* so an older grant never admits a call without a question. (An action
\* property: it is checked on every step.)
AdmissionUsesCurrentEpoch ==
    [][\A c \in Cmds :
          (pc[c] = "idle" /\ pc'[c] = "admitted" /\ auth'[c] = "grant")
              => authEpoch'[c] = epoch']_vars

\* With no pending refresh, the ready snapshot reflects the latest dotfiles.
FreshWhenClean == (owner = "ready" /\ ~dirty) => genEpoch[active] = epoch

-----------------------------------------------------------------------------
(* Liveness under weak fairness.                                            *)

CaptureResolves == (owner = "capturing") ~> (owner \in {"ready", "failed"})

EveryCallProgresses ==
    \A c \in Cmds :
        (pc[c] \in {"admitted", "waiting"})
            ~> (pc[c] \in {"run_snap", "run_full", "done", "idle"})

EveryRunFinishes ==
    \A c \in Cmds : (pc[c] \in {"run_snap", "run_full"}) ~> (pc[c] = "done")

=============================================================================
