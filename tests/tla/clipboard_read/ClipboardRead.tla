---------------------------- MODULE ClipboardRead ----------------------------
(***************************************************************************)
(* Reading a macOS clipboard image for /paste and Ctrl+V                   *)
(* (src/core/images/clipboard_read.zig, wired through                      *)
(* src/core/images/image_commands.zig, src/core/app/app_input_runtime.zig, *)
(* src/core/app/app_agents_runtime.zig, and src/main.zig).                 *)
(*                                                                         *)
(* The input loop starts a read and returns at once. A worker thread runs  *)
(* osascript, stops it at a deadline or when shutdown sets the cancel      *)
(* flag, and leaves the outcome for the loop, which takes it in its fact   *)
(* collection and attaches the image to the agent that asked: on screen,   *)
(* or in the draft that agent keeps while hidden. Only an agent that has   *)
(* closed loses the image, with a notice and a trace line.                 *)
(*                                                                         *)
(* Each event the code handles is one action: Press (the terminal delivers *)
(* a key), ReadText, Paste, Quit, ChildExits, TimeOut, CancelKill,         *)
(* Collect, Exit, Switch, Close, Reopen, and Borrow. The environment acts  *)
(* through Press, ChildExits (osascript may also never exit: the action    *)
(* has no fairness), Switch, Close, Reopen, and Borrow. Agent "main" never *)
(* closes; slot "sub" holds one subagent at a time, and a new one opened   *)
(* after a close has the next generation, as a reused address would.       *)
(*                                                                         *)
(* Variant selects the design or one planted defect:                       *)
(*   fixed            the design                                           *)
(*   blocking         fx before this change: the loop runs osascript       *)
(*                    itself, with no deadline and no cancel               *)
(*   no_guard         a second paste starts a second osascript             *)
(*   no_timeout       nothing stops an osascript that never exits          *)
(*   no_cancel        shutdown does not set the cancel flag                *)
(*   screen_agent     the image goes to whichever agent is on screen       *)
(*   drop_hidden      the image is dropped when its agent is hidden        *)
(*   no_forget        a closed agent is not forgotten, so a new agent at   *)
(*                    the same address takes its image                     *)
(*   no_borrow_check  the image goes into the composer the model picker    *)
(*                    holds                                                *)
(*   silent_drop      shutdown frees an uncollected read without logging   *)
(***************************************************************************)
EXTENDS Naturals

CONSTANTS Variant, MaxPastes, MaxGen

Variants == {"fixed", "blocking", "no_guard", "no_timeout", "no_cancel", "screen_agent",
             "drop_hidden", "no_forget", "no_borrow_check", "silent_drop"}
Slots == {"main", "sub"}
Keys == {"text", "paste", "quit"}
Results == {"image", "no_image", "failed"}
Agents == [slot: Slots, gen: 0..MaxGen]
NoAgent == [slot |-> "none", gen |-> 0]
Outs == {"none", "reading", "busy", "skipped", "inserted", "no_image", "failed", "timed_out",
         "dropped", "freed"}

VARIABLES
    app,       \* "running", "stopping" (shutdown started), or "exited"
    loop,      \* "free", or "waiting" while the input loop itself waits on osascript
    job,       \* the runtime: "idle", "reading", or "done" (outcome waiting for the loop)
    alive,     \* osascript processes running
    cancel,    \* the runtime's cancel flag
    result,    \* the outcome the runtime holds: "none", a Result, "timed_out", or "cancelled"
    req,       \* the agent that asked, or NoAgent
    gone,      \* the agent that asked has closed and was forgotten
    screen,    \* the slot on screen
    open,      \* slot "sub" holds an open subagent
    gen,       \* the generation of the subagent in slot "sub"
    borrowed,  \* the model picker holds the composer
    key,       \* a key the terminal delivered and the loop has not read: "none" or a Key
    pastes,    \* paste keys delivered, bounded by MaxPastes
    started,   \* reads started
    settled,   \* reads whose outcome reached the user or the trace log
    wrong,     \* an image went to an agent that did not ask for it
    misdropped,\* an image was dropped while the agent that asked was still open
    clobbered, \* an image went into the composer the model picker held
    waited,    \* shutdown waited for the read's deadline
    out        \* what the last step showed

vars == <<app, loop, job, alive, cancel, result, req, gone, screen, open, gen, borrowed, key,
          pastes, started, settled, wrong, misdropped, clobbered, waited, out>>

Current(s) == [slot |-> s, gen |-> IF s = "sub" THEN gen ELSE 0]
IsOpen(a) == a.slot = "main" \/ (a.slot = "sub" /\ open /\ gen = a.gen)
\* What the code can tell about the agent that asked: forgotten when it
\* closed, or, without the forget hook, only whether its slot is taken.
Seems(a) == IF Variant = "no_forget" THEN a.slot = "main" \/ open ELSE ~gone

Init ==
    /\ app = "running" /\ loop = "free" /\ job = "idle" /\ alive = 0 /\ cancel = FALSE
    /\ result = "none" /\ req = NoAgent /\ gone = FALSE /\ screen = "main" /\ open = FALSE
    /\ gen = 0 /\ borrowed = FALSE /\ key = "none" /\ pastes = 0 /\ started = 0 /\ settled = 0
    /\ wrong = FALSE /\ misdropped = FALSE /\ clobbered = FALSE /\ waited = FALSE /\ out = "none"

Running == app = "running" /\ loop = "free"

Press(k) ==
    /\ app = "running" /\ key = "none" /\ k \in Keys
    /\ (k = "paste" => pastes < MaxPastes)
    /\ key' = k
    /\ pastes' = IF k = "paste" THEN pastes + 1 ELSE pastes
    /\ out' = "none"
    /\ UNCHANGED <<app, loop, job, alive, cancel, result, req, gone, screen, open, gen, borrowed,
                   started, settled, wrong, misdropped, clobbered, waited>>

ReadText ==
    /\ Running /\ key = "text"
    /\ key' = "none" /\ out' = "none"
    /\ UNCHANGED <<app, loop, job, alive, cancel, result, req, gone, screen, open, gen, borrowed,
                   pastes, started, settled, wrong, misdropped, clobbered, waited>>

\* Ctrl+V or /paste. While the model picker holds the composer, Ctrl+V is
\* skipped before anything starts.
Paste ==
    /\ Running /\ key = "paste"
    /\ key' = "none"
    /\ IF borrowed
          THEN /\ out' = "skipped"
               /\ UNCHANGED <<loop, job, alive, req, gone, started>>
       ELSE IF job = "idle" \/ Variant = "no_guard"
          THEN /\ job' = "reading" /\ alive' = alive + 1 /\ req' = Current(screen)
               /\ gone' = FALSE /\ started' = started + 1 /\ out' = "reading"
               /\ loop' = IF Variant = "blocking" THEN "waiting" ELSE "free"
          ELSE /\ out' = "busy"
               /\ UNCHANGED <<loop, job, alive, req, gone, started>>
    /\ UNCHANGED <<app, cancel, result, screen, open, gen, borrowed, pastes, settled, wrong,
                   misdropped, clobbered, waited>>

Quit ==
    /\ Running /\ key = "quit"
    /\ key' = "none" /\ app' = "stopping"
    /\ cancel' = (Variant \notin {"no_cancel", "blocking"})
    /\ out' = "none"
    /\ UNCHANGED <<loop, job, alive, result, req, gone, screen, open, gen, borrowed, pastes,
                   started, settled, wrong, misdropped, clobbered, waited>>

\* osascript ends on its own with result r.
ChildExits(r) ==
    /\ job = "reading" /\ alive > 0 /\ r \in Results
    /\ alive' = alive - 1 /\ job' = "done" /\ result' = r /\ out' = "none"
    /\ UNCHANGED <<app, loop, cancel, req, gone, screen, open, gen, borrowed, key, pastes,
                   started, settled, wrong, misdropped, clobbered, waited>>

\* The worker checks the cancel flag before the deadline, so after Quit only
\* CancelKill stops the child.
TimeOut ==
    /\ job = "reading" /\ alive > 0 /\ ~cancel /\ Variant \notin {"no_timeout", "blocking"}
    /\ alive' = alive - 1 /\ job' = "done" /\ result' = "timed_out" /\ out' = "none"
    /\ waited' = (waited \/ app = "stopping")
    /\ UNCHANGED <<app, loop, cancel, req, gone, screen, open, gen, borrowed, key, pastes,
                   started, settled, wrong, misdropped, clobbered>>

CancelKill ==
    /\ job = "reading" /\ alive > 0 /\ cancel
    /\ alive' = alive - 1 /\ job' = "done" /\ result' = "cancelled" /\ out' = "none"
    /\ UNCHANGED <<app, loop, cancel, req, gone, screen, open, gen, borrowed, key, pastes,
                   started, settled, wrong, misdropped, clobbered, waited>>

\* The loop's fact collection takes the outcome. It waits while the model
\* picker holds the composer. The fx before this change took it inside the
\* paste, with the loop waiting.
Collect ==
    /\ app = "running" /\ job = "done"
    /\ (IF Variant = "blocking" THEN TRUE ELSE loop = "free")
    /\ (~borrowed \/ Variant = "no_borrow_check")
    /\ LET target == IF Variant = "screen_agent" THEN Current(screen)
                     ELSE IF Variant = "no_forget" /\ req.slot = "sub" THEN Current("sub")
                     ELSE req
           keep == IF Variant = "screen_agent" THEN TRUE
                   ELSE IF Variant = "drop_hidden" THEN req.slot = screen /\ ~gone
                   ELSE Seems(req)
       \* A read for an agent that closed is dropped, with a notice only
       \* when it held an image; anything else goes to the agent that asked.
       IN IF ~keep
             THEN /\ out' = "dropped"
                  /\ misdropped' = (misdropped \/ (result = "image" /\ IsOpen(req)))
                  /\ UNCHANGED <<wrong, clobbered>>
          ELSE IF result = "image"
             THEN /\ out' = "inserted"
                  /\ wrong' = (wrong \/ target # req)
                  /\ clobbered' = (clobbered \/ (borrowed /\ target.slot = screen))
                  /\ UNCHANGED misdropped
             ELSE /\ out' = result
                  /\ UNCHANGED <<wrong, misdropped, clobbered>>
    /\ job' = "idle" /\ result' = "none" /\ req' = NoAgent /\ gone' = FALSE
    /\ settled' = settled + 1 /\ loop' = "free"
    /\ UNCHANGED <<app, alive, cancel, screen, open, gen, borrowed, key, pastes, started, waited>>

\* Shutdown joins the worker, which has ended its child, and frees an
\* outcome nobody collected, logging it as dropped.
Exit ==
    /\ app = "stopping" /\ job # "reading"
    /\ app' = "exited"
    /\ settled' = IF result # "none" /\ Variant # "silent_drop" THEN settled + 1 ELSE settled
    /\ out' = IF result # "none" THEN "freed" ELSE "none"
    /\ job' = "idle" /\ result' = "none" /\ req' = NoAgent /\ gone' = FALSE
    /\ UNCHANGED <<loop, alive, cancel, screen, open, gen, borrowed, key, pastes, started, wrong,
                   misdropped, clobbered, waited>>

Switch ==
    /\ Running /\ open
    /\ screen' = IF screen = "main" THEN "sub" ELSE "main"
    /\ out' = "none"
    /\ UNCHANGED <<app, loop, job, alive, cancel, result, req, gone, open, gen, borrowed, key,
                   pastes, started, settled, wrong, misdropped, clobbered, waited>>

\* The subagent in slot "sub" closes; the forget hook marks it gone when it
\* is the agent that asked.
Close ==
    /\ Running /\ open
    /\ open' = FALSE /\ screen' = "main"
    /\ gone' = (gone \/ (req.slot = "sub" /\ req.gen = gen))
    /\ out' = "none"
    /\ UNCHANGED <<app, loop, job, alive, cancel, result, req, gen, borrowed, key, pastes,
                   started, settled, wrong, misdropped, clobbered, waited>>

Reopen ==
    /\ Running /\ ~open /\ gen < MaxGen
    /\ open' = TRUE /\ gen' = gen + 1 /\ out' = "none"
    /\ UNCHANGED <<app, loop, job, alive, cancel, result, req, gone, screen, borrowed, key,
                   pastes, started, settled, wrong, misdropped, clobbered, waited>>

Borrow ==
    /\ Running
    /\ borrowed' = ~borrowed /\ out' = "none"
    /\ UNCHANGED <<app, loop, job, alive, cancel, result, req, gone, screen, open, gen, key,
                   pastes, started, settled, wrong, misdropped, clobbered, waited>>

Next ==
    \/ \E k \in Keys : Press(k)
    \/ ReadText \/ Paste \/ Quit
    \/ \E r \in Results : ChildExits(r)
    \/ TimeOut \/ CancelKill \/ Collect \/ Exit
    \/ Switch \/ Close \/ Reopen \/ Borrow

\* osascript may hang, so ChildExits has no fairness, and the person may
\* never quit or close the picker. Everything fx does itself is fair.
Fairness ==
    /\ WF_vars(ReadText) /\ WF_vars(Paste) /\ WF_vars(Quit)
    /\ WF_vars(TimeOut) /\ WF_vars(CancelKill) /\ WF_vars(Collect) /\ WF_vars(Exit)

Spec == Init /\ [][Next]_vars /\ Fairness

TypeOK ==
    /\ app \in {"running", "stopping", "exited"} /\ loop \in {"free", "waiting"}
    /\ job \in {"idle", "reading", "done"} /\ alive \in 0..MaxPastes /\ cancel \in BOOLEAN
    /\ result \in {"none", "timed_out", "cancelled"} \cup Results
    /\ req \in Agents \cup {NoAgent} /\ gone \in BOOLEAN /\ screen \in Slots /\ open \in BOOLEAN
    /\ gen \in 0..MaxGen /\ borrowed \in BOOLEAN /\ key \in Keys \cup {"none"}
    /\ pastes \in 0..MaxPastes /\ started \in 0..MaxPastes /\ settled \in 0..MaxPastes
    /\ out \in Outs

\* I414: the input loop never waits on osascript.
LoopNeverWaits == loop = "free"
\* One read at a time: a second paste is refused, never a second osascript.
OneChild == alive <= 1
ChildOnlyWhileReading == alive > 0 => job = "reading"
\* The image goes to the agent that asked, on screen or hidden.
ImageToRequester == ~wrong
\* It is dropped only when that agent has closed.
DropOnlyWhenClosed == ~misdropped
\* Never into the composer the model picker holds.
PickerComposerUntouched == ~clobbered
\* Shutdown stops osascript through the cancel flag, never by waiting out
\* the deadline.
ShutdownNeverWaitsForDeadline == ~waited
\* Every read reaches the user or the trace log, and no child outlives fx.
EveryReadSettles == app = "exited" => (settled = started /\ alive = 0)
NoReadAfterExit == app = "exited" => job = "idle"

\* A key the person types is read.
KeysAreRead == key # "none" ~> key = "none"
\* No read lasts forever, even when osascript never exits.
ReadEnds == job = "reading" ~> job # "reading"
ShutdownEnds == app = "stopping" ~> app = "exited"
=============================================================================
