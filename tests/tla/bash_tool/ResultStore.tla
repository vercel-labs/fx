---------------------------- MODULE ResultStore ----------------------------
(***************************************************************************)
(* One agent's bash session and its result store, for the one bash tool    *)
(* design behind the experimental.bash_tool setting                        *)
(* (src/core/bash_session/bash_session.zig and src/tools/bash/bash.zig):   *)
(* one program at a time, wait_more, the saved bash state, and the result  *)
(* files in $FX_OUT.                                                       *)
(*                                                                         *)
(* The model sends programs. One runs at a time; a program sent while      *)
(* another runs is refused and never starts. When a program ends, fx saves *)
(* its full output as the next numbered file, then adds its index line,    *)
(* and only then is its result ready. The next number is one more than the *)
(* highest number already in the folder, files and index both, so a number *)
(* is never used twice, even after fx stops between the two writes. A      *)
(* folder with no room left saves nothing, and the result says so. The     *)
(* client waits a bounded time for the program it sent; when the program   *)
(* outlives that, the model sends wait_more, which waits for the same      *)
(* program and never runs it again. A preview reaches the model only after *)
(* the output it shows is saved and indexed.                               *)
(*                                                                         *)
(* fx can stop at any step, for example on a crash or a quit, and the      *)
(* session resumes in a new fx process. The files and the index stay. A    *)
(* program that was running, or whose output was not yet indexed, is not   *)
(* shown. This model does not cover the bash state across a resume.        *)
(*                                                                         *)
(* Each program is its own process. It loads the bash state the last       *)
(* program saved, and its EXIT trap saves the state again with an atomic   *)
(* rename when it ends normally or with exit. A killed program saves       *)
(* nothing, so the last complete state stays. A state over the size cap is *)
(* not saved either: the last complete state stays, and the program's      *)
(* output says so.                                                         *)
(*                                                                         *)
(* A program can also damage the session's own files after its save, for   *)
(* example by removing the session folder or leaving a FIFO where a file   *)
(* should be. Before the next program starts, fx heals the files: that     *)
(* program starts from a fresh state, and its result says the saved state  *)
(* was lost.                                                               *)
(*                                                                         *)
(* The server ends a program in steps, as the code does: the program ends, *)
(* fx writes its file, then its index line, which makes the result ready,  *)
(* and then it clears its running marker.                                  *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS
    Programs,     \* the programs the model may send, each once
    Room,         \* how many result files the folder holds before it is full
    MaxRestarts,  \* how many times fx may stop and resume
    Faults,       \* TRUE: a file or an index line can fail to be written (FileFails, IndexFails)
    Mutation      \* "none", or one planted defect named in check.sh

None == "none"

VARIABLES
    sent,      \* programs fx accepted
    current,   \* the server's current or last program, or None
    phase,     \* the server: "idle", "run", "ended", "filed", or "saved" (marker not yet cleared)
    ready,     \* the program whose result waits for a client, or None
    waiting,   \* the program a client waits for, or None
    shown,     \* programs whose preview reached the model
    files,     \* the result files in the folder, each [n, prog]
    indexed,   \* the numbers that have an index line
    unsaved,   \* programs whose output found no room
    fullNoticed, \* programs whose result says their output was not saved
    saveFailed, \* programs whose output could not be written as a file
    indexFailed, \* programs whose file is saved, but its index line could not be written
    failNoticed, \* programs whose result says their output could not be saved
    indexNoticed, \* programs whose result says their index line could not be written
    stopped,   \* programs fx stopped before their result was ready
    restarts,  \* how many times fx stopped and resumed
    runs,      \* how many times each program ran
    saves,     \* how many times a program saved the bash state
    torn,      \* the saved bash state is half-written
    how,       \* how each program ended: "none", "ok", "exit", or "killed"
    savedBy,   \* programs whose end saved the bash state
    refused,   \* programs whose end did not save a state over the size cap
    noticed,   \* programs whose output says their state was not saved
    damaged,   \* a program left the session's files damaged after its save
    lost,      \* programs that started from a fresh state after a heal
    lostNoticed, \* programs whose result says the saved state was lost
    unreported \* a loss of saved state that no result has reported yet

stateVars == <<saves, torn, how, savedBy, refused, noticed, damaged, lost, lostNoticed, unreported>>
storeVars == <<files, indexed, unsaved, fullNoticed, stopped, restarts, saveFailed, indexFailed, failNoticed, indexNoticed>>
vars == <<sent, current, phase, ready, waiting, shown, runs, storeVars, stateVars>>

\* The running marker the client reads: the program until the server clears it.
Running == IF phase = "idle" THEN None ELSE current

Init ==
    /\ sent = {}
    /\ current = None
    /\ phase = "idle"
    /\ ready = None
    /\ waiting = None
    /\ shown = {}
    /\ files = {}
    /\ indexed = {}
    /\ unsaved = {}
    /\ fullNoticed = {}
    /\ saveFailed = {}
    /\ indexFailed = {}
    /\ failNoticed = {}
    /\ indexNoticed = {}
    /\ stopped = {}
    /\ restarts = 0
    /\ runs = [p \in Programs |-> 0]
    /\ saves = 0
    /\ torn = FALSE
    /\ how = [p \in Programs |-> "none"]
    /\ savedBy = {}
    /\ refused = {}
    /\ noticed = {}
    /\ damaged = FALSE
    /\ lost = {}
    /\ lostNoticed = {}
    /\ unreported = FALSE

Numbers == {f.n : f \in files}
Max(S) == IF S = {} THEN 0 ELSE CHOOSE m \in S : \A x \in S : x <= m

\* One more than the highest number in the folder, files and index both.
NextNumber == 1 + Max(IF Mutation = "number-from-index" THEN indexed ELSE Numbers \cup indexed)

\* p's output is saved, and its index line names it.
Indexed(p) == \E f \in files : f.prog = p /\ f.n \in indexed

\* The model sends p while no marker is set. A result nobody read stays
\* saved and unread. fx first heals the session's files: when a program
\* damaged them, p starts from a fresh state and its result says the saved
\* state was lost. Otherwise p loads the last saved bash state.
Send(p) ==
    /\ p \notin sent
    /\ phase = "idle"
    /\ sent' = sent \cup {p}
    /\ current' = p
    /\ phase' = "run"
    /\ runs' = [runs EXCEPT ![p] = @ + 1]
    /\ ready' = None
    /\ waiting' = p
    /\ IF damaged
       THEN /\ damaged' = (Mutation = "skip-heal")
            /\ lost' = lost \cup {p}
            /\ lostNoticed' = IF Mutation = "silent-heal" THEN lostNoticed ELSE lostNoticed \cup {p}
            /\ unreported' = (Mutation = "silent-heal")
       ELSE UNCHANGED <<damaged, lost, lostNoticed, unreported>>
    /\ UNCHANGED <<shown, storeVars, saves, torn, how, savedBy, refused, noticed>>

\* After its save, the last program damages the session's files: its EXIT
\* trap or a child it left behind removes the folder or puts a FIFO there.
Damage ==
    /\ current # None
    /\ phase # "run"
    /\ ~damaged
    /\ damaged' = TRUE
    /\ unreported' = TRUE
    /\ UNCHANGED <<sent, current, phase, ready, waiting, shown, runs, storeVars,
                   saves, torn, how, savedBy, refused, noticed, lost, lostNoticed>>

\* fx cannot make a fresh session folder for the next program, so that call
\* fails and runs nothing. The loss stays unreported until a later program
\* starts, whose heal reports it.
HealFails ==
    /\ phase = "idle"
    /\ damaged
    /\ damaged' = (Mutation # "forget-on-fail")
    /\ UNCHANGED <<sent, current, phase, ready, waiting, shown, runs, storeVars,
                   saves, torn, how, savedBy, refused, noticed, lost, lostNoticed, unreported>>

\* The program ends: normally ("ok"), with exit ("exit"), or killed
\* ("killed"), for example by a cancel or its timeout. fx saves its output in
\* every case, in the next two steps. Its EXIT trap saves the bash
\* state unless it is killed. The state file is replaced with an atomic
\* rename, so a kill never leaves it half-written. When the new state is
\* over the size cap (big), the trap keeps the last complete state and
\* writes a notice into the program's output.
Finish(kind, big) ==
    /\ phase = "run"
    /\ phase' = "ended"
    /\ how' = [how EXCEPT ![current] = kind]
    /\ IF kind = "killed" \/ (kind = "exit" /\ Mutation = "exit-skips-save")
       THEN /\ saves' = saves
            /\ savedBy' = savedBy
            /\ torn' = (torn \/ (kind = "killed" /\ Mutation = "torn-save"))
            /\ UNCHANGED <<refused, noticed>>
       ELSE IF big
       THEN /\ saves' = saves
            /\ savedBy' = savedBy
            /\ torn' = (torn \/ Mutation = "big-save-torn")
            /\ refused' = refused \cup {current}
            /\ noticed' = IF Mutation = "silent-refusal" THEN noticed ELSE noticed \cup {current}
       ELSE /\ saves' = saves + 1
            /\ savedBy' = savedBy \cup {current}
            /\ torn' = FALSE
            /\ UNCHANGED <<refused, noticed>>
    /\ UNCHANGED <<sent, current, ready, waiting, shown, runs, storeVars, damaged, lost, lostNoticed, unreported>>

\* In the code, a bash call takes File and Index for a program that ended after its
\* last result, before its own Send (bash.zig settleLastProgram). A session that stops
\* first is a stop (Restart), and its program's result is never shown.
\* fx writes the ended program's output as the next numbered file, with an
\* atomic rename. A folder with no room saves nothing: the result is ready
\* at once and says the output was not saved (RULES.md R3.8).
File ==
    /\ phase = "ended"
    /\ IF Cardinality(files) < Room
       THEN /\ files' = files \cup {[n |-> NextNumber, prog |-> current]}
            /\ phase' = "filed"
            /\ UNCHANGED <<ready, unsaved, fullNoticed>>
       ELSE /\ unsaved' = unsaved \cup {current}
            /\ fullNoticed' = IF Mutation = "silent-full" THEN fullNoticed ELSE fullNoticed \cup {current}
            /\ phase' = "saved"
            /\ ready' = current
            /\ UNCHANGED files
    /\ UNCHANGED <<sent, current, waiting, shown, runs, indexed, stopped, restarts, saveFailed, indexFailed, failNoticed, indexNoticed, stateVars>>

\* fx replaces the index with one that adds the file's line, with an atomic
\* rename, and the result is ready.
Index ==
    /\ phase = "filed"
    /\ indexed' = IF Mutation = "skip-index" THEN indexed
                   ELSE indexed \cup {f.n : f \in {g \in files : g.prog = current}}
    /\ phase' = "saved"
    /\ ready' = current
    /\ UNCHANGED <<sent, current, waiting, shown, runs, files, unsaved, fullNoticed, stopped, restarts, saveFailed, failNoticed, indexFailed, indexNoticed, stateVars>>

\* fx cannot write the ended program's output as a file: a link or a directory a
\* program left at the number the folder picked refuses the publish, so no file is
\* written. The result is ready at once and says the output was not saved (RULES.md R3.8).
\* A folder with no room is File's full case: the folder refuses before it writes a name,
\* so this fault can only reach a folder with room.
FileFails ==
    /\ Faults
    /\ phase = "ended"
    /\ Cardinality(files) < Room
    /\ saveFailed' = saveFailed \cup {current}
    /\ failNoticed' = failNoticed \cup {current}
    /\ phase' = "saved"
    /\ ready' = current
    /\ UNCHANGED <<sent, current, waiting, shown, runs, files, indexed, unsaved, fullNoticed, indexFailed, indexNoticed, stopped, restarts, stateVars>>

\* fx saves the file, but cannot write its index line: a directory is at index.tsv.
\* The file stays with no index line, and the result is ready and says so (RULES.md R3.8).
IndexFails ==
    /\ Faults
    /\ phase = "filed"
    /\ indexFailed' = indexFailed \cup {current}
    /\ indexNoticed' = IF Mutation = "silent-index" THEN indexNoticed ELSE indexNoticed \cup {current}
    /\ phase' = "saved"
    /\ ready' = current
    /\ UNCHANGED <<sent, current, waiting, shown, runs, files, indexed, unsaved, fullNoticed, saveFailed, failNoticed, stopped, restarts, stateVars>>

\* The server clears its running marker.
Clear ==
    /\ phase = "saved"
    /\ phase' = "idle"
    /\ UNCHANGED <<sent, current, ready, waiting, shown, runs, storeVars, stateVars>>

\* fx stops at any step, and the session resumes in a new fx process. The
\* files and the index stay. A program that had not reached "saved" is never
\* shown; a result that was ready but unread stays saved.
Restart ==
    /\ restarts < MaxRestarts
    /\ restarts' = restarts + 1
    /\ stopped' = IF phase \in {"run", "ended", "filed"} THEN stopped \cup {current} ELSE stopped
    /\ phase' = "idle"
    /\ current' = None
    /\ ready' = None
    /\ waiting' = None
    /\ UNCHANGED <<sent, shown, runs, files, indexed, unsaved, fullNoticed, saveFailed, indexFailed, failNoticed, indexNoticed, stateVars>>

\* The waiting client shows the model its program's result.
Show ==
    /\ waiting # None
    /\ \/ ready = waiting
       \/ Mutation = "show-before-save" /\ phase \in {"ended", "filed"} /\ current = waiting
    /\ shown' = shown \cup {waiting}
    /\ waiting' = None
    /\ ready' = None
    /\ UNCHANGED <<sent, current, phase, runs, storeVars, stateVars>>

\* The client's wait ends first; the model hears the program still runs.
GiveUp ==
    /\ waiting # None
    /\ ready # waiting
    /\ waiting' = None
    /\ UNCHANGED <<sent, current, phase, ready, shown, runs, storeVars, stateVars>>

\* wait_more waits for the last program, running or ready.
WaitMore ==
    /\ waiting = None
    /\ Running # None \/ ready # None
    /\ waiting' = current
    /\ runs' = IF Mutation = "rerun-on-wait" /\ phase = "run"
               THEN [runs EXCEPT ![current] = @ + 1] ELSE runs
    /\ UNCHANGED <<sent, current, phase, ready, shown, storeVars, stateVars>>

Next ==
    \/ \E p \in Programs : Send(p)
    \/ \E big \in BOOLEAN : Finish("ok", big) \/ Finish("exit", big)
    \/ Finish("killed", FALSE)
    \/ File
    \/ Index
    \/ FileFails
    \/ IndexFails
    \/ Clear
    \/ Show
    \/ GiveUp
    \/ WaitMore
    \/ Damage
    \/ HealFails
    \/ Restart

Spec ==
    /\ Init /\ [][Next]_vars
    /\ WF_vars(Finish("ok", FALSE)) /\ WF_vars(File) /\ WF_vars(Index)
    /\ WF_vars(Clear) /\ WF_vars(Show) /\ WF_vars(WaitMore)

-----------------------------------------------------------------------------
\* Rules.

TypeOK ==
    /\ sent \subseteq Programs
    /\ current \in Programs \cup {None}
    /\ phase \in {"idle", "run", "ended", "filed", "saved"}
    /\ ready \in Programs \cup {None}
    /\ waiting \in Programs \cup {None}
    /\ shown \subseteq sent
    /\ saves \in 0..Cardinality(Programs)
    /\ torn \in BOOLEAN
    /\ how \in [Programs -> {"none", "ok", "exit", "killed"}]
    /\ savedBy \subseteq sent
    /\ refused \subseteq sent
    /\ noticed \subseteq sent
    /\ damaged \in BOOLEAN
    /\ lost \subseteq sent
    /\ lostNoticed \subseteq sent
    /\ unreported \in BOOLEAN
    /\ \A f \in files : f.n \in Nat /\ f.prog \in sent
    /\ indexed \subseteq Nat
    /\ unsaved \subseteq sent
    /\ fullNoticed \subseteq sent
    /\ saveFailed \subseteq sent
    /\ indexFailed \subseteq sent
    /\ failNoticed \subseteq sent
    /\ indexNoticed \subseteq sent
    /\ stopped \subseteq sent
    /\ restarts \in 0..MaxRestarts

\* A program runs at most once, whatever the client and the model do.
RunOnce == \A p \in Programs : runs[p] <= 1

\* One program at a time: a ready result is the last program's, and none is
\* ready while it runs.
OneAtATime ==
    /\ ready # None => ready = current
    /\ phase \in {"run", "ended", "filed"} => ready = None

\* Every preview the model saw shows output that is saved and indexed, or
\* its result said the folder had no room.
SavedBeforeShown ==
    \A p \in shown :
        Indexed(p) \/ (p \in unsaved /\ p \in fullNoticed)
        \/ (p \in saveFailed /\ p \in failNoticed) \/ (p \in indexFailed /\ p \in indexNoticed)

\* A number names one result, so a path the model saw never shows other output.
NoReuse == \A f, g \in files : f.n = g.n => f = g

\* An index line always names a file that is there.
IndexNamesFile == indexed \subseteq Numbers

\* Output that found no room is never dropped silently (RULES.md R3.8).
FullNoticed == unsaved \subseteq fullNoticed

\* The saved bash state is never half-written, so the next program always
\* loads a complete one.
StateNeverTorn == ~torn

\* A program that ended normally or with exit saved the bash state, or its
\* state was over the size cap.
EndedSaves == \A p \in Programs : how[p] \in {"ok", "exit"} => p \in savedBy \cup refused

\* A state that was not saved for its size is never dropped silently: the
\* program's output says so (RULES.md R3.8).
RefusalNoticed == refused \subseteq noticed

\* fx heals the session's files before a program runs, so no program runs
\* on damaged files.
NeverLoadsDamaged == phase = "run" => ~damaged

\* Saved state lost to damaged files is never lost silently: the result of
\* the program that started fresh says so (RULES.md R3.8).
LossNoticed == lost \subseteq lostNoticed

\* No program runs while a loss of saved state is unreported, even when an
\* earlier heal failed (RULES.md R3.8).
ReportedBeforeRun == phase = "run" => ~unreported

\* A saved result file or index line is never changed or removed.
StoreAppendOnly == [][files \subseteq files' /\ indexed \subseteq indexed']_vars

\* Every program fx accepted has its output saved and indexed in the end,
\* unless the folder had no room or fx stopped before its result was ready.
EverySentIsSaved ==
    \A p \in Programs :
        p \in sent ~> (Indexed(p) \/ p \in unsaved \/ p \in stopped \/ p \in saveFailed \/ p \in indexFailed)

-----------------------------------------------------------------------------
\* Witnesses: each must be violated, to show TLC reaches that case.

\* A file whose index line fx never wrote, because it stopped between them.
OrphanWitness == ~(phase = "idle" /\ \E f \in files : f.n \notin indexed)

\* A program whose output found no room.
FullWitness == unsaved = {}

\* After fx stopped between a file and its index line, a later result got
\* a higher number and reached the model.
ResumeWitness == ~(\E f, g \in files : f.n \notin indexed /\ g.n > f.n /\ g.prog \in shown)

=============================================================================
