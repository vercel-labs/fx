---- MODULE Selftest ----
\* Toolchain self-test for tools/selftest.sh. Not a product model.
\* One request that either gets a response or is cancelled. With the planted
\* bug (AllowLateDelivery), a response can still be delivered after a cancel,
\* which breaks AtMostOneOutcome (the shape of rule REQ-02).
EXTENDS Naturals

CONSTANT AllowLateDelivery

VARIABLES status, outcomes

vars == <<status, outcomes>>

Init ==
    /\ status = "pending"
    /\ outcomes = 0

ResponseReceived ==
    /\ \/ status = "pending"
       \/ AllowLateDelivery /\ status = "cancelled"
    /\ status' = "done"
    /\ outcomes' = outcomes + 1

CancelRequested ==
    /\ status = "pending"
    /\ status' = "cancelled"
    /\ outcomes' = outcomes + 1

Next == ResponseReceived \/ CancelRequested \/ UNCHANGED vars

Spec == Init /\ [][Next]_vars

TypeOK ==
    /\ status \in {"pending", "done", "cancelled"}
    /\ outcomes \in 0..2

AtMostOneOutcome == outcomes <= 1
====
