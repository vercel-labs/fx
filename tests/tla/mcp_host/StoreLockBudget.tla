---- MODULE StoreLockBudget ----
\* The MCP credential store's lock with the Keychain backend
\* (src/core/mcp_host/credentials.zig Store.lock), on a whole-second clock.
\*
\* Holders, other fx processes, read and write the Keychain while they hold
\* credentials-v3.lock, each call an osascript child with its own timeout
\* (src/core/hosts/native_keychain.zig keychain_process_timeout). One
\* waiter polls the lock every 10 ms. When it gives up, a refreshed login it
\* was saving is dropped (runtime.zig saveCredential): "another fx kept it
\* busy".
\*
\* The design: before each Keychain call it makes, a holder writes the awake
\* time into the lock file, and the call ends within its own timeout,
\* CallMax <= Budget, of then; the waiter gives up only once the stamp it
\* reads, or its own start if that is later, is Budget + Slack old. A hold
\* of several slow calls lasts as long as they take, and its stamp is never
\* more than one call old. flock has no queue, so other holders may take the
\* lock between the waiter's polls; the laptop may sleep once, which stops
\* the awake clock and moves the real one; a holder may freeze (ctrl+z) and
\* never act again.
\*
\* NoGiveUpOnLiveHolder: the waiter gives up only behind a frozen holder.
EXTENDS Naturals

CONSTANTS
    Holders,   \* the other fx processes that take the lock
    CallMax,   \* one Keychain call's own timeout (s)
    MaxCalls,  \* Keychain calls one hold makes, at most
    Budget,    \* how old a live holder's stamp gets (s): call_budget_ms
    Slack,     \* what a waiter allows past it (s): hold_slack_ms
    MaxSleep   \* the longest laptop sleep (s); 0 for none

VARIABLES
    awake, real,  \* the clocks
    slept,        \* the one sleep happened
    owner,        \* the holder with the lock, or "none"
    state,        \* holder -> "ready" | "holding" | "done"
    needs,        \* holder -> Keychain calls its hold makes
    calls,        \* holder -> calls finished
    inCall,       \* holder -> in a Keychain call
    callAt,       \* holder -> awake time its call started
    stamped,      \* holder -> it wrote the stamp for its next call
    lockStamp,    \* the stamp in the lock file: the last one written
    frozen,       \* holder -> frozen
    waiter,       \* "waiting" | "got" | "gaveup"
    wStart        \* when the waiter started, on its clock

vars == <<awake, real, slept, owner, state, needs, calls, inCall, callAt,
          stamped, lockStamp, frozen, waiter, wStart>>

\* The clock the waiter and the stamps use: awake time.
WClock == awake

Max(a, b) == IF a > b THEN a ELSE b

\* When the waiter gives up on the lock's current holder.
Deadline == Max(lockStamp, wStart) + Budget + Slack

Live(h) == owner = h /\ ~frozen[h]

\* The holder's call has run out its own timeout.
CallOver(h) == inCall[h] /\ awake - callAt[h] >= CallMax

TypeOK ==
    /\ owner \in Holders \cup {"none"}
    /\ state \in [Holders -> {"ready", "holding", "done"}]
    /\ waiter \in {"waiting", "got", "gaveup"}

Init ==
    /\ awake = 0 /\ real = 0 /\ slept = FALSE
    \* Another fx holds the lock, stamped, as the waiter starts: the worst case.
    /\ owner \in Holders
    /\ state = [h \in Holders |-> IF h = owner THEN "holding" ELSE "ready"]
    /\ needs \in [Holders -> 1..MaxCalls]
    /\ calls = [h \in Holders |-> 0]
    /\ inCall = [h \in Holders |-> FALSE]
    /\ callAt = [h \in Holders |-> 0]
    /\ stamped = [h \in Holders |-> h = owner]
    /\ lockStamp = 0
    /\ frozen = [h \in Holders |-> FALSE]
    /\ waiter = "waiting" /\ wStart = 0

\* Another fx takes the free lock between the waiter's polls.
Acquire(h) ==
    /\ owner = "none" /\ state[h] = "ready" /\ waiter = "waiting"
    /\ owner' = h
    /\ state' = [state EXCEPT ![h] = "holding"]
    /\ UNCHANGED <<awake, real, slept, needs, calls, inCall, callAt, stamped, lockStamp, frozen, waiter, wStart>>

\* Before each Keychain call, the holder writes the time into the lock file.
WriteStamp(h) ==
    /\ Live(h) /\ ~stamped[h] /\ ~inCall[h] /\ calls[h] < needs[h]
    /\ stamped' = [stamped EXCEPT ![h] = TRUE]
    /\ lockStamp' = WClock
    /\ UNCHANGED <<awake, real, slept, owner, state, needs, calls, inCall, callAt, frozen, waiter, wStart>>

StartCall(h) ==
    /\ Live(h) /\ stamped[h] /\ ~inCall[h] /\ calls[h] < needs[h]
    /\ inCall' = [inCall EXCEPT ![h] = TRUE]
    /\ callAt' = [callAt EXCEPT ![h] = awake]
    /\ stamped' = [stamped EXCEPT ![h] = FALSE]
    /\ UNCHANGED <<awake, real, slept, owner, state, needs, calls, lockStamp, frozen, waiter, wStart>>

\* A call may answer at any time before it runs out.
EndCall(h) ==
    /\ Live(h) /\ inCall[h] /\ ~CallOver(h)
    /\ inCall' = [inCall EXCEPT ![h] = FALSE]
    /\ calls' = [calls EXCEPT ![h] = @ + 1]
    /\ UNCHANGED <<awake, real, slept, owner, state, needs, callAt, stamped, lockStamp, frozen, waiter, wStart>>

Finish(h) ==
    /\ Live(h) /\ ~inCall[h] /\ calls[h] = needs[h]
    /\ owner' = "none"
    /\ state' = [state EXCEPT ![h] = "done"]
    /\ UNCHANGED <<awake, real, slept, needs, calls, inCall, callAt, stamped, lockStamp, frozen, waiter, wStart>>

\* The call is killed; the operation fails and the lock is released.
Cut(h) ==
    /\ Live(h) /\ CallOver(h)
    /\ owner' = "none"
    /\ state' = [state EXCEPT ![h] = "done"]
    /\ inCall' = [inCall EXCEPT ![h] = FALSE]
    /\ UNCHANGED <<awake, real, slept, needs, calls, callAt, stamped, lockStamp, frozen, waiter, wStart>>

Freeze(h) ==
    /\ Live(h)
    /\ frozen' = [frozen EXCEPT ![h] = TRUE]
    /\ UNCHANGED <<awake, real, slept, owner, state, needs, calls, inCall, callAt, stamped, lockStamp, waiter, wStart>>

Get ==
    /\ waiter = "waiting" /\ owner = "none"
    /\ waiter' = "got"
    /\ UNCHANGED <<awake, real, slept, owner, state, needs, calls, inCall, callAt, stamped, lockStamp, frozen, wStart>>

GiveUp ==
    /\ waiter = "waiting" /\ owner # "none" /\ WClock >= Deadline
    /\ waiter' = "gaveup"
    /\ UNCHANGED <<awake, real, slept, owner, state, needs, calls, inCall, callAt, stamped, lockStamp, frozen, wStart>>

\* Timeouts fire, and a holder moves on between calls, before time does; a
\* free lock is taken within the waiter's 10 ms poll.
Due ==
    \/ \E h \in Holders : Live(h) /\ (CallOver(h) \/ ~inCall[h])
    \/ owner = "none"
    \/ WClock >= Deadline

Tick ==
    /\ waiter = "waiting" /\ ~Due
    /\ awake' = awake + 1 /\ real' = real + 1
    /\ UNCHANGED <<slept, owner, state, needs, calls, inCall, callAt, stamped, lockStamp, frozen, waiter, wStart>>

\* The laptop sleeps: nothing runs, the awake clock stops, real time passes.
Sleep ==
    /\ waiter = "waiting" /\ MaxSleep > 0 /\ ~slept
    /\ \E d \in 1..MaxSleep : real' = real + d
    /\ slept' = TRUE
    /\ UNCHANGED <<awake, owner, state, needs, calls, inCall, callAt, stamped, lockStamp, frozen, waiter, wStart>>

Next ==
    \/ \E h \in Holders : Acquire(h) \/ WriteStamp(h) \/ StartCall(h) \/ EndCall(h) \/ Finish(h) \/ Cut(h) \/ Freeze(h)
    \/ Get \/ GiveUp \/ Tick \/ Sleep

Spec == Init /\ [][Next]_vars

NoGiveUpOnLiveHolder == waiter = "gaveup" => (owner # "none" /\ frozen[owner])
====
