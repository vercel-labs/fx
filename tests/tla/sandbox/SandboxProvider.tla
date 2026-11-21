--------------------------- MODULE SandboxProvider ---------------------------
(***************************************************************************)
(* One shell call that fx may place in a sandbox, run through a provider   *)
(* program that does all sandbox work (src/core/sandbox/, and the default  *)
(* provider src/core/sandbox/providers/vercel.sh over the `sandbox` CLI).  *)
(* This models code that has not landed yet; the drivers in                *)
(* tests/tla/drivers/sandbox/ that need it run only with --next.           *)
(*                                                                         *)
(* fx decides. With the experiment on, the private rules give the call a   *)
(* placement: local, workspace, or isolated. A placed call is refused when *)
(* the provider cannot be used or the call asks for a tty, and it is never *)
(* run on this machine instead. Admission needs a grant for the call AND   *)
(* its placement. fx then runs the provider as a normal local process.     *)
(*                                                                         *)
(* The provider makes or resumes the sandbox, sends the files, starts the  *)
(* command with a remote timeout, waits for it, brings back what it        *)
(* changed (workspace) or removes the sandbox (isolated), and reports how  *)
(* it ended: its last "fx: " lines and its exit status (125 when the       *)
(* command did not run, 143 when it was stopped). On SIGTERM it asks the   *)
(* sandbox to kill the command. fx sends SIGKILL when its grace ends       *)
(* (grace_ms in the config, 5 s by default, against 700 ms for a local     *)
(* command). `report` is what the provider last said; with nothing said,   *)
(* fx shows only how the process ended and never claims it did not run.    *)
(*                                                                         *)
(* Time moves in ticks, about 250 ms each: the remote kill takes KillTicks *)
(* (one `sandbox commands kill` call, about 740 ms), fx's grace is Grace,  *)
(* and a remote command runs at most Timeout ticks.                        *)
(***************************************************************************)
EXTENDS Integers, FiniteSets

CONSTANTS
    Bug,        \* "none", or the one planted defect named in the configs
    Grace,      \* ticks fx waits after SIGTERM before SIGKILL
    KillTicks,  \* ticks a remote kill takes to land
    Timeout,    \* ticks a remote command may run (exec --timeout)
    MaxEdits    \* local edits to the file during one call

Placements == {"local", "workspace", "isolated"}
Codes == {0, 1}
ProvLive == {"setup", "created", "pushed", "started", "pulled"}
ProvGone == {"exited", "killed"}
Events == {"none", "decide", "local", "provider", "create", "createfail", "push",
           "start", "exit", "timeout", "edit", "copy", "keep", "nochange", "final",
           "rm", "stop", "termexit", "killsent", "killed", "sigkill", "crash",
           "result", "sweep", "tick"}

VARIABLES
    placement,      \* where the rules put the call
    tty,            \* the call asked for a terminal
    ready,          \* the provider can be used (config valid, program found)
    configured,     \* the config names env variables for workspace runs
    grants,         \* placements the user approved this command for
    runAt,          \* where fx runs it
    phase,          \* fx: decide, admitted, running, done
    result,         \* what fx tells the model
    ranLocal,       \* the command ran on this machine
    prov,           \* the provider process
    term,           \* ticks since SIGTERM, or -1
    killWait,       \* ticks the remote kill has been in flight, or -1
    crashed,        \* the provider died for another reason
    report,         \* the provider's report: none, notstarted, started, final, stopped
    remote,         \* the remote command: none, running, exited, timedout, killed
    code,           \* its exit code
    age,            \* ticks it has run
    remoteChanged,  \* it changed the file
    env,            \* env names sent to the sandbox
    localVer,       \* the local file's version
    pushedVer,      \* the version the provider sent
    lost,           \* a local edit was overwritten
    conflict,       \* the provider kept a local edit and did not bring the file back
    sandbox,        \* none, up, removed
    ev              \* what the last step did, for trace validation

inputs == <<placement, tty, ready, configured, grants>>
fxv == <<runAt, phase, result, ranLocal>>
provv == <<prov, term, killWait, crashed, report>>
remv == <<remote, code, age, remoteChanged>>
filev == <<env, localVer, pushedVer, lost, conflict>>
vars == <<inputs, fxv, provv, remv, filev, sandbox, ev>>

TypeOK ==
    /\ placement \in Placements
    /\ tty \in BOOLEAN
    /\ ready \in BOOLEAN
    /\ configured \in BOOLEAN
    /\ grants \subseteq Placements
    /\ runAt \in Placements
    /\ phase \in {"decide", "admitted", "running", "done"}
    /\ result \in {"none", "refused", "local", "exit", "stopped", "didnotrun", "mayhaveran"}
    /\ ranLocal \in BOOLEAN
    /\ prov \in {"none"} \cup ProvLive \cup ProvGone
    /\ term \in -1..Grace
    /\ killWait \in -1..KillTicks
    /\ crashed \in BOOLEAN
    /\ report \in {"none", "notstarted", "started", "final", "stopped"}
    /\ remote \in {"none", "running", "exited", "timedout", "killed"}
    /\ code \in Codes \cup {137}
    /\ age \in 0..(Timeout + 1)
    /\ remoteChanged \in BOOLEAN
    /\ env \subseteq {"KEY"}
    /\ localVer \in 0..MaxEdits
    /\ pushedVer \in 0..MaxEdits
    /\ lost \in BOOLEAN
    /\ conflict \in BOOLEAN
    /\ sandbox \in {"none", "up", "removed"}
    /\ ev \in Events

Init ==
    /\ placement \in Placements
    /\ tty \in BOOLEAN
    /\ ready \in BOOLEAN
    /\ configured \in BOOLEAN
    /\ grants \in SUBSET Placements
    /\ runAt = placement
    /\ phase = "decide"
    /\ result = "none"
    /\ ranLocal = FALSE
    /\ prov = "none"
    /\ term = -1
    /\ killWait = -1
    /\ crashed = FALSE
    /\ report = "none"
    /\ remote = "none"
    /\ code = 0
    /\ age = 0
    /\ remoteChanged = FALSE
    /\ env = {}
    /\ localVer = 0
    /\ pushedVer = 0
    /\ lost = FALSE
    /\ conflict = FALSE
    /\ sandbox = "none"
    /\ ev = "none"

\* Admission: a grant for this command at this placement.
Admits == IF Bug = "grant_any_placement" THEN grants # {} ELSE placement \in grants

-----------------------------------------------------------------------------
(* fx *)

Decide ==
    /\ phase = "decide"
    /\ IF placement # "local" /\ ~ready
       THEN IF Bug = "local_fallback"
            THEN /\ phase' = "admitted"
                 /\ runAt' = "local"
                 /\ UNCHANGED result
            ELSE /\ phase' = "done"
                 /\ result' = "refused"
                 /\ UNCHANGED runAt
       ELSE IF placement # "local" /\ tty /\ Bug # "tty_placed"
            THEN /\ phase' = "done"
                 /\ result' = "refused"
                 /\ UNCHANGED runAt
            ELSE IF Admits
                 THEN /\ phase' = "admitted"
                      /\ UNCHANGED <<runAt, result>>
                 ELSE /\ phase' = "done"
                      /\ result' = "refused"
                      /\ UNCHANGED runAt
    /\ ev' = "decide"
    /\ UNCHANGED <<inputs, ranLocal, provv, remv, filev, sandbox>>

RunLocal ==
    /\ phase = "admitted"
    /\ runAt = "local"
    /\ ranLocal' = TRUE
    /\ phase' = "done"
    /\ result' = "local"
    /\ ev' = "local"
    /\ UNCHANGED <<inputs, runAt, provv, remv, filev, sandbox>>

\* fx starts the provider; only a workspace run gets the configured env.
StartProvider ==
    /\ phase = "admitted"
    /\ runAt # "local"
    /\ phase' = "running"
    /\ prov' = "setup"
    /\ env' = IF configured /\ (placement = "workspace" \/ Bug = "isolated_keys") THEN {"KEY"} ELSE {}
    /\ ev' = "provider"
    /\ UNCHANGED <<inputs, runAt, result, ranLocal, term, killWait, crashed, report,
                   remv, localVer, pushedVer, lost, conflict, sandbox>>

\* fx reads the report once the provider is gone.
Collect ==
    /\ phase = "running"
    /\ prov \in ProvGone
    /\ phase' = "done"
    /\ result' = CASE report = "final" -> "exit"
                   [] report = "stopped" -> "stopped"
                   [] report = "notstarted" -> "didnotrun"
                   [] OTHER -> IF Bug = "trust_missing" THEN "didnotrun" ELSE "mayhaveran"
    /\ ev' = "result"
    /\ UNCHANGED <<inputs, runAt, ranLocal, provv, remv, filev, sandbox>>

\* The user or the model stops the call: fx sends SIGTERM.
Stop ==
    /\ phase = "running"
    /\ prov \in ProvLive
    /\ term = -1
    /\ term' = 0
    /\ ev' = "stop"
    /\ UNCHANGED <<inputs, fxv, prov, killWait, crashed, report, remv, filev, sandbox>>

\* The grace ended: fx sends SIGKILL to the provider.
GraceOver ==
    /\ term = Grace
    /\ prov \in ProvLive
    /\ prov' = "killed"
    /\ ev' = "sigkill"
    /\ UNCHANGED <<inputs, fxv, term, killWait, crashed, report, remv, filev, sandbox>>

\* The next fx start removes isolated sandboxes whose owner is gone.
Sweep ==
    /\ phase = "done"
    /\ placement = "isolated"
    /\ sandbox = "up"
    /\ prov \in ProvGone
    /\ Bug # "no_sweep"
    /\ sandbox' = "removed"
    /\ ev' = "sweep"
    /\ UNCHANGED <<inputs, fxv, provv, remv, filev>>

-----------------------------------------------------------------------------
(* The provider *)

\* sandbox create, or resume the kept workspace sandbox.
Create ==
    /\ prov = "setup"
    /\ term = -1
    /\ prov' = "created"
    /\ sandbox' = "up"
    /\ ev' = "create"
    /\ UNCHANGED <<inputs, fxv, term, killWait, crashed, report, remv, filev>>

CreateFail ==
    /\ prov = "setup"
    /\ term = -1
    /\ prov' = "exited"
    /\ report' = "notstarted"
    /\ ev' = "createfail"
    /\ UNCHANGED <<inputs, fxv, term, killWait, crashed, remv, filev, sandbox>>

Push ==
    /\ prov = "created"
    /\ term = -1
    /\ prov' = "pushed"
    /\ pushedVer' = localVer
    /\ ev' = "push"
    /\ UNCHANGED <<inputs, fxv, term, killWait, crashed, report, remv,
                   env, localVer, lost, conflict, sandbox>>

\* sandbox exec --detach --timeout; the report now says it started.
Start ==
    /\ prov = "pushed"
    /\ term = -1
    /\ prov' = "started"
    /\ report' = "started"
    /\ remote' = "running"
    /\ age' = 0
    /\ ev' = "start"
    /\ UNCHANGED <<inputs, fxv, term, killWait, crashed, code, remoteChanged, filev, sandbox>>

\* Bring back a changed file, unless it changed here since it was sent.
Pull ==
    /\ prov = "started"
    /\ remote \in {"exited", "timedout"}
    /\ prov' = "pulled"
    /\ IF placement = "workspace" /\ remoteChanged
       THEN IF localVer = pushedVer \/ Bug = "overwrite_local"
            THEN /\ lost' = (lost \/ localVer # pushedVer)
                 /\ UNCHANGED conflict
                 /\ ev' = "copy"
            ELSE /\ conflict' = TRUE
                 /\ UNCHANGED lost
                 /\ ev' = "keep"
       ELSE /\ UNCHANGED <<lost, conflict>>
            /\ ev' = "nochange"
    /\ UNCHANGED <<inputs, fxv, term, killWait, crashed, report, remv,
                   env, localVer, pushedVer, sandbox>>

\* Write the final report; an isolated sandbox is removed.
Finish ==
    /\ prov = "pulled"
    /\ prov' = "exited"
    /\ report' = IF report = "stopped" THEN "stopped" ELSE "final"
    /\ IF placement = "isolated" /\ sandbox = "up"
       THEN /\ sandbox' = "removed"
            /\ ev' = "rm"
       ELSE /\ UNCHANGED sandbox
            /\ ev' = "final"
    /\ UNCHANGED <<inputs, fxv, term, killWait, crashed, remv, filev>>

\* The SIGTERM handler: before the start it exits at once; while the
\* command runs it asks the sandbox to kill it.
OnTerm ==
    /\ term >= 0
    /\ prov \in ProvLive
    /\ killWait = -1
    /\ \/ /\ prov \in {"setup", "created", "pushed"}
          /\ prov' = "exited"
          /\ report' = "notstarted"
          /\ IF placement = "isolated" /\ sandbox = "up"
             THEN /\ sandbox' = "removed"
                  /\ ev' = "rm"
             ELSE /\ UNCHANGED sandbox
                  /\ ev' = "termexit"
          /\ UNCHANGED killWait
       \/ /\ prov = "started"
          /\ remote = "running"
          /\ killWait' = 0
          /\ ev' = "killsent"
          /\ UNCHANGED <<prov, report, sandbox>>
    /\ UNCHANGED <<inputs, fxv, term, crashed, remv, filev>>

\* The remote kill landed; Finish writes the report and cleans up.
KillLands ==
    /\ killWait = KillTicks
    /\ prov \in ProvLive
    /\ remote' = IF remote = "running" THEN "killed" ELSE remote
    /\ report' = IF remote = "running" THEN "stopped" ELSE report
    /\ prov' = "pulled"
    /\ ev' = "killed"
    /\ UNCHANGED <<inputs, fxv, term, killWait, crashed, code, age, remoteChanged, filev, sandbox>>

Crash ==
    /\ prov \in ProvLive
    /\ ~crashed
    /\ prov' = "killed"
    /\ crashed' = TRUE
    /\ ev' = "crash"
    /\ UNCHANGED <<inputs, fxv, term, killWait, report, remv, filev, sandbox>>

-----------------------------------------------------------------------------
(* The sandbox and this machine *)

RemoteEnds ==
    /\ remote = "running"
    /\ \E c \in Codes, ch \in BOOLEAN :
          /\ code' = c
          /\ remoteChanged' = ch
    /\ remote' = "exited"
    /\ ev' = "exit"
    /\ UNCHANGED <<inputs, fxv, provv, age, filev, sandbox>>

TimeOut ==
    /\ remote = "running"
    /\ age = Timeout
    /\ Bug # "no_timeout"
    /\ \E ch \in BOOLEAN : remoteChanged' = ch
    /\ remote' = "timedout"
    /\ code' = 137
    /\ ev' = "timeout"
    /\ UNCHANGED <<inputs, fxv, provv, age, filev, sandbox>>

\* Someone edits the file here while the call runs.
LocalEdit ==
    /\ phase = "running"
    /\ prov \in ProvLive
    /\ localVer < MaxEdits
    /\ localVer' = localVer + 1
    /\ ev' = "edit"
    /\ UNCHANGED <<inputs, fxv, provv, remv, env, pushedVer, lost, conflict, sandbox>>

\* Time passes. The provider handles a signal at once, and a timer that is
\* due fires before more time passes.
Tick ==
    /\ ~ENABLED OnTerm
    /\ ~(remote = "running" /\ age = Timeout /\ Bug # "no_timeout")
    /\ ~(term = Grace /\ prov \in ProvLive)
    /\ ~(killWait = KillTicks /\ prov \in ProvLive)
    /\ \/ remote = "running" /\ age <= Timeout
       \/ term >= 0 /\ term < Grace /\ prov \in ProvLive
       \/ killWait >= 0 /\ killWait < KillTicks /\ prov \in ProvLive
    /\ age' = IF remote = "running" /\ age <= Timeout THEN age + 1 ELSE age
    /\ term' = IF term >= 0 /\ term < Grace /\ prov \in ProvLive THEN term + 1 ELSE term
    /\ killWait' = IF killWait >= 0 /\ killWait < KillTicks /\ prov \in ProvLive
                   THEN killWait + 1 ELSE killWait
    /\ ev' = "tick"
    /\ UNCHANGED <<inputs, fxv, prov, crashed, report, remote, code, remoteChanged, filev, sandbox>>

\* The call is over; time and cleanup may still move.
Done ==
    /\ phase = "done"
    /\ ev' = "none"
    /\ UNCHANGED <<inputs, fxv, provv, remv, filev, sandbox>>

Next ==
    \/ Decide \/ RunLocal \/ StartProvider \/ Collect \/ Stop \/ GraceOver \/ Sweep
    \/ Create \/ CreateFail \/ Push \/ Start \/ Pull \/ Finish \/ OnTerm \/ KillLands \/ Crash
    \/ RemoteEnds \/ TimeOut \/ LocalEdit \/ Tick \/ Done

Fairness ==
    /\ WF_vars(Decide) /\ WF_vars(RunLocal) /\ WF_vars(StartProvider) /\ WF_vars(Collect)
    /\ WF_vars(GraceOver) /\ WF_vars(Sweep) /\ WF_vars(Create) /\ WF_vars(Push)
    /\ WF_vars(Start) /\ WF_vars(Pull) /\ WF_vars(Finish) /\ WF_vars(OnTerm)
    /\ WF_vars(KillLands) /\ WF_vars(TimeOut) /\ WF_vars(Tick)

Spec == Init /\ [][Next]_vars /\ Fairness

-----------------------------------------------------------------------------
(* Rules *)

\* A call placed in a sandbox never runs on this machine.
NoLocalFallback == placement # "local" => ~ranLocal

\* Whatever runs, at either place, was granted for its placement.
GrantPerPlacement == (ranLocal \/ prov # "none") => placement \in grants

\* A terminal call never reaches a provider.
TtyNeverPlaced == (tty /\ placement # "local") => prov = "none"

\* An isolated sandbox gets no configured env.
IsolatedNoKeys == placement = "isolated" => env = {}

\* Bringing files back never overwrites an edit made here during the call.
NoLostLocalEdit == ~lost

\* fx says only what it knows.
HonestResult ==
    /\ result = "didnotrun" => remote = "none"
    /\ result = "exit" => remote \in {"exited", "timedout"}
    /\ result = "stopped" => remote = "killed"
    /\ result \in {"refused", "local"} => prov = "none"

\* A stop that no crash interrupted leaves nothing running.
NoOrphanAfterStop == (term >= 0 /\ ~crashed /\ prov \in ProvGone) => remote # "running"

\* A command whose provider died still ends by its remote timeout.
OrphanBounded == remote = "running" => age <= Timeout

\* Every call ends.
CallEnds == <>(phase = "done")

\* No isolated sandbox stays up for good.
IsolatedCleanedUp == <>[](placement = "isolated" => sandbox # "up")
=============================================================================
