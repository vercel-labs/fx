---------------------------- MODULE WorkspaceTrust ----------------------------
(***************************************************************************)
(* Workspace trust prompt and persistence model for fx (code not yet       *)
(* landed).                                                                *)
(*                                                                         *)
(* Models two concurrent launches across TUI and headless surfaces in a    *)
(* main repository, a git worktree sharing that repository's trust key,    *)
(* and the home folder (which always asks and is never saved).             *)
(*                                                                         *)
(* Design = "current" has no trust prompt. Design = "a" gates TUI sessions *)
(* behind consent and lets headless launches load repo content as fx does  *)
(* today. Design = "b" also guards repo content loading on trust = TRUE.   *)
(* Mutant plants a single defect to verify each invariant catches it.      *)
(***************************************************************************)
EXTENDS FiniteSets, TLC

CONSTANTS
  Design,  \* "current" | "a" | "b"
  Mutant,  \* "none" | "skip_check" | "save_on_no" | "save_home" | "headless_prompt" | "lost_write" | "headless_content" | "trust_spoof"
  Class    \* "all" | "ideal" | "nonideal"

ASSUME Design \in {"current", "a", "b"}
ASSUME Mutant \in {"none", "skip_check", "save_on_no", "save_home", "headless_prompt", "lost_write", "headless_content", "trust_spoof"}
ASSUME Class \in {"all", "ideal", "nonideal"}

VARIABLES
  store,      \* Saved trust record: [Keys -> {"unknown", "trusted"}]
  ln,         \* Per-launch state record
  yesKeys,    \* Ghost: keys a Yes answer was given for
  initStore   \* Ghost snapshot of initial store for InitiallyTrusted

vars == <<store, ln, yesKeys, initStore>>

Folders == {"repo", "worktree", "spoof", "home"}
Keys == {"repo", "spoof", "home"}
\* A spoofed folder names a trusted repository's worktree that the repository never registered, so fx keys it by its own path.
TrueKey(f) ==
  CASE f \in {"repo", "worktree"} -> "repo"
    [] f = "spoof" -> "spoof"
    [] OTHER -> "home"
Key(f) == IF Mutant = "trust_spoof" /\ f = "spoof" THEN "repo" ELSE TrueKey(f)
Launches == {1, 2}
Surfaces == {"tui", "headless"}

Init ==
  /\ store \in [Keys -> {"unknown", "trusted"}]
  /\ store["home"] = "unknown"
  /\ initStore = store
  /\ ln \in [Launches ->
       [surface: Surfaces,
        folder: Folders,
        phase: {"start"},
        yes: {FALSE},
        trust: {FALSE},
        repo: {FALSE},
        notice: {FALSE}]]
  /\ yesKeys = {}

Decide(l) ==
  /\ ln[l].phase = "start"
  /\ LET cur == ln[l]
         trusted == store[Key(cur.folder)] = "trusted"
     IN IF Design = "current" THEN
          ln' = [ln EXCEPT ![l].phase = "running"]
        ELSE IF cur.surface = "tui" THEN
          IF cur.folder # "home" /\ trusted THEN
            ln' = [ln EXCEPT ![l].phase = "running", ![l].trust = TRUE]
          ELSE IF Mutant = "skip_check" THEN
            ln' = [ln EXCEPT ![l].phase = "running", ![l].trust = FALSE]
          ELSE
            ln' = [ln EXCEPT ![l].phase = "asking"]
        ELSE
          IF Mutant = "headless_prompt" THEN
            ln' = [ln EXCEPT ![l].phase = "asking"]
          ELSE
            ln' = [ln EXCEPT ![l].phase = "running", ![l].trust = trusted]
  /\ UNCHANGED <<store, yesKeys, initStore>>

AnswerYes(l) ==
  /\ ln[l].phase = "asking"
  /\ LET cur == ln[l]
         k == Key(cur.folder)
         shouldSave == cur.folder # "home" \/ Mutant = "save_home"
     IN IF ~shouldSave THEN
          /\ ln' = [ln EXCEPT ![l].phase = "running",
                              ![l].yes = TRUE,
                              ![l].trust = TRUE]
          /\ UNCHANGED <<store, yesKeys, initStore>>
        ELSE
          /\ \/ /\ store' = [store EXCEPT ![k] = "trusted"]
                /\ yesKeys' = yesKeys \cup {k}
                /\ ln' = [ln EXCEPT ![l].phase = "running",
                                    ![l].yes = TRUE,
                                    ![l].trust = TRUE]
             \/ /\ Class \in {"nonideal", "all"}
                /\ ln' = [ln EXCEPT ![l].phase = "running",
                                    ![l].yes = TRUE,
                                    ![l].trust = TRUE,
                                    ![l].notice = (Mutant # "lost_write")]
                /\ UNCHANGED <<store, yesKeys>>
          /\ UNCHANGED initStore

AnswerNo(l) ==
  /\ ln[l].phase = "asking"
  /\ ln' = [ln EXCEPT ![l].phase = "exited"]
  /\ IF Mutant = "save_on_no"
       THEN store' = [store EXCEPT ![Key(ln[l].folder)] = "trusted"]
       ELSE UNCHANGED store
  /\ UNCHANGED <<yesKeys, initStore>>

LoadRepoContent(l) ==
  /\ ln[l].phase = "running"
  /\ ~ln[l].repo
  /\ (Design = "b" /\ Mutant # "headless_content") => ln[l].trust
  /\ ln' = [ln EXCEPT ![l].repo = TRUE]
  /\ UNCHANGED <<store, yesKeys, initStore>>

Crash(l) ==
  /\ Class \in {"nonideal", "all"}
  /\ ln[l].phase # "exited"
  /\ ln' = [ln EXCEPT ![l].phase = "exited"]
  /\ UNCHANGED <<store, yesKeys, initStore>>

\* In Class "ideal", Crash is disabled, so a running launch with no enabled
\* repo load has finished all reachable actions.
LaunchDone(l) ==
  \/ ln[l].phase = "exited"
  \/ /\ Class = "ideal"
     /\ ln[l].phase = "running"
     /\ (ln[l].repo \/ (Design = "b" /\ Mutant # "headless_content" /\ ~ln[l].trust))

Done == \A l \in Launches : LaunchDone(l)

Next ==
  \/ \E l \in Launches :
       \/ Decide(l)
       \/ AnswerYes(l)
       \/ AnswerNo(l)
       \/ LoadRepoContent(l)
       \/ Crash(l)
  \/ (Done /\ UNCHANGED vars)

Spec == Init /\ [][Next]_vars

InitiallyTrusted(k) == initStore[k] = "trusted"

ConsentBeforeSession ==
  \A l \in Launches : ln[l].surface = "tui" /\ ln[l].phase = "running" => ln[l].trust

NoNeverSaves ==
  \A k \in Keys : store[k] = "trusted" => (k \in yesKeys \/ InitiallyTrusted(k))

HomeNeverSaved == store["home"] = "unknown"

HeadlessNeverWaits ==
  \A l \in Launches : ln[l].surface = "headless" => ln[l].phase # "asking"

SavedOrSaid ==
  \A l \in Launches :
    (ln[l].yes /\ ln[l].folder # "home") => (store[Key(ln[l].folder)] = "trusted" \/ ln[l].notice)

UntrustedHeadlessNoRepoContent ==
  \A l \in Launches : ln[l].repo => ln[l].trust

\* Trust that comes from a saved record is the folder's own record.
NoBorrowedTrust ==
  \A l \in Launches : (ln[l].trust /\ ~ ln[l].yes) => store[TrueKey(ln[l].folder)] = "trusted"

=============================================================================
