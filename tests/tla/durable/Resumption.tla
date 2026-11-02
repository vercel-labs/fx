---------------------------- MODULE Resumption ----------------------------
(***************************************************************************)
(* Step: agentic resumption.                                             *)
(*                                                                         *)
(* fx never asks the user to continue a session; it tells the agent.     *)
(* When a process reopens a session whose last turn was cut off          *)
(* by a crash, fx continues that turn on its own and tells the model     *)
(* "Resuming from unexpected session interruption". It never asks, and   *)
(* there is no crash-loop guard. A turn the user                       *)
(* stopped, or a committed turn, is never resumed automatically. Reopen  *)
(* covers `agent.resume()`, the queue waking a function through          *)
(* libfx/workflow's route, and `fx -c`.                                  *)
(*                                                                         *)
(* A turn ends in three steps: its final reply is saved with the turn's  *)
(* progress, then its end is sent, then the end lands. A crash in        *)
(* between loses the end, never the saved reply. A resume that finds a   *)
(* saved reply delivers it and asks the model nothing, and the host's    *)
(* `turn.result` resolves only once the turn's end is durable.           *)
(*                                                                         *)
(* Today's CLI asks after the first unclean exit                          *)
(* (`ask_after_unclean_exit`); mutants.py keeps that behavior, and a     *)
(* one-resume guard, as planted bugs this spec must reject.              *)
(***************************************************************************)
EXTENDS Naturals

CONSTANTS MaxCrashes, MaxTurns

VARIABLES
    proc,           \* "running" | "down"
    turn,           \* durable: "none" | "open" | "committed" | "user_stopped"
    turns,          \* turns started (bound)
    crashesInTurn,  \* durable: unclean exits while this turn was open
    autoResumes,    \* durable: automatic resumptions of this turn
    asked,          \* fx asked the user what to do with this turn
    notices,        \* resume notices given to the model for this turn
    delivered,      \* resumptions that delivered the turn's saved reply
    badResume,      \* history: an automatic resume of a turn that was not cut off
    crashes,
    reply,          \* durable: "none" | "saved", the open turn's final reply
    ending,         \* the turn's end was sent and is not durable yet
    resolved,       \* the host's turn.result for this turn has resolved
    replySaved,     \* history: this turn's reply was saved at some point
    askedAgain,     \* history: a model request after the turn's reply was saved
    earlyResult     \* history: a turn.result that resolved before its durable end

vars == <<proc, turn, turns, crashesInTurn, autoResumes, asked, notices,
          delivered, badResume, crashes, reply, ending, resolved, replySaved,
          askedAgain, earlyResult>>

TypeOK ==
    /\ proc \in {"running", "down"}
    /\ turn \in {"none", "open", "committed", "user_stopped"}
    /\ turns \in 0..MaxTurns
    /\ crashesInTurn \in 0..MaxCrashes
    /\ autoResumes \in 0..MaxCrashes
    /\ asked \in BOOLEAN
    /\ notices \in 0..MaxCrashes
    /\ delivered \in 0..MaxCrashes
    /\ badResume \in BOOLEAN
    /\ crashes \in 0..MaxCrashes
    /\ reply \in {"none", "saved"}
    /\ ending \in BOOLEAN
    /\ resolved \in BOOLEAN
    /\ replySaved \in BOOLEAN
    /\ askedAgain \in BOOLEAN
    /\ earlyResult \in BOOLEAN

Init ==
    /\ proc = "running"
    /\ turn = "none"
    /\ turns = 0
    /\ crashesInTurn = 0
    /\ autoResumes = 0
    /\ asked = FALSE
    /\ notices = 0
    /\ delivered = 0
    /\ badResume = FALSE
    /\ crashes = 0
    /\ reply = "none"
    /\ ending = FALSE
    /\ resolved = FALSE
    /\ replySaved = FALSE
    /\ askedAgain = FALSE
    /\ earlyResult = FALSE

StartTurn ==
    /\ proc = "running"
    /\ turn \in {"none", "committed", "user_stopped"}
    /\ turns < MaxTurns
    /\ turn' = "open"
    /\ turns' = turns + 1
    /\ crashesInTurn' = 0
    /\ autoResumes' = 0
    /\ asked' = FALSE
    /\ notices' = 0
    /\ delivered' = 0
    /\ reply' = "none"
    /\ ending' = FALSE
    /\ resolved' = FALSE
    /\ replySaved' = FALSE
    /\ UNCHANGED <<proc, badResume, crashes, askedAgain, earlyResult>>

\* A model request for the open turn. One whose turn already has a saved
\* final reply would ask the model for an answer the turn already has.
Request ==
    /\ proc = "running"
    /\ turn = "open"
    /\ ~ending
    /\ reply = "none"
    /\ askedAgain' = (askedAgain \/ replySaved)
    /\ UNCHANGED <<proc, turn, turns, crashesInTurn, autoResumes, asked,
                   notices, delivered, badResume, crashes, reply, ending,
                   resolved, replySaved, earlyResult>>

\* The final reply finished, and the progress saved after it holds it.
FinishReply ==
    /\ proc = "running"
    /\ turn = "open"
    /\ ~ending
    /\ reply = "none"
    /\ reply' = "saved"
    /\ replySaved' = TRUE
    /\ UNCHANGED <<proc, turn, turns, crashesInTurn, autoResumes, asked,
                   notices, delivered, badResume, crashes, ending, resolved,
                   askedAgain, earlyResult>>

\* The turn's end goes to the store, which has not made it durable yet.
SendEnd ==
    /\ proc = "running"
    /\ turn = "open"
    /\ reply = "saved"
    /\ ~ending
    /\ ending' = TRUE
    /\ UNCHANGED <<proc, turn, turns, crashesInTurn, autoResumes, asked,
                   notices, delivered, badResume, crashes, reply, resolved,
                   replySaved, askedAgain, earlyResult>>

\* The store makes the turn's end durable.
EndLands ==
    /\ proc = "running"
    /\ ending
    /\ turn' = "committed"
    /\ ending' = FALSE
    /\ UNCHANGED <<proc, turns, crashesInTurn, autoResumes, asked, notices,
                   delivered, badResume, crashes, reply, resolved, replySaved,
                   askedAgain, earlyResult>>

\* The host's turn.result resolves.
ResolveResult ==
    /\ proc = "running"
    /\ ~resolved
    /\ turns > 0
    /\ turn = "committed"
    /\ resolved' = TRUE
    /\ earlyResult' = (earlyResult \/ turn # "committed")
    /\ UNCHANGED <<proc, turn, turns, crashesInTurn, autoResumes, asked,
                   notices, delivered, badResume, crashes, reply, ending,
                   replySaved, askedAgain>>

\* The user cancels the turn (Esc, Ctrl+C, turn.cancel()); recorded durably.
UserStop ==
    /\ proc = "running"
    /\ turn = "open"
    /\ ~ending
    /\ turn' = "user_stopped"
    /\ UNCHANGED <<proc, turns, crashesInTurn, autoResumes, asked, notices,
                   delivered, badResume, crashes, reply, ending, resolved,
                   replySaved, askedAgain, earlyResult>>

\* Laptop crash, kill -9, function timeout. An end still being stored is
\* lost; the saved reply is not.
Crash ==
    /\ proc = "running"
    /\ crashes < MaxCrashes
    /\ proc' = "down"
    /\ crashes' = crashes + 1
    /\ crashesInTurn' = IF turn = "open" THEN crashesInTurn + 1 ELSE crashesInTurn
    /\ ending' = FALSE
    /\ UNCHANGED <<turn, turns, autoResumes, asked, notices, delivered,
                   badResume, reply, resolved, replySaved, askedAgain,
                   earlyResult>>

\* A clean exit only happens between turns.
CleanExit ==
    /\ proc = "running"
    /\ turn # "open"
    /\ proc' = "down"
    /\ UNCHANGED <<turn, turns, crashesInTurn, autoResumes, asked, notices,
                   delivered, badResume, crashes, reply, ending, resolved,
                   replySaved, askedAgain, earlyResult>>

\* agent.resume(), the queue waking a function, or fx -c. A turn with a
\* saved reply is delivered and asks the model nothing; any other open turn
\* tells the model in its next request.
Reopen ==
    /\ proc = "down"
    /\ proc' = "running"
    /\ IF turn = "open"
       THEN /\ autoResumes' = autoResumes + 1
            /\ IF reply = "saved"
               THEN /\ delivered' = delivered + 1
                    /\ UNCHANGED notices
               ELSE /\ notices' = notices + 1
                    /\ UNCHANGED delivered
            /\ UNCHANGED asked
       ELSE UNCHANGED <<autoResumes, notices, delivered, asked>>
    /\ badResume' = (badResume \/ (autoResumes' > autoResumes /\ turn # "open"))
    /\ UNCHANGED <<turn, turns, crashesInTurn, crashes, reply, ending,
                   resolved, replySaved, askedAgain, earlyResult>>

Next ==
    \/ StartTurn
    \/ Request
    \/ FinishReply
    \/ SendEnd
    \/ EndLands
    \/ ResolveResult
    \/ UserStop
    \/ Crash
    \/ CleanExit
    \/ Reopen

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
(* Invariants *)

\* fx never asks the user to continue.
NeverAsks == ~asked

\* Every crash of an open turn was answered by an automatic resume by the
\* time the session runs again.
EveryCrashResumed == proc = "running" /\ turn = "open" => autoResumes = crashesInTurn

\* Every automatic resumption tells the model what happened, or asks it
\* nothing because it delivers the turn's saved reply.
ModelToldEveryTime == notices + delivered = autoResumes

\* Committed and user-stopped turns are never resumed automatically.
NeverResumeFinishedTurn == ~badResume

\* Each automatic resumption answers a crash during that turn.
AutoResumeOnlyAfterCrash == autoResumes <= crashesInTurn

\* A turn whose final reply was saved never asks the model again.
SavedAnswerNotRequested == ~askedAgain

\* The host's turn.result resolves only after the turn's end is durable.
ResultOnlyAfterDurableEnd == ~earlyResult

\* Witness only: no resumption ever delivers a saved reply. mutants.py
\* adds it to the .cfg and requires TLC to violate it.
NoDelivery == delivered = 0

=============================================================================
