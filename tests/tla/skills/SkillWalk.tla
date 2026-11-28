------------------------------ MODULE SkillWalk ------------------------------
(***************************************************************************)
(* The project skill walk: which folders fx scans for workspace skill      *)
(* roots, from the workspace up toward `/`                                 *)
(* (src/core/skills/skill_runtime.zig appendWorkspaceRoots).              *)
(*                                                                         *)
(* The folders from the top of the chain (0, which stands for `/`) down to *)
(* the workspace (depth) are numbered by depth. HOME is one of:            *)
(*                                                                         *)
(*   [kind |-> "at", pos |-> p]         folder p, at or above the          *)
(*                                      workspace                          *)
(*   [kind |-> "elsewhere", pos |-> 0]  not above the workspace, or unset  *)
(*   [kind |-> "prefix", pos |-> p]     a sibling of folder p whose path   *)
(*                                      is a string prefix of p's, such as *)
(*                                      /tmp/home beside /tmp/home2        *)
(*                                                                         *)
(* gits is the set of folders that hold a `.git` directory or file.        *)
(*                                                                         *)
(* Rule picks the walk. "fixed" is the design: with HOME above the         *)
(* workspace the walk stops before HOME as it always has, and otherwise it *)
(* stops after the nearest repository root, or at the workspace itself     *)
(* outside a repository. "today" is fx before it, where HOME was the only  *)
(* stop. Each "mutation-*" plants one defect; check.sh names the rule that *)
(* must catch it. SkillWalkTrace.tla checks runs of the built fx binary    *)
(* against this model; tests/tla/drivers/skills/driver.ts makes them.     *)
(***************************************************************************)
EXTENDS Integers, FiniteSets

CONSTANTS MaxDepth, Rule

Rules == {"fixed", "today", "mutation-no-workspace-stop",
          "mutation-farthest-repository", "mutation-stop-inside-home",
          "mutation-skip-repository-root", "mutation-string-prefix"}

ASSUME MaxDepth \in Nat \ {0} /\ Rule \in Rules

Homes(d) ==
    {[kind |-> "at", pos |-> p] : p \in 0..d}
        \cup {[kind |-> "elsewhere", pos |-> 0]}
        \cup {[kind |-> "prefix", pos |-> p] : p \in 1..d}

VARIABLES depth, home, gits, dir, scanned, done
vars == <<depth, home, gits, dir, scanned, done>>

Max(S) == CHOOSE x \in S : \A y \in S : y <= x
Min(S) == CHOOSE x \in S : \A y \in S : x <= y

\* HOME really is at or above the workspace.
HomeAbove == home.kind = "at"

\* Whether fx counts HOME as above the workspace. pathing.pathInside compares
\* whole path components; the string-prefix mutation compares characters.
SeesHomeAbove ==
    IF Rule = "mutation-string-prefix"
    THEN home.kind \in {"at", "prefix"}
    ELSE HomeAbove

\* The folder whose path equals HOME's: the walk breaks there before scanning.
IsHome(p) == home.kind = "at" /\ home.pos = p

\* The nearest repository root at or above the workspace.
Repository == Max(gits)

\* The last folder the walk scans, or -1 when only HOME and `/` end it.
LastDir ==
    IF Rule = "today" THEN -1
    ELSE IF SeesHomeAbove /\ Rule # "mutation-stop-inside-home" THEN -1
    ELSE IF gits # {}
         THEN IF Rule = "mutation-farthest-repository" THEN Min(gits) ELSE Repository
    ELSE IF Rule = "mutation-no-workspace-stop" THEN -1
    ELSE depth

InitWith(e) ==
    /\ depth = e.depth
    /\ home = e.home
    /\ gits = e.gits
    /\ dir = e.depth
    /\ scanned = {}
    /\ done = FALSE

Init ==
    \E d \in 1..MaxDepth :
        \E h \in Homes(d) :
            \E g \in SUBSET (0..d) :
                InitWith([depth |-> d, home |-> h, gits |-> g])

\* One pass of the loop at dir: break at HOME, scan dir, then stop at the last
\* folder or at `/`, or go on to the parent.
Walk ==
    /\ ~done
    /\ IF IsHome(dir)
       THEN /\ done' = TRUE
            /\ UNCHANGED <<dir, scanned>>
       ELSE IF Rule = "mutation-skip-repository-root" /\ gits # {} /\ dir = LastDir
       THEN /\ done' = TRUE
            /\ UNCHANGED <<dir, scanned>>
       ELSE /\ scanned' = scanned \cup {dir}
            /\ IF dir = LastDir \/ dir = 0
               THEN /\ done' = TRUE
                    /\ UNCHANGED dir
               ELSE /\ dir' = dir - 1
                    /\ UNCHANGED done
    /\ UNCHANGED <<depth, home, gits>>

Finished == done /\ UNCHANGED vars

Next == Walk \/ Finished

Spec == Init /\ [][Next]_vars /\ WF_vars(Walk)

TypeOK ==
    /\ depth \in 1..MaxDepth
    /\ home \in Homes(depth)
    /\ gits \subseteq 0..depth
    /\ dir \in 0..depth
    /\ scanned \subseteq 0..depth
    /\ done \in BOOLEAN

\* Where the walk must end when HOME is not above the workspace.
Boundary == IF gits # {} THEN Repository ELSE depth

\* Outside HOME, no folder above the nearest repository root is scanned, nor
\* any folder above the workspace outside a repository.
NoSkillAboveBoundary ==
    done /\ ~HomeAbove => \A p \in scanned : p >= Boundary

\* Outside HOME, every folder from the workspace up to that boundary is
\* scanned, so the repository's own skills keep loading.
RepositoryLoaded ==
    done /\ ~HomeAbove => Boundary..depth \subseteq scanned

\* With HOME at or above the workspace, the walk is unchanged: every folder
\* below HOME, and nothing at or above it.
InsideHomeUnchanged ==
    done /\ HomeAbove => scanned = {p \in 0..depth : p > home.pos}

\* Every walk ends.
Terminates == <>done
=============================================================================
