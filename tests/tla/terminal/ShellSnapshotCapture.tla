------------------------- MODULE ShellSnapshotCapture -------------------------
(***************************************************************************)
(* What one shell snapshot capture keeps, and which startup-file edits     *)
(* make it stale (src/core/terminal/shell_resolver.zig zsh_capture_script  *)
(* and bash_capture_script, src/core/terminal/shell_snapshot.zig           *)
(* parsePayload and currentFingerprint). ShellSnapshot.tla models the      *)
(* owner around it: leases, refreshes, and approval epochs.                *)
(*                                                                          *)
(* The startup files define functions: a public wrapper, `_` and `__`      *)
(* helpers it calls, a completion function that compinit only marks for    *)
(* autoloading (a stub) or that the files load, and fx's own               *)
(* `__fx_snapshot_` names. zsh startup files may also move ZDOTDIR, with   *)
(* or without exporting it, from an inherited ZDOTDIR or from HOME.        *)
(*                                                                          *)
(* fx captures once, then before every command compares the stamps of the  *)
(* startup files it watches: those in fx's own ZDOTDIR, HOME, and the      *)
(* ZDOTDIR the capture recorded. A changed stamp means a new capture. Each *)
(* command records what it saw: the functions it can call, ZDOTDIR and     *)
(* whether it is exported, and whether the startup file zsh read was the   *)
(* current one.                                                            *)
(*                                                                          *)
(* FilterRule and ZdotdirRule pick fx's rules. "fixed" is fx with this     *)
(* change. "old" and "env_only" are fx before it: every `_*` function was  *)
(* dropped, and ZDOTDIR came only from the exported environment, so it was *)
(* neither watched nor restored when unexported. The other values plant    *)
(* one broken rule each.                                                   *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS FilterRule, ZdotdirRule, MaxEdits, MaxRuns

ASSUME FilterRule \in {"fixed", "old", "keep_stubs", "keep_private"}
ASSUME ZdotdirRule \in {"fixed", "env_only", "no_restore", "restore_exported"}
ASSUME MaxEdits \in Nat /\ MaxRuns \in Nat \ {0}

Funcs == {"wrap", "_helper", "__dunder", "_comp", "__fx_snapshot_x"}
\* Names that start with `_`.
Underscore == {"_helper", "__dunder", "_comp", "__fx_snapshot_x"}
FxPrivate == {"__fx_snapshot_x"}
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

VARIABLES shell, inherited, zmode, fstate, ver, snap, captures, seen
vars == <<shell, inherited, zmode, fstate, ver, snap, captures, seen>>

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
Replayed(f) ==
    /\ fstate[f] # "absent"
    /\ CASE FilterRule = "old" -> f \notin Underscore
         [] FilterRule = "keep_stubs" -> f \notin FxPrivate
         [] FilterRule = "keep_private" -> ~(f \in Underscore /\ fstate[f] = "stub")
         [] OTHER -> /\ f \notin FxPrivate
                     /\ ~(f \in Underscore /\ fstate[f] = "stub")
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

Changed == snap # NoSnap /\ \E d \in snap.watched : snap.stamps[d] # ver[d]

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

\* The first capture, or a new one after a watched file changed.
Capture ==
    /\ snap = NoSnap \/ Changed
    /\ snap' = [replay |-> {f \in Funcs : Replayed(f)},
                names |-> {f \in Funcs : fstate[f] # "absent"},
                zdotdir |-> RecordedZ,
                zval |-> CommandZ,
                zexp |-> CommandZExported,
                watched |-> Watched(RecordedZ),
                stamps |-> ver,
                read |-> ver[ReadDir]]
    /\ captures' = captures + 1
    /\ UNCHANGED <<shell, inherited, zmode, fstate, ver, seen>>

\* The user edits a startup file in folder d.
Edit(d) ==
    /\ snap # NoSnap
    /\ ver[d] < MaxEdits
    /\ ver' = [ver EXCEPT ![d] = @ + 1]
    /\ UNCHANGED <<shell, inherited, zmode, fstate, snap, captures, seen>>

\* A command runs from the snapshot once no watched file changed.
Run ==
    /\ snap # NoSnap
    /\ ~Changed
    /\ Len(seen) < MaxRuns
    /\ seen' = Append(seen, [callable |-> snap.replay, z |-> snap.zval, zexp |-> snap.zexp,
                             fresh |-> snap.read = ver[ReadDir], captures |-> captures])
    /\ UNCHANGED <<shell, inherited, zmode, fstate, ver, snap, captures>>

Next == Capture \/ Run \/ \E d \in Dirs : Edit(d)
Spec == Init /\ [][Next]_vars

\* --- Rules -----------------------------------------------------------------
TypeOK ==
    /\ fstate \in [Funcs -> {"absent", "stub", "loaded"}]
    /\ ver \in [Dirs -> 0..MaxEdits]
    /\ captures \in Nat

\* Every function the startup files define and load can be called in a
\* command, so a wrapper that calls `_` or `__` helpers works (#1329).
HelpersCallable ==
    \A i \in 1..Len(seen) :
        {f \in Funcs \ FxPrivate : fstate[f] = "loaded"} \subseteq seen[i].callable

\* Completion stubs stay out of the replay, which runs before every command.
StubsStayOut ==
    \A f \in snap.replay : ~(f \in Underscore /\ fstate[f] = "stub")

\* fx's own capture variables never reach a command.
FxPrivateOut == snap.replay \cap FxPrivate = {}

\* The names auto mode checks still list every defined function.
NamesComplete ==
    snap # NoSnap => snap.names = {f \in Funcs : fstate[f] # "absent"}

\* A command never runs with a startup file older than the one zsh reads
\* (#1512): an edit there is seen before the next command.
FreshAfterEdit == \A i \in 1..Len(seen) : seen[i].fresh

\* A command sees ZDOTDIR as the login shell left it, exported or not.
ZdotdirAsLogin ==
    \A i \in 1..Len(seen) : seen[i].z = LoginZ /\ seen[i].zexp = LoginZExported
=============================================================================
