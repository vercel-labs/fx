-------------------------- MODULE KeyedInputReceipt --------------------------
EXTENDS Naturals, Sequences

CONSTANT ForgetOnRestart
Keys == {"first", "second"}
NoReceipt == 0

VARIABLES log, reply, requested, restarts

Init ==
    /\ log = <<>>
    /\ reply = NoReceipt
    /\ requested = "first"
    /\ restarts = 0

Accept(k) ==
    LET prior == {i \in DOMAIN log : log[i] = k} IN
    /\ Len(log) < 3
    /\ requested' = k
    /\ IF prior = {} \/ (ForgetOnRestart /\ restarts > 0)
       THEN /\ log' = Append(log, k)
            /\ reply' = Len(log')
       ELSE /\ UNCHANGED log
            /\ \E id \in prior : reply' = id
    /\ UNCHANGED restarts

CrashAndReopen ==
    /\ restarts = 0
    /\ restarts' = 1
    /\ reply' = NoReceipt
    /\ UNCHANGED <<log, requested>>

Next == (\E k \in Keys : Accept(k)) \/ CrashAndReopen

Spec == Init /\ [][Next]_<<log, reply, requested, restarts>>

OneReceiptPerKey ==
    \A i, j \in DOMAIN log : (log[i] = log[j]) => i = j

ReplyNamesAcceptedInput ==
    reply = NoReceipt \/ (reply \in DOMAIN log /\ log[reply] = requested)

=============================================================================
