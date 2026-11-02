---- MODULE ListingWait ----
\* The `@` menu's frame wait (picker_state.FileListingWait) inside fx's event
\* loop. A keystroke starts a folder listing and requests a frame. Each loop
\* iteration harvests a finished listing, asks the wait whether to hold the
\* frame, paints when it does not, and polls again after 1 ms while the wait
\* is measuring a listing or 8 ms otherwise. hold/active/measuring below are
\* transcribed from the implementation; the driver compares every step's
\* hold and measuring values with the real code.
EXTENDS Integers, Sequences

CONSTANTS Durations, Tmax, MaxKeys, PollMeasuring

HoldMs == 8
Within(s, t) == t >= s /\ t - s < HoldMs
Measuring(st, t) == st # 0 /\ Within(st, t)
Active(st, out, t) == ~out /\ Measuring(st, t)

VARIABLES now, started, outlasted, inflight, finishAt, keyFrame, needRows,
          keyAt, keys, curSlow, prevSlow, painted, badFlash, lastHold, lastMeasuring,
          lastInflight, lastNow, history
vars == <<now, started, outlasted, inflight, finishAt, keyFrame, needRows, keyAt, keys,
          curSlow, prevSlow, painted, badFlash, lastHold, lastMeasuring, lastInflight, lastNow, history>>

Init ==
    /\ now = 1 /\ started = 0 /\ outlasted = FALSE /\ inflight = FALSE /\ finishAt = 0
    /\ keyFrame = FALSE /\ needRows = FALSE /\ keyAt = 0 /\ keys = 0
    /\ curSlow = FALSE /\ prevSlow = FALSE /\ painted = <<>> /\ badFlash = FALSE
    /\ lastHold = FALSE /\ lastMeasuring = FALSE /\ lastInflight = FALSE /\ lastNow = 0
    /\ history = <<>>

\* One keystroke, after the previous one's rows are on screen.
Key(d) ==
    /\ ~inflight /\ ~keyFrame /\ ~needRows /\ keys < MaxKeys /\ now + d <= Tmax
    /\ inflight' = TRUE /\ finishAt' = now + d /\ keyFrame' = TRUE /\ keyAt' = now
    /\ keys' = keys + 1 /\ prevSlow' = curSlow /\ curSlow' = (d >= HoldMs)
    /\ history' = Append(history, <<"Key", d>>)
    /\ UNCHANGED <<now, started, outlasted, needRows, painted, badFlash, lastHold, lastMeasuring, lastInflight, lastNow>>

Iterate ==
    LET doneNow == inflight /\ now >= finishAt
        inf == inflight /\ ~doneNow
        \* FileListingWait.hold(inf, now)
        out1 == IF ~inf /\ started # 0 THEN ~Within(started, now) ELSE outlasted
        st1 == IF ~inf THEN 0 ELSE IF started = 0 THEN now ELSE started
        h == IF ~inf THEN FALSE ELSE Active(st1, out1, now)
        meas == Measuring(st1, now)
        paintKey == keyFrame /\ ~h
        timeout == IF (IF PollMeasuring THEN meas ELSE Active(st1, out1, now)) THEN 1 ELSE HoldMs
    IN
    /\ now + timeout <= Tmax + HoldMs
    /\ inflight' = inf /\ started' = st1 /\ outlasted' = out1
    /\ painted' = IF paintKey THEN Append(painted, IF inf THEN "loading" ELSE "rows")
                  ELSE IF needRows /\ ~inf THEN Append(painted, "rows") ELSE painted
    /\ badFlash' = (badFlash \/ (paintKey /\ inf /\ ~curSlow /\ ~prevSlow))
    /\ needRows' = IF paintKey THEN inf ELSE (needRows /\ inf)
    /\ keyFrame' = (keyFrame /\ h)
    /\ lastHold' = h /\ lastMeasuring' = meas /\ lastInflight' = inf /\ lastNow' = now
    /\ now' = now + timeout
    /\ history' = Append(history, <<"Iterate", now>>)
    /\ UNCHANGED <<finishAt, keyAt, keys, curSlow, prevSlow>>

Next == (\E d \in Durations : Key(d)) \/ Iterate
Spec == Init /\ [][Next]_vars

\* A keystroke's frame never waits longer than one 8 ms tick.
HoldBounded == keyFrame => now - keyAt <= HoldMs
\* A loading frame appears only when this listing or the one before it was slow.
NoFlashUnlessSlow == ~badFlash
====
