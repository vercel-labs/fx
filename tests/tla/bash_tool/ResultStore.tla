---------------------------- MODULE ResultStore ----------------------------
(***************************************************************************)
(* One agent's bash session and its result store, for the one bash tool    *)
(* design behind the experimental.bash_tool setting. The session part has  *)
(* landed (src/core/bash_session/bash_session.zig and                      *)
(* src/tools/bash/bash.zig): one program at a time, wait_more, and the     *)
(* saved bash state. The result store, the numbered result files and their *)
(* index, has not landed yet.                                              *)
(*                                                                         *)
(* The model sends programs. One runs at a time; a program sent while      *)
(* another runs is refused and never starts. Every result is saved as the  *)
(* next numbered file with one index line: a program's full output when it *)
(* ends, and each fx command result it saves while it runs (mcp, skill,    *)
(* subagent, web). The client waits a bounded time for the program it      *)
(* sent; when the program outlives that, the model sends wait_more, which  *)
(* waits for the same program and never runs it again. A preview reaches   *)
(* the model only after the output it shows is saved.                      *)
(*                                                                         *)
(* Each program is its own process. It loads the bash state the last       *)
(* program saved, and its EXIT trap saves the state again with an atomic   *)
(* rename when it ends normally or with exit. A killed program saves       *)
(* nothing, so the last complete state stays. A state over the size cap is *)
(* not saved either: the last complete state stays, and the program's      *)
(* output says so.                                                         *)
(*                                                                         *)
(* The server ends a program in three steps, as the code does: it saves    *)
(* the output, makes the result ready, and then clears its running marker. *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS
    Programs,     \* the programs the model may send, each once
    MaxFx,        \* fx command results one program may save
    Mutation      \* "none", or one planted defect named in check.sh

None == "none"

VARIABLES
    sent,      \* programs fx accepted
    current,   \* the server's current or last program, or None
    phase,     \* the server: "idle", "run", or "saved" (marker not yet cleared)
    ready,     \* the program whose result waits for a client, or None
    waiting,   \* the program a client waits for, or None
    shown,     \* programs whose preview reached the model
    store,     \* the saved results in order, each [kind, prog]
    index,     \* the index lines in order: result numbers
    runs,      \* how many times each program ran
    saves,     \* how many times a program saved the bash state
    torn,      \* the saved bash state is half-written
    how,       \* how each program ended: "none", "ok", "exit", or "killed"
    savedBy,   \* programs whose end saved the bash state
    refused,   \* programs whose end did not save a state over the size cap
    noticed,   \* programs whose output says their state was not saved
    fxSaved    \* fx command results the current program saved

stateVars == <<saves, torn, how, savedBy, refused, noticed>>
vars == <<sent, current, phase, ready, waiting, shown, store, index, runs, fxSaved, stateVars>>

\* The running marker the client reads: the program until the server clears it.
Running == IF phase = "idle" THEN None ELSE current

Init ==
    /\ sent = {}
    /\ current = None
    /\ phase = "idle"
    /\ ready = None
    /\ waiting = None
    /\ shown = {}
    /\ store = <<>>
    /\ index = <<>>
    /\ runs = [p \in Programs |-> 0]
    /\ saves = 0
    /\ torn = FALSE
    /\ how = [p \in Programs |-> "none"]
    /\ savedBy = {}
    /\ refused = {}
    /\ noticed = {}
    /\ fxSaved = 0

\* Saving a result appends it and its index line.
Save(kind, p) ==
    /\ store' = Append(store, [kind |-> kind, prog |-> p])
    /\ index' = IF Mutation = "skip-index" /\ kind = "fx" THEN index ELSE Append(index, Len(store) + 1)

\* The model sends p while no marker is set. A result nobody read stays
\* saved and unread. The program loads the last saved bash state.
Send(p) ==
    /\ p \notin sent
    /\ phase = "idle"
    /\ sent' = sent \cup {p}
    /\ current' = p
    /\ phase' = "run"
    /\ runs' = [runs EXCEPT ![p] = @ + 1]
    /\ ready' = None
    /\ waiting' = p
    /\ fxSaved' = 0
    /\ UNCHANGED <<shown, store, index, stateVars>>

\* The running program saves one fx command result.
SaveFx ==
    /\ phase = "run"
    /\ fxSaved < MaxFx
    /\ Save("fx", current)
    /\ fxSaved' = fxSaved + 1
    /\ UNCHANGED <<sent, current, phase, ready, waiting, shown, runs, stateVars>>

\* The program ends: normally ("ok"), with exit ("exit"), or killed
\* ("killed"), for example by a cancel or its timeout. fx saves its output in
\* every case, and then its result is ready. Its EXIT trap saves the bash
\* state unless it is killed. The state file is replaced with an atomic
\* rename, so a kill never leaves it half-written. When the new state is
\* over the size cap (big), the trap keeps the last complete state and
\* writes a notice into the program's output.
Finish(kind, big) ==
    /\ phase = "run"
    /\ Save("output", current)
    /\ phase' = "saved"
    /\ ready' = current
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
    /\ UNCHANGED <<sent, current, waiting, shown, runs, fxSaved>>

\* The server clears its running marker.
Clear ==
    /\ phase = "saved"
    /\ phase' = "idle"
    /\ UNCHANGED <<sent, current, ready, waiting, shown, store, index, runs, fxSaved, stateVars>>

\* The waiting client shows the model its program's result.
Show ==
    /\ waiting # None
    /\ \/ ready = waiting
       \/ Mutation = "show-before-save" /\ phase = "run" /\ current = waiting
    /\ shown' = shown \cup {waiting}
    /\ waiting' = None
    /\ ready' = None
    /\ UNCHANGED <<sent, current, phase, store, index, runs, fxSaved, stateVars>>

\* The client's wait ends first; the model hears the program still runs.
GiveUp ==
    /\ waiting # None
    /\ ready # waiting
    /\ waiting' = None
    /\ UNCHANGED <<sent, current, phase, ready, shown, store, index, runs, fxSaved, stateVars>>

\* wait_more waits for the last program, running or ready.
WaitMore ==
    /\ waiting = None
    /\ Running # None \/ ready # None
    /\ waiting' = current
    /\ runs' = IF Mutation = "rerun-on-wait" /\ phase = "run"
               THEN [runs EXCEPT ![current] = @ + 1] ELSE runs
    /\ UNCHANGED <<sent, current, phase, ready, shown, store, index, fxSaved, stateVars>>

Next ==
    \/ \E p \in Programs : Send(p)
    \/ SaveFx
    \/ \E big \in BOOLEAN : Finish("ok", big) \/ Finish("exit", big)
    \/ Finish("killed", FALSE)
    \/ Clear
    \/ Show
    \/ GiveUp
    \/ WaitMore

Spec ==
    /\ Init /\ [][Next]_vars
    /\ WF_vars(Finish("ok", FALSE)) /\ WF_vars(Clear) /\ WF_vars(Show) /\ WF_vars(WaitMore)

-----------------------------------------------------------------------------
\* Rules.

TypeOK ==
    /\ sent \subseteq Programs
    /\ current \in Programs \cup {None}
    /\ phase \in {"idle", "run", "saved"}
    /\ ready \in Programs \cup {None}
    /\ waiting \in Programs \cup {None}
    /\ shown \subseteq sent
    /\ saves \in 0..Cardinality(Programs)
    /\ torn \in BOOLEAN
    /\ how \in [Programs -> {"none", "ok", "exit", "killed"}]
    /\ savedBy \subseteq sent
    /\ refused \subseteq sent
    /\ noticed \subseteq sent
    /\ fxSaved \in 0..MaxFx

\* A program runs at most once, whatever the client and the model do.
RunOnce == \A p \in Programs : runs[p] <= 1

\* One program at a time: a ready result is the last program's, and none is
\* ready while it runs.
OneAtATime ==
    /\ ready # None => ready = current
    /\ phase = "run" => ready = None

\* Every preview the model saw shows output that is saved.
SavedBeforeShown ==
    \A p \in shown : \E i \in 1..Len(store) : store[i] = [kind |-> "output", prog |-> p]

\* The index has one line per saved result, in the order they were saved.
IndexMatchesStore ==
    /\ Len(index) = Len(store)
    /\ \A i \in 1..Len(index) : index[i] = i

\* The saved bash state is never half-written, so the next program always
\* loads a complete one.
StateNeverTorn == ~torn

\* A program that ended normally or with exit saved the bash state, or its
\* state was over the size cap.
EndedSaves == \A p \in Programs : how[p] \in {"ok", "exit"} => p \in savedBy \cup refused

\* A state that was not saved for its size is never dropped silently: the
\* program's output says so (RULES.md R3.8).
RefusalNoticed == refused \subseteq noticed

\* A saved result is never changed or removed.
StoreAppendOnly == [][SubSeq(store', 1, Len(store)) = store]_vars

\* Every program fx accepted has its output saved in the end.
EverySentIsSaved ==
    \A p \in Programs :
        p \in sent ~> \E i \in 1..Len(store) : store[i] = [kind |-> "output", prog |-> p]

=============================================================================
