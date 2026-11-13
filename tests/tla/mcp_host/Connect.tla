---- MODULE Connect ----
\* One TCP connect of fx's process `std.Io`, under cancel signals, as
\* src/core/shared/net_connect.zig makes it on macOS and Linux (#1687). The
\* std code it replaces is Io/Threaded.zig `posixConnect`, `Syscall.checkCancel`
\* and Io/net/HostName.zig `connect`.
\*
\* std cancels the helper task of `HostName.connect` on every exit. The
\* cancel sends SIGIO, a handler without SA_RESTART, to a worker thread, and
\* the signal can land after that thread has started another connect. Such a
\* signal is a stray: it is not a cancel of the connect it interrupts.
\*
\* `Std` is std's loop: a blocking `connect`; on EINTR that is not a cancel,
\* `connect` is called again on the same socket. The second call answers
\* EALREADY (std: error.ConnectionPending) or ISCONN (std treats it as a bug:
\* a panic in a debug build, error.Unexpected otherwise), so a connect that the
\* kernel was completing is reported failed. The findings configs check this.
\*
\* net_connect.zig (`Std = FALSE`): the socket is non-blocking and `connect`
\* is called once. `awaitConnected` then loops: `poll` for up to one slice
\* (20 ms, `cancel_check_ms`); if the socket is ready, the kernel's answer is
\* read from SO_ERROR and returned, whatever the cancel flag says; otherwise
\* (the slice ended, or a stray signal ended it early) it looks at the cancel
\* flag and either ends canceled or polls again. A successful connect hands back
\* a blocking socket again. The kernel's answer wins over a cancel that arrives in
\* the same slice: `awaitConnected` in src/core/shared/net_connect.zig reads
\* poll's result before it calls `io.checkCancel`.
\*
\* sock is what the kernel did: connecting, then connected or refused.
\* th is the worker: idle, in_connect (blocked in a blocking connect), waiting
\* (in the poll loop), or done. calls counts `connect` calls on the socket.
\* blocking is the socket's mode: a new socket blocks, net_connect.zig makes
\* it non-blocking while it connects. waitedCanceled records a pass that found
\* the cancel flag set and still polled again.
EXTENDS Naturals

CONSTANTS Std

VARIABLES sock, th, calls, res, cancel, blocking, waitedCanceled

vars == <<sock, th, calls, res, cancel, blocking, waitedCanceled>>

Socks == {"none", "connecting", "connected", "refused"}
Ths == {"idle", "in_connect", "waiting", "done"}
Ress == {"none", "ok", "fail", "canceled"}

TypeOK ==
    /\ sock \in Socks
    /\ th \in Ths
    /\ calls \in 0..2
    /\ res \in Ress
    /\ cancel \in BOOLEAN
    /\ blocking \in BOOLEAN
    /\ waitedCanceled \in BOOLEAN

Init ==
    /\ sock = "none"
    /\ th = "idle"
    /\ calls = 0
    /\ res = "none"
    /\ cancel = FALSE
    /\ blocking = TRUE
    /\ waitedCanceled = FALSE

\* The first and only connect() net_connect.zig makes is non-blocking; std's blocks.
Start ==
    /\ th = "idle"
    /\ sock' = "connecting"
    /\ calls' = 1
    /\ th' = IF Std THEN "in_connect" ELSE "waiting"
    /\ blocking' = Std
    /\ UNCHANGED <<res, cancel, waitedCanceled>>

\* The kernel finishes the handshake or is refused, whenever it likes.
KernelDone ==
    /\ sock = "connecting"
    /\ sock' \in {"connected", "refused"}
    /\ UNCHANGED <<th, calls, res, cancel, blocking, waitedCanceled>>

\* A cancel request. std sends the signal itself; net_connect.zig only sets the flag.
Cancel ==
    /\ th \in {"idle", "in_connect", "waiting"}
    /\ ~cancel
    /\ cancel' = TRUE
    /\ UNCHANGED <<sock, th, calls, res, blocking, waitedCanceled>>

\* ---- std's loop ----

\* The blocking connect returns because the kernel finished.
StdReturn ==
    /\ Std
    /\ th = "in_connect"
    /\ sock \in {"connected", "refused"}
    /\ th' = "done"
    /\ res' = IF sock = "connected" THEN "ok" ELSE "fail"
    /\ UNCHANGED <<sock, calls, cancel, blocking, waitedCanceled>>

\* A signal interrupts the blocked connect (EINTR) and it was a cancel of this
\* connect: std returns error.Canceled.
StdCancelled ==
    /\ Std
    /\ th = "in_connect"
    /\ sock = "connecting"
    /\ cancel
    /\ th' = "done"
    /\ res' = "canceled"
    /\ UNCHANGED <<sock, calls, cancel, blocking, waitedCanceled>>

\* A signal interrupts the blocked connect (EINTR) and it was not a cancel of
\* this connect: connect again, on the same socket. The kernel answers EALREADY
\* or ISCONN, which std reports as a failure or a bug.
StdRetry ==
    /\ Std
    /\ th = "in_connect"
    /\ sock = "connecting"
    /\ ~cancel
    /\ calls' = calls + 1
    /\ th' = "done"
    /\ res' = "fail"
    /\ UNCHANGED <<sock, cancel, blocking, waitedCanceled>>

StdIntr == StdCancelled \/ StdRetry

\* ---- net_connect.zig ----

\* One pass of the poll loop. Three things can end it. The socket is ready
\* (poll returned): its answer is read from SO_ERROR, a canceled connect
\* included. The slice ended or a stray signal ended it, and the cancel flag
\* is set: canceled. The slice ended, the flag is clear and the kernel has not
\* answered: poll again.
FixedPass ==
    /\ ~Std
    /\ th = "waiting"
    /\ \/ /\ sock \in {"connected", "refused"}
          /\ th' = "done"
          /\ res' = IF sock = "connected" THEN "ok" ELSE "fail"
          /\ blocking' = IF sock = "connected" THEN TRUE ELSE blocking
          /\ UNCHANGED <<sock, calls, cancel, waitedCanceled>>
       \/ /\ cancel
          /\ th' = "done"
          /\ res' = "canceled"
          /\ UNCHANGED <<sock, calls, cancel, blocking, waitedCanceled>>
       \/ /\ ~cancel
          /\ sock = "connecting"
          /\ waitedCanceled' = (waitedCanceled \/ cancel)
          /\ UNCHANGED <<sock, th, calls, res, cancel, blocking>>

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

\* A pass that finds the cancel flag set never polls again: a canceled connect
\* ends within one slice.
CancelWins == ~waitedCanceled

\* A socket that is connecting is never given a second connect.
NoReissue == calls <= 1

\* A canceled result needs a cancel.
CanceledNeedsCancel == (res = "canceled") => cancel

\* A connect that succeeded hands back a blocking socket, as std's does.
ReturnsBlocking == (th = "done" /\ res = "ok") => blocking
====
