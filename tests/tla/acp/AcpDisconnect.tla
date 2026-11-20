--------------------------- MODULE AcpDisconnect ---------------------------
(***************************************************************************)
(* A client of fx acp that disconnects: its input ends.                    *)
(*                                                                         *)
(*  - A client that lists sh.fx/keepTurnOnDisconnect (Keep) keeps its      *)
(*    running turn and its queued prompts: they finish and are saved.      *)
(*  - Any other client's running turn stops when the client leaves, and    *)
(*    is saved as interrupted; its queued prompts still run.               *)
(*  - After the client leaves, fx never waits for an answer from it: a     *)
(*    permission request is denied at once, and the turn goes on.          *)
(*  - fx exits once no turn runs and no prompt waits, and by then every    *)
(*    prompt the client sent is saved.                                     *)
(*                                                                         *)
(* Rules = FALSE gives fx acp before these rules: a disconnect stops       *)
(* every running turn, and a permission request made after it waits for    *)
(* an answer that never comes.                                             *)
(***************************************************************************)
EXTENDS Naturals, Sequences

CONSTANTS
    Rules,      \* TRUE: these rules; FALSE: fx acp before them
    Keep,       \* TRUE: the client lists sh.fx/keepTurnOnDisconnect
    MaxPrompts

VARIABLES
    connected,  \* whether the client's input is open
    turn,       \* "idle", "running", or "asking" (waiting for a permission)
    queue,      \* prompts that wait behind the running turn
    cut,        \* whether the running turn was running when the client left
    saved,      \* each saved turn: its outcome and its cut
    prompts,    \* prompts the client sent
    exited
vars == <<connected, turn, queue, cut, saved, prompts, exited>>

Init ==
    /\ connected = TRUE
    /\ turn = "idle"
    /\ queue = 0
    /\ cut = FALSE
    /\ saved = <<>>
    /\ prompts = 0
    /\ exited = FALSE

\* The next queued prompt starts, or fx goes idle.
Next_turn(q) == IF q > 0 THEN <<"running", q - 1>> ELSE <<"idle", 0>>

\* The client sends a prompt: it starts a turn, or it waits in the queue.
Prompt ==
    /\ connected /\ prompts < MaxPrompts
    /\ prompts' = prompts + 1
    /\ IF turn = "idle"
       THEN /\ turn' = "running" /\ cut' = FALSE /\ UNCHANGED queue
       ELSE /\ queue' = queue + 1 /\ UNCHANGED <<turn, cut>>
    /\ UNCHANGED <<connected, saved, exited>>

\* The running turn needs a permission. While the client is there, fx asks
\* it. After it left, the rules deny at once and the turn goes on; before
\* them, fx asks anyway and waits.
Ask ==
    /\ turn = "running"
    /\ IF connected \/ ~Rules
       THEN turn' = "asking"
       ELSE UNCHANGED turn
    /\ UNCHANGED <<connected, queue, cut, saved, prompts, exited>>

\* The client answers a permission request.
Answer ==
    /\ connected /\ turn = "asking"
    /\ turn' = "running"
    /\ UNCHANGED <<connected, queue, cut, saved, prompts, exited>>

\* The running turn ends and is saved; the next queued prompt starts.
Finish ==
    /\ turn = "running"
    /\ saved' = Append(saved, [outcome |-> "completed", cut |-> cut])
    /\ turn' = Next_turn(queue)[1]
    /\ queue' = Next_turn(queue)[2]
    /\ cut' = FALSE
    /\ UNCHANGED <<connected, prompts, exited>>

\* The client's input ends. A waiting permission request ends as a deny. A
\* kept turn goes on (marked cut); any other running turn is saved as
\* interrupted, and the next queued prompt starts.
Disconnect ==
    /\ connected
    /\ connected' = FALSE
    /\ IF turn = "idle"
       THEN UNCHANGED <<turn, queue, cut, saved>>
       ELSE IF Rules /\ Keep
            THEN /\ turn' = "running" /\ cut' = TRUE
                 /\ UNCHANGED <<queue, saved>>
            ELSE /\ saved' = Append(saved, [outcome |-> "interrupted", cut |-> TRUE])
                 /\ turn' = Next_turn(queue)[1]
                 /\ queue' = Next_turn(queue)[2]
                 /\ cut' = FALSE
    /\ UNCHANGED <<prompts, exited>>

\* fx exits once the client left, no turn runs and no prompt waits.
Exit ==
    /\ ~connected /\ turn = "idle" /\ queue = 0 /\ ~exited
    /\ exited' = TRUE
    /\ UNCHANGED <<connected, turn, queue, cut, saved, prompts>>

Next == Prompt \/ Ask \/ Answer \/ Finish \/ Disconnect \/ Exit

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
TypeOK ==
    /\ connected \in BOOLEAN /\ exited \in BOOLEAN /\ cut \in BOOLEAN
    /\ turn \in {"idle", "running", "asking"}
    /\ queue \in 0..MaxPrompts

\* A kept client's turns are all saved as completed.
KeptTurnsComplete == Keep => \A k \in DOMAIN saved : saved[k].outcome = "completed"

\* Any other client's turn that ran when it left is saved as interrupted.
PlainTurnsStop == ~Keep => \A k \in DOMAIN saved : saved[k].cut => saved[k].outcome = "interrupted"

\* After the client left, fx never waits for its answer.
NeverWaitsForGoneClient == ~connected => turn # "asking"

\* When fx exits, every prompt the client sent is saved.
EveryPromptSaved == exited => Len(saved) = prompts
=============================================================================
