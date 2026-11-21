--------------------------- MODULE HostPreferences ---------------------------
(***************************************************************************)
(* Where a preference that a command changes is saved, on the native and   *)
(* the JS host runtime profiles.                                           *)
(*                                                                         *)
(* Native fx saves user preferences in ~/.fx/settings.json. fx-term.wasm   *)
(* and the other JS host surfaces (runtime_profile.allows(App,             *)
(* .js_host_config)) have no settings file: the host's config store keeps  *)
(* the model and the permission mode, and WASI has no file system, so a    *)
(* settings write there fails with HomeNotSet without HOME, and with       *)
(* FileNotFound when the host passes HOME. Every command that saves a      *)
(* preference asks one wrapper, attemptUserPreferences in                  *)
(* src/core/app/app_host_config_runtime.zig, which answers host_owned on a *)
(* JS host profile without touching HOME, and otherwise writes the file.   *)
(*                                                                         *)
(* Commands and the labels their notices use:                              *)
(*   Model        /model: "model"; the host store keeps "model"            *)
(*   Mode         /permissions ask|auto: "permission-mode"; host "mode"    *)
(*   FullAccess   /permissions full-access: "permission-mode", then, the   *)
(*                first time the warning is shown and not yet held, the    *)
(*                acknowledgment write "full-access-acknowledgment"        *)
(*   Scrollback   /settings startup-scrollback: "startup-scrollback"       *)
(*   HistoryOn    /history on: "history"; a failed write turns history off *)
(*   Sound        /sound: "sound"                                          *)
(*                                                                         *)
(* Rule selects how the write is decided:                                  *)
(*   "fixed"            the wrapper above                                  *)
(*   "today"            fx before it: every profile writes the file        *)
(*   "partial_guard"    guards at some call sites: only the /model commit  *)
(*                      and /sound (and the settings menu) skip the write  *)
(*   "home_check"       skip the write when HOME is missing, not by        *)
(*                      profile                                            *)
(*   "every_profile"    skip the write on every profile                    *)
(*   "ack_dropped"      fixed, but the acknowledgment treats host_owned as *)
(*                      a failure and never holds it                       *)
(*   "history_dropped"  fixed, but /history on treats host_owned as a      *)
(*                      failure and turns history off                      *)
(*   "fake_unchanged"   host_owned reported as an unchanged write, which   *)
(*                      callers announce as saved to global settings       *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS Rule, MaxSteps

Profiles == {"native", "js_host"}
\* HOME as the settings write sees it: missing; present with a writable
\* settings file; present but the write fails (a malformed settings.json on
\* native, no file system on WASI).
Homes == {"unset", "writable", "broken"}
HomesFor(p) == IF p = "js_host" THEN {"unset", "broken"} ELSE Homes

Labels == {"model", "permission-mode", "full-access-acknowledgment",
           "startup-scrollback", "history", "sound"}
HostKeys == {"model", "mode"}
\* Commands whose successful write prints a line that claims a save.
AnnouncesSave == {"startup-scrollback", "history"}
GuardedLabels == {"model", "sound"}
Results == {"outcome", "failure", "host_owned", "fake_outcome"}

VARIABLES
    profile,      \* the runtime profile, fixed for a run
    home,         \* what HOME gives the settings write, fixed for a run
    steps,        \* commands run so far
    attempted,    \* labels whose command asked for a settings write
    errors,       \* labels that showed "not saved to global settings"
    saved,        \* labels that showed a line claiming the save
    settingsFile, \* labels whose patch reached settings.json
    touchedHome,  \* a settings write opened the store under HOME
    hostStore,    \* keys the JS host config store holds
    historyOn,    \* prompt history is on
    yoloAck,      \* the full-access warning is acknowledged for good
    yoloAttempted,\* the acknowledgment write already ran in this process
    lastWarned    \* the last command showed the full-access warning

vars == <<profile, home, steps, attempted, errors, saved, settingsFile,
          touchedHome, hostStore, historyOn, yoloAck, yoloAttempted, lastWarned>>

TypeOK ==
    /\ profile \in Profiles
    /\ home \in HomesFor(profile)
    /\ steps \in Nat
    /\ attempted \subseteq Labels
    /\ errors \subseteq Labels
    /\ saved \subseteq Labels
    /\ settingsFile \subseteq Labels
    /\ touchedHome \in BOOLEAN
    /\ hostStore \subseteq HostKeys
    /\ historyOn \in BOOLEAN
    /\ yoloAck \in BOOLEAN
    /\ yoloAttempted \in BOOLEAN
    /\ lastWarned \in BOOLEAN

FileWrite == IF home = "writable" THEN "outcome" ELSE "failure"

\* What one settings write for label l returns.
Attempt(l) ==
    CASE Rule \in {"fixed", "ack_dropped", "history_dropped"} ->
             IF profile = "js_host" THEN "host_owned" ELSE FileWrite
      [] Rule = "today" -> FileWrite
      [] Rule = "partial_guard" ->
             IF profile = "js_host" /\ l \in GuardedLabels THEN "host_owned" ELSE FileWrite
      [] Rule = "home_check" -> IF home = "unset" THEN "host_owned" ELSE FileWrite
      [] Rule = "every_profile" -> "host_owned"
      [] Rule = "fake_unchanged" ->
             IF profile = "js_host" THEN "fake_outcome" ELSE FileWrite

\* Callers handle a fake outcome as a success.
Succeeded(r) == r \in {"outcome", "host_owned", "fake_outcome"}
Touches(r) == r \in {"outcome", "failure"} /\ home # "unset"

\* The settings effects of the writes in one command: a set of
\* [label, result] records.
Effects(ws) ==
    /\ attempted' = attempted \cup {w.label : w \in ws}
    /\ errors' = errors \cup {w.label : w \in {x \in ws : x.result = "failure"}}
    /\ saved' = saved \cup {w.label : w \in {x \in ws :
                    x.result \in {"outcome", "fake_outcome"} /\ x.label \in AnnouncesSave}}
    /\ settingsFile' = settingsFile \cup {w.label : w \in {x \in ws : x.result = "outcome"}}
    /\ touchedHome' = (touchedHome \/ \E w \in ws : Touches(w.result))

W(l) == [label |-> l, result |-> Attempt(l)]

HostWrite(key) ==
    hostStore' = IF profile = "js_host" THEN hostStore \cup {key} ELSE hostStore

InitWith(p, h) ==
    /\ profile = p
    /\ home = h
    /\ steps = 0
    /\ attempted = {}
    /\ errors = {}
    /\ saved = {}
    /\ settingsFile = {}
    /\ touchedHome = FALSE
    /\ hostStore = {}
    /\ historyOn = TRUE
    /\ yoloAck = FALSE
    /\ yoloAttempted = FALSE
    /\ lastWarned = FALSE

Init == \E p \in Profiles, h \in Homes : h \in HomesFor(p) /\ InitWith(p, h)

Step == steps < MaxSteps /\ steps' = steps + 1

Model ==
    /\ Step
    /\ Effects({W("model")})
    /\ HostWrite("model")
    /\ lastWarned' = FALSE
    /\ UNCHANGED <<profile, home, historyOn, yoloAck, yoloAttempted>>

Mode ==
    /\ Step
    /\ Effects({W("permission-mode")})
    /\ HostWrite("mode")
    /\ lastWarned' = FALSE
    /\ UNCHANGED <<profile, home, historyOn, yoloAck, yoloAttempted>>

\* The warning shows while the acknowledgment is not held; fx tries to save
\* the acknowledgment once per process, after the first frame that shows it.
FullAccess ==
    /\ Step
    /\ LET ack == ~yoloAck /\ ~yoloAttempted
           r == Attempt("full-access-acknowledgment")
       IN /\ Effects(IF ack THEN {W("permission-mode"), W("full-access-acknowledgment")}
                            ELSE {W("permission-mode")})
          /\ lastWarned' = ~yoloAck
          /\ yoloAttempted' = (yoloAttempted \/ ack)
          /\ yoloAck' = IF ack
                          THEN IF Rule = "ack_dropped" THEN r = "outcome" ELSE Succeeded(r)
                          ELSE yoloAck
    /\ HostWrite("mode")
    /\ UNCHANGED <<profile, home, historyOn>>

Scrollback ==
    /\ Step
    /\ Effects({W("startup-scrollback")})
    /\ lastWarned' = FALSE
    /\ UNCHANGED <<profile, home, hostStore, historyOn, yoloAck, yoloAttempted>>

HistoryOn ==
    /\ Step
    /\ LET r == Attempt("history") IN
          historyOn' = IF Rule = "history_dropped" THEN r = "outcome" ELSE Succeeded(r)
    /\ Effects({W("history")})
    /\ lastWarned' = FALSE
    /\ UNCHANGED <<profile, home, hostStore, yoloAck, yoloAttempted>>

Sound ==
    /\ Step
    /\ Effects({W("sound")})
    /\ lastWarned' = FALSE
    /\ UNCHANGED <<profile, home, hostStore, historyOn, yoloAck, yoloAttempted>>

\* One command by name, for the trace checker.
Do(cmd) ==
    CASE cmd = "model" -> Model
      [] cmd = "mode" -> Mode
      [] cmd = "full_access" -> FullAccess
      [] cmd = "scrollback" -> Scrollback
      [] cmd = "history_on" -> HistoryOn
      [] cmd = "sound" -> Sound

Next == Model \/ Mode \/ FullAccess \/ Scrollback \/ HistoryOn \/ Sound

Spec == Init /\ [][Next]_vars

Bounded == steps <= MaxSteps

-----------------------------------------------------------------------------
(* Rules *)

\* A JS host profile never reports a failed settings save: it has no
\* settings file to save to.
HostProfileQuiet == profile = "js_host" => errors = {}

\* A JS host profile never opens a settings store under HOME, even when
\* the host passes HOME.
HostNeverTouchesHome == profile = "js_host" => ~touchedHome

\* Nothing claims a save to global settings where there is no such file.
HostNeverClaimsSaved == profile = "js_host" => saved = {}

\* Once fx has tried to keep the acknowledgment on a JS host profile, it
\* holds it for the process.
HostAckHeld == profile = "js_host" /\ yoloAttempted => yoloAck

\* /history on leaves history on wherever nothing failed.
HistoryFollowsCommand == (profile = "js_host" \/ home = "writable") => historyOn

\* Native fx still reports every failed save.
NativeReportsFailures == profile = "native" /\ home # "writable" => errors = attempted

\* Native fx with a writable settings file still saves every change.
NativeSavesEveryWrite ==
    profile = "native" /\ home = "writable" => settingsFile = attempted /\ errors = {}
=============================================================================
