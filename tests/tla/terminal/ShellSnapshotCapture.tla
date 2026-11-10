------------------------- MODULE ShellSnapshotCapture -------------------------
(***************************************************************************)
(* What one shell snapshot capture keeps, and which startup-file edits     *)
(* make it stale (src/core/terminal/shell_resolver.zig zsh_capture_script  *)
(* and bash_capture_script, src/core/terminal/shell_snapshot.zig           *)
(* parsePayload and currentFingerprint). ShellSnapshot.tla models the      *)
(* owner around it: leases, refreshes, and approval epochs.                *)
(*                                                                          *)
(* The startup files define functions: a public wrapper, `_` and `__`      *)
(* helpers it calls, a completion function, and fx's own `__fx_snapshot_`  *)
(* names. A completion function is a `_` function that comes from a        *)
(* completion file: in zsh one autoloaded from a file of its own name, as  *)
(* compinit does, whether the files only mark it (a stub) or load it; in   *)
(* bash one defined in a file whose path holds `completion`. zsh startup   *)
(* files may also move ZDOTDIR, with or without exporting it, from an      *)
(* inherited ZDOTDIR or from HOME.                                         *)
(*                                                                          *)
(* fx captures once, then before every command compares the stamps of the  *)
(* startup files it watches: those in fx's own ZDOTDIR, HOME, and the      *)
(* ZDOTDIR the capture recorded. A changed stamp means a new capture. Each *)
(* command records what it saw: the functions it can call, ZDOTDIR and     *)
(* whether it is exported, and whether the startup file zsh read was the   *)
(* current one.                                                            *)
(*                                                                          *)
(* A capture takes time. fx stamps the folders it knows when it starts     *)
(* (BeginCapture), the login shell reads its startup file (ReadFile), and  *)
(* fx installs the snapshot when the shell is done (FinishCapture). The    *)
(* user can edit a file at any point in between, and no command runs from  *)
(* a snapshot until the capture is done. The folder the startup files move *)
(* ZDOTDIR to is not known when the capture starts. fx counts a file there *)
(* whose time is at or after the capture's start as changed.               *)
(*                                                                          *)
(* FilterRule and ZdotdirRule pick fx's rules. "fixed" is fx with this     *)
(* change. "env_only" is fx before the ZDOTDIR watch: ZDOTDIR came only    *)
(* from the exported environment, so it was neither watched nor restored   *)
(* when unexported. "old" is fx before it kept `_` helpers: every `_*`     *)
(* function was dropped.                                                   *)
(* "stamp_late" is fx with the watch but before the capture-start rule: it *)
(* stamped the moved folder when the capture finished, so an edit made     *)
(* while the capture ran became the baseline. The other values plant one   *)
(* broken rule each.                                                       *)
(*                                                                          *)
(* A command can also find that the restored shell rejects the replay      *)
(* (ReplayFails). fx then runs commands with the full startup until a      *)
(* watched file changes. "failed_layout" is fx with the ZDOTDIR watch      *)
(* before the repair of that state: it compared the failure's stamps, laid *)
(* out for the generation's ZDOTDIR, with stamps laid out for none, so it  *)
(* saw a change that never happened and captured before every command.     *)
(*                                                                          *)
(* A command waits for the capture it starts, and for the recapture a stale *)
(* result calls for. A startup file can renew the files fx watches at every *)
(* start: a new folder with a new .zshrc, a .zshrc rewritten, or a HOME     *)
(* file that touches itself. Every capture then ends stale. cmdCaps counts  *)
(* the captures the waiting command started. After the capture and one      *)
(* recapture (MaxCaptures) a snapshot that is still stale no longer holds   *)
(* the command: RunFull runs it with the full startup, and the next command *)
(* may capture again. "unbounded" is fx before that bound: the command kept *)
(* waiting for as long as the files kept changing. "zero_bound" plants a    *)
(* bound of zero, which never captures. The model has one command at a time;*)
(* the code counts per `acquire` call, so concurrent commands each keep     *)
(* their own count.                                                         *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS FilterRule, ZdotdirRule, MaxEdits, MaxRuns

ASSUME FilterRule \in {"fixed", "old", "keep_completion", "keep_private"}
ASSUME ZdotdirRule \in {"fixed", "env_only", "no_restore", "restore_exported", "stamp_late",
                         "failed_layout", "unbounded", "zero_bound"}
ASSUME MaxEdits \in Nat /\ MaxRuns \in Nat \ {0}

Funcs == {"wrap", "_helper", "__dunder", "_comp", "__fx_snapshot_x"}
\* Names that start with `_`.
Underscore == {"_helper", "__dunder", "_comp", "__fx_snapshot_x"}
FxPrivate == {"__fx_snapshot_x"}
\* Functions that come from a completion file, loaded or not.
Completion == {"_comp"}
Dirs == {"home", "inherited", "moved"}
\* What the startup files do with ZDOTDIR:
\*   keep          nothing
\*   unset         unset ZDOTDIR
\*   export_moved  export ZDOTDIR=$HOME/moved
\*   local_moved   unset ZDOTDIR; ZDOTDIR=$HOME/moved
\*   assign_moved  ZDOTDIR=$HOME/moved (exported only if it was inherited)
ZModes == {"keep", "unset", "export_moved", "local_moved", "assign_moved"}
None == "none"
NoSnap == [replay |-> {}, names |-> {}, zdotdir |-> None, zval |-> None,
           zexp |-> FALSE, watched |-> {}, stamps |-> [d \in Dirs |-> 0], read |-> 0]

VARIABLES shell, inherited, zmode, fstate, ver, snap, captures, seen, phase, startVer, readVer, failed, cmdCaps
vars == <<shell, inherited, zmode, fstate, ver, snap, captures, seen, phase, startVer, readVer, failed, cmdCaps>>

\* idle: no capture runs. started: fx stamped the folders it knows and the
\* shell has not read the startup file yet. read: the shell read it, and fx
\* has not installed the snapshot. startVer is each folder's version when the
\* capture started; readVer is the version of the file the shell read.
Phases == {"idle", "started", "read"}

FStates(s) == IF s = "zsh" THEN {"absent", "stub", "loaded"} ELSE {"absent", "loaded"}

\* --- The login shell -------------------------------------------------------
StartDir == IF inherited THEN "inherited" ELSE "home"
Moved == zmode \in {"export_moved", "local_moved", "assign_moved"}
\* The folder whose .zshrc zsh reads; bash reads HOME's files.
ReadDir ==
    IF shell = "bash" THEN "home"
    ELSE IF Moved THEN "moved"
    ELSE IF zmode = "unset" THEN "home"
    ELSE StartDir
\* ZDOTDIR once the startup files ran, and whether it is exported.
LoginZ ==
    IF shell = "bash" THEN None
    ELSE CASE zmode = "keep" -> (IF inherited THEN "inherited" ELSE None)
           [] zmode = "unset" -> None
           [] OTHER -> "moved"
LoginZExported ==
    /\ shell = "zsh"
    /\ CASE zmode = "keep" -> inherited
         [] zmode = "unset" -> FALSE
         [] zmode = "export_moved" -> TRUE
         [] zmode = "local_moved" -> FALSE
         [] zmode = "assign_moved" -> inherited

\* --- fx's capture rules ----------------------------------------------------
\* A `_` function that comes from a completion file, or that zsh only marked
\* for autoloading: commands never run completion, so the replay leaves it out.
IsCompletion(f) == f \in Completion \/ fstate[f] = "stub"
Replayed(f) ==
    /\ fstate[f] # "absent"
    /\ CASE FilterRule = "old" -> f \notin Underscore
         [] FilterRule = "keep_completion" -> f \notin FxPrivate
         [] FilterRule = "keep_private" -> ~(f \in Underscore /\ IsCompletion(f))
         [] OTHER -> /\ f \notin FxPrivate
                     /\ ~(f \in Underscore /\ IsCompletion(f))
\* ZDOTDIR as `env -0` shows it, and as its own payload section shows it.
EnvZ == IF LoginZExported THEN LoginZ ELSE None
RecordedZ == IF ZdotdirRule = "env_only" THEN EnvZ ELSE LoginZ
\* ZDOTDIR in a command: the environment carries an exported one, and the
\* replay assigns the recorded one, which keeps the export flag it has.
CommandZ ==
    IF ZdotdirRule \in {"env_only", "no_restore"} THEN EnvZ ELSE RecordedZ
CommandZExported ==
    IF ZdotdirRule = "restore_exported" THEN CommandZ # None ELSE LoginZExported /\ CommandZ # None
\* currentFingerprint: fx's own ZDOTDIR, HOME, and the recorded ZDOTDIR.
Watched(z) ==
    IF shell = "bash" THEN {"home"}
    ELSE {"home"} \cup (IF inherited THEN {"inherited"} ELSE {}) \cup (IF z = None THEN {} ELSE {z})

\* The folders fx knows when a capture starts: HOME and an inherited ZDOTDIR.
StartKnown == {"home"} \cup (IF inherited THEN {"inherited"} ELSE {})
\* What a later check compares each folder with. fx stamps the known folders
\* when the capture starts. A version above the start version in the moved
\* folder stands for a file whose time is at or after that start. "stamp_late"
\* stamps the moved folder when the capture finishes instead.
CaptureStamps ==
    [d \in Dirs |-> IF ZdotdirRule = "stamp_late" /\ d \notin StartKnown THEN ver[d] ELSE startVer[d]]

\* "failed_layout" compares a failed snapshot's stamps with the wrong layout
\* whenever the snapshot watches a folder fx did not know when the capture started.
LayoutMismatch ==
    /\ failed
    /\ ZdotdirRule = "failed_layout"
    /\ snap.watched \ StartKnown # {}

\* A watched file's stamp differs from the file now.
StampDiffers == \E d \in snap.watched : snap.stamps[d] # ver[d]

Changed == snap # NoSnap /\ (LayoutMismatch \/ StampDiffers)

\* No capture runs and the snapshot is missing or out of date: the waiting
\* command needs a capture.
Stale == phase = "idle" /\ (snap = NoSnap \/ Changed)

\* The most captures one command starts: the capture and one recapture.
MaxCaptures == 2
Bound == IF ZdotdirRule = "zero_bound" THEN 0 ELSE MaxCaptures
BoundReached == ZdotdirRule # "unbounded" /\ cmdCaps >= Bound

\* --- Actions ---------------------------------------------------------------
Init ==
    /\ shell \in {"zsh", "bash"}
    /\ inherited \in (IF shell = "zsh" THEN BOOLEAN ELSE {FALSE})
    /\ zmode \in (IF shell = "zsh" THEN ZModes ELSE {"keep"})
    /\ fstate \in [Funcs -> FStates(shell)]
    /\ ver = [d \in Dirs |-> 0]
    /\ snap = NoSnap
    /\ captures = 0
    /\ seen = <<>>
    /\ phase = "idle"
    /\ startVer = [d \in Dirs |-> 0]
    /\ readVer = 0
    /\ failed = FALSE
    /\ cmdCaps = 0

\* The first capture, or a new one after a watched file changed, starts.
BeginCapture ==
    /\ Stale
    /\ ~BoundReached
    /\ phase' = "started"
    /\ startVer' = ver
    /\ failed' = FALSE
    /\ cmdCaps' = cmdCaps + 1
    /\ UNCHANGED <<shell, inherited, zmode, fstate, ver, snap, captures, seen, readVer>>

\* The login shell reads the startup file of ReadDir.
ReadFile ==
    /\ phase = "started"
    /\ phase' = "read"
    /\ readVer' = ver[ReadDir]
    /\ UNCHANGED <<shell, inherited, zmode, fstate, ver, snap, captures, seen, startVer, failed, cmdCaps>>

\* fx installs the snapshot the shell reported.
FinishCapture ==
    /\ phase = "read"
    /\ snap' = [replay |-> {f \in Funcs : Replayed(f)},
                names |-> {f \in Funcs : fstate[f] # "absent"},
                zdotdir |-> RecordedZ,
                zval |-> CommandZ,
                zexp |-> CommandZExported,
                watched |-> Watched(RecordedZ),
                stamps |-> CaptureStamps,
                read |-> readVer]
    /\ captures' = captures + 1
    /\ phase' = "idle"
    /\ UNCHANGED <<shell, inherited, zmode, fstate, ver, seen, startVer, readVer, failed, cmdCaps>>

\* The user edits a startup file in folder d, between commands or while a
\* capture runs.
Edit(d) ==
    /\ snap # NoSnap \/ phase # "idle"
    /\ ver[d] < MaxEdits
    /\ ver' = [ver EXCEPT ![d] = @ + 1]
    /\ UNCHANGED <<shell, inherited, zmode, fstate, snap, captures, seen, phase, startVer, readVer, failed, cmdCaps>>

\* A command runs from the snapshot once no capture runs and no watched file
\* changed.
Run ==
    /\ phase = "idle"
    /\ snap # NoSnap
    /\ ~failed
    /\ ~Changed
    /\ Len(seen) < MaxRuns
    /\ seen' = Append(seen, [callable |-> snap.replay, z |-> snap.zval, zexp |-> snap.zexp,
                             fresh |-> snap.read = ver[ReadDir], captures |-> captures,
                             full |-> FALSE, cmdCaps |-> cmdCaps])
    /\ cmdCaps' = 0
    /\ UNCHANGED <<shell, inherited, zmode, fstate, ver, snap, captures, phase, startVer, readVer, failed>>

\* The waiting command has started the capture and one recapture, and the
\* snapshot is still stale: it runs with the full startup. Its own login shell
\* reads the startup files as they are, so it sees every function they define
\* and ZDOTDIR as they leave it, and the files load once more (captures + 1).
RunFull ==
    /\ Stale
    /\ BoundReached
    /\ Len(seen) < MaxRuns
    /\ seen' = Append(seen, [callable |-> {f \in Funcs : fstate[f] # "absent"}, z |-> LoginZ,
                             zexp |-> LoginZExported, fresh |-> TRUE, captures |-> captures + 1,
                             full |-> TRUE, cmdCaps |-> cmdCaps])
    /\ cmdCaps' = 0
    /\ UNCHANGED <<shell, inherited, zmode, fstate, ver, snap, captures, phase, startVer, readVer, failed>>

\* The restored shell rejects the replay while no watched file changed: commands
\* run with the full startup until a watched file changes.
ReplayFails ==
    /\ phase = "idle"
    /\ snap # NoSnap
    /\ ~failed
    /\ ~Changed
    /\ failed' = TRUE
    /\ cmdCaps' = 0
    /\ UNCHANGED <<shell, inherited, zmode, fstate, ver, snap, captures, seen, phase, startVer, readVer>>

Next == BeginCapture \/ ReadFile \/ FinishCapture \/ Run \/ RunFull \/ ReplayFails \/ \E d \in Dirs : Edit(d)
Spec == Init /\ [][Next]_vars

\* --- Rules -----------------------------------------------------------------
TypeOK ==
    /\ fstate \in [Funcs -> {"absent", "stub", "loaded"}]
    /\ ver \in [Dirs -> 0..MaxEdits]
    /\ captures \in Nat
    /\ phase \in Phases
    /\ startVer \in [Dirs -> 0..MaxEdits]
    /\ readVer \in 0..MaxEdits
    /\ failed \in BOOLEAN
    /\ cmdCaps \in Nat

\* Every function the startup files define and load, except a completion
\* function, can be called in a command, so a wrapper that calls `_` or `__`
\* helpers works (#1329).
HelpersCallable ==
    \A i \in 1..Len(seen) :
        {f \in Funcs \ (FxPrivate \cup Completion) : fstate[f] = "loaded"} \subseteq seen[i].callable

\* Completion functions stay out of the replay, which runs before every command.
CompletionStaysOut ==
    \A f \in snap.replay : ~(f \in Underscore /\ IsCompletion(f))

\* fx's own capture variables never reach a command.
FxPrivateOut == snap.replay \cap FxPrivate = {}

\* The names auto mode checks still list every defined function.
NamesComplete ==
    snap # NoSnap => snap.names = {f \in Funcs : fstate[f] # "absent"}

\* A command never runs with a startup file older than the one zsh reads
\* (#1512): an edit there is seen before the next command.
FreshAfterEdit == \A i \in 1..Len(seen) : seen[i].fresh

\* A snapshot taken while a watched startup file changed is never current:
\* once the capture is over and no watched file changed since fx stamped it,
\* the snapshot holds the file zsh reads as it now is. An edit made while the
\* capture ran, in the folder the startup files moved ZDOTDIR to, counts.
CurrentIsFresh ==
    (snap # NoSnap /\ phase = "idle" /\ ~Changed) => snap.read = ver[ReadDir]

\* After a replay failure, fx sees a change only when a watched file changed,
\* so it does not capture before every command while nothing changed.
FailedChangeIsReal == (failed /\ Changed) => StampDiffers

\* A command sees ZDOTDIR as the login shell left it, exported or not.
ZdotdirAsLogin ==
    \A i \in 1..Len(seen) : seen[i].z = LoginZ /\ seen[i].zexp = LoginZExported

\* A command waits for at most the capture and one recapture, however often the
\* startup files change the files fx watches.
CapturesBounded == cmdCaps <= MaxCaptures

\* A command runs with the full startup only after the capture and one recapture
\* left the snapshot stale: fx always tries before it gives up.
FullOnlyAfterRecapture ==
    \A i \in 1..Len(seen) : seen[i].full => seen[i].cmdCaps = MaxCaptures

\* A witness, not a rule: its config must fail. Under fx's rules a command does
\* run with the full startup when the files change at every capture, so the bound
\* holds the command and does not strand it.
NoFullRun == \A i \in 1..Len(seen) : ~seen[i].full
=============================================================================
