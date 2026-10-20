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
(* The record that ends the turn says how the turn ended: it goes out    *)
(* only once the turn's stop reason is decided, so a reader of the store *)
(* and the host agree on it (EndSaysHow). Once that end is on its way,  *)
(* the turn ended as it says: a cancel then stops nothing, and the host's *)
(* `turn.result` says what the end says (ResultSaysHow). An input the     *)
(* turn accepted and *)
(* never placed waits for the model: the turn ends with its reply only   *)
(* when none waits, its end hands back one that came after the reply,    *)
(* and a resume that finds one asks the model with it instead of         *)
(* delivering the saved reply, which never saw it (EveryInputAnswered). *)
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
    askedAgain,     \* history: a model request for an answer the turn had saved,
                    \* with no input waiting for it
    earlyResult,    \* history: a turn.result that resolved before its durable end
    waiting,        \* durable: an input the open turn accepted and never placed
    unanswered,     \* history: an input placed in a turn the model never saw it in
    sentHow,        \* how the turn's end on its way says the turn ended
    endHow,         \* durable: how the turn's end says it ended, "none" until it lands
    lateCancel,     \* the user cancelled the turn while its end was on its way
    resultHow       \* how the host's turn.result says the turn ended, "none" until it resolves

vars == <<proc, turn, turns, crashesInTurn, autoResumes, asked, notices,
          delivered, badResume, crashes, reply, ending, resolved, replySaved,
          askedAgain, earlyResult, waiting, unanswered, sentHow, endHow,
          lateCancel, resultHow>>

How == {"none", "end_turn", "cancelled", "unknown"}

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
    /\ waiting \in BOOLEAN
    /\ unanswered \in BOOLEAN
    /\ sentHow \in How
    /\ endHow \in How
    /\ lateCancel \in BOOLEAN
    /\ resultHow \in How

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
    /\ waiting = FALSE
    /\ unanswered = FALSE
    /\ sentHow = "none"
    /\ endHow = "none"
    /\ lateCancel = FALSE
    /\ resultHow = "none"

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
    /\ waiting' = FALSE
    /\ sentHow' = "none"
    /\ endHow' = "none"
    /\ lateCancel' = FALSE
    /\ resultHow' = "none"
    /\ UNCHANGED <<proc, badResume, crashes, askedAgain, earlyResult, unanswered>>

\* A model request for the open turn, which carries the inputs it accepted
\* and never placed. One whose turn already has a saved final reply, with
\* no input waiting, would ask the model for an answer the turn already has.
Request ==
    /\ proc = "running"
    /\ turn = "open"
    /\ ~ending
    /\ reply = "none"
    /\ askedAgain' = (askedAgain \/ (replySaved /\ ~waiting))
    /\ waiting' = FALSE
    /\ UNCHANGED <<proc, turn, turns, crashesInTurn, autoResumes, asked,
                   notices, delivered, badResume, crashes, reply, ending,
                   resolved, replySaved, earlyResult, unanswered, sentHow, endHow>>
    /\ UNCHANGED <<lateCancel, resultHow>>

\* The turn accepts an input, such as a steer, which it stores before it
\* places it in a model request.
Accept ==
    /\ proc = "running"
    /\ turn = "open"
    /\ ~ending
    /\ ~waiting
    /\ waiting' = TRUE
    /\ UNCHANGED <<proc, turn, turns, crashesInTurn, autoResumes, asked,
                   notices, delivered, badResume, crashes, reply, ending,
                   resolved, replySaved, askedAgain, earlyResult, unanswered,
                   sentHow, endHow>>
    /\ UNCHANGED <<lateCancel, resultHow>>

\* The final reply finished, and the progress saved after it holds it. An
\* input waiting would go on with the turn instead.
FinishReply ==
    /\ proc = "running"
    /\ turn = "open"
    /\ ~ending
    /\ reply = "none"
    /\ ~waiting
    /\ reply' = "saved"
    /\ replySaved' = TRUE
    /\ UNCHANGED <<proc, turn, turns, crashesInTurn, autoResumes, asked,
                   notices, delivered, badResume, crashes, ending, resolved,
                   askedAgain, earlyResult, waiting, unanswered, sentHow, endHow>>
    /\ UNCHANGED <<lateCancel, resultHow>>

\* The turn's end goes to the store, which has not made it durable yet. It
\* goes once the turn's stop reason is decided, saying it, and hands back
\* an input that came after the reply, which then never ran.
SendEnd ==
    /\ proc = "running"
    /\ turn = "open"
    /\ reply = "saved"
    /\ ~ending
    /\ ending' = TRUE
    /\ sentHow' = "end_turn"
    /\ waiting' = FALSE
    /\ UNCHANGED <<proc, turn, turns, crashesInTurn, autoResumes, asked,
                   notices, delivered, badResume, crashes, reply, resolved,
                   replySaved, askedAgain, earlyResult, unanswered, endHow>>
    /\ UNCHANGED <<lateCancel, resultHow>>

\* The store makes the turn's end durable.
EndLands ==
    /\ proc = "running"
    /\ ending
    /\ turn' = "committed"
    /\ ending' = FALSE
    /\ endHow' = sentHow
    /\ UNCHANGED <<proc, turns, crashesInTurn, autoResumes, asked, notices,
                   delivered, badResume, crashes, reply, resolved, replySaved,
                   askedAgain, earlyResult, waiting, unanswered, sentHow>>
    /\ UNCHANGED <<lateCancel, resultHow>>

\* The user cancels the turn while its end is on its way to the store.
\* The turn ended as that end says: the cancel stops nothing.
CancelWhileEnding ==
    /\ proc = "running"
    /\ turn = "open"
    /\ ending
    /\ ~lateCancel
    /\ lateCancel' = TRUE
    /\ UNCHANGED <<proc, turn, turns, crashesInTurn, autoResumes, asked,
                   notices, delivered, badResume, crashes, reply, ending,
                   resolved, replySaved, askedAgain, earlyResult, waiting,
                   unanswered, sentHow, endHow, resultHow>>

\* The host's turn.result resolves, from the turn's durable end.
ResolveResult ==
    /\ proc = "running"
    /\ ~resolved
    /\ turns > 0
    /\ turn = "committed"
    /\ resolved' = TRUE
    /\ earlyResult' = (earlyResult \/ turn # "committed")
    /\ resultHow' = endHow
    /\ UNCHANGED <<proc, turn, turns, crashesInTurn, autoResumes, asked,
                   notices, delivered, badResume, crashes, reply, ending,
                   replySaved, askedAgain, waiting, unanswered, sentHow, endHow>>
    /\ UNCHANGED lateCancel

\* The user cancels the turn (Esc, Ctrl+C, turn.cancel()); recorded durably,
\* saying so, and handing back an input it never placed.
UserStop ==
    /\ proc = "running"
    /\ turn = "open"
    /\ ~ending
    /\ turn' = "user_stopped"
    /\ endHow' = "cancelled"
    /\ waiting' = FALSE
    /\ UNCHANGED <<proc, turns, crashesInTurn, autoResumes, asked, notices,
                   delivered, badResume, crashes, reply, ending, resolved,
                   replySaved, askedAgain, earlyResult, unanswered, sentHow>>
    /\ UNCHANGED <<lateCancel, resultHow>>

\* Laptop crash, kill -9, function timeout. An end still being stored is
\* lost; the saved reply is not. A cancel dies with its process.
Crash ==
    /\ proc = "running"
    /\ crashes < MaxCrashes
    /\ proc' = "down"
    /\ crashes' = crashes + 1
    /\ crashesInTurn' = IF turn = "open" THEN crashesInTurn + 1 ELSE crashesInTurn
    /\ ending' = FALSE
    /\ UNCHANGED <<turn, turns, autoResumes, asked, notices, delivered,
                   badResume, reply, resolved, replySaved, askedAgain,
                   earlyResult, waiting, unanswered, sentHow, endHow>>
    /\ lateCancel' = FALSE
    /\ UNCHANGED resultHow

\* A clean exit only happens between turns.
CleanExit ==
    /\ proc = "running"
    /\ turn # "open"
    /\ proc' = "down"
    /\ UNCHANGED <<turn, turns, crashesInTurn, autoResumes, asked, notices,
                   delivered, badResume, crashes, reply, ending, resolved,
                   replySaved, askedAgain, earlyResult, waiting, unanswered,
                   sentHow, endHow>>
    /\ UNCHANGED <<lateCancel, resultHow>>

\* agent.resume(), the queue waking a function, or fx -c. A turn with a
\* saved reply and no input waiting is delivered and asks the model nothing;
\* any other open turn tells the model in its next request, which carries
\* the input waiting, so a reply saved before that input arrived is asked
\* for again. A delivered turn places what waits in its history, where the
\* model never saw it.
Reopen ==
    /\ proc = "down"
    /\ proc' = "running"
    /\ IF turn = "open"
       THEN /\ autoResumes' = autoResumes + 1
            /\ IF reply = "saved" /\ ~waiting
               THEN /\ delivered' = delivered + 1
                    /\ unanswered' = (unanswered \/ waiting)
                    /\ waiting' = FALSE
                    /\ UNCHANGED <<notices, reply, replySaved>>
               ELSE /\ notices' = notices + 1
                    /\ reply' = "none"
                    /\ replySaved' = (replySaved /\ ~waiting)
                    /\ UNCHANGED <<delivered, unanswered, waiting>>
            /\ UNCHANGED asked
       ELSE UNCHANGED <<autoResumes, notices, delivered, asked, reply, replySaved, unanswered, waiting>>
    /\ badResume' = (badResume \/ (autoResumes' > autoResumes /\ turn # "open"))
    /\ UNCHANGED <<turn, turns, crashesInTurn, crashes, ending,
                   resolved, askedAgain, earlyResult, sentHow, endHow>>
    /\ UNCHANGED <<lateCancel, resultHow>>

Next ==
    \/ StartTurn
    \/ Request
    \/ Accept
    \/ FinishReply
    \/ SendEnd
    \/ EndLands
    \/ CancelWhileEnding
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

\* A turn whose final reply was saved never asks the model again, unless
\* an input it accepted after that waits for an answer.
SavedAnswerNotRequested == ~askedAgain

\* Every input a turn accepts reaches the model, or is handed back: none is
\* placed in a turn whose reply the model gave without it, and none is left
\* waiting once the turn ended.
EveryInputAnswered == ~unanswered /\ (turn # "open" => ~waiting)

\* A finished turn's durable end says how the turn ended, as the host's
\* result does, also after a crash cut the turn off before its result.
EndSaysHow == turn \in {"committed", "user_stopped"} => endHow \in {"end_turn", "cancelled"}

\* The host's turn.result resolves only after the turn's end is durable.
ResultOnlyAfterDurableEnd == ~earlyResult

\* The host's turn.result says how the turn's durable end says it ended,
\* also when the user cancelled the turn while that end was on its way
\* (DUR-20, DUR-64).
ResultSaysHow == resolved => resultHow = endHow

\* Witness only: no cancel comes while a turn's end is on its way.
\* mutants.py adds it to the .cfg and requires TLC to violate it.
NoLateCancel == ~lateCancel

\* Witness only: no resumption ever delivers a saved reply. mutants.py
\* adds it to the .cfg and requires TLC to violate it.
NoDelivery == delivered = 0

=============================================================================
