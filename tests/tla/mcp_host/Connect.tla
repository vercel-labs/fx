---- MODULE Connect ----
\* One TCP connect of fx's `std.Io` on macOS, under cancel signals
\* (std's Io/Threaded.zig `posixConnect`, `Syscall.checkCancel`, and
\* Io/net/HostName.zig `connect`; fx's replacement is
\* src/core/shared/darwin_connect.zig).
\*
\* std cancels the helper task of `HostName.connect` on every exit. The
\* cancel sends SIG.IO, a handler without SA_RESTART, to a worker thread, and
\* the signal can land after that thread has started another connect. Such a
\* signal is a stray: it is not a cancel of the connect it interrupts.
\*
\* `Std` is std's loop: a blocking `connect`; on EINTR that is not a cancel,
\* `connect` is called again on the same socket. macOS answers ISCONN to a
\* second connect on a socket that is connecting or connected, and std treats
\* ISCONN as a bug (a panic in a debug build, error.Unexpected otherwise): a
\* connect that the kernel was completing is reported failed.
\*
\* The fix (`Std = FALSE`): a non-blocking `connect` once, then a loop of
\* short `poll` slices; every pass looks at the cancel flag first, then at the
\* kernel's answer, which is read from SO_ERROR. A stray signal only ends a
\* slice early.
\*
\* sock is what the kernel did: connecting, then connected or refused.
\* th is the worker: idle, in_connect (blocked in a blocking connect), waiting
\* (in the poll loop), or done. calls counts `connect` calls on the socket.
\* cancelAt records where the socket was when the cancel was requested.
EXTENDS Naturals

CONSTANTS Std

VARIABLES sock, th, calls, res, cancel, cancelAt

vars == <<sock, th, calls, res, cancel, cancelAt>>

Socks == {"none", "connecting", "connected", "refused"}
Ths == {"idle", "in_connect", "waiting", "done"}
Ress == {"none", "ok", "fail", "canceled"}
CancelAts == {"none", "connecting", "settled"}

TypeOK ==
    /\ sock \in Socks
    /\ th \in Ths
    /\ calls \in 0..2
    /\ res \in Ress
    /\ cancel \in BOOLEAN
    /\ cancelAt \in CancelAts

Init ==
    /\ sock = "none"
    /\ th = "idle"
    /\ calls = 0
    /\ res = "none"
    /\ cancel = FALSE
    /\ cancelAt = "none"

\* The first and only connect() the fix makes is non-blocking; std's blocks.
Start ==
    /\ th = "idle"
    /\ sock' = "connecting"
    /\ calls' = 1
    /\ th' = IF Std THEN "in_connect" ELSE "waiting"
    /\ UNCHANGED <<res, cancel, cancelAt>>

\* The kernel finishes the handshake or is refused, whenever it likes.
KernelDone ==
    /\ sock = "connecting"
    /\ sock' \in {"connected", "refused"}
    /\ UNCHANGED <<th, calls, res, cancel, cancelAt>>

\* A cancel request. std sends the signal itself; the fix only sets the flag.
Cancel ==
    /\ th \in {"idle", "in_connect", "waiting"}
    /\ ~cancel
    /\ cancel' = TRUE
    /\ cancelAt' = IF sock = "connecting" THEN "connecting" ELSE "settled"
    /\ UNCHANGED <<sock, th, calls, res>>

\* ---- std's loop ----

\* The blocking connect returns because the kernel finished.
StdReturn ==
    /\ Std
    /\ th = "in_connect"
    /\ sock \in {"connected", "refused"}
    /\ th' = "done"
    /\ res' = IF sock = "connected" THEN "ok" ELSE "fail"
    /\ UNCHANGED <<sock, calls, cancel, cancelAt>>

\* A signal interrupts the blocked connect (EINTR) and it was a cancel of this
\* connect: std returns error.Canceled.
StdCancelled ==
    /\ Std
    /\ th = "in_connect"
    /\ sock = "connecting"
    /\ cancel
    /\ th' = "done"
    /\ res' = "canceled"
    /\ UNCHANGED <<sock, calls, cancel, cancelAt>>

\* A signal interrupts the blocked connect (EINTR) and it was not a cancel of
\* this connect: connect again, on the same socket. The kernel answers ISCONN,
\* which std treats as a bug.
StdRetry ==
    /\ Std
    /\ th = "in_connect"
    /\ sock = "connecting"
    /\ ~cancel
    /\ calls' = calls + 1
    /\ th' = "done"
    /\ res' = "fail"
    /\ UNCHANGED <<sock, cancel, cancelAt>>

StdIntr == StdCancelled \/ StdRetry

\* ---- the fix ----

\* One pass of the poll loop: a slice ended, a stray signal, or the socket is
\* ready. The cancel flag is read first, then SO_ERROR.
FixedPass ==
    /\ ~Std
    /\ th = "waiting"
    /\ \/ /\ cancel
          /\ th' = "done"
          /\ res' = "canceled"
          /\ UNCHANGED <<sock, calls, cancel, cancelAt>>
       \/ /\ ~cancel
          /\ sock = "connecting"
          /\ UNCHANGED vars                 \* nothing yet, wait again
       \/ /\ ~cancel
          /\ sock \in {"connected", "refused"}
          /\ th' = "done"
          /\ res' = IF sock = "connected" THEN "ok" ELSE "fail"
          /\ UNCHANGED <<sock, calls, cancel, cancelAt>>

\* The worker is done: nothing more happens (the socket's last steps still can).
Stop ==
    /\ th = "done"
    /\ UNCHANGED vars

Next ==
    \/ Stop
    \/ Start
    \/ KernelDone
    \/ Cancel
    \/ StdReturn
    \/ StdIntr
    \/ FixedPass

Spec == Init /\ [][Next]_vars

\* A connect that the kernel completed is never reported failed.
NoFalseFailure == (res = "fail") => (sock = "refused")

\* A connect is reported connected only when the kernel connected it.
NoFalseSuccess == (res = "ok") => (sock = "connected")

\* A connect whose cancel came while the kernel was still working ends
\* canceled once the worker is done.
CancelWins == (th = "done" /\ cancelAt = "connecting") => (res = "canceled")

\* A socket that is connecting is never given a second connect.
NoReissue == calls <= 1

\* A canceled result needs a cancel.
CanceledNeedsCancel == (res = "canceled") => cancel
====
