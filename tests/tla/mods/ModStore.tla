------------------------------ MODULE ModStore ------------------------------
(***************************************************************************)
(* Models the mod store under ~/.fx/mods/ (src/core/mods/store.zig),       *)
(* which `fx mod add`, `update`, `disable`, `enable` and `remove` change   *)
(* and fx's loaders read.                                                  *)
(*                                                                         *)
(* One mod, m. Installers 1..N each run one command, and they can run at   *)
(* once; a running fx loads the mod at any moment. `committed` is the      *)
(* state the last finished change promised the person. Every load must     *)
(* see exactly that state, during a change and after a crash: never a      *)
(* half-copied mod, never a mod that is gone in the middle of an update,   *)
(* never an old on or off state.                                           *)
(*                                                                         *)
(* Design "current" reuses the skills install transaction                  *)
(* (src/builtins/skills.zig copySkillDirWithOptions): copy into a hidden   *)
(* folder, rename the old folder aside, rename the copy in, delete the     *)
(* old. A marker file in the folder turns the mod off.                     *)
(* Design "a" keeps a manifest, ~/.fx/mods/manifest.json, that names each  *)
(* mod's versioned folder and its on or off state, rewritten as a temp     *)
(* file and a rename under the mod's lock.                                 *)
(* Design "b" keeps each version in its own folder under                   *)
(* ~/.fx/mods/.store/, and ~/.fx/mods/m (or m.off when the mod is off) is  *)
(* a symlink to it. A change swaps or renames the link, under the mod's    *)
(* lock.                                                                   *)
(*                                                                         *)
(* Bug plants one defect; check.sh names the rule that must catch each.    *)
(* Nonideal lets an installer crash at any step; the OS then drops its     *)
(* lock, and what it left behind stays on disk.                            *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS N, MaxVersion, Design, Bug, Nonideal

ASSUME N \in Nat /\ N >= 1 /\ MaxVersion \in Nat /\ MaxVersion >= 1
ASSUME Design \in {"current", "a", "b"}
ASSUME Bug \in {"none", "no_lock", "gc_live", "add_replaces"}
ASSUME Nonideal \in BOOLEAN

Installers == 1..N
Ops == {"add", "update", "disable", "enable", "remove"}
NoMod == [v |-> 0, off |-> FALSE]
Mods == {NoMod} \cup [v: 1..MaxVersion, off: BOOLEAN]
\* Installer i writes its copy under token i; token N + 1 is the copy the
\* store starts with.
MaxTok == N + 1
Toks == 1..MaxTok
NoTok == 0
Gone == [v |-> 0, complete |-> FALSE]
NoManifest == [tok |-> NoTok, off |-> FALSE]
Busy == {"lock", "copy", "copied", "aside", "temp", "switched", "collect"}
\* What a load sees when the store names a half-copied, missing, or doubly
\* named mod. It is a record so TLC can compare it with a mod.
Bad == [v |-> MaxVersion + 1, off |-> FALSE]
NoStaged == [st |-> "none", m |-> NoMod]
NoTemp == [has |-> FALSE, tok |-> NoTok, off |-> FALSE]

VARIABLES
    pc,         \* each installer: idle, a step of its command, done, or crashed
    op,         \* the command each installer runs
    ver,        \* the version an add or update installs
    result,     \* what each command told the person: none, ok, exists, missing, busy
    lock,       \* the installer that holds the mod's lock, or 0
    committed,  \* the mod as the last finished change left it
    load_bad,   \* whether a load ever saw something other than `committed`
    \* Design "current".
    dir,        \* the folder ~/.fx/mods/m, or NoMod
    staged,     \* each installer's hidden copy: [st, m], st none, copying or ready
    aside,      \* each installer's renamed-aside old folder, or NoMod
    \* Designs "a" and "b".
    folders,    \* each token's versioned folder
    manifest,   \* design "a": [tok, off] for m, or NoManifest
    mtemp,      \* design "a": each installer's temp manifest, or NoTemp
    link_on,    \* design "b": the token ~/.fx/mods/m points to, or NoTok
    link_off,   \* design "b": the token ~/.fx/mods/m.off points to, or NoTok
    seen        \* design "b": the link an update saw when it took the lock

vars == <<pc, op, ver, result, lock, committed, load_bad, dir, staged, aside,
          folders, manifest, mtemp, link_on, link_off, seen>>
Fs == <<dir, staged, aside, folders, manifest, mtemp, link_on, link_off>>

TypeOK ==
    /\ pc \in [Installers -> {"idle", "done", "crashed"} \cup Busy]
    /\ op \in [Installers -> Ops \cup {"none"}]
    /\ ver \in [Installers -> 0..MaxVersion]
    /\ result \in [Installers -> {"none", "ok", "exists", "missing", "busy"}]
    /\ lock \in Installers \cup {0}
    /\ committed \in Mods
    /\ load_bad \in BOOLEAN
    /\ dir \in Mods
    /\ staged \in [Installers -> [st: {"none", "copying", "ready"}, m: Mods]]
    /\ aside \in [Installers -> Mods]
    /\ folders \in [Toks -> [v: 0..MaxVersion, complete: BOOLEAN]]
    /\ manifest \in [tok: 0..MaxTok, off: BOOLEAN]
    /\ mtemp \in [Installers -> [has: BOOLEAN, tok: 0..MaxTok, off: BOOLEAN]]
    /\ link_on \in 0..MaxTok /\ link_off \in 0..MaxTok
    /\ seen \in [Installers -> {"on", "off", "none"}]

\* What a load of m sees.
Loaded ==
    CASE Design = "current" -> dir
      [] Design = "a" ->
            IF manifest.tok = NoTok THEN NoMod
            ELSE IF folders[manifest.tok].complete
                    THEN [v |-> folders[manifest.tok].v, off |-> manifest.off]
                    ELSE Bad
      [] Design = "b" ->
            IF link_on # NoTok /\ link_off # NoTok THEN Bad
            ELSE IF link_on # NoTok
                    THEN IF folders[link_on].complete
                            THEN [v |-> folders[link_on].v, off |-> FALSE] ELSE Bad
            ELSE IF link_off # NoTok
                    THEN IF folders[link_off].complete
                            THEN [v |-> folders[link_off].v, off |-> TRUE] ELSE Bad
            ELSE NoMod

InitOf(m) ==
    /\ committed = m
    /\ dir = (IF Design = "current" THEN m ELSE NoMod)
    /\ folders = [t \in Toks |-> IF Design # "current" /\ m # NoMod /\ t = MaxTok
                                    THEN [v |-> m.v, complete |-> TRUE] ELSE Gone]
    /\ manifest = (IF Design = "a" /\ m # NoMod THEN [tok |-> MaxTok, off |-> m.off] ELSE NoManifest)
    /\ link_on = (IF Design = "b" /\ m # NoMod /\ ~m.off THEN MaxTok ELSE NoTok)
    /\ link_off = (IF Design = "b" /\ m # NoMod /\ m.off THEN MaxTok ELSE NoTok)

Init ==
    /\ pc = [i \in Installers |-> "idle"]
    /\ op = [i \in Installers |-> "none"]
    /\ ver = [i \in Installers |-> 0]
    /\ result = [i \in Installers |-> "none"]
    /\ lock = 0
    /\ load_bad = FALSE
    /\ staged = [i \in Installers |-> NoStaged]
    /\ aside = [i \in Installers |-> NoMod]
    /\ mtemp = [i \in Installers |-> NoTemp]
    /\ seen = [i \in Installers |-> "none"]
    \* The store starts empty, or with version 1 installed, on or off.
    /\ \E m \in {NoMod, [v |-> 1, off |-> FALSE], [v |-> 1, off |-> TRUE]} : InitOf(m)

\* A running fx reads the mod: when it starts a session, lists providers, or
\* runs the mod's sign-in command.
Load ==
    /\ load_bad' = (load_bad \/ Loaded # committed)
    /\ UNCHANGED <<pc, op, ver, result, lock, committed, seen>> /\ UNCHANGED Fs

\* The person runs a command.
Start(i, o, v) ==
    /\ pc[i] = "idle"
    /\ pc' = [pc EXCEPT ![i] = "lock"]
    /\ op' = [op EXCEPT ![i] = o]
    /\ ver' = [ver EXCEPT ![i] = v]
    /\ UNCHANGED <<result, lock, committed, load_bad, seen>> /\ UNCHANGED Fs

Locks == Bug # "no_lock"

Finish(i, r) ==
    /\ pc' = [pc EXCEPT ![i] = "done"]
    /\ result' = [result EXCEPT ![i] = r]
    /\ lock' = IF lock = i THEN 0 ELSE lock

Exists == IF Design = "current" THEN dir # NoMod ELSE Loaded \notin {NoMod, Bad}

\* An add needs the mod absent (unless add_replaces), every other command
\* needs it present.
CanRun(i) == IF op[i] = "add" THEN ~Exists \/ Bug = "add_replaces" ELSE Exists

\* Take the mod's lock, or give up as busy at the lock's deadline (skills use
\* 2 seconds). Then check the command can run at all.
TakeLock(i) ==
    /\ pc[i] = "lock"
    /\ IF Locks /\ lock # 0
          THEN /\ Finish(i, "busy")
               /\ UNCHANGED <<op, ver, committed, load_bad, seen>> /\ UNCHANGED Fs
          ELSE IF ~CanRun(i)
          THEN /\ Finish(i, IF op[i] = "add" THEN "exists" ELSE "missing")
               /\ UNCHANGED <<op, ver, committed, load_bad, seen>> /\ UNCHANGED Fs
          ELSE /\ lock' = IF Locks THEN i ELSE lock
               /\ pc' = [pc EXCEPT ![i] = IF op[i] \in {"add", "update"} THEN "copy" ELSE "switched"]
               /\ seen' = [seen EXCEPT ![i] = IF link_on # NoTok THEN "on"
                                               ELSE IF link_off # NoTok THEN "off" ELSE "none"]
               /\ UNCHANGED <<op, ver, result, committed, load_bad>> /\ UNCHANGED Fs

\* Copy the mod's files into a place no load reads: a hidden folder, or a
\* versioned folder nothing names yet.
CopyStart(i) ==
    /\ pc[i] = "copy"
    /\ pc' = [pc EXCEPT ![i] = "copied"]
    /\ IF Design = "current"
          THEN /\ staged' = [staged EXCEPT ![i] = [st |-> "copying", m |-> NoMod]]
               /\ UNCHANGED folders
          ELSE /\ folders' = [folders EXCEPT ![i] = [v |-> ver[i], complete |-> FALSE]]
               /\ UNCHANGED staged
    /\ UNCHANGED <<op, ver, result, lock, committed, load_bad, seen, dir, aside, manifest, mtemp, link_on, link_off>>

\* The copy is complete. In design "current" the copy carries the old
\* folder's off marker, so an update keeps the mod off.
CopyDone(i) ==
    /\ pc[i] = "copied"
    /\ IF Design = "current"
          THEN /\ staged[i].st = "copying"
               /\ staged' = [staged EXCEPT ![i] =
                                 [st |-> "ready", m |-> [v |-> ver[i], off |-> (op[i] = "update" /\ dir.off)]]]
               /\ pc' = [pc EXCEPT ![i] = IF op[i] = "update" THEN "aside" ELSE "switched"]
               /\ UNCHANGED folders
          ELSE /\ folders' = [folders EXCEPT ![i] = [v |-> ver[i], complete |-> TRUE]]
               /\ pc' = [pc EXCEPT ![i] = IF Design = "a" THEN "temp" ELSE "switched"]
               /\ UNCHANGED staged
    /\ UNCHANGED <<op, ver, result, lock, committed, load_bad, seen, dir, aside, manifest, mtemp, link_on, link_off>>

\* Design "current": rename the old folder aside, for an update or a remove.
\* A remove is finished here; an update is not.
MoveAside(i) ==
    /\ Design = "current"
    /\ \/ pc[i] = "aside"
       \/ pc[i] = "switched" /\ op[i] = "remove"
    /\ aside' = [aside EXCEPT ![i] = dir]
    /\ dir' = NoMod
    /\ committed' = IF op[i] = "remove" THEN NoMod ELSE committed
    /\ pc' = [pc EXCEPT ![i] = IF op[i] = "remove" THEN "collect" ELSE "switched"]
    /\ UNCHANGED <<op, ver, result, lock, load_bad, seen, staged, folders, manifest, mtemp, link_on, link_off>>

\* Design "a": write the new manifest to a temp file, from the manifest as it
\* reads it now.
WriteTemp(i) ==
    /\ Design = "a"
    /\ \/ pc[i] = "temp"
       \/ pc[i] = "switched" /\ op[i] \in {"disable", "enable", "remove"} /\ ~mtemp[i].has
    /\ mtemp' = [mtemp EXCEPT ![i] =
                    CASE op[i] \in {"add", "update"} ->
                            [has |-> TRUE, tok |-> i, off |-> (op[i] = "update" /\ manifest.off)]
                      [] op[i] = "disable" -> [has |-> TRUE, tok |-> manifest.tok, off |-> TRUE]
                      [] op[i] = "enable" -> [has |-> TRUE, tok |-> manifest.tok, off |-> FALSE]
                      [] op[i] = "remove" -> [has |-> TRUE, tok |-> NoTok, off |-> FALSE]]
    /\ pc' = [pc EXCEPT ![i] = "switched"]
    /\ UNCHANGED <<op, ver, result, lock, committed, load_bad, seen, dir, staged, aside, folders, manifest, link_on, link_off>>

NextCommitted(i) ==
    CASE op[i] = "add" -> [v |-> ver[i], off |-> FALSE]
      [] op[i] = "update" -> [v |-> ver[i], off |-> committed.off]
      \* Without the lock, a disable or enable can land after a remove; the
      \* person was promised no mod.
      [] op[i] = "disable" -> IF committed = NoMod THEN NoMod ELSE [committed EXCEPT !.off = TRUE]
      [] op[i] = "enable" -> IF committed = NoMod THEN NoMod ELSE [committed EXCEPT !.off = FALSE]
      [] op[i] = "remove" -> NoMod

\* The one step that makes the change visible.
Switch(i) ==
    /\ pc[i] = "switched"
    /\ \/ /\ Design = "current"
          /\ op[i] \in {"add", "update"}
          /\ staged[i].st = "ready"
          /\ dir = NoMod
          /\ dir' = staged[i].m
          /\ committed' = staged[i].m
          /\ UNCHANGED <<staged, folders, manifest, mtemp, link_on, link_off>>
       \/ /\ Design = "current"
          /\ op[i] \in {"disable", "enable"}
          /\ dir # NoMod
          /\ dir' = [dir EXCEPT !.off = (op[i] = "disable")]
          /\ committed' = NextCommitted(i)
          /\ UNCHANGED <<staged, folders, manifest, mtemp, link_on, link_off>>
       \/ /\ Design = "a"
          /\ mtemp[i].has
          /\ manifest' = [tok |-> mtemp[i].tok, off |-> mtemp[i].off]
          /\ mtemp' = [mtemp EXCEPT ![i] = NoTemp]
          /\ committed' = NextCommitted(i)
          /\ UNCHANGED <<dir, staged, folders, link_on, link_off>>
       \/ /\ Design = "b"
          /\ committed' = NextCommitted(i)
          \* An add creates m; an update replaces the link it saw when it
          \* took the lock; disable and enable rename it; remove deletes it.
          /\ CASE op[i] = "add" ->
                     link_on' = i /\ UNCHANGED link_off
               [] op[i] = "update" ->
                     IF seen[i] = "on" THEN link_on' = i /\ UNCHANGED link_off
                     ELSE link_off' = i /\ UNCHANGED link_on
               [] op[i] = "disable" ->
                     /\ link_off' = (IF link_on # NoTok THEN link_on ELSE link_off)
                     /\ link_on' = NoTok
               [] op[i] = "enable" ->
                     /\ link_on' = (IF link_off # NoTok THEN link_off ELSE link_on)
                     /\ link_off' = NoTok
               [] op[i] = "remove" -> link_on' = NoTok /\ link_off' = NoTok
          /\ UNCHANGED <<dir, staged, folders, manifest, mtemp>>
    /\ pc' = [pc EXCEPT ![i] = "collect"]
    /\ UNCHANGED <<op, ver, result, lock, load_bad, seen, aside>>

\* Still under the lock, delete what no load reads any more: the aside
\* folder, every versioned folder no link or manifest names, including what a
\* crashed installer left. Under gc_live the old version is chosen before the
\* switch, so it can be the one the store names now. Then let the lock go.
Named(t) == t = manifest.tok \/ t = link_on \/ t = link_off
Collect(i) ==
    /\ pc[i] = "collect"
    /\ IF Design = "current"
          THEN /\ aside' = [aside EXCEPT ![i] = NoMod]
               /\ UNCHANGED folders
          ELSE /\ folders' = [t \in Toks |->
                                  IF Bug = "gc_live" /\ t \in {link_on, link_off} /\ t # NoTok
                                     THEN Gone
                                  ELSE IF Named(t) THEN folders[t] ELSE Gone]
               /\ UNCHANGED aside
    /\ Finish(i, "ok")
    /\ UNCHANGED <<op, ver, committed, load_bad, seen, dir, staged, manifest, mtemp, link_on, link_off>>

\* The installer dies. The OS drops its lock; its files stay.
Crash(i) ==
    /\ Nonideal
    /\ pc[i] \in Busy
    /\ pc' = [pc EXCEPT ![i] = "crashed"]
    /\ lock' = IF lock = i THEN 0 ELSE lock
    /\ UNCHANGED <<op, ver, result, committed, load_bad, seen>> /\ UNCHANGED Fs

Step(i) == TakeLock(i) \/ CopyStart(i) \/ CopyDone(i) \/ MoveAside(i) \/ WriteTemp(i) \/ Switch(i) \/ Collect(i)

Next ==
    \/ Load
    \/ \E i \in Installers :
          \/ \E o \in Ops, v \in 1..MaxVersion : Start(i, o, v)
          \/ Step(i) \/ Crash(i)

Spec == Init /\ [][Next]_vars /\ \A i \in Installers : WF_vars(Step(i))

\* Every load sees what the last finished change left: never a half-copied
\* mod, a mod missing in the middle of an update, or an old on or off state.
LoadsSeeCommitted == ~load_bad

\* Two adds of the mod never both succeed without a remove between.
OneAddWins ==
    Cardinality({i \in Installers : op[i] = "add" /\ result[i] = "ok"})
        <= 1 + Cardinality({i \in Installers : op[i] = "remove" /\ result[i] = "ok"})

\* Every command that starts ends, unless its process dies.
CommandsEnd == \A i \in Installers : pc[i] \in Busy ~> pc[i] \in {"done", "crashed"}
=============================================================================
