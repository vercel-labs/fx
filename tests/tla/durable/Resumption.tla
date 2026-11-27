---------------------------- MODULE Resumption ----------------------------
(***************************************************************************)
(* Step: agentic resumption in libfx (src/acp/libfx_journal.zig,           *)
(* src/acp/prompt.zig, sdk/engine.js, sdk/durable.js).                     *)
(*                                                                         *)
(* tests/tla/recovery/Resume.tla defines the shared crash-resume policy:   *)
(* fx never asks the user to continue a session. When a process reopens a  *)
(* libfx journal whose last turn was cut off by a crash, fx computes       *)
(* n = saved crash count + 1. At CrashLoopAfter (3) abrupt deaths of the   *)
(* same turn, the resume appends no rerun and sends nothing, and ends the  *)
(* turn with error code `crash_loop`; durable.js never resumes that turn   *)
(* again. Below the guard, fx stores `turn_resumed` with n as a barrier    *)
(* before any rerun of a safe call or any model request, and continues the *)
(* turn while telling the model "Resuming from unexpected session          *)
(* interruption." A yield does not count as a crash. A turn the user       *)
(* stopped, a committed turn, or a `crash_loop` turn is never resumed      *)
(* automatically. Reopen covers `agent.resume()` and the queue waking a    *)
(* function through libfx/workflow's route.                                *)
(*                                                                         *)
(* A turn ends in three steps: its final reply is saved with the turn's    *)
(* progress, then its end is sent, then the end lands. A crash in between  *)
(* loses the end, never the saved reply. Below the guard, a resume that    *)
(* finds a saved reply delivers it and asks the model nothing, and the     *)
(* host's `turn.result` resolves only once the turn's end is durable.      *)
(*                                                                         *)
(* The notice is a steering entry of the turn (`resumeCheckpoint` in       *)
(* src/acp/libfx_journal.zig), so the turn's next progress saves it with   *)
(* the turn and every later request of the turn carries it. `saved` is     *)
(* the turn as its last stored progress holds it, a sequence of tool       *)
(* steps and notices in the order the model sees them, and `run` the       *)
(* running process's copy, which the next progress stores. A turn whose    *)
(* deadline passed yields: it stops before its next request, its yield     *)
(* record lands, and the next process continues it without a notice        *)
(* until anything else lands after that record. A crash in that window     *)
(* lost nothing the model saw, so the turn still continues as yielded.     *)
(*                                                                         *)
(* Rule says what a resume after an interruption does with the turn's      *)
(* steering. "once" adds the notice only when the turn holds none, so a    *)
(* turn resumed again keeps its one notice where it was. "each" adds one   *)
(* on every resume, as fx did before (#1584): AtMostOneNotice must fail.   *)
(* "moved" drops the earlier notices and adds one at the end, as #1615     *)
(* proposed: that rewrites what the model already saw, and                 *)
(* SavedOnlyGrows must fail.                                               *)
(*                                                                         *)
(* mutants.py keeps "fx -c asks after an unclean exit", missing the guard, *)
(* saving the count after a rerun, and counting a yield as a crash as      *)
(* planted bugs this spec must reject.                                     *)
(***************************************************************************)
EXTENDS Naturals, Sequences

CONSTANTS MaxCrashes, MaxTurns, MaxSteps, MaxYields, Rule

ASSUME Rule \in {"once", "each", "moved"}

CrashLoopAfter == 3   \* recovery.zig crash_loop_after

Min(a, b) == IF a < b THEN a ELSE b

VARIABLES
    proc,           \* "running" | "down"
    turn,           \* durable: "none" | "open" | "committed" | "user_stopped" | "crash_loop"
    turns,          \* turns started (bound)
    crashesInTurn,  \* world truth: abrupt deaths while this turn was open and not yielded
    savedCrashes,   \* durable: crash count saved in the journal (`turn_resumed`)
    pendingCrashes, \* in-memory crash count computed on Reopen
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
    earlyResult,    \* history: a turn.result that resolved before its durable end
    saved,          \* durable: the open turn's steps and notices, as stored
    run,            \* the running process's copy of the open turn
    yielded,        \* durable: the turn's yield record is its last record
    yields,         \* yields so far (bound)
    canRerun,       \* an optional safe call rerun may run before the next request
    sentAfterGuard, \* history: a model request sent when crashesInTurn >= CrashLoopAfter
    rerunAfterGuard \* history: a rerun started when crashesInTurn >= CrashLoopAfter

vars == <<proc, turn, turns, crashesInTurn, savedCrashes, pendingCrashes,
          autoResumes, asked, notices, delivered, badResume, crashes, reply,
          ending, resolved, replySaved, askedAgain, earlyResult, saved, run,
          yielded, yields, canRerun, sentAfterGuard, rerunAfterGuard>>

Entries == {"step", "notice"}

NoticesIn(s) == Len(SelectSeq(s, LAMBDA e : e = "notice"))
StepsIn(s) == Len(SelectSeq(s, LAMBDA e : e = "step"))
WithoutNotices(s) == SelectSeq(s, LAMBDA e : e # "notice")
IsPrefix(s, t) == Len(s) <= Len(t) /\ SubSeq(t, 1, Len(s)) = s

\* What a resume after an interruption continues the turn from.
Resumed(s) ==
    CASE Rule = "once"  -> IF NoticesIn(s) > 0 THEN s ELSE Append(s, "notice")
      [] Rule = "each"  -> Append(s, "notice")
      [] Rule = "moved" -> Append(WithoutNotices(s), "notice")

\* What the resume of a turn that yielded continues it from.
Continued(s) == IF Rule = "moved" THEN WithoutNotices(s) ELSE s

TypeOK ==
    /\ proc \in {"running", "down"}
    /\ turn \in {"none", "open", "committed", "user_stopped", "crash_loop"}
    /\ turns \in 0..MaxTurns
    /\ crashesInTurn \in 0..MaxCrashes
    /\ savedCrashes \in 0..CrashLoopAfter
    /\ pendingCrashes \in 0..CrashLoopAfter
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
    /\ saved \in Seq(Entries)
    /\ run \in Seq(Entries)
    /\ yielded \in BOOLEAN
    /\ yields \in 0..MaxYields
    /\ canRerun \in BOOLEAN
    /\ sentAfterGuard \in BOOLEAN
    /\ rerunAfterGuard \in BOOLEAN

Init ==
    /\ proc = "running"
    /\ turn = "none"
    /\ turns = 0
    /\ crashesInTurn = 0
    /\ savedCrashes = 0
    /\ pendingCrashes = 0
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
    /\ saved = <<>>
    /\ run = <<>>
    /\ yielded = FALSE
    /\ yields = 0
    /\ canRerun = FALSE
    /\ sentAfterGuard = FALSE
    /\ rerunAfterGuard = FALSE

StartTurn ==
    /\ proc = "running"
    /\ turn \in {"none", "committed", "user_stopped", "crash_loop"}
    /\ turns < MaxTurns
    /\ turn' = "open"
    /\ turns' = turns + 1
    /\ crashesInTurn' = 0
    /\ savedCrashes' = 0
    /\ pendingCrashes' = 0
    /\ autoResumes' = 0
    /\ asked' = FALSE
    /\ notices' = 0
    /\ delivered' = 0
    /\ reply' = "none"
    /\ ending' = FALSE
    /\ resolved' = FALSE
    /\ replySaved' = FALSE
    /\ saved' = <<>>
    /\ run' = <<>>
    /\ yielded' = FALSE
    /\ canRerun' = FALSE
    /\ UNCHANGED <<proc, badResume, crashes, askedAgain, earlyResult, yields,
                   sentAfterGuard, rerunAfterGuard>>

\* Optional rerun of a safe call before the resumed turn's first model request.
Rerun ==
    /\ proc = "running"
    /\ turn = "open"
    /\ ~ending
    /\ reply = "none"
    /\ canRerun
    /\ canRerun' = FALSE
    /\ rerunAfterGuard' = (rerunAfterGuard \/ crashesInTurn >= CrashLoopAfter)
    /\ UNCHANGED <<proc, turn, turns, crashesInTurn, savedCrashes, pendingCrashes,
                   autoResumes, asked, notices, delivered, badResume, crashes,
                   reply, ending, resolved, replySaved, askedAgain, earlyResult,
                   saved, run, yielded, yields, sentAfterGuard>>

\* A model request for the open turn, after the progress that holds the
\* turn as the request shows it lands. One whose turn already has a saved
\* final reply would ask the model for an answer the turn already has.
Request ==
    /\ proc = "running"
    /\ turn = "open"
    /\ ~ending
    /\ reply = "none"
    /\ askedAgain' = (askedAgain \/ replySaved)
    /\ sentAfterGuard' = (sentAfterGuard \/ crashesInTurn >= CrashLoopAfter)
    /\ saved' = run
    /\ savedCrashes' = pendingCrashes
    /\ yielded' = FALSE
    /\ canRerun' = FALSE
    /\ UNCHANGED <<proc, turn, turns, crashesInTurn, pendingCrashes, autoResumes,
                   asked, notices, delivered, badResume, crashes, reply, ending,
                   resolved, replySaved, earlyResult, run, yields, rerunAfterGuard>>

\* The model called a tool, the call ran, and the progress after it landed.
ToolStep ==
    /\ proc = "running"
    /\ turn = "open"
    /\ ~ending
    /\ reply = "none"
    /\ StepsIn(run) < MaxSteps
    /\ run' = Append(run, "step")
    /\ saved' = run'
    /\ yielded' = FALSE
    /\ canRerun' = FALSE
    /\ UNCHANGED <<proc, turn, turns, crashesInTurn, savedCrashes, pendingCrashes,
                   autoResumes, asked, notices, delivered, badResume, crashes,
                   reply, ending, resolved, replySaved, askedAgain, earlyResult,
                   yields, sentAfterGuard, rerunAfterGuard>>

\* The turn's deadline passed before its next request: the progress there
\* and the yield record land, and the worker stops with the turn open.
Yield ==
    /\ proc = "running"
    /\ turn = "open"
    /\ ~ending
    /\ reply = "none"
    /\ yields < MaxYields
    /\ proc' = "down"
    /\ yields' = yields + 1
    /\ yielded' = TRUE
    /\ saved' = run
    /\ canRerun' = FALSE
    /\ UNCHANGED <<turn, turns, crashesInTurn, savedCrashes, pendingCrashes,
                   autoResumes, asked, notices, delivered, badResume, crashes,
                   reply, ending, resolved, replySaved, askedAgain, earlyResult,
                   run, sentAfterGuard, rerunAfterGuard>>

\* The final reply finished, and the progress saved after it holds it.
FinishReply ==
    /\ proc = "running"
    /\ turn = "open"
    /\ ~ending
    /\ reply = "none"
    /\ reply' = "saved"
    /\ replySaved' = TRUE
    /\ saved' = run
    /\ yielded' = FALSE
    /\ canRerun' = FALSE
    /\ UNCHANGED <<proc, turn, turns, crashesInTurn, savedCrashes, pendingCrashes,
                   autoResumes, asked, notices, delivered, badResume, crashes,
                   ending, resolved, askedAgain, earlyResult, run, yields,
                   sentAfterGuard, rerunAfterGuard>>

\* The turn's end goes to the store, which has not made it durable yet.
SendEnd ==
    /\ proc = "running"
    /\ turn = "open"
    /\ reply = "saved"
    /\ ~ending
    /\ ending' = TRUE
    /\ canRerun' = FALSE
    /\ UNCHANGED <<proc, turn, turns, crashesInTurn, savedCrashes, pendingCrashes,
                   autoResumes, asked, notices, delivered, badResume, crashes,
                   reply, resolved, replySaved, askedAgain, earlyResult, saved,
                   run, yielded, yields, sentAfterGuard, rerunAfterGuard>>

\* The store makes the turn's end durable.
EndLands ==
    /\ proc = "running"
    /\ ending
    /\ turn' = "committed"
    /\ ending' = FALSE
    /\ UNCHANGED <<proc, turns, crashesInTurn, savedCrashes, pendingCrashes,
                   autoResumes, asked, notices, delivered, badResume, crashes,
                   reply, resolved, replySaved, askedAgain, earlyResult, saved,
                   run, yielded, yields, canRerun, sentAfterGuard, rerunAfterGuard>>

\* The host's turn.result resolves.
ResolveResult ==
    /\ proc = "running"
    /\ ~resolved
    /\ turns > 0
    /\ turn = "committed"
    /\ resolved' = TRUE
    /\ earlyResult' = (earlyResult \/ turn # "committed")
    /\ UNCHANGED <<proc, turn, turns, crashesInTurn, savedCrashes, pendingCrashes,
                   autoResumes, asked, notices, delivered, badResume, crashes,
                   reply, ending, replySaved, askedAgain, saved, run, yielded,
                   yields, canRerun, sentAfterGuard, rerunAfterGuard>>

\* The user cancels the turn (Esc, Ctrl+C, turn.cancel()); recorded durably.
UserStop ==
    /\ proc = "running"
    /\ turn = "open"
    /\ ~ending
    /\ turn' = "user_stopped"
    /\ canRerun' = FALSE
    /\ UNCHANGED <<proc, turns, crashesInTurn, savedCrashes, pendingCrashes,
                   autoResumes, asked, notices, delivered, badResume, crashes,
                   reply, ending, resolved, replySaved, askedAgain, earlyResult,
                   saved, run, yielded, yields, sentAfterGuard, rerunAfterGuard>>

\* Laptop crash, kill -9, function timeout, or a worker fenced by another.
\* An end still being stored is lost; the saved reply is not. A crash while
\* the yield record is still the turn's last record leaves it yielded.
Crash ==
    /\ proc = "running"
    /\ crashes < MaxCrashes
    /\ proc' = "down"
    /\ crashes' = crashes + 1
    /\ crashesInTurn' = IF turn = "open" /\ ~yielded THEN crashesInTurn + 1 ELSE crashesInTurn
    /\ ending' = FALSE
    /\ canRerun' = FALSE
    /\ UNCHANGED <<turn, turns, savedCrashes, pendingCrashes, autoResumes, asked,
                   notices, delivered, badResume, reply, resolved, replySaved,
                   askedAgain, earlyResult, saved, run, yielded, yields,
                   sentAfterGuard, rerunAfterGuard>>

\* A clean exit only happens between turns.
CleanExit ==
    /\ proc = "running"
    /\ turn # "open"
    /\ proc' = "down"
    /\ UNCHANGED <<turn, turns, crashesInTurn, savedCrashes, pendingCrashes,
                   autoResumes, asked, notices, delivered, badResume, crashes,
                   reply, ending, resolved, replySaved, askedAgain, earlyResult,
                   saved, run, yielded, yields, canRerun, sentAfterGuard,
                   rerunAfterGuard>>

\* agent.resume() or the queue waking a function. Computes next crash count
\* n = savedCrashes + 1 when not yielded. At CrashLoopAfter or more, ends the
\* turn with error code `crash_loop`, reruns nothing, and sends nothing.
\* Below the guard, stores `turn_resumed` with n as a barrier before any
\* rerun or send: a saved reply is delivered and asks the model nothing; a
\* turn that yielded continues where it stopped; any other open turn tells
\* the model in its next request.
Reopen ==
    LET next == Min(savedCrashes + 1, CrashLoopAfter)
        stops == turn = "open" /\ ~yielded /\ next >= CrashLoopAfter
    IN
    /\ proc = "down"
    /\ proc' = "running"
    /\ IF stops
       THEN /\ turn' = "crash_loop"
            /\ savedCrashes' = next
            /\ pendingCrashes' = next
            /\ canRerun' = FALSE
            /\ UNCHANGED <<autoResumes, notices, delivered, asked, run, badResume>>
       ELSE /\ turn' = turn
            /\ IF turn = "open" /\ ~yielded
               THEN /\ savedCrashes' = next
                    /\ pendingCrashes' = next
                    /\ autoResumes' = autoResumes + 1
                    /\ canRerun' = (reply = "none")
                    /\ IF reply = "saved"
                       THEN /\ delivered' = delivered + 1
                            /\ UNCHANGED notices
                       ELSE /\ notices' = notices + 1
                            /\ UNCHANGED delivered
                    /\ UNCHANGED asked
               ELSE /\ canRerun' = FALSE
                    /\ UNCHANGED <<savedCrashes, pendingCrashes, autoResumes,
                                   notices, delivered, asked>>
            /\ run' = IF turn # "open" THEN run
                      ELSE IF yielded THEN Continued(saved)
                      ELSE IF reply = "saved" THEN saved
                      ELSE Resumed(saved)
            /\ badResume' = (badResume \/ (autoResumes' > autoResumes /\ turn # "open"))
    /\ UNCHANGED <<turns, crashesInTurn, crashes, reply, ending, resolved,
                   replySaved, askedAgain, earlyResult, saved, yielded, yields,
                   sentAfterGuard, rerunAfterGuard>>

Next ==
    \/ StartTurn
    \/ Rerun
    \/ Request
    \/ ToolStep
    \/ Yield
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

\* A turn below the guard resumes every crash, and never ends with `crash_loop`.
FirstCrashResumes ==
    /\ (proc = "running" /\ turn = "open" /\ crashesInTurn < CrashLoopAfter => autoResumes = crashesInTurn)
    /\ (turn = "crash_loop" => crashesInTurn >= CrashLoopAfter)

\* At CrashLoopAfter or more abrupt deaths, the turn ends with `crash_loop`
\* and is never resumed, rerun, or sent again.
CrashLoopStops ==
    /\ (proc = "running" /\ crashesInTurn >= CrashLoopAfter => turn = "crash_loop")
    /\ ~sentAfterGuard
    /\ ~rerunAfterGuard

\* Every automatic resumption tells the model what happened, or asks it
\* nothing because it delivers the turn's saved reply.
ModelToldEveryTime == notices + delivered = autoResumes

\* Committed, user-stopped, and crash-loop turns are never resumed automatically.
NeverResumeFinishedTurn == ~badResume

\* Each automatic resumption answers a crash during that turn.
AutoResumeOnlyAfterCrash == autoResumes <= crashesInTurn

\* A turn whose final reply was saved never asks the model again.
SavedAnswerNotRequested == ~askedAgain

\* The host's turn.result resolves only after the turn's end is durable.
ResultOnlyAfterDurableEnd == ~earlyResult

\* However often a turn resumes, it carries one resume notice at most.
AtMostOneNotice == NoticesIn(run) <= 1 /\ NoticesIn(saved) <= 1

\* Once a resume told the model, the rest of the turn still tells it, a
\* resume after a yield included.
NoticeStays == proc = "running" /\ turn = "open" /\ notices > 0 => NoticesIn(run) > 0

\* A yield is not an interruption: a turn no resume told carries no notice.
NoticeOnlyAfterInterruption == notices = 0 => NoticesIn(run) = 0 /\ NoticesIn(saved) = 0

\* Each progress of a turn extends the one before it, so what the model
\* already saw keeps its place and a cached prompt prefix stays valid.
SavedOnlyGrows == [][turns' = turns => IsPrefix(saved, saved')]_vars

\* Witness only: no resumption ever delivers a saved reply. mutants.py
\* adds it to the .cfg and requires TLC to violate it.
NoDelivery == delivered = 0

=============================================================================
