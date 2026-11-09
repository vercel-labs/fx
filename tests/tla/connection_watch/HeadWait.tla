----------------------------- MODULE HeadWait -----------------------------
(* The wait for a model response's first byte on a provider connection
   (`ConnectionWatch` in src/gateway/client.zig, as `post` in
   src/gateway/chat_completions.zig starts it for a configured connection),
   and what recovery does when that wait ends without a head
   (src/core/recovery/recovery.zig).

   One request, through its sends. Each send waits for its head while a
   discrete clock runs; one tick is 5 seconds. The wait ends on one of:
     Head         the server sends its first byte
     ReadFails    the server closed the socket, so the head read fails at once
     Probe        the dead-peer probes find a peer that went silent, within
                  ProbeBound ticks of its death
     Esc          the user cancels
     Deadline     the request's own deadline passes, as a permission review's
                  30 s does
     HeadTimeout  a bounded wait runs out at HeadBound, which the code reports
                  as a lost connection
   A wait that ends on ReadFails, Probe, or HeadTimeout is lost. Recovery
   resends an agent request (Resend); a request with its own deadline goes
   back to its caller (GiveBack).

   The server of each send is slow, which answers within MaxDelay ticks, or
   hung, which never answers but keeps its socket up. Either can die at any
   time: closed, or silent. A cold local model that needs more than two
   minutes before its first byte is a slow server with a delay past
   HeadBound.

   `deadline` is 0 for an agent stream, which has no caller deadline, or the
   request's own deadline in ticks.

   Patient selects which requests wait for their head without a bound:
     "no_deadline"  the design: an agent stream waits as the AI Gateway's
                    agent path does (src/gateway/client.zig
                    streamGatewayCompletionCore), and a request with its own
                    deadline keeps the bound
     "none"         fx before the change: every configured request is bounded
     "all"          planted: a request with its own deadline is patient too
   The other constants plant bugs in the watch:
     WatchDeadline  FALSE: the watch ignores the caller's deadline
     WatchCancel    FALSE: Esc does not end the wait
     Probes         FALSE: nothing finds a peer that went silent

   Time past Horizon is not explored: a hung server on a patient wait waits
   until Esc or a dead socket, by design. *)
EXTENDS Naturals, TLC

CONSTANTS HeadBound, Deadlines, ProbeBound, MaxDelay, Horizon, MaxSends,
          Patient, WatchDeadline, WatchCancel, Probes

ASSUME /\ HeadBound \in Nat /\ ProbeBound \in Nat /\ MaxDelay \in Nat
       /\ Horizon \in Nat /\ MaxSends \in Nat \ {0}
       /\ Deadlines \subseteq Nat \ {0}
       /\ Patient \in {"no_deadline", "none", "all"}
       /\ WatchDeadline \in BOOLEAN /\ WatchCancel \in BOOLEAN /\ Probes \in BOOLEAN

VARIABLES deadline,    \* 0 for an agent stream, else ticks until the caller's deadline
          phase,       \* "waiting", "lost", "done", "cancelled", "timed_out", "failed"
          clock,       \* ticks since this send started waiting
          sends,
          server,      \* "slow", "hung", "closed", "silent"
          sinceDeath,  \* ticks since a silent server died
          esc,
          how,         \* how the current send's wait ended
          droppedAlive, \* a wait ended as lost while its server was still up
          everDied     \* some send's server died

vars == <<deadline, phase, clock, sends, server, sinceDeath, esc, how, droppedAlive, everDied>>

Up == {"slow", "hung"}
Endings == {"none", "head", "read_fails", "probe", "esc", "deadline", "head_timeout"}

Min(a, b) == IF a < b THEN a ELSE b

IsPatient(d) ==
    CASE Patient = "no_deadline" -> d = 0
      [] Patient = "none" -> FALSE
      [] Patient = "all" -> TRUE

TypeOK ==
    /\ deadline \in {0} \cup Deadlines
    /\ phase \in {"waiting", "lost", "done", "cancelled", "timed_out", "failed"}
    /\ clock \in 0..Horizon
    /\ sends \in 1..MaxSends
    /\ server \in Up \cup {"closed", "silent"}
    /\ sinceDeath \in 0..(ProbeBound + 1)
    /\ esc \in BOOLEAN
    /\ how \in Endings
    /\ droppedAlive \in BOOLEAN
    /\ everDied \in BOOLEAN

InitWith(d, s) ==
    /\ deadline = d /\ phase = "waiting" /\ clock = 0 /\ sends = 1
    /\ server = s /\ sinceDeath = 0 /\ esc = FALSE /\ how = "none"
    /\ droppedAlive = FALSE /\ everDied = FALSE

Init == \E d \in {0} \cup Deadlines, s \in Up : InitWith(d, s)

\* The next request starts, for HeadWaitTrace.tla.
ResetWith(d, s) ==
    /\ deadline' = d /\ phase' = "waiting" /\ clock' = 0 /\ sends' = 1
    /\ server' = s /\ sinceDeath' = 0 /\ esc' = FALSE /\ how' = "none"
    /\ droppedAlive' = FALSE /\ everDied' = FALSE

Waiting == phase = "waiting"

\* The clock cannot pass a moment at which the wait must already have ended.
MustEnd ==
    \/ ~IsPatient(deadline) /\ clock >= HeadBound
    \/ WatchDeadline /\ deadline # 0 /\ clock >= deadline
    \/ server = "slow" /\ clock >= MaxDelay
    \/ server = "closed"
    \/ Probes /\ server = "silent" /\ sinceDeath >= ProbeBound

Tick ==
    /\ Waiting /\ clock < Horizon /\ ~MustEnd
    /\ clock' = clock + 1
    /\ sinceDeath' = IF server = "silent" THEN Min(sinceDeath + 1, ProbeBound + 1) ELSE sinceDeath
    /\ UNCHANGED <<deadline, phase, sends, server, esc, how, droppedAlive, everDied>>

Head ==
    /\ Waiting /\ server = "slow"
    /\ phase' = "done" /\ how' = "head"
    /\ UNCHANGED <<deadline, clock, sends, server, sinceDeath, esc, droppedAlive, everDied>>

DieAs(kind) ==
    /\ Waiting /\ server \in Up
    /\ server' = kind /\ sinceDeath' = 0 /\ everDied' = TRUE
    /\ UNCHANGED <<deadline, phase, clock, sends, esc, how, droppedAlive>>

Die == \E kind \in {"closed", "silent"} : DieAs(kind)

Lose(ending) ==
    /\ phase' = "lost" /\ how' = ending
    /\ droppedAlive' = (droppedAlive \/ server \in Up)

ReadFails ==
    /\ Waiting /\ server = "closed"
    /\ Lose("read_fails")
    /\ UNCHANGED <<deadline, clock, sends, server, sinceDeath, esc, everDied>>

Probe ==
    /\ Probes /\ Waiting /\ server = "silent"
    /\ Lose("probe")
    /\ UNCHANGED <<deadline, clock, sends, server, sinceDeath, esc, everDied>>

Esc ==
    /\ Waiting /\ ~esc
    /\ esc' = TRUE
    /\ IF WatchCancel
          THEN phase' = "cancelled" /\ how' = "esc"
          ELSE UNCHANGED <<phase, how>>
    /\ UNCHANGED <<deadline, clock, sends, server, sinceDeath, droppedAlive, everDied>>

Deadline ==
    /\ WatchDeadline /\ Waiting /\ deadline # 0 /\ clock >= deadline
    /\ phase' = "timed_out" /\ how' = "deadline"
    /\ UNCHANGED <<deadline, clock, sends, server, sinceDeath, esc, droppedAlive, everDied>>

HeadTimeout ==
    /\ Waiting /\ ~IsPatient(deadline) /\ clock >= HeadBound
    /\ Lose("head_timeout")
    /\ UNCHANGED <<deadline, clock, sends, server, sinceDeath, esc, everDied>>

\* Recovery sends a lost agent request again, on a new connection.
ResendWith(s) ==
    /\ phase = "lost" /\ deadline = 0 /\ sends < MaxSends
    /\ phase' = "waiting" /\ clock' = 0 /\ sends' = sends + 1
    /\ server' = s /\ sinceDeath' = 0 /\ how' = "none"
    /\ UNCHANGED <<deadline, esc, droppedAlive, everDied>>

Resend == \E s \in Up : ResendWith(s)

\* A request with its own deadline hands a lost send back to its caller.
GiveBack ==
    /\ phase = "lost" /\ deadline # 0
    /\ phase' = "failed"
    /\ UNCHANGED <<deadline, clock, sends, server, sinceDeath, esc, how, droppedAlive, everDied>>

Next ==
    \/ Tick \/ Head \/ Die \/ ReadFails \/ Probe \/ Esc \/ Deadline \/ HeadTimeout
    \/ Resend \/ GiveBack

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
(* Rules *)

\* An agent request's wait ends only on its head, a dead socket, or Esc:
\* silence alone never drops it, however long the server takes.
SilenceNeverDropsAgent == deadline = 0 => ~droppedAlive

\* A server that stays up and answers is answered on the first send.
AnsweredOnFirstSend == (phase = "done" /\ ~everDied) => sends = 1

\* A request with its own deadline ends by that deadline, and never waits
\* for its head past the bound.
OwnDeadlineBounded == (deadline # 0 /\ Waiting) => clock <= Min(deadline, HeadBound)

\* Esc ends the wait at once.
EscEndsWait == esc => ~Waiting

\* A peer that went silent is found within ProbeBound ticks.
DeadSocketFound == (Waiting /\ server = "silent") => sinceDeath <= ProbeBound
=============================================================================
