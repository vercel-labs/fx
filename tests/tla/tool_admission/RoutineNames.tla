---------------------------- MODULE RoutineNames ----------------------------
(***************************************************************************)
(* Auto mode's routine-command lane for `user` profile shell commands      *)
(* (resolveOrdinaryPermissionOutcome in src/core/tooling/tool_admission.zig)*)
(* against the shell snapshot owner (Owner in                              *)
(* src/core/terminal/shell_snapshot.zig) and the run that follows          *)
(* (executeWithSnapshot in src/core/execution/command_runner.zig).         *)
(*                                                                          *)
(* A routine command such as `git status` runs without review. An alias or *)
(* function in the startup files can redefine its word, so a routine       *)
(* command may skip review only when fx knows the names it will run with.  *)
(* Admission captures the snapshot first when there is none or the startup *)
(* files changed, and sends the command to review when a word is           *)
(* redefined, the capture failed, or the call reloads the startup files.   *)
(* A routine approval carries the epoch of the generation it checked, and  *)
(* the run refuses it under any other epoch, including the full-startup    *)
(* rerun after a failed replay.                                            *)
(*                                                                          *)
(* A generation whose startup files move ZDOTDIR to a folder that fx's own *)
(* environment does not name carries that folder's file stamps in its      *)
(* fingerprint. The owner's failed state compares fingerprints without     *)
(* them, so after such a generation fails, the failed state reports a      *)
(* change that no edit made (failedExt). The bound approval re-checks the  *)
(* startup files after a failed replay, and that check must run while the  *)
(* owner still holds the generation, or it refuses a command whose files   *)
(* did not change (NoFalseRefusal). A second command whose replay fails    *)
(* after the first one failed the generation still meets the failed        *)
(* state's comparison; the model leaves that case out of NoFalseRefusal,   *)
(* because only a failed state that compares with the moved ZDOTDIR's      *)
(* stamps removes it.                                                      *)
(*                                                                          *)
(* One routine word, git, can be aliased. "nonroutine" commands, such as   *)
(* `echo warm` or an edit of the startup files, always go to review; an    *)
(* edit is the command's effect when it runs. Edit and UserReload are       *)
(* changes from outside the commands: another agent, the user's editor,    *)
(* or /shell reload. The reviewer may clear or hold any reviewed command.  *)
(*                                                                          *)
(* Design picks the rule:                                                  *)
(*   "fixed"              the rule above;                                  *)
(*   "main"               fx before it: admission reads the generation     *)
(*                        already there, captured or not, fresh or not,    *)
(*                        and only a failed capture counts as unknown;     *)
(*   "late_check"         the fixed rule, except that the rerun after a    *)
(*                        failed replay checks the startup files after the *)
(*                        owner failed the generation, as fx did before    *)
(*                        the moved-ZDOTDIR repair;                        *)
(*   "review_unknown"     the alternative: no capture at admission, and    *)
(*                        an empty or stale snapshot goes to review;       *)
(* and each planted bug breaks one part of the fixed rule:                 *)
(*   "unbound"            a routine approval carries no epoch;             *)
(*   "reload_routine"     a call that reloads still takes the routine lane;*)
(*   "failed_clear"       a failed capture counts as clear;                *)
(*   "fallback_unchecked" the rerun after a failed replay skips the check; *)
(*   "capture_again"      the run captures again after admission did;      *)
(*   "moved_unchecked"    the rerun after a failed replay skips the check  *)
(*                        when the startup files moved ZDOTDIR.            *)
(*                                                                          *)
(* The startup files are re-read only by a capture and by a full-startup   *)
(* run, each atomic here. A change between fx's last check and the moment  *)
(* a full-startup shell reads the files is not modeled: no rule can close  *)
(* it, and such runs are reviewed unless they rerun a failed replay.       *)
(***************************************************************************)
EXTENDS Integers, FiniteSets, TLC

CONSTANTS Cmds, MaxEdits, MaxReloads, MaxFails, MaxGen, Design

Designs == {"fixed", "main", "review_unknown", "late_check", "unbound", "reload_routine",
            "failed_clear", "fallback_unchecked", "capture_again", "moved_unchecked"}
ASSUME Design \in Designs
ASSUME MaxGen \in Nat \ {0}

Gens     == 1..MaxGen
NoGen    == 0
NoBind   == -1
Kinds    == {"git", "nonroutine"}
Effects  == {"none", "alias_on", "alias_off"}
PcStates == {"idle", "admitting", "reviewing", "approved", "running", "replaying", "done"}
Outcomes == {"none", "alias", "real", "refused", "held", "cancelled"}

VARIABLES
    aliased,      \* the startup files on disk define git
    fver,         \* their fingerprint, bumped by every edit
    everAliased,  \* they have defined git at some point
    edits,        \* edits from outside the commands
    moved,        \* the startup files set ZDOTDIR to a folder fx's environment does not name
    owner,        \* "empty" | "capturing" | "ready" | "failed"
    dirty,        \* a refresh is pending
    epoch,        \* approval epoch, bumped by every accepted refresh trigger
    active,       \* the ready generation, or NoGen
    capGen,       \* the generation being captured, or NoGen
    nextGen,
    genEpoch,     \* epoch each generation was captured under
    genAliased,   \* each generation defines git
    genFver,      \* fingerprint taken when each capture started
    capFver,      \* fingerprint taken when the running capture started
    capAliased,   \* whether the files defined git when it started
    failedFver,   \* fingerprint the failed state compares against
    failedExt,    \* it holds a moved ZDOTDIR's stamps, which the failed state's comparison drops
    captures,     \* captures started: each runs the startup files once
    triggers,     \* refresh triggers accepted
    fails,        \* failed captures and failed replays
    reloads,      \* /shell reloads
    pc,
    kind,
    reload,       \* the call asks to reload the startup files
    effect,       \* what the command does to the startup files when it runs
    auth,         \* "none" | "routine" | "review"
    bound,        \* epoch a routine approval was bound to, or NoBind
    cgen,         \* generation a running command leased
    outcome,
    trigAtAdmit,  \* triggers when the routine approval was made
    ownTrig,      \* 1 when the command's own reload was a trigger
    recaptured,   \* capture_again: the run already forced its capture
    falseAlarm    \* the check after this command's failed replay noted a change no edit made

fileVars  == <<aliased, fver, everAliased, edits, moved>>
ownerVars == <<owner, dirty, epoch, active, capGen, nextGen, genEpoch, genAliased,
               genFver, capFver, capAliased, failedFver, failedExt, captures, triggers, fails,
               reloads>>
cmdVars   == <<pc, kind, reload, effect, auth, bound, cgen, outcome, trigAtAdmit,
               ownTrig, recaptured, falseAlarm>>
vars      == <<fileVars, ownerVars, cmdVars>>

TypeOK ==
    /\ aliased \in BOOLEAN /\ everAliased \in BOOLEAN
    /\ fver \in Nat /\ edits \in Nat /\ moved \in BOOLEAN
    /\ owner \in {"empty", "capturing", "ready", "failed"}
    /\ dirty \in BOOLEAN /\ epoch \in Nat
    /\ active \in 0..MaxGen /\ capGen \in 0..MaxGen /\ nextGen \in 1..(MaxGen + 1)
    /\ genEpoch \in [Gens -> Nat] /\ genAliased \in [Gens -> BOOLEAN]
    /\ genFver \in [Gens -> Nat] /\ capFver \in Nat /\ capAliased \in BOOLEAN
    /\ failedFver \in Nat /\ failedExt \in BOOLEAN
    /\ captures \in Nat /\ triggers \in Nat /\ fails \in Nat /\ reloads \in Nat
    /\ pc \in [Cmds -> PcStates]
    /\ kind \in [Cmds -> Kinds]
    /\ reload \in [Cmds -> BOOLEAN]
    /\ effect \in [Cmds -> Effects]
    /\ auth \in [Cmds -> {"none", "routine", "review"}]
    /\ bound \in [Cmds -> {NoBind} \cup Nat]
    /\ cgen \in [Cmds -> 0..MaxGen]
    /\ outcome \in [Cmds -> Outcomes]
    /\ trigAtAdmit \in [Cmds -> Nat] /\ ownTrig \in [Cmds -> 0..1]
    /\ recaptured \in [Cmds -> BOOLEAN]
    /\ falseAlarm \in [Cmds -> BOOLEAN]

\* A process starts with no snapshot; `start` says whether its startup files
\* already define git, and `move` whether they set ZDOTDIR to a folder fx's
\* own environment does not name.
InitWith(start, move) ==
    /\ aliased = start /\ fver = 0 /\ everAliased = start /\ edits = 0
    /\ moved = move
    /\ owner = "empty" /\ dirty = FALSE /\ epoch = 0
    /\ active = NoGen /\ capGen = NoGen /\ nextGen = 1
    /\ genEpoch = [g \in Gens |-> 0] /\ genAliased = [g \in Gens |-> FALSE]
    /\ genFver = [g \in Gens |-> 0] /\ capFver = 0 /\ capAliased = FALSE
    /\ failedFver = 0 /\ failedExt = FALSE
    /\ captures = 0 /\ triggers = 0 /\ fails = 0 /\ reloads = 0
    /\ pc = [c \in Cmds |-> "idle"]
    /\ kind = [c \in Cmds |-> "git"]
    /\ reload = [c \in Cmds |-> FALSE]
    /\ effect = [c \in Cmds |-> "none"]
    /\ auth = [c \in Cmds |-> "none"]
    /\ bound = [c \in Cmds |-> NoBind]
    /\ cgen = [c \in Cmds |-> NoGen]
    /\ outcome = [c \in Cmds |-> "none"]
    /\ trigAtAdmit = [c \in Cmds |-> 0]
    /\ ownTrig = [c \in Cmds |-> 0]
    /\ recaptured = [c \in Cmds |-> FALSE]
    /\ falseAlarm = [c \in Cmds |-> FALSE]

Init == \E start \in BOOLEAN, move \in BOOLEAN : InitWith(start, move)

-----------------------------------------------------------------------------
(* The owner's decision, made under its mutex: note startup-file changes    *)
(* (noteChangesLocked), then lease, fall back, start the capture, or wait   *)
(* (decideLocked). checkStartupFiles is the note alone.                     *)

Changed ==
    /\ ~dirty
    /\ \/ owner = "ready" /\ fver # genFver[active]
       \/ owner = "failed" /\ (fver # failedFver \/ failedExt)

NotedDirty    == dirty \/ Changed
NotedEpoch    == IF Changed THEN epoch + 1 ELSE epoch
NotedTriggers == IF Changed THEN triggers + 1 ELSE triggers

CanLease    == owner = "ready" /\ ~NotedDirty
CanFull     == owner = "failed" /\ ~NotedDirty
MustCapture == owner = "empty" \/ (owner \in {"ready", "failed"} /\ NotedDirty)

ApplyNote ==
    /\ dirty' = NotedDirty
    /\ epoch' = NotedEpoch
    /\ triggers' = NotedTriggers

\* startCaptureLocked, after the note. The fingerprint is taken before the
\* shell reads the files.
StartCapture ==
    /\ nextGen <= MaxGen
    /\ owner' = "capturing"
    /\ capGen' = nextGen
    /\ nextGen' = nextGen + 1
    /\ genEpoch' = [genEpoch EXCEPT ![nextGen] = NotedEpoch]
    /\ capFver' = fver
    /\ capAliased' = aliased
    /\ dirty' = FALSE
    /\ epoch' = NotedEpoch
    /\ triggers' = NotedTriggers
    /\ captures' = captures + 1

UnchangedCapture == UNCHANGED <<owner, capGen, nextGen, genEpoch, capFver, capAliased, captures>>

\* The command's own edit of the startup files, when it runs.
RunEffect(c) ==
    IF effect[c] = "none"
    THEN UNCHANGED <<aliased, fver, everAliased>>
    ELSE /\ aliased' = (effect[c] = "alias_on")
         /\ fver' = fver + 1
         /\ everAliased' = (everAliased \/ effect[c] = "alias_on")

Finish(c, result) ==
    /\ pc' = [pc EXCEPT ![c] = "done"]
    /\ outcome' = [outcome EXCEPT ![c] = result]

-----------------------------------------------------------------------------
(* Admission. checkStartupFiles runs for every shell call first.            *)

Review(c) ==
    /\ auth' = [auth EXCEPT ![c] = "review"]
    /\ pc' = [pc EXCEPT ![c] = "reviewing"]

Routine(c, epochBound) ==
    /\ auth' = [auth EXCEPT ![c] = "routine"]
    /\ bound' = [bound EXCEPT ![c] = epochBound]
    /\ trigAtAdmit' = [trigAtAdmit EXCEPT ![c] = NotedTriggers]
    /\ pc' = [pc EXCEPT ![c] = "approved"]

Admit(c, k, r, e) ==
    /\ pc[c] = "idle"
    /\ k \in Kinds /\ r \in BOOLEAN /\ e \in Effects
    /\ k = "git" => e = "none"
    /\ kind' = [kind EXCEPT ![c] = k]
    /\ reload' = [reload EXCEPT ![c] = r]
    /\ effect' = [effect EXCEPT ![c] = e]
    /\ ApplyNote
    /\ CASE k = "nonroutine" ->
              Review(c) /\ UNCHANGED <<bound, trigAtAdmit>>
         [] Design = "main" ->
              \* fx before the fix read whatever generation was active and
              \* counted only a failed capture as unknown.
              IF owner = "failed" \/ (active # NoGen /\ genAliased[active])
              THEN Review(c) /\ UNCHANGED <<bound, trigAtAdmit>>
              ELSE Routine(c, NoBind)
         [] Design = "review_unknown" ->
              IF ~r /\ CanLease /\ ~genAliased[active]
              THEN Routine(c, genEpoch[active])
              ELSE Review(c) /\ UNCHANGED <<bound, trigAtAdmit>>
         [] OTHER ->
              IF r /\ Design # "reload_routine"
              THEN Review(c) /\ UNCHANGED <<bound, trigAtAdmit>>
              ELSE pc' = [pc EXCEPT ![c] = "admitting"] /\ UNCHANGED <<auth, bound, trigAtAdmit>>
    /\ UNCHANGED <<fileVars, owner, active, capGen, nextGen, genEpoch, genAliased, genFver,
                   capFver, capAliased, failedFver, failedExt, captures, fails, reloads,
                   cgen, outcome, ownTrig, recaptured, falseAlarm>>

\* checkCommandNames: the routine check waits for a capture when there is
\* no snapshot or the files changed, then reads the generation it leased.
AdmitDecide(c) ==
    /\ pc[c] = "admitting"
    /\ \/ /\ CanLease
          /\ ApplyNote
          /\ IF genAliased[active]
             THEN Review(c) /\ UNCHANGED <<bound, trigAtAdmit>>
             ELSE Routine(c, IF Design = "unbound" THEN NoBind ELSE genEpoch[active])
          /\ UnchangedCapture
       \/ /\ CanFull
          /\ ApplyNote
          /\ IF Design = "failed_clear"
             THEN Routine(c, NotedEpoch)
             ELSE Review(c) /\ UNCHANGED <<bound, trigAtAdmit>>
          /\ UnchangedCapture
       \/ /\ MustCapture
          /\ StartCapture
          /\ UNCHANGED <<pc, auth, bound, trigAtAdmit>>
    /\ UNCHANGED <<fileVars, active, genAliased, genFver, failedFver, failedExt, fails, reloads,
                   kind, reload, effect, cgen, outcome, ownTrig, recaptured, falseAlarm>>

\* The turn is cancelled while admission waits; the shared capture goes on.
AdmitCancel(c) ==
    /\ pc[c] = "admitting"
    /\ Finish(c, "cancelled")
    /\ UNCHANGED <<fileVars, ownerVars, kind, reload, effect, auth, bound, cgen,
                   trigAtAdmit, ownTrig, recaptured, falseAlarm>>

\* The reviewer clears or holds the exact action.
Reviewed(c, clear) ==
    /\ pc[c] = "reviewing"
    /\ clear \in BOOLEAN
    /\ IF clear
       THEN pc' = [pc EXCEPT ![c] = "approved"] /\ UNCHANGED outcome
       ELSE Finish(c, "held")
    /\ UNCHANGED <<fileVars, ownerVars, kind, reload, effect, auth, bound, cgen,
                   trigAtAdmit, ownTrig, recaptured, falseAlarm>>

-----------------------------------------------------------------------------
(* The run. A reload marks the snapshot dirty first (shell.zig callRun).    *)

StartRun(c) ==
    /\ pc[c] = "approved"
    /\ pc' = [pc EXCEPT ![c] = "running"]
    /\ IF reload[c] /\ ~dirty
       THEN /\ dirty' = TRUE
            /\ epoch' = epoch + 1
            /\ triggers' = triggers + 1
            /\ ownTrig' = [ownTrig EXCEPT ![c] = 1]
       ELSE UNCHANGED <<dirty, epoch, triggers, ownTrig>>
    /\ UNCHANGED <<fileVars, owner, active, capGen, nextGen, genEpoch, genAliased, genFver,
                   capFver, capAliased, failedFver, failedExt, captures, fails, reloads,
                   kind, reload, effect, auth, bound, cgen, outcome, trigAtAdmit, recaptured,
                   falseAlarm>>

StaleBinding(c, e) == bound[c] # NoBind /\ bound[c] # e

\* executeWithSnapshot's acquire, then the epoch check.
RunDecide(c) ==
    /\ pc[c] = "running"
    /\ \/ /\ Design = "capture_again" /\ auth[c] = "routine" /\ ~recaptured[c]
          /\ owner # "capturing"
          /\ StartCapture
          /\ recaptured' = [recaptured EXCEPT ![c] = TRUE]
          /\ UNCHANGED <<fileVars, pc, outcome, cgen>>
       \/ /\ ~(Design = "capture_again" /\ auth[c] = "routine" /\ ~recaptured[c])
          /\ \/ /\ CanLease
                /\ ApplyNote
                /\ IF StaleBinding(c, genEpoch[active])
                   THEN Finish(c, "refused") /\ UNCHANGED cgen
                   ELSE /\ pc' = [pc EXCEPT ![c] = "replaying"]
                        /\ cgen' = [cgen EXCEPT ![c] = active]
                        /\ UNCHANGED outcome
                /\ UnchangedCapture
                /\ UNCHANGED fileVars
             \/ /\ CanFull
                /\ ApplyNote
                /\ IF StaleBinding(c, NotedEpoch)
                   THEN Finish(c, "refused") /\ UNCHANGED fileVars
                   ELSE Finish(c, IF kind[c] = "git" /\ aliased THEN "alias" ELSE "real")
                        /\ RunEffect(c) /\ UNCHANGED <<edits, moved>>
                /\ UnchangedCapture
                /\ UNCHANGED cgen
             \/ /\ MustCapture
                /\ StartCapture
                /\ UNCHANGED <<fileVars, pc, outcome, cgen>>
          /\ UNCHANGED recaptured
    /\ UNCHANGED <<active, genAliased, genFver, failedFver, failedExt, fails, reloads,
                   kind, reload, effect, auth, bound, trigAtAdmit, ownTrig, falseAlarm>>

\* The restored shell runs the command with the generation's names.
Replay(c) ==
    /\ pc[c] = "replaying"
    /\ Finish(c, IF kind[c] = "git" /\ genAliased[cgen[c]] THEN "alias" ELSE "real")
    /\ RunEffect(c)
    /\ UNCHANGED <<edits, moved, ownerVars, kind, reload, effect, auth, bound, cgen,
                   trigAtAdmit, ownTrig, recaptured, falseAlarm>>

\* The restored shell rejected the replay before the command started. The
\* owner fails the generation if it still holds it (markReplayFailed); the
\* command reruns once with full startup, which reads the files as they are.
\* A bound approval checks the files again first (checkStartupFiles), while
\* the owner still holds the generation: its own fingerprint, with the moved
\* ZDOTDIR's stamps, is what the files are compared with. Design
\* "late_check" checks after the owner failed it, and the failed state's
\* comparison drops those stamps.
ReplayFail(c) ==
    /\ pc[c] = "replaying"
    /\ fails < MaxFails
    /\ LET g       == cgen[c]
           holds   == owner = "ready" /\ active = g
           owner2  == IF holds THEN "failed" ELSE owner
           ffver2  == IF holds THEN genFver[g] ELSE failedFver
           fext2   == IF holds THEN moved ELSE failedExt
           check   == /\ bound[c] # NoBind
                      /\ Design \notin {"main", "fallback_unchecked"}
                      /\ ~(Design = "moved_unchecked" /\ moved)
           \* The files differ from what the owner compared them with.
           edited  == /\ ~dirty
                      /\ \/ owner2 = "ready" /\ fver # genFver[active]
                         \/ owner2 = "failed" /\ fver # ffver2
           \* What noteChangesLocked reports in the state the check runs in.
           noted   == IF Design = "late_check"
                      THEN edited \/ (~dirty /\ owner2 = "failed" /\ fext2)
                      ELSE Changed
           epoch2  == IF check /\ noted THEN epoch + 1 ELSE epoch
       IN  /\ owner' = owner2
           /\ active' = IF holds THEN NoGen ELSE active
           /\ failedFver' = ffver2
           /\ failedExt' = fext2
           /\ fails' = fails + 1
           /\ dirty' = (dirty \/ (check /\ noted))
           /\ epoch' = epoch2
           /\ triggers' = IF check /\ noted THEN triggers + 1 ELSE triggers
           /\ falseAlarm' = [falseAlarm EXCEPT ![c] = holds /\ check /\ noted /\ ~edited]
           /\ IF check /\ StaleBinding(c, epoch2)
              THEN Finish(c, "refused") /\ UNCHANGED <<aliased, fver, everAliased>>
              ELSE Finish(c, IF kind[c] = "git" /\ aliased THEN "alias" ELSE "real")
                   /\ RunEffect(c)
    /\ UNCHANGED <<edits, moved, capGen, nextGen, genEpoch, genAliased, genFver, capFver, capAliased,
                   captures, reloads, kind, reload, effect, auth, bound, cgen,
                   trigAtAdmit, ownTrig, recaptured>>

-----------------------------------------------------------------------------
(* The capture thread.                                                      *)

\* The shell reads the files at some point during the capture, so an edit
\* made while it runs may or may not be in the result. The fingerprint from
\* before the capture makes such an edit dirty the result either way.
CaptureOk ==
    /\ owner = "capturing"
    /\ \E seen \in {capAliased, aliased} :
          genAliased' = [genAliased EXCEPT ![capGen] = seen]
    /\ owner' = "ready"
    /\ active' = capGen
    /\ capGen' = NoGen
    /\ genFver' = [genFver EXCEPT ![capGen] = capFver]
    /\ UNCHANGED <<fileVars, dirty, epoch, nextGen, genEpoch, capFver, capAliased, failedFver,
                   failedExt, captures, triggers, fails, reloads, cmdVars>>

\* The failed state keeps the fingerprint taken when the capture started,
\* before the shell could move ZDOTDIR.
CaptureFail ==
    /\ owner = "capturing"
    /\ fails < MaxFails
    /\ owner' = "failed"
    /\ active' = NoGen
    /\ capGen' = NoGen
    /\ failedFver' = capFver
    /\ failedExt' = FALSE
    /\ fails' = fails + 1
    /\ UNCHANGED <<fileVars, dirty, epoch, nextGen, genEpoch, genAliased, genFver, capFver,
                   capAliased, captures, triggers, reloads, cmdVars>>

-----------------------------------------------------------------------------
(* Changes from outside the commands.                                       *)

Edit(v) ==
    /\ edits < MaxEdits
    /\ v \in BOOLEAN
    /\ aliased' = v
    /\ fver' = fver + 1
    /\ everAliased' = (everAliased \/ v)
    /\ edits' = edits + 1
    /\ UNCHANGED <<moved, ownerVars, cmdVars>>

\* /shell reload, or another agent's reload=true.
UserReload ==
    /\ reloads < MaxReloads
    /\ ~dirty
    /\ dirty' = TRUE
    /\ epoch' = epoch + 1
    /\ triggers' = triggers + 1
    /\ reloads' = reloads + 1
    /\ UNCHANGED <<fileVars, owner, active, capGen, nextGen, genEpoch, genAliased, genFver,
                   capFver, capAliased, failedFver, failedExt, captures, fails, cmdVars>>

Done ==
    /\ \A c \in Cmds : pc[c] = "done"
    /\ UNCHANGED vars

CmdStep(c) ==
    \/ \E k \in Kinds, r \in BOOLEAN, e \in Effects : Admit(c, k, r, e)
    \/ AdmitDecide(c)
    \/ AdmitCancel(c)
    \/ \E clear \in BOOLEAN : Reviewed(c, clear)
    \/ StartRun(c)
    \/ RunDecide(c)
    \/ Replay(c)
    \/ ReplayFail(c)

Next ==
    \/ \E c \in Cmds : CmdStep(c)
    \/ CaptureOk
    \/ CaptureFail
    \/ \E v \in BOOLEAN : Edit(v)
    \/ UserReload
    \/ Done

Fairness ==
    /\ WF_vars(CaptureOk \/ CaptureFail)
    /\ \A c \in Cmds :
          /\ WF_vars(AdmitDecide(c))
          /\ WF_vars(\E clear \in BOOLEAN : Reviewed(c, clear))
          /\ WF_vars(StartRun(c))
          /\ WF_vars(RunDecide(c))
          /\ WF_vars(Replay(c) \/ ReplayFail(c))

Spec       == Init /\ [][Next]_vars /\ Fairness
SafetySpec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
(* What the rule promises.                                                  *)

\* A command that ran with git redefined was reviewed first.
NoUnreviewedAlias == \A c \in Cmds : outcome[c] = "alias" => auth[c] = "review"

\* A routine git command is reviewed only when the startup files have
\* defined git, a capture or replay failed, or the call reloads.
ZeroReview ==
    \A c \in Cmds :
        (kind[c] = "git" /\ auth[c] = "review") => (everAliased \/ fails > 0 \/ reload[c])

\* The startup files run once, plus once per refresh: admission and the run
\* share one capture.
CapturesBounded == captures <= 1 + triggers

\* A routine approval is refused only when something other than the call
\* itself refreshed the snapshot after admission.
RefusedOnlyAfterRefresh ==
    \A c \in Cmds :
        outcome[c] = "refused" => triggers - ownTrig[c] > trigAtAdmit[c]

\* A failed replay refuses a bound approval only when the startup files
\* changed, whether or not they set ZDOTDIR to a folder fx's environment does
\* not name.
NoFalseRefusal == \A c \in Cmds : outcome[c] = "refused" => ~falseAlarm[c]

\* Every command that starts finishes.
EveryCommandFinishes == \A c \in Cmds : (pc[c] # "idle") ~> (pc[c] = "done")

=============================================================================
