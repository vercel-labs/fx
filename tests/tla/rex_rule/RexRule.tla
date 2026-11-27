------------------------------- MODULE RexRule -------------------------------
(***************************************************************************)
(* The Rex resume rule: fx puts one require("fx") line into Rex's init.lua *)
(* and writes fx.lua, so Rex loads fx's rule, and takes both back out when *)
(* the user turns the setting off. Each fx process runs one attempt. The   *)
(* attempts share the same files and take turns on fx's lock file. At any  *)
(* moment the user can remove fx's line by hand, flip the setting, or edit *)
(* the user's own text, Rex can restart, and any process can crash at any  *)
(* step: the OS drops its lock and the files stay as they are.             *)
(*                                                                         *)
(* This models the code in src/core/rex_rule/ (plan.zig decide, apply.zig  *)
(* addRuleEdits, removeRuleEdits, rollback), not an earlier plan. Where    *)
(* the procedure left a choice open, the code's choice is used.            *)
(*                                                                         *)
(* Steps of one attempt, as the code runs them:                            *)
(*  - Setting on: take the lock, stop if gave_up, ask Rex and read init.lua *)
(*    and fx.lua (the observation), decide. Adding: write fx.lua, back up   *)
(*    init.lua, compare init.lua with the observation and write the line   *)
(*    in one atomic step, check, reload, verify.                           *)
(*  - Setting off: take the lock, observe, and do nothing unless fx's line  *)
(*    is there. Then back up, then compare with the observation and remove *)
(*    the line in one atomic step, check (the result is only logged),      *)
(*    delete fx.lua if                                                     *)
(*    the observation had it as ours, reload, clear added.                 *)
(*  - A compare that finds init.lua changed since the observation stops the *)
(*    attempt at once: nothing else changes (no rollback, added and fx.lua *)
(*    stay as they are), except fx.lua written by this attempt is deleted.  *)
(*  - A failed check or reload, or a verify that is not trusted, rolls back: *)
(*    take out the line this attempt wrote (never put one back), delete     *)
(*    fx.lua if this attempt created it, reload. Verify sets gave_up on     *)
(*    no_rule or untrusted, not on no answer.                              *)
(*                                                                         *)
(* Setting snapshot: the setting is read once, when the lock is taken, and *)
(* the branch stays fixed for the whole attempt. A flip affects only       *)
(* attempts that start later.                                              *)
(*                                                                         *)
(* Planted bugs (Mutant). Each one breaks the invariant named after it:    *)
(*  line-first       writes the line before fx.lua     NoDanglingRequire   *)
(*  rollback-order   deletes fx.lua before the line    NoDanglingRequire   *)
(*  no-lock          skips the lock                    OneWriter           *)
(*  ignore-removal   ignores added in the decision     NoReAddAfterRemoval *)
(*  double-line      appends the line without a check  AtMostOneLine       *)
(*  restore-backup   puts back the whole backup        UserTextKept        *)
(*                                                                         *)
(* Not modeled: user text that mentions fx, a foreign line, a missing      *)
(* init.lua, and a check that fails before the attempt starts.             *)
(***************************************************************************)
EXTENDS Naturals

CONSTANTS
    NProcs,  \* the number of fx processes: 2 or 3
    Mutant,  \* "none" or one planted bug, see the header
    Class    \* "ideal" or "nonideal", see the header

ASSUME NProcs \in {2, 3}
ASSUME Mutant \in {"none", "line-first", "rollback-order", "no-lock",
                   "ignore-removal", "double-line", "restore-backup"}
ASSUME Class \in {"ideal", "nonideal"}

Procs == 1..NProcs
NoOwner == 0
Texts == {"u1", "u2"}

Faults == Class = "nonideal"
Crashes == Class = "nonideal"
BoolChoice == IF Faults THEN {TRUE, FALSE} ELSE {TRUE}

Honors == Mutant /= "ignore-removal"
LineFirst == Mutant = "line-first"
RollbackBackward == Mutant = "rollback-order"
NoLock == Mutant = "no-lock"
DoubleLine == Mutant = "double-line"
RestoreWhole == Mutant = "restore-backup"

Idle == {"fresh", "done"}
Phases == {"fresh", "dec", "wfx", "bk", "cmp", "chk", "rld", "vfy",
           "rbR", "rbD", "rbL", "obk", "ocmp", "orm", "ochk", "odel", "orld",
           "oclr", "done"}
FirstAdd == IF LineFirst THEN "cmp" ELSE "wfx"
FirstRb == IF RollbackBackward THEN "rbD" ELSE "rbR"

VARIABLES
    owner,       \* the process holding fx's lock file, or NoOwner
    setting,     \* TRUE when the user turned the rule on
    pc,          \* [Procs -> Phases]: where each process is in its attempt
    created,     \* [Procs -> BOOLEAN]: this attempt created fx.lua
    seenUser,    \* [Procs -> Texts]: init.lua's user text at the observation
    seenLines,   \* [Procs -> 0..2]: fx's lines in init.lua at the observation
    userText,    \* the user's own text; only the user changes it
    fileUser,    \* the user's text now in init.lua
    lines,       \* how many fx require lines init.lua holds, 0 to 2
    fxLua,       \* "none", "ours", or "foreign"
    bkLines,     \* the backup copy of lines
    bkUser,      \* the backup copy of fileUser
    rexLoaded,   \* Rex loaded fx's rule at its last reload
    rexTrusted,  \* Rex trusts the rule it loaded
    added,       \* state.json: the rule was added
    gaveUp,      \* state.json: Rex untrusted the rule after an add
    stranded     \* ghost flag, see NoReAddAfterRemoval

vars == <<owner, setting, pc, created, seenUser, seenLines, userText, fileUser,
          lines, fxLua, bkLines, bkUser, rexLoaded, rexTrusted, added, gaveUp,
          stranded>>
vSeen == <<seenUser, seenLines>>
vFile == <<userText, fileUser, lines, fxLua>>
vText == <<userText, fileUser>>
vBk == <<bkLines, bkUser>>
vRex == <<rexLoaded, rexTrusted>>
vFlags == <<added, gaveUp, stranded, setting>>

Init ==
    /\ owner = NoOwner
    /\ setting \in BOOLEAN
    /\ pc = [p \in Procs |-> "fresh"]
    /\ created = [p \in Procs |-> FALSE]
    /\ seenUser = [p \in Procs |-> "u1"]
    /\ seenLines = [p \in Procs |-> 0]
    /\ userText \in Texts
    /\ fileUser = userText
    /\ \/ /\ fxLua = "none" /\ lines = 0
       \/ /\ fxLua = "foreign" /\ lines = 0
       \/ /\ fxLua = "ours" /\ lines \in {0, 1}
    /\ bkLines = 0
    /\ bkUser = userText
    /\ rexLoaded = FALSE
    /\ rexTrusted = FALSE
    /\ added = FALSE
    /\ gaveUp = FALSE
    /\ stranded = FALSE

RexRecord == IF ~rexLoaded THEN "no_rule" ELSE IF rexTrusted THEN "trusted" ELSE "untrusted"
RexAnswers == IF Faults THEN {RexRecord, "noanswer"} ELSE {RexRecord}

\* A reload: Rex loads init.lua and fx.lua as they are now.
ReloadTo(acc) ==
    /\ rexLoaded' = (lines > 0)
    /\ rexTrusted' = (lines > 0 /\ fxLua = "ours" /\ acc)

\* The decision, with the observation made in the same step (plan.zig decide).
Proceed(a) == (a = "no_rule") /\ fxLua /= "foreign" /\ ~(Honors /\ added /\ lines = 0)

\* init.lua changed since the observation: the compare fails.
Changed(p) == (fileUser /= seenUser[p]) \/ (lines /= seenLines[p])

\* The attempt ends. Its observation and its created flag are forgotten.
Finish(p) ==
    /\ pc' = [pc EXCEPT ![p] = "done"]
    /\ owner' = IF owner = p THEN NoOwner ELSE owner
    /\ created' = [created EXCEPT ![p] = FALSE]
    /\ seenUser' = [seenUser EXCEPT ![p] = "u1"]
    /\ seenLines' = [seenLines EXCEPT ![p] = 0]

\* Try the lock. Busy stops. gave_up stops (the lock is taken and dropped).
StopGaveUp(p) ==
    /\ pc[p] = "fresh" /\ setting /\ gaveUp
    /\ Finish(p)
    /\ UNCHANGED <<vFile, vBk, vRex, vFlags>>

Busy(p) ==
    /\ pc[p] = "fresh" /\ ~NoLock /\ owner /= NoOwner
    /\ Finish(p)
    /\ UNCHANGED <<vFile, vBk, vRex, vFlags>>

StartOn(p) ==
    /\ pc[p] = "fresh" /\ setting /\ ~gaveUp
    /\ (owner = NoOwner \/ NoLock)
    /\ owner' = IF NoLock THEN owner ELSE p
    /\ pc' = [pc EXCEPT ![p] = "dec"]
    /\ UNCHANGED <<created, vSeen, vFile, vBk, vRex, vFlags>>

\* The setting off. The observation is taken as the lock is taken. The attempt
\* does nothing unless fx's line is there.
StartOff(p) ==
    /\ pc[p] = "fresh" /\ ~setting
    /\ (owner = NoOwner \/ NoLock)
    /\ IF lines > 0
       THEN /\ owner' = IF NoLock THEN owner ELSE p
            /\ pc' = [pc EXCEPT ![p] = "obk"]
            /\ seenUser' = [seenUser EXCEPT ![p] = fileUser]
            /\ seenLines' = [seenLines EXCEPT ![p] = lines]
            /\ created' = created
            /\ UNCHANGED <<vFile, vBk, vRex, vFlags>>
       ELSE Finish(p) /\ UNCHANGED <<vFile, vBk, vRex, vFlags>>

\* Ask Rex, observe init.lua and fx.lua, decide. The check of the config
\* on the observed text is a decision input too.
Decide(p) ==
    /\ pc[p] = "dec"
    /\ \E a \in RexAnswers: \E ok \in BoolChoice:
        IF Proceed(a) /\ ok
        THEN /\ pc' = [pc EXCEPT ![p] = FirstAdd]
             /\ created' = [created EXCEPT ![p] = (fxLua = "none")]
             /\ seenUser' = [seenUser EXCEPT ![p] = fileUser]
             /\ seenLines' = [seenLines EXCEPT ![p] = lines]
             /\ owner' = owner
        ELSE Finish(p)
    /\ UNCHANGED <<vFile, vBk, vRex, vFlags>>

WriteFx(p) ==
    /\ pc[p] = "wfx"
    /\ fxLua' = "ours"
    /\ pc' = [pc EXCEPT ![p] = "bk"]
    /\ UNCHANGED <<owner, created, vSeen, vText, lines, vBk, vRex, vFlags>>

Backup(p) ==
    /\ pc[p] = "bk"
    /\ bkLines' = lines
    /\ bkUser' = fileUser
    /\ pc' = [pc EXCEPT ![p] = IF LineFirst THEN "chk" ELSE "cmp"]
    /\ UNCHANGED <<owner, created, vSeen, vText, lines, fxLua, vRex, vFlags>>

\* The compare and the atomic write of the line are one step. A user edit
\* since the observation stops the attempt with nothing else changed, except
\* that fx.lua this attempt created is deleted.
CompareWrite(p) ==
    /\ pc[p] = "cmp"
    /\ IF Changed(p)
       THEN /\ fxLua' = IF created[p] THEN "none" ELSE fxLua
            /\ Finish(p)
            /\ UNCHANGED <<userText, fileUser, lines, vBk, vRex, vFlags>>
       ELSE /\ lines' = IF DoubleLine THEN lines + 1 ELSE 1
            /\ pc' = [pc EXCEPT ![p] = IF LineFirst THEN "wfx" ELSE "chk"]
            /\ UNCHANGED <<owner, created, vSeen, vText, fxLua, vBk, vRex, vFlags>>

CheckPass(p) ==
    /\ pc[p] = "chk"
    /\ pc' = [pc EXCEPT ![p] = "rld"]
    /\ UNCHANGED <<owner, created, vSeen, vFile, vBk, vRex, vFlags>>

CheckFail(p) ==
    /\ pc[p] = "chk" /\ Faults
    /\ pc' = [pc EXCEPT ![p] = FirstRb]
    /\ UNCHANGED <<owner, created, vSeen, vFile, vBk, vRex, vFlags>>

Reload(p) ==
    /\ pc[p] = "rld"
    /\ \E acc \in BoolChoice: ReloadTo(acc)
    /\ pc' = [pc EXCEPT ![p] = "vfy"]
    /\ UNCHANGED <<owner, created, vSeen, vText, lines, fxLua, vBk, vFlags>>

\* A failed reload rolls back, as the code does.
ReloadFails(p) ==
    /\ pc[p] = "rld" /\ Faults
    /\ pc' = [pc EXCEPT ![p] = FirstRb]
    /\ UNCHANGED <<owner, created, vSeen, vFile, vBk, vRex, vFlags>>

Verify(p) ==
    /\ pc[p] = "vfy"
    /\ \E a \in RexAnswers:
        IF a = "trusted"
        THEN /\ added' = TRUE
             /\ Finish(p)
             /\ UNCHANGED <<gaveUp, stranded, setting, vFile, vBk, vRex>>
        ELSE /\ gaveUp' = (gaveUp \/ (a /= "noanswer"))
             /\ pc' = [pc EXCEPT ![p] = FirstRb]
             /\ UNCHANGED <<owner, created, vSeen, added, stranded, setting, vFile, vBk, vRex>>

\* Rollback, in order: take out the line this attempt wrote, delete fx.lua if
\* this attempt created it, reload. The planted order swaps the first two.
RbRestore(p) ==
    /\ pc[p] = "rbR"
    /\ lines' = IF RestoreWhole THEN bkLines ELSE IF bkLines = 0 THEN 0 ELSE lines
    /\ fileUser' = IF RestoreWhole THEN bkUser ELSE fileUser
    /\ pc' = [pc EXCEPT ![p] = IF RollbackBackward THEN "rbL" ELSE "rbD"]
    /\ UNCHANGED <<owner, created, vSeen, userText, fxLua, vBk, vRex, vFlags>>

RbDelete(p) ==
    /\ pc[p] = "rbD"
    /\ fxLua' = IF created[p] THEN "none" ELSE fxLua
    /\ pc' = [pc EXCEPT ![p] = IF RollbackBackward THEN "rbR" ELSE "rbL"]
    /\ UNCHANGED <<owner, created, vSeen, vText, lines, vBk, vRex, vFlags>>

RbReload(p) ==
    /\ pc[p] = "rbL"
    /\ \E acc \in BoolChoice: ReloadTo(acc)
    /\ Finish(p)
    /\ UNCHANGED <<vFile, vBk, vFlags>>

RbReloadFails(p) ==
    /\ pc[p] = "rbL" /\ Faults
    /\ Finish(p)
    /\ UNCHANGED <<vFile, vBk, vRex, vFlags>>

\* The setting off: back up, compare, remove the line, check, delete fx.lua
\* if the observation had it as ours, reload, clear added.
OffBackup(p) ==
    /\ pc[p] = "obk"
    /\ bkLines' = lines
    /\ bkUser' = fileUser
    /\ pc' = [pc EXCEPT ![p] = "ocmp"]
    /\ UNCHANGED <<owner, created, vSeen, vText, lines, fxLua, vRex, vFlags>>

\* The compare and the atomic removal are one step, as on the add path.
OffCompareRemove(p) ==
    /\ pc[p] = "ocmp"
    /\ IF Changed(p)
       THEN Finish(p) /\ UNCHANGED <<vFile, vBk, vRex, vFlags>>
       ELSE /\ lines' = 0
            /\ pc' = [pc EXCEPT ![p] = "ochk"]
            /\ UNCHANGED <<owner, created, vSeen, vText, fxLua, vBk, vRex, vFlags>>

\* The check after the removal is only logged by the code: no branch.
OffCheck(p) ==
    /\ pc[p] = "ochk"
    /\ pc' = [pc EXCEPT ![p] = "odel"]
    /\ UNCHANGED <<owner, created, vSeen, vText, lines, fxLua, vBk, vRex, vFlags>>

OffDelete(p) ==
    /\ pc[p] = "odel"
    /\ fxLua' = IF fxLua = "ours" THEN "none" ELSE fxLua
    /\ pc' = [pc EXCEPT ![p] = "orld"]
    /\ UNCHANGED <<owner, created, vSeen, vText, lines, vBk, vRex, vFlags>>

OffReload(p) ==
    /\ pc[p] = "orld"
    /\ \E acc \in BoolChoice: ReloadTo(acc)
    /\ pc' = [pc EXCEPT ![p] = "oclr"]
    /\ UNCHANGED <<owner, created, vSeen, vText, lines, fxLua, vBk, vFlags>>

OffReloadFails(p) ==
    /\ pc[p] = "orld" /\ Faults
    /\ pc' = [pc EXCEPT ![p] = "oclr"]
    /\ UNCHANGED <<owner, created, vSeen, vText, lines, fxLua, vBk, vRex, vFlags>>

OffClear(p) ==
    /\ pc[p] = "oclr"
    /\ added' = FALSE
    /\ Finish(p)
    /\ UNCHANGED <<gaveUp, stranded, setting, vFile, vBk, vRex>>

\* A crash releases the lock and forgets the attempt. The files stay.
Crash(p) ==
    /\ Crashes /\ pc[p] \notin Idle
    /\ Finish(p)
    /\ UNCHANGED <<vFile, vBk, vRex, vFlags>>

Step(p) ==
    \/ StopGaveUp(p) \/ Busy(p) \/ StartOn(p) \/ StartOff(p)
    \/ Decide(p) \/ WriteFx(p) \/ Backup(p) \/ CompareWrite(p)
    \/ CheckPass(p) \/ CheckFail(p) \/ Reload(p) \/ ReloadFails(p) \/ Verify(p)
    \/ RbRestore(p) \/ RbDelete(p) \/ RbReload(p) \/ RbReloadFails(p)
    \/ OffBackup(p) \/ OffCompareRemove(p) \/ OffCheck(p)
    \/ OffDelete(p) \/ OffReload(p) \/ OffReloadFails(p) \/ OffClear(p)
    \/ Crash(p)

\* The user removes one fx line by hand. If added is set, the removal is
\* stranded until the setting is flipped.
UserRemoveLine ==
    /\ lines > 0
    /\ lines' = lines - 1
    /\ stranded' = (stranded \/ added)
    /\ UNCHANGED <<owner, setting, pc, created, vSeen, vText, fxLua, vBk, vRex, added, gaveUp>>

\* The user flips the setting. The flip clears stranded (the user restated
\* the choice). It does not change which attempts add: see the handoff.
UserFlip ==
    /\ setting' = ~setting
    /\ stranded' = FALSE
    /\ UNCHANGED <<owner, pc, created, vSeen, vText, lines, fxLua, vBk, vRex, added, gaveUp>>

UserEdit ==
    /\ \E t \in Texts: (userText' = t /\ fileUser' = t)
    /\ UNCHANGED <<owner, setting, pc, created, vSeen, lines, fxLua, vBk, vRex, vFlags>>

\* Rex restarts and loads init.lua and fx.lua as they are now.
RexRestart ==
    /\ \E acc \in BoolChoice: ReloadTo(acc)
    /\ UNCHANGED <<owner, setting, pc, created, vSeen, vText, lines, fxLua, vBk, vFlags>>

Next ==
    \/ \E p \in Procs: Step(p)
    \/ UserRemoveLine
    \/ UserFlip
    \/ UserEdit
    \/ RexRestart

Spec == Init /\ [][Next]_vars

TypeOK ==
    /\ owner \in {NoOwner} \cup Procs
    /\ setting \in BOOLEAN
    /\ pc \in [Procs -> Phases]
    /\ created \in [Procs -> BOOLEAN]
    /\ seenUser \in [Procs -> Texts]
    /\ seenLines \in [Procs -> 0..2]
    /\ userText \in Texts
    /\ fileUser \in Texts
    /\ bkUser \in Texts
    /\ lines \in 0..2
    /\ bkLines \in 0..2
    /\ fxLua \in {"none", "ours", "foreign"}
    /\ rexLoaded \in BOOLEAN
    /\ rexTrusted \in BOOLEAN
    /\ added \in BOOLEAN
    /\ gaveUp \in BOOLEAN
    /\ stranded \in BOOLEAN

\* Whenever init.lua has fx's line, fx.lua is ours. Rex trusts nothing
\* when init.lua cannot load, so this holds in every state, crashes too.
NoDanglingRequire == lines > 0 => fxLua = "ours"

\* init.lua never holds fx's line twice.
AtMostOneLine == lines <= 1

\* fx never changes the user's own text in init.lua.
UserTextKept == fileUser = userText

\* Once the user removed the line while added was set, no attempt adds it
\* again, until the user flips the setting.
NoReAddAfterRemoval == ~(stranded /\ lines > 0)

\* At most one attempt is past the lock at a time.
OneWriter == \A p, q \in Procs: (p /= q) => ~(pc[p] \notin Idle /\ pc[q] \notin Idle)
=============================================================================
